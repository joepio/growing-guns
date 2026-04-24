extends RefCounted

# Voronoi-splits a Mesh into random chunks and spawns each as a RigidBody3D.
# Triangles are bucketed by which random seed their centroid is nearest to.
# Each chunk's cut boundary is capped with a fan of flesh triangles (vertex-
# coloured dark red, double-sided) so tumbling chunks show meaty innards
# instead of reading as hollow shells.
#
# The Voronoi bake is expensive (~tens of ms per mesh), so results are
# cached and ideally pre-built on a worker thread via Gib.warm_tree(node)
# at map load. `explode()` picks one of the cached variants and just
# instantiates ArrayMeshes + RigidBody3Ds — near-free at runtime.

const _VARIANTS_PER_MESH := 3
const _QUANTIZE := 0.0001

# [mesh, chunk_count] → Array[variant]; each variant is Array[chunk_dict].
static var _cache: Dictionary = {}
static var _cache_mutex: Mutex = Mutex.new()
static var _flesh_material_cached: StandardMaterial3D = null
static var _blood_splat_material_cached: StandardMaterial3D = null

# Kick off async bakes for every MeshInstance3D under `root`. Idempotent;
# subsequent calls with the same mesh/chunk_count are no-ops.
static func warm_tree(root: Node, chunk_count: int = 4) -> void:
	if root == null:
		return
	var meshes: Array[Mesh] = []
	_collect_meshes(root, meshes)
	for m in meshes:
		warm(m, chunk_count)

static func warm(mesh: Mesh, chunk_count: int = 4) -> void:
	if mesh == null:
		return
	var key: Array = [mesh, chunk_count]
	_cache_mutex.lock()
	var present: bool = _cache.has(key)
	if not present:
		_cache[key] = null  # reserve slot so concurrent warms dedupe
	_cache_mutex.unlock()
	if present:
		return
	WorkerThreadPool.add_task(_warm_task.bind(mesh, chunk_count), false, "Gib.warm")

static func _warm_task(mesh: Mesh, chunk_count: int) -> void:
	var variants: Array = _build_variants(mesh, chunk_count)
	_cache_mutex.lock()
	_cache[[mesh, chunk_count]] = variants
	_cache_mutex.unlock()

static func _collect_meshes(node: Node, out: Array[Mesh]) -> void:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		var m: Mesh = (node as MeshInstance3D).mesh
		if not out.has(m):
			out.append(m)
	for child in node.get_children():
		_collect_meshes(child, out)

# Grab (or synchronously build) the variants for this mesh+chunk_count.
# The synchronous fallback fires only if `warm()` wasn't called in time —
# a first-kill hitch rather than a per-kill hitch.
static func _get_variants(mesh: Mesh, chunk_count: int) -> Array:
	var key: Array = [mesh, chunk_count]
	_cache_mutex.lock()
	var cached: Variant = _cache.get(key)
	_cache_mutex.unlock()
	if cached is Array:
		return cached
	var variants: Array = _build_variants(mesh, chunk_count)
	_cache_mutex.lock()
	var latest: Variant = _cache.get(key)
	if latest is Array:
		variants = latest  # another thread raced us — prefer its result
	else:
		_cache[key] = variants
	_cache_mutex.unlock()
	return variants

static func explode(
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
	var variants: Array = _get_variants(mesh, chunk_count)
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
	var flesh_material: StandardMaterial3D = _get_flesh_material()

	var body_basis: Basis = source_transform.basis.orthonormalized()
	for chunk in chunks:
		var rb: RigidBody3D = _instantiate_chunk(
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

static func _instantiate_chunk(
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
	if chunk_material:
		mi.set_surface_override_material(0, chunk_material)
	if has_cap and flesh_material:
		mi.set_surface_override_material(1, flesh_material)
	rb.add_child(mi)

	var cs: CollisionShape3D = CollisionShape3D.new()
	var box_shape: BoxShape3D = BoxShape3D.new()
	var sz: Vector3 = chunk_aabb.size
	box_shape.size = Vector3(maxf(sz.x, 0.05), maxf(sz.y, 0.05), maxf(sz.z, 0.05))
	cs.shape = box_shape
	cs.position = chunk_aabb.position + chunk_aabb.size * 0.5
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
		_on_chunk_body_entered(rb, scene, impact_blood_strength)
	)
	return rb

static func _on_chunk_body_entered(rb: RigidBody3D, scene: Node, strength: float) -> void:
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
	_spawn_blood_splat(scene, hit.position, hit.normal, dir, strength)

static func _spawn_blood_splat(
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
	splat.material_override = _get_blood_splat_material()
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

static func _get_blood_splat_material() -> StandardMaterial3D:
	if _blood_splat_material_cached:
		return _blood_splat_material_cached
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_DISABLED
	_blood_splat_material_cached = mat
	return mat

# -------------------- baking (thread-safe) --------------------

static func _build_variants(mesh: Mesh, chunk_count: int) -> Array:
	var variants: Array = []
	for _i in _VARIANTS_PER_MESH:
		variants.append(_bake_one(mesh, chunk_count))
	return variants

static func _bake_one(mesh: Mesh, chunk_count: int) -> Array:
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
		var chunk_dict: Dictionary = _bake_chunk(bucket_indices, src_verts, src_norms, src_uvs)
		if not chunk_dict.is_empty():
			out.append(chunk_dict)
	return out

static func _bake_chunk(
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

	var cap: Dictionary = _build_cap(local_verts, new_indices)

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
static func _build_cap(
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
			int(round(p.x / _QUANTIZE)),
			int(round(p.y / _QUANTIZE)),
			int(round(p.z / _QUANTIZE)),
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
		cap_colors.append(_flesh_color())
		var i2: int = cap_verts.size()
		cap_verts.append(v2)
		cap_colors.append(_flesh_color())
		cap_indices.append(0)
		cap_indices.append(i1)
		cap_indices.append(i2)

	out["verts"] = cap_verts
	out["colors"] = cap_colors
	out["indices"] = cap_indices
	return out

static func _flesh_color() -> Color:
	var t: float = randf()
	return Color(0.22, 0.015, 0.015).lerp(Color(0.92, 0.18, 0.12), t)

static func _get_flesh_material() -> StandardMaterial3D:
	if _flesh_material_cached != null:
		return _flesh_material_cached
	var mat := StandardMaterial3D.new()
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.roughness = 0.9
	mat.metallic = 0.0
	mat.vertex_color_use_as_albedo = true
	_flesh_material_cached = mat
	return _flesh_material_cached
