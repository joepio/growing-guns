extends Node3D

# Reproduces the IN-GAME case the per-brick inspector can't: ONE body (a wall) made
# of many chunk instances, with damage mapped over the WHOLE body (dmg_box_size =
# wall size), exactly like a real DestructibleSolid. Splats a centre hit and an
# off-centre hit so we can see whether mid-wall chunks actually deform.
#
#   godot --path . res://scenes/deform_wall_test.tscn -- capture=/tmp/wall.png

const DestructibleSolid := preload("res://scripts/destructible_solid.gd")
const ArenaGenerator := preload("res://scripts/arena_generator.gd")

const CELL := 2.4
const COLS := 20
const ROWS := 6
const THICK := 1.0
const SUBDIV := 12
# Resolution computed like the real game (per-body viewport, capped at 1024).

var _cam: Camera3D
var _box: Vector3
var _splatter: Node2D
var _vp: SubViewport
var _res := 1024
var _base_mm: MultiMesh
var _deform_mm: MultiMesh
var _chunk_xform: Array[Transform3D] = []
var _chunk_custom: Array[Color] = []
var _migrated: Dictionary = {}  # chunk index -> deform slot


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
			var st: float = float(s["strength"])
			draw_texture_rect(brush, Rect2(c - Vector2(ru, rv), Vector2(ru * 2.0, rv * 2.0)),
				false, Color(st, st, st, 1.0))
		pending.clear()


func _ready() -> void:
	_box = Vector3(float(COLS) * CELL, float(ROWS) * CELL, THICK)
	_res = clampi(int(maxf(_box.x, _box.y) * 28.0), 384, 1280)  # same as the real game
	print("[walltest] wall %.0fx%.0fm  viewport=%dpx  (%.1f px/m on the long axis)"
		% [_box.x, _box.y, _res, float(_res) / 3.0 / _box.x])
	_build_world()
	_build_wall()
	# LEFT: a hit dead-centre on ONE brick's face. RIGHT: a hit on the boundary
	# where 4 bricks meet. (Brick centres are at multiples of CELL offset by 0.5.)
	var brick_centre := Vector3(-6.0, 1.2, THICK * 0.5)              # dead-centre of brick (7,3)
	var brick_corner := Vector3(7.2, 0.0, THICK * 0.5)              # boundary of 4 bricks
	_splat(brick_centre, Vector3(0, 0, 1), 18.0)
	_splat(brick_corner, Vector3(0, 0, 1), 18.0)
	print("[walltest] LEFT=brick-centre hit   RIGHT=4-brick-boundary hit")
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

	var dmat := (ArenaGenerator.make_rock_material(Color(0.55, 0.51, 0.46), 0.95, 7) as ShaderMaterial).duplicate() as ShaderMaterial
	dmat.set_shader_parameter("damage_enabled", 1.0)
	dmat.set_shader_parameter("damage_tex", _vp.get_texture())
	dmat.set_shader_parameter("dmg_world_to_local", Transform3D.IDENTITY)
	dmat.set_shader_parameter("dmg_box_size", _box)
	dmat.set_shader_parameter("dmg_tex_size", float(_res))
	dmat.set_shader_parameter("dmg_crater_depth", 0.85)
	var base_mat := ArenaGenerator.make_rock_material(Color(0.55, 0.51, 0.46), 0.95, 7)

	for r in ROWS:
		for c in COLS:
			var pos := Vector3(
				(float(c) + 0.5) * CELL - _box.x * 0.5,
				(float(r) + 0.5) * CELL - _box.y * 0.5,
				0.0)
			_chunk_xform.append(Transform3D(Basis.IDENTITY.scaled(Vector3(CELL, CELL, THICK) * 0.99), pos))
			_chunk_custom.append(Color(fposmod(float(_chunk_xform.size()) * 0.618, 1.0), 1.0, 1.0, 0.65))

	# Base batch (cheap mesh, no damage) — like the real game.
	var base_mmi := MultiMeshInstance3D.new()
	base_mmi.material_override = base_mat
	_base_mm = MultiMesh.new()
	_base_mm.transform_format = MultiMesh.TRANSFORM_3D
	_base_mm.use_custom_data = true
	_base_mm.mesh = DestructibleSolid._build_hand_hewn_stone_mesh(5)
	_base_mm.instance_count = _chunk_xform.size()
	for j in _chunk_xform.size():
		_base_mm.set_instance_transform(j, _chunk_xform[j])
		_base_mm.set_instance_custom_data(j, _chunk_custom[j])
	base_mmi.multimesh = _base_mm
	base_mmi.custom_aabb = AABB(-_box, _box * 2.0)
	add_child(base_mmi)

	# Deform batch (dense mesh, damage material) — empty until chunks migrate in.
	var def_mmi := MultiMeshInstance3D.new()
	def_mmi.material_override = dmat
	_deform_mm = MultiMesh.new()
	_deform_mm.transform_format = MultiMesh.TRANSFORM_3D
	_deform_mm.use_custom_data = true
	_deform_mm.mesh = DestructibleSolid._build_hand_hewn_stone_mesh(SUBDIV)
	_deform_mm.instance_count = 0
	def_mmi.multimesh = _deform_mm
	def_mmi.custom_aabb = AABB(-_box, _box * 2.0)
	add_child(def_mmi)


# Replicates _candidate_cols + _move_chunk_to_deform: migrate chunks whose cell is
# within `reach` of the hit (per-axis), exactly like the game.
func _migrate_near(local_pos: Vector3, reach: float) -> void:
	var half := Vector3(CELL, CELL, THICK) * 0.5
	for j in _chunk_xform.size():
		if _migrated.has(j):
			continue
		var center: Vector3 = _chunk_xform[j].origin
		if absf(center.x - local_pos.x) <= half.x + reach \
				and absf(center.y - local_pos.y) <= half.y + reach \
				and absf(center.z - local_pos.z) <= half.z + reach:
			var slot := _deform_mm.instance_count
			_deform_mm.instance_count = slot + 1
			# re-apply all (resize can wipe), like the game
			for k_idx in _migrated:
				_deform_mm.set_instance_transform(int(_migrated[k_idx]), _chunk_xform[k_idx])
				_deform_mm.set_instance_custom_data(int(_migrated[k_idx]), _chunk_custom[k_idx])
			_deform_mm.set_instance_transform(slot, _chunk_xform[j])
			_deform_mm.set_instance_custom_data(slot, _chunk_custom[j])
			_migrated[j] = slot
			_base_mm.set_instance_transform(j, Transform3D(Basis.IDENTITY.scaled(Vector3.ZERO), center))


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
	var crater := 0.7 * 1.4 + 0.25  # carve radius → larger crater (matches game)
	_splatter.pending.append({
		"uv": Vector2((float(col) + ruv.x) / 3.0, (float(row) + ruv.y) / 2.0),
		"ru": (crater / plane.x) / 3.0,
		"rv": (crater / plane.y) / 2.0,
		"strength": clampf(0.55 + dmg * 0.03, 0.5, 1.4),
	})
	_splatter.queue_redraw()
	_migrate_near(local_pos, crater * 0.5)
	print("[walltest] hit at %v → migrated %d chunks total" % [local_pos, _migrated.size()])


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
	_cam.position = Vector3(-6.0, 1.6, 9.0)   # close, near head-on to the brick-centre hit
	_cam.look_at(Vector3(-6.0, 1.2, 0.0), Vector3.UP)
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
