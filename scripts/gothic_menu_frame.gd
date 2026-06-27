class_name GothicMenuFrame
extends Control

const GothicMenuUi = preload("res://scripts/gothic_menu_ui.gd")

# Procedural stone-and-iron menu frame: mortar grid, gold trim, crown spikes, skull crest.

@export var frame_seed: int = 424242


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = false
	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()


func _draw() -> void:
	GothicMenuUi.draw_frame(self, get_rect(), frame_seed)
