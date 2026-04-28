@tool
class_name ArenaGenerator
extends Node3D

# Procedural closed-arena map generator — the only map type in MAP_POOL.
#
# Layout: 80m x 80m floor, walled in 12m tall, optional center tower, mirrored
# pairs of tall buildings (with side ledges + accent strips), pillars, cover
# blocks, and floating platforms. Every placed feature has a 180° rotational
# mirror at (-x, -z) so the map is symmetric and plays fair from any spawn.
#
# Tuned for the player's movement kit:
#   WALK 14 m/s, JUMP 9 (~1.35m), DOUBLE_JUMP +~1.2m total ~2.5m,
#   WALL_JUMP_V 10.5 (chained wall-jumps reach 6m+), DASH 28×0.18s = +5m h.
# Buildings 8-12m tall, ledges at ~60% height: a player can wall-jump from
# ground to ledge, then ledge to roof.

signal regenerated(stats: Dictionary)

@export var seed: int = 0:
	set(v): seed = v; if auto_regenerate: _queue_regen()
@export var auto_regenerate: bool = true
# If true, regenerate() runs once when the scene first enters the tree. Turn
# off when the host wants to drive regeneration explicitly (e.g. game.gd
# calling apply_seed after instantiating a procedural arena).
@export var regenerate_on_ready: bool = true
# Visible disc under each spawn point — useful in the preview, distracting
# in actual gameplay. The in-game procedural arena turns this off.
@export var show_spawn_markers: bool = false

@export_group("Bounds")
# Per-seed size variation: regenerate() picks a value in [min, max] using
# the seed. To force a specific size, set both fields equal (the preview's
# --size= CLI arg does this).
@export_range(40.0, 120.0, 1.0) var arena_size_min: float = 50.0:
	set(v): arena_size_min = v; if auto_regenerate: _queue_regen()
@export_range(40.0, 120.0, 1.0) var arena_size_max: float = 95.0:
	set(v): arena_size_max = v; if auto_regenerate: _queue_regen()
@export_range(8.0, 18.0, 0.5) var wall_height: float = 12.0:
	set(v): wall_height = v; if auto_regenerate: _queue_regen()

# Effective arena size for the current generation. Computed from the seeded
# RNG at the start of regenerate(); reported in stats.
var arena_size: float = 80.0

@export_group("Counts (each pair places one + 180° mirror)")
@export_range(0, 4) var num_building_pairs: int = 2:
	set(v): num_building_pairs = v; if auto_regenerate: _queue_regen()
@export_range(0, 6) var num_pillar_pairs: int = 1:
	set(v): num_pillar_pairs = v; if auto_regenerate: _queue_regen()
@export_range(0, 12) var num_cover_pairs: int = 6:
	set(v): num_cover_pairs = v; if auto_regenerate: _queue_regen()
@export_range(0, 4) var num_floating_pairs: int = 1:
	set(v): num_floating_pairs = v; if auto_regenerate: _queue_regen()
@export_range(0, 4) var num_diagonal_walls: int = 1:
	set(v): num_diagonal_walls = v; if auto_regenerate: _queue_regen()
@export_range(0.0, 1.0, 0.05) var center_tower_chance: float = 0.6:
	set(v): center_tower_chance = v; if auto_regenerate: _queue_regen()
@export_range(0.0, 1.0, 0.05) var tunnel_chance: float = 0.4:
	set(v): tunnel_chance = v; if auto_regenerate: _queue_regen()
@export_range(0.0, 1.0, 0.05) var bridge_chance: float = 0.6:
	set(v): bridge_chance = v; if auto_regenerate: _queue_regen()
@export_range(0.0, 1.0, 0.05) var building_rotation_chance: float = 0.55:
	set(v): building_rotation_chance = v; if auto_regenerate: _queue_regen()

@export_group("")
@export var regenerate_now: bool = false:
	set(_v): regenerate()

# Per-seed palette pool. Each entry covers both geometry materials and the
# atmosphere (sky / fog / sun / fill) which the preview applies at runtime so
# the whole scene retunes when the seed changes.
const PALETTES: Array = [
	{
		"name": "red_noir",
		"floor": Color(0.06, 0.05, 0.09),
		"wall": Color(0.18, 0.16, 0.24),
		"building": Color(0.42, 0.38, 0.55),
		"dark": Color(0.24, 0.22, 0.32),
		"accent_a": Color(1.00, 0.20, 0.18),
		"accent_b": Color(1.00, 0.85, 0.10),
		"sky_top": Color(0.04, 0.02, 0.10),
		"sky_horizon": Color(0.55, 0.10, 0.25),
		"ambient": Color(0.35, 0.35, 0.55),
		"fog": Color(0.22, 0.06, 0.18),
		"fog_density": 0.012,
		"sun": Color(1.00, 0.75, 0.65),
		"fill": Color(1.00, 0.35, 0.20),
	},
	{
		"name": "cyan_factory",
		"floor": Color(0.03, 0.05, 0.07),
		"wall": Color(0.10, 0.20, 0.24),
		"building": Color(0.22, 0.42, 0.46),
		"dark": Color(0.10, 0.28, 0.32),
		"accent_a": Color(0.10, 1.00, 0.85),
		"accent_b": Color(0.85, 1.00, 0.20),
		"sky_top": Color(0.005, 0.040, 0.050),
		"sky_horizon": Color(0.04, 0.45, 0.42),
		"ambient": Color(0.30, 0.55, 0.55),
		"fog": Color(0.04, 0.22, 0.20),
		"fog_density": 0.012,
		"sun": Color(0.80, 1.00, 0.95),
		"fill": Color(0.10, 0.85, 0.85),
	},
	{
		"name": "synthwave",
		"floor": Color(0.04, 0.02, 0.08),
		"wall": Color(0.16, 0.08, 0.30),
		"building": Color(0.38, 0.20, 0.58),
		"dark": Color(0.22, 0.12, 0.34),
		"accent_a": Color(1.00, 0.18, 0.85),
		"accent_b": Color(0.20, 0.95, 1.00),
		"sky_top": Color(0.05, 0.02, 0.18),
		"sky_horizon": Color(0.45, 0.10, 0.55),
		"ambient": Color(0.45, 0.30, 0.65),
		"fog": Color(0.30, 0.10, 0.40),
		"fog_density": 0.012,
		"sun": Color(1.00, 0.65, 0.90),
		"fill": Color(0.85, 0.30, 1.00),
	},
	{
		"name": "desert_dusk",
		"floor": Color(0.08, 0.06, 0.04),
		"wall": Color(0.22, 0.16, 0.10),
		"building": Color(0.78, 0.55, 0.32),
		"dark": Color(0.36, 0.26, 0.16),
		"accent_a": Color(1.00, 0.45, 0.08),
		"accent_b": Color(0.15, 0.85, 1.00),
		"sky_top": Color(0.18, 0.06, 0.10),
		"sky_horizon": Color(0.98, 0.42, 0.12),
		# Cool-leaning ambient so warm geometry doesn't melt into the sky.
		"ambient": Color(0.40, 0.42, 0.55),
		"fog": Color(0.45, 0.22, 0.14),
		# Lower density so the bright desert sky doesn't flood the arena.
		"fog_density": 0.0035,
		"sun": Color(1.00, 0.80, 0.55),
		"fill": Color(1.00, 0.45, 0.18),
	},
]
const COLOR_SPAWN := Color(1.00, 0.40, 0.18)

const LAVA_SHADER_CODE := """
shader_type spatial;
render_mode unshaded, cull_disabled;

varying vec3 v_world_pos;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
		mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x),
		f.y
	);
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 5; i++) {
		v += a * vnoise(p);
		p *= 2.05;
		a *= 0.5;
	}
	return v;
}

void vertex() {
	// Hand the world position to fragment so noise can be sampled in world
	// space — features stay the same physical size regardless of how big
	// the plane is.
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// 1 noise unit ≈ 25m on the ground, no matter how big the plane.
	vec2 uv = v_world_pos.xz * 0.04;
	float t = TIME * 0.18;
	float n1 = fbm(uv + vec2(t, t * 0.55));
	float n2 = fbm(uv * 1.7 + vec2(-t * 0.7, t * 0.85));
	float heat = (n1 + n2) * 0.5;

	vec3 crust = vec3(0.32, 0.04, 0.02);
	vec3 hot = vec3(1.55, 0.45, 0.08);
	vec3 white_hot = vec3(2.80, 1.45, 0.30);

	vec3 col = mix(crust, hot, smoothstep(0.30, 0.68, heat));
	col = mix(col, white_hot, smoothstep(0.78, 0.95, heat));

	ALBEDO = col * 0.5;
	EMISSION = col * 1.8;
}
"""

var _mat_floor: StandardMaterial3D
var _mat_wall: StandardMaterial3D
var _mat_building: StandardMaterial3D
var _mat_dark: StandardMaterial3D
var _mat_accent_red: StandardMaterial3D
var _mat_accent_yellow: StandardMaterial3D
var _mat_spawn: StandardMaterial3D

# Each entry: [Vector2 center_xz, float radius]. Used for collision-free
# placement (kept flat instead of full AABB — bounding circles are good
# enough for this scale and avoid axis-aligned rotation headaches).
var _placed: Array = []
var _spawn_positions: Array[Vector3] = []

var last_stats: Dictionary = {}
var _regen_pending: bool = false


func _ready() -> void:
	if not Engine.is_editor_hint() and regenerate_on_ready:
		regenerate()


func _queue_regen() -> void:
	if _regen_pending:
		return
	_regen_pending = true
	call_deferred("_do_queued_regen")


func _do_queued_regen() -> void:
	_regen_pending = false
	regenerate()


func regenerate() -> void:
	for c in get_children():
		c.queue_free()
	_placed.clear()
	_spawn_positions.clear()
	_ensure_materials()

	var t0: int = Time.get_ticks_usec()
	var rng := RandomNumberGenerator.new()
	rng.seed = seed

	# Per-seed size pull (rounded so the HUD reads cleanly). Drawn first so it
	# sits at a stable position in the rng stream — geometry placement after
	# this point is reproducible for a given (seed, size_range) combo.
	var lo: float = minf(arena_size_min, arena_size_max)
	var hi: float = maxf(arena_size_min, arena_size_max)
	arena_size = roundf(rng.randf_range(lo, hi))

	# One roll picks the structural variant. 30% open arena (no perimeter
	# walls — players can run off into the lava), 20% walled with a hole in
	# the floor, 50% normal walled-and-solid. Mutually exclusive.
	var variant_roll: float = rng.randf()
	var no_walls: bool = variant_roll < 0.30
	var has_hole: bool = (not no_walls) and variant_roll < 0.50
	var hole_pos: Vector2 = Vector2.ZERO
	var hole_size: float = 0.0
	if has_hole:
		hole_size = rng.randf_range(10.0, 16.0)
		var max_off: float = arena_size * 0.25
		hole_pos = Vector2(rng.randf_range(-max_off, max_off), rng.randf_range(-max_off, max_off))

	_build_floor(has_hole, hole_pos, hole_size)
	if not no_walls:
		_build_walls()
	_build_lava_pool()
	# Reserve the hole as an unplaceable circle so buildings / pillars / etc.
	# don't land in it. Spawnpoints are corners + rooftops, both safe.
	if has_hole:
		_placed.append([hole_pos, hole_size * 0.5 + 1.5])

	# Reserve the perimeter band so nothing tries to clip into a wall.
	var perim_radius: float = arena_size * 0.5 - 1.5
	# Reserve a no-go circle around the absolute center if no tower; otherwise
	# the tower itself takes the slot.
	var has_center: bool = rng.randf() < center_tower_chance
	var tower_h: float = 0.0
	if has_center:
		tower_h = rng.randf_range(10.0, 14.0)
		_build_center_tower(tower_h)
		_placed.append([Vector2.ZERO, 4.5])
		_spawn_positions.append(Vector3(0, tower_h + 1.0, 0))
	else:
		# Empty center — keep a small reserved disc so cover doesn't all clump there.
		_placed.append([Vector2.ZERO, 2.0])

	# Buildings (with ledges + lights). The bigger the footprint, the further
	# from center — keeps the inside fightable.
	var buildings_built: int = 0
	# Primary-half building info, used later for bridges. Each entry:
	# {pos: Vector3, size: Vector3, rotation: float, roof_y: float}
	var primary_buildings: Array = []
	for i in num_building_pairs:
		for attempt in 40:
			var w: float = rng.randf_range(7.0, 11.0)
			var d: float = rng.randf_range(7.0, 11.0)
			var h: float = rng.randf_range(8.0, 12.0)
			var max_dim: float = maxf(w, d)
			var inset: float = max_dim * 0.5 + 2.0
			var x: float = rng.randf_range(-perim_radius + inset, -max_dim * 0.5 - 4.0)
			var z: float = rng.randf_range(-perim_radius + inset, perim_radius - inset)
			var pos := Vector3(x, h * 0.5, z)
			# Diagonal rotation for variety (some seeds keep buildings axis-aligned).
			var rot: float = 0.0
			if rng.randf() < building_rotation_chance:
				rot = rng.randf() * PI * 0.5  # 0..90° covers all unique orientations
			# Bounding circle radius accounts for any rotation since the circle is rotation-invariant.
			var radius: float = sqrt(w * w + d * d) * 0.5 + 1.5
			if not _try_place(pos, radius):
				continue
			# Pre-pick the random visual params so the mirror copy renders the
			# same accent face / colors / light tint as the primary.
			var accent_face: int = rng.randi() % 4
			var strip_color: StandardMaterial3D = _mat_accent_red if rng.randf() < 0.5 else _mat_accent_yellow
			var light_color: Color = Color(1, 0.35, 0.2, 1) if rng.randf() < 0.5 else Color(1, 0.7, 0.2, 1)
			_build_building(pos, Vector3(w, h, d), rot, accent_face, strip_color, light_color)
			_build_building(_mirror(pos), Vector3(w, h, d), rot + PI, accent_face, strip_color, light_color)
			# Rooftop spawn (1m above so the player stands on it).
			_spawn_positions.append(Vector3(pos.x, h + 1.0, pos.z))
			_spawn_positions.append(_mirror(Vector3(pos.x, h + 1.0, pos.z)))
			buildings_built += 2
			primary_buildings.append({
				"pos": pos,
				"size": Vector3(w, h, d),
				"rotation": rot,
				"roof_y": h,
			})
			break

	# Approach pillars — one per primary building, placed at wall-jump distance
	# from the building face, at ~half the building's height. Acts as a
	# stepping stone: ground → pillar → ledge → roof.
	for b in primary_buildings:
		var b_pos: Vector3 = b["pos"]
		var b_size: Vector3 = b["size"]
		var b_roof: float = b["roof_y"]
		var b_extent: float = maxf(b_size.x, b_size.z) * 0.5
		for attempt in 20:
			var ang: float = rng.randf() * TAU
			var jump_dist: float = rng.randf_range(5.0, 7.5)
			var px: float = b_pos.x + cos(ang) * (b_extent + jump_dist)
			var pz: float = b_pos.z + sin(ang) * (b_extent + jump_dist)
			if absf(px) > perim_radius - 2.0 or absf(pz) > perim_radius - 2.0:
				continue
			var ph: float = b_roof * rng.randf_range(0.4, 0.6)
			var pos := Vector3(px, ph * 0.5, pz)
			if not _try_place(pos, 2.5):
				continue
			_build_pillar(pos, 3.0, ph)
			_build_pillar(_mirror(pos), 3.0, ph)
			break

	# Approach floaters — at most one per building (chance gated). Mid-height,
	# dash-distance away. Lets the player chain ground → floater → roof.
	for b in primary_buildings:
		if rng.randf() >= 0.7:
			continue
		var b_pos2: Vector3 = b["pos"]
		var b_size2: Vector3 = b["size"]
		var b_roof2: float = b["roof_y"]
		var b_extent2: float = maxf(b_size2.x, b_size2.z) * 0.5
		for attempt in 20:
			var ang: float = rng.randf() * TAU
			var f_dist: float = rng.randf_range(3.0, 5.5)
			var px: float = b_pos2.x + cos(ang) * (b_extent2 + f_dist)
			var pz: float = b_pos2.z + sin(ang) * (b_extent2 + f_dist)
			if absf(px) > perim_radius - 2.0 or absf(pz) > perim_radius - 2.0:
				continue
			var py: float = b_roof2 * rng.randf_range(0.55, 0.75)
			var pos := Vector3(px, py, pz)
			if not _try_place(pos, 3.5):
				continue
			_build_floating_platform(pos)
			_build_floating_platform(_mirror(pos))
			break

	# Bridges. Placed after buildings, before pillars, so they sit at roof
	# height regardless of pillar / cover placements below.
	var bridges_built: int = 0
	# (a) Building → building bridges (primary half + their mirrors). Only
	# allow bridges between near-equal-height roofs so the bridge connects
	# two rooftops cleanly instead of piercing the side of the taller one.
	for i in primary_buildings.size():
		for j in range(i + 1, primary_buildings.size()):
			var a: Dictionary = primary_buildings[i]
			var b: Dictionary = primary_buildings[j]
			var dxz: float = Vector2(a["pos"].x - b["pos"].x, a["pos"].z - b["pos"].z).length()
			if dxz < 9.0 or dxz > 28.0:
				continue
			if absf(a["roof_y"] - b["roof_y"]) > 3.0:
				continue
			if rng.randf() >= bridge_chance:
				continue
			_build_bridge(a["pos"], b["pos"], a["roof_y"], b["roof_y"])
			_build_bridge(_mirror(a["pos"]), _mirror(b["pos"]), a["roof_y"], b["roof_y"])
			bridges_built += 2
	# (b) Building → center tower bridges (only if a tower exists, and only
	# when the building roof and tower top are within bridge-able height).
	if has_center:
		for a in primary_buildings:
			var d_to_center: float = Vector2(a["pos"].x, a["pos"].z).length()
			if d_to_center < 6.0 or d_to_center > 24.0:
				continue
			if absf(a["roof_y"] - tower_h) > 3.0:
				continue
			if rng.randf() >= bridge_chance * 0.55:
				continue
			# Bridge ends 2.5m short of the center so it touches the tower face,
			# not the tower's centerline.
			var dir2 := Vector2(-a["pos"].x, -a["pos"].z).normalized()
			var tower_endpoint := Vector3(dir2.x * 2.5, 0, dir2.y * 2.5)
			_build_bridge(a["pos"], tower_endpoint, a["roof_y"], tower_h)
			_build_bridge(_mirror(a["pos"]), -tower_endpoint, a["roof_y"], tower_h)
			bridges_built += 2

	# Tunnel (sometimes) — covered passage with two open ends. Long footprint
	# so it eats a lot of placement budget; try once and accept failure.
	var tunnels_built: int = 0
	if rng.randf() < tunnel_chance:
		for attempt in 20:
			var t_len: float = rng.randf_range(11.0, 16.0)
			var t_width: float = 4.0
			var t_height: float = 4.0
			var ang_pos: float = rng.randf() * TAU
			var dist: float = rng.randf_range(8.0, perim_radius - t_len * 0.6)
			var x: float = cos(ang_pos) * dist
			var z: float = sin(ang_pos) * dist
			# Constrain to negative-x half so mirror is well-defined.
			if x > 0:
				x = -x
				z = -z
			var t_rot: float = rng.randf() * PI
			var pos := Vector3(x, t_height * 0.5, z)
			# Conservative footprint — tunnel is long, place it carefully.
			var t_radius: float = t_len * 0.5 + 1.0
			if not _try_place(pos, t_radius):
				continue
			_build_tunnel(pos, t_len, t_width, t_height, t_rot)
			_build_tunnel(_mirror(pos), t_len, t_width, t_height, t_rot + PI)
			tunnels_built = 2
			break

	# Diagonal walls — long thin slabs at random angles. Internal partitions
	# that break sightlines and offer cover at unusual orientations.
	var diag_built: int = 0
	for i in num_diagonal_walls:
		for attempt in 30:
			var dw_len: float = rng.randf_range(8.0, 13.0)
			var dw_h: float = rng.randf_range(4.0, 6.0)
			var x: float = rng.randf_range(-perim_radius + dw_len * 0.5, -3.0)
			var z: float = rng.randf_range(-perim_radius + dw_len * 0.5, perim_radius - dw_len * 0.5)
			var pos := Vector3(x, dw_h * 0.5, z)
			var rot: float = rng.randf() * PI
			if not _try_place(pos, dw_len * 0.5 + 0.5):
				continue
			_add_static_box(pos, Vector3(dw_len, dw_h, 1.0), _mat_dark, rot)
			_add_static_box(_mirror(pos), Vector3(dw_len, dw_h, 1.0), _mat_dark, rot + PI)
			diag_built += 2
			break

	# Pillars.
	var pillar_size: float = 3.0
	var pillar_h: float = 8.0
	for i in num_pillar_pairs:
		for attempt in 40:
			var x: float = rng.randf_range(-perim_radius + 3.0, -3.0)
			var z: float = rng.randf_range(-perim_radius + 3.0, perim_radius - 3.0)
			var pos := Vector3(x, pillar_h * 0.5, z)
			if not _try_place(pos, pillar_size * 0.5 + 1.5):
				continue
			_build_pillar(pos, pillar_size, pillar_h)
			_build_pillar(_mirror(pos), pillar_size, pillar_h)
			break

	# Cover blocks (low, random rotation — angle the long face for varied sightlines).
	var cover_size := Vector3(3.5, 2.0, 1.2)
	for i in num_cover_pairs:
		for attempt in 40:
			var x: float = rng.randf_range(-perim_radius + 2.0, -1.5)
			var z: float = rng.randf_range(-perim_radius + 2.0, perim_radius - 2.0)
			var pos := Vector3(x, cover_size.y * 0.5, z)
			if not _try_place(pos, cover_size.x * 0.55 + 0.5):
				continue
			var rot: float = rng.randf() * TAU
			_build_cover(pos, rot, cover_size)
			_build_cover(_mirror(pos), rot + PI, cover_size)
			break

	# Floating platforms (use cylinder mesh — visual break from the boxy stuff).
	for i in num_floating_pairs:
		for attempt in 30:
			var x: float = rng.randf_range(-perim_radius + 4.0, -3.0)
			var z: float = rng.randf_range(-perim_radius + 4.0, perim_radius - 4.0)
			var y: float = rng.randf_range(5.0, 9.0)
			var pos := Vector3(x, y, z)
			if not _try_place(pos, 3.5):
				continue
			_build_floating_platform(pos)
			_build_floating_platform(_mirror(pos))
			break

	# Always-present corner ground spawns (4) — guarantees a spawn even if
	# building placement fails entirely.
	var corner: float = arena_size * 0.42
	_spawn_positions.append(Vector3(-corner, 3.0, -corner))
	_spawn_positions.append(Vector3(corner, 3.0, corner))
	_spawn_positions.append(Vector3(-corner, 3.0, corner))
	_spawn_positions.append(Vector3(corner, 3.0, -corner))

	_emit_spawnpoints()

	var palette: Dictionary = current_palette()
	last_stats = {
		"seed": seed,
		"arena_size": arena_size,
		"buildings": buildings_built,
		"bridges": bridges_built,
		"tunnels": tunnels_built,
		"diagonal_walls": diag_built,
		"spawnpoints": _spawn_positions.size(),
		"has_center_tower": has_center,
		"no_walls": no_walls,
		"has_hole": has_hole,
		"palette": palette["name"],
		"sky_top": palette["sky_top"],
		"sky_horizon": palette["sky_horizon"],
		"ambient": palette["ambient"],
		"fog": palette["fog"],
		"fog_density": palette.get("fog_density", 0.012),
		"sun": palette["sun"],
		"fill": palette["fill"],
		"gen_ms": (Time.get_ticks_usec() - t0) / 1000.0,
	}
	emit_signal("regenerated", last_stats)


# --- Placement helpers --------------------------------------------------------

func _mirror(p: Vector3) -> Vector3:
	return Vector3(-p.x, p.y, -p.z)


func _try_place(pos: Vector3, radius: float) -> bool:
	# Check the candidate AND its 180° mirror against everything previously
	# placed (which already includes mirrors). Reject if either overlaps.
	var p2 := Vector2(pos.x, pos.z)
	var mp2 := Vector2(-pos.x, -pos.z)
	for entry in _placed:
		var ep: Vector2 = entry[0]
		var er: float = entry[1]
		var min_d: float = radius + er
		if p2.distance_to(ep) < min_d:
			return false
		if mp2.distance_to(ep) < min_d:
			return false
	_placed.append([p2, radius])
	# Don't double-register the mirror if the candidate is already on the axis.
	if p2.distance_to(mp2) > 0.01:
		_placed.append([mp2, radius])
	return true


# --- Material helpers ---------------------------------------------------------

func _ensure_materials() -> void:
	var palette: Dictionary = current_palette()
	_mat_floor = _make_mat(palette["floor"], 0.9)
	_mat_wall = _make_mat(palette["wall"], 0.82)
	_mat_building = _make_mat(palette["building"], 0.68)
	_mat_dark = _make_mat(palette["dark"], 0.78)
	_mat_accent_red = _make_emissive(palette["accent_a"], 2.6)
	_mat_accent_yellow = _make_emissive(palette["accent_b"], 2.8)
	_mat_spawn = _make_emissive(COLOR_SPAWN, 1.5)


func current_palette() -> Dictionary:
	return PALETTES[absi(seed) % PALETTES.size()]


func _make_mat(color: Color, roughness: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	return m


func _make_emissive(color: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = energy
	return m


# --- Builders -----------------------------------------------------------------

func _add_static_box(pos: Vector3, size: Vector3, mat: StandardMaterial3D, rotation_y: float = 0.0, with_collider: bool = true) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = pos
	if rotation_y != 0.0:
		body.rotation.y = rotation_y
	add_child(body)
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mi.mesh = box
	mi.material_override = mat
	body.add_child(mi)
	var col: CollisionShape3D = null
	if with_collider:
		col = CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = size
		col.shape = shape
		body.add_child(col)
	if Engine.is_editor_hint():
		var root: Node = get_tree().edited_scene_root
		body.owner = root
		mi.owner = root
		if col:
			col.owner = root
	return body


func _build_floor(has_hole: bool = false, hole_pos: Vector2 = Vector2.ZERO, hole_size: float = 0.0) -> void:
	if not has_hole or hole_size <= 0.0:
		_add_static_box(Vector3(0, -0.5, 0), Vector3(arena_size, 1, arena_size), _mat_floor)
		return
	# Floor with a square cutout — built as 4 strips (N / S / W / E) around
	# the hole. Lava under the floor (y = -2) shows through the hole, and
	# the kill area instakills any player who falls in.
	var half: float = arena_size * 0.5
	var hx: float = hole_pos.x
	var hz: float = hole_pos.y
	var hh: float = hole_size * 0.5
	# North strip — full width, runs from -half (Z) up to the hole's near edge.
	var n_d: float = (hz - hh) - (-half)
	if n_d > 0.1:
		var n_z: float = (-half + (hz - hh)) * 0.5
		_add_static_box(Vector3(0, -0.5, n_z), Vector3(arena_size, 1, n_d), _mat_floor)
	# South strip — from hole's far edge to +half.
	var s_d: float = half - (hz + hh)
	if s_d > 0.1:
		var s_z: float = ((hz + hh) + half) * 0.5
		_add_static_box(Vector3(0, -0.5, s_z), Vector3(arena_size, 1, s_d), _mat_floor)
	# West strip — only spans the hole's Z range, fills X up to the hole.
	var w_w: float = (hx - hh) - (-half)
	if w_w > 0.1:
		var w_x: float = (-half + (hx - hh)) * 0.5
		_add_static_box(Vector3(w_x, -0.5, hz), Vector3(w_w, 1, hole_size), _mat_floor)
	# East strip — from hole's far edge to +half.
	var e_w: float = half - (hx + hh)
	if e_w > 0.1:
		var e_x: float = ((hx + hh) + half) * 0.5
		_add_static_box(Vector3(e_x, -0.5, hz), Vector3(e_w, 1, hole_size), _mat_floor)


func _build_lava_pool() -> void:
	# Huge animated lava plane stretching to the horizon, plus an Area3D that
	# instakills any player whose hitboxes drop into it. Sits 2m below the
	# arena floor so it never shows through inside; a player who escapes the
	# perimeter wall (wall-jump out, knockback over the edge, etc.) falls
	# past where the floor would be and lands in the lava.
	#
	# 6km plane — the geometry is still just a subdivided quad, the shader
	# samples noise in world space so features don't stretch with the size,
	# and fog hides everything past ~120m anyway.
	var pool_size: float = 6000.0
	var pool_y: float = -2.0

	var mi := MeshInstance3D.new()
	mi.name = "LavaSurface"
	var plane := PlaneMesh.new()
	plane.size = Vector2(pool_size, pool_size)
	# Subdivide so global glow / future vertex shader animation has data.
	plane.subdivide_width = 8
	plane.subdivide_depth = 8
	mi.mesh = plane
	mi.position = Vector3(0, pool_y, 0)
	mi.material_override = _make_lava_material()
	add_child(mi)

	var area := Area3D.new()
	area.name = "LavaKillArea"
	area.collision_layer = 0
	# Mask 2 → matches the player's hitbox Area3Ds (HeadHitbox / TorsoHitbox /
	# LegsHitbox in player.tscn, all on layer 2). The CharacterBody3D itself
	# is on layer 0, so we can't use body_entered.
	area.collision_mask = 2
	area.position = Vector3(0, pool_y, 0)
	area.area_entered.connect(_on_lava_area_entered)

	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(pool_size, 4.0, pool_size)
	col.shape = shape
	# Push the box down 2m so its top face lines up with the lava surface.
	col.position = Vector3(0, -2.0, 0)
	area.add_child(col)
	add_child(area)

	if Engine.is_editor_hint():
		var root: Node = get_tree().edited_scene_root
		mi.owner = root
		area.owner = root
		col.owner = root


func _make_lava_material() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = LAVA_SHADER_CODE
	var mat := ShaderMaterial.new()
	mat.shader = sh
	return mat


func _on_lava_area_entered(other_area: Area3D) -> void:
	# Hitboxes are children of the player CharacterBody3D — climb to the
	# parent to reach handle_environmental_death(). Filter to player_hitboxes
	# so other Area3Ds in the scene (none today, but future-proof) don't kill.
	if other_area == null or not other_area.is_in_group("player_hitboxes"):
		return
	var player_node: Node = other_area.get_parent()
	if player_node and player_node.has_method("handle_environmental_death"):
		player_node.handle_environmental_death("lava")


func _build_walls() -> void:
	var half: float = arena_size * 0.5
	# N + S walls span X, depth 1m on Z.
	_add_static_box(Vector3(0, wall_height * 0.5, -half), Vector3(arena_size, wall_height, 1), _mat_wall)
	_add_static_box(Vector3(0, wall_height * 0.5, half), Vector3(arena_size, wall_height, 1), _mat_wall)
	# E + W walls span Z, depth 1m on X.
	_add_static_box(Vector3(half, wall_height * 0.5, 0), Vector3(1, wall_height, arena_size), _mat_wall)
	_add_static_box(Vector3(-half, wall_height * 0.5, 0), Vector3(1, wall_height, arena_size), _mat_wall)


func _build_center_tower(h: float) -> void:
	var size: float = 5.0
	_add_static_box(Vector3(0, h * 0.5, 0), Vector3(size, h, size), _mat_building)
	# Accent strips on each face, alternating red/yellow.
	for i in 4:
		var ang: float = i * PI * 0.5
		var off: float = size * 0.5 + 0.15
		var px: float = cos(ang) * off
		var pz: float = sin(ang) * off
		var mat: StandardMaterial3D = _mat_accent_yellow if i % 2 == 0 else _mat_accent_red
		_add_static_box(Vector3(px, h * 0.5, pz), Vector3(0.3, h * 0.95, 0.3), mat, ang, false)
	# Light at the top.
	var light := OmniLight3D.new()
	light.position = Vector3(0, h + 2.0, 0)
	light.light_color = Color(1, 0.4, 0.3, 1)
	light.light_energy = 2.5
	light.omni_range = 30.0
	add_child(light)
	if Engine.is_editor_hint():
		light.owner = get_tree().edited_scene_root


func _build_building(pos: Vector3, size: Vector3, rotation_y: float, accent_face: int, strip_color: StandardMaterial3D, light_color: Color) -> void:
	# Main body.
	_add_static_box(pos, size, _mat_building, rotation_y)
	# Vertical accent strip on the chosen face. Computed in the building's
	# local frame, then rotated into world.
	var local_ang_a: float = accent_face * PI * 0.5
	var world_ang_a: float = rotation_y + local_ang_a
	var off_a: float = (size.x if accent_face % 2 == 0 else size.z) * 0.5 + 0.15
	var strip_pos: Vector3 = pos + Vector3(cos(world_ang_a) * off_a, 0, sin(world_ang_a) * off_a)
	_add_static_box(strip_pos, Vector3(0.3, size.y * 0.92, 0.3), strip_color, rotation_y, false)
	# Ledge on the opposite face — a wall-jump target halfway up.
	var ledge_face: int = (accent_face + 2) % 4
	var local_ang_l: float = ledge_face * PI * 0.5
	var world_ang_l: float = rotation_y + local_ang_l
	var off_l: float = (size.x if ledge_face % 2 == 0 else size.z) * 0.5 + 1.0
	var ledge_y_offset: float = size.y * 0.6 - size.y * 0.5  # 60% up the building
	var ledge_pos: Vector3 = pos + Vector3(cos(world_ang_l) * off_l, ledge_y_offset, sin(world_ang_l) * off_l)
	# Ledge mesh is 6×0.5×2 (long axis = X). On X-axis faces (face % 2 == 0)
	# we add 90° so the long axis runs parallel to the face, not perpendicular.
	var ledge_align: float = PI * 0.5 if ledge_face % 2 == 0 else 0.0
	_add_static_box(ledge_pos, Vector3(6, 0.5, 2), _mat_building, rotation_y + ledge_align)
	# Roof light.
	var light := OmniLight3D.new()
	light.position = pos + Vector3(0, size.y * 0.5 + 2.0, 0)
	light.light_color = light_color
	light.light_energy = 2.0
	light.omni_range = 18.0
	add_child(light)
	if Engine.is_editor_hint():
		light.owner = get_tree().edited_scene_root


func _build_bridge(a_pos: Vector3, b_pos: Vector3, a_roof_y: float, b_roof_y: float) -> void:
	# Thin slab spanning two rooftops. Sits at the lower of the two roof
	# heights so a player can drop onto it from the taller building or jump
	# up to it from the shorter one. Width 3m → enough to walk on, narrow
	# enough to fall off if you mistime a dash.
	var midpoint := (a_pos + b_pos) * 0.5
	var dxz := Vector2(b_pos.x - a_pos.x, b_pos.z - a_pos.z)
	var length: float = dxz.length() + 2.0  # 1m overlap onto each rooftop
	var angle: float = atan2(dxz.y, dxz.x)
	midpoint.y = minf(a_roof_y, b_roof_y) + 0.2  # sit 0.2m above the rooftop surface
	_add_static_box(midpoint, Vector3(length, 0.4, 3.0), _mat_dark, angle)


func _build_tunnel(center: Vector3, length: float, width: float, height: float, rotation_y: float) -> void:
	# 3-piece tube: two side walls + a roof. Open at both ends so players
	# can run straight through. Center is the tunnel's midpoint at half-height.
	var t: float = 0.5  # wall thickness
	var rot_v: Vector3 = Vector3.UP
	# Side walls in local frame: offset along local Z (perpendicular to length).
	var lw_local := Vector3(0, 0, -(width * 0.5 + t * 0.5))
	var rw_local := Vector3(0, 0, (width * 0.5 + t * 0.5))
	var top_local := Vector3(0, height * 0.5 + t * 0.5, 0)
	var lw_pos: Vector3 = center + lw_local.rotated(rot_v, rotation_y)
	var rw_pos: Vector3 = center + rw_local.rotated(rot_v, rotation_y)
	var top_pos: Vector3 = center + top_local.rotated(rot_v, rotation_y)
	_add_static_box(lw_pos, Vector3(length, height, t), _mat_dark, rotation_y)
	_add_static_box(rw_pos, Vector3(length, height, t), _mat_dark, rotation_y)
	_add_static_box(top_pos, Vector3(length, t, width + 2 * t), _mat_dark, rotation_y)
	# Accent strip running along the inside of the roof, for visibility.
	var strip_local := Vector3(0, height - 0.05, 0)
	var strip_pos: Vector3 = center + strip_local.rotated(rot_v, rotation_y)
	_add_static_box(strip_pos, Vector3(length * 0.85, 0.08, 0.3), _mat_accent_red, rotation_y, false)


func _build_pillar(pos: Vector3, w: float, h: float) -> void:
	_add_static_box(pos, Vector3(w, h, w), _mat_dark)


func _build_cover(pos: Vector3, rot_y: float, size: Vector3) -> void:
	_add_static_box(pos, size, _mat_dark, rot_y)


func _build_floating_platform(pos: Vector3) -> void:
	# Octagonal puck — cleanly readable as a discrete jump target without
	# adding more boxes to the box-heavy palette.
	var body := StaticBody3D.new()
	body.position = pos
	add_child(body)
	var mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.radial_segments = 8
	cyl.top_radius = 2.5
	cyl.bottom_radius = 2.0
	cyl.height = 0.6
	mi.mesh = cyl
	mi.material_override = _mat_dark
	body.add_child(mi)
	var col := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 2.4
	shape.height = 0.6
	col.shape = shape
	body.add_child(col)
	if Engine.is_editor_hint():
		var root: Node = get_tree().edited_scene_root
		body.owner = root
		mi.owner = root
		col.owner = root


func _emit_spawnpoints() -> void:
	for i in _spawn_positions.size():
		var sp := Node3D.new()
		sp.name = "Spawn_%d" % i
		sp.position = _spawn_positions[i]
		sp.add_to_group("spawnpoints")
		add_child(sp)
		if Engine.is_editor_hint():
			sp.owner = get_tree().edited_scene_root
		if not show_spawn_markers:
			continue
		# Small disc at the player's foot height for visual feedback in preview.
		var marker := MeshInstance3D.new()
		var m := CylinderMesh.new()
		m.radial_segments = 12
		m.top_radius = 0.5
		m.bottom_radius = 0.5
		m.height = 0.18
		marker.mesh = m
		marker.material_override = _mat_spawn
		marker.position.y = -1.0
		sp.add_child(marker)
		if Engine.is_editor_hint():
			marker.owner = get_tree().edited_scene_root


func apply_palette_to_environment(env: Environment, sun: DirectionalLight3D = null, fill: Light3D = null) -> void:
	# Push the current seed's palette into a WorldEnvironment + lights. Used
	# by both the preview and the in-game procedural arena scene so the
	# atmosphere matches the geometry colors.
	var p: Dictionary = current_palette()
	if env and env.sky and env.sky.sky_material is ProceduralSkyMaterial:
		var sky_mat: ProceduralSkyMaterial = env.sky.sky_material
		sky_mat.sky_top_color = p["sky_top"]
		sky_mat.sky_horizon_color = p["sky_horizon"]
		sky_mat.ground_horizon_color = (p["sky_horizon"] as Color).darkened(0.55)
		sky_mat.ground_bottom_color = (p["sky_top"] as Color).darkened(0.45)
	if env:
		env.ambient_light_color = p["ambient"]
		env.fog_light_color = p["fog"]
		env.fog_density = p.get("fog_density", 0.012)
	if sun:
		sun.light_color = p["sun"]
	if fill:
		fill.light_color = p["fill"]
