extends StaticBody3D

const DestructibleManager = preload("res://scripts/destructible_manager.gd")
const Violence = preload("res://scripts/violence.gd")

# One destructible path for terrain and props: pre-split into deterministic,
# uneven box chunks. Blasts only remove existing mesh/collider pairs, so there
# is no runtime mesh rebuild cost when dozens of explosions land in a second.

const MIN_REMOVE_DAMAGE := 12.0
const MIN_ACCUMULATE_DAMAGE := 8.0
# A hit must deal at least this much damage to affect a block AT ALL — below it the
# gun neither deforms nor damages it (weak guns just ping off). Above it, a hit both
# deforms and chips HP, so "can't dent it" always means "can't destroy it".
# The base default gun deals 16 to a block (impact_dmg_ratio 1.0 → 9 + 1.0*7), so 17
# leaves it just shy of denting anything — you need a stronger gun or an explosion.
const MIN_DESTRUCTION_DAMAGE := 17.0
const CHUNK_BASE_HEALTH := 42.0
const CHUNK_VOLUME_HEALTH := 4.0
const TARGET_CELL := 2.4
const MAX_CHUNKS_PER_AXIS := 6
const EDGE_JITTER := 0.38
const MAX_JAGGEDIZE_PER_CARVE := 18
const MAX_EXPOSURE_JOBS_PER_FRAME := 1

const CHUNK_MESH_SUBDIVIDE := 4
# One hand-hewn unit brick for intact, decal, and deform batches (~216 verts at subdiv 4).
# Deform is shader-driven; subdiv 3 was too coarse for edge/corner carves on multi-chunk walls.
# Visual inset — hairline shadow between bricks; keep tight so walls read solid.
const VISUAL_CHUNK_INSET := 0.992

var box_size: Vector3 = Vector3.ONE
var _pending_carves: Array[Dictionary] = []
var _pending_exposure_carves: Array[Dictionary] = []
var _body_seed: int = 0
var _mat: Material = null
# GPU damage: lazily-allocated per-body damage accumulation buffer (VRAM, never
# read back). Created on first hit; the body swaps to a unique damage material.
var _dmg_viewport: SubViewport = null
var _dmg_splatter: Node2D = null
var _decal_mat: ShaderMaterial = null  # fragment-only damage (bullet holes)
var _dmg_mat: ShaderMaterial = null  # full vertex+fragment deform carve
var _dmg_axis: int = 2
var _dmg_plane_size: Vector2 = Vector2.ONE
var _dmg_tex_res: int = 512
static var _dmg_brush_tex: Texture2D = null
var _chunk_cols: Array[CollisionShape3D] = []
var _chunk_grid: Array[CollisionShape3D] = []
var _intact_mmi: MultiMeshInstance3D = null
var _intact_mm: MultiMesh = null
# Damaged-but-alive chunks migrate here: same unit brick + full deform material.
var _deform_mmi: MultiMeshInstance3D = null
var _deform_mm: MultiMesh = null
var _deform_slots: Dictionary = {}  # chunk instance_id -> deform MM index
var _deform_free: Array[int] = []
# Decal-only chunks: same unit brick + damage material (R-channel bullet holes).
var _decal_mmi: MultiMeshInstance3D = null
var _decal_mm: MultiMesh = null
var _decal_slots: Dictionary = {}  # chunk instance_id -> decal MM index
var _decal_free: Array[int] = []
var _grid := Vector3i.ONE
var _x_edges := PackedFloat32Array()
var _y_edges := PackedFloat32Array()
var _z_edges := PackedFloat32Array()


func setup_box(
	pos: Vector3,
	size: Vector3,
	mat: Material,
	rotation_y: float = 0.0,
	_with_collider: bool = true,
) -> void:
	box_size = size
	position = pos
	if rotation_y != 0.0:
		rotation.y = rotation_y
	collision_layer = 1
	add_to_group("destructible")
	set_process(false)
	_body_seed = hash([pos, size, rotation_y])
	_mat = mat
	_build_chunks()
	if is_inside_tree():
		_register_with_manager()


func setup_cylinder(
	pos: Vector3,
	radius: float,
	height: float,
	mat: Material,
	bottom_radius_scale: float = 0.8,
) -> void:
	setup_box(pos, Vector3(radius * 2.0, height, radius * 2.0), mat)


func intersects_sphere(world_pos: Vector3, radius_sq: float) -> bool:
	var local: Vector3 = to_local(world_pos)
	var half: Vector3 = box_size * 0.5
	var closest := Vector3(
		clampf(local.x, -half.x, half.x),
		clampf(local.y, -half.y, half.y),
		clampf(local.z, -half.z, half.z),
	)
	return closest.distance_squared_to(local) <= radius_sq


func queue_blast_damage(
	world_pos: Vector3,
	radius: float,
	damage: float,
	hit_normal: Vector3 = Vector3.ZERO,
) -> void:
	if radius <= 0.0 or damage <= 0.0:
		return
	var local_pos := to_local(world_pos)
	var local_normal := Vector3.ZERO
	if hit_normal.length_squared() > 0.0001:
		local_normal = (global_basis.inverse() * hit_normal).normalized()
	# Every hit leaves a decal + chips (handled in _splat_damage). But only hits at or
	# above the threshold queue a CARVE that costs HP / deforms — weaker guns mark the
	# rock without whittling it down (and can't destroy what they can't dent).
	_splat_damage(local_pos, radius, damage, local_normal)
	if damage < MIN_DESTRUCTION_DAMAGE:
		return
	if not _pending_carves.is_empty():
		var last: Dictionary = _pending_carves[-1]
		var last_pos: Vector3 = last["pos"] as Vector3
		if last_pos.distance_squared_to(local_pos) <= 0.36:
			last["damage"] = float(last["damage"]) + damage
			last["radius"] = maxf(float(last["radius"]), radius)
			DestructibleManager.mark_dirty(self)
			return
	_pending_carves.append({
		"pos": local_pos,
		"radius": radius,
		"damage": damage,
		"normal": local_normal,
		"max_depth": -1.0,
	})
	DestructibleManager.mark_dirty(self)


func queue_carve_world(
	world_pos: Vector3,
	radius: float,
	hit_normal: Vector3 = Vector3.ZERO,
	max_depth: float = -1.0,
) -> void:
	if radius <= 0.0:
		return
	var local_pos := to_local(world_pos)
	var local_normal := Vector3.ZERO
	if hit_normal.length_squared() > 0.0001:
		local_normal = (global_basis.inverse() * hit_normal).normalized()
	_splat_damage(local_pos, radius, 800.0, local_normal)
	_pending_carves.append({
		"pos": local_pos,
		"radius": radius,
		"damage": 800.0,
		"normal": local_normal,
		"max_depth": max_depth,
	})
	DestructibleManager.mark_dirty(self)


# 2D canvas drawn into the damage SubViewport; stamps queued splats additively.
class _DmgSplatter:
	extends Node2D
	var pending: Array = []
	var brush: Texture2D
	var res: float = 512.0

	func _draw() -> void:
		for s: Dictionary in pending:
			var c: Vector2 = (s["uv"] as Vector2) * res
			var ru: float = float(s["ru"]) * res
			var rv: float = float(s["rv"]) * res
			# R = decal strength (every hit), G = deform strength (strong hits only).
			draw_texture_rect(
				brush, Rect2(c - Vector2(ru, rv), Vector2(ru * 2.0, rv * 2.0)),
				false, Color(float(s["decal"]), float(s["deform"]), 0.0, 1.0))
		pending.clear()


static func _get_dmg_brush() -> Texture2D:
	if _dmg_brush_tex == null:
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
		_dmg_brush_tex = ImageTexture.create_from_image(img)
	return _dmg_brush_tex


# Lazily build the per-body damage buffer and swap to a unique damage material.
func _ensure_damage_buffer() -> void:
	if _dmg_viewport != null or _mat == null:
		return
	var s := box_size
	_dmg_axis = 0
	if s.y <= s.x and s.y <= s.z:
		_dmg_axis = 1
	elif s.z <= s.x and s.z <= s.y:
		_dmg_axis = 2
	if _dmg_axis == 0:
		_dmg_plane_size = Vector2(s.z, s.y)
	elif _dmg_axis == 1:
		_dmg_plane_size = Vector2(s.x, s.z)
	else:
		_dmg_plane_size = Vector2(s.x, s.y)
	# Higher res on large faces so 0.2–0.4 m bullet holes stay a few texels wide.
	var res := clampi(int(maxf(_dmg_plane_size.x, _dmg_plane_size.y) * 36.0), 512, 1536)
	_dmg_tex_res = res

	_dmg_viewport = SubViewport.new()
	_dmg_viewport.size = Vector2i(res, res)
	_dmg_viewport.transparent_bg = false
	_dmg_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE
	_dmg_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(_dmg_viewport)
	var splatter := _DmgSplatter.new()
	splatter.brush = _get_dmg_brush()
	splatter.res = float(res)
	var cmat := CanvasItemMaterial.new()
	cmat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	splatter.material = cmat
	_dmg_viewport.add_child(splatter)
	_dmg_splatter = splatter

	var dmg_tex := _dmg_viewport.get_texture()
	var world_to_local := global_transform.affine_inverse()
	_decal_mat = (_mat as ShaderMaterial).duplicate() as ShaderMaterial
	_decal_mat.set_shader_parameter("damage_enabled", 1.0)
	_decal_mat.set_shader_parameter("dmg_vertex_deform", 0.0)
	_decal_mat.set_shader_parameter("damage_tex", dmg_tex)
	_decal_mat.set_shader_parameter("dmg_world_to_local", world_to_local)
	_decal_mat.set_shader_parameter("dmg_box_size", box_size)
	_decal_mat.set_shader_parameter("dmg_tex_size", float(res))
	_decal_mat.set_shader_parameter("dmg_crater_depth", 0.72)

	_dmg_mat = _decal_mat.duplicate() as ShaderMaterial
	_dmg_mat.set_shader_parameter("dmg_vertex_deform", 1.0)
	# Intact chunks keep the base material; only splat-covered chunks migrate into
	# the decal or deform batches (see _move_chunk_to_decal / _move_chunk_to_deform).


# Signed atlas region for a hit: 0=+X 1=-X 2=+Y 3=-Y 4=+Z 5=-Z (matches the shader).
# Blasts arrive without a normal — splat onto a broad face (the body's thin axis, +).
func _dmg_region_for_normal(n: Vector3) -> int:
	if n.length_squared() < 0.01:
		return _dmg_axis * 2
	var a := n.abs()
	if a.x >= a.y and a.x >= a.z:
		return 0 if n.x > 0.0 else 1
	if a.y >= a.x and a.y >= a.z:
		return 2 if n.y > 0.0 else 3
	return 4 if n.z > 0.0 else 5


func _dmg_region_plane(region: int) -> Vector2:
	if region < 2:
		return Vector2(box_size.z, box_size.y)
	if region < 4:
		return Vector2(box_size.x, box_size.z)
	return Vector2(box_size.x, box_size.y)


func _dmg_region_ruv(l: Vector3, region: int) -> Vector2:
	var t := Vector3(l.x / box_size.x, l.y / box_size.y, l.z / box_size.z) + Vector3(0.5, 0.5, 0.5)
	if region < 2:
		return Vector2(t.z, t.y)
	if region < 4:
		return Vector2(t.x, t.z)
	return Vector2(t.x, t.y)


func _refresh_damage_transform() -> void:
	if _decal_mat == null:
		return
	var world_to_local := global_transform.affine_inverse()
	_decal_mat.set_shader_parameter("dmg_world_to_local", world_to_local)
	if _dmg_mat != null:
		_dmg_mat.set_shader_parameter("dmg_world_to_local", world_to_local)


# Half-extents of a damage brush in atlas UV (3-wide x 2-tall face grid).
# Large walls need a wider world-space decal or the R splat lands on ~1 texel.
func _damage_brush_half_uv(world_half: float, plane: Vector2) -> Vector2:
	var ru := (world_half / maxf(plane.x, 0.01)) / 3.0
	var rv := (world_half / maxf(plane.y, 0.01)) / 2.0
	var tex_res := float(_dmg_tex_res)
	var min_ru := 10.0 / tex_res
	var min_rv := 10.0 / tex_res
	var max_ru := (0.48 / maxf(plane.x, 0.01)) / 3.0
	var max_rv := (0.48 / maxf(plane.y, 0.01)) / 2.0
	return Vector2(
		clampf(maxf(ru, min_ru), min_ru, maxf(min_ru, max_ru)),
		clampf(maxf(rv, min_rv), min_rv, maxf(min_rv, max_rv)),
	)


func _decal_world_radius(plane: Vector2) -> float:
	var span := maxf(plane.x, plane.y)
	return clampf(maxf(0.22, span * 0.011), 0.22, 0.48)


# Queue a damage splat at a body-local hit point (sparse CPU event; the GPU buffer
# accumulates, never read back). Written into the hit face's signed atlas region
# (3x2 grid), kept round in world space. Chunks under the splat migrate into the
# decal batch (weak hits) or the dense deform batch (strong hits).
func _splat_damage(local_pos: Vector3, world_radius: float, damage: float, local_normal: Vector3) -> void:
	_ensure_damage_buffer()
	if _dmg_splatter == null:
		return
	var region := _dmg_region_for_normal(local_normal)
	var ruv := _dmg_region_ruv(local_pos, region)
	var plane := _dmg_region_plane(region)
	# Atlas: 3x2 grid, U compressed by 3, V by 2.
	var col := region % 3
	var row := region / 3
	var atlas_uv := Vector2((float(col) + ruv.x) / 3.0, (float(row) + ruv.y) / 2.0)
	var strong := damage >= MIN_DESTRUCTION_DAMAGE
	var crater := world_radius * 1.4 + 0.25
	# DECAL (R): bullet hole + radial cracks. Must cover enough texels on wide walls
	# (arena faces are tens of metres — a fixed 0.18 m stamp was sub-pixel).
	var dec_r := _decal_world_radius(plane)
	var dec_uv := _damage_brush_half_uv(dec_r, plane)
	var decal := clampf(0.18 + damage * 0.0045, 0.18, 0.42)
	_dmg_splatter.pending.append({
		"uv": atlas_uv, "decal": decal, "deform": 0.0,
		"ru": dec_uv.x, "rv": dec_uv.y,
	})
	# DEFORM (G): only strong hits, with the larger crater radius so the geometry
	# carve reads clearly. Accumulates so a strong gun wears the chunk down gradually.
	if strong:
		var deform := clampf(damage * 0.013, 0.08, 0.72)
		var def_uv := _damage_brush_half_uv(crater, plane)
		_dmg_splatter.pending.append({
			"uv": atlas_uv, "decal": 0.0, "deform": deform,
			"ru": def_uv.x, "rv": def_uv.y,
		})
	_refresh_damage_transform()
	_dmg_splatter.queue_redraw()
	_dmg_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	if strong:
		for c: CollisionShape3D in _candidate_cols(local_pos, crater * 0.5, 0.0):
			if is_instance_valid(c) and not bool(c.get_meta("destroyed", false)):
				_move_chunk_to_deform(c)
	else:
		for c: CollisionShape3D in _candidate_cols(local_pos, dec_r + TARGET_CELL * 0.12):
			if is_instance_valid(c) and not bool(c.get_meta("destroyed", false)):
				_move_chunk_to_decal(c)
	# A few chips fly off at EVERY hit (not just removal), scaled by damage — a weak
	# shot flicks a couple of flecks, a heavy round throws a real spray. GPU
	# debris merges/caps per-tick chip jobs so sustained fire can't spam it.
	var scene := _fx_scene()
	if scene != null:
		var wp := to_global(local_pos)
		var chip_count := clampf(0.06 + damage * 0.008, 0.06, 1.0)
		var chip_size := TARGET_CELL * clampf(0.05 + damage * 0.0022, 0.05, 0.35)
		GpuDebris.request_chips(
			scene, wp, world_radius, _material_base_color(), chip_size, chip_count)


func apply_pending_carves() -> bool:
	if _pending_carves.is_empty():
		return false
	var t0 := Time.get_ticks_usec() if BenchFlags.active else 0
	# Merge every carve queued this tick: accumulate damage per chunk first, then
	# do ONE threshold/removal sweep + ONE debris burst. The old per-carve path
	# dropped every sub-MIN_ACCUMULATE_DAMAGE hit (so a stream of small blasts
	# never removed anything) and paid the full removal + debris + physics-churn
	# cost per blast instead of once per tick.
	var accum: Dictionary = {}                  # CollisionShape3D -> damage
	var touched: Array[CollisionShape3D] = []
	var max_radius := 0.0
	var blast_center_local := Vector3.ZERO  # the dominant carve's centre = the boom origin
	for carve: Dictionary in _pending_carves:
		var local_center: Vector3 = carve["pos"] as Vector3
		var radius: float = float(carve["radius"])
		if radius > max_radius:
			blast_center_local = local_center
		max_radius = maxf(max_radius, radius)
		var damage: float = float(carve.get("damage", 800.0))
		var inward: Vector3 = carve["normal"] as Vector3
		var max_depth: float = float(carve.get("max_depth", -1.0))
		var directed: bool = inward.length_squared() > 0.0001 and max_depth > 0.0
		if directed:
			inward = inward.normalized()
		for col: CollisionShape3D in _candidate_cols(local_center, radius):
			if not is_instance_valid(col) or bool(col.get_meta("destroyed", false)):
				continue
			var center: Vector3 = col.get_meta("chunk_center_local") as Vector3
			var half_diag: float = float(col.get_meta("chunk_half_diag"))
			if directed:
				var depth: float = (center - local_center).dot(inward)
				if depth < -half_diag or depth > max_depth + half_diag:
					continue
			var dist: float = center.distance_to(local_center)
			if dist > radius + half_diag:
				continue
			var d: float = DestructibleManager.blast_damage_at(maxf(0.0, dist - half_diag), radius, damage)
			if accum.has(col):
				accum[col] = float(accum[col]) + d
			else:
				accum[col] = d
				touched.append(col)
	_pending_carves.clear()

	# Single threshold + HP sweep over every chunk touched this tick.
	var to_remove_cols: Array[CollisionShape3D] = []
	var damaged: Array[Dictionary] = []  # survivors: {col, dmg_t}
	for col: CollisionShape3D in touched:
		var amount: float = float(accum[col])
		if amount <= 0.0:
			continue
		# Persist even small hits into chunk_hp (don't drop sub-threshold damage), so
		# sustained weak fire eventually breaks a tough chunk instead of being ignored.
		var chunk_size: Vector3 = col.get_meta("chunk_size") as Vector3
		var maxhp: float = _chunk_max_health(chunk_size)
		var old_hp: float = float(col.get_meta("chunk_hp", maxhp))
		var new_hp: float = old_hp - amount
		col.set_meta("chunk_hp", new_hp)
		if new_hp <= 0.0 or amount >= new_hp + MIN_REMOVE_DAMAGE:
			to_remove_cols.append(col)
		else:
			var dmg_t: float = clampf(1.0 - new_hp / maxhp, 0.0, 1.0)
			if dmg_t > 0.08:
				damaged.append({"col": col, "dmg_t": dmg_t})
	# Damaged-but-surviving chunks migrate into the dense deform batch so the GPU
	# carves real geometry on just the chunks that were hit.
	for d: Dictionary in damaged:
		_move_chunk_to_deform(d["col"] as CollisionShape3D)
	if to_remove_cols.is_empty():
		return not damaged.is_empty()

	# Disable + hide every removed chunk, then ONE debris burst + ONE jag job.
	var burst_center := Vector3.ZERO
	var exposure_center := Vector3.ZERO
	var scene := _fx_scene()
	var max_blood_cleanup_r := 0.0
	for col: CollisionShape3D in to_remove_cols:
		_hide_intact_instance(col)
		_remove_chunk_from_decal(col)
		_remove_chunk_from_deform(col)
		burst_center += col.global_position
		exposure_center += col.get_meta("chunk_center_local") as Vector3
		max_blood_cleanup_r = maxf(
			max_blood_cleanup_r,
			float(col.get_meta("chunk_half_diag", 1.0)) + 0.35,
		)
		col.set_meta("destroyed", true)
		col.disabled = true
	var n := float(to_remove_cols.size())
	if scene and max_blood_cleanup_r > 0.0:
		Violence.clear_blood_splats_near(scene, burst_center / n, max_blood_cleanup_r)
	DestructibleManager.note_chunk_removals(to_remove_cols.size())
	if is_in_group("lava_floor") and has_meta("_lava_openness_tracker"):
		var tracker: Variant = get_meta("_lava_openness_tracker")
		if tracker != null and is_instance_valid(tracker) and tracker.has_method("notify_chunks_removed"):
			tracker.call("notify_chunks_removed", self, to_remove_cols)
	var base_color := _material_base_color()
	# Debris radiates from the BLAST origin, not each block's own centre, so a big
	# boom throws everything outward instead of each block puffing on the spot.
	GpuDebris.request_burst(
		scene, to_global(blast_center_local), max_radius,
		to_remove_cols.size(), base_color)
	exposure_center /= n
	var exposure_radius := 0.0
	for col: CollisionShape3D in to_remove_cols:
		exposure_radius = maxf(exposure_radius,
			(col.get_meta("chunk_center_local") as Vector3).distance_to(exposure_center))
	_pending_exposure_carves.append({"pos": exposure_center, "radius": exposure_radius + TARGET_CELL})
	set_process(true)

	if _count_chunks() <= 0:
		remove_from_group("destructible")
		collision_layer = 0
		DestructibleManager.unregister_destructible(self)
	if BenchFlags.active and t0 > 0:
		DestructibleManager.bench_destruct_prof("chunk_remove", Time.get_ticks_usec() - t0)
	return true


# GPU debris: append (world center, half-extent) pairs for every chunk still
# standing, for rasterizing into a blast's occupancy snapshot. Conservative
# for Y-rotated bodies (axis-aligned box around the rotated chunk).
func alive_chunk_world_boxes(out: Array[Vector3]) -> void:
	var gt := global_transform
	var b := gt.basis
	for col: CollisionShape3D in _chunk_cols:
		if col == null or not is_instance_valid(col) or col.disabled:
			continue
		if bool(col.get_meta("destroyed", false)):
			continue
		var c: Vector3 = col.get_meta("chunk_center_local") as Vector3
		var h: Vector3 = (col.get_meta("chunk_size") as Vector3) * 0.5
		out.append(gt * c)
		out.append(Vector3(
			absf(b.x.x) * h.x + absf(b.y.x) * h.y + absf(b.z.x) * h.z,
			absf(b.x.y) * h.x + absf(b.y.y) * h.y + absf(b.z.y) * h.z,
			absf(b.x.z) * h.x + absf(b.y.z) * h.y + absf(b.z.z) * h.z,
		))


func debug_chunk_count() -> int:
	return _count_chunks()


func debug_pending_count() -> int:
	return _pending_carves.size()


func _exit_tree() -> void:
	DestructibleManager.unregister_destructible(self)


func _enter_tree() -> void:
	if not _chunk_cols.is_empty():
		_register_with_manager()


func _process(_delta: float) -> void:
	var jobs := 0
	var _t := Time.get_ticks_usec()
	while jobs < MAX_EXPOSURE_JOBS_PER_FRAME and not _pending_exposure_carves.is_empty():
		var job: Dictionary = _pending_exposure_carves.pop_front()
		_jaggedize_exposed_chunks(job["pos"] as Vector3, float(job["radius"]))
		jobs += 1
	if jobs > 0:
		var elapsed := Time.get_ticks_usec() - _t
		Trace.prof("jag", elapsed)
		if BenchFlags.active:
			DestructibleManager.bench_destruct_prof("jag", elapsed)
	if _pending_exposure_carves.is_empty():
		set_process(false)


func _register_with_manager() -> void:
	DestructibleManager.register_destructible(self, global_position, box_size.length() * 0.5)


func _build_chunks() -> void:
	_grid = Vector3i(
		_axis_chunks(box_size.x),
		_axis_chunks(box_size.y),
		_axis_chunks(box_size.z),
	)
	_x_edges = _axis_edges(box_size.x, _grid.x, _body_seed ^ 0xA341)
	_y_edges = _axis_edges(box_size.y, _grid.y, _body_seed ^ 0xC5F9)
	_z_edges = _axis_edges(box_size.z, _grid.z, _body_seed ^ 0x71D3)
	_chunk_grid.resize(_grid.x * _grid.y * _grid.z)
	for z: int in _grid.z:
		for y: int in _grid.y:
			for x: int in _grid.x:
				var min_corner := Vector3(_x_edges[x], _y_edges[y], _z_edges[z])
				var max_corner := Vector3(_x_edges[x + 1], _y_edges[y + 1], _z_edges[z + 1])
				var chunk_size := max_corner - min_corner
				var center := (min_corner + max_corner) * 0.5 + _running_bond_shift(Vector3i(x, y, z))
				_add_chunk(center, chunk_size, Vector3i(x, y, z))
	_build_intact_multimesh()


func _axis_chunks(size: float) -> int:
	return clampi(ceili(size / TARGET_CELL), 1, MAX_CHUNKS_PER_AXIS)


func _axis_edges(size: float, count: int, axis_seed: int) -> PackedFloat32Array:
	var edges := PackedFloat32Array()
	edges.resize(count + 1)
	edges[0] = -size * 0.5
	edges[count] = size * 0.5
	if count <= 1:
		return edges
	var base_step := size / float(count)
	var rng := RandomNumberGenerator.new()
	rng.seed = axis_seed
	for i: int in range(1, count):
		var jitter := rng.randf_range(-EDGE_JITTER, EDGE_JITTER) * base_step
		edges[i] = -size * 0.5 + float(i) * base_step + jitter
	return edges


func _add_chunk(center: Vector3, chunk_size: Vector3, cell: Vector3i) -> void:
	var tag := "Chunk_%d_%d_%d" % [cell.x, cell.y, cell.z]
	var col := CollisionShape3D.new()
	col.name = tag + "_Col"
	var shape := BoxShape3D.new()
	shape.size = chunk_size
	col.shape = shape
	col.position = center
	col.set_meta("chunk_center_local", center)
	col.set_meta("chunk_size", chunk_size)
	col.set_meta("chunk_cell", cell)
	col.set_meta("chunk_half_diag", chunk_size.length() * 0.5)
	col.set_meta("chunk_hp", _chunk_max_health(chunk_size))
	col.set_meta("multimesh_index", _chunk_cols.size())
	col.set_meta("chunk_custom", _chunk_custom_data(cell))
	add_child(col)
	_chunk_cols.append(col)
	_chunk_grid[_flat_index(cell.x, cell.y, cell.z)] = col


func _chunk_custom_data(cell: Vector3i) -> Color:
	# Per-brick variation for MultiMesh INSTANCE_CUSTOM (no extra draw calls).
	var h: int = hash([_body_seed, cell.x, cell.y, cell.z])
	var h2: int = hash([h, 90210])
	var h3: int = hash([h, 31337])
	var h4: int = hash([h, 4242])
	return Color(
		float(h % 1000) / 1000.0,
		0.72 + float(h2 % 100) / 118.0,
		0.86 + float(h3 % 140) / 280.0,
		0.38 + float(h4 % 100) / 115.0,
	)


func _build_intact_multimesh() -> void:
	_intact_mmi = MultiMeshInstance3D.new()
	_intact_mmi.name = "IntactChunks"
	_intact_mmi.material_override = _mat
	var unit_box := _chunk_unit_mesh()
	_intact_mm = MultiMesh.new()
	_intact_mm.transform_format = MultiMesh.TRANSFORM_3D
	_intact_mm.use_custom_data = true
	_intact_mm.mesh = unit_box
	_intact_mm.instance_count = _chunk_cols.size()
	for i: int in _chunk_cols.size():
		var col: CollisionShape3D = _chunk_cols[i]
		var center: Vector3 = col.get_meta("chunk_center_local") as Vector3
		var chunk_size: Vector3 = col.get_meta("chunk_size") as Vector3
		_intact_mm.set_instance_transform(
			i, _chunk_visual_transform(center, chunk_size, col.get_meta("chunk_cell") as Vector3i))
		_intact_mm.set_instance_custom_data(i, col.get_meta("chunk_custom") as Color)
	_intact_mmi.multimesh = _intact_mm
	_intact_mmi.custom_aabb = AABB(-box_size * 0.5, box_size)
	add_child(_intact_mmi)


func _hide_intact_instance(col: CollisionShape3D) -> void:
	if _intact_mm == null:
		return
	var idx: int = int(col.get_meta("multimesh_index", -1))
	if idx < 0 or idx >= _intact_mm.instance_count:
		return
	var center: Vector3 = col.get_meta("chunk_center_local") as Vector3
	_intact_mm.set_instance_transform(idx, Transform3D(Basis.IDENTITY.scaled(Vector3.ZERO), center))


func _ensure_deform_mm() -> void:
	if _deform_mmi != null:
		return
	_ensure_damage_buffer()
	if _dmg_mat == null:
		return
	_deform_mmi = MultiMeshInstance3D.new()
	_deform_mmi.name = "DeformChunks"
	_deform_mmi.material_override = _dmg_mat
	_deform_mm = MultiMesh.new()
	_deform_mm.transform_format = MultiMesh.TRANSFORM_3D
	_deform_mm.use_custom_data = true
	_deform_mm.mesh = get_deform_chunk_mesh()
	_deform_mm.instance_count = 0
	_deform_mmi.multimesh = _deform_mm
	_deform_mmi.custom_aabb = AABB(-box_size * 0.5, box_size)
	add_child(_deform_mmi)


# Move a splatted chunk onto the decal damage-material batch. Idempotent.
func _move_chunk_to_decal(col: CollisionShape3D) -> void:
	var id: int = col.get_instance_id()
	if _deform_slots.has(id) or _decal_slots.has(id):
		return
	_ensure_decal_mm()
	if _decal_mm == null:
		return
	var idx: int
	var grew := false
	if not _decal_free.is_empty():
		idx = int(_decal_free.pop_back())
	else:
		idx = _decal_mm.instance_count
		_decal_mm.instance_count = idx + 1
		grew = true
	_decal_slots[id] = idx
	if grew:
		_refresh_all_decal_instances()
	else:
		_set_decal_instance(idx, col)
	_hide_intact_instance(col)


func _ensure_decal_mm() -> void:
	if _decal_mmi != null:
		return
	_ensure_damage_buffer()
	if _decal_mat == null:
		return
	_decal_mmi = MultiMeshInstance3D.new()
	_decal_mmi.name = "DecalChunks"
	_decal_mmi.material_override = _decal_mat
	_decal_mm = MultiMesh.new()
	_decal_mm.transform_format = MultiMesh.TRANSFORM_3D
	_decal_mm.use_custom_data = true
	_decal_mm.mesh = _chunk_unit_mesh()
	_decal_mm.instance_count = 0
	_decal_mmi.multimesh = _decal_mm
	_decal_mmi.custom_aabb = AABB(-box_size * 0.5, box_size)
	add_child(_decal_mmi)


func _set_decal_instance(idx: int, col: CollisionShape3D) -> void:
	_decal_mm.set_instance_transform(idx, _chunk_visual_transform(
		col.get_meta("chunk_center_local") as Vector3,
		col.get_meta("chunk_size") as Vector3,
		col.get_meta("chunk_cell") as Vector3i))
	_decal_mm.set_instance_custom_data(idx, col.get_meta("chunk_custom") as Color)


func _refresh_all_decal_instances() -> void:
	var active: Dictionary = {}
	for sid: int in _decal_slots:
		var c: Object = instance_from_id(sid)
		if is_instance_valid(c) and c is CollisionShape3D:
			active[int(_decal_slots[sid])] = c
	for i: int in _decal_mm.instance_count:
		if active.has(i):
			_set_decal_instance(i, active[i] as CollisionShape3D)
		else:
			_decal_mm.set_instance_transform(
				i, Transform3D(Basis.IDENTITY.scaled(Vector3.ZERO), Vector3.ZERO))


func _remove_chunk_from_decal(col: CollisionShape3D) -> void:
	var id: int = col.get_instance_id()
	if not _decal_slots.has(id):
		return
	var idx: int = _decal_slots[id]
	_decal_slots.erase(id)
	if _decal_mm != null and idx >= 0 and idx < _decal_mm.instance_count:
		_decal_mm.set_instance_transform(idx, Transform3D(
			Basis.IDENTITY.scaled(Vector3.ZERO), col.get_meta("chunk_center_local") as Vector3))
		_decal_free.append(idx)


# Move a damaged-but-alive chunk into the deform material batch (idempotent).
func _move_chunk_to_deform(col: CollisionShape3D) -> void:
	var id: int = col.get_instance_id()
	if _deform_slots.has(id):
		return
	_remove_chunk_from_decal(col)
	_ensure_deform_mm()
	if _deform_mm == null:
		return
	var idx: int
	var grew := false
	if not _deform_free.is_empty():
		idx = int(_deform_free.pop_back())
	else:
		idx = _deform_mm.instance_count
		_deform_mm.instance_count = idx + 1
		grew = true
	_deform_slots[id] = idx
	# Growing instance_count can wipe the existing instance buffer in Godot, which
	# would silently blank out previously-migrated chunks (visible-but-alive bug).
	# So after a grow, re-apply EVERY slot; otherwise just set the reused slot.
	if grew:
		_refresh_all_deform_instances()
	else:
		_set_deform_instance(idx, col)
	_hide_intact_instance(col)


func _set_deform_instance(idx: int, col: CollisionShape3D) -> void:
	_deform_mm.set_instance_transform(idx, _chunk_visual_transform(
		col.get_meta("chunk_center_local") as Vector3,
		col.get_meta("chunk_size") as Vector3,
		col.get_meta("chunk_cell") as Vector3i))
	_deform_mm.set_instance_custom_data(idx, col.get_meta("chunk_custom") as Color)


# Re-apply all instance data (active slots from their chunk, all others zeroed) —
# defends against MultiMesh.instance_count resizes clearing the buffer.
func _refresh_all_deform_instances() -> void:
	var active: Dictionary = {}
	for sid: int in _deform_slots:
		var c: Object = instance_from_id(sid)
		if is_instance_valid(c) and c is CollisionShape3D:
			active[int(_deform_slots[sid])] = c
	for i: int in _deform_mm.instance_count:
		if active.has(i):
			_set_deform_instance(i, active[i] as CollisionShape3D)
		else:
			_deform_mm.set_instance_transform(
				i, Transform3D(Basis.IDENTITY.scaled(Vector3.ZERO), Vector3.ZERO))


func _remove_chunk_from_deform(col: CollisionShape3D) -> void:
	var id: int = col.get_instance_id()
	if not _deform_slots.has(id):
		return
	var idx: int = _deform_slots[id]
	_deform_slots.erase(id)
	if _deform_mm != null and idx >= 0 and idx < _deform_mm.instance_count:
		_deform_mm.set_instance_transform(idx, Transform3D(
			Basis.IDENTITY.scaled(Vector3.ZERO), col.get_meta("chunk_center_local") as Vector3))
		_deform_free.append(idx)




func _count_chunks() -> int:
	var n := 0
	for col: CollisionShape3D in _chunk_cols:
		if (
			is_instance_valid(col)
			and not bool(col.get_meta("destroyed", false))
		):
			n += 1
	return n


func _chunk_max_health(chunk_size: Vector3) -> float:
	var volume: float = maxf(0.01, chunk_size.x * chunk_size.y * chunk_size.z)
	return CHUNK_BASE_HEALTH + volume * CHUNK_VOLUME_HEALTH




func _flat_index(x: int, y: int, z: int) -> int:
	return x + y * _grid.x + z * _grid.x * _grid.y


func _axis_overlap_range(edges: PackedFloat32Array, axis_count: int, min_v: float, max_v: float) -> Vector2i:
	var first := axis_count
	var last := -1
	for i: int in axis_count:
		if edges[i + 1] < min_v:
			continue
		if edges[i] > max_v:
			break
		first = mini(first, i)
		last = i
	if last < first:
		return Vector2i(0, -1)
	return Vector2i(first, last)


func _candidate_cols(local_center: Vector3, radius: float, extra: float = 0.0) -> Array[CollisionShape3D]:
	var reach := radius + extra
	var xr := _axis_overlap_range(_x_edges, _grid.x, local_center.x - reach, local_center.x + reach)
	var yr := _axis_overlap_range(_y_edges, _grid.y, local_center.y - reach, local_center.y + reach)
	var zr := _axis_overlap_range(_z_edges, _grid.z, local_center.z - reach, local_center.z + reach)
	var cols: Array[CollisionShape3D] = []
	if xr.y < xr.x or yr.y < yr.x or zr.y < zr.x:
		return cols
	for z: int in range(zr.x, zr.y + 1):
		for y: int in range(yr.x, yr.y + 1):
			for x: int in range(xr.x, xr.y + 1):
				var col: CollisionShape3D = _chunk_grid[_flat_index(x, y, z)]
				if col != null:
					cols.append(col)
	return cols


# Cheap OBB test — grid broadphase over-fetches nearby volumes; skip chunk narrowphase
# when the segment misses this body's box entirely (open-air fast path).
func segment_may_hit_volume(world_from: Vector3, world_to: Vector3) -> bool:
	if _chunk_cols.is_empty():
		return false
	var inv_basis := global_basis.inverse()
	var local_from := inv_basis * (world_from - global_position)
	var local_delta := inv_basis * (world_to - world_from)
	var seg_len := local_delta.length()
	if seg_len < 1e-5:
		return false
	var local_dir := local_delta / seg_len
	var half_box := box_size * 0.5
	return _ray_segment_aabb_enter_t(local_from, local_dir, seg_len, -half_box, half_box) >= 0.0


func raycast_chunks(world_from: Vector3, world_to: Vector3, exclude_rids: Array[RID] = []) -> Dictionary:
	if _chunk_cols.is_empty():
		return {}
	var body_rid := get_rid()
	if DestructibleManager._rid_in(body_rid, exclude_rids):
		return {}
	var inv_basis := global_basis.inverse()
	var local_from := inv_basis * (world_from - global_position)
	var local_delta := inv_basis * (world_to - world_from)
	var seg_len := local_delta.length()
	if seg_len < 1e-5:
		return {}
	var local_dir := local_delta / seg_len
	var half_box := box_size * 0.5
	var vol_t := _ray_segment_aabb_enter_t(local_from, local_dir, seg_len, -half_box, half_box)
	if vol_t < 0.0:
		return {}
	if _chunk_cols.size() == 1:
		var only: CollisionShape3D = _chunk_cols[0]
		if not is_instance_valid(only) or only.disabled or bool(only.get_meta("destroyed", false)):
			return {}
		var chunk_center: Vector3 = only.get_meta("chunk_center_local") as Vector3
		var chunk_half: Vector3 = (only.get_meta("chunk_size") as Vector3) * 0.5
		var t_enter := _ray_segment_aabb_enter_t(
			local_from, local_dir, seg_len, chunk_center - chunk_half, chunk_center + chunk_half)
		if t_enter < 0.0:
			return {}
		var hit_local := local_from + local_dir * t_enter
		return {
			"position": to_global(hit_local),
			"normal": (global_basis * _aabb_face_normal(hit_local, chunk_center, chunk_half)).normalized(),
			"collider": only,
			"rid": body_rid,
		}
	var local_to := local_from + local_delta
	var min_v := local_from.min(local_to) - Vector3.ONE * (TARGET_CELL * 0.05)
	var max_v := local_from.max(local_to) + Vector3.ONE * (TARGET_CELL * 0.05)
	var xr := _axis_overlap_range(_x_edges, _grid.x, min_v.x, max_v.x)
	var yr := _axis_overlap_range(_y_edges, _grid.y, min_v.y, max_v.y)
	var zr := _axis_overlap_range(_z_edges, _grid.z, min_v.z, max_v.z)
	if xr.y < xr.x or yr.y < yr.x or zr.y < zr.x:
		return {}
	var best_t := INF
	var best_col: CollisionShape3D = null
	var best_hit_local := Vector3.ZERO
	var best_normal := Vector3.UP
	for z: int in range(zr.x, zr.y + 1):
		for y: int in range(yr.x, yr.y + 1):
			for x: int in range(xr.x, xr.y + 1):
				var col: CollisionShape3D = _chunk_grid[_flat_index(x, y, z)]
				if col == null:
					continue
				if not is_instance_valid(col) or col.disabled:
					continue
				if bool(col.get_meta("destroyed", false)):
					continue
				var center: Vector3 = col.get_meta("chunk_center_local") as Vector3
				var size: Vector3 = col.get_meta("chunk_size") as Vector3
				var half := size * 0.5
				var t_enter := _ray_segment_aabb_enter_t(
					local_from, local_dir, seg_len, center - half, center + half)
				if t_enter < 0.0 or t_enter >= best_t:
					continue
				best_t = t_enter
				best_col = col
				best_hit_local = local_from + local_dir * t_enter
				best_normal = _aabb_face_normal(best_hit_local, center, half)
	if best_col == null:
		return {}
	return {
		"position": to_global(best_hit_local),
		"normal": (global_basis * best_normal).normalized(),
		"collider": best_col,
		"rid": body_rid,
	}


func _candidate_cols_segment(local_from: Vector3, local_to: Vector3, extra: float = 0.0) -> Array[CollisionShape3D]:
	var min_v := local_from.min(local_to) - Vector3.ONE * extra
	var max_v := local_from.max(local_to) + Vector3.ONE * extra
	var xr := _axis_overlap_range(_x_edges, _grid.x, min_v.x, max_v.x)
	var yr := _axis_overlap_range(_y_edges, _grid.y, min_v.y, max_v.y)
	var zr := _axis_overlap_range(_z_edges, _grid.z, min_v.z, max_v.z)
	var cols: Array[CollisionShape3D] = []
	if xr.y < xr.x or yr.y < yr.x or zr.y < zr.x:
		return cols
	for z: int in range(zr.x, zr.y + 1):
		for y: int in range(yr.x, yr.y + 1):
			for x: int in range(xr.x, xr.y + 1):
				var col: CollisionShape3D = _chunk_grid[_flat_index(x, y, z)]
				if col != null:
					cols.append(col)
	return cols


static func _ray_segment_aabb_enter_t(
	origin: Vector3,
	dir: Vector3,
	seg_len: float,
	bmin: Vector3,
	bmax: Vector3,
) -> float:
	var t_enter := 0.0
	var t_exit := seg_len
	for axis: int in 3:
		var o: float = origin[axis]
		var d: float = dir[axis]
		if absf(d) < 1e-8:
			if o < bmin[axis] or o > bmax[axis]:
				return -1.0
			continue
		var inv := 1.0 / d
		var t0: float = (bmin[axis] - o) * inv
		var t1: float = (bmax[axis] - o) * inv
		if t0 > t1:
			var tmp := t0
			t0 = t1
			t1 = tmp
		t_enter = maxf(t_enter, t0)
		t_exit = minf(t_exit, t1)
		if t_exit < t_enter:
			return -1.0
	if t_exit < 0.0 or t_enter > seg_len:
		return -1.0
	return maxf(t_enter, 0.0)


static func _aabb_face_normal(hit: Vector3, center: Vector3, half: Vector3) -> Vector3:
	var rel := hit - center
	var ax := absf(rel.x / maxf(half.x, 0.0001))
	var ay := absf(rel.y / maxf(half.y, 0.0001))
	var az := absf(rel.z / maxf(half.z, 0.0001))
	if ax >= ay and ax >= az:
		return Vector3(signf(rel.x if rel.x != 0.0 else 1.0), 0.0, 0.0)
	if ay >= az:
		return Vector3(0.0, signf(rel.y if rel.y != 0.0 else 1.0), 0.0)
	return Vector3(0.0, 0.0, signf(rel.z if rel.z != 0.0 else 1.0))


func _fx_scene() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	if tree.current_scene:
		return tree.current_scene
	return tree.root


func _jaggedize_exposed_chunks(local_center: Vector3, radius: float) -> void:
	var jag_cap := MAX_JAGGEDIZE_PER_CARVE
	if PerfGovernor and PerfGovernor.quality_scale < 0.75:
		jag_cap = maxi(6, MAX_JAGGEDIZE_PER_CARVE / 3)
	var jaggedized := 0
	for col: CollisionShape3D in _candidate_cols(local_center, radius, TARGET_CELL * 0.75):
		if jaggedized >= jag_cap:
			return
		if not is_instance_valid(col) or bool(col.get_meta("destroyed", false)):
			continue
		var center: Vector3 = col.get_meta("chunk_center_local") as Vector3
		var half_diag: float = float(col.get_meta("chunk_half_diag"))
		if center.distance_to(local_center) > radius + half_diag + TARGET_CELL * 0.75:
			continue
		# Blocks bordering the hole shouldn't stay pristine: damage them by
		# proximity — cracks/scorch on the outer ring, chipped geometry on the
		# immediate rim — and weaken their HP so a follow-up blast cascades.
		var dist: float = center.distance_to(local_center)
		var halo: float = clampf(1.0 - dist / maxf(radius, 0.01), 0.0, 1.0)
		var halo_dmg: float = lerpf(0.22, 0.82, halo * halo)
		var chunk_size: Vector3 = col.get_meta("chunk_size") as Vector3
		var maxhp: float = _chunk_max_health(chunk_size)
		var cur_hp: float = float(col.get_meta("chunk_hp", maxhp))
		col.set_meta("chunk_hp", minf(cur_hp, maxhp * (1.0 - halo_dmg)))
		jaggedized += 1


static var _cached_chunk_mesh: Mesh = null
static var _cached_chunk_mesh_key: String = ""


static func _chunk_mesh_cache_key() -> String:
	return "round:%d:0.09" % CHUNK_MESH_SUBDIVIDE


static func get_stone_block_mesh() -> Mesh:
	return _chunk_unit_mesh()


# Same low-poly unit brick as intact/decal — deform is shader-driven, not extra geometry.
static func get_deform_chunk_mesh() -> Mesh:
	return _chunk_unit_mesh()


func _running_bond_shift(cell: Vector3i) -> Vector3:
	# Stagger every other course so joints aren't a perfect grid.
	if _grid.x > 1 and cell.y % 2 == 1:
		return Vector3(box_size.x / float(_grid.x) * 0.5, 0.0, 0.0)
	if _grid.y <= 1 and _grid.z > 1 and _grid.x > 1 and cell.z % 2 == 1:
		return Vector3(box_size.x / float(_grid.x) * 0.5, 0.0, 0.0)
	return Vector3.ZERO


static func _visual_chunk_scale(chunk_size: Vector3) -> Vector3:
	return chunk_size * VISUAL_CHUNK_INSET


func _chunk_visual_transform(center: Vector3, chunk_size: Vector3, _cell: Vector3i) -> Transform3D:
	return Transform3D(Basis.IDENTITY.scaled(_visual_chunk_scale(chunk_size)), center)


static func _chunk_unit_mesh() -> Mesh:
	var key := _chunk_mesh_cache_key()
	if _cached_chunk_mesh == null or _cached_chunk_mesh_key != key:
		var built: ArrayMesh = _build_hand_hewn_stone_mesh()
		if built.get_surface_count() == 0:
			push_warning("DestructibleSolid: hand-hewn mesh failed; using subdivided box fallback")
			var box := BoxMesh.new()
			box.size = Vector3.ONE
			box.subdivide_width = CHUNK_MESH_SUBDIVIDE
			box.subdivide_height = CHUNK_MESH_SUBDIVIDE
			box.subdivide_depth = CHUNK_MESH_SUBDIVIDE
			var st := SurfaceTool.new()
			st.create_from(box, 0)
			built = st.commit()
		_cached_chunk_mesh = built
		_cached_chunk_mesh_key = key
	return _cached_chunk_mesh


static func _build_hand_hewn_stone_mesh(subdiv: int = CHUNK_MESH_SUBDIVIDE) -> ArrayMesh:
	var box := BoxMesh.new()
	box.size = Vector3.ONE
	box.subdivide_width = subdiv
	box.subdivide_height = subdiv
	box.subdivide_depth = subdiv
	var st := SurfaceTool.new()
	st.create_from(box, 0)
	var base_mesh: ArrayMesh = st.commit()
	var mdt := MeshDataTool.new()
	mdt.create_from_surface(base_mesh, 0)
	for i: int in mdt.get_vertex_count():
		var p: Vector3 = mdt.get_vertex(i)
		mdt.set_vertex(i, _sculpt_hand_hewn_vertex(p))
	var sculpted := ArrayMesh.new()
	mdt.commit_to_surface(sculpted)
	var regen := SurfaceTool.new()
	regen.create_from(sculpted, 0)
	regen.generate_normals()
	regen.generate_tangents()  # needed for GPU-damage crater normal perturbation
	return regen.commit()


static func _sculpt_hand_hewn_vertex(p: Vector3) -> Vector3:
	const HALF := 0.5
	const BEVEL := 0.09
	var s := Vector3(
		signf(p.x) if absf(p.x) > 0.0001 else 1.0,
		signf(p.y) if absf(p.y) > 0.0001 else 1.0,
		signf(p.z) if absf(p.z) > 0.0001 else 1.0,
	)
	var ap := p.abs()
	var inner := HALF - BEVEL
	var q := ap - Vector3(inner, inner, inner)
	var q_pos := Vector3(maxf(q.x, 0.0), maxf(q.y, 0.0), maxf(q.z, 0.0))
	var dist := q_pos.length()
	var out_ap := ap
	if dist > 0.0001:
		out_ap = Vector3(inner, inner, inner) + q_pos / dist * BEVEL
	return Vector3(out_ap.x * s.x, out_ap.y * s.y, out_ap.z * s.z)


func _material_base_color() -> Color:
	return ArenaGenerator.rock_debris_color(_mat)
