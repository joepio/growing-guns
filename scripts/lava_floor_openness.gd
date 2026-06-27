class_name LavaFloorOpenness
extends Node

# Drives the lava omni glow from how open each floor column is (blocks between
# lava and the walk surface). Chunk removals mark columns dirty; a short upward
# ray through each dirty cell measures remaining cover.

const CELL := 2.8
const RAY_TOP_Y := 1.35
const MAX_DIRTY_RAYS_PER_FRAME := 28

var _generator: Node3D
var _lava_y: float = -3.0
var _arena_half: float = 40.0
var _max_energy: float = 5.5
var _omni_range: float = 60.0
var _light: OmniLight3D
var _cell_block: Dictionary = {}  # Vector2i -> 0..1 sealed fraction
var _dirty: Array[Vector2i] = []
var _dirty_set: Dictionary = {}


func setup(
	generator: Node3D,
	lava_local_y: float,
	arena_size: float,
	max_energy: float,
	omni_range: float,
) -> void:
	_generator = generator
	_lava_y = lava_local_y
	_arena_half = arena_size * 0.5
	_max_energy = max_energy
	_omni_range = omni_range
	_cell_block.clear()
	_dirty.clear()
	_dirty_set.clear()

	if _light == null or not is_instance_valid(_light):
		_light = OmniLight3D.new()
		_light.name = "LavaGlow"
		_light.light_color = Color(1.0, 0.42, 0.12)
		_light.omni_attenuation = 0.65
		_light.shadow_enabled = false
		add_child(_light)
	_light.position = Vector3(0.0, _lava_y + 0.6, 0.0)
	_light.omni_range = _omni_range
	_light.light_energy = 0.0
	set_process(true)
	call_deferred("_seed_column_grid")


func get_ratio() -> float:
	if _cell_block.is_empty():
		return 0.0
	var sum := 0.0
	for block: Variant in _cell_block.values():
		sum += 1.0 - clampf(float(block), 0.0, 1.0)
	return sum / float(_cell_block.size())


func notify_chunks_removed(_body: Node, cols: Array) -> void:
	for col: Variant in cols:
		if col is CollisionShape3D:
			_mark_chunk_cells(col as CollisionShape3D, _body as Node3D)


func _seed_column_grid() -> void:
	var min_cell := _cell_of(Vector3(-_arena_half, 0.0, -_arena_half))
	var max_cell := _cell_of(Vector3(_arena_half, 0.0, _arena_half))
	for x: int in range(min_cell.x, max_cell.x + 1):
		for z: int in range(min_cell.y, max_cell.y + 1):
			_mark_dirty(Vector2i(x, z))
	_apply_light()


func _process(_delta: float) -> void:
	if _dirty.is_empty():
		return
	var n := mini(MAX_DIRTY_RAYS_PER_FRAME, _dirty.size())
	for _i: int in n:
		var cell: Vector2i = _dirty.pop_front()
		_dirty_set.erase(cell)
		_resample_cell(cell)
	_apply_light()


func _mark_chunk_cells(col: CollisionShape3D, body: Node3D) -> void:
	if body == null:
		return
	var center: Vector3 = body.to_global(col.get_meta("chunk_center_local") as Vector3)
	var size: Vector3 = col.get_meta("chunk_size") as Vector3
	var local := _generator.to_local(center)
	var half := size * 0.5
	var min_c := _cell_of(local - Vector3(half.x, 0.0, half.z))
	var max_c := _cell_of(local + Vector3(half.x, 0.0, half.z))
	for x: int in range(min_c.x, max_c.x + 1):
		for z: int in range(min_c.y, max_c.y + 1):
			_mark_dirty(Vector2i(x, z))


func _mark_dirty(cell: Vector2i) -> void:
	if _dirty_set.has(cell):
		return
	_dirty_set[cell] = true
	_dirty.append(cell)


func _resample_cell(cell: Vector2i) -> void:
	_cell_block[cell] = _measure_column_block(cell)


func _measure_column_block(cell: Vector2i) -> float:
	var space := _generator.get_world_3d().direct_space_state if _generator else null
	if space == null:
		return 1.0
	var cx := (float(cell.x) + 0.5) * CELL
	var cz := (float(cell.y) + 0.5) * CELL
	var from := _generator.global_transform * Vector3(cx, _lava_y + 0.18, cz)
	var to := _generator.global_transform * Vector3(cx, RAY_TOP_Y, cz)
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 1
	query.hit_from_inside = true
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return 0.0
	var collider: Object = hit.get("collider")
	if collider is Node and _is_lava_floor_collider(collider as Node):
		var hit_local := _generator.to_local(hit.position as Vector3)
		var span := maxf(0.05, RAY_TOP_Y - _lava_y)
		return clampf((hit_local.y - _lava_y) / span, 0.0, 1.0)
	return 1.0


func _is_lava_floor_collider(node: Node) -> bool:
	var cur: Node = node
	while cur != null:
		if cur.is_in_group("lava_floor"):
			return true
		cur = cur.get_parent()
	return false


func _cell_of(local: Vector3) -> Vector2i:
	return Vector2i(floori(local.x / CELL), floori(local.z / CELL))


func _apply_light() -> void:
	if _light == null:
		return
	var ratio := get_ratio()
	_light.light_energy = _max_energy * pow(ratio, 0.72)
