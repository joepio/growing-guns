extends Control

@onready var name_input: LineEdit = $Panel/VBox/NameInput
@onready var addr_input: LineEdit = $Panel/VBox/AddrInput
@onready var host_button: Button = $Panel/VBox/HBox/HostButton
@onready var join_button: Button = $Panel/VBox/HBox/JoinButton
@onready var status_label: Label = $Panel/VBox/Status

func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	host_button.pressed.connect(_on_host)
	join_button.pressed.connect(_on_join)
	name_input.text = "Player_%d" % (randi() % 1000)

func _on_host() -> void:
	status_label.text = "Hosting..."
	if NetworkManager.host_game(name_input.text):
		_go_to_game()
	else:
		status_label.text = "Failed to host (port in use?)"

func _on_join() -> void:
	status_label.text = "Connecting to %s..." % addr_input.text
	if NetworkManager.join_game(addr_input.text, name_input.text):
		_go_to_game()
	else:
		status_label.text = "Failed to connect"

func _go_to_game() -> void:
	get_tree().change_scene_to_file("res://scenes/game.tscn")
