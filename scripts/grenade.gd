extends RigidBody3D

const FUSE := 1.8
const ARM_DELAY := 0.12          # ignore contacts for this long after spawn
const RADIUS := 6.0
const MAX_DAMAGE := 100
const MIN_DAMAGE := 10
const SHAKE_RADIUS := 22.0
const SHAKE_STRENGTH := 0.16     # max camera-shake amplitude (m) at the epicenter
const VFX_TRANSIENT_LIGHTS := false
const MINE_TRIGGER_RADIUS := 1.25
const MINE_LIFETIME := 10.0        # mines self-detonate if nobody wanders in

@export var shooter_id: int = 1
@export var is_mine: bool = false

var _age := 0.0
var _exploded := false

func _ready() -> void:
	set_multiplayer_authority(1)
	if not multiplayer.is_server():
		freeze = true
		freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	body_entered.connect(_on_body_entered)

func _physics_process(delta: float) -> void:
	if _exploded:
		return
	_age += delta
	if not multiplayer.is_server():
		return
	if is_mine:
		if _age >= MINE_LIFETIME:
			_explode()
		else:
			_maybe_trigger_mine()
	elif _age >= FUSE:
		_explode()

func _on_body_entered(_body: Node) -> void:
	# Only the authoritative server triggers explosions; clients are passive visuals.
	if not multiplayer.is_server() or _exploded:
		return
	if _age < ARM_DELAY:
		return
	if is_mine:
		return
	_explode()

func _maybe_trigger_mine() -> void:
	if _age < ARM_DELAY:
		return
	for p in get_tree().get_nodes_in_group("players"):
		if not is_instance_valid(p):
			continue
		if p.get("ghost_mode") == true:
			continue
		if global_position.distance_to(p.global_position) <= MINE_TRIGGER_RADIUS:
			_explode()
			return

# Called when a bullet hits the grenade (server-side raycast on the rifle).
func detonate() -> void:
	if _exploded or not multiplayer.is_server():
		return
	_explode()

func _explode() -> void:
	_exploded = true
	for p in get_tree().get_nodes_in_group("players"):
		if not is_instance_valid(p):
			continue
		var dist: float = global_position.distance_to(p.global_position)
		if dist > RADIUS:
			continue
		var space := get_world_3d().direct_space_state
		var q := PhysicsRayQueryParameters3D.create(global_position, p.global_position)
		q.collision_mask = 1  # world only — LoS check
		var hit := space.intersect_ray(q)
		if not hit.is_empty():
			continue

		var falloff: float = clamp(1.0 - (dist / RADIUS), 0.0, 1.0)
		var dmg: int = int(lerp(float(MIN_DAMAGE), float(MAX_DAMAGE), falloff))

		# Self-damage reduction
		if p.player_id == shooter_id:
			dmg = int(dmg * 0.4)

		if dmg > 0:
			p.take_damage.rpc_id(p.get_multiplayer_authority(), dmg, shooter_id)

		# Grenade Knockback
		var kb_force: float = 18.0 # Stronger base for heavy grenades
		var dir: Vector3 = (p.global_position - global_position)
		if dir.length_squared() > 0.001:
			dir = dir.normalized()
		else:
			dir = Vector3.UP

		var impulse: Vector3 = (dir * kb_force * falloff) + (Vector3.UP * kb_force * 0.4 * falloff)
		p.apply_knockback.rpc_id(p.get_multiplayer_authority(), impulse)
	_do_vfx.rpc()

@rpc("authority", "call_local", "reliable")
func _do_vfx() -> void:
	SFX.explosion(global_position)
	var pos: Vector3 = global_position
	var scene: Node = get_tree().current_scene

	# --- Bright white-hot core flash (very short)
	var core := MeshInstance3D.new()
	var core_mesh := SphereMesh.new()
	core_mesh.radius = 0.6
	core_mesh.height = 1.2
	core.mesh = core_mesh
	var core_mat := StandardMaterial3D.new()
	core_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	core_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	core_mat.albedo_color = Color(1.0, 0.95, 0.75, 1.0)
	core_mat.emission_enabled = true
	core_mat.emission = Color(1.0, 0.85, 0.4)
	core_mat.emission_energy_multiplier = 10.0
	core.material_override = core_mat
	core.position = pos
	scene.add_child(core)
	var ctw := core.create_tween().set_parallel(true)
	ctw.tween_property(core, "scale", Vector3(4.0, 4.0, 4.0), 0.12)\
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	ctw.tween_property(core_mat, "albedo_color", Color(1, 1, 1, 0.0), 0.14)
	ctw.tween_property(core_mat, "emission_energy_multiplier", 0.0, 0.14)
	ctw.chain().tween_callback(core.queue_free)

	# --- Orange shockwave ring (expands to blast radius)
	var wave := MeshInstance3D.new()
	var wave_mesh := SphereMesh.new()
	wave_mesh.radius = 0.3
	wave_mesh.height = 0.6
	wave.mesh = wave_mesh
	var wave_mat := StandardMaterial3D.new()
	wave_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	wave_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	wave_mat.albedo_color = Color(1.0, 0.45, 0.15, 0.55)
	wave_mat.emission_enabled = true
	wave_mat.emission = Color(1.0, 0.35, 0.08)
	wave_mat.emission_energy_multiplier = 5.0
	wave_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	wave.material_override = wave_mat
	wave.position = pos
	scene.add_child(wave)
	var wtw := wave.create_tween().set_parallel(true)
	wtw.tween_property(wave, "scale", Vector3(14.0, 14.0, 14.0), 0.32)\
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	wtw.tween_property(wave_mat, "albedo_color", Color(1, 0.3, 0.0, 0.0), 0.32)
	wtw.tween_property(wave_mat, "emission_energy_multiplier", 0.0, 0.32)
	wtw.chain().tween_callback(wave.queue_free)

	if VFX_TRANSIENT_LIGHTS:
		var light := OmniLight3D.new()
		light.light_color = Color(1.0, 0.65, 0.25)
		light.light_energy = 22.0
		light.omni_range = 16.0
		light.position = pos
		scene.add_child(light)
		var ltw := light.create_tween()
		ltw.tween_property(light, "light_energy", 0.0, 0.25).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
		ltw.tween_callback(light.queue_free)

	# --- Local camera shake with distance falloff
	var lp: Node = scene.get("local_player")
	if lp and is_instance_valid(lp):
		var dist: float = pos.distance_to(lp.global_position)
		if dist < SHAKE_RADIUS:
			var strength: float = SHAKE_STRENGTH * (1.0 - dist / SHAKE_RADIUS)
			lp.shake_amt = max(lp.shake_amt, strength)

	queue_free()
