extends Node
## Bridges the GameNight autoload (addons/gamenight/gamenight.gd) to this
## game's scene lifecycle. Owns the prepare -> ready -> start -> finished ->
## dispose state machine across both start_screen.tscn and game.tscn, since
## GameNight's signals fire on a Node that survives scene swaps while
## start_screen.gd / game.gd get freed and reloaded each transition.
##
## Zero effect on standalone play: everything below is gated behind
## GameNight.launched_by_daemon, which is only true when the daemon spawned
## this process with GAMENIGHT=1.

const GAME_SCENE := "res://scenes/game.tscn"
const START_SCENE := "res://scenes/start_screen.tscn"

## Session id of the session currently being played/prepared. game.gd reads
## this (GameNightBridge.current_session_id) so notify_finished can fire
## without threading a session id argument through every call site.
var current_session_id: String = ""

var _pending_seats: Array = []
var _pending_players: Array = []
## Device index to auto-join as seat 1 once the scene lands, or -2 if seat 1
## isn't a local human this session. -1 means keyboard/mouse.
var _pending_second_device: int = -2


func _ready() -> void:
	# Fallback game id for standalone runs / before the daemon's env override
	# is read. GameNight._ready() already applied GAMENIGHT_GAME_ID if the
	# daemon set one — don't clobber that.
	if OS.get_environment("GAMENIGHT_GAME_ID") == "":
		GameNight.game_id = "growing-guns"

	if not GameNight.launched_by_daemon:
		return

	# The project's own fullscreen default (native macOS Space-isolating
	# fullscreen) used to fight the GameNight overlay: a plain NSWindow
	# overlay couldn't render above another app's exclusive-fullscreen Space,
	# so daemon-launched sessions were forced windowed as a workaround. The
	# overlay is now a non-activating NSPanel (canJoinAllSpaces +
	# fullScreenAuxiliary) that composites over fullscreen apps without a
	# Space-switch, so this game can just keep its native fullscreen default.
	#
	# ...except `window/size/mode=3` in project.godot turned out not to be
	# enough on its own — verified via the actual macOS window server that a
	# daemon-launched session (both editor debug-run AND a real exported
	# release build) stayed windowed regardless. Calling it explicitly here,
	# still at `_ready()`, ALSO didn't take — this autoload's `_ready()`
	# fires before the OS window is fully realized, same class of race that
	# broke jumpy's own fullscreen transition when it ran at `Startup`. Wait
	# a few frames for the window to actually exist first.
	#
	# Deliberately NOT called here: taking the screen is what `start` means.
	# The daemon launches us long before anybody asks to play so the match is
	# already loaded when they do, and a warm process that goes fullscreen on
	# boot covers the lobby the party is still standing in.
	_go_quiet()

	GameNight.prepared.connect(_on_prepared)
	GameNight.started.connect(_on_started)
	GameNight.paused.connect(_on_paused)
	GameNight.resumed.connect(_on_resumed)
	GameNight.disposed.connect(_on_disposed)


## ── Warm state ─────────────────────────────────────────────────────────────
##
## Being warm means being a whole running copy of the game that nobody has
## asked to see yet: the point is that the match is already loaded when the
## party picks us, not that we start playing early. So stay silent and out of
## the way until `start` — otherwise the party gets a second window over their
## lobby and two soundtracks at once.

func _go_quiet() -> void:
	print("[gamenight] warm: muted and off-screen until start")
	AudioServer.set_bus_mute(AudioServer.get_bus_index(&"Master"), true)
	# Minimizing is the portable "not on screen" — Godot has no equivalent of
	# AppKit's app-level hide. It does mean the compositor may throttle us
	# while warm, so treat scene loading (which `prepare` does) as the real
	# pre-caching and this as belt and braces.
	_window_mode_deferred(DisplayServer.WINDOW_MODE_MINIMIZED)


func _take_the_screen() -> void:
	print("[gamenight] start: taking the screen")
	AudioServer.set_bus_mute(AudioServer.get_bus_index(&"Master"), false)
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	DisplayServer.window_move_to_foreground()


## The window isn't realized during this autoload's `_ready()` — see the note
## in `_ready`. Anything set before it exists is silently dropped.
func _window_mode_deferred(mode: int) -> void:
	for _i in range(10):
		await get_tree().process_frame
	DisplayServer.window_set_mode(mode)


## ── Session lifecycle ──────────────────────────────────────────────────────

func _on_prepared(session_id: String, seats: Array, players: Array) -> void:
	print("[gamenight] prepare %s (%d seats)" % [session_id, seats.size()])
	current_session_id = session_id
	_pending_seats = seats
	_pending_players = players
	_configure_meta_from_seats(seats)
	get_tree().change_scene_to_file(GAME_SCENE)
	_notify_ready_once_loaded.call_deferred(session_id)


func _configure_meta_from_seats(seats: Array) -> void:
	NetworkManager.set_meta("game_mode", "versus")
	if NetworkManager.has_meta("coop_mode"):
		NetworkManager.remove_meta("coop_mode")

	var seat1_kind := "empty"
	for seat in seats:
		if typeof(seat) == TYPE_DICTIONARY and int(seat.get("index", -1)) == 1:
			var occupant: Dictionary = seat.get("occupant", {})
			seat1_kind = str(occupant.get("kind", "empty"))
			break

	_pending_second_device = -2
	if seat1_kind == "local":
		# A second local human occupies seat 1. GameNight already knows the
		# party is seated — don't make them press a button to confirm what
		# the daemon already told us. Assign real input devices: if two
		# gamepads are connected, seat 0 gets the first and seat 1 gets the
		# second (nobody's assumed to be on keyboard); otherwise seat 0 keeps
		# keyboard/mouse and seat 1 gets the first gamepad.
		var pads := Input.get_connected_joypads()
		var primary_device := -1
		if pads.size() >= 2:
			primary_device = pads[0]
			_pending_second_device = pads[1]
		elif pads.size() == 1:
			_pending_second_device = pads[0]
		else:
			_pending_second_device = -1  # no pads at all; still try keyboard-ish join
		NetworkManager.set_meta("splitscreen_on_start", true)
		NetworkManager.set_meta("splitscreen_primary_device", primary_device)
		if NetworkManager.has_meta("spawn_bot_on_start"):
			NetworkManager.remove_meta("spawn_bot_on_start")
	else:
		# "ai" or "empty" (or any kind we don't special-case yet): versus mode
		# requires 2 players to start (_maybe_start_match), so fall back to a
		# single bot opponent — matches the existing solo-vs-bot behavior
		# game.gd._ready already uses for standalone launches.
		if NetworkManager.has_meta("splitscreen_on_start"):
			NetworkManager.remove_meta("splitscreen_on_start")
		NetworkManager.set_meta("spawn_bot_on_start", true)
		NetworkManager.set_meta("bot_count_on_start", 1)
	NetworkManager.set_meta("host_started", true)


## Wait for game.gd's _ready() to finish (a couple of frames after the scene
## swap lands) before telling the daemon we're ready. The _gamenight_start_gate
## in game.gd is what actually blocks gameplay from starting early, so this
## timing only needs to be "after _ready has run", not exact.
func _notify_ready_once_loaded(session_id: String) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if session_id != current_session_id:
		return  # a newer prepare (or dispose) superseded this one
	_bind_gamenight_seats()
	print("[gamenight] ready %s" % session_id)
	GameNight.notify_ready(session_id)


## GameNight already told us who's seated (Step 2 of prepare) — bind seat 1
## directly instead of waiting for a physical "press X to join", and hide the
## walk-up join prompt since this session's seats are fully decided by the
## party, not by whoever reaches for a spare controller.
func _bind_gamenight_seats() -> void:
	if _pending_second_device == -2:
		return
	var game := get_tree().current_scene
	if game == null:
		return
	var splitscreen: Node = game.get("_splitscreen")
	if splitscreen == null or not splitscreen.has_method("_join_player"):
		return
	splitscreen._join_player(_pending_second_device)
	var join_label: Label = splitscreen.get("_join_label")
	if join_label != null:
		join_label.visible = false


func _on_started(session_id: String) -> void:
	if session_id != current_session_id:
		return
	# This is the transition: the screen and the speakers become ours in the
	# same frame the match is allowed to run.
	_take_the_screen()
	var game := get_tree().current_scene
	if game and game.has_method("_open_gamenight_start_gate"):
		game._open_gamenight_start_gate()


func _on_paused(session_id: String) -> void:
	_freeze_all_players(session_id, true)


func _on_resumed(session_id: String) -> void:
	_freeze_all_players(session_id, false)


func _freeze_all_players(session_id: String, frozen: bool) -> void:
	if session_id != current_session_id:
		return
	var game := get_tree().current_scene
	if game == null:
		return
	var players_root: Node = game.get("players_root")
	if players_root == null:
		return
	for child in players_root.get_children():
		if child.has_method("set_frozen"):
			child.set_frozen.rpc(frozen)


func _on_disposed(session_id: String) -> void:
	if session_id != current_session_id:
		return
	current_session_id = ""
	if get_tree().current_scene and get_tree().current_scene.scene_file_path == GAME_SCENE:
		get_tree().change_scene_to_file(START_SCENE)
	# The process stays resident and may be prepared again later in the night,
	# so go back to being warm rather than sitting on the party's screen.
	_go_quiet()
