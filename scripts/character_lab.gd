extends Node3D

class GunDragField extends PanelContainer:
	signal value_changed(value: float)

	var min_value: float = -1.0
	var max_value: float = 1.0
	var step: float = 0.01

	var _value: float = 0.0
	var _dragging := false
	var _label: Label

	func _ready() -> void:
		custom_minimum_size = Vector2(76.0, 26.0)
		mouse_filter = Control.MOUSE_FILTER_STOP
		mouse_default_cursor_shape = Control.CURSOR_VSIZE
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.14, 0.15, 0.2)
		sb.set_corner_radius_all(3)
		sb.content_margin_left = 4
		sb.content_margin_right = 4
		sb.content_margin_top = 2
		sb.content_margin_bottom = 2
		add_theme_stylebox_override("panel", sb)
		_label = Label.new()
		_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_label.add_theme_font_size_override("font_size", 11)
		add_child(_label)
		_refresh_label()

	func set_value_no_signal(v: float) -> void:
		_value = clampf(v, min_value, max_value)
		_refresh_label()

	func get_value() -> float:
		return _value

	func _set_value(v: float) -> void:
		var clamped := clampf(v, min_value, max_value)
		if is_equal_approx(clamped, _value):
			return
		_value = clamped
		_refresh_label()
		value_changed.emit(_value)

	func _refresh_label() -> void:
		if _label == null:
			return
		_label.text = ("%.3f" if step < 0.05 else "%.1f") % _value

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton:
			match event.button_index:
				MOUSE_BUTTON_LEFT:
					_dragging = event.pressed
					accept_event()
				MOUSE_BUTTON_WHEEL_UP:
					_nudge(step)
					accept_event()
				MOUSE_BUTTON_WHEEL_DOWN:
					_nudge(-step)
					accept_event()
		elif event is InputEventMouseMotion and _dragging:
			var s := step * (0.1 if Input.is_key_pressed(KEY_SHIFT) else 1.0)
			if Input.is_key_pressed(KEY_CTRL):
				_set_value(_value + event.relative.x * s)
			else:
				_set_value(_value - event.relative.y * s)
			accept_event()

	func _nudge(delta: float) -> void:
		var s := delta * (0.1 if Input.is_key_pressed(KEY_SHIFT) else 1.0)
		_set_value(_value + s)

# Character lab: preview knight animations, tune third-person gun placement, and
# apply weapon/card stats to the procedural rifle on the hand anchor.
#
# Run: godot --path . res://scenes/character_lab.tscn
#
# Controls: RMB = mouse look · WASD/QE = move cam · Shift = sprint
#   SPACE = fire · R = reload anim · P = roam (walk/look/shoot) · F1 = UI

const WALK_SPEED := 14.0
const MOVE_SPEED := 7.0
const FAST_MULT := 3.0
const MOUSE_SENS := 0.0025
const ROAM_RADIUS := 5.0
const CAM_DISTANCE := 4.5
const CAM_MIN_DISTANCE := 2.2
const CAM_MAX_DISTANCE := 12.0
const CAM_ZOOM_SENS := 0.35
const CAM_ORBIT_SPEED := 1.4

var state: int = 1
var local_player: Node = null

@onready var _actor: Node3D = $Actor
@onready var _character: CharacterVisual = $Actor/CharacterVisual

var _camera: Camera3D
var _yaw: float = PI
var _pitch: float = 0.12
var _cam_distance := CAM_DISTANCE
var _panel: PanelContainer
var _stats_label: Label
var _help_label: Label
var _clip_buttons: Array[Button] = []
var _loco_slider: HSlider
var _loco_value_label: Label
var _roam_btn: Button

var _weapon := Weapon.new()
var _procedural_gun: Node3D
var _gun_mount_root: Node3D
var _gun_ready := false

var _manual_loco := true
var _loco_blend := 0.0
var _active_clip := &"pistol_idle"
var _roam := false

var _actor_yaw := 0.0
var _actor_target_yaw := 0.0
var _look_pitch := 0.0
var _look_pitch_target := 0.0
var _roam_speed := 0.0
var _roam_dest := Vector3.ZERO
var _roam_idle_timer := 0.0
var _shoot_cd := 0.0
var _mag := 12
var _reloading := false
var _reload_timer := 0.0
var _rifle_cd := 0.0

var _gun_pos := CharacterVisual.WEAPON_MOUNT_POSITION
var _gun_rot := CharacterVisual.WEAPON_MOUNT_ROTATION_DEGREES
var _gun_pos_fields: Array[GunDragField] = []
var _gun_rot_fields: Array[GunDragField] = []
var _mount_label: Label


func _ready() -> void:
	_build_camera()
	_build_ui()
	_roam_dest = _actor.global_position
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _mouse_over_ui() -> bool:
	if _panel == null or not _panel.visible:
		return false
	return _panel.get_global_rect().has_point(get_viewport().get_mouse_position())


func _build_camera() -> void:
	_camera = $Camera3D
	_camera.make_current()
	_update_camera_orbit()


func _setup_gun() -> void:
	if _gun_ready or _character == null or not _character.is_active():
		return
	_procedural_gun = preload("res://scripts/procedural_gun.gd").new()
	_procedural_gun.name = "ProceduralGun"
	_gun_mount_root = _character.mount_third_person_weapon(_procedural_gun)
	if _gun_mount_root == null:
		_procedural_gun = null
		return
	_apply_gun_transform()
	_refresh_weapon_visual()
	_gun_ready = true
	if _character.has_method("scan_animation_dir"):
		_character.scan_animation_dir()
	_rebuild_clip_buttons()


func _apply_gun_transform() -> void:
	if _procedural_gun == null:
		return
	_procedural_gun.position = _gun_pos
	_procedural_gun.rotation_degrees = _gun_rot
	_update_mount_label()


func _refresh_weapon_visual() -> void:
	if _procedural_gun and _procedural_gun.has_method("apply_weapon_stats"):
		_procedural_gun.apply_weapon_stats(_weapon)
	_mag = _weapon.get_mag_size()
	_apply_gun_transform()
	_refresh_stats()


func _input(event: InputEvent) -> void:
	if _mouse_over_ui():
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		Input.mouse_mode = (
			Input.MOUSE_MODE_VISIBLE
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
			else Input.MOUSE_MODE_CAPTURED
		)
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * MOUSE_SENS
		_pitch = clampf(_pitch - event.relative.y * MOUSE_SENS, -0.35, 1.1)
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_cam_distance = maxf(CAM_MIN_DISTANCE, _cam_distance - CAM_ZOOM_SENS)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_cam_distance = minf(CAM_MAX_DISTANCE, _cam_distance + CAM_ZOOM_SENS)
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_ESCAPE:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			KEY_F1:
				if _panel:
					_panel.visible = not _panel.visible
			KEY_SPACE:
				if not _roam:
					_fire_once()
			KEY_J:
				if _character.is_active():
					_character.play_jump()
			KEY_R:
				_start_reload()
			KEY_P:
				_set_roam(not _roam)


func _process(delta: float) -> void:
	if not _camera.current:
		_camera.make_current()
	_setup_gun()
	if _roam:
		_roam_tick(delta)
	else:
		_apply_manual_animation()
	_tick_weapon_timers(delta)
	_update_camera_orbit()
	_orbit_camera_input(delta)
	_update_help()


func _get_cam_pivot() -> Vector3:
	if _character != null and _character.is_active():
		return _character.get_camera_pivot()
	return _actor.global_position + Vector3(0.0, 1.0, 0.0)


func _update_camera_orbit() -> void:
	if _camera == null:
		return
	var pivot := _get_cam_pivot()
	var cp := cos(_pitch)
	var offset := Vector3(sin(_yaw) * cp, sin(_pitch), cos(_yaw) * cp) * _cam_distance
	_camera.global_position = pivot + offset
	_camera.look_at(pivot, Vector3.UP)


func _orbit_camera_input(delta: float) -> void:
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	if Input.is_key_pressed(KEY_A):
		_yaw -= CAM_ORBIT_SPEED * delta
	if Input.is_key_pressed(KEY_D):
		_yaw += CAM_ORBIT_SPEED * delta
	if Input.is_key_pressed(KEY_W):
		_cam_distance = maxf(CAM_MIN_DISTANCE, _cam_distance - MOVE_SPEED * delta)
	if Input.is_key_pressed(KEY_S):
		_cam_distance = minf(CAM_MAX_DISTANCE, _cam_distance + MOVE_SPEED * delta)


func _apply_manual_animation() -> void:
	if not _character.is_active():
		return
	if _manual_loco:
		_character.use_locomotion_tree()
		_character.set_locomotion_blend(_loco_blend)
	else:
		_character.play_clip(_active_clip)


func _roam_tick(delta: float) -> void:
	if not _character.is_active():
		return

	_roam_idle_timer -= delta
	if _roam_idle_timer <= 0.0:
		_roam_idle_timer = randf_range(0.6, 2.2)
		if randf() < 0.55:
			var ang := randf() * TAU
			_roam_dest = Vector3(cos(ang), 0.0, sin(ang)) * randf_range(1.0, ROAM_RADIUS)
		else:
			_roam_dest = Vector3.ZERO
		_actor_target_yaw = randf_range(-PI, PI)
		_look_pitch_target = deg_to_rad(randf_range(-18.0, 22.0))
		_roam_speed = randf_range(0.0, 1.0) * WALK_SPEED * _weapon.move_speed_mult

	var to_dest := _roam_dest - _actor.position
	to_dest.y = 0.0
	if to_dest.length() > 0.15 and _roam_speed > 0.1:
		_actor_target_yaw = atan2(-to_dest.x, -to_dest.z)

	_actor_yaw = lerp_angle(_actor_yaw, _actor_target_yaw, clampf(delta * 4.0, 0.0, 1.0))
	_look_pitch = lerp_angle(_look_pitch, _look_pitch_target, clampf(delta * 3.0, 0.0, 1.0))
	_actor.rotation.y = _actor_yaw
	_character.rotation.x = _look_pitch

	var planar_speed := 0.0
	if to_dest.length() > 0.2 and _roam_speed > 0.1:
		var step := minf(_roam_speed * delta, to_dest.length())
		_actor.position += to_dest.normalized() * step
		planar_speed = _roam_speed
	_character.use_locomotion_tree()
	_character.set_locomotion_blend(clampf(planar_speed / WALK_SPEED, 0.0, 1.0))

	if _loco_slider:
		_loco_blend = _character.is_active() and planar_speed / WALK_SPEED or 0.0
		_loco_slider.value = clampf(_loco_blend, 0.0, 1.0)
		_loco_value_label.text = "%.0f%% run" % (_loco_slider.value * 100.0)

	_shoot_cd -= delta
	if _shoot_cd <= 0.0 and _rifle_cd <= 0.0 and _mag > 0 and not _reloading:
		if randf() < 0.035:
			_fire_once()
			_shoot_cd = randf_range(0.25, 1.1)


func _tick_weapon_timers(delta: float) -> void:
	_rifle_cd = maxf(0.0, _rifle_cd - delta)
	if _reloading:
		_reload_timer -= delta
		if _reload_timer <= 0.0:
			_reloading = false
			_mag = _weapon.get_mag_size()
	_refresh_stats()


func _fire_once() -> void:
	if not _gun_ready or _procedural_gun == null:
		return
	if _reloading or _rifle_cd > 0.0 or _mag <= 0:
		return
	_rifle_cd = _weapon.get_fire_interval()
	_mag -= 1
	if _procedural_gun.has_method("cycle_bolt"):
		_procedural_gun.cycle_bolt(_weapon.get_fire_interval())
	if _procedural_gun.has_method("add_heat"):
		_procedural_gun.add_heat(_weapon.damage_mult)
	var muzzle: Vector3 = _procedural_gun.global_transform * _procedural_gun.get_muzzle_exit_local()
	SFX.shot(_weapon, muzzle, false)
	if _mag <= 0:
		_start_reload()


func _start_reload() -> void:
	if _reloading:
		return
	_reloading = true
	_reload_timer = _weapon.get_reload_time()


func _set_roam(on: bool) -> void:
	_roam = on
	if _roam_btn:
		_roam_btn.text = "Roam: ON" if _roam else "Roam: OFF"
		_roam_btn.modulate = Color(0.6, 1.0, 0.65) if _roam else Color.WHITE
	if not _roam:
		_actor.rotation.y = 0.0
		_character.rotation.x = 0.0
		_roam_dest = Vector3.ZERO
		_actor.position = Vector3.ZERO


func _set_manual_loco(on: bool) -> void:
	_manual_loco = on
	if _character.is_active():
		if on:
			_character.use_locomotion_tree()
		else:
			_character.play_clip(_active_clip)


func _select_clip(clip: String) -> void:
	_active_clip = clip
	_manual_loco = false
	if _character.is_active():
		_character.play_clip(clip)


func _on_loco_slider(value: float) -> void:
	_loco_blend = value
	_manual_loco = true
	if _loco_value_label:
		_loco_value_label.text = "%.0f%% run" % (value * 100.0)


func _apply_card(card_id: String) -> void:
	var card: Dictionary = CardLibrary.by_id(card_id)
	if card.is_empty():
		return
	var apply_fn: Callable = card.get("apply")
	if apply_fn.is_valid():
		apply_fn.call(_weapon)
	_refresh_weapon_visual()


func _reset_weapon() -> void:
	_weapon = Weapon.new()
	_refresh_weapon_visual()


func _reset_gun_mount() -> void:
	_gun_pos = CharacterVisual.WEAPON_MOUNT_POSITION
	_gun_rot = CharacterVisual.WEAPON_MOUNT_ROTATION_DEGREES
	_sync_gun_spinboxes()
	_apply_gun_transform()


func _copy_gun_mount() -> void:
	var txt := (
		"WEAPON_MOUNT_POSITION = Vector3(%.4f, %.4f, %.4f)\n"
		+ "WEAPON_MOUNT_ROTATION_DEGREES = Vector3(%.2f, %.2f, %.2f)"
	) % [_gun_pos.x, _gun_pos.y, _gun_pos.z, _gun_rot.x, _gun_rot.y, _gun_rot.z]
	DisplayServer.clipboard_set(txt)
	if _mount_label:
		_mount_label.text = "Copied: " + txt.replace("\n", "  ")


func _sync_gun_spinboxes() -> void:
	for axis: int in 3:
		if _gun_pos_fields.size() > axis:
			_gun_pos_fields[axis].set_value_no_signal(_gun_pos[axis])
		if _gun_rot_fields.size() > axis:
			_gun_rot_fields[axis].set_value_no_signal(_gun_rot[axis])


func _update_mount_label() -> void:
	if _mount_label == null:
		return
	_mount_label.text = (
		"pos (%.3f, %.3f, %.3f)  rot (%.1f, %.1f, %.1f)"
		% [_gun_pos.x, _gun_pos.y, _gun_pos.z, _gun_rot.x, _gun_rot.y, _gun_rot.z]
	)


# -------------------- UI --------------------

func _build_ui() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)

	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_panel.position = Vector2(10.0, 10.0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.82)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	_panel.add_theme_stylebox_override("panel", sb)
	canvas.add_child(_panel)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 8)
	_panel.add_child(outer)

	_help_label = Label.new()
	_help_label.text = "CHARACTER LAB"
	_help_label.add_theme_font_size_override("font_size", 12)
	_help_label.add_theme_color_override("font_color", Color(1, 0.95, 0.6))
	outer.add_child(_help_label)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	outer.add_child(row)
	_roam_btn = Button.new()
	_roam_btn.text = "Roam: OFF"
	_roam_btn.focus_mode = Control.FOCUS_NONE
	_roam_btn.pressed.connect(func() -> void: _set_roam(not _roam))
	row.add_child(_roam_btn)
	var fire_btn := Button.new()
	fire_btn.text = "Fire"
	fire_btn.focus_mode = Control.FOCUS_NONE
	fire_btn.pressed.connect(_fire_once)
	row.add_child(fire_btn)
	var reset_btn := Button.new()
	reset_btn.text = "Reset cards"
	reset_btn.focus_mode = Control.FOCUS_NONE
	reset_btn.pressed.connect(_reset_weapon)
	row.add_child(reset_btn)

	outer.add_child(_section_label("Animations"))
	var clip_row := HBoxContainer.new()
	clip_row.add_theme_constant_override("separation", 4)
	outer.add_child(clip_row)
	# Buttons rebuilt once gun/character ready; seed with defaults.
	for clip_name: String in ["pistol_idle", "pistol_run", "pistol_jump"]:
		clip_row.add_child(_make_clip_button(clip_name))

	var loco_row := HBoxContainer.new()
	loco_row.add_theme_constant_override("separation", 8)
	outer.add_child(loco_row)
	var loco_lbl := Label.new()
	loco_lbl.text = "Loco blend"
	loco_lbl.custom_minimum_size = Vector2(80.0, 0.0)
	loco_row.add_child(loco_lbl)
	_loco_slider = HSlider.new()
	_loco_slider.min_value = 0.0
	_loco_slider.max_value = 1.0
	_loco_slider.step = 0.01
	_loco_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_loco_slider.custom_minimum_size = Vector2(180.0, 0.0)
	_loco_slider.value_changed.connect(_on_loco_slider)
	loco_row.add_child(_loco_slider)
	_loco_value_label = Label.new()
	_loco_value_label.text = "0% run"
	_loco_value_label.custom_minimum_size = Vector2(56.0, 0.0)
	loco_row.add_child(_loco_value_label)

	outer.add_child(_section_label("Gun on hand (drag field / wheel; Shift=fine, Ctrl=horizontal)"))
	var mount_row := HBoxContainer.new()
	mount_row.add_theme_constant_override("separation", 6)
	outer.add_child(mount_row)
	var reset_mount_btn := Button.new()
	reset_mount_btn.text = "Reset mount"
	reset_mount_btn.focus_mode = Control.FOCUS_NONE
	reset_mount_btn.pressed.connect(_reset_gun_mount)
	mount_row.add_child(reset_mount_btn)
	var copy_mount_btn := Button.new()
	copy_mount_btn.text = "Copy values"
	copy_mount_btn.focus_mode = Control.FOCUS_NONE
	copy_mount_btn.pressed.connect(_copy_gun_mount)
	mount_row.add_child(copy_mount_btn)
	_mount_label = Label.new()
	_mount_label.add_theme_font_size_override("font_size", 10)
	_mount_label.add_theme_color_override("font_color", Color(0.7, 0.85, 0.7))
	_mount_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_mount_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mount_row.add_child(_mount_label)
	_add_gun_vec_row(outer, "Pos", _gun_pos_fields, _set_gun_pos_component, -2.0, 2.0, 0.005)
	_add_gun_vec_row(outer, "Rot°", _gun_rot_fields, _set_gun_rot_component, -360.0, 360.0, 0.5)
	_update_mount_label()

	outer.add_child(_section_label("Weapon cards"))
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(380.0, 280.0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	outer.add_child(scroll)
	var cards_vb := VBoxContainer.new()
	cards_vb.add_theme_constant_override("separation", 2)
	cards_vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(cards_vb)
	var sorted_cards: Array = CardLibrary.all().duplicate()
	sorted_cards.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ra: int = 0 if str(a.get("rarity", "common")) == "rare" else 1
		var rb: int = 0 if str(b.get("rarity", "common")) == "rare" else 1
		if ra != rb:
			return ra < rb
		return str(a.get("name", "")) < str(b.get("name", "")))
	for card: Dictionary in sorted_cards:
		_add_card_row(cards_vb, card)

	_stats_label = Label.new()
	_stats_label.add_theme_font_size_override("font_size", 11)
	_stats_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	_stats_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_stats_label.custom_minimum_size = Vector2(380.0, 0.0)
	outer.add_child(_stats_label)
	_refresh_stats()


func _section_label(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_color", Color(0.75, 0.82, 1.0))
	return lbl


func _make_clip_button(clip_name: String) -> Button:
	var btn := Button.new()
	btn.text = clip_name
	btn.focus_mode = Control.FOCUS_NONE
	btn.pressed.connect(_select_clip.bind(clip_name))
	_clip_buttons.append(btn)
	return btn


func _rebuild_clip_buttons() -> void:
	if _character == null or not _character.is_active():
		return
	var clips := _character.get_clip_names()
	if clips.is_empty():
		return
	# Append any discovered clips not already in UI.
	var existing: Dictionary = {}
	for btn: Button in _clip_buttons:
		existing[btn.text] = true
	var parent: Node = _clip_buttons[0].get_parent() if _clip_buttons.size() > 0 else null
	if parent == null:
		return
	for clip_name: String in clips:
		if existing.has(clip_name):
			continue
		parent.add_child(_make_clip_button(clip_name))


func _add_card_row(vb: VBoxContainer, card: Dictionary) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	vb.add_child(row)
	var btn := Button.new()
	btn.text = "+"
	btn.custom_minimum_size = Vector2(28.0, 0.0)
	btn.focus_mode = Control.FOCUS_NONE
	btn.pressed.connect(_apply_card.bind(str(card.get("id", ""))))
	row.add_child(btn)
	var name_lbl := Label.new()
	name_lbl.text = str(card.get("name", "?"))
	var rare := str(card.get("rarity", "common")) == "rare"
	name_lbl.add_theme_color_override("font_color", Color(1, 0.7, 1) if rare else Color(0.9, 0.9, 0.9))
	name_lbl.add_theme_font_size_override("font_size", 12)
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_lbl)


func _set_gun_pos_component(axis: int, value: float) -> void:
	if axis < 0 or axis > 2:
		return
	_gun_pos[axis] = value
	_apply_gun_transform()


func _set_gun_rot_component(axis: int, value: float) -> void:
	if axis < 0 or axis > 2:
		return
	_gun_rot[axis] = value
	_apply_gun_transform()


func _add_gun_vec_row(
	parent: VBoxContainer,
	label: String,
	out_fields: Array[GunDragField],
	set_component: Callable,
	min_v: float,
	max_v: float,
	step: float,
) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	parent.add_child(row)
	var lbl := Label.new()
	lbl.text = label
	lbl.custom_minimum_size = Vector2(36.0, 0.0)
	lbl.add_theme_font_size_override("font_size", 11)
	row.add_child(lbl)
	var axes := ["X", "Y", "Z"]
	var vec: Vector3 = _gun_pos if label == "Pos" else _gun_rot
	for axis: int in 3:
		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", 0)
		row.add_child(col)
		var axis_lbl := Label.new()
		axis_lbl.text = axes[axis]
		axis_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		axis_lbl.add_theme_font_size_override("font_size", 9)
		axis_lbl.add_theme_color_override("font_color", Color(0.65, 0.65, 0.65))
		col.add_child(axis_lbl)
		var field := GunDragField.new()
		field.min_value = min_v
		field.max_value = max_v
		field.step = step
		field.set_value_no_signal(vec[axis])
		var axis_copy := axis
		field.value_changed.connect(func(v: float) -> void: set_component.call(axis_copy, v))
		col.add_child(field)
		out_fields.append(field)


func _refresh_stats() -> void:
	if _stats_label == null:
		return
	var clip_text := "…"
	if _character and _character.is_active():
		clip_text = String(", ").join(_character.get_clip_names())
	var w := _weapon
	var barrel_len := 0.0
	if _procedural_gun != null and _procedural_gun.get("barrel_length") != null:
		barrel_len = float(_procedural_gun.get("barrel_length"))
	_stats_label.text = (
		"clips: %s\n"
		% clip_text
		+ "dmg ×%.2f  fire %.3fs  mag %d/%d  reload %.2fs  spread %.2f°  bullet ×%.2f\n"
		% [
			float(w.get_damage()) / Weapon.BASE_DAMAGE,
			float(w.get_fire_interval()),
			int(_mag),
			int(w.get_mag_size()),
			float(w.get_reload_time()),
			float(rad_to_deg(w.spread)),
			float(w.bullet_scale),
		]
		+ "barrel ~%.2fm  shots/trigger %d  explosive r=%.1f"
		% [barrel_len, int(w.get_shots_per_trigger()), float(w.explosive_radius)]
	)


func _update_help() -> void:
	if _help_label == null:
		return
	var mode := "ROAM" if _roam else "MANUAL"
	_help_label.text = (
		"CHARACTER LAB — [%s]  F1 UI  ·  P roam  ·  SPACE fire  ·  R reload\n"
		+ "RMB orbit  ·  wheel zoom  ·  WASD orbit/zoom  ·  drag gun fields  ·  J jump"
	) % mode
