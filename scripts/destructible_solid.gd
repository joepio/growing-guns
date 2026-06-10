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
const EDGE_JITTER := 0.28
const VISUAL_JAGGEDNESS := 0.16
const MAX_JAGGEDIZE_PER_CARVE := 18
const MAX_EXPOSURE_JOBS_PER_FRAME := 1

var box_size: Vector3 = Vector3.ONE
var _pending_carves: Array[Dictionary] = []
var _pending_exposure_carves: Array[Dictionary] = []
var _body_seed: int = 0
var _mat: StandardMaterial3D = null
var _chunk_cols: Array[CollisionShape3D] = []
var _chunk_meshes: Dictionary = {}
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
	mat: StandardMaterial3D,
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
	mat: StandardMaterial3D,
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
	var local_normal := Vector3.ZERO
	if hit_normal.length_squared() > 0.0001:
		local_normal = (global_basis.inverse() * hit_normal).normalized()
	_pending_carves.append({
		"pos": to_local(world_pos),
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
	for col: CollisionShape3D in to_remove_cols:
		_hide_intact_instance(col)
		var mesh_obj: Object = _chunk_meshes.get(col.get_instance_id()) as Object
		if mesh_obj is MeshInstance3D:
			(mesh_obj as MeshInstance3D).visible = false
		burst_center += col.global_position
		burst_size += col.get_meta("chunk_size") as Vector3
		exposure_center += col.get_meta("chunk_center_local") as Vector3
		col.set_meta("destroyed", true)
		col.disabled = true
	var n := float(to_remove_cols.size())
	DestructibleManager.note_chunk_removals(to_remove_cols.size())
	var scene := _fx_scene()
	var base_color := _mat.albedo_color if _mat != null else Color(0.45, 0.7, 0.72)
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
		Trace.prof("jag", Time.get_ticks_usec() - _t)
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
				var center := (min_corner + max_corner) * 0.5
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
	col.set_meta("chunk_half_diag", chunk_size.length() * 0.5)
	col.set_meta("chunk_hp", _chunk_max_health(chunk_size))
	col.set_meta("jagged_visual", false)
	col.set_meta("multimesh_index", _chunk_cols.size())
	add_child(col)
	_chunk_cols.append(col)
	_chunk_grid[_flat_index(cell.x, cell.y, cell.z)] = col


func _build_intact_multimesh() -> void:
	_intact_mmi = MultiMeshInstance3D.new()
	_intact_mmi.name = "IntactChunks"
	_intact_mmi.material_override = _mat
	var unit_box := BoxMesh.new()
	unit_box.size = Vector3.ONE
	_intact_mm = MultiMesh.new()
	_intact_mm.transform_format = MultiMesh.TRANSFORM_3D
	_intact_mm.mesh = unit_box
	_intact_mm.instance_count = _chunk_cols.size()
	for i: int in _chunk_cols.size():
		var col: CollisionShape3D = _chunk_cols[i]
		var center: Vector3 = col.get_meta("chunk_center_local") as Vector3
		var chunk_size: Vector3 = col.get_meta("chunk_size") as Vector3
		_intact_mm.set_instance_transform(i, Transform3D(Basis.IDENTITY.scaled(chunk_size), center))
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


func _ensure_chunk_mesh(col: CollisionShape3D) -> MeshInstance3D:
	var id: int = col.get_instance_id()
	var existing: Object = _chunk_meshes.get(id) as Object
	if existing is MeshInstance3D:
		return existing as MeshInstance3D
	var mi := MeshInstance3D.new()
	mi.name = str(col.name).replace("_Col", "_Mesh")
	mi.material_override = _mat
	mi.position = col.get_meta("chunk_center_local") as Vector3
	add_child(mi)
	_chunk_meshes[id] = mi
	return mi


func _make_jagged_box_mesh(size: Vector3, seed_value: int) -> ArrayMesh:
	var half := size * 0.5
	var jitter_limit := minf(size.x, minf(size.y, size.z)) * VISUAL_JAGGEDNESS
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var corners: Array[Vector3] = [
		Vector3(-half.x, -half.y, -half.z),
		Vector3(half.x, -half.y, -half.z),
		Vector3(half.x, half.y, -half.z),
		Vector3(-half.x, half.y, -half.z),
		Vector3(-half.x, -half.y, half.z),
		Vector3(half.x, -half.y, half.z),
		Vector3(half.x, half.y, half.z),
		Vector3(-half.x, half.y, half.z),
	]
	for i in corners.size():
		corners[i] += Vector3(
			rng.randf_range(-jitter_limit, jitter_limit),
			rng.randf_range(-jitter_limit, jitter_limit),
			rng.randf_range(-jitter_limit, jitter_limit)
		)
	var faces: Array[Array] = [
		[0, 1, 2, 3],
		[5, 4, 7, 6],
		[4, 0, 3, 7],
		[1, 5, 6, 2],
		[3, 2, 6, 7],
		[4, 5, 1, 0],
	]
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	for face in faces:
		var a: Vector3 = corners[int(face[0])]
		var b: Vector3 = corners[int(face[1])]
		var c: Vector3 = corners[int(face[2])]
		var d: Vector3 = corners[int(face[3])]
		var n := (b - a).cross(c - a).normalized()
		verts.append_array([a, b, c, a, c, d])
		norms.append_array([n, n, n, n, n, n])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


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
	var jaggedized := 0
	for col: CollisionShape3D in _candidate_cols(local_center, radius, TARGET_CELL * 0.75):
		if jaggedized >= MAX_JAGGEDIZE_PER_CARVE:
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
		var mesh_obj: Object = _chunk_meshes.get(col.get_instance_id()) as Object
		var chunk_size: Vector3 = col.get_meta("chunk_size") as Vector3
		_hide_intact_instance(col)
		var mi: MeshInstance3D = mesh_obj as MeshInstance3D if mesh_obj is MeshInstance3D else _ensure_chunk_mesh(col)
		mi.mesh = _make_jagged_box_mesh(
			chunk_size,
			hash([_body_seed, str(col.name), "exposed"])
		)
		col.set_meta("jagged_visual", true)
		jaggedized += 1
