extends RefCounted

# Batched destruction for pre-split destructible solids. Blasts mark bodies
# dirty; each physics tick removes a limited number of affected chunks.

const MAX_DIRTY_FLUSH_PER_FRAME := 24
const MAX_DIRTY_FLUSH_USEC := 2500

static var _dirty: Array[int] = []
static var _dirty_set: Dictionary = {}
static var _registered_ids: Array[int] = []
static var _registered_centers: Array[Vector3] = []
static var _registered_bounds: Array[float] = []
static var _registered_index_by_id: Dictionary = {}


static func blast_damage_at(dist: float, radius: float, damage: float) -> float:
	if radius <= 0.0 or damage <= 0.0 or dist >= radius:
		return 0.0
	var t: float = 1.0 - dist / radius
	return damage * t * t


static func apply_blast(
	world_pos: Vector3,
	radius: float,
	damage: float,
	hit_normal: Vector3 = Vector3.ZERO,
) -> void:
	if BenchFlags.active and BenchFlags.no_destruction:
		return
	if radius <= 0.0 or damage <= 0.0:
		return
	var _t := Time.get_ticks_usec()
	var hit_ids: Array[int] = []
	var i := 0
	while i < _registered_ids.size():
		var id: int = _registered_ids[i]
		var node: Object = instance_from_id(id)
		if not is_instance_valid(node):
			_unregister_id(id)
			continue
		var reach: float = radius + _registered_bounds[i]
		if _registered_centers[i].distance_squared_to(world_pos) <= reach * reach:
			hit_ids.append(id)
		i += 1
	# Queue only — the carve is applied once per physics tick by flush() (the
	# body marks itself dirty in queue_*). Applying synchronously here made the
	# per-tick batching dead code and paid full removal+debris cost per blast;
	# deferring lets all of a body's blasts in a tick merge into one sweep.
	for id: int in hit_ids:
		var node: Object = instance_from_id(id)
		if not is_instance_valid(node):
			continue
		if node.has_method("queue_blast_damage"):
			node.call("queue_blast_damage", world_pos, radius, damage, hit_normal)
		elif node.has_method("queue_carve_world"):
			node.call("queue_carve_world", world_pos, radius, hit_normal)
	var elapsed := Time.get_ticks_usec() - _t
	Trace.prof("carve", elapsed)
	bench_destruct_prof("carve_queue", elapsed)
	bench_destruct_prof("carve_calls", 0)


static func carve_sphere(
	world_pos: Vector3,
	radius: float,
	hit_normal: Vector3 = Vector3.ZERO,
	_max_depth: float = -1.0,
) -> void:
	# Bench / debug — still blows through HP instantly.
	apply_blast(world_pos, radius, 800.0, hit_normal)


static func carve_from_hit(
	world_pos: Vector3,
	dmg_ratio: float,
	explosive_radius: float,
	collider: Node,
	hit_normal: Vector3 = Vector3.ZERO,
	explosive_damage: float = 0.0,
) -> void:
	if BenchFlags.active and BenchFlags.no_destruction:
		return
	if explosive_radius <= 0.0:
		# Rifle hits chip HP locally so crack wear shows before fracture.
		if _collider_is_destructible(collider):
			var chip_dmg: float = clampf(9.0 + dmg_ratio * 7.0, 9.0, 24.0)
			apply_blast(world_pos, 0.7, chip_dmg, hit_normal)
		return
	var dmg: float = explosive_damage if explosive_damage > 0.0 else 30.0
	var blast_r: float = explosive_radius * 0.52
	var hit_vol: Node = _destructible_root(collider)
	if hit_vol != null:
		_apply_blast_on_volume(hit_vol, world_pos, blast_r, dmg, hit_normal)
		_apply_blast_neighbors_once_per_frame(hit_vol, world_pos, blast_r, dmg, hit_normal)
		if BenchFlags.active:
			bench_destruct_prof("carve_calls", 0)
			bench_destruct_prof("carve_fast_hit", 0)
		return
	apply_blast(world_pos, blast_r, dmg, hit_normal)


static func _destructible_root(collider: Node) -> Node:
	if collider == null:
		return null
	var node: Node = collider
	while node != null:
		if node.is_in_group("destructible"):
			return node
		node = node.get_parent()
	return null


static func _apply_blast_on_volume(
	vol: Node,
	world_pos: Vector3,
	radius: float,
	damage: float,
	hit_normal: Vector3,
) -> void:
	if not is_instance_valid(vol):
		return
	if vol.has_method("queue_blast_damage"):
		vol.call("queue_blast_damage", world_pos, radius, damage, hit_normal)
	elif vol.has_method("queue_carve_world"):
		vol.call("queue_carve_world", world_pos, radius, hit_normal)


static var _blast_neighbor_scan_vol_id: int = -1
static var _blast_neighbor_scan_frame: int = -1


static func _apply_blast_neighbors_once_per_frame(
	primary: Node,
	world_pos: Vector3,
	radius: float,
	damage: float,
	hit_normal: Vector3,
) -> void:
	if not is_instance_valid(primary):
		return
	var frame: int = Engine.get_physics_frames()
	var primary_id: int = primary.get_instance_id()
	if _blast_neighbor_scan_vol_id == primary_id and _blast_neighbor_scan_frame == frame:
		return
	_blast_neighbor_scan_vol_id = primary_id
	_blast_neighbor_scan_frame = frame
	var _t := Time.get_ticks_usec()
	var i := 0
	while i < _registered_ids.size():
		var id: int = _registered_ids[i]
		if id == primary_id:
			i += 1
			continue
		var node: Object = instance_from_id(id)
		if not is_instance_valid(node):
			_unregister_id(id)
			continue
		var reach: float = radius + _registered_bounds[i]
		if _registered_centers[i].distance_squared_to(world_pos) <= reach * reach:
			if node.has_method("queue_blast_damage"):
				node.call("queue_blast_damage", world_pos, radius, damage, hit_normal)
			elif node.has_method("queue_carve_world"):
				node.call("queue_carve_world", world_pos, radius, hit_normal)
		i += 1
	var elapsed := Time.get_ticks_usec() - _t
	Trace.prof("carve", elapsed)
	bench_destruct_prof("carve_queue", elapsed)
	bench_destruct_prof("carve_calls", 0)
	bench_destruct_prof("carve_neighbor_scan", 0)


static func _collider_is_destructible(collider: Node) -> bool:
	var node: Node = collider
	while node != null:
		if node.is_in_group("destructible"):
			return true
		node = node.get_parent()
	return false


static func mark_dirty(vol: Node) -> void:
	_mark_dirty(vol)


static func register_destructible(vol: Node3D, center: Vector3, bound_radius: float) -> void:
	if not is_instance_valid(vol):
		return
	var id: int = vol.get_instance_id()
	if _registered_index_by_id.has(id):
		var existing: int = int(_registered_index_by_id[id])
		_registered_centers[existing] = center
		_registered_bounds[existing] = bound_radius
		return
	_registered_index_by_id[id] = _registered_ids.size()
	_registered_ids.append(id)
	_registered_centers.append(center)
	_registered_bounds.append(bound_radius)


static func unregister_destructible(vol: Node) -> void:
	if not is_instance_valid(vol):
		return
	_unregister_id(vol.get_instance_id())


static func _unregister_id(id: int) -> void:
	if not _registered_index_by_id.has(id):
		return
	var idx: int = int(_registered_index_by_id[id])
	var last_idx: int = _registered_ids.size() - 1
	var last_id: int = _registered_ids[last_idx]
	_registered_ids[idx] = last_id
	_registered_centers[idx] = _registered_centers[last_idx]
	_registered_bounds[idx] = _registered_bounds[last_idx]
	_registered_index_by_id[last_id] = idx
	_registered_ids.pop_back()
	_registered_centers.pop_back()
	_registered_bounds.pop_back()
	_registered_index_by_id.erase(id)


static func _mark_dirty(vol: Node) -> void:
	if not is_instance_valid(vol):
		return
	var id: int = vol.get_instance_id()
	if _dirty_set.has(id):
		return
	_dirty_set[id] = true
	_dirty.append(id)


static func flush() -> void:
	if _dirty.is_empty():
		return
	var deadline := Time.get_ticks_usec() + MAX_DIRTY_FLUSH_USEC
	var ops: int = 0
	var i: int = 0
	var keep: Array[int] = []
	while i < _dirty.size():
		var id: int = _dirty[i]
		i += 1
		var vol: Object = instance_from_id(id)
		if not is_instance_valid(vol):
			_dirty_set.erase(id)
			continue
		if ops >= MAX_DIRTY_FLUSH_PER_FRAME or Time.get_ticks_usec() >= deadline:
			keep.append(id)
			continue
		_dirty_set.erase(id)
		if vol.has_method("apply_pending_carves") and vol.call("apply_pending_carves"):
			ops += 1
	_dirty = keep
	_dirty_set.clear()
	for id: int in _dirty:
		_dirty_set[id] = true


# Chunk-removal counter — lets the stress bench report removals/sec (frame time
# at high blast rates is dominated by removals + debris, not the carve math).
static var _chunk_removals_total: int = 0

static func note_chunk_removals(n: int) -> void:
	_chunk_removals_total += n

static func debug_chunk_removals() -> int:
	return _chunk_removals_total

static func reset_chunk_removals() -> void:
	_chunk_removals_total = 0


static var _bench_destruct_usec: Dictionary = {}
static var _bench_destruct_n: Dictionary = {}


static func reset_bench_destruct_prof() -> void:
	_bench_destruct_usec.clear()
	_bench_destruct_n.clear()


static func bench_destruct_prof_summary() -> Dictionary:
	return {"usec": _bench_destruct_usec.duplicate(), "n": _bench_destruct_n.duplicate()}


static func bench_destruct_prof(bucket: String, usec: int) -> void:
	if not BenchFlags.active:
		return
	_bench_destruct_usec[bucket] = int(_bench_destruct_usec.get(bucket, 0)) + usec
	_bench_destruct_n[bucket] = int(_bench_destruct_n.get(bucket, 0)) + 1


static func debug_dirty_queue_len() -> int:
	return _dirty.size()


static func debug_registered_count() -> int:
	return _registered_ids.size()
