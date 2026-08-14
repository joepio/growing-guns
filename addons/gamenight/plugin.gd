@tool
extends EditorPlugin

const AUTOLOAD_NAME := "GameNight"
## The window manners (screen.gd). A separate autoload rather than part of
## GameNight itself so a game can switch it off — `GameNightScreen.automatic =
## false` — without losing the socket.
const SCREEN_AUTOLOAD_NAME := "GameNightScreen"

func _enter_tree() -> void:
	add_autoload_singleton(AUTOLOAD_NAME, "res://addons/gamenight/gamenight.gd")
	add_autoload_singleton(SCREEN_AUTOLOAD_NAME, "res://addons/gamenight/screen.gd")

func _exit_tree() -> void:
	remove_autoload_singleton(SCREEN_AUTOLOAD_NAME)
	remove_autoload_singleton(AUTOLOAD_NAME)
