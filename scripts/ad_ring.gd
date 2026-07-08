class_name AdRing
extends Node3D

# Perimeter advertisement boards — the LED ribbon every real arena has,
# ringing the barrier below the first row of seats. Every board shows the
# SAME campaign; on rotation the next ad slides in and pushes the old one
# out (the classic LED push), synchronized around the whole ring.
#
# The content lives in ONE tiny 2D SubViewport (text + colored backdrop —
# clipping is free in 2D, which Label3D can't do), and every board is a quad
# textured with that shared ViewportTexture. The viewport renders only
# during the half-second push, then sleeps (UPDATE_ONCE). Built by
# ColosseumBuilder.build().

# Shared with the jumbotron ad breaks (stadium_tv.gd). Text + display color;
# palette rule: no red — that belongs to blood and gun-flesh.
const ADS: Array = [
	["ACME COLA — THIRST IS ETERNAL", Color(0.15, 0.65, 0.95)],
	["MAG-NIFICENT™ — BIGGER IS LEGAL", Color(0.95, 0.72, 0.10)],
	["SOUL-DOGS: PROBABLY MEAT", Color(0.55, 0.90, 0.12)],
	["OUCH!™ — PROUD SPONSOR OF EXPLOSIONS", Color(0.90, 0.15, 0.75)],
	["STYX PREMIUM FERRY LOUNGE — SKIP THE QUEUE", Color(0.05, 0.75, 0.72)],
	["REPRINTS-R-US — DIE HAPPY, COME BACK", Color(0.55, 0.25, 0.95)],
	["BARREL BROS. — WHY NOT TWO?", Color(0.95, 0.72, 0.10)],
	["MORE ROUNDS! MORE ROUNDS! MORE ROUNDS!", Color(0.92, 0.92, 0.92)],
	["THE HOUSE PROVIDES", Color(0.05, 0.75, 0.72)],
	["TONIGHT: EVERYONE vs EVERYONE", Color(0.90, 0.15, 0.75)],
]
const BOARD_COUNT := 14
const SWAP_SECONDS := 6.0
const BOARD_H := 2.3
const PUSH_SECONDS := 0.45
const VP_SIZE := Vector2i(1024, 152)  # ~board aspect; 2 wrapped lines max

var _vp: SubViewport = null
var _cards: Control = null
var _card_a: Array = []  # [ColorRect, Label] — the visible card
var _card_b: Array = []  # the card waiting below, slides up during the push
var _index: int = 0
var _timer: float = SWAP_SECONDS
var _push: float = -1.0  # <0 idle, else 0..1 through the slide

# Boards ring the bowl in front of the facade, inward of the facade columns'
# radius band and clear of the arena wall crenellations. inner_r/base_y are
# the same values ColosseumBuilder works with; sq is its squircle callable.
func setup(inner_r: float, base_y: float, sq: Callable) -> void:
	_build_feed()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_texture = _vp.get_texture()
	var back_mat := StandardMaterial3D.new()
	back_mat.albedo_color = Color(0.07, 0.07, 0.09)
	back_mat.roughness = 0.9
	for i in BOARD_COUNT:
		var ang := TAU * (float(i) + 0.5) / float(BOARD_COUNT)
		var s: float = sq.call(ang)
		var dir := Vector3(cos(ang), 0.0, sin(ang))
		var r := (inner_r - 3.6) * s
		var board := MeshInstance3D.new()
		board.name = "AdBoard%d" % i
		var quad := QuadMesh.new()
		quad.size = Vector2(r * TAU / float(BOARD_COUNT) * 0.62, BOARD_H)
		board.mesh = quad
		board.material_override = mat
		board.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		board.position = dir * r + Vector3(0.0, base_y - 0.7, 0.0)
		board.basis = Basis.looking_at(dir, Vector3.UP)  # +Z faces the arena
		add_child(board)
		# Slim dark backing slab so the ribbon has depth from the side.
		var back := MeshInstance3D.new()
		var bb := BoxMesh.new()
		bb.size = Vector3(quad.size.x + 0.25, BOARD_H + 0.25, 0.22)
		back.mesh = bb
		back.material_override = back_mat
		back.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		board.add_child(back)
		back.position = Vector3(0.0, 0.0, -0.13)
	_set_card(_card_a, ADS[0])

func _build_feed() -> void:
	_vp = SubViewport.new()
	_vp.size = VP_SIZE
	_vp.disable_3d = true
	_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(_vp)
	_cards = Control.new()
	_vp.add_child(_cards)
	_card_a = _make_card(0.0)
	_card_b = _make_card(float(VP_SIZE.y))

func _make_card(y: float) -> Array:
	var bg := ColorRect.new()
	bg.position = Vector2(0.0, y)
	bg.size = Vector2(VP_SIZE)
	_cards.add_child(bg)
	var lbl := Label.new()
	lbl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
	lbl.add_theme_font_size_override("font_size", 60)
	lbl.add_theme_color_override("font_color", Color.WHITE)
	lbl.add_theme_color_override("font_outline_color", Color(0.05, 0.05, 0.08))
	lbl.add_theme_constant_override("outline_size", 20)
	bg.add_child(lbl)
	return [bg, lbl]

func _set_card(card: Array, ad: Array) -> void:
	(card[0] as ColorRect).color = (ad[1] as Color) * 0.8
	(card[1] as Label).text = str(ad[0])

func _process(delta: float) -> void:
	if _push >= 0.0:
		_push += delta / PUSH_SECONDS
		var t := clampf(_push, 0.0, 1.0)
		# Ease-out: the new ad arrives fast and settles, LED-board style.
		_cards.position.y = -float(VP_SIZE.y) * (1.0 - pow(1.0 - t, 3.0))
		if _push >= 1.0:
			# Card A takes over the new campaign; container snaps home on an
			# identical frame, then the viewport goes back to sleep.
			_push = -1.0
			_set_card(_card_a, ADS[_index % ADS.size()])
			_cards.position.y = 0.0
			_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
		return
	_timer -= delta
	if _timer <= 0.0:
		_timer = SWAP_SECONDS
		_index += 1
		_set_card(_card_b, ADS[_index % ADS.size()])
		_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		_push = 0.0
