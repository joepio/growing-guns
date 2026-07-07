class_name BenchFlags
extends RefCounted

# Single source of truth for perf-bench instrumentation. Stays at the
# compile-time defaults (active=false) outside of perf_benchmark.tscn, so
# production paths only pay one static-bool branch where bench hooks are
# wired in — no scene-root .get() lookups, no string comparisons.
#
# perf_benchmark.gd sets `active = true` and the per-subsystem toggles in
# its own _ready(). Static state persists for the lifetime of the process,
# which is fine because the bench scene runs to completion and quits.

static var active: bool = false
static var no_casings: bool = false
static var no_bullets: bool = false
static var no_bullet_visuals: bool = false
static var no_bullet_zips: bool = false
static var no_shot_audio: bool = false
static var no_muzzle_flash: bool = false
static var no_explosion_visuals: bool = false
static var no_explosion_audio: bool = false
static var no_destruction: bool = false

# Counter sink — set by the bench to its own scene root so static callers
# can fan events without re-resolving current_scene.
static var event_sink: Object = null

# Branchless-ish convenience: production cost is one bool read + branch.
# Callers do `BenchFlags.inc("collisions")` instead of carrying scene refs.
static func inc(kind: String) -> void:
	if active and event_sink != null:
		event_sink.call("_bench_inc", kind)
