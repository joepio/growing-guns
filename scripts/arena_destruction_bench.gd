extends Node3D

# Headless bench for destructible-arena startup cost.
#
# Run:
#   godot --headless --path /Users/joep/dev/growing-guns res://scenes/arena_destruction_bench.tscn

const ARENA_SCENE := preload("res://scenes/arena_procedural.tscn")
const DestructibleSolid = preload("res://scripts/destructible_solid.gd")
const DestructibleManager = preload("res://scripts/destructible_manager.gd")

const DEFAULT_SEED := 0xB00B5
const JSON_PATH := "/tmp/godot_arena_destruction_bench.json"

var bench_seed: int = DEFAULT_SEED
var sample_frames: int = 90
var carve_hits: int = 24
var stress_radius: float = 3.5
var stress_damage: float = 100.0
var do_force_draw: bool = true
var screenshot_path: String = ""

var _arena: Node3D = null
var _camera: Camera3D = null
var _frame_idx: int = 0
var _phase := "load"
var _load_summary: Dictionary = {}

var _frame_ms: Array[float] = []
var _physics_ms: Array[float] = []
var _node_count: Array[int] = []
var _collision_pairs: Array[int] = []
var _chunks_before_stress := 0


func _ready() -> void:
	_parse_cli_args()
	print("[arena-destruction-bench] seed=%x frames=%d carve_hits=%d" % [bench_seed, sample_frames, carve_hits])
	var load_t0 := Time.get_ticks_usec()
	_arena = ARENA_SCENE.instantiate()
	_arena.name = "Arena"
	add_child(_arena)
	if _arena.has_method("apply_seed"):
		_arena.call("apply_seed", bench_seed)
	var load_ms := (Time.get_ticks_usec() - load_t0) / 1000.0
	var counts := _count_destructible_stats()
	_camera = Camera3D.new()
	_camera.position = Vector3(0, 14, 18)
	_camera.rotation_degrees = Vector3(-32, 0, 0)
	add_child(_camera)
	_camera.make_current()
	var force_draw_ms := 0.0
	if do_force_draw:
		await get_tree().process_frame
		var fd_t0 := Time.get_ticks_usec()
		RenderingServer.force_draw()
		force_draw_ms = (Time.get_ticks_usec() - fd_t0) / 1000.0
	var carve_ms := 0.0
	var chunks_removed := 0
	if carve_hits > 0:
		_chunks_before_stress = _count_pieces()
		var carve_t0 := Time.get_ticks_usec()
		chunks_removed = _run_carve_stress(carve_hits)
		carve_ms = (Time.get_ticks_usec() - carve_t0) / 1000.0
		await get_tree().process_frame
		for _i in 30:
			DestructibleManager.flush()
			await get_tree().process_frame
	if screenshot_path != "":
		await _write_screenshot()
	for _i in 20:
		await get_tree().physics_frame
	_phase = "sample"
	_frame_idx = 0
	_load_summary = {
		"seed": bench_seed,
		"arena_load_ms": load_ms,
		"gen_ms": counts.get("gen_ms", 0.0),
		"force_draw_ms": force_draw_ms,
		"carve_stress_ms": carve_ms,
		"carve_hits": carve_hits,
		"pieces_removed": chunks_removed,
		"counts": counts,
	}
	print("[arena-destruction-bench] load=%.1fms bodies=%d chunks=%d nodes=%d"
		% [load_ms, counts.bodies, counts.chunks, counts.nodes])


func _parse_cli_args() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("seed="):
			bench_seed = int(arg.substr(5))
		elif arg.begins_with("frames="):
			sample_frames = maxi(1, int(arg.substr(7)))
		elif arg.begins_with("carve_hits="):
			carve_hits = maxi(0, int(arg.substr(11)))
		elif arg.begins_with("stress_radius="):
			stress_radius = maxf(0.01, float(arg.substr(14)))
		elif arg.begins_with("stress_damage="):
			stress_damage = maxf(0.0, float(arg.substr(14)))
		elif arg.begins_with("force_draw="):
			do_force_draw = int(arg.substr(11)) != 0
		elif arg.begins_with("screenshot="):
			screenshot_path = arg.substr(11)


func _count_destructible_stats() -> Dictionary:
	var bodies := 0
	var chunks := 0
	var nodes := 0
	var gen_ms := 0.0
	if _arena != null and _arena.has_node("Generator"):
		var gen: Node = _arena.get_node("Generator")
		if gen.get("last_stats") is Dictionary:
			gen_ms = float(gen.get("last_stats").get("gen_ms", 0.0))
	for node: Node in get_tree().get_nodes_in_group("destructible"):
		bodies += 1
		if node.get_script() == DestructibleSolid:
			if node.has_method("debug_chunk_count"):
				chunks += int(node.call("debug_chunk_count"))
			for child: Node in node.get_children():
				nodes += 1
	return {
		"bodies": bodies,
		"chunks": chunks,
		"nodes": nodes,
		"gen_ms": gen_ms,
		"object_node_count": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"static_mem_mb": float(Performance.get_monitor(Performance.MEMORY_STATIC)) / (1024.0 * 1024.0),
	}


func _run_carve_stress(hits: int) -> int:
	var targets := get_tree().get_nodes_in_group("destructible")
	if targets.is_empty():
		return 0
	var removed := 0
	for i in hits:
		var node := targets[i % targets.size()]
		if not node is Node3D:
			continue
		var pos := (node as Node3D).global_position
		var before := int(node.call("debug_chunk_count")) if node.has_method("debug_chunk_count") else 0
		DestructibleManager.apply_blast(pos, stress_radius, stress_damage)
		var after := int(node.call("debug_chunk_count")) if is_instance_valid(node) and node.has_method("debug_chunk_count") else 0
		removed += maxi(0, before - after)
	return removed


func _count_pieces() -> int:
	var n := 0
	for node: Node in get_tree().get_nodes_in_group("destructible"):
		if is_instance_valid(node):
			if node.has_method("debug_chunk_count"):
				n += int(node.call("debug_chunk_count"))
				continue
			for child: Node in node.get_children():
				if child is CollisionShape3D and not child.is_queued_for_deletion() and str(child.name).contains("Chunk_"):
					n += 1
	return n


func _write_screenshot() -> void:
	await get_tree().process_frame
	RenderingServer.force_draw()
	var img := get_viewport().get_texture().get_image()
	if img == null or img.is_empty():
		push_warning("[arena-destruction-bench] screenshot image was empty")
		return
	var err := img.save_png(screenshot_path)
	if err != OK:
		push_warning("[arena-destruction-bench] failed to write screenshot %s err=%d" % [screenshot_path, err])
	else:
		print("[arena-destruction-bench] wrote screenshot %s" % screenshot_path)


func _physics_process(_delta: float) -> void:
	if _phase != "sample":
		return
	DestructibleManager.flush()
	_frame_ms.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	_physics_ms.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	_node_count.append(int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)))
	_collision_pairs.append(int(Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS)))
	_frame_idx += 1
	if _frame_idx >= sample_frames:
		_dump_results()
		get_tree().quit()


func _dump_results() -> void:
	var summary := _load_summary.duplicate(true)
	summary["sample_frames"] = sample_frames
	summary["physics_ms"] = _stats(_physics_ms)
	summary["frame_ms"] = _stats(_frame_ms)
	summary["node_count"] = _istats(_node_count)
	summary["post_sample"] = _count_destructible_stats()
	print("\n========== ARENA DESTRUCTION BENCH ==========")
	print("Arena load:         %7.1f ms" % summary.arena_load_ms)
	print("gen_ms:             %7.1f ms" % summary.gen_ms)
	print("force_draw:         %7.1f ms" % summary.force_draw_ms)
	print("Bodies:             %d" % summary.counts.bodies)
	print("Chunks:             %d" % summary.counts.chunks)
	print("Chunks removed:     %d in %.1f ms" % [summary.pieces_removed, summary.carve_stress_ms])
	_print_row("physics_ms", summary.physics_ms)
	_print_row("frame_ms", summary.frame_ms)
	print("Static mem (MB):   %.1f" % summary.counts.static_mem_mb)
	print("===========================================\n")
	var f := FileAccess.open(JSON_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(summary, "\t"))
		f.close()
		print("[arena-destruction-bench] wrote %s" % JSON_PATH)


func _print_row(label: String, s: Dictionary) -> void:
	print("%-18s mean=%7.3f  p50=%7.3f  p95=%7.3f  max=%7.3f" % [
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
