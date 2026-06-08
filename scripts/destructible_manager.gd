extends RefCounted

# Batched destruction for pre-split destructible solids. Blasts mark bodies
# dirty; each physics tick removes a limited number of affected chunks.

const MAX_DIRTY_FLUSH_PER_FRAME := 24

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
	for id: int in hit_ids:
		var node: Object = instance_from_id(id)
		if not is_instance_valid(node):
			continue
		if node.has_method("queue_blast_damage"):
			node.call("queue_blast_damage", world_pos, radius, damage, hit_normal)
			if node.has_method("apply_pending_carves"):
				node.call("apply_pending_carves")
		elif node.has_method("queue_carve_world"):
			node.call("queue_carve_world", world_pos, radius, hit_normal)
			if node.has_method("apply_pending_carves"):
				node.call("apply_pending_carves")


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
	apply_blast(world_pos, explosive_radius * 0.52, dmg, hit_normal)


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
		if ops >= MAX_DIRTY_FLUSH_PER_FRAME:
			keep.append(id)
			continue
		_dirty_set.erase(id)
		if vol.has_method("apply_pending_carves") and vol.call("apply_pending_carves"):
			ops += 1
	_dirty = keep
	_dirty_set.clear()
	for id: int in _dirty:
		_dirty_set[id] = true
