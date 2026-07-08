class_name ColosseumCrowd
extends Node3D

# Destructible crowd: blasts and bullets that reach the stands kill the
# spectators they touch. The kill itself is a per-instance MultiMesh transform
# zero (CPU cost only on kill events, segment-bucketed lookup); the gore is a
# one-shot GPUParticles3D whose process shader collides against the stadium's
# ANALYTIC step function (crowd_gore.gdshader) — chunks cascade down the
# stairs with no snapshot, no physics bodies, no readback.
#
# Event flow: CrowdAudio already detects crowd-band hits (bullet segment
# crossings + blasts near the ring) for its audience reactions; it forwards
# those same events here so blood and screams always agree.

const GORE_SHADER := preload("res://shaders/crowd_gore.gdshader")
const MARKS_SHADER := preload("res://shaders/crowd_marks.gdshader")

const MAX_GORE_EMITTERS := 5
const GORE_CHIP_SIZE := 0.42
# Rolling mark pool: scorch + blood quads share one MultiMesh; when full, the
# oldest mark is overwritten. Fixed cost forever.
const MAX_MARKS := 256
const MARKS_PER_BLAST := 22
const DEAD_XFORM := Transform3D(
	Basis(Vector3(0.0001, 0, 0), Vector3(0, 0.0001, 0), Vector3(0, 0, 0.0001)),
	Vector3(0.0, -500.0, 0.0))

static var active: ColosseumCrowd = null

# Set by ColosseumBuilder — the crowd's ShaderMaterial, which owns the
# flee-from-blast uniforms (see crowd.gdshader).
var crowd_mat: ShaderMaterial = null

const FLEE_SLOTS := 4
const FLEE_HOLD_SEC := 6.0    # stay scattered this long after the LAST hit
const FLEE_RETURN_DUR := 4.5  # must match the shader's FLEE_RETURN_DUR

var _mm: MultiMesh = null
var _positions := PackedVector3Array()  # local space, parallel to MM instances
var _alive := PackedByteArray()
var _buckets: Array[PackedInt32Array] = []  # seat indices per ring segment
var _segments := 1
var _inner_r := 70.0
var _base_y := 14.0
var _row_depth := 2.2
var _row_rise := 1.4
var _rows := 18.0
var _gore_live: Array[GPUParticles3D] = []
var _marks_mm: MultiMesh = null
var _mark_next := 0
var _flee_blast := PackedVector4Array()
var _flee_start_ms := PackedInt64Array()
var _flee_hold := PackedFloat32Array()
var dead_count := 0

static var _marks_tex: Texture2D = null


func setup(
	mm: MultiMesh,
	positions: PackedVector3Array,
	seat_segments: PackedInt32Array,
	segments: int,
	inner_r: float,
	base_y: float,
	row_depth: float,
	row_rise: float,
	rows: int,
) -> void:
	_mm = mm
	_positions = positions
	_segments = maxi(segments, 1)
	_inner_r = inner_r
	_base_y = base_y
	_row_depth = row_depth
	_row_rise = row_rise
	_rows = float(rows)
	_alive.resize(positions.size())
	_alive.fill(1)
	_buckets.resize(_segments)
	for s in _segments:
		_buckets[s] = PackedInt32Array()
	for i in seat_segments.size():
		_buckets[seat_segments[i]].append(i)


func _ready() -> void:
	active = self
	_build_marks_pool()
	_flee_blast.resize(FLEE_SLOTS)
	_flee_start_ms.resize(FLEE_SLOTS)
	_flee_start_ms.fill(-1_000_000)
	_flee_hold.resize(FLEE_SLOTS)
	_flee_hold.fill(FLEE_HOLD_SEC)
	if crowd_mat != null:
		crowd_mat.set_shader_parameter(
			"ring_center", Vector2(global_position.x, global_position.z))
	set_process(false)  # only ticks while a flee wave is live
	# Compile the gore process-shader PSO before the first real hit.
	_spawn_gore(global_position + Vector3(0.0, 2.0, 0.0), 0.5, 1, 0.001)


# The whole flee simulation lives in the crowd vertex shader; the CPU's entire
# job is these uniforms — a 4-slot ring of scare zones, their ages, and their
# per-slot hold times.
func _record_flee(world_pos: Vector3, radius: float) -> void:
	if crowd_mat == null:
		return
	var now := Time.get_ticks_msec()
	# MERGE into a live nearby zone: sustained fire on one section keeps a
	# single slot scattered by pushing its return clock out, so the profile
	# never dips. (Naive ring-cycling evicted a mid-flee slot every 4th shot,
	# snapping its people home in one frame — spectators visibly "spawned"
	# at the hit point.)
	for i in FLEE_SLOTS:
		var age := float(now - _flee_start_ms[i]) / 1000.0
		if age >= _flee_hold[i] + FLEE_RETURN_DUR:
			continue  # slot finished — free for reuse below
		var slot := _flee_blast[i]
		var dxz := Vector2(world_pos.x - slot.x, world_pos.z - slot.z).length()
		if dxz <= maxf(4.0, slot.w * 1.5):
			var merged := slot
			merged.w = maxf(slot.w, radius)
			_flee_blast[i] = merged
			_flee_hold[i] = age + FLEE_HOLD_SEC
			_push_flee_uniforms()
			return
	# NEW zone: take the most-finished slot (expired first), so if eviction
	# ever cuts a flee short, it cuts the one closest to done.
	var best := 0
	var best_score := -INF
	for i in FLEE_SLOTS:
		var age := float(now - _flee_start_ms[i]) / 1000.0
		var score := age - (_flee_hold[i] + FLEE_RETURN_DUR)
		if score > best_score:
			best_score = score
			best = i
	_flee_blast[best] = Vector4(world_pos.x, world_pos.y, world_pos.z, radius)
	_flee_start_ms[best] = now
	_flee_hold[best] = FLEE_HOLD_SEC
	_push_flee_uniforms()


func _push_flee_uniforms() -> void:
	crowd_mat.set_shader_parameter("flee_blast", _flee_blast)
	crowd_mat.set_shader_parameter("flee_hold", Vector4(
		_flee_hold[0], _flee_hold[1], _flee_hold[2], _flee_hold[3]))
	set_process(true)


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	var ages := Vector4.ZERO
	var all_done := true
	for i in FLEE_SLOTS:
		var age := float(now - _flee_start_ms[i]) / 1000.0
		ages[i] = age
		if age < _flee_hold[i] + FLEE_RETURN_DUR:
			all_done = false
	if crowd_mat != null:
		crowd_mat.set_shader_parameter("flee_age", ages)
	if all_done:
		set_process(false)


func _build_marks_pool() -> void:
	_marks_mm = MultiMesh.new()
	_marks_mm.transform_format = MultiMesh.TRANSFORM_3D
	_marks_mm.use_colors = true
	_marks_mm.use_custom_data = true
	var quad := PlaneMesh.new()  # lies in XZ, faces up — matches the treads
	quad.size = Vector2.ONE
	_marks_mm.mesh = quad
	_marks_mm.instance_count = MAX_MARKS
	for i in MAX_MARKS:
		_marks_mm.set_instance_transform(i, DEAD_XFORM)
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Marks"
	mmi.multimesh = _marks_mm
	var mat := ShaderMaterial.new()
	mat.shader = MARKS_SHADER
	mat.set_shader_parameter("atlas", _get_marks_tex())
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Marks appear anywhere on the ring; one conservative AABB beats per-write
	# bounds recomputation.
	var reach := _inner_r + _rows * _row_depth + 4.0
	mmi.custom_aabb = AABB(
		Vector3(-reach, -2.0, -reach),
		Vector3(reach * 2.0, _base_y + _rows * _row_rise + 10.0, reach * 2.0))
	add_child(mmi)


# Stadium step height under a LOCAL-space point (mirror of the gore shader's
# ground_at) — marks sit flat on whichever tread is below.
func _ground_height_local(p: Vector3) -> float:
	var r := Vector2(p.x, p.z).length()
	if r < _inner_r:
		return 0.0
	var row := clampf(floorf((r - _inner_r) / _row_depth), 0.0, _rows - 1.0)
	return _base_y + row * _row_rise


func _add_mark(local_pos: Vector3, diameter: float, tint: Color, frame: float) -> void:
	if _marks_mm == null:
		return
	var lift := 0.06 + float(_mark_next % 7) * 0.004
	var xform: Transform3D
	var flat := Vector2(local_pos.x, local_pos.z)
	if flat.length() < _inner_r + 0.1:
		# Arena floor: flat on the ground, random spin.
		var basis := Basis(Vector3.UP, randf() * TAU) * Basis.from_scale(
			Vector3(diameter, 1.0, diameter * randf_range(0.75, 1.0)))
		xform = Transform3D(basis, Vector3(local_pos.x, lift, local_pos.z))
	else:
		# On the stands: orient the mark on the SLOPE ENVELOPE (the plane
		# through the step noses, tilted toward the arena). Flat-on-tread
		# marks are edge-on — invisible — from the arena floor, which is where
		# players actually stand; the envelope face is what they look at.
		var r := clampf(
			flat.length(), _inner_r + 0.2, _inner_r + _rows * _row_depth - 0.2)
		var dir := Vector3(flat.x, 0.0, flat.y).normalized()  # outward
		var tangent := Vector3(-dir.z, 0.0, dir.x)
		var pitch := atan2(_row_rise, _row_depth)
		var n := (Vector3.UP * cos(pitch) - dir * sin(pitch)).normalized()
		var downslope := tangent.cross(n)
		var y_env := _base_y + (r - _inner_r) / _row_depth * _row_rise
		var pos := Vector3(dir.x * r, y_env, dir.z * r) + n * lift
		var rot := randf() * TAU
		var xaxis := (tangent * cos(rot) + downslope * sin(rot)) * diameter
		var zaxis := (-tangent * sin(rot) + downslope * cos(rot)) \
			* (diameter * randf_range(0.75, 1.0))
		xform = Transform3D(Basis(xaxis, n, zaxis), pos)
	_marks_mm.set_instance_transform(_mark_next, xform)
	_marks_mm.set_instance_color(_mark_next, tint)
	_marks_mm.set_instance_custom_data(_mark_next, Color(frame, 0.0, 0.0, 0.0))
	_mark_next = (_mark_next + 1) % MAX_MARKS


func _exit_tree() -> void:
	if active == self:
		active = null


# Blast reaching the crowd band: kill everyone inside the radius, throw gore.
# Returns the kill count (CrowdAudio scales its reaction with it).
func apply_blast(world_pos: Vector3, radius: float) -> int:
	if _mm == null or _positions.is_empty():
		return 0
	# Everyone near the blast bolts, dead or not — recorded before the kill
	# loop so even a zero-kill near-miss scatters the section.
	_record_flee(world_pos, radius)
	var local := to_local(world_pos)
	var r_sq := radius * radius
	var ang := atan2(local.z, local.x)
	# Candidate segments: the blast's angular footprint on the ring, padded by
	# one segment. Everything else is untouched — no full-crowd scans.
	var half_arc := radius / maxf(_inner_r, 1.0) + TAU / float(_segments)
	var kills := 0
	var kill_spots: Array[Vector3] = []
	for s in _segments:
		var seg_center := TAU * (float(s) + 0.5) / float(_segments)
		if absf(angle_difference(seg_center, ang)) > half_arc:
			continue
		for idx in _buckets[s]:
			if _alive[idx] == 0:
				continue
			if _positions[idx].distance_squared_to(local) > r_sq:
				continue
			_alive[idx] = 0
			_mm.set_instance_transform(idx, DEAD_XFORM)
			kills += 1
			if kill_spots.size() < MARKS_PER_BLAST:
				kill_spots.append(_positions[idx])
	dead_count += kills
	# Scorch FIRST: marks share one transparent MultiMesh, so overlap blends in
	# stamp order — blood stamped after stays visible ON TOP of the scorch
	# (the kill zone sits entirely inside the scorch footprint).
	_add_mark(
		_scorch_anchor(local), clampf(radius * 1.2, 2.5, 8.0),
		Color(0.04, 0.035, 0.03, 0.85), 0.0)
	if kills > 0:
		_spawn_gore(world_pos, maxf(radius * 0.75, 1.2), kills)
		# Bigger massacres leave bigger pools: mark size scales with the body
		# count — a 30-kill blast paints double-size splatters.
		var mag := clampf(1.0 + float(kills) * 0.035, 1.0, 2.0)
		for spot in kill_spots:
			_add_mark(
				spot, randf_range(1.4, 2.4) * mag,
				Color(randf_range(0.42, 0.55), 0.04, 0.03, randf_range(0.88, 1.0)), 1.0)
		# Big blasts don't stop at the kill zone: blood gets thrown OUTWARD
		# onto the surrounding rows too.
		if kills >= 10:
			for _i in mini(kills / 3, 8):
				var a := randf() * TAU
				var rr := radius * randf_range(1.1, 1.7)
				_add_mark(
					local + Vector3(cos(a) * rr, 0.0, sin(a) * rr),
					randf_range(1.0, 1.8) * mag,
					Color(randf_range(0.38, 0.5), 0.04, 0.03, randf_range(0.7, 0.9)), 1.0)
	return kills


# Blasts against the facade (or mid-air just in front of the stands) sit at a
# radius whose ground is the hidden arena floor behind the wall — snap the
# scorch to the tread nearest the hit height instead so it stays visible.
func _scorch_anchor(local_pos: Vector3) -> Vector3:
	var flat := Vector2(local_pos.x, local_pos.z)
	if flat.length() >= _inner_r or local_pos.y < _base_y - 1.5:
		return local_pos
	var row := clampf(roundf((local_pos.y - _base_y) / _row_rise), 0.0, _rows - 1.0)
	var dir := flat.normalized()
	var target_r := _inner_r + (row + 0.5) * _row_depth
	return Vector3(dir.x * target_r, _base_y + row * _row_rise, dir.y * target_r)


# Is this point inside the "body zone" — above a seating step, below head
# height? That's where a bullet flying through the (collider-less) crowd
# should be able to hit somebody. Two compares + a distance; bullet-tick safe.
func bullet_body_zone(world_pos: Vector3) -> bool:
	var local := to_local(world_pos)
	var r := Vector2(local.x, local.z).length()
	if r < _inner_r + 0.1 or r > _inner_r + _rows * _row_depth:
		return false
	var h := local.y - _ground_height_local(local)
	return h > 0.0 and h < 1.9


# Hitscan companion: march the beam through the band and resolve the first
# body hit. Returns the kill position, or Vector3.INF if the beam hit nobody.
func raycast_bodies(from: Vector3, to: Vector3) -> Vector3:
	var seg := to - from
	var seg_len := seg.length()
	if seg_len < 0.01:
		return Vector3.INF
	# Cheap reject: entirely below the stands.
	if maxf(from.y, to.y) < global_position.y + _base_y - 1.0:
		return Vector3.INF
	var steps := clampi(int(seg_len / 0.8), 1, 60)
	var stride := seg / float(steps)
	var p := from
	for _s in steps:
		p += stride
		if bullet_body_zone(p) and apply_bullet(p) > 0:
			return p
	return Vector3.INF


# Single bullet crossing into the stands: kill at most a couple of spectators
# right at the impact point, with a small spray.
func apply_bullet(world_pos: Vector3) -> int:
	if _mm == null or _positions.is_empty():
		return 0
	_record_flee(world_pos, 1.2)  # a small local scatter around the impact
	var local := to_local(world_pos)
	var ang := atan2(local.z, local.x)
	var kills := 0
	for s in _segments:
		var seg_center := TAU * (float(s) + 0.5) / float(_segments)
		if absf(angle_difference(seg_center, ang)) > 1.6 / maxf(_inner_r, 1.0) + TAU / float(_segments):
			continue
		for idx in _buckets[s]:
			if _alive[idx] == 0:
				continue
			if _positions[idx].distance_squared_to(local) > 1.7 * 1.7:
				continue
			_alive[idx] = 0
			_mm.set_instance_transform(idx, DEAD_XFORM)
			_add_mark(
				_positions[idx], randf_range(1.0, 1.5),
				Color(randf_range(0.42, 0.55), 0.04, 0.03, randf_range(0.85, 1.0)), 1.0)
			kills += 1
			if kills >= 2:
				break
		if kills >= 2:
			break
	dead_count += kills
	if kills > 0:
		_spawn_gore(world_pos, 0.9, kills)
	return kills


# Two 64x64 alpha frames: soft ragged scorch blob | splatter with satellite
# droplets. Generated once per process, cached.
static func _get_marks_tex() -> Texture2D:
	if _marks_tex != null:
		return _marks_tex
	var img := Image.create(128, 64, false, Image.FORMAT_RGBA8)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("crowd_marks")
	# Frame 0: scorch — dense dark core, ragged noise-eaten rim.
	for y in 64:
		for x in 64:
			var p := Vector2(x - 32, y - 32) / 32.0
			var d := p.length()
			var rim := sin(p.angle() * 7.0) * 0.08 + sin(p.angle() * 13.0 + 2.1) * 0.05
			var a := clampf(1.0 - (d + rim) * 1.15, 0.0, 1.0)
			a = pow(a, 0.45)  # near-opaque core, soft edge
			img.set_pixel(x, y, Color(1, 1, 1, a))
	# Frame 1: blood splatter — heavy centre + random satellite droplets.
	for y in 64:
		for x in 64:
			var p := Vector2(x - 96, y - 32) / 32.0
			var a := clampf(1.0 - p.length() * 1.5, 0.0, 1.0)
			img.set_pixel(x + 64, y, Color(1, 1, 1, pow(a, 0.7)))
	for _i in 34:
		var ang := rng.randf() * TAU
		var dist := rng.randf_range(6.0, 30.0)
		var cx := 96 + int(cos(ang) * dist)
		var cy := 32 + int(sin(ang) * dist * 0.8)
		var r := rng.randi_range(2, 5)
		for y in range(maxi(cy - r, 0), mini(cy + r + 1, 64)):
			for x in range(maxi(cx - r, 64), mini(cx + r + 1, 128)):
				if Vector2(x - cx, y - cy).length() <= float(r):
					img.set_pixel(x, y, Color(1, 1, 1, rng.randf_range(0.75, 1.0)))
	_marks_tex = ImageTexture.create_from_image(img)
	return _marks_tex


func _spawn_gore(world_pos: Vector3, radius: float, kills: int, scale_mult: float = 1.0) -> void:
	if BenchFlags.active and BenchFlags.no_explosion_visuals:
		return
	if not is_inside_tree():
		return
	var p := GPUParticles3D.new()
	p.amount = clampi(kills * 6, 16, 320)
	p.lifetime = 2.4
	p.one_shot = true
	p.explosiveness = 1.0
	p.fixed_fps = 60
	p.local_coords = false
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.visibility_aabb = AABB(world_pos - Vector3(30.0, 25.0, 30.0), Vector3(60.0, 50.0, 60.0))
	var m := ShaderMaterial.new()
	m.shader = GORE_SHADER
	var center := global_position
	m.set_shader_parameter("ring_center", Vector2(center.x, center.z))
	m.set_shader_parameter("inner_r", _inner_r)
	m.set_shader_parameter("base_y", center.y + _base_y)
	m.set_shader_parameter("floor_y", center.y)
	m.set_shader_parameter("row_depth", _row_depth)
	m.set_shader_parameter("row_rise", _row_rise)
	m.set_shader_parameter("rows", _rows)
	m.set_shader_parameter("blast_pos", world_pos)
	m.set_shader_parameter("blast_radius", radius)
	m.set_shader_parameter("speed", clampf(4.0 + radius * 1.2, 5.0, 11.0))
	m.set_shader_parameter("chip_size", GORE_CHIP_SIZE * scale_mult)
	m.set_shader_parameter("kill_y", center.y - 40.0)
	p.process_material = m
	# Same shard mesh + vertex-color material as GPU debris — shares its PSOs.
	p.draw_pass_1 = Violence._get_impact_chip_mesh()
	p.material_override = GpuDebris._chip_material()
	add_child(p)
	p.emitting = true
	p.finished.connect(p.queue_free)
	_gore_live.append(p)
	p.tree_exiting.connect(func() -> void: _gore_live.erase(p))
	while _gore_live.size() > MAX_GORE_EMITTERS:
		var oldest: GPUParticles3D = _gore_live.pop_front()
		if is_instance_valid(oldest):
			oldest.queue_free()
	# Blood mist blooming AT the impact — the explosion smoke system with a red
	# smoke_tint, opted out of smoke-pushing (pushable=false) so its own blast
	# doesn't shove it away. Skipped for the sub-pixel warmup burst.
	if scale_mult >= 1.0:
		# Sized a bit under the blast's own smoke cloud: our `radius` is the
		# gore radius (0.75x the already-halved kill radius); the smoke gets
		# the full visual blast radius, so ~2x recovers most of it. Longer
		# life and a gentler rise than smoke — the red mist hangs in the air
		# after the grey has dissipated — but translucent (opacity 0.6) so it
		# reads as a haze over the explosion rather than a solid red wall.
		var mist_r := maxf(radius * 2.0, 2.0)
		var mist_life := (0.5 + 0.13 * mist_r) * 1.6
		var mist_count := clampi(
			int(round((4.0 + float(kills) * 0.7) * Violence.vfx_quality_scale())), 4, 10)
		Violence._spawn_blast_billow(
			get_tree().current_scene, world_pos, mist_r,
			mist_count, false, Color(0.5, 0.05, 0.05),
			mist_life, 0.45, 1.05, mist_r * 0.3, 1.0, 0.0, Color(2.2, 0.22, 0.18),
			false, 0.6)
