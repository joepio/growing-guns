extends Node3D

# Wraps an ArenaGenerator with a WorldEnvironment + sun + fill light so it
# slots into game.gd's MAP_POOL the same way the hand-built arena scenes do.
#
# game.gd calls apply_seed(seed) right after add_child() — that's the only
# entry point. The generator regenerates synchronously, then we copy the
# matching palette into our environment + lights so the atmosphere matches.

@onready var generator: Node3D = $Generator
@onready var world_env: WorldEnvironment = $WorldEnvironment
@onready var sun: DirectionalLight3D = $Sun
@onready var fill_light: OmniLight3D = $FillLight

const LAVA_TICK_SECONDS := 0.5
const LAVA_TICK_DAMAGE := 15
const LAVA_WALL_FLOW_SECONDS := 4.0
const LAVA_WALL_HAZARD_WIDTH := 1.25
const LAVA_FLOOR_Y := 0.09
const LAVA_RISE_SPEED := 1.5
const LAVA_MAX_RISE := 18.0

var _lava_leak_active := false
var _lava_leak_elapsed := 0.0
var _lava_leak_duration := 20.0
var _lava_floor_elapsed := 0.0
var _lava_rise_height := 0.0
var _lava_has_walls := false
var _lava_floor_already_full := false
var _lava_arena_half := 40.0
var _lava_inset := 0.0
var _lava_fronts: Array[MeshInstance3D] = []
var _lava_front_meshes: Array[BoxMesh] = []
var _lava_walls: Array[MeshInstance3D] = []
var _lava_wall_meshes: Array[BoxMesh] = []
var _lava_damage_accum_by_player: Dictionary = {}


func _ready() -> void:
	# Listen so a manual change to generator.seed (e.g. in editor) still
	# updates the atmosphere. game.gd's apply_seed path also goes through here.
	if not generator.regenerated.is_connected(_on_regenerated):
		generator.regenerated.connect(_on_regenerated)
	# Pre-populate with a default-seed arena so spawnpoints exist before
	# game.gd's first _swap_arena fires. Without this, players who join
	# during the WAITING state (or between rounds, where there's a brief
	# window mid-swap) fall through _pick_spawn's "no spawnpoints" fallback
	# and end up outside the arena bounds. The first real round start will
	# overwrite this with the proper seed via apply_seed().
	apply_seed(0)


func _process(delta: float) -> void:
	if not _lava_leak_active:
		return
	_lava_leak_elapsed += delta
	var wall_seconds := LAVA_WALL_FLOW_SECONDS if _lava_has_walls else 0.0
	var wall_t := clampf(_lava_leak_elapsed / maxf(0.01, wall_seconds), 0.0, 1.0) if wall_seconds > 0.0 else 1.0
	_lava_floor_elapsed = maxf(0.0, _lava_leak_elapsed - wall_seconds)
	var floor_duration := maxf(0.1, _lava_leak_duration - wall_seconds)
	var floor_t := clampf(_lava_floor_elapsed / floor_duration, 0.0, 1.0)
	if _lava_floor_already_full:
		_lava_floor_elapsed = _lava_leak_duration
		floor_t = 1.0
	if _lava_has_walls and wall_t >= 1.0 and floor_t <= 0.0:
		floor_t = 0.001
	var eased_floor := floor_t * floor_t * (3.0 - 2.0 * floor_t)
	_lava_inset = lerpf(0.0, _lava_arena_half, eased_floor)
	if floor_t >= 1.0:
		_lava_rise_height = minf(LAVA_MAX_RISE, _lava_rise_height + delta * LAVA_RISE_SPEED)
	_update_lava_leak_visuals(wall_t, floor_t)
	_apply_lava_leak_damage(delta)


func apply_seed(s: int, size_min: float = -1.0, size_max: float = -1.0) -> void:
	# Set seed first so palette lookup uses the new value, then regenerate
	# synchronously so spawnpoints exist before the caller queries them.
	stop_lava_leak()
	if size_min >= 0.0 and size_max >= 0.0:
		generator.arena_size_min = size_min
		generator.arena_size_max = size_max
	else:
		generator.arena_size_min = 55.0
		generator.arena_size_max = 95.0
	generator.seed = s
	generator.regenerate()


func _on_regenerated(_stats: Dictionary) -> void:
	if generator and generator.has_method("apply_palette_to_environment"):
		generator.apply_palette_to_environment(world_env.environment, sun, fill_light)


func is_all_floor_lava() -> bool:
	if generator and generator.has_method("is_all_floor_lava"):
		return bool(generator.is_all_floor_lava())
	var stats: Dictionary = generator.get("last_stats") if generator else {}
	return bool(stats.get("all_floor_lava", false))


func is_lava_spawn_safe(world_pos: Vector3) -> bool:
	if generator and generator.has_method("is_lava_spawn_safe"):
		return bool(generator.is_lava_spawn_safe(world_pos))
	return true


func get_lava_fallback_spawn_world() -> Vector3:
	if generator and generator.has_method("get_lava_fallback_spawn_world"):
		return generator.get_lava_fallback_spawn_world()
	return global_position + Vector3(0.0, 5.0, 0.0)


func start_lava_leak(spread_seconds: float = 20.0, start_elapsed: float = 0.0) -> void:
	stop_lava_leak()
	_lava_leak_duration = maxf(0.1, spread_seconds)
	_lava_leak_elapsed = maxf(0.0, start_elapsed)
	_lava_floor_elapsed = 0.0
	_lava_rise_height = 0.0
	var arena_size: float = float(generator.get("arena_size")) if generator else 80.0
	_lava_arena_half = arena_size * 0.5
	var stats: Dictionary = generator.get("last_stats") if generator else {}
	_lava_floor_already_full = bool(stats.get("all_floor_lava", false))
	_lava_has_walls = (not _lava_floor_already_full) and not bool(stats.get("no_walls", false))
	_lava_inset = _lava_arena_half if _lava_floor_already_full else 0.0
	_build_lava_leak_nodes()
	_lava_leak_active = true
	if start_elapsed > 0.0:
		var wall_seconds := LAVA_WALL_FLOW_SECONDS if _lava_has_walls else 0.0
		_lava_floor_elapsed = maxf(0.0, _lava_leak_elapsed - wall_seconds)
		var floor_duration := maxf(0.1, _lava_leak_duration - wall_seconds)
		var floor_t := clampf(_lava_floor_elapsed / floor_duration, 0.0, 1.0)
		if _lava_floor_already_full:
			floor_t = 1.0
		var eased_floor := floor_t * floor_t * (3.0 - 2.0 * floor_t)
		_lava_inset = lerpf(0.0, _lava_arena_half, eased_floor)
		if floor_t >= 1.0:
			_lava_rise_height = minf(LAVA_MAX_RISE, maxf(0.0, _lava_floor_elapsed - floor_duration) * LAVA_RISE_SPEED)
		var wall_t := clampf(_lava_leak_elapsed / maxf(0.01, wall_seconds), 0.0, 1.0) if wall_seconds > 0.0 else 1.0
		_update_lava_leak_visuals(wall_t, floor_t)
	else:
		_update_lava_leak_visuals(1.0, 1.0 if _lava_floor_already_full else 0.0)


func stop_lava_leak() -> void:
	_lava_leak_active = false
	_lava_floor_already_full = false
	for n in _lava_fronts:
		if n and is_instance_valid(n):
			n.queue_free()
	for n in _lava_walls:
		if n and is_instance_valid(n):
			n.queue_free()
	_lava_fronts.clear()
	_lava_front_meshes.clear()
	_lava_walls.clear()
	_lava_wall_meshes.clear()
	_lava_damage_accum_by_player.clear()


func _build_lava_leak_nodes() -> void:
	var floor_mat := _make_lava_material()
	_build_lava_front("NorthLavaFront", floor_mat)
	_build_lava_front("SouthLavaFront", floor_mat)
	_build_lava_front("WestLavaFront", floor_mat)
	_build_lava_front("EastLavaFront", floor_mat)

	if _lava_has_walls:
		var wall_mat := _make_lava_material()
		_build_lava_wall(true, -1.0, wall_mat)
		_build_lava_wall(true, 1.0, wall_mat)
		_build_lava_wall(false, -1.0, wall_mat)
		_build_lava_wall(false, 1.0, wall_mat)


func _build_lava_front(front_name: String, mat: ShaderMaterial) -> void:
	var mi := MeshInstance3D.new()
	mi.name = front_name
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.01, 0.045, 0.01)
	mi.mesh = mesh
	mi.material_override = mat
	add_child(mi)
	_lava_fronts.append(mi)
	_lava_front_meshes.append(mesh)


func _build_lava_wall(along_z: bool, side_sign: float, mat: ShaderMaterial) -> void:
	var mi := MeshInstance3D.new()
	mi.name = "LavaWallFlow"
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.35, 0.1, 0.35)
	mi.mesh = mesh
	mi.material_override = mat
	add_child(mi)
	mi.set_meta("along_z", along_z)
	mi.set_meta("side_sign", side_sign)
	_lava_walls.append(mi)
	_lava_wall_meshes.append(mesh)


func _update_lava_leak_visuals(wall_t: float, floor_t: float) -> void:
	_update_lava_front_visuals(floor_t)
	if not _lava_has_walls:
		return
	var wall_h := float(generator.get("wall_height")) if generator else 12.0
	var height := lerpf(0.05, wall_h, wall_t)
	var y := wall_h - height * 0.5
	for i in _lava_walls.size():
		var wall := _lava_walls[i]
		var mesh := _lava_wall_meshes[i]
		var along_z := bool(wall.get_meta("along_z"))
		var side_sign := float(wall.get_meta("side_sign"))
		if along_z:
			mesh.size = Vector3(0.45, height, _lava_arena_half * 2.0)
			wall.position = Vector3(side_sign * (_lava_arena_half - 0.62), y, 0.0)
		else:
			mesh.size = Vector3(_lava_arena_half * 2.0, height, 0.45)
			wall.position = Vector3(0.0, y, side_sign * (_lava_arena_half - 0.62))


func _update_lava_front_visuals(floor_t: float) -> void:
	if _lava_floor_already_full:
		for front in _lava_fronts:
			front.visible = false
		return
	var visible := floor_t > 0.0 or not _lava_has_walls
	var h := _lava_arena_half
	var i := clampf(maxf(_lava_inset, 0.08 if visible else 0.0), 0.0, h)
	var side_len := h * 2.0
	var center_len := maxf(0.0, side_len - i * 2.0)
	var lava_y := LAVA_FLOOR_Y + _lava_rise_height
	for front in _lava_fronts:
		front.visible = visible
	if _lava_fronts.size() < 4:
		return
	_set_front_rect(0, Vector3(0.0, lava_y, -h + i * 0.5), Vector3(side_len, 0.045, i))
	_set_front_rect(1, Vector3(0.0, lava_y, h - i * 0.5), Vector3(side_len, 0.045, i))
	_set_front_rect(2, Vector3(-h + i * 0.5, lava_y, 0.0), Vector3(i, 0.045, center_len))
	_set_front_rect(3, Vector3(h - i * 0.5, lava_y, 0.0), Vector3(i, 0.045, center_len))


func _set_front_rect(index: int, pos: Vector3, size: Vector3) -> void:
	var front := _lava_fronts[index]
	var mesh := _lava_front_meshes[index]
	front.visible = front.visible and size.x > 0.01 and size.z > 0.01
	mesh.size = Vector3(maxf(0.01, size.x), size.y, maxf(0.01, size.z))
	front.position = pos


func _apply_lava_leak_damage(delta: float) -> void:
	var lava_y := global_position.y + LAVA_FLOOR_Y + _lava_rise_height
	var wall_seconds := LAVA_WALL_FLOW_SECONDS if _lava_has_walls else 0.0
	var wall_t := clampf(_lava_leak_elapsed / maxf(0.01, wall_seconds), 0.0, 1.0) if wall_seconds > 0.0 else 1.0
	var floor_active := _lava_floor_elapsed > 0.0 or (not _lava_has_walls) or wall_t >= 1.0
	var wall_h := float(generator.get("wall_height")) if generator else 12.0
	var wall_height := lerpf(0.05, wall_h, wall_t)
	var active_ids: Dictionary = {}
	for p: Node in get_tree().get_nodes_in_group("players"):
		if not p is Node3D or not p.is_multiplayer_authority():
			continue
		var pid := int(p.get("player_id")) if p.get("player_id") != null else p.get_instance_id()
		var p3 := p as Node3D
		if p3.global_position.y < lava_y:
			_lava_damage_accum_by_player.erase(pid)
			if p.has_method("kill_environmental"):
				p.kill_environmental("lava_fall")
			continue
		var clearance := 1.15 if _lava_floor_already_full else 2.4
		if p3.global_position.y > lava_y + clearance:
			_lava_damage_accum_by_player.erase(pid)
			continue
		var pos_xz := Vector2(p3.global_position.x, p3.global_position.z)
		var in_floor_lava := floor_active and _point_in_floor_lava(pos_xz)
		var in_wall_lava := _lava_has_walls and _point_touching_lava_wall(pos_xz, p3.global_position.y, wall_height, wall_h)
		if not in_floor_lava and not in_wall_lava:
			_lava_damage_accum_by_player.erase(pid)
			continue
		active_ids[pid] = true
		var accum := float(_lava_damage_accum_by_player.get(pid, 0.0)) + delta
		while accum >= LAVA_TICK_SECONDS:
			accum -= LAVA_TICK_SECONDS
			if p.has_method("apply_environmental_damage"):
				p.apply_environmental_damage(LAVA_TICK_DAMAGE, "lava")
		_lava_damage_accum_by_player[pid] = accum
	for raw_id in _lava_damage_accum_by_player.keys():
		if not active_ids.has(raw_id):
			_lava_damage_accum_by_player.erase(raw_id)


func _point_in_floor_lava(world_xz: Vector2) -> bool:
	var local := world_xz - Vector2(global_position.x, global_position.z)
	var safe_half := maxf(0.0, _lava_arena_half - _lava_inset)
	return absf(local.x) > safe_half or absf(local.y) > safe_half


func _point_touching_lava_wall(world_xz: Vector2, world_y: float, wall_lava_height: float, wall_height: float) -> bool:
	var local_y := world_y - global_position.y
	if local_y < wall_height - wall_lava_height - 0.8 or local_y > wall_height + 0.8:
		return false
	var local := world_xz - Vector2(global_position.x, global_position.z)
	var near_x_wall := absf(absf(local.x) - _lava_arena_half) <= LAVA_WALL_HAZARD_WIDTH \
		and absf(local.y) <= _lava_arena_half
	var near_z_wall := absf(absf(local.y) - _lava_arena_half) <= LAVA_WALL_HAZARD_WIDTH \
		and absf(local.x) <= _lava_arena_half
	return near_x_wall or near_z_wall


func _make_lava_material() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = ArenaGenerator.LAVA_SHADER_CODE
	var mat := ShaderMaterial.new()
	mat.shader = sh
	return mat
