extends Node
## GameNight SDK for Godot 4.
##
## Autoloaded as `GameNight` by the plugin. The integration contract:
##
## 1. Set [member game_id] (project settings or before the first frame).
## 2. Connect to [signal prepared]: load your level, bind inputs to the given
##    seats, then call [method notify_ready]. Don't show anything yet.
## 3. Connect to [signal started]: you are live — start the match instantly.
## 4. When the match ends, call [method notify_finished] and keep rendering
##    until [signal disposed], then tear the session down. A new `prepared`
##    may follow later in the night.
##
## Seats and players arrive as plain Dictionaries matching docs/protocol.md.

## Session lifecycle -----------------------------------------------------------

## Warm up: load everything for these seats, then call notify_ready().
signal prepared(session_id: String, seats: Array, players: Array)
## The transition landed on you. Start the match NOW.
signal started(session_id: String)
signal paused(session_id: String)
signal resumed(session_id: String)
## Tear the session down; the id will never be used again.
signal disposed(session_id: String)

## Connection ------------------------------------------------------------------

signal daemon_connected
signal daemon_disconnected
## Fresh party snapshot (players, seats, playlist, vote...).
signal party_updated(party: Dictionary)
## The party changed one of the settings you declared with
## declare_settings(). Apply it live if a match is running, otherwise from
## the next match. `value` is a bool, int or String per the setting's kind.
signal setting_changed(key: String, value: Variant)

const PROTOCOL_VERSION := 1
const RECONNECT_DELAY := 2.0

## Which title this process runs. Must match the playlist entry's game id.
## Overridden by GAMENIGHT_GAME_ID when the daemon launched us.
@export var game_id: String = ProjectSettings.get_setting("application/config/name", "godot-game").to_lower()
@export var daemon_url: String = "ws://127.0.0.1:7912"
## Reconnect automatically while the daemon is away.
@export var auto_reconnect: bool = true

var party: Dictionary = {}
## True when this process was launched by a GameNight daemon (GAMENIGHT=1).
## Games use this to skip their menu and boot straight into party mode.
var launched_by_daemon: bool = false

var _launch_token: String = ""

var _socket: WebSocketPeer
var _said_hello := false
var _reconnect_at := 0.0

func _ready() -> void:
	# The daemon passes the handshake via environment — same binary boots
	# into game-night mode when launched, runs standalone otherwise.
	launched_by_daemon = OS.get_environment("GAMENIGHT") == "1"
	var env_game_id := OS.get_environment("GAMENIGHT_GAME_ID")
	if env_game_id != "":
		game_id = env_game_id
	var env_addr := OS.get_environment("GAMENIGHT_ADDR")
	if env_addr != "":
		daemon_url = "ws://%s" % env_addr
	var env_overlay_url := OS.get_environment("GAMENIGHT_OVERLAY_URL")
	if env_overlay_url != "":
		overlay_url = env_overlay_url
	_launch_token = OS.get_environment("GAMENIGHT_TOKEN")
	_open()

func _open() -> void:
	_socket = WebSocketPeer.new()
	_said_hello = false
	var err := _socket.connect_to_url(daemon_url)
	if err != OK:
		push_warning("GameNight: cannot reach daemon at %s (%s)" % [daemon_url, err])
		_schedule_reconnect()

func _process(_delta: float) -> void:
	if _socket == null:
		if auto_reconnect and Time.get_ticks_msec() / 1000.0 >= _reconnect_at:
			_open()
		return
	_socket.poll()
	match _socket.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			if not _said_hello:
				_said_hello = true
				var hello := {"type": "hello", "role": "game", "game": game_id}
				if _launch_token != "":
					hello["token"] = _launch_token
				_send(hello)
			while _socket.get_available_packet_count() > 0:
				var text := _socket.get_packet().get_string_from_utf8()
				_handle(JSON.parse_string(text))
		WebSocketPeer.STATE_CLOSED:
			if _said_hello:
				daemon_disconnected.emit()
			_socket = null
			_schedule_reconnect()

func _schedule_reconnect() -> void:
	_reconnect_at = Time.get_ticks_msec() / 1000.0 + RECONNECT_DELAY

## Emitted the moment `ready` goes out, so anything that has been waiting for
## the load to finish can act on it — see screen.gd, which stops spending a
## core on a match nobody is watching yet.
signal ready_sent(session_id: String)

## Assets loaded, controllers mapped: the session can start instantly.
func notify_ready(session_id: String) -> void:
	_send({"type": "ready", "session": session_id})
	ready_sent.emit(session_id)

## The match is over. The daemon takes it from here (vote / transition).
func notify_finished(session_id: String) -> void:
	_send({"type": "finished", "session": session_id})

## Declare the match settings the party may change (items on/off, stock
## count, arena...). Call once, any time after _ready(); the addon re-declares
## automatically after every reconnect. Each entry is a Dictionary matching
## docs/protocol.md, e.g.:
##   { "key": "items", "label": "Items", "kind": "toggle", "default": true }
##   { "key": "stock", "label": "Stock", "kind": "number",
##     "default": 3, "min": 1, "max": 99 }
##   { "key": "arena", "label": "Arena", "kind": "choice",
##     "default": "meadow", "options": ["meadow", "volcano"] }
## Changes arrive via [signal setting_changed]; values the party already
## picked survive reconnects and are replayed right after declaring.
func declare_settings(settings: Array) -> void:
	_declared_settings = settings
	_send({"type": "declare_settings", "settings": settings})

var _declared_settings: Array = []

## Optional: how far along warming is (0-100), so the lobby's screen can show
## the party something truthful while they wait instead of an unchanging
## "loading". Send as often as is useful; the daemon keeps the latest. A game
## that loads instantly never needs to call this.
func notify_progress(session_id: String, percent: int, label: String = "") -> void:
	var msg := {"type": "progress", "session": session_id, "percent": clampi(percent, 0, 100)}
	if label != "":
		msg["label"] = label
	_send(msg)


## A player asked to get back to the party. The daemon pauses this session and
## puts the lobby back on screen — the game does not have to do anything else.
##
## The one party command a game is allowed to send: a player stuck inside a
## game with no way out is the one failure the party cannot fix themselves.
func request_overlay() -> void:
	_send({"type": "request_overlay"})


## A player reached for this window directly — Cmd+Tab, a Dock click, a click
## on the window — rather than going through the party. The pair to
## `request_overlay`: we report what the human did, the daemon decides what it
## means (start us if we're warm, resume us if we're paused, ignore it
## otherwise). Safe to send whenever focus arrives.
func request_start() -> void:
	_send({"type": "request_start"})


## ── Seats ──────────────────────────────────────────────────────────────────

## How many of `seats` hold a person on this machine. This, not the number of
## pads you can see, is your player count.
func local_seat_count(seats: Array) -> int:
	var n := 0
	for seat in seats:
		if typeof(seat) == TYPE_DICTIONARY \
				and str((seat.get("occupant", {}) as Dictionary).get("kind", "")) == "local":
			n += 1
	return n


## How many seats the party wants a bot in. The daemon fills empty seats up to
## your declared `min_players`, so this is usually all the fallback you need
## for "only one person turned up".
func ai_seat_count(seats: Array) -> int:
	var n := 0
	for seat in seats:
		if typeof(seat) == TYPE_DICTIONARY \
				and str((seat.get("occupant", {}) as Dictionary).get("kind", "")) == "ai":
			n += 1
	return n


## Which physical device drives each local seat, in seat order: `[0]` drives
## seat 0. `-1` means keyboard/mouse.
##
## GameNight hands out seats, not controller ids — routing input is the
## daemon's job and it doesn't do it yet — so the mapping is yours to make.
## The rule, and the reasoning, in one place instead of once per game:
##
##  * Connected pads in order. The party seats people in join order and
##    desktop gamepad enumeration follows connection order, so index-to-index
##    is right in practice and self-correcting when it isn't (people swap pads,
##    or the party swaps the seats).
##  * Keyboard/mouse last, and only once. There is one mouse on this machine;
##    handing it to two seats is one mouse turning two heads.
##  * A seat with nothing left to drive it is left out rather than doubled up,
##    and returned short — spawn a bot for the difference if your game needs
##    the numbers.
##
## **Call this on `start`, not on `prepare`.** Warming happens minimised and
## unfocused, where a pad that connects — or gets picked up — need not be
## enumerated for a background process yet.
func devices_for_local_seats(count: int) -> Array:
	var pads := Input.get_connected_joypads()
	var devices: Array = []
	for i in range(count):
		if i < pads.size():
			devices.append(int(pads[i]))
		elif not devices.has(-1):
			devices.append(-1)
		else:
			push_warning("[gamenight] seat %d has no input device left to drive it" % i)
			break
	return devices


func _send(msg: Dictionary) -> void:
	if _socket != null and _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_socket.send_text(JSON.stringify(msg))

## Raise the real party overlay ---------------------------------------------
##
## Nobody should be stranded inside a game with no way back to the party.
## The controller Back/Select button (or F1) raises the *actual* browser
## overlay (overlay/index.html) rather than building a second, inevitably
## inconsistent copy of it inside every engine. Bringing that window to the
## front already pauses the game and opens the party UI on its own — see
## the `focus`/`blur` handling in overlay/index.html — so the game's only
## job here is to raise it.
##
## Deliberately NOT the Guide/Home button: iOS/macOS (GCController) and most
## consoles reserve that button at the OS/shell level and never deliver it to
## the app at all (on a Mac it opens Game Center/Arcade instead) — there's no
## portable way for an engine to intercept it. Back/Select is unclaimed by
## every integration so far and isn't reserved by any platform shell.
##
## Set [member overlay_url] (or `GAMENIGHT_OVERLAY_URL`) to the overlay's
## URL/file path once per machine. Left unset, this is a no-op — deliberately
## no in-game substitute gets built.
@export var overlay_url: String = ""

func _unhandled_input(event: InputEvent) -> void:
	var back: bool = false
	if event is InputEventJoypadButton:
		back = event.button_index == JOY_BUTTON_BACK and event.pressed
	var f1: bool = false
	if event is InputEventKey:
		f1 = event.pressed and not event.echo and event.keycode in [KEY_F1, KEY_F12]
	if not (back or f1):
		return
	# Under a daemon this is a real "back to the party": it pauses us and puts
	# the lobby on screen, which is the whole point — no second, inevitably
	# inconsistent copy of the party UI inside every engine. Only fall back to
	# opening the overlay URL when there is no daemon to ask.
	if launched_by_daemon:
		request_overlay()
	else:
		_raise_overlay()

func _raise_overlay() -> void:
	if overlay_url == "":
		push_warning("GameNight: overlay_url not set (GAMENIGHT_OVERLAY_URL) — cannot raise the party overlay")
		return
	OS.shell_open(overlay_url)

func _handle(msg: Variant) -> void:
	if typeof(msg) != TYPE_DICTIONARY:
		return
	match msg.get("type", ""):
		"welcome":
			party = msg.get("party", {})
			daemon_connected.emit()
			party_updated.emit(party)
			# A reconnect: re-declare so the daemon replays any values the
			# party changed while we were away.
			if not _declared_settings.is_empty():
				_send({"type": "declare_settings", "settings": _declared_settings})
		"party_state":
			party = msg.get("party", {})
			party_updated.emit(party)
		"prepare":
			prepared.emit(msg.get("session", ""), msg.get("seats", []), msg.get("players", []))
		"start":
			started.emit(msg.get("session", ""))
		"pause":
			paused.emit(msg.get("session", ""))
		"resume":
			resumed.emit(msg.get("session", ""))
		"dispose":
			disposed.emit(msg.get("session", ""))
		"setting_changed":
			var value: Variant = msg.get("value")
			if value is float:
				# JSON numbers parse as float; number settings are integers.
				value = int(value)
			setting_changed.emit(msg.get("key", ""), value)
		"error":
			push_warning("GameNight daemon: %s" % msg.get("message", "unknown error"))
