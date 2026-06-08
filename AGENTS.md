# AGENTS.md

Notes for AI agents working on this codebase.

## What this is

Multiplayer FPS in Godot 4.6. Last-man-standing rounds; round losers pick stacking cards that mutate their weapon and body for the next round. Played LAN-only via `ENetMultiplayerPeer`.

- Engine: Godot **4.6.2** (`/Applications/Godot.app/Contents/MacOS/Godot` on this machine)
- Physics tick: **120 Hz** (`project.godot` → `common/physics_ticks_per_second=120`)
- Render cap: 240 fps
- Main scene: `res://scenes/game.tscn`
- Autoloads (singletons): `NetworkManager` (`scripts/network_manager.gd`), `SFX` (`scripts/sfx.gd`)

`Violence` (`scripts/violence.gd`) is a `class_name` static class — call as `Violence.foo(...)`, do **not** instantiate and do **not** `call_deferred()` on it (it's not an instance, will fail to compile).

## File map (the ones that matter most)

| Script | Role | Notes |
|---|---|---|
| `player.gd` (~2k lines) | The Player class. Movement, aim, RPC firing, bot AI, gun visual setup, body scaling, ghost mode. | `_fire_rifle` is the **human** fire path (cycles bolt, ejects casings, adds heat). `_bot_shoot` calls `_rifle_fired.rpc()` directly and **bypasses** all that. |
| `weapon.gd` | `class_name Weapon` resource. Single source of truth for stats. | Cards mutate fields; never read raw fields in gameplay code — use the `get_*()` derived getters. |
| `card_library.gd` | All cards. `static func by_id(id)` and `random_ids(n, score)`. | Card dicts have `apply: Callable` that mutates a `Weapon`. |
| `bullet.gd` | Per-bullet `Node3D` (set_script-ed at spawn, **not** a scene). Raycasts each `_physics_process`. | `_handle_collision` runs gameplay **and** visual spawning synchronously in physics tick — careful adding work here. |
| `procedural_gun.gd` (~1k lines) | `@tool`, builds first-person rifle from primitives. | Re-read the file before editing — has many setters that all call `_rebuild()`. `apply_weapon_stats(w)` is the entry point that maps stats → geometry. |
| `violence.gd` | Static helpers for blood, gibs, ragdolls, explosion VFX, view punch. | All calls are static. Many cached `MeshInstance3D` resources at the top of the file. |
| `sfx.gd` (~1.4k lines) | Procedural audio synthesis (no WAV samples on disk for shots/explosions/casings). HDR ducking, raytraced reverb bus, distance-delay simulation. | Hot path uses `_cached_wav(key, gen)` — caches the converted `AudioStreamWAV`, not just the raw `PackedVector2Array`. Don't reintroduce per-call `_samples_to_wav(...)`. |
| `game.gd` (~2.3k lines) | Round flow, scoreboard, card pick UI, state machine, HUD overlays. | Still the biggest file — search before adding. Two child managers split out: `dev_panel.gd` and `splitscreen_manager.gd`. |
| `dev_panel.gd` | F1 inspector — read-mostly view of the local-or-targeted player + card add/remove buttons. | `_ready()` self-builds; instantiated by Game and added under `$HUD`. Game routes its dev keybindings (G/P/M/1-5/?) through it via `_dev_panel.get_target()` / `refresh_if_visible()`. |
| `splitscreen_manager.gd` | Couch-coop layer: per-gamepad spawn + SubViewports + per-device pause menu. | Child of Game; checks `NetworkManager.has_meta("splitscreen_on_start")` in `_ready` to decide whether to build its UI. RPCs (`_do_spawn`, `_despawn`, `_broadcast_scores`) stay on Game; manager calls `_game._do_spawn.rpc(...)`. |

## Runnable scenes (besides `game.tscn`)

- `scenes/action_lab.tscn` — full arena, 5 random-card bots, free-look camera, live SFX sliders. Use for AI / combat playtesting.
- `scenes/gun_lab.tscn` + `gun_preview.tscn` — preview procedural gun visually, tweak exports.
- `scenes/audio_lab.tscn` — SFX mix / synth iteration.
- `scenes/lava_death_lab.tscn` — lava-shader body + sink death; live-tune sink timing and SFX.
- `scenes/perf_benchmark.tscn` — see below.

Run any of them with:
```bash
godot --path /Users/joep/dev/godot res://scenes/<name>.tscn
```

## Performance

Use `scenes/perf_benchmark.tscn` to measure regressions:

```bash
godot --headless --path /Users/joep/dev/godot res://scenes/perf_benchmark.tscn
```

Spawns 4 bots with a fixed overpowered card build (uzi×2 + shotgun + explosive×2 + damage), runs for 15 s after a 3 s warmup, dumps a stats table + JSON to `/tmp/godot_perf_bench.json`. Always run **headless** — macOS won't honour `WINDOW_MODE_MINIMIZED` on a freshly-opened window, and a visible window introduces ~500 ms compositor stalls that pollute `frame_ms`.

A/B isolation modes — pass via `-- mode=NAME`:

- `no_casings` — `procedural_gun.eject_casing()` no-ops
- `no_bullets` — `_rifle_fired` skips spawning the projectile (isolates AI / CharacterBody3D from bullet cost)
- `no_explosion_visuals` — `bullet._handle_collision` skips `_spawn_bullet_blast`
- `no_explosion_audio` — `Violence.spawn_bullet_blast` skips the `SFX.explosion(...)` call
- `no_explosion_audio_or_visuals` — combined floor

All toggles live on `BenchFlags` (`scripts/bench_flags.gd`) — a `class_name` with `static var active`, `no_*`, `event_sink`, and a `BenchFlags.inc(kind)` event counter. `perf_benchmark.gd` sets `BenchFlags.active = true` in `_ready()`. In production it stays `false`, so every hook is gated behind one static-bool branch — no scene-root `.get()` lookups, no string comparisons. **Always use `BenchFlags.active` checks for any new bench instrumentation, never `current_scene.get("bench_*")`.**

What's known about the budget (4-bot stress test):

- Floor (no explosion FX/audio at all): ~5 ms `physics_ms` mean — bullet raycasts + bot AI + 4 `CharacterBody3D` moves
- Each `SFX.explosion(...)` was the biggest offender until the WAV cache landed; visuals are ~0.15 ms each by comparison
- Bot AI bypasses `_fire_rifle()` so any cost added there (heat / bolt / casings) doesn't show up in this bench. Validate human paths separately.

`bench_mode=baseline` should report `physics_ms` mean ~4–7 ms. If it climbs above ~10 ms you've added meaningful per-tick work somewhere.

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

## Build / export

```bash
tools/build_release.sh                       # mac + win → build/{macos,windows}/MoreRounds.zip
tools/build_release.sh all --itch user/game  # build both AND push to itch.io via tools/bin/butler
```

See `README.md` for distribution to LAN playtesters.
