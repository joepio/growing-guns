extends Control

var spread: float = 0.0
var color: Color = Color(1.2, 1.0, 0.4, 0.9) # HDR-ish yellow, higher opacity
var line_width: float = 1.5
var line_length: float = 8.0
var base_gap: float = 4.0

func _process(_delta: float) -> void:
	queue_redraw()

func _draw() -> void:
	var center := size * 0.5
	# Convert spread (radians) to pixel offset.
	# Assuming ~75 deg FOV, 1000 pixels across.
	# A rough but effective approximation for feel:
	var spread_offset := spread * 400.0
	var gap := base_gap + spread_offset

	# Top
	draw_line(center + Vector2(0, -gap), center + Vector2(0, -gap - line_length), color, line_width)
	# Bottom
	draw_line(center + Vector2(0, gap), center + Vector2(0, gap + line_length), color, line_width)
	# Left
	draw_line(center + Vector2(-gap, 0), center + Vector2(-gap - line_length, 0), color, line_width)
	# Right
	draw_line(center + Vector2(gap, 0), center + Vector2(gap + line_length, 0), color, line_width)
