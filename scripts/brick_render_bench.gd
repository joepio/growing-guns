extends Node3D

# Isolated RENDER benchmark for deformed bricks — no bullets/AI/physics, just the
# GPU cost of drawing a realistic field of stone bricks where a fraction are dense
# + GPU-deformed. Sweeps the deformed-brick subdivision so we can see how poly
# count trades against framerate, and decide the brick geometry.
#
# Run (must be windowed — headless has no real renderer):
#   godot --path . res://scenes/brick_render_bench.tscn
#   godot --path . res://scenes/brick_render_bench.tscn -- count=2000 frac=0.3
#   godot --path . res://scenes/brick_render_bench.tscn -- subdiv=12   (single)

const DestructibleSolid := preload("res://scripts/destructible_solid.gd")
const ArenaGenerator := preload("res://scripts/arena_generator.gd")

const BRICK := 2.0           # brick world size (m)
const INSET := 0.96
const BASE_SUBDIV := DestructibleSolid.CHUNK_MESH_SUBDIVIDE
const WARMUP_FRAMES := 30
const MEASURE_SEC := 3.5

var total := 1500            # total bricks on screen (realistic-ish wall field)
var dmg_frac := 0.22         # fraction on damage material (hit bricks)
var subdiv_sweep: Array = [2, 3, 4, 5]

var _cam: Camera3D
var _base_mat: ShaderMaterial
var _dmg_mat: ShaderMaterial
var _undmg_mmi: MultiMeshInstance3D
var _dmg_mmi: MultiMeshInstance3D
var _cols := 0
var _rows := 0

var _results: Array = []
var _sweep_i := 0
var _phase := "warmup"
var _phase_frames := 0
var _accum := 0.0
var _frames := 0


var _capture_path := ""


func _ready() -> void:
	_parse_args()
	_build_world()
	_layout_bricks()
	_undmg_mmi.multimesh.mesh = DestructibleSolid._build_hand_hewn_stone_mesh(BASE_SUBDIV)
	if _capture_path != "":
		_dmg_mmi.multimesh.mesh = DestructibleSolid._build_hand_hewn_stone_mesh(subdiv_sweep[0])
		_run_capture(_capture_path)
		return
	_start_subdiv()


func _parse_args() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("count="):
			total = maxi(1, int(a.substr(6)))
		elif a.begins_with("frac="):
			dmg_frac = clampf(float(a.substr(5)), 0.0, 1.0)
		elif a.begins_with("subdiv="):
			subdiv_sweep = [int(a.substr(7))]
		elif a.begins_with("capture="):
			_capture_path = a.substr(8)


func _run_capture(path: String) -> void:
	# Angle the camera so corner/edge erosion shows in the silhouette.
	var d := _cam.position.z
	_cam.position = Vector3(d * 0.55, d * 0.32, d * 0.82)
	_cam.look_at(Vector3.ZERO, Vector3.UP)
	for _i in 30:
		await get_tree().process_frame
	RenderingServer.force_draw(true)
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(path)
	print("[brickbench] captured: ", path)
	get_tree().quit()


func _build_world() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.05, 0.06, 0.09)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.4, 0.42, 0.48)
	env.ambient_light_energy = 0.5
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-42.0, -34.0, 0.0)
	sun.light_energy = 1.1
	add_child(sun)

	_cam = Camera3D.new()
	_cam.fov = 70.0
	add_child(_cam)

	_base_mat = ArenaGenerator.make_rock_material(Color(0.55, 0.51, 0.46), 0.95, 7)
	_dmg_mat = _base_mat.duplicate() as ShaderMaterial
	_dmg_mat.set_shader_parameter("damage_enabled", 1.0)
	_dmg_mat.set_shader_parameter("damage_tex", _make_damage_tex())
	_dmg_mat.set_shader_parameter("dmg_world_to_local", Transform3D.IDENTITY)
	_dmg_mat.set_shader_parameter("dmg_box_size", Vector3.ONE * BRICK)
	_dmg_mat.set_shader_parameter("dmg_tex_size", 256.0)
	_dmg_mat.set_shader_parameter("dmg_crater_depth", 0.3)


# A mostly-damaged field so deformed bricks actually exercise the carve path.
func _make_damage_tex() -> Texture2D:
	# A localized blob in each atlas third (≈ a real splat near a brick corner),
	# so the capture shows real crater/edge erosion instead of a striped field.
	var n := 256
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var ru := fmod(float(x) / float(n) * 3.0, 1.0)        # 0..1 within a third
			var p := Vector2(ru - 0.68, float(y) / float(n) - 0.68)  # toward a corner
			var v: float = clampf(1.0 - p.length() * 2.0, 0.0, 1.0)
			img.set_pixel(x, y, Color(v * v, v * v, v * v, 1.0))
	return ImageTexture.create_from_image(img)


func _layout_bricks() -> void:
	_cols = int(ceil(sqrt(float(total) * 16.0 / 9.0)))
	_rows = int(ceil(float(total) / float(_cols)))
	var undmg := MultiMesh.new()
	undmg.transform_format = MultiMesh.TRANSFORM_3D
	undmg.use_custom_data = true
	var dmg := MultiMesh.new()
	dmg.transform_format = MultiMesh.TRANSFORM_3D
	dmg.use_custom_data = true

	var positions: Array[Transform3D] = []
	var w := float(_cols) * BRICK
	var h := float(_rows) * BRICK
	for r in _rows:
		for c in _cols:
			if positions.size() >= total:
				break
			var p := Vector3(
				(float(c) + 0.5) * BRICK - w * 0.5,
				(float(r) + 0.5) * BRICK - h * 0.5,
				0.0)
			positions.append(Transform3D(Basis().scaled(Vector3.ONE * BRICK * INSET), p))

	# Interleave damaged bricks across the field (realistic scatter + overdraw).
	var n_dmg := int(round(float(positions.size()) * dmg_frac))
	var stride := maxi(1, int(round(1.0 / maxf(dmg_frac, 0.0001))))
	var undmg_x: Array[Transform3D] = []
	var dmg_x: Array[Transform3D] = []
	for i in positions.size():
		if dmg_x.size() < n_dmg and i % stride == 0:
			dmg_x.append(positions[i])
		else:
			undmg_x.append(positions[i])

	undmg.instance_count = undmg_x.size()
	for i in undmg_x.size():
		undmg.set_instance_transform(i, undmg_x[i])
		undmg.set_instance_custom_data(i, _brick_custom(i))
	dmg.instance_count = dmg_x.size()
	for i in dmg_x.size():
		dmg.set_instance_transform(i, dmg_x[i])
		dmg.set_instance_custom_data(i, _brick_custom(i + 7))

	_undmg_mmi = MultiMeshInstance3D.new()
	_undmg_mmi.multimesh = undmg
	_undmg_mmi.material_override = _base_mat
	_undmg_mmi.custom_aabb = AABB(Vector3(-w, -h, -BRICK), Vector3(w * 2, h * 2, BRICK * 2))
	add_child(_undmg_mmi)

	_dmg_mmi = MultiMeshInstance3D.new()
	_dmg_mmi.multimesh = dmg
	_dmg_mmi.material_override = _dmg_mat
	_dmg_mmi.custom_aabb = AABB(Vector3(-w, -h, -BRICK), Vector3(w * 2, h * 2, BRICK * 2))
	add_child(_dmg_mmi)

	# Frame the whole field.
	var dist := (w * 0.5) / tan(deg_to_rad(_cam.fov * 0.5)) * 1.05
	_cam.position = Vector3(0.0, 0.0, dist)
	_cam.look_at(Vector3.ZERO, Vector3.UP)

	print("[brickbench] field=%dx%d total=%d damaged=%d (%.0f%%) cam_dist=%.1f"
		% [_cols, _rows, total, dmg_x.size(), dmg_frac * 100.0, dist])


func _brick_custom(i: int) -> Color:
	var s := fposmod(float(i) * 0.61803, 1.0)
	return Color(s, 1.0, 0.85 + s * 0.3, 0.65)


func _start_subdiv() -> void:
	var sd: int = subdiv_sweep[_sweep_i]
	_dmg_mmi.multimesh.mesh = DestructibleSolid._build_hand_hewn_stone_mesh(sd)
	_phase = "warmup"
	_phase_frames = 0
	_accum = 0.0
	_frames = 0


func _verts_of(mesh: Mesh) -> int:
	if mesh == null or mesh.get_surface_count() == 0:
		return 0
	return (mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()


func _process(delta: float) -> void:
	if _phase == "done":
		return
	if _phase == "warmup":
		_phase_frames += 1
		if _phase_frames >= WARMUP_FRAMES:
			_phase = "measure"
			_accum = 0.0
			_frames = 0
		return
	# measure
	_accum += delta
	_frames += 1
	if _accum >= MEASURE_SEC:
		_record()
		_sweep_i += 1
		if _sweep_i >= subdiv_sweep.size():
			_report()
			_phase = "done"
			get_tree().quit()
		else:
			_start_subdiv()


func _record() -> void:
	var rid := get_viewport().get_viewport_rid()
	var draws := RenderingServer.viewport_get_render_info(
		rid, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE,
		RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME)
	var prims := RenderingServer.viewport_get_render_info(
		rid, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE,
		RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME)
	var fps := float(_frames) / _accum
	_results.append({
		"subdiv": subdiv_sweep[_sweep_i],
		"verts": _verts_of(_dmg_mmi.multimesh.mesh),
		"fps": fps,
		"ms": 1000.0 / maxf(fps, 0.01),
		"draws": draws,
		"prims": prims,
	})


func _report() -> void:
	print("\n========== DEFORMED-BRICK RENDER BENCH ==========")
	print("total bricks=%d  deformed=%.0f%%  base(undamaged) subdiv=%d  brick=%.1fm"
		% [total, dmg_frac * 100.0, BASE_SUBDIV, BRICK])
	print("deformed-brick verts is per-brick; %d bricks deformed\n"
		% int(round(float(total) * dmg_frac)))
	print("subdiv | verts/brick |   fps | frame_ms | draws | prims(M)")
	print("-------+-------------+-------+----------+-------+---------")
	for r: Dictionary in _results:
		print("%6d | %11d | %5.1f | %8.2f | %5d | %7.2f" % [
			r["subdiv"], r["verts"], r["fps"], r["ms"], r["draws"],
			float(r["prims"]) / 1.0e6])
	print("=================================================\n")
