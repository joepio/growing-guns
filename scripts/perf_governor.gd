extends Node

# Adaptive VFX quality governor (autoload: PerfGovernor).
#
# Watches the REAL frame time (the _process delta, which is independent of
# vsync / max_fps, unlike Engine.get_frames_per_second()) and derives a single
# `quality_scale` in [MIN_SCALE, 1.0]. The expensive explosion budgets in
# violence.gd multiply their caps by it, so a machine that starts dropping
# frames automatically sheds the priciest VFX (fewer simultaneous full blasts,
# fewer smoke layers, fewer particles) to defend the framerate — then eases
# back to full quality once it has headroom again.
#
# This is a FLOOR protector, not a target enforcer: full quality holds for any
# machine comfortably above FULL_QUALITY_FPS. We only trim when fps sags toward
# MIN_QUALITY_FPS. Tune the constants below to taste.

# At/above this measured fps, run everything at full quality (scale = 1.0).
const FULL_QUALITY_FPS := 200.0
# At/below this fps, clamp to MIN_SCALE — framerate-survival mode.
const MIN_QUALITY_FPS := 90.0
# Floor for the scale: even under heavy load explosions never fully vanish.
const MIN_SCALE := 0.34
# EMA weight for the frame-time average. Small = smoother (a lone hitch won't
# yank quality); ~0.1 tracks roughly the last couple dozen frames.
const FRAME_EMA := 0.1
# Asymmetric response: drop quality fast when frames slow (protect fps), recover
# slowly so effects don't visibly pop in/out (hysteresis against oscillation).
const FALL_LERP := 0.25
const RISE_LERP := 0.03
# Ignore frame-time spikes above this (loading stalls, alt-tab) so a single huge
# delta doesn't read as ~0 fps and slam quality to the floor.
const MAX_FRAME_MS := 100.0

var quality_scale: float = 1.0
var _avg_frame_ms: float = 1000.0 / 240.0

func _process(delta: float) -> void:
	var frame_ms: float = minf(delta * 1000.0, MAX_FRAME_MS)
	_avg_frame_ms = lerpf(_avg_frame_ms, frame_ms, FRAME_EMA)
	var fps: float = 1000.0 / maxf(_avg_frame_ms, 0.001)
	var t: float = clampf(inverse_lerp(MIN_QUALITY_FPS, FULL_QUALITY_FPS, fps), 0.0, 1.0)
	var target: float = lerpf(MIN_SCALE, 1.0, t)
	var rate: float = FALL_LERP if target < quality_scale else RISE_LERP
	quality_scale = lerpf(quality_scale, target, rate)

# Smoothed fps estimate — handy for HUD/debug readouts.
func smoothed_fps() -> float:
	return 1000.0 / maxf(_avg_frame_ms, 0.001)
