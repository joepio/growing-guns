@tool
class_name DemonGrowth
extends Node3D

# Living-gun growth layer — PROTOTYPE (preview via scenes/flesh_lab.tscn).
#
# Decorates a ProceduralGun with flesh, bone and an eye. `corruption` (0..1)
# drives how overgrown the gun is: at 0 the gun is clean metal, at 1 it's an
# animal wearing a rifle as a skeleton. The intended game mapping is
# corruption ∝ how far the Weapon has mutated from stock (i.e. cards picked),
# so the gun literally comes alive as it grows — see corruption_from_weapon().
#
# Growth is CONTINUOUS, not staged: every part has its own sprout point and
# emergence ramp (_emerge), so each card sprouts a lump or two and swells the
# ones already there. Rough order of appearance as corruption climbs:
# receiver lumps → barrel sheath / mag throat → bone spine → eye →
# gums + teeth → tendons. Full demon lands around 12 cards.
#
# This node must be a SIBLING of the gun (same parent, same transform), not a
# child: ProceduralGun._rebuild() frees all of its own children on every stat
# change and would take our meshes with it. Placement math below mirrors the
# defaults/derivations in procedural_gun.gd's _rebuild — acceptable
# duplication for a prototype; fold into the builder if we adopt this.

const FLESH_SHADER := preload("res://shaders/gun_flesh.gdshader")

@export_range(0.0, 1.0) var corruption: float = 0.5 : set = _set_corruption
@export var gun_path: NodePath

var _rng := RandomNumberGenerator.new()
var _flesh_mat: ShaderMaterial = null
var _bone_mat: StandardMaterial3D = null

# Eye animation state. The pupil wanders on a random-walk (retarget at random
# intervals, exponential chase) — deliberately NOT a periodic sweep, which
# reads as a surveillance camera instead of a creature.
var _eye_root: Node3D = null
var _iris: MeshInstance3D = null
var _pupil: MeshInstance3D = null
var _lid: MeshInstance3D = null
var _eye_r: float = 0.03
# Default gaze: out of the eye's (+X) side, tilted back toward the wielder —
# reads as an eye from frame one, and "it watches you" is the right flavor.
var _look_current := Vector3(0.75, 0.1, 0.45).normalized()
var _look_target := Vector3(0.75, 0.1, 0.45).normalized()
var _next_look: float = 1.0
var _blink: float = 0.0        # 0 open .. 1 closed
var _blink_phase: float = -1.0 # <0 idle, else progresses 0..1 over blink
var _next_blink: float = 2.5

# Corruption tween (card-pick growth moment) — steps the corruption setter at
# a bounded cadence; the seeded layout means each rebuild grows the same
# creature in place rather than reshuffling parts.
var _anim_from: float = 0.0
var _anim_to: float = 0.0
var _anim_elapsed: float = -1.0  # <0 = idle
var _anim_duration: float = 2.0
var _anim_next: float = 0.0
const ANIM_APPLY_INTERVAL := 1.0 / 20.0

# --- Rebuild-invariant resource caches (static, process-wide) --------------
# The growth morph rebuilds at 20 Hz during the card-pick cage descent, and
# creating fresh meshes/materials every pass churned GPU buffer uploads hard
# enough to visibly hitch the gun (and ~100ms on the big pick-time jump).
# Flesh lumps are baked ONCE per variant at a reference radius and sized via
# node scale, so the morph never touches lump mesh data at all; the remaining
# quantized-key caches (cones, eye spheres) hit ~100% after the first build.
static var _shared_flesh_mat: ShaderMaterial = null
static var _shared_bone_mat: StandardMaterial3D = null
static var _mesh_cache: Dictionary = {}
static var _eye_mat_cache: Dictionary = {}

# Lump meshes: noise-displaced spheres — the organic silhouette that stock
# SphereMesh squashing never achieved. A handful of baked variants gets
# reused everywhere at different scales/rotations, which reads as endless
# variety at zero per-rebuild cost.
const LUMP_REF_R := 0.03
const LUMP_VARIANT_COUNT := 6
static var _lump_variants: Array = []


static func _cached_lump(variant: int) -> ArrayMesh:
	if _lump_variants.is_empty():
		_lump_variants.resize(LUMP_VARIANT_COUNT)
	var vi: int = posmod(variant, LUMP_VARIANT_COUNT)
	if _lump_variants[vi] == null:
		_lump_variants[vi] = _build_lump_mesh(vi)
	return _lump_variants[vi]


# Baked once per variant at LUMP_REF_R; callers scale the node instead, so
# the 20 Hz growth morph never regenerates or re-uploads mesh data. UVs are
# dropped on purpose: the flesh shader is UV-free, and without them
# SurfaceTool.index() welds the sphere's UV-seam/pole duplicates so the
# smoothed normals have no crease.
static func _build_lump_mesh(variant: int) -> ArrayMesh:
	var sm := SphereMesh.new()
	sm.radius = LUMP_REF_R
	sm.height = LUMP_REF_R * 2.0
	sm.radial_segments = 18
	sm.rings = 10
	var arrays := sm.get_mesh_arrays()
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.seed = 7000 + variant
	# Wavelength ~ sphere radius → 2-4 fat lobes per lump, not spiky crackle.
	noise.frequency = 1.1
	for i in verts.size():
		var d := verts[i] / LUMP_REF_R
		var n := noise.get_noise_3dv(d) + 0.5 * noise.get_noise_3dv(d * 2.6 + Vector3(13.1, 7.7, 3.3))
		# Asymmetric clamp — bulging outward more than denting in reads as
		# tissue pushing through gaps rather than a deflated balloon.
		verts[i] = verts[i] * (1.0 + clampf(0.55 * n, -0.3, 0.45))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in idx.size():
		st.add_vertex(verts[idx[i]])
	st.index()
	st.generate_normals()
	return st.commit()


static func _cached_sphere(r: float, height: float = -1.0) -> SphereMesh:
	var h := height if height > 0.0 else r * 2.0
	var key := ["s", snappedf(r, 0.0005), snappedf(h, 0.0005)]
	var m: SphereMesh = _mesh_cache.get(key)
	if m == null:
		m = SphereMesh.new()
		m.radius = r
		m.height = h
		_mesh_cache[key] = m
	return m


static func _cached_cone(r: float, h: float) -> CylinderMesh:
	var key := ["c", snappedf(r, 0.0005), snappedf(h, 0.0005)]
	var m: CylinderMesh = _mesh_cache.get(key)
	if m == null:
		m = CylinderMesh.new()
		m.top_radius = 0.0
		m.bottom_radius = r
		m.height = h
		m.radial_segments = 6
		_mesh_cache[key] = m
	return m


static func _cached_capsule(r: float, h: float) -> CapsuleMesh:
	var key := ["t", snappedf(r, 0.0005), snappedf(h, 0.0005)]
	var m: CapsuleMesh = _mesh_cache.get(key)
	if m == null:
		m = CapsuleMesh.new()
		m.radius = r
		m.height = h
		_mesh_cache[key] = m
	return m


static func _cached_eye_mat(col: Color, emission_energy: float, rough: float) -> StandardMaterial3D:
	var key := ["em", col.to_rgba32(), snappedf(emission_energy, 0.01), snappedf(rough, 0.01)]
	var m: StandardMaterial3D = _eye_mat_cache.get(key)
	if m == null:
		m = StandardMaterial3D.new()
		m.albedo_color = col
		m.roughness = rough
		if emission_energy > 0.0:
			m.emission_enabled = true
			m.emission = col
			m.emission_energy_multiplier = emission_energy
		_eye_mat_cache[key] = m
	return m


func _set_corruption(v: float) -> void:
	corruption = clampf(v, 0.0, 1.0)
	if is_inside_tree():
		rebuild()

func _ready() -> void:
	rebuild()

# Map "how mutated is this weapon vs stock" onto 0..1. CARD COUNT is the
# pacing driver — the demon takes ~12 rounds of losing to fully grow, so two
# cards mean a few subtle lumps, not a monster. Stats only season it (a
# heavy explosive build reads a little meaner a little earlier); the
# seasoning is capped so no single card jumps ahead.
static func corruption_from_weapon(w: Weapon) -> float:
	if w == null:
		return 0.0
	var cards: float = float(w.applied_cards.size())
	var d: float = 0.0
	d += absf(w.damage_mult - 1.0) * 0.1
	d += absf(w.fire_rate_mult - 1.0) * 0.07
	d += absf(w.bullet_scale - 1.0) * 0.1
	d += float(w.extra_projectiles) * 0.06
	if w.explosive_radius > 0.0:
		d += 0.1
	return clampf(cards / 12.0 + minf(d, 0.12), 0.0, 1.0)


# 0→1 ramp as corruption passes a part's sprout point. Every part gets its
# own start, so cards trickle new growth in instead of popping whole stages.
static func _emerge(c: float, start: float, span: float = 0.15) -> float:
	return smoothstep(start, start + span, c)


func rebuild() -> void:
	var _pt := Time.get_ticks_usec() if Trace.enabled else 0
	_rebuild_body()
	if Trace.enabled:
		Trace.prof("growth", Time.get_ticks_usec() - _pt)


func _rebuild_body() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_eye_root = null
	_iris = null
	_pupil = null
	_lid = null

	var gun = get_node_or_null(gun_path)
	if gun == null or corruption <= 0.01:
		return
	# Deterministic layout: same corruption → same growth pattern. Every part
	# draws ALL its rng params BEFORE its emergence check, so low corruption
	# renders a strict subset of the full-demon layout — cards make the demon
	# *grow*, not reshuffle.
	_rng.seed = 0xF1E5
	if _shared_flesh_mat == null:
		_shared_flesh_mat = ShaderMaterial.new()
		_shared_flesh_mat.shader = FLESH_SHADER
		_shared_bone_mat = StandardMaterial3D.new()
		_shared_bone_mat.albedo_color = Color(0.7, 0.62, 0.48)
		_shared_bone_mat.roughness = 0.7
		_shared_bone_mat.diffuse_mode = BaseMaterial3D.DIFFUSE_TOON
		_shared_bone_mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	_flesh_mat = _shared_flesh_mat
	_bone_mat = _shared_bone_mat

	var c: float = corruption
	var rs: Vector3 = gun.get("receiver_size")
	# The gun widens its receiver to wrap multi-barrel layouts — the built
	# Receiver mesh carries that effective size. Growths must hug the real
	# surface, not the nominal stat block, or they end up buried in metal.
	var recv := gun.get_node_or_null("Receiver") as MeshInstance3D
	if recv != null and recv.mesh is BoxMesh:
		rs = (recv.mesh as BoxMesh).size
	var barrel_len: float = gun.get("barrel_length")
	var barrel_r: float = gun.get("barrel_radius")
	var muzzle_flare: float = gun.get("muzzle_flare")
	var mag_size: Vector3 = gun.get("mag_size")
	var mag_offset_z: float = gun.get("mag_offset_z")
	var receiver_front_z: float = -rs.z * 0.5
	var muzzle_exit: Vector3 = gun.call("get_muzzle_exit_local")

	# --- Flesh lumps clinging to the receiver faces (from card 1) ---
	# Fixed pool with staggered sprout points spanning the whole corruption
	# range: each card sprouts a lump or two and swells the older ones.
	for i in 12:
		var side: float = -1.0 if _rng.randf() < 0.5 else 1.0
		var on_bottom: bool = _rng.randf() < 0.3
		var r_full: float = _rng.randf_range(0.02, 0.048)
		var px: float = _rng.randf_range(-rs.x * 0.3, rs.x * 0.3)
		var py: float = _rng.randf_range(-rs.y * 0.35, rs.y * 0.35)
		var pz: float = _rng.randf_range(-rs.z * 0.42, rs.z * 0.42)
		var spin: float = _rng.randf_range(0.0, TAU)
		# Flattened against the surface, elongated in a random tangent
		# direction (via spin) — smeared tissue, not a marble.
		var squash := Vector3(_rng.randf_range(0.45, 0.65),
			_rng.randf_range(0.85, 1.25), _rng.randf_range(0.9, 1.6))
		var variant: int = _rng.randi_range(0, LUMP_VARIANT_COUNT - 1)
		var phase: float = _rng.randf_range(0.0, 8.0)
		var start: float = 0.02 + 0.075 * float(i) + _rng.randf_range(-0.02, 0.02)
		var e := _emerge(c, start)
		if e <= 0.01:
			continue
		var r := r_full * lerpf(0.3, 1.0, e)
		var out_dir := Vector3(side, 0, 0)
		var pos := Vector3(side * rs.x * 0.5, py, pz)
		if on_bottom:
			out_dir = Vector3(0, -1, 0)
			pos = Vector3(px, -rs.y * 0.5, pz)
		_add_lump("Blob%d" % i, variant, r, pos, out_dir, squash, spin, phase)

	# --- Muscle sheath creeping down the barrel (from ~card 3-4) ---
	# Lumps hug whatever surface is actually there at that depth — shroud
	# box, minigun bundle, or the bare barrel row — at scattered angles;
	# never centred on the bore axis. Covered length creeps toward the
	# muzzle as corruption rises.
	var n_barrels: int = maxi(1, int(gun.get("barrel_count")))
	var has_shroud: bool = gun.get("has_shroud")
	var is_minigun: bool = gun.get("is_minigun")
	var shroud_len: float = barrel_len * clampf(float(gun.get("shroud_length_frac")), 0.05, 0.95) if has_shroud else 0.0
	var shroud_hx: float = maxf(float(gun.get("shroud_extent")), barrel_r + 0.012) + 0.004
	var shroud_hy: float = barrel_r + 0.016
	var row_hx: float = barrel_r * 2.4 * float(n_barrels - 1) * 0.5 + barrel_r
	var bundle_hug: float = barrel_r * 1.8 + barrel_r
	var cover: float = barrel_len * (0.15 + 0.6 * c)
	for j in 8:
		var t: float = float(j) / 7.0
		var ang: float = _rng.randf_range(0.55, TAU - 0.55)  # 0 = straight up; keep off the sight line
		var lump_r_full: float = barrel_r * _rng.randf_range(1.1, 1.9)
		var spin2: float = _rng.randf_range(-0.4, 0.4)  # small — keep the long axis along the barrel
		var variant2: int = _rng.randi_range(0, LUMP_VARIANT_COUNT - 1)
		var phase2: float = _rng.randf_range(0.0, 8.0)
		var zj: float = _rng.randf_range(-0.012, 0.012)
		var start2: float = 0.24 + 0.06 * float(j)
		var e2 := _emerge(c, start2)
		if e2 <= 0.01:
			continue
		var depth: float = cover * t
		var dir := Vector3(sin(ang), cos(ang), 0.0)
		var hug: float
		if has_shroud and depth < shroud_len:
			# Box shroud ≈ ellipse with the shroud's half-extents.
			hug = shroud_hx * shroud_hy / sqrt(pow(shroud_hy * dir.x, 2.0) + pow(shroud_hx * dir.y, 2.0))
		elif is_minigun:
			hug = bundle_hug
		else:
			hug = row_hx * barrel_r / sqrt(pow(barrel_r * dir.x, 2.0) + pow(row_hx * dir.y, 2.0))
		var lr := lump_r_full * lerpf(0.35, 1.0, e2)
		var pos2 := dir * (hug - lr * 0.15) + Vector3(0, 0, receiver_front_z - depth + zj)
		_add_lump("Sheath%d" % j, variant2, lr, pos2, dir, Vector3(0.55, 0.95, 1.6), spin2, phase2)

	# --- Connective mass swallowing the magazine (from ~card 4) ---
	# Hugs the mag's side faces where it meets the receiver, so the mag reads
	# swallowed rather than bolted on.
	for k in 2:
		var side3: float = -1.0 if k == 0 else 1.0
		var r3_full: float = mag_size.y * _rng.randf_range(0.22, 0.3)
		var spin3: float = _rng.randf_range(-0.4, 0.4)
		var variant3: int = _rng.randi_range(0, LUMP_VARIANT_COUNT - 1)
		var phase3: float = _rng.randf_range(0.0, 8.0)
		var start3: float = 0.3 + 0.08 * float(k)
		var e3 := _emerge(c, start3)
		if e3 <= 0.01:
			continue
		var r3 := r3_full * lerpf(0.35, 1.0, e3)
		var pos3 := Vector3(side3 * mag_size.x * 0.5, -rs.y * 0.5 - mag_size.y * 0.2, mag_offset_z)
		_add_lump("Throat%d" % k, variant3, r3, pos3, Vector3(side3, 0, 0), Vector3(0.5, 1.4, 0.9), spin3, phase3)

	# --- Bone spine along the top rail (from ~card 4-5) ---
	# Grows back-to-front, each vertebra swelling in on its own ramp; per-
	# spike length jitter so the ridge reads grown, not manufactured.
	for i in 9:
		var t2: float = float(i) / 8.0
		var hj: float = _rng.randf_range(0.75, 1.25)
		var tilt_x: float = _rng.randf_range(-0.15, 0.35)
		var tilt_z: float = _rng.randf_range(-0.12, 0.12)
		var start4: float = 0.34 + 0.05 * float(i) + _rng.randf_range(-0.015, 0.015)
		var e4 := _emerge(c, start4)
		if e4 <= 0.01:
			continue
		var z2: float = lerpf(rs.z * 0.42, receiver_front_z - barrel_len * 0.3 * c, t2)
		var h: float = lerpf(0.055, 0.02, t2) * hj * (0.6 + 0.5 * c) * lerpf(0.25, 1.0, e4)
		# Ride the actual top surface: rail over the receiver, then drop to
		# the shroud/barrel once the ridge creeps past the receiver front.
		var surf_y: float = rs.y * 0.5 + 0.02
		if z2 < receiver_front_z:
			var over_shroud := has_shroud and (receiver_front_z - z2) < shroud_len
			surf_y = shroud_hy if over_shroud else (bundle_hug if is_minigun else barrel_r)
		var spike := _add_cone("Spike%d" % i, (0.005 + 0.007 * c) * lerpf(0.5, 1.0, e4), h,
			Vector3(0, surf_y - 0.002 + h * 0.5, z2), _bone_mat)
		spike.rotation = Vector3(tilt_x, 0, tilt_z)

	# --- The eye (from ~card 7) ---
	# Right (+X) side: the flank the inspect pose turns toward the camera
	# (the muzzle yaws LEFT during the card-growth moment). Socket flesh
	# swells first; the eyeball scales in shortly after.
	_eye_r = lerpf(0.022, 0.04, c)
	var eye_pos := Vector3(rs.x * 0.5 + _eye_r * 0.55, rs.y * 0.18, -rs.z * 0.1)
	var socket_spin: float = _rng.randf_range(0.0, TAU)
	var socket_var: int = _rng.randi_range(0, LUMP_VARIANT_COUNT - 1)
	var socket_phase: float = _rng.randf_range(0.0, 8.0)
	var lid_phase: float = _rng.randf_range(0.0, 8.0)
	var se := _emerge(c, 0.48, 0.12)
	if se > 0.01:
		_add_lump("Socket", socket_var, _eye_r * 1.5 * lerpf(0.35, 1.0, se),
			eye_pos + Vector3(-_eye_r * 0.45, 0, 0), Vector3(1, 0, 0),
			Vector3(0.7, 1.1, 1.1), socket_spin, socket_phase)
	var ee := _emerge(c, 0.56, 0.1)
	if ee > 0.01:
		_eye_root = Node3D.new()
		_eye_root.name = "Eye"
		_eye_root.position = eye_pos
		_eye_root.scale = Vector3.ONE * lerpf(0.35, 1.0, ee)
		add_child(_eye_root)
		var sclera := MeshInstance3D.new()
		sclera.name = "Sclera"
		sclera.mesh = _cached_sphere(_eye_r)
		# Bloodshot, not porcelain.
		sclera.material_override = _cached_eye_mat(Color(0.5, 0.3, 0.22), 0.0, 0.08)
		_eye_root.add_child(sclera)
		_iris = _make_eye_disc("Iris", _eye_r * 0.62, Color(1.0, 0.55, 0.1), 2.2)
		_pupil = _make_eye_disc("Pupil", _eye_r * 0.26, Color(0.02, 0.0, 0.0), 0.0)
		# Lid: flesh-covered sphere slice parked above the eye; blink slides
		# it down over the sclera (animated in _process).
		_lid = MeshInstance3D.new()
		_lid.name = "Lid"
		_lid.mesh = _cached_sphere(_eye_r * 1.12)
		_lid.material_override = _flesh_mat
		_lid.set_instance_shader_parameter("phase", lid_phase)
		_eye_root.add_child(_lid)
		_apply_eye_pose()

	# --- Gums + teeth ringing the muzzle (from ~card 8) ---
	# Gum lumps hug the muzzle rim (not a bore-centred ball); teeth arrive
	# one by one behind them.
	var ring_r: float = maxf(barrel_r * muzzle_flare * 1.05, barrel_r * 1.5)
	for g in 6:
		var gang: float = TAU * float(g) / 6.0 + _rng.randf_range(-0.2, 0.2)
		var gr_full: float = ring_r * _rng.randf_range(0.5, 0.7)
		var gspin: float = _rng.randf_range(-0.5, 0.5)
		var gvar: int = _rng.randi_range(0, LUMP_VARIANT_COUNT - 1)
		var gphase: float = _rng.randf_range(0.0, 8.0)
		var gstart: float = 0.6 + 0.025 * float(g)
		var ge := _emerge(c, gstart, 0.12)
		if ge <= 0.01:
			continue
		var gdir := Vector3(cos(gang), sin(gang), 0.0)
		var gr := gr_full * lerpf(0.35, 1.0, ge)
		_add_lump("Gum%d" % g, gvar, gr, gdir * ring_r * 0.9 + Vector3(0, 0, muzzle_exit.z + 0.015),
			gdir, Vector3(0.7, 1.0, 0.55), gspin, gphase)
	for i in 10:
		var ang2: float = TAU * float(i) / 10.0 + _rng.randf_range(-0.1, 0.1)
		var tstart: float = 0.64 + _rng.randf_range(0.0, 0.22)
		var te := _emerge(c, tstart, 0.12)
		if te <= 0.01:
			continue
		var tooth_len: float = (0.024 + 0.03 * c) * lerpf(0.3, 1.0, te)
		var radial := Vector3(cos(ang2), sin(ang2), 0.0)
		var base: Vector3 = Vector3(0, 0, muzzle_exit.z - tooth_len * 0.3) + radial * ring_r
		var tooth := _add_cone("Tooth%d" % i, 0.008 * lerpf(0.5, 1.0, te), tooth_len, base, _bone_mat)
		# Point forward, tips biting slightly inward.
		var dir2: Vector3 = (Vector3(0, 0, -1.0) - radial * 0.45).normalized()
		tooth.quaternion = Quaternion(Vector3.UP, dir2)

	# --- Tendons strapping it all together (from ~card 10) ---
	var mag_bottom := Vector3(0, -rs.y * 0.5 - mag_size.y * 0.85, mag_offset_z)
	var tendon_pts: Array = [
		[mag_bottom, Vector3(0, -barrel_r * 2.0, receiver_front_z - barrel_len * 0.45), 0.006],
		[Vector3(rs.x * 0.4, rs.y * 0.4, rs.z * 0.45), Vector3(rs.x * 0.2, rs.y * 0.5 + 0.03, -rs.z * 0.2), 0.005],
		[Vector3(-rs.x * 0.4, -rs.y * 0.3, rs.z * 0.4), Vector3(-rs.x * 0.3, -rs.y * 0.55, mag_offset_z - 0.02), 0.005],
	]
	for ti in tendon_pts.size():
		var tphase: float = _rng.randf_range(0.0, 8.0)
		var t_e := _emerge(c, 0.76 + 0.045 * float(ti), 0.12)
		if t_e <= 0.01:
			continue
		_add_tendon("Tendon%d" % ti, tendon_pts[ti][0], tendon_pts[ti][1],
			float(tendon_pts[ti][2]) * lerpf(0.4, 1.0, t_e), tphase)

func animate_corruption(from_c: float, to_c: float, duration: float = 2.0) -> void:
	if Engine.is_editor_hint():
		return
	_anim_from = clampf(from_c, 0.0, 1.0)
	_anim_to = clampf(to_c, 0.0, 1.0)
	_anim_duration = maxf(0.1, duration)
	_anim_elapsed = 0.0
	_anim_next = 0.0
	corruption = _anim_from

func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if _anim_elapsed >= 0.0:
		# Clamped step: hitch frames must not fast-forward the growth.
		_anim_elapsed += minf(delta, 0.05)
		if _anim_elapsed >= _anim_duration:
			_anim_elapsed = -1.0
			corruption = _anim_to
		elif _anim_elapsed >= _anim_next:
			_anim_next = _anim_elapsed + ANIM_APPLY_INTERVAL
			var t: float = _anim_elapsed / _anim_duration
			# easeInOutCubic — paced with the gun's slow-start growth spurt.
			var e: float = 4.0 * t * t * t if t < 0.5 else 1.0 - pow(-2.0 * t + 2.0, 3.0) * 0.5
			corruption = lerpf(_anim_from, _anim_to, e)
	if _eye_root == null:
		return
	# Pupil random walk: pick a new gaze target at irregular intervals,
	# exponentially chase it (fast saccade onset, soft settle).
	_next_look -= delta
	if _next_look <= 0.0:
		_next_look = randf_range(0.6, 2.6)
		_look_target = Vector3(
			randf_range(-0.3, 1.0),  # biased outward from the receiver (+X side)
			randf_range(-0.5, 0.5),
			randf_range(-1.0, 0.6)).normalized()  # +Z glances = looks at its wielder
	_look_current = _look_current.lerp(_look_target, 1.0 - exp(-10.0 * delta)).normalized()
	# Blink: idle countdown, then a quick close/open ramp.
	if _blink_phase < 0.0:
		_next_blink -= delta
		if _next_blink <= 0.0:
			_blink_phase = 0.0
			_next_blink = randf_range(1.5, 6.0)
	else:
		_blink_phase += delta / 0.16
		if _blink_phase >= 1.0:
			_blink_phase = -1.0
	_blink = sin(clampf(_blink_phase, 0.0, 1.0) * PI) if _blink_phase >= 0.0 else 0.0
	_apply_eye_pose()

func _apply_eye_pose() -> void:
	# Discs are Y-flattened spheres — aim their Y axis along the gaze.
	if _iris:
		_iris.position = _look_current * _eye_r * 0.72
		_iris.quaternion = Quaternion(Vector3.UP, _look_current)
	if _pupil:
		_pupil.position = _look_current * _eye_r * 0.78
		_pupil.quaternion = Quaternion(Vector3.UP, _look_current)
	if _lid:
		_lid.scale = Vector3(1.0, lerpf(0.22, 1.02, _blink), 1.0)
		_lid.position = Vector3(0, lerpf(_eye_r * 0.85, 0.0, _blink), 0)

# ---- part helpers ----

# Place a flesh lump hugging a surface: out_dir is the surface normal, the
# lump's flattened axis (squash.x) aligns with it, spin rotates the tangent
# elongation around it. Sizing goes through node scale so the cached variant
# meshes are shared untouched.
func _add_lump(part_name: String, variant: int, r: float, pos: Vector3, out_dir: Vector3,
		squash: Vector3, spin: float, phase: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = part_name
	mi.mesh = _cached_lump(variant)
	mi.material_override = _flesh_mat
	mi.position = pos
	var out := out_dir.normalized()
	var q: Quaternion
	if out.dot(Vector3.RIGHT) < -0.999:
		q = Quaternion(Vector3.UP, PI)  # arc constructor is degenerate at 180°
	else:
		q = Quaternion(Vector3.RIGHT, out)
	mi.quaternion = q * Quaternion(Vector3.RIGHT, spin)
	mi.scale = squash * (r / LUMP_REF_R)
	add_child(mi)
	mi.set_instance_shader_parameter("phase", phase)
	_own(mi)
	return mi

func _add_cone(part_name: String, r: float, h: float, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = part_name
	mi.mesh = _cached_cone(r, h)
	mi.material_override = mat
	mi.position = pos
	add_child(mi)
	_own(mi)
	return mi

func _add_tendon(part_name: String, a: Vector3, b: Vector3, r: float, phase: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = part_name
	mi.mesh = _cached_capsule(r, maxf(a.distance_to(b), r * 2.1))
	mi.material_override = _flesh_mat
	mi.position = (a + b) * 0.5
	var dir := (b - a).normalized()
	if not dir.is_equal_approx(Vector3.UP) and not dir.is_equal_approx(Vector3.DOWN):
		mi.quaternion = Quaternion(Vector3.UP, dir)
	add_child(mi)
	mi.set_instance_shader_parameter("phase", phase)
	_own(mi)
	return mi

func _make_eye_disc(part_name: String, r: float, col: Color, emission_energy: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = part_name
	# Flattened cap sitting on the sclera surface.
	mi.mesh = _cached_sphere(r, r * 0.7)
	mi.material_override = _cached_eye_mat(col, emission_energy, 0.15)
	_eye_root.add_child(mi)
	_own(mi)
	return mi

func _own(node: Node) -> void:
	if not Engine.is_editor_hint():
		return
	var tree := get_tree()
	if tree and tree.edited_scene_root:
		node.owner = tree.edited_scene_root
