extends Node3D

# Client-side stress bench for the case that hurt on Windows: a remote player
# firing a minigun stream past the local camera. Unlike perf_benchmark.tscn,
# this intentionally keeps a visible camera/listener and drives the remote
# _rifle_fired path directly, so muzzle flashes, shot audio, bullet visuals,
# zip audio, and third-person casings show up in the samples.
#
# Run visible for render/client cost:
#   godot --path /Users/joep/dev/growing-guns res://scenes/remote_minigun_benchmark.tscn -- build=minigun
#
# Useful isolation modes:
#   mode=no_bullets
#   mode=no_bullet_visuals
#   mode=no_zips
#   mode=no_shot_audio
#   mode=no_muzzle_flash
#   mode=no_casings
#   mode=no_explosion_visuals
#   mode=no_explosion_audio
#   mode=no_explosion_audio_or_visuals

const PLAYER_SCENE := preload("res://scenes/player.tscn")
const SHOOTER_ID := 9001
const WARMUP_SEC := 2.0
const MEASURE_SEC := 12.0

var bench_mode: String = "baseline"
var build: Array[String] = ["minigun"]
var local_player: Node3D = null
var state: int = 1

var ev_bullets_spawned: int = 0
var ev_collisions: int = 0
var ev_explosions: int = 0
var ev_casings_spawned: int = 0

var _camera: Camera3D = null
var _shooter: Node = null
var _weapon: Weapon = null
var _fire_accum: float = 0.0
var _start_t: float = 0.0
var _phase := "warmup"

var _frame_ms: Array[float] = []
var _physics_ms: Array[float] = []
var _draw_calls: Array[int] = []
var _drawn_objects: Array[int] = []
var _active_rb: Array[int] = []
var _node_count: Array[int] = []
var _resource_count: Array[int] = []
var _projectile_count: Array[int] = []
var _audio_players: Array[int] = []
var _peak_static_mem: int = 0
var _shots_triggered: int = 0


func _ready() -> void:
	_parse_cli_args()
	BenchFlags.active = true
	BenchFlags.event_sink = self
	print("[remote-minigun-bench] mode=%s build=%s warmup=%.1fs measure=%.1fs" % [
		bench_mode,
		str(build),
		WARMUP_SEC,
		MEASURE_SEC,
	])
	_build_world()
	_spawn_remote_shooter()
	_start_t = Time.get_ticks_msec() / 1000.0


func _parse_cli_args() -> void:
	BenchFlags.no_casings = false
	BenchFlags.no_bullets = false
	BenchFlags.no_bullet_visuals = false
	BenchFlags.no_bullet_zips = false
	BenchFlags.no_shot_audio = false
	BenchFlags.no_muzzle_flash = false
	BenchFlags.no_explosion_audio = false
	BenchFlags.no_explosion_visuals = false
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("mode="):
			bench_mode = arg.substr(5)
		elif arg.begins_with("build="):
			build = []
			for cid in arg.substr(6).split(",", false):
				var trimmed := cid.strip_edges()
				if not trimmed.is_empty():
					build.append(trimmed)
	match bench_mode:
		"no_casings":
			BenchFlags.no_casings = true
		"no_bullets":
			BenchFlags.no_bullets = true
		"no_bullet_visuals":
			BenchFlags.no_bullet_visuals = true
		"no_zips", "no_bullet_zips":
			BenchFlags.no_bullet_zips = true
		"no_shot_audio":
			BenchFlags.no_shot_audio = true
		"no_muzzle_flash":
			BenchFlags.no_muzzle_flash = true
		"no_explosion_visuals":
			BenchFlags.no_explosion_visuals = true
		"no_explosion_audio":
			BenchFlags.no_explosion_audio = true
		"no_explosion_audio_or_visuals":
			BenchFlags.no_explosion_visuals = true
			BenchFlags.no_explosion_audio = true


func _build_world() -> void:
	var players_root := Node3D.new()
	players_root.name = "Players"
	add_child(players_root)

	_camera = Camera3D.new()
	_camera.name = "BenchCamera"
	_camera.fov = 75.0
	_camera.position = Vector3(0.0, 1.6, 0.0)
	_camera.rotation_degrees = Vector3.ZERO
	add_child(_camera)
	_camera.make_current()

	var listener := AudioListener3D.new()
	_camera.add_child(listener)
	listener.make_current()

	# Simple collision backstop so some bullets hit eventually while many pass
	# close enough to the camera to exercise near-miss zip audio first.
	var wall := StaticBody3D.new()
	wall.name = "Backstop"
	wall.collision_layer = 1
	wall.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(30.0, 12.0, 0.3)
	shape.shape = box
	wall.add_child(shape)
	wall.position = Vector3(0.0, 3.0, 45.0)
	add_child(wall)


func _spawn_remote_shooter() -> void:
	var players_root: Node = $Players
	_shooter = PLAYER_SCENE.instantiate()
	_shooter.name = str(SHOOTER_ID)
	_shooter.set("player_id", SHOOTER_ID)
	_shooter.set("player_name", "Remote Minigun")
	_shooter.position = Vector3(0.0, 1.0, -10.0)
	players_root.add_child(_shooter)
	await get_tree().process_frame
	for cid in build:
		if _shooter.has_method("apply_card"):
			_shooter.call("apply_card", cid)
	_weapon = _shooter.get("weapon")
	print("[remote-minigun-bench] shots_per_trigger=%d fire_interval=%.4f projectiles_per_sec=%.1f damage=%.2f" % [
		_weapon.get_shots_per_trigger(),
		_weapon.get_fire_interval(),
		_weapon.get_projectiles_per_second(),
		_weapon.get_damage(),
	])


func _physics_process(delta: float) -> void:
	if _phase == "done" or _shooter == null or _weapon == null:
		return
	_fire_accum += delta
	var interval: float = _weapon.get_fire_interval()
	if _fire_accum >= interval:
		_fire_accum = 0.0
		_fire_remote_trigger()


func _fire_remote_trigger() -> void:
	var origin := Vector3(0.0, 1.55, -8.8)
	var shots := _weapon.get_shots_per_trigger()
	for i in shots:
		var x_offset := randf_range(-5.0, 5.0)
		var y_offset := randf_range(-2.1, 2.1)
		# Aim through a plane around the local camera, not directly at it.
		# This creates lots of near misses without constantly damaging a player.
		var aim := Vector3(x_offset, 1.6 + y_offset, 3.0)
		var dir := (aim - origin).normalized()
		_shooter.call("_rifle_fired", origin, dir, SHOOTER_ID, false)
	_shots_triggered += 1


func _process(_delta: float) -> void:
	var t := Time.get_ticks_msec() / 1000.0 - _start_t
	match _phase:
		"warmup":
			if t >= WARMUP_SEC:
				_phase = "measure"
				_clear_samples()
				print("[remote-minigun-bench] warmup done")
		"measure":
			_capture_sample()
			if t >= WARMUP_SEC + MEASURE_SEC:
				_phase = "done"
				_dump_results()
				get_tree().quit()


func _bench_inc(kind: String) -> void:
	if _phase != "measure":
		return
	match kind:
		"bullets_spawned": ev_bullets_spawned += 1
		"collisions": ev_collisions += 1
		"explosions": ev_explosions += 1
		"casings_spawned": ev_casings_spawned += 1


func _clear_samples() -> void:
	ev_bullets_spawned = 0
	ev_collisions = 0
	ev_explosions = 0
	ev_casings_spawned = 0
	_frame_ms.clear()
	_physics_ms.clear()
	_draw_calls.clear()
	_drawn_objects.clear()
	_active_rb.clear()
	_node_count.clear()
	_resource_count.clear()
	_projectile_count.clear()
	_audio_players.clear()
	_peak_static_mem = 0
	_shots_triggered = 0


func _capture_sample() -> void:
	_frame_ms.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	_physics_ms.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	_draw_calls.append(int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)))
	_drawn_objects.append(int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)))
	_active_rb.append(int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS)))
	_node_count.append(int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)))
	_resource_count.append(int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)))
	_projectile_count.append(get_tree().get_nodes_in_group("projectiles").size())
	_audio_players.append(_count_audio_players(self))
	var mem := int(Performance.get_monitor(Performance.MEMORY_STATIC))
	if mem > _peak_static_mem:
		_peak_static_mem = mem


func _count_audio_players(root: Node) -> int:
	var count := 0
	for child in root.get_children():
		if child is AudioStreamPlayer or child is AudioStreamPlayer3D:
			count += 1
		count += _count_audio_players(child)
	return count


func _dump_results() -> void:
	var fps_mean: float = 1000.0 / _mean(_frame_ms) if _mean(_frame_ms) > 0.0 else 0.0
	print("\n====== REMOTE MINIGUN BENCH ======")
	print("Mode:                   %s" % bench_mode)
	print("Build:                  %s" % str(build))
	print("Samples:                %d frames over %.1f s" % [_frame_ms.size(), MEASURE_SEC])
	print("FPS (from mean frame):  %6.1f" % fps_mean)
	print("Trigger pulls/sec:      %4d" % int(_shots_triggered / MEASURE_SEC))
	print("Event rates/sec:        bullets=%4d collisions=%4d casings=%4d" % [
		int(ev_bullets_spawned / MEASURE_SEC),
		int(ev_collisions / MEASURE_SEC),
		int(ev_casings_spawned / MEASURE_SEC),
	])
	_print_row("frame_ms", _stats(_frame_ms))
	_print_row("physics_ms", _stats(_physics_ms))
	_print_irow("draw_calls", _istats(_draw_calls))
	_print_irow("drawn_objects", _istats(_drawn_objects))
	_print_irow("active_rigid_bodies", _istats(_active_rb))
	_print_irow("projectiles", _istats(_projectile_count))
	_print_irow("audio_players", _istats(_audio_players))
	_print_irow("node_count", _istats(_node_count))
	print("Peak static mem (MB):   %.1f" % (float(_peak_static_mem) / (1024.0 * 1024.0)))
	print("==================================\n")
	var summary := {
		"mode": bench_mode,
		"build": build,
		"frame_ms": _stats(_frame_ms),
		"physics_ms": _stats(_physics_ms),
		"draw_calls": _istats(_draw_calls),
		"drawn_objects": _istats(_drawn_objects),
		"projectiles": _istats(_projectile_count),
		"audio_players": _istats(_audio_players),
		"node_count": _istats(_node_count),
		"bullets_per_sec": int(ev_bullets_spawned / MEASURE_SEC),
		"casings_per_sec": int(ev_casings_spawned / MEASURE_SEC),
	}
	var f := FileAccess.open("/tmp/remote_minigun_bench_%s.json" % bench_mode, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(summary, "  "))
		f.close()


func _print_row(label: String, s: Dictionary) -> void:
	print("%-22s mean=%7.3f p50=%7.3f p95=%7.3f max=%7.3f" % [
		label, s.mean, s.p50, s.p95, s.max])


func _print_irow(label: String, s: Dictionary) -> void:
	print("%-22s mean=%7d p50=%7d p95=%7d max=%7d" % [
		label, s.mean, s.p50, s.p95, s.max])


func _stats(arr: Array) -> Dictionary:
	if arr.is_empty():
		return {"mean": 0.0, "p50": 0.0, "p95": 0.0, "max": 0.0}
	var sorted := arr.duplicate()
	sorted.sort()
	return {
		"mean": _mean(arr),
		"p50": float(sorted[int(sorted.size() * 0.50)]),
		"p95": float(sorted[int(sorted.size() * 0.95)]),
		"max": float(sorted[sorted.size() - 1]),
	}


func _istats(arr: Array) -> Dictionary:
	if arr.is_empty():
		return {"mean": 0, "p50": 0, "p95": 0, "max": 0}
	var sorted := arr.duplicate()
	sorted.sort()
	var sum := 0
	for v in arr:
		sum += int(v)
	return {
		"mean": int(sum / arr.size()),
		"p50": int(sorted[int(sorted.size() * 0.50)]),
		"p95": int(sorted[int(sorted.size() * 0.95)]),
		"max": int(sorted[sorted.size() - 1]),
	}


func _mean(arr: Array) -> float:
	if arr.is_empty():
		return 0.0
	var sum := 0.0
	for v in arr:
		sum += float(v)
	return sum / float(arr.size())
