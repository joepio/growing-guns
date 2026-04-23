extends Control

@onready var name_input: LineEdit = $Panel/VBox/NameInput
@onready var addr_input: LineEdit = $Panel/VBox/AddrInput
@onready var bot_button: Button = $Panel/VBox/BotButton
@onready var host_button: Button = $Panel/VBox/HostButton
@onready var join_button: Button = $Panel/VBox/JoinButton
@onready var status_label: Label = $Panel/VBox/Status

func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if bot_button: bot_button.pressed.connect(_on_vs_bot)
	if host_button: host_button.pressed.connect(_on_host)
	if join_button: join_button.pressed.connect(_on_join)
	name_input.text = "Player_%d" % (randi() % 1000)

func _on_vs_bot() -> void:
	status_label.text = "Starting solo match..."
	if NetworkManager.host_game(name_input.text):
		# We want a bot immediately. We can tell the game controller via a singleton or property.
		# For now, let's just use a static flag on NetworkManager if we can, or just wait for game start.
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
	status_label.text = "Connecting to %s..." % addr
	if NetworkManager.join_game(addr, name_input.text):
		_go_to_game()
	else:
		status_label.text = "Failed to connect"

func _go_to_game() -> void:
	get_tree().change_scene_to_file("res://scenes/game.tscn")
