extends Node3D

const Violence = preload("res://scripts/violence.gd")

const ION_COLOR := Color(0.38, 0.78, 1.0)
const ION_CORE := Color(0.92, 0.97, 1.0)
const CHARGE_SECONDS := 3.8
const SKY_HEIGHT := 220.0
const BOTTOM_DEPTH := 55.0
const START_RADIUS := 30.0
const END_RADIUS := 1.5
const BLAST_RADIUS := 38.0
const BLAST_DAMAGE := 175.0

var target_pos: Vector3 = Vector3.ZERO

var _fx_scene: Node = null
var _cylinder: MeshInstance3D = null
var _cyl_mesh: CylinderMesh = null
var _cyl_mat: StandardMaterial3D = null
var _core_light: OmniLight3D = null
var _ground_light: OmniLight3D = null
var _charge_elapsed: float = 0.0
var _mote_tick: float = 0.0
var _pulse: float = 0.0
var _detonated: bool = false
var _game: Node = null
var _notify_server: bool = false
var shooter_id: int = 0


func setup(
	fx_scene: Node,
	p_target: Vector3,
	p_shooter_id: int = 0,
	game: Node = null,
	notify_server: bool = false,
) -> void:
	_fx_scene = fx_scene
	target_pos = p_target
	shooter_id = p_shooter_id
	_game = game
	_notify_server = notify_server
	add_to_group("ion_cannon_markers")
	_spawn_column()
	_spawn_lights()
	SFX.mine_plant(target_pos)


func _column_layout() -> Dictionary:
	var sky_top := SKY_HEIGHT
	var height := sky_top + BOTTOM_DEPTH
	var center_y := target_pos.y + (sky_top - BOTTOM_DEPTH) * 0.5
	return {
		"height": height,
		"center_y": center_y,
		"sky_top": sky_top,
	}


func _spawn_column() -> void:
	if _fx_scene == null:
		return
	_cylinder = MeshInstance3D.new()
	_cylinder.name = "IonColumn"
	_cyl_mesh = CylinderMesh.new()
	_cyl_mesh.height = SKY_HEIGHT
	_cyl_mesh.top_radius = START_RADIUS
	_cyl_mesh.bottom_radius = START_RADIUS * 1.06
	_cyl_mesh.radial_segments = 36
	_cylinder.mesh = _cyl_mesh
	_cyl_mat = StandardMaterial3D.new()
	_cyl_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_cyl_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_cyl_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_cyl_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_cyl_mat.albedo_color = Color(ION_COLOR.r, ION_COLOR.g, ION_COLOR.b, 0.09)
	_cyl_mat.emission_enabled = true
	_cyl_mat.emission = ION_CORE
	_cyl_mat.emission_energy_multiplier = 28.0
	_cylinder.material_override = _cyl_mat
	_fx_scene.add_child(_cylinder)
	var layout := _column_layout()
	_cyl_mesh.height = layout.height
	_cylinder.global_position = Vector3(target_pos.x, layout.center_y, target_pos.z)


func _spawn_lights() -> void:
	if _fx_scene == null:
		return
	_core_light = OmniLight3D.new()
	_core_light.name = "IonCoreLight"
	_core_light.light_color = ION_CORE
	_core_light.light_energy = 22.0
	_core_light.omni_range = 110.0
	_fx_scene.add_child(_core_light)
	_core_light.global_position = target_pos + Vector3.UP * (SKY_HEIGHT * 0.55)

	_ground_light = OmniLight3D.new()
	_ground_light.name = "IonGroundLight"
	_ground_light.light_color = ION_COLOR
	_ground_light.light_energy = 14.0
	_ground_light.omni_range = 28.0
	_fx_scene.add_child(_ground_light)
	_ground_light.global_position = target_pos + Vector3.UP * 0.4


func _spawn_ascending_mote(radius: float) -> void:
	if _fx_scene == null:
		return
	var ang := randf() * TAU
	var rad := randf() * radius * 0.82
	var start := target_pos + Vector3(cos(ang) * rad, randf_range(0.15, 2.5), sin(ang) * rad)
	var mote := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = randf_range(0.04, 0.11)
	mesh.height = mesh.radius * 2.0
	mesh.radial_segments = 6
	mesh.rings = 4
	mote.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = Color(0.72, 0.9, 1.0, 0.0)
	mat.emission_enabled = true
	mat.emission = Color(0.82, 0.94, 1.0)
	mat.emission_energy_multiplier = randf_range(32.0, 58.0)
	mote.material_override = mat
	mote.position = start
	mote.add_to_group("ion_cannon_motes")
	_fx_scene.add_child(mote)
	var rise := randf_range(12.0, 34.0)
	var end_pos := start + Vector3(
		randf_range(-1.2, 1.2),
		rise,
		randf_range(-1.2, 1.2),
	)
	var lifetime := randf_range(2.2, 4.2)
	var peak_alpha := randf_range(0.32, 0.62)
	var tw := mote.create_tween().set_parallel(true)
	tw.tween_property(mote, "position", end_pos, lifetime)\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.tween_property(mote, "scale", Vector3.ONE * randf_range(1.4, 2.4), lifetime * 0.85)\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	var atw := mote.create_tween()
	atw.tween_property(mat, "albedo_color", Color(0.82, 0.94, 1.0, peak_alpha), lifetime * 0.28)\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	atw.tween_property(mat, "albedo_color", Color(0.82, 0.94, 1.0, 0.0), lifetime * 0.72)\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	atw.tween_callback(mote.queue_free)


func _update_column(u: float, pulse: float) -> void:
	var focus := u * u
	var glow := u * u * u
	var radius := lerpf(START_RADIUS, END_RADIUS, focus)
	var layout := _column_layout()
	var height: float = layout.height
	var center_y: float = layout.center_y
	var sky_top: float = layout.sky_top
	if _cyl_mesh:
		_cyl_mesh.top_radius = radius
		_cyl_mesh.bottom_radius = radius * 1.04
		_cyl_mesh.height = height
	if _cylinder:
		_cylinder.global_position = Vector3(target_pos.x, center_y, target_pos.z)
	if _cyl_mat:
		_cyl_mat.emission_energy_multiplier = lerpf(28.0, 420.0, glow) + pulse * 14.0 * glow
		_cyl_mat.albedo_color = Color(
			ION_COLOR.r,
			ION_COLOR.g,
			ION_COLOR.b,
			lerpf(0.08, 0.92, glow),
		)
	if _core_light:
		_core_light.global_position = Vector3(
			target_pos.x,
			target_pos.y + sky_top * 0.58,
			target_pos.z,
		)
		_core_light.light_energy = lerpf(22.0, 420.0, glow) + pulse * 28.0 * glow
		_core_light.omni_range = lerpf(110.0, 48.0, focus)
	if _ground_light:
		_ground_light.light_energy = lerpf(14.0, 180.0, glow) + pulse * 10.0 * glow
		_ground_light.omni_range = lerpf(28.0, 20.0, focus)


func _detonate() -> void:
	if _detonated:
		return
	_detonated = true
	var blast_color := Color(0.68, 0.9, 1.0)
	var scene := _fx_scene if is_instance_valid(_fx_scene) else get_tree().current_scene
	var local_player: Node = null
	if _game and is_instance_valid(_game) and _game.get("local_player"):
		local_player = _game.local_player
	if _notify_server and _game and is_instance_valid(_game) and _game.has_method("_apply_environment_explosion"):
		_game.call("_apply_environment_explosion", target_pos, BLAST_RADIUS, BLAST_DAMAGE, shooter_id)
	if scene:
		Violence.spawn_bullet_blast(scene, target_pos, BLAST_RADIUS, blast_color, local_player)
	_finish()


func _finish() -> void:
	if is_instance_valid(_cylinder):
		_cylinder.queue_free()
		_cylinder = null
	if is_instance_valid(_core_light):
		_core_light.queue_free()
		_core_light = null
	if is_instance_valid(_ground_light):
		_ground_light.queue_free()
		_ground_light = null
	if _notify_server and _game and is_instance_valid(_game) and _game.has_method("_ion_cannon_finished"):
		_game.call("_ion_cannon_finished")
	queue_free()


func _exit_tree() -> void:
	if is_instance_valid(_cylinder):
		_cylinder.queue_free()
	if is_instance_valid(_core_light):
		_core_light.queue_free()
	if is_instance_valid(_ground_light):
		_ground_light.queue_free()


func _process(delta: float) -> void:
	if _detonated:
		return
	_pulse += delta
	_charge_elapsed += delta
	var pulse := sin(_pulse * 9.0)
	var u := clampf(_charge_elapsed / CHARGE_SECONDS, 0.0, 1.0)
	_update_column(u, pulse)
	_mote_tick += delta
	if _mote_tick >= 0.065:
		_mote_tick = 0.0
		var focus := u * u
		var glow := u * u * u
		if glow >= 0.08:
			var radius := lerpf(START_RADIUS, END_RADIUS, focus)
			var mote_count := 1 if glow < 0.35 else 2
			for _i in mote_count:
				_spawn_ascending_mote(radius)
	if _charge_elapsed >= CHARGE_SECONDS:
		_detonate()
