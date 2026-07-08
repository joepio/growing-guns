class_name AdRing
extends Node3D

# Perimeter advertisement boards — the LED ribbon every real arena has,
# ringing the barrier below the first row of seats. Dark boards with bright
# in-lore sponsor slogans (docs/lore.md) that rotate every few seconds.
# Built by ColosseumBuilder.build(). Cost: one box + one Label3D per board.

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

var _labels: Array[Label3D] = []
var _board_mats: Array[StandardMaterial3D] = []
var _offset: int = 0
var _timer: float = SWAP_SECONDS

# Boards ring the bowl in front of the facade — pulled INWARD of the facade
# columns' radius band (they clipped straight through them) and kept low so
# they read as barrier boards. inner_r/base_y are the same values
# ColosseumBuilder works with; sq is its squircle callable.
func setup(inner_r: float, base_y: float, sq: Callable) -> void:
	for i in BOARD_COUNT:
		var ang := TAU * (float(i) + 0.5) / float(BOARD_COUNT)
		var s: float = sq.call(ang)
		var dir := Vector3(cos(ang), 0.0, sin(ang))
		var r := (inner_r - 3.6) * s
		var board := MeshInstance3D.new()
		board.name = "AdBoard%d" % i
		var bm := BoxMesh.new()
		bm.size = Vector3(r * TAU / float(BOARD_COUNT) * 0.62, BOARD_H, 0.3)
		board.mesh = bm
		# Per-board material: bright sponsor-colored backdrop (unshaded, so
		# it stays vivid in canopy shade and blackout rounds).
		var bg := StandardMaterial3D.new()
		bg.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		bg.albedo_color = Color(0.1, 0.1, 0.1)
		board.material_override = bg
		_board_mats.append(bg)
		board.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		board.position = dir * r + Vector3(0.0, base_y - 0.7, 0.0)
		board.basis = Basis.looking_at(dir, Vector3.UP)  # +Z faces the arena
		add_child(board)
		var lbl := Label3D.new()
		lbl.pixel_size = 0.011
		lbl.font_size = 96
		lbl.outline_size = 30  # chunky poster lettering
		lbl.modulate = Color.WHITE
		lbl.outline_modulate = Color(0.05, 0.05, 0.08)
		lbl.width = bm.size.x / lbl.pixel_size * 0.94
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
		lbl.position = Vector3(0.0, 0.0, 0.22)
		board.add_child(lbl)
		_labels.append(lbl)
	_apply_texts()

func _process(delta: float) -> void:
	_timer -= delta
	if _timer <= 0.0:
		_timer = SWAP_SECONDS
		_offset += 1
		_apply_texts()

func _apply_texts() -> void:
	for i in _labels.size():
		var ad: Array = ADS[(i + _offset) % ADS.size()]
		_labels[i].text = str(ad[0])
		# White bold-outlined text on the sponsor color, slightly deepened so
		# the lettering pops.
		_board_mats[i].albedo_color = (ad[1] as Color) * 0.8
