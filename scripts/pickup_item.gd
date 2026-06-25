extends Node3D

# Sky-drop power-up. Server spawns via Game._spawn_pickup_item; all peers run
# the same fall physics, server alone handles collection.

const KINDS: PackedStringArray = ["heart", "mushroom", "bomb", "plus_one", "laser", "dice", "air_strike"]

const FALL_GRAVITY := 28.0
const MAX_FALL_SPEED := 55.0
const COLLECT_RADIUS := 1.45
const BOB_SPEED := 4.2
const BOB_AMOUNT := 0.08
const LIFETIME_GROUNDED := 45.0

var kind: String = "heart"
var _pickup_id: int = -1
var _spawn_sky_pos := Vector3.ZERO
var _land_pos := Vector3.ZERO
var _velocity := Vector3.ZERO
var _grounded := false
var _ground_y := 0.0
var _bob_phase := 0.0
var _grounded_time := 0.0
var _collected := false
var _visual: Node3D = null
var _base_visual_y := 0.0
var _beam: MeshInstance3D = null
var _beam_mat: StandardMaterial3D = null
var _ground_light: OmniLight3D = null
var _beam_pulse := 0.0


static func beam_color(p_kind: String) -> Color:
	match p_kind:
		"heart":
			return Color(1.0, 0.25, 0.45)
		"mushroom":
			return Color(1.0, 0.35, 0.2)
		"bomb":
			return Color(1.0, 0.72, 0.15)
		"plus_one":
			return Color(0.35, 1.0, 0.45)
		"laser":
			return Color(0.25, 0.95, 1.0)
		"air_strike":
			return Color(1.0, 0.45, 0.12)
		_:
			return Color(0.85, 0.95, 1.0)


static func display_info(p_kind: String) -> Dictionary:
	match p_kind:
		"heart":
			return {"title": "HEART", "subtitle": "+50 HP (overheal)", "color": beam_color(p_kind)}
		"mushroom":
			return {"title": "MUSHROOM", "subtitle": "+100 HP, big body", "color": beam_color(p_kind)}
		"bomb":
			return {"title": "BOMB", "subtitle": "2× explosive rounds", "color": beam_color(p_kind)}
		"plus_one":
			return {"title": "+1 UP", "subtitle": "Revive once this round", "color": beam_color(p_kind)}
		"laser":
			return {"title": "LASER RIFLE", "subtitle": "A lot of crazy fast pew pews", "color": beam_color(p_kind)}
		"dice":
			return {"title": "DICE", "subtitle": "Random stat ×2 and ×½", "color": Color(0.95, 0.85, 1.0)}
		"air_strike":
			return {"title": "AIR STRIKE", "subtitle": "Next RMB: rocket on crosshair", "color": beam_color(p_kind)}
		_:
			return {"title": "PICKUP", "subtitle": "", "color": beam_color(p_kind)}


func setup(p_kind: String, world_pos: Vector3, pickup_id: int = -1) -> void:
	kind = p_kind
	_pickup_id = pickup_id
	_spawn_sky_pos = world_pos
	_land_pos = _compute_landing_pos(world_pos)
	global_position = world_pos
	_velocity = Vector3.ZERO
	_grounded = false
	_grounded_time = 0.0
	_collected = false
	_bob_phase = randf() * TAU
	add_to_group("pickups")
	_build_visual()
	_build_drop_beam()
	_base_visual_y = _visual.position.y if _visual else 0.0


func _physics_process(delta: float) -> void:
	_beam_pulse += delta
	_tick_fall(delta)
	_update_drop_beam_pulse()
	if _grounded:
		_grounded_time += delta
		_tick_bob(delta)
		if _grounded_time >= LIFETIME_GROUNDED:
			queue_free()
			return
	if multiplayer.is_server():
		_try_collect()


func _tick_fall(delta: float) -> void:
	if _grounded:
		return
	_velocity.y = maxf(_velocity.y - FALL_GRAVITY * delta, -MAX_FALL_SPEED)
	var from := global_position
	var to := from + Vector3(0.0, _velocity.y * delta, 0.0)
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, to, 1)
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		global_position = to
		return
	var hit_pos: Vector3 = hit.get("position", to)
	global_position = hit_pos + Vector3.UP * 0.42
	_land_pos = global_position
	_ground_y = global_position.y
	_grounded = true
	_velocity = Vector3.ZERO


func _tick_bob(delta: float) -> void:
	if _visual == null:
		return
	_bob_phase += delta * BOB_SPEED
	_visual.position.y = _base_visual_y + sin(_bob_phase) * BOB_AMOUNT


func _try_collect() -> void:
	if _collected:
		return
	var game := get_tree().current_scene
	var is_coop := false
	if game and game.has_method("is_coop_mode"):
		is_coop = game.is_coop_mode()
	
	for node in get_tree().get_nodes_in_group("players"):
		if not node is Node3D:
			continue
		var player := node as Node3D
		if is_coop and bool(player.get("is_bot")):
			continue
		if bool(player.get("ghost_mode")):
			continue
		if int(player.get("health")) <= 0:
			continue
		if bool(player.get("launching")):
			continue
		if player.global_position.distance_to(global_position) > COLLECT_RADIUS * _player_collect_scale(player):
			continue
		_collect(player)
		return


func _player_collect_scale(player: Node) -> float:
	if player.get("weapon") == null:
		return 1.0
	var w = player.get("weapon")
	if w == null:
		return 1.0
	return maxf(1.0, float(w.body_scale))


func _collect(player: Node) -> void:
	if _collected:
		return
	_collected = true
	if player.has_method("apply_round_pickup"):
		player.apply_round_pickup.rpc(kind)
	var game := get_tree().current_scene
	if game and game.has_method("_despawn_pickup") and _pickup_id >= 0:
		game._despawn_pickup.rpc(_pickup_id)
	else:
		queue_free()


func _build_drop_beam() -> void:
	var color := beam_color(kind)
	_beam = MeshInstance3D.new()
	_beam.name = "DropBeam"
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.12
	mesh.bottom_radius = 0.36
	mesh.height = 1.0
	_beam.mesh = mesh
	_beam_mat = StandardMaterial3D.new()
	_beam_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_beam_mat.albedo_color = Color(color.r, color.g, color.b, 0.78)
	_beam_mat.emission_enabled = true
	_beam_mat.emission = color
	_beam_mat.emission_energy_multiplier = 13.0
	_beam_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_beam.material_override = _beam_mat
	add_child(_beam)

	_ground_light = OmniLight3D.new()
	_ground_light.name = "DropLight"
	_ground_light.light_color = color
	_ground_light.light_energy = 8.0
	_ground_light.omni_range = 5.5
	add_child(_ground_light)
	_orient_drop_beam()


func _compute_landing_pos(from_sky: Vector3) -> Vector3:
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from_sky, from_sky + Vector3.DOWN * 500.0, 1)
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return from_sky + Vector3.DOWN * 48.0 + Vector3.UP * 0.42
	return hit.get("position", from_sky) + Vector3.UP * 0.42


func _orient_drop_beam() -> void:
	if _beam == null:
		return
	var from := _spawn_sky_pos
	var to := _land_pos
	var dist := maxf(from.distance_to(to), 0.5)
	var mesh := _beam.mesh as CylinderMesh
	mesh.height = dist
	_beam.top_level = true
	_beam.global_position = from.lerp(to, 0.5)
	var dir := (to - from).normalized()
	if absf(dir.dot(Vector3.UP)) > 0.99:
		_beam.look_at(from + dir, Vector3.RIGHT)
	else:
		_beam.look_at(from + dir, Vector3.UP)
	_beam.rotate_object_local(Vector3.RIGHT, PI * 0.5)
	if _ground_light:
		_ground_light.top_level = true
		_ground_light.global_position = to + Vector3.UP * 0.08


func _update_drop_beam_pulse() -> void:
	if _beam_mat:
		_beam_mat.emission_energy_multiplier = 11.0 + sin(_beam_pulse * 4.2) * 2.5


func _build_visual() -> void:
	if _visual:
		_visual.queue_free()
	_visual = Node3D.new()
	_visual.name = "Visual"
	add_child(_visual)
	match kind:
		"heart":
			_add_sphere(_visual, 0.28, Color(1.0, 0.18, 0.28), 3.5)
		"mushroom":
			_add_sphere(_visual, 0.22, Color(0.95, 0.2, 0.18), 2.5, Vector3(0.0, 0.24, 0.0))
			_add_cylinder(_visual, 0.16, 0.14, 0.18, Color(0.95, 0.88, 0.72), 1.2)
		"bomb":
			_add_sphere(_visual, 0.26, Color(0.12, 0.12, 0.14), 2.0)
			_add_sphere(_visual, 0.06, Color(1.0, 0.85, 0.2), 4.0, Vector3(0.16, 0.2, 0.0))
		"plus_one":
			_add_box(_visual, Vector3(0.42, 0.42, 0.12), Color(0.25, 0.95, 0.35), 3.0)
		"laser":
			_add_cylinder(_visual, 0.08, 0.08, 0.36, Color(0.2, 0.95, 1.0), 5.0)
			_add_sphere(_visual, 0.05, Color(1.0, 0.2, 0.2), 6.0, Vector3(0.0, 0.0, -0.22))
		"dice":
			_add_box(_visual, Vector3(0.34, 0.34, 0.34), Color(0.95, 0.92, 1.0), 4.5)
			_add_sphere(_visual, 0.05, Color(0.15, 0.15, 0.2), 3.0, Vector3(0.1, 0.12, 0.18))
		"air_strike":
			_build_air_strike_rocket(_visual)
		_:
			_add_sphere(_visual, 0.25, Color.WHITE, 2.0)


func _build_air_strike_rocket(parent: Node3D) -> void:
	var body_color := Color(0.95, 0.72, 0.38)
	var hot := Color(1.0, 0.55, 0.12)
	_add_cylinder(parent, 0.06, 0.075, 0.34, body_color, 4.2)
	_add_cylinder(parent, 0.02, 0.06, 0.11, Color(1.0, 0.96, 0.88), 5.5, Vector3(0.0, 0.225, 0.0))
	_add_cylinder(parent, 0.095, 0.045, 0.11, hot, 7.0, Vector3(0.0, -0.225, 0.0))
	_add_box(parent, Vector3(0.16, 0.02, 0.04), body_color, 2.8, Vector3(0.0, -0.1, 0.0))
	_add_box(parent, Vector3(0.04, 0.02, 0.16), body_color, 2.8, Vector3(0.0, -0.1, 0.0))


func _add_sphere(parent: Node3D, radius: float, color: Color, energy: float, pos: Vector3 = Vector3.ZERO) -> void:
	var mi := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 7
	mesh.rings = 4
	mi.mesh = mesh
	mi.material_override = _mat(color, energy)
	mi.position = pos
	parent.add_child(mi)


func _add_cylinder(
	parent: Node3D,
	top_r: float,
	bottom_r: float,
	height: float,
	color: Color,
	energy: float,
	pos: Vector3 = Vector3.ZERO,
) -> void:
	var mi := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = top_r
	mesh.bottom_radius = bottom_r
	mesh.height = height
	mesh.radial_segments = 6
	mesh.rings = 1
	mi.mesh = mesh
	mi.material_override = _mat(color, energy)
	mi.position = pos
	parent.add_child(mi)


func _add_box(parent: Node3D, size: Vector3, color: Color, energy: float, pos: Vector3 = Vector3.ZERO) -> void:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.material_override = _mat(color, energy)
	mi.position = pos
	parent.add_child(mi)


func _mat(color: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = color
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = energy
	return m
