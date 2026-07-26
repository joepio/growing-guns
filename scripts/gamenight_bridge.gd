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

## Frame rate while warm and frozen — high enough to answer the daemon
## promptly, low enough that a game nobody is watching isn't spending a core
## redrawing a still image. Lifted the moment we're asked to play.
const WARM_MAX_FPS := 10

## How long to wait after gaining focus for the window to actually come back
## on screen before deciding that it isn't going to — comfortably longer than
## the deminiaturise animation, and short enough that a real Cmd+Tab still
## feels instant. See `_on_focus_in`.
const FOCUS_SETTLE_MS := 1500

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
		# Playing normally: go fullscreen, which is what `window/size/mode=3`
		# used to do for us. It doesn't any more — see `_go_quiet` below for
		# why that had to become a runtime decision — so do it here instead.
		# A frame later than before, and nobody can tell.
		_screen_epoch += 1
		_claim_the_screen(_screen_epoch)
		return

	# Warm means frozen, and freezing means pausing the tree — so the two
	# nodes that must keep running while the rest of the game is stopped say
	# so up front: this bridge, and the socket that will deliver `start`.
	# Without that the game pauses itself and never hears the message that
	# would unpause it.
	process_mode = Node.PROCESS_MODE_ALWAYS
	GameNight.process_mode = Node.PROCESS_MODE_ALWAYS
	# Cmd+Tabbing to a warm game is the party asking to play it. Window focus
	# is the one signal GameNight cannot override — the window server decides
	# who is on screen — so rather than fight it, report it and let the daemon
	# rule on it (see `_on_focus_in`).
	get_window().focus_entered.connect(_on_focus_in)

	# Taking the screen is what `start` means, and nothing before it: the
	# daemon launches us long before anybody asks to play, so the party is
	# looking at the lobby when our window turns up.
	#
	# Which is why `window/size/mode` in project.godot is now 0 (windowed)
	# rather than 3 (fullscreen), with standalone play going fullscreen from
	# `_ready` above instead.
	#
	# That setting applied before a single line of this script ran: the process
	# opened *fullscreen*, covering the lobby and dragging the desktop onto its
	# own macOS Space, and the first thing we then did was minimise it again.
	# On macOS a fullscreen window minimises by way of windowed, so the party
	# watched a game they hadn't asked for open fullscreen, shrink and vanish.
	# Nothing this script can do at `_ready()` is early enough to prevent that
	# — and neither is the command line: Godot 4.7 ignores `--windowed`,
	# `--position` and `--resolution` when the project setting says fullscreen
	# (measured, all three). The setting itself was the only lever.
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

## Bumped every time the window is asked to do something. The two loops below
## run across frames, so a `start` arriving mid-retry would otherwise be
## fighting a still-running "get off the screen" — the party would watch the
## match they just picked minimise itself. Whoever bumps this last wins.
var _screen_epoch: int = 0

## Whether we have ever actually made it off the screen. Until then, focus
## arriving means "your window just opened", not "a player asked for you" —
## see `_on_focus_in`.
var _has_been_out_of_the_way: bool = false


func _go_quiet(why: String = "warm") -> void:
	print("[gamenight] %s: muted and off-screen until start" % why)
	AudioServer.set_bus_mute(AudioServer.get_bus_index(&"Master"), true)
	# Minimizing is the portable "not on screen" — Godot has no equivalent of
	# AppKit's app-level hide. It does mean the compositor may throttle us
	# while warm, so treat scene loading (which `prepare` does) as the real
	# pre-caching and this as belt and braces.
	_screen_epoch += 1
	_leave_the_screen(_screen_epoch)


func _take_the_screen(why: String) -> void:
	print("[gamenight] %s: taking the screen" % why)
	AudioServer.set_bus_mute(AudioServer.get_bus_index(&"Master"), false)
	_screen_epoch += 1
	_claim_the_screen(_screen_epoch)


## How long to let a window-mode change land before asking again. Miniaturise
## and fullscreen are *animated*: ask every frame and each request restarts the
## animation, so it never finishes and the mode never changes — which looks
## exactly like the request being ignored.
##
## Milliseconds, not frames. While warming, frames take as long as loading a
## chunk of arena does — a frame-counted wait is dead time the party spends
## looking at a game they didn't ask for.
const WINDOW_RETRY_MS := 250


## The window isn't realized during this autoload's `_ready()` — see the note
## in `_ready` — and anything set before it exists is silently dropped.
##
## So keep asking until it takes, rather than once after a fixed wait: a fixed
## wait is either too short (the request is dropped and a warm game sits on the
## party's screen for the whole night) or too long — and it is always too long
## here, because the window is up and visible for every frame of it. The party
## watches a game they didn't ask for cover the lobby, exactly during the
## loading the lobby's TV is trying to show them.
func _leave_the_screen(epoch: int) -> void:
	# Back to not stealing focus, so the next time we're warmed behind someone
	# else's match we start out as harmless as we did at launch.
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
	var asked_at := -WINDOW_RETRY_MS
	while epoch == _screen_epoch:
		if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_MINIMIZED:
			# From here on, focus coming back is a person asking for us.
			_has_been_out_of_the_way = true
			return
		var now := Time.get_ticks_msec()
		if now - asked_at >= WINDOW_RETRY_MS:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MINIMIZED)
			asked_at = now
		await get_tree().process_frame


## Same "ask until it takes" shape, in the other direction — and for the same
## reason it can't be a single call: deminiaturising is animated, and a
## fullscreen request that lands while the window is still climbing out of the
## Dock is dropped on the floor. That printed "taking the screen" and then left
## the party looking at a small window, or at whatever was behind us.
func _claim_the_screen(epoch: int) -> void:
	# The window is created no-focus (project.godot), so that warming behind a
	# game the party is playing doesn't yank the screen out from under them —
	# macOS activates a newly launched app the moment it puts up a window, and
	# a warm process doing that is the one thing warming must never do. A
	# no-focus window also ignores every input except mouse clicks, so the flag
	# has to come off the moment we're the game being played.
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, false)
	var asked_at := -WINDOW_RETRY_MS
	while epoch == _screen_epoch:
		var mode := DisplayServer.window_get_mode()
		if mode == DisplayServer.WINDOW_MODE_FULLSCREEN \
				or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN:
			DisplayServer.window_move_to_foreground()
			return
		var now := Time.get_ticks_msec()
		if now - asked_at >= WINDOW_RETRY_MS:
			if mode == DisplayServer.WINDOW_MODE_MINIMIZED:
				DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			else:
				DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
			DisplayServer.window_move_to_foreground()
			asked_at = now
		await get_tree().process_frame


## Somebody switched to our window. Tell the daemon and let it decide: if
## we're warm it starts us, if we're paused it resumes us, otherwise nothing
## happens.
##
## The one thing filtered here, because only this process can tell the
## difference: focus that arrives while we're *still opening*. A newly created
## window is handed focus by the window server as a matter of course, and
## reporting that would mean every warm game starts itself the moment it
## launches — which is the opposite of warming. Once we've actually got off
## the screen, any focus that comes back is a person: they Cmd+Tabbed to us,
## clicked our Dock icon, or pulled us out of the Dock.
func _on_focus_in() -> void:
	if not GameNight.launched_by_daemon:
		return
	if not _has_been_out_of_the_way:
		return
	# Focus alone isn't the signal — the window coming *back* is. macOS
	# activates a freshly launched app as a matter of course, and that fires
	# focus_entered while our window is still sitting minimised in the Dock:
	# taken at face value, every warm game starts itself a second after it
	# launches. A person reaching for us un-minimises us; an app activation
	# does not. Deminiaturising is animated, so give it a moment to happen
	# rather than judging on the first frame.
	var deadline := Time.get_ticks_msec() + FOCUS_SETTLE_MS
	while Time.get_ticks_msec() < deadline:
		if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_MINIMIZED:
			GameNight.request_start()
			return
		await get_tree().process_frame


## ── Session lifecycle ──────────────────────────────────────────────────────

func _on_prepared(session_id: String, seats: Array, players: Array) -> void:
	print("[gamenight] prepare %s (%d seats)" % [session_id, seats.size()])
	current_session_id = session_id
	_pending_seats = seats
	_pending_players = players
	GameNight.notify_progress(session_id, 5, "setting up the match")
	_configure_meta_from_seats(seats)
	GameNight.notify_progress(session_id, 20, "loading the arena")
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
	GameNight.notify_progress(session_id, 70, "generating terrain")
	# The arena generator is the slow part and it runs across several frames
	# after the scene lands, so keep the lobby's screen moving until it's
	# actually done rather than jumping 70 -> ready with a silent gap.
	await _report_arena_progress(session_id)
	_bind_gamenight_seats()
	print("[gamenight] ready %s" % session_id)
	GameNight.notify_progress(session_id, 100, "ready")
	GameNight.notify_ready(session_id)
	# Loaded, and now frozen until somebody asks for us. `_gamenight_start_gate`
	# only holds back the match *state machine*: the arena is still simulating,
	# the bots are still fighting, the players still answer the sticks. So a
	# warm process that becomes visible for even a moment isn't a game about to
	# start — it's a game already in progress that the party can walk into.
	# (It also spends a whole core on a match nobody is watching.) Warm should
	# mean loaded, not playing.
	get_tree().paused = true
	# Pausing stops the simulation but not the renderer, which happily keeps
	# drawing the frozen frame as fast as the GPU allows. Nobody is looking:
	# a handful of frames a second is plenty to stay responsive to `start`,
	# which lifts the cap again. Not capped any earlier than this — loading is
	# what the frames before now were *for*.
	Engine.max_fps = WARM_MAX_FPS


## Follow the arena generator, which is the slow part of warming and runs
## across several frames after the scene lands. Completion is real (the
## generator's own `regenerated` signal); the number in between is a
## time-based ramp, because the generator reports no intermediate progress.
##
## Gives up after a couple of seconds: progress is a courtesy to the people
## waiting, never a gate on play.
func _report_arena_progress(session_id: String) -> void:
	var game := get_tree().current_scene
	var arena: Node = game.get_node_or_null("Arena") if game != null else null
	if arena == null or not arena.has_signal("regenerated"):
		return
	var done := [false]
	arena.regenerated.connect(func(_stats: Dictionary) -> void: done[0] = true, CONNECT_ONE_SHOT)
	var waited := 0.0
	while not done[0] and waited < 2.0:
		if session_id != current_session_id:
			return
		GameNight.notify_progress(
			session_id, 70 + int(minf(waited / 2.0, 1.0) * 25.0), "generating terrain"
		)
		await get_tree().process_frame
		waited += get_process_delta_time()


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
	# This is the transition: the screen, the speakers and the simulation all
	# become ours in the same frame the match is allowed to run. Unpause first
	# — the gate below starts the match, and starting a match inside a paused
	# tree gets the party a still image of one.
	get_tree().paused = false
	Engine.max_fps = 0  # full speed again — we're the thing on the TV now
	_take_the_screen("start")
	var game := get_tree().current_scene
	if game and game.has_method("_open_gamenight_start_gate"):
		game._open_gamenight_start_gate()


func _on_paused(session_id: String) -> void:
	_freeze_all_players(session_id, true)
	if session_id != current_session_id:
		return
	# Pause means the party asked for the lobby, and the lobby is a whole other
	# app — so getting out of the way is part of pausing, not something the
	# lobby can do to us from outside. macOS won't let a background app take
	# focus from the frontmost one, and while we're paused the frontmost one is
	# us: the lobby can ask all it likes and stay invisible behind a game that
	# is no longer running. Stepping aside is what makes room for it.
	_go_quiet("pause")


func _on_resumed(session_id: String) -> void:
	if session_id != current_session_id:
		return
	# Resume is start all over again. Calling up the party doesn't draw an
	# overlay on top of us — it hands the couch's attention to the lobby, a
	# whole other app — so coming back has to be a real window activation.
	# Unfreezing alone left the match running invisibly behind the lobby with
	# no way back into it.
	_take_the_screen("resume")
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
	# Unpause before swapping scenes: the next `prepare` pauses again once it
	# has finished loading, and a scene change into a paused tree would never
	# get the frames it needs to load at all.
	get_tree().paused = false
	Engine.max_fps = 0  # the next prepare needs real frames to load in
	if get_tree().current_scene and get_tree().current_scene.scene_file_path == GAME_SCENE:
		get_tree().change_scene_to_file(START_SCENE)
	# The process stays resident and may be prepared again later in the night,
	# so go back to being warm rather than sitting on the party's screen.
	_go_quiet()
