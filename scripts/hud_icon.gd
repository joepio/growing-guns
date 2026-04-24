extends Control

enum Type { SHIFT, LMB, RMB }
@export var icon_type: Type = Type.LMB
@export var icon_color: Color = Color.WHITE

func _draw() -> void:
	match icon_type:
		Type.SHIFT:
			_draw_shift_icon()
		Type.LMB:
			_draw_mouse_icon(true)
		Type.RMB:
			_draw_mouse_icon(false)

func _draw_shift_icon() -> void:
	var pad := 4.0
	var r := Rect2(Vector2.ZERO, size)
	# Draw the keycap box
	draw_rect(r, icon_color, false, 1.5)

	# Draw the text manually or use a child label?
	# For simplicity and style consistency, let's just use the draw_string
	# (Note: Requires a font, but we can just use a tiny child Label in the setup)
	pass

func _draw_mouse_icon(left_filled: bool) -> void:
	var w := size.x
	var h := size.y
	var center := size * 0.5

	# Mouse body outline
	var points := PackedVector2Array()
	var sides := 16
	for i in range(sides + 1):
		var ang := PI + (float(i) / sides) * PI
		points.append(center + Vector2(cos(ang) * w * 0.4, sin(ang) * h * 0.4))
	for i in range(sides + 1):
		var ang := (float(i) / sides) * PI
		points.append(center + Vector2(cos(ang) * w * 0.4, sin(ang) * h * 0.3 + h * 0.2))

	draw_polyline(points, icon_color, 1.5, true)

	# Split line
	draw_line(center + Vector2(0, -h * 0.4), center, icon_color, 1.5)

	# Filled button
	if left_filled:
		var left_poly := PackedVector2Array()
		for i in range(int(sides/2) + 1):
			var ang := PI + (float(i) / sides) * PI
			left_poly.append(center + Vector2(cos(ang) * w * 0.4, sin(ang) * h * 0.4))
		left_poly.append(center)
		draw_colored_polygon(left_poly, icon_color)
	else:
		var right_poly := PackedVector2Array()
		for i in range(int(sides/2), sides + 1):
			var ang := PI + (float(i) / sides) * PI
			right_poly.append(center + Vector2(cos(ang) * w * 0.4, sin(ang) * h * 0.4))
		right_poly.append(center)
		draw_colored_polygon(right_poly, icon_color)
