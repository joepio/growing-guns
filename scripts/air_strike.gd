extends Node3D

const Violence = preload("res://scripts/violence.gd")

const MARKER_COLOR := Color(1.0, 0.08, 0.04)
const ROCKET_TRAVEL_SECONDS := 4.2
const BLAST_RADIUS := 34.0
const BLAST_DAMAGE := 165.0

var target_pos: Vector3 = Vector3.ZERO
var sky_from: Vector3 = Vector3.ZERO

var _fx_scene: Node = null
var _beam: MeshInstance3D = null
var _beam_mat: StandardMaterial3D = null
var _target_light: OmniLight3D = null
var _pulse: float = 0.0
var _inbound: bool = false
var _rocket: Node3D = null
var _body_mat: StandardMaterial3D = null
var _engine_mat: StandardMaterial3D = null
var _plume_mat: StandardMaterial3D = null
var _engine_light: OmniLight3D = null
var _core_light: OmniLight3D = null
var _woosh: AudioStreamPlayer3D = null
var _travel_seconds: float = 0.0
var _travel_elapsed: float = 0.0
var _smoke_tick: float = 0.0
var _flight_tween: Tween = null
var _game: Node = null
var _notify_server: bool = false
var shooter_id: int = 0


func setup(
	fx_scene: Node,
	p_sky_from: Vector3,
	p_target: Vector3,
	p_shooter_id: int = 0,
	game: Node = null,
	notify_server: bool = false,
) -> void:
	_fx_scene = fx_scene
	sky_from = p_sky_from
	target_pos = p_target
	shooter_id = p_shooter_id
	_game = game
	_notify_server = notify_server
	add_to_group("air_strike_markers")
	_travel_seconds = ROCKET_TRAVEL_SECONDS
	_spawn_beam()
	_spawn_target_light()
	SFX.mine_plant(target_pos)
	begin_flight(fx_scene, game, notify_server)


func begin_flight(fx_scene: Node, game: Node, notify_server: bool = false) -> void:
	if _inbound:
		return
	_inbound = true
	if fx_scene != null:
		_fx_scene = fx_scene
	if game != null:
		_game = game
	_notify_server = notify_server
	_travel_elapsed = 0.0
	_smoke_tick = 0.0

	_rocket = _build_rocket_visual()
	add_child(_rocket)
	_rocket.global_position = sky_from
	_orient_rocket_nose_first(_rocket, sky_from, target_pos)

	_woosh = SFX.attach_air_strike_inbound(_rocket, _travel_seconds, false)
	if _flight_tween and _flight_tween.is_valid():
		_flight_tween.kill()
	_flight_tween = create_tween()
	_flight_tween.tween_method(_set_rocket_along_path, 0.0, 1.0, _travel_seconds)\
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_flight_tween.tween_callback(_on_rocket_impact)


func _set_rocket_along_path(t: float) -> void:
	if not is_instance_valid(_rocket):
		return
	_rocket.global_position = sky_from.lerp(target_pos, t)
	_orient_rocket_nose_first(_rocket, sky_from, target_pos)


func _on_rocket_impact() -> void:
	if not _inbound:
		return
	_inbound = false
	var blast_color := Color(1.0, 0.45, 0.08)
	var scene := _fx_scene if is_instance_valid(_fx_scene) else get_tree().current_scene
	var local_player: Node = null
	if _game and is_instance_valid(_game) and _game.get("local_player"):
		local_player = _game.local_player
	if _notify_server and _game and is_instance_valid(_game) and _game.has_method("_apply_environment_explosion"):
		_game.call("_apply_environment_explosion", target_pos, BLAST_RADIUS, BLAST_DAMAGE, shooter_id)
	if scene:
		Violence.spawn_bullet_blast(scene, target_pos, BLAST_RADIUS, blast_color, local_player)
	if is_instance_valid(_rocket):
		_rocket.queue_free()
		_rocket = null
	_finish_strike()


func _finish_strike() -> void:
	if _flight_tween and _flight_tween.is_valid():
		_flight_tween.kill()
		_flight_tween = null
	if is_instance_valid(_beam):
		_beam.queue_free()
		_beam = null
	if is_instance_valid(_target_light):
		_target_light.queue_free()
		_target_light = null
	if is_instance_valid(_rocket):
		_rocket.queue_free()
		_rocket = null
	if _notify_server and _game and is_instance_valid(_game) and _game.has_method("_air_strike_finished"):
		_game.call("_air_strike_finished")
	queue_free()


func _exit_tree() -> void:
	if _flight_tween and _flight_tween.is_valid():
		_flight_tween.kill()
		_flight_tween = null
	_cleanup_fx()


func _cleanup_fx() -> void:
	if is_instance_valid(_beam):
		_beam.queue_free()
		_beam = null
	if is_instance_valid(_target_light):
		_target_light.queue_free()
		_target_light = null
	if is_instance_valid(_rocket):
		_rocket.queue_free()
		_rocket = null


func _spawn_beam() -> void:
	if _fx_scene == null:
		return
	var dist := maxf(sky_from.distance_to(target_pos), 0.5)
	_beam = MeshInstance3D.new()
	_beam.name = "StrikeBeam"
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.12, 0.12, dist)
	_beam.mesh = mesh
	_beam_mat = StandardMaterial3D.new()
	_beam_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_beam_mat.albedo_color = Color(MARKER_COLOR.r, MARKER_COLOR.g, MARKER_COLOR.b, 0.72)
	_beam_mat.emission_enabled = true
	_beam_mat.emission = MARKER_COLOR
	_beam_mat.emission_energy_multiplier = 9.0
	_beam_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_beam.material_override = _beam_mat
	_fx_scene.add_child(_beam)
	_beam.global_position = sky_from.lerp(target_pos, 0.5)
	_orient_along_path(_beam, sky_from, target_pos)


func _spawn_target_light() -> void:
	if _fx_scene == null:
		return
	_target_light = OmniLight3D.new()
	_target_light.name = "StrikeTargetLight"
	_target_light.light_color = MARKER_COLOR
	_target_light.light_energy = 6.0
	_target_light.omni_range = 7.0
	_fx_scene.add_child(_target_light)
	_target_light.global_position = target_pos + Vector3.UP * 0.35


func _orient_along_path(node: Node3D, from: Vector3, to: Vector3) -> void:
	var dir := (to - from).normalized()
	if dir.length_squared() < 0.0001:
		return
	if absf(dir.dot(Vector3.UP)) > 0.99:
		node.look_at(to, Vector3.RIGHT)
	else:
		node.look_at(to, Vector3.UP)


func _orient_rocket_nose_first(node: Node3D, from: Vector3, to: Vector3) -> void:
	var dir := (to - from).normalized()
	if dir.length_squared() < 0.0001:
		return
	var side := Vector3.UP
	if absf(dir.dot(side)) > 0.99:
		side = Vector3.RIGHT
	node.look_at(to, side)
	node.rotate_object_local(Vector3.RIGHT, -PI * 0.5)


func _build_rocket_visual() -> Node3D:
	var root := Node3D.new()
	root.name = "StrikeRocket"
	root.add_to_group("air_strike_rockets")

	var body := MeshInstance3D.new()
	var body_mesh := CylinderMesh.new()
	body_mesh.top_radius = 0.22
	body_mesh.bottom_radius = 0.28
	body_mesh.height = 3.2
	body.mesh = body_mesh
	_body_mat = StandardMaterial3D.new()
	_body_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_body_mat.albedo_color = Color(0.95, 0.72, 0.38)
	_body_mat.emission_enabled = true
	_body_mat.emission = Color(1.0, 0.55, 0.12)
	_body_mat.emission_energy_multiplier = 18.0
	body.material_override = _body_mat
	root.add_child(body)

	var nose := MeshInstance3D.new()
	var nose_mesh := CylinderMesh.new()
	nose_mesh.top_radius = 0.07
	nose_mesh.bottom_radius = 0.22
	nose_mesh.height = 0.8
	nose.mesh = nose_mesh
	nose.position = Vector3(0.0, 2.0, 0.0)
	var nose_mat := StandardMaterial3D.new()
	nose_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	nose_mat.albedo_color = Color(1.0, 0.96, 0.88)
	nose_mat.emission_enabled = true
	nose_mat.emission = Color(1.0, 0.95, 0.82)
	nose_mat.emission_energy_multiplier = 22.0
	nose.material_override = nose_mat
	root.add_child(nose)

	var engine := MeshInstance3D.new()
	engine.name = "EngineCore"
	var engine_mesh := CylinderMesh.new()
	engine_mesh.top_radius = 0.34
	engine_mesh.bottom_radius = 0.16
	engine_mesh.height = 0.75
	engine.mesh = engine_mesh
	engine.position = Vector3(0.0, -1.95, 0.0)
	_engine_mat = StandardMaterial3D.new()
	_engine_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_engine_mat.albedo_color = Color(1.0, 0.82, 0.28)
	_engine_mat.emission_enabled = true
	_engine_mat.emission = Color(1.0, 0.62, 0.1)
	_engine_mat.emission_energy_multiplier = 64.0
	engine.material_override = _engine_mat
	root.add_child(engine)

	var plume := MeshInstance3D.new()
	plume.name = "EnginePlume"
	var plume_mesh := CylinderMesh.new()
	plume_mesh.top_radius = 0.55
	plume_mesh.bottom_radius = 0.12
	plume_mesh.height = 3.6
	plume.mesh = plume_mesh
	plume.position = Vector3(0.0, -4.2, 0.0)
	_plume_mat = StandardMaterial3D.new()
	_plume_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_plume_mat.albedo_color = Color(1.0, 0.48, 0.06, 0.9)
	_plume_mat.emission_enabled = true
	_plume_mat.emission = Color(1.0, 0.32, 0.02)
	_plume_mat.emission_energy_multiplier = 52.0
	_plume_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	plume.material_override = _plume_mat
	root.add_child(plume)

	_core_light = OmniLight3D.new()
	_core_light.name = "EngineCoreLight"
	_core_light.light_color = Color(1.0, 0.72, 0.28)
	_core_light.light_energy = 120.0
	_core_light.omni_range = 55.0
	_core_light.position = Vector3(0.0, -2.0, 0.0)
	root.add_child(_core_light)

	_engine_light = OmniLight3D.new()
	_engine_light.name = "EngineLight"
	_engine_light.light_color = Color(1.0, 0.55, 0.12)
	_engine_light.light_energy = 180.0
	_engine_light.omni_range = 130.0
	_engine_light.position = Vector3(0.0, -3.0, 0.0)
	root.add_child(_engine_light)

	return root


func _process(delta: float) -> void:
	if not _inbound:
		_pulse += delta
		var pulse := sin(_pulse * 6.2)
		if _beam_mat:
			_beam_mat.emission_energy_multiplier = 8.0 + pulse * 2.0
		if _target_light:
			_target_light.light_energy = 5.0 + pulse * 1.5
		return

	_pulse += delta
	var pulse := sin(_pulse * 14.0)
	if _body_mat:
		_body_mat.emission_energy_multiplier = 16.0 + pulse * 6.0
	if _engine_mat:
		_engine_mat.emission_energy_multiplier = 58.0 + pulse * 14.0
	if _plume_mat:
		_plume_mat.emission_energy_multiplier = 48.0 + pulse * 12.0
	if _core_light:
		_core_light.light_energy = 110.0 + pulse * 35.0
	if _engine_light:
		_engine_light.light_energy = 165.0 + pulse * 40.0
	if is_instance_valid(_rocket) and _fx_scene:
		_smoke_tick += delta
		if _smoke_tick >= 0.016:
			_smoke_tick = 0.0
			var flight_dir := (target_pos - sky_from).normalized()
			var spread := Vector3(
				randf_range(-1.0, 1.0),
				randf_range(-0.15, 0.25),
				randf_range(-1.0, 1.0),
			).normalized()
			var tail_base := _rocket.global_position - flight_dir * randf_range(3.6, 5.8)
			for _burst in 2:
				var tail := tail_base + spread * randf_range(0.08, 0.42)
				Violence.spawn_exhaust_smoke(
					_fx_scene,
					tail,
					randf_range(0.45, 0.85),
					(-flight_dir * 0.35 + Vector3.UP * 0.55 + spread * 0.18).normalized(),
				)
	if _woosh:
		_travel_elapsed += delta
		var u := clampf(_travel_elapsed / maxf(_travel_seconds, 0.001), 0.0, 1.0)
		var swell := lerpf(0.62, 1.0, u * u)
		_woosh.volume_db = SFX.air_strike_inbound_db + linear_to_db(swell)
