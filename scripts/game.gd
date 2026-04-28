extends Node3D

const PLAYER_SCENE := preload("res://scenes/player.tscn")
const HUD_ICON_SCRIPT := preload("res://scripts/hud_icon.gd")
const DEV_PANEL_SCRIPT := preload("res://scripts/dev_panel.gd")
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
const SPLIT_PLAYER_ID_BASE := 10000

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
@onready var health_label: Label = $HUD/HealthPanel/HealthLabel
@onready var scoreboard: Label = $HUD/Scoreboard
@onready var hitmarker: Control = $HUD/Hitmarker
@onready var damage_indicator: Control = $HUD/DamageIndicator
@onready var rifle_label: Label = $HUD/AbilityBar/Rifle/Label
@onready var rifle_bar: ProgressBar = $HUD/AbilityBar/Rifle/Bar
@onready var grenade_bar: ProgressBar = $HUD/AbilityBar/Grenade/Bar
@onready var grenade_label: Label = $HUD/AbilityBar/Grenade/Label
@onready var melee_bar: ProgressBar = $HUD/AbilityBar/Melee/Bar
@onready var dash_bar: ProgressBar = $HUD/AbilityBar/Dash/Bar
@onready var round_banner: Label = $HUD/RoundBanner
@onready var banner_timer: Timer = $HUD/BannerTimer
@onready var pick_overlay: Control = $HUD/CardPickOverlay
@onready var pick_title: Label = $HUD/CardPickOverlay/Center/VBox/Title
@onready var pick_subtitle: Label = $HUD/CardPickOverlay/Center/VBox/Subtitle
@onready var pick_row: HBoxContainer = $HUD/CardPickOverlay/Center/VBox/CardRow

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
var local_player: Node3D
var _custom_crosshair: Control = null
var _stats_panel: Control = null
var _stats_content: GridContainer = null

var _pick_timeout_timer: float = 0.0
var _pick_timeout_active: bool = false
var _last_pling_sec: int = -1

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
var _ghost_overlay: Control = null
var _ghost_label: Label = null
var _death_overlay: ColorRect = null
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

var _dash_segments: Array[ProgressBar] = []
var _dash_text_hbox: Control = null
var _last_input_was_controller := false
# Owned by scripts/splitscreen_manager.gd, instantiated in _ready as a child
# Node. Reads NetworkManager metadata to decide whether to build its layer.
var _splitscreen: Node = null
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

	# --- Ability Bar Redesign ---
	# Hide legacy components
	var melee_cont = $HUD/AbilityBar/Melee
	if melee_cont: melee_cont.visible = false
	if dash_bar: dash_bar.visible = false
	if rifle_bar: rifle_bar.visible = false
	if grenade_bar: grenade_bar.visible = false

	# 1. Setup Rifle & Grenade overlays
	for info in [
		{"cont": $HUD/AbilityBar/Rifle, "bar": rifle_bar, "lbl": rifle_label, "type": 1, "color": Color(1, 0.9, 0.5)}, # LMB
		{"cont": $HUD/AbilityBar/Grenade, "bar": grenade_bar, "lbl": grenade_label, "type": 2, "color": Color(0.7, 1, 0.4)} # RMB
	]:
		var c: Control = info.cont
		var b: ProgressBar = info.bar
		var l: Label = info.lbl

		# Overlay layout
		b.get_parent().remove_child(b)
		l.get_parent().remove_child(l)

		var overlay := PanelContainer.new()
		overlay.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
		overlay.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
		c.add_child(overlay)

		b.custom_minimum_size.y = 28
		overlay.add_child(b)

		var hbox := HBoxContainer.new()
		hbox.alignment = BoxContainer.ALIGNMENT_CENTER
		hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hbox.add_theme_constant_override("separation", 8)
		overlay.add_child(hbox)

		# Create icon
		var icon := Control.new()
		icon.custom_minimum_size = Vector2(38, 20)
		icon.set_script(HUD_ICON_SCRIPT)
		icon.set("icon_type", info.type)
		icon.set("icon_color", info.color)
		hbox.add_child(icon)

		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		l.text = "" # We'll set the action name (RIFLE/GRENADE) in _refresh
		hbox.add_child(l)

	# 2. Setup Dash Segmented Overlay
	var dash_cont := $HUD/AbilityBar/Dash
	var dash_lbl := $HUD/AbilityBar/Dash/Label
	dash_lbl.get_parent().remove_child(dash_lbl)

	var d_overlay := PanelContainer.new()
	d_overlay.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	d_overlay.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	dash_cont.add_child(d_overlay)

	var d_bar_hbox := HBoxContainer.new()
	d_bar_hbox.add_theme_constant_override("separation", 4)
	d_overlay.add_child(d_bar_hbox)

	for i in range(2):
		var seg := ProgressBar.new()
		seg.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		seg.custom_minimum_size.y = 28
		seg.max_value = 1.0
		seg.show_percentage = false
		d_bar_hbox.add_child(seg)
		_dash_segments.append(seg)

	_dash_text_hbox = HBoxContainer.new()
	_dash_text_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	_dash_text_hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dash_text_hbox.add_theme_constant_override("separation", 8)
	d_overlay.add_child(_dash_text_hbox)

	var d_icon := Control.new()
	d_icon.custom_minimum_size = Vector2(46, 20) # Wider for SHIFT
	d_icon.set_script(HUD_ICON_SCRIPT)
	d_icon.set("icon_type", 0) # SHIFT
	d_icon.set("icon_color", Color(0.6, 0.9, 1.0))
	_dash_text_hbox.add_child(d_icon)

	dash_lbl.text = "DASH"
	_dash_text_hbox.add_child(dash_lbl)

	# Always-process so the retro-shader cursor + mouse-mode keep updating
	# while the world is paused (pause menu open). Gameplay-tickling parts of
	# _process and _input are guarded with explicit get_tree().paused checks
	# below so they still pause correctly.
	process_mode = Node.PROCESS_MODE_ALWAYS

	_custom_crosshair = Control.new()
	_custom_crosshair.name = "DynamicCrosshair"
	_custom_crosshair.set_anchors_preset(Control.PRESET_FULL_RECT)
	_custom_crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_custom_crosshair.set_script(load("res://scripts/crosshair.gd"))
	$HUD.add_child(_custom_crosshair)

	# Networking auto-bootstrap moved further down — see the IrohServer.start()
	# call right before the multiplayer.is_server() branch. Iroh is the only
	# transport now; LAN/ENet auto-connect was removed with the main menu.

	NetworkManager.player_list_changed.connect(_update_scoreboard)
	banner_timer.timeout.connect(func() -> void: round_banner.visible = false)
	pick_overlay.visible = false
	round_banner.visible = false
	scoreboard.visible = false
	_build_rematch_overlay()
	_build_ghost_overlay()
	_build_custom_cursor()
	_build_death_overlay()
	_build_explosion_flash_overlay()
	_build_retro_filter()
	_load_settings()
	_apply_settings()
	_build_tab_overlay()
	_build_stats_panel()
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
		NetworkManager.host_game_iroh(_player_name)

	if multiplayer.is_server():
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

func _install_controller_input_map() -> void:
	_add_joy_axis_action("move_left", JOY_AXIS_LEFT_X, -1.0)
	_add_joy_axis_action("move_right", JOY_AXIS_LEFT_X, 1.0)
	_add_joy_axis_action("move_forward", JOY_AXIS_LEFT_Y, -1.0)
	_add_joy_axis_action("move_back", JOY_AXIS_LEFT_Y, 1.0)
	_add_joy_axis_action("shoot", JOY_AXIS_TRIGGER_RIGHT, 1.0)
	_add_joy_button_action("shoot_grenade", JOY_BUTTON_RIGHT_SHOULDER)
	_add_joy_button_action("shoot_grenade", JOY_BUTTON_B)
	_add_joy_button_action("jump", JOY_BUTTON_LEFT_SHOULDER)
	_add_joy_button_action("jump", JOY_BUTTON_A)
	_add_joy_button_action("reload", JOY_BUTTON_X)
	_add_joy_button_action("dash", JOY_BUTTON_LEFT_STICK)

func _add_joy_button_action(action: StringName, button_index: int) -> void:
	if not InputMap.has_action(action):
		return
	var event := InputEventJoypadButton.new()
	event.button_index = button_index
	if not InputMap.action_has_event(action, event):
		InputMap.action_add_event(action, event)

func _add_joy_axis_action(action: StringName, axis: int, axis_value: float) -> void:
	if not InputMap.has_action(action):
		return
	var event := InputEventJoypadMotion.new()
	event.axis = axis
	event.axis_value = axis_value
	if not InputMap.action_has_event(action, event):
		InputMap.action_add_event(action, event)

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

func _process(delta: float) -> void:
	_update_explosion_sidechain(delta)
	_sync_mouse_mode()
	if multiplayer.is_server() and state == State.PLAYING:
		_update_round_music_phase()
	_update_custom_cursor()
	if local_player and is_instance_valid(local_player):
		health_label.text = "GHOST" if local_player.get("ghost_mode") == true else "HP  %d" % local_player.health
		_refresh_cooldowns()
		_update_ghost_overlay()

		# Crosshair reflects effective spread (base + movement + recoil) so the
		# reticle visibly blooms when sprinting / spamming.
		if _custom_crosshair:
			_custom_crosshair.spread = local_player.get_effective_spread()
	# Splitscreen camera sync runs from splitscreen_manager._process when enabled.

	if _pick_timeout_active and not get_tree().paused:
		_pick_timeout_timer -= delta
		var sec := int(ceil(_pick_timeout_timer))

		# Show countdown in subtitle
		if pick_overlay.visible:
			pick_subtitle.text = "you lost the round — choose an upgrade (%ds left)" % max(0, sec)

		# Audio feedback in last 3 seconds
		if sec <= 3 and sec > 0 and sec != _last_pling_sec:
			_last_pling_sec = sec
			# Increase by 1 semitone every second
			var semitones := (3 - sec)
			var pitch := pow(2.0, float(semitones) / 12.0)
			SFX.pling(pitch)

		if _pick_timeout_timer <= 0.0:
			_on_pick_timeout()

	# Tab is handled in _input — Godot's GUI focus navigation eats the Tab key
	# before _process polling can see it, so we intercept it earlier.

func _input(event: InputEvent) -> void:
	# Pause-menu controls live on a Control with PROCESS_MODE_ALWAYS that has
	# its own Esc/Enter shortcut. Early-out during pause so the same key
	# event isn't double-handled here AND on the menu's Resume button.
	if get_tree().paused:
		return
	_track_input_device(event)
	if _splitscreen and _splitscreen.handle_input(event):
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

	# Pause menu: ui_cancel (Esc), Enter, and numpad Enter.
	var pause_pressed: bool = event.is_action_pressed("ui_cancel") \
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

	# Cheat hotkeys (G / P / M / 1-5 / ?) — only when dev tools are enabled.
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

func _refresh_cooldowns() -> void:
	var w: Weapon = local_player.weapon
	var is_ghost: bool = local_player.get("ghost_mode") == true

	# --- Ammo / Rifle ---
	var rifle_text_box := rifle_label.get_parent() as Control
	if is_ghost:
		rifle_label.text = "GHOST"
		rifle_bar.visible = false
		if rifle_text_box: rifle_text_box.visible = true
	elif local_player.reloading:
		rifle_bar.visible = true
		if rifle_text_box: rifle_text_box.visible = false
		rifle_bar.value = 1.0 - (local_player.rifle_cooldown / max(0.01, w.get_reload_time()))
	else:
		rifle_label.text = "%d / %d" % [local_player.mag, w.get_mag_size()]
		rifle_bar.visible = false
		if rifle_text_box: rifle_text_box.visible = true

	# --- Special (RMB) ---
	var special_max: float = local_player.GRENADE_RELOAD
	var grenade_text_box := grenade_label.get_parent() as Control
	if is_ghost:
		special_max = local_player.MINE_RELOAD
		grenade_label.text = "MINE"
	else:
		match w.special:
			Weapon.SPECIAL_TELEPORT: special_max = local_player.TELEPORT_RELOAD
			Weapon.SPECIAL_SHIELD:   special_max = local_player.SHIELD_RELOAD
			Weapon.SPECIAL_INVISIBLE: special_max = local_player.INVISIBLE_RELOAD
			Weapon.SPECIAL_SWORD:    special_max = local_player.MELEE_RELOAD
		special_max *= w.special_cooldown_mult
		grenade_label.text = w.special.to_upper()

	var special_ready: bool = local_player.grenade_cooldown <= 0.0
	grenade_bar.visible = not special_ready
	if grenade_text_box: grenade_text_box.visible = special_ready
	if not special_ready:
		grenade_bar.value = 1.0 - (local_player.grenade_cooldown / max(0.01, special_max))

	# --- Dash (Segmented) ---
	var dash_recharge: float = local_player.dash_recharge_timer / local_player.DASH_RECHARGE_TIME
	var all_full: bool = local_player.dash_charges >= _dash_segments.size()

	if _dash_text_hbox:
		_dash_text_hbox.visible = all_full

	for i in range(_dash_segments.size()):
		var seg: ProgressBar = _dash_segments[i]
		if local_player.dash_charges > i:
			seg.value = 1.0
			seg.visible = not all_full # Hide individual segments if totally full
		elif local_player.dash_charges == i:
			seg.value = dash_recharge
			seg.visible = true
		else:
			seg.value = 0.0
			seg.visible = true

# -------------------- SPAWN / DESPAWN --------------------

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
			_do_spawn.rpc_id(sender, pid, NetworkManager.players[pid],
				players_root.get_node(str(pid)).global_position)
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
) -> void:
	if players_root.has_node(str(id)):
		return
	var p := PLAYER_SCENE.instantiate()
	p.name = str(id)
	p.player_id = id
	p.is_bot = bot
	p.player_name = pname
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
	if _splitscreen and _splitscreen.is_enabled() and split_local:
		# Manager owns the device→player_id map server-side; on clients we
		# just need the view layout refreshed so the new SubViewport appears.
		_splitscreen.update_views()

@rpc("authority", "call_local", "reliable")
func _despawn(id: int) -> void:
	var node := players_root.get_node_or_null(str(id))
	if node:
		node.queue_free()

# -------------------- SINGLE-PLAYER BOT --------------------

func _spawn_bots(count: int) -> void:
	if not multiplayer.is_server() or count <= 0:
		return
	var spawned_any := false
	for i in count:
		var pid: int = BOT_ID_BASE + i
		if pid >= BOT_ID_LIMIT:
			break
		if players_root.has_node(str(pid)):
			continue
		var bot_name: String = BOT_NAME if count == 1 else "%s_%d" % [BOT_NAME, i + 1]
		NetworkManager.players[pid] = bot_name
		round_wins[pid] = 0
		var bot_pick := _pick_spawn(_current_player_positions())
		_do_spawn.rpc(pid, bot_name, bot_pick["pos"], true, -1, false, bot_pick["yaw"])
		spawned_any = true
	if spawned_any:
		NetworkManager.player_list_changed.emit()
		_broadcast_scores.rpc(round_wins)
		_maybe_start_match()

func _despawn_all_bots() -> void:
	var bot_ids := _bot_ids()
	if bot_ids.is_empty():
		return
	for pid in bot_ids:
		_despawn.rpc(pid)
		NetworkManager.players.erase(pid)
		round_wins.erase(pid)
		pending_pick_cards_by_player.erase(pid)
		completed_picks.erase(pid)
		eliminated_players.erase(pid)
	NetworkManager.player_list_changed.emit()
	_broadcast_scores.rpc(round_wins)
	if state == State.PICKING_CARD:
		_hide_card_pick.rpc()
	_hide_rematch_overlay.rpc()
	state = State.WAITING

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
	# Clear any leftover round-end banner ("PICKING A CARD…", "WAITING FOR …",
	# etc.) so it doesn't bleed into the new round.
	_announce.rpc("", 0)

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
			_hide_card_pick.rpc_id(peer)
			if state == State.PLAYING:
				_show_spectating.rpc_id(peer, "SPECTATING…")
			elif state == State.PICKING_CARD:
				_show_spectating.rpc_id(peer, _waiting_for_pickers_spectator_label())
	_maybe_finish_card_picks()

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
	pick_overlay.visible = false
	for c in pick_row.get_children():
		c.queue_free()
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
	var my_id := multiplayer.get_unique_id()
	var is_me := loser_id == my_id
	var loser_name: String = NetworkManager.players.get(loser_id, "Player")
	if not is_me:
		# Winner keeps roaming — no full-screen overlay, just a banner.
		pick_overlay.visible = false
		round_banner.text = "%s IS PICKING A CARD…" % loser_name
		round_banner.visible = true
		banner_timer.stop()
		return
	# Loser: full overlay + cursor + card buttons.
	pick_overlay.visible = true
	_set_gameplay_hud_visible(false)
	_stats_panel.visible = true
	_refresh_stats_panel()
	pick_title.text = "PICK A CARD"

	var is_solo := NetworkManager.players.size() <= 1
	if is_solo:
		pick_subtitle.text = "you lost the round — choose an upgrade"
		_pick_timeout_active = false
	else:
		pick_subtitle.text = "you lost the round — choose an upgrade (8s left)"
		_pick_timeout_timer = 8.0
		_pick_timeout_active = true
		_last_pling_sec = -1

	_sync_mouse_mode()
	_populate_cards(card_ids, true)

	# 1-second grace period before the loser can actually click — avoids
	# accidental picks mid-death animation / mid-mouse-release.
	_set_card_buttons_disabled(true)
	await get_tree().create_timer(1.0).timeout
	if not pick_overlay.visible:
		return
	_set_card_buttons_disabled(false)

func _set_card_buttons_disabled(disabled: bool) -> void:
	for wrapper in pick_row.get_children():
		var btn := _find_button_recursive(wrapper)
		if btn:
			btn.disabled = disabled

func _find_button_recursive(node: Node) -> Button:
	if node is Button:
		return node
	for child in node.get_children():
		var res := _find_button_recursive(child)
		if res:
			return res
	return null

func _populate_cards(card_ids: Array, clickable: bool) -> void:
	for c in pick_row.get_children():
		c.queue_free()

	var index := 0
	for raw_id in card_ids:
		var cid := str(raw_id)
		var card: Dictionary = CardLibrary.by_id(cid)
		if card.is_empty():
			continue

		var card_node := _make_card_button(cid, card, clickable)
		pick_row.add_child(card_node)

		var body = card_node.get_child(0).get_child(0) # root -> idle_node -> card_body
		var content = body.get_child(0) # VBoxContainer with labels

		# Store the intended 'front' style from the override we just set
		var front_style = body.get_theme_stylebox("panel")

		# 1. Initial 'Face Down' State
		body.position.y = 400.0
		body.scale.x = 0.0 # Narrow for flip
		content.visible = false

		# Create a temporary back-side style
		var back_style := StyleBoxFlat.new()
		back_style.bg_color = Color(0.12, 0.12, 0.15, 1.0)
		back_style.border_color = Color(0.3, 0.3, 0.4)
		back_style.set_corner_radius_all(12)
		body.add_theme_stylebox_override("panel", back_style)

		# 2. Entry + Flip Reveal Sequence
		var reveal_delay := index * 0.15
		var tw := body.create_tween()

		# Pop up from below (still face down)
		tw.tween_property(body, "position:y", 0.0, 0.4)\
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT).set_delay(index * 0.04)

		# Flip animation
		tw.tween_interval(reveal_delay)
		tw.tween_property(body, "scale:x", 0.0, 0.1) # Ensure it's narrow
		tw.tween_callback(func():
			content.visible = true
			body.add_theme_stylebox_override("panel", front_style) # Re-apply front style
			SFX.card_flip(0.8 + (index * 0.15))
		)
		tw.tween_property(body, "scale:x", 1.0, 0.15).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

		index += 1

func _make_card_button(card_id: String, card: Dictionary, clickable: bool) -> Control:
	var rarity: String = str(card.get("rarity", "common"))
	var col: Color = card.color

	# 1. Root: The stable footprint in the HBox
	var root := Control.new()
	root.custom_minimum_size = Vector2(220, 300)
	root.size_flags_vertical = Control.SIZE_SHRINK_CENTER

	# 2. Idle: Handles the bobbing animation
	var idle_node := Control.new()
	idle_node.size = Vector2(200, 280)
	idle_node.position = (root.custom_minimum_size - idle_node.size) * 0.5
	root.add_child(idle_node)

	# 3. Card Body: Handles scaling and visuals. Use a simple Panel (not Container)
	# to prevent any child from growing the card's physical footprint.
	var card_body := Panel.new()
	card_body.custom_minimum_size = Vector2(200, 280)
	card_body.size = card_body.custom_minimum_size
	card_body.pivot_offset = card_body.size * 0.5
	idle_node.add_child(card_body)

	# Style the card body
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(12)
	sb.set_border_width_all(3)
	if rarity == "rare":
		sb.bg_color = Color(0.06, 0.07, 0.18, 0.98)
		sb.border_color = Color(0.8, 0.9, 1.0)
		sb.shadow_color = Color(0.4, 0.6, 1.0, 0.4)
		sb.shadow_size = 25
	else:
		sb.bg_color = Color(col.r * 0.15, col.g * 0.15, col.b * 0.15, 0.96)
		sb.border_color = col.lerp(Color.WHITE, 0.2)
		sb.shadow_color = Color(0, 0, 0, 0.3)
		sb.shadow_size = 8
	card_body.add_theme_stylebox_override("panel", sb)

	# 4. Content: Centered VBox inside the card
	var v_content := VBoxContainer.new()
	v_content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 14)
	v_content.add_theme_constant_override("separation", 10)
	card_body.add_child(v_content)

	var title := Label.new()
	title.text = card.name.to_upper()
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color.WHITE if rarity != "rare" else Color(1.0, 0.95, 0.8))
	v_content.add_child(title)

	var desc := Label.new()
	desc.text = card.desc
	desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.add_theme_font_size_override("font_size", 16)
	desc.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
	v_content.add_child(desc)

	# Mathematical Stat Diffs
	var stats_vbox := VBoxContainer.new()
	stats_vbox.add_theme_constant_override("separation", 1)
	v_content.add_child(stats_vbox)

	for diff_line in _get_card_stat_diff(card_id):
		var slbl := Label.new()
		slbl.text = diff_line
		slbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		slbl.add_theme_font_size_override("font_size", 14)
		slbl.add_theme_color_override("font_color", Color(0.75, 0.85, 1.0, 0.85))
		stats_vbox.add_child(slbl)

	# Holographic effects for rare
	if rarity == "rare":
		# Pulsing border color
		var tw_border := card_body.create_tween().set_loops()
		tw_border.tween_property(sb, "border_color", Color(0.6, 0.9, 1.0), 1.8)
		tw_border.tween_property(sb, "border_color", Color(0.9, 0.6, 1.0), 1.8)

		var holo_shader := Shader.new()
		holo_shader.code = "
			shader_type canvas_item;
			render_mode blend_add;
			uniform sampler2D gradient : source_color;
			uniform float speed = 0.5;
			uniform float angle = 0.5;
			uniform float intensity = 0.16;
			uniform vec2 card_size = vec2(200.0, 280.0);
			uniform float corner_radius = 12.0;

			void fragment() {
				vec2 uv = UV;
				float s = sin(angle);
				float c = cos(angle);
				vec2 rot_uv = vec2(
					uv.x * c - uv.y * s,
					uv.x * s + uv.y * c
				);
				float pos = fract(rot_uv.x * 1.5 + TIME * speed);
				vec4 holo_color = texture(gradient, vec2(pos, 0.5));
				float noise = fract(sin(dot(uv, vec2(12.9898, 78.233))) * 43758.5453);
				holo_color.rgb += noise * 0.15;
				// Rounded-corner mask so the shimmer doesn't bleed past the
				// StyleBox's rounded panel underneath. SDF of a rounded rect.
				vec2 px = uv * card_size;
				vec2 d = max(vec2(0.0), abs(px - card_size * 0.5) - (card_size * 0.5 - corner_radius));
				float dist = length(d) - corner_radius;
				float mask = smoothstep(1.0, -1.0, dist);
				// Additive blend on top of the card panel below. ColorRect's
				// base color is ignored — we emit only the shimmer contribution.
				COLOR = vec4(holo_color.rgb * intensity * mask, 1.0);
			}
		"

		var holo_mat := ShaderMaterial.new()
		holo_mat.shader = holo_shader

		# Create a rainbow gradient texture
		var grad := Gradient.new()
		grad.set_offsets(PackedFloat32Array([0.0, 0.25, 0.5, 0.75, 1.0]))
		grad.set_colors(PackedColorArray([
			Color(1.0, 0.3, 0.3), # Red
			Color(1.0, 0.9, 0.3), # Yellow
			Color(0.3, 1.0, 0.3), # Green
			Color(0.3, 0.6, 1.0), # Blue
			Color(1.0, 0.3, 1.0)  # Magenta
		]))

		var grad_tex := GradientTexture1D.new()
		grad_tex.gradient = grad
		holo_mat.set_shader_parameter("gradient", grad_tex)

		var holo_overlay := ColorRect.new()
		holo_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
		holo_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		holo_overlay.material = holo_mat
		card_body.add_child(holo_overlay)
		card_body.move_child(holo_overlay, 0)

	# Clickable overlay
	var btn := Button.new()
	btn.flat = true
	btn.size = card_body.size
	btn.focus_mode = Control.FOCUS_NONE
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	card_body.add_child(btn)

	if clickable:
		btn.pressed.connect(func() -> void: _on_card_button(card_id, root))

		# Idle Float (bobbing & tilting)
		idle_node.pivot_offset = idle_node.size * 0.5

		var idle_y := idle_node.create_tween().set_loops()
		idle_y.tween_property(idle_node, "position:y", 4.0, 2.2).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		idle_y.tween_property(idle_node, "position:y", -4.0, 2.2).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

		var idle_rot := idle_node.create_tween().set_loops()
		var rot_mag := randf_range(1.5, 3.5)
		idle_rot.tween_property(idle_node, "rotation_degrees", rot_mag, 3.1).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		idle_rot.tween_property(idle_node, "rotation_degrees", -rot_mag, 3.1).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

		# Hover logic
		btn.mouse_entered.connect(func() -> void:
			_refresh_stats_panel(card_id) # Show projection
			var tw := card_body.create_tween().set_parallel(true)
			tw.tween_property(card_body, "scale", Vector2(1.12, 1.12), 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
			tw.tween_property(card_body, "position:y", -10.0, 0.2).set_trans(Tween.TRANS_CUBIC)

			if idle_y.is_running(): idle_y.pause()
			if idle_rot.is_running(): idle_rot.pause()

			tw.tween_property(idle_node, "rotation_degrees", 0.0, 0.15).set_trans(Tween.TRANS_CUBIC)

			if rarity == "rare":
				sb.shadow_size = 40
				sb.shadow_color.a = 0.7
		)

		btn.mouse_exited.connect(func() -> void:
			_refresh_stats_panel() # Reset to current
			var tw := card_body.create_tween().set_parallel(true)
			tw.tween_property(card_body, "scale", Vector2.ONE, 0.25).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
			tw.tween_property(card_body, "position:y", 0.0, 0.25).set_trans(Tween.TRANS_CUBIC)
			if rarity == "rare":
				sb.shadow_size = 25
				sb.shadow_color.a = 0.4
			if idle_y: idle_y.play()
			if idle_rot: idle_rot.play()
		)

	return root
func _get_card_stat_diff(card_id: String) -> Array[String]:
	var out: Array[String] = []
	if local_player == null or not is_instance_valid(local_player):
		return out

	var card := CardLibrary.by_id(card_id)
	if card.is_empty():
		return out

	# Clone current weapon to simulate the change
	var base_w: Weapon = local_player.weapon
	var next_w: Weapon = base_w.duplicate()
	card.apply.call(next_w)

	# Percent diffs
	if abs(base_w.damage_mult - next_w.damage_mult) > 0.001:
		var d = (next_w.damage_mult / base_w.damage_mult - 1.0) * 100.0
		out.append("%+d%% Damage" % int(round(d)))

	if abs(base_w.fire_rate_mult - next_w.fire_rate_mult) > 0.001:
		var d = (next_w.fire_rate_mult / base_w.fire_rate_mult - 1.0) * 100.0
		out.append("%+d%% Fire Rate" % int(round(d)))

	if base_w.mag_size_bonus != next_w.mag_size_bonus:
		out.append("%+d Ammo Capacity" % (next_w.mag_size_bonus - base_w.mag_size_bonus))

	if abs(base_w.reload_mult - next_w.reload_mult) > 0.001:
		var d = (next_w.reload_mult / base_w.reload_mult - 1.0) * 100.0
		out.append("%+d%% Reload Speed" % int(round(d)))

	if base_w.extra_projectiles != next_w.extra_projectiles:
		out.append("%+d Projectiles" % (next_w.extra_projectiles - base_w.extra_projectiles))

	if base_w.ricochet_count != next_w.ricochet_count:
		out.append("%+d Bounces" % (next_w.ricochet_count - base_w.ricochet_count))

	if abs(base_w.move_speed_mult - next_w.move_speed_mult) > 0.001:
		var d = (next_w.move_speed_mult / base_w.move_speed_mult - 1.0) * 100.0
		out.append("%+d%% Move Speed" % int(round(d)))

	if next_w.bullet_speed_mult > base_w.bullet_speed_mult * 1.1:
		out.append("Faster Projectiles")
	elif next_w.bullet_speed_mult < base_w.bullet_speed_mult * 0.9:
		out.append("Slower Projectiles")

	if next_w.spread < base_w.spread * 0.5:
		out.append("Huge Accuracy Boost")
	elif next_w.spread < base_w.spread:
		out.append("Accuracy Up")
	elif next_w.spread > base_w.spread:
		out.append("Spread Increased")

	if next_w.explosive_radius > base_w.explosive_radius:
		out.append("Explosive Payload")

	if next_w.lifesteal > base_w.lifesteal:
		out.append("+%.0f%% Lifesteal" % ((next_w.lifesteal - base_w.lifesteal) * 100.0))

	if base_w.max_hp_bonus != next_w.max_hp_bonus:
		out.append("%+d Max HP" % (next_w.max_hp_bonus - base_w.max_hp_bonus))

	if base_w.extra_jumps != next_w.extra_jumps:
		out.append("%+d Extra Jumps" % (next_w.extra_jumps - base_w.extra_jumps))

	if abs(base_w.get_headshot_mult() - next_w.get_headshot_mult()) > 0.01:
		out.append("%.1fx Headshot Mult" % next_w.get_headshot_mult())

	return out

func _on_pick_timeout() -> void:
	_pick_timeout_active = false
	if not pick_overlay.visible:
		return

	# Pick first available card and find its wrapper for animation
	var card_id := ""
	var wrapper: Control = null
	if not pending_pick_cards.is_empty():
		card_id = str(pending_pick_cards[0])
		if pick_row.get_child_count() > 0:
			wrapper = pick_row.get_child(0)

	if card_id != "":
		_on_card_button(card_id, wrapper)

func _on_card_button(card_id: String, picked_wrapper: Control = null) -> void:
	_pick_timeout_active = false
	_set_card_buttons_disabled(true)

	if picked_wrapper:
		# Selection animation
		var picked_body = picked_wrapper.get_child(0).get_child(0) # root -> idle -> body

		# Move other cards away
		for other in pick_row.get_children():
			if other == picked_wrapper: continue
			var other_body = other.get_child(0).get_child(0)
			var tw_other := other_body.create_tween().set_parallel(true)
			tw_other.tween_property(other_body, "scale", Vector2(0.5, 0.5), 0.4).set_trans(Tween.TRANS_CUBIC)
			tw_other.tween_property(other_body, "modulate:a", 0.0, 0.3)

		# Animate picked card
		var tw_pick := picked_body.create_tween().set_parallel(true)
		tw_pick.tween_property(picked_body, "scale", Vector2(1.5, 1.5), 0.5).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		tw_pick.tween_property(picked_body, "position:y", -100.0, 0.5).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		tw_pick.tween_property(picked_body, "rotation_degrees", 0.0, 0.3)

		await get_tree().create_timer(0.6).timeout

	if multiplayer.is_server():
		_server_card_picked(card_id)
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
	if not pending_pick_cards_by_player.has(sender):
		return
	var cards: Array = pending_pick_cards_by_player[sender]
	if not cards.has(card_id):
		return
	_finalize_card_pick(sender, card_id)

@rpc("authority", "call_local", "reliable")
func _hide_card_pick() -> void:
	pick_overlay.visible = false
	if _stats_panel: _stats_panel.visible = false
	for c in pick_row.get_children():
		c.queue_free()
	_set_gameplay_hud_visible(true)
	_sync_mouse_mode()
	# Card picked → no longer "freshly dead". Drop the blood overlay so
	# the spectator/ghost view is clear.
	show_death_effect(false)

func _set_gameplay_hud_visible(visible_: bool) -> void:
	# Hide in-game HUD pieces (HP, ammo bars, crosshair, hit-direction
	# indicator, scoreboard) so the card-pick overlay reads cleanly.
	for path in ["HUD/HealthPanel", "HUD/AbilityBar", "HUD/Hitmarker", "HUD/DamageIndicator", "HUD/Scoreboard"]:
		var n := get_node_or_null(path)
		if n:
			n.visible = visible_
	if _custom_crosshair:
		_custom_crosshair.visible = visible_

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
	_extend_button.focus_mode = Control.FOCUS_NONE
	_extend_button.pressed.connect(_on_extend_pressed)
	vb.add_child(_extend_button)

	_exit_to_menu_button = Button.new()
	_exit_to_menu_button.text = "EXIT GAME"
	_exit_to_menu_button.custom_minimum_size = Vector2(260, 46)
	_exit_to_menu_button.focus_mode = Control.FOCUS_NONE
	_exit_to_menu_button.pressed.connect(_quit_game)
	vb.add_child(_exit_to_menu_button)

func _show_rematch_overlay(_winner_id: int) -> void:
	if _rematch_overlay == null:
		_build_rematch_overlay()
	_rematch_requested = false
	_extend_button.disabled = false
	_extend_button.text = "5 MORE ROUNDS"
	_rematch_overlay.visible = true

func _build_ghost_overlay() -> void:
	_ghost_overlay = Control.new()
	_ghost_overlay.name = "GhostOverlay"
	_ghost_overlay.anchor_right = 1.0
	_ghost_overlay.anchor_bottom = 1.0
	_ghost_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ghost_overlay.visible = false
	$HUD.add_child(_ghost_overlay)

	var veil := ColorRect.new()
	veil.anchor_right = 1.0
	veil.anchor_bottom = 1.0
	veil.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var spirit_shader := Shader.new()
	spirit_shader.code = "
		shader_type canvas_item;
		uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_nearest;
		void fragment() {
			vec4 color = texture(screen_texture, SCREEN_UV);
			float gray = dot(color.rgb, vec3(0.299, 0.587, 0.114));
			vec3 b_w = vec3(gray);
			vec3 tint = vec3(0.5, 0.8, 1.0);
			COLOR.rgb = mix(b_w, tint * (gray + 0.1), 0.35);
			COLOR.a = 1.0;
		}
	"
	var mat := ShaderMaterial.new()
	mat.shader = spirit_shader
	veil.material = mat
	_ghost_overlay.add_child(veil)

	_ghost_label = Label.new()
	_ghost_label.text = "GHOST MODE"
	_ghost_label.anchor_left = 0.5
	_ghost_label.anchor_right = 0.5
	_ghost_label.anchor_top = 1.0
	_ghost_label.anchor_bottom = 1.0
	_ghost_label.offset_left = -70
	_ghost_label.offset_right = 70
	_ghost_label.offset_top = -34
	_ghost_label.offset_bottom = -12
	_ghost_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_ghost_label.add_theme_font_size_override("font_size", 14)
	_ghost_label.add_theme_color_override("font_color", Color(0.78, 0.95, 1.0, 0.72))
	_ghost_overlay.add_child(_ghost_label)

	# Move to the background of the HUD so it doesn't affect other UI elements
	$HUD.move_child(_ghost_overlay, 0)

var _retro_layer: CanvasLayer = null
var _retro_material: ShaderMaterial = null

# -------------------- VIDEO SETTINGS --------------------
const SETTINGS_PATH := "user://settings.cfg"
const MUSIC_DB_MIN := -40.0  # below this is treated as muted
const MUSIC_DB_MAX := 0.0
const MUSIC_DB_DEFAULT := -16.0
var _retro_enabled: bool = true
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
	if _retro_layer:
		_retro_layer.visible = _retro_enabled
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
			int p_size = max(1, int(round(res.y / 720.0)));
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
	# Polygon cursor in HUD is no longer used — the retro shader now renders
	# the cursor itself (in-shader) so it gets the fisheye distortion applied
	# correctly. This keeps the polygon hidden so it doesn't double-up.
	if _custom_cursor != null:
		_custom_cursor.visible = false
	# Drive the retro shader's cursor uniforms — visible whenever the mouse
	# is uncaptured (menus / panels), positioned at the live mouse coords.
	if _retro_material == null:
		return
	var show: bool = Input.mouse_mode != Input.MOUSE_MODE_CAPTURED
	_retro_material.set_shader_parameter("cursor_visible", 1.0 if show else 0.0)
	if show:
		var vp := get_viewport()
		var size: Vector2 = vp.get_visible_rect().size
		if size.x > 0.0 and size.y > 0.0:
			var mp := vp.get_mouse_position()
			_retro_material.set_shader_parameter("mouse_uv", Vector2(mp.x / size.x, mp.y / size.y))

func _build_retro_filter() -> void:
	var cl := CanvasLayer.new()
	cl.name = "RetroFilterLayer"
	cl.layer = 100 # Put it above everything else
	add_child(cl)
	_retro_layer = cl

	var retro_overlay := ColorRect.new()
	retro_overlay.name = "RetroFilter"
	retro_overlay.anchor_right = 1.0
	retro_overlay.anchor_bottom = 1.0
	retro_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_apply_retro_shader(retro_overlay)
	cl.add_child(retro_overlay)

func _update_ghost_overlay() -> void:
	if _ghost_overlay == null:
		return
	var is_ghost: bool = local_player != null and is_instance_valid(local_player) and local_player.get("ghost_mode") == true
	var picking: bool = pick_overlay != null and pick_overlay.visible
	_ghost_overlay.visible = is_ghost and not picking

func _build_stats_panel() -> void:
	_stats_panel = PanelContainer.new()
	_stats_panel.custom_minimum_size = Vector2(600, 0)
	_stats_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stats_panel.visible = false

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.05, 0.08, 0.98) # Dark solid background
	sb.set_border_width_all(2)
	sb.border_color = Color(0.4, 0.8, 1.0, 0.6)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 24
	sb.content_margin_right = 24
	sb.content_margin_top = 14
	sb.content_margin_bottom = 14
	_stats_panel.add_theme_stylebox_override("panel", sb)

	_stats_content = GridContainer.new()
	_stats_content.columns = 6 # label, old, arrow, new, spacer, ...
	_stats_content.add_theme_constant_override("h_separation", 10)
	_stats_content.add_theme_constant_override("v_separation", 6)
	_stats_panel.add_child(_stats_content)

	# Add to the HUD at a fixed bottom position
	_stats_panel.anchor_left = 0.5
	_stats_panel.anchor_right = 0.5
	_stats_panel.anchor_top = 1.0
	_stats_panel.anchor_bottom = 1.0
	_stats_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_stats_panel.offset_left = -300.0
	_stats_panel.offset_right = 300.0
	_stats_panel.offset_bottom = -20.0
	# Remove fixed offset_top to allow dynamic height

	pick_overlay.add_child(_stats_panel)
func _refresh_stats_panel(projected_card_id: String = "") -> void:
	if local_player == null or not is_instance_valid(local_player):
		return

	if projected_card_id == "" or pick_overlay == null or not pick_overlay.visible:
		_animate_stats_panel(false)
		return

	var card := CardLibrary.by_id(projected_card_id)
	if card.is_empty():
		_animate_stats_panel(false)
		return

	# Clear and rebuild content before showing
	for c in _stats_content.get_children():
		c.queue_free()

	var base_w: Weapon = local_player.weapon
	var next_w := base_w.duplicate()
	card.apply.call(next_w)

	_add_stat_comparison("DAMAGE", base_w.get_damage(), next_w.get_damage(), true)
	_add_stat_comparison("FIRE RATE", 1.0/base_w.get_fire_interval(), 1.0/next_w.get_fire_interval(), true)
	_add_stat_comparison("AMMO", base_w.get_mag_size(), next_w.get_mag_size(), true)
	_add_stat_comparison("RELOAD", base_w.get_reload_time(), next_w.get_reload_time(), false)
	_add_stat_comparison("ACCURACY", rad_to_deg(base_w.spread), rad_to_deg(next_w.spread), false)
	_add_stat_comparison("MOVEMENT", base_w.move_speed_mult, next_w.move_speed_mult, true)
	_add_stat_comparison("BOUNCES", base_w.ricochet_count, next_w.ricochet_count, true)
	_add_stat_comparison("MAX HP", 100.0 + base_w.max_hp_bonus, 100.0 + next_w.max_hp_bonus, true)
	_add_stat_comparison("JUMPS", 2.0 + base_w.extra_jumps, 2.0 + next_w.extra_jumps, true)
	_add_stat_comparison("PROJ SPD", base_w.bullet_speed_mult, next_w.bullet_speed_mult, true)
	_add_stat_comparison("EXPLOSION", base_w.explosive_radius, next_w.explosive_radius, true)
	_add_stat_comparison("KNOCKBACK", base_w.knockback, next_w.knockback, true)

	# Special Cooldown (calculated based on equipped special)
	var base_cd: float = _get_base_special_cd(base_w.special) * base_w.special_cooldown_mult
	var next_cd: float = _get_base_special_cd(next_w.special) * next_w.special_cooldown_mult
	_add_stat_comparison("SPECIAL CD", base_cd, next_cd, false)

	if base_w.special != next_w.special:
		_add_text_comparison("SPECIAL", base_w.special.to_upper(), next_w.special.to_upper(), Color(0.4, 0.8, 1.0))

	_animate_stats_panel(true)

var _stats_tween: Tween = null
func _animate_stats_panel(show: bool) -> void:
	if _stats_panel == null: return

	if _stats_tween and _stats_tween.is_valid():
		_stats_tween.kill()

	if show:
		_stats_panel.visible = true
		_stats_tween = create_tween().set_parallel(true)
		_stats_tween.tween_property(_stats_panel, "modulate:a", 1.0, 0.25).set_trans(Tween.TRANS_CUBIC)
		_stats_tween.tween_property(_stats_panel, "offset_top", -120.0, 0.3).from(-80.0).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	else:
		_stats_tween = create_tween().set_parallel(true)
		_stats_tween.tween_property(_stats_panel, "modulate:a", 0.0, 0.2).set_trans(Tween.TRANS_CUBIC)
		_stats_tween.tween_property(_stats_panel, "offset_top", -80.0, 0.2).set_trans(Tween.TRANS_CUBIC)
		_stats_tween.chain().tween_callback(func(): _stats_panel.visible = false)

func _get_base_special_cd(special_id: String) -> float:
	match special_id:
		Weapon.SPECIAL_TELEPORT: return 2.0
		Weapon.SPECIAL_SHIELD:   return 8.0
		Weapon.SPECIAL_INVISIBLE: return 10.0
		_: return 3.0 # Grenade baseline

func _add_text_comparison(label_text: String, old_val: String, next_val: String, tint: Color) -> void:
	# 1. Stat Label
	var l := Label.new()
	l.text = label_text
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", Color(0.6, 0.6, 0.7))
	_stats_content.add_child(l)

	# 2. Old Value
	var v_old := Label.new()
	v_old.text = old_val
	v_old.add_theme_font_size_override("font_size", 13)
	v_old.add_theme_color_override("font_color", Color.WHITE)
	_stats_content.add_child(v_old)

	# 3. Arrow
	var arr := Label.new()
	arr.text = ">>"
	arr.add_theme_font_size_override("font_size", 11)
	arr.add_theme_color_override("font_color", Color(0.4, 0.4, 0.5))
	_stats_content.add_child(arr)

	# 4. New Value
	var v_new := Label.new()
	v_new.text = next_val
	v_new.add_theme_color_override("font_color", tint)
	v_new.add_theme_font_size_override("font_size", 14)
	_stats_content.add_child(v_new)

	# Spacers
	_stats_content.add_child(Control.new())
	_stats_content.add_child(Control.new())

func _add_stat_comparison(label_text: String, base_val: float, next_val: float, higher_is_better: bool) -> void:
	var diff := next_val - base_val
	if abs(diff) < 0.001:
		return

	# 1. Stat Label (Grey)
	var l := Label.new()
	l.text = label_text
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", Color(0.6, 0.6, 0.7))
	_stats_content.add_child(l)

	# 2. Old Value (White)
	var v_old := Label.new()
	v_old.text = "%.1f" % base_val
	v_old.add_theme_font_size_override("font_size", 13)
	v_old.add_theme_color_override("font_color", Color.WHITE)
	_stats_content.add_child(v_old)

	# 3. Arrow (Neutral)
	var arr := Label.new()
	arr.text = ">>"
	arr.add_theme_font_size_override("font_size", 11)
	arr.add_theme_color_override("font_color", Color(0.4, 0.4, 0.5))
	_stats_content.add_child(arr)

	# 4. New Value (Red/Green)
	var v_new := Label.new()
	v_new.text = "%.1f" % next_val
	var is_better := (diff > 0.001 and higher_is_better) or (diff < -0.001 and not higher_is_better)
	v_new.add_theme_color_override("font_color", Color(0.4, 1.0, 0.4) if is_better else Color(1.0, 0.4, 0.4))
	v_new.add_theme_font_size_override("font_size", 14)
	_stats_content.add_child(v_new)

	# Spacers for GridContainer columns (6 columns total)
	_stats_content.add_child(Control.new())
	_stats_content.add_child(Control.new())

func _build_death_overlay() -> void:
	_death_overlay = ColorRect.new()
	_death_overlay.name = "DeathOverlay"
	_death_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_death_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_death_overlay.color = Color(0.8, 0, 0, 0) # Start transparent red
	$HUD.add_child(_death_overlay)
	# Place it above the ghost shader (index 0) but still at the back of the HUD
	$HUD.move_child(_death_overlay, 1)

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

func show_death_effect(show: bool) -> void:
	if _death_overlay == null: return

	if _death_overlay.has_meta("tween"):
		var old_tw: Tween = _death_overlay.get_meta("tween")
		if old_tw and old_tw.is_valid():
			old_tw.kill()

	var tw := _death_overlay.create_tween()
	_death_overlay.set_meta("tween", tw)

	if show:
		# Rapidly surge to 100% solid red and HOLD it
		_death_overlay.color.a = 0.6
		tw.tween_property(_death_overlay, "color", Color(0.65, 0.0, 0.0, 1.0), 0.4).set_trans(Tween.TRANS_SINE)
	else:
		# Fade out only when told to (at respawn)
		tw.tween_property(_death_overlay, "color:a", 0.0, 0.5).set_trans(Tween.TRANS_CUBIC)

func _on_extend_pressed() -> void:
	_extend_button.text = "VOTED TO EXTEND"
	_extend_button.disabled = true
	if multiplayer.is_server():
		_server_extend_vote(multiplayer.get_unique_id())
	else:
		_server_extend_vote.rpc_id(1, multiplayer.get_unique_id())

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
	show_death_effect(false) # Clear blood if match continues

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

func show_hitmarker(kind: String, dmg: int = 0, world_pos: Vector3 = Vector3.INF) -> void:
	hitmarker.flash(kind)
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
	if pick_overlay and pick_overlay.visible:
		return true
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

func _is_cursor_modal_open() -> bool:
	if pick_overlay and pick_overlay.visible:
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

func _sync_mouse_mode() -> void:
	var modal_open := _is_cursor_modal_open()
	var desired := Input.MOUSE_MODE_CAPTURED
	if modal_open:
		desired = Input.MOUSE_MODE_HIDDEN if _retro_enabled else Input.MOUSE_MODE_VISIBLE
	if Input.mouse_mode != desired:
		Input.mouse_mode = desired

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
		_sync_mouse_mode()
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
	join_input.text_submitted.connect(func(_t: String) -> void: _pause_join())
	join_row.add_child(join_input)
	var join_btn := Button.new()
	join_btn.text = "JOIN"
	join_btn.custom_minimum_size = Vector2(80, 36)
	join_btn.pressed.connect(_pause_join)
	join_row.add_child(join_btn)
	_pause_join_input = join_input

	# Spacer before action buttons.
	var spacer2 := Control.new()
	spacer2.custom_minimum_size = Vector2(0, 8)
	vb.add_child(spacer2)

	var restart_btn := Button.new()
	restart_btn.text = "RESTART MATCH"
	restart_btn.custom_minimum_size = Vector2(0, 44)
	restart_btn.pressed.connect(_pause_restart_match)
	vb.add_child(restart_btn)

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


func _music_label_for(db: float) -> String:
	if db <= MUSIC_DB_MIN + 0.5:
		return "Off"
	return "%.0f dB" % db


func _close_settings() -> void:
	if _settings_panel:
		_settings_panel.visible = false
	if _pause_menu:
		_pause_menu.visible = true


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


func _pause_join() -> void:
	if _pause_join_input == null:
		return
	var game_id := _pause_join_input.text.strip_edges()
	if game_id.is_empty():
		return
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
		push_error("Failed to start iroh client")
		return
	get_tree().change_scene_to_file("res://scenes/game.tscn")


func _pause_restart_match() -> void:
	# Close the pause menu first so the round-start banner is visible.
	if _pause_menu and _pause_menu.visible:
		_toggle_pause_menu()
	if multiplayer.is_server():
		_restart_match()


func _quit_game() -> void:
	get_tree().paused = false
	get_tree().quit()

func show_damage_direction(from_pos: Vector3) -> void:
	if not local_player or not is_instance_valid(local_player):
		return
	var delta: Vector3 = from_pos - local_player.global_position
	delta.y = 0.0
	if delta.length_squared() < 0.0001:
		return
	# Rotate the horizontal world vector into the player's local frame using
	# only their yaw (camera pitch doesn't affect damage direction).
	var yaw: float = local_player.rotation.y
	var c := cos(yaw)
	var s := sin(yaw)
	var local_x := c * delta.x - s * delta.z
	var local_z := s * delta.x + c * delta.z
	# Forward in local space is -Z. Angle convention: 0 forward, +π/2 right.
	var angle := atan2(local_x, -local_z)
	damage_indicator.flash(angle)

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
