# AGENTS.md

Notes for AI agents working on this codebase.

## What this is

Multiplayer FPS in Godot 4.6. Last-man-standing rounds; round losers pick stacking cards that mutate their weapon and body for the next round. Played LAN-only via `ENetMultiplayerPeer`.

- Engine: Godot **4.6.2** (`/Applications/Godot.app/Contents/MacOS/Godot` on this machine)
- Physics tick: **120 Hz** (`project.godot` → `common/physics_ticks_per_second=120`)
- Render cap: 240 fps
- Main scene: `res://scenes/game.tscn`
- Autoloads (singletons): `NetworkManager` (`scripts/network_manager.gd`), `SFX` (`scripts/sfx.gd`), `CrowdAudio` (`scripts/crowd_audio.gd`, colosseum crowd ambience + reactions), `Trace` (`scripts/trace.gd`, debug/`GG_TRACE=1` only useful)

`Violence` (`scripts/violence.gd`) is a `class_name` static class — call as `Violence.foo(...)`, do **not** instantiate and do **not** `call_deferred()` on it (it's not an instance, will fail to compile).

## File map (the ones that matter most)

| Script | Role | Notes |
|---|---|---|
| `player.gd` (~2k lines) | The Player class. Movement, aim, RPC firing, bot AI, gun visual setup, body scaling, ghost mode. | `_fire_rifle` is the **human** fire path (cycles bolt, ejects casings, adds heat). `_bot_shoot` calls `_rifle_fired.rpc()` directly and **bypasses** all that. |
| `weapon.gd` | `class_name Weapon` resource. Single source of truth for stats. | Cards mutate fields; never read raw fields in gameplay code — use the `get_*()` derived getters. |
| `card_library.gd` | All cards. `static func by_id(id)` and `random_ids(n, score)`. | Card dicts have `apply: Callable` that mutates a `Weapon`. |
| `destructible_manager.gd` | Static registry + batched destruction flush for `DestructibleSolid` volumes. | Bullet rays use spatial grid + analytical chunk AABB tests; `register_destructible` must succeed or bullets pass through terrain. |
| `destructible_solid.gd` | Pre-split destructible terrain/props (`StaticBody3D` + chunk colliders). | `raycast_chunks()` is the analytical narrowphase; GPU damage uses per-chunk decal/deform batches. |
| `bullet.gd` | Per-bullet `Node3D` (set_script-ed at spawn, **not** a scene). Dual raycast each `_physics_process` (see Performance). | `_handle_collision` runs gameplay **and** visual spawning synchronously in physics tick — careful adding work here. |
| `procedural_gun.gd` (~1k lines) | `@tool`, builds first-person rifle from primitives. | Re-read the file before editing — has many setters that all call `_rebuild()`. `apply_weapon_stats(w)` is the entry point that maps stats → geometry. |
| `violence.gd` | Static helpers for blood, gibs, ragdolls, explosion VFX, view punch. | All calls are static. Many cached `MeshInstance3D` resources at the top of the file. |
| `gpu_debris.gd` | Destruction rubble, simulated on the GPU. `request_burst` (chunk removals) / `request_chips` (per-hit flecks) rasterize alive chunks into a 3D occupancy texture; the particles shader bounces shards off it. | `enabled` is a kill-switch, default true. New bursts evict oldest emitters when the particle pool is full. Emitters join the `destruction_debris` group (round cleanup, Trace `dbr`). |
| `sfx.gd` (~1.4k lines) | Procedural audio synthesis (no WAV samples on disk for shots/explosions/casings). HDR ducking, raytraced reverb bus, distance-delay simulation. | Hot path uses `_cached_wav(key, gen)` — caches the converted `AudioStreamWAV`, not just the raw `PackedVector2Array`. Don't reintroduce per-call `_samples_to_wav(...)`. |
| `game.gd` (~2.3k lines) | Round flow, scoreboard, card pick UI, state machine, HUD overlays. | Still the biggest file — search before adding. Two child managers split out: `dev_panel.gd` and `splitscreen_manager.gd`. |
| `dev_panel.gd` | F1 inspector — read-mostly view of the local-or-targeted player + card add/remove buttons. | `_ready()` self-builds; instantiated by Game and added under `$HUD`. Game routes its dev keybindings (G/P/M/1-5/?) through it via `_dev_panel.get_target()` / `refresh_if_visible()`. |
| `splitscreen_manager.gd` | Couch-coop layer: per-gamepad spawn + SubViewports + per-device pause menu. | Child of Game; checks `NetworkManager.has_meta("splitscreen_on_start")` in `_ready` to decide whether to build its UI. RPCs (`_do_spawn`, `_despawn`, `_broadcast_scores`) stay on Game; manager calls `_game._do_spawn.rpc(...)`. |

## Runnable scenes (besides `game.tscn`)

- `scenes/action_lab.tscn` — full arena, 5 random-card bots, free-look camera, live SFX sliders. Use for AI / combat playtesting.
- `scenes/gun_lab.tscn` + `gun_preview.tscn` — preview procedural gun visually, tweak exports.
- `scenes/audio_lab.tscn` — SFX mix / synth iteration.
- `scenes/crowd_lab.tscn` — colosseum crowd audio: enthusiasm/fear sliders, event buttons, chant audition/reroll, mix knobs.
- `scenes/lava_death_lab.tscn` — lava-shader body + sink death; live-tune sink timing and SFX.
- `scenes/deform_wall_test.tscn` — 20×6 wall, one body UV, weak decals top / strong deform bottom (matches in-game chunk batching). Auto-captures PNG with `-- capture=/tmp/wall.png`.
- `scenes/deform_inspect.tscn` — four single bricks (weak decal vs strong deform on centre/corner/side). `-- capture=/tmp/inspect.png`.
- `scenes/gpu_damage_bench.tscn` / `scenes/brick_render_bench.tscn` — GPU damage A/B and subdiv sweep for stone render cost.
- `scenes/perf_benchmark.tscn` — see below.

Run any of them with:
```bash
godot --path /Users/joep/dev/growing-guns res://scenes/<name>.tscn
```

## Performance

Use `scenes/perf_benchmark.tscn` to measure regressions:

```bash
godot --headless --path /Users/joep/dev/growing-guns res://scenes/perf_benchmark.tscn
```

For spike attribution during a bench or gameplay session:

```bash
GG_TRACE=1 godot --headless --path /Users/joep/dev/growing-guns res://scenes/perf_benchmark.tscn
```

Grep the log for `[trace] SPIKE` lines. `cpu[...]` buckets are **GDScript µs summed across all physics ticks in that render frame** — not the same thing as `physics_ms` (see below).

Spawns 4 bots with a fixed overpowered card build (uzi×2 + shotgun + explosive×2 + damage), runs for 15 s after a 3 s warmup, dumps a stats table + JSON to `/tmp/godot_perf_bench.json`. Always run **headless** — macOS won't honour `WINDOW_MODE_MINIMIZED` on a freshly-opened window, and a visible window introduces ~500 ms compositor stalls that pollute `frame_ms`.

A/B isolation modes — pass via `-- mode=NAME`:

- `no_casings` — `procedural_gun.eject_casing()` no-ops
- `no_bullets` — `_rifle_fired` skips spawning the projectile (isolates AI / CharacterBody3D from bullet cost)
- `no_explosion_visuals` — `bullet._handle_collision` skips `_spawn_bullet_blast`
- `no_explosion_audio` — `Violence.spawn_bullet_blast` skips the `SFX.explosion(...)` call
- `no_explosion_audio_or_visuals` — combined floor

All toggles live on `BenchFlags` (`scripts/bench_flags.gd`) — a `class_name` with `static var active`, `no_*`, `event_sink`, and a `BenchFlags.inc(kind)` event counter. `perf_benchmark.gd` sets `BenchFlags.active = true` in `_ready()`. In production it stays `false`, so every hook is gated behind one static-bool branch — no scene-root `.get()` lookups, no string comparisons. **Always use `BenchFlags.active` checks for any new bench instrumentation, never `current_scene.get("bench_*")`.**

What's known about the budget (4-bot stress test):

- **Target:** `physics_ms` mean ~4–7 ms in baseline combat. Above ~10 ms means meaningful per-tick regression.
- **Floor (no explosion FX/audio):** ~5 ms `physics_ms` mean — bot AI + 4× `CharacterBody3D` + bullet rays + destruction queue.
- **Light combat** (few projectiles): `physics_ms` mean can still look fine (~4 ms) even while spike frames are bad — don't trust mean alone.
- **Heavy combat** (~100–150 projectiles, uzi×2 build): spike frames hit **60–70 ms** render time with **8 physics catch-up steps** (`psteps=8`). Bench `physics_ms` max can reach **200+ ms** on individual samples.
- Each `SFX.explosion(...)` was the biggest audio offender until the WAV cache landed; blast **visuals** are ~0.15 ms each when not deferred.
- Bot AI bypasses `_fire_rifle()` so cost added there (heat / bolt / casings) doesn't show up in this bench. Validate human paths separately.

### How to read the numbers

| Metric | Source | Meaning |
|---|---|---|
| `physics_ms` (bench table) | `Performance.TIME_PHYSICS_PROCESS` | **Last physics tick only**, sampled ~1 Hz during the 15 s measure window. Underreports sustained load. |
| `physSum` / `psteps` (Trace SPIKE lines) | Trace autoload | Total engine physics ms **this render frame** and how many 120 Hz steps ran (spiral when behind). |
| `cpu[bullet=…]` etc. | `Trace.prof()` in GDScript | Our script time **summed across all physics ticks in that render frame**. Can exceed `physSum` because it's a different accounting. |
| `DestructibleManager.bench_bullet_ray_stats()` | Printed at end of bench | Analytical-ray counters: calls, avg grid candidates/ray, full-volume fallback count, `raycast_chunks` invocations. |

### Bullet ray architecture (current — as of analytical-path work)

Each bullet tick calls `_intersect_ray(from, to)`:

1. **`DestructibleManager.query_bullet_ray`** — **one** spatial-grid query + analytical `raycast_chunks` on sorted nearby volumes. Returns `{ hit, terrain_near }`.
2. **`space.intersect_ray`** — if `terrain_near`, physics mask is **players + projectiles only** (`2|4`); terrain comes from step 1. Open air uses full mask `1|2|4`.
3. **Fallback** (rare) — if grid said terrain nearby but both rays miss, one full-mask physics ray (grid miss safety net).

Key field in `bullet.gd`: `excluded_rids` (lifetime pierce/ghost list). Do **not** rebuild a per-tick body-RID exclude list — use the layer mask instead.

**Implementation notes (Mar 2026):**
- Merged duplicate grid passes (`fill_bullet_physics_exclude` + `raycast_bullet_destructibles` → single `query_bullet_ray`).
- Removed full-volume fallback (was scanning all ~470 volumes — perf cliff + pass-through bugs).
- ~~Widen grid pad (3× cell) on empty first pass~~ — REMOVED (Jul 2026): volumes are inserted into every cell their bounds overlap, so an empty first pass proves clear air; the widen re-scanned ~850 cells per bullet-tick for nothing and drove the crowd-era physics spiral. Regression guard: `explosion_lab.tscn -- --ray-probe` (headless) asserts the analytical+fallback contract.
- Sort grid candidates by ray distance for early `ray_to` shortening.
- Cache volume node refs in `_registered_vols` (skip `instance_from_id` per candidate).

**Correctness trap:** `destructible_manager.gd` must compile. A bad call like `sqrtf()` (invalid GDScript) breaks the script → `register_destructible` never runs → analytical path empty + physics excludes terrain → **bullets pass through everything**.

**Correctness trap:** `fill_bullet_physics_exclude` must **not** fall back to excluding all ~470 volume body RIDs when the grid misses. That made physics miss all terrain while analytical also failed → pass-through, and pushed `physics_ms` mean to ~100 ms.

### What is actually costly (measured with `GG_TRACE=1`, not guessed)

On spike frames with **~100–150 projectiles** in flight:

| Trace bucket | Typical spike-frame cost (pre-merge, ~100 proj) | After merge + mask (moderate proj) |
|---|---|---|
| `bullet_analytical` / `bullet_destruct_ray` | **~70–125 ms** | **~5–12 ms** |
| ~~`bullet_sync_exclude`~~ | ~~**~40–55 ms**~~ | **removed** (was duplicate grid) |
| `bullet_phys_ray` | **~0.3–1 ms** | **~0 ms** when terrain_near (mask skips layer 1) |
| `bullet_phys_fallback` | **~0.2 ms** | rare |
| `bullet` (total) | **~90–185 ms** | scales with projectile count + hits |
| `gpu_debris` | ~0 ms | Occupancy-snapshot build + emitter spawn per blast (debris sim itself runs on the GPU). |
| `blast_vfx` | ~0–25 ms | Mostly deferred via `Violence.flush_pending_blast_visuals()` from `game.gd` / bench. |

**Old path (single `intersect_ray` through chunk colliders):** ~5 ms `physics_ms` mean but physics engine scanned **~5000 chunk shapes** on layer 1 per ray — caused **75–85 ms** spike frames attributed to bullet/physics before analytical work.

**Current tradeoff:** physics narrowphase is cheap (`bullet_phys_ray` ≪ 1 ms/frame), but **GDScript analytical broadphase+narrowphase replaced it** and is now the bottleneck. The optimization partially worked; the replacement path isn't lean enough yet.

### Bench counters and Trace buckets

When `BenchFlags.active`, the bench prints:

```
Bullet analytical rays: calls=N  grid/ray=X  obb/ray=Y  chunk-volumes tested=Z
```

- **grid/ray** — avg volumes in spatial cells along the segment (broadphase, over-fetches).
- **obb/ray** — avg volumes after OBB filter (actually intersect the segment).
- **chunk-volumes tested** — `raycast_chunks` invocations (capped at 14/ray).

With `GG_TRACE=1`, `_intersect_ray` sub-buckets: `bullet_sync_exclude`, `bullet_phys_ray`, `bullet_analytical`, `bullet_phys_fallback`, plus parent `bullet`.

### Stone / destructible **render** cost (GPU — looking at damaged walls)

Separate from bullet-ray `physics_ms`. Cost scales with **visible chunk instances × verts/chunk × shader tier**.

**One unit brick mesh** (`CHUNK_MESH_SUBDIVIDE=3`, ~150 verts) shared by intact, decal, and deform MultiMesh batches — only the **material** differs:

| Batch | When | Shader |
|---|---|---|
| Intact | never hit | base rock (`damage_enabled=0`) |
| Decal | any bullet hit | damage fragment only (`dmg_vertex_deform=0`) |
| Deform | strong hit / carve | damage vertex carve (`dmg_vertex_deform=1`) |

Undamaged chunks never touch the damage path. Hit chunks add draw instances, not extra geometry density — deform used to use subdiv 12 (~864 verts) on the same bricks; that was removed.

**Measure render regressions** (must be windowed — headless reports 0 draws):

```bash
godot --path /Users/joep/dev/growing-guns res://scenes/gpu_damage_bench.tscn
godot --path /Users/joep/dev/growing-guns res://scenes/brick_render_bench.tscn -- frac=0.3
```

### Other recent perf work (for context)

- **GPU damage:** scoped to hit chunks only (`destructible_solid.gd` decal/deform batches) — avoids whole-body material swap regression.
- **Blast VFX:** heavy visuals deferred; flush from game loop.
- **Debris:** fully GPU-simulated (`gpu_debris.gd` + `shaders/gpu_debris.gdshader`) — one-shot GPUParticles3D colliding against a per-blast occupancy snapshot of the alive chunk grid. Cosmetic only, no readback, no physics bodies. Budgets scale with `PerfGovernor` (new bursts evict the oldest emitters). The old CPU parabola-chip system was deleted from `violence.gd`.

### Open perf work (if heavy combat regresses again)

1. **Cap `raycast_chunks` work** — `MAX_BULLET_VOLUME_RAYCASTS=14` + OBB filter before narrowphase (Mar 2026).
2. **Open-air fast path** — `terrain_near` is false when the segment misses every volume OBB; one physics ray only, no analytical pass.
3. **Per-volume shell collider** — one box shape per volume for physics-only fallback instead of thousands of chunk shapes (bigger change).
4. **`_handle_collision` on hit frames** — still inside the `bullet` Trace bucket; keep blast VFX deferred.
5. **Render draws (~5k)** — many visible MultiMesh bodies; fewer verts/chunk + scoped damage materials help; further wins = draw merging / fewer bodies visible.
6. **`max_physics_steps_per_frame=6`** — caps catch-up spiral (`psteps` was hitting 8); slight slow-mo under extreme load beats 6 fps freeze.

Always A/B with headless bench + `GG_TRACE=1`. Bench prints `Bullet analytical rays: calls=… candidates/ray=…`.

## Networking notes

- **iroh-only.** ENet / LAN UDP discovery / `auto_connect` were removed alongside the main menu. `network_manager.gd` exposes:
  - `host_game_iroh(name) -> String` — returns the game ID; called automatically in `game.gd._ready` if no peer is set.
  - `join_game_iroh(id, name) -> bool` — called from the pause menu's paste-and-join row; followed by `change_scene_to_file("res://scenes/game.tscn")` so `_ready` re-runs in client mode.
  - `current_iroh_game_id` — the host's connection string. Empty when this peer is a client.
  - `leave_game()` — closes the peer and clears bookkeeping.
- Plugin: `addons/godot_iroh/` ships v0.1.5 pre-built native libs (macOS universal, Windows x64, Linux x64). Wire ALPN is `b"godot-iroh/0.1"` — all peers must run the same plugin version. **No local-LAN discovery in this version**: iroh has it internally but the plugin doesn't surface it. If you want it, contribute upstream or roll your own UDP-broadcast-of-the-game-ID layer (it's transport-independent).
- Boot flow: `game.tscn` is the main scene; `_ready` auto-hosts iroh and the SP-fallback path spawns one bot, so launching = solo-vs-AI with a shareable game ID immediately. Pause menu (Esc) shows the ID + Copy button + paste-to-join field + Restart Match + Resume + Exit.
- Single-process / no-peer mode: `multiplayer.is_server()` returns **true** (default peer is server-only with `unique_id == 1`). Server-only RPC branches in `bullet.gd` and `player.gd` therefore **do** execute in the bench / local play.
- `_rifle_fired` is `@rpc("any_peer", "call_local", "reliable")` — runs on every peer including the shooter. Visual / SFX spawning in `_rifle_fired` shows up everywhere.
- Health changes go through `take_damage.rpc_id(target_authority, ...)` — don't write directly to remote `health`.

## Conventions

- **Forward is local −Z** in 3D scripts (Godot convention). +Y up, +X right.
- The procedural gun's children are rebuilt from scratch on every `_rebuild()` call. Don't keep stale references to its child nodes across a stat change — re-fetch via `_procedural_gun.get_node_or_null(...)`.
- Cached resources in `violence.gd` and `sfx.gd` (`static var _heat_mesh`, `_wav_cache`, etc.) are intentional — don't make them per-call.
- `@tool` scripts (`procedural_gun.gd`) run setters during scene load before sibling props settle. The `_request_preview()` / `call_deferred("_apply_preview")` pattern coalesces those. Follow it when adding new exports that depend on each other.

## Don'ts

- **Don't `call_deferred()` on `Violence`** — it's a `class_name` static class, not an instance. Compiles will fail and cascade through `bullet.gd` → `player.gd`.
- **Don't add per-frame work in `bullet._physics_process`** without measuring — bullets are spawned in bursts (~50–90 in flight in heavy combat).
- **Don't add per-call allocations to SFX hot paths** (`shot`, `explosion`, `casing_drop`, `impact`). They run hundreds of times per second under stress. Use `_cached_wav` + `_play_stream`, never `_play(_samples_to_wav(...))`.
- **Don't remove the `_bench_inc` / `bench_no_*` hooks** without checking `perf_benchmark.gd` first — they're how the bench attributes cost.
- **Don't break `destructible_manager.gd` compile** — if it fails to load, destructibles don't register and the dual bullet-ray path silently stops hitting terrain.
- **Don't reintroduce full-volume grid fallback** — never scan all ~470 registered volumes per ray.

## Build / export

```bash
tools/build_release.sh                       # mac + win → build/{macos,windows}/MoreRounds.zip
tools/build_release.sh all --itch user/game  # build both AND push to itch.io via tools/bin/butler
```

See `README.md` for distribution to LAN playtesters.
