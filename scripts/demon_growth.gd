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
# The layout is seeded — same corruption produces the same part sizes — so
# quantized-key caches hit 100% after the first build.
static var _shared_flesh_mat: ShaderMaterial = null
static var _shared_bone_mat: StandardMaterial3D = null
static var _mesh_cache: Dictionary = {}
static var _eye_mat_cache: Dictionary = {}


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
# pacing driver — the demon takes ~10 rounds of losing to fully grow, so two
# cards mean a few subtle seams, not a monster. Stats only season it (a
# heavy explosive build reads a little meaner a little earlier); the
# seasoning is capped so no single card jumps a stage.
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
	return clampf(cards / 10.0 + minf(d, 0.15), 0.0, 1.0)

func rebuild() -> void:
	var _pt := Time.get_ticks_usec() if Trace.enabled else 0
	_rebuild_body()
	if Trace.enabled:
		Trace.prof("growth", Time.get_ticks_usec() - _pt)


func _rebuild_body() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	_eye_root = null
	_iris = null
	_pupil = null
	_lid = null

	var gun = get_node_or_null(gun_path)
	if gun == null or corruption <= 0.01:
		return
	# Deterministic layout: same corruption → same growth pattern, so cards
	# make the demon *grow*, not reshuffle.
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
	var barrel_len: float = gun.get("barrel_length")
	var barrel_r: float = gun.get("barrel_radius")
	var muzzle_flare: float = gun.get("muzzle_flare")
	var mag_size: Vector3 = gun.get("mag_size")
	var mag_offset_z: float = gun.get("mag_offset_z")
	var receiver_front_z: float = -rs.z * 0.5
	var muzzle_exit: Vector3 = gun.call("get_muzzle_exit_local")

	# --- Stage 1 (any corruption): flesh seams on the receiver ---
	# Squashed blobs clinging to the side/bottom faces, like tissue growing
	# out of the panel gaps. Count and size ramp with corruption.
	var n_blobs: int = 1 + int(round(c * 8.0))
	for i in n_blobs:
		var side: float = -1.0 if _rng.randf() < 0.5 else 1.0
		var on_bottom: bool = _rng.randf() < 0.3
		var r: float = _rng.randf_range(0.018, 0.045) * (0.55 + 0.9 * c)
		var pos := Vector3(
			side * rs.x * 0.5,
			_rng.randf_range(-rs.y * 0.35, rs.y * 0.35),
			_rng.randf_range(-rs.z * 0.42, rs.z * 0.42))
		var squash := Vector3(0.5, 1.0, 1.0)
		if on_bottom:
			pos = Vector3(_rng.randf_range(-rs.x * 0.3, rs.x * 0.3), -rs.y * 0.5, pos.z)
			squash = Vector3(1.0, 0.5, 1.0)
		_add_flesh_sphere("Blob%d" % i, r, pos, squash)

	# --- Stage 2 (c > 0.3, ~round 3): muscle sheath at the barrel base ---
	if c > 0.3:
		var cover: float = barrel_len * (0.2 + 0.55 * c)
		var k: int = 3 + int(round(c * 4.0))
		for i in k:
			var t: float = float(i) / float(maxi(1, k - 1))
			var z: float = receiver_front_z - cover * t
			var r2: float = barrel_r * (3.0 - 1.6 * t) * (0.6 + 0.7 * c)
			var jitter := Vector3(_rng.randf_range(-0.004, 0.004), _rng.randf_range(-0.004, 0.004), 0.0)
			_add_flesh_sphere("Sheath%d" % i, r2, Vector3(0, 0, z) + jitter, Vector3(1.0, 1.0, 1.4))
		# Throat under the magazine — connective mass so the mag reads
		# swallowed rather than bolted on.
		var mag_y: float = -rs.y * 0.5 - mag_size.y * 0.35
		_add_flesh_sphere("Throat", mag_size.y * 0.32 * (0.6 + 0.8 * c),
			Vector3(0, mag_y, mag_offset_z), Vector3(0.8, 1.3, 0.9))

	# --- Stage 2.5 (c > 0.4, ~round 4): bone spine along the top rail ---
	var n_spikes: int = int(round(lerpf(0.0, 9.0, maxf(0.0, (c - 0.4) / 0.6))))
	for i in n_spikes:
		var t2: float = float(i) / float(maxi(1, n_spikes - 1))
		var z2: float = lerpf(rs.z * 0.42, receiver_front_z - barrel_len * 0.3 * c, t2)
		# Tallest over the receiver, tapering toward the muzzle; per-spike
		# length jitter so the ridge reads grown, not manufactured.
		var h: float = lerpf(0.055, 0.02, t2) * (0.5 + 0.9 * c) * _rng.randf_range(0.75, 1.25)
		var spike := _add_cone("Spike%d" % i, 0.005 + 0.007 * c, h,
			Vector3(0, rs.y * 0.5 + 0.02 + h * 0.5, z2), _bone_mat)
		spike.rotation = Vector3(_rng.randf_range(-0.15, 0.35), 0, _rng.randf_range(-0.12, 0.12))

	# --- Stage 3.5 (c > 0.7, ~round 7): teeth ringing the muzzle ---
	if c > 0.7:
		var ring_r: float = maxf(barrel_r * muzzle_flare * 1.05, barrel_r * 1.5)
		var n_teeth: int = 4 + int(round(c * 8.0))
		var tooth_len: float = 0.024 + 0.03 * c
		# Gum collar behind the teeth so they emerge from flesh, not metal —
		# kept slim so the teeth clear it instead of drowning in it.
		_add_flesh_sphere("Gum", ring_r * 1.05,
			Vector3(0, 0, muzzle_exit.z + 0.02), Vector3(1.0, 1.0, 0.5))
		for i in n_teeth:
			var ang: float = TAU * float(i) / float(n_teeth) + _rng.randf_range(-0.1, 0.1)
			var radial := Vector3(cos(ang), sin(ang), 0.0)
			var base: Vector3 = Vector3(0, 0, muzzle_exit.z - tooth_len * 0.3) + radial * ring_r
			var tooth := _add_cone("Tooth%d" % i, 0.008, tooth_len, base, _bone_mat)
			# Point forward, tips biting slightly inward.
			var dir: Vector3 = (Vector3(0, 0, -1.0) - radial * 0.45).normalized()
			tooth.quaternion = Quaternion(Vector3.UP, dir)

	# --- Stage 3 (c > 0.55, ~round 5-6): the eye ---
	if c > 0.55:
		# Right (+X) side: the flank the inspect pose turns toward the camera
		# (the muzzle yaws LEFT during the card-growth moment).
		_eye_r = lerpf(0.022, 0.04, c)
		var eye_pos := Vector3(rs.x * 0.5 + _eye_r * 0.55, rs.y * 0.18, -rs.z * 0.1)
		_add_flesh_sphere("Socket", _eye_r * 1.5, eye_pos + Vector3(-_eye_r * 0.45, 0, 0), Vector3(0.7, 1.1, 1.1))
		_eye_root = Node3D.new()
		_eye_root.name = "Eye"
		_eye_root.position = eye_pos
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
		_lid.set_instance_shader_parameter("phase", _rng.randf_range(0.0, 8.0))
		_eye_root.add_child(_lid)
		_apply_eye_pose()

	# --- Stage 4 (c > 0.8, ~round 8+): tendons strapping it all together ---
	if c > 0.8:
		var mag_bottom := Vector3(0, -rs.y * 0.5 - mag_size.y * 0.85, mag_offset_z)
		_add_tendon("Tendon0", mag_bottom, Vector3(0, -barrel_r * 2.0, receiver_front_z - barrel_len * 0.45), 0.006)
		_add_tendon("Tendon1", Vector3(rs.x * 0.4, rs.y * 0.4, rs.z * 0.45),
			Vector3(rs.x * 0.2, rs.y * 0.5 + 0.03, -rs.z * 0.2), 0.005)
		_add_tendon("Tendon2", Vector3(-rs.x * 0.4, -rs.y * 0.3, rs.z * 0.4),
			Vector3(-rs.x * 0.3, -rs.y * 0.55, mag_offset_z - 0.02), 0.005)

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

func _add_flesh_sphere(part_name: String, r: float, pos: Vector3, squash: Vector3 = Vector3.ONE) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = part_name
	mi.mesh = _cached_sphere(r)
	mi.material_override = _flesh_mat
	mi.position = pos
	mi.scale = squash
	add_child(mi)
	mi.set_instance_shader_parameter("phase", _rng.randf_range(0.0, 8.0))
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

func _add_tendon(part_name: String, a: Vector3, b: Vector3, r: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = part_name
	mi.mesh = _cached_capsule(r, maxf(a.distance_to(b), r * 2.1))
	mi.material_override = _flesh_mat
	mi.position = (a + b) * 0.5
	var dir := (b - a).normalized()
	if not dir.is_equal_approx(Vector3.UP) and not dir.is_equal_approx(Vector3.DOWN):
		mi.quaternion = Quaternion(Vector3.UP, dir)
	add_child(mi)
	mi.set_instance_shader_parameter("phase", _rng.randf_range(0.0, 8.0))
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
