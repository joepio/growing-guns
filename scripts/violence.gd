class_name Violence extends RefCounted

# Default chunk count when fracturing a body. Must match the value used by
# gib_warm_tree() at scene load — varying it forces synchronous bakes on the
# main thread (~200ms per mesh).
const GIB_CHUNK_COUNT := 5
# Killing blow that would leave health here or lower → full body disintegrate.
const OVERKILL_DISINTEGRATE_HEALTH := -50

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

static func gib_warm_sync(mesh: Mesh, chunk_count: int = GIB_CHUNK_COUNT) -> void:
	if mesh == null:
		return
	var key: Array = [mesh, chunk_count]
	_gib_cache_mutex.lock()
	var cached: Variant = _gib_cache.get(key)
	if cached is Array:
		_gib_cache_mutex.unlock()
		return
	_gib_cache_mutex.unlock()
	var variants: Array = _gib_build_variants(mesh, chunk_count)
	_gib_cache_mutex.lock()
	if _gib_cache.get(key) is Array:
		_gib_cache_mutex.unlock()
		return
	_gib_cache[key] = variants
	_gib_cache_mutex.unlock()

static func gib_warm_tree_sync(root: Node, chunk_count: int = GIB_CHUNK_COUNT) -> void:
	if root == null:
		return
	var meshes: Array[Mesh] = []
	_gib_collect_meshes(root, meshes)
	for m in meshes:
		gib_warm_sync(m, chunk_count)

# Bake every player-body gib variant up front so the first overkill /
# disintegration never hitches on the main thread.
static func prewarm_disintegration_cache() -> void:
	_gib_get_flesh_material()
	var player_scene: PackedScene = load("res://scenes/player.tscn") as PackedScene
	if player_scene:
		var temp: Node = player_scene.instantiate()
		var body_model: Node = temp.get_node_or_null("BodyModel")
		if body_model:
			gib_warm_tree_sync(body_model, GIB_CHUNK_COUNT)
		temp.free()
	# Bots swap HeadBlob to a box — warm that mesh too.
	var bot_head := BoxMesh.new()
	bot_head.size = Vector3(0.78, 0.78, 0.78)
	gib_warm_sync(bot_head, GIB_CHUNK_COUNT)


# Force the GPU to compile `mat`'s render pipeline (PSO) now, during a quiet
# window (round start), instead of synchronously on the material's first
# in-fight draw — that first draw stalls the render thread for ~100-250ms.
# Renders the material on a sub-pixel sphere at the scene origin for a few
# frames, then self-frees. Mirrors grenade.gd's warmup_shaders; the per-effect
# warmers (warmup_blast_materials, IonCannon.warmup_shaders,
# Player.warmup_phoenix_shaders) build their real materials and route them here.
static func warmup_material(scene: Node, mat: Material) -> void:
	if scene == null or mat == null:
		return
	var mi := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.001
	sphere.height = 0.002
	mi.mesh = sphere
	mi.material_override = mat
	# Park at the origin so it's actually rendered (compiles the PSO) but at
	# sub-pixel scale so it's invisible.
	_attach_world_3d(scene, mi, Vector3.ZERO)
	var t := Timer.new()
	t.wait_time = 0.4
	t.one_shot = true
	t.process_mode = Node.PROCESS_MODE_ALWAYS
	mi.add_child(t)
	t.start()
	t.timeout.connect(mi.queue_free)


# Pre-compile the explosion fireball material PSO. The screen-space heat +
# shock distortion shaders are warmed separately by grenade.warmup_shaders;
# this covers the additive emissive shell every blast spawns via
# _spawn_blast_fireball. (The cluster-pop core + phoenix column share their PSO
# with the phoenix-column material, warmed in Player.warmup_phoenix_shaders.)
static func warmup_blast_materials(scene: Node) -> void:
	if scene == null:
		return
	var fireball := StandardMaterial3D.new()
	_configure_blast_fireball_mat(fireball, Color(1.0, 0.78, 0.42), 0.88, 16.0)
	warmup_material(scene, fireball)
	# Fused fire/smoke billow runs on a MultiMesh — instanced rendering is its own
	# PSO, so warm it with an actual (sub-pixel) MultiMesh, not a plain mesh.
	var billow := ShaderMaterial.new()
	billow.shader = _get_billow_mm_shader()
	billow.set_shader_parameter("anim", 0.3)
	_warmup_mm_material(scene, billow)
	# Additive MultiMesh projectile shader (embers + shards) — its own PSO.
	var proj := ShaderMaterial.new()
	proj.shader = _get_blast_projectile_shader()
	proj.set_shader_parameter("anim", 0.3)
	_warmup_mm_material(scene, proj)


# Like warmup_material but compiles the instanced (MultiMesh) PSO variant.
static func _warmup_mm_material(scene: Node, mat: Material) -> void:
	if scene == null or mat == null:
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = _get_smoke_billow_mesh()
	mm.instance_count = 1
	mm.set_instance_transform(0, Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.001), Vector3.ZERO))
	mm.set_instance_color(0, Color(1, 1, 1, 0.5))
	mm.set_instance_custom_data(0, Color(0.5, 0.0, 0.5, 0.0))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	_attach_world_3d(scene, mmi, Vector3.ZERO)
	var t := Timer.new()
	t.wait_time = 0.4
	t.one_shot = true
	t.process_mode = Node.PROCESS_MODE_ALWAYS
	mmi.add_child(t)
	t.start()
	t.timeout.connect(mmi.queue_free)

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
		# Bind the body's own queue_free: an early free (round reset clears the
		# world) auto-disconnects the connection instead of invoking a lambda
		# whose captured `rb` was already freed ("Lambda capture was freed").
		scene.get_tree().create_timer(lifetime).timeout.connect(rb.queue_free)
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
	# Bind the body's own queue_free so an early free auto-disconnects instead
	# of erroring on a freed lambda capture (see other cleanup sites).
	scene.get_tree().create_timer(lifetime).timeout.connect(rb.queue_free)
	return rb


# Extra flying blood/meat spheres on top of Voronoi body chunks — reads
# gory even when the source mesh is a smooth blob.
static func spawn_blood_gib_blobs(
	scene: Node,
	origin: Vector3,
	dir: Vector3,
	intensity: float,
	chaos: float,
	base_velocity: Vector3,
	burst_strength: float,
	force_origin: Vector3,
	impact_blood_strength: float,
	lifetime: float = 12.0,
) -> Array[RigidBody3D]:
	var out: Array[RigidBody3D] = []
	if scene == null:
		return out
	var dir_n := dir.normalized() if dir.length_squared() > 0.001 else Vector3.UP
	var sev := clampf(intensity, 0.35, 2.8)
	var blob_count := clampi(int(round(lerpf(5.0, 20.0, sev / 2.5) + chaos * 6.0)), 4, 24)
	for i in blob_count:
		var radius := randf_range(0.035, 0.13) * lerpf(0.85, 1.55, sev / 2.5)
		var rb := RigidBody3D.new()
		rb.collision_layer = 0
		rb.collision_mask = 1
		rb.gravity_scale = 1.0
		rb.contact_monitor = true
		rb.max_contacts_reported = 1
		scene.add_child(rb)
		rb.global_position = origin + Vector3(
			randf_range(-0.35, 0.35),
			randf_range(-0.15, 0.45),
			randf_range(-0.35, 0.35),
		)
		var mi := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = radius
		sm.height = radius * 2.0
		sm.radial_segments = 5
		sm.rings = 3
		mi.mesh = sm
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		if randf() < 0.38:
			mat.albedo_color = _gib_flesh_color()
		else:
			mat.albedo_color = Color(randf_range(0.16, 0.34), 0.018, 0.012, 1.0)
		mat.emission_enabled = true
		mat.emission = Color(0.38, 0.02, 0.015)
		mat.emission_energy_multiplier = 0.07
		mi.material_override = mat
		mi.scale = Vector3(
			randf_range(0.75, 1.25),
			randf_range(0.65, 1.05),
			randf_range(0.75, 1.25),
		)
		rb.add_child(mi)
		var cs := CollisionShape3D.new()
		var shape := SphereShape3D.new()
		shape.radius = radius
		cs.shape = shape
		rb.add_child(cs)
		var burst_dir := rb.global_position - (force_origin if force_origin != Vector3.INF else origin)
		if burst_dir.length_squared() < 0.0001:
			burst_dir = dir_n + Vector3(
				randf_range(-0.7, 0.7),
				randf_range(0.15, 0.85),
				randf_range(-0.7, 0.7),
			)
		burst_dir = burst_dir.normalized()
		var burst := burst_strength * randf_range(0.85, 1.35) * (1.0 + chaos * 0.22)
		rb.linear_velocity = base_velocity + burst_dir * burst + Vector3.UP * burst * randf_range(0.15, 0.35)
		rb.angular_velocity = Vector3(
			randf_range(-14.0, 14.0),
			randf_range(-14.0, 14.0),
			randf_range(-14.0, 14.0),
		)
		rb.body_entered.connect(func(_body: Node) -> void:
			_gib_on_chunk_body_entered(rb, scene, impact_blood_strength)
		)
		# Bind the body's own queue_free: an early free (round reset clears the
		# world) auto-disconnects the connection instead of invoking a lambda
		# whose captured `rb` was already freed ("Lambda capture was freed").
		scene.get_tree().create_timer(lifetime).timeout.connect(rb.queue_free)
		out.append(rb)
	return out


static func spawn_disintegrate_gore(
	scene: Node,
	pos: Vector3,
	dir: Vector3,
	intensity: float,
	chaos: float = 0.0,
	base_velocity: Vector3 = Vector3.ZERO,
	burst_strength: float = 3.0,
	force_origin: Vector3 = Vector3.INF,
	impact_blood_strength: float = 0.6,
	skip_mist: bool = false,
) -> Array[RigidBody3D]:
	if scene == null:
		return []
	var dir_n := dir.normalized() if dir.length_squared() > 0.001 else Vector3.UP
	var sev := clampf(intensity, 0.35, 2.8)
	if not skip_mist:
		spawn_gib_mist(scene, pos, dir_n, sev * 2.4, 0.0, sev * 0.52 + chaos * 0.28)
		spawn_blood(scene, pos, dir_n, sev * 1.6, 16)
		spawn_blast_blood_splash(scene, pos, dir_n, clampf(sev * 0.78, 0.4, 1.0))
		_spawn_headshot_puffs(scene, pos, dir_n, sev, true)
	return spawn_blood_gib_blobs(
		scene, pos, dir_n, sev, chaos, base_velocity, burst_strength,
		force_origin, impact_blood_strength,
	)


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
	_free_ragdoll_blood_wounds(rb)
	var scene: Node = rb.get_tree().current_scene
	if scene == null:
		return
	var carry: Vector3 = rb.linear_velocity + push_dir.normalized() * 4.0
	var origin: Vector3 = rb.global_position
	var push_n := push_dir.normalized() if push_dir.length_squared() > 0.001 else carry.normalized()
	spawn_disintegrate_gore(
		scene,
		origin,
		push_n,
		0.9,
		0.25,
		carry,
		3.0,
		origin,
		0.55,
	)
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
	strength: float,
) -> MeshInstance3D:
	if scene == null:
		return null
	var up := normal.normalized() if normal.length_squared() > 0.001 else Vector3.UP
	var sev := maxf(strength, 0.0)
	var count := clampi(int(round(lerpf(2.0, 8.0, clampf(sev / 2.5, 0.0, 1.0)))), 2, 10)
	var first: MeshInstance3D = null
	for i in count:
		var blob := _spawn_env_blood_stain(scene, pos, up, travel_dir, sev)
		if blob and first == null:
			first = blob
	return first


static func _spawn_env_blood_stain(
	scene: Node,
	pos: Vector3,
	normal: Vector3,
	travel_dir: Vector3,
	strength: float,
) -> MeshInstance3D:
	var up := normal.normalized()
	var tangent := travel_dir.slide(up).normalized()
	if tangent.length_squared() < 0.001:
		tangent = up.cross(Vector3.RIGHT).normalized()
		if tangent.length_squared() < 0.001:
			tangent = Vector3.FORWARD
	var blob := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	var sev := maxf(strength, 0.0)
	var size_mult := lerpf(0.9, 2.15, clampf(sev / 2.5, 0.0, 1.0))
	var radius := randf_range(0.055, 0.15) * size_mult
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 6
	mesh.rings = 4
	blob.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(randf_range(0.18, 0.34), 0.016, 0.01, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(0.32, 0.02, 0.015)
	mat.emission_energy_multiplier = 0.06
	blob.material_override = mat
	blob.add_to_group("blood_splats")
	scene.add_child(blob)
	blob.global_position = pos + up * 0.015 + tangent * randf_range(-0.08, 0.08) * size_mult \
		+ up.cross(tangent).normalized() * randf_range(-0.08, 0.08) * size_mult
	blob.look_at(blob.global_position + up, tangent)
	# Squash into the surface so it reads as a smear, not a floating orb.
	var spread := lerpf(1.0, 1.65, clampf(sev / 2.5, 0.0, 1.0))
	blob.scale = Vector3(
		randf_range(0.95, 1.45) * spread,
		randf_range(0.95, 1.45) * spread,
		randf_range(0.22, 0.42),
	)
	return blob


const PLAYER_BLOOD_WOUND_MAX := 32


static func _spawn_player_blood_blob(
	attach_to: Node3D,
	hit_pos: Vector3,
	normal: Vector3,
	strength: float,
) -> MeshInstance3D:
	if attach_to == null:
		return null
	var blob := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	var radius := randf_range(0.05, 0.1) * lerpf(0.95, 1.4, clampf(strength, 0.0, 1.2))
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 6
	mesh.rings = 4
	blob.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.render_priority = 2
	mat.albedo_color = Color(randf_range(0.2, 0.36), 0.018, 0.012, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(0.35, 0.02, 0.015)
	mat.emission_energy_multiplier = 0.12
	blob.material_override = mat
	blob.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	blob.add_to_group("player_blood_wounds")
	attach_to.add_child(blob)
	attach_to.move_child(blob, -1)

	var up := normal.normalized() if normal.length_squared() > 0.001 else Vector3.UP
	# Sit slightly proud of the skin — embedding caused z-fighting / clipping.
	blob.global_position = hit_pos + up * radius * randf_range(0.08, 0.22)
	blob.scale = Vector3(
		randf_range(0.88, 1.22),
		randf_range(0.78, 1.12),
		randf_range(0.88, 1.22),
	)
	return blob


static func _spawn_player_blood_cluster(
	attach: Node3D,
	center: Vector3,
	normal: Vector3,
	strength: float,
	count: int,
) -> Array:
	var out: Array = []
	if attach == null:
		return out
	var up := normal.normalized() if normal.length_squared() > 0.001 else Vector3.UP
	for i in count:
		var jitter := Vector3(
			randf_range(-0.06, 0.06),
			randf_range(-0.06, 0.06),
			randf_range(-0.06, 0.06),
		)
		var blob := _spawn_player_blood_blob(
			attach,
			center + jitter,
			normal,
			strength * randf_range(0.85, 1.05),
		)
		if blob:
			out.append(blob)
	return out


static func _append_ragdoll_blood_wounds(rb: RigidBody3D, wounds: Array) -> void:
	if rb == null or wounds.is_empty():
		return
	var existing: Array = rb.get_meta("blood_wounds") if rb.has_meta("blood_wounds") else []
	existing.append_array(wounds)
	rb.set_meta("blood_wounds", existing)


static func _player_blood_attach_mesh(player: Node, collider: Node) -> Node3D:
	if collider != null and collider.is_in_group("player_head_hitboxes"):
		var head: Variant = player.get("head_blob")
		if head is Node3D:
			return head
	var core: Variant = player.get("blob_core")
	if core is Node3D:
		return core
	var body: Variant = player.get("body_model")
	if body is Node3D:
		return body
	return null


static func spawn_player_blood_wound(
	player: Node,
	collider: Node,
	hit_pos: Vector3,
	normal: Vector3,
	travel_dir: Vector3,
	strength: float,
) -> void:
	if player == null or hit_pos == Vector3.INF:
		return
	var attach := _player_blood_attach_mesh(player, collider)
	if attach == null:
		return
	var wounds: Array = player.get("_blood_wounds")
	while wounds.size() >= PLAYER_BLOOD_WOUND_MAX:
		var old: Variant = wounds.pop_front()
		if old is Node and is_instance_valid(old):
			(old as Node).queue_free()
	var count := clampi(int(round(lerpf(2.0, 4.0, clampf(strength, 0.0, 1.2)))), 2, 5)
	var up := normal.normalized() if normal.length_squared() > 0.001 else Vector3.UP
	var tangent := travel_dir.slide(up).normalized()
	if tangent.length_squared() < 0.001:
		tangent = up.cross(Vector3.RIGHT).normalized()
		if tangent.length_squared() < 0.001:
			tangent = Vector3.FORWARD
	for i in count:
		var jitter := tangent * randf_range(-0.05, 0.05) \
			+ up.cross(tangent).normalized() * randf_range(-0.05, 0.05) \
			+ up * randf_range(-0.025, 0.025)
		var blob := _spawn_player_blood_blob(
			attach,
			hit_pos + jitter,
			normal,
			strength * randf_range(0.82, 1.05),
		)
		if blob:
			wounds.append(blob)
	player.set("_blood_wounds", wounds)


static func clear_player_blood_wounds(player: Node) -> void:
	if player == null:
		return
	var wounds: Array = player.get("_blood_wounds")
	for d in wounds:
		if d is Node and is_instance_valid(d):
			(d as Node).queue_free()
	wounds.clear()
	player.set("_blood_wounds", wounds)
	var body_model: Node = player.get("body_model")
	if body_model:
		_clear_group_under(body_model, "player_blood_wounds")


static func _clear_group_under(root: Node, group_name: String) -> void:
	for child in root.get_children():
		if child.is_in_group(group_name):
			child.queue_free()
		_clear_group_under(child, group_name)


static func transfer_player_blood_wounds(player: Node, attach_rb: Node3D) -> void:
	if player == null or attach_rb == null or not is_instance_valid(attach_rb):
		return
	var wounds: Array = player.get("_blood_wounds")
	var transferred: Array = []
	for d in wounds:
		if not (d is Node3D) or not is_instance_valid(d):
			continue
		(d as Node3D).reparent(attach_rb, true)
		transferred.append(d)
	wounds.clear()
	player.set("_blood_wounds", wounds)
	_append_ragdoll_blood_wounds(attach_rb, transferred)
	var body_model: Node = player.get("body_model")
	if body_model:
		_clear_group_under(body_model, "player_blood_wounds")


static func _free_ragdoll_blood_wounds(rb: RigidBody3D) -> void:
	if rb == null or not is_instance_valid(rb):
		return
	if rb.has_meta("blood_wounds"):
		for d in rb.get_meta("blood_wounds"):
			if d is Node and is_instance_valid(d):
				(d as Node).queue_free()
		rb.remove_meta("blood_wounds")
	for child in rb.get_children():
		if child.is_in_group("player_blood_wounds"):
			child.queue_free()

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
static var _blast_budget_frame: int = -1
static var _full_blasts_this_frame: int = 0
static var _cheap_blasts_this_frame: int = 0
static var _blast_cluster_positions: Array[Vector3] = []
static var _full_blast_window_ms: int = -10000
static var _full_blasts_this_window: int = 0
static var _active_smoke_puffs: int = 0
static var _pending_smoke_puffs: int = 0
static var _smoke_burst_window_ms: int = -10000
static var _smoke_burst_count: int = 0
static var _explosion_sfx_window_ms: int = -10000
static var _explosion_sfx_count: int = 0
static var _cheap_light_window_ms: int = -10000
static var _cheap_light_count: int = 0

const MAX_FULL_BLASTS_PER_FRAME := 3
const MAX_CHEAP_BLASTS_PER_FRAME := 10
const BLAST_CLUSTER_DIST_SQ := 9.0
const FULL_BLAST_WINDOW_MS := 500
const MAX_FULL_BLASTS_PER_WINDOW := 25   # ~50/sec sustained; bursts still capped by MAX_FULL_BLASTS_PER_FRAME + 3m cluster dedup
const MAX_ACTIVE_SMOKE_PUFFS := 36
const MAX_PENDING_SMOKE_PUFFS := 12
const SMOKE_BURST_WINDOW_MS := 750
const MAX_SMOKE_BURSTS_PER_WINDOW := 1
const EXPLOSION_SFX_WINDOW_MS := 500
const MAX_EXPLOSION_SFX_PER_WINDOW := 25  # explosion audio is cheap (cached WAV); allow ~50/sec so explosive-round streams still sound like explosions
const CHEAP_LIGHT_WINDOW_MS := 180
const MAX_CHEAP_LIGHTS_PER_WINDOW := 2

# -------------------- world-space VFX attach --------------------

# Callers pass world positions; parent may be Arena (non-zero transform).
static func _attach_world_3d(scene: Node, node: Node3D, world_pos: Vector3) -> void:
	scene.add_child(node)
	if scene is Node3D:
		node.global_position = world_pos
	else:
		node.position = world_pos


static func _begin_blast_frame() -> void:
	var frame := Engine.get_physics_frames()
	if _blast_budget_frame == frame:
		return
	_blast_budget_frame = frame
	_full_blasts_this_frame = 0
	_cheap_blasts_this_frame = 0
	_blast_cluster_positions.clear()


static func _claim_full_blast(pos: Vector3) -> bool:
	_begin_blast_frame()
	for existing in _blast_cluster_positions:
		if existing.distance_squared_to(pos) <= BLAST_CLUSTER_DIST_SQ:
			return false
	var now := Time.get_ticks_msec()
	if now - _full_blast_window_ms >= FULL_BLAST_WINDOW_MS:
		_full_blast_window_ms = now
		_full_blasts_this_window = 0
	if _full_blasts_this_frame >= MAX_FULL_BLASTS_PER_FRAME:
		return false
	if _full_blasts_this_window >= MAX_FULL_BLASTS_PER_WINDOW:
		return false
	_full_blasts_this_frame += 1
	_full_blasts_this_window += 1
	_blast_cluster_positions.append(pos)
	return true


static func _claim_cheap_blast() -> bool:
	_begin_blast_frame()
	if _cheap_blasts_this_frame >= MAX_CHEAP_BLASTS_PER_FRAME:
		return false
	_cheap_blasts_this_frame += 1
	return true


static func _claim_explosion_sfx() -> bool:
	var now := Time.get_ticks_msec()
	if now - _explosion_sfx_window_ms >= EXPLOSION_SFX_WINDOW_MS:
		_explosion_sfx_window_ms = now
		_explosion_sfx_count = 0
	if _explosion_sfx_count >= MAX_EXPLOSION_SFX_PER_WINDOW:
		return false
	_explosion_sfx_count += 1
	return true


static func _claim_cheap_light() -> bool:
	var now := Time.get_ticks_msec()
	if now - _cheap_light_window_ms >= CHEAP_LIGHT_WINDOW_MS:
		_cheap_light_window_ms = now
		_cheap_light_count = 0
	if _cheap_light_count >= MAX_CHEAP_LIGHTS_PER_WINDOW:
		return false
	_cheap_light_count += 1
	return true


static func _can_spawn_smoke_puff() -> bool:
	return _active_smoke_puffs < MAX_ACTIVE_SMOKE_PUFFS


static func _claim_pending_smoke_puff() -> bool:
	if _active_smoke_puffs + _pending_smoke_puffs >= MAX_ACTIVE_SMOKE_PUFFS + MAX_PENDING_SMOKE_PUFFS:
		return false
	_pending_smoke_puffs += 1
	return true


static func _claim_smoke_burst() -> bool:
	var now := Time.get_ticks_msec()
	if now - _smoke_burst_window_ms >= SMOKE_BURST_WINDOW_MS:
		_smoke_burst_window_ms = now
		_smoke_burst_count = 0
	if _smoke_burst_count >= MAX_SMOKE_BURSTS_PER_WINDOW:
		return false
	_smoke_burst_count += 1
	return true


static func _configure_blast_fireball_mat(
	mat: StandardMaterial3D,
	hot: Color,
	start_alpha: float,
	emission_mult: float = 7.5,
) -> void:
	# Additive unshaded shell — low alpha keeps it see-through; emission carries
	# the brightness so it still blooms.
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.render_priority = 2
	mat.albedo_color = Color(hot.r, hot.g, hot.b, start_alpha)
	mat.emission_enabled = true
	mat.emission = hot
	mat.emission_energy_multiplier = emission_mult


const BLAST_FRONT_SPEED := 343.0  # m/s — shockwave front + audio delay
const BLAST_FIREBALL_MIN_GROW := 0.12
const BLAST_FIREBALL_MAX_GROW := 0.32


static func blast_expand_time(radius: float) -> float:
	# Linear growth synced to sound speed, but clamped so small blasts stay visible.
	return clampf(radius / BLAST_FRONT_SPEED, BLAST_FIREBALL_MIN_GROW, BLAST_FIREBALL_MAX_GROW)


static func _blast_fireball_timing(radius: float) -> Dictionary:
	# Bigger blasts flash bigger AND a touch longer (grenade ~0.27s, airstrike ~0.55s).
	var grow := clampf(0.12 + radius * 0.007, 0.12, 0.45)
	var fade := clampf(0.08 + radius * 0.005, 0.08, 0.28)
	return {"grow": grow, "fade": fade}


static func _animate_blast_fireball(
	ball: MeshInstance3D,
	mat: StandardMaterial3D,
	hot: Color,
	target_scale: float,
	timing: Dictionary,
) -> void:
	var grow: float = timing.grow
	var fade: float = timing.fade
	var life: float = grow + fade
	var start_hot := hot.lerp(Color(1.0, 1.0, 0.98), 0.65)
	var mid_hot := hot.lerp(Color(1.0, 0.48, 0.08), 0.5)
	var end_hot := hot.lerp(Color(1.0, 0.30, 0.04), 0.45)
	# Very high emission energy → blown-out white-hot HDR core that blooms hard.
	_configure_blast_fireball_mat(mat, start_hot, 0.98, 55.0)
	ball.scale = Vector3.ONE * maxf(0.01, target_scale * 0.4)
	# Additive brightness is gated by alpha, so the core must HOLD full alpha +
	# emission for a beat (the bright HDR flash) before fading — otherwise it
	# winks out before the eye registers it.
	var hold := life * 0.28

	# One sphere, one tween per property — nothing animates the same property
	# twice, so it reads as a single fireball easing white→orange while getting
	# steadily dimmer and more transparent. (The old version ran two overlapping
	# albedo tweens whose alpha fought near the end, popping an orange ghost
	# sphere back into view as it died.)
	# Scale: expand linearly for the whole lifetime — constant rate, no easing
	# slowdown and no plateau (keeps growing right up until it's freed).
	ball.create_tween().tween_property(ball, "scale", Vector3.ONE * target_scale, life)\
		.set_trans(Tween.TRANS_LINEAR)

	# Emission hue: white → orange → deep orange across the full life.
	var col_tw := ball.create_tween()
	col_tw.tween_property(mat, "emission", mid_hot, life * 0.45)\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	col_tw.tween_property(mat, "emission", end_hot, life * 0.55)\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)

	# Albedo carries the same hue and a single clean alpha sweep 0.88 → 0 — one
	# front-loaded ease (no mid-life plateau), so transparency rises smoothly and
	# fast all the way to fully see-through.
	var alb_tw := ball.create_tween()
	alb_tw.tween_interval(hold)
	alb_tw.tween_property(mat, "albedo_color", Color(end_hot.r, end_hot.g, end_hot.b, 0.0), life - hold)\
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

	# Emission energy: hold the hot peak, then decay to nothing.
	var em_tw := ball.create_tween()
	em_tw.tween_interval(hold)
	em_tw.tween_property(mat, "emission_energy_multiplier", 0.0, life - hold)\
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	em_tw.tween_callback(ball.queue_free)


static func _spawn_blast_fireball(scene: Node, pos: Vector3, radius: float, color: Color = Color.WHITE) -> void:
	var ball := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.25
	mesh.height = 0.5
	ball.mesh = mesh
	var mat := StandardMaterial3D.new()
	ball.material_override = mat
	_attach_world_3d(scene, ball, pos)
	# Hot core stays compact — it's the bright HDR heart, smaller than the smoke
	# body that surrounds it (see spawn_blast_fire_smoke).
	var target_scale := maxf(0.01, (radius * 0.58) / mesh.radius)
	var hot := color.lerp(Color(1.0, 0.78, 0.42), 0.45)
	_animate_blast_fireball(ball, mat, hot, target_scale, _blast_fireball_timing(radius))


# ---- Stylized flame shards + embers --------------------------------------
# Radial flame petals + flying sparks layered on the fireball for a stylized
# "burst" read. Performance notes:
#  - Meshes are built once and shared by every shard/ember ever (cached below).
#  - Each blast uses ONE additive material (a single shared fade tween, not one
#    per particle) configured exactly like the fireball — so it's the SAME
#    already-warmed PSO variant (warmup_blast_materials), no new shader compile.
#  - Only full blasts spawn them, so the per-frame blast budget caps the count.
# Live tuning hooks for the explosion lab (1.0 == production look; 0 == off).
static var blast_shard_count_scale: float = 1.0
static var blast_ember_count_scale: float = 1.0

static var _blast_shard_mesh: Mesh = null
static var _blast_ember_mesh: Mesh = null

static func _get_blast_shard_mesh() -> Mesh:
	if _blast_shard_mesh == null:
		# Tapered cone (tip at +Y) — a flame petal. Unit height/radius; the
		# spawner scales it into a long thin shard.
		var c := CylinderMesh.new()
		c.top_radius = 0.0
		c.bottom_radius = 0.5
		c.height = 1.0
		c.radial_segments = 6
		c.rings = 1
		c.cap_bottom = true
		c.cap_top = false
		_blast_shard_mesh = c
	return _blast_shard_mesh

static func _get_blast_ember_mesh() -> Mesh:
	if _blast_ember_mesh == null:
		var s := SphereMesh.new()
		s.radius = 0.06
		s.height = 0.12
		s.radial_segments = 5
		s.rings = 3
		_blast_ember_mesh = s
	return _blast_ember_mesh


# Additive "projectile" layer (embers + flame shards) as a MultiMesh. Each
# instance flies outward from the blast centre to its travel target
# (decelerating) and fades. Orientation, scale, streak, growth and the fly-out
# are ALL computed in the shader from per-instance data, so the instance
# transform is plain identity and nothing depends on MODEL_MATRIX (which doesn't
# reliably expose the per-instance transform for MultiMesh). One draw call, one
# material, one tween for the whole burst.
#   INSTANCE_CUSTOM = (travel.xyz world-offset from centre, delay)
#   COLOR           = (size01, elong01, grow_start, brightness_jitter)
static var _blast_projectile_shader: Shader = null

const _BLAST_PROJECTILE_CODE := "
	shader_type spatial;
	render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled, blend_add;
	uniform float anim = 0.0;
	uniform vec3 tint : source_color = vec3(1.0, 0.7, 0.3);
	uniform float brightness = 6.0;
	uniform float size_scale = 1.0;
	uniform float elong_max = 8.0;
	uniform float fade_start = 0.35;
	varying float v_b;
	void vertex() {
		vec3 travel = INSTANCE_CUSTOM.xyz;     // world target offset from blast centre
		float delay = INSTANCE_CUSTOM.w;
		float size = COLOR.r * size_scale;
		float elong = 1.0 + COLOR.g * (elong_max - 1.0);
		float grow_start = COLOR.b;
		float age = clamp((anim - delay) / max(1.0 - delay, 0.001), 0.0, 1.0);
		float prog = 1.0 - pow(1.0 - age, 2.0);   // decelerating
		float dist = length(travel);
		vec3 dir = dist > 0.0001 ? travel / dist : vec3(0.0, 1.0, 0.0);
		// Orthonormal frame with Y aligned to the travel direction.
		vec3 upv = abs(dir.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
		vec3 ex = normalize(cross(upv, dir));
		vec3 ez = cross(dir, ex);
		float grow = mix(grow_start, 1.0, prog);
		vec3 v = VERTEX;
		v.x *= size * grow;
		v.z *= size * grow;
		v.y *= size * grow * mix(1.0, elong, prog);   // stretch into a streak/petal as it flies
		// Orient (mesh Y -> dir) then fly outward from centre to target.
		VERTEX = ex * v.x + dir * v.y + ez * v.z + travel * prog;
		v_b = (1.0 - smoothstep(fade_start, 1.0, age)) * COLOR.a;
	}
	void fragment() {
		ALBEDO = tint * brightness;   // additive (blend_add); HDR brightness blooms
		ALPHA = v_b;                  // fade modulates the added light
	}
"

static func _get_blast_projectile_shader() -> Shader:
	if _blast_projectile_shader == null:
		_blast_projectile_shader = Shader.new()
		_blast_projectile_shader.code = _BLAST_PROJECTILE_CODE
	return _blast_projectile_shader

static func _finish_projectile_layer(scene: Node, mm: MultiMesh, pos: Vector3, tint: Color, brightness: float, life: float, aabb_extent: float, size_scale: float, elong_max: float) -> void:
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.custom_aabb = AABB(Vector3.ONE * (-aabb_extent), Vector3.ONE * (2.0 * aabb_extent))
	var mat := ShaderMaterial.new()
	mat.shader = _get_blast_projectile_shader()
	mat.set_shader_parameter("anim", 0.0)
	mat.set_shader_parameter("tint", tint)
	mat.set_shader_parameter("brightness", brightness)
	mat.set_shader_parameter("size_scale", size_scale)
	mat.set_shader_parameter("elong_max", elong_max)
	mmi.material_override = mat
	_attach_world_3d(scene, mmi, pos)
	var tw := mmi.create_tween()
	tw.tween_property(mat, "shader_parameter/anim", 1.0, life).set_trans(Tween.TRANS_LINEAR)
	tw.tween_callback(mmi.queue_free)


static func spawn_blast_flame_shards(scene: Node, pos: Vector3, radius: float, color: Color) -> void:
	if scene == null or blast_shard_count_scale <= 0.0:
		return
	if BenchFlags.active and BenchFlags.no_explosion_visuals:
		return
	var count := int(round(clampi(int(radius * 0.9), 5, 14) * blast_shard_count_scale))
	if count <= 0:
		return
	var rng := RandomNumberGenerator.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = _get_blast_shard_mesh()
	mm.instance_count = count
	var size_scale := radius * 0.11   # max thick → COLOR.r is thick normalised to [0,1]
	for i in count:
		var theta := rng.randf() * TAU
		var elev := rng.randf_range(-0.35, 1.3)
		var dir := Vector3(cos(theta) * cos(elev), sin(elev), sin(theta) * cos(elev)).normalized()
		var thick := radius * rng.randf_range(0.05, 0.11)
		var length := radius * rng.randf_range(0.6, 1.25)
		var travel := dir * length * rng.randf_range(0.4, 0.75)   # how far the petal launches
		mm.set_instance_transform(i, Transform3D.IDENTITY)
		# COLOR = (size01, elong01, grow_start, brightness_jitter)
		mm.set_instance_color(i, Color(thick / size_scale, clampf((length / thick - 1.0) / 24.0, 0.0, 1.0), 0.35, rng.randf_range(0.75, 1.0)))
		# CUSTOM = (travel.xyz, delay)
		mm.set_instance_custom_data(i, Color(travel.x, travel.y, travel.z, rng.randf_range(0.0, 0.28)))
	var hot := color.lerp(Color(1.0, 0.92, 0.7), 0.5)
	_finish_projectile_layer(scene, mm, pos, hot, 7.0, 0.2 + radius * 0.025, radius * 2.5, size_scale, 25.0)


static func spawn_blast_embers(scene: Node, pos: Vector3, radius: float, color: Color) -> void:
	if scene == null or blast_ember_count_scale <= 0.0:
		return
	if BenchFlags.active and BenchFlags.no_explosion_visuals:
		return
	var count := int(round(clampi(int(radius * 5.0), 30, 110) * blast_ember_count_scale))
	if count <= 0:
		return
	var rng := RandomNumberGenerator.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = _get_blast_ember_mesh()
	mm.instance_count = count
	var size_scale := 1.2   # max sz → COLOR.r normalised to [0,1]
	for i in count:
		var theta := rng.randf() * TAU
		var elev := rng.randf_range(-0.2, 1.35)
		var dir := Vector3(cos(theta) * cos(elev), sin(elev), sin(theta) * cos(elev)).normalized()
		var dist := radius * rng.randf_range(0.8, 2.0)
		var drop := radius * rng.randf_range(0.2, 0.7)
		var travel := dir * dist + Vector3.DOWN * drop
		# Streak along travel (faster/farther sparks trail longer).
		var sz := rng.randf_range(0.4, 1.15)
		var streak := 1.0 + clampf(dist / radius, 0.0, 2.0) * rng.randf_range(1.6, 3.6)
		mm.set_instance_transform(i, Transform3D.IDENTITY)
		# COLOR = (size01, elong01=streak, grow_start=1 (no grow-in), brightness_jitter)
		mm.set_instance_color(i, Color(sz / size_scale, clampf((streak - 1.0) / 7.0, 0.0, 1.0), 1.0, rng.randf_range(0.6, 1.0)))
		# CUSTOM = (travel.xyz, delay)
		mm.set_instance_custom_data(i, Color(travel.x, travel.y, travel.z, rng.randf_range(0.0, 0.15)))
	var hot := color.lerp(Color(1.0, 0.86, 0.5), 0.4)
	_finish_projectile_layer(scene, mm, pos, hot, 5.0, 0.3 + radius * 0.03, radius * 3.5, size_scale, 8.0)


# Orthonormal basis whose +Y axis aligns with `dir` (for orienting the shard cone).
static func _basis_from_y(dir: Vector3) -> Basis:
	var y := dir.normalized()
	var x := y.cross(Vector3.FORWARD)
	if x.length_squared() < 0.001:
		x = y.cross(Vector3.RIGHT)
	x = x.normalized()
	var z := x.cross(y).normalized()
	return Basis(x, y, z)


# ---- Fused fire + smoke body (MultiMesh, GPU-animated) -------------------
# Billowing cauliflower clouds: lumpy puffs with DARK fresnel-rimmed edges, the
# fire ones emissive (hot white centre → orange outward), the smoke ones dark.
# Performance: each cloud layer is ONE MultiMesh (one draw call for every puff),
# ONE material, and ONE tween — all the per-puff motion (growth, fade, glow,
# lump, stagger) is baked into the shader and driven by a single `anim` uniform
# 0→1. Replaces the old per-puff path (~30 nodes + 30 materials + 90 tweens per
# layer) so blasts scale to hundreds/sec. Per-instance data: COLOR = (body.rgb,
# opacity_peak), INSTANCE_CUSTOM = (seed, delay, heat-or-glow, 0).
static var blast_smoke_count_scale: float = 1.0
static var blast_fire_cloud_count_scale: float = 1.0
static var _smoke_billow_mesh: Mesh = null
static var _billow_mm_shader: Shader = null

const _BILLOW_MM_CODE := "
	shader_type spatial;
	render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled;
	uniform float anim = 0.0;          // 0..1, tweened once per layer
	uniform float is_fire = 0.0;
	uniform float edge_power = 2.1;
	uniform float lump_amount = 0.32;
	uniform float growth_min = 0.35;
	uniform float tail_power = 1.5;    // <1 = long lingering tail, >1 = quick fade
	uniform vec3 warm_glow : source_color = vec3(1.0, 0.45, 0.12);
	uniform vec3 fire_cool : source_color = vec3(1.0, 0.5, 0.16);
	uniform vec3 fire_hot : source_color = vec3(1.0, 0.97, 0.86);
	uniform float fire_glow_lo = 14.0;
	uniform float fire_glow_hi = 65.0;
	varying float v_age;
	varying float v_heat;
	varying vec3 v_body;
	varying float v_opk;
	void vertex() {
		float seed = INSTANCE_CUSTOM.x;
		float delay = INSTANCE_CUSTOM.y;
		v_heat = INSTANCE_CUSTOM.z;
		v_body = COLOR.rgb;
		v_opk = COLOR.a;
		// Staggered local age so puffs don't all pop at once.
		v_age = clamp((anim - delay) / max(1.0 - delay, 0.001), 0.0, 1.0);
		// Per-instance lumpy displacement (seed varies every puff).
		float s = seed * 100.0;
		float a = sin(VERTEX.x * 6.3 + s) * sin(VERTEX.y * 5.1 + s * 1.7) * sin(VERTEX.z * 7.2 + s * 0.9);
		float b = sin(VERTEX.x * 13.0 + s * 2.1) * sin(VERTEX.z * 11.0 + s * 1.3);
		VERTEX += NORMAL * (a * 0.7 + b * 0.3) * lump_amount;
		// Growth 0.35 -> 1.0 at a CONSTANT rate (linear — keeps expanding, no
		// ease-out settling at the end). The slow fade is the alpha's job.
		VERTEX *= mix(growth_min, 1.0, v_age);
	}
	void fragment() {
		float facing = abs(dot(normalize(NORMAL), normalize(VIEW)));
		float fres = pow(1.0 - facing, edge_power);
		float fade_in = smoothstep(0.0, 0.12, v_age);
		float t = clamp((v_age - 0.12) / 0.88, 0.0, 1.0);
		// Long lingering tail (tail_power < 1) but with a SOFT landing — the last
		// stretch eases gently to zero instead of dropping off a cliff at the end.
		float fade_out = pow(1.0 - t, tail_power) * (1.0 - smoothstep(0.5, 1.0, t));
		ALPHA = v_opk * fade_in * fade_out * smoothstep(0.0, 0.5, facing);
		if (is_fire > 0.5) {
			vec3 hot = mix(fire_cool, fire_hot, v_heat);
			float glow = mix(fire_glow_lo, fire_glow_hi, v_heat) * (1.0 - smoothstep(0.0, 0.55, v_age));
			vec3 body = mix(hot * 0.3, vec3(0.45, 0.16, 0.04), fres);
			ALBEDO = body + hot * glow * facing;   // unshaded ignores EMISSION; HDR via ALBEDO
		} else {
			vec3 body = mix(v_body, v_body * 0.1, fres);
			float glow = v_heat * (1.0 - smoothstep(0.0, 0.45, v_age));  // v_heat = subtle warm underglow
			ALBEDO = body + warm_glow * glow * facing;
		}
	}
"

static func _get_smoke_billow_mesh() -> Mesh:
	if _smoke_billow_mesh == null:
		var s := SphereMesh.new()
		s.radius = 0.5
		s.height = 1.0
		s.radial_segments = 10
		s.rings = 6
		_smoke_billow_mesh = s
	return _smoke_billow_mesh

static func _get_billow_mm_shader() -> Shader:
	if _billow_mm_shader == null:
		_billow_mm_shader = Shader.new()
		_billow_mm_shader.code = _BILLOW_MM_CODE
	return _billow_mm_shader


# Builds one cloud layer as a single MultiMesh + material + tween.
static func _spawn_blast_billow(scene: Node, pos: Vector3, radius: float, count: int,
		is_fire: bool, tint: Color, layer_life: float, scale_lo: float, scale_hi: float, rise: float) -> void:
	var rng := RandomNumberGenerator.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = _get_smoke_billow_mesh()
	mm.instance_count = count
	var spread := radius * (0.45 if is_fire else 0.65)
	for i in count:
		var ang := rng.randf() * TAU
		var rad := rng.randf_range(0.0, spread)
		var off := Vector3(cos(ang) * rad, rng.randf_range(-0.2, 0.6) * radius * 0.45, sin(ang) * rad)
		var end_scale := radius * rng.randf_range(scale_lo, scale_hi)
		mm.set_instance_transform(i, Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * end_scale), off))
		var seed := rng.randf()
		var delay := rng.randf_range(0.0, 0.22 if is_fire else 0.12)
		var heat: float
		var body: Color
		var opk: float
		if is_fire:
			heat = pow(1.0 - clampf(rad / maxf(spread, 0.001), 0.0, 1.0), 1.4)
			body = Color(1, 1, 1)
			opk = rng.randf_range(0.75, 0.95)
		else:
			heat = rng.randf_range(0.2, 0.55)   # warm underglow amount
			# Dark, dense neutral-grey smoke (one grey value with a fixed slight
			# warm bias — NOT independent per-channel randomness, which produced
			# random red/green/purple tints).
			var g := rng.randf_range(0.12, 0.24)
			body = Color(g * 1.08, g, g * 0.9)
			opk = rng.randf_range(0.6, 0.85)
		mm.set_instance_color(i, Color(body.r, body.g, body.b, opk))
		mm.set_instance_custom_data(i, Color(seed, delay, heat, 0.0))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	# Generous AABB so the grown/displaced puffs aren't frustum-culled early.
	mmi.custom_aabb = AABB(Vector3.ONE * (-radius * 2.5), Vector3.ONE * (radius * 5.0))
	var mat := ShaderMaterial.new()
	mat.shader = _get_billow_mm_shader()
	mat.set_shader_parameter("anim", 0.0)
	mat.set_shader_parameter("is_fire", 1.0 if is_fire else 0.0)
	if is_fire:
		mat.set_shader_parameter("tail_power", 2.2)   # fire fades fast
		mat.set_shader_parameter("fire_cool", tint.lerp(Color(1.0, 0.5, 0.16), 0.5))
		mat.set_shader_parameter("fire_hot", tint.lerp(Color(1.0, 0.97, 0.86), 0.7))
	else:
		mat.set_shader_parameter("tail_power", 0.38)   # smoke lingers with a long, slow tail
		mat.set_shader_parameter("warm_glow", tint.lerp(Color(1.0, 0.45, 0.12), 0.6))
	mmi.material_override = mat
	var base := pos + Vector3.UP * (radius * 0.1)
	_attach_world_3d(scene, mmi, base)
	var atw := mmi.create_tween()
	atw.tween_property(mat, "shader_parameter/anim", 1.0, layer_life).set_trans(Tween.TRANS_LINEAR)
	atw.tween_callback(mmi.queue_free)
	if rise > 0.0:
		mmi.create_tween().tween_property(mmi, "position", base + Vector3.UP * rise, layer_life)\
			.set_trans(Tween.TRANS_LINEAR)


static func spawn_blast_fire_smoke(scene: Node, pos: Vector3, radius: float, color: Color) -> void:
	if scene == null or blast_smoke_count_scale <= 0.0:
		return
	if BenchFlags.active and BenchFlags.no_explosion_visuals:
		return
	var count := int(round(clampi(int(radius * 1.1), 8, 24) * blast_smoke_count_scale))
	if count <= 0:
		return
	# Lifetime scales with blast size: a small grenade (r≈6) smokes ~1.3s, a huge
	# airstrike (r≈30) lingers ~4.4s.
	_spawn_blast_billow(scene, pos, radius, count, false, color, 0.5 + radius * 0.13, 0.5, 1.3, radius * 0.7)


# Fire as clouds: same lumpy billow puffs, but emissive — hot white near the
# centre cooling to orange outward. Alpha-blended like the smoke, so depth-mixed
# you get patches where smoke is in front (dark) and patches where fire is in
# front (glowing). Short-lived — the fire cools and dies into the smoke.
static func spawn_blast_fire_clouds(scene: Node, pos: Vector3, radius: float, color: Color) -> void:
	if scene == null or blast_fire_cloud_count_scale <= 0.0:
		return
	if BenchFlags.active and BenchFlags.no_explosion_visuals:
		return
	var count := int(round(clampi(int(radius * 0.8), 6, 18) * blast_fire_cloud_count_scale))
	if count <= 0:
		return
	# Fire shape burns longer for bigger blasts (r≈6 → ~0.7s, r≈30 → ~2s).
	_spawn_blast_billow(scene, pos, radius, count, true, color, 0.35 + radius * 0.055, 0.3, 0.7, radius * 0.3)


const BLAST_LIGHT_FLASH_HOLD := 0.045   # ~1–3 rendered frames before decay
const BLAST_LIGHT_FLASH_DECAY := 0.09
const BLAST_LIGHT_CORE_HOLD := 0.03
const BLAST_LIGHT_CORE_DECAY := 0.075
const BLAST_LIGHT_HOT := Color(1.0, 0.995, 0.98)
const BLAST_LIGHT_WARM := Color(1.0, 0.54, 0.12)


static func _tween_blast_light_pop(
	light: OmniLight3D,
	peak_energy: float,
	hold_s: float,
	decay_s: float,
	hot_color: Color = BLAST_LIGHT_HOT,
	warm_color: Color = BLAST_LIGHT_WARM,
) -> void:
	# Peak is set immediately (frame 0). Hold keeps energy flat for one flash
	# beat, then energy falls off fast while color drifts hot-white → orange.
	light.light_color = hot_color
	light.light_energy = peak_energy
	var total := hold_s + decay_s
	var ctw := light.create_tween()
	ctw.tween_property(light, "light_color", warm_color, total)\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	var etw := light.create_tween()
	if hold_s > 0.0001:
		etw.tween_interval(hold_s)
	etw.tween_property(light, "light_energy", 0.0, decay_s)\
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	etw.tween_callback(light.queue_free)


static func _spawn_blast_flash_light(scene: Node, pos: Vector3, radius: float) -> void:
	var flash := OmniLight3D.new()
	var peak := 45.0 + radius * 5.5
	flash.omni_range = clampf(radius * 6.5, 55.0, 190.0)
	flash.shadow_enabled = false
	_attach_world_3d(scene, flash, pos)
	_tween_blast_light_pop(flash, peak, BLAST_LIGHT_FLASH_HOLD, BLAST_LIGHT_FLASH_DECAY)


static func _spawn_blast_core_light(scene: Node, pos: Vector3, radius: float, color: Color, energy_mult: float = 1.0) -> void:
	var core_light := OmniLight3D.new()
	var peak := (22.0 + radius * 2.5) * energy_mult
	core_light.omni_range = clampf(radius * 2.2, 12.0, 65.0)
	core_light.shadow_enabled = false
	_attach_world_3d(scene, core_light, pos)
	var hot := color.lerp(BLAST_LIGHT_HOT, 0.55)
	var warm := color.lerp(BLAST_LIGHT_WARM, 0.45)
	_tween_blast_light_pop(core_light, peak, BLAST_LIGHT_CORE_HOLD, BLAST_LIGHT_CORE_DECAY, hot, warm)


static func _spawn_cheap_blast_flare(scene: Node, pos: Vector3, radius: float, color: Color) -> void:
	if scene == null or radius <= 0.0 or not _claim_cheap_blast():
		return
	var expand_time := blast_expand_time(radius)
	_spawn_blast_fireball(scene, pos, radius, color)
	if _claim_cheap_light():
		_spawn_blast_flash_light(scene, pos, radius)
		_spawn_blast_core_light(scene, pos, radius, color, 0.55)


# Bigger blasts expand further, hold a hotter core, and pump a brighter
# point light — stacked EXPLOSIVE ROUNDS cards should feel earth-shaking.
# `local_player` (optional) is the local human's player; if provided, gets a
# view-punch + is checked against the scene's exposure sidechain hook.
static func spawn_bullet_blast(scene: Node, pos: Vector3, radius: float, color: Color, local_player: Node = null, play_audio: bool = true) -> void:
	if scene == null:
		return
	var full_blast := _claim_full_blast(pos)
	if full_blast and scene.has_method("trigger_explosion_sidechain"):
		# Uncap so big bazookas push exposure WAY down (was 1.0 cap → all
		# explosions ducked the same). Peak ~3 at radius 15+ feels properly
		# blinding for the biggest blasts.
		var sidechain_peak := clampf(radius / 5.0, 0.35, 3.0)
		scene.trigger_explosion_sidechain(pos, radius, sidechain_peak)
	if full_blast and local_player and is_instance_valid(local_player) and local_player.has_method("apply_explosion_view_punch"):
		# Allow peak > 1.0 for big blasts — uncapping makes a bazooka register
		# noticeably harder than a small grenade-class burst.
		var punch_peak := clampf(radius / 5.0, 0.45, 1.6)
		local_player.apply_explosion_view_punch(pos, radius, punch_peak)
	if not full_blast:
		_spawn_cheap_blast_flare(scene, pos, radius, color)
		return
	var expand_time := blast_expand_time(radius)
	spawn_heat_distortion(scene, pos, radius, expand_time, clampf(radius * 0.012, 0.025, 0.06))
	spawn_shockwave_ring(scene, pos, radius)
	# Drop scorch rings on every nearby surface (floor under midair blasts,
	# walls beside corner blasts, ceiling above ground-level pops).
	spawn_blast_scorches(scene, pos, radius)

	# Lights first, then fireball meshes on top (render_priority 2).
	_spawn_blast_flash_light(scene, pos, radius)
	_spawn_blast_core_light(scene, pos, radius, color)
	_spawn_blast_fireball(scene, pos, radius, color)
	# Stylized burst layers — fused fire/smoke body, radial flame petals, embers.
	if not (BenchFlags.active and BenchFlags.no_explosion_visuals):
		spawn_blast_fire_smoke(scene, pos, radius, color)
		spawn_blast_fire_clouds(scene, pos, radius, color)
		spawn_blast_flame_shards(scene, pos, radius, color)
		spawn_blast_embers(scene, pos, radius, color)

	# 4) Big blasts play the full explosion SFX; smaller impacts stay visual.
	if play_audio and radius >= 3.5:
		# Bench A/B isolation — gated by BenchFlags so production hits one
		# static bool branch instead of a scene-root .get() lookup.
		if not (BenchFlags.active and BenchFlags.no_explosion_audio) and _claim_explosion_sfx():
			SFX.explosion(pos, radius)


static func spawn_smoke_puff(
	scene: Node,
	pos: Vector3,
	size: float = 1.0,
	drift: Vector3 = Vector3.UP,
	lifetime: float = 2.5,
	tint: Color = Color(0.42, 0.40, 0.36, 0.52),
	rise_mult: float = 1.0,
) -> void:
	if scene == null or (BenchFlags.active and BenchFlags.no_explosion_visuals):
		return
	if not _can_spawn_smoke_puff():
		return
	_active_smoke_puffs += 1
	var puff := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.35 * size
	mesh.height = 0.7 * size
	mesh.radial_segments = 8
	mesh.rings = 4
	puff.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = Color(tint.r, tint.g, tint.b, 0.0)
	puff.material_override = mat
	puff.position = pos
	puff.scale = Vector3.ONE * 0.06
	puff.add_to_group("smoke_puffs")
	scene.add_child(puff)
	var drift_norm := drift
	if drift_norm.length_squared() < 0.0001:
		drift_norm = Vector3.UP
	else:
		drift_norm = drift_norm.normalized()
	var horizontal := Vector3(drift_norm.x, 0.0, drift_norm.z)
	var lateral_dist := size * randf_range(0.35, 1.05)
	if horizontal.length_squared() > 0.0001:
		horizontal = horizontal.normalized() * lateral_dist
	else:
		horizontal = Vector3.ZERO
	var rise_dist := size * randf_range(2.6, 5.4) * rise_mult
	var end_pos := pos + horizontal + Vector3.UP * rise_dist
	var end_scale := Vector3.ONE * randf_range(1.2, 2.1) * maxf(size, 0.35)
	var peak := Color(tint.r, tint.g, tint.b, tint.a)
	var tw := puff.create_tween().set_parallel(true)
	tw.tween_property(puff, "position", end_pos, lifetime)\
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(puff, "scale", end_scale, lifetime * 0.88)\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	var atw := puff.create_tween()
	atw.tween_property(mat, "albedo_color", peak, lifetime * 0.22)\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	atw.tween_property(mat, "albedo_color", Color(tint.r, tint.g, tint.b, 0.0), lifetime * 0.72)\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	atw.tween_callback(func() -> void:
		_active_smoke_puffs = maxi(0, _active_smoke_puffs - 1)
		if is_instance_valid(puff):
			puff.queue_free()
	)


static func spawn_exhaust_smoke(scene: Node, pos: Vector3, size: float, drift: Vector3) -> void:
	var tint := Color(
		randf_range(0.58, 0.68),
		randf_range(0.54, 0.62),
		randf_range(0.48, 0.56),
		randf_range(0.10, 0.18),
	)
	spawn_smoke_puff(
		scene,
		pos,
		size * 0.28,
		drift,
		randf_range(0.75, 1.35),
		tint,
		1.85,
	)


static func spawn_blast_smoke(scene: Node, pos: Vector3, radius: float) -> void:
	if scene == null or radius <= 0.0 or (BenchFlags.active and BenchFlags.no_explosion_visuals):
		return
	if not _claim_smoke_burst():
		return
	var ground := pos + Vector3.UP * 0.35
	var scale := clampf(radius / 14.0, 0.55, 2.4)
	for i in int(clampf(radius * 0.18, 4, 10)):
		var ang := randf() * TAU
		var rad := randf_range(0.0, radius * 0.34)
		var offset := Vector3(cos(ang) * rad, randf_range(0.0, 1.2), sin(ang) * rad)
		var dark := i % 3 == 0
		var tint := Color(
			randf_range(0.18, 0.28) if dark else randf_range(0.42, 0.50),
			randf_range(0.16, 0.24) if dark else randf_range(0.40, 0.46),
			randf_range(0.14, 0.22) if dark else randf_range(0.36, 0.42),
			randf_range(0.22, 0.36),
		)
		spawn_smoke_puff(
			scene,
			ground + offset,
			randf_range(1.8, 3.8) * scale,
			Vector3(
				randf_range(-1.0, 1.0),
				randf_range(1.6, 4.0),
				randf_range(-1.0, 1.0),
			).normalized(),
			randf_range(4.0, 7.0),
			tint,
		)
	var column_count := int(clampf(radius * 0.12, 2, 6))
	for j in column_count:
		if not _claim_pending_smoke_puff():
			continue
		var delay := float(j) * 0.16
		# .bind a static helper (not a capturing lambda): if `scene` frees before
		# the timer fires (match restart), the helper still runs the budget
		# decrement — preventing a permanent _pending_smoke_puffs leak — then
		# bails on the freed scene. A capturing lambda would error and skip both.
		scene.get_tree().create_timer(delay).timeout.connect(
			_emit_delayed_smoke_puff.bind(scene, ground, radius, scale), CONNECT_ONE_SHOT)


static func _emit_delayed_smoke_puff(scene: Node, ground: Vector3, radius: float, scale: float) -> void:
	# Always release the budget slot first, even if the scene is already gone.
	_pending_smoke_puffs = maxi(0, _pending_smoke_puffs - 1)
	if not is_instance_valid(scene):
		return
	var ring := randf_range(0.0, radius * 0.16)
	var ang2 := randf() * TAU
	var col_offset := Vector3(cos(ang2) * ring, randf_range(1.0, 3.0), sin(ang2) * ring)
	spawn_smoke_puff(
		scene,
		ground + col_offset,
		randf_range(2.2, 4.5) * scale,
		Vector3(randf_range(-0.25, 0.25), randf_range(2.8, 5.0), randf_range(-0.25, 0.25)),
		randf_range(5.0, 8.5),
		Color(0.34, 0.32, 0.30, randf_range(0.18, 0.30)),
	)

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
	_attach_world_3d(scene, shell, pos)

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
	_attach_world_3d(scene, shell, pos)
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
static func spawn_impact(scene: Node, pos: Vector3, color: Color = Color(1.0, 0.9, 0.3), scale_f: float = 1.0, dmg_ratio: float = 1.0, vfx_max_impact_dust: int = 5, normal: Vector3 = Vector3.UP, explosive_radius: float = 0.0, collider: Node = null) -> void:
	if scene == null:
		return
	# Heavier guns leave a bigger crater of dust + a brighter spark, and once
	# damage is very high we add a second "heat flash" — as if the slug is
	# hot enough to burn the ground it lands in.
	var sz: float = scale_f * dmg_ratio
	var spark_boost: float = lerpf(1.0, 2.5, clampf((dmg_ratio - 1.0) / 4.0, 0.0, 1.0))

	# Persistent dark crater on the surface — always spawned, size scales with
	# damage. High-damage rounds add a glowing red-hot phase that fades; very
	# heavy rounds add a brief bright blink on top of the existing spark light
	# below. Round-reset clears the "craters" group.
	spawn_crater(scene, pos, normal, dmg_ratio, scale_f, collider)
	# Explosive rounds leave a larger soot ring AROUND the central crater —
	# the wider blast scorch. Sized off the actual explosive_radius rather
	# than damage so HEAVY-ROUNDS doesn't accidentally produce a giant ring.
	if explosive_radius > 0.0:
		spawn_blast_crater(scene, pos, normal, explosive_radius, collider)

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
	var dust_count: int = int(clampf(3.0 * dmg_ratio, 2.0, 15.0))
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

# Brief high-intensity beam for hitscan bullets. Rendered for 1-2 frames 
# as a bright white streak.
static func spawn_laser_tracer(scene: Node, from: Vector3, to: Vector3) -> void:
	if scene == null:
		return
	var dist := from.distance_to(to)
	if dist < 0.1:
		return

	var line := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	# Laser beam thickness. Long axis is Z.
	mesh.size = Vector3(0.025, 0.025, dist)
	line.mesh = mesh

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color.WHITE
	mat.emission_enabled = true
	mat.emission = Color.WHITE
	mat.emission_energy_multiplier = 22.0
	line.material_override = mat

	# Add to scene FIRST so global_transform / look_at work in world space.
	# Then set position and orientation.
	scene.add_child(line)
	line.global_position = from.lerp(to, 0.5)
	
	var dir := (to - from).normalized()
	# If pointing straight up/down, use a different up vector for look_at.
	if absf(dir.dot(Vector3.UP)) > 0.99:
		line.look_at(to, Vector3.RIGHT)
	else:
		line.look_at(to, Vector3.UP)

	# Bright white-hot flash at the muzzle
	var light := OmniLight3D.new()
	light.light_color = Color.WHITE
	light.light_energy = 15.0
	light.omni_range = 5.0
	scene.add_child(light)
	light.global_position = from

	var tw := line.create_tween()
	tw.tween_interval(0.04) # roughly 2-3 frames
	tw.tween_callback(line.queue_free)

	var ltw := light.create_tween()
	ltw.tween_property(light, "light_energy", 0.0, 0.1)
	ltw.tween_callback(light.queue_free)

# Persistent scorch mark on the impacted surface. Always spawned by
# spawn_impact; bigger rounds get bigger craters. dmg_ratio > ~2 adds an
# emission "red-hot" phase that fades to black over a few seconds. Lifetime
# ~25 s — and round-reset clears the "craters" group anyway.
const CRATER_LIFETIME := 25.0
const CRATER_RED_HOT_DMG := 2.0
const CRATER_BLINK_DMG := 2.0
const CRATER_TEXTURE_VARIANTS := 5

# Perf caps for full-auto spam — UZIs / shotguns can produce hundreds of
# impacts per second. Without these, transparent quads + tween updates
# accumulate into a noticeable cost.
const MAX_CRATERS := 120                # FIFO across the whole scene
const MAX_HOT_EXTRAS := 32              # concurrent warm + glow + OmniLight sets
const MAX_BLAST_CRATERS := 40           # outer rings from explosive impacts
const MAX_CRATERS_PER_FRAME := 10       # cap allocations per tick

# Cached procedural cloud-noise alpha textures. Built lazily on the first
# crater spawn so we don't pay the cost when no shots are fired. Each
# crater's QuadMesh tints the texture's white pixels with the dark scorch
# colour (and emission for red-hot craters).
static var _crater_textures: Array[Texture2D] = []
# Single shared circular disk mesh — every crater scales its instance via the
# basis instead of allocating a new mesh resource per shot. Using real circular
# geometry keeps the mark round even if texture filtering or edge clamps would
# otherwise make a square alpha plane read as stretched.
static var _shared_crater_mesh: Mesh = null
# FIFO of live crater nodes — when full, the oldest is freed to make room.
static var _crater_fifo: Array[Node] = []
# Live counts updated via tree_exiting signals so we never over-spawn the
# expensive extras (warm-glow, hot-spot, OmniLight) or blast scorches.
static var _hot_extras_active: int = 0
static var _blast_craters_active: int = 0
# Per-frame allocation budget — caps spawn rate from a UZI burst.
static var _crater_frame_id: int = -1
static var _craters_this_frame: int = 0

static func _get_crater_mesh() -> Mesh:
	if _shared_crater_mesh == null:
		var mesh := ArrayMesh.new()
		var verts := PackedVector3Array()
		var normals := PackedVector3Array()
		var uvs := PackedVector2Array()
		var indices := PackedInt32Array()
		var segments := 40
		verts.append(Vector3.ZERO)
		normals.append(Vector3.UP)
		uvs.append(Vector2(0.5, 0.5))
		for i in segments:
			var a := TAU * float(i) / float(segments)
			var x := cos(a) * 0.5
			var z := sin(a) * 0.5
			verts.append(Vector3(x, 0.0, z))
			normals.append(Vector3.UP)
			uvs.append(Vector2(0.5 + x, 0.5 + z))
		for i in segments:
			indices.append(0)
			indices.append(i + 1)
			indices.append(1 if i == segments - 1 else i + 2)
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_TEX_UV] = uvs
		arrays[Mesh.ARRAY_INDEX] = indices
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		_shared_crater_mesh = mesh
	return _shared_crater_mesh

static func _can_spawn_crater_this_frame() -> bool:
	var f := Engine.get_process_frames()
	if f != _crater_frame_id:
		_crater_frame_id = f
		_craters_this_frame = 0
	if _craters_this_frame >= MAX_CRATERS_PER_FRAME:
		return false
	_craters_this_frame += 1
	return true

# Push a crater into the FIFO. If the queue is over MAX_CRATERS, drop the
# oldest entry. Cheap — single linear pop from the front + O(1) append.
static func _enroll_crater(node: Node) -> void:
	while _crater_fifo.size() > 0 and not is_instance_valid(_crater_fifo[0]):
		_crater_fifo.pop_front()
	_crater_fifo.append(node)
	while _crater_fifo.size() > MAX_CRATERS:
		var old: Node = _crater_fifo.pop_front()
		if is_instance_valid(old):
			old.queue_free()

static func _ensure_crater_textures() -> void:
	if not _crater_textures.is_empty():
		return
	var rng := RandomNumberGenerator.new()
	for i in CRATER_TEXTURE_VARIANTS:
		# Stable per-variant seed so the same 5 textures are produced every run
		# — easier to reason about regressions visually.
		rng.seed = hash([i, "crater"])
		_crater_textures.append(_generate_crater_texture(rng))

static func _generate_crater_texture(rng: RandomNumberGenerator) -> Texture2D:
	# Radially-symmetric silhouette so the crater looks the same regardless
	# of how its quad ends up rotated by look_at. Internal noise modulates
	# brightness/density but never extends the silhouette past the radial
	# mask — so wall-orientation differences become invisible.
	var size := 64
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var noise := FastNoiseLite.new()
	noise.seed = int(rng.randi())
	noise.noise_type = FastNoiseLite.TYPE_PERLIN
	noise.frequency = 0.12
	noise.fractal_octaves = 3
	var center := Vector2(size, size) * 0.5
	var max_r: float = float(size) * 0.5
	for y in size:
		for x in size:
			var p := Vector2(x, y)
			var d_norm: float = p.distance_to(center) / max_r
			# Soft circular silhouette — single source of truth for the
			# crater's outline. Noise only modulates inside this mask.
			var radial: float = 1.0 - smoothstep(0.50, 0.98, d_norm)
			# Speckle: -0.18..+0.18 darkens / brightens the soot density.
			# Multiplied (not added to silhouette) so the outline stays round.
			var n: float = noise.get_noise_2d(float(x), float(y)) * 0.18
			var alpha: float = clampf(radial * (1.0 + n), 0.0, 1.0)
			img.set_pixel(x, y, Color(1, 1, 1, alpha))
	return ImageTexture.create_from_image(img)


static func _first_collision_shape(collider: Node) -> CollisionShape3D:
	if collider == null:
		return null
	if collider is CollisionShape3D:
		return collider as CollisionShape3D
	for child in collider.get_children():
		if child is CollisionShape3D:
			return child as CollisionShape3D
	return null


static func _distance_to_box_edge(local_pos: Vector3, local_dir: Vector3, half: Vector3) -> float:
	var d := local_dir.normalized()
	var best := INF
	if absf(d.x) > 0.0001:
		best = minf(best, ((half.x if d.x > 0.0 else -half.x) - local_pos.x) / d.x)
	if absf(d.y) > 0.0001:
		best = minf(best, ((half.y if d.y > 0.0 else -half.y) - local_pos.y) / d.y)
	if absf(d.z) > 0.0001:
		best = minf(best, ((half.z if d.z > 0.0 else -half.z) - local_pos.z) / d.z)
	return maxf(0.0, best) if best < INF else INF


static func _distance_to_cylinder_edge(local_pos: Vector3, local_dir: Vector3, shape: CylinderShape3D) -> float:
	var d := local_dir.normalized()
	var best := INF
	var half_h := shape.height * 0.5
	if absf(d.y) > 0.0001:
		best = minf(best, ((half_h if d.y > 0.0 else -half_h) - local_pos.y) / d.y)
	var a := d.x * d.x + d.z * d.z
	if a > 0.0001:
		var b := 2.0 * (local_pos.x * d.x + local_pos.z * d.z)
		var c := local_pos.x * local_pos.x + local_pos.z * local_pos.z - shape.radius * shape.radius
		var disc := b * b - 4.0 * a * c
		if disc >= 0.0:
			var root := sqrt(disc)
			var t1 := (-b - root) / (2.0 * a)
			var t2 := (-b + root) / (2.0 * a)
			if t1 > 0.0001:
				best = minf(best, t1)
			if t2 > 0.0001:
				best = minf(best, t2)
	return maxf(0.0, best) if best < INF else INF


static func _crater_surface_scale(pos: Vector3, right: Vector3, bitan: Vector3, size: float, collider: Node) -> Vector2:
	var col := _first_collision_shape(collider)
	if col == null or col.shape == null:
		return Vector2(size, size)
	var local_pos: Vector3 = col.global_transform.affine_inverse() * pos
	var inv_basis := col.global_transform.basis.inverse()
	var right_local: Vector3 = (inv_basis * right).normalized()
	var bitan_local: Vector3 = (inv_basis * bitan).normalized()
	var edge_pad := 0.96
	var max_right := INF
	var max_bitan := INF
	if col.shape is BoxShape3D:
		var half: Vector3 = (col.shape as BoxShape3D).size * 0.5
		max_right = minf(
			_distance_to_box_edge(local_pos, right_local, half),
			_distance_to_box_edge(local_pos, -right_local, half)
		)
		max_bitan = minf(
			_distance_to_box_edge(local_pos, bitan_local, half),
			_distance_to_box_edge(local_pos, -bitan_local, half)
		)
	elif col.shape is CylinderShape3D:
		var cyl := col.shape as CylinderShape3D
		max_right = minf(
			_distance_to_cylinder_edge(local_pos, right_local, cyl),
			_distance_to_cylinder_edge(local_pos, -right_local, cyl)
		)
		max_bitan = minf(
			_distance_to_cylinder_edge(local_pos, bitan_local, cyl),
			_distance_to_cylinder_edge(local_pos, -bitan_local, cyl)
		)
	if max_right == INF or max_bitan == INF:
		return Vector2(size, size)
	# Keep the texture circular. Near an edge, shrink uniformly to the tighter
	# tangent bound instead of turning the scorch into an oval.
	var uniform_size: float = minf(size, minf(max_right * 2.0 * edge_pad, max_bitan * 2.0 * edge_pad))
	uniform_size = maxf(0.035, uniform_size)
	return Vector2(uniform_size, uniform_size)


static func _crater_basis(normal: Vector3, rotation: float = 0.0) -> Basis:
	var n: Vector3 = normal.normalized() if normal.length_squared() > 0.001 else Vector3.UP
	var helper: Vector3 = Vector3.UP if absf(n.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	var right: Vector3 = helper.cross(n).normalized()
	var bitan: Vector3 = n.cross(right).normalized()
	return Basis(right, n, bitan).rotated(n, rotation)


static func spawn_crater(scene: Node, pos: Vector3, normal: Vector3, dmg_ratio: float, scale_f: float = 1.0, collider: Node = null) -> void:
	if scene == null or not _can_spawn_crater_this_frame():
		return
	_ensure_crater_textures()
	var dmg: float = clampf(dmg_ratio, 0.5, 6.0)
	# Crater size: scales linearly from ~10cm to ~80cm based on damage ratio.
	# This makes it much more obvious when a heavy round hits compared to a pistol.
	var size: float = (0.08 + 0.14 * dmg) * scale_f

	var splat := Decal.new()
	splat.add_to_group("craters")
	_enroll_crater(splat)

	# Build the basis manually so the orientation is identical across every
	# wall (look_at picks different up-vectors for axis-aligned normals,
	# producing visibly inconsistent rotations — that's what was wrong).
	var n: Vector3 = normal.normalized() if normal.length_squared() > 0.001 else Vector3.UP
	var rot := randf_range(-PI, PI)
	var b := _crater_basis(n, rot)
	var crater_scale := _crater_surface_scale(pos, b.x.normalized(), b.z.normalized(), size, collider)
	# Random jitter on the surface offset prevents Z-fighting when multiple 
	# shots hit the exact same spot.
	var offset_jitter: float = randf_range(-0.002, 0.002)
	splat.global_transform = Transform3D(b, pos + n * (0.012 + offset_jitter))
	splat.size = Vector3(crater_scale.x, 0.08, crater_scale.y)
	splat.texture_albedo = _crater_textures[randi() % _crater_textures.size()]
	var darkness: float = randf_range(0.04, 0.10)
	splat.modulate = Color(darkness, darkness, darkness, 1.0)
	splat.albedo_mix = 1.0
	splat.upper_fade = 0.0
	splat.lower_fade = 0.0
	splat.normal_fade = 0.35
	scene.add_child(splat)

	var hot: bool = dmg >= CRATER_RED_HOT_DMG
	if hot and _hot_extras_active < MAX_HOT_EXTRAS:
		_hot_extras_active += 1
		# Container for the glow layers + light so we can track the count
		# with a single signal and free them all together.
		var extras := Node3D.new()
		extras.tree_exiting.connect(func(): _hot_extras_active -= 1)
		scene.add_child(extras)

		var hot_amount: float = clampf((dmg - CRATER_RED_HOT_DMG) / 3.0, 0.0, 1.0)

		# Single bright additive quad in the centre as the molten spot. The
		# dark base scorch already darkens the wall material outside this
		# centre — a full-size warm glow on top would just paint the whole
		# crater red, which read as "way too hot" at any range.

		var glow_node := MeshInstance3D.new()
		glow_node.mesh = _get_crater_mesh()
		# Tiny center spot: 12.5% of the base crater size.
		var glow_b := b.rotated(n, randf_range(-PI, PI)).scaled(Vector3.ONE * 0.125)
		glow_node.global_transform = Transform3D(glow_b, pos + n * (0.020 + offset_jitter))
		var glow_mat := StandardMaterial3D.new()
		glow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		glow_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		glow_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		glow_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		# Render on top of the warm glow.
		glow_mat.render_priority = 2
		glow_mat.albedo_texture = _crater_textures[randi() % _crater_textures.size()]
		glow_mat.albedo_color = Color(1.0, 0.45, 0.10, lerpf(0.6, 1.0, hot_amount))
		glow_node.material_override = glow_mat
		extras.add_child(glow_node)

		var hot_tw := glow_node.create_tween()
		hot_tw.tween_property(glow_mat, "albedo_color", Color(0.55, 0.05, 0.0, 0.0), 6.0)\
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

		# Kill the whole "hot" set after the longest fade (6 s) finishes.
		var master_tw := extras.create_tween()
		master_tw.tween_interval(6.1)
		master_tw.tween_callback(extras.queue_free)

	# Bright camera-flash blink for high-damage rounds — shorter and brighter
	# than the heat light, reads as the kinetic flash of impact.
	if dmg >= CRATER_BLINK_DMG:
		var blink := OmniLight3D.new()
		blink.light_color = Color(1.0, 0.95, 0.85)
		blink.light_energy = lerpf(8.0, 24.0, clampf((dmg - CRATER_BLINK_DMG) / 4.0, 0.0, 1.0))
		blink.omni_range = lerpf(2.5, 6.0, clampf((dmg - CRATER_BLINK_DMG) / 4.0, 0.0, 1.0))
		blink.position = pos + n * 0.04
		scene.add_child(blink)
		var btw := blink.create_tween()
		btw.tween_property(blink, "light_energy", 0.0, 0.07)\
			.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
		btw.tween_callback(blink.queue_free)

	# Slow alpha fade across the full lifetime — the crater stays visible
	# until round reset (or this fade completes), whichever comes first.
	var fade_tw := splat.create_tween()
	fade_tw.tween_interval(CRATER_LIFETIME * 0.6)
	fade_tw.tween_property(splat, "modulate", Color(darkness, darkness, darkness, 0.0), CRATER_LIFETIME * 0.4)
	fade_tw.tween_callback(splat.queue_free)

# Outer scorch ring left by an explosive bullet — diameter scales with the
# blast radius, opacity is lower.
static func spawn_blast_crater(scene: Node, pos: Vector3, normal: Vector3, blast_radius: float, collider: Node = null) -> void:
	if scene == null or blast_radius <= 0.0 or _blast_craters_active >= MAX_BLAST_CRATERS:
		return
	_blast_craters_active += 1
	_ensure_crater_textures()
	# Surface scorch is much narrower than the air blast.
	var size: float = clampf(blast_radius * 0.45, 0.6, 3.5)

	var splat := Decal.new()
	splat.add_to_group("craters")
	splat.tree_exiting.connect(func(): _blast_craters_active -= 1)

	var n: Vector3 = normal.normalized() if normal.length_squared() > 0.001 else Vector3.UP
	var b := _crater_basis(n, randf_range(-PI, PI))
	var crater_scale := _crater_surface_scale(pos, b.x.normalized(), b.z.normalized(), size, collider)
	# Sit slightly further off the surface than the central crater.
	splat.global_transform = Transform3D(b, pos + n * 0.008)
	splat.size = Vector3(crater_scale.x, 0.10, crater_scale.y)
	splat.texture_albedo = _crater_textures[randi() % _crater_textures.size()]
	# Lighter / greyer than the central crater — surface soot, not a hole.
	var darkness: float = randf_range(0.10, 0.16)
	splat.modulate = Color(darkness, darkness, darkness, 0.55)
	splat.albedo_mix = 1.0
	splat.upper_fade = 0.0
	splat.lower_fade = 0.0
	splat.normal_fade = 0.35
	scene.add_child(splat)

	var fade_tw := splat.create_tween()
	fade_tw.tween_interval(CRATER_LIFETIME * 0.6)
	fade_tw.tween_property(splat, "modulate", Color(darkness, darkness, darkness, 0.0), CRATER_LIFETIME * 0.4)
	fade_tw.tween_callback(splat.queue_free)

# Cast cardinal-direction rays from an explosion center and drop a blast
# scorch on every surface within `radius`.
static func spawn_blast_scorches(scene: Node, pos: Vector3, radius: float) -> void:
	if scene == null or radius <= 0.0:
		return
	var space: PhysicsDirectSpaceState3D = scene.get_world_3d().direct_space_state
	if space == null:
		return
	const DIRS: Array[Vector3] = [
		Vector3.DOWN, Vector3.UP,
		Vector3.RIGHT, Vector3.LEFT,
		Vector3.FORWARD, Vector3.BACK,
	]
	for dir in DIRS:
		var q := PhysicsRayQueryParameters3D.create(pos, pos + dir * radius)
		q.collision_mask = 1  # world only
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			continue
		spawn_blast_crater(scene, hit.position, hit.normal, radius)

# Wipe all persistent craters — call from round-start cleanup.
static func clear_craters(scene_root: Node) -> void:
	if scene_root == null:
		return
	for n in scene_root.get_tree().get_nodes_in_group("craters"):
		if is_instance_valid(n):
			n.queue_free()
	_crater_fifo.clear()


static func clear_blood_splats(scene_root: Node) -> void:
	if scene_root == null:
		return
	for n in scene_root.get_tree().get_nodes_in_group("blood_splats"):
		if is_instance_valid(n):
			n.queue_free()
	for n in scene_root.get_tree().get_nodes_in_group("player_blood_wounds"):
		if is_instance_valid(n):
			n.queue_free()


static func clear_smoke_puffs(scene_root: Node) -> void:
	if scene_root == null:
		return
	for n in scene_root.get_tree().get_nodes_in_group("smoke_puffs"):
		if is_instance_valid(n):
			n.queue_free()

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
	var chaos := blast_severity * clampf(intensity / maxf(Weapon.REFERENCE_KNOCKBACK, 0.001), 0.6, 2.4)
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


# Headshot gore — red mist puffs radiating from the wound.
static func _spawn_headshot_puffs(
	scene: Node,
	pos: Vector3,
	dir: Vector3,
	severity: float,
	lethal: bool,
) -> void:
	if scene == null:
		return
	var dir_n := dir.normalized() if dir.length_squared() > 0.001 else Vector3.UP
	var sev := clampf(severity, 0.25, 3.0)
	var count := clampi(
		int(round(lerpf(6.0, 18.0, sev / 2.5) if lethal else lerpf(3.0, 9.0, sev / 1.8))),
		3, 20)
	var base_size := lerpf(0.12, 0.34, sev / 2.5) if lethal else lerpf(0.09, 0.22, sev / 1.6)
	var spread := lerpf(0.35, 0.75, sev / 2.5) if lethal else lerpf(0.28, 0.5, sev / 1.6)
	var travel := lerpf(0.55, 1.35, sev / 2.5) if lethal else lerpf(0.35, 0.85, sev / 1.6)

	for i in count:
		var puff := MeshInstance3D.new()
		var mesh := SphereMesh.new()
		mesh.radius = randf_range(base_size * 0.55, base_size * 1.25)
		mesh.height = mesh.radius * 2.0
		mesh.radial_segments = 6
		mesh.rings = 4
		puff.mesh = mesh
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		var shade := randf_range(0.32, 0.58)
		mat.albedo_color = Color(shade, 0.015, 0.01, randf_range(0.28, 0.55))
		mat.emission_enabled = true
		mat.emission = Color(0.55, 0.03, 0.02)
		mat.emission_energy_multiplier = lerpf(0.12, 0.35, sev / 2.5)
		puff.material_override = mat
		puff.position = pos + Vector3(
			randf_range(-0.06, 0.06),
			randf_range(-0.06, 0.06),
			randf_range(-0.06, 0.06),
		)
		scene.add_child(puff)

		var scatter := Vector3(
			randf_range(-spread, spread),
			randf_range(-0.18, 0.42),
			randf_range(-spread, spread),
		)
		var travel_dir := (dir_n + scatter).normalized()
		var end := puff.position + travel_dir * randf_range(travel * 0.55, travel * 1.15)
		var dur := randf_range(0.18, 0.42) if lethal else randf_range(0.22, 0.48)
		var tw := puff.create_tween().set_parallel(true)
		tw.tween_property(puff, "position", end, dur)\
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tw.tween_property(puff, "scale", Vector3.ONE * randf_range(2.0, 3.4), dur)\
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		tw.tween_property(mat, "albedo_color", Color(shade, 0.015, 0.01, 0.0), dur)\
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		tw.chain().tween_callback(puff.queue_free)


# Non-lethal head hit — extra red spray on top of the normal blood squirt.
static func spawn_headshot_spray(scene: Node, pos: Vector3, dir: Vector3, severity: float = 1.0) -> void:
	if scene == null:
		return
	var dir_n := dir.normalized() if dir.length_squared() > 0.001 else Vector3.UP
	var sev := clampf(severity, 0.35, 2.5)
	spawn_gib_mist(scene, pos, dir_n, sev * 1.35, 0.0, sev * 0.28)
	_spawn_headshot_puffs(scene, pos, dir_n, sev, false)


# Lethal headshot — head chunks + heavy red mist.
static func spawn_headshot_gore(scene: Node, pos: Vector3, dir: Vector3, intensity: float = 1.5) -> void:
	if scene == null:
		return
	var dir_n := dir.normalized() if dir.length_squared() > 0.001 else Vector3.UP
	var sev := clampf(intensity, 0.8, 3.0)

	var light := OmniLight3D.new()
	light.light_color = Color(0.95, 0.08, 0.06)
	light.light_energy = 5.5 * sev
	light.omni_range = 2.4 + sev * 0.9
	light.shadow_enabled = false
	_attach_world_3d(scene, light, pos)
	var lt := light.create_tween()
	lt.tween_property(light, "light_energy", 0.0, 0.2)\
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	lt.tween_callback(light.queue_free)

	spawn_gib_mist(scene, pos, dir_n, sev * 2.1, 0.0, sev * 0.55)
	spawn_blood(scene, pos, dir_n, sev * 1.75, 14)
	spawn_blast_blood_splash(scene, pos, dir_n, clampf(sev * 0.8, 0.5, 1.0))
	_spawn_headshot_puffs(scene, pos, dir_n, sev, true)


# Overkill gib — blood cloud + wall/floor splatter when a hit pulps the target.
static func spawn_overkill_gore(scene: Node, pos: Vector3, dir: Vector3, severity: float = 1.0) -> void:
	if scene == null:
		return
	var dir_n := dir.normalized() if dir.length_squared() > 0.001 else Vector3.UP
	var sev := clampf(severity, 0.4, 2.5)

	var light := OmniLight3D.new()
	light.light_color = Color(0.92, 0.06, 0.05)
	light.light_energy = 4.0 + sev * 3.5
	light.omni_range = 2.0 + sev * 1.4
	light.shadow_enabled = false
	_attach_world_3d(scene, light, pos)
	var lt := light.create_tween()
	lt.tween_property(light, "light_energy", 0.0, 0.24)\
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	lt.tween_callback(light.queue_free)

	spawn_gib_mist(scene, pos, dir_n, sev * 2.4, 0.0, sev * 0.65)
	spawn_blood(scene, pos, dir_n, sev * 2.0, 18)
	spawn_blast_blood_splash(scene, pos, dir_n, clampf(sev * 0.95, 0.55, 1.0))
	_spawn_headshot_puffs(scene, pos, dir_n, sev, true)
	spawn_overkill_blood_splats(scene, pos, dir_n, sev)


static func spawn_overkill_blood_splats(scene: Node, pos: Vector3, dir: Vector3, severity: float) -> void:
	if scene == null:
		return
	var space: PhysicsDirectSpaceState3D = scene.get_world_3d().direct_space_state
	if space == null:
		return
	var dir_n := dir.normalized() if dir.length_squared() > 0.001 else Vector3.UP
	var sev := clampf(severity, 0.4, 2.5)
	var radius := clampf(1.8 + sev * sev * 2.2, 1.8, 10.0)
	var strength := clampf(0.55 + sev * 0.72, 0.55, 2.35)
	const CARDINAL: Array[Vector3] = [
		Vector3.DOWN, Vector3.UP,
		Vector3.RIGHT, Vector3.LEFT,
		Vector3.FORWARD, Vector3.BACK,
	]
	var cardinal_passes := 1 if sev < 1.2 else (2 if sev < 1.9 else 3)
	for pass_i in cardinal_passes:
		var pass_strength := strength * lerpf(0.82, 1.0, float(pass_i) / maxf(float(cardinal_passes - 1), 1.0))
		for axis in CARDINAL:
			var offset := Vector3.ZERO
			if pass_i > 0:
				offset = Vector3(
					randf_range(-0.35, 0.35),
					randf_range(-0.35, 0.35),
					randf_range(-0.35, 0.35),
				)
			var origin := pos + offset
			var q := PhysicsRayQueryParameters3D.create(origin, origin + axis * radius)
			q.collision_mask = 1
			var hit := space.intersect_ray(q)
			if hit.is_empty():
				continue
			var hit_strength := pass_strength * (1.28 if axis == Vector3.DOWN else 1.0)
			_gib_spawn_blood_splat(scene, hit.position, hit.normal, dir_n, hit_strength)
	# Floor pool — big ground stain under the burst.
	var floor_count := clampi(int(round(2.0 + sev * sev * 5.0)), 2, 14)
	for i in floor_count:
		var offset := Vector3(
			randf_range(-0.55, 0.55) * sev,
			0.0,
			randf_range(-0.55, 0.55) * sev,
		)
		var origin := pos + offset + Vector3.UP * 0.2
		var qf := PhysicsRayQueryParameters3D.create(origin, origin + Vector3.DOWN * radius)
		qf.collision_mask = 1
		var floor_hit := space.intersect_ray(qf)
		if floor_hit.is_empty():
			continue
		_gib_spawn_blood_splat(
			scene,
			floor_hit.position,
			floor_hit.normal,
			dir_n,
			strength * randf_range(1.05, 1.35),
		)
	var spray_count := clampi(int(round(4.0 + sev * sev * 9.0)), 4, 28)
	for i in spray_count:
		var scatter := (-dir_n * lerpf(0.45, 0.85, sev / 2.5)) + Vector3(
			randf_range(-1.0, 1.0),
			randf_range(-0.35, 0.85),
			randf_range(-1.0, 1.0),
		)
		if scatter.length_squared() < 0.001:
			continue
		var ray_dir := scatter.normalized()
		var q2 := PhysicsRayQueryParameters3D.create(pos, pos + ray_dir * radius)
		q2.collision_mask = 1
		var hit2 := space.intersect_ray(q2)
		if hit2.is_empty():
			continue
		_gib_spawn_blood_splat(
			scene,
			hit2.position,
			hit2.normal,
			dir_n,
			strength * randf_range(0.78, 1.08),
		)


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
		# .bind (not a capturing lambda) so a player freed during the speed-of-
		# sound delay doesn't error on a freed capture; do_explosion_view_punch
		# guards is_instance_valid(player) for that case.
		player.get_tree().create_timer(delay).timeout.connect(
			do_explosion_view_punch.bind(player, pos, radius, peak))

static func do_explosion_view_punch(player: Node, pos: Vector3, radius: float, peak: float) -> void:
	if not is_instance_valid(player) or player.get("camera") == null:
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
	overkill_disintegrate: bool = false,
	overkill_severity: float = 0.0,
) -> void:
	if player == null:
		return
	# Switch to the squinty `>_<` face so the cloned ragdoll meshes inherit
	# that state. Done BEFORE hiding the body so visibility checks during
	# cloning still reflect the (about-to-be-hidden) authored tree.
	set_hit_face_state(player, true)
	player.set("_hit_face_timer", 0.0)  # don't let _process auto-revert on the dead body
	spawn_ragdoll(
		player, push_dir, force_origin, gib_force, blast_radius, blast_severity, is_head,
		overkill_disintegrate, overkill_severity,
	)
	if blast_radius > 0.0 or overkill_disintegrate:
		clear_player_blood_wounds(player)
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
	overkill_disintegrate: bool = false,
	overkill_severity: float = 0.0,
) -> void:
	# Voronoi-split the blob's primitive meshes into chunks that fly apart.
	# body_model is hidden first so the user only reads the flying debris.
	# Chunks collide with world only — players and bullets ignore the corpse.
	var scene: Node = player.get_tree().current_scene
	var full_disintegrate := blast_radius > 0.0 or overkill_disintegrate
	var inferred_force: float = push_dir.length()
	if gib_force > 0.0:
		inferred_force = maxf(inferred_force, gib_force)
	var kb_mag: float = clampf(sqrt(maxf(inferred_force, 1.0)), 1.0, 2.6)
	var dir_n: Vector3 = push_dir.normalized() if push_dir.length_squared() > 0.01 else Vector3.UP
	var chaos := 0.0
	if blast_radius > 0.0:
		chaos = clampf(blast_severity * clampf(gib_force / maxf(Weapon.REFERENCE_KNOCKBACK, 0.001), 0.6, 1.8), 0.0, 1.1)
	elif overkill_disintegrate:
		chaos = clampf(overkill_severity * 0.82, 0.35, 1.1)
	var blast_lift := 0.2
	if blast_radius > 0.0:
		blast_lift = 0.2 + chaos * 0.06
	elif overkill_disintegrate:
		blast_lift = 0.18 + chaos * 0.08
	var base_vel: Vector3 = dir_n * randf_range(2.2, 3.9) * kb_mag * (1.0 + chaos * 0.18) \
		+ Vector3.UP * randf_range(1.2, 2.8) * kb_mag * (1.0 + blast_lift)
	var burst_strength: float = 1.45 * kb_mag
	if blast_radius > 0.0:
		burst_strength *= 1.0 + clampf(blast_radius / 12.0, 0.0, 0.25) + chaos * 0.2
	elif overkill_disintegrate:
		burst_strength *= 1.0 + clampf(overkill_severity * 0.22, 0.0, 0.35) + chaos * 0.18

	var meshes: Array[MeshInstance3D] = []
	var body_model: Node = player.get("body_model")
	if body_model:
		collect_meshes(body_model, meshes)
	if meshes.is_empty():
		return
	var mist_origin: Vector3 = force_origin if force_origin != Vector3.INF else (player.global_position as Vector3) + Vector3.UP * 0.4
	if is_head and not full_disintegrate:
		var head_blob_for_fx: Node = player.get("head_blob")
		if head_blob_for_fx:
			mist_origin = (head_blob_for_fx as Node3D).global_position
	if overkill_disintegrate and blast_radius <= 0.0:
		spawn_overkill_gore(scene, mist_origin, dir_n, overkill_severity)
	elif is_head:
		spawn_headshot_gore(scene, mist_origin, dir_n, kb_mag)
	elif not full_disintegrate:
		spawn_gib_mist(scene, mist_origin, dir_n, kb_mag, blast_radius, blast_severity)
		if blast_radius > 0.0:
			spawn_blast_blood_splash(scene, mist_origin, dir_n, blast_severity)
	# Fixed chunk_count so the gib cache stays at one key per source mesh.
	var chunk_count: int = GIB_CHUNK_COUNT
	var impact_blood_strength := clampf(0.18 + kb_mag * 0.12 + chaos * 0.22, 0.15, 1.0)
	if overkill_disintegrate:
		impact_blood_strength = clampf(impact_blood_strength + overkill_severity * 0.18, 0.45, 1.0)

	# Death modes:
	#   • Explosion / overkill: chunk every body mesh — full disintegrate.
	#   • Headshot: head Voronoi-shatters, torso ragdolls intact.
	#   • Regular hit: whole body tumbles as a single rigid body.
	var local_is_authority: bool = player.is_multiplayer_authority() and not bool(player.get("is_bot"))
	var ragdoll_pieces: Array = player.get("_ragdoll_pieces")
	if full_disintegrate:
		var gore_int := kb_mag
		if overkill_disintegrate:
			gore_int = maxf(gore_int, overkill_severity)
		if blast_radius > 0.0:
			gore_int = maxf(gore_int, blast_severity * 1.15)
		var skip_mist := overkill_disintegrate and blast_radius <= 0.0
		var extra_gibs: Array = spawn_disintegrate_gore(
			scene,
			mist_origin,
			dir_n,
			gore_int,
			chaos,
			base_vel,
			burst_strength,
			force_origin,
			impact_blood_strength,
			skip_mist,
		)
		for g in extra_gibs:
			ragdoll_pieces.append(g)
		if blast_radius > 0.0:
			var splat_sev := clampf(blast_radius / 3.5 + blast_severity * 0.95, 1.0, 2.6)
			if overkill_disintegrate:
				splat_sev = maxf(splat_sev, overkill_severity)
			spawn_overkill_blood_splats(scene, mist_origin, dir_n, splat_sev)
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
				if scene.has_method("show_death_effect_for"):
					scene.show_death_effect_for(int(player.get("player_id")), true)
				elif scene.has_method("show_death_effect"):
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
			transfer_player_blood_wounds(player, torso_rb)
			if is_head and head_blob:
				var neck_wounds := _spawn_player_blood_cluster(
					torso_rb,
					(head_blob as Node3D).global_position,
					Vector3.UP,
					0.9,
					4,
				)
				_append_ragdoll_blood_wounds(torso_rb, neck_wounds)
			if local_is_authority:
				player.set("_ragdoll_head", torso_rb)
				if scene.has_method("show_death_effect_for"):
					scene.show_death_effect_for(int(player.get("player_id")), true)
				elif scene.has_method("show_death_effect"):
					scene.show_death_effect(true)
		if not head_meshes.is_empty():
			var head_pos: Vector3 = (head_blob as Node3D).global_position
			var head_vel: Vector3 = base_vel + dir_n * 9.0 + Vector3.UP * 11.0
			var head_burst: float = burst_strength * 2.1
			var head_blood: float = clampf(0.65 + kb_mag * 0.18, 0.55, 1.0)
			var first_head_chunk: bool = true
			for src in head_meshes:
				if src.mesh == null:
					continue
				var head_chunks: Array[RigidBody3D] = gib_explode(
					src.mesh,
					src.global_transform,
					scene,
					src.material_override,
					head_vel + Vector3(
						randf_range(-2.2, 2.2),
						randf_range(0.6, 2.8),
						randf_range(-2.2, 2.2),
					),
					head_burst,
					chunk_count,
					14.0,
					head_pos,
					head_blood,
				)
				for c in head_chunks:
					ragdoll_pieces.append(c)
					if first_head_chunk and local_is_authority:
						player.set("_ragdoll_head", c)
						first_head_chunk = false


# Free all spawned ragdoll pieces and restore body visibility / hitbox layers.
# Caller is responsible for calling _apply_ghost_visuals() afterward (since
# that touches Player-private rendering knobs).
static func clear_ragdoll(player: Node) -> void:
	var pieces: Array = player.get("_ragdoll_pieces")
	for piece in pieces:
		if is_instance_valid(piece):
			if piece is RigidBody3D:
				_free_ragdoll_blood_wounds(piece as RigidBody3D)
			piece.queue_free()
	pieces.clear()
	clear_player_blood_wounds(player)
	set_dead_visuals(player, false)

static func apply_knockback(player: Node, impulse: Vector3) -> void:
	if bool(player.get("ghost_mode")) or bool(player.get("frozen")) or not player.is_multiplayer_authority():
		return
	player.set("velocity", player.get("velocity") + impulse)
