extends StaticBody3D

const DestructibleManager = preload("res://scripts/destructible_manager.gd")
const Violence = preload("res://scripts/violence.gd")

# One destructible path for terrain and props: pre-split into deterministic,
# uneven box chunks. Blasts only remove existing mesh/collider pairs, so there
# is no runtime mesh rebuild cost when dozens of explosions land in a second.

const MIN_REMOVE_DAMAGE := 12.0
const MIN_ACCUMULATE_DAMAGE := 8.0
const CHUNK_BASE_HEALTH := 42.0
const CHUNK_VOLUME_HEALTH := 4.0
const TARGET_CELL := 2.4
const MAX_CHUNKS_PER_AXIS := 6
const EDGE_JITTER := 0.38
const MAX_JAGGEDIZE_PER_CARVE := 18
const MAX_EXPOSURE_JOBS_PER_FRAME := 1
# Below this VFX quality, exposed chunks stay in the intact MultiMesh (zero extra
# draws). Existing exposed batches are collapsed back when quality sags.
const EXPOSURE_SHED_QS := 0.55

const CHUNK_MESH_SUBDIVIDE := 5
# Visual inset — hairline shadow between bricks; keep tight so walls read solid.
const VISUAL_CHUNK_INSET := 0.992

var box_size: Vector3 = Vector3.ONE
var _pending_carves: Array[Dictionary] = []
var _pending_exposure_carves: Array[Dictionary] = []
var _body_seed: int = 0
var _mat: Material = null
var _chunk_cols: Array[CollisionShape3D] = []
var _chunk_meshes: Dictionary = {}
var _exposed_mmi: MultiMeshInstance3D = null
var _exposed_mm: MultiMesh = null
var _exposed_free: Array[int] = []
var _exposure_shed: bool = false
var _chunk_grid: Array[CollisionShape3D] = []
var _intact_mmi: MultiMeshInstance3D = null
var _intact_mm: MultiMesh = null
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
	if not _pending_carves.is_empty():
		var last: Dictionary = _pending_carves[-1]
		var last_pos: Vector3 = last["pos"] as Vector3
		if last_pos.distance_squared_to(local_pos) <= 0.36:
			last["damage"] = float(last["damage"]) + damage
			last["radius"] = maxf(float(last["radius"]), radius)
			DestructibleManager.mark_dirty(self)
			return
	var local_normal := Vector3.ZERO
	if hit_normal.length_squared() > 0.0001:
		local_normal = (global_basis.inverse() * hit_normal).normalized()
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
	var local_normal := Vector3.ZERO
	if hit_normal.length_squared() > 0.0001:
		local_normal = (global_basis.inverse() * hit_normal).normalized()
	_pending_carves.append({
		"pos": to_local(world_pos),
		"radius": radius,
		"damage": 800.0,
		"normal": local_normal,
		"max_depth": max_depth,
	})
	DestructibleManager.mark_dirty(self)


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
	for carve: Dictionary in _pending_carves:
		var local_center: Vector3 = carve["pos"] as Vector3
		var radius: float = float(carve["radius"])
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
	for col: CollisionShape3D in touched:
		var amount: float = float(accum[col])
		if amount < MIN_ACCUMULATE_DAMAGE:
			continue
		var chunk_size: Vector3 = col.get_meta("chunk_size") as Vector3
		var old_hp: float = float(col.get_meta("chunk_hp", _chunk_max_health(chunk_size)))
		var new_hp: float = old_hp - amount
		col.set_meta("chunk_hp", new_hp)
		if new_hp <= 0.0 or amount >= new_hp + MIN_REMOVE_DAMAGE:
			to_remove_cols.append(col)
	if to_remove_cols.is_empty():
		return false

	# Disable + hide every removed chunk, then ONE debris burst + ONE jag job.
	var burst_center := Vector3.ZERO
	var burst_size := Vector3.ZERO
	var exposure_center := Vector3.ZERO
	var scene := _fx_scene()
	var max_blood_cleanup_r := 0.0
	for col: CollisionShape3D in to_remove_cols:
		_hide_intact_instance(col)
		_hide_exposed_chunk(col)
		burst_center += col.global_position
		burst_size += col.get_meta("chunk_size") as Vector3
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
	Violence.spawn_destruction_debris(
		scene, burst_center / n, global_basis, burst_size / n, base_color,
		burst_center / n, max_radius, to_remove_cols.size())
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
	col.set_meta("jagged_visual", false)
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


func _restore_intact_instance(col: CollisionShape3D) -> void:
	if _intact_mm == null:
		return
	var idx: int = int(col.get_meta("multimesh_index", -1))
	if idx < 0 or idx >= _intact_mm.instance_count:
		return
	var center: Vector3 = col.get_meta("chunk_center_local") as Vector3
	var chunk_size: Vector3 = col.get_meta("chunk_size") as Vector3
	_intact_mm.set_instance_transform(
		idx, _chunk_visual_transform(center, chunk_size, col.get_meta("chunk_cell") as Vector3i))


func _ensure_exposed_multimesh() -> MultiMesh:
	if _exposed_mm != null:
		return _exposed_mm
	_exposed_mmi = MultiMeshInstance3D.new()
	_exposed_mmi.name = "ExposedChunks"
	_exposed_mmi.material_override = _mat
	var unit_box := _chunk_unit_mesh()
	_exposed_mm = MultiMesh.new()
	_exposed_mm.transform_format = MultiMesh.TRANSFORM_3D
	_exposed_mm.use_custom_data = true
	_exposed_mm.mesh = unit_box
	_exposed_mm.instance_count = 0
	_exposed_mmi.multimesh = _exposed_mm
	_exposed_mmi.custom_aabb = AABB(-box_size * 0.5, box_size)
	_exposed_mmi.add_to_group("destructible_exposed_mm")
	add_child(_exposed_mmi)
	return _exposed_mm


func _update_exposure_lod() -> void:
	var qs: float = Violence.vfx_quality_scale()
	var should_shed := qs <= EXPOSURE_SHED_QS
	if should_shed and not _exposure_shed:
		_pending_exposure_carves.clear()
		_shed_all_exposed_visuals()
		_exposure_shed = true
	elif not should_shed and _exposure_shed:
		_exposure_shed = false


func _shed_all_exposed_visuals() -> void:
	var shed := 0
	for col: CollisionShape3D in _chunk_cols:
		if not is_instance_valid(col) or bool(col.get_meta("destroyed", false)):
			continue
		if not bool(col.get_meta("jagged_visual", false)):
			continue
		_restore_intact_instance(col)
		col.set_meta("jagged_visual", false)
		shed += 1
	if shed > 0:
		DestructibleManager.note_exposed_chunk(-shed)
	_chunk_meshes.clear()
	_exposed_free.clear()
	if _exposed_mm != null:
		_exposed_mm.instance_count = 0


func _show_exposed_chunk(col: CollisionShape3D, chunk_size: Vector3, center: Vector3) -> void:
	if Violence.vfx_quality_scale() <= EXPOSURE_SHED_QS:
		return
	_hide_intact_instance(col)
	var mm := _ensure_exposed_multimesh()
	var idx: int
	if not _exposed_free.is_empty():
		idx = int(_exposed_free.pop_back())
	else:
		idx = mm.instance_count
		mm.instance_count = idx + 1
	mm.set_instance_transform(
		idx, _chunk_visual_transform(center, chunk_size, col.get_meta("chunk_cell") as Vector3i))
	mm.set_instance_custom_data(idx, col.get_meta("chunk_custom") as Color)
	_chunk_meshes[col.get_instance_id()] = idx
	col.set_meta("jagged_visual", true)
	DestructibleManager.note_exposed_chunk(1)


func _hide_exposed_chunk(col: CollisionShape3D) -> void:
	var id: int = col.get_instance_id()
	if not _chunk_meshes.has(id):
		return
	var idx: int = int(_chunk_meshes[id])
	_chunk_meshes.erase(id)
	if _exposed_mm != null and idx >= 0 and idx < _exposed_mm.instance_count:
		var center: Vector3 = col.get_meta("chunk_center_local") as Vector3
		_exposed_mm.set_instance_transform(
			idx, Transform3D(Basis.IDENTITY.scaled(Vector3.ZERO), center))
		_exposed_free.append(idx)
	DestructibleManager.note_exposed_chunk(-1)


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


func _fx_scene() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	if tree.current_scene:
		return tree.current_scene
	return tree.root


func _jaggedize_exposed_chunks(local_center: Vector3, radius: float) -> void:
	if Violence.vfx_quality_scale() <= EXPOSURE_SHED_QS:
		return
	var jag_cap := MAX_JAGGEDIZE_PER_CARVE
	if PerfGovernor and PerfGovernor.quality_scale < 0.75:
		jag_cap = maxi(6, MAX_JAGGEDIZE_PER_CARVE / 3)
	var jaggedized := 0
	for col: CollisionShape3D in _candidate_cols(local_center, radius, TARGET_CELL * 0.75):
		if jaggedized >= jag_cap:
			return
		if (
				not is_instance_valid(col)
				or bool(col.get_meta("destroyed", false))
				or bool(col.get_meta("jagged_visual", false))
			):
			continue
		var center: Vector3 = col.get_meta("chunk_center_local") as Vector3
		var half_diag: float = float(col.get_meta("chunk_half_diag"))
		if center.distance_to(local_center) > radius + half_diag + TARGET_CELL * 0.75:
			continue
		var chunk_size: Vector3 = col.get_meta("chunk_size") as Vector3
		_hide_intact_instance(col)
		_show_exposed_chunk(col, chunk_size, center)
		jaggedized += 1


static var _cached_chunk_mesh: Mesh = null
static var _cached_chunk_mesh_key: String = ""


static func _chunk_mesh_cache_key() -> String:
	return "round:%d:0.09" % CHUNK_MESH_SUBDIVIDE


static func get_stone_block_mesh() -> Mesh:
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


static func _build_hand_hewn_stone_mesh() -> ArrayMesh:
	var box := BoxMesh.new()
	box.size = Vector3.ONE
	box.subdivide_width = CHUNK_MESH_SUBDIVIDE
	box.subdivide_height = CHUNK_MESH_SUBDIVIDE
	box.subdivide_depth = CHUNK_MESH_SUBDIVIDE
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
	if _mat is StandardMaterial3D:
		return (_mat as StandardMaterial3D).albedo_color
	if _mat is ShaderMaterial:
		var bc = (_mat as ShaderMaterial).get_shader_parameter("base_color")
		if bc is Color:
			return bc
	return Color(0.45, 0.44, 0.42)
