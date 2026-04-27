class_name Violence extends RefCounted

# Default chunk count when fracturing a body. Must match the value used by
# gib_warm_tree() at scene load — varying it forces synchronous bakes on the
# main thread (~200ms per mesh).
const GIB_CHUNK_COUNT := 5

# Single home for all death / ragdoll / impact / gore logic. Player.gd keeps
# RPC entry points (must live on the Node) as thin pass-throughs and exposes
# its state vars; everything else lives here as static helpers.
#
# Layout:
#   1. Gib mesh fracturing  — Voronoi splitter + ragdoll body builder.
#   2. VFX spawners         — bullet impact, blood, blast, heat distortion,
#                             shockwave ring (scene-scoped, no Player state).
#   3. Player-coupled       — view punch, hit-face, ragdoll spawn/clear,
#                             knockback. These take a player Node.

# -------------------- 1. GIB MESH FRACTURING --------------------
#
# Voronoi-splits a Mesh into random chunks and spawns each as a RigidBody3D.
# Triangles are bucketed by which random seed their centroid is nearest to.
# Each chunk's cut boundary is capped with a fan of flesh triangles (vertex-
# coloured dark red, double-sided) so tumbling chunks show meaty innards
# instead of reading as hollow shells.
#
# The Voronoi bake is expensive (~tens of ms per mesh), so results are
# cached and ideally pre-built on a worker thread via gib_warm_tree(node)
# at map load. `gib_explode()` picks one of the cached variants and just
# instantiates ArrayMeshes + RigidBody3Ds — near-free at runtime.

const _GIB_VARIANTS_PER_MESH := 3
const _GIB_QUANTIZE := 0.0001

# [mesh, chunk_count] → Array[variant]; each variant is Array[chunk_dict].
static var _gib_cache: Dictionary = {}
static var _gib_cache_mutex: Mutex = Mutex.new()
static var _gib_flesh_material_cached: StandardMaterial3D = null
static var _gib_blood_splat_material_cached: StandardMaterial3D = null

# Kick off async bakes for every MeshInstance3D under `root`. Idempotent;
# subsequent calls with the same mesh/chunk_count are no-ops.
static func gib_warm_tree(root: Node, chunk_count: int = 4) -> void:
	if root == null:
		return
	var meshes: Array[Mesh] = []
	_gib_collect_meshes(root, meshes)
	for m in meshes:
		gib_warm(m, chunk_count)

static func gib_warm(mesh: Mesh, chunk_count: int = 4) -> void:
	if mesh == null:
		return
	var key: Array = [mesh, chunk_count]
	_gib_cache_mutex.lock()
	var present: bool = _gib_cache.has(key)
	if not present:
		_gib_cache[key] = null  # reserve slot so concurrent warms dedupe
	_gib_cache_mutex.unlock()
	if present:
		return
	WorkerThreadPool.add_task(_gib_warm_task.bind(mesh, chunk_count), false, "Violence.gib_warm")

static func _gib_warm_task(mesh: Mesh, chunk_count: int) -> void:
	var variants: Array = _gib_build_variants(mesh, chunk_count)
	_gib_cache_mutex.lock()
	_gib_cache[[mesh, chunk_count]] = variants
	_gib_cache_mutex.unlock()

static func _gib_collect_meshes(node: Node, out: Array[Mesh]) -> void:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		var m: Mesh = (node as MeshInstance3D).mesh
		if not out.has(m):
			out.append(m)
	for child in node.get_children():
		_gib_collect_meshes(child, out)

# Grab (or synchronously build) the variants for this mesh+chunk_count.
# The synchronous fallback fires only if `gib_warm()` wasn't called in time —
# a first-kill hitch rather than a per-kill hitch.
static func _gib_get_variants(mesh: Mesh, chunk_count: int) -> Array:
	var key: Array = [mesh, chunk_count]
	_gib_cache_mutex.lock()
	var cached: Variant = _gib_cache.get(key)
	_gib_cache_mutex.unlock()
	if cached is Array:
		return cached
	var variants: Array = _gib_build_variants(mesh, chunk_count)
	_gib_cache_mutex.lock()
	var latest: Variant = _gib_cache.get(key)
	if latest is Array:
		variants = latest  # another thread raced us — prefer its result
	else:
		_gib_cache[key] = variants
	_gib_cache_mutex.unlock()
	return variants

static func gib_explode(
	mesh: Mesh,
	source_transform: Transform3D,
	scene: Node,
	material: Material,
	base_velocity: Vector3,
	burst_strength: float = 3.0,
	chunk_count: int = 4,
	lifetime: float = 12.0,
	force_origin_global: Vector3 = Vector3.INF,
	impact_blood_strength: float = 0.0,
) -> Array[RigidBody3D]:
	var out: Array[RigidBody3D] = []
	if mesh == null or scene == null:
		return out
	var variants: Array = _gib_get_variants(mesh, chunk_count)
	if variants.is_empty():
		return out
	var chunks: Array = variants.pick_random()
	if chunks.is_empty():
		return out

	# Make the caller's material double-sided so open triangles don't disappear.
	var chunk_material: Material = material
	if material is StandardMaterial3D:
		var dup: StandardMaterial3D = (material as StandardMaterial3D).duplicate()
		dup.cull_mode = BaseMaterial3D.CULL_DISABLED
		chunk_material = dup
	var flesh_material: StandardMaterial3D = _gib_get_flesh_material()

	var body_basis: Basis = source_transform.basis.orthonormalized()
	for chunk in chunks:
		var rb: RigidBody3D = _gib_instantiate_chunk(
			chunk, chunk_material, flesh_material,
			source_transform, body_basis, scene,
			base_velocity, burst_strength, force_origin_global, impact_blood_strength,
		)
		if rb == null:
			continue
		scene.get_tree().create_timer(lifetime).timeout.connect(func() -> void:
			if is_instance_valid(rb):
				rb.queue_free())
		out.append(rb)
	return out

static func _gib_instantiate_chunk(
	chunk: Dictionary,
	chunk_material: Material,
	flesh_material: StandardMaterial3D,
	source_transform: Transform3D,
	body_basis: Basis,
	scene: Node,
	base_velocity: Vector3,
	burst_strength: float,
	force_origin_global: Vector3,
	impact_blood_strength: float,
) -> RigidBody3D:
	var verts: PackedVector3Array = chunk["verts"]
	if verts.is_empty():
		return null

	var chunk_mesh: ArrayMesh = ArrayMesh.new()
	var shell: Array = []
	shell.resize(Mesh.ARRAY_MAX)
	shell[Mesh.ARRAY_VERTEX] = verts
	var norms: PackedVector3Array = chunk["norms"]
	if norms.size() == verts.size():
		shell[Mesh.ARRAY_NORMAL] = norms
	var uvs: PackedVector2Array = chunk["uvs"]
	if uvs.size() == verts.size():
		shell[Mesh.ARRAY_TEX_UV] = uvs
	shell[Mesh.ARRAY_INDEX] = chunk["indices"]
	chunk_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, shell)

	var cap_verts: PackedVector3Array = chunk["cap_verts"]
	var has_cap: bool = not cap_verts.is_empty()
	if has_cap:
		var cap: Array = []
		cap.resize(Mesh.ARRAY_MAX)
		cap[Mesh.ARRAY_VERTEX] = cap_verts
		cap[Mesh.ARRAY_COLOR] = chunk["cap_colors"]
		cap[Mesh.ARRAY_INDEX] = chunk["cap_indices"]
		chunk_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, cap)

	var centroid_src: Vector3 = chunk["centroid"]
	var chunk_aabb: AABB = chunk["aabb"]

	# Non-uniform warp from the source body (SLENDERMAN, FLATFISH, …). The
	# chunk geometry is cached in unwarped source-local space, so we apply the
	# warp visually on the MeshInstance3D and to the collision box. The rigid
	# body itself stays orthonormal so physics behaves cleanly.
	var warp: Vector3 = source_transform.basis.get_scale()

	var rb: RigidBody3D = RigidBody3D.new()
	rb.collision_layer = 0
	rb.collision_mask = 1
	rb.gravity_scale = 1.0
	rb.contact_monitor = true
	rb.max_contacts_reported = 1
	scene.add_child(rb)
	rb.global_transform = Transform3D(body_basis, source_transform * centroid_src)

	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = chunk_mesh
	mi.scale = warp
	if chunk_material:
		mi.set_surface_override_material(0, chunk_material)
	if has_cap and flesh_material:
		mi.set_surface_override_material(1, flesh_material)
	rb.add_child(mi)

	var cs: CollisionShape3D = CollisionShape3D.new()
	var box_shape: BoxShape3D = BoxShape3D.new()
	var sz: Vector3 = chunk_aabb.size * warp
	box_shape.size = Vector3(maxf(sz.x, 0.05), maxf(sz.y, 0.05), maxf(sz.z, 0.05))
	cs.shape = box_shape
	cs.position = (chunk_aabb.position + chunk_aabb.size * 0.5) * warp
	rb.add_child(cs)

	# If a force origin is provided (bullet hit point / explosion center),
	# burst away from that point; otherwise fall back to body-center fan-out.
	var centroid_global: Vector3 = source_transform * centroid_src
	var burst_dir: Vector3
	if force_origin_global != Vector3.INF:
		burst_dir = centroid_global - force_origin_global
		if burst_dir.length_squared() < 0.0001:
			burst_dir = body_basis * centroid_src
	else:
		burst_dir = body_basis * centroid_src
	if burst_dir.length_squared() < 0.0001:
		burst_dir = Vector3(randf_range(-1.0, 1.0), 1.0, randf_range(-1.0, 1.0))
	burst_dir = burst_dir.normalized()
	rb.linear_velocity = base_velocity \
		+ burst_dir * burst_strength \
		+ Vector3.UP * burst_strength * 0.2
	rb.angular_velocity = Vector3(
		randf_range(-10.0, 10.0),
		randf_range(-10.0, 10.0),
		randf_range(-10.0, 10.0),
	)
	rb.body_entered.connect(func(_body: Node) -> void:
		_gib_on_chunk_body_entered(rb, scene, impact_blood_strength)
	)
	return rb

# Single rigid body containing every supplied mesh — used for non-explosive
# deaths so the corpse tumbles as one piece. `pivot_xform` is the world
# transform the body spawns at; child meshes get cloned into it preserving
# their position relative to the pivot. Collision is one BoxShape3D sized
# to the union AABB of all meshes — coarse but cheap and shape-stable.
static func gib_body_ragdoll(
	pivot_xform: Transform3D,
	meshes: Array,
	scene: Node,
	base_velocity: Vector3,
	spin: float = 4.0,
	lifetime: float = 14.0,
) -> RigidBody3D:
	if scene == null or meshes.is_empty():
		return null
	var rb := RigidBody3D.new()
	# Layer 2 + "corpses" group so bullets can still hit a downed body — the
	# corpse accumulates damage and disintegrates at CORPSE_DISINTEGRATE_DMG.
	rb.collision_layer = 2
	rb.collision_mask = 1
	rb.gravity_scale = 1.0
	rb.add_to_group("corpses")
	rb.set_meta("dmg_taken", 0.0)
	scene.add_child(rb)
	# Keep the rigid body itself orthonormal (physics doesn't like non-uniform
	# scale on bodies), but bake any pivot warp INTO the cloned mesh transforms
	# below. That way SLENDERMAN / FLATFISH ragdolls keep the same shape.
	var rb_xform := Transform3D(pivot_xform.basis.orthonormalized(), pivot_xform.origin)
	rb.global_transform = rb_xform

	var inv := rb_xform.affine_inverse()
	var union: AABB = AABB()
	var union_init := false
	for src: MeshInstance3D in meshes:
		if src.mesh == null:
			continue
		# Skip meshes that aren't actually rendered — lets the caller toggle
		# state-based visuals (e.g. squinty hit eyes) before snapshotting.
		if not src.is_visible_in_tree():
			continue
		var local_xform: Transform3D = inv * src.global_transform
		var mi := MeshInstance3D.new()
		mi.mesh = src.mesh
		if src.material_override:
			mi.material_override = src.material_override
		mi.transform = local_xform
		rb.add_child(mi)
		var aabb_local: AABB = local_xform * src.mesh.get_aabb()
		if union_init:
			union = union.merge(aabb_local)
		else:
			union = aabb_local
			union_init = true

	if union_init:
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(maxf(union.size.x, 0.1), maxf(union.size.y, 0.1), maxf(union.size.z, 0.1))
		cs.shape = box
		cs.position = union.position + union.size * 0.5
		rb.add_child(cs)

	rb.linear_velocity = base_velocity
	rb.angular_velocity = Vector3(
		randf_range(-spin, spin),
		randf_range(-spin, spin),
		randf_range(-spin, spin),
	)
	scene.get_tree().create_timer(lifetime).timeout.connect(func() -> void:
		if is_instance_valid(rb):
			rb.queue_free())
	return rb

# Cumulative damage at which a still-intact corpse falls apart into chunks.
const CORPSE_DISINTEGRATE_DMG := 50.0

# Bullet hit a non-disintegrated ragdoll body. Sprays blood on the wound,
# accumulates damage, and disintegrates the corpse once the running total
# crosses the threshold. Cosmetic-only — runs independently on each peer
# (the ragdoll itself was already a per-peer simulation).
static func hit_corpse(rb: RigidBody3D, hit_pos: Vector3, dir: Vector3, dmg: float) -> void:
	if rb == null or not is_instance_valid(rb):
		return
	var scene: Node = rb.get_tree().current_scene
	if scene == null:
		return
	# Squirt of blood at the wound + a faint mist behind so the impact reads
	# from any angle.
	spawn_blood(scene, hit_pos, dir, 0.7)
	var splash_dir: Vector3 = dir.normalized() if dir.length_squared() > 0.001 else Vector3.UP
	_gib_spawn_blood_splat(scene, hit_pos, -splash_dir, splash_dir, 0.5)
	# Push the body slightly so heavy rounds visibly shove the corpse.
	rb.apply_central_impulse(splash_dir * clampf(dmg * 0.05, 0.5, 4.0))
	var taken: float = float(rb.get_meta("dmg_taken", 0.0)) + dmg
	rb.set_meta("dmg_taken", taken)
	if taken >= CORPSE_DISINTEGRATE_DMG:
		disintegrate_corpse(rb, splash_dir)

# Voronoi-shatter every mesh of an intact ragdoll body and free the body.
# Carries the rigid body's current velocity into the chunks so the burst
# continues whatever motion the corpse already had.
static func disintegrate_corpse(rb: RigidBody3D, push_dir: Vector3 = Vector3.ZERO) -> void:
	if rb == null or not is_instance_valid(rb):
		return
	var scene: Node = rb.get_tree().current_scene
	if scene == null:
		return
	var carry: Vector3 = rb.linear_velocity + push_dir.normalized() * 4.0
	for child in rb.get_children():
		if not (child is MeshInstance3D):
			continue
		var mi := child as MeshInstance3D
		if mi.mesh == null or not mi.is_visible_in_tree():
			continue
		gib_explode(
			mi.mesh,
			mi.global_transform,
			scene,
			mi.material_override,
			carry + Vector3(randf_range(-1.0, 1.0), randf_range(0.4, 1.4), randf_range(-1.0, 1.0)),
			3.2,
			GIB_CHUNK_COUNT,
			14.0,
			rb.global_position,
			0.6,
		)
	rb.queue_free()

static func _gib_on_chunk_body_entered(rb: RigidBody3D, scene: Node, strength: float) -> void:
	if rb == null or scene == null or not is_instance_valid(rb):
		return
	if rb.get_meta("blood_splatted", false):
		return
	rb.set_meta("blood_splatted", true)
	if strength <= 0.01:
		return
	var vel: Vector3 = rb.linear_velocity
	if vel.length_squared() < 0.01:
		vel = -rb.global_transform.basis.z
	var dir := vel.normalized()
	var start := rb.global_position + dir * 0.18
	var finish := rb.global_position - dir * 0.45
	var q := PhysicsRayQueryParameters3D.create(start, finish)
	q.collision_mask = 1
	var hit := rb.get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return
	_gib_spawn_blood_splat(scene, hit.position, hit.normal, dir, strength)

static func _gib_spawn_blood_splat(
	scene: Node,
	pos: Vector3,
	normal: Vector3,
	travel_dir: Vector3,
	strength: float
) -> void:
	var splat := MeshInstance3D.new()
	var mesh := QuadMesh.new()
	var size := randf_range(0.16, 0.28) * lerpf(0.9, 2.1, clampf(strength, 0.0, 1.0))
	mesh.size = Vector2(size, size * randf_range(0.6, 1.15))
	splat.mesh = mesh
	splat.material_override = _gib_get_blood_splat_material()
	scene.add_child(splat)

	var up := normal.normalized() if normal.length_squared() > 0.001 else Vector3.UP
	var tangent := travel_dir.slide(up).normalized()
	if tangent.length_squared() < 0.001:
		tangent = up.cross(Vector3.RIGHT).normalized()
		if tangent.length_squared() < 0.001:
			tangent = Vector3.FORWARD
	splat.global_position = pos + up * 0.025
	splat.look_at(splat.global_position + up, tangent)
	splat.rotate_object_local(Vector3.FORWARD, randf_range(-0.55, 0.55))

	var mat := splat.material_override.duplicate() as StandardMaterial3D
	var alpha := randf_range(0.5, 0.82) * lerpf(0.8, 1.2, clampf(strength, 0.0, 1.0))
	mat.albedo_color = Color(randf_range(0.28, 0.42), 0.015, 0.015, clampf(alpha, 0.0, 0.92))
	splat.material_override = mat

	var tw := splat.create_tween().set_parallel(true)
	tw.tween_property(splat, "scale", Vector3.ONE * randf_range(1.05, 1.3), 0.22)\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.tween_property(mat, "albedo_color", Color(mat.albedo_color.r, 0.015, 0.015, mat.albedo_color.a * 0.92), 0.22)

static func _gib_get_blood_splat_material() -> StandardMaterial3D:
	if _gib_blood_splat_material_cached:
		return _gib_blood_splat_material_cached
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_DISABLED
	_gib_blood_splat_material_cached = mat
	return mat

# -------------------- baking (thread-safe) --------------------

static func _gib_build_variants(mesh: Mesh, chunk_count: int) -> Array:
	var variants: Array = []
	for _i in _GIB_VARIANTS_PER_MESH:
		variants.append(_gib_bake_one(mesh, chunk_count))
	return variants

static func _gib_bake_one(mesh: Mesh, chunk_count: int) -> Array:
	var out: Array = []
	if mesh == null or mesh.get_surface_count() == 0:
		return out
	var arrays: Array = mesh.surface_get_arrays(0)
	var src_verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	if src_verts.is_empty():
		return out
	var src_norms_raw: Variant = arrays[Mesh.ARRAY_NORMAL]
	var src_uvs_raw: Variant = arrays[Mesh.ARRAY_TEX_UV]
	var src_idx_raw: Variant = arrays[Mesh.ARRAY_INDEX]

	var src_norms: PackedVector3Array = src_norms_raw if src_norms_raw != null else PackedVector3Array()
	var src_uvs: PackedVector2Array = src_uvs_raw if src_uvs_raw != null else PackedVector2Array()
	var indices: PackedInt32Array
	if src_idx_raw == null:
		indices = PackedInt32Array()
		indices.resize(src_verts.size())
		for i in src_verts.size():
			indices[i] = i
	else:
		indices = src_idx_raw

	var tri_count: int = indices.size() / 3
	if tri_count < 2:
		return out

	var aabb: AABB = AABB(src_verts[0], Vector3.ZERO)
	for v in src_verts:
		aabb = aabb.expand(v)

	var seeds: Array[Vector3] = []
	for _i in chunk_count:
		seeds.append(Vector3(
			aabb.position.x + randf() * aabb.size.x,
			aabb.position.y + randf() * aabb.size.y,
			aabb.position.z + randf() * aabb.size.z,
		))

	var buckets: Array = []
	for _i in chunk_count:
		buckets.append(PackedInt32Array())
	for t in tri_count:
		var i0: int = indices[t * 3 + 0]
		var i1: int = indices[t * 3 + 1]
		var i2: int = indices[t * 3 + 2]
		var tc: Vector3 = (src_verts[i0] + src_verts[i1] + src_verts[i2]) / 3.0
		var best: int = 0
		var best_d: float = INF
		for s in chunk_count:
			var d: float = tc.distance_squared_to(seeds[s])
			if d < best_d:
				best_d = d
				best = s
		var bucket: PackedInt32Array = buckets[best]
		bucket.append(i0)
		bucket.append(i1)
		bucket.append(i2)
		buckets[best] = bucket

	for b in chunk_count:
		var bucket_indices: PackedInt32Array = buckets[b]
		if bucket_indices.size() < 3:
			continue
		var chunk_dict: Dictionary = _gib_bake_chunk(bucket_indices, src_verts, src_norms, src_uvs)
		if not chunk_dict.is_empty():
			out.append(chunk_dict)
	return out

static func _gib_bake_chunk(
	bucket_indices: PackedInt32Array,
	src_verts: PackedVector3Array,
	src_norms: PackedVector3Array,
	src_uvs: PackedVector2Array,
) -> Dictionary:
	var local_verts: PackedVector3Array = PackedVector3Array()
	var local_norms: PackedVector3Array = PackedVector3Array()
	var local_uvs: PackedVector2Array = PackedVector2Array()
	var new_indices: PackedInt32Array = PackedInt32Array()
	var remap: Dictionary = {}
	for old_idx in bucket_indices:
		var new_idx: int
		if remap.has(old_idx):
			new_idx = int(remap[old_idx])
		else:
			new_idx = local_verts.size()
			remap[old_idx] = new_idx
			local_verts.append(src_verts[old_idx])
			if src_norms.size() > old_idx:
				local_norms.append(src_norms[old_idx])
			if src_uvs.size() > old_idx:
				local_uvs.append(src_uvs[old_idx])
		new_indices.append(new_idx)

	var chunk_centroid: Vector3 = Vector3.ZERO
	for v in local_verts:
		chunk_centroid += v
	chunk_centroid /= float(local_verts.size())
	for i in local_verts.size():
		local_verts[i] = local_verts[i] - chunk_centroid

	var chunk_aabb: AABB = AABB(local_verts[0], Vector3.ZERO)
	for v in local_verts:
		chunk_aabb = chunk_aabb.expand(v)

	var cap: Dictionary = _gib_build_cap(local_verts, new_indices)

	return {
		"verts": local_verts,
		"norms": local_norms,
		"uvs": local_uvs,
		"indices": new_indices,
		"centroid": chunk_centroid,
		"aabb": chunk_aabb,
		"cap_verts": cap.get("verts", PackedVector3Array()),
		"cap_colors": cap.get("colors", PackedColorArray()),
		"cap_indices": cap.get("indices", PackedInt32Array()),
	}

# Find boundary edges (appear exactly once) and fan-triangulate them to
# the chunk's local origin. Edges are matched by quantised vertex position
# so meshes with duplicate-position vertices (hard-edge normals, primitive
# meshes) still produce correct boundary detection.
static func _gib_build_cap(
	local_verts: PackedVector3Array,
	new_indices: PackedInt32Array,
) -> Dictionary:
	var out: Dictionary = {}
	var vert_count: int = local_verts.size()
	if vert_count == 0 or new_indices.is_empty():
		return out

	# Position-canonicalise vertices so duplicates share an identity.
	var canon: PackedInt32Array = PackedInt32Array()
	canon.resize(vert_count)
	var pos_to_canon: Dictionary = {}
	for i in vert_count:
		var p: Vector3 = local_verts[i]
		var key: Vector3i = Vector3i(
			int(round(p.x / _GIB_QUANTIZE)),
			int(round(p.y / _GIB_QUANTIZE)),
			int(round(p.z / _GIB_QUANTIZE)),
		)
		if pos_to_canon.has(key):
			canon[i] = int(pos_to_canon[key])
		else:
			var c: int = pos_to_canon.size()
			pos_to_canon[key] = c
			canon[i] = c

	var edge_counts: Dictionary = {}
	var edge_repr: Dictionary = {}  # canonical edge key → [local_a, local_b]
	var tri_count: int = new_indices.size() / 3
	for t in tri_count:
		var ia: int = new_indices[t * 3 + 0]
		var ib: int = new_indices[t * 3 + 1]
		var ic: int = new_indices[t * 3 + 2]
		var pairs: Array = [[ia, ib], [ib, ic], [ic, ia]]
		for pair in pairs:
			var a: int = pair[0]
			var b: int = pair[1]
			var ca: int = canon[a]
			var cb: int = canon[b]
			var key := Vector2i(mini(ca, cb), maxi(ca, cb))
			edge_counts[key] = int(edge_counts.get(key, 0)) + 1
			if not edge_repr.has(key):
				edge_repr[key] = [a, b]

	var boundary: Array = []
	for key: Vector2i in edge_counts.keys():
		if int(edge_counts[key]) == 1:
			boundary.append(edge_repr[key])
	if boundary.is_empty():
		return out

	var cap_verts: PackedVector3Array = PackedVector3Array()
	var cap_colors: PackedColorArray = PackedColorArray()
	var cap_indices: PackedInt32Array = PackedInt32Array()
	cap_verts.append(Vector3.ZERO)                  # apex at chunk centre
	cap_colors.append(Color(0.18, 0.01, 0.01))      # darkest deep inside
	for edge_pair in boundary:
		var v1: Vector3 = local_verts[edge_pair[0]]
		var v2: Vector3 = local_verts[edge_pair[1]]
		var i1: int = cap_verts.size()
		cap_verts.append(v1)
		cap_colors.append(_gib_flesh_color())
		var i2: int = cap_verts.size()
		cap_verts.append(v2)
		cap_colors.append(_gib_flesh_color())
		cap_indices.append(0)
		cap_indices.append(i1)
		cap_indices.append(i2)

	out["verts"] = cap_verts
	out["colors"] = cap_colors
	out["indices"] = cap_indices
	return out

static func _gib_flesh_color() -> Color:
	var t: float = randf()
	return Color(0.22, 0.015, 0.015).lerp(Color(0.92, 0.18, 0.12), t)

static func _gib_get_flesh_material() -> StandardMaterial3D:
	if _gib_flesh_material_cached != null:
		return _gib_flesh_material_cached
	var mat := StandardMaterial3D.new()
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.roughness = 0.9
	mat.metallic = 0.0
	mat.vertex_color_use_as_albedo = true
	_gib_flesh_material_cached = mat
	return _gib_flesh_material_cached

# -------------------- 2. VFX SPAWNERS (scene-scoped) --------------------

# Cached shaders + sphere meshes shared across all explosions. Lives on
# Violence so a single instance is reused process-wide; the player.gd
# version held one per Player instance.
static var _heat_mesh: SphereMesh = null
static var _heat_shader: Shader = null
static var _shock_mesh: SphereMesh = null
static var _shock_shader: Shader = null

# Bigger blasts expand further, hold a hotter core, and pump a brighter
# point light — stacked EXPLOSIVE ROUNDS cards should feel earth-shaking.
# `local_player` (optional) is the local human's player; if provided, gets a
# view-punch + is checked against the scene's exposure sidechain hook.
static func spawn_bullet_blast(scene: Node, pos: Vector3, radius: float, color: Color, local_player: Node = null) -> void:
	if scene == null:
		return
	if scene.has_method("trigger_explosion_sidechain"):
		# Uncap so big bazookas push exposure WAY down (was 1.0 cap → all
		# explosions ducked the same). Peak ~3 at radius 15+ feels properly
		# blinding for the biggest blasts.
		scene.trigger_explosion_sidechain(pos, radius, clampf(radius / 5.0, 0.35, 3.0))
	if local_player and is_instance_valid(local_player) and local_player.has_method("apply_explosion_view_punch"):
		# Allow peak > 1.0 for big blasts — uncapping makes a bazooka register
		# noticeably harder than a small grenade-class burst.
		local_player.apply_explosion_view_punch(pos, radius, clampf(radius / 5.0, 0.45, 1.6))
	var expand_time: float = clampf(0.1 + radius * 0.012, 0.12, 0.24)
	spawn_heat_distortion(scene, pos, radius, expand_time, clampf(radius * 0.012, 0.025, 0.06))
	spawn_shockwave_ring(scene, pos, radius)

	# 1) Fireball volume. Grow linearly to the effective radius while the
	# emitted light drops fast; opacity ramps up as the blast front arrives.
	var core := MeshInstance3D.new()
	var cm := SphereMesh.new()
	cm.radius = 0.25
	cm.height = 0.5
	core.mesh = cm
	var cmat := StandardMaterial3D.new()
	cmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	cmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	cmat.albedo_color = Color(1.0, 0.96, 0.86, 0.08)
	cmat.emission_enabled = true
	cmat.emission = Color(1.0, 0.88, 0.4)
	cmat.emission_energy_multiplier = 14.0
	cmat.cull_mode = BaseMaterial3D.CULL_DISABLED
	core.material_override = cmat
	core.position = pos
	scene.add_child(core)
	var ctw := core.create_tween().set_parallel(true)
	var core_target_scale := Vector3.ONE * maxf(0.01, radius / cm.radius)
	ctw.tween_property(core, "scale", core_target_scale, expand_time)\
		.set_trans(Tween.TRANS_LINEAR).set_ease(Tween.EASE_IN_OUT)
	ctw.tween_property(cmat, "albedo_color", Color(1.0, 0.62, 0.18, 0.34), expand_time * 0.52)\
		.set_trans(Tween.TRANS_LINEAR).set_ease(Tween.EASE_IN_OUT)
	ctw.tween_property(cmat, "albedo_color", Color(0.95, 0.12, 0.02, 0.0), expand_time * 0.48)\
		.set_delay(expand_time * 0.52).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	ctw.tween_property(cmat, "emission", Color(1.0, 0.34, 0.08), expand_time * 0.65)\
		.set_trans(Tween.TRANS_LINEAR).set_ease(Tween.EASE_IN_OUT)
	ctw.tween_property(cmat, "emission_energy_multiplier", 0.0, expand_time * 0.34)\
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	ctw.chain().tween_callback(core.queue_free)

	# 2) Dense blast shell. The border of the effective radius reads as a
	# briefly opaque wall rather than a faint transparent puff.
	var wave := MeshInstance3D.new()
	var wm := SphereMesh.new()
	wm.radius = 0.2
	wm.height = 0.4
	wave.mesh = wm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 0.5, 0.14, 0.02)
	mat.emission_enabled = true
	mat.emission = color.lerp(Color(1.0, 0.45, 0.08), 0.6)
	mat.emission_energy_multiplier = 4.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	wave.material_override = mat
	wave.position = pos
	scene.add_child(wave)
	var tw := wave.create_tween().set_parallel(true)
	var wave_target_scale := Vector3.ONE * maxf(0.01, (radius * 1.08) / wm.radius)
	# Shockwave expands at the speed of sound (343 m/s) so visual + audio
	# arrive together at distant viewers (audio is delayed dist/343 in SFX).
	# Min 30 ms so tiny blasts remain perceptible.
	var wave_expand_time: float = maxf(0.03, radius / 343.0)
	tw.tween_property(wave, "scale", wave_target_scale, wave_expand_time)\
		.set_trans(Tween.TRANS_LINEAR).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(mat, "albedo_color", Color(1.0, 0.42, 0.08, 0.13), wave_expand_time * 0.5)\
		.set_trans(Tween.TRANS_LINEAR).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(mat, "albedo_color", Color(0.82, 0.08, 0.01, 0.0), wave_expand_time * 0.5)\
		.set_delay(wave_expand_time * 0.5).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.tween_property(mat, "emission_energy_multiplier", 0.0, wave_expand_time * 0.28)\
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.chain().tween_callback(wave.queue_free)

	# Brief scene-wide flash — way brighter than the warm-ember decay light
	# below, but only ~60 ms so it reads as the moment-of-detonation spike.
	var flash := OmniLight3D.new()
	flash.light_color = Color(1.0, 0.98, 0.92)
	flash.light_energy = 100.0 + radius * 14.0
	flash.omni_range = maxf(40.0, radius * 6.0)
	flash.position = pos
	scene.add_child(flash)
	var ftw := flash.create_tween()
	ftw.tween_property(flash, "light_energy", 0.0, 0.06)\
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	ftw.tween_callback(flash.queue_free)

	# Bright core glow — small range, longer duration than the scene flash.
	# Reads as the white-hot fireball center hanging around as the blast
	# evolves, distinct from the scene-wide initial spike.
	var core_light := OmniLight3D.new()
	core_light.light_color = color.lerp(Color(1.0, 0.95, 0.78), 0.7)
	core_light.light_energy = 60.0 + radius * 8.0
	core_light.omni_range = maxf(8.0, radius * 1.4)
	core_light.position = pos
	scene.add_child(core_light)
	var ctlw := core_light.create_tween()
	ctlw.tween_property(core_light, "light_color", color.lerp(Color(1.0, 0.55, 0.18), 0.5), 0.12)\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	ctlw.parallel().tween_property(core_light, "light_energy", 0.0, 0.32)\
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	ctlw.tween_callback(core_light.queue_free)

	# 3) Explosion light — extremely bright at ignition, then it collapses fast.
	var light := OmniLight3D.new()
	var hot_color := color.lerp(Color(1.0, 0.98, 0.9), 0.72)
	var warm_color := color.lerp(Color(1.0, 0.6, 0.18), 0.5)
	var ember_color := color.lerp(Color(0.9, 0.16, 0.04), 0.38)
	light.light_color = hot_color
	light.light_energy = clampf(20.0 + radius * 4.5, 20.0, 48.0)
	light.omni_range = radius * 4.2
	light.position = pos
	scene.add_child(light)
	var light_dur := clampf(0.1 + radius * 0.012, 0.1, 0.22)
	var ltw := light.create_tween()
	ltw.set_parallel(true)
	ltw.tween_property(light, "light_color", warm_color, light_dur * 0.28)\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	ltw.tween_property(light, "light_color", ember_color, light_dur * 0.72)\
		.set_delay(light_dur * 0.28).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	ltw.tween_property(light, "light_energy", 0.0, light_dur)\
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	ltw.tween_callback(light.queue_free)

	# 4) Big blasts play the full explosion SFX; smaller impacts stay visual.
	if radius >= 3.5:
		# Bench A/B isolation — gated by BenchFlags so production hits one
		# static bool branch instead of a scene-root .get() lookup.
		if not (BenchFlags.active and BenchFlags.no_explosion_audio):
			SFX.explosion(pos, radius)

static func spawn_heat_distortion(scene: Node, pos: Vector3, radius: float, duration: float, strength: float) -> void:
	if scene == null:
		return
	var shell := MeshInstance3D.new()
	if _heat_mesh == null:
		_heat_mesh = SphereMesh.new()
		_heat_mesh.radius = 0.22
		_heat_mesh.height = 0.44
		_heat_mesh.radial_segments = 20
		_heat_mesh.rings = 10
	shell.mesh = _heat_mesh
	if _heat_shader == null:
		_heat_shader = Shader.new()
		_heat_shader.code = """
			shader_type spatial;
			render_mode unshaded, cull_disabled, depth_draw_never;

			uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
			uniform float distortion_strength = 0.04;
			uniform float zoom_strength = 0.015;
			uniform float opacity = 0.18;

			void fragment() {
				vec3 n = normalize((VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
				float fresnel = pow(1.0 - abs(dot(normalize(VIEW), NORMAL)), 2.4);
				vec2 offset = n.xy * distortion_strength * fresnel;
				vec2 zoom = (SCREEN_UV - vec2(0.5)) * zoom_strength * fresnel;
				vec2 uv = SCREEN_UV - zoom + offset;
				vec3 col = texture(screen_tex, uv).rgb;
				ALBEDO = col;
				ALPHA = opacity * fresnel;
			}
		"""
	var mat := ShaderMaterial.new()
	mat.shader = _heat_shader
	mat.set_shader_parameter("distortion_strength", strength * 2.4)
	mat.set_shader_parameter("zoom_strength", strength * 0.9)
	mat.set_shader_parameter("opacity", 0.34)
	shell.material_override = mat
	shell.position = pos
	scene.add_child(shell)

	var target_scale := Vector3.ONE * maxf(0.01, (radius * 1.85) / _heat_mesh.radius)
	var tw := shell.create_tween().set_parallel(true)
	tw.tween_property(shell, "scale", target_scale, duration)\
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.tween_method(
		func(v: float) -> void: mat.set_shader_parameter("distortion_strength", v),
		strength,
		0.0,
		duration * 0.85
	).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.tween_method(
		func(v: float) -> void: mat.set_shader_parameter("zoom_strength", v),
		strength * 0.35,
		0.0,
		duration * 0.85
	).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.tween_method(
		func(v: float) -> void: mat.set_shader_parameter("opacity", v),
		0.34,
		0.0,
		duration * 0.72
	).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.chain().tween_callback(shell.queue_free)

# Thin-shell screen-space shockwave: sphere expanding at the speed of sound.
# High-power fresnel concentrates the pixel displacement on the silhouette
# ring so the camera sees a thin distorted halo travelling outward — the
# "shock front" — while the heat distortion handles the slower bloom.
static func spawn_shockwave_ring(scene: Node, pos: Vector3, radius: float) -> void:
	if scene == null:
		return
	var shell := MeshInstance3D.new()
	if _shock_mesh == null:
		_shock_mesh = SphereMesh.new()
		_shock_mesh.radius = 0.25
		_shock_mesh.height = 0.5
		_shock_mesh.radial_segments = 32
		_shock_mesh.rings = 16
	shell.mesh = _shock_mesh
	if _shock_shader == null:
		_shock_shader = Shader.new()
		_shock_shader.code = """
			shader_type spatial;
			render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

			uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
			uniform float distortion_strength = 0.05;
			uniform float ring_thickness = 7.0;
			uniform float opacity = 0.9;

			void fragment() {
				// High exponent -> energy concentrated on silhouette ring only.
				float fresnel = pow(1.0 - abs(dot(normalize(VIEW), NORMAL)), ring_thickness);
				vec3 n = normalize((VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
				vec2 offset = n.xy * distortion_strength * fresnel;
				vec3 col = texture(screen_tex, SCREEN_UV + offset).rgb;
				ALBEDO = col;
				ALPHA = fresnel * opacity;
			}
		"""
	var mat := ShaderMaterial.new()
	mat.shader = _shock_shader
	mat.set_shader_parameter("distortion_strength", 0.05)
	mat.set_shader_parameter("ring_thickness", 7.0)
	mat.set_shader_parameter("opacity", 0.9)
	shell.material_override = mat
	shell.position = pos
	scene.add_child(shell)
	# Sound-speed expansion (matches audio delay) with 30 ms minimum so
	# tiny blasts remain visible.
	var dur: float = maxf(0.03, radius / 343.0)
	var target_scale := Vector3.ONE * maxf(0.01, (radius * 1.05) / _shock_mesh.radius)
	var tw := shell.create_tween().set_parallel(true)
	tw.tween_property(shell, "scale", target_scale, dur)\
		.set_trans(Tween.TRANS_LINEAR).set_ease(Tween.EASE_OUT)
	tw.tween_method(
		func(v: float) -> void: mat.set_shader_parameter("distortion_strength", v),
		0.05,
		0.0,
		dur
	).set_trans(Tween.TRANS_LINEAR).set_ease(Tween.EASE_OUT)
	tw.tween_method(
		func(v: float) -> void: mat.set_shader_parameter("opacity", v),
		0.9,
		0.0,
		dur * 0.9
	).set_trans(Tween.TRANS_LINEAR).set_ease(Tween.EASE_OUT)
	tw.chain().tween_callback(shell.queue_free)

# `vfx_max_*`: caller passes the budget caps so the global VFX flag stays
# in player.gd (along with all other dev toggles).
static func spawn_impact(scene: Node, pos: Vector3, color: Color = Color(1.0, 0.9, 0.3), scale_f: float = 1.0, dmg_ratio: float = 1.0, vfx_max_impact_dust: int = 5) -> void:
	if scene == null:
		return
	# Heavier guns leave a bigger crater of dust + a brighter spark, and once
	# damage is very high we add a second "heat flash" — as if the slug is
	# hot enough to burn the ground it lands in.
	var sz: float = scale_f * sqrt(dmg_ratio)
	var spark_boost: float = lerpf(1.0, 2.5, clampf((dmg_ratio - 1.0) / 4.0, 0.0, 1.0))

	# Heavy hits flash a brief colored point light at the impact. Pistol-base
	# shots stay dark so the GPU doesn't burn cycles on every plink.
	if dmg_ratio > 1.4:
		var light := OmniLight3D.new()
		light.light_color = color
		light.light_energy = 3.5 * scale_f * spark_boost
		light.omni_range = 2.2 * sz
		light.position = pos
		scene.add_child(light)
		var ltw := light.create_tween()
		ltw.tween_property(light, "light_energy", 0.0, 0.12) \
			.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
		ltw.tween_callback(light.queue_free)

	# Heat flash: a very brief, almost-white burst for very-high-damage hits.
	if dmg_ratio > 2.2:
		var heat := OmniLight3D.new()
		heat.light_color = Color(1.0, 0.88, 0.65)
		heat.light_energy = 6.0 + 3.0 * dmg_ratio
		heat.omni_range = 1.4 + 0.45 * dmg_ratio
		heat.position = pos
		scene.add_child(heat)
		var htw := heat.create_tween()
		htw.tween_property(heat, "light_energy", 0.0, 0.08) \
			.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
		htw.tween_callback(heat.queue_free)

	# A handful of dust particles scattering outward and falling.
	var dust_count: int = min(vfx_max_impact_dust, int(round(5.0 * sqrt(dmg_ratio))))
	for i in dust_count:
		var dust := MeshInstance3D.new()
		var m := SphereMesh.new()
		m.radius = 0.035 * sz
		m.height = 0.07 * sz
		m.radial_segments = 6
		m.rings = 3
		dust.mesh = m
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(0.72, 0.66, 0.55, 0.75)
		dust.material_override = mat
		dust.position = pos
		scene.add_child(dust)
		var dir := Vector3(
			randf_range(-1.0, 1.0),
			randf_range(0.1, 1.0),
			randf_range(-1.0, 1.0),
		).normalized()
		var end := pos + dir * randf_range(0.25, 0.7) * sz
		var tw := dust.create_tween().set_parallel(true)
		tw.tween_property(dust, "position", end, 0.35) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tw.tween_property(mat, "albedo_color", Color(0.72, 0.66, 0.55, 0.0), 0.4)
		tw.chain().tween_callback(dust.queue_free)

static func spawn_blood(scene: Node, pos: Vector3, dir: Vector3, dmg_ratio: float, vfx_max_blood_drops: int = 8) -> void:
	if scene == null:
		return
	# Dark-red cloud with a short red-lit core. Spatter biases in the bullet's
	# travel direction (through the body) plus a random scatter cone.
	var sz: float = sqrt(dmg_ratio)
	var count: int = min(vfx_max_blood_drops, int(round(8.0 * sz)))

	# Hard hits emit a brief deep-red flash on the wound site.
	if dmg_ratio > 1.4:
		var light := OmniLight3D.new()
		light.light_color = Color(0.8, 0.05, 0.05)
		light.light_energy = 2.5 * sz
		light.omni_range = 1.3 * sz
		light.position = pos
		scene.add_child(light)
		var lt := light.create_tween()
		lt.tween_property(light, "light_energy", 0.0, 0.18)\
			.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
		lt.tween_callback(light.queue_free)

	for i in count:
		var drop := MeshInstance3D.new()
		var m := SphereMesh.new()
		m.radius = randf_range(0.04, 0.09) * sz
		m.height = m.radius * 2.0
		m.radial_segments = 5
		m.rings = 3
		drop.mesh = m
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		var shade := randf_range(0.28, 0.55)
		mat.albedo_color = Color(shade, 0.03, 0.02, 0.9)
		drop.material_override = mat
		drop.position = pos
		scene.add_child(drop)
		var scatter := Vector3(randf_range(-0.8, 0.8), randf_range(-0.3, 0.9),
			randf_range(-0.8, 0.8)).normalized()
		var spray: Vector3 = (dir * randf_range(0.3, 0.9) + scatter * randf_range(0.4, 1.1)).normalized()
		var travel := randf_range(0.45, 1.2) * sz
		var end := pos + spray * travel + Vector3.DOWN * 0.25 * sz
		var dur := randf_range(0.35, 0.55)
		var tw := drop.create_tween().set_parallel(true)
		tw.tween_property(drop, "position", end, dur)\
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tw.tween_property(mat, "albedo_color", Color(shade, 0.03, 0.02, 0.0), dur * 1.1)
		tw.chain().tween_callback(drop.queue_free)

static func spawn_gib_mist(
	scene: Node,
	pos: Vector3,
	dir: Vector3,
	intensity: float,
	blast_radius: float = 0.0,
	blast_severity: float = 0.0
) -> void:
	if scene == null:
		return
	var dir_n := dir.normalized() if dir.length_squared() > 0.001 else Vector3.UP
	var chaos := blast_severity * clampf(intensity / maxf(Weapon.BASE_KNOCKBACK, 0.001), 0.6, 2.4)
	var count: int = clampi(int(round(8.0 + intensity * 2.5 + blast_radius * 0.25 + chaos * 10.0)), 8, 28)
	var spread: float = 0.45 + blast_radius * 0.03 + chaos * 0.14
	var base_travel: float = 0.9 + intensity * 0.22 + blast_radius * 0.05 + chaos * 0.9
	var base_size: float = 0.12 + intensity * 0.018 + chaos * 0.04

	for i in count:
		var puff := MeshInstance3D.new()
		var mesh := SphereMesh.new()
		mesh.radius = randf_range(base_size * 0.6, base_size * 1.2)
		mesh.height = mesh.radius * 2.0
		mesh.radial_segments = 6
		mesh.rings = 4
		puff.mesh = mesh
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		var shade := randf_range(0.28, 0.52)
		mat.albedo_color = Color(shade, 0.02, 0.02, randf_range(0.2, 0.42))
		mat.emission_enabled = true
		mat.emission = Color(0.4, 0.02, 0.02)
		mat.emission_energy_multiplier = 0.1
		puff.material_override = mat
		puff.position = pos + Vector3(
			randf_range(-0.08, 0.08),
			randf_range(-0.08, 0.08),
			randf_range(-0.08, 0.08)
		)
		scene.add_child(puff)

		var scatter := Vector3(
			randf_range(-spread, spread),
			randf_range(-0.22, 0.45),
			randf_range(-spread, spread)
		)
		var travel_dir := (dir_n + scatter).normalized()
		var end := puff.position + travel_dir * randf_range(base_travel * 0.65, base_travel * 1.2)
		var dur := randf_range(0.35, 0.68)
		var tw := puff.create_tween().set_parallel(true)
		tw.tween_property(puff, "position", end, dur)\
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tw.tween_property(puff, "scale", Vector3.ONE * randf_range(1.8, 2.8), dur)\
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		tw.tween_property(mat, "albedo_color", Color(shade, 0.02, 0.02, 0.0), dur)\
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		tw.chain().tween_callback(puff.queue_free)

static func spawn_blast_blood_splash(scene: Node, pos: Vector3, dir: Vector3, severity: float) -> void:
	if severity <= 0.08 or scene == null:
		return
	var dir_n := dir.normalized() if dir.length_squared() > 0.001 else Vector3.UP
	var count := clampi(int(round(5.0 + severity * 10.0)), 5, 14)
	for i in count:
		var splash := MeshInstance3D.new()
		var mesh := SphereMesh.new()
		mesh.radius = randf_range(0.06, 0.12) * lerpf(0.9, 1.5, severity)
		mesh.height = mesh.radius * 2.0
		mesh.radial_segments = 5
		mesh.rings = 3
		splash.mesh = mesh
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.albedo_color = Color(randf_range(0.3, 0.46), 0.02, 0.02, randf_range(0.18, 0.34))
		splash.material_override = mat
		splash.position = pos
		scene.add_child(splash)
		var scatter := Vector3(
			randf_range(-0.9, 0.9),
			randf_range(-0.25, 0.85),
			randf_range(-0.9, 0.9)
		)
		var end := pos + (dir_n + scatter).normalized() * randf_range(0.6, 1.5) * lerpf(0.8, 1.8, severity)
		var dur := randf_range(0.22, 0.42)
		var tw := splash.create_tween().set_parallel(true)
		tw.tween_property(splash, "position", end, dur)\
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tw.tween_property(splash, "scale", Vector3.ONE * randf_range(1.2, 1.9), dur)\
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		tw.tween_property(mat, "albedo_color", Color(mat.albedo_color.r, 0.02, 0.02, 0.0), dur)\
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		tw.chain().tween_callback(splash.queue_free)

# -------------------- 3. PLAYER-COUPLED HELPERS --------------------
#
# These take a `player` Node and read/mutate its state. Player.gd's @rpc
# methods delegate here.

# Apply / clear the squinty `>_<` hit face by toggling eye-mesh visibility.
static func set_hit_face_state(player: Node, active: bool) -> void:
	if player == null:
		return
	var eye_left: Node = player.get("eye_left")
	if eye_left:
		eye_left.visible = not active
	var eye_right: Node = player.get("eye_right")
	if eye_right:
		eye_right.visible = not active
	var pupil_left: Node = player.get("pupil_left")
	if pupil_left:
		pupil_left.visible = not active
	var pupil_right: Node = player.get("pupil_right")
	if pupil_right:
		pupil_right.visible = not active
	var hit_eye_left: Node = player.get("hit_eye_left")
	if hit_eye_left:
		hit_eye_left.visible = active
	var hit_eye_right: Node = player.get("hit_eye_right")
	if hit_eye_right:
		hit_eye_right.visible = active

# Authority-only: schedule the view punch with a speed-of-sound delay so the
# shake arrives in sync with the audio + visual shockwave.
static func apply_explosion_view_punch(player: Node, pos: Vector3, radius: float, peak: float = 1.0) -> void:
	if player == null or not player.is_multiplayer_authority():
		return
	var camera: Node = player.get("camera")
	if camera == null:
		return
	var to_player: Vector3 = player.global_position - pos
	var dist: float = to_player.length()
	# Felt-radius is 5× the visible blast — distant players still get a
	# tremor; nearby players get a real kick.
	var effect_radius := maxf(radius * 5.0, radius + 1.0)
	if dist >= effect_radius:
		return
	var delay: float = dist / 343.0
	if delay < 0.01:
		do_explosion_view_punch(player, pos, radius, peak)
	else:
		player.get_tree().create_timer(delay).timeout.connect(func() -> void:
			if is_instance_valid(player):
				do_explosion_view_punch(player, pos, radius, peak))

static func do_explosion_view_punch(player: Node, pos: Vector3, radius: float, peak: float) -> void:
	if player == null or player.get("camera") == null:
		return
	# Recompute distance — the player may have moved during the propagation.
	var to_player: Vector3 = player.global_position - pos
	var dist: float = to_player.length()
	var effect_radius := maxf(radius * 5.0, radius + 1.0)
	if dist >= effect_radius:
		return
	# Linear-ish falloff (was pow 1.6 — too steep for big blasts at range).
	# Now a 24m bazooka at 60m still hits at strength ~0.5 * peak.
	var linear: float = clampf(1.0 - dist / effect_radius, 0.0, 1.0)
	var strength: float = pow(linear, 1.0) * peak
	if strength <= 0.0:
		return
	var away_dir := to_player.normalized() if dist > 0.001 else Vector3.UP
	var local_dir: Vector3 = player.global_transform.basis.inverse() * away_dir
	player.set("_view_punch_pos", player.get("_view_punch_pos") + local_dir * (0.09 + 0.33 * strength))
	player.set("_view_punch_rot", player.get("_view_punch_rot") + Vector3(
		-local_dir.y * (0.045 + 0.165 * strength),
		local_dir.x * (0.018 + 0.084 * strength),
		-local_dir.x * (0.024 + 0.114 * strength),
	))
	player.set("shake_amt", maxf(player.get("shake_amt"), 0.015 + 0.15 * strength))

# -------------------- ragdoll / death --------------------

# Recursively gather all MeshInstance3D nodes under a subtree.
static func collect_meshes(node: Node, out: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		out.append(node)
	for child in node.get_children():
		collect_meshes(child, out)

# Hide first-person gun + drop hitboxes off their layer so a corpse can't be
# shot or seen with a floating gun.
static func set_dead_visuals(player: Node, dead: bool) -> void:
	var muzzle: Node = player.get("muzzle")
	if muzzle:
		muzzle.visible = not dead
	var layer: int = 0 if dead else 2
	var head_hitbox: Node = player.get("head_hitbox")
	if head_hitbox:
		head_hitbox.collision_layer = layer
	var torso_hitbox: Node = player.get("torso_hitbox")
	if torso_hitbox:
		torso_hitbox.collision_layer = layer
	var legs_hitbox: Node = player.get("legs_hitbox")
	if legs_hitbox:
		legs_hitbox.collision_layer = layer

# Full death sequence: snap the hit face on, hide the body, spawn the
# Voronoi-shattered corpse, drop hitboxes off their layer.
static func do_ragdoll(
	player: Node,
	push_dir: Vector3,
	force_origin: Vector3 = Vector3.INF,
	gib_force: float = 0.0,
	blast_radius: float = 0.0,
	blast_severity: float = 0.0,
	is_head: bool = false,
) -> void:
	if player == null:
		return
	# Switch to the squinty `>_<` face so the cloned ragdoll meshes inherit
	# that state. Done BEFORE hiding the body so visibility checks during
	# cloning still reflect the (about-to-be-hidden) authored tree.
	set_hit_face_state(player, true)
	player.set("_hit_face_timer", 0.0)  # don't let _process auto-revert on the dead body
	spawn_ragdoll(player, push_dir, force_origin, gib_force, blast_radius, blast_severity, is_head)
	# Every peer simulates its own corpse — cosmetic desync is fine.
	var body_model: Node = player.get("body_model")
	if body_model:
		body_model.visible = false
	set_dead_visuals(player, true)

static func spawn_ragdoll(
	player: Node,
	push_dir: Vector3,
	force_origin: Vector3 = Vector3.INF,
	gib_force: float = 0.0,
	blast_radius: float = 0.0,
	blast_severity: float = 0.0,
	is_head: bool = false,
) -> void:
	# Voronoi-split the blob's primitive meshes into chunks that fly apart.
	# body_model is hidden first so the user only reads the flying debris.
	# Chunks collide with world only — players and bullets ignore the corpse.
	var scene: Node = player.get_tree().current_scene
	var inferred_force: float = push_dir.length()
	if gib_force > 0.0:
		inferred_force = maxf(inferred_force, gib_force)
	var kb_mag: float = clampf(sqrt(maxf(inferred_force, 1.0)), 1.0, 2.6)
	var dir_n: Vector3 = push_dir.normalized() if push_dir.length_squared() > 0.01 else Vector3.UP
	var chaos := 0.0
	if blast_radius > 0.0:
		chaos = clampf(blast_severity * clampf(gib_force / maxf(Weapon.BASE_KNOCKBACK, 0.001), 0.6, 1.8), 0.0, 1.1)
	var blast_lift := 0.2
	if blast_radius > 0.0:
		blast_lift = 0.2 + chaos * 0.06
	var base_vel: Vector3 = dir_n * randf_range(2.2, 3.9) * kb_mag * (1.0 + chaos * 0.18) \
		+ Vector3.UP * randf_range(1.2, 2.8) * kb_mag * (1.0 + blast_lift)
	var burst_strength: float = 1.45 * kb_mag
	if blast_radius > 0.0:
		burst_strength *= 1.0 + clampf(blast_radius / 12.0, 0.0, 0.25) + chaos * 0.2

	var meshes: Array[MeshInstance3D] = []
	var body_model: Node = player.get("body_model")
	if body_model:
		collect_meshes(body_model, meshes)
	if meshes.is_empty():
		return
	var mist_origin: Vector3 = force_origin if force_origin != Vector3.INF else (player.global_position as Vector3) + Vector3.UP * 0.4
	spawn_gib_mist(scene, mist_origin, dir_n, kb_mag, blast_radius, blast_severity)
	if blast_radius > 0.0:
		spawn_blast_blood_splash(scene, mist_origin, dir_n, blast_severity)
	# Fixed chunk_count so the gib cache stays at one key per source mesh.
	var chunk_count: int = GIB_CHUNK_COUNT
	var impact_blood_strength := clampf(0.18 + kb_mag * 0.12 + chaos * 0.22, 0.15, 1.0)

	# Three death modes:
	#   • Explosion (blast_radius > 0): chunk every body mesh — full disintegrate.
	#   • Headshot: head pops off as one body, the rest stays connected.
	#   • Regular hit: whole body tumbles as a single rigid body.
	var local_is_authority: bool = player.is_multiplayer_authority() and not bool(player.get("is_bot"))
	var ragdoll_pieces: Array = player.get("_ragdoll_pieces")
	if blast_radius > 0.0:
		var first: bool = true
		for src in meshes:
			if src.mesh == null:
				continue
			var chunks: Array[RigidBody3D] = gib_explode(
				src.mesh,
				src.global_transform,
				scene,
				src.material_override,
				base_vel + Vector3(randf_range(-1.5, 1.5), 0, randf_range(-1.5, 1.5)),
				burst_strength,
				chunk_count,
				14.0,
				force_origin,
				impact_blood_strength,
			)
			if chunks.is_empty():
				continue
			if first and local_is_authority:
				player.set("_ragdoll_head", chunks[0])
				if scene.has_method("show_death_effect"):
					scene.show_death_effect(true)
				first = false
			for c in chunks:
				ragdoll_pieces.append(c)
	else:
		# Split head subtree from torso so headshots can launch the head alone.
		var head_meshes: Array[MeshInstance3D] = []
		var head_blob: Node = player.get("head_blob")
		if is_head and head_blob:
			collect_meshes(head_blob, head_meshes)
		var torso_meshes: Array[MeshInstance3D] = []
		for m in meshes:
			if not head_meshes.has(m):
				torso_meshes.append(m)
		var torso_rb: RigidBody3D = gib_body_ragdoll(
			(body_model as Node3D).global_transform, torso_meshes, scene,
			base_vel + Vector3(randf_range(-0.6, 0.6), 0, randf_range(-0.6, 0.6)),
			4.0, 14.0,
		)
		if torso_rb:
			ragdoll_pieces.append(torso_rb)
			if local_is_authority:
				player.set("_ragdoll_head", torso_rb)
				if scene.has_method("show_death_effect"):
					scene.show_death_effect(true)
		if not head_meshes.is_empty():
			var head_v: Vector3 = base_vel + dir_n * 6.0 + Vector3.UP * 8.0
			var head_rb: RigidBody3D = gib_body_ragdoll(
				(head_blob as Node3D).global_transform, head_meshes, scene,
				head_v, 18.0, 14.0,
			)
			if head_rb:
				ragdoll_pieces.append(head_rb)
				# Camera prefers the popping head over the torso.
				if local_is_authority:
					player.set("_ragdoll_head", head_rb)

# Free all spawned ragdoll pieces and restore body visibility / hitbox layers.
# Caller is responsible for calling _apply_ghost_visuals() afterward (since
# that touches Player-private rendering knobs).
static func clear_ragdoll(player: Node) -> void:
	var pieces: Array = player.get("_ragdoll_pieces")
	for piece in pieces:
		if is_instance_valid(piece):
			piece.queue_free()
	pieces.clear()
	set_dead_visuals(player, false)

static func apply_knockback(player: Node, impulse: Vector3) -> void:
	if bool(player.get("ghost_mode")) or bool(player.get("frozen")) or not player.is_multiplayer_authority():
		return
	player.set("velocity", player.get("velocity") + impulse)
