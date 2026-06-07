extends RigidBody3D

const Blast = preload("res://scripts/blast.gd")

const FUSE := 4.0                # fallback if the grenade somehow never touches anything
const ARM_DELAY := 0.04          # ignore contacts for this long after spawn (just enough to clear the muzzle)
# Mines stay dormant a bit longer than thrown grenades — long enough for the
# plant SFX (thud + arm-beep) to finish so the player hears the cue and the
# planter can step away before it'll trigger.
const MINE_ARM_DELAY := 0.7
const RADIUS := 6.0
const MAX_DAMAGE := 100
const MIN_DAMAGE := 20
const MIN_FALLOFF := 0.2
const SHAKE_RADIUS := 22.0
const SHAKE_STRENGTH := 0.16     # max camera-shake amplitude (m) at the epicenter
const VFX_TRANSIENT_LIGHTS := false
const MINE_TRIGGER_RADIUS := 1.25
const MINE_LIFETIME := 10.0        # mines quietly expire if nobody wanders in
const SPEED_OF_SOUND := 343.0      # m/s — same constant as audio + visuals use
const CLUSTER_POP_RADIUS := 3.5
const CLUSTER_POP_DAMAGE := 35.0
const FRAGMENT_COUNT := 7
const FRAGMENT_RADIUS := 3.2
const FRAGMENT_MAX_DAMAGE := 48.0
const FRAGMENT_MIN_DAMAGE := 14.0
const FRAGMENT_FUSE := 1.8
const FRAGMENT_LAUNCH_SPEED := 13.0
const FRAGMENT_LAUNCH_LIFT := 5.0
const FRAGMENT_ARM_DELAY := 0.12
const DASH_BOMB_FUSE := 1.0
const DASH_BOMB_RADIUS := 2.8
const DASH_BOMB_MAX_DAMAGE := 42.0
const DASH_BOMB_MIN_DAMAGE := 10.0

# Static-cached shaders for the heat-distortion shell + shockwave ring. Each
# explosion used to call Shader.new() with identical source, paying a fresh
# bytecode parse + PSO compile on first detonation of every match. Caching at
# class scope means the bytecode parse happens once total; the PSO can be
# pre-warmed via warmup_shaders().
static var _heat_shader_cached: Shader = null
static var _shock_shader_cached: Shader = null

const _HEAT_SHADER_CODE := "
	shader_type spatial;
	render_mode unshaded, cull_disabled, depth_draw_never;

	uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
	uniform float distortion_strength = 0.05;
	uniform float zoom_strength = 0.018;
	uniform float opacity = 0.2;

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
"

const _SHOCK_SHADER_CODE := "
	shader_type spatial;
	render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

	uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
	uniform float distortion_strength = 0.04;
	uniform float ring_thickness = 7.0;
	uniform float opacity = 0.85;

	void fragment() {
		float fresnel = pow(1.0 - abs(dot(normalize(VIEW), NORMAL)), ring_thickness);
		vec3 n = normalize((VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
		vec2 offset = n.xy * distortion_strength * fresnel;
		vec3 col = texture(screen_tex, SCREEN_UV + offset).rgb;
		ALBEDO = col;
		ALPHA = fresnel * opacity;
	}
"


static func _get_heat_shader() -> Shader:
	if _heat_shader_cached == null:
		_heat_shader_cached = Shader.new()
		_heat_shader_cached.code = _HEAT_SHADER_CODE
	return _heat_shader_cached


static func _get_shock_shader() -> Shader:
	if _shock_shader_cached == null:
		_shock_shader_cached = Shader.new()
		_shock_shader_cached.code = _SHOCK_SHADER_CODE
	return _shock_shader_cached


# Force the GPU to compile the heat + shock shader pipelines now (during a
# quiet warmup window) instead of on the first explosion mid-fight. Attaches
# tiny invisible meshes to the scene; they self-free after a couple frames.
static func warmup_shaders(scene: Node) -> void:
	if scene == null:
		return
	for shader: Shader in [_get_heat_shader(), _get_shock_shader()]:
		var mat := ShaderMaterial.new()
		mat.shader = shader
		var mi := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 0.001
		sphere.height = 0.002
		mi.mesh = sphere
		mi.material_override = mat
		# Park at scene origin so it's actually rendered (compiles the PSO),
		# but at sub-pixel scale so it's invisible.
		scene.add_child(mi)
		mi.global_position = Vector3.ZERO
		var t := Timer.new()
		t.wait_time = 0.3
		t.one_shot = true
		t.process_mode = Node.PROCESS_MODE_ALWAYS
		mi.add_child(t)
		t.start()
		t.timeout.connect(mi.queue_free)


@export var shooter_id: int = 1
@export var is_mine: bool = false
@export var is_cluster_parent: bool = false
@export var is_fragment: bool = false
@export var is_dash_bomb: bool = false
@export var predicted_visual: bool = false

var _age := 0.0
var _exploded := false

func _ready() -> void:
	set_multiplayer_authority(1)
	add_to_group("projectiles")
	if not multiplayer.is_server() and is_mine:
		freeze = true
		freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	body_entered.connect(_on_body_entered)
	if is_fragment:
		scale = Vector3(0.55, 0.55, 0.55)
		_tint_mesh(Color(1.0, 0.42, 0.12))
	elif is_cluster_parent:
		scale = Vector3(1.22, 1.22, 1.22)
		_tint_mesh(Color(1.0, 0.55, 0.15))
	elif is_dash_bomb:
		scale = Vector3(0.62, 0.62, 0.62)
		_tint_mesh(Color(1.0, 0.32, 0.14))
		freeze = true
		freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC


func _tint_mesh(color: Color) -> void:
	var mesh := get_node_or_null("Mesh") as MeshInstance3D
	if mesh == null:
		return
	var mat := mesh.get_active_material(0)
	if mat == null:
		return
	var dup := mat.duplicate() as StandardMaterial3D
	dup.albedo_color = color
	dup.emission = color.lerp(Color(1.0, 0.85, 0.35), 0.45)
	dup.emission_energy_multiplier = 1.1
	mesh.material_override = dup


func _blast_radius() -> float:
	if is_dash_bomb:
		return DASH_BOMB_RADIUS
	if is_fragment:
		return FRAGMENT_RADIUS
	if is_cluster_parent:
		return CLUSTER_POP_RADIUS
	return RADIUS


func _max_damage() -> float:
	if is_dash_bomb:
		return DASH_BOMB_MAX_DAMAGE
	if is_fragment:
		return FRAGMENT_MAX_DAMAGE
	if is_cluster_parent:
		return CLUSTER_POP_DAMAGE
	return MAX_DAMAGE


func _min_damage() -> float:
	if is_dash_bomb:
		return DASH_BOMB_MIN_DAMAGE
	if is_fragment:
		return FRAGMENT_MIN_DAMAGE
	return MIN_DAMAGE


func _arm_delay() -> float:
	if is_fragment:
		return FRAGMENT_ARM_DELAY
	return ARM_DELAY


func _fuse_time() -> float:
	if is_dash_bomb:
		return DASH_BOMB_FUSE
	if is_fragment:
		return FRAGMENT_FUSE
	return FUSE

func _physics_process(delta: float) -> void:
	if _exploded:
		return
	_age += delta
	if not multiplayer.is_server():
		return
	if is_dash_bomb:
		if _age >= DASH_BOMB_FUSE:
			_explode()
		return
	if is_mine:
		if _age >= MINE_LIFETIME:
			_disarm()
		else:
			_maybe_trigger_mine()
	elif _age >= _fuse_time():
		_explode()

func _on_body_entered(_body: Node) -> void:
	# Only the authoritative server triggers explosions; clients are passive visuals.
	if not multiplayer.is_server() or _exploded:
		return
	if _age < _arm_delay():
		return
	if is_mine:
		return
	if is_dash_bomb:
		return
	_explode()

func _maybe_trigger_mine() -> void:
	if _age < MINE_ARM_DELAY:
		return
	for p in get_tree().get_nodes_in_group("players"):
		if not is_instance_valid(p):
			continue
		if p.get("ghost_mode") == true:
			continue
		if global_position.distance_to(p.global_position) <= MINE_TRIGGER_RADIUS:
			_explode()
			return

# Called when a bullet hits the grenade (server-side raycast on the rifle).
func detonate() -> void:
	if _exploded or not multiplayer.is_server():
		return
	if is_mine:
		_disarm()
		return
	if is_dash_bomb:
		return
	_explode()

func _disarm() -> void:
	if _exploded:
		return
	_exploded = true
	_remove_quietly.rpc()

@rpc("authority", "call_local", "reliable")
func _remove_quietly() -> void:
	queue_free()

func _explode() -> void:
	_exploded = true
	if is_cluster_parent:
		_explode_cluster_parent()
		return
	var radius := _blast_radius()
	Blast.apply(
		get_tree().current_scene,
		global_position,
		radius,
		float(_max_damage()),
		shooter_id,
		MIN_FALLOFF,
		0.4,
		1.0,
		0.4,
		Blast.LOS_CENTER,
		false,
		_min_damage(),
		SPEED_OF_SOUND
	)
	_do_vfx.rpc()


func _explode_cluster_parent() -> void:
	var pos := global_position
	var radius := CLUSTER_POP_RADIUS
	Blast.apply(
		get_tree().current_scene,
		pos,
		radius,
		CLUSTER_POP_DAMAGE,
		shooter_id,
		MIN_FALLOFF,
		0.35,
		1.0,
		0.4,
		Blast.LOS_CENTER,
		false,
		12.0,
		SPEED_OF_SOUND
	)
	_spawn_cluster_fragments.rpc(pos, shooter_id)
	_do_cluster_pop_vfx.rpc(pos, radius)


@rpc("authority", "call_local", "reliable")
func _spawn_cluster_fragments(origin: Vector3, shooter: int) -> void:
	var scene: PackedScene = load("res://scenes/grenade.tscn")
	var cluster_id: int = hash([origin.x, origin.y, origin.z, shooter]) & 0x7fffffff
	var rng := RandomNumberGenerator.new()
	rng.seed = cluster_id
	var golden := PI * (3.0 - sqrt(5.0))
	for i in FRAGMENT_COUNT:
		var g := scene.instantiate()
		g.is_fragment = true
		g.shooter_id = shooter
		g.name = "CF_%d_%x_%d" % [shooter, cluster_id, i]
		get_tree().current_scene.add_child(g)
		g.global_position = origin + Vector3.UP * 0.15
		var y := 1.0 - (float(i) + 0.5) / float(FRAGMENT_COUNT) * 2.0
		var r := sqrt(maxf(0.0, 1.0 - y * y))
		var theta := golden * float(i)
		var dir := Vector3(cos(theta) * r, y, sin(theta) * r).normalized()
		dir = dir.lerp(Vector3.UP, 0.18).normalized()
		dir = dir.rotated(Vector3.UP, rng.randf_range(-0.35, 0.35))
		g.linear_velocity = dir * (FRAGMENT_LAUNCH_SPEED + rng.randf_range(-1.5, 2.0)) \
			+ Vector3(0.0, FRAGMENT_LAUNCH_LIFT + rng.randf_range(-0.5, 1.0), 0.0)


@rpc("authority", "call_local", "reliable")
func _do_cluster_pop_vfx(pos: Vector3, radius: float) -> void:
	SFX.explosion(pos, radius)
	var scene: Node = get_tree().current_scene
	if scene and scene.has_method("trigger_explosion_sidechain"):
		scene.trigger_explosion_sidechain(pos, radius, 0.85)
	Violence.spawn_blast_scorches(scene, pos, radius)
	var core := MeshInstance3D.new()
	var core_mesh := SphereMesh.new()
	core_mesh.radius = 0.45
	core_mesh.height = 0.9
	core.mesh = core_mesh
	var core_mat := StandardMaterial3D.new()
	core_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	core_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	core_mat.albedo_color = Color(1.0, 0.72, 0.22, 0.12)
	core_mat.emission_enabled = true
	core_mat.emission = Color(1.0, 0.55, 0.12)
	core_mat.emission_energy_multiplier = 14.0
	core_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	core.material_override = core_mat
	core.global_position = pos
	scene.add_child(core)
	var tw := core.create_tween().set_parallel(true)
	var dur := 0.14
	var target_scale := Vector3.ONE * maxf(0.01, radius / core_mesh.radius)
	tw.tween_property(core, "scale", target_scale, dur)
	tw.tween_property(core_mat, "albedo_color", Color(1.0, 0.35, 0.05, 0.0), dur)
	tw.tween_property(core_mat, "emission_energy_multiplier", 0.0, dur * 0.8)
	tw.chain().tween_callback(core.queue_free)
	var lp: Node = scene.get("local_player")
	if lp and is_instance_valid(lp) and lp.has_method("apply_explosion_view_punch"):
		lp.apply_explosion_view_punch(pos, radius, 0.9)
	queue_free()

@rpc("authority", "call_local", "reliable")
func _do_vfx() -> void:
	var radius := _blast_radius()
	SFX.explosion(global_position, radius)
	var pos: Vector3 = global_position
	var scene: Node = get_tree().current_scene
	if scene and scene.has_method("trigger_explosion_sidechain"):
		scene.trigger_explosion_sidechain(pos, radius, 1.25)
	_spawn_heat_distortion(scene, pos, radius, 0.3, 0.055)
	_spawn_shockwave_ring(scene, pos, radius)
	# Surface scorch rings — same helper as explosive bullets, raycasts in
	# the 6 cardinal directions and drops a soot crater on each surface hit.
	Violence.spawn_blast_scorches(scene, pos, radius)

	Violence._spawn_blast_fireball(scene, pos, radius, Color(1.0, 0.9, 0.32))

	Violence._spawn_blast_flash_light(scene, pos, radius)
	Violence._spawn_blast_core_light(scene, pos, radius, Color(1.0, 0.9, 0.32), 0.85)

	# --- Local camera shake with distance falloff
	var lp: Node = scene.get("local_player")
	if lp and is_instance_valid(lp) and lp.has_method("apply_explosion_view_punch"):
		lp.apply_explosion_view_punch(pos, radius, 1.25)

	queue_free()

func _spawn_heat_distortion(scene: Node, pos: Vector3, radius: float, duration: float, strength: float) -> void:
	if scene == null:
		return
	var shell := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.3
	mesh.height = 0.6
	mesh.radial_segments = 24
	mesh.rings = 12
	shell.mesh = mesh
	var mat := ShaderMaterial.new()
	mat.shader = _get_heat_shader()
	mat.set_shader_parameter("distortion_strength", strength * 2.4)
	mat.set_shader_parameter("zoom_strength", strength * 0.9)
	mat.set_shader_parameter("opacity", 0.38)
	shell.material_override = mat
	shell.position = pos
	scene.add_child(shell)

	var target_scale := Vector3.ONE * maxf(0.01, (radius * 1.95) / mesh.radius)
	var tw := shell.create_tween().set_parallel(true)
	tw.tween_property(shell, "scale", target_scale, duration)\
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.tween_method(
		func(v: float) -> void: mat.set_shader_parameter("distortion_strength", v),
		strength,
		0.0,
		duration * 0.9
	).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.tween_method(
		func(v: float) -> void: mat.set_shader_parameter("zoom_strength", v),
		strength * 0.35,
		0.0,
		duration * 0.9
	).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.tween_method(
		func(v: float) -> void: mat.set_shader_parameter("opacity", v),
		0.38,
		0.0,
		duration * 0.7
	).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.chain().tween_callback(shell.queue_free)

# Thin-shell screen-space shockwave: a sphere expanding at the speed of sound.
# A high-power fresnel concentrates the pixel displacement on the silhouette
# ring, so the camera sees a thin distorted halo travelling outward.
func _spawn_shockwave_ring(scene: Node, pos: Vector3, radius: float) -> void:
	if scene == null:
		return
	var shell := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.25
	mesh.height = 0.5
	mesh.radial_segments = 32
	mesh.rings = 16
	shell.mesh = mesh
	var mat := ShaderMaterial.new()
	mat.shader = _get_shock_shader()
	mat.set_shader_parameter("distortion_strength", 0.05)
	mat.set_shader_parameter("ring_thickness", 7.0)
	mat.set_shader_parameter("opacity", 0.9)
	shell.material_override = mat
	shell.position = pos
	scene.add_child(shell)
	# Sound-speed expansion (matches audio delay) with a 30 ms minimum so
	# tiny blasts remain visible.
	var dur: float = maxf(0.03, radius / 343.0)
	var target_scale := Vector3.ONE * maxf(0.01, (radius * 1.05) / mesh.radius)
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
