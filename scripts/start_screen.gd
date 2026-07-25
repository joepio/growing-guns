extends Node3D

const MenuHelpers = preload("res://scripts/menu_helpers.gd")
const RetroFilter = preload("res://scripts/retro_filter.gd")
const GothicMenuUi = preload("res://scripts/gothic_menu_ui.gd")
const GAME_SCENE := "res://scenes/game.tscn"
const GAME_MODE_VERSUS := "versus"
const GAME_MODE_COOP := "coop"
const PLAYER_SCENE := preload("res://scenes/player.tscn")
const GRENADE_SCRIPT := preload("res://scripts/grenade.gd")
const MENU_ARENA_SEED := 424242
const MENU_ARENA_SIZE := 72.0
const MENU_CAPTURE_ORBIT := 0.72

@onready var _camera: Camera3D = $Camera3D
@onready var _arena: Node3D = $Arena
@onready var _versus_button: Button = $UI/MenuPanel/VBox/VersusButton
@onready var _wave_button: Button = $UI/MenuPanel/VBox/WaveButton
@onready var _notice: Label = $UI/MenuPanel/VBox/Notice
@onready var _vbox: VBoxContainer = $UI/MenuPanel/VBox

var _orbit_t := 0.0
var _orbit_origin := Vector3.ZERO
var _capture_path := ""
var _capture_mode := false

# Multiplayer and settings UI elements
var _players_root: Node3D
var _share_field: LineEdit
var _host_online_button: Button
var _copy_button: Button
var _join_input: LineEdit
var _join_button: Button
var _settings_button: Button
var _settings_panel: Control
var _retro_layer: CanvasLayer = null
var _retro_material: ShaderMaterial = null

# Settings state is unified and handled via MenuHelpers static variables

var state: int = 1  # State.PLAYING == 1 (required so bots can shoot in the background)


func _ready() -> void:
	if GameNight.launched_by_daemon:
		# The daemon drives everything from here: GameNightBridge listens for
		# GameNight.prepared and swaps to game.tscn once a session arrives.
		# Skip building the menu entirely — nothing here should render.
		return
	_capture_path = _cli_capture_path()
	_capture_mode = not _capture_path.is_empty()
	if _capture_mode:
		DisplayServer.window_set_size(Vector2i(1280, 720))
		get_viewport().size = Vector2i(1280, 720)
	# Load settings first using the unified settings system
	MenuHelpers.load_settings()
	if MenuHelpers.player_name.is_empty():
		MenuHelpers.player_name = "Player_%d" % (randi() % 1000)
		MenuHelpers.save_settings()
	NetworkManager.local_player_name = MenuHelpers.player_name
	
	# Register settings callbacks
	MenuHelpers.settings_changed_callback = _apply_settings
	MenuHelpers.player_name_committed_callback = _on_player_name_committed
	
	# Cinematic lava-island fort for the menu backdrop (matches reference art).
	if _arena and _arena.has_method("apply_cinematic_seed"):
		_arena.call("apply_cinematic_seed", MENU_ARENA_SEED, MENU_ARENA_SIZE)
	elif _arena and _arena.has_method("apply_seed"):
		_arena.call("apply_seed", MENU_ARENA_SEED, MENU_ARENA_SIZE, MENU_ARENA_SIZE)
	if _arena:
		_orbit_origin = _arena.global_position
	
	# Container for background fight bots
	_players_root = Node3D.new()
	_players_root.name = "Players"
	add_child(_players_root)
	
	# Spawn background fighting bots (skip for PNG capture runs).
	if not _capture_mode:
		_spawn_background_bots()
	
	_versus_button.pressed.connect(_start_versus)
	_wave_button.pressed.connect(_start_wave_survival)
	
	# Build the start screen multiplayer / settings UI
	_build_start_screen_multiplayer_ui()
	GothicMenuUi.apply_start_screen($UI)
	_build_retro_filter()
	_apply_settings()
	
	NetworkManager.ensure_solo_registered(MenuHelpers.player_name)

	if not NetworkManager.network_status_changed.is_connected(_on_network_status_changed):
		NetworkManager.network_status_changed.connect(_on_network_status_changed)
	if not NetworkManager.iroh_host_ready.is_connected(_refresh_online_host_ui):
		NetworkManager.iroh_host_ready.connect(func(_id: String) -> void: _refresh_online_host_ui())
	_refresh_online_host_ui()
	_show_network_notice()
	if not _capture_mode:
		_versus_button.grab_focus()
	_orbit_t = MENU_CAPTURE_ORBIT if _capture_mode else 0.0
	_position_camera(_orbit_t)
	if _capture_mode:
		call_deferred("_capture_and_quit", _capture_path)
	else:
		call_deferred("_warmup_menu_assets")


func _warmup_menu_assets() -> void:
	SFX.warmup_specials()
	if _arena and is_instance_valid(_arena):
		await get_tree().process_frame
		ShaderWarmup.warmup_effect_shaders(_arena)


func _process(delta: float) -> void:
	if _capture_mode:
		return
	_orbit_t += delta * 0.055
	_position_camera(_orbit_t)
	_update_custom_cursor()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		if _settings_panel and _settings_panel.visible:
			_close_settings_menu()
			get_viewport().set_input_as_handled()
		else:
			get_tree().quit()
	if event is InputEventKey and event.pressed and not event.echo:
		if _settings_panel == null or not _settings_panel.visible:
			match event.keycode:
				KEY_1:
					_start_versus()
				KEY_2:
					_start_wave_survival()


func _position_camera(t: float) -> void:
	if _camera == null:
		return
	var radius := 82.0
	var height := 34.0
	var pos := _orbit_origin + Vector3(cos(t) * radius, height, sin(t) * radius)
	_camera.global_position = pos
	_camera.look_at(_orbit_origin + Vector3(0.0, 5.5, 0.0), Vector3.UP)


func _cli_capture_path() -> String:
	var args := OS.get_cmdline_user_args()
	for i: int in args.size():
		if args[i] == "--capture" and i + 1 < args.size():
			return String(args[i + 1])
	return ""


func _capture_and_quit(path: String) -> void:
	for _i: int in 10:
		await get_tree().process_frame
	RenderingServer.force_draw(true)
	await get_tree().process_frame
	var tex := get_viewport().get_texture()
	if tex == null:
		push_error("StartScreen: viewport texture is null")
		get_tree().quit(1)
		return
	var img: Image = tex.get_image()
	if img == null or img.is_empty():
		push_error("StartScreen: captured image is empty")
		get_tree().quit(1)
		return
	if not path.is_absolute_path():
		path = ProjectSettings.globalize_path("res://").path_join(path)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var err := img.save_png(path)
	if err != OK:
		push_error("StartScreen capture failed (%d): %s" % [err, path])
		get_tree().quit(1)
		return
	print("StartScreen captured: ", path, " (", img.get_width(), "x", img.get_height(), ")")
	get_tree().quit()


func _start_versus() -> void:
	_start_game(GAME_MODE_VERSUS)


func _start_wave_survival() -> void:
	_start_game(GAME_MODE_COOP)


func _start_game(mode: String) -> void:
	# Never let an in-flight iroh bring-up race game.tscn shader warmup.
	NetworkManager.cancel_background_host()
	Violence.discard_pending_blast_visuals()
	# Keep an already-live host; otherwise play offline until the player opts in.
	if NetworkManager.current_iroh_game_id.is_empty():
		NetworkManager.leave_game()
	NetworkManager.set_meta("game_mode", mode)
	if NetworkManager.has_meta("coop_mode"):
		NetworkManager.remove_meta("coop_mode")
	get_tree().change_scene_to_file(GAME_SCENE)


func _show_network_notice() -> void:
	_notice.visible = false
	if not NetworkManager.has_meta("network_notice"):
		return
	var notice := str(NetworkManager.get_meta("network_notice"))
	NetworkManager.remove_meta("network_notice")
	if notice.is_empty():
		return
	_notice.text = notice
	_notice.visible = true


# ── Background Bots spawning ──
func _spawn_background_bots() -> void:
	var spawnpoints := get_tree().get_nodes_in_group("spawnpoints")
	if spawnpoints.is_empty():
		return
		
	spawnpoints.shuffle()
	var count := mini(4, spawnpoints.size())
	
	for i in count:
		var sp := spawnpoints[i] as Node3D
		var p := PLAYER_SCENE.instantiate()
		p.player_id = 200 + i  # Unique ID base for start screen background bots
		p.name = str(p.player_id)
		p.is_bot = true
		p.player_name = "AI_%d" % i
		p.set_multiplayer_authority(1)
		_players_root.add_child(p)
		
		p.global_position = sp.global_position
		p.rotation.y = randf() * TAU
		
		var spawn_pos: Vector3 = sp.global_position
		p.died.connect(func(_killer_id): _on_bot_died(p, spawn_pos))
		
		# Equip bot with 4 random cards
		var cards := CardLibrary.all()
		for j in 4:
			if not cards.is_empty():
				var card_id: String = cards.pick_random()["id"]
				p.apply_card(card_id)


func _on_bot_died(bot: Node3D, spawn_pos: Vector3) -> void:
	if not is_instance_valid(bot):
		return
	# Wait 3.0s and respawn them
	get_tree().create_timer(3.0).timeout.connect(func():
		if is_instance_valid(bot):
			bot.call("clear_ragdoll")
			bot.call("_set_dead_visuals", false)
			bot.call("server_respawn", spawn_pos, randf() * TAU)
	)


# ── UI Construction ──
func _build_start_screen_multiplayer_ui() -> void:
	# Keep the panel's fixed frame size (set in the scene) — don't zero the height,
	# or the gothic frame collapses and the menu floats to the top of the screen.
	var menu_panel = $UI/MenuPanel
	menu_panel.custom_minimum_size = Vector2(350, 392)
	
	var exit_note = $UI/MenuPanel/VBox/ExitNote
	var notice = $UI/MenuPanel/VBox/Notice
	
	# Add spacer
	var spacer_mid := Control.new()
	spacer_mid.custom_minimum_size = Vector2(0, 4)
	_vbox.add_child(spacer_mid)
	
	# Settings button
	_settings_button = Button.new()
	_settings_button.text = "SETTINGS"
	_settings_button.custom_minimum_size = Vector2(0, 32)
	_vbox.add_child(_settings_button)
	_settings_button.pressed.connect(_open_settings_menu)
	
	var sep := HSeparator.new()
	_vbox.add_child(sep)
	
	# Share Match ID
	var share_lbl := Label.new()
	share_lbl.text = "Share your Match ID:"
	share_lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.85))
	_vbox.add_child(share_lbl)
	
	var share_row := HBoxContainer.new()
	share_row.add_theme_constant_override("separation", 8)
	_vbox.add_child(share_row)
	
	_share_field = LineEdit.new()
	_share_field.editable = false
	_share_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_share_field.custom_minimum_size = Vector2(0, 32)
	_share_field.placeholder_text = "Offline — click Host online"
	share_row.add_child(_share_field)

	_host_online_button = Button.new()
	_host_online_button.text = "HOST ONLINE"
	_host_online_button.custom_minimum_size = Vector2(110, 32)
	_host_online_button.pressed.connect(_on_host_online_pressed)
	share_row.add_child(_host_online_button)
	
	_copy_button = Button.new()
	_copy_button.text = "COPY"
	_copy_button.custom_minimum_size = Vector2(70, 32)
	share_row.add_child(_copy_button)
	_copy_button.pressed.connect(_on_copy_pressed)
	
	# Join Friend
	var join_lbl := Label.new()
	join_lbl.text = "Or join a friend's match:"
	join_lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.85))
	_vbox.add_child(join_lbl)
	
	var join_row := HBoxContainer.new()
	join_row.add_theme_constant_override("separation", 8)
	_vbox.add_child(join_row)
	
	_join_input = LineEdit.new()
	_join_input.placeholder_text = "Paste friend's Game ID..."
	_join_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_join_input.custom_minimum_size = Vector2(0, 32)
	_join_input.text_changed.connect(_on_join_input_changed)
	_join_input.text_submitted.connect(func(_t): _on_join_pressed())
	join_row.add_child(_join_input)
	
	_join_button = Button.new()
	_join_button.text = "JOIN"
	_join_button.custom_minimum_size = Vector2(70, 32)
	_join_button.disabled = true
	join_row.add_child(_join_button)
	_join_button.pressed.connect(_on_join_pressed)
	
	# Reorder labels to make notice / quit help be at bottom
	_vbox.move_child(exit_note, _vbox.get_child_count() - 1)
	if notice:
		_vbox.move_child(notice, _vbox.get_child_count() - 1)
		
	# Force the menu panel to resize to its new minimum size including the dynamic controls
	menu_panel.size = Vector2.ZERO
	GothicMenuUi.apply_start_screen($UI)
	_refresh_online_host_ui()


func _on_host_online_pressed() -> void:
	NetworkManager.request_online_host(MenuHelpers.player_name)
	_refresh_online_host_ui()


func _refresh_online_host_ui() -> void:
	var id := NetworkManager.current_iroh_game_id
	var starting := NetworkManager.is_host_starting()
	if _share_field:
		_share_field.text = id
		if id.is_empty() and starting:
			_share_field.placeholder_text = "Starting host..."
		elif id.is_empty():
			_share_field.placeholder_text = "Offline — click Host online"
	if _host_online_button:
		_host_online_button.visible = id.is_empty()
		_host_online_button.disabled = starting
		_host_online_button.text = "STARTING..." if starting else "HOST ONLINE"
	if _copy_button:
		_copy_button.disabled = id.is_empty()


func _on_copy_pressed() -> void:
	if _share_field and not _share_field.text.is_empty():
		DisplayServer.clipboard_set(_share_field.text)
		_copy_button.text = "COPIED!"
		get_tree().create_timer(1.5).timeout.connect(func():
			if _copy_button:
				_copy_button.text = "COPY"
		)


func _on_join_pressed() -> void:
	if _join_input == null or _join_input.text.strip_edges().is_empty():
		return
	var game_id := _join_input.text.strip_edges()
	
	_join_button.disabled = true
	_join_button.text = "JOINING..."
	
	if NetworkManager.multiplayer.multiplayer_peer != null:
		NetworkManager.leave_game()
		
	if not NetworkManager.join_game_iroh(game_id, MenuHelpers.player_name):
		_join_button.disabled = false
		_join_button.text = "JOIN"
		_show_status("Could not initiate join connection.", true)
		return
		
	get_tree().change_scene_to_file(GAME_SCENE)


func _on_join_input_changed(text: String) -> void:
	var extracted := MenuHelpers.extract_iroh_node_id(text)
	if _join_input:
		var old_caret := _join_input.caret_column
		_join_input.set_text(extracted)
		_join_input.caret_column = mini(old_caret, extracted.length())
		
	var is_valid := MenuHelpers.is_valid_iroh_node_id(extracted)
	var is_own := MenuHelpers.is_own_iroh_game_id(extracted)
	_join_button.disabled = not is_valid or is_own


func _on_network_status_changed(message: String, is_error: bool) -> void:
	_show_status(message, is_error)
	_refresh_online_host_ui()


func _show_status(message: String, is_error: bool) -> void:
	if _notice:
		_notice.text = message
		_notice.visible = not message.is_empty()
		if is_error:
			_notice.add_theme_color_override("font_color", Color(1.0, 0.45, 0.35))
		else:
			_notice.add_theme_color_override("font_color", Color(0.45, 1.0, 0.65))


# ── Settings menu implementation ──
func _open_settings_menu() -> void:
	if _settings_panel:
		_settings_panel.queue_free()
	_settings_panel = MenuHelpers.build_settings_panel($UI, _close_settings_menu, true)
	for child in _settings_panel.get_children():
		if child is PanelContainer:
			GothicMenuUi.apply_settings_panel(child as PanelContainer)
			break
	$UI/MenuPanel.visible = false
	$UI/Title.visible = false
	_settings_panel.visible = true
	MenuHelpers.grab_first_menu_focus(_settings_panel)


func _close_settings_menu() -> void:
	if _settings_panel:
		_settings_panel.queue_free()
		_settings_panel = null
	$UI/MenuPanel.visible = true
	$UI/Title.visible = true
	MenuHelpers.grab_first_menu_focus($UI/MenuPanel)


func _apply_settings() -> void:
	RetroFilter.apply(_retro_layer, _retro_material, MenuHelpers.retro_enabled)
	Input.mouse_mode = Input.MOUSE_MODE_HIDDEN if MenuHelpers.retro_enabled else Input.MOUSE_MODE_VISIBLE
	var muted: bool = MenuHelpers.music_db <= MenuHelpers.MUSIC_DB_MIN + 0.5
	ProceduralMusic.enabled = not muted
	ProceduralMusic.music_db = MenuHelpers.music_db
	if not muted:
		ProceduralMusic.set_energy(1, true)
	else:
		ProceduralMusic.set_energy(0, true)


func _on_player_name_committed(new_name: String) -> void:
	NetworkManager.leave_game()
	NetworkManager.ensure_solo_registered(new_name)
	_refresh_online_host_ui()


func _build_retro_filter() -> void:
	var built := RetroFilter.build(self)
	_retro_layer = built["layer"] as CanvasLayer
	_retro_material = built["material"] as ShaderMaterial


func _update_custom_cursor() -> void:
	if _retro_material == null or not MenuHelpers.retro_enabled:
		if _retro_material:
			_retro_material.set_shader_parameter("cursor_visible", 0.0)
		return
	_retro_material.set_shader_parameter("cursor_visible", 1.0)
	var vp := get_viewport()
	var size: Vector2 = vp.get_visible_rect().size
	if size.x > 0.0 and size.y > 0.0:
		var mp := vp.get_mouse_position()
		_retro_material.set_shader_parameter("mouse_uv", Vector2(mp.x / size.x, mp.y / size.y))
