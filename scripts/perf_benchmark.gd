extends Node3D

# Performance benchmark — spawns 4 bots with a fixed, very overpowered card
# build (uzi-stacked + explosive + multi-shot), lets them fight for a fixed
# duration, samples per-frame perf metrics, and dumps a summary + JSON file.
# Auto-quits when done so it can be run from the CLI for iteration.
#
# Run (recommended — no visible window):
#   godot --headless --path /Users/joep/dev/godot res://scenes/perf_benchmark.tscn
#
# Pass `-- mode=NAME` to toggle A/B isolation flags (see _parse_cli_args).
# Pass `-- build=card,card,...` to override the stress build.
# Baseline includes level destruction (explosive rounds carve destructible
# terrain via DestructionCoordinator). Use `mode=no_destruction` to A/B it.
# In --headless mode, render-side perf monitors return 0 (draw_calls etc.);
# physics_ms / frame_ms / event rates remain accurate, which is what we
# actually want for tracking gameplay-side regressions.

const DestructibleManager = preload("res://scripts/destructible_manager.gd")

const ARENA_SCENE := preload("res://scenes/arena_procedural.tscn")
const PLAYER_SCENE := preload("res://scenes/player.tscn")
const PLAYING_STATE := 1   # Player._bot_physics gates firing on scene.state == 1.

const NUM_BOTS := 4
const RNG_SEED := 0xB00B5
const WARMUP_SEC := 3.0    # let bots find each other and the SFX cache populate
const MEASURE_SEC := 15.0
# A/B isolation toggles — read by other systems via a global on this scene so
# we can attribute physics_ms to specific subsystems.
# Pass these on the command line via `-- bench_mode=NAME`. NAME is one of:
#   baseline   — everything on (default)
#   no_casings — eject_casing() is a no-op (procedural_gun reads scene.bench_no_casings)
#   no_explosions — explosive cards do damage but spawn no bullet_blast visuals
var bench_mode: String = "baseline"
# Counters to attribute event rates per second
var ev_bullets_spawned: int = 0
var ev_collisions: int = 0
var ev_explosions: int = 0
var ev_casings_spawned: int = 0
# A "simulation" RID count snapshot — total RigidBody3D / CollisionObject3D in
# the scene tree. Higher than active_rigid_bodies because broadphase tracks
# sleeping bodies too.
var _peak_collision_objects: int = 0
# Stacked deliberately to compound (uzi×2 = 9× fire rate; explosive×2 = bigger radius).
const BUILD: Array[String] = [
	"uzi",        # fire_rate ×3, mag +20, dmg ×0.7
	"uzi",        # stacks: ×9 fire rate, +40 mag, ×0.49 dmg
	"shotgun",    # +2 extra projectiles per trigger
	"explosive",  # explosive radius + damage
	"explosive",  # stacks
	"damage",     # ×1.5 damage
]
var build: Array[String] = BUILD.duplicate()

var state: int = PLAYING_STATE
var local_player: Node = null   # consumers null-guard this; leaving it null is fine

var _camera: Camera3D
var _bots: Array[Node] = []
var _start_t: float = 0.0
var _phase: String = "warmup"

# Per-frame samples (captured during MEASURE phase)
var _frame_ms: Array[float] = []
var _physics_ms: Array[float] = []
var _draw_calls: Array[int] = []
var _drawn_objects: Array[int] = []
var _active_rb: Array[int] = []
var _node_count: Array[int] = []
var _orphan_count: Array[int] = []
var _resource_count: Array[int] = []
var _projectile_count: Array[int] = []
var _debris_nodes: Array[int] = []
var _debris_queue_len: Array[int] = []
var _destruct_dirty_queue: Array[int] = []
var _arena_chunks: Array[int] = []
var _chunks_at_measure_start: int = 0
var _peak_static_mem: int = 0
var _wall_spray_collider: Node = null
var _wall_spray_pos: Vector3 = Vector3.ZERO
var _wall_spray_accum: float = 0.0
const WALL_SPRAY_RATE := 40.0  # ~minigun explosive hits/sec at one spot


func _ready() -> void:
	seed(RNG_SEED)
	_parse_cli_args()
	# Activate bench instrumentation. Outside this scene, BenchFlags.active
	# stays false so gameplay scripts skip the hooks at a single bool branch.
	BenchFlags.active = true
	BenchFlags.event_sink = self
	# Best-effort: try to minimise the window if we have one. macOS ignores
	# this on a freshly-opened window — recommended invocation is --headless.
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MINIMIZED)
	print("[bench] seed=%x bots=%d warmup=%.1fs measure=%.1fs mode=%s build=%s"
		% [RNG_SEED, NUM_BOTS, WARMUP_SEC, MEASURE_SEC, bench_mode, str(build)])
	_build_arena()
	_build_camera()
	_warmup_effect_shaders()
	_spawn_bots()
	# Top-up HP every second so bots can't actually die.
	var hp_timer := Timer.new()
	hp_timer.wait_time = 1.0
	hp_timer.autostart = true
	hp_timer.timeout.connect(_top_up_bots)
	add_child(hp_timer)
	_start_t = Time.get_ticks_msec() / 1000.0


func _parse_cli_args() -> void:
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
		"no_explosion_visuals":
			BenchFlags.no_explosion_visuals = true
		"no_explosion_audio":
			BenchFlags.no_explosion_audio = true
		"no_explosion_audio_or_visuals":
			BenchFlags.no_explosion_audio = true
			BenchFlags.no_explosion_visuals = true
		"no_bullets":
			BenchFlags.no_bullets = true
		"no_destruction":
			BenchFlags.no_destruction = true
		"wall_spray":
			bench_mode = "wall_spray"
			build = ["minigun", "explosive", "explosive"]


func _build_arena() -> void:
	var arena: Node = ARENA_SCENE.instantiate()
	arena.name = "Arena"
	add_child(arena)
	# Reuse the bench's RNG_SEED so the layout is reproducible run-to-run.
	if arena.has_method("apply_seed"):
		arena.apply_seed(RNG_SEED)
	# Bot AI walks siblings via get_parent().get_children() to find targets.
	var players_root := Node3D.new()
	players_root.name = "Players"
	add_child(players_root)


func _warmup_effect_shaders() -> void:
	# Mirror game.gd's boot warmup so the bench measures steady-state, not the
	# one-time first-explosion effect-cache/shader population (these caches are
	# process-wide). Without this the first blasts compile shaders / build cached
	# meshes mid-run — the ~23ms "first time" spike.
	if not has_node("Arena"):
		return
	var arena := $Arena
	Violence.prewarm_disintegration_cache()
	Violence.warmup_blast_materials(arena)
	Violence.warmup_gib_render(arena)
	if DisplayServer.get_name() != "headless":
		RenderingServer.force_draw(true)


func _build_camera() -> void:
	# Static overhead camera — we don't care about the view, but the renderer
	# still needs an active camera to produce meaningful draw-call counts.
	_camera = Camera3D.new()
	_camera.fov = 75.0
	_camera.position = Vector3(0, 18, 18)
	_camera.rotation_degrees = Vector3(-35, 0, 0)
	add_child(_camera)
	_camera.make_current()


func _spawn_bots() -> void:
	var players_root: Node = $Players
	var spawns := _gather_spawn_points()
	for i in NUM_BOTS:
		var pid := 9000 + i
		var bot := PLAYER_SCENE.instantiate()
		bot.name = str(pid)
		bot.set("player_id", pid)
		bot.set("player_name", "Bot_%d" % i)
		bot.set("is_bot", true)
		var pos: Vector3
		if not spawns.is_empty():
			pos = spawns[i % spawns.size()]
		else:
			var angle := float(i) / float(NUM_BOTS) * TAU
			pos = Vector3(cos(angle) * 8.0, 1.5, sin(angle) * 8.0)
		bot.position = pos
		players_root.add_child(bot)
		_bots.append(bot)
		# CardLibrary etc. are global — defer card application a frame so the
		# Player has a chance to finish _ready / instantiate its weapon.
		await get_tree().process_frame
		for cid in build:
			if bot.has_method("apply_card"):
				bot.call("apply_card", cid)
		bot.set("health", 999999)
	_camera.make_current()


# Called by player.gd / bullet.gd / procedural_gun.gd via has_method() check.
# Counts events during measurement only, so warmup doesn't pollute rates.
func _bench_inc(kind: String) -> void:
	if _phase != "measure":
		return
	match kind:
		"bullets_spawned": ev_bullets_spawned += 1
		"collisions":      ev_collisions += 1
		"explosions":      ev_explosions += 1
		"casings_spawned": ev_casings_spawned += 1


func _gather_spawn_points() -> Array[Vector3]:
	var out: Array[Vector3] = []
	for n in get_tree().get_nodes_in_group("spawnpoints"):
		if n is Node3D:
			out.append((n as Node3D).global_position)
	return out


func _top_up_bots() -> void:
	for b in _bots:
		if not is_instance_valid(b):
			continue
		var hp: int = int(b.get("health"))
		if hp < 100:
			b.set("health", 999999)
			if bool(b.get("ghost_mode")):
				b.call("set_ghost_mode", false)
			if bool(b.get("frozen")):
				b.set("frozen", false)


func _process(_delta: float) -> void:
	Violence.flush_pending_blast_visuals()
	var t := Time.get_ticks_msec() / 1000.0 - _start_t
	match _phase:
		"warmup":
			if t >= WARMUP_SEC:
				Violence.reset_bench_blast_prof()
				DestructibleManager.reset_bench_destruct_prof()
				DestructibleManager.reset_chunk_removals()
				DestructibleManager.reset_bench_bullet_ray_stats()
				Violence.reset_debris_bench_counters()
				_chunks_at_measure_start = _count_arena_chunks()
				_debris_nodes.clear()
				_debris_queue_len.clear()
				_destruct_dirty_queue.clear()
				_arena_chunks.clear()
				_setup_wall_spray()
				_phase = "measure"
				print("[bench] warmup done — sampling for %.1fs (arena chunks=%d destruction=%s)"
					% [MEASURE_SEC, _chunks_at_measure_start,
						"off" if BenchFlags.no_destruction else "on"])
		"measure":
			_capture_sample()
			if t >= WARMUP_SEC + MEASURE_SEC:
				_phase = "done"
				_dump_results()
				get_tree().quit()


func _physics_process(delta: float) -> void:
	if bench_mode != "wall_spray" or _phase != "measure" or BenchFlags.no_destruction:
		return
	if _wall_spray_collider == null or not is_instance_valid(_wall_spray_collider):
		return
	_wall_spray_accum += delta * WALL_SPRAY_RATE
	while _wall_spray_accum >= 1.0:
		_wall_spray_accum -= 1.0
		DestructibleManager.carve_from_hit(
			_wall_spray_pos,
			1.2,
			6.5,
			_wall_spray_collider,
			Vector3.UP,
			55.0,
		)
		if not BenchFlags.no_explosion_visuals:
			Violence.spawn_bullet_blast(self, _wall_spray_pos, 6.5, Color(1.0, 0.5, 0.15), null, false)


func _setup_wall_spray() -> void:
	if bench_mode != "wall_spray":
		return
	_wall_spray_collider = null
	for vol in get_tree().get_nodes_in_group("destructible"):
		if not vol is Node3D:
			continue
		for child in vol.get_children():
			if child is CollisionShape3D and not bool(child.get_meta("destroyed", false)):
				_wall_spray_collider = child
				_wall_spray_pos = (child as Node3D).global_position
				print("[bench] wall_spray target=%s @ %s" % [vol.name, _wall_spray_pos])
				return
	print("[bench] WARNING: wall_spray mode but no destructible collider found")


func _capture_sample() -> void:
	# TIME_PROCESS / TIME_PHYSICS_PROCESS report seconds spent in the LAST
	# tick — a direct proxy for frame budget consumption.
	_frame_ms.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	_physics_ms.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	_draw_calls.append(int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)))
	_drawn_objects.append(int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)))
	_active_rb.append(int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS)))
	_node_count.append(int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)))
	_orphan_count.append(int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)))
	_resource_count.append(int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)))
	_projectile_count.append(get_tree().get_nodes_in_group("projectiles").size())
	_debris_nodes.append(get_tree().get_nodes_in_group("destruction_debris").size())
	_debris_queue_len.append(Violence.debug_debris_queue_len())
	_destruct_dirty_queue.append(DestructibleManager.debug_dirty_queue_len())
	_arena_chunks.append(_count_arena_chunks())
	var mem := int(Performance.get_monitor(Performance.MEMORY_STATIC))
	if mem > _peak_static_mem:
		_peak_static_mem = mem
	# Count CollisionObject3D instances under the scene (RigidBody3D + areas +
	# static bodies). Cheap because Performance gives us the totals.
	var co_count := int(Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS))
	if co_count > _peak_collision_objects:
		_peak_collision_objects = co_count


func _dump_results() -> void:
	if _frame_ms.is_empty():
		print("[bench] no samples!")
		return
	var fps_mean: float = 1000.0 / _mean(_frame_ms) if _mean(_frame_ms) > 0.0 else 0.0
	var summary := {
		"build": build,
		"bots": NUM_BOTS,
		"samples": _frame_ms.size(),
		"warmup_sec": WARMUP_SEC,
		"measure_sec": MEASURE_SEC,
		"frame_ms": _stats(_frame_ms),
		"physics_ms": _stats(_physics_ms),
		"fps_from_mean_frame_ms": fps_mean,
		"draw_calls": _istats(_draw_calls),
		"drawn_objects": _istats(_drawn_objects),
		"active_rigid_bodies": _istats(_active_rb),
		"projectiles_in_group": _istats(_projectile_count),
		"destruction_debris_nodes": _istats(_debris_nodes),
		"destruction_debris_queue": _istats(_debris_queue_len),
		"destruction_dirty_queue": _istats(_destruct_dirty_queue),
		"arena_chunks_remaining": _istats(_arena_chunks),
		"node_count": _istats(_node_count),
		"orphan_nodes": _istats(_orphan_count),
		"resource_count": _istats(_resource_count),
		"peak_static_mem_mb": float(_peak_static_mem) / (1024.0 * 1024.0),
	}
	print("\n========== PERF BENCHMARK RESULT ==========")
	print("Mode:                   %s" % bench_mode)
	print("Build:                  %s" % str(build))
	print("Samples:                %d frames over %.1f s" % [_frame_ms.size(), MEASURE_SEC])
	print("FPS (from mean frame):  %6.1f" % fps_mean)
	print("Event rates (per sec):  bullets=%4d  collisions=%4d  explosions=%4d  casings=%4d" % [
		int(ev_bullets_spawned / MEASURE_SEC),
		int(ev_collisions / MEASURE_SEC),
		int(ev_explosions / MEASURE_SEC),
		int(ev_casings_spawned / MEASURE_SEC),
	])
	print("Peak collision pairs:   %d" % _peak_collision_objects)
	_print_row("frame_ms (process)",  _stats(_frame_ms))
	_print_row("physics_ms",          _stats(_physics_ms))
	_print_irow("draw_calls",         _istats(_draw_calls))
	_print_irow("drawn_objects",      _istats(_drawn_objects))
	_print_irow("active_rigid_bodies",_istats(_active_rb))
	_print_irow("projectiles",        _istats(_projectile_count))
	_print_irow("debris_nodes",       _istats(_debris_nodes))
	_print_irow("debris_queue",       _istats(_debris_queue_len))
	_print_irow("destruct_dirty_q",   _istats(_destruct_dirty_queue))
	_print_irow("arena_chunks",       _istats(_arena_chunks))
	_print_irow("node_count",         _istats(_node_count))
	_print_irow("orphan_nodes",       _istats(_orphan_count))
	_print_irow("resource_count",     _istats(_resource_count))
	print("Peak static mem (MB):   %.1f" % (float(_peak_static_mem) / (1024.0 * 1024.0)))
	_print_destruct_summary(summary)
	_print_blast_prof(summary)
	print("===========================================\n")
	# JSON dump — easy to diff across runs.
	var path := "/tmp/godot_perf_bench.json"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(summary, "  "))
		f.close()
		print("[bench] wrote %s" % path)


func _print_row(label: String, s: Dictionary) -> void:
	print("%-22s mean=%7.3f  p50=%7.3f  p95=%7.3f  max=%7.3f" % [
		label, s.mean, s.p50, s.p95, s.max])


func _print_irow(label: String, s: Dictionary) -> void:
	print("%-22s mean=%7d  p50=%7d  p95=%7d  max=%7d" % [
		label, s.mean, s.p50, s.p95, s.max])


func _print_blast_prof(summary: Dictionary) -> void:
	var prof: Dictionary = Violence.bench_blast_prof_summary()
	var usec: Dictionary = prof.get("usec", {})
	var n: Dictionary = prof.get("n", {})
	if usec.is_empty():
		return
	var calls := int(n.get("blast_calls", 0))
	var full := int(n.get("blast_full", 0))
	var cheap := int(n.get("blast_cheap", 0))
	var total_usec := int(usec.get("blast_total", 0))
	print("\n--- blast VFX spawn cost (measure window) ---")
	print("Calls: full=%d  cheap=%d  total=%d" % [full, cheap, calls])
	if calls > 0 and total_usec > 0:
		print("Total spawn CPU: %.1f ms  (%.1f us/call mean)" % [
			total_usec / 1000.0, float(total_usec) / float(calls)])
	var layers: Array[String] = [
		"sidechain", "view_punch", "cheap_flare", "heat_distortion", "shockwave",
		"flash_light", "fireball_light", "smoke_push", "smoke_billow", "fire_billow",
		"flame_shards", "embers", "explosion_audio", "blast_total",
	]
	var rows: Array[Dictionary] = []
	for bucket in layers:
		var bu := int(usec.get(bucket, 0))
		if bu <= 0:
			continue
		var bn := int(n.get(bucket, 0))
		rows.append({
			"bucket": bucket,
			"ms": bu / 1000.0,
			"us_per": float(bu) / float(maxi(bn, 1)),
			"n": bn,
			"pct": 100.0 * float(bu) / float(maxi(total_usec, 1)),
		})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["ms"]) > float(b["ms"]))
	for row in rows:
		print("  %-16s %8.1f ms  %7.1f us/call  n=%5d  %5.1f%%" % [
			row["bucket"], row["ms"], row["us_per"], row["n"], row["pct"]])
	summary["blast_prof"] = prof
	summary["blast_prof_rows"] = rows


func _count_arena_chunks() -> int:
	var total := 0
	for node in get_tree().get_nodes_in_group("destructible"):
		if node.has_method("debug_chunk_count"):
			total += int(node.call("debug_chunk_count"))
	return total


func _print_destruct_summary(summary: Dictionary) -> void:
	var chunks_end := _count_arena_chunks()
	var chunks_removed := DestructibleManager.debug_chunk_removals()
	var prem := Violence.debug_debris_premium_bursts()
	var cheap := Violence.debug_debris_cheap_bursts()
	var destructibles := DestructibleManager.debug_registered_count()
	var removals_per_sec := int(float(chunks_removed) / MEASURE_SEC)
	summary["destruction"] = {
		"enabled": not BenchFlags.no_destruction,
		"chunks_at_start": _chunks_at_measure_start,
		"chunks_at_end": chunks_end,
		"chunks_removed": chunks_removed,
		"removals_per_sec": removals_per_sec,
		"debris_premium_bursts": prem,
		"debris_cheap_bursts": cheap,
		"destructible_volumes": destructibles,
	}
	print("\n--- level destruction (measure window) ---")
	print("Enabled:                %s" % ("yes" if not BenchFlags.no_destruction else "no (mode=no_destruction)"))
	print("Destructible volumes:   %d" % destructibles)
	var brs: Dictionary = DestructibleManager.bench_bullet_ray_stats()
	if int(brs.get("calls", 0)) > 0:
		print("Bullet analytical rays: calls=%d  candidates/ray=%.1f  chunk-volumes tested=%d"
			% [int(brs.calls), float(brs.candidates_avg), int(brs.volumes_raycast)])
	print("Arena chunks:           start=%d  end=%d  removed=%d  (~%d/s)"
		% [_chunks_at_measure_start, chunks_end, chunks_removed, removals_per_sec])
	print("Debris bursts:          premium=%d  cheap=%d" % [prem, cheap])
	if not BenchFlags.no_destruction and chunks_removed <= 0:
		print("WARNING: no chunk removals — destruction may not be wired (check arena + explosive hits)")
	var prof: Dictionary = DestructibleManager.bench_destruct_prof_summary()
	var usec: Dictionary = prof.get("usec", {})
	var n: Dictionary = prof.get("n", {})
	if usec.is_empty():
		return
	var carve_calls := int(n.get("carve_calls", 0))
	var total_usec := 0
	for bucket in ["carve_queue", "destruct_flush", "debris_flush", "chunk_remove", "jag"]:
		total_usec += int(usec.get(bucket, 0))
	print("Destruction CPU:        %.1f ms total  carve_calls=%d" % [total_usec / 1000.0, carve_calls])
	var layers: Array[String] = [
		"carve_queue", "destruct_flush", "debris_flush", "chunk_remove", "jag",
	]
	var rows: Array[Dictionary] = []
	for bucket in layers:
		var bu := int(usec.get(bucket, 0))
		if bu <= 0:
			continue
		var bn := int(n.get(bucket, 0))
		rows.append({
			"bucket": bucket,
			"ms": bu / 1000.0,
			"us_per": float(bu) / float(maxi(bn, 1)),
			"n": bn,
			"pct": 100.0 * float(bu) / float(maxi(total_usec, 1)),
		})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["ms"]) > float(b["ms"]))
	for row in rows:
		print("  %-16s %8.1f ms  %7.1f us/call  n=%5d  %5.1f%%" % [
			row["bucket"], row["ms"], row["us_per"], row["n"], row["pct"]])
	summary["destruct_prof"] = prof
	summary["destruct_prof_rows"] = rows


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
