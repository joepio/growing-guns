extends Node3D

# Windowed GPU A/B bench isolating the damage-system render cost.
# Headless can't measure GPU, so this must run in a visible window. It draws one
# full-screen field of stone bricks and re-renders it under several configs:
#   - base material (pre-damage intact path)
#   - whole-body damage material (pre-fix worst case — every brick runs the path)
#   - scoped decals (post-fix — only hit_frac of bricks on the damage material)
#   - dense subdiv-12 deform mesh (vertex cost of hit chunks)
#
#   godot --path . res://scenes/gpu_damage_bench.tscn
#   godot --path . res://scenes/gpu_damage_bench.tscn -- count=3000 hit_frac=0.05

const DestructibleSolid := preload("res://scripts/destructible_solid.gd")
const ArenaGenerator := preload("res://scripts/arena_generator.gd")

const BRICK := 2.0
const INSET := 0.96
const WARMUP_FRAMES := 30
const MEASURE_SEC := 3.0

var total := 2200
var hit_frac := 0.05

var _cam: Camera3D
var _base_mat: ShaderMaterial
var _dmg_mat: ShaderMaterial
var _mmi: MultiMeshInstance3D
var _mmi_hit: MultiMeshInstance3D
var _xforms: Array[Transform3D] = []
var _customs: Array[Color] = []
var _hit_indices: Array[int] = []
var _mesh_cache: Dictionary = {}  # subdiv -> Mesh

var _configs: Array = []
var _ci := 0
var _phase := "warmup"
var _phase_frames := 0
var _accum := 0.0
var _frames := 0
var _results: Array = []


func _ready() -> void:
	_parse_args()
	_build_world()
	_build_mats()
	_layout()
	_configs = [
		{"label": "base mat, subdiv-5   (intact)", "mode": "single", "mat": _base_mat, "subdiv": 5},
		{"label": "damage mat, subdiv-5  (whole-body)", "mode": "single", "mat": _dmg_mat, "subdiv": 5},
		{
			"label": "scoped decals, subdiv-5 (%.0f%% hit)" % (hit_frac * 100.0),
			"mode": "scoped",
			"mat": _base_mat,
			"hit_mat": _dmg_mat,
			"subdiv": 5,
		},
		{
			"label": "scoped deform, subdiv-12 (%.0f%% hit)" % (hit_frac * 100.0),
			"mode": "scoped",
			"mat": _base_mat,
			"hit_mat": _dmg_mat,
			"subdiv": 5,
			"hit_subdiv": 12,
		},
	]
	_start_config()


func _parse_args() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("count="):
			total = maxi(1, int(a.substr(6)))
		elif a.begins_with("hit_frac="):
			hit_frac = clampf(float(a.substr(9)), 0.01, 1.0)


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


func _build_mats() -> void:
	_base_mat = ArenaGenerator.make_rock_material(Color(0.55, 0.51, 0.46), 0.95, 7)
	_dmg_mat = _base_mat.duplicate() as ShaderMaterial
	_dmg_mat.set_shader_parameter("damage_enabled", 1.0)
	_dmg_mat.set_shader_parameter("damage_tex", _make_damage_tex())
	_dmg_mat.set_shader_parameter("dmg_world_to_local", Transform3D.IDENTITY)
	_dmg_mat.set_shader_parameter("dmg_box_size", Vector3.ONE * BRICK)
	_dmg_mat.set_shader_parameter("dmg_tex_size", 256.0)
	_dmg_mat.set_shader_parameter("dmg_crater_depth", 0.85)


# A damaged field (R decal + G deform) so the fragment damage path runs in full.
func _make_damage_tex() -> Texture2D:
	var n := 256
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var ru := fmod(float(x) / float(n) * 3.0, 1.0)
			var p := Vector2(ru - 0.5, float(y) / float(n) - 0.5)
			var v: float = clampf(1.0 - p.length() * 2.2, 0.0, 1.0)
			img.set_pixel(x, y, Color(v * v, v * 0.7, 0.0, 1.0))
	return ImageTexture.create_from_image(img)


func _mesh_for(subdiv: int) -> Mesh:
	if not _mesh_cache.has(subdiv):
		_mesh_cache[subdiv] = DestructibleSolid._build_hand_hewn_stone_mesh(subdiv)
	return _mesh_cache[subdiv]


func _build_hit_indices() -> void:
	_hit_indices.clear()
	var want := maxi(1, int(round(float(total) * hit_frac)))
	var step := maxi(1, int(round(float(total) / float(want))))
	var i := 0
	while i < total and _hit_indices.size() < want:
		_hit_indices.append(i)
		i += step


func _layout() -> void:
	var cols := int(ceil(sqrt(float(total) * 16.0 / 9.0)))
	var rows := int(ceil(float(total) / float(cols)))
	var w := float(cols) * BRICK
	var h := float(rows) * BRICK
	for r in rows:
		for c in cols:
			if _xforms.size() >= total:
				break
			var p := Vector3(
				(float(c) + 0.5) * BRICK - w * 0.5,
				(float(r) + 0.5) * BRICK - h * 0.5,
				0.0)
			_xforms.append(Transform3D(Basis().scaled(Vector3.ONE * BRICK * INSET), p))
			_customs.append(Color(fposmod(float(_xforms.size()) * 0.61803, 1.0), 1.0, 0.9, 0.65))
	_build_hit_indices()

	var aabb := AABB(Vector3(-w, -h, -BRICK), Vector3(w * 2.0, h * 2.0, BRICK * 2.0))
	_mmi = _make_mmi("Field", aabb)
	_mmi_hit = _make_mmi("HitChunks", aabb)
	add_child(_mmi)
	add_child(_mmi_hit)

	var dist := (w * 0.5) / tan(deg_to_rad(_cam.fov * 0.5)) * 1.05
	_cam.position = Vector3(0.0, 0.0, dist)
	_cam.look_at(Vector3.ZERO, Vector3.UP)
	print("[gpubench] field=%dx%d total=%d hit=%d (%.0f%%)" % [
		cols, rows, total, _hit_indices.size(), hit_frac * 100.0])


func _make_mmi(name: String, aabb: AABB) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = _mesh_for(5)
	mm.instance_count = 0
	var mmi := MultiMeshInstance3D.new()
	mmi.name = name
	mmi.multimesh = mm
	mmi.material_override = _base_mat
	mmi.custom_aabb = aabb
	return mmi


func _fill_single(mmi: MultiMeshInstance3D, mat: Material, subdiv: int) -> void:
	var mm := mmi.multimesh
	mm.mesh = _mesh_for(subdiv)
	mmi.material_override = mat
	mm.instance_count = _xforms.size()
	for i in _xforms.size():
		mm.set_instance_transform(i, _xforms[i])
		mm.set_instance_custom_data(i, _customs[i])


func _fill_scoped(pristine_mmi: MultiMeshInstance3D, hit_mmi: MultiMeshInstance3D, subdiv: int, hit_subdiv: int = -1) -> void:
	var hit_mesh_subdiv := subdiv if hit_subdiv < 0 else hit_subdiv
	var hit_set: Dictionary = {}
	for idx: int in _hit_indices:
		hit_set[idx] = true
	var pristine_mm := pristine_mmi.multimesh
	var hit_mm := hit_mmi.multimesh
	pristine_mm.mesh = _mesh_for(subdiv)
	hit_mm.mesh = _mesh_for(hit_mesh_subdiv)
	pristine_mmi.material_override = _base_mat
	hit_mmi.material_override = _dmg_mat
	var pi := 0
	for i in _xforms.size():
		if hit_set.has(i):
			continue
		pristine_mm.set_instance_transform(pi, _xforms[i])
		pristine_mm.set_instance_custom_data(pi, _customs[i])
		pi += 1
	pristine_mm.instance_count = pi
	hit_mm.instance_count = _hit_indices.size()
	for j in _hit_indices.size():
		var src: int = _hit_indices[j]
		hit_mm.set_instance_transform(j, _xforms[src])
		hit_mm.set_instance_custom_data(j, _customs[src])


func _start_config() -> void:
	var cfg: Dictionary = _configs[_ci]
	if str(cfg.get("mode", "single")) == "scoped":
		_mmi.visible = true
		_mmi_hit.visible = true
		_fill_scoped(_mmi, _mmi_hit, int(cfg["subdiv"]), int(cfg.get("hit_subdiv", -1)))
	else:
		_mmi.visible = true
		_mmi_hit.visible = false
		_fill_single(_mmi, cfg["mat"], int(cfg["subdiv"]))
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
	_accum += delta
	_frames += 1
	if _accum >= MEASURE_SEC:
		_record()
		_ci += 1
		if _ci >= _configs.size():
			_report()
			_phase = "done"
			get_tree().quit()
		else:
			_start_config()


func _record() -> void:
	var rid := get_viewport().get_viewport_rid()
	var draws := RenderingServer.viewport_get_render_info(
		rid, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE,
		RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME)
	var prims := RenderingServer.viewport_get_render_info(
		rid, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE,
		RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME)
	var fps := float(_frames) / _accum
	var cfg: Dictionary = _configs[_ci]
	var verts := _verts_of(_mmi.multimesh.mesh)
	if str(cfg.get("mode", "single")) == "scoped":
		verts = _verts_of(_mmi_hit.multimesh.mesh)
	_results.append({
		"label": cfg["label"],
		"verts": verts,
		"fps": fps,
		"ms": 1000.0 / maxf(fps, 0.01),
		"draws": draws,
		"prims": prims,
	})


func _report() -> void:
	print("\n========== GPU DAMAGE-MATERIAL A/B BENCH ==========")
	print("bricks=%d  hit_frac=%.0f%%  (subdiv-5 rows share geometry; delta = fragment cost)\n" % [
		total, hit_frac * 100.0])
	print("config                                     | verts/brick |   fps | frame_ms | prims(M)")
	print("-------------------------------------------+-------------+-------+----------+---------")
	for r: Dictionary in _results:
		print("%-42s | %11d | %5.1f | %8.2f | %7.2f" % [
			r["label"], r["verts"], r["fps"], r["ms"], float(r["prims"]) / 1.0e6])
	if _results.size() >= 2:
		var a: float = _results[0]["ms"]
		var b: float = _results[1]["ms"]
		print("\nwhole-body damage material fragment cost: %+.2f ms/frame (%.0f%% vs base)"
			% [b - a, (b / maxf(a, 0.01) - 1.0) * 100.0])
	if _results.size() >= 3:
		var scoped: float = _results[2]["ms"]
		var base: float = _results[0]["ms"]
		var whole: float = _results[1]["ms"]
		print("scoped decals (%.0f%% hit) vs base:       %+.2f ms/frame (%.0f%% vs base)"
			% [hit_frac * 100.0, scoped - base, (scoped / maxf(base, 0.01) - 1.0) * 100.0])
		print("scoped vs whole-body (regression saved):  %+.2f ms/frame (%.0f%% of whole-body cost)"
			% [scoped - whole, (scoped - base) / maxf(whole - base, 0.001) * 100.0])
	if _results.size() >= 4:
		var scoped_ms: float = _results[2]["ms"]
		var deform: float = _results[3]["ms"]
		print("scoped subdiv-12 deform (hit only) vs scoped: %+.2f ms/frame (%.0f%% vs scoped decals)"
			% [deform - scoped_ms, (deform / maxf(scoped_ms, 0.01) - 1.0) * 100.0])
	print("===================================================\n")
