extends Node3D

# Lava death lab — preview the lava-shader + sink sequence and tune sink/audio.
#
# Run: godot --path . res://scenes/lava_death_lab.tscn
#
# Controls: SPACE = trigger · RMB = mouse look · WASD/QE = move · Shift = sprint.

const ARENA_SCENE := preload("res://scenes/arena_procedural.tscn")
const PLAYER_SCENE := preload("res://scenes/player.tscn")

const MOVE_SPEED := 8.0
const FAST_MULT := 4.0
const MOUSE_SENS := 0.0025
const FALL_DROP_HEIGHT := 5.5
const LAVA_CONTACT_BODY_Y := 0.95

var _camera: Camera3D
var _yaw: float = 0.0
var _pitch: float = -0.22

var _arena: Node3D
var _dummy: CharacterBody3D
var _arena_seed: int = 0

var _fall_death: bool = true
var _play_sound: bool = true
var _repeat_interval: float = 0.0
var _repeat_accum: float = 0.0
var _fall_tween: Tween
var _busy_falling := false
var _spawn_x: float = 0.0
var _spawn_z: float = 0.0


func _ready() -> void:
	_build_arena()
	_build_camera()
	_build_dummy()
	_build_ui()
	_warmup()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _exit_tree() -> void:
	Engine.time_scale = 1.0


func _warmup() -> void:
	SFX.warmup_specials()


func _build_arena() -> void:
	_arena = ARENA_SCENE.instantiate()
	_arena.name = "Arena"
	add_child(_arena)
	if _arena.has_method("apply_seed"):
		var found_lava := false
		for seed in range(256):
			_arena.apply_seed(seed)
			var gen: Node = _arena.get_node_or_null("Generator")
			if gen and gen.has_method("is_all_floor_lava") and gen.is_all_floor_lava():
				_arena_seed = seed
				found_lava = true
				break
		if not found_lava:
			_arena.apply_seed(0)
			_arena_seed = 0
	call_deferred("_refresh_spawn_site")


func _build_camera() -> void:
	_camera = Camera3D.new()
	_camera.fov = 75.0
	_camera.rotation = Vector3(_pitch, _yaw, 0)
	add_child(_camera)
	_camera.global_position = Vector3(8.0, 5.0, 12.0)
	_yaw = _camera.rotation.y
	_pitch = _camera.rotation.x
	_camera.make_current()
	var listener := RaytracedAudioListener.new()
	_camera.add_child(listener)
	listener.owner = _camera


func _build_dummy() -> void:
	var players := Node3D.new()
	players.name = "Players"
	add_child(players)
	_dummy = PLAYER_SCENE.instantiate() as CharacterBody3D
	_dummy.name = "LavaDummy"
	_dummy.player_id = 1
	_dummy.player_name = "Dummy"
	_dummy.is_bot = true
	players.add_child(_dummy)


func _lava_surface_y() -> float:
	if _arena and _arena.has_method("get_lava_surface_world_y"):
		return float(_arena.call("get_lava_surface_world_y"))
	return 0.04


func _cancel_fall_tween() -> void:
	_busy_falling = false
	if _fall_tween != null and _fall_tween.is_valid():
		_fall_tween.kill()
	_fall_tween = null


func _contact_body_y() -> float:
	return _lava_surface_y() + LAVA_CONTACT_BODY_Y


func _idle_dummy_position() -> Vector3:
	var y: float = _contact_body_y() if not _fall_death else _lava_surface_y() + FALL_DROP_HEIGHT
	return Vector3(_spawn_x, y, _spawn_z)


func _refresh_spawn_site() -> void:
	var found := _find_open_lava_spawn_xz()
	_spawn_x = found.x
	_spawn_z = found.y
	if _camera:
		_camera.look_at(Vector3(_spawn_x, _lava_surface_y() + 1.2, _spawn_z), Vector3.UP)
		_yaw = _camera.rotation.y
		_pitch = _camera.rotation.x
	if _dummy:
		_reset_dummy()


func _find_open_lava_spawn_xz() -> Vector2:
	var lava_y := _lava_surface_y()
	var contact_y := lava_y + LAVA_CONTACT_BODY_Y
	var origin := _arena.global_position if _arena else Vector3.ZERO
	for radius in range(10, 68, 2):
		var steps := maxi(12, int(radius * 0.5))
		for i in steps:
			var ang := float(i) / float(steps) * TAU
			var wx := origin.x + cos(ang) * float(radius)
			var wz := origin.z + sin(ang) * float(radius)
			var probe := Vector3(wx, contact_y, wz)
			if _arena and _arena.has_method("is_lava_spawn_safe") and _arena.is_lava_spawn_safe(probe):
				continue
			if _solid_above_lava(wx, wz, lava_y):
				continue
			return Vector2(wx, wz)
	return Vector2(origin.x + 18.0, origin.z + 12.0)


func _solid_above_lava(world_x: float, world_z: float, lava_y: float) -> bool:
	var space := get_world_3d().direct_space_state
	if space == null:
		return false
	var from := Vector3(world_x, lava_y + 28.0, world_z)
	var to := Vector3(world_x, lava_y - 0.35, world_z)
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty():
		return false
	return float(hit.position.y) > lava_y + 0.12


func _reset_dummy() -> void:
	if _dummy == null:
		return
	_cancel_fall_tween()
	Violence.end_lava_death(_dummy)
	Violence.set_dead_visuals(_dummy, false)
	_dummy.health = _dummy.MAX_HEALTH
	_dummy.velocity = Vector3.ZERO
	var body_model: Node3D = _dummy.get("body_model") as Node3D
	if body_model:
		body_model.rotation.x = 0.0
		body_model.visible = true
	_dummy.global_position = _idle_dummy_position()


func _is_busy() -> bool:
	return _busy_falling or bool(_dummy.get("_lava_death_active")) if _dummy else false


func _input(event: InputEvent) -> void:
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
	var rt_delta: float = delta / maxf(Engine.time_scale, 0.0001)
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
		_camera.global_position += dir.normalized() * speed * rt_delta
	if _repeat_interval > 0.0 and not _is_busy():
		_repeat_accum += rt_delta
		if _repeat_accum >= _repeat_interval:
			_repeat_accum = 0.0
			_trigger()


func _trigger() -> void:
	if _dummy == null or _is_busy():
		return
	_cancel_fall_tween()
	Violence.end_lava_death(_dummy)
	_dummy.set("_lava_death_active", false)
	_dummy.velocity = Vector3.ZERO
	if _fall_death:
		_dummy.global_position = _idle_dummy_position()
		_begin_fall()
	else:
		_dummy.global_position = _idle_dummy_position()
		_commit_lava_death()


func _begin_fall() -> void:
	var target_y := _contact_body_y()
	var drop: float = maxf(_dummy.global_position.y - target_y, 0.1)
	var dur: float = clampf(sqrt(drop / 4.9), 0.45, 3.0)
	_busy_falling = true
	_fall_tween = create_tween()
	_fall_tween.tween_property(_dummy, "global_position:y", target_y, dur)\
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_fall_tween.tween_callback(_on_lava_impact)


func _on_lava_impact() -> void:
	_busy_falling = false
	_fall_tween = null
	_commit_lava_death()


func _commit_lava_death() -> void:
	if _dummy == null:
		return
	if _play_sound:
		SFX.lava_sizzle(_dummy.global_position, _fall_death)
		SFX.death(_dummy.global_position, true)
	Violence.play_lava_death(_dummy, _fall_death)


func _build_ui() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)
	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_TOP_LEFT)
	scroll.position = Vector2(12, 12)
	scroll.custom_minimum_size = Vector2(380, 520)
	canvas.add_child(scroll)
	var panel := PanelContainer.new()
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
	vb.add_theme_constant_override("separation", 5)
	panel.add_child(vb)

	_header(vb, "LAVA DEATH LAB", Color(1.0, 0.55, 0.2), 16)
	var hint := Label.new()
	hint.text = "SPACE = fall/trigger on lava contact · RMB look · WASD/QE move"
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	vb.add_child(hint)

	var trig_btn := Button.new()
	trig_btn.text = "🔥  LAVA DEATH"
	trig_btn.focus_mode = Control.FOCUS_NONE
	trig_btn.pressed.connect(_trigger)
	vb.add_child(trig_btn)

	var reset_btn := Button.new()
	reset_btn.text = "Reset dummy"
	reset_btn.focus_mode = Control.FOCUS_NONE
	reset_btn.pressed.connect(_reset_dummy)
	vb.add_child(reset_btn)

	vb.add_child(HSeparator.new())
	_header(vb, "MODE", Color(0.9, 0.75, 0.5), 12)
	_add_toggle(vb, "Fall into lava", _fall_death, func(on: bool) -> void:
		_fall_death = on
		_reset_dummy())
	_add_toggle(vb, "Play SFX", _play_sound, func(on: bool) -> void:
		_play_sound = on)
	_add_slider(vb, "Time scale", 0.02, 1.0, Engine.time_scale, 0.01,
		func(v: float) -> void: Engine.time_scale = v)
	_add_slider(vb, "Auto-repeat (s, 0=off)", 0.0, 6.0, _repeat_interval, 0.1,
		func(v: float) -> void:
			_repeat_interval = v
			_repeat_accum = 0.0)
	_add_slider(vb, "Arena seed (lava)", 0.0, 255.0, float(_arena_seed), 1.0,
		func(v: float) -> void:
			_arena_seed = int(v)
			if _arena and _arena.has_method("apply_seed"):
				_arena.apply_seed(_arena_seed)
			call_deferred("_refresh_spawn_site"))

	vb.add_child(HSeparator.new())
	_header(vb, "SINK", Color(1.0, 0.55, 0.25), 12)
	_bind_violence(vb, "Sink depth fall (m)", "lava_death_sink_y_fall", 0.1, 2.5, 0.05)
	_bind_violence(vb, "Sink depth stand (m)", "lava_death_sink_y_stand", 0.1, 2.0, 0.05)
	_bind_violence(vb, "Sink duration fall (s)", "lava_death_sink_dur_fall", 0.3, 5.0, 0.05)
	_bind_violence(vb, "Sink duration stand (s)", "lava_death_sink_dur_stand", 0.3, 4.0, 0.05)
	_bind_violence(vb, "Splash pillar height", "lava_splash_pillar_height", 0.6, 4.0, 0.05)
	_bind_violence(vb, "Splash pillar radius", "lava_splash_pillar_radius", 0.15, 1.5, 0.02)
	_bind_violence(vb, "Splash rise (s)", "lava_splash_rise_dur", 0.04, 0.5, 0.01)
	_bind_violence(vb, "Splash sink (s)", "lava_splash_sink_dur", 0.1, 1.5, 0.02)

	vb.add_child(HSeparator.new())
	_header(vb, "SFX (dB)", Color(0.7, 0.9, 1.0), 12)
	AudioSettingsPanel.add_sfx_slider(vb, "Lava fall sizzle", "lava_fall_sizzle_db", -50.0, 0.0, 150.0)
	AudioSettingsPanel.add_sfx_slider(vb, "Lava contact sizzle", "lava_sizzle_db", -50.0, 0.0, 150.0)
	AudioSettingsPanel.add_sfx_slider(vb, "Death self", "death_self_db", -50.0, 0.0, 130.0)
	AudioSettingsPanel.add_sfx_slider(vb, "Death world", "death_world_db", -40.0, 6.0, 130.0)


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


func _violence_float(prop: String) -> float:
	match prop:
		"lava_death_sink_y_fall": return Violence.lava_death_sink_y_fall
		"lava_death_sink_y_stand": return Violence.lava_death_sink_y_stand
		"lava_death_sink_dur_fall": return Violence.lava_death_sink_dur_fall
		"lava_death_sink_dur_stand": return Violence.lava_death_sink_dur_stand
		"lava_splash_pillar_height": return Violence.lava_splash_pillar_height
		"lava_splash_pillar_radius": return Violence.lava_splash_pillar_radius
		"lava_splash_rise_dur": return Violence.lava_splash_rise_dur
		"lava_splash_sink_dur": return Violence.lava_splash_sink_dur
		_: return 0.0


func _set_violence_float(prop: String, v: float) -> void:
	match prop:
		"lava_death_sink_y_fall": Violence.lava_death_sink_y_fall = v
		"lava_death_sink_y_stand": Violence.lava_death_sink_y_stand = v
		"lava_death_sink_dur_fall": Violence.lava_death_sink_dur_fall = v
		"lava_death_sink_dur_stand": Violence.lava_death_sink_dur_stand = v
		"lava_splash_pillar_height": Violence.lava_splash_pillar_height = v
		"lava_splash_pillar_radius": Violence.lava_splash_pillar_radius = v
		"lava_splash_rise_dur": Violence.lava_splash_rise_dur = v
		"lava_splash_sink_dur": Violence.lava_splash_sink_dur = v


func _bind_violence(
	vb: VBoxContainer,
	label: String,
	prop: String,
	lo: float,
	hi: float,
	step: float,
) -> void:
	_add_slider(vb, label, lo, hi, _violence_float(prop), step, func(v: float) -> void: _set_violence_float(prop, v))
