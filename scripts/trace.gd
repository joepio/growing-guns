extends Node

const DestructibleManager = preload("res://scripts/destructible_manager.gd")

# Lightweight timing/tracing for diagnosing startup hitches and runtime stutter
# (autoload: Trace). Everything goes through print(), so it lands in the Godot
# log file for offline analysis after a demo run:
#   ~/Library/Application Support/Godot/app_userdata/Growing Guns/logs/godot.log
# Grep the log for "[trace]".
#
# SPIKE line fields (render frame):
#   dt_ms     — this frame's wall time (what you feel as hitch)
#   proc      — Engine TIME_PROCESS for the last *process* tick (seconds→ms)
#   phys1     — Engine TIME_PHYSICS_PROCESS for the last *physics* tick only
#   physSum   — sum of TIME_PHYSICS_PROCESS across every physics tick since the
#               previous render frame (total physics-engine ms this frame)
#   psteps    — how many physics ticks ran since the previous render frame
#               (at 60 Hz physics + ~50 fps render, expect ~1–2)
#   rb        — Performance PHYSICS_3D_ACTIVE_OBJECTS (all active RigidBody3D)
#   cas/gib/corp — scene group counts (see brass_casings / gib_chunks / corpses)
#   rb?       — rb minus tagged groups (unlabelled rigid bodies — investigate)
#   cpu[...]  — our own µs buckets (gameplay scripts we wrapped with Trace.prof)
#
# Enabled in debug builds (editor / debug exports) or when GG_TRACE is set.

var enabled: bool = false
var spike_ms: float = 12.0
var warmup_frames: int = 15

var _t0_ms: int = 0
var _spans: Dictionary = {}
var _last_mark_ms: int = 0
var _frames_seen: int = 0
var _sum_dt: float = 0.0
var _sum_n: int = 0
var _worst_dt: float = 0.0
var _sum_window: float = 0.0
# Physics accumulators — reset each render frame in _process.
var _phys_steps_this_render: int = 0
var _phys_usec_this_render: int = 0
# 1 s rollup for physics + scene counts.
var _sum_phys_sigma: float = 0.0
var _sum_psteps: int = 0
var _sum_draws: float = 0.0
var _sum_rb: float = 0.0
var _sum_cas: float = 0.0
var _sum_gib: float = 0.0

var _prof: Dictionary = {}


func _ready() -> void:
	_t0_ms = Time.get_ticks_msec()
	enabled = OS.is_debug_build() or OS.has_environment("GG_TRACE")
	if OS.has_environment("GG_TRACE_SPIKE_MS"):
		spike_ms = maxf(1.0, float(OS.get_environment("GG_TRACE_SPIKE_MS")))
	process_priority = 1000
	# Run on every physics tick so we can sum engine physics cost per render frame.
	set_physics_process(true)
	if enabled:
		print("[trace] enabled — t0 set, spike threshold=%.1fms" % spike_ms)


func _now() -> int:
	return Time.get_ticks_msec() - _t0_ms


func mark(label: String) -> void:
	if not enabled:
		return
	var now := _now()
	print("[trace] +%6dms (Δ%5dms)  %s" % [now, now - _last_mark_ms, label])
	_last_mark_ms = now


func prof(bucket: String, usec: int) -> void:
	if not enabled:
		return
	_prof[bucket] = int(_prof.get(bucket, 0)) + usec


func _prof_str() -> String:
	if _prof.is_empty():
		return ""
	var parts := PackedStringArray()
	for k in _prof:
		parts.append("%s=%.1f" % [k, float(_prof[k]) / 1000.0])
	return "  cpu[" + " ".join(parts) + "]ms"


func _prof_total_ms() -> float:
	var total_usec := 0
	for k in _prof:
		total_usec += int(_prof[k])
	return float(total_usec) / 1000.0


func span_begin(label: String) -> void:
	if not enabled:
		return
	_spans[label] = Time.get_ticks_msec()


func span_end(label: String) -> void:
	if not enabled or not _spans.has(label):
		return
	var dur := Time.get_ticks_msec() - int(_spans[label])
	_spans.erase(label)
	print("[trace] +%6dms  %-28s took %5dms" % [_now(), label, dur])


func _physics_process(_delta: float) -> void:
	if not enabled:
		return
	_phys_steps_this_render += 1
	_phys_usec_this_render += int(
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1_000_000.0
	)


func _scene_counts(tree: SceneTree) -> Dictionary:
	var cas := tree.get_nodes_in_group("brass_casings").size()
	var gib := tree.get_nodes_in_group("gib_chunks").size()
	var corp := tree.get_nodes_in_group("corpses").size()
	var rb := int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS))
	return {
		"cas": cas,
		"gib": gib,
		"corp": corp,
		"rb": rb,
		"rb_other": maxi(0, rb - cas - gib - corp),
		"plr": tree.get_nodes_in_group("players").size(),
		"proj": tree.get_nodes_in_group("projectiles").size(),
		"dbr": tree.get_nodes_in_group("destruction_debris").size(),
		"blood": (
			tree.get_nodes_in_group("blood_splats").size()
			+ tree.get_nodes_in_group("player_blood_wounds").size()
		),
		"crat": tree.get_nodes_in_group("craters").size(),
		"smk": (
			tree.get_nodes_in_group("smoke_puffs").size()
			+ tree.get_nodes_in_group("blast_smoke_layers").size()
		),
		"dest": tree.get_nodes_in_group("destructible").size(),
		"expm": tree.get_nodes_in_group("destructible_exposed_mm").size(),
	}


func _process(delta: float) -> void:
	if not enabled:
		return
	_frames_seen += 1
	if _frames_seen <= warmup_frames:
		_phys_steps_this_render = 0
		_phys_usec_this_render = 0
		return

	var dt_ms := delta * 1000.0
	var psteps := _phys_steps_this_render
	var phys_sigma_ms := float(_phys_usec_this_render) / 1000.0
	var phys_last_ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	_phys_steps_this_render = 0
	_phys_usec_this_render = 0

	var tree := get_tree()
	var sc: Dictionary = _scene_counts(tree) if tree else {}
	var draws := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))

	if dt_ms >= spike_ms:
		print((
			"[trace] SPIKE %6.1fms +%6dms proc=%4.1f phys1=%4.1f physSum=%5.1f psteps=%d "
			+ "fps=%3.0f draws=%5d rb=%d cas=%d gib=%d corp=%d rb?=%d plr=%d "
			+ "proj=%d dbr=%d blood=%d smk=%d qs=%.2f bnd=%s rs=%.2f shd=%d "
			+ "dest=%d exp=%d expm=%d cpuTot=%4.1f%s"
		) % [
			dt_ms, _now(),
			Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
			phys_last_ms,
			phys_sigma_ms,
			psteps,
			Engine.get_frames_per_second(),
			draws,
			sc.get("rb", 0),
			sc.get("cas", 0),
			sc.get("gib", 0),
			sc.get("corp", 0),
			sc.get("rb_other", 0),
			sc.get("plr", 0),
			sc.get("proj", 0),
			sc.get("dbr", 0),
			sc.get("blood", 0),
			sc.get("smk", 0),
			PerfGovernor.quality_scale if PerfGovernor else 1.0,
			PerfGovernor.bound_label() if PerfGovernor else "?",
			PerfGovernor.render_scale() if PerfGovernor else 1.0,
			PerfGovernor.shed_level if PerfGovernor else 0,
			sc.get("dest", 0),
			DestructibleManager.debug_exposed_chunk_count(),
			sc.get("expm", 0),
			_prof_total_ms(),
			_prof_str(),
		])

	if not _prof.is_empty():
		_prof.clear()

	_sum_dt += dt_ms
	_sum_n += 1
	_worst_dt = maxf(_worst_dt, dt_ms)
	_sum_window += delta
	_sum_phys_sigma += phys_sigma_ms
	_sum_psteps += psteps
	_sum_draws += float(draws)
	_sum_rb += float(sc.get("rb", 0))
	_sum_cas += float(sc.get("cas", 0))
	_sum_gib += float(sc.get("gib", 0))

	if _sum_window >= 1.0:
		var avg := _sum_dt / maxf(_sum_n, 1)
		var n := maxf(float(_sum_n), 1.0)
		print((
			"[trace] 1s  +%6dms  frames=%3d  avg=%5.2fms (%3.0ffps)  worst=%6.2fms  "
			+ "physSum_avg=%5.1f  psteps_avg=%4.1f  draws_avg=%4.0f  "
			+ "rb_avg=%4.0f  cas_avg=%4.0f  gib_avg=%4.0f  gov[%s]"
		) % [
			_now(), _sum_n, avg, 1000.0 / maxf(avg, 0.001), _worst_dt,
			_sum_phys_sigma / n,
			float(_sum_psteps) / n,
			_sum_draws / n,
			_sum_rb / n,
			_sum_cas / n,
			_sum_gib / n,
			PerfGovernor.debug_state() if PerfGovernor else "?",
		])
		_sum_dt = 0.0
		_sum_n = 0
		_worst_dt = 0.0
		_sum_window = 0.0
		_sum_phys_sigma = 0.0
		_sum_psteps = 0
		_sum_draws = 0.0
		_sum_rb = 0.0
		_sum_cas = 0.0
		_sum_gib = 0.0
