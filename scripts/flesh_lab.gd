extends Node3D

# Flesh-gun prototype lab: the same default rifle at four corruption stages,
# side by side. Shows how DemonGrowth overgrows the metal skeleton as cards
# stack (0% = current game look, 100% = fully alive).
#
#   godot --path . res://scenes/flesh_lab.tscn                    # interactive (guns slowly turn)
#   godot --path . res://scenes/flesh_lab.tscn -- capture=/tmp/flesh.png
#   godot --path . res://scenes/flesh_lab.tscn -- levels=0.08,0.17,0.25,0.33  # custom corruption row

const GUN_SCRIPT := preload("res://scripts/procedural_gun.gd")
const GROWTH_SCRIPT := preload("res://scripts/demon_growth.gd")
var LEVELS: Array[float] = [0.0, 0.35, 0.65, 1.0]
const ROW_Y := 1.2
const SPACING := 0.95

var _cam: Camera3D
var _holders: Array[Node3D] = []

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("levels="):
			LEVELS.clear()
			for s in a.substr(7).split(","):
				LEVELS.append(clampf(float(s), 0.0, 1.0))
	_build_env()
	for i in LEVELS.size():
		var holder := Node3D.new()
		holder.name = "Gun%d" % i
		holder.position = Vector3((float(i) - float(LEVELS.size() - 1) * 0.5) * SPACING, ROW_Y, 0.0)
		# 3/4 view: muzzle toward camera-left so barrel + receiver both read.
		holder.rotation = Vector3(0.0, deg_to_rad(65.0), 0.0)
		add_child(holder)
		var gun: Node3D = GUN_SCRIPT.new()
		gun.name = "ProceduralGun"
		holder.add_child(gun)
		var growth: Node3D = GROWTH_SCRIPT.new()
		growth.name = "Growth"
		holder.add_child(growth)
		growth.gun_path = growth.get_path_to(gun)
		growth.corruption = LEVELS[i]
		var lbl := Label3D.new()
		lbl.text = "%d%%" % int(round(LEVELS[i] * 100.0))
		lbl.font_size = 64
		lbl.pixel_size = 0.0012
		lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lbl.position = Vector3(0, -0.42, 0)
		holder.add_child(lbl)
		_holders.append(holder)
	_build_camera()
	if _cli_capture() != "":
		_run_capture()

func _process(delta: float) -> void:
	if _cli_capture() != "":
		return
	for h in _holders:
		h.rotate_y(delta * 0.35)

func _build_env() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.09, 0.08, 0.085)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.5, 0.45, 0.45)
	env.ambient_light_energy = 0.5
	env.glow_enabled = true
	env.glow_intensity = 0.6
	env.glow_bloom = 0.1
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	# Warm key from upper-right, cool fill from the left — flesh needs shape.
	var key := DirectionalLight3D.new()
	key.light_color = Color(1.0, 0.9, 0.8)
	key.light_energy = 1.9
	key.rotation = Vector3(deg_to_rad(-35.0), deg_to_rad(35.0), 0.0)
	add_child(key)
	var fill := OmniLight3D.new()
	fill.light_color = Color(0.5, 0.6, 0.9)
	fill.light_energy = 1.2
	fill.omni_range = 8.0
	fill.position = Vector3(-2.5, 1.0, 2.0)
	add_child(fill)
	var floor_mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(20, 20)
	floor_mi.mesh = pm
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color(0.16, 0.14, 0.13)
	fm.roughness = 0.9
	floor_mi.material_override = fm
	add_child(floor_mi)

func _build_camera() -> void:
	_cam = Camera3D.new()
	_cam.fov = 45.0
	add_child(_cam)
	if _has_flag("close"):
		# Close-up on the 100% gun — inspect eye/teeth/flesh detail.
		var target := Vector3(float(LEVELS.size() - 1 - 1.5) * SPACING, ROW_Y, 0.0)
		_cam.position = target + Vector3(-0.45, 0.12, 0.62)
		_cam.look_at(target + Vector3(0.0, -0.02, 0.0), Vector3.UP)
	else:
		_cam.position = Vector3(0.0, 1.5, 2.9)
		_cam.look_at(Vector3(0.0, ROW_Y - 0.02, 0.0), Vector3.UP)
	_cam.make_current()

func _has_flag(flag: String) -> bool:
	return OS.get_cmdline_user_args().has(flag + "=1")

func _cli_capture() -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("capture="):
			return a.substr(8)
	return ""

func _run_capture() -> void:
	var size := Vector2i(1500, 700)
	DisplayServer.window_set_size(size)
	get_viewport().size = size
	# Let the heartbeat shader and eye settle a few beats before the still.
	for _i in 40:
		await get_tree().process_frame
	RenderingServer.force_draw(true)
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_cli_capture())
	print("[fleshlab] captured: ", _cli_capture())
	get_tree().quit()
