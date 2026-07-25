@tool
extends EditorPlugin

const AUTOLOAD_NAME := "GameNight"

func _enter_tree() -> void:
	add_autoload_singleton(AUTOLOAD_NAME, "res://addons/gamenight/gamenight.gd")

func _exit_tree() -> void:
	remove_autoload_singleton(AUTOLOAD_NAME)
