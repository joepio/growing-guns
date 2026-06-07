extends Node3D

# Explosion lab: a controlled arena for seeing + hearing explosions in
# isolation, with live sliders to retune them — including a time-scale knob so
# you can watch the fireball / shockwave / light decay in slow motion.
#
# Run: godot --path . res://scenes/explosion_lab.tscn  (or set as main scene).
#
# Controls: SPACE = boom now · RMB = mouse look · WASD/QE = move · Shift = sprint.
# The blast spawns at a fixed pad in front of the start camera; move around it
# freely. Time scale only slows the visuals (tweens) — audio always plays at
# normal pitch, which is what you want for judging the synth.

const ARENA_SCENE := preload("res://scenes/arena_procedural.tscn")
const ARENA_SEED := 7

const MOVE_SPEED := 8.0
const FAST_MULT := 4.0
const MOUSE_SENS := 0.0025

# Where blasts spawn. Camera starts framing it.
const BLAST_PAD := Vector3(0.0, 2.0, 0.0)

const WARM_COLOR := Color(1.0, 0.9, 0.32)
const ION_COLOR := Color(0.38, 0.78, 1.0)

const TYPE_BULLET := 0
const TYPE_ION := 1

# Player paths look up scene.get("state")/("local_player") in null-guarded
# spots; mirror action_lab so the shared blast code is happy.
var state: int = 1
var local_player: Node = null

var _camera: Camera3D
var _yaw: float = 0.0
var _pitch: float = -0.18

# Tunables (driven by the sliders).
var _radius: float = 8.0
var _repeat_interval: float = 0.0   # 0 = off
var _blast_type: int = TYPE_BULLET
var _repeat_accum: float = 0.0

func _ready() -> void:
	_build_arena()
	_build_camera()
	_build_ui()
	_warmup()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _exit_tree() -> void:
	# Don't leak slow-mo back into the rest of the engine.
	Engine.time_scale = 1.0

func _warmup() -> void:
	# Compile the blast pipelines + synth the sounds up front so the very first
	# boom doesn't hitch (same warmup the real game does at round start / boot).
	Violence.warmup_blast_materials(self)
	preload("res://scripts/grenade.gd").warmup_shaders(self)
	preload("res://scripts/ion_cannon.gd").warmup_shaders(self)
	SFX.warmup_specials()

# -------------------- scene --------------------

func _build_arena() -> void:
	var arena: Node = ARENA_SCENE.instantiate()
	arena.name = "Arena"
	add_child(arena)
	if arena.has_method("apply_seed"):
		arena.apply_seed(ARENA_SEED)

func _build_camera() -> void:
	_camera = Camera3D.new()
	_camera.fov = 75.0
	_camera.rotation = Vector3(_pitch, _yaw, 0)
	add_child(_camera)
	_camera.global_position = Vector3(0, 5, 16)
	_camera.make_current()
	# Raytraced-audio listener tracks the active camera (one per scene).
	var listener := RaytracedAudioListener.new()
	_camera.add_child(listener)
	listener.owner = _camera

# -------------------- input / camera --------------------

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		Input.mouse_mode = (
			Input.MOUSE_MODE_VISIBLE
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
			else Input.MOUSE_MODE_CAPTURED
		)
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_SPACE:
		_boom()
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
	# Real-time delta so camera + auto-repeat stay responsive under slow-mo.
	var rt_delta: float = delta / maxf(Engine.time_scale, 0.0001)
	var dir := Vector3.ZERO
	var b := _camera.global_transform.basis
	if Input.is_key_pressed(KEY_W): dir -= b.z
	if Input.is_key_pressed(KEY_S): dir += b.z
	if Input.is_key_pressed(KEY_A): dir -= b.x
	if Input.is_key_pressed(KEY_D): dir += b.x
	if Input.is_key_pressed(KEY_E): dir += Vector3.UP
	if Input.is_key_pressed(KEY_Q): dir -= Vector3.UP
	if dir != Vector3.ZERO:
		var speed := MOVE_SPEED * (FAST_MULT if Input.is_key_pressed(KEY_SHIFT) else 1.0)
		_camera.global_position += dir.normalized() * speed * rt_delta
	if _repeat_interval > 0.0:
		_repeat_accum += rt_delta
		if _repeat_accum >= _repeat_interval:
			_repeat_accum = 0.0
			_boom()

# -------------------- explosions --------------------

func _boom() -> void:
	match _blast_type:
		TYPE_ION:
			# Audio (base bang + the 40 Hz sawtooth burst) is fully handled by
			# ion_cannon_detonate; spawn the visual with play_audio off so the
			# explosion bang isn't doubled.
			SFX.ion_cannon_detonate(BLAST_PAD, _radius)
			Violence.spawn_bullet_blast(self, BLAST_PAD, _radius, ION_COLOR, null, false)
		_:
			Violence.spawn_bullet_blast(self, BLAST_PAD, _radius, WARM_COLOR, null, true)

# -------------------- UI --------------------

func _build_ui() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.position = Vector2(12, 12)
	panel.custom_minimum_size = Vector2(400, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.66)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	panel.add_theme_stylebox_override("panel", sb)
	canvas.add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 5)
	panel.add_child(vb)

	var title := Label.new()
	title.text = "EXPLOSION LAB"
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", Color(1, 0.7, 0.3))
	vb.add_child(title)
	var hint := Label.new()
	hint.text = "SPACE boom · RMB look · WASD/QE move · Shift sprint"
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	vb.add_child(hint)

	# Big trigger button.
	var boom_btn := Button.new()
	boom_btn.text = "💥  BOOM"
	boom_btn.focus_mode = Control.FOCUS_NONE
	boom_btn.pressed.connect(_boom)
	vb.add_child(boom_btn)

	# Blast type.
	var type_row := HBoxContainer.new()
	type_row.add_theme_constant_override("separation", 8)
	vb.add_child(type_row)
	var type_lbl := Label.new()
	type_lbl.text = "Type"
	type_lbl.custom_minimum_size = Vector2(120, 0)
	type_lbl.add_theme_font_size_override("font_size", 12)
	type_row.add_child(type_lbl)
	var type_opt := OptionButton.new()
	type_opt.focus_mode = Control.FOCUS_NONE
	type_opt.add_item("Bullet blast", TYPE_BULLET)
	type_opt.add_item("Ion detonation", TYPE_ION)
	type_opt.item_selected.connect(func(idx: int) -> void: _blast_type = idx)
	type_row.add_child(type_opt)

	var sep := HSeparator.new()
	vb.add_child(sep)

	# Scene tunables.
	_add_slider(vb, "Time scale (slow-mo)", 0.05, 1.0, Engine.time_scale, 0.01,
		func(v: float) -> void: Engine.time_scale = v)
	_add_slider(vb, "Blast radius (m)", 2.0, 24.0, _radius, 0.5,
		func(v: float) -> void: _radius = v)
	_add_slider(vb, "Auto-repeat (s, 0=off)", 0.0, 4.0, _repeat_interval, 0.1,
		func(v: float) -> void:
			_repeat_interval = v
			_repeat_accum = 0.0)
	_add_slider(vb, "Smoke clouds ×", 0.0, 3.0, Violence.blast_smoke_count_scale, 0.1,
		func(v: float) -> void: Violence.blast_smoke_count_scale = v)
	_add_slider(vb, "Fire clouds ×", 0.0, 3.0, Violence.blast_fire_cloud_count_scale, 0.1,
		func(v: float) -> void: Violence.blast_fire_cloud_count_scale = v)
	_add_slider(vb, "Flame shards ×", 0.0, 3.0, Violence.blast_shard_count_scale, 0.1,
		func(v: float) -> void: Violence.blast_shard_count_scale = v)
	_add_slider(vb, "Embers ×", 0.0, 3.0, Violence.blast_ember_count_scale, 0.1,
		func(v: float) -> void: Violence.blast_ember_count_scale = v)

	var sep2 := HSeparator.new()
	vb.add_child(sep2)
	var sfx_lbl := Label.new()
	sfx_lbl.text = "SFX LEVELS (dB)"
	sfx_lbl.add_theme_font_size_override("font_size", 12)
	sfx_lbl.add_theme_color_override("font_color", Color(0.7, 0.9, 1.0))
	vb.add_child(sfx_lbl)
	# Reuse the shared SFX-knob slider (binds straight to SFX.<prop>).
	AudioSettingsPanel.add_sfx_slider(vb, "Explosion bang", "explosion_bang_db", -24.0, 24.0, 130.0)
	AudioSettingsPanel.add_sfx_slider(vb, "Explosion rumble", "explosion_rumble_db", -24.0, 24.0, 130.0)
	AudioSettingsPanel.add_sfx_slider(vb, "Ion burst", "ion_cannon_burst_db", -24.0, 12.0, 130.0)
	AudioSettingsPanel.add_sfx_slider(vb, "Ion charge", "ion_cannon_charge_db", -36.0, 6.0, 130.0)

# Generic labelled slider with a live value readout, wired to `on_change`.
func _add_slider(vb: VBoxContainer, label: String, lo: float, hi: float, value: float, step: float, on_change: Callable) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	vb.add_child(row)
	var lbl := Label.new()
	lbl.text = label
	lbl.custom_minimum_size = Vector2(150, 0)
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
	val.custom_minimum_size = Vector2(46, 0)
	val.add_theme_font_size_override("font_size", 12)
	row.add_child(val)
	slider.value_changed.connect(func(v: float) -> void:
		val.text = "%.2f" % v
		on_change.call(v))
