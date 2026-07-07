extends Node3D

# Headless stress bench: sustained destructible blasts + debris at N/sec.
#
# Run:
#   godot --headless --path /Users/joep/dev/growing-guns res://scenes/destruction_stress_bench.tscn

const ARENA_SCENE := preload("res://scenes/arena_procedural.tscn")
const DestructibleManager = preload("res://scripts/destructible_manager.gd")

const DEFAULT_SEED := 0xDEAD10
const JSON_PATH := "/tmp/godot_destruction_stress_bench.json"
const RATES := [0.0, 20.0, 50.0, 100.0, 200.0, 400.0]
const WARMUP_SEC := 1.5
const SAMPLE_SEC := 2.0

var bench_seed: int = DEFAULT_SEED
var blast_radius: float = 4.5
var blast_damage: float = 120.0

var _arena: Node3D = null
var _blast_targets: Array[Vector3] = []
var _stage := 0
var _phase := "warmup"
var _t := 0.0
var _stress_accum := 0.0
var _blasts_this_sec := 0
var _blast_count_sec := 0.0
var _blasts_per_sec := 0.0

var _frame_ms: Array[float] = []
var _physics_ms: Array[float] = []
var _debris_nodes: Array[int] = []
var _debris_queue: Array[int] = []
var _results: Array[Dictionary] = []


func _ready() -> void:
	BenchFlags.active = true
	_parse_cli_args()
	print("[destruction-stress-bench] seed=%x radius=%.1f" % [bench_seed, blast_radius])
	_arena = ARENA_SCENE.instantiate()
	_arena.name = "Arena"
	add_child(_arena)
	if _arena.has_method("apply_seed"):
		_arena.call("apply_seed", bench_seed)
	for _i in 30:
		await get_tree().physics_frame
		DestructibleManager.flush()
	_collect_blast_targets()
	print("[destruction-stress-bench] targets=%d" % _blast_targets.size())
	_phase = "warmup"
	_t = 0.0


func _parse_cli_args() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("seed="):
			bench_seed = int(arg.substr(5))
		elif arg.begins_with("blast_radius="):
			blast_radius = maxf(0.5, float(arg.substr(13)))
		elif arg.begins_with("blast_damage="):
			blast_damage = maxf(1.0, float(arg.substr(13)))


func _physics_process(delta: float) -> void:
	if _stage >= RATES.size():
		return
	var rate: float = RATES[_stage]
	_t += delta
	if rate > 0.0:
		_stress_accum += delta * rate
		while _stress_accum >= 1.0:
			_stress_accum -= 1.0
			_fire_blast()
			_blasts_this_sec += 1
	_blast_count_sec += delta
	if _blast_count_sec >= 1.0:
		_blast_count_sec -= 1.0
		_blasts_per_sec = float(_blasts_this_sec)
		_blasts_this_sec = 0
	if _phase == "warmup":
		if _t >= WARMUP_SEC:
			_phase = "sample"
			_t = 0.0
			_frame_ms.clear()
			_physics_ms.clear()
			_debris_nodes.clear()
			_debris_queue.clear()
			GpuDebris.reset_debug_counters()
			DestructibleManager.reset_chunk_removals()
		return
	_frame_ms.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	_physics_ms.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	_debris_nodes.append(_count_group("destruction_debris"))
	_debris_queue.append(GpuDebris.debug_live_particles())
	if _t >= SAMPLE_SEC:
		_record_stage(rate)
		_stage += 1
		if _stage >= RATES.size():
			_dump_results()
			get_tree().quit()
			return
		_phase = "warmup"
		_t = 0.0
		_stress_accum = 0.0
		GpuDebris.reset_debug_counters()


func _collect_blast_targets() -> void:
	_blast_targets.clear()
	for node: Node in get_tree().get_nodes_in_group("destructible"):
		if not node is Node3D:
			continue
		var body := node as Node3D
		var center := body.global_position
		_blast_targets.append(center)
		_blast_targets.append(center + Vector3(0.0, 1.2, 0.0))
		_blast_targets.append(center + Vector3(randf_range(-1.5, 1.5), 0.5, randf_range(-1.5, 1.5)))
	if _blast_targets.is_empty():
		_blast_targets.append(Vector3.ZERO)


func _fire_blast() -> void:
	var pos: Vector3 = _blast_targets[randi() % _blast_targets.size()]
	pos += Vector3(
		randf_range(-0.8, 0.8),
		randf_range(-0.4, 0.8),
		randf_range(-0.8, 0.8),
	)
	DestructibleManager.apply_blast(pos, blast_radius, blast_damage)


func _count_group(group_name: String) -> int:
	return get_tree().get_nodes_in_group(group_name).size()


func _record_stage(rate: float) -> void:
	var row := {
		"rate_target": rate,
		"rate_actual": _blasts_per_sec,
		"frame_ms": _stats(_frame_ms),
		"physics_ms": _stats(_physics_ms),
		"debris_nodes": _istats(_debris_nodes),
		"debris_particles": _istats(_debris_queue),
		"debris_bursts": GpuDebris.debug_bursts_total(),
		"removals_per_sec": int(DestructibleManager.debug_chunk_removals() / SAMPLE_SEC),
	}
	_results.append(row)
	print(
		"[destruction-stress-bench] rate=%4.0f/s act=%4.0f/s phys=%5.2fms frame=%5.2fms emitters=%4d particles=%4d removals=%5d/s bursts=%d"
		% [
			rate,
			row.rate_actual,
			row.physics_ms.mean,
			row.frame_ms.mean,
			row.debris_nodes.mean,
			row.debris_particles.mean,
			row.removals_per_sec,
			row.debris_bursts,
		]
	)


func _dump_results() -> void:
	print("\n========== DESTRUCTION STRESS BENCH ==========")
	for row in _results:
		print(
			"rate %4.0f/s  phys %5.2fms  frame %5.2fms  emitters %4d  particles %4d  bursts %d"
			% [
				row.rate_target,
				row.physics_ms.mean,
				row.frame_ms.mean,
				row.debris_nodes.mean,
				row.debris_particles.mean,
				row.debris_bursts,
			]
		)
	print("====================================================\n")
	var summary := {
		"seed": bench_seed,
		"blast_radius": blast_radius,
		"blast_damage": blast_damage,
		"stages": _results,
	}
	var f := FileAccess.open(JSON_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(summary, "\t"))
		f.close()
		print("[destruction-stress-bench] wrote %s" % JSON_PATH)


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
