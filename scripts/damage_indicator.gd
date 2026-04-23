extends Control

# Shows a red arc near the screen edge in the direction a hit came from.
# flash(angle) appends a fading indicator; multiple simultaneous hits stack.
# `angle` is relative to the viewer's facing: 0 = forward, +π/2 = right,
# π = behind, −π/2 = left (clockwise-positive, like compass bearing).

const DURATION := 0.28
const ARC_HALF_WIDTH := 0.38         # radians (~44° total arc)
const THICKNESS := 26.0
const RADIUS_FRAC := 0.42            # fraction of min(width, height)
const MAX_ALPHA := 0.65

var _flashes: Array[Dictionary] = []

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _process(delta: float) -> void:
	if _flashes.is_empty():
		return
	var alive: Array[Dictionary] = []
	for f in _flashes:
		f["life"] = f["life"] - delta
		if f["life"] > 0.0:
			alive.append(f)
	_flashes = alive
	queue_redraw()

func _draw() -> void:
	if _flashes.is_empty():
		return
	var center := size * 0.5
	var radius := minf(size.x, size.y) * RADIUS_FRAC
	for f in _flashes:
		var t: float = clampf(f["life"] / DURATION, 0.0, 1.0)
		# Ease-in fade — stays punchy at the start, drops off at the end.
		var alpha := t * t * MAX_ALPHA
		# Our angle convention is 0 = up; Godot's draw_arc is 0 = +X (right).
		var g_angle: float = float(f["angle"]) - PI * 0.5
		var col := Color(1.0, 0.12, 0.14, alpha)
		draw_arc(center, radius,
			g_angle - ARC_HALF_WIDTH, g_angle + ARC_HALF_WIDTH,
			24, col, THICKNESS, true)

func flash(angle: float) -> void:
	_flashes.append({"angle": angle, "life": DURATION})
