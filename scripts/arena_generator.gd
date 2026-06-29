@tool
class_name ArenaGenerator
extends Node3D

const DestructibleSolid = preload("res://scripts/destructible_solid.gd")
const DestructionCoordinator = preload("res://scripts/destruction_coordinator.gd")
const LavaFloorOpenness = preload("res://scripts/lava_floor_openness.gd")

# Large floor/wall spans are tiled so each piece fractures like cover/buildings.
const TERRAIN_TILE_SIZE := 8.0
# Hairline mortar gap — keep in sync with DestructibleSolid.VISUAL_CHUNK_INSET.
const MASONRY_MORTAR := 0.008

# Corner tower proportions — reference: chunky medieval parapet + merlons.
const CASTLE_TOWER_FOOTPRINT := 7.5
const CASTLE_TOWER_LIFT := 3.5
const CASTLE_PARAPET_OVERHANG := 1.15
const CASTLE_PARAPET_HEIGHT := 1.35
const CASTLE_MERLON := 1.2
const CASTLE_MERLON_HEIGHT := 1.35
const CASTLE_CRENel := 1.0

# Procedural closed-arena map generator — the only map type in MAP_POOL.
#
# Layout: procedural floor + perimeter walls with corner castle towers
# (overhanging parapet + crenellations), optional center tower, mirrored
# pairs of tall buildings (with side ledges), pillars, cover
# blocks, and floating platforms. Every placed feature has a 180° rotational
# mirror at (-x, -z) so the map is symmetric and plays fair from any spawn.
#
# Tuned for the player's movement kit:
#   WALK 14 m/s, JUMP 9 (~1.35m), DOUBLE_JUMP +~1.2m total ~2.5m,
#   WALL_JUMP_V 10.5 (chained wall-jumps reach 6m+), DASH 28×0.18s = +5m h.
# Buildings 8-12m tall, ledges at ~60% height: a player can wall-jump from
# ground to ledge, then ledge to roof.

signal regenerated(stats: Dictionary)

var _rock_material_cache: Dictionary = {}
static var _static_rock_material_cache: Dictionary = {}

@export var seed: int = 0:
	set(v): seed = v; if auto_regenerate: _queue_regen()
@export var auto_regenerate: bool = true
# If true, regenerate() runs once when the scene first enters the tree. Turn
# off when the host wants to drive regeneration explicitly (e.g. game.gd
# calling apply_seed after instantiating a procedural arena).
@export var regenerate_on_ready: bool = true
# When true, every regenerate() uses the lava-sea island layout (floating stone
# over visible lava). Used by the start menu cinematic.
@export var force_all_floor_lava: bool = false
# Larger central fort + horizon silhouettes + inferno atmosphere tuning.
@export var cinematic_present: bool = false
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
		"name": "castle_grey",
		"floor": Color(0.49, 0.47, 0.44),
		"wall": Color(0.56, 0.54, 0.50),
		"building": Color(0.60, 0.57, 0.53),
		"dark": Color(0.42, 0.40, 0.38),
		"accent_a": Color(0.95, 0.55, 0.22),
		"accent_b": Color(0.82, 0.72, 0.38),
		"sky_top": Color(0.22, 0.24, 0.28),
		"sky_horizon": Color(0.48, 0.46, 0.44),
		"ambient": Color(0.52, 0.50, 0.48),
		"ambient_energy": 1.05,
		"tonemap_exposure": 1.08,
		"ssao_intensity": 0.52,
		"sun_energy": 2.0,
		"fill_energy": 0.55,
		"fog": Color(0.38, 0.38, 0.40),
		"fog_density": 0.010,
		"sun": Color(1.00, 0.82, 0.58),
		"fill": Color(0.55, 0.62, 0.82),
	},
	{
		"name": "limestone_keep",
		"floor": Color(0.50, 0.47, 0.43),
		"wall": Color(0.58, 0.55, 0.50),
		"building": Color(0.62, 0.58, 0.53),
		"dark": Color(0.44, 0.41, 0.37),
		"accent_a": Color(0.90, 0.48, 0.18),
		"accent_b": Color(0.70, 0.62, 0.34),
		"sky_top": Color(0.28, 0.26, 0.24),
		"sky_horizon": Color(0.62, 0.56, 0.48),
		"ambient": Color(0.54, 0.50, 0.46),
		"ambient_energy": 1.05,
		"tonemap_exposure": 1.08,
		"ssao_intensity": 0.52,
		"sun_energy": 2.0,
		"fill_energy": 0.55,
		"fog": Color(0.50, 0.46, 0.40),
		"fog_density": 0.009,
		"sun": Color(1.00, 0.88, 0.68),
		"fill": Color(0.72, 0.68, 0.58),
	},
	{
		"name": "granite_ruin",
		"floor": Color(0.47, 0.48, 0.49),
		"wall": Color(0.54, 0.55, 0.56),
		"building": Color(0.58, 0.59, 0.60),
		"dark": Color(0.40, 0.41, 0.42),
		"accent_a": Color(0.88, 0.42, 0.20),
		"accent_b": Color(0.55, 0.62, 0.38),
		"sky_top": Color(0.18, 0.22, 0.26),
		"sky_horizon": Color(0.42, 0.46, 0.48),
		"ambient": Color(0.50, 0.52, 0.54),
		"ambient_energy": 1.05,
		"tonemap_exposure": 1.08,
		"ssao_intensity": 0.52,
		"sun_energy": 2.0,
		"fill_energy": 0.55,
		"fog": Color(0.32, 0.36, 0.38),
		"fog_density": 0.011,
		"sun": Color(0.92, 0.94, 0.98),
		"fill": Color(0.58, 0.64, 0.78),
	},
	{
		"name": "sandstone_bastion",
		"floor": Color(0.50, 0.46, 0.41),
		"wall": Color(0.58, 0.53, 0.47),
		"building": Color(0.62, 0.56, 0.50),
		"dark": Color(0.44, 0.40, 0.36),
		"accent_a": Color(0.95, 0.50, 0.16),
		"accent_b": Color(0.78, 0.66, 0.32),
		"sky_top": Color(0.32, 0.24, 0.20),
		"sky_horizon": Color(0.72, 0.58, 0.42),
		"ambient": Color(0.56, 0.50, 0.44),
		"ambient_energy": 1.05,
		"tonemap_exposure": 1.08,
		"ssao_intensity": 0.52,
		"sun_energy": 2.0,
		"fill_energy": 0.55,
		"fog": Color(0.55, 0.46, 0.36),
		"fog_density": 0.008,
		"sun": Color(1.00, 0.82, 0.58),
		"fill": Color(0.82, 0.62, 0.42),
	},
]
const COLOR_SPAWN := Color(1.00, 0.40, 0.18)
const LAVA_TICK_SECONDS := 0.5
const LAVA_TICK_DAMAGE := 15
const LAVA_POOL_Y := -3.0
const LAVA_FLOOR_SURFACE_Y := 0.04
const LAVA_FLOOR_DAMAGE_Y := 1.15
const LAVA_ISLAND_TOP_Y := 1.0
const LAVA_ISLAND_MAX_GAP := 5.6
const LAVA_ISLAND_MIN_TOP_Y := 0.9
const LAVA_ISLAND_MAX_TOP_Y := 9.0
const LAVA_ISLAND_MAX_HEIGHT_STEP := 2.05
const LAVA_SPAWN_PLATFORM_INSET := 0.65  # keep the player capsule off platform edges

const LAVA_FLOW_SHADER := preload("res://shaders/lava_flow.gdshader")
const ROCK_SURFACE_SHADER := preload("res://shaders/rock_surface.gdshader")
const BANNER_SHADER := preload("res://shaders/banner.gdshader")

static var _lava_noise_texture: ImageTexture = null
static var _rock_noise_texture: ImageTexture = null


static func get_lava_noise_texture() -> ImageTexture:
	if _lava_noise_texture != null:
		return _lava_noise_texture
	var fl := FastNoiseLite.new()
	fl.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	fl.fractal_type = FastNoiseLite.FRACTAL_FBM
	fl.frequency = 0.07
	fl.fractal_octaves = 5
	fl.seed = 90210
	var size := 256
	var img := Image.create(size, size, false, Image.FORMAT_RF)
	for y in size:
		for x in size:
			var v: float = fl.get_noise_2d(float(x), float(y)) * 0.5 + 0.5
			img.set_pixel(x, y, Color(v, 0.0, 0.0, 1.0))
	_lava_noise_texture = ImageTexture.create_from_image(img)
	return _lava_noise_texture


static func get_rock_noise_texture() -> ImageTexture:
	if _rock_noise_texture != null:
		return _rock_noise_texture
	var fl := FastNoiseLite.new()
	fl.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	fl.fractal_type = FastNoiseLite.FRACTAL_FBM
	fl.frequency = 0.032
	fl.fractal_octaves = 5
	fl.seed = 44102
	var size := 256
	var img := Image.create(size, size, false, Image.FORMAT_RF)
	for y in size:
		for x in size:
			var v: float = fl.get_noise_2d(float(x), float(y)) * 0.5 + 0.5
			img.set_pixel(x, y, Color(v, 0.0, 0.0, 1.0))
	_rock_noise_texture = ImageTexture.create_from_image(img)
	return _rock_noise_texture


static func make_rock_material(color: Color, roughness: float = 0.96, seed_salt: int = 0) -> ShaderMaterial:
	var key := "m10s:%d:%d:%d:%d:%d" % [
		roundi(color.r * 255.0),
		roundi(color.g * 255.0),
		roundi(color.b * 255.0),
		roundi(roughness * 100.0),
		seed_salt,
	]
	if _static_rock_material_cache.has(key):
		return _static_rock_material_cache[key]
	var mat := ShaderMaterial.new()
	mat.shader = ROCK_SURFACE_SHADER
	mat.set_shader_parameter("base_color", color)
	mat.set_shader_parameter("moss_color", Color(0.36, 0.56, 0.30))
	mat.set_shader_parameter("roughness", roughness)
	mat.set_shader_parameter("noise_texture", get_rock_noise_texture())
	mat.set_shader_parameter("material_seed", float(absi(hash(key)) % 10000) * 0.001)
	mat.set_shader_parameter("pit_depth", 0.48)
	mat.set_shader_parameter("crack_depth", 0.52)
	mat.set_shader_parameter("moss_amount", 0.38)
	mat.set_shader_parameter("noise_scale", 0.085)
	mat.set_shader_parameter("detail_scale", 2.0)
	mat.set_shader_parameter("color_variation", 0.28)
	mat.set_shader_parameter("deform_amount", 0.055)
	_static_rock_material_cache[key] = mat
	return mat


static func make_lava_shader_material() -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = LAVA_FLOW_SHADER
	mat.set_shader_parameter("noise_texture", get_lava_noise_texture())
	mat.set_shader_parameter("world_scale", 0.048)
	mat.set_shader_parameter("flow_speed", 0.42)
	mat.set_shader_parameter("emission_strength", 1.35)
	return mat


var _mat_floor: ShaderMaterial
var _mat_wall: ShaderMaterial
var _mat_building: ShaderMaterial
var _mat_dark: ShaderMaterial
var _banner_mat: ShaderMaterial
var _mat_spawn: StandardMaterial3D

# Each entry: [Vector2 center_xz, float radius]. Used for collision-free
# placement (kept flat instead of full AABB — bounding circles are good
# enough for this scale and avoid axis-aligned rotation headaches).
var _placed: Array = []
var _spawn_positions: Array[Vector3] = []
var _lava_damage_accum_by_player: Dictionary = {}
var _lava_safe_zones: Array = []
var _all_floor_lava: bool = false
var _lava_openness: LavaFloorOpenness = null

var last_stats: Dictionary = {}
var _regen_pending: bool = false


func _ready() -> void:
	if not Engine.is_editor_hint() and regenerate_on_ready:
		regenerate()


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if _all_floor_lava:
		_apply_all_floor_lava_damage(delta)
	else:
		_apply_lava_pool_damage(delta)


func _queue_regen() -> void:
	if _regen_pending:
		return
	_regen_pending = true
	call_deferred("_do_queued_regen")


func _do_queued_regen() -> void:
	_regen_pending = false
	regenerate()


func regenerate() -> void:
	while get_child_count() > 0:
		var child := get_child(0)
		remove_child(child)
		child.free()
	var coord: Node = DestructionCoordinator.new()
	add_child(coord)
	_placed.clear()
	_spawn_positions.clear()
	_lava_damage_accum_by_player.clear()
	_lava_safe_zones.clear()
	_all_floor_lava = false
	_lava_openness = null
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

	# One roll picks the structural variant. 18% all-floor-lava island arena,
	# 24% open arena (no perimeter walls — players can run off into the lava),
	# 16% walled with a hole in the floor, 42% normal walled-and-solid.
	# Mutually exclusive.
	var variant_roll: float = rng.randf()
	var all_floor_lava: bool = force_all_floor_lava or variant_roll < 0.18
	var no_walls: bool = (not all_floor_lava) and variant_roll < 0.42
	var has_hole: bool = (not all_floor_lava) and (not no_walls) and variant_roll < 0.58
	var hole_pos: Vector2 = Vector2.ZERO
	var hole_size: float = 0.0
	if has_hole:
		hole_size = rng.randf_range(10.0, 16.0)
		var max_off: float = arena_size * 0.25
		hole_pos = Vector2(rng.randf_range(-max_off, max_off), rng.randf_range(-max_off, max_off))

	if all_floor_lava:
		_all_floor_lava = true
		_build_walls()
		_build_lava_pool()
		_build_lava_floor_surface()
		var lava_stats: Dictionary = _build_lava_island_layout(rng, arena_size * 0.5 - 3.0)
		_build_sky_visuals(rng)
		_emit_spawnpoints()
		var lava_palette: Dictionary = current_palette()
		last_stats = {
			"seed": seed,
			"arena_size": arena_size,
			"buildings": 0,
			"bridges": lava_stats.get("bridges", 0),
			"tunnels": 0,
			"diagonal_walls": 0,
			"spawnpoints": _spawn_positions.size(),
			"has_center_tower": false,
			"no_walls": false,
			"has_hole": false,
			"all_floor_lava": true,
			"lava_platforms": lava_stats.get("platforms", 0),
			"reachable_edges": lava_stats.get("reachable_edges", 0),
			"reachable_valid": lava_stats.get("reachable_valid", false),
			"palette": lava_palette["name"],
			"sky_top": lava_palette["sky_top"],
			"sky_horizon": lava_palette["sky_horizon"],
			"ambient": lava_palette["ambient"],
			"fog": lava_palette["fog"],
			"fog_density": lava_palette.get("fog_density", 0.012),
			"sun": lava_palette["sun"],
			"fill": lava_palette["fill"],
			"gen_ms": (Time.get_ticks_usec() - t0) / 1000.0,
		}
		emit_signal("regenerated", last_stats)
		return

	_build_floor(has_hole, hole_pos, hole_size)
	if not no_walls:
		_build_walls()
	_build_lava_pool()
	_setup_lava_openness_from_floor()
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
		var tower_roof_y := _castle_tower_top_y(tower_h)
		_spawn_positions.append(Vector3(0, tower_roof_y + 1.0, 0))
	else:
		# Empty center — keep a small reserved disc so cover doesn't all clump there.
		_placed.append([Vector2.ZERO, 2.0])

	# Buildings (with ledges + roof lights). The bigger the footprint, the further
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
			# same accent face / light tint as the primary.
			var accent_face: int = rng.randi() % 4
			var light_color: Color = Color(1, 0.35, 0.2, 1) if rng.randf() < 0.5 else Color(1, 0.7, 0.2, 1)
			_build_building(pos, Vector3(w, h, d), rot, accent_face, light_color)
			_build_building(_mirror(pos), Vector3(w, h, d), rot + PI, accent_face, light_color)
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
		var tower_roof_y := _castle_tower_top_y(tower_h)
		for a in primary_buildings:
			var d_to_center: float = Vector2(a["pos"].x, a["pos"].z).length()
			if d_to_center < 6.0 or d_to_center > 24.0:
				continue
			if absf(a["roof_y"] - tower_roof_y) > 3.0:
				continue
			if rng.randf() >= bridge_chance * 0.55:
				continue
			# Bridge ends 2.5m short of the center so it touches the tower face,
			# not the tower's centerline.
			var dir2 := Vector2(-a["pos"].x, -a["pos"].z).normalized()
			var tower_endpoint := Vector3(dir2.x * 2.5, 0, dir2.y * 2.5)
			_build_bridge(a["pos"], tower_endpoint, a["roof_y"], tower_roof_y)
			_build_bridge(_mirror(a["pos"]), -tower_endpoint, a["roof_y"], tower_roof_y)
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
	_build_sky_visuals(rng)

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
		"corner_towers": 4 if not no_walls else 0,
		"no_walls": no_walls,
		"has_hole": has_hole,
		"all_floor_lava": false,
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
	_mat_floor = _make_mat(palette["floor"], 0.97)
	_mat_wall = _make_mat(palette["wall"], 0.96)
	_mat_building = _make_mat(palette["building"], 0.94)
	_mat_dark = _make_mat(palette["dark"], 0.98)
	_mat_spawn = _make_emissive(COLOR_SPAWN, 1.5)


func _cloud_tint() -> Color:
	var palette: Dictionary = current_palette()
	if _all_floor_lava or cinematic_present:
		return (palette["fog"] as Color).lerp(palette["sky_horizon"] as Color, 0.35).lightened(0.12)
	var horizon: Color = palette["sky_horizon"]
	var top: Color = palette["sky_top"]
	return horizon.lerp(top, 0.25).lightened(0.48)


func current_palette() -> Dictionary:
	var p: Dictionary = PALETTES[absi(seed) % PALETTES.size()]
	if _all_floor_lava or cinematic_present:
		return _inferno_palette(p)
	return p


func _inferno_palette(base: Dictionary) -> Dictionary:
	var p: Dictionary = base.duplicate(true)
	var stone := Color(0.30, 0.28, 0.26)
	p["floor"] = (base["floor"] as Color).lerp(stone, 0.62)
	p["wall"] = (base["wall"] as Color).lerp(stone.lightened(0.08), 0.68)
	p["building"] = (base["building"] as Color).lerp(stone.lightened(0.12), 0.64)
	p["dark"] = (base["dark"] as Color).lerp(Color(0.20, 0.18, 0.17), 0.72)
	p["sky_top"] = Color(0.06, 0.05, 0.09)
	p["sky_horizon"] = Color(0.58, 0.24, 0.10)
	p["ambient"] = Color(0.42, 0.32, 0.28)
	p["ambient_energy"] = 1.02
	p["fog"] = Color(0.62, 0.26, 0.10)
	p["fog_density"] = 0.010
	p["fog_sun_scatter"] = 0.0
	p["fog_aerial_perspective"] = 0.0
	p["fog_light_energy"] = 0.82
	p["tonemap_exposure"] = 1.14
	p["sun"] = Color(1.0, 0.72, 0.38)
	p["sun_energy"] = 2.55
	p["fill"] = Color(0.72, 0.38, 0.22)
	p["fill_energy"] = 0.48
	p["sky_energy"] = 1.55
	p["sun_angle_max"] = 28.0
	p["sun_curve"] = 0.12
	p["sun_angular_distance"] = 0.48
	p["glow_intensity"] = 1.18
	p["glow_bloom"] = 0.30
	return p


func is_all_floor_lava() -> bool:
	return _all_floor_lava or bool(last_stats.get("all_floor_lava", false))


func get_lava_surface_world_y() -> float:
	if is_all_floor_lava():
		return global_position.y + LAVA_FLOOR_SURFACE_Y
	return global_position.y + LAVA_POOL_Y


func is_lava_spawn_safe(world_pos: Vector3) -> bool:
	if _lava_safe_zones.is_empty():
		return true
	var local := Vector2(world_pos.x - global_position.x, world_pos.z - global_position.z)
	var local_y := world_pos.y - global_position.y
	# CharacterBody origin ≈ capsule centre; keep it above the lava damage band.
	if local_y < LAVA_FLOOR_SURFACE_Y + LAVA_FLOOR_DAMAGE_Y + 0.5:
		return false
	for entry in _lava_safe_zones:
		var center: Vector2 = entry[0]
		var radius: float = float(entry[1])
		var spawn_radius := maxf(0.35, radius - LAVA_SPAWN_PLATFORM_INSET)
		if local.distance_to(center) <= spawn_radius:
			return true
	return false


func get_lava_fallback_spawn_world() -> Vector3:
	# Center pillar — always present on the lava-platforms layout.
	return global_position + Vector3(0.0, LAVA_ISLAND_TOP_Y + 1.0, 0.0)


func get_lava_spawn_platform_at(world_pos: Vector3) -> Dictionary:
	# Footprint of the lava platform under world_pos, for spawn-offset logic.
	if _lava_safe_zones.is_empty():
		return {}
	var local := Vector2(world_pos.x - global_position.x, world_pos.z - global_position.z)
	var local_y := world_pos.y - global_position.y
	if local_y < LAVA_FLOOR_SURFACE_Y + LAVA_FLOOR_DAMAGE_Y + 0.5:
		return {}
	for entry in _lava_safe_zones:
		var center: Vector2 = entry[0]
		var radius: float = float(entry[1])
		var spawn_radius := maxf(0.35, radius - LAVA_SPAWN_PLATFORM_INSET)
		if local.distance_to(center) <= spawn_radius + 0.75:
			return {
				"center": global_position + Vector3(center.x, world_pos.y, center.y),
				"spawn_radius": spawn_radius,
			}
	return {}


func _prune_lava_spawn_positions() -> void:
	if not _all_floor_lava:
		return
	var kept: Array[Vector3] = []
	for local_spawn in _spawn_positions:
		if is_lava_spawn_safe(global_position + local_spawn):
			kept.append(local_spawn)
	if kept.is_empty():
		kept.append(Vector3(0.0, LAVA_ISLAND_TOP_Y + 1.0, 0.0))
	_spawn_positions = kept


func _make_mat(color: Color, roughness: float) -> ShaderMaterial:
	return make_rock_material(color, roughness, absi(hash(color)) % 997)


static func material_surface_color(mat: Material, fallback: Color = Color(0.45, 0.44, 0.42)) -> Color:
	if mat is StandardMaterial3D:
		return (mat as StandardMaterial3D).albedo_color
	if mat is ShaderMaterial:
		var bc = (mat as ShaderMaterial).get_shader_parameter("base_color")
		if bc is Color:
			return bc
	return fallback


func warmup_gpu_materials(scene: Node) -> void:
	if scene == null:
		return
	_ensure_materials()
	Violence.warmup_material(scene, _mat_wall)
	Violence.warmup_rock_multimesh(scene, _mat_wall)


func _make_emissive(color: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color.lightened(0.05)
	m.roughness = 1.0
	m.metallic = 0.0
	m.diffuse_mode = BaseMaterial3D.DIFFUSE_TOON
	m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = energy * 0.75
	return m


# --- Builders -----------------------------------------------------------------

# Returns the editor's currently-edited scene root, or null when we're not
# inside the editor with a live tree (Engine.is_editor_hint() is also true
# during headless --import / --export, where the node may not even be in a
# tree yet — get_tree() prints "data.tree is null" if called too early).
func _editor_owner() -> Node:
	if not Engine.is_editor_hint() or not is_inside_tree():
		return null
	var tree := get_tree()
	return tree.edited_scene_root if tree else null


func get_lava_openness_ratio() -> float:
	if _all_floor_lava:
		return 1.0
	if _lava_openness != null and is_instance_valid(_lava_openness):
		return _lava_openness.get_ratio()
	return 0.0


func _setup_lava_openness_from_floor() -> void:
	if _all_floor_lava:
		return
	if _lava_openness != null and is_instance_valid(_lava_openness):
		_lava_openness.queue_free()
	_lava_openness = LavaFloorOpenness.new()
	_lava_openness.name = "LavaOpenness"
	add_child(_lava_openness)
	_lava_openness.setup(self, LAVA_POOL_Y, arena_size, 5.5, arena_size * 0.85)
	for child in get_children():
		if child is StaticBody3D and child.is_in_group("lava_floor"):
			child.set_meta("_lava_openness_tracker", _lava_openness)
	var owner_root := _editor_owner()
	if owner_root:
		_lava_openness.owner = owner_root


func _add_destructible_region(
	center: Vector3,
	size: Vector3,
	mat: Material,
	rotation_y: float = 0.0,
	tracks_lava_openness: bool = false,
) -> void:
	var counts := Vector3i(
		maxi(1, ceili(size.x / TERRAIN_TILE_SIZE)),
		maxi(1, ceili(size.y / TERRAIN_TILE_SIZE)),
		maxi(1, ceili(size.z / TERRAIN_TILE_SIZE)),
	)
	var cell := Vector3(
		size.x / float(counts.x),
		size.y / float(counts.y),
		size.z / float(counts.z),
	)
	var corner := center - size * 0.5
	for z: int in counts.z:
		for y: int in counts.y:
			for x: int in counts.x:
				var local := Vector3(
					(float(x) + 0.5) * cell.x,
					(float(y) + 0.5) * cell.y,
					(float(z) + 0.5) * cell.z,
				)
				var tile_center := corner + local
				if rotation_y != 0.0:
					tile_center = center + (local - size * 0.5).rotated(Vector3.UP, rotation_y)
				_add_static_box(tile_center, cell, mat, rotation_y, true, true, tracks_lava_openness)


func _add_static_box(
	pos: Vector3,
	size: Vector3,
	mat: Material,
	rotation_y: float = 0.0,
	with_collider: bool = true,
	destructible: bool = true,
	tracks_lava_openness: bool = false,
) -> StaticBody3D:
	var body: StaticBody3D
	if destructible:
		body = DestructibleSolid.new()
		body.setup_box(pos, size, mat, rotation_y, with_collider)
		if tracks_lava_openness:
			body.add_to_group("lava_floor")
			if _lava_openness != null and is_instance_valid(_lava_openness):
				body.set_meta("_lava_openness_tracker", _lava_openness)
	else:
		body = StaticBody3D.new()
		body.position = pos
		if rotation_y != 0.0:
			body.rotation.y = rotation_y
		var mi := MeshInstance3D.new()
		mi.mesh = DestructibleSolid.get_stone_block_mesh()
		mi.scale = size
		mi.material_override = mat
		body.add_child(mi)
		if with_collider:
			var col := CollisionShape3D.new()
			var shape := BoxShape3D.new()
			shape.size = size
			col.shape = shape
			body.add_child(col)
	add_child(body)
	var box_owner := _editor_owner()
	if box_owner:
		body.owner = box_owner
		for child in body.get_children():
			child.owner = box_owner
	return body


func _add_floor_slab(center: Vector3, size: Vector3) -> void:
	# Three 1m layers — walk surface at y=0, bottom at y=-3 on lava.
	var layer_h := 1.0
	var layers := maxi(1, int(round(size.y)))
	var top_y := center.y + size.y * 0.5 - layer_h * 0.5
	for i in layers:
		var y := top_y - float(i) * layer_h
		_add_destructible_region(Vector3(center.x, y, center.z), Vector3(size.x, layer_h, size.z), _mat_floor, 0.0, true)


func _build_floor(has_hole: bool = false, hole_pos: Vector2 = Vector2.ZERO, hole_size: float = 0.0) -> void:
	if not has_hole or hole_size <= 0.0:
		_add_floor_slab(Vector3(0, -1.5, 0), Vector3(arena_size, 3.0, arena_size))
		return
	# Floor with a square cutout — built as 4 strips (N / S / W / E) around
	# the hole. Lava under the floor (y = -3) shows through once all layers
	# are gone, and the kill area instakills any player who falls in.
	var half: float = arena_size * 0.5
	var hx: float = hole_pos.x
	var hz: float = hole_pos.y
	var hh: float = hole_size * 0.5
	# North strip — full width, runs from -half (Z) up to the hole's near edge.
	var n_d: float = (hz - hh) - (-half)
	if n_d > 0.1:
		var n_z: float = (-half + (hz - hh)) * 0.5
		_add_floor_slab(Vector3(0, -1.5, n_z), Vector3(arena_size, 3.0, n_d))
	# South strip — from hole's far edge to +half.
	var s_d: float = half - (hz + hh)
	if s_d > 0.1:
		var s_z: float = ((hz + hh) + half) * 0.5
		_add_floor_slab(Vector3(0, -1.5, s_z), Vector3(arena_size, 3.0, s_d))
	# West strip — only spans the hole's Z range, fills X up to the hole.
	var w_w: float = (hx - hh) - (-half)
	if w_w > 0.1:
		var w_x: float = (-half + (hx - hh)) * 0.5
		_add_floor_slab(Vector3(w_x, -1.5, hz), Vector3(w_w, 3.0, hole_size))
	# East strip — from hole's far edge to +half.
	var e_w: float = half - (hx + hh)
	if e_w > 0.1:
		var e_x: float = ((hx + hh) + half) * 0.5
		_add_floor_slab(Vector3(e_x, -1.5, hz), Vector3(e_w, 3.0, hole_size))


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
	var pool_y: float = LAVA_POOL_Y

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

	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(pool_size, 4.0, pool_size)
	col.shape = shape
	# Push the box down 2m so its top face lines up with the lava surface.
	col.position = Vector3(0, -2.0, 0)
	area.add_child(col)
	add_child(area)

	var root := _editor_owner()
	if root:
		mi.owner = root
		area.owner = root
		col.owner = root


func _build_lava_floor_surface() -> void:
	var mi := MeshInstance3D.new()
	mi.name = "LavaFloorSurface"
	var plane := PlaneMesh.new()
	plane.size = Vector2(arena_size, arena_size)
	plane.subdivide_width = 8
	plane.subdivide_depth = 8
	mi.mesh = plane
	mi.position = Vector3(0, LAVA_FLOOR_SURFACE_Y, 0)
	mi.material_override = _make_lava_material()
	add_child(mi)
	var glow_energy := 16.0 if cinematic_present else 8.0
	_add_lava_glow_light(
		Vector3(0.0, LAVA_FLOOR_SURFACE_Y + 0.35, 0.0),
		arena_size * 0.78,
		glow_energy,
	)
	if cinematic_present:
		_build_cinematic_lava_sea_glow()
	var floor_owner := _editor_owner()
	if floor_owner:
		mi.owner = floor_owner


func _make_lava_material() -> ShaderMaterial:
	return make_lava_shader_material()


func _add_lava_glow_light(local_pos: Vector3, omni_range: float, energy: float) -> void:
	var light := OmniLight3D.new()
	light.name = "LavaGlow"
	light.position = local_pos
	light.light_color = Color(1.0, 0.42, 0.12)
	light.light_energy = energy
	light.omni_range = omni_range
	light.omni_attenuation = 0.65
	light.shadow_enabled = false
	add_child(light)
	var owner_root := _editor_owner()
	if owner_root:
		light.owner = owner_root


func _build_cinematic_lava_sea_glow() -> void:
	# Extra rim fill so exposed lava reads hot even under the floating fort.
	for i in 8:
		var ang := TAU * float(i) / 8.0
		var dist := arena_size * 0.22
		_add_lava_glow_light(
			Vector3(cos(ang) * dist, LAVA_FLOOR_SURFACE_Y + 0.22, sin(ang) * dist),
			arena_size * 0.38,
			5.5,
		)


func _add_torch_brazier(local_pos: Vector3, energy: float = 2.8, omni_range: float = 14.0) -> void:
	var root := Node3D.new()
	root.name = "Torch"
	root.position = local_pos
	add_child(root)
	var owner_root := _editor_owner()
	if owner_root:
		root.owner = owner_root

	var pole := MeshInstance3D.new()
	var pole_mesh := CylinderMesh.new()
	pole_mesh.top_radius = 0.08
	pole_mesh.bottom_radius = 0.11
	pole_mesh.height = 1.35
	pole.mesh = pole_mesh
	pole.position.y = 0.68
	pole.material_override = _mat_dark
	root.add_child(pole)

	var flame := MeshInstance3D.new()
	var flame_mesh := SphereMesh.new()
	flame_mesh.radius = 0.22
	flame_mesh.height = 0.44
	flame.mesh = flame_mesh
	flame.position.y = 1.45
	var flame_mat := StandardMaterial3D.new()
	flame_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	flame_mat.emission_enabled = true
	flame_mat.emission = Color(1.0, 0.55, 0.15)
	flame_mat.emission_energy_multiplier = 3.2
	flame_mat.albedo_color = Color(1.0, 0.62, 0.18)
	flame.material_override = flame_mat
	root.add_child(flame)

	var light := OmniLight3D.new()
	light.position.y = 1.35
	light.light_color = Color(1.0, 0.58, 0.18)
	light.light_energy = energy
	light.omni_range = omni_range
	light.omni_attenuation = 0.85
	light.shadow_enabled = false
	root.add_child(light)

	if owner_root:
		pole.owner = owner_root
		flame.owner = owner_root
		light.owner = owner_root


# Medieval dressing on the perimeter walls: a few flickering wall torches and a
# heraldic shield/sword banner per wall, all facing into the arena.
func _build_wall_decorations(half: float) -> void:
	# along = axis the wall runs along; fixed = the wall plane; nrm = inward normal.
	var walls := [
		{"along": Vector3(1, 0, 0), "fixed": Vector3(0, 0, -half), "nrm": Vector3(0, 0, 1)},
		{"along": Vector3(1, 0, 0), "fixed": Vector3(0, 0, half), "nrm": Vector3(0, 0, -1)},
		{"along": Vector3(0, 0, 1), "fixed": Vector3(half, 0, 0), "nrm": Vector3(-1, 0, 0)},
		{"along": Vector3(0, 0, 1), "fixed": Vector3(-half, 0, 0), "nrm": Vector3(1, 0, 0)},
	]
	# Each torch is an always-on (shadowless) omni — keep the per-wall count modest.
	var torch_count := clampi(int(arena_size / 24.0), 2, 3)
	for wdef in walls:
		var along: Vector3 = wdef["along"]
		var fixed: Vector3 = wdef["fixed"]
		var nrm: Vector3 = wdef["nrm"]
		for i in torch_count:
			var t := (float(i) + 1.0) / (float(torch_count) + 1.0)
			var along_x := lerpf(-half + 5.0, half - 5.0, t)
			var pos := fixed + along * along_x + nrm * 0.5 + Vector3.UP * (wall_height * 0.6)
			_add_wall_torch(pos, nrm)
		# One banner centred on the wall, hanging from the upper section. Offset
		# past the wall's half-depth (0.5) so it sits in front of the inner face.
		var bpos := fixed + nrm * 0.55 + Vector3.UP * (wall_height * 0.62)
		_add_wall_banner(bpos, nrm, 2.3, 3.6)


func _add_wall_torch(local_pos: Vector3, out_dir: Vector3) -> void:
	var root := Node3D.new()
	root.name = "WallTorch"
	root.position = local_pos
	add_child(root)
	var owner_root := _editor_owner()
	if owner_root:
		root.owner = owner_root
	# Bracket angles up and out from the wall; the flame sits at its tip.
	var bdir := (out_dir + Vector3.UP * 1.5).normalized()
	var bracket := MeshInstance3D.new()
	var bm := CylinderMesh.new()
	bm.top_radius = 0.05
	bm.bottom_radius = 0.08
	bm.height = 0.75
	bracket.mesh = bm
	bracket.material_override = _mat_dark
	bracket.transform = Transform3D(_aim_y_basis(bdir), bdir * 0.34)
	root.add_child(bracket)
	var tip := bdir * 0.72
	var flame := MeshInstance3D.new()
	var fm := SphereMesh.new()
	fm.radius = 0.2
	fm.height = 0.46
	flame.mesh = fm
	flame.position = tip
	var fmat := StandardMaterial3D.new()
	fmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fmat.emission_enabled = true
	fmat.emission = Color(1.0, 0.55, 0.15)
	fmat.emission_energy_multiplier = 3.4
	fmat.albedo_color = Color(1.0, 0.62, 0.2)
	flame.material_override = fmat
	root.add_child(flame)
	var light := OmniLight3D.new()
	light.position = tip
	light.light_color = Color(1.0, 0.56, 0.2)
	light.light_energy = 2.6
	light.omni_range = 13.0
	light.omni_attenuation = 0.9
	light.shadow_enabled = false
	root.add_child(light)
	# Gentle perpetual flicker.
	var tw := light.create_tween().set_loops()
	tw.tween_property(light, "light_energy", 3.1, 0.10).set_trans(Tween.TRANS_SINE)
	tw.tween_property(light, "light_energy", 2.2, 0.13).set_trans(Tween.TRANS_SINE)
	tw.tween_property(light, "light_energy", 2.8, 0.08).set_trans(Tween.TRANS_SINE)
	if owner_root:
		bracket.owner = owner_root
		flame.owner = owner_root
		light.owner = owner_root


func _add_wall_banner(local_pos: Vector3, out_dir: Vector3, w: float, h: float) -> void:
	if _banner_mat == null:
		_banner_mat = ShaderMaterial.new()
		_banner_mat.shader = BANNER_SHADER
	var mi := MeshInstance3D.new()
	mi.name = "Banner"
	var qm := QuadMesh.new()
	qm.size = Vector2(w, h)
	mi.mesh = qm
	mi.material_override = _banner_mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.transform = Transform3D(_aim_z_basis(out_dir), local_pos + out_dir * 0.07)
	add_child(mi)
	var owner_root := _editor_owner()
	if owner_root:
		mi.owner = owner_root


# Orthonormal basis with local +Y aligned to dir (for cylinder brackets).
func _aim_y_basis(dir: Vector3) -> Basis:
	var y := dir.normalized()
	var ref := Vector3.FORWARD if absf(y.dot(Vector3.FORWARD)) < 0.95 else Vector3.RIGHT
	var x := ref.cross(y).normalized()
	var z := x.cross(y).normalized()
	var b := Basis()
	b.x = x
	b.y = y
	b.z = z
	return b


# Orthonormal basis with local +Z aligned to dir, +Y world-up (for facing quads).
func _aim_z_basis(dir: Vector3) -> Basis:
	var z := dir.normalized()
	var x := Vector3.UP.cross(z)
	if x.length_squared() < 0.0001:
		x = Vector3.RIGHT
	x = x.normalized()
	var y := z.cross(x).normalized()
	var b := Basis()
	b.x = x
	b.y = y
	b.z = z
	return b


func _build_cinematic_fort_underglow(slab_base_y: float, footprint: float) -> void:
	var y := slab_base_y + 0.08
	var ring := footprint * 0.46
	for i in 12:
		var ang := TAU * float(i) / 12.0
		var pos := Vector3(cos(ang) * ring, y, sin(ang) * ring)
		var light := OmniLight3D.new()
		light.name = "FortUnderglow"
		light.position = pos
		light.light_color = Color(1.0, 0.38, 0.10)
		light.light_energy = 4.8
		light.omni_range = 13.0
		light.omni_attenuation = 0.55
		light.shadow_enabled = false
		add_child(light)
		var owner_root := _editor_owner()
		if owner_root:
			light.owner = owner_root


func _apply_all_floor_lava_damage(delta: float) -> void:
	var active_ids: Dictionary = {}
	var lava_y := global_position.y + LAVA_FLOOR_SURFACE_Y
	for p: Node in get_tree().get_nodes_in_group("players"):
		if not p is Node3D or not p.is_multiplayer_authority():
			continue
		var pid := int(p.get("player_id")) if p.get("player_id") != null else p.get_instance_id()
		var p3 := p as Node3D
		if p3.global_position.y < lava_y:
			_lava_damage_accum_by_player.erase(pid)
			if p.has_method("kill_environmental"):
				p.kill_environmental("lava_fall")
			continue
		if p3.global_position.y > lava_y + LAVA_FLOOR_DAMAGE_Y:
			_lava_damage_accum_by_player.erase(pid)
			continue
		if _point_in_lava_safe_zone(Vector2(p3.global_position.x, p3.global_position.z)):
			_lava_damage_accum_by_player.erase(pid)
			continue
		active_ids[pid] = true
		var accum := float(_lava_damage_accum_by_player.get(pid, 0.0)) + delta
		while accum >= LAVA_TICK_SECONDS:
			accum -= LAVA_TICK_SECONDS
			if p.has_method("apply_environmental_damage"):
				p.apply_environmental_damage(LAVA_TICK_DAMAGE, "lava")
		_lava_damage_accum_by_player[pid] = accum
	for raw_id in _lava_damage_accum_by_player.keys():
		if not active_ids.has(raw_id):
			_lava_damage_accum_by_player.erase(raw_id)


func _point_in_lava_safe_zone(world_xz: Vector2) -> bool:
	var local := world_xz - Vector2(global_position.x, global_position.z)
	for entry in _lava_safe_zones:
		var center: Vector2 = entry[0]
		var radius: float = entry[1]
		if local.distance_to(center) <= radius:
			return true
	return false


func _apply_lava_pool_damage(delta: float) -> void:
	var active_ids: Dictionary = {}
	var lava_y := global_position.y + LAVA_POOL_Y
	for p: Node in get_tree().get_nodes_in_group("players"):
		if not p is Node3D or not p.is_multiplayer_authority():
			continue
		var pid := int(p.get("player_id")) if p.get("player_id") != null else p.get_instance_id()
		var p3 := p as Node3D
		if p3.global_position.y < lava_y:
			_lava_damage_accum_by_player.erase(pid)
			if p.has_method("kill_environmental"):
				p.kill_environmental("lava_fall")
			continue
		if p3.global_position.y > lava_y + 1.2:
			_lava_damage_accum_by_player.erase(pid)
			continue
		active_ids[pid] = true
		var accum := float(_lava_damage_accum_by_player.get(pid, 0.0)) + delta
		while accum >= LAVA_TICK_SECONDS:
			accum -= LAVA_TICK_SECONDS
			if p.has_method("apply_environmental_damage"):
				p.apply_environmental_damage(LAVA_TICK_DAMAGE, "lava")
		_lava_damage_accum_by_player[pid] = accum
	for raw_id in _lava_damage_accum_by_player.keys():
		if not active_ids.has(raw_id):
			_lava_damage_accum_by_player.erase(raw_id)


func _build_walls() -> void:
	var half: float = arena_size * 0.5
	# N + S walls span X, depth 1m on Z.
	_add_destructible_region(Vector3(0, wall_height * 0.5, -half), Vector3(arena_size, wall_height, 1), _mat_wall)
	_add_destructible_region(Vector3(0, wall_height * 0.5, half), Vector3(arena_size, wall_height, 1), _mat_wall)
	# E + W walls span Z, depth 1m on X.
	_add_destructible_region(Vector3(half, wall_height * 0.5, 0), Vector3(1, wall_height, arena_size), _mat_wall)
	_add_destructible_region(Vector3(-half, wall_height * 0.5, 0), Vector3(1, wall_height, arena_size), _mat_wall)
	_build_corner_towers(half)
	_build_wall_decorations(half)


func _build_corner_towers(half: float) -> void:
	var corners: Array[Vector2] = [
		Vector2(half, -half),
		Vector2(half, half),
		Vector2(-half, half),
		Vector2(-half, -half),
	]
	for corner: Vector2 in corners:
		_build_castle_tower(Vector3(corner.x, 0.0, corner.y))
		_placed.append([corner, CASTLE_TOWER_FOOTPRINT * 0.55 + CASTLE_PARAPET_OVERHANG + 1.5])
		var top_y := _castle_tower_top_y()
		_spawn_positions.append(Vector3(corner.x, top_y + 1.0, corner.y))


func _castle_tower_top_y(shaft_height: float = -1.0) -> float:
	var shaft := shaft_height if shaft_height > 0.0 else wall_height + CASTLE_TOWER_LIFT
	return shaft + CASTLE_PARAPET_HEIGHT + CASTLE_MERLON_HEIGHT


func _build_castle_tower(
	center_xz: Vector3,
	footprint: float = CASTLE_TOWER_FOOTPRINT,
	shaft_height: float = -1.0,
	shaft_mat: Material = null,
	parapet_mat: Material = null,
) -> void:
	var shaft_h := shaft_height if shaft_height > 0.0 else wall_height + CASTLE_TOWER_LIFT
	var shaft_material: Material = shaft_mat if shaft_mat != null else _mat_wall
	var parapet_material: Material = parapet_mat if parapet_mat != null else _mat_building

	_add_destructible_region(
		Vector3(center_xz.x, shaft_h * 0.5, center_xz.z),
		Vector3(footprint, shaft_h, footprint),
		shaft_material,
	)

	var parapet_w := footprint + CASTLE_PARAPET_OVERHANG * 2.0
	var parapet_base_y := shaft_h
	var parapet_center_y := parapet_base_y + CASTLE_PARAPET_HEIGHT * 0.5
	_add_destructible_region(
		Vector3(center_xz.x, parapet_center_y, center_xz.z),
		Vector3(parapet_w, CASTLE_PARAPET_HEIGHT, parapet_w),
		parapet_material,
	)

	_build_crenellation_ring(
		Vector3(center_xz.x, parapet_base_y + CASTLE_PARAPET_HEIGHT, center_xz.z),
		parapet_w,
	)


func _build_crenellation_ring(origin: Vector3, ring_width: float) -> void:
	var merlon_y := origin.y + CASTLE_MERLON_HEIGHT * 0.5
	var half_w := ring_width * 0.5
	var depth := CASTLE_MERLON * 0.88
	_build_crenellation_run(
		Vector3(origin.x, merlon_y, origin.z - half_w),
		Vector3.RIGHT, ring_width, Vector3(0.0, 0.0, -1.0), depth,
	)
	_build_crenellation_run(
		Vector3(origin.x, merlon_y, origin.z + half_w),
		Vector3.RIGHT, ring_width, Vector3(0.0, 0.0, 1.0), depth,
	)
	_build_crenellation_run(
		Vector3(origin.x - half_w, merlon_y, origin.z),
		Vector3(0.0, 0.0, 1.0), ring_width, Vector3(-1.0, 0.0, 0.0), depth,
	)
	_build_crenellation_run(
		Vector3(origin.x + half_w, merlon_y, origin.z),
		Vector3(0.0, 0.0, 1.0), ring_width, Vector3(1.0, 0.0, 0.0), depth,
	)


func _build_crenellation_run(
	edge_center: Vector3,
	axis: Vector3,
	span: float,
	outward: Vector3,
	depth: float,
) -> void:
	var merlon := CASTLE_MERLON
	var gap := CASTLE_CRENel
	var pitch := merlon + gap
	var count := maxi(2, int(floor((span + gap) / pitch)))
	var total := float(count) * pitch - gap
	var axis_n := axis.normalized()
	var outward_n := outward.normalized()
	var start := edge_center - axis_n * (total * 0.5 - merlon * 0.5)
	var merlon_size := Vector3(merlon, CASTLE_MERLON_HEIGHT, depth)
	if absf(outward_n.x) > 0.5:
		merlon_size = Vector3(depth, CASTLE_MERLON_HEIGHT, merlon)
	for i: int in count:
		var pos := start + axis_n * (float(i) * pitch) + outward_n * (depth * 0.35)
		_add_static_box(pos, merlon_size, _mat_wall)


func _build_lava_island_layout(rng: RandomNumberGenerator, perim_radius: float) -> Dictionary:
	var platforms: Array = []
	var edges: Array = []
	var center_top: Vector3
	var center_radius: float
	if cinematic_present:
		_build_cinematic_lava_fort(rng, platforms)
		if not platforms.is_empty():
			var hub: Dictionary = platforms[0]
			center_top = hub["pos"] as Vector3
			center_radius = float(hub["radius"])
		else:
			center_top = Vector3(0, LAVA_ISLAND_TOP_Y, 0)
			center_radius = 4.2
	else:
		center_radius = 4.2
		center_top = Vector3(0, LAVA_ISLAND_TOP_Y, 0)
		_register_lava_platform(center_top, center_radius, 1.0, platforms)
		_placed.append([Vector2.ZERO, center_radius + 0.9])

	var spine_anchor: Vector3
	var spine_anchor_radius: float
	if cinematic_present and not platforms.is_empty():
		var hub: Dictionary = platforms[0]
		spine_anchor = hub["pos"] as Vector3
		spine_anchor_radius = float(hub["radius"])
	else:
		spine_anchor = Vector3(0, LAVA_ISLAND_TOP_Y, 0)
		spine_anchor_radius = 4.2
	if not cinematic_present:
		for spine_i in rng.randi_range(3, 5):
			var radius: float = rng.randf_range(3.0, 4.7)
			var height_step: float = rng.randf_range(1.25, LAVA_ISLAND_MAX_HEIGHT_STEP)
			var top_y: float = clampf(spine_anchor.y + height_step, LAVA_ISLAND_MIN_TOP_Y, LAVA_ISLAND_MAX_TOP_Y)
			var gap: float = rng.randf_range(2.7, _lava_max_gap_for_height_step(top_y - spine_anchor.y))
			var dist: float = spine_anchor_radius + radius + gap
			var dir2 := Vector2(-1.0, rng.randf_range(-0.28, 0.28)).normalized()
			var pos := Vector3(spine_anchor.x + dir2.x * dist, top_y, spine_anchor.z + dir2.y * dist)
			if absf(pos.x) + radius > perim_radius or absf(pos.z) + radius > perim_radius:
				break
			if not _try_place(pos, radius + 0.9):
				break
			var mirror_pos := _mirror(pos)
			var column_extra: float = rng.randf_range(0.6, 1.4)
			_register_lava_platform(pos, radius, column_extra, platforms)
			_register_lava_platform(mirror_pos, radius, column_extra, platforms)
			edges.append([spine_anchor, pos])
			edges.append([_mirror(spine_anchor), mirror_pos])
			spine_anchor = pos
			spine_anchor_radius = radius

		var target_pairs: int = clampi(int(round(arena_size / 6.0)) + rng.randi_range(1, 4), 10, 18)
		for i in target_pairs:
			for attempt in 80:
				var anchor: Dictionary = platforms[rng.randi_range(0, platforms.size() - 1)]
				var anchor_pos: Vector3 = anchor["pos"]
				var anchor_radius: float = anchor["radius"]
				if anchor_pos.x > 0.0:
					anchor_pos = _mirror(anchor_pos)
				var radius: float = rng.randf_range(2.2, 5.2)
				var angle: float = rng.randf() * TAU
				var height_step: float = rng.randf_range(-1.55, LAVA_ISLAND_MAX_HEIGHT_STEP)
				if rng.randf() < 0.58 and anchor_pos.y < LAVA_ISLAND_MAX_TOP_Y - 0.7:
					height_step = rng.randf_range(0.6, LAVA_ISLAND_MAX_HEIGHT_STEP)
				var top_y: float = clampf(anchor_pos.y + height_step, LAVA_ISLAND_MIN_TOP_Y, LAVA_ISLAND_MAX_TOP_Y)
				var actual_height_step: float = top_y - anchor_pos.y
				var gap: float = rng.randf_range(2.8, _lava_max_gap_for_height_step(actual_height_step))
				var dist: float = anchor_radius + radius + gap
				var pos := Vector3(
					anchor_pos.x + cos(angle) * dist,
					top_y,
					anchor_pos.z + sin(angle) * dist
				)
				if pos.x > -0.35:
					continue
				if absf(pos.x) + radius > perim_radius or absf(pos.z) + radius > perim_radius:
					continue
				if absf(pos.y - anchor_pos.y) > LAVA_ISLAND_MAX_HEIGHT_STEP:
					continue
				if not _try_place(pos, radius + 0.9):
					continue
				var mirror_pos := _mirror(pos)
				var column_extra: float = rng.randf_range(0.45, 1.5)
				_register_lava_platform(pos, radius, column_extra, platforms)
				_register_lava_platform(mirror_pos, radius, column_extra, platforms)
				edges.append([anchor_pos, pos])
				edges.append([_mirror(anchor_pos), mirror_pos])
				break

		# A few guaranteed cross-arena stepping stones keep the graph from feeling
		# like two disconnected mirrored halves. They are also individually within
		# reach of the center platform.
		var axis_step := Vector3(-(center_radius + 3.2 + LAVA_ISLAND_MAX_GAP * 0.55), LAVA_ISLAND_TOP_Y + 0.15, 0.0)
		if _try_place(axis_step, 3.1):
			_register_lava_platform(axis_step, 3.0, 1.25, platforms)
			_register_lava_platform(_mirror(axis_step), 3.0, 1.25, platforms)
			edges.append([center_top, axis_step])
			edges.append([center_top, _mirror(axis_step)])

	var decorative_bridges: int = _build_lava_island_bridges(edges, rng)
	_add_lava_island_cover(platforms, rng)
	_prune_lava_spawn_positions()
	var reachable_valid := _validate_lava_platform_graph(platforms, edges)
	if not reachable_valid:
		push_warning("Lava island graph failed reachability validation for seed %d" % seed)
	return {
		"platforms": platforms.size(),
		"reachable_edges": edges.size(),
		"bridges": decorative_bridges,
		"reachable_valid": reachable_valid,
	}


func _build_cinematic_lava_fort(rng: RandomNumberGenerator, platforms: Array) -> void:
	var slab_base_y := LAVA_ISLAND_TOP_Y + 0.35
	var footprint := 24.0
	var slab_h := 3.2
	var slab_center_y := slab_base_y + slab_h * 0.5
	_add_static_box(
		Vector3(0.0, slab_center_y, 0.0),
		Vector3(footprint, slab_h, footprint),
		_mat_wall,
	)
	var deck_y := slab_base_y + slab_h
	var half := footprint * 0.5 - 0.35
	var parapet_h := 2.6
	for side in 4:
		var along_x := side % 2 == 0
		var sign := -1.0 if side < 2 else 1.0
		var wall_len := footprint - 1.2
		var wall_center := Vector3(
			0.0 if along_x else sign * half,
			deck_y + parapet_h * 0.5,
			sign * half if along_x else 0.0,
		)
		var wall_size := Vector3(wall_len, parapet_h, 1.35) if along_x else Vector3(1.35, parapet_h, wall_len)
		_add_static_box(wall_center, wall_size, _mat_wall)
	_build_crenellation_ring(Vector3(0.0, deck_y + parapet_h, 0.0), footprint - 1.0)

	var tower_h := rng.randf_range(11.5, 13.5)
	_build_castle_tower(
		Vector3(0.0, deck_y - 0.15, 0.0),
		9.5, tower_h, _mat_wall, _mat_building,
	)
	for i in 4:
		var ang := float(i) * PI * 0.5 + PI * 0.25
		var off := Vector3(cos(ang), 0.0, sin(ang)) * footprint * 0.36
		_add_static_box(
			Vector3(off.x, deck_y + 1.4, off.z),
			Vector3(5.2, 2.8, 5.2),
			_mat_building,
		)
		_add_torch_brazier(
			Vector3(off.x, deck_y + 0.2, off.z),
			2.4, 12.0,
		)
	_add_torch_brazier(Vector3(0.0, deck_y + 0.35, 0.0), 4.2, 18.0)
	_build_cinematic_fort_underglow(slab_base_y, footprint)

	var hub_top := Vector3(0.0, deck_y, 0.0)
	_lava_safe_zones.append([Vector2.ZERO, footprint * 0.44])
	_spawn_positions.append(Vector3(0.0, _castle_tower_top_y(tower_h) + 1.0, 0.0))
	_placed.append([Vector2.ZERO, footprint * 0.48])
	platforms.append({"pos": hub_top, "radius": footprint * 0.44, "height": slab_h})


func _register_lava_platform(top_pos: Vector3, radius: float, platform_height: float, platforms: Array) -> void:
	var height := maxf(0.45, top_pos.y - LAVA_FLOOR_SURFACE_Y + platform_height)
	var center := Vector3(top_pos.x, top_pos.y - height * 0.5, top_pos.z)
	_build_lava_jump_platform(center, radius, height)
	_lava_safe_zones.append([Vector2(top_pos.x, top_pos.z), radius + 0.25])
	_spawn_positions.append(Vector3(top_pos.x, top_pos.y + 1.0, top_pos.z))
	platforms.append({
		"pos": top_pos,
		"radius": radius,
		"height": height,
	})


func _validate_lava_platform_graph(platforms: Array, edges: Array) -> bool:
	if platforms.is_empty():
		return false
	var radii: Dictionary = {}
	var adjacency: Dictionary = {}
	for platform in platforms:
		var pos: Vector3 = platform["pos"]
		var key := _lava_platform_key(pos)
		radii[key] = float(platform["radius"])
		adjacency[key] = []
	for edge in edges:
		var a: Vector3 = edge[0]
		var b: Vector3 = edge[1]
		var a_key := _lava_platform_key(a)
		var b_key := _lava_platform_key(b)
		if not adjacency.has(a_key) or not adjacency.has(b_key):
			push_warning("Lava reachability edge references missing platform: %s -> %s" % [a_key, b_key])
			return false
		var gap := Vector2(a.x - b.x, a.z - b.z).length() - float(radii[a_key]) - float(radii[b_key])
		var max_gap := _lava_max_gap_for_height_step(b.y - a.y)
		if gap > max_gap + 0.05:
			push_warning("Lava reachability edge gap too wide: %.2f > %.2f (%s -> %s)" % [gap, max_gap, a_key, b_key])
			return false
		if absf(a.y - b.y) > LAVA_ISLAND_MAX_HEIGHT_STEP + 0.05:
			push_warning("Lava reachability height step too tall: %.2f > %.2f (%s -> %s)" % [absf(a.y - b.y), LAVA_ISLAND_MAX_HEIGHT_STEP, a_key, b_key])
			return false
		(adjacency[a_key] as Array).append(b_key)
		(adjacency[b_key] as Array).append(a_key)
	var start_key := _lava_platform_key(platforms[0]["pos"])
	var visited: Dictionary = {start_key: true}
	var queue: Array = [start_key]
	while not queue.is_empty():
		var key: String = queue.pop_front()
		for next_key in adjacency[key]:
			if visited.has(next_key):
				continue
			visited[next_key] = true
			queue.append(next_key)
	if visited.size() != platforms.size():
		push_warning("Lava reachability graph disconnected: %d / %d platforms reached" % [visited.size(), platforms.size()])
		return false
	return true


func _lava_platform_key(pos: Vector3) -> String:
	var x := 0.0 if absf(pos.x) < 0.005 else pos.x
	var y := 0.0 if absf(pos.y) < 0.005 else pos.y
	var z := 0.0 if absf(pos.z) < 0.005 else pos.z
	return "%.2f,%.2f,%.2f" % [x, y, z]


func _lava_max_gap_for_height_step(height_step: float) -> float:
	var climb_t := clampf(absf(height_step) / LAVA_ISLAND_MAX_HEIGHT_STEP, 0.0, 1.0)
	return lerpf(LAVA_ISLAND_MAX_GAP, 3.1, climb_t)


func _build_lava_island_bridges(edges: Array, rng: RandomNumberGenerator) -> int:
	var built: int = 0
	for edge in edges:
		if rng.randf() > 0.22:
			continue
		var a: Vector3 = edge[0]
		var b: Vector3 = edge[1]
		var dxz := Vector2(b.x - a.x, b.z - a.z)
		var length: float = dxz.length()
		if length < 7.0:
			continue
		var midpoint := (a + b) * 0.5
		midpoint.y = minf(a.y, b.y) + 0.08
		var angle := atan2(dxz.y, dxz.x)
		_add_static_box(midpoint, Vector3(length - 4.8, 0.22, 1.0), _mat_dark, angle)
		built += 1
	return built


func _add_lava_island_cover(platforms: Array, rng: RandomNumberGenerator) -> void:
	for platform in platforms:
		if rng.randf() > 0.38:
			continue
		var pos: Vector3 = platform["pos"]
		var radius: float = platform["radius"]
		if radius < 3.0:
			continue
		var angle := rng.randf() * TAU
		var cover_size := Vector3(rng.randf_range(1.8, 2.8), 1.1, rng.randf_range(0.8, 1.2))
		var cover_half := maxf(cover_size.x, cover_size.z) * 0.5
		var min_off := maxf(cover_half + 1.35, radius * 0.58)
		var max_off := maxf(min_off + 0.2, radius * 0.88)
		var off := rng.randf_range(min_off, max_off)
		var cover_pos := Vector3(pos.x + cos(angle) * off, pos.y + 0.55, pos.z + sin(angle) * off)
		_add_static_box(cover_pos, cover_size, _mat_dark, rng.randf() * TAU)


func _build_lava_jump_platform(center: Vector3, radius: float, height: float) -> void:
	var body: StaticBody3D = DestructibleSolid.new()
	body.setup_box(center, Vector3(radius * 2.0, height, radius * 2.0), _mat_dark)
	add_child(body)
	var island_owner := _editor_owner()
	if island_owner:
		body.owner = island_owner
		for child in body.get_children():
			child.owner = island_owner


func _build_center_tower(h: float) -> void:
	var footprint := 6.5
	_build_castle_tower(Vector3.ZERO, footprint, h, _mat_building, _mat_building)
	var light := OmniLight3D.new()
	light.position = Vector3(0.0, _castle_tower_top_y(h) + 1.5, 0.0)
	light.light_color = Color(1, 0.4, 0.3, 1)
	light.light_energy = 2.5
	light.omni_range = 30.0
	add_child(light)
	var lava_owner := _editor_owner()
	if lava_owner:
		light.owner = lava_owner


func _build_building(pos: Vector3, size: Vector3, rotation_y: float, accent_face: int, light_color: Color) -> void:
	# Main body.
	_add_static_box(pos, size, _mat_building, rotation_y)
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
	var building_owner := _editor_owner()
	if building_owner:
		light.owner = building_owner


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


func _build_pillar(pos: Vector3, w: float, h: float) -> void:
	_add_static_box(pos, Vector3(w, h, w), _mat_dark)


func _build_cover(pos: Vector3, rot_y: float, size: Vector3) -> void:
	_add_static_box(pos, size, _mat_dark, rot_y)


func _build_floating_platform(pos: Vector3) -> void:
	var body: StaticBody3D = DestructibleSolid.new()
	body.setup_box(pos, Vector3(5.0, 0.6, 5.0), _mat_dark)
	add_child(body)
	var spawn_root := _editor_owner()
	if spawn_root:
		body.owner = spawn_root
		for child in body.get_children():
			child.owner = spawn_root


func _build_sky_visuals(rng: RandomNumberGenerator) -> void:
	var root := Node3D.new()
	root.name = "SkyClouds"
	add_child(root)
	var owner_root := _editor_owner()
	if owner_root:
		root.owner = owner_root

	var hell := _all_floor_lava or cinematic_present
	var tint := _cloud_tint()
	var cloud_count := 16 if hell else 9
	var ring_min := arena_size * (0.28 if hell else 0.34)
	var ring_max := arena_size * (0.92 if hell else 0.86)
	var y_min := 24.0 if hell else 24.0
	var y_max := 40.0 if hell else 39.0
	for i in cloud_count:
		var angle := (TAU * float(i) / float(cloud_count)) + rng.randf_range(-0.22, 0.22)
		var dist := rng.randf_range(ring_min, ring_max)
		var center := Vector3(cos(angle) * dist, rng.randf_range(y_min, y_max), sin(angle) * dist)
		var cluster := Violence.spawn_sky_cloud_cluster(
			root, center, rng, tint,
			rng.randi_range(7 if hell else 6, 12 if hell else 10),
			rng.randf_range(14.0 if hell else 11.0, 22.0 if hell else 18.0),
			rng.randf_range(8.0 if hell else 6.5, 14.0 if hell else 10.0),
			rng.randf_range(14.0 if hell else 12.0, 26.0 if hell else 20.0),
			hell,
		)
		if owner_root and cluster != null:
			cluster.owner = owner_root
	if hell:
		_build_horizon_silhouettes(rng, root, owner_root)


func _build_horizon_silhouettes(rng: RandomNumberGenerator, root: Node3D, owner_root: Node = null) -> void:
	var silhouettes := Node3D.new()
	silhouettes.name = "HorizonSilhouettes"
	root.add_child(silhouettes)
	if owner_root:
		silhouettes.owner = owner_root
	var peak_mat := StandardMaterial3D.new()
	peak_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	peak_mat.albedo_color = Color(0.035, 0.028, 0.04)
	var dist := arena_size * 0.88
	for i in 14:
		var ang := TAU * float(i) / 14.0 + rng.randf_range(-0.12, 0.12)
		var mi := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		var w := rng.randf_range(16.0, 42.0)
		var h := rng.randf_range(20.0, 52.0)
		mesh.size = Vector3(w, h, w * rng.randf_range(0.22, 0.42))
		mi.mesh = mesh
		mi.material_override = peak_mat
		mi.position = Vector3(cos(ang) * dist, h * 0.32 - 8.0, sin(ang) * dist)
		mi.rotation.y = ang + PI * 0.5
		mi.extra_cull_margin = 220.0
		mi.ignore_occlusion_culling = true
		silhouettes.add_child(mi)
		if owner_root:
			mi.owner = owner_root


func _emit_spawnpoints() -> void:
	for i in _spawn_positions.size():
		var sp := Node3D.new()
		sp.name = "Spawn_%d" % i
		sp.position = _spawn_positions[i]
		sp.add_to_group("spawnpoints")
		add_child(sp)
		var sp_owner := _editor_owner()
		if sp_owner:
			sp.owner = sp_owner
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
		var marker_owner := _editor_owner()
		if marker_owner:
			marker.owner = marker_owner


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
		sky_mat.energy_multiplier = float(p.get("sky_energy", 1.25))
		sky_mat.sky_energy_multiplier = float(p.get("sky_energy", 1.25))
		sky_mat.sun_angle_max = float(p.get("sun_angle_max", 28.0))
		sky_mat.sun_curve = float(p.get("sun_curve", 0.08))
	if env:
		env.ambient_light_color = p["ambient"]
		env.ambient_light_energy = float(p.get("ambient_energy", 1.05))
		env.tonemap_exposure = float(p.get("tonemap_exposure", 1.08))
		env.ssao_enabled = true
		env.ssao_radius = float(p.get("ssao_radius", 1.0))
		env.ssao_intensity = float(p.get("ssao_intensity", 0.52))
		env.fog_enabled = true
		env.fog_light_color = p["fog"]
		env.fog_density = p.get("fog_density", 0.012)
		env.fog_light_energy = float(p.get("fog_light_energy", 1.0))
		env.fog_sun_scatter = float(p.get("fog_sun_scatter", 0.0))
		env.fog_aerial_perspective = float(p.get("fog_aerial_perspective", 0.0))
		env.glow_enabled = true
		env.glow_intensity = float(p.get("glow_intensity", 0.9))
		env.glow_bloom = float(p.get("glow_bloom", 0.2))
	if sun:
		sun.light_color = p["sun"]
		sun.light_energy = float(p.get("sun_energy", 2.0))
		sun.light_angular_distance = float(p.get("sun_angular_distance", 0.85))
		sun.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_AND_SKY
	if fill:
		fill.light_color = p["fill"]
		fill.light_energy = float(p.get("fill_energy", 0.55))
		fill.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
