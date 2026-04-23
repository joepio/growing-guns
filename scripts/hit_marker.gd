extends Control

# Four diagonal line segments drawn around the crosshair. Calling flash(kind)
# triggers a scale-out + fade animation. Re-triggering while active restarts
# the animation — a hit followed quickly by a kill reads as two distinct pops.

const INNER := 5.0
const OUTER := 13.0
const WIDTH := 2.4

var _alpha: float = 0.0
var _spread: float = 1.0
var _color: Color = Color.WHITE

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _process(_delta: float) -> void:
	queue_redraw()

func _draw() -> void:
	if _alpha <= 0.001:
		return
	var center := size * 0.5
	var col := Color(_color.r, _color.g, _color.b, _alpha)
	var outline := Color(0.0, 0.0, 0.0, min(1.0, _alpha * 1.1))
	var dirs := [
		Vector2( 0.7071,  0.7071),
		Vector2(-0.7071,  0.7071),
		Vector2(-0.7071, -0.7071),
		Vector2( 0.7071, -0.7071),
	]
	var inner := INNER * _spread
	var outer := OUTER * _spread
	for d in dirs:
		draw_line(center + d * inner, center + d * outer, outline, WIDTH + 1.6, true)
	for d in dirs:
		draw_line(center + d * inner, center + d * outer, col, WIDTH, true)

func flash(kind: String = "body") -> void:
	match kind:
		"head": _color = Color(1.0, 0.9, 0.25)
		"kill": _color = Color(1.0, 0.25, 0.22)
		_:      _color = Color(1.0, 1.0, 1.0)
	_alpha = 1.0
	_spread = 0.7
	var tw := create_tween().set_parallel(true)
	tw.tween_property(self, "_alpha", 0.0, 0.16) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tw.tween_property(self, "_spread", 1.35, 0.13) \
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
