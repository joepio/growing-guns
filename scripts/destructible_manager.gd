class_name DestructibleManager
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
static var _registered_body_rids: Array[RID] = []
static var _registered_vols: Array[Node3D] = []
static var _registered_index_by_id: Dictionary = {}
# Spatial broadphase for bullet rays — most arena tiles are separate volumes, so
# scanning all ~400+ registrations per projectile per tick was the spike source.
const BULLET_VOL_CELL := 12.0
const RIFLE_CHIP_DAMAGE_BASE := 9.0
const RIFLE_CHIP_DAMAGE_PER_RATIO := 7.0
const RIFLE_CHIP_RADIUS_BASE := 0.7
const RIFLE_CHIP_RADIUS_PER_RATIO := 0.045
const RIFLE_CHIP_RADIUS_MAX := 2.2
# After grid broadphase, at most this many volumes run chunk narrowphase per ray.
const MAX_BULLET_VOLUME_RAYCASTS := 8
# Hard cap across all bullets per physics tick — stops mag-dump sky spam from
# running thousands of chunk raycasts in one frame.
const MAX_BULLET_VOLUME_RAYCASTS_GLOBAL := 32
static var _vol_ray_budget_left: int = 0
static var _vol_ray_budget_frame: int = -1
static var _combat_ceiling_local_y: float = 22.0
static var _vol_grid: Dictionary = {}  # "x,y,z" -> Array[int] volume instance ids
static var _vol_grid_cells_by_id: Dictionary = {}  # instance id -> Array[String]


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


# Read-only broadphase for GPU debris occupancy snapshots: every registered
# volume whose bounding sphere touches the world-space box. No unregistration
# side effects here — callers may hold the result across a frame.
static func volumes_overlapping_aabb(world_aabb: AABB) -> Array[Node3D]:
	var out: Array[Node3D] = []
	var i := 0
	while i < _registered_ids.size():
		var vol: Node3D = _registered_vols[i]
		if vol != null and is_instance_valid(vol):
			if world_aabb.grow(_registered_bounds[i]).has_point(_registered_centers[i]):
				out.append(vol)
		i += 1
	return out


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
		# Rifle hits chip chunk HP locally. dmg_ratio is bullet_damage / BASE_DAMAGE
		# (uncapped) — high damage cards should one-shot a brick when chip_dmg
		# exceeds ~CHUNK_BASE_HEALTH + volume scaling (~50–120 typical).
		if _collider_is_destructible(collider):
			var chip_dmg: float = RIFLE_CHIP_DAMAGE_BASE + dmg_ratio * RIFLE_CHIP_DAMAGE_PER_RATIO
			var chip_r: float = clampf(
				RIFLE_CHIP_RADIUS_BASE + dmg_ratio * RIFLE_CHIP_RADIUS_PER_RATIO,
				RIFLE_CHIP_RADIUS_BASE,
				RIFLE_CHIP_RADIUS_MAX,
			)
			apply_blast(world_pos, chip_r, chip_dmg, hit_normal)
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
	var primary_idx: int = int(_registered_index_by_id.get(primary_id, -1))
	if primary_idx >= 0 and radius <= _registered_bounds[primary_idx] * 0.85:
		return
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
		_vol_grid_remove_id(id)
		_vol_grid_insert_id(id, center, bound_radius)
		return
	_registered_index_by_id[id] = _registered_ids.size()
	_registered_ids.append(id)
	_registered_centers.append(center)
	_registered_bounds.append(bound_radius)
	if vol is CollisionObject3D:
		_registered_body_rids.append((vol as CollisionObject3D).get_rid())
	else:
		_registered_body_rids.append(RID())
	_registered_vols.append(vol)
	_vol_grid_insert_id(id, center, bound_radius)


static func unregister_destructible(vol: Node) -> void:
	if not is_instance_valid(vol):
		return
	_unregister_id(vol.get_instance_id())


static func _unregister_id(id: int) -> void:
	if not _registered_index_by_id.has(id):
		return
	_vol_grid_remove_id(id)
	var idx: int = int(_registered_index_by_id[id])
	var last_idx: int = _registered_ids.size() - 1
	var last_id: int = _registered_ids[last_idx]
	_registered_ids[idx] = last_id
	_registered_centers[idx] = _registered_centers[last_idx]
	_registered_bounds[idx] = _registered_bounds[last_idx]
	_registered_body_rids[idx] = _registered_body_rids[last_idx]
	_registered_vols[idx] = _registered_vols[last_idx]
	_registered_index_by_id[last_id] = idx
	_registered_ids.pop_back()
	_registered_centers.pop_back()
	_registered_bounds.pop_back()
	_registered_body_rids.pop_back()
	_registered_vols.pop_back()
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


static var _exposed_chunk_count: int = 0


static func debug_exposed_chunk_count() -> int:
	return _exposed_chunk_count


static func reset_exposed_chunk_count() -> void:
	_exposed_chunk_count = 0


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


# Playable map AABB — bullets outside skip destructible narrowphase entirely.
static var _play_origin: Vector3 = Vector3.ZERO
static var _play_half_xz: float = 40.0
static var _play_y_min: float = -15.0
static var _play_y_max: float = 55.0
static var _play_bounds_valid: bool = false


static func play_bounds_enabled() -> bool:
	return _play_bounds_valid


static func set_play_bounds(origin: Vector3, half_xz: float, y_min: float, y_max: float, combat_ceiling_local_y: float = -1.0) -> void:
	_play_origin = origin
	_play_half_xz = maxf(half_xz, 1.0)
	_play_y_min = y_min
	_play_y_max = maxf(y_max, y_min + 1.0)
	if combat_ceiling_local_y >= 0.0:
		_combat_ceiling_local_y = combat_ceiling_local_y
	else:
		_combat_ceiling_local_y = _play_y_max - 6.0
	_play_bounds_valid = true


static func clear_play_bounds() -> void:
	_play_bounds_valid = false


static func update_play_bounds_from_arena(arena: Node3D) -> void:
	if arena == null:
		clear_play_bounds()
		return
	var bounds: Dictionary = {}
	if arena.has_method("get_play_bounds"):
		bounds = arena.call("get_play_bounds") as Dictionary
	elif arena is ArenaGenerator:
		bounds = (arena as ArenaGenerator).get_play_bounds()
	if bounds.is_empty():
		set_play_bounds(arena.global_position, 40.0, -15.0, 55.0)
		return
	set_play_bounds(
		bounds.get("origin", arena.global_position) as Vector3,
		float(bounds.get("half_xz", 40.0)),
		float(bounds.get("y_min", -15.0)),
		float(bounds.get("y_max", 55.0)),
		float(bounds.get("y_combat_ceiling", -1.0)),
	)


static func point_above_combat_ceiling(world_pos: Vector3) -> bool:
	if not _play_bounds_valid:
		return false
	return (world_pos - _play_origin).y > _combat_ceiling_local_y


static func segment_needs_destruct_query(world_from: Vector3, world_to: Vector3) -> bool:
	if not _play_bounds_valid:
		return true
	if not _segment_intersects_play_bounds(world_from, world_to):
		return false
	var local_from := world_from - _play_origin
	var local_to := world_to - _play_origin
	# Open sky — both endpoints above the fort roof line, no terrain to hit.
	if local_from.y > _combat_ceiling_local_y and local_to.y > _combat_ceiling_local_y:
		return false
	return true


static func _refresh_vol_ray_budget() -> void:
	var pf := Engine.get_physics_frames()
	if pf == _vol_ray_budget_frame:
		return
	_vol_ray_budget_frame = pf
	_vol_ray_budget_left = MAX_BULLET_VOLUME_RAYCASTS_GLOBAL


static func _take_vol_ray_budget() -> bool:
	_refresh_vol_ray_budget()
	if _vol_ray_budget_left <= 0:
		return false
	_vol_ray_budget_left -= 1
	return true


static func point_inside_play_bounds(world_pos: Vector3, margin: float = 0.0) -> bool:
	if not _play_bounds_valid:
		return true
	var local := world_pos - _play_origin
	var half := _play_half_xz + margin
	return (
		absf(local.x) <= half
		and absf(local.z) <= half
		and local.y >= _play_y_min - margin
		and local.y <= _play_y_max + margin
	)


static func _segment_intersects_play_bounds(world_from: Vector3, world_to: Vector3) -> bool:
	if not _play_bounds_valid:
		return true
	var local_from := world_from - _play_origin
	var local_to := world_to - _play_origin
	var dir := local_to - local_from
	var tmin := 0.0
	var tmax := 1.0
	var half := _play_half_xz
	var axes: Array = [
		[dir.x, local_from.x, -half, half],
		[dir.y, local_from.y, _play_y_min, _play_y_max],
		[dir.z, local_from.z, -half, half],
	]
	for ax: Array in axes:
		var d: float = float(ax[0])
		var f: float = float(ax[1])
		var b0: float = float(ax[2])
		var b1: float = float(ax[3])
		if absf(d) < 1e-8:
			if f < b0 or f > b1:
				return false
			continue
		var t0 := (b0 - f) / d
		var t1 := (b1 - f) / d
		if t0 > t1:
			var swap := t0
			t0 = t1
			t1 = swap
		tmin = maxf(tmin, t0)
		tmax = minf(tmax, t1)
		if tmin > tmax:
			return false
	return true


# Bullets skip destructible chunk shapes in PhysicsServer raycasts (thousands of
# box colliders on one layer) and resolve hits analytically per volume instead.
# Returns { "hit": Dictionary, "terrain_near": bool } — terrain_near means the
# spatial grid found volumes along the segment (caller should use physics mask
# without layer 1 and rely on this analytical hit for terrain).
static func query_bullet_ray(
	world_from: Vector3,
	world_to: Vector3,
	shooter_exclude: Array[RID],
) -> Dictionary:
	var seg := world_to - world_from
	var seg_len_sq := seg.length_squared()
	if seg_len_sq < 1e-8:
		return {"hit": {}, "terrain_near": false}
	if not segment_needs_destruct_query(world_from, world_to):
		return {"hit": {}, "terrain_near": false}
	var _t := Time.get_ticks_usec()
	_ensure_vol_grid()
	var seg_len: float = sqrt(seg_len_sq)
	var seg_dir: Vector3 = seg / seg_len
	var grid_candidates: Array[int] = _vol_grid_candidates(world_from, world_to, BULLET_VOL_CELL)
	if grid_candidates.is_empty():
		grid_candidates = _vol_grid_candidates(world_from, world_to, BULLET_VOL_CELL * 3.0)
	if BenchFlags.active:
		_bench_ray_calls += 1
		_bench_grid_candidate_sum += grid_candidates.size()
	# Grid cells over-fetch (sphere bounds). Keep only volumes whose OBB the segment
	# actually crosses — open-air shots skip chunk narrowphase entirely.
	var candidates: Array[int] = _filter_volume_hits(world_from, world_to, grid_candidates)
	if BenchFlags.active:
		_bench_candidate_sum += candidates.size()
	if candidates.is_empty():
		Trace.prof("bullet_destruct_ray", Time.get_ticks_usec() - _t)
		return {"hit": {}, "terrain_near": false}
	_sort_candidates_by_ray_t(world_from, seg_dir, candidates)
	var best_t := INF
	var best_hit := {}
	var ray_to := world_to
	var raycasts := 0
	var i := 0
	while i < candidates.size():
		if raycasts >= MAX_BULLET_VOLUME_RAYCASTS:
			break
		if raycasts > 0 and not _take_vol_ray_budget():
			break
		var id: int = candidates[i]
		i += 1
		if not _registered_index_by_id.has(id):
			continue
		var idx: int = int(_registered_index_by_id[id])
		var center: Vector3 = _registered_centers[idx]
		var bound: float = _registered_bounds[idx]
		if best_t < INF:
			var along: float = (center - world_from).dot(seg_dir)
			if along - bound > best_t + 0.05:
				break
		if not _segment_may_hit_volume(world_from, ray_to, center, bound):
			continue
		var vol: Node3D = _registered_vols[idx]
		if not is_instance_valid(vol):
			_unregister_id(id)
			continue
		if not vol.has_method("raycast_chunks"):
			continue
		raycasts += 1
		if BenchFlags.active:
			_bench_volumes_raycast += 1
		var hit: Dictionary = vol.call("raycast_chunks", world_from, ray_to, shooter_exclude)
		if hit.is_empty():
			continue
		var t: float = world_from.distance_to(hit.position)
		if t < best_t:
			best_t = t
			best_hit = hit
			ray_to = world_from + seg_dir * best_t
	Trace.prof("bullet_destruct_ray", Time.get_ticks_usec() - _t)
	return {"hit": best_hit, "terrain_near": not best_hit.is_empty()}


static var _bench_ray_calls: int = 0
static var _bench_grid_candidate_sum: int = 0
static var _bench_candidate_sum: int = 0
static var _bench_volumes_raycast: int = 0


static func reset_bench_bullet_ray_stats() -> void:
	_bench_ray_calls = 0
	_bench_grid_candidate_sum = 0
	_bench_candidate_sum = 0
	_bench_volumes_raycast = 0


static func bench_bullet_ray_stats() -> Dictionary:
	return {
		"calls": _bench_ray_calls,
		"grid_candidates_avg": float(_bench_grid_candidate_sum) / maxf(1.0, float(_bench_ray_calls)),
		"candidates_avg": float(_bench_candidate_sum) / maxf(1.0, float(_bench_ray_calls)),
		"volumes_raycast": _bench_volumes_raycast,
	}


static func _filter_volume_hits(world_from: Vector3, world_to: Vector3, ids: Array[int]) -> Array[int]:
	var out: Array[int] = []
	for id: int in ids:
		if not _registered_index_by_id.has(id):
			continue
		var idx: int = int(_registered_index_by_id[id])
		var vol: Node3D = _registered_vols[idx]
		if not is_instance_valid(vol):
			_unregister_id(id)
			continue
		if vol.has_method("segment_may_hit_volume"):
			if vol.call("segment_may_hit_volume", world_from, world_to):
				out.append(id)
		elif _segment_may_hit_volume(
			world_from, world_to, _registered_centers[idx], _registered_bounds[idx]
		):
			out.append(id)
	return out


# Legacy — pierce/ghost paths only refresh shooter excludes; terrain uses query in _intersect_ray.
static func fill_bullet_physics_exclude(
	shooter_exclude: Array[RID],
	world_from: Vector3,
	world_to: Vector3,
	out: Array[RID],
) -> void:
	out.clear()
	out.append_array(shooter_exclude)


static func raycast_bullet_destructibles(
	world_from: Vector3,
	world_to: Vector3,
	exclude_rids: Array[RID],
) -> Dictionary:
	return query_bullet_ray(world_from, world_to, exclude_rids).get("hit", {})


static func _vol_cell_coord(p: Vector3) -> Vector3i:
	return Vector3i(
		floori(p.x / BULLET_VOL_CELL),
		floori(p.y / BULLET_VOL_CELL),
		floori(p.z / BULLET_VOL_CELL),
	)


static func _vol_cell_key(c: Vector3i) -> String:
	return "%d,%d,%d" % [c.x, c.y, c.z]


static func _vol_cell_keys_for_aabb(center: Vector3, bound: float) -> Array[String]:
	var bmin := center - Vector3.ONE * bound
	var bmax := center + Vector3.ONE * bound
	var c0 := _vol_cell_coord(bmin)
	var c1 := _vol_cell_coord(bmax)
	var keys: Array[String] = []
	for x: int in range(c0.x, c1.x + 1):
		for y: int in range(c0.y, c1.y + 1):
			for z: int in range(c0.z, c1.z + 1):
				keys.append(_vol_cell_key(Vector3i(x, y, z)))
	return keys


static func _vol_grid_insert_id(id: int, center: Vector3, bound: float) -> void:
	var keys := _vol_cell_keys_for_aabb(center, bound)
	_vol_grid_cells_by_id[id] = keys
	for key: String in keys:
		var bucket: Array = _vol_grid.get(key, [])
		bucket.append(id)
		_vol_grid[key] = bucket


static func _vol_grid_remove_id(id: int) -> void:
	if not _vol_grid_cells_by_id.has(id):
		return
	var keys: Array = _vol_grid_cells_by_id[id]
	for key: Variant in keys:
		var bucket: Array = _vol_grid.get(key, [])
		var pos := bucket.find(id)
		if pos >= 0:
			bucket.remove_at(pos)
		if bucket.is_empty():
			_vol_grid.erase(key)
		else:
			_vol_grid[key] = bucket
	_vol_grid_cells_by_id.erase(id)


static func _vol_grid_candidates(from: Vector3, to: Vector3, pad: float) -> Array[int]:
	if _registered_ids.is_empty():
		return []
	_ensure_vol_grid()
	var pad_v := Vector3.ONE * pad
	var bmin := from.min(to) - pad_v
	var bmax := from.max(to) + pad_v
	var c0 := _vol_cell_coord(bmin)
	var c1 := _vol_cell_coord(bmax)
	var seen: Dictionary = {}
	var out: Array[int] = []
	for x: int in range(c0.x, c1.x + 1):
		for y: int in range(c0.y, c1.y + 1):
			for z: int in range(c0.z, c1.z + 1):
				var bucket: Array = _vol_grid.get(_vol_cell_key(Vector3i(x, y, z)), [])
				for id: Variant in bucket:
					var vid: int = int(id)
					if seen.has(vid):
						continue
					seen[vid] = true
					out.append(vid)
	return out


static func _sort_candidates_by_ray_t(from: Vector3, seg_dir: Vector3, candidates: Array[int]) -> void:
	if candidates.size() < 2:
		return
	candidates.sort_custom(func(a: int, b: int) -> bool:
		var ia: int = int(_registered_index_by_id.get(a, -1))
		var ib: int = int(_registered_index_by_id.get(b, -1))
		if ia < 0 or ib < 0:
			return a < b
		var ta: float = (_registered_centers[ia] - from).dot(seg_dir)
		var tb: float = (_registered_centers[ib] - from).dot(seg_dir)
		return ta < tb
	)


static func _ensure_vol_grid() -> void:
	if not _vol_grid.is_empty():
		return
	var i := 0
	while i < _registered_ids.size():
		var id: int = _registered_ids[i]
		_vol_grid_insert_id(id, _registered_centers[i], _registered_bounds[i])
		i += 1


static func _rid_in(rid: RID, arr: Array[RID]) -> bool:
	for existing: RID in arr:
		if existing == rid:
			return true
	return false


static func _segment_may_hit_volume(from: Vector3, to: Vector3, center: Vector3, bound: float) -> bool:
	var seg := to - from
	var seg_len_sq := seg.length_squared()
	var reach := bound + 0.05
	if seg_len_sq < 1e-8:
		return from.distance_squared_to(center) <= reach * reach
	var t := clampf((center - from).dot(seg) / seg_len_sq, 0.0, 1.0)
	var closest := from + seg * t
	return closest.distance_squared_to(center) <= reach * reach
