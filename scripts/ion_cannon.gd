extends Node3D

const DestructibleManager = preload("res://scripts/destructible_manager.gd")

const ION_COLOR := Color(0.38, 0.78, 1.0)
const ION_CORE := Color(0.92, 0.97, 1.0)
const CHARGE_SECONDS := 3.8
const SKY_HEIGHT := 2200.0
const BOTTOM_DEPTH := 55.0
const START_RADIUS := 30.0
const END_RADIUS := 1.5
const BLAST_RADIUS := 38.0
const BLAST_DAMAGE := 175.0
const DETONATION_CYLINDER_UP := 880.0
const DETONATION_DEPTH_BELOW_LAVA := 20.0
const DETONATION_LINE_COUNT := 40
const DETONATION_LINE_MIN_SPEED := 70.0
const DETONATION_LINE_MAX_SPEED := 120.0
const DETONATION_LINE_MIN_LEN := 16.0
const DETONATION_LINE_MAX_LEN := 30.0
const DETONATION_LINE_MIN_LIFE := 0.28
const DETONATION_LINE_MAX_LIFE := 0.62
const DETONATION_SHELL_FADE := 0.17
const DETONATION_FLASH_SUSTAIN := 0.05
const DETONATION_FLASH_RELEASE := 0.30

# Nested shells read as a volumetric column without FogVolume setup.
const COLUMN_LAYERS := [
	{
		"radius_scale": 0.08,
		"alpha_start": 0.035,
		"alpha_end": 1.0,
		"emission_start": 5.0,
		"emission_end": 5200.0,
		"emission": Color(0.42, 0.72, 0.96),
	},
	{
		"radius_scale": 0.15,
		"alpha_start": 0.028,
		"alpha_end": 0.92,
		"emission_start": 4.0,
		"emission_end": 3400.0,
		"emission": Color(0.46, 0.76, 0.98),
	},
	{
		"radius_scale": 0.25,
		"alpha_start": 0.022,
		"alpha_end": 0.78,
		"emission_start": 3.2,
		"emission_end": 2100.0,
		"emission": Color(0.40, 0.74, 0.98),
	},
	{
		"radius_scale": 0.38,
		"alpha_start": 0.018,
		"alpha_end": 0.58,
		"emission_start": 2.6,
		"emission_end": 1200.0,
		"emission": Color(0.36, 0.70, 0.98),
	},
	{
		"radius_scale": 0.52,
		"alpha_start": 0.014,
		"alpha_end": 0.42,
		"emission_start": 2.0,
		"emission_end": 680.0,
		"emission": Color(0.32, 0.66, 0.96),
	},
	{
		"radius_scale": 0.68,
		"alpha_start": 0.010,
		"alpha_end": 0.28,
		"emission_start": 1.5,
		"emission_end": 360.0,
		"emission": Color(0.28, 0.62, 0.94),
	},
	{
		"radius_scale": 0.84,
		"alpha_start": 0.008,
		"alpha_end": 0.18,
		"emission_start": 1.1,
		"emission_end": 190.0,
		"emission": Color(0.24, 0.58, 0.90),
	},
	{
		"radius_scale": 1.0,
		"alpha_start": 0.006,
		"alpha_end": 0.12,
		"emission_start": 0.8,
		"emission_end": 95.0,
		"emission": Color(0.20, 0.54, 0.86),
	},
]

var target_pos: Vector3 = Vector3.ZERO

var _fx_scene: Node = null
var _column_root: Node3D = null
var _column_layers: Array[MeshInstance3D] = []
var _column_meshes: Array[CylinderMesh] = []
var _column_mats: Array[StandardMaterial3D] = []
var _core_light: OmniLight3D = null
var _mid_light: OmniLight3D = null
var _ground_light: OmniLight3D = null
var _charge_audio: AudioStreamPlayer3D = null
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
	if _column_root:
		# Sound from the ground-level strike point, not the sky-high column root
		# (the audio source would otherwise be ~1km up and culled to silence).
		_charge_audio = SFX.attach_ion_cannon_charge(_column_root, CHARGE_SECONDS, target_pos)


func _column_layout() -> Dictionary:
	var sky_top := SKY_HEIGHT
	var height := sky_top + BOTTOM_DEPTH
	var center_y := target_pos.y + (sky_top - BOTTOM_DEPTH) * 0.5
	return {
		"height": height,
		"center_y": center_y,
		"sky_top": sky_top,
	}


# Pre-compile the additive ion-beam material PSOs so the first ION CANNON cast
# of the match doesn't hitch (~200ms) while the charge column appears. The
# charge column, ascending motes and detonation shells all share one additive
# unshaded/fog-disabled PSO variant, so warming the column + ion-add materials
# (built from the real factories) covers them all. Routed through
# Violence.warmup_material, which renders them sub-pixel for a few frames.
static func warmup_shaders(scene: Node) -> void:
	if scene == null:
		return
	Violence.warmup_material(scene, _make_column_material(COLUMN_LAYERS[0]))
	Violence.warmup_material(scene, _make_ion_add_material(ION_COLOR, 0.5, 400.0))


static func _make_column_material(layer: Dictionary) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.disable_fog = true
	mat.no_depth_test = false
	mat.emission_enabled = true
	mat.emission = layer.get("emission", ION_CORE)
	mat.albedo_color = Color(
		layer.emission.r,
		layer.emission.g,
		layer.emission.b,
		layer.get("alpha_start", 0.1),
	)
	mat.emission_energy_multiplier = float(layer.get("emission_start", 20.0))
	return mat


func _spawn_column() -> void:
	if _fx_scene == null:
		return
	_column_root = Node3D.new()
	_column_root.name = "IonColumnRoot"
	_fx_scene.add_child(_column_root)
	var layout := _column_layout()
	_column_root.global_position = Vector3(target_pos.x, layout.center_y, target_pos.z)
	for i in COLUMN_LAYERS.size():
		var layer: Dictionary = COLUMN_LAYERS[i]
		var mesh := CylinderMesh.new()
		mesh.height = layout.height
		mesh.top_radius = START_RADIUS * float(layer.get("radius_scale", 1.0))
		mesh.bottom_radius = mesh.top_radius * 1.03
		mesh.radial_segments = 44 if i <= 1 else 36 if i <= 4 else 28
		var shell := MeshInstance3D.new()
		shell.name = "IonShell%d" % i
		shell.mesh = mesh
		shell.material_override = _make_column_material(layer)
		_column_root.add_child(shell)
		_column_meshes.append(mesh)
		_column_mats.append(shell.material_override as StandardMaterial3D)
		_column_layers.append(shell)


func _spawn_lights() -> void:
	if _fx_scene == null:
		return
	_core_light = OmniLight3D.new()
	_core_light.name = "IonCoreLight"
	_core_light.light_color = ION_CORE
	_core_light.light_energy = 6.0
	_core_light.omni_range = 120.0
	_fx_scene.add_child(_core_light)
	_core_light.global_position = target_pos + Vector3.UP * (SKY_HEIGHT * 0.58)

	_mid_light = OmniLight3D.new()
	_mid_light.name = "IonMidLight"
	_mid_light.light_color = ION_COLOR.lerp(ION_CORE, 0.45)
	_mid_light.light_energy = 4.0
	_mid_light.omni_range = 82.0
	_fx_scene.add_child(_mid_light)
	_mid_light.global_position = target_pos + Vector3.UP * (SKY_HEIGHT * 0.22)

	_ground_light = OmniLight3D.new()
	_ground_light.name = "IonGroundLight"
	_ground_light.light_color = ION_COLOR
	_ground_light.light_energy = 3.0
	_ground_light.omni_range = 30.0
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
	mat.disable_fog = true
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


func _charge_curves(u: float) -> Dictionary:
	# Keep the first second ghostly; snap to white HDR only in the final stretch.
	var focus := u * u
	var vis := pow(u, 4.2)
	var power := pow(u, 2.35)
	var ignite := smoothstep(0.48, 0.985, u)
	return {
		"focus": focus,
		"vis": vis,
		"power": power,
		"ignite": ignite,
	}


func _update_column(u: float, pulse: float) -> void:
	var curves := _charge_curves(u)
	var focus: float = curves.focus
	var vis: float = curves.vis
	var power: float = curves.power
	var ignite: float = curves.ignite
	var radius := lerpf(START_RADIUS, END_RADIUS, focus)
	var layout := _column_layout()
	var height: float = layout.height
	var center_y: float = layout.center_y
	var sky_top: float = layout.sky_top
	if _column_root:
		_column_root.global_position = Vector3(target_pos.x, center_y, target_pos.z)
	for i in _column_meshes.size():
		var layer: Dictionary = COLUMN_LAYERS[i]
		var mesh := _column_meshes[i]
		var mat := _column_mats[i]
		var shell_radius := radius * float(layer.get("radius_scale", 1.0))
		mesh.height = height
		mesh.top_radius = shell_radius
		mesh.bottom_radius = shell_radius * 1.03
		if mat:
			var base_col: Color = layer.get("emission", ION_CORE)
			var emission_col := base_col.lerp(Color(1.0, 1.0, 1.0), ignite)
			var alpha := lerpf(
				float(layer.get("alpha_start", 0.1)),
				float(layer.get("alpha_end", 0.5)),
				vis,
			)
			mat.albedo_color = Color(emission_col.r, emission_col.g, emission_col.b, alpha)
			mat.emission = emission_col
			mat.emission_energy_multiplier = lerpf(
				float(layer.get("emission_start", 20.0)),
				float(layer.get("emission_end", 200.0)),
				power,
			) + pulse * 14.0 * power * (1.0 - float(i) * 0.1)
	if _core_light:
		_core_light.global_position = Vector3(
			target_pos.x,
			target_pos.y + sky_top * 0.58,
			target_pos.z,
		)
		_core_light.light_color = ION_CORE.lerp(Color(1.0, 1.0, 1.0), ignite)
		_core_light.light_energy = lerpf(6.0, 760.0, power) + pulse * 36.0 * power
		_core_light.omni_range = lerpf(120.0, 68.0, focus)
	if _mid_light:
		_mid_light.global_position = Vector3(
			target_pos.x,
			target_pos.y + sky_top * 0.24,
			target_pos.z,
		)
		_mid_light.light_color = ION_COLOR.lerp(Color(1.0, 1.0, 1.0), ignite * 0.92)
		_mid_light.light_energy = lerpf(4.0, 480.0, power) + pulse * 24.0 * power
		_mid_light.omni_range = lerpf(82.0, 48.0, focus)
	if _ground_light:
		_ground_light.light_color = ION_COLOR.lerp(Color(1.0, 1.0, 1.0), ignite * 0.75)
		_ground_light.light_energy = lerpf(3.0, 240.0, power) + pulse * 10.0 * power
		_ground_light.omni_range = lerpf(30.0, 22.0, focus)
	if _charge_audio and is_instance_valid(_charge_audio):
		var swell := lerpf(0.48, 1.0, power)
		_charge_audio.volume_db = SFX.ion_cannon_charge_db + linear_to_db(swell)


func _free_column() -> void:
	if is_instance_valid(_column_root):
		_column_root.queue_free()
	_column_root = null
	_column_layers.clear()
	_column_meshes.clear()
	_column_mats.clear()


func _clear_charge_motes() -> void:
	for node in get_tree().get_nodes_in_group("ion_cannon_motes"):
		if is_instance_valid(node):
			node.queue_free()


func _snap_off_charge_vfx() -> void:
	_free_column()
	if is_instance_valid(_core_light):
		_core_light.queue_free()
		_core_light = null
	if is_instance_valid(_mid_light):
		_mid_light.queue_free()
		_mid_light = null
	if is_instance_valid(_ground_light):
		_ground_light.queue_free()
		_ground_light = null


func _detonate() -> void:
	if _detonated:
		return
	_detonated = true
	_clear_charge_motes()
	_snap_off_charge_vfx()
	if is_instance_valid(_charge_audio):
		_charge_audio.stop()
		_charge_audio = null
	SFX.ion_cannon_detonate(target_pos, BLAST_RADIUS)
	var scene := _fx_scene if is_instance_valid(_fx_scene) else get_tree().current_scene
	var local_player: Node = null
	if _game and is_instance_valid(_game) and _game.get("local_player"):
		local_player = _game.local_player
	if _notify_server and _game and is_instance_valid(_game) and _game.has_method("_apply_ion_cannon_explosion"):
		_game.call("_apply_ion_cannon_explosion", target_pos, BLAST_RADIUS, BLAST_DAMAGE, shooter_id)
	if scene:
		DestructibleManager.apply_blast(target_pos, BLAST_RADIUS * 0.52, BLAST_DAMAGE)
		var sidechain_peak := 5.5
		if scene.has_method("trigger_explosion_sidechain"):
			scene.trigger_explosion_sidechain(
				target_pos, BLAST_RADIUS, sidechain_peak, DETONATION_FLASH_SUSTAIN, DETONATION_FLASH_RELEASE,
			)
		if local_player and is_instance_valid(local_player) and local_player.has_method("apply_explosion_view_punch"):
			local_player.apply_explosion_view_punch(
				target_pos,
				BLAST_RADIUS,
				clampf(BLAST_RADIUS / 5.0, 0.55, 2.0),
			)
		_spawn_ion_detonation_fx(scene, target_pos, BLAST_RADIUS)
	_finish()


static func _make_ion_add_material(tint: Color, alpha: float, emission: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.disable_fog = true
	mat.emission_enabled = true
	mat.emission = tint
	mat.albedo_color = Color(tint.r, tint.g, tint.b, alpha)
	mat.emission_energy_multiplier = emission
	return mat


func _spawn_ion_rise_line(parent: Node3D, radius: float, _cyl_height: float, rng: RandomNumberGenerator) -> void:
	var line_len := rng.randf_range(DETONATION_LINE_MIN_LEN, DETONATION_LINE_MAX_LEN)
	var line := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = rng.randf_range(0.09, 0.22)
	mesh.bottom_radius = mesh.top_radius
	mesh.height = line_len
	mesh.radial_segments = 6
	mesh.rings = 1
	line.mesh = mesh
	var peak_emission := rng.randf_range(420.0, 900.0)
	var mat := _make_ion_add_material(Color(1.0, 1.0, 1.0), rng.randf_range(0.7, 1.0), peak_emission)
	line.material_override = mat
	var ang := rng.randf() * TAU
	var dist := sqrt(rng.randf()) * radius * 0.88
	# Random height around the blast site — roughly 20 m below to 20 m above ground.
	var base_y := rng.randf_range(-20.0, 20.0)
	line.position = Vector3(cos(ang) * dist, base_y, sin(ang) * dist)
	line.rotation.y = rng.randf_range(0.0, TAU)
	parent.add_child(line)
	var speed := rng.randf_range(DETONATION_LINE_MIN_SPEED, DETONATION_LINE_MAX_SPEED)
	var lifetime := rng.randf_range(DETONATION_LINE_MIN_LIFE, DETONATION_LINE_MAX_LIFE)
	var travel_y := speed * lifetime
	var end_pos := line.position + Vector3(
		rng.randf_range(-1.5, 1.5),
		travel_y,
		rng.randf_range(-1.5, 1.5),
	)
	var tw := line.create_tween().set_parallel(true)
	tw.tween_property(line, "position", end_pos, lifetime)\
		.set_trans(Tween.TRANS_LINEAR)
	tw.tween_property(mat, "emission_energy_multiplier", 0.0, lifetime * 0.85)\
		.set_delay(lifetime * 0.15).set_trans(Tween.TRANS_LINEAR)
	tw.tween_property(mat, "albedo_color", Color(1.0, 1.0, 1.0, 0.0), lifetime)\
		.set_trans(Tween.TRANS_LINEAR)
	tw.chain().tween_callback(line.queue_free)


static func damage_column_bounds(scene: Node, strike_pos: Vector3) -> Dictionary:
	var lava_y := _lava_surface_world_y_for_scene(scene, strike_pos)
	var bottom_y := lava_y - DETONATION_DEPTH_BELOW_LAVA
	var top_y := strike_pos.y + DETONATION_CYLINDER_UP
	return {"bottom_y": bottom_y, "top_y": top_y}


static func _lava_surface_world_y_for_scene(scene: Node, strike_pos: Vector3) -> float:
	var arena: Node = scene.get_node_or_null("Arena") if scene else null
	if arena and arena.has_method("get_lava_surface_world_y"):
		return float(arena.get_lava_surface_world_y())
	if arena:
		return arena.global_position.y - 2.0
	return strike_pos.y - BOTTOM_DEPTH


func _detonation_column_layout(scene: Node, strike_pos: Vector3) -> Dictionary:
	var lava_y := _lava_surface_world_y_for_scene(scene, strike_pos)
	var bottom_y := lava_y - DETONATION_DEPTH_BELOW_LAVA
	var top_y := strike_pos.y + DETONATION_CYLINDER_UP
	var height := maxf(12.0, top_y - bottom_y)
	var center_local_y := (top_y + bottom_y) * 0.5 - strike_pos.y
	return {"height": height, "center_y": center_local_y}


func _spawn_detonation_flash(parent: Node3D, radius: float) -> void:
	var flash := OmniLight3D.new()
	flash.name = "IonDetonationFlash"
	flash.light_color = Color(0.96, 0.99, 1.0)
	flash.light_energy = 22000.0
	flash.omni_range = radius * 6.0
	flash.position = Vector3(0.0, 2.0, 0.0)
	parent.add_child(flash)
	var ltw := flash.create_tween()
	ltw.tween_interval(DETONATION_FLASH_SUSTAIN)
	ltw.tween_property(flash, "light_energy", 0.0, DETONATION_FLASH_RELEASE)\
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_IN)
	ltw.tween_callback(flash.queue_free)

func _spawn_ion_detonation_fx(scene: Node, pos: Vector3, radius: float) -> void:
	var root := Node3D.new()
	root.name = "IonDetonationFx"
	scene.add_child(root)
	root.global_position = pos

	_spawn_detonation_flash(root, radius)

	var layout := _detonation_column_layout(scene, pos)
	var cyl_height: float = layout.height
	var shell := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = radius
	cyl.bottom_radius = radius
	cyl.height = cyl_height
	cyl.radial_segments = 56
	cyl.rings = 2
	shell.mesh = cyl
	var shell_tint := ION_CORE.lerp(ION_COLOR, 0.18)
	var shell_mat := _make_ion_add_material(shell_tint, 0.0, 0.0)
	shell.material_override = shell_mat
	shell.position = Vector3(0.0, layout.center_y, 0.0)
	root.add_child(shell)

	var shell_tw := shell.create_tween()
	shell_tw.tween_property(shell_mat, "emission_energy_multiplier", 14000.0, 0.012)\
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	shell_tw.parallel().tween_property(shell_mat, "albedo_color", Color(shell_tint.r, shell_tint.g, shell_tint.b, 0.72), 0.012)
	shell_tw.tween_property(shell_mat, "emission_energy_multiplier", 5200.0, 0.018)\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	shell_tw.parallel().tween_property(shell_mat, "albedo_color", Color(shell_tint.r, shell_tint.g, shell_tint.b, 0.45), 0.018)
	shell_tw.tween_property(shell_mat, "emission_energy_multiplier", 0.0, DETONATION_SHELL_FADE)\
		.set_trans(Tween.TRANS_LINEAR)
	shell_tw.parallel().tween_property(shell_mat, "albedo_color", Color(shell_tint.r, shell_tint.g, shell_tint.b, 0.0), DETONATION_SHELL_FADE)

	var rng := RandomNumberGenerator.new()
	rng.seed = hash([pos.x, pos.y, pos.z, radius]) & 0x7fffffff
	for _i in DETONATION_LINE_COUNT:
		_spawn_ion_rise_line(root, radius, cyl_height, rng)

	for i in 4:
		var fill_light := OmniLight3D.new()
		fill_light.light_color = ION_CORE
		fill_light.light_energy = 0.0
		fill_light.omni_range = radius * 3.2
		fill_light.position = Vector3(0.0, 4.0 + float(i) * 6.0, 0.0)
		root.add_child(fill_light)
		var peak_energy := 5200.0 - float(i) * 650.0
		var ltw := fill_light.create_tween()
		ltw.tween_property(fill_light, "light_energy", peak_energy, 0.012)\
			.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
		ltw.tween_property(fill_light, "light_energy", 0.0, DETONATION_SHELL_FADE * (0.75 + float(i) * 0.05))\
			.set_trans(Tween.TRANS_LINEAR)

	var cleanup := root.create_tween()
	cleanup.tween_interval(DETONATION_SHELL_FADE + 0.65)
	cleanup.tween_callback(root.queue_free)


func _finish() -> void:
	_free_column()
	if is_instance_valid(_charge_audio):
		_charge_audio.stop()
		_charge_audio = null
	if is_instance_valid(_core_light):
		_core_light.queue_free()
		_core_light = null
	if is_instance_valid(_mid_light):
		_mid_light.queue_free()
		_mid_light = null
	if is_instance_valid(_ground_light):
		_ground_light.queue_free()
		_ground_light = null
	if _notify_server and _game and is_instance_valid(_game) and _game.has_method("_ion_cannon_finished"):
		_game.call("_ion_cannon_finished")
	queue_free()


func _exit_tree() -> void:
	_free_column()
	if is_instance_valid(_charge_audio):
		_charge_audio.stop()
		_charge_audio = null
	if is_instance_valid(_core_light):
		_core_light.queue_free()
	if is_instance_valid(_mid_light):
		_mid_light.queue_free()
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
		var curves := _charge_curves(u)
		var focus: float = curves.focus
		var power: float = curves.power
		if power >= 0.12:
			var radius := lerpf(START_RADIUS, END_RADIUS, focus)
			var mote_count := 1 if power < 0.42 else 2 if power < 0.78 else 3
			for _i in mote_count:
				_spawn_ascending_mote(radius)
	if _charge_elapsed >= CHARGE_SECONDS:
		_detonate()
