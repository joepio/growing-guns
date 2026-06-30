extends Node3D

# Reproduces the IN-GAME case: ONE body (a wall) of many chunk instances, damage
# mapped over the WHOLE body (dmg_box_size = wall size), like DestructibleSolid.
# Splats weak hits (decal) and strong hits (deform + chunk migrate).
#
#   godot --path . res://scenes/deform_wall_test.tscn -- capture=/tmp/wall.png

const DestructibleSolid := preload("res://scripts/destructible_solid.gd")
const ArenaGenerator := preload("res://scripts/arena_generator.gd")

const CELL := 2.4
const COLS := 20
const ROWS := 6
const THICK := 1.0

var _cam: Camera3D
var _box: Vector3
var _splatter: Node2D
var _vp: SubViewport
var _res := 1024
var _base_mm: MultiMesh
var _decal_mm: MultiMesh
var _deform_mm: MultiMesh
var _chunk_xform: Array[Transform3D] = []
var _chunk_custom: Array[Color] = []
var _decal_slots: Dictionary = {}
var _deform_slots: Dictionary = {}


class Splat2D:
	extends Node2D
	var pending: Array = []
	var brush: Texture2D
	var res: float = 512.0

	func _draw() -> void:
		for s: Dictionary in pending:
			var c: Vector2 = (s["uv"] as Vector2) * res
			var ru: float = float(s["ru"]) * res
			var rv: float = float(s["rv"]) * res
			draw_texture_rect(
				brush, Rect2(c - Vector2(ru, rv), Vector2(ru * 2.0, rv * 2.0)),
				false, Color(float(s["decal"]), float(s["deform"]), 0.0, 1.0))
		pending.clear()


func _ready() -> void:
	_box = Vector3(float(COLS) * CELL, float(ROWS) * CELL, THICK)
	_res = clampi(int(maxf(_box.x, _box.y) * 28.0), 384, 1280)
	print("[walltest] wall %.0fx%.0fm  subdiv=%d  viewport=%dpx"
		% [_box.x, _box.y, DestructibleSolid.CHUNK_MESH_SUBDIVIDE, _res])
	_build_world()
	_build_wall()
	for _k in 5:
		_splat(Vector3(-1.2, 6.0, THICK * 0.5), Vector3(0, 0, 1), 16.0)
	for _k in 4:
		_splat(Vector3(3.6, -6.0, THICK * 0.5), Vector3(0, 0, 1), 20.0)
	print("[walltest] TOP=weak 5x (decal)  BOTTOM=strong 4x (deform)")
	_run_capture()


func _build_world() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.07, 0.08, 0.11)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.46, 0.48, 0.53)
	env.ambient_light_energy = 0.55
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-36.0, -26.0, 0.0)
	sun.light_energy = 1.2
	add_child(sun)
	_cam = Camera3D.new()
	_cam.fov = 52.0
	add_child(_cam)


func _make_damage_mats() -> Array[ShaderMaterial]:
	var rock := ArenaGenerator.make_rock_material(Color(0.55, 0.51, 0.46), 0.95, 7) as ShaderMaterial
	var base_mat := rock
	var decal_mat := rock.duplicate() as ShaderMaterial
	decal_mat.set_shader_parameter("damage_enabled", 1.0)
	decal_mat.set_shader_parameter("dmg_vertex_deform", 0.0)
	decal_mat.set_shader_parameter("damage_tex", _vp.get_texture())
	decal_mat.set_shader_parameter("dmg_world_to_local", Transform3D.IDENTITY)
	decal_mat.set_shader_parameter("dmg_box_size", _box)
	decal_mat.set_shader_parameter("dmg_tex_size", float(_res))
	decal_mat.set_shader_parameter("dmg_crater_depth", 0.72)
	var deform_mat := decal_mat.duplicate() as ShaderMaterial
	deform_mat.set_shader_parameter("dmg_vertex_deform", 1.0)
	return [base_mat, decal_mat, deform_mat]


func _build_wall() -> void:
	_vp = SubViewport.new()
	_vp.size = Vector2i(_res, _res)
	_vp.transparent_bg = false
	_vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE
	_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(_vp)
	_splatter = Splat2D.new()
	_splatter.brush = _brush()
	_splatter.res = float(_res)
	var cm := CanvasItemMaterial.new()
	cm.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	_splatter.material = cm
	_vp.add_child(_splatter)

	var mats := _make_damage_mats()
	var base_mat: ShaderMaterial = mats[0]
	var decal_mat: ShaderMaterial = mats[1]
	var deform_mat: ShaderMaterial = mats[2]
	var brick_mesh := DestructibleSolid.get_deform_chunk_mesh()

	for r in ROWS:
		for c in COLS:
			var pos := Vector3(
				(float(c) + 0.5) * CELL - _box.x * 0.5,
				(float(r) + 0.5) * CELL - _box.y * 0.5,
				0.0)
			_chunk_xform.append(Transform3D(Basis.IDENTITY.scaled(Vector3(CELL, CELL, THICK) * 0.99), pos))
			_chunk_custom.append(Color(fposmod(float(_chunk_xform.size()) * 0.618, 1.0), 1.0, 1.0, 0.65))

	var aabb := AABB(-_box, _box * 2.0)

	var base_mmi := MultiMeshInstance3D.new()
	base_mmi.material_override = base_mat
	_base_mm = MultiMesh.new()
	_base_mm.transform_format = MultiMesh.TRANSFORM_3D
	_base_mm.use_custom_data = true
	_base_mm.mesh = brick_mesh
	_base_mm.instance_count = _chunk_xform.size()
	for j in _chunk_xform.size():
		_base_mm.set_instance_transform(j, _chunk_xform[j])
		_base_mm.set_instance_custom_data(j, _chunk_custom[j])
	base_mmi.multimesh = _base_mm
	base_mmi.custom_aabb = aabb
	add_child(base_mmi)

	var decal_mmi := MultiMeshInstance3D.new()
	decal_mmi.material_override = decal_mat
	_decal_mm = MultiMesh.new()
	_decal_mm.transform_format = MultiMesh.TRANSFORM_3D
	_decal_mm.use_custom_data = true
	_decal_mm.mesh = brick_mesh
	_decal_mm.instance_count = 0
	decal_mmi.multimesh = _decal_mm
	decal_mmi.custom_aabb = aabb
	add_child(decal_mmi)

	var def_mmi := MultiMeshInstance3D.new()
	def_mmi.material_override = deform_mat
	_deform_mm = MultiMesh.new()
	_deform_mm.transform_format = MultiMesh.TRANSFORM_3D
	_deform_mm.use_custom_data = true
	_deform_mm.mesh = brick_mesh
	_deform_mm.instance_count = 0
	def_mmi.multimesh = _deform_mm
	def_mmi.custom_aabb = aabb
	add_child(def_mmi)


func _migrate_decal(local_pos: Vector3, reach: float) -> void:
	var half := Vector3(CELL, CELL, THICK) * 0.5
	for j in _chunk_xform.size():
		if _decal_slots.has(j) or _deform_slots.has(j):
			continue
		var center: Vector3 = _chunk_xform[j].origin
		if absf(center.x - local_pos.x) > half.x + reach:
			continue
		if absf(center.y - local_pos.y) > half.y + reach:
			continue
		if absf(center.z - local_pos.z) > half.z + reach:
			continue
		var slot := _decal_mm.instance_count
		_decal_mm.instance_count = slot + 1
		_decal_slots[j] = slot
		_refresh_decal()
		_base_mm.set_instance_transform(j, Transform3D(Basis.IDENTITY.scaled(Vector3.ZERO), center))


func _migrate_deform(local_pos: Vector3, reach: float) -> void:
	var half := Vector3(CELL, CELL, THICK) * 0.5
	for j in _chunk_xform.size():
		if _deform_slots.has(j):
			continue
		if _decal_slots.has(j):
			var center: Vector3 = _chunk_xform[j].origin
			_decal_slots.erase(j)
			_refresh_decal()
			_base_mm.set_instance_transform(j, Transform3D(Basis.IDENTITY.scaled(Vector3.ZERO), center))
		var center: Vector3 = _chunk_xform[j].origin
		if absf(center.x - local_pos.x) > half.x + reach:
			continue
		if absf(center.y - local_pos.y) > half.y + reach:
			continue
		if absf(center.z - local_pos.z) > half.z + reach:
			continue
		var slot := _deform_mm.instance_count
		_deform_mm.instance_count = slot + 1
		_deform_slots[j] = slot
		_refresh_deform()
		_base_mm.set_instance_transform(j, Transform3D(Basis.IDENTITY.scaled(Vector3.ZERO), center))


func _refresh_decal() -> void:
	for j: int in _decal_slots:
		var slot: int = int(_decal_slots[j])
		_decal_mm.set_instance_transform(slot, _chunk_xform[j])
		_decal_mm.set_instance_custom_data(slot, _chunk_custom[j])


func _refresh_deform() -> void:
	for j: int in _deform_slots:
		var slot: int = int(_deform_slots[j])
		_deform_mm.set_instance_transform(slot, _chunk_xform[j])
		_deform_mm.set_instance_custom_data(slot, _chunk_custom[j])


func _splat(local_pos: Vector3, n: Vector3, dmg: float) -> void:
	var region := _region(n)
	var t := local_pos / _box + Vector3(0.5, 0.5, 0.5)
	var ruv := Vector2(t.x, t.y)
	var plane := Vector2(_box.x, _box.y)
	if region < 2:
		ruv = Vector2(t.z, t.y)
		plane = Vector2(_box.z, _box.y)
	elif region < 4:
		ruv = Vector2(t.x, t.z)
		plane = Vector2(_box.x, _box.z)
	var col := region % 3
	var row := region / 3
	var crater := 0.7 * 1.4 + 0.25
	var strong := dmg >= 17.0
	var dec_r := 0.18
	var uv := Vector2((float(col) + ruv.x) / 3.0, (float(row) + ruv.y) / 2.0)
	_splatter.pending.append({
		"uv": uv, "ru": (dec_r / plane.x) / 3.0, "rv": (dec_r / plane.y) / 2.0,
		"decal": clampf(0.12 + dmg * 0.004, 0.12, 0.32), "deform": 0.0})
	if strong:
		_splatter.pending.append({
			"uv": uv, "ru": (crater / plane.x) / 3.0, "rv": (crater / plane.y) / 2.0,
			"decal": 0.0, "deform": clampf(dmg * 0.013, 0.08, 0.9)})
	_splatter.queue_redraw()
	_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	var reach := dec_r + CELL * 0.12
	_migrate_decal(local_pos, reach)
	if strong:
		_migrate_deform(local_pos, crater * 0.5)


func _region(n: Vector3) -> int:
	var a := n.abs()
	if a.x >= a.y and a.x >= a.z:
		return 0 if n.x > 0.0 else 1
	if a.y >= a.x and a.y >= a.z:
		return 2 if n.y > 0.0 else 3
	return 4 if n.z > 0.0 else 5


func _brush() -> Texture2D:
	var n := 128
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var p := Vector2(float(x) / float(n - 1) - 0.5, float(y) / float(n - 1) - 0.5)
			var d := p.length() * 2.0
			var core := clampf(1.0 - d * 0.72, 0.0, 1.0)
			core = core * core
			var halo := clampf(1.0 - d, 0.0, 1.0)
			halo = halo * halo * 0.22
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, maxf(core, halo)))
	return ImageTexture.create_from_image(img)


func _cli_capture() -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("capture="):
			return a.substr(8)
	return ""


func _run_capture() -> void:
	var size := Vector2i(1400, 760)
	DisplayServer.window_set_size(size)
	get_viewport().size = size
	_cam.position = Vector3(0.0, 0.0, 32.0)
	_cam.look_at(Vector3.ZERO, Vector3.UP)
	for _i in 30:
		await get_tree().process_frame
	RenderingServer.force_draw(true)
	await RenderingServer.frame_post_draw
	var path := _cli_capture()
	if path == "":
		path = "user://wall.png"
	get_viewport().get_texture().get_image().save_png(path)
	print("[walltest] captured: ", path)
	get_tree().quit()
