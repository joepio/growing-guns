class_name ColosseumBuilder
extends RefCounted

const CROWD_SHADER := preload("res://shaders/crowd.gdshader")

# A colossal spectator bowl wrapped around the whole castle arena: tiered
# stone stands rising well above the towers, packed with cheering crowds.
# Pure set dressing — no collision, no lights, and (by design) almost no cost:
# the entire structure is ONE MultiMesh of scaled unit boxes and the whole
# crowd is ONE MultiMesh of silhouette quads animated in the vertex shader.
# Two draw calls total, shadows off.
#
# Blackout: the stands use a lit StandardMaterial (global light crush darkens
# them) and the crowd shader multiplies by the world_light_dim global.

const SEGMENTS := 56
# Stepped seating like a real colosseum: many shallow rows, each raised above
# the one in front, one crowd row per step — every spectator visible from the
# arena floor instead of a few deep terraces hiding their back rows.
const ROWS := 18
const ROW_DEPTH := 2.2
const ROW_RISE := 1.4
const BACK_WALL_EXTRA := 6.0
# Facade (ground -> first row): tall enough to clear the arena walls' sightline
# when the arena HAS walls; low and approachable when it doesn't.
const BASE_ABOVE_WALLS := 2.5
const BASE_NO_WALLS := 4.5
const CROWD_SPACING := 0.9
const CROWD_MAX := 15000
const CROWD_SKIP_CHANCE := 0.08  # a few empty seats — full-to-the-brim reads fake

# Roman-era stone: each map rolls ONE quarry for the whole colosseum — warm
# sandstone or pale limestone — so the bowl reads as a single construction.
const SANDSTONE: Array[Color] = [
	Color(0.74, 0.61, 0.42),
	Color(0.70, 0.57, 0.40),
	Color(0.77, 0.65, 0.46),
]
# Dusty weathered limestone — sandy beige, not polished marble white.
const LIMESTONE: Array[Color] = [
	Color(0.72, 0.66, 0.53),
	Color(0.68, 0.63, 0.51),
	Color(0.75, 0.69, 0.56),
]

# Muted, undyed-cloth medieval tones — browns, greys, faded maroon/navy. The
# occasional richer color is rare on purpose; peasant crowds weren't confetti.
const CROWD_COLORS: Array[Color] = [
	Color(0.34, 0.27, 0.21),
	Color(0.30, 0.25, 0.19),
	Color(0.29, 0.29, 0.30),
	Color(0.24, 0.21, 0.18),
	Color(0.38, 0.31, 0.22),
	Color(0.36, 0.20, 0.17),
	Color(0.21, 0.24, 0.32),
	Color(0.31, 0.33, 0.24),
]
# ~1 in 12 wears something brighter (a merchant, a noble's servant).
const CROWD_ACCENTS: Array[Color] = [
	Color(0.55, 0.18, 0.14),
	Color(0.2, 0.3, 0.5),
	Color(0.55, 0.45, 0.2),
]

static var _person_mesh: ArrayMesh = null

# Roof ring: how much of the seating depth the canopy covers (from the back
# wall inward) and how far its inner lip drops below the outer edge.
const ROOF_COVER_FRAC := 0.5
const ROOF_DROP := 3.0
const LIGHT_TOWER_COUNT := 4


# Rounded-square (superellipse, n=4) plan: radius scale factor at a given
# ring angle. 1.0 on the side midpoints, ~1.19 at the corners — flat-ish
# sides with bulged corners, echoing the square arena floor below.
static func _sq(ang: float) -> float:
	var c := absf(cos(ang))
	var s := absf(sin(ang))
	return pow(c * c * c * c + s * s * s * s, -0.25)


static func build(
	parent: Node3D,
	rng: RandomNumberGenerator,
	arena_size: float,
	wall_height: float,
	stone: Color,
	has_perimeter_walls: bool = true,
) -> Node3D:
	var root := Node3D.new()
	root.name = "Colosseum"
	parent.add_child(root)

	var inner_r := arena_size * 0.82
	var base_y := wall_height + BASE_ABOVE_WALLS if has_perimeter_walls else BASE_NO_WALLS

	# Pick the map's quarry, keeping a hint of the arena palette so the bowl
	# still sits in each map's mood (hell maps stay a touch redder, etc.).
	var quarry := SANDSTONE if rng.randf() < 0.5 else LIMESTONE
	var roman: Color = quarry[rng.randi() % quarry.size()]
	_build_stands(root, inner_r, base_y, roman.lerp(stone, 0.22))
	var crowd_mat := _build_crowd(root, rng, inner_r, base_y)
	# Jumbotrons on the outer wall — live broadcast feed of the arena
	# (stadium_tv.gd). Skipped in editor previews like the crowd controller.
	if not Engine.is_editor_hint():
		var tvs := StadiumTV.new()
		tvs.name = "StadiumTVs"
		root.add_child(tvs)
		tvs.setup(
			inner_r,
			base_y,
			inner_r + float(ROWS) * ROW_DEPTH + 1.4,
			base_y + float(ROWS) * ROW_RISE + BACK_WALL_EXTRA,
		)
	# Hand the ring geometry + crowd material to the reaction system: bullets
	# and blasts landing in this band scare the crowd, kills make it roar, and
	# CrowdAudio drives the shader's excitement/panic uniforms. Editor preview
	# has no autoloads, so tool builds skip it.
	if not Engine.is_editor_hint():
		# Squircle plan: radius varies 1.0..~1.19 around the ring, so the
		# registered band spans min inner to max outer.
		CrowdAudio.register_ring(
			root,
			inner_r,
			(inner_r + float(ROWS) * ROW_DEPTH + 2.2) * 1.19,
			base_y,
			base_y + float(ROWS) * ROW_RISE + BACK_WALL_EXTRA,
			crowd_mat,
		)
		var ring_id := root.get_instance_id()
		root.tree_exited.connect(func() -> void: CrowdAudio.unregister_ring(ring_id))
	return root


static func _build_stands(root: Node3D, inner_r: float, base_y: float, stone: Color) -> void:
	var xforms: Array[Transform3D] = []
	var seg_ang := TAU / float(SEGMENTS)
	for i in SEGMENTS:
		var ang := seg_ang * (float(i) + 0.5)
		var s := _sq(ang)
		var dir := Vector3(cos(ang), 0.0, sin(ang))
		var yaw := -ang + PI * 0.5  # box X axis along the ring tangent
		# Facade: ground to the first tier, so the bowl doesn't float.
		var facade_r := (inner_r - 0.8) * s
		var facade_len := 2.0 * facade_r * tan(seg_ang * 0.5) + 0.8
		xforms.append(_box_xform(
			dir * facade_r + Vector3(0.0, base_y * 0.5, 0.0),
			Vector3(facade_len, base_y, 1.6), yaw))
		# Periodic columns proud of the facade — the repeating vertical
		# rhythm that makes the bowl read designed instead of extruded.
		if i % 2 == 0:
			var col_r := (inner_r - 2.0) * s
			xforms.append(_box_xform(
				dir * col_r + Vector3(0.0, base_y * 0.55, 0.0),
				Vector3(1.5, base_y * 1.1, 1.5), yaw))
			xforms.append(_box_xform(
				dir * col_r + Vector3(0.0, base_y * 1.1 + 0.6, 0.0),
				Vector3(2.3, 1.2, 2.3), yaw))
		for row in ROWS:
			# One box per step: its top is the seating surface, its front face
			# is the riser to the row below.
			var r_mid := (inner_r + (float(row) + 0.5) * ROW_DEPTH) * s
			var seg_len := 2.0 * (r_mid + ROW_DEPTH * 0.5) * tan(seg_ang * 0.5) + 0.8
			var top_y := base_y + float(row) * ROW_RISE
			var step_h := ROW_RISE + 0.6
			xforms.append(_box_xform(
				dir * r_mid + Vector3(0.0, top_y - step_h * 0.5, 0.0),
				Vector3(seg_len, step_h, ROW_DEPTH + 0.15), yaw))
		# Towering outer wall behind the top row — the stadium silhouette.
		var wall_r := (inner_r + float(ROWS) * ROW_DEPTH + 1.4) * s
		var wall_h := base_y + float(ROWS) * ROW_RISE + BACK_WALL_EXTRA
		var wall_len := 2.0 * wall_r * tan(seg_ang * 0.5) + 0.9
		xforms.append(_box_xform(
			dir * wall_r + Vector3(0.0, wall_h * 0.5, 0.0),
			Vector3(wall_len, wall_h, 2.2), yaw))
		# Crenellation block on every other segment's rim.
		if i % 2 == 0:
			xforms.append(_box_xform(
				dir * wall_r + Vector3(0.0, wall_h + 1.1, 0.0),
				Vector3(wall_len * 0.55, 2.2, 2.2), yaw))

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = BoxMesh.new()
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Stands"
	mmi.multimesh = mm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = stone
	mat.roughness = 1.0
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mmi)
	_build_roof(root, inner_r, base_y, stone)
	_build_light_towers(root, inner_r, base_y)
	_build_collision(root, inner_r, base_y)


# Partial canopy over the upper rows — outer edge on the back wall, inner lip
# hanging over roughly the back half of the seating. Its own MultiMesh with
# cast_shadow ON (the only colosseum piece that casts): the sun genuinely
# stops at the roof line, shading the upper crowd like the reference bowls.
static func _build_roof(root: Node3D, inner_r: float, base_y: float, stone: Color) -> void:
	var seg_ang := TAU / float(SEGMENTS)
	var roof_len := float(ROWS) * ROW_DEPTH * ROOF_COVER_FRAC
	var wall_h := base_y + float(ROWS) * ROW_RISE + BACK_WALL_EXTRA
	var pitch := atan2(ROOF_DROP, roof_len)  # inner lip dips toward the arena
	var xforms: Array[Transform3D] = []
	for i in SEGMENTS:
		var ang := seg_ang * (float(i) + 0.5)
		var s := _sq(ang)
		var dir := Vector3(cos(ang), 0.0, sin(ang))
		var yaw := -ang + PI * 0.5
		var mid_r := (inner_r + float(ROWS) * ROW_DEPTH - roof_len * 0.5 + 1.0) * s
		var seg_len := 2.0 * (mid_r + roof_len * 0.5) * tan(seg_ang * 0.5) + 0.9
		var mid_y := wall_h + 0.6 - ROOF_DROP * 0.5
		xforms.append(Transform3D(
			Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, -pitch)
				* Basis.from_scale(Vector3(seg_len, 0.5, roof_len)),
			dir * mid_r + Vector3(0.0, mid_y, 0.0)))
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = BoxMesh.new()
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Roof"
	mmi.multimesh = mm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = stone * 0.75  # underside reads shaded even unlit
	mat.roughness = 1.0
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	root.add_child(mmi)


# Floodlight towers on the four squircle corners: a shaft up past the roof
# line, an emissive light bank leaning over the bowl, and a real (shadowless)
# SpotLight3D aimed at the arena floor — the stage reads lit, and the banks
# stay glowing through blackout rounds like the jumbotrons do.
static func _build_light_towers(root: Node3D, inner_r: float, base_y: float) -> void:
	var wall_h := base_y + float(ROWS) * ROW_RISE + BACK_WALL_EXTRA
	var tower_h := wall_h + 9.0
	var shaft_mat := StandardMaterial3D.new()
	shaft_mat.albedo_color = Color(0.16, 0.16, 0.18)
	shaft_mat.roughness = 0.8
	var bank_mat := StandardMaterial3D.new()
	bank_mat.albedo_color = Color(0.95, 0.93, 0.85)
	bank_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bank_mat.emission_enabled = true
	bank_mat.emission = Color(1.0, 0.96, 0.85)
	bank_mat.emission_energy_multiplier = 2.6
	for i in LIGHT_TOWER_COUNT:
		var ang := TAU * (float(i) + 0.5) / float(LIGHT_TOWER_COUNT)  # corners
		var s := _sq(ang)
		var dir := Vector3(cos(ang), 0.0, sin(ang))
		var r := (inner_r + float(ROWS) * ROW_DEPTH * 0.72) * s
		var shaft := MeshInstance3D.new()
		var sbox := BoxMesh.new()
		sbox.size = Vector3(2.0, tower_h, 2.0)
		shaft.mesh = sbox
		shaft.material_override = shaft_mat
		shaft.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		shaft.position = dir * r + Vector3(0.0, tower_h * 0.5, 0.0)
		root.add_child(shaft)
		var bank := MeshInstance3D.new()
		var bbox := BoxMesh.new()
		bbox.size = Vector3(6.0, 3.2, 0.6)
		bank.mesh = bbox
		bank.material_override = bank_mat
		bank.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		bank.position = dir * (r - 2.2) + Vector3(0.0, tower_h + 1.2, 0.0)
		# Face the arena (+Z toward center), leaning over the bowl. Built
		# while the arena is still outside the tree, so no look_at here.
		bank.basis = Basis.looking_at(dir, Vector3.UP).rotated(dir.cross(Vector3.UP).normalized(), -0.5)
		root.add_child(bank)
		if not Engine.is_editor_hint():
			var spot := SpotLight3D.new()
			spot.position = bank.position
			spot.spot_range = r + 30.0
			spot.spot_angle = 32.0
			spot.light_energy = 3.0
			spot.light_color = Color(1.0, 0.96, 0.86)
			spot.shadow_enabled = false
			spot.light_specular = 0.2
			# Aim at the arena floor center (spot emits along -Z).
			spot.basis = Basis.looking_at((Vector3.ZERO - spot.position).normalized(), Vector3.UP)
			root.add_child(spot)


# Physics so shots LAND in the stands instead of flying through the crowd
# forever: per segment, one sloped slab over the seating (the stair envelope),
# the facade front, and the outer back wall. Static, on the world layer —
# bullets detonate on it, and CrowdAudio/ColosseumCrowd take it from there.
static func _build_collision(root: Node3D, inner_r: float, base_y: float) -> void:
	var body := StaticBody3D.new()
	body.name = "StandsBody"
	# bullet.gd reports stand hits to CrowdAudio/ColosseumCrowd off this tag.
	body.set_meta("colosseum_stands", true)
	var seg_ang := TAU / float(SEGMENTS)
	var slope_len := Vector2(float(ROWS) * ROW_DEPTH, float(ROWS) * ROW_RISE).length()
	var pitch := atan2(ROW_RISE, ROW_DEPTH)
	var slab_r := inner_r + float(ROWS) * ROW_DEPTH * 0.5
	var wall_r := inner_r + float(ROWS) * ROW_DEPTH + 1.4
	var wall_h := base_y + float(ROWS) * ROW_RISE + BACK_WALL_EXTRA
	for i in SEGMENTS:
		var ang := seg_ang * (float(i) + 0.5)
		var s := _sq(ang)
		var dir := Vector3(cos(ang), 0.0, sin(ang))
		var yaw := -ang + PI * 0.5
		var outer_len := 2.0 * wall_r * s * tan(seg_ang * 0.5) + 0.9
		# Seating slope: box local X = tangent, tilted so +Z (radial) rises.
		var slab := CollisionShape3D.new()
		var slab_shape := BoxShape3D.new()
		slab_shape.size = Vector3(outer_len, 1.0, slope_len)
		slab.shape = slab_shape
		slab.transform = Transform3D(
			Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, -pitch),
			dir * (slab_r * s) + Vector3(0.0, base_y + float(ROWS) * ROW_RISE * 0.5 - 0.5, 0.0))
		body.add_child(slab)
		# Facade front (ground -> first row).
		var facade := CollisionShape3D.new()
		var facade_shape := BoxShape3D.new()
		facade_shape.size = Vector3(outer_len, base_y, 1.6)
		facade.shape = facade_shape
		facade.transform = Transform3D(
			Basis(Vector3.UP, yaw),
			dir * ((inner_r - 0.8) * s) + Vector3(0.0, base_y * 0.5, 0.0))
		body.add_child(facade)
		# Outer back wall — nothing escapes the stadium.
		var wall := CollisionShape3D.new()
		var wall_shape := BoxShape3D.new()
		wall_shape.size = Vector3(outer_len, wall_h, 2.2)
		wall.shape = wall_shape
		wall.transform = Transform3D(
			Basis(Vector3.UP, yaw),
			dir * (wall_r * s) + Vector3(0.0, wall_h * 0.5, 0.0))
		body.add_child(wall)
	root.add_child(body)


static func _build_crowd(root: Node3D, rng: RandomNumberGenerator, inner_r: float, base_y: float) -> ShaderMaterial:
	var seg_ang := TAU / float(SEGMENTS)
	# (position, yaw) built first so the instance count is known up front.
	# Segment ids ride along so ColosseumCrowd can bucket kill lookups.
	var seats: Array[Transform3D] = []
	var seat_segments := PackedInt32Array()
	for i in SEGMENTS:
		var ang := seg_ang * (float(i) + 0.5)
		for row in ROWS:
			var y := base_y + float(row) * ROW_RISE
			var row_r := inner_r + (float(row) + 0.45) * ROW_DEPTH
			var arc_len := row_r * _sq(ang) * seg_ang
			var count := int(arc_len / CROWD_SPACING)
			for k in count:
				if rng.randf() < CROWD_SKIP_CHANCE:
					continue
				var a := ang + (float(k) + 0.5) / float(count) * seg_ang - seg_ang * 0.5
				a += rng.randf_range(-0.15, 0.15) / maxf(row_r, 1.0)
				var r := row_r * _sq(a)
				var pos := Vector3(cos(a) * r, y, sin(a) * r)
				pos += Vector3(rng.randf_range(-0.15, 0.15), 0.0, rng.randf_range(-0.25, 0.25))
				# Figure +Z faces the arena centre.
				var yaw := -a - PI * 0.5
				var scale := rng.randf_range(1.5, 1.85)  # unit mesh -> person height in metres
				var basis := Basis(Vector3.UP, yaw) * Basis.from_scale(Vector3.ONE * scale)
				seats.append(Transform3D(basis, pos))
				seat_segments.append(i)
				if seats.size() >= CROWD_MAX:
					break
			if seats.size() >= CROWD_MAX:
				break
		if seats.size() >= CROWD_MAX:
			break

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = _get_person_mesh()
	mm.instance_count = seats.size()
	for i in seats.size():
		mm.set_instance_transform(i, seats[i])
		var col: Color
		if rng.randf() < 0.08:
			col = CROWD_ACCENTS[rng.randi() % CROWD_ACCENTS.size()]
		else:
			col = CROWD_COLORS[rng.randi() % CROWD_COLORS.size()]
		mm.set_instance_color(i, col)
		# ~30% sit still (hop 0); the rest bounce with individual tempo/phase.
		var hop := 0.0 if rng.randf() < 0.3 else rng.randf_range(0.15, 0.42)
		mm.set_instance_custom_data(i, Color(
			rng.randf(), rng.randf(), hop, rng.randf()))
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Crowd"
	mmi.multimesh = mm
	var mat := ShaderMaterial.new()
	mat.shader = CROWD_SHADER
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The crowd controller owns the MultiMesh and handles kills + gore; the
	# editor preview skips it (no CrowdAudio to forward events anyway).
	if Engine.is_editor_hint():
		root.add_child(mmi)
		return mat
	var controller := ColosseumCrowd.new()
	controller.name = "CrowdController"
	controller.crowd_mat = mat
	var positions := PackedVector3Array()
	positions.resize(seats.size())
	for i in seats.size():
		positions[i] = seats[i].origin
	controller.setup(
		mm, positions, seat_segments, SEGMENTS,
		inner_r, base_y, ROW_DEPTH, ROW_RISE, ROWS)
	controller.add_child(mmi)
	root.add_child(controller)
	return mat


# Tiny 3D spectator, ~48 tris: torso, head, two arms. Unit-height (1.0 = head
# top), feet at y=0; instances scale it to person height. UV2 tags vertices for
# the shader: x = arm (cheer-raised), y = head (skin tint). Built once, cached.
static func _get_person_mesh() -> ArrayMesh:
	if _person_mesh != null:
		return _person_mesh
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Torso: shoulders to a slightly wider hem at the feet would need a taper —
	# a plain box reads identically past 20 m.
	_st_box(st, Vector3(0.0, 0.31, 0.0), Vector3(0.30, 0.62, 0.19), Vector2(0.0, 0.0))
	# Head.
	_st_box(st, Vector3(0.0, 0.78, 0.0), Vector3(0.22, 0.24, 0.20), Vector2(0.0, 1.0))
	# Arms, hanging at the sides; the shader raises them by the UV2.x tag.
	_st_box(st, Vector3(-0.21, 0.44, 0.0), Vector3(0.09, 0.34, 0.10), Vector2(1.0, 0.0))
	_st_box(st, Vector3(0.21, 0.44, 0.0), Vector3(0.09, 0.34, 0.10), Vector2(1.0, 0.0))
	_person_mesh = st.commit()
	return _person_mesh


# Axis-aligned box with per-face normals and a uniform UV2 tag on every vertex.
static func _st_box(st: SurfaceTool, center: Vector3, size: Vector3, tag: Vector2) -> void:
	var h := size * 0.5
	# Each face: normal + 4 corners (CCW seen from outside) as two triangles.
	var faces := [
		[Vector3.RIGHT, Vector3(h.x, -h.y, -h.z), Vector3(h.x, h.y, -h.z), Vector3(h.x, h.y, h.z), Vector3(h.x, -h.y, h.z)],
		[Vector3.LEFT, Vector3(-h.x, -h.y, h.z), Vector3(-h.x, h.y, h.z), Vector3(-h.x, h.y, -h.z), Vector3(-h.x, -h.y, -h.z)],
		[Vector3.UP, Vector3(-h.x, h.y, -h.z), Vector3(-h.x, h.y, h.z), Vector3(h.x, h.y, h.z), Vector3(h.x, h.y, -h.z)],
		[Vector3.DOWN, Vector3(-h.x, -h.y, h.z), Vector3(-h.x, -h.y, -h.z), Vector3(h.x, -h.y, -h.z), Vector3(h.x, -h.y, h.z)],
		[Vector3.BACK, Vector3(-h.x, -h.y, h.z), Vector3(h.x, -h.y, h.z), Vector3(h.x, h.y, h.z), Vector3(-h.x, h.y, h.z)],
		[Vector3.FORWARD, Vector3(h.x, -h.y, -h.z), Vector3(-h.x, -h.y, -h.z), Vector3(-h.x, h.y, -h.z), Vector3(h.x, h.y, -h.z)],
	]
	for f: Array in faces:
		var n: Vector3 = f[0]
		st.set_normal(n)
		st.set_uv2(tag)
		# Corners are listed CCW-from-outside; Godot front faces wind CW, so
		# emit each triangle reversed or the boxes render inside-out.
		for idx in [1, 3, 2, 1, 4, 3]:
			st.add_vertex(center + (f[idx] as Vector3))


static func _box_xform(pos: Vector3, size: Vector3, yaw: float) -> Transform3D:
	# Scale on LOCAL axes (rotate * scale), so box length follows the ring
	# tangent — Basis.scaled() would scale on global axes and skew the box.
	return Transform3D(Basis(Vector3.UP, yaw) * Basis.from_scale(size), pos)
