extends Node

# Lightweight timing/tracing for diagnosing startup hitches and runtime stutter
# (autoload: Trace). Everything goes through print(), so it lands in the Godot
# log file for offline analysis after a demo run:
#   ~/Library/Application Support/Godot/app_userdata/Growing Guns/logs/godot.log
# Grep the log for "[trace]".
#
# API:
#   Trace.mark("label")        — log a timestamped point (Δ since previous mark)
#   Trace.span_begin("label")  — start timing a region
#   Trace.span_end("label")    — log how long that region took
# Plus an always-on (when enabled) per-frame hitch detector + 1s rolling summary.
#
# Enabled in debug builds (editor / debug exports) or when GG_TRACE is set, so
# release builds stay silent. Toggle the threshold with GG_TRACE_SPIKE_MS.

var enabled: bool = false
# Frames slower than this (ms) get logged individually with context. ~12ms ≈ 83fps
# — well below smooth on this engine, so normal play won't spam, but a startup
# stutter (multi-frame, much worse) lights up clearly.
var spike_ms: float = 12.0
# Skip the first frames so one-time boot/scene-load cost isn't flagged as a hitch.
var warmup_frames: int = 15

var _t0_ms: int = 0
var _spans: Dictionary = {}
var _last_mark_ms: int = 0
var _frames_seen: int = 0
# 1s rolling summary accumulators.
var _sum_dt: float = 0.0
var _sum_n: int = 0
var _worst_dt: float = 0.0
var _sum_window: float = 0.0

func _ready() -> void:
	_t0_ms = Time.get_ticks_msec()
	enabled = OS.is_debug_build() or OS.has_environment("GG_TRACE")
	if OS.has_environment("GG_TRACE_SPIKE_MS"):
		spike_ms = maxf(1.0, float(OS.get_environment("GG_TRACE_SPIKE_MS")))
	# Run after gameplay scripts so the measured frame reflects the full frame's
	# work, and so marks emitted from gameplay this frame are already timestamped.
	process_priority = 1000
	if enabled:
		print("[trace] enabled — t0 set, spike threshold=%.1fms" % spike_ms)

func _now() -> int:
	return Time.get_ticks_msec() - _t0_ms

# A timestamped point. Δ is ms since the previous mark — handy for reading a
# startup sequence top to bottom.
func mark(label: String) -> void:
	if not enabled:
		return
	var now := _now()
	print("[trace] +%6dms (Δ%5dms)  %s" % [now, now - _last_mark_ms, label])
	_last_mark_ms = now

# Per-render-frame CPU buckets (µs), so a spike can say WHERE the main-thread
# time went. Callers wrap a region: Trace.prof("carve", usec_elapsed). Cleared
# every frame in _process (which runs last, priority 1000).
var _prof: Dictionary = {}

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

func _process(delta: float) -> void:
	if not enabled:
		return
	_frames_seen += 1
	if _frames_seen <= warmup_frames:
		return
	var dt_ms := delta * 1000.0

	# Per-frame hitch with context — this is what pins down WHICH frame stutters
	# at round start and what's in the scene when it does.
	if dt_ms >= spike_ms:
		# Break draws down by visual group so a high-draws spike says WHAT's on
		# screen: bullets (2 meshes each), debris chips (1 each), blood/gore,
		# decals, smoke. Only runs on a spike, so the group scans are rare.
		var tree := get_tree()
		# proc+phys = main-thread CPU; frame_ms minus that ≈ GPU/render wait. This
		# is the CPU-bound vs GPU-bound discriminator.
		print("[trace] SPIKE %6.1fms +%6dms proc=%4.1f phys=%4.1f fps=%3.0f draws=%5d rb=%d proj=%d dbr=%d blood=%d crat=%d smk=%d corpse=%d qs=%.2f%s" % [
			dt_ms, _now(),
			Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
			Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
			Engine.get_frames_per_second(),
			int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
			int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS)),
			tree.get_nodes_in_group("projectiles").size(),
			tree.get_nodes_in_group("destruction_debris").size(),
			tree.get_nodes_in_group("blood_splats").size() + tree.get_nodes_in_group("player_blood_wounds").size(),
			tree.get_nodes_in_group("craters").size(),
			tree.get_nodes_in_group("smoke_puffs").size() + tree.get_nodes_in_group("blast_smoke_layers").size(),
			tree.get_nodes_in_group("corpses").size(),
			PerfGovernor.quality_scale if PerfGovernor else 1.0,
			_prof_str(),
		])

	# Clear the CPU buckets for the next frame (we run last, so they're complete).
	if not _prof.is_empty():
		_prof.clear()

	# 1s rolling summary — shows the smoothness profile over time (e.g. choppy
	# first 3 seconds, then steady), independent of individual spikes.
	_sum_dt += dt_ms
	_sum_n += 1
	_worst_dt = maxf(_worst_dt, dt_ms)
	_sum_window += delta
	if _sum_window >= 1.0:
		var avg := _sum_dt / maxf(_sum_n, 1)
		print("[trace] 1s  +%6dms  frames=%3d  avg=%5.2fms (%3.0ffps)  worst=%6.2fms" % [
			_now(), _sum_n, avg, 1000.0 / maxf(avg, 0.001), _worst_dt])
		_sum_dt = 0.0
		_sum_n = 0
		_worst_dt = 0.0
		_sum_window = 0.0
