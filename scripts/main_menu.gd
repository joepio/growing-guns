extends Control

@onready var name_input: LineEdit = $Panel/VBox/NameSection/NameInput
@onready var addr_input: LineEdit = $Panel/VBox/JoinSection/HBoxJoin/AddrInput
@onready var bot_button: Button = $Panel/VBox/MainActions/BotButton
@onready var host_button: Button = $Panel/VBox/MainActions/HostButton
@onready var join_button: Button = $Panel/VBox/JoinSection/HBoxJoin/JoinButton
@onready var game_list_vbox: VBoxContainer = $Panel/VBox/ScrollContainer/GameList
@onready var status_label: Label = $Panel/VBox/Status

func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	bot_button.pressed.connect(_on_vs_bot)
	host_button.pressed.connect(_on_host)
	join_button.pressed.connect(_on_join)

	name_input.text = "Player_%d" % (randi() % 1000)

	# Start listening for local games immediately
	NetworkManager.game_discovered.connect(_on_games_discovered)
	NetworkManager.start_discovery()

func _exit_tree() -> void:
	# Stop discovery if we leave the main menu (though typically we only go to game)
	NetworkManager.stop_discovery()

func _on_vs_bot() -> void:
	status_label.text = "Starting solo match..."
	if NetworkManager.host_game(name_input.text):
		NetworkManager.set_meta("spawn_bot_on_start", true)
		_go_to_game()

func _on_host() -> void:
	status_label.text = "Hosting..."
	NetworkManager.set_meta("spawn_bot_on_start", false)
	if NetworkManager.host_game(name_input.text):
		_go_to_game()
	else:
		status_label.text = "Failed to host (port in use?)"

func _on_join() -> void:
	var addr := addr_input.text.strip_edges()
	if addr.is_empty():
		addr = "127.0.0.1"
	_do_join(addr)

func _do_join(addr: String) -> void:
	status_label.text = "Connecting to %s..." % addr
	if NetworkManager.join_game(addr, name_input.text):
		_go_to_game()
	else:
		status_label.text = "Failed to connect"

func _on_games_discovered(games: Dictionary) -> void:
	# Clear list
	for child in game_list_vbox.get_children():
		child.queue_free()

	if games.is_empty():
		var lbl := Label.new()
		lbl.text = "   (searching...)"
		lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		lbl.add_theme_font_size_override("font_size", 12)
		game_list_vbox.add_child(lbl)
		return

	for addr in games:
		var game: Dictionary = games[addr]
		var btn := Button.new()
		btn.text = " JOIN: %s (%d/%d) @ %s" % [game.name, game.players, game.max, addr]
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.custom_minimum_size = Vector2(0, 36)
		btn.add_theme_font_size_override("font_size", 12)
		btn.add_theme_color_override("font_hover_color", Color(0.6, 0.9, 1.0))

		# Reuse the established button styles
		btn.add_theme_stylebox_override("normal", load("res://scenes/main.tscn::Style_Button"))
		btn.add_theme_stylebox_override("hover", load("res://scenes/main.tscn::Style_Button_Hover"))
		btn.add_theme_stylebox_override("pressed", load("res://scenes/main.tscn::Style_Button"))

		btn.pressed.connect(_do_join.bind(addr))
		game_list_vbox.add_child(btn)

func _go_to_game() -> void:
	get_tree().change_scene_to_file("res://scenes/game.tscn")
