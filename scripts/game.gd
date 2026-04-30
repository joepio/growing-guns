extends Node3D

const PLAYER_SCENE := preload("res://scenes/player.tscn")
const HUD_ICON_SCRIPT := preload("res://scripts/hud_icon.gd")
const DEV_PANEL_SCRIPT := preload("res://scripts/dev_panel.gd")
const RENDER_PLAYER_SCRIPT := preload("res://scripts/render_player.gd")
const SPLITSCREEN_MANAGER_SCRIPT := preload("res://scripts/splitscreen_manager.gd")

# Maps that can be picked at the start of each round. Server picks an index
# and broadcasts via _swap_arena.rpc(idx) so all peers agree. Add new maps
# here — they need at least one node in the "spawnpoints" group.
const MAP_POOL: Array[PackedScene] = [
	preload("res://scenes/arena_procedural.tscn"),
]
# Position offset applied to whichever arena is loaded — matches the static
# transform game.tscn used to apply to its embedded Arena instance, so spawn
# points and player coords stay consistent across both maps.
const ARENA_OFFSET := Vector3(1.7405052, 4.5380306, 16.383654)

enum State { WAITING, PLAYING, PICKING_CARD, MATCH_OVER }

const CARDS_PER_PICK := 3
const SPAWN_CAPSULE_RADIUS := 0.4
const SPAWN_CAPSULE_HEIGHT := 1.8
const BOT_ID_BASE := 9000
const BOT_ID_LIMIT := 9100  # IDs 9000..9099 are reserved for bots
const BOT_NAME := "BOT"
const BOT_NAME_PREFIXES: PackedStringArray = [
	"Blitz", "Crank", "Dash", "Fang", "Fuse", "Glitch", "Hex", "Jolt",
	"Knock", "Pixel", "Quake", "Rift", "Scrap", "Spark", "Vex", "Zip",
]
const BOT_NAME_SUFFIXES: PackedStringArray = [
	"Byte", "Core", "Drift", "Flux", "Kick", "Loop", "Nail", "Patch",
	"Pulse", "Rush", "Scope", "Shift", "Slug", "Snap", "Volt", "Wire",
]
const SPLIT_PLAYER_ID_BASE := 10000
const IROH_NODE_ID_LENGTH := 52
const IROH_NODE_ID_CHARS := "0123456789abcdefghijklmnopqrstuv"
const JOIN_TIMEOUT_SECONDS := 12.0
const PING_PROBE_INTERVAL := 2.0
const PING_STALE_AFTER_MS := 7000
const HIGH_PING_WARN_MS := 180
const HIGH_PING_WARN_INTERVAL := 8.0
const KILL_FEED_LIFETIME := 3.0
const KILL_FEED_MAX_ITEMS := 6
const LAVA_LEAK_START_SECONDS := 30.0
const LAVA_LEAK_SPREAD_SECONDS := 20.0

func _is_bot_id(pid: int) -> bool:
	return pid >= BOT_ID_BASE and pid < BOT_ID_LIMIT

func _bot_ids() -> Array[int]:
	var out: Array[int] = []
	for raw_id in NetworkManager.players:
		var pid := int(raw_id)
		if _is_bot_id(pid):
			out.append(pid)
	return out

func _human_count() -> int:
	var n: int = 0
	for raw_id in NetworkManager.players:
		if not _is_bot_id(int(raw_id)):
			n += 1
	return n
const SPAWN_MIN_SPACING := 8.0   # meters — two fresh spawns must be at least this far apart

var rounds_to_win: int = 10

@onready var players_root: Node3D = $Players
@onready var scoreboard: Label = $HUD/Scoreboard
@onready var round_banner: Label = $HUD/RoundBanner
@onready var banner_timer: Timer = $HUD/BannerTimer

var state: int = State.WAITING
var round_wins: Dictionary = {}
var current_round: int = 1
var pending_pick_cards: Array = []
var pending_picker_id: int = 0
var pending_pick_cards_by_player: Dictionary = {}
var completed_picks: Dictionary = {}
var eliminated_players: Dictionary = {}
var round_winner_id: int = 0
var _round_music_level: int = 1
var _round_damage_seen: bool = false
var _round_elapsed: float = 0.0
var _lava_leak_started: bool = false
var local_player: Node3D

# --- Match over / rematch ---
var _rematch_overlay: Control = null
var _rematch_subtitle: Label = null
var _extend_button: Button = null
var _exit_to_menu_button: Button = null
var _rematch_requested: bool = false
var _extend_votes: Dictionary = {} # id -> bool

# --- Dev panel (F1) ---
# Owned by scripts/dev_panel.gd, instantiated in _ready and added under $HUD.
# Stays null in release builds (no --dev flag) — cheats are unreachable.
var _dev_panel: Node = null


func _dev_tools_enabled() -> bool:
	# Editor + debug exports → on. Release exports → off unless the user
	# explicitly opts in by passing --dev on the command line.
	if OS.is_debug_build():
		return true
	return "--dev" in OS.get_cmdline_args()
# Dev-only: bots keep full AI (targeting, chasing, aiming) but never fire.
# Read by Player AI; mutated by F1 panel toggle and the P keybinding.
var bots_hold_fire: bool = false

# --- Tab scoreboard overlay ---
var _tab_root: PanelContainer = null
var _tab_content: VBoxContainer = null

# --- Pause menu (ESC) ---
var _pause_menu: Control = null
var _network_status_panel: PanelContainer = null
var _network_status_label: Label = null
var _network_status_hide_token: int = 0
var _kill_feed: VBoxContainer = null
var _splitscreen_hint: Label = null
var _join_auto_submit_text: String = ""
var _join_in_progress: bool = false
var _ping_ms_by_player: Dictionary = {}
var _ping_pending: Dictionary = {}
var _bot_appearance_seeds: Dictionary = {}
var _ping_seq: int = 0
var _ping_probe_timer: float = 0.0
var _high_ping_warn_timer: float = 0.0
var _tab_refresh_timer: float = 0.0
var _explosion_flash_overlay: ColorRect = null
var _arena_env: Environment = null
var _base_tonemap_exposure: float = 1.0
var _exposure_duck: float = 0.0
var _exposure_duck_vel: float = 0.0
var _flash_alpha: float = 0.0
var _flash_alpha_vel: float = 0.0
# Target the alpha lerps TOWARD on the rise — instant set on _flash_alpha
# tears visibly with vsync off (a single frame jumping 0 -> 0.8 splits the
# screen). Ramping over a couple frames keeps per-frame change small.
var _flash_alpha_target: float = 0.0

var _last_input_was_controller := false
var _last_controller_device: int = -1
# Owned by scripts/splitscreen_manager.gd, instantiated in _ready as a child
# Node. Reads NetworkManager metadata to decide whether to build its layer.
var _splitscreen: Node = null
var _render_layer: CanvasLayer = null
var _render_root: Control = null
var _render_players: Dictionary = {}
var _audio_panel: AudioSettingsPanel = null

func _ready() -> void:
	ProceduralMusic.set_energy(1, true)
	_install_controller_input_map()
	# Splitscreen manager: builds a CanvasLayer + per-device viewports if the
	# NetworkManager flag is set. Inert otherwise (still a Node, but no UI).
	_splitscreen = SPLITSCREEN_MANAGER_SCRIPT.new()
	_splitscreen.name = "Splitscreen"
	add_child(_splitscreen)
	_splitscreen.setup(self)
	# F2 brings up the live audio-tuning panel — same sliders as action_lab.
	_audio_panel = AudioSettingsPanel.new()
	add_child(_audio_panel)

	# Always-process so the retro-shader cursor + mouse-mode keep updating
	# while the world is paused (pause menu open). Gameplay-tickling parts of
	# _process and _input are guarded with explicit get_tree().paused checks
	# below so they still pause correctly.
	process_mode = Node.PROCESS_MODE_ALWAYS

	# Networking auto-bootstrap moved further down — see the IrohServer.start()
	# call right before the multiplayer.is_server() branch. Iroh is the only
	# transport now; LAN/ENet auto-connect was removed with the main menu.

	NetworkManager.player_list_changed.connect(_update_scoreboard)
	NetworkManager.player_list_changed.connect(_refresh_bot_counter)
	if not NetworkManager.network_status_changed.is_connected(_on_network_status_changed):
		NetworkManager.network_status_changed.connect(_on_network_status_changed)
	banner_timer.timeout.connect(func() -> void: round_banner.visible = false)
	round_banner.visible = false
	scoreboard.visible = false
	_build_rematch_overlay()
	_build_custom_cursor()
	_build_explosion_flash_overlay()
	_build_retro_filter()
	_build_network_status_panel()
	_build_kill_feed()
	_build_splitscreen_hint()
	Input.joy_connection_changed.connect(_on_joy_connection_changed)
	_refresh_splitscreen_hint()
	if NetworkManager.has_meta("network_notice"):
		var notice := str(NetworkManager.get_meta("network_notice"))
		NetworkManager.remove_meta("network_notice")
		_on_network_status_changed(notice, true)
	if not NetworkManager.last_network_error.is_empty():
		_on_network_status_changed(NetworkManager.last_network_error, true)
	_load_settings()
	_apply_settings()
	# Web-zip distribution doesn't auto-update like the itch.io app does —
	# this fires a one-shot HTTPRequest against the repo's VERSION file and
	# pops a tiny "click to download" button if the released version is
	# newer than the build the user is running.
	add_child(preload("res://scripts/version_check.gd").new())
	_build_tab_overlay()
	# Dev panel (F1) — cheats. Only built in debug runs (editor + debug
	# exports) or when --dev is on the command line. Released zips ship
	# without it so the F1 panel + G/P/M/1-5 cheat hotkeys are dormant.
	if _dev_tools_enabled():
		_dev_panel = DEV_PANEL_SCRIPT.new()
		_dev_panel.setup(self)
		$HUD.add_child(_dev_panel)
	var we := $Arena/WorldEnvironment
	if we and we.environment:
		_arena_env = we.environment
		_base_tonemap_exposure = _arena_env.tonemap_exposure

	# First-launch name prompt. We persist the chosen callsign in
	# settings.cfg [player] name; if we never asked, block the boot until
	# the player gives us one. The HUD is already built (see _build_*
	# calls above), so the modal can attach to $HUD now.
	if _player_name.is_empty():
		_show_name_prompt()
		await self._player_name_set
	NetworkManager.local_player_name = _player_name

	# Auto-host an iroh server unless we're already wired to a real peer
	# (e.g. the user just clicked Join in the pause menu, which set up an
	# IrohClient before reloading the scene). This is what makes the boot
	# experience "open game → playing immediately, ID ready to share".
	# Godot 4 installs a default OfflineMultiplayerPeer when no peer is set,
	# so a plain `== null` check never fires — must also reject that.
	if multiplayer.multiplayer_peer == null \
			or multiplayer.multiplayer_peer is OfflineMultiplayerPeer:
		var hosted_id := NetworkManager.host_game_iroh(_player_name)
		if hosted_id.is_empty() and not NetworkManager.last_network_error.is_empty():
			_on_network_status_changed(NetworkManager.last_network_error, true)

	if multiplayer.is_server():
		if not multiplayer.peer_connected.is_connected(_on_peer_connected):
			multiplayer.peer_connected.connect(_on_peer_connected)
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
		for pid in NetworkManager.players:
			round_wins[pid] = 0
			_spawn_player(pid, NetworkManager.players[pid])

		var bot_requested: bool = NetworkManager.has_meta("spawn_bot_on_start") and NetworkManager.get_meta("spawn_bot_on_start")
		var requested_count: int = int(NetworkManager.get_meta("bot_count_on_start", 1)) if bot_requested else 0
		if bot_requested:
			_spawn_bots(requested_count)
		_maybe_start_match()

		# Solo-vs-AI fallback: with the main menu gone, every fresh launch
		# of game.tscn lands here as the iroh host with no peers yet — give
		# the player a bot to fight while the lobby waits for friends.
		# `host_started` meta lets a future flow (pause-menu "host empty
		# lobby"?) opt out; the splitscreen path also opts out because each
		# device adds its own real player.
		var host_started: bool = NetworkManager.has_meta("host_started") and NetworkManager.get_meta("host_started")
		if not bot_requested and not host_started and not _splitscreen.is_enabled():
			_spawn_bots.call_deferred(1)

		# Iroh host: re-show the "ID copied — share it" notice on the in-game
		# banner. Called locally (not .rpc) so only the host sees it. Sticks
		# until a friend joins and _maybe_start_match overwrites the banner.
		# Cleared so a manual restart-match later doesn't re-announce stale info.
		if NetworkManager.get_meta("iroh_host_announce_share", false):
			_announce("MATCH ID COPIED TO CLIPBOARD\nShare with your friends!", 99.0)
			NetworkManager.set_meta("iroh_host_announce_share", false)
	else:
		# Instantly show the client state — makes it obvious when you thought
		# you were solo but actually joined an orphan on port 27015.
		round_banner.text = "CONNECTING TO HOST…"
		round_banner.visible = true
		banner_timer.stop()
		_client_request_spawn_when_ready()

	_update_scoreboard()
	# Splitscreen manager auto-builds its layer in its own _ready when enabled.

func _track_input_device(event: InputEvent) -> void:
	var controller_input := event is InputEventJoypadButton or event is InputEventJoypadMotion
	var keyboard_mouse_input := event is InputEventKey or event is InputEventMouseButton or event is InputEventMouseMotion
	if controller_input:
		if event is InputEventJoypadMotion and absf(event.axis_value) < 0.18:
			return
		_last_controller_device = event.device
		_set_controller_hud_icons(true)
	elif keyboard_mouse_input:
		if event is InputEventMouseMotion and event.relative.length_squared() < 0.01:
			return
		_set_controller_hud_icons(false)

func _set_controller_hud_icons(enabled: bool) -> void:
	if _last_input_was_controller == enabled:
		return
	_last_input_was_controller = enabled
	HUD_ICON_SCRIPT.use_controller_icons = enabled
	get_tree().call_group("hud_input_icons", "_refresh_input_device")
	_refresh_splitscreen_hint()

func _install_controller_input_map() -> void:
	_add_joy_axis_action("move_left", JOY_AXIS_LEFT_X, -1.0)
	_add_joy_axis_action("move_right", JOY_AXIS_LEFT_X, 1.0)
	_add_joy_axis_action("move_forward", JOY_AXIS_LEFT_Y, -1.0)
	_add_joy_axis_action("move_back", JOY_AXIS_LEFT_Y, 1.0)
	_add_joy_axis_action("shoot", JOY_AXIS_TRIGGER_RIGHT, 1.0)
	_add_joy_axis_action("shoot_grenade", JOY_AXIS_TRIGGER_LEFT, 1.0)
	_add_joy_button_action("shoot_grenade", JOY_BUTTON_B)
	_add_joy_button_action("jump", JOY_BUTTON_LEFT_SHOULDER)
	_add_joy_button_action("jump", JOY_BUTTON_A)
	_add_joy_button_action("reload", JOY_BUTTON_X)
	_add_joy_button_action("dash", JOY_BUTTON_RIGHT_SHOULDER)
	_add_joy_button_action("dash", JOY_BUTTON_Y)
	_add_joy_button_action("ui_accept", JOY_BUTTON_A)
	_add_joy_button_action("ui_accept", JOY_BUTTON_X)
	_add_joy_button_action("ui_cancel", JOY_BUTTON_START)
	_add_joy_button_action("ui_left", JOY_BUTTON_DPAD_LEFT)
	_add_joy_button_action("ui_right", JOY_BUTTON_DPAD_RIGHT)
	_add_joy_button_action("ui_up", JOY_BUTTON_DPAD_UP)
	_add_joy_button_action("ui_down", JOY_BUTTON_DPAD_DOWN)
	_add_joy_axis_action("ui_left", JOY_AXIS_LEFT_X, -1.0)
	_add_joy_axis_action("ui_right", JOY_AXIS_LEFT_X, 1.0)
	_add_joy_axis_action("ui_up", JOY_AXIS_LEFT_Y, -1.0)
	_add_joy_axis_action("ui_down", JOY_AXIS_LEFT_Y, 1.0)

func _add_joy_button_action(action: StringName, button_index: int) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	var event := InputEventJoypadButton.new()
	event.button_index = button_index
	if not InputMap.action_has_event(action, event):
		InputMap.action_add_event(action, event)

func _add_joy_axis_action(action: StringName, axis: int, axis_value: float) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	var event := InputEventJoypadMotion.new()
	event.axis = axis
	event.axis_value = axis_value
	if not InputMap.action_has_event(action, event):
		InputMap.action_add_event(action, event)

func _ensure_render_player(player_id: int, input_device: int = -1) -> RenderPlayer:
	if _render_players.has(player_id):
		return _render_players[player_id] as RenderPlayer
	_build_render_layer()
	var renderer := RENDER_PLAYER_SCRIPT.new() as RenderPlayer
	renderer.name = "RenderPlayer_%d" % player_id
	_render_root.add_child(renderer)
	renderer.setup(self, player_id, input_device)
	renderer.card_selected.connect(_on_render_player_card_selected)
	_render_players[player_id] = renderer
	_update_render_player_layouts()
	return renderer

func _remove_render_player(player_id: int) -> void:
	var renderer := _render_players.get(player_id) as Node
	if renderer and is_instance_valid(renderer):
		renderer.queue_free()
	_render_players.erase(player_id)

func _clear_render_players() -> void:
	for id in _render_players.keys():
		_remove_render_player(int(id))

func _build_render_layer() -> void:
	if _render_layer:
		return
	_render_layer = CanvasLayer.new()
	_render_layer.name = "RenderLayer"
	_render_layer.layer = 0
	add_child(_render_layer)
	_render_root = Control.new()
	_render_root.name = "RenderPlayers"
	_render_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_render_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_render_layer.add_child(_render_root)
	_render_root.resized.connect(_update_render_player_layouts)

func _update_render_player_layouts() -> void:
	if _render_root == null:
		return
	var size := _render_root.get_rect().size
	if size.x <= 0.0 or size.y <= 0.0:
		size = get_viewport().get_visible_rect().size
	for renderer in _render_players.values():
		var rp := renderer as RenderPlayer
		rp.position = Vector2.ZERO
		rp.size = size
		rp.layout_for_size(size)

func _handle_render_player_input(event: InputEvent) -> bool:
	for renderer in _render_players.values():
		if renderer.handle_input(event):
			return true
	return false

func _client_request_spawn_when_ready() -> void:
	# The scene change happens before `connected_to_server` fires, so the
	# client can reach _ready with a peer that isn't fully connected yet.
	# RPCs sent in that window are dropped silently — wait for the signal.
	var peer := multiplayer.multiplayer_peer
	if peer and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		_request_spawn.rpc_id(1, NetworkManager.local_player_name)
		return
	multiplayer.connected_to_server.connect(
		func() -> void: _request_spawn.rpc_id(1, NetworkManager.local_player_name),
		CONNECT_ONE_SHOT,
	)
	get_tree().create_timer(JOIN_TIMEOUT_SECONDS).timeout.connect(_on_join_timeout)


func _on_join_timeout() -> void:
	var peer := multiplayer.multiplayer_peer
	if peer == null or peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		return
	var message := "Connection timed out. Confirm the match ID, make sure the host is still running, and allow the game through Windows Firewall."
	NetworkManager.last_network_error = message
	NetworkManager.set_meta("network_notice", message)
	NetworkManager.leave_game()
	get_tree().change_scene_to_file("res://scenes/game.tscn")

func _process(delta: float) -> void:
	_update_explosion_sidechain(delta)
	_sync_mouse_mode()
	_update_ping_monitor(delta)
	if _tab_root and _tab_root.visible:
		_tab_refresh_timer -= delta
		if _tab_refresh_timer <= 0.0:
			_tab_refresh_timer = 0.5
			_refresh_tab_overlay()
	if multiplayer.is_server() and state == State.PLAYING:
		_update_lava_leak(delta)
		_update_round_music_phase()
	_update_custom_cursor()
	# Polling-based pause toggle. On macOS, pressing Esc while the mouse is
	# captured auto-uncaptures it at the engine level and the resulting
	# InputEventKey doesn't reliably propagate to Game._input — but the
	# Input singleton's action state still flips for one frame, which polls
	# fine from here. Gating on `paused` avoids double-toggling alongside
	# the pause menu's Resume-button Shortcut.
	if Input.is_action_just_pressed("ui_cancel") and not get_tree().paused:
		if _dev_panel != null and _dev_panel.is_open():
			_dev_panel.toggle()
			_sync_mouse_mode()
		else:
			_toggle_pause_menu()
		return
	_update_render_player_layouts()

	# Tab is handled in _input — Godot's GUI focus navigation eats the Tab key
	# before _process polling can see it, so we intercept it earlier.

func _input(event: InputEvent) -> void:
	_track_input_device(event)
	var cancel_pressed := event.is_action_pressed("ui_cancel")
	if cancel_pressed:
		if _settings_panel != null and _settings_panel.visible:
			_close_settings()
			get_viewport().set_input_as_handled()
			return
		if _pause_menu != null and _pause_menu.visible:
			_toggle_pause_menu()
			get_viewport().set_input_as_handled()
			return

	# When solo play pauses the scene tree, only pause/menu close handling
	# above should continue through Game._input.
	if get_tree().paused:
		return
	if _splitscreen and _splitscreen.handle_input(event):
		get_viewport().set_input_as_handled()
		return
	if _handle_render_player_input(event):
		get_viewport().set_input_as_handled()
		return

	# Tab hold = scoreboard overlay. Use _input (not _unhandled_input) so we
	# beat the viewport's GUI focus navigation, which would otherwise consume
	# Tab and prevent our polling from ever seeing it.
	if event is InputEventKey and not event.echo and event.keycode == KEY_TAB:
		if event.pressed:
			_show_tab_overlay()
		else:
			_hide_tab_overlay()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F1:
		if _dev_panel != null:
			_dev_panel.toggle()
			_sync_mouse_mode()
		return

	# Pause menu: ui_cancel (Esc / Start), Enter, and numpad Enter.
	var pause_pressed: bool = cancel_pressed \
		or (event is InputEventKey and event.pressed and not event.echo and (
			event.keycode == KEY_ENTER \
			or event.keycode == KEY_KP_ENTER
		))
	if pause_pressed:
		if _dev_panel != null and _dev_panel.is_open():
			_dev_panel.toggle()
			_sync_mouse_mode()
			return
		_toggle_pause_menu()
		return

	# Cheat hotkeys (G / P / M / L / 1-5 / ?) — only when dev tools are enabled.
	if event is InputEventKey and event.pressed and not event.echo and _dev_panel != null:
		var cheat_handled := true
		match event.keycode:
			KEY_G:
				var t = _dev_panel.get_target()
				if t:
					t.god_mode = not t.god_mode
					_announce.rpc("GODMODE: %s" % ("ON" if t.god_mode else "OFF"), 1.0)
					_dev_panel.refresh_if_visible()
			KEY_P:
				bots_hold_fire = not bots_hold_fire
				_announce.rpc("PASSIVE AI: %s" % ("ON" if bots_hold_fire else "OFF"), 1.0)
				_dev_panel.refresh_if_visible()
			KEY_M:
				if multiplayer.is_server():
					_restart_match()
			KEY_L:
				if multiplayer.is_server():
					_lava_leak_started = true
					_start_lava_leak.rpc(LAVA_LEAK_SPREAD_SECONDS)
					_announce.rpc("LAVA TRIGGERED", 1.0)
			KEY_1:
				var t = _dev_panel.get_target()
				if t:
					t.reset_weapon.rpc()
					_announce.rpc("WEAPON RESET", 1.0)
					_dev_panel.refresh_if_visible()
			KEY_2:
				var t = _dev_panel.get_target()
				if t:
					t.apply_card.rpc("sniper")
					_announce.rpc("APPLIED: SNIPER", 1.0)
					_dev_panel.refresh_if_visible()
			KEY_3:
				var t = _dev_panel.get_target()
				if t:
					t.apply_card.rpc("shotgun")
					_announce.rpc("APPLIED: SHOTGUN", 1.0)
					_dev_panel.refresh_if_visible()
			KEY_4:
				var t = _dev_panel.get_target()
				if t:
					t.apply_card.rpc("uzi")
					_announce.rpc("APPLIED: UZI", 1.0)
					_dev_panel.refresh_if_visible()
			KEY_5:
				var t = _dev_panel.get_target()
				if t:
					t.apply_card.rpc("bazooka")
					_announce.rpc("APPLIED: BAZOOKA", 1.0)
					_dev_panel.refresh_if_visible()
			KEY_SLASH:
				if event.shift_pressed: # '?'
					_dev_panel.show_help()
			_:
				cheat_handled = false

		if cheat_handled:
			get_viewport().set_input_as_handled()
			return

# -------------------- SPAWN / DESPAWN --------------------

func _on_peer_connected(_id: int) -> void:
	if not multiplayer.is_server():
		return
	# The boot-time bot is only a solo fallback. As soon as a real remote peer
	# arrives, remove it before the joining player spawns so the default match
	# becomes humans-only.
	_despawn_all_bots()


func _on_peer_disconnected(id: int) -> void:
	if not multiplayer.is_server():
		return
	var node := players_root.get_node_or_null(str(id))
	if node:
		_despawn.rpc(id)
	round_wins.erase(id)
	_broadcast_scores.rpc(round_wins)
	if state == State.PICKING_CARD and id == pending_picker_id:
		_hide_card_pick.rpc()
		state = State.PLAYING
	pending_pick_cards_by_player.erase(id)
	completed_picks.erase(id)
	eliminated_players.erase(id)
	_ping_ms_by_player.erase(id)
	for seq in _ping_pending.keys():
		if int(_ping_pending[seq].get("peer", 0)) == id:
			_ping_pending.erase(seq)
	_broadcast_ping_ms.rpc(_ping_ms_by_player)
	if NetworkManager.players.size() < 2:
		state = State.WAITING
		_hide_card_pick.rpc()
		_hide_rematch_overlay.rpc()
		_announce.rpc("WAITING FOR PLAYERS…", 99.0)

@rpc("any_peer", "call_local", "reliable")
func _request_spawn(pname: String) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = 1
	# A real peer is joining — boot any SP bots that are around.
	_despawn_all_bots()
	NetworkManager.players[sender] = pname
	if not round_wins.has(sender):
		round_wins[sender] = 0
	_ping_ms_by_player[sender] = -1
	# Ship the current map to the joiner before spawning them. The embedded
	# arena_procedural in game.tscn has regenerate_on_ready=false, so a
	# fresh client's local Arena has no floor / walls / spawnpoints until a
	# _swap_arena RPC arrives. That RPC normally only fires at round start,
	# so a mid-round join would otherwise teleport the player onto a server-
	# valid position that doesn't exist on their client → fall into lava.
	# Targeting just the joiner via rpc_id keeps existing peers untouched.
	if state != State.WAITING and current_map_index >= 0 and current_map_index < MAP_POOL.size():
		_swap_arena.rpc_id(sender, current_map_index, current_map_seed)
	_spawn_player(sender, pname)
	for pid in NetworkManager.players:
		if players_root.has_node(str(pid)) and pid != sender:
			var existing := players_root.get_node(str(pid)) as Node3D
			if existing == null:
				continue
			_do_spawn.rpc_id(sender, pid, NetworkManager.players[pid],
				existing.global_position, _is_bot_id(int(pid)), -1, false, existing.rotation.y,
				int(_bot_appearance_seeds.get(pid, 0)))
	_broadcast_scores.rpc(round_wins)
	_maybe_start_match()

func _spawn_player(id: int, pname: String) -> void:
	# Avoid dropping a new player on top of anyone already in the arena.
	var pick := _pick_spawn(_current_player_positions())
	_do_spawn.rpc(id, pname, pick["pos"], false, -1, false, pick["yaw"])

func _current_player_positions() -> Array[Vector3]:
	var out: Array[Vector3] = []
	for child in players_root.get_children():
		if child is Node3D:
			out.append((child as Node3D).global_position)
	return out

func _pick_spawn(avoid: Array[Vector3] = []) -> Dictionary:
	# Returns {"pos": Vector3, "yaw": float}. Picks the spawnpoint that maximizes
	#   min_distance(other_spawns) - height_penalty
	# so respawning players land far from each other and at roughly the same
	# height as the first one already placed this round. Yaw faces the arena
	# center unless that direction is blocked by a wall within 3m, in which
	# case we try perpendicular and back-facing yaws.
	var spawns := get_tree().get_nodes_in_group("spawnpoints")
	if spawns.is_empty():
		# Belt-and-suspenders: if we somehow get here while no arena spawn
		# nodes exist, plant the player at the arena's center at safe
		# height instead of world (0, 3, 0). The arena lives at
		# ARENA_OFFSET; world (0, 3, 0) sits in lava and outside the
		# floor — players spawning there fall straight to their death.
		var fb_arena: Node = get_node_or_null("Arena")
		var fb_origin: Vector3 = (fb_arena as Node3D).global_position if fb_arena and fb_arena is Node3D else Vector3.ZERO
		return {"pos": fb_origin + Vector3(0, 5, 0), "yaw": 0.0}

	# Anchor for the height-match bonus: the first spawn already placed this
	# pass, if any. With nothing placed yet, target_y is unused.
	var has_target_y: bool = not avoid.is_empty()
	var target_y: float = avoid[0].y if has_target_y else 0.0

	var arena: Node = get_node_or_null("Arena")
	var arena_origin: Vector3 = (arena as Node3D).global_position if arena and arena is Node3D else Vector3.ZERO

	# Shuffle so all-tied scores still rotate spawn picks across rounds.
	spawns.shuffle()

	var best_pos: Vector3 = Vector3.ZERO
	var best_yaw: float = 0.0
	var best_score: float = -INF
	var found_clear: bool = false
	for spawn in spawns:
		var pos: Vector3 = spawn.global_position
		if not _spawn_is_clear(pos):
			continue
		found_clear = true
		var min_d: float = _min_distance(pos, avoid) if not avoid.is_empty() else 100.0
		# Heavy penalty when below the SPAWN_MIN_SPACING bar — but candidate
		# stays in contention so we have something to fall back to.
		if min_d < SPAWN_MIN_SPACING:
			min_d *= 0.1
		var height_penalty: float = absf(pos.y - target_y) * 1.5 if has_target_y else 0.0
		var score: float = min_d - height_penalty
		if score > best_score:
			best_score = score
			best_pos = pos
			best_yaw = _spawn_yaw_at(pos, arena_origin)

	if found_clear:
		return {"pos": best_pos, "yaw": best_yaw}
	# Last-ditch fallback: physics-blocked everywhere. Return the first spawn
	# anyway so the round still runs.
	var fb: Vector3 = (spawns[0] as Node3D).global_position
	return {"pos": fb, "yaw": _spawn_yaw_at(fb, arena_origin)}


func _min_distance(pos: Vector3, others: Array[Vector3]) -> float:
	var best: float = INF
	for o in others:
		var d: float = pos.distance_to(o)
		if d < best:
			best = d
	return best


func _spawn_yaw_at(pos: Vector3, arena_origin: Vector3) -> float:
	# Default: face the arena center. yaw is the body's rotation around Y;
	# at yaw=0 the player looks toward -Z, so atan2(dx, dz) gives the yaw
	# that turns -Z onto the (pos → center) → -Z direction.
	var dx: float = pos.x - arena_origin.x
	var dz: float = pos.z - arena_origin.z
	var center_yaw: float = atan2(dx, dz) if (dx * dx + dz * dz) > 0.01 else 0.0
	# If a wall blocks the center-facing direction within 3m, try perpendicular
	# yaws and finally a 180° flip. First non-blocked direction wins.
	var candidates: Array[float] = [
		center_yaw,
		center_yaw + PI * 0.5,
		center_yaw - PI * 0.5,
		center_yaw + PI,
	]
	for y in candidates:
		if not _wall_within(pos, y, 3.0):
			return y
	return center_yaw


func _wall_within(pos: Vector3, yaw: float, dist: float) -> bool:
	var fwd: Vector3 = Vector3(-sin(yaw), 0, -cos(yaw))
	var head: Vector3 = pos + Vector3(0, 1.6, 0)
	var to: Vector3 = head + fwd * dist
	var query := PhysicsRayQueryParameters3D.create(head, to, 1)
	var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(query)
	return not hit.is_empty()

func _spawn_is_clear(pos: Vector3) -> bool:
	var shape := CapsuleShape3D.new()
	shape.radius = SPAWN_CAPSULE_RADIUS
	shape.height = SPAWN_CAPSULE_HEIGHT
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = Transform3D(Basis.IDENTITY, pos)
	query.collision_mask = 1
	return get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty()

@rpc("authority", "call_local", "reliable")
func _do_spawn(
	id: int,
	pname: String,
	pos: Vector3,
	bot: bool = false,
	input_device: int = -1,
	split_local: bool = false,
	yaw: float = 0.0,
	appearance_seed: int = 0,
) -> void:
	if players_root.has_node(str(id)):
		return
	var p := PLAYER_SCENE.instantiate()
	p.name = str(id)
	p.player_id = id
	p.is_bot = bot
	p.player_name = pname
	p.appearance_seed = appearance_seed
	p.local_input_device = input_device
	p.split_screen_local = split_local
	p.set_multiplayer_authority(1 if (bot or split_local) else id)
	players_root.add_child(p, true)
	# global_position / rotation must be set after add_child — they require
	# being in-tree.
	p.global_position = pos
	p.rotation.y = yaw
	if id == multiplayer.get_unique_id():
		local_player = p
		# Push the saved mouse-sens slider value onto the freshly spawned
		# local player so first mouse-look frame already uses it.
		_apply_mouse_sens_to_local()
		# Attach the raytraced-audio listener under the local player's camera.
		# Only one listener should be in the scene at a time. Owner needs a
		# valid transform — the plugin reads owner.transform.basis.x for
		# ambient pan and crashes if it's null.
		var cam: Camera3D = p.get_node_or_null("Camera") as Camera3D
		if cam:
			var listener := RaytracedAudioListener.new()
			cam.add_child(listener)
			listener.owner = cam
		if not (_splitscreen and _splitscreen.is_enabled()):
			_ensure_render_player(id, p.local_input_device)
	if _splitscreen and _splitscreen.is_enabled() and split_local:
		# Manager owns the device→player_id map server-side; on clients we
		# just need the view layout refreshed so the new SubViewport appears.
		_splitscreen.update_views()

@rpc("authority", "call_local", "reliable")
func _despawn(id: int) -> void:
	var node := players_root.get_node_or_null(str(id))
	if node:
		node.queue_free()
	if id == multiplayer.get_unique_id():
		local_player = null
	_remove_render_player(id)

# -------------------- SINGLE-PLAYER BOT --------------------

func _spawn_bots(count: int) -> void:
	if not multiplayer.is_server() or count <= 0:
		return
	var spawned_any := false
	for _i in count:
		var pid := _next_bot_id()
		if pid == 0:
			continue
		var bot_name := _random_bot_name(pid)
		var appearance_seed := randi() & 0x7fffffff
		_bot_appearance_seeds[pid] = appearance_seed
		NetworkManager.players[pid] = bot_name
		round_wins[pid] = 0
		_ping_ms_by_player[pid] = -1
		var bot_pick := _pick_spawn(_current_player_positions())
		_do_spawn.rpc(pid, bot_name, bot_pick["pos"], true, -1, false, bot_pick["yaw"], appearance_seed)
		spawned_any = true
	if spawned_any:
		NetworkManager.player_list_changed.emit()
		_broadcast_scores.rpc(round_wins)
		_maybe_start_match()
		_refresh_bot_counter()


func _next_bot_id() -> int:
	for pid in range(BOT_ID_BASE, BOT_ID_LIMIT):
		if not NetworkManager.players.has(pid) and not players_root.has_node(str(pid)):
			return pid
	return 0


func _random_bot_name(pid: int) -> String:
	var prefix := BOT_NAME_PREFIXES[randi() % BOT_NAME_PREFIXES.size()]
	var suffix := BOT_NAME_SUFFIXES[randi() % BOT_NAME_SUFFIXES.size()]
	var serial := 10 + ((pid - BOT_ID_BASE + randi()) % 90)
	return "%s %s %02d" % [prefix, suffix, serial]


func _despawn_bot(pid: int) -> void:
	if not _is_bot_id(pid):
		return
	_despawn.rpc(pid)
	NetworkManager.players.erase(pid)
	round_wins.erase(pid)
	_ping_ms_by_player.erase(pid)
	_bot_appearance_seeds.erase(pid)
	pending_pick_cards_by_player.erase(pid)
	completed_picks.erase(pid)
	eliminated_players.erase(pid)


func _despawn_one_bot() -> void:
	if not multiplayer.is_server():
		return
	var bot_ids := _bot_ids()
	if bot_ids.is_empty():
		return
	bot_ids.sort()
	_despawn_bot(int(bot_ids.back()))
	NetworkManager.player_list_changed.emit()
	_broadcast_scores.rpc(round_wins)
	_refresh_bot_counter()
	if NetworkManager.players.size() < 2:
		state = State.WAITING
		_hide_card_pick.rpc()
		_hide_rematch_overlay.rpc()
		_announce.rpc("WAITING FOR PLAYERS…", 99.0)

func _despawn_all_bots() -> void:
	var bot_ids := _bot_ids()
	if bot_ids.is_empty():
		return
	for pid in bot_ids:
		_despawn_bot(int(pid))
	NetworkManager.player_list_changed.emit()
	_broadcast_scores.rpc(round_wins)
	_refresh_bot_counter()
	if state == State.PICKING_CARD:
		_hide_card_pick.rpc()
	_hide_rematch_overlay.rpc()
	state = State.WAITING


func _update_ping_monitor(delta: float) -> void:
	if multiplayer.is_server():
		_ping_probe_timer -= delta
		if _ping_probe_timer <= 0.0:
			_ping_probe_timer = PING_PROBE_INTERVAL
			_send_ping_probes()
	_prune_stale_pings()
	_update_high_ping_warning(delta)


func _send_ping_probes() -> void:
	var now := Time.get_ticks_msec()
	_ping_ms_by_player[1] = 0
	for raw_id in NetworkManager.players:
		var peer_id := int(raw_id)
		if peer_id == 1 or _is_bot_id(peer_id):
			continue
		_ping_seq += 1
		_ping_pending[_ping_seq] = {"peer": peer_id, "sent_ms": now}
		_ping_probe.rpc_id(peer_id, _ping_seq, now)
	_broadcast_ping_ms.rpc(_ping_ms_by_player)


func _prune_stale_pings() -> void:
	var now := Time.get_ticks_msec()
	var changed := false
	for seq in _ping_pending.keys():
		var pending: Dictionary = _ping_pending[seq]
		if now - int(pending.get("sent_ms", now)) > PING_STALE_AFTER_MS:
			var peer_id := int(pending.get("peer", 0))
			if peer_id != 0:
				_ping_ms_by_player[peer_id] = -1
				changed = true
			_ping_pending.erase(seq)
	if changed and multiplayer.is_server():
		_broadcast_ping_ms.rpc(_ping_ms_by_player)


func _update_high_ping_warning(delta: float) -> void:
	if state != State.PLAYING:
		return
	_high_ping_warn_timer = maxf(0.0, _high_ping_warn_timer - delta)
	var my_id := multiplayer.get_unique_id()
	var ping := int(_ping_ms_by_player.get(my_id, 0))
	if my_id == 1:
		var worst := 0
		for raw_id in _ping_ms_by_player:
			worst = max(worst, int(_ping_ms_by_player[raw_id]))
		ping = worst
	if ping < HIGH_PING_WARN_MS or _high_ping_warn_timer > 0.0:
		return
	_high_ping_warn_timer = HIGH_PING_WARN_INTERVAL
	_on_network_status_changed("HIGH PING: %d ms" % ping, false)


@rpc("authority", "call_local", "unreliable")
func _ping_probe(seq: int, sent_ms: int) -> void:
	if multiplayer.is_server():
		return
	_ping_reply.rpc_id(1, seq, sent_ms)


@rpc("any_peer", "unreliable")
func _ping_reply(seq: int, sent_ms: int) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		return
	var pending: Dictionary = _ping_pending.get(seq, {})
	if int(pending.get("peer", 0)) != sender:
		return
	_ping_pending.erase(seq)
	_ping_ms_by_player[sender] = max(0, Time.get_ticks_msec() - sent_ms)
	_broadcast_ping_ms.rpc(_ping_ms_by_player)


@rpc("authority", "call_local", "unreliable")
func _broadcast_ping_ms(pings: Dictionary) -> void:
	_ping_ms_by_player = pings.duplicate()

# -------------------- ROUND FLOW --------------------

func _maybe_start_match() -> void:
	if not multiplayer.is_server():
		return
	if state != State.WAITING:
		return
	if NetworkManager.players.size() < 2:
		_announce.rpc("WAITING FOR PLAYERS…", 99.0)
		_set_music_energy.rpc(1)
		return
	state = State.PLAYING
	current_round = 1
	_reset_round_tracking()
	for pid in NetworkManager.players:
		var p := players_root.get_node_or_null(str(pid))
		if p:
			p.reset_weapon.rpc()
	_start_round_now()

func _start_round_now() -> void:
	_reset_round_tracking()
	_round_damage_seen = false
	_round_music_level = 2
	_round_elapsed = 0.0
	_lava_leak_started = false
	var music_seed := randi()
	_set_music_track.rpc(music_seed, current_round)
	_set_music_energy.rpc(2, true)
	# Pick a random map for this round and broadcast the swap to all peers
	# before respawning, so _pick_spawn() reads the new arena's spawn
	# points (the call_local RPC runs the swap synchronously here too).
	if multiplayer.is_server() and MAP_POOL.size() >= 1:
		# Always swap so the procedural arena gets a fresh seed each round
		# (with a single-entry pool, the index is always 0).
		_swap_arena.rpc(randi() % MAP_POOL.size(), randi())
	# Respawn everyone, reset HP + cooldowns, unfreeze, announce.
	# Track already-assigned spawn positions so nobody lands on top of another.
	# The first pick anchors the height target so subsequent picks land near
	# the same elevation.
	var used: Array[Vector3] = []
	for pid in NetworkManager.players:
		var p := players_root.get_node_or_null(str(pid))
		if not p:
			continue
		var pick := _pick_spawn(used)
		used.append(pick["pos"])
		p.set_ghost_mode.rpc(false)
		# Rocket-spawn: catch the player ~60m above the landing spot already
		# moving at terminal speed (80 m/s constant — no gravity ramp). 0.75s
		# from spawn to impact. Each player auto-ends their launch on first
		# floor contact, so there's no central timer gating the round start.
		var sky_pos: Vector3 = pick["pos"] + Vector3(0.0, 60.0, 0.0)
		p.server_respawn.rpc_id(p.get_multiplayer_authority(), sky_pos, pick["yaw"])
		# Clear any leftover freeze (e.g. losers were frozen during card-pick
		# at the end of the previous round) before kicking off the launch —
		# otherwise the player lands and can't move.
		p.set_frozen.rpc(false)
		p.set_launching.rpc(true, 80.0)
		p.clear_ragdoll.rpc()
	_clear_projectiles.rpc()
	_clear_craters.rpc()
	_clear_blood_splats.rpc()
	_hide_rematch_overlay.rpc()
	# Warm shot + explosion synths for whichever weapons are in play this
	# round (and a few common explosion radii) during the rocket-spawn window
	# so the first bullet / first grenade doesn't pay 30-50ms of audio synth
	# mid-fight. Yields one cache fill per frame; cache hits are instant.
	_warmup_round_audio()
	# Force the heat-distortion + shockwave shader pipelines to compile now
	# while the camera is settling in, not on the first explosion.
	if has_node("Arena"):
		preload("res://scripts/grenade.gd").warmup_shaders($Arena)
	# Clear any leftover round-end banner ("PICKING A CARD…", "WAITING FOR …",
	# etc.) so it doesn't bleed into the new round.
	_announce.rpc("", 0)

func _update_lava_leak(delta: float) -> void:
	if _lava_leak_started:
		return
	_round_elapsed += delta
	if _round_elapsed < LAVA_LEAK_START_SECONDS:
		return
	_lava_leak_started = true
	_start_lava_leak.rpc(LAVA_LEAK_SPREAD_SECONDS)

@rpc("authority", "call_local", "reliable")
func _start_lava_leak(spread_seconds: float) -> void:
	var arena := get_node_or_null("Arena")
	if arena and arena.has_method("start_lava_leak"):
		arena.start_lava_leak(spread_seconds)
	_announce("LAVA LEAK", 1.5)

@rpc("authority", "call_local", "reliable")
func _stop_lava_leak() -> void:
	var arena := get_node_or_null("Arena")
	if arena and arena.has_method("stop_lava_leak"):
		arena.stop_lava_leak()

@rpc("authority", "call_local", "reliable")
func _set_music_energy(level: int, immediate: bool = false, next_bar: bool = false) -> void:
	if level > 0:
		_round_music_level = level
	# Slider at the bottom of its range = muted; skip pumping energy so the
	# bus stays quiet between rounds.
	if _music_db <= MUSIC_DB_MIN + 0.5:
		ProceduralMusic.set_energy(0, true)
		return
	ProceduralMusic.set_energy(level, immediate, next_bar)

@rpc("authority", "call_local", "reliable")
func _set_music_track(seed: int, round_index: int) -> void:
	ProceduralMusic.generate_track(seed, round_index)

@rpc("any_peer", "call_local", "reliable")
func _report_player_damage(victim_id: int, attacker_id: int, amount: int, victim_health: int) -> void:
	if not multiplayer.is_server():
		return
	if state != State.PLAYING:
		return
	if amount <= 0 or attacker_id == victim_id:
		return
	_round_damage_seen = true
	if _round_music_level < 3:
		_set_round_music_level(3)
	_update_round_music_phase()

func _update_round_music_phase() -> void:
	if _round_music_level >= 4:
		return
	if not _late_round_music_condition():
		return
	_set_round_music_level(4)

func _late_round_music_condition() -> bool:
	var alive := _alive_player_ids()
	if alive.size() != 2:
		return false
	for pid in alive:
		var p := players_root.get_node_or_null(str(pid))
		if not p:
			continue
		var hp := int(p.get("health"))
		var max_hp := 100
		var w = p.get("weapon")
		if w != null:
			max_hp += int(w.max_hp_bonus)
		if hp > 0 and hp <= int(ceil(float(max_hp) * 0.5)):
			return true
	return false

func _set_round_music_level(level: int) -> void:
	if level <= _round_music_level:
		return
	_round_music_level = level
	_set_music_energy.rpc(level, false, true)

@rpc("authority", "call_local", "reliable")
func _clear_projectiles() -> void:
	# Wipe in-flight bullets and grenades so leftovers from the previous round
	# can't deal damage in the new one.
	for node in get_tree().get_nodes_in_group("projectiles"):
		if is_instance_valid(node):
			node.queue_free()

@rpc("authority", "call_local", "reliable")
func _clear_craters() -> void:
	# Persistent bullet-impact scorch marks reset between rounds — old craters
	# from last round shouldn't litter the new arena.
	Violence.clear_craters(self)

@rpc("authority", "call_local", "reliable")
func _clear_blood_splats() -> void:
	# Same logic as craters: blood decals from last round shouldn't bleed
	# into the new map.
	Violence.clear_blood_splats(self)

# Replace the current "Arena" child with the map at MAP_POOL[map_index].
# Called from _start_round_now via RPC — server picks the index, every peer
# (including the server thanks to call_local) swaps in lockstep.
# remove_child happens synchronously so the OLD spawnpoints leave the tree
# before _pick_spawn() runs; the deferred queue_free does the actual delete.
@rpc("authority", "call_local", "reliable")
func _swap_arena(map_index: int, map_seed: int = 0) -> void:
	if map_index < 0 or map_index >= MAP_POOL.size():
		return
	var existing := get_node_or_null("Arena")
	if existing:
		remove_child(existing)
		existing.queue_free()
	var new_arena: Node = MAP_POOL[map_index].instantiate()
	new_arena.name = "Arena"
	add_child(new_arena)
	if new_arena is Node3D:
		(new_arena as Node3D).position = ARENA_OFFSET
	# Procedural maps need the seed plumbed in so every peer regenerates the
	# same geometry. Synchronous: spawnpoints are in the tree before
	# _pick_spawn() runs in _start_round_now().
	if new_arena.has_method("apply_seed"):
		new_arena.apply_seed(map_seed)
	current_map_index = map_index
	current_map_seed = map_seed
	_refresh_pause_seed_label()
	# Re-grab WorldEnvironment so explosion-tonemap-duck logic (_arena_env in
	# _process) keeps working against the new arena's environment resource.
	var we := new_arena.get_node_or_null("WorldEnvironment") as WorldEnvironment
	if we and we.environment:
		_arena_env = we.environment
		_base_tonemap_exposure = _arena_env.tonemap_exposure

func _reset_round_tracking() -> void:
	pending_picker_id = 0
	pending_pick_cards.clear()
	pending_pick_cards_by_player.clear()
	completed_picks.clear()
	eliminated_players.clear()
	round_winner_id = 0
	_round_elapsed = 0.0
	_lava_leak_started = false

func report_kill(killer_id: int, victim_id: int) -> void:
	# Called on the server by Player._report_death. In 3+ player rounds,
	# deaths eliminate players; the last survivor wins the round.
	if not multiplayer.is_server():
		return
	if state != State.PLAYING:
		return
	if eliminated_players.has(victim_id):
		return
	eliminated_players[victim_id] = true
	if killer_id != 0 and killer_id != victim_id:
		if _human_count() >= 3:
			var killer_name := str(NetworkManager.players.get(killer_id, "Player"))
			var victim_name := str(NetworkManager.players.get(victim_id, "Player"))
			_show_kill_feed.rpc(killer_name, victim_name)
		var killer_node := players_root.get_node_or_null(str(killer_id))
		if killer_node:
			# Route via authority so server-owned bots receive their own RPC.
			killer_node.confirm_kill.rpc_id(killer_node.get_multiplayer_authority())
	var victim_node := players_root.get_node_or_null(str(victim_id))
	if victim_node and NetworkManager.players.size() >= 3:
		victim_node.set_ghost_mode.rpc(true)

	var alive := _alive_player_ids()
	if alive.size() <= 1:
		var winner_id := int(alive[0]) if alive.size() == 1 else _fallback_round_winner(victim_id)
		_end_round(winner_id)
	else:
		# Only pick immediately if the round is still going (3+ players)
		_begin_card_pick_for_loser(victim_id)

func _alive_player_ids() -> Array[int]:
	var alive: Array[int] = []
	for raw_id in NetworkManager.players:
		var pid := int(raw_id)
		if eliminated_players.has(pid):
			continue
		if not players_root.has_node(str(pid)):
			continue
		alive.append(pid)
	return alive

func _fallback_round_winner(victim_id: int) -> int:
	for raw_id in NetworkManager.players:
		var pid := int(raw_id)
		if pid != victim_id:
			return pid
	return 0

func _end_round(winner_id: int) -> void:
	round_winner_id = winner_id
	_round_music_level = 1
	_round_damage_seen = false
	_set_music_energy.rpc(1, false, true)
	if winner_id != 0:
		round_wins[winner_id] = int(round_wins.get(winner_id, 0)) + 1
		_broadcast_scores.rpc(round_wins)
		# Show "<winner> WINS THE ROUND" on every peer before the card-pick UI
		# starts overwriting the banner. The await below gives the message
		# enough screen time to read; the match-over branch below uses its
		# own _match_over banner so we skip the announce when this is also
		# the final round.
		var winner_name: String = NetworkManager.players.get(winner_id, "Player")
		var is_final: bool = int(round_wins[winner_id]) >= rounds_to_win
		if not is_final:
			_announce.rpc("%s WINS THE ROUND" % winner_name, 1.6)
	# Match over?
	if winner_id != 0 and int(round_wins[winner_id]) >= rounds_to_win:
		state = State.MATCH_OVER
		for pid in NetworkManager.players:
			var pn := players_root.get_node_or_null(str(pid))
			if pn:
				# Freeze everyone except the winner so they can celebrate
				if int(pid) != winner_id:
					pn.set_frozen.rpc(true)
		_match_over.rpc(winner_id)
		return
	# Hold on the "X WINS THE ROUND" banner for a beat before the card-pick
	# UI cascade overwrites it.
	if winner_id != 0:
		await get_tree().create_timer(1.4).timeout
	# Freeze the losers and wait for them to finish their picks.
	state = State.PICKING_CARD
	# Don't freeze losers during card pick — let everyone keep moving while
	# the round-pick UI is up. The picker's UI overlay captures their mouse
	# / clicks; movement keys still work in the background, which is fine
	# (it just means they can stretch their legs while picking).
	for raw_loser_id in eliminated_players.keys():
		var loser_id := int(raw_loser_id)
		if not completed_picks.has(loser_id) and not pending_pick_cards_by_player.has(loser_id):
			_begin_card_pick_for_loser(loser_id)
		elif completed_picks.has(loser_id) and not _is_bot_id(loser_id):
			_show_spectating.rpc_id(_peer_for_player(loser_id), _waiting_for_pickers_spectator_label())
	_show_round_winner_wait.rpc(winner_id, _active_picker_names())
	_maybe_finish_card_picks()

func _begin_card_pick_for_loser(loser_id: int) -> void:
	if completed_picks.has(loser_id) or pending_pick_cards_by_player.has(loser_id):
		return

	var score_factor := _get_rarity_score_factor(loser_id)
	var cards := CardLibrary.random_ids(CARDS_PER_PICK, score_factor)
	pending_pick_cards_by_player[loser_id] = cards
	pending_picker_id = loser_id
	pending_pick_cards = cards
	var peer := _peer_for_player(loser_id)
	if peer != 0 and not _is_bot_id(loser_id):
		_show_card_pick.rpc_id(peer, loser_id, cards)
	if _is_bot_id(loser_id):
		_bot_auto_pick.call_deferred(loser_id)

func _get_rarity_score_factor(pid: int) -> float:
	# Calculate score rank.
	# 1.0 = top score, >1.0 = trailing.
	var my_score := int(round_wins.get(pid, 0))
	var max_score := 0
	for other_id in NetworkManager.players:
		max_score = max(max_score, int(round_wins.get(int(other_id), 0)))

	if max_score <= 0:
		return 1.0

	# Trailing players get up to 4x better luck (if they have 0 and someone has 8)
	var diff := float(max_score - my_score)
	return 1.0 + (diff * 0.4)

func _bot_auto_pick(loser_id: int) -> void:
	await get_tree().create_timer(1.2).timeout
	if not pending_pick_cards_by_player.has(loser_id):
		return
	var cards: Array = pending_pick_cards_by_player[loser_id]
	if cards.is_empty():
		return
	var pick: String = str(cards[randi() % cards.size()])
	_finalize_card_pick(loser_id, pick)

func _finalize_card_pick(player_id_to_apply: int, card_id: String) -> void:
	var p := players_root.get_node_or_null(str(player_id_to_apply))
	if p:
		p.apply_card.rpc(card_id)
	completed_picks[player_id_to_apply] = true
	pending_pick_cards_by_player.erase(player_id_to_apply)
	# Bots have no HUD; routing UI RPCs to a bot's peer hits the server peer
	# (1), which would clobber the host human's overlay. Skip them entirely.
	if not _is_bot_id(player_id_to_apply):
		var peer := _peer_for_player(player_id_to_apply)
		if peer != 0:
			_hide_card_pick_for.rpc_id(peer, player_id_to_apply)
			if state == State.PLAYING:
				_show_spectating.rpc_id(peer, "SPECTATING…")
			elif state == State.PICKING_CARD:
				_show_spectating.rpc_id(peer, _waiting_for_pickers_spectator_label())
	_maybe_finish_card_picks()

func _warmup_round_audio() -> void:
	# Collect every live player's current Weapon (mutated by whatever cards
	# they've picked so far) so SFX.warmup_async caches the shot variants
	# they're actually about to fire. Always include a default Weapon so
	# fresh joiners / bots without applied cards aren't a cache miss.
	var weapons: Array = [Weapon.new()]
	for child in players_root.get_children():
		var w: Variant = child.get("weapon")
		if w != null:
			weapons.append(w)
	# Common explosion radii — covers BLAST cards (4–8m) and bazooka/grenade
	# blasts (6–10m). Bucketed integer-rounded inside warmup_async.
	SFX.warmup_async(weapons, [4.0, 6.0, 8.0, 10.0])


func _maybe_finish_card_picks() -> void:
	if state != State.PICKING_CARD:
		return
	for raw_loser_id in eliminated_players.keys():
		var loser_id := int(raw_loser_id)
		if not completed_picks.has(loser_id):
			return
	current_round += 1
	state = State.PLAYING
	_start_round_now()

func _peer_for_player(pid: int) -> int:
	var p := players_root.get_node_or_null(str(pid))
	if p:
		return int(p.get_multiplayer_authority())
	return pid

@rpc("authority", "call_local", "reliable")
func _show_spectating(text: String = "SPECTATING…") -> void:
	_hide_card_pick()
	round_banner.text = text
	round_banner.visible = true
	banner_timer.stop()
	_sync_mouse_mode()

@rpc("authority", "call_local", "reliable")
func _show_round_winner_wait(winner_id: int, picker_names: PackedStringArray = PackedStringArray()) -> void:
	if multiplayer.get_unique_id() != winner_id:
		return
	round_banner.text = _waiting_for_pickers_label(picker_names)
	round_banner.visible = true
	banner_timer.stop()


func _waiting_for_pickers_label(picker_names: PackedStringArray) -> String:
	if picker_names.is_empty():
		return "ROUND WON — WAITING FOR PICKS…"
	if picker_names.size() == 1:
		return "ROUND WON — WAITING FOR %s…" % picker_names[0]
	return "ROUND WON — WAITING FOR %s…" % ", ".join(picker_names)


# Server-only: build the spectator-side wait label (shown to losers who
# already picked, while other losers are still picking).
func _waiting_for_pickers_spectator_label() -> String:
	var names := _active_picker_names()
	if names.is_empty():
		return "WAITING FOR OTHER PICKS…"
	if names.size() == 1:
		return "WAITING FOR %s…" % names[0]
	return "WAITING FOR %s…" % ", ".join(names)


# Server-only: collect display names of every player who still owes a card
# pick this round. Used by the winner-banner text (and the spectator banner
# for losers who finished their pick early).
func _active_picker_names() -> PackedStringArray:
	var out := PackedStringArray()
	for raw_id in eliminated_players.keys():
		var pid := int(raw_id)
		if completed_picks.has(pid):
			continue
		# Skip bots — they auto-pick instantly and the human shouldn't see
		# the wait label list them.
		if _is_bot_id(pid):
			continue
		var pname: String = NetworkManager.players.get(pid, "Player")
		out.append(pname)
	return out

# -------------------- CARD PICK UI --------------------

@rpc("authority", "call_local", "reliable")
func _show_card_pick(loser_id: int, card_ids: Array) -> void:
	_show_render_card_pick(loser_id, card_ids)
	_sync_mouse_mode()

func _show_render_card_pick(player_id: int, card_ids: Array) -> bool:
	if _splitscreen and _splitscreen.is_enabled() and _splitscreen.has_method("show_card_pick"):
		if _splitscreen.show_card_pick(player_id, card_ids):
			return true
	var renderer := _render_players.get(player_id) as RenderPlayer
	if renderer == null:
		return false
	renderer.show_card_pick(card_ids)
	return true

func _on_render_player_card_selected(player_id: int, card_id: String) -> void:
	if multiplayer.is_server():
		_server_card_picked_for_player(player_id, card_id)
	else:
		_server_card_picked.rpc_id(1, card_id)

@rpc("any_peer", "call_local", "reliable")
func _server_card_picked(card_id: String) -> void:
	if not multiplayer.is_server():
		return
	if state != State.PICKING_CARD and state != State.PLAYING:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = multiplayer.get_unique_id()
	if _splitscreen and _splitscreen.is_enabled() and not pending_pick_cards_by_player.has(sender) \
			and pending_picker_id >= SPLIT_PLAYER_ID_BASE:
		sender = pending_picker_id
	_server_card_picked_for_player(sender, card_id)

func _server_card_picked_for_player(player_id: int, card_id: String) -> void:
	if not multiplayer.is_server():
		return
	if state != State.PICKING_CARD and state != State.PLAYING:
		return
	if not pending_pick_cards_by_player.has(player_id):
		return
	var cards: Array = pending_pick_cards_by_player[player_id]
	if not cards.has(card_id):
		return
	_finalize_card_pick(player_id, card_id)

@rpc("authority", "call_local", "reliable")
func _hide_card_pick() -> void:
	for renderer in _render_players.values():
		renderer.hide_card_pick()
	if _splitscreen and _splitscreen.is_enabled():
		for player_id in pending_pick_cards_by_player.keys():
			if _splitscreen.has_method("hide_card_pick"):
				_splitscreen.hide_card_pick(int(player_id))
	_sync_mouse_mode()

@rpc("authority", "call_local", "reliable")
func _hide_card_pick_for(player_id: int) -> void:
	var hid_render := false
	if _splitscreen and _splitscreen.is_enabled() and _splitscreen.has_method("hide_card_pick"):
		hid_render = _splitscreen.hide_card_pick(player_id)
	var renderer := _render_players.get(player_id) as RenderPlayer
	if renderer:
		renderer.hide_card_pick()
		hid_render = true
	if hid_render:
		show_death_effect_for(player_id, false)
	_sync_mouse_mode()

@rpc("authority", "call_local", "reliable")
func _announce(text: String, duration: float, font_size: int = -1) -> void:
	_set_banner(text, duration, font_size)


# Local-only banner setter — body of _announce, callable from inside other
# RPCs that already run via call_local on every peer (so we don't need to
# re-broadcast).
func _set_banner(text: String, duration: float, font_size: int = -1) -> void:
	if text == "" or duration <= 0:
		round_banner.visible = false
		banner_timer.stop()
		return

	round_banner.text = text
	round_banner.visible = true

	if font_size > 0:
		round_banner.add_theme_font_size_override("font_size", font_size)
	else:
		round_banner.remove_theme_font_size_override("font_size")

	banner_timer.stop()
	if duration < 90.0:
		banner_timer.wait_time = maxf(0.01, duration)
		banner_timer.start()



@rpc("authority", "call_local", "reliable")
func _match_over(winner_id: int) -> void:
	_hide_card_pick() # Ensure picker is gone
	var winner_name: String = NetworkManager.players.get(winner_id, "Player")
	var is_me := winner_id == multiplayer.get_unique_id()
	round_banner.text = "YOU'RE THE WINNER" if is_me else "%s WINS THE MATCH" % winner_name
	round_banner.visible = true
	banner_timer.stop()
	_show_rematch_overlay(winner_id)
	_sync_mouse_mode()

func _build_rematch_overlay() -> void:
	_rematch_overlay = Control.new()
	_rematch_overlay.name = "RematchOverlay"
	_rematch_overlay.anchor_right = 1.0
	_rematch_overlay.anchor_bottom = 1.0
	_rematch_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_rematch_overlay.visible = false
	$HUD.add_child(_rematch_overlay)

	var center := CenterContainer.new()
	center.anchor_right = 1.0
	center.anchor_bottom = 1.0
	_rematch_overlay.add_child(center)

	# No backdrop panel — buttons float over the world. The big "WINNER"
	# banner above is enough framing.
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	center.add_child(vb)

	_rematch_subtitle = Label.new()
	_rematch_subtitle.text = ""
	_rematch_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_rematch_subtitle.add_theme_font_size_override("font_size", 18)
	_rematch_subtitle.add_theme_color_override("font_color", Color(0.86, 0.86, 0.95))
	vb.add_child(_rematch_subtitle)

	_extend_button = Button.new()
	_extend_button.text = "5 MORE ROUNDS"
	_extend_button.custom_minimum_size = Vector2(260, 46)
	_extend_button.pressed.connect(_on_extend_pressed)
	vb.add_child(_extend_button)

	_exit_to_menu_button = Button.new()
	_exit_to_menu_button.text = "EXIT GAME"
	_exit_to_menu_button.custom_minimum_size = Vector2(260, 46)
	_exit_to_menu_button.pressed.connect(_quit_game)
	vb.add_child(_exit_to_menu_button)

func _show_rematch_overlay(_winner_id: int) -> void:
	if _rematch_overlay == null:
		_build_rematch_overlay()
	_rematch_requested = false
	_extend_button.disabled = false
	_extend_button.text = "5 MORE ROUNDS"
	_rematch_overlay.visible = true
	_grab_first_menu_focus(_rematch_overlay)

var _retro_material: ShaderMaterial = null

# -------------------- VIDEO SETTINGS --------------------
const SETTINGS_PATH := "user://settings.cfg"
const MUSIC_DB_MIN := -40.0  # below this is treated as muted
const MUSIC_DB_MAX := 0.0
const MUSIC_DB_DEFAULT := -16.0
var _retro_enabled: bool = true

func _is_retro_enabled() -> bool:
	return _retro_enabled
var _music_db: float = MUSIC_DB_DEFAULT
var _mouse_sens_mult: float = 1.0
var _movement_tilt_enabled: bool = true
var _player_name: String = ""

signal _player_name_set


func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	_retro_enabled = cfg.get_value("video", "retro", cfg.get_value("video", "dither", true))
	# Migrate the old bool setting: if music=false was saved, start the slider
	# at the muted floor so behaviour matches the previous toggle. Otherwise
	# read the new music_db key (with default volume).
	var music_legacy: bool = cfg.get_value("audio", "music", true)
	var music_legacy_default: float = MUSIC_DB_DEFAULT if music_legacy else MUSIC_DB_MIN
	_music_db = float(cfg.get_value("audio", "music_db", music_legacy_default))
	_mouse_sens_mult = float(cfg.get_value("input", "mouse_sens_mult", 1.0))
	_movement_tilt_enabled = cfg.get_value("input", "movement_tilt", true)
	_player_name = String(cfg.get_value("player", "name", ""))


func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("video", "retro", _retro_enabled)
	cfg.set_value("audio", "music_db", _music_db)
	cfg.set_value("input", "mouse_sens_mult", _mouse_sens_mult)
	cfg.set_value("input", "movement_tilt", _movement_tilt_enabled)
	cfg.set_value("player", "name", _player_name)
	cfg.save(SETTINGS_PATH)


func _apply_settings() -> void:
	if _retro_material:
		_retro_material.set_shader_parameter("dither_strength", 1.0)
		_retro_material.set_shader_parameter("fisheye_strength", 1.0)
	# Music: drive the procedural music's volume directly. Treat the bottom
	# of the slider as "off" — saves the audio bus when the user wants silence.
	var muted: bool = _music_db <= MUSIC_DB_MIN + 0.5
	ProceduralMusic.enabled = not muted
	ProceduralMusic.music_db = _music_db
	if not muted:
		ProceduralMusic.set_energy(_round_music_level, true)
	else:
		ProceduralMusic.set_energy(0, true)
	_apply_mouse_sens_to_local()
	_sync_mouse_mode()


func _apply_mouse_sens_to_local() -> void:
	if local_player and is_instance_valid(local_player):
		local_player.set("mouse_sens_mult", _mouse_sens_mult)
		local_player.set("tilt_enabled", _movement_tilt_enabled)

func _apply_retro_shader(node: Control) -> void:
	var shader := Shader.new()
	shader.code = "
		shader_type canvas_item;
		uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_nearest;
		uniform vec2 mouse_uv = vec2(-1.0);  // mouse position in pre-distortion UV (0..1)
		uniform float cursor_visible = 0.0;  // 0 = hidden, 1 = drawn
		// Settings-driven effect strengths. 0.0 disables, 1.0 = original look.
		uniform float fisheye_strength = 1.0;
		uniform float dither_strength = 1.0;

		const float bayer[16] = {
			0.0/16.0, 8.0/16.0, 2.0/16.0, 10.0/16.0,
			12.0/16.0, 4.0/16.0, 14.0/16.0, 6.0/16.0,
			3.0/16.0, 11.0/16.0, 1.0/16.0, 9.0/16.0,
			15.0/16.0, 7.0/16.0, 13.0/16.0, 5.0/16.0
		};

		void fragment() {
			vec2 uv = SCREEN_UV;
			vec2 centered_uv = uv - 0.5;
			float aspect = SCREEN_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.x;
			vec2 aspect_uv = centered_uv * vec2(aspect, 1.0);
			float dist = length(aspect_uv);
			// Scale lens distortion by the toggle so 0.0 = flat screen.
			float distortion = 0.15 * fisheye_strength;
			float max_dist_sq = dot(vec2(0.5 * aspect, 0.5), vec2(0.5 * aspect, 0.5));
			float zoom = mix(1.0, 0.995 / (1.0 + 0.15 * max_dist_sq), fisheye_strength);
			uv = 0.5 + centered_uv * zoom * (1.0 + distortion * dist * dist);

			vec2 res = 1.0 / SCREEN_PIXEL_SIZE;
			int p_size = max(1, int(round(res.y / 1080.0)));
			uv = (floor(uv * res / float(p_size)) + 0.5) * float(p_size) / res;
			vec2 uv_min = SCREEN_PIXEL_SIZE * 0.5;
			vec2 uv_max = vec2(1.0) - uv_min;

			float amount = 0.001 * (dist * dist);
			float r = texture(screen_texture, clamp(uv + vec2(amount, 0.0), uv_min, uv_max)).r;
			float g = texture(screen_texture, clamp(uv, uv_min, uv_max)).g;
			float b = texture(screen_texture, clamp(uv - vec2(amount, 0.0), uv_min, uv_max)).b;
			vec3 color = vec3(r, g, b);

			vec3 bleed = vec3(0.0);
			vec2 b_offset = SCREEN_PIXEL_SIZE * float(p_size) * 1.5;
			bleed += texture(screen_texture, clamp(uv + vec2(b_offset.x, b_offset.y), uv_min, uv_max)).rgb;
			bleed += texture(screen_texture, clamp(uv + vec2(-b_offset.x, b_offset.y), uv_min, uv_max)).rgb;
			bleed += texture(screen_texture, clamp(uv + vec2(b_offset.x, -b_offset.y), uv_min, uv_max)).rgb;
			bleed += texture(screen_texture, clamp(uv + vec2(-b_offset.x, -b_offset.y), uv_min, uv_max)).rgb;
			color += bleed * 0.15;

			ivec2 p = ivec2(FRAGCOORD.xy / float(p_size));
			// Bayer dither pattern, scaled by toggle. 0.0 = visible banding.
			float threshold = (bayer[(p.x % 4) * 4 + (p.y % 4)] - 0.5) * 0.5 * dither_strength;

			float levels = 32.0;
			float vignette = clamp(1.0 - dist * 1.4, 0.0, 1.0);
			color = floor(color * levels + threshold + 0.5) / levels;
			color *= mix(0.7, 1.0, vignette);

			// In-shader cursor: drawn at the pre-distortion UV that this
			// fragment is displaying, so it lives on the warped surface and
			// stays aligned with the warped UI underneath. `mouse_uv` is the
			// undistorted mouse position from Godot. Compare against `uv`
			// (the un-warped UV this fragment shows) to find the on-screen
			// pixel that visually represents the mouse position.
			if (cursor_visible > 0.5) {
				vec2 d = (uv - mouse_uv) * res;  // pixel offset in unwarped space
				// Triangle arrow: tip at (0,0), 12 px tall pointing down-right.
				bool arrow = d.x >= 0.0 && d.y >= 0.0 && (d.x + d.y) <= 12.0;
				bool outline = d.x >= -1.5 && d.y >= -1.5 && (d.x + d.y) <= 13.5 && !arrow;
				if (arrow) color = vec3(1.0);
				else if (outline) color = vec3(0.05);
			}

			COLOR.rgb = color;
			COLOR.a = 1.0;
		}
	"
	var mat := ShaderMaterial.new()
	mat.shader = shader
	node.material = mat
	_retro_material = mat

# Custom in-HUD cursor so the retro/fisheye shader distorts the cursor along
# with the rest of the UI. The OS cursor is hidden (MOUSE_MODE_HIDDEN) in
# menus; the mouse position Godot tracks is undistorted and matches the
# button's logical rect, so clicks land correctly while the cursor *visually*
# follows the warped UI.
var _custom_cursor: Polygon2D = null

func _build_custom_cursor() -> void:
	_custom_cursor = Polygon2D.new()
	_custom_cursor.name = "CustomCursor"
	# Classic arrow pointing up-left, tip at (0,0).
	_custom_cursor.polygon = PackedVector2Array([
		Vector2(0, 0), Vector2(0, 16), Vector2(4, 12),
		Vector2(7, 18), Vector2(9, 17), Vector2(6, 11),
		Vector2(11, 11),
	])
	_custom_cursor.color = Color(1, 1, 1)
	_custom_cursor.z_index = 4096
	_custom_cursor.visible = false
	$HUD.add_child(_custom_cursor)

func _update_custom_cursor() -> void:
	if _custom_cursor != null:
		_custom_cursor.visible = false
	if _retro_material == null:
		return
	_retro_material.set_shader_parameter("cursor_visible", 0.0)

func _build_retro_filter() -> void:
	var template := Control.new()
	_apply_retro_shader(template)

func _build_explosion_flash_overlay() -> void:
	# Dedicated CanvasLayer above HUD so the flash covers ability bars, health,
	# scoreboard etc. Otherwise the flash sits behind those widgets and you
	# only see white bars in the gaps between them.
	var flash_layer := CanvasLayer.new()
	flash_layer.name = "ExplosionFlashLayer"
	flash_layer.layer = 50  # well above HUD's default layer (1)
	add_child(flash_layer)
	_explosion_flash_overlay = ColorRect.new()
	_explosion_flash_overlay.name = "ExplosionFlashOverlay"
	_explosion_flash_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_explosion_flash_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_explosion_flash_overlay.color = Color(1.0, 0.96, 0.88, 0.0)
	flash_layer.add_child(_explosion_flash_overlay)

func _build_network_status_panel() -> void:
	if _network_status_panel != null:
		return
	_network_status_panel = PanelContainer.new()
	_network_status_panel.name = "NetworkStatus"
	_network_status_panel.visible = false
	_network_status_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_network_status_panel.anchor_left = 1.0
	_network_status_panel.anchor_right = 1.0
	_network_status_panel.anchor_top = 0.0
	_network_status_panel.anchor_bottom = 0.0
	_network_status_panel.offset_left = -440.0
	_network_status_panel.offset_right = -18.0
	_network_status_panel.offset_top = 18.0
	_network_status_panel.offset_bottom = 0.0
	_network_status_panel.grow_vertical = Control.GROW_DIRECTION_END
	$HUD.add_child(_network_status_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	_network_status_panel.add_child(margin)

	_network_status_label = Label.new()
	_network_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_network_status_label.add_theme_font_size_override("font_size", 15)
	_network_status_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.95))
	_network_status_label.add_theme_constant_override("outline_size", 4)
	margin.add_child(_network_status_label)


func _build_kill_feed() -> void:
	if _kill_feed != null:
		return
	_kill_feed = VBoxContainer.new()
	_kill_feed.name = "KillFeed"
	_kill_feed.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_kill_feed.anchor_left = 1.0
	_kill_feed.anchor_right = 1.0
	_kill_feed.anchor_top = 0.0
	_kill_feed.anchor_bottom = 0.0
	_kill_feed.offset_left = -360.0
	_kill_feed.offset_right = -18.0
	_kill_feed.offset_top = 96.0
	_kill_feed.offset_bottom = 0.0
	_kill_feed.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_kill_feed.grow_vertical = Control.GROW_DIRECTION_END
	_kill_feed.alignment = BoxContainer.ALIGNMENT_BEGIN
	_kill_feed.add_theme_constant_override("separation", 6)
	$HUD.add_child(_kill_feed)


# Top-left hint that points the user at the SPLITSCREEN entry in the pause
# menu when a controller is connected. Hidden once splitscreen is engaged, the
# host loses control of the lobby (becomes a client), or no controller is
# attached.
func _build_splitscreen_hint() -> void:
	if _splitscreen_hint != null:
		return
	var hint := Label.new()
	hint.name = "SplitscreenHint"
	hint.text = "2-PLAYER: open menu (Esc) → SPLITSCREEN"
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint.add_theme_font_size_override("font_size", 14)
	hint.add_theme_color_override("font_color", Color(1.0, 0.9, 0.45))
	hint.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	hint.add_theme_constant_override("outline_size", 4)
	hint.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	hint.offset_left = 16.0
	hint.offset_top = 12.0
	hint.offset_right = 420.0
	hint.offset_bottom = 36.0
	hint.visible = false
	$HUD.add_child(hint)
	_splitscreen_hint = hint


func _on_joy_connection_changed(_device: int, _connected: bool) -> void:
	_refresh_splitscreen_hint()


func _refresh_splitscreen_hint() -> void:
	if _splitscreen_hint == null:
		return
	_splitscreen_hint.visible = _should_show_splitscreen_hint()


func _should_show_splitscreen_hint() -> bool:
	if _splitscreen and _splitscreen.is_enabled():
		return false
	if not multiplayer.is_server():
		return false
	var pad_count := Input.get_connected_joypads().size()
	if pad_count == 0:
		return false
	if pad_count >= 2:
		return true
	# One controller: only nudge if the host is currently on keyboard/mouse —
	# otherwise that single pad is the host's own and a splitscreen partner
	# would need their own pad anyway.
	return not _last_input_was_controller


@rpc("authority", "call_local", "reliable")
func _show_kill_feed(killer_name: String, victim_name: String) -> void:
	if killer_name.is_empty() or victim_name.is_empty():
		return
	if _kill_feed == null:
		_build_kill_feed()

	var entry := PanelContainer.new()
	entry.mouse_filter = Control.MOUSE_FILTER_IGNORE
	entry.modulate.a = 1.0
	entry.custom_minimum_size = Vector2(0, 30)

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.02, 0.025, 0.03, 0.78)
	style.border_color = Color(1.0, 0.78, 0.35, 0.7)
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 5
	style.content_margin_bottom = 5
	entry.add_theme_stylebox_override("panel", style)

	var label := Label.new()
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	label.text = "%s => %s" % [killer_name, victim_name]
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_color", Color(1.0, 0.94, 0.80))
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.95))
	label.add_theme_constant_override("outline_size", 4)
	entry.add_child(label)

	_kill_feed.add_child(entry)
	while _kill_feed.get_child_count() > KILL_FEED_MAX_ITEMS:
		_kill_feed.get_child(0).queue_free()

	var tween := entry.create_tween()
	tween.tween_interval(KILL_FEED_LIFETIME)
	tween.tween_property(entry, "modulate:a", 0.0, 0.35)
	tween.tween_callback(entry.queue_free)


func _on_network_status_changed(message: String, is_error: bool) -> void:
	if message.is_empty():
		return
	if _network_status_panel == null:
		_build_network_status_panel()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.22, 0.03, 0.035, 0.94) if is_error else Color(0.03, 0.07, 0.10, 0.88)
	sb.border_color = Color(1.0, 0.35, 0.28, 0.9) if is_error else Color(0.35, 0.75, 1.0, 0.65)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(6)
	_network_status_panel.add_theme_stylebox_override("panel", sb)

	_network_status_label.add_theme_color_override("font_color", Color(1.0, 0.84, 0.78) if is_error else Color(0.76, 0.92, 1.0))
	_network_status_label.text = message
	if is_error:
		_network_status_label.text += "\nLogs: %s" % OS.get_user_data_dir().path_join("logs")
	_network_status_panel.visible = true

	_network_status_hide_token += 1
	var token := _network_status_hide_token
	if not is_error:
		await get_tree().create_timer(3.0, true).timeout
		if token == _network_status_hide_token and is_instance_valid(_network_status_panel):
			_network_status_panel.visible = false

func trigger_explosion_sidechain(pos: Vector3, radius: float, peak: float = 1.0) -> void:
	if local_player == null or not is_instance_valid(local_player):
		return
	var dist := pos.distance_to(local_player.global_position)
	# Wider reach (was 3.2× radius) so distant big blasts still flash and
	# duck exposure — bazooka at r=24 now reaches 144 m, grenade r=6 → 36 m.
	var affect_radius := maxf(radius * 6.0, 12.0)
	if dist > affect_radius:
		return
	# Upper bound 3.0 so big bazookas (peak 3) at point-blank get the full
	# blinding duck instead of being capped at "regular grenade" intensity.
	var amount := clampf((1.0 - dist / affect_radius) * peak, 0.0, 3.0)
	if amount <= 0.0:
		return
	# Exposure duck sells the "camera iris clamps down" effect while the white
	# veil provides the immediate retinal blast.
	_exposure_duck = maxf(_exposure_duck, amount * 0.95)
	_exposure_duck_vel = maxf(_exposure_duck_vel, 4.6 + amount * 2.8)
	# Flash target capped at 0.92 so the white veil doesn't fully cover the HUD.
	# Alpha lerps to this target over a few frames in _update_explosion_sidechain
	# so the rise doesn't tear with vsync off.
	_flash_alpha_target = maxf(_flash_alpha_target, minf(amount * 0.55, 0.92))
	_flash_alpha_vel = maxf(_flash_alpha_vel, 7.0 + amount * 4.0)

func _update_explosion_sidechain(delta: float) -> void:
	if _arena_env:
		# Floor at 0.05 so a huge duck can't crash exposure to black (renders
		# as full black). 0.05 = ~4 stops below base — still very dark.
		var target_exposure := maxf(0.05, _base_tonemap_exposure - _exposure_duck * 0.75)
		_arena_env.tonemap_exposure = lerpf(_arena_env.tonemap_exposure, target_exposure, clampf(delta * 20.0, 0.0, 1.0))
	# Lerp alpha toward the target on the rise (smooth attack so any tearing
	# shows minimal per-frame contrast), then move_toward 0 on the decay as
	# the target also decays. Attack rate ~25 reaches 80% of target in ~60 ms.
	_flash_alpha = lerpf(_flash_alpha, _flash_alpha_target, clampf(delta * 25.0, 0.0, 1.0))
	if _explosion_flash_overlay:
		_explosion_flash_overlay.color.a = _flash_alpha
	_exposure_duck = move_toward(_exposure_duck, 0.0, _exposure_duck_vel * delta)
	_flash_alpha_target = move_toward(_flash_alpha_target, 0.0, _flash_alpha_vel * delta)

func show_death_effect_for(player_id: int, show: bool) -> void:
	if _splitscreen and _splitscreen.is_enabled() and _splitscreen.has_method("show_death_effect_for"):
		if _splitscreen.show_death_effect_for(player_id, show):
			return
	var renderer := _render_players.get(player_id) as RenderPlayer
	if renderer:
		renderer.show_death_effect(show)
		return

func _on_extend_pressed() -> void:
	_extend_button.text = "VOTED TO EXTEND"
	_extend_button.disabled = true
	var vote_ids := _local_extend_vote_ids()
	if multiplayer.is_server():
		for player_id in vote_ids:
			_server_extend_vote(int(player_id))
	else:
		for player_id in vote_ids:
			_server_extend_vote.rpc_id(1, int(player_id))


func _local_extend_vote_ids() -> Array[int]:
	if _splitscreen and _splitscreen.is_enabled() and _splitscreen.has_method("_local_player_ids"):
		return _splitscreen._local_player_ids()
	return [multiplayer.get_unique_id()]

@rpc("any_peer", "call_local", "reliable")
func _server_extend_vote(player_id: int) -> void:
	if not multiplayer.is_server():
		return
	if state != State.MATCH_OVER:
		return
	_extend_votes[player_id] = true

	# Check if everyone has voted to extend
	var all_voted := true
	for pid in NetworkManager.players:
		# Bots always effectively vote 'yes' instantly
		if _is_bot_id(int(pid)):
			continue
		if not _extend_votes.get(pid, false):
			all_voted = false
			break

	if all_voted:
		_extend_match()

func _extend_match() -> void:
	# Increase goal, hide UI, continue match
	var new_goal := rounds_to_win + 5
	_set_rounds_to_win.rpc(new_goal)
	_extend_votes.clear()
	for player_id in NetworkManager.players:
		show_death_effect_for(int(player_id), false)

	# Start a normal round pick flow for the loser of the last round.
	state = State.PICKING_CARD
	_hide_rematch_overlay.rpc()

	# Find who lost the last round (usually the one who triggered _match_over)
	# We'll let the person who didn't win pick a card.
	for pid in NetworkManager.players:
		if pid != round_winner_id:
			_begin_card_pick_for_loser(pid)

@rpc("authority", "call_local", "reliable")
func _set_rounds_to_win(count: int) -> void:
	rounds_to_win = count

@rpc("authority", "call_local", "reliable")
func _hide_rematch_overlay() -> void:
	if _rematch_overlay:
		_rematch_overlay.visible = false
	_rematch_requested = false

@rpc("authority", "call_local", "reliable")
func _broadcast_scores(scores: Dictionary) -> void:
	round_wins = scores
	_update_scoreboard()

func show_hitmarker_for(player_id: int, kind: String, dmg: int = 0, world_pos: Vector3 = Vector3.INF) -> void:
	if _splitscreen and _splitscreen.is_enabled() and _splitscreen.has_method("show_hitmarker_for"):
		if _splitscreen.show_hitmarker_for(player_id, kind):
			if kind == "kill":
				SFX.kill_confirm()
			else:
				SFX.hitmarker(kind, dmg)
			if dmg > 0 and world_pos != Vector3.INF:
				_show_hit_damage_number(dmg, kind, world_pos)
			return
	var renderer := _render_players.get(player_id) as RenderPlayer
	if renderer:
		renderer.show_hitmarker(kind)
	else:
		return
	if kind == "kill":
		SFX.kill_confirm()
	else:
		SFX.hitmarker(kind, dmg)
	if dmg > 0 and world_pos != Vector3.INF:
		_show_hit_damage_number(dmg, kind, world_pos)

func _show_hit_damage_number(dmg: int, kind: String, world_pos: Vector3) -> void:
	# Floating world-space damage number anchored above the hit point.
	# Each call spawns a fresh Label3D so simultaneous hits stack rather than
	# overwriting each other; a small random offset keeps them from piling up.
	var label := Label3D.new()
	label.text = str(dmg)
	label.font_size = 64
	label.outline_size = 16
	label.outline_modulate = Color(0, 0, 0, 1)
	label.modulate = Color(1.0, 0.55, 0.45) if kind == "head" else Color(1.0, 0.95, 0.75)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true                  # always visible — gameplay info
	label.fixed_size = false
	label.pixel_size = 0.004
	add_child(label)
	var jitter := Vector3(
		randf_range(-0.35, 0.35),
		randf_range(0.05, 0.35),
		randf_range(-0.35, 0.35),
	)
	var start_pos: Vector3 = world_pos + Vector3.UP * 0.4 + jitter
	label.global_position = start_pos
	var end_pos: Vector3 = start_pos + Vector3.UP * 0.9
	var tw := label.create_tween().set_parallel(true)
	tw.tween_property(label, "global_position", end_pos, 1.0)\
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(label, "modulate:a", 0.0, 0.55)\
		.set_delay(0.45).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(label.queue_free)

func is_any_modal_open() -> bool:
	# Used by Player._unhandled_input to avoid recapturing the mouse when a
	# UI overlay (card pick, dev panel, pause menu, settings, rematch) is visible.
	if _is_render_card_pick_visible():
		return true
	return _is_global_modal_open()


# Per-player modal check used by Player._can_accept_gameplay_input — a
# splitscreen teammate's card pick must NOT freeze everyone else on the
# same machine, only the picker themselves.
func is_modal_blocking_player(pid: int) -> bool:
	if _is_card_pick_visible_for_player(pid):
		return true
	return _is_global_modal_open()

func _is_cursor_modal_open() -> bool:
	# Only mouse-using local pickers should force the cursor visible. A
	# controller-using teammate can navigate cards without the cursor, so
	# their pick shouldn't yank mouse capture away from a kbd+mouse player
	# who's still alive and running around.
	if _is_card_pick_visible_for_mouse_player():
		return true
	if _dev_panel and _dev_panel.is_open():
		return true
	if _pause_menu and _pause_menu.visible:
		return true
	if _settings_panel and _settings_panel.visible:
		return true
	if _rematch_overlay and _rematch_overlay.visible:
		return true
	if _audio_panel and _audio_panel.visible:
		return true
	return false

func _is_global_modal_open() -> bool:
	if _dev_panel and _dev_panel.is_open():
		return true
	if _pause_menu and _pause_menu.visible:
		return true
	if _settings_panel and _settings_panel.visible:
		return true
	if _tab_root and _tab_root.visible:
		return true
	if _rematch_overlay and _rematch_overlay.visible:
		return true
	if _audio_panel and _audio_panel.visible:
		return true
	return false

func _is_render_card_pick_visible() -> bool:
	for renderer in _render_players.values():
		if renderer.is_card_pick_visible():
			return true
	if _splitscreen and _splitscreen.is_enabled() and _splitscreen.has_method("is_card_pick_visible"):
		return _splitscreen.is_card_pick_visible()
	return false


func _is_card_pick_visible_for_player(pid: int) -> bool:
	var renderer := _render_players.get(pid) as RenderPlayer
	if renderer and renderer.is_card_pick_visible():
		return true
	if _splitscreen and _splitscreen.is_enabled() and _splitscreen.has_method("is_card_pick_visible_for"):
		return bool(_splitscreen.is_card_pick_visible_for(pid))
	return false


func _is_card_pick_visible_for_mouse_player() -> bool:
	for pid in _render_players.keys():
		if not _is_card_pick_visible_for_player(int(pid)):
			continue
		if _player_uses_mouse(int(pid)):
			return true
	if _splitscreen and _splitscreen.is_enabled() and _splitscreen.has_method("_local_player_ids"):
		for pid in _splitscreen._local_player_ids():
			if not _is_card_pick_visible_for_player(int(pid)):
				continue
			if _player_uses_mouse(int(pid)):
				return true
	return false


func _player_uses_mouse(pid: int) -> bool:
	var p := players_root.get_node_or_null(str(pid))
	if p == null:
		return false
	return int(p.get("local_input_device")) < 0

func _sync_mouse_mode() -> void:
	var modal_open := _is_cursor_modal_open()
	var desired := Input.MOUSE_MODE_CAPTURED
	if modal_open:
		desired = Input.MOUSE_MODE_VISIBLE
	if Input.mouse_mode != desired:
		Input.mouse_mode = desired

func _grab_first_menu_focus(root: Node) -> void:
	if root == null:
		return
	var focus_target := _find_focusable_menu_control(root)
	if focus_target:
		focus_target.grab_focus()
	call_deferred("_grab_first_menu_focus_deferred", root)

func _grab_first_menu_focus_deferred(root: Node) -> void:
	if not is_instance_valid(root):
		return
	var focus_target := _find_focusable_menu_control(root)
	if focus_target:
		focus_target.grab_focus()

func _find_focusable_menu_control(node: Node) -> Control:
	if node is Control:
		var control := node as Control
		if not control.visible:
			return null
		if control.focus_mode != Control.FOCUS_NONE and not (control is LineEdit):
			var disabled := false
			if control is BaseButton:
				disabled = (control as BaseButton).disabled
			if not disabled:
				return control
	for child in node.get_children():
		var focusable := _find_focusable_menu_control(child)
		if focusable:
			return focusable
	return null

# -------------------- PAUSE MENU (ESC) --------------------

func _toggle_pause_menu() -> void:
	if _pause_menu == null:
		_build_pause_menu()
	_pause_menu.visible = not _pause_menu.visible
	if _pause_menu.visible:
		# Refresh the game-ID field — the iroh server may have come up after
		# _build_pause_menu ran (host_game_iroh in _ready races with the
		# pause menu's lazy build).
		_pause_refresh_game_id()
		_refresh_pause_seed_label()
		_update_join_form()
		_refresh_bot_counter()
		_sync_mouse_mode()
		_grab_first_menu_focus(_pause_menu)
		# Pause the world if this is a solo match (local player + bots only).
		if _human_count() <= 1:
			get_tree().paused = true
	else:
		# Unpause if we were paused.
		get_tree().paused = false
		_sync_mouse_mode()

func _build_pause_menu() -> void:
	var root := Control.new()
	root.name = "PauseMenu"
	root.anchor_right = 1.0
	root.anchor_bottom = 1.0
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	root.process_mode = Node.PROCESS_MODE_ALWAYS
	$HUD.add_child(root)

	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.55)
	bg.anchor_right = 1.0
	bg.anchor_bottom = 1.0
	root.add_child(bg)

	var center := CenterContainer.new()
	center.anchor_right = 1.0
	center.anchor_bottom = 1.0
	root.add_child(center)

	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.08, 0.1, 0.95)
	sb.border_color = Color(0.35, 0.7, 1.0)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 28
	sb.content_margin_right = 28
	sb.content_margin_top = 22
	sb.content_margin_bottom = 22
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	panel.add_child(vb)

	# Game title — readable from across the room.
	var title := Label.new()
	title.text = "MORE ROUNDS"
	title.add_theme_font_size_override("font_size", 36)
	title.add_theme_color_override("font_color", Color(1, 0.9, 0.45))
	title.add_theme_color_override("font_outline_color", Color(0.4, 0.0, 0.1))
	title.add_theme_constant_override("outline_size", 6)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)

	# Spacer to separate title from the multiplayer rows.
	var spacer1 := Control.new()
	spacer1.custom_minimum_size = Vector2(0, 6)
	vb.add_child(spacer1)

	# ── Share my game ID ──
	var share_label := Label.new()
	share_label.text = "Share your match with friends:"
	share_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.85))
	vb.add_child(share_label)

	var id_row := HBoxContainer.new()
	id_row.add_theme_constant_override("separation", 8)
	vb.add_child(id_row)
	# LineEdit instead of Label so the user can drag-select + Cmd+C the ID
	# manually if the Copy button isn't enough.
	var id_field := LineEdit.new()
	id_field.editable = false
	id_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	id_field.custom_minimum_size = Vector2(360, 36)
	id_field.placeholder_text = "(no game ID — not hosting)"
	id_row.add_child(id_field)
	var copy_btn := Button.new()
	copy_btn.text = "COPY"
	copy_btn.custom_minimum_size = Vector2(80, 36)
	id_row.add_child(copy_btn)
	# Stash so _toggle_pause_menu can refresh the field every time the menu opens.
	_pause_id_field = id_field
	_pause_copy_button = copy_btn
	copy_btn.pressed.connect(_pause_copy_game_id)

	# ── Join someone else's game ──
	var join_label := Label.new()
	join_label.text = "Or join a friend:"
	join_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.85))
	vb.add_child(join_label)

	var join_row := HBoxContainer.new()
	join_row.add_theme_constant_override("separation", 8)
	vb.add_child(join_row)
	var join_input := LineEdit.new()
	join_input.placeholder_text = "Paste a Game ID…"
	join_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	join_input.custom_minimum_size = Vector2(360, 36)
	join_input.text_changed.connect(_on_join_input_changed)
	join_input.text_submitted.connect(func(_t: String) -> void: _pause_join())
	join_row.add_child(join_input)
	var join_btn := Button.new()
	join_btn.text = "JOIN"
	join_btn.custom_minimum_size = Vector2(80, 36)
	join_btn.disabled = true
	join_btn.pressed.connect(_pause_join)
	join_row.add_child(join_btn)
	_pause_join_input = join_input
	_pause_join_button = join_btn

	var join_notice := Label.new()
	join_notice.text = "Paste a 52-character iroh node ID"
	join_notice.add_theme_font_size_override("font_size", 12)
	join_notice.add_theme_color_override("font_color", Color(0.55, 0.60, 0.72))
	vb.add_child(join_notice)
	_pause_join_notice = join_notice

	# ── Bot count ──
	var bot_label := Label.new()
	bot_label.text = "Bots:"
	bot_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.85))
	vb.add_child(bot_label)

	var bot_row := HBoxContainer.new()
	bot_row.add_theme_constant_override("separation", 8)
	vb.add_child(bot_row)

	var bot_minus := Button.new()
	bot_minus.text = "-"
	bot_minus.custom_minimum_size = Vector2(44, 36)
	bot_minus.pressed.connect(_pause_remove_bot)
	bot_row.add_child(bot_minus)

	var bot_count := Label.new()
	bot_count.text = "0"
	bot_count.custom_minimum_size = Vector2(0, 36)
	bot_count.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bot_count.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bot_count.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	bot_count.add_theme_font_size_override("font_size", 18)
	bot_count.add_theme_color_override("font_color", Color(1.0, 0.95, 0.78))
	bot_row.add_child(bot_count)

	var bot_plus := Button.new()
	bot_plus.text = "+"
	bot_plus.custom_minimum_size = Vector2(44, 36)
	bot_plus.pressed.connect(_pause_add_bot)
	bot_row.add_child(bot_plus)

	_pause_bot_count_label = bot_count
	_pause_bot_minus_button = bot_minus
	_pause_bot_plus_button = bot_plus
	_refresh_bot_counter()

	# Spacer before action buttons.
	var spacer2 := Control.new()
	spacer2.custom_minimum_size = Vector2(0, 8)
	vb.add_child(spacer2)

	var restart_btn := Button.new()
	restart_btn.text = "RESTART MATCH"
	restart_btn.custom_minimum_size = Vector2(0, 44)
	restart_btn.pressed.connect(_pause_restart_match)
	vb.add_child(restart_btn)

	var splitscreen_btn := Button.new()
	splitscreen_btn.text = "SPLITSCREEN"
	splitscreen_btn.custom_minimum_size = Vector2(0, 44)
	splitscreen_btn.pressed.connect(_pause_start_splitscreen)
	vb.add_child(splitscreen_btn)

	var settings_btn := Button.new()
	settings_btn.text = "SETTINGS"
	settings_btn.custom_minimum_size = Vector2(0, 44)
	settings_btn.pressed.connect(_open_settings)
	vb.add_child(settings_btn)

	var resume := Button.new()
	resume.text = "RESUME"
	resume.custom_minimum_size = Vector2(0, 44)
	resume.pressed.connect(_toggle_pause_menu)
	# Esc / Enter close the menu; the _input handler also routes those keys
	# through here, but the Shortcut keeps focus-driven controllers happy.
	var shortcut := Shortcut.new()
	var ev := InputEventAction.new()
	ev.action = "ui_cancel"
	shortcut.events.append(ev)
	resume.shortcut = shortcut
	vb.add_child(resume)

	var exit_btn := Button.new()
	exit_btn.text = "EXIT GAME"
	exit_btn.custom_minimum_size = Vector2(0, 44)
	exit_btn.pressed.connect(_quit_game)
	vb.add_child(exit_btn)

	# Subtle map+seed readout pinned to the bottom-right corner of the screen
	# (sibling of the bg + panel so it's not constrained by the center column).
	var seed_label := Label.new()
	seed_label.name = "SeedLabel"
	seed_label.add_theme_color_override("font_color", Color(0.72, 0.72, 0.85, 0.85))
	seed_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	seed_label.add_theme_constant_override("outline_size", 3)
	seed_label.add_theme_font_size_override("font_size", 13)
	seed_label.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	seed_label.offset_left = -260
	seed_label.offset_top = -28
	seed_label.offset_right = -12
	seed_label.offset_bottom = -8
	seed_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	seed_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(seed_label)
	_pause_seed_label = seed_label
	_refresh_pause_seed_label()

	_pause_menu = root
	_pause_menu.visible = false


# Pause-menu controls — set in _build_pause_menu, used by the action handlers
# below so we don't need to walk the scene tree to find them.
var _pause_id_field: LineEdit = null
var _pause_copy_button: Button = null
var _pause_join_input: LineEdit = null
var _pause_join_button: Button = null
var _pause_join_notice: Label = null
var _pause_bot_count_label: Label = null
var _pause_bot_minus_button: Button = null
var _pause_bot_plus_button: Button = null
var _pause_seed_label: Label = null
var _settings_panel: Control = null
var _settings_retro_toggle: CheckButton = null
var _settings_music_slider: HSlider = null
var _settings_music_value_label: Label = null
var _settings_mouse_slider: HSlider = null
var _settings_mouse_value_label: Label = null
var _settings_tilt_toggle: CheckButton = null


func _open_settings() -> void:
	if _settings_panel == null:
		_build_settings_panel()
	if _pause_menu:
		_pause_menu.visible = false
	# Sync controls to the live state in case the values changed via some
	# other path (CLI flag, save edit, etc.) since the panel was last opened.
	if _settings_retro_toggle:
		_settings_retro_toggle.set_pressed_no_signal(_retro_enabled)
	if _settings_music_slider:
		_settings_music_slider.set_value_no_signal(_music_db)
		if _settings_music_value_label:
			_settings_music_value_label.text = _music_label_for(_music_db)
	if _settings_mouse_slider:
		_settings_mouse_slider.set_value_no_signal(_mouse_sens_mult)
		if _settings_mouse_value_label:
			_settings_mouse_value_label.text = "%.2fx" % _mouse_sens_mult
	if _settings_tilt_toggle:
		_settings_tilt_toggle.set_pressed_no_signal(_movement_tilt_enabled)
	_settings_panel.visible = true
	_grab_first_menu_focus(_settings_panel)


func _music_label_for(db: float) -> String:
	if db <= MUSIC_DB_MIN + 0.5:
		return "Off"
	return "%.0f dB" % db


func _close_settings() -> void:
	if _settings_panel:
		_settings_panel.visible = false
	if _pause_menu:
		_pause_menu.visible = true
		_grab_first_menu_focus(_pause_menu)


func _build_settings_panel() -> void:
	# Mirrors the visual style of _build_pause_menu so the two screens read
	# as part of the same flow. Toggles persist immediately on change.
	var root := Control.new()
	root.name = "SettingsPanel"
	root.anchor_right = 1.0
	root.anchor_bottom = 1.0
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	root.process_mode = Node.PROCESS_MODE_ALWAYS
	$HUD.add_child(root)

	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.55)
	bg.anchor_right = 1.0
	bg.anchor_bottom = 1.0
	root.add_child(bg)

	var center := CenterContainer.new()
	center.anchor_right = 1.0
	center.anchor_bottom = 1.0
	root.add_child(center)

	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.08, 0.1, 0.95)
	sb.border_color = Color(0.35, 0.7, 1.0)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 28
	sb.content_margin_right = 28
	sb.content_margin_top = 22
	sb.content_margin_bottom = 22
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	vb.custom_minimum_size = Vector2(420, 0)
	panel.add_child(vb)

	var title := Label.new()
	title.text = "SETTINGS"
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", Color(1, 0.9, 0.45))
	title.add_theme_color_override("font_outline_color", Color(0.4, 0.0, 0.1))
	title.add_theme_constant_override("outline_size", 5)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)

	var spacer1 := Control.new()
	spacer1.custom_minimum_size = Vector2(0, 6)
	vb.add_child(spacer1)

	var retro_toggle := CheckButton.new()
	retro_toggle.text = "Retro shader look"
	retro_toggle.button_pressed = _retro_enabled
	retro_toggle.toggled.connect(func(on: bool) -> void:
		_retro_enabled = on
		_apply_settings()
		_save_settings())
	vb.add_child(retro_toggle)
	_settings_retro_toggle = retro_toggle

	# Music volume slider — bottom of range = "Off".
	var music_row := _build_slider_row("Music", _music_db, MUSIC_DB_MIN, MUSIC_DB_MAX, 1.0, _music_label_for(_music_db))
	vb.add_child(music_row["row"])
	_settings_music_slider = music_row["slider"]
	_settings_music_value_label = music_row["value_label"]
	_settings_music_slider.value_changed.connect(func(v: float) -> void:
		_music_db = v
		if _settings_music_value_label:
			_settings_music_value_label.text = _music_label_for(v)
		_apply_settings()
		_save_settings())

	# Mouse sensitivity multiplier — 1.0 = base MOUSE_SENS in player.gd.
	var mouse_row := _build_slider_row("Mouse sensitivity", _mouse_sens_mult, 0.3, 3.0, 0.05, "%.2fx" % _mouse_sens_mult)
	vb.add_child(mouse_row["row"])
	_settings_mouse_slider = mouse_row["slider"]
	_settings_mouse_value_label = mouse_row["value_label"]
	_settings_mouse_slider.value_changed.connect(func(v: float) -> void:
		_mouse_sens_mult = v
		if _settings_mouse_value_label:
			_settings_mouse_value_label.text = "%.2fx" % v
		_apply_settings()
		_save_settings())

	# Movement tilt — strafe-driven camera + gun roll. Some players hate it.
	var tilt_toggle := CheckButton.new()
	tilt_toggle.text = "Movement tilt"
	tilt_toggle.button_pressed = _movement_tilt_enabled
	tilt_toggle.toggled.connect(func(on: bool) -> void:
		_movement_tilt_enabled = on
		_apply_settings()
		_save_settings())
	vb.add_child(tilt_toggle)
	_settings_tilt_toggle = tilt_toggle

	var spacer2 := Control.new()
	spacer2.custom_minimum_size = Vector2(0, 8)
	vb.add_child(spacer2)

	var back_btn := Button.new()
	back_btn.text = "BACK"
	back_btn.custom_minimum_size = Vector2(0, 44)
	back_btn.pressed.connect(_close_settings)
	# Esc returns to the pause menu — without this you'd be stuck in
	# settings since Game._input early-returns while the tree is paused.
	var back_shortcut := Shortcut.new()
	var back_ev := InputEventAction.new()
	back_ev.action = "ui_cancel"
	back_shortcut.events.append(back_ev)
	back_btn.shortcut = back_shortcut
	vb.add_child(back_btn)

	_settings_panel = root
	_settings_panel.visible = false


func _show_name_prompt() -> void:
	# Blocking modal shown on first launch (no name in settings.cfg). _ready
	# awaits _player_name_set before continuing to host_game_iroh, so the
	# server is created with the player's chosen name on the very first try.
	var modal := Control.new()
	modal.name = "NamePrompt"
	modal.process_mode = Node.PROCESS_MODE_ALWAYS
	modal.anchor_right = 1.0
	modal.anchor_bottom = 1.0
	modal.mouse_filter = Control.MOUSE_FILTER_STOP
	$HUD.add_child(modal)

	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.65)
	bg.anchor_right = 1.0
	bg.anchor_bottom = 1.0
	modal.add_child(bg)

	var center := CenterContainer.new()
	center.anchor_right = 1.0
	center.anchor_bottom = 1.0
	modal.add_child(center)

	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.08, 0.1, 0.95)
	sb.border_color = Color(0.35, 0.7, 1.0)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 28
	sb.content_margin_right = 28
	sb.content_margin_top = 22
	sb.content_margin_bottom = 22
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	vb.custom_minimum_size = Vector2(380, 0)
	panel.add_child(vb)

	var title := Label.new()
	title.text = "WHAT'S YOUR NAME?"
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", Color(1, 0.9, 0.45))
	title.add_theme_color_override("font_outline_color", Color(0.4, 0.0, 0.1))
	title.add_theme_constant_override("outline_size", 5)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)

	var input := LineEdit.new()
	input.placeholder_text = "Your callsign…"
	input.max_length = 20
	input.custom_minimum_size = Vector2(360, 36)
	vb.add_child(input)

	var submit_btn := Button.new()
	submit_btn.text = "READY"
	submit_btn.custom_minimum_size = Vector2(0, 44)
	vb.add_child(submit_btn)

	var on_submit := func() -> void:
		var entered: String = input.text.strip_edges()
		if entered.is_empty():
			# Empty submit falls back to a Player_NNN handle so we never
			# end up with a blank string in NetworkManager.
			entered = "Player_%d" % (randi() % 1000)
		_player_name = entered
		_save_settings()
		modal.queue_free()
		_player_name_set.emit()

	submit_btn.pressed.connect(on_submit)
	input.text_submitted.connect(func(_t: String) -> void: on_submit.call())
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	input.call_deferred("grab_focus")


func _build_slider_row(label_text: String, value: float, min_val: float, max_val: float, step: float, value_text: String) -> Dictionary:
	# Returns {row: HBoxContainer, slider: HSlider, value_label: Label} so the
	# caller can wire signals and update the live value display.
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(170, 0)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.95))
	row.add_child(label)
	var slider := HSlider.new()
	slider.min_value = min_val
	slider.max_value = max_val
	slider.step = step
	slider.value = clampf(value, min_val, max_val)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size = Vector2(180, 28)
	row.add_child(slider)
	var value_label := Label.new()
	value_label.text = value_text
	value_label.custom_minimum_size = Vector2(70, 0)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	value_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.85))
	row.add_child(value_label)
	return {"row": row, "slider": slider, "value_label": value_label}


# Last map swap inputs — used by the pause menu's seed label (and any future
# "rejoin same map" feature). Updated in _swap_arena.
var current_map_index: int = 0
var current_map_seed: int = 0


func _refresh_pause_seed_label() -> void:
	if _pause_seed_label == null:
		return
	var map_name: String = "?"
	if current_map_index >= 0 and current_map_index < MAP_POOL.size():
		map_name = MAP_POOL[current_map_index].resource_path.get_file().get_basename()
	_pause_seed_label.text = "%s · seed %d" % [map_name, current_map_seed]


func _pause_refresh_game_id() -> void:
	# Called whenever the pause menu opens — the iroh server might have been
	# created after _build_pause_menu ran (or torn down because we became a
	# client), so the field is refreshed lazily.
	if _pause_id_field == null:
		return
	var id := NetworkManager.current_iroh_game_id
	_pause_id_field.text = id
	var hosting := id != ""
	_pause_copy_button.disabled = not hosting
	_pause_id_field.editable = false  # always read-only; copying via select+keyboard or button


func _pause_copy_game_id() -> void:
	var id := NetworkManager.current_iroh_game_id
	if id.is_empty():
		return
	DisplayServer.clipboard_set(id)
	# Brief affordance — flash the button label so the user sees something happened.
	if _pause_copy_button:
		var orig := _pause_copy_button.text
		_pause_copy_button.text = "COPIED!"
		await get_tree().create_timer(0.8).timeout
		if is_instance_valid(_pause_copy_button):
			_pause_copy_button.text = orig


func _on_join_input_changed(text: String) -> void:
	var extracted := _extract_iroh_node_id(text)
	if not extracted.is_empty() and extracted != text:
		var old_caret := _pause_join_input.caret_column if _pause_join_input else 0
		_pause_join_input.set_text(extracted)
		_pause_join_input.caret_column = mini(old_caret, extracted.length())
		text = extracted
	_update_join_form()
	if _is_valid_iroh_node_id(text) and not _join_in_progress and _join_auto_submit_text != text:
		_join_auto_submit_text = text
		call_deferred("_pause_join")


func _update_join_form() -> void:
	var text := _pause_join_input.text.strip_edges() if _pause_join_input else ""
	var valid := _is_valid_iroh_node_id(text)
	if _pause_join_button:
		_pause_join_button.disabled = _join_in_progress or not valid
		_pause_join_button.text = "..." if _join_in_progress else "JOIN"
	if _pause_join_notice:
		if _join_in_progress:
			_pause_join_notice.text = "Connecting..."
			_pause_join_notice.add_theme_color_override("font_color", Color(0.76, 0.92, 1.0))
		elif text.is_empty():
			_pause_join_notice.text = "Paste a 52-character iroh node ID"
			_pause_join_notice.add_theme_color_override("font_color", Color(0.55, 0.60, 0.72))
		elif valid:
			_pause_join_notice.text = "Valid ID - connecting automatically"
			_pause_join_notice.add_theme_color_override("font_color", Color(0.58, 1.0, 0.65))
		else:
			_pause_join_notice.text = "That does not look like an iroh node ID"
			_pause_join_notice.add_theme_color_override("font_color", Color(1.0, 0.62, 0.50))


func _extract_iroh_node_id(text: String) -> String:
	var lower := text.strip_edges().to_lower()
	var run := ""
	for i in lower.length():
		var ch := lower.substr(i, 1)
		if IROH_NODE_ID_CHARS.contains(ch):
			run += ch
			if run.length() == IROH_NODE_ID_LENGTH:
				return run
		else:
			run = ""
	return lower


func _is_valid_iroh_node_id(text: String) -> bool:
	var id := text.strip_edges().to_lower()
	if id.length() != IROH_NODE_ID_LENGTH:
		return false
	for i in id.length():
		if not IROH_NODE_ID_CHARS.contains(id.substr(i, 1)):
			return false
	return true


func _refresh_bot_counter() -> void:
	var count := _bot_ids().size()
	if _pause_bot_count_label:
		_pause_bot_count_label.text = str(count)
	if _pause_bot_minus_button:
		_pause_bot_minus_button.disabled = not multiplayer.is_server() or count <= 0
	if _pause_bot_plus_button:
		_pause_bot_plus_button.disabled = not multiplayer.is_server() or count >= BOT_ID_LIMIT - BOT_ID_BASE


func _pause_add_bot() -> void:
	if not multiplayer.is_server():
		_announce("BOTS ARE HOST-ONLY", 1.5)
		return
	_spawn_bots(1)


func _pause_remove_bot() -> void:
	if not multiplayer.is_server():
		_announce("BOTS ARE HOST-ONLY", 1.5)
		return
	_despawn_one_bot()


func _pause_join() -> void:
	if _pause_join_input == null:
		return
	if _join_in_progress:
		return
	var game_id := _extract_iroh_node_id(_pause_join_input.text)
	if not _is_valid_iroh_node_id(game_id):
		_update_join_form()
		return
	_pause_join_input.set_text(game_id)
	_join_in_progress = true
	_update_join_form()
	# Tear down the current iroh server (we're switching from host to client),
	# then reload the scene with the new IrohClient peer in place. The reload
	# branches into the `else` arm of _ready (multiplayer.is_server() == false)
	# which waits for connected_to_server before requesting a spawn.
	get_tree().paused = false
	if multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	NetworkManager.players.clear()
	if not NetworkManager.join_game_iroh(game_id, "Player_%d" % (randi() % 1000)):
		_join_in_progress = false
		_update_join_form()
		if not NetworkManager.last_network_error.is_empty():
			_on_network_status_changed(NetworkManager.last_network_error, true)
		return
	get_tree().change_scene_to_file("res://scenes/game.tscn")


func _pause_start_splitscreen() -> void:
	if not multiplayer.is_server():
		_announce("SPLITSCREEN IS HOST-ONLY", 2.0)
		return
	NetworkManager.set_meta("splitscreen_on_start", true)
	if _splitscreen and _splitscreen.has_method("enable"):
		var primary_device := _last_controller_device if _last_input_was_controller else -1
		_splitscreen.enable(primary_device)
	_despawn_all_bots()
	pending_picker_id = 0
	pending_pick_cards.clear()
	pending_pick_cards_by_player.clear()
	completed_picks.clear()
	eliminated_players.clear()
	round_winner_id = 0
	state = State.WAITING
	_hide_card_pick.rpc()
	_hide_rematch_overlay.rpc()
	_broadcast_scores.rpc(round_wins)
	_update_scoreboard()
	if _pause_menu and _pause_menu.visible:
		_toggle_pause_menu()
	get_tree().paused = false
	_sync_mouse_mode()
	# The "PRESS X TO JOIN" hint lives on the persistent _join_label managed
	# by splitscreen_manager — no central banner here, otherwise the host
	# sees the same prompt twice (and one of them sticks around).
	_refresh_splitscreen_hint()


func _pause_restart_match() -> void:
	# Close the pause menu first so the round-start banner is visible.
	if _pause_menu and _pause_menu.visible:
		_toggle_pause_menu()
	if multiplayer.is_server():
		_restart_match()


func _quit_game() -> void:
	get_tree().paused = false
	get_tree().quit()

func show_damage_direction_for(player_id: int, from_pos: Vector3) -> void:
	if _splitscreen and _splitscreen.is_enabled() and _splitscreen.has_method("show_damage_direction_for"):
		if _splitscreen.show_damage_direction_for(player_id, from_pos):
			return
	var renderer := _render_players.get(player_id) as RenderPlayer
	if renderer:
		renderer.show_damage_direction(from_pos)

func _update_scoreboard() -> void:
	var lines: Array[String] = ["— ROUNDS —"]
	for id in NetworkManager.players:
		var wins := int(round_wins.get(id, 0))
		var marker := "  ★" if wins >= rounds_to_win else ""
		var pname := str(NetworkManager.players[id])
		lines.append("%s  %d/%d%s" % [pname, wins, rounds_to_win, marker])

	scoreboard.text = "\n".join(lines)

# -------------------- TAB SCOREBOARD OVERLAY --------------------

func _build_tab_overlay() -> void:
	_tab_root = PanelContainer.new()
	_tab_root.anchor_left = 0.5
	_tab_root.anchor_right = 0.5
	_tab_root.anchor_top = 0.12
	_tab_root.anchor_bottom = 0.88
	_tab_root.offset_left = -360.0
	_tab_root.offset_right = 360.0
	_tab_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tab_root.visible = false
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.04, 0.07, 0.93)
	style.set_border_width_all(2)
	style.border_color = Color(1.0, 0.85, 0.4, 0.8)
	style.set_corner_radius_all(6)
	style.content_margin_left = 20
	style.content_margin_right = 20
	style.content_margin_top = 16
	style.content_margin_bottom = 16
	_tab_root.add_theme_stylebox_override("panel", style)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_tab_root.add_child(scroll)
	_tab_content = VBoxContainer.new()
	_tab_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tab_content.add_theme_constant_override("separation", 10)
	scroll.add_child(_tab_content)
	$HUD.add_child(_tab_root)

func _show_tab_overlay() -> void:
	if _tab_root == null:
		_build_tab_overlay()
	_tab_refresh_timer = 0.5
	_refresh_tab_overlay()
	_tab_root.visible = true

func _hide_tab_overlay() -> void:
	if _tab_root:
		_tab_root.visible = false

func _refresh_tab_overlay() -> void:
	for c in _tab_content.get_children():
		c.queue_free()
	var header := Label.new()
	header.text = "SCOREBOARD"
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.add_theme_font_size_override("font_size", 28)
	header.add_theme_color_override("font_color", Color(1, 0.9, 0.5))
	_tab_content.add_child(header)
	var sub := Label.new()
	sub.text = "first to %d rounds wins" % rounds_to_win
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 13)
	sub.add_theme_color_override("font_color", Color(0.65, 0.65, 0.8))
	_tab_content.add_child(sub)
	_tab_content.add_child(HSeparator.new())
	for id in NetworkManager.players:
		_tab_content.add_child(_tab_player_row(int(id)))

func _tab_player_row(id: int) -> Control:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	# Name + kills line
	var hbox := HBoxContainer.new()
	var nlbl := Label.new()
	nlbl.text = str(NetworkManager.players.get(id, "Player"))
	nlbl.add_theme_font_size_override("font_size", 20)
	nlbl.add_theme_color_override("font_color", Color(1, 1, 1))
	nlbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(nlbl)
	var wins := int(round_wins.get(id, 0))
	var score_lbl := Label.new()
	score_lbl.text = "%d / %d" % [wins, rounds_to_win]
	score_lbl.add_theme_font_size_override("font_size", 20)
	score_lbl.add_theme_color_override("font_color", Color(1, 0.85, 0.4))
	hbox.add_child(score_lbl)
	var ping_lbl := Label.new()
	ping_lbl.text = _ping_label_for(id)
	ping_lbl.custom_minimum_size = Vector2(82, 0)
	ping_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	ping_lbl.add_theme_font_size_override("font_size", 16)
	ping_lbl.add_theme_color_override("font_color", _ping_color_for(id))
	hbox.add_child(ping_lbl)
	row.add_child(hbox)
	# Cards as colored pills (empty for fresh players).
	var p_node := players_root.get_node_or_null(str(id))
	if p_node and p_node.get("weapon") != null:
		var cards: Array = p_node.weapon.applied_cards
		if cards.is_empty():
			var empty_lbl := Label.new()
			empty_lbl.text = "    (no cards)"
			empty_lbl.add_theme_font_size_override("font_size", 12)
			empty_lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
			row.add_child(empty_lbl)
		else:
			var flow := HFlowContainer.new()
			flow.add_theme_constant_override("h_separation", 6)
			flow.add_theme_constant_override("v_separation", 4)
			for cid in cards:
				var cdata := CardLibrary.by_id(str(cid))
				if cdata.is_empty():
					continue
				flow.add_child(_tab_card_pill(str(cdata.get("name", cid)), cdata.get("color", Color.WHITE)))
			row.add_child(flow)
	return row


func _ping_label_for(id: int) -> String:
	if _is_bot_id(id):
		return "BOT"
	var ping := int(_ping_ms_by_player.get(id, -1))
	if ping < 0:
		return "-- ms"
	return "%d ms" % ping


func _ping_color_for(id: int) -> Color:
	if _is_bot_id(id):
		return Color(0.55, 0.55, 0.65)
	var ping := int(_ping_ms_by_player.get(id, -1))
	if ping < 0:
		return Color(0.65, 0.65, 0.75)
	if ping >= HIGH_PING_WARN_MS:
		return Color(1.0, 0.42, 0.35)
	if ping >= 100:
		return Color(1.0, 0.78, 0.35)
	return Color(0.55, 1.0, 0.65)

func _tab_card_pill(text: String, col: Color) -> Control:
	var pc := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(col.r * 0.22, col.g * 0.22, col.b * 0.22, 0.95)
	sb.border_color = col
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(3)
	sb.content_margin_left = 7
	sb.content_margin_right = 7
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	pc.add_theme_stylebox_override("panel", sb)
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.add_theme_color_override("font_color", col)
	pc.add_child(lbl)
	return pc

func _restart_match() -> void:
	if not multiplayer.is_server():
		return
	state = State.WAITING
	round_wins.clear()
	for pid in NetworkManager.players:
		round_wins[pid] = 0
	_broadcast_scores.rpc(round_wins)
	_maybe_start_match()
