extends Node3D

# Visual iteration lab for hand-hewn stone blocks.
# Interactive: godot --path . res://scenes/rock_lab.tscn
# Capture:      tools/capture_rock_lab.sh artifacts/rock_lab.png

const DestructibleSolid = preload("res://scripts/destructible_solid.gd")
const ArenaGenerator = preload("res://scripts/arena_generator.gd")

const BLOCK := 2.4
const INSET := DestructibleSolid.VISUAL_CHUNK_INSET
const CAPTURE_SIZE := Vector2i(1280, 720)


func _ready() -> void:
	var capture_path := _cli_capture_path()
	if capture_path.is_empty():
		DisplayServer.window_set_size(CAPTURE_SIZE)
		var world := Node3D.new()
		world.name = "World"
		add_child(world)
		_build_environment(world)
		_build_wall(world)
		var cam := Camera3D.new()
		cam.position = Vector3(5.8, 3.4, 7.2)
		cam.fov = 52.0
		world.add_child(cam)
		cam.look_at(Vector3(2.4, 2.0, 0.8), Vector3.UP)
		return
	await _run_offscreen_capture(capture_path)


func _cli_capture_path() -> String:
	var args := OS.get_cmdline_user_args()
	for i: int in args.size():
		if args[i] == "--capture" and i + 1 < args.size():
			return String(args[i + 1])
	return ""


func _run_offscreen_capture(path: String) -> void:
	var vp := SubViewport.new()
	vp.name = "CaptureViewport"
	vp.size = CAPTURE_SIZE
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.msaa_3d = Viewport.MSAA_4X
	add_child(vp)

	var world := Node3D.new()
	world.name = "World"
	vp.add_child(world)
	_build_environment(world)
	_build_wall(world)

	var cam := Camera3D.new()
	cam.position = Vector3(5.8, 3.4, 7.2)
	cam.fov = 52.0
	world.add_child(cam)
	cam.look_at(Vector3(2.4, 2.0, 0.8), Vector3.UP)

	for _i: int in 6:
		await get_tree().process_frame
	RenderingServer.force_draw(true)
	await get_tree().process_frame

	var tex: ViewportTexture = vp.get_texture()
	if tex == null:
		push_error("RockLab: SubViewport texture is null")
		get_tree().quit(1)
		return
	var img: Image = tex.get_image()
	if img == null or img.is_empty():
		push_error("RockLab: captured image is empty")
		get_tree().quit(1)
		return

	if not path.is_absolute_path():
		path = ProjectSettings.globalize_path("res://").path_join(path)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var err := img.save_png(path)
	if err != OK:
		push_error("RockLab capture failed (%d): %s" % [err, path])
		get_tree().quit(1)
		return
	print("RockLab captured: ", path, " (", img.get_width(), "x", img.get_height(), ")")
	get_tree().quit()


func _build_environment(parent: Node3D) -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.06, 0.05, 0.07)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.52, 0.50, 0.48)
	env.ambient_light_energy = 1.05
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.08
	env.ssao_enabled = true
	env.ssao_radius = 1.1
	env.ssao_intensity = 0.52
	env.sdfgi_enabled = false

	var we := WorldEnvironment.new()
	we.environment = env
	parent.add_child(we)

	var key := DirectionalLight3D.new()
	key.light_color = Color(1.0, 0.78, 0.52)
	key.light_energy = 2.2
	key.rotation_degrees = Vector3(-52.0, 38.0, 0.0)
	key.shadow_enabled = true
	parent.add_child(key)

	var fill := DirectionalLight3D.new()
	fill.light_color = Color(0.50, 0.58, 0.72)
	fill.light_energy = 0.45
	fill.rotation_degrees = Vector3(-18.0, -125.0, 0.0)
	parent.add_child(fill)


func _build_wall(parent: Node3D) -> void:
	var root := Node3D.new()
	root.name = "StoneWall"
	parent.add_child(root)

	var mesh: Mesh = DestructibleSolid.get_stone_block_mesh()
	var wall_color := Color(0.56, 0.52, 0.47)
	var floor_color := wall_color.darkened(0.12)
	var mat := ArenaGenerator.make_rock_material(wall_color, 0.96, 101)
	var floor_mat := ArenaGenerator.make_rock_material(floor_color, 0.98, 404)

	var blocks: Array[Dictionary] = []
	for y: int in 3:
		var row_shift := (BLOCK * 0.5) if y % 2 == 1 else 0.0
		for x: int in 4:
			blocks.append({
				"pos": Vector3(x * BLOCK + row_shift, y * BLOCK + BLOCK * 0.5, 0.0),
				"cell": Vector3i(x, y, 0),
			})
	for x: int in 5:
		blocks.append({
			"pos": Vector3(x * BLOCK - BLOCK * 0.5, 0.0, BLOCK * 0.6),
			"cell": Vector3i(x, -1, 1),
		})
	for y: int in 3:
		var row_shift := (BLOCK * 0.5) if y % 2 == 1 else 0.0
		for z: int in 3:
			blocks.append({
				"pos": Vector3(0.0, y * BLOCK + BLOCK * 0.5, z * BLOCK + BLOCK * 0.6 + row_shift),
				"cell": Vector3i(-1, y, z),
			})

	_add_block_batch(
		root, mesh, mat,
		blocks.filter(func(b: Dictionary) -> bool: return int((b["cell"] as Vector3i).y) != -1),
	)
	_add_block_batch(
		root, mesh, floor_mat,
		blocks.filter(func(b: Dictionary) -> bool: return int((b["cell"] as Vector3i).y) == -1),
	)


func _add_block_batch(parent: Node3D, mesh: Mesh, mat: Material, blocks: Array) -> void:
	if blocks.is_empty():
		return
	var mmi := MultiMeshInstance3D.new()
	mmi.material_override = mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = blocks.size()
	for i: int in blocks.size():
		var b: Dictionary = blocks[i]
		var pos: Vector3 = b["pos"] as Vector3
		var cell: Vector3i = b["cell"] as Vector3i
		mm.set_instance_transform(
			i, Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * BLOCK * INSET), pos))
		mm.set_instance_custom_data(i, _lab_custom_data(cell))
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	parent.add_child(mmi)


func _lab_custom_data(cell: Vector3i) -> Color:
	var h: int = hash([4242, cell.x, cell.y, cell.z])
	var h2: int = hash([h, 90210])
	var h3: int = hash([h, 31337])
	var h4: int = hash([h, 7919])
	return Color(
		float(h % 1000) / 1000.0,
		0.72 + float(h2 % 100) / 118.0,
		0.86 + float(h3 % 140) / 280.0,
		0.38 + float(h4 % 100) / 115.0,
	)
