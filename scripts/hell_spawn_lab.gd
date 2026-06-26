extends Node3D

# Hell spawn lab — iterate coop enemy pentagram telegraph + ground emerge.
#
# Run:
#   godot --path /Users/joep/dev/growing-guns res://scenes/hell_spawn_lab.tscn
#
# Controls: SPACE = trigger · RMB = mouse look · WASD/QE = move · Shift = sprint

const ARENA_SCENE := preload("res://scenes/arena_procedural.tscn")
const PLAYER_SCENE := preload("res://scenes/player.tscn")
const PLAYER_SCRIPT := preload("res://scripts/player.gd")

const MOVE_SPEED := 8.0
const FAST_MULT := 4.0
const MOUSE_SENS := 0.0025
const DEFAULT_ARENA_SEED := 42
const CAPSULE_HALF := 0.9
const CAMERA_OFFSET := Vector3(5.5, 4.2, 6.5)
const SPAWN_PICK_MIN_SEP := 4.0

var _camera: Camera3D
var _yaw: float = 0.0
var _pitch: float = -0.35

var _arena: Node3D
var _dummy: CharacterBody3D
var _arena_seed: int = DEFAULT_ARENA_SEED
var _spawn_pos := Vector3.ZERO
var _floor_pos := Vector3.ZERO
var _spawn_yaw: float = 0.0
var _spawn_info_label: Label
var _spawn_candidate_count: int = 0

var _telegraph_warmup: float = 0.9
var _telegraph_hold: float = 0.5
var _telegraph_cooldown: float = PLAYER_SCRIPT.HELL_EMERGE_GLOW
var _emerge_depth: float = PLAYER_SCRIPT.HELL_EMERGE_DEPTH
var _emerge_duration: float = PLAYER_SCRIPT.HELL_EMERGE_DURATION
var _star_radius: float = 1.05
var _play_sound: bool = true
var _repeat_interval: float = 0.0
var _repeat_accum: float = 0.0

var _sequence_busy: bool = false
var _telegraph_timer: float = -1.0
var _active_telegraph: Node3D = null


func _ready() -> void:
	_build_arena()
	_build_camera()
	_build_dummy()
	_build_ui()
	call_deferred("_refresh_spawn_site")
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _exit_tree() -> void:
	Engine.time_scale = 1.0


func _build_arena() -> void:
	_arena = ARENA_SCENE.instantiate()
	_arena.name = "Arena"
	add_child(_arena)
	_apply_arena_seed(_arena_seed)


func _apply_arena_seed(seed: int) -> void:
	_arena_seed = seed
	if _arena and _arena.has_method("apply_seed"):
		_arena.apply_seed(_arena_seed)
	_update_spawn_info_label()


func _random_arena_seed() -> void:
	_cancel_sequence()
	var next := randi() & 0xffff
	if next == _arena_seed:
		next = (next + 1) & 0xffff
	_apply_arena_seed(next)
	call_deferred("_refresh_spawn_site")


func _build_camera() -> void:
	_camera = Camera3D.new()
	_camera.fov = 75.0
	add_child(_camera)
	_camera.make_current()


func _build_dummy() -> void:
	var players := Node3D.new()
	players.name = "Players"
	add_child(players)
	_dummy = PLAYER_SCENE.instantiate() as CharacterBody3D
	_dummy.name = "HellDummy"
	_dummy.player_id = 9001
	_dummy.player_name = "HellDummy"
	_dummy.is_bot = true
	_dummy.set_multiplayer_authority(1)
	players.add_child(_dummy)
	if _dummy.has_method("apply_enemy_archetype"):
		_dummy.apply_enemy_archetype("grunt", 1)


func _refresh_spawn_site() -> void:
	_cancel_sequence()
	var candidates := _collect_spawn_candidates()
	_spawn_candidate_count = candidates.size()
	_spawn_pos = _pick_spawn_site_from(candidates, true)
	_floor_pos = Vector3(_spawn_pos.x, _spawn_pos.y - CAPSULE_HALF, _spawn_pos.z)
	_spawn_yaw = 0.0
	_frame_camera_on_spawn()
	_bury_dummy(true)
	_update_spawn_info_label()


func _pick_spawn_site_from(candidates: Array[Vector3], prefer_different: bool) -> Vector3:
	if candidates.is_empty():
		var origin := _arena.global_position if _arena else Vector3.ZERO
		return _standing_at(origin.x, origin.z)

	if not prefer_different or _spawn_pos == Vector3.ZERO:
		return _choose_weighted_spawn(candidates)

	var far_enough: Array[Vector3] = []
	for pos in candidates:
		var flat := Vector2(pos.x - _spawn_pos.x, pos.z - _spawn_pos.z)
		if flat.length() >= SPAWN_PICK_MIN_SEP:
			far_enough.append(pos)
	if not far_enough.is_empty():
		return _choose_weighted_spawn(far_enough)
	return _choose_weighted_spawn(candidates)


func _collect_spawn_candidates() -> Array[Vector3]:
	var seen: Dictionary = {}
	var scored: Array[Dictionary] = []
	for sp in get_tree().get_nodes_in_group("spawnpoints"):
		if sp is Node3D and _arena and _arena.is_ancestor_of(sp):
			_try_add_spawn_candidate(scored, seen, (sp as Node3D).global_position)
	for radius in range(6, 56, 3):
		var origin := _arena.global_position if _arena else Vector3.ZERO
		var steps := maxi(12, int(radius * 0.55))
		for i in steps:
			var ang := float(i) / float(steps) * TAU
			var wx := origin.x + cos(ang) * float(radius)
			var wz := origin.z + sin(ang) * float(radius)
			_try_add_spawn_candidate(scored, seen, _standing_at(wx, wz))
	if scored.is_empty():
		return []
	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["score"]) > float(b["score"])
	)
	var out: Array[Vector3] = []
	for entry in scored:
		out.append(entry["pos"] as Vector3)
	return out


func _try_add_spawn_candidate(scored: Array[Dictionary], seen: Dictionary, pos: Vector3) -> void:
	var key := "%d_%d" % [int(round(pos.x * 2.0)), int(round(pos.z * 2.0))]
	if seen.has(key):
		return
	if not _spawn_has_ground(pos):
		return
	if pos.y > 6.5:
		return
	seen[key] = true
	scored.append({"pos": pos, "score": _spawn_view_score(pos)})


func _choose_weighted_spawn(candidates: Array[Vector3]) -> Vector3:
	if candidates.is_empty():
		return Vector3.ZERO
	if candidates.size() == 1:
		return candidates[0]
	var pool: Array[Vector3] = []
	pool.assign(candidates.slice(0, mini(8, candidates.size())))
	pool.shuffle()
	return pool[0]


func _standing_at(world_x: float, world_z: float) -> Vector3:
	var floor_y := _floor_y_at(world_x, world_z)
	return Vector3(world_x, floor_y + CAPSULE_HALF, world_z)


func _floor_y_at(world_x: float, world_z: float) -> float:
	var space := get_world_3d().direct_space_state
	if space == null:
		return 0.0
	var from := Vector3(world_x, 40.0, world_z)
	var to := Vector3(world_x, -20.0, world_z)
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 1
	query.collide_with_areas = false
	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty():
		return 0.0
	return float(hit.get("position", from).y)


func _spawn_has_ground(pos: Vector3) -> bool:
	var space := get_world_3d().direct_space_state
	if space == null:
		return false
	var query := PhysicsRayQueryParameters3D.create(pos + Vector3.UP * 0.2, pos + Vector3.DOWN * 20.0)
	query.collision_mask = 1
	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty():
		return false
	var normal: Vector3 = hit.get("normal", Vector3.UP)
	return normal.dot(Vector3.UP) >= 0.65


func _spawn_view_score(pos: Vector3) -> float:
	var focus := pos + Vector3.UP * 1.2
	var cam := _camera_pos_for_spawn(pos)
	var clear := 1.0 if _line_of_sight_clear(cam, focus) else 0.0
	var height_penalty := pos.y * 0.35
	return clear * 100.0 - height_penalty


func _camera_pos_for_spawn(pos: Vector3) -> Vector3:
	var focus := pos + Vector3.UP * 1.2
	var cam := pos + CAMERA_OFFSET
	if _line_of_sight_clear(cam, focus):
		return cam
	for lift in [6.0, 8.5, 11.0, 14.0]:
		var lifted := pos + Vector3(CAMERA_OFFSET.x, lift, CAMERA_OFFSET.z)
		if _line_of_sight_clear(lifted, focus):
			return lifted
	return pos + Vector3(CAMERA_OFFSET.x, 14.0, CAMERA_OFFSET.z)


func _line_of_sight_clear(from: Vector3, to: Vector3) -> bool:
	var space := get_world_3d().direct_space_state
	if space == null:
		return true
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 1
	query.collide_with_areas = false
	var hit: Dictionary = space.intersect_ray(query)
	return hit.is_empty()


func _frame_camera_on_spawn() -> void:
	if _camera == null:
		return
	var focus := _spawn_pos + Vector3.UP * 1.2
	_camera.global_position = _camera_pos_for_spawn(_spawn_pos)
	_camera.look_at(focus, Vector3.UP)
	_yaw = _camera.rotation.y
	_pitch = _camera.rotation.x


func _bury_dummy(hide_body: bool = false) -> void:
	if _dummy == null:
		return
	_dummy.set("_hell_emerging", false)
	_dummy.set("_hell_emerge_finished", false)
	_dummy.velocity = Vector3.ZERO
	_dummy.frozen = false
	_dummy.health = _dummy.MAX_HEALTH
	Violence.clear_ragdoll(_dummy)
	Violence.set_dead_visuals(_dummy, false)
	if _dummy.has_method("_clear_hell_emerge_fx"):
		_dummy.call("_clear_hell_emerge_fx")
	if _dummy.has_method("_apply_identity_skin_materials"):
		_dummy.call("_apply_identity_skin_materials")
	if _dummy.has_method("_apply_ghost_visuals"):
		_dummy.call("_apply_ghost_visuals")
	var body_model: Node3D = _dummy.get("body_model") as Node3D
	if body_model:
		body_model.visible = not hide_body
	var name_label: Node3D = _dummy.get("name_label") as Node3D
	if name_label:
		name_label.visible = not hide_body
	_dummy.global_position = _spawn_pos - Vector3.UP * _emerge_depth
	_dummy.rotation.y = _spawn_yaw


func _show_dummy_for_emerge() -> void:
	if _dummy == null:
		return
	var body_model: Node3D = _dummy.get("body_model") as Node3D
	if body_model:
		body_model.visible = true
	var name_label: Node3D = _dummy.get("name_label") as Node3D
	if name_label:
		name_label.visible = true


func _cancel_sequence() -> void:
	_sequence_busy = false
	_telegraph_timer = -1.0
	if _active_telegraph and is_instance_valid(_active_telegraph):
		Violence.dismiss_enemy_incoming_telegraph(_active_telegraph, 0.12)
	_active_telegraph = null


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		Input.mouse_mode = (
			Input.MOUSE_MODE_VISIBLE
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
			else Input.MOUSE_MODE_CAPTURED
		)
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_SPACE:
		_trigger()
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * MOUSE_SENS
		_pitch = clampf(_pitch - event.relative.y * MOUSE_SENS, -1.4, 1.4)
		_camera.rotation = Vector3(_pitch, _yaw, 0)


func _process(delta: float) -> void:
	if _camera == null:
		return
	if not _camera.current:
		_camera.make_current()

	var move_delta := delta
	var dir := Vector3.ZERO
	var b := _camera.global_transform.basis
	if Input.is_key_pressed(KEY_W):
		dir -= b.z
	if Input.is_key_pressed(KEY_S):
		dir += b.z
	if Input.is_key_pressed(KEY_A):
		dir -= b.x
	if Input.is_key_pressed(KEY_D):
		dir += b.x
	if Input.is_key_pressed(KEY_E):
		dir += Vector3.UP
	if Input.is_key_pressed(KEY_Q):
		dir -= Vector3.UP
	if dir != Vector3.ZERO:
		var speed := MOVE_SPEED * (FAST_MULT if Input.is_key_pressed(KEY_SHIFT) else 1.0)
		_camera.global_position += dir.normalized() * speed * move_delta

	if _telegraph_timer >= 0.0:
		_telegraph_timer -= move_delta
		if _telegraph_timer <= 0.0:
			_telegraph_timer = -1.0
			_spawn_emerge()

	if _sequence_busy and _dummy and not bool(_dummy.get("_hell_emerging")):
		_sequence_busy = false
	if _active_telegraph and not is_instance_valid(_active_telegraph):
		_active_telegraph = null

	if _repeat_interval > 0.0 and not _sequence_busy:
		_repeat_accum += move_delta
		if _repeat_accum >= _repeat_interval:
			_repeat_accum = 0.0
			_trigger()


func _trigger() -> void:
	if _dummy == null:
		return
	_cancel_sequence()
	_sequence_busy = true
	_bury_dummy(true)
	if _play_sound:
		SFX.enemy_incoming(_spawn_pos)
	_active_telegraph = Violence.spawn_enemy_incoming_telegraph(
		self,
		_spawn_pos,
		_telegraph_warmup,
		_star_radius,
	) as Node3D
	_telegraph_timer = _telegraph_hold


func _spawn_emerge() -> void:
	if _dummy == null:
		_sequence_busy = false
		return
	_show_dummy_for_emerge()
	_dummy.global_position = _spawn_pos - Vector3.UP * _emerge_depth
	_dummy.rotation.y = _spawn_yaw
	_dummy.begin_hell_emerge.rpc(
		_spawn_pos,
		Time.get_ticks_msec(),
		_emerge_depth,
		_emerge_duration,
		_telegraph_cooldown,
	)


func _build_ui() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)
	var scroll := ScrollContainer.new()
	scroll.position = Vector2(12, 12)
	scroll.custom_minimum_size = Vector2(380, 560)
	scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	canvas.add_child(scroll)
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_PASS
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.66)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	panel.add_theme_stylebox_override("panel", sb)
	scroll.add_child(panel)
	var vb := VBoxContainer.new()
	vb.mouse_filter = Control.MOUSE_FILTER_PASS
	vb.add_theme_constant_override("separation", 5)
	panel.add_child(vb)

	_header(vb, "HELL SPAWN LAB", Color(1.0, 0.45, 0.12), 16)
	var hint := Label.new()
	hint.text = "SPACE = reset + pentagram + emerge · RMB look · WASD/QE move · Shift sprint"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(340, 0)
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	vb.add_child(hint)

	var trig_btn := Button.new()
	trig_btn.text = "⛧  RESET + HELL SPAWN"
	trig_btn.focus_mode = Control.FOCUS_NONE
	trig_btn.pressed.connect(_trigger)
	vb.add_child(trig_btn)

	var respawn_btn := Button.new()
	respawn_btn.text = "Next spawn site"
	respawn_btn.focus_mode = Control.FOCUS_NONE
	respawn_btn.pressed.connect(_refresh_spawn_site)
	vb.add_child(respawn_btn)

	var seed_btn := Button.new()
	seed_btn.text = "Random arena seed"
	seed_btn.focus_mode = Control.FOCUS_NONE
	seed_btn.pressed.connect(_random_arena_seed)
	vb.add_child(seed_btn)

	_spawn_info_label = Label.new()
	_spawn_info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_spawn_info_label.custom_minimum_size = Vector2(340, 0)
	_spawn_info_label.add_theme_font_size_override("font_size", 11)
	_spawn_info_label.add_theme_color_override("font_color", Color(0.72, 0.72, 0.72))
	vb.add_child(_spawn_info_label)

	vb.add_child(HSeparator.new())
	_header(vb, "TELEGRAPH", Color(1.0, 0.55, 0.2), 12)
	_add_slider(vb, "Warmup (s)", 0.2, 2.0, _telegraph_warmup, 0.05,
		func(v: float) -> void: _telegraph_warmup = v)
	_add_slider(vb, "Hold until spawn (s)", 0.5, 4.0, _telegraph_hold, 0.05,
		func(v: float) -> void: _telegraph_hold = v)
	_add_slider(vb, "Glow fade (s)", 0.15, 2.0, _telegraph_cooldown, 0.05,
		func(v: float) -> void: _telegraph_cooldown = v)
	_add_slider(vb, "Star radius (m)", 0.5, 2.0, _star_radius, 0.05,
		func(v: float) -> void: _star_radius = v)
	_add_toggle(vb, "Play SFX", _play_sound, func(on: bool) -> void: _play_sound = on)

	vb.add_child(HSeparator.new())
	_header(vb, "EMERGE", Color(1.0, 0.35, 0.1), 12)
	_add_slider(vb, "Burial depth (m)", 1.0, 4.0, _emerge_depth, 0.05,
		func(v: float) -> void: _emerge_depth = v)
	_add_slider(vb, "Rise duration (s)", 0.2, 2.5, _emerge_duration, 0.05,
		func(v: float) -> void: _emerge_duration = v)

	vb.add_child(HSeparator.new())
	_header(vb, "LAB", Color(0.85, 0.85, 0.85), 12)
	_add_slider(vb, "Time scale", 0.05, 1.0, Engine.time_scale, 0.01,
		func(v: float) -> void: Engine.time_scale = v)
	_add_slider(vb, "Auto-repeat (s, 0=off)", 0.0, 8.0, _repeat_interval, 0.1,
		func(v: float) -> void:
			_repeat_interval = v
			_repeat_accum = 0.0)


func _header(vb: VBoxContainer, text: String, col: Color, size: int) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	vb.add_child(l)


func _add_toggle(vb: VBoxContainer, label: String, value: bool, on_change: Callable) -> void:
	var cb := CheckButton.new()
	cb.text = label
	cb.button_pressed = value
	cb.focus_mode = Control.FOCUS_NONE
	cb.add_theme_font_size_override("font_size", 12)
	cb.toggled.connect(on_change)
	vb.add_child(cb)


func _add_slider(
	vb: VBoxContainer,
	label: String,
	lo: float,
	hi: float,
	value: float,
	step: float,
	on_change: Callable,
) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	vb.add_child(row)
	var lbl := Label.new()
	lbl.text = label
	lbl.custom_minimum_size = Vector2(168, 0)
	lbl.add_theme_font_size_override("font_size", 12)
	row.add_child(lbl)
	var slider := HSlider.new()
	slider.min_value = lo
	slider.max_value = hi
	slider.step = step
	slider.value = value
	slider.custom_minimum_size = Vector2(150, 18)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.focus_mode = Control.FOCUS_NONE
	row.add_child(slider)
	var val := Label.new()
	val.text = "%.2f" % value
	val.custom_minimum_size = Vector2(52, 0)
	val.add_theme_font_size_override("font_size", 12)
	row.add_child(val)
	slider.value_changed.connect(func(v: float) -> void:
		val.text = "%.2f" % v
		on_change.call(v))


func _update_spawn_info_label() -> void:
	if _spawn_info_label == null:
		return
	_spawn_info_label.text = "Arena seed %d · spawn (%.0f, %.0f) y=%.1f · %d sites" % [
		_arena_seed,
		_spawn_pos.x,
		_spawn_pos.z,
		_spawn_pos.y,
		_spawn_candidate_count,
	]
