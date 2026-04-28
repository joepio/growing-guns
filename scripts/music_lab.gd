extends Control

const SEED_MAX := 999999

const CHANNELS: Array = [
	{"label": "Lead", "mute": "_mute_lead", "solo": "_solo_lead"},
	{"label": "Answer", "mute": "_mute_answer", "solo": "_solo_answer"},
	{"label": "Bass", "mute": "_mute_bass", "solo": "_solo_bass"},
	{"label": "Pad", "mute": "_mute_pad", "solo": "_solo_pad"},
	{"label": "Kick", "mute": "_mute_kick", "solo": "_solo_kick"},
	{"label": "Snare", "mute": "_mute_snare", "solo": "_solo_snare"},
	{"label": "Hats", "mute": "_mute_hats", "solo": "_solo_hats"},
	{"label": "Perc", "mute": "_mute_perc", "solo": "_solo_perc"},
	{"label": "Glitch", "mute": "_mute_glitch", "solo": "_solo_glitch"},
]

const KNOBS: Array = [
	{"group": "Transport", "label": "Music dB", "prop": "music_db", "min": -36.0, "max": 0.0},
	{"group": "Transport", "label": "BPM", "prop": "bpm", "min": 110.0, "max": 190.0},
	{"group": "Lead", "label": "Lead drive", "prop": "_acid_drive", "min": 0.5, "max": 5.0},
	{"group": "Lead", "label": "Pre drive", "prop": "_acid_pre_drive", "min": 0.5, "max": 7.0},
	{"group": "Lead", "label": "Post drive", "prop": "_acid_post_drive", "min": 0.5, "max": 4.0},
	{"group": "Lead", "label": "Asymmetry", "prop": "_acid_asym", "min": -0.4, "max": 0.4},
	{"group": "Lead", "label": "Square mix", "prop": "_acid_square_mix", "min": 0.0, "max": 0.8},
	{"group": "Lead", "label": "Sub mix", "prop": "_acid_sub_mix", "min": 0.0, "max": 0.6},
	{"group": "Lead filter", "label": "Base cutoff", "prop": "_acid_filter_base", "min": 0.002, "max": 0.10},
	{"group": "Lead filter", "label": "Sweep", "prop": "_acid_filter_sweep", "min": 0.02, "max": 0.70},
	{"group": "Lead filter", "label": "Attack", "prop": "_acid_filter_attack", "min": 0.001, "max": 0.050},
	{"group": "Lead filter", "label": "Decay", "prop": "_acid_filter_decay", "min": 0.005, "max": 0.180},
	{"group": "Lead filter", "label": "Hold", "prop": "_acid_filter_hold", "min": 0.0, "max": 0.080},
	{"group": "Lead filter", "label": "Sustain", "prop": "_acid_filter_sustain", "min": 0.0, "max": 0.90},
	{"group": "Lead filter", "label": "Release", "prop": "_acid_filter_release", "min": 0.005, "max": 0.300},
	{"group": "Lead filter", "label": "Gate time", "prop": "_acid_gate_time", "min": 0.015, "max": 0.180},
	{"group": "Lead filter", "label": "Q", "prop": "_acid_resonance", "min": 0.0, "max": 1.2},
	{"group": "Lead filter", "label": "Long gate", "prop": "_acid_long_gate_mult", "min": 1.0, "max": 4.0},
	{"group": "Lead filter", "label": "Long decay", "prop": "_acid_long_decay_mult", "min": 1.0, "max": 5.0},
	{"group": "Lead filter", "label": "Long release", "prop": "_acid_long_release_mult", "min": 1.0, "max": 3.5},
	{"group": "Lead filter", "label": "Long Q boost", "prop": "_acid_long_q_boost", "min": 0.0, "max": 0.7},
	{"group": "Lead filter", "label": "Long sweep", "prop": "_acid_long_sweep_boost", "min": 0.0, "max": 0.8},
	{"group": "Lead filter", "label": "4th-bar lift", "prop": "_variant_filter_lift", "min": 0.0, "max": 0.35},
	{"group": "Lead filter", "label": "Stereo offset", "prop": "_acid_pan_offset", "min": 0.0, "max": 0.060},
	{"group": "Bass", "label": "Support drive", "prop": "_bass_drive", "min": 0.5, "max": 5.0},
	{"group": "Bass", "label": "Answer drive", "prop": "_answer_bass_drive", "min": 0.5, "max": 6.0},
	{"group": "Bass", "label": "Answer cutoff", "prop": "_answer_bass_cutoff", "min": 0.004, "max": 0.14},
	{"group": "Bass", "label": "Answer decay", "prop": "_answer_bass_decay", "min": 0.9992, "max": 0.99995},
	{"group": "Bass", "label": "Answer pulse", "prop": "_answer_bass_square_mix", "min": 0.0, "max": 0.9},
	{"group": "Bass", "label": "Answer level", "prop": "_answer_bass_level", "min": 0.0, "max": 1.0},
	{"group": "Bass", "label": "Formant amount", "prop": "_answer_formant_amount", "min": 0.0, "max": 1.0},
	{"group": "Bass", "label": "Formant Q", "prop": "_answer_formant_q", "min": 0.0, "max": 0.6},
	{"group": "Pad", "label": "Pad cutoff", "prop": "_pad_cutoff", "min": 0.001, "max": 0.020},
	{"group": "Pad", "label": "Pad spread", "prop": "_pad_spread", "min": 0.0, "max": 0.080},
	{"group": "Mix", "label": "Tier 3 duck", "prop": "_tier3_duck_depth", "min": 0.0, "max": 1.0},
	{"group": "Mix", "label": "Mud scoop", "prop": "_drum_mud_cut_amount", "min": 0.0, "max": 1.0},
	{"group": "Mix", "label": "Tier 2 upward", "prop": "_tier2_upward_amount", "min": 0.0, "max": 1.0},
	{"group": "Mix", "label": "Width punch", "prop": "_width_punch_amount", "min": 0.0, "max": 1.0},
	{"group": "Mix", "label": "Master sat", "prop": "_master_saturation", "min": 0.6, "max": 2.4},
	{"group": "Mix", "label": "Clip drive", "prop": "_master_clip_drive", "min": 0.8, "max": 1.8},
	{"group": "Glitch", "label": "Glitch chance", "prop": "_glitch_chance", "min": 0.0, "max": 1.0},
	{"group": "Glitch", "label": "Glitch feedback", "prop": "_glitch_feedback", "min": 0.0, "max": 0.9},
	{"group": "Drums", "label": "Kick base Hz", "prop": "_kick_base_hz", "min": 25.0, "max": 80.0},
	{"group": "Drums", "label": "Kick drop Hz", "prop": "_kick_drop_hz", "min": 40.0, "max": 200.0},
	{"group": "Drums", "label": "Snare tone Hz", "prop": "_snare_tone_hz", "min": 80.0, "max": 360.0},
	{"group": "Drums", "label": "Hat level", "prop": "_hat_level", "min": 0.0, "max": 2.0},
]

var _seed_edit: LineEdit = null
var _energy_label: Label = null
var _energy_buttons: Dictionary = {}
var _sliders: Dictionary = {}
var _toggles: Dictionary = {}
var _suppress_slider_updates := false


func _ready() -> void:
	ProceduralMusic.enabled = true
	ProceduralMusic.set_energy(2, true)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_build_ui()
	_apply_seed(1234)


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_ESCAPE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		elif event.keycode >= KEY_1 and event.keycode <= KEY_4:
			_set_energy(event.keycode - KEY_0)


func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.035, 0.035, 0.045, 1.0)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.offset_left = 18
	panel.offset_top = 18
	panel.offset_right = -18
	panel.offset_bottom = -18
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.02, 0.02, 0.025, 0.92)
	sb.border_color = Color.TRANSPARENT
	sb.set_border_width_all(0)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = 14
	sb.content_margin_bottom = 14
	panel.add_theme_stylebox_override("panel", sb)
	add_child(panel)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	panel.add_child(root)

	var title := Label.new()
	title.text = "MUSIC LAB"
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Color(1.0, 0.92, 0.55))
	root.add_child(title)

	var seed_row := HBoxContainer.new()
	seed_row.add_theme_constant_override("separation", 8)
	root.add_child(seed_row)
	seed_row.add_child(_label("Seed", 42))
	_seed_edit = LineEdit.new()
	_seed_edit.max_length = 6
	_seed_edit.custom_minimum_size = Vector2(90, 34)
	_seed_edit.text_submitted.connect(func(_t: String) -> void: _apply_seed_from_text())
	seed_row.add_child(_seed_edit)
	seed_row.add_child(_button("Apply", _apply_seed_from_text))
	seed_row.add_child(_button("Random", _random_seed))
	seed_row.add_child(_button("Regen same", _apply_seed_from_text))

	_energy_label = _label("Energy 2", 78)
	seed_row.add_child(_energy_label)
	for level in range(1, 5):
		seed_row.add_child(_energy_button(level))
	seed_row.add_child(_toggle_button("Call/response", "_call_response"))
	seed_row.add_child(_toggle_button("4th ending", "_fourth_bar_variant"))

	_add_channel_controls(root)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 18)
	grid.add_theme_constant_override("v_separation", 4)
	scroll.add_child(grid)

	var current_group := ""
	for spec in KNOBS:
		var group := str(spec.group)
		if group != current_group:
			current_group = group
			var group_label := Label.new()
			group_label.text = group.to_upper()
			group_label.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0))
			group_label.add_theme_font_size_override("font_size", 13)
			grid.add_child(group_label)
			grid.add_child(Control.new())
		_add_knob(grid, spec)


func _add_knob(parent: GridContainer, spec: Dictionary) -> void:
	var prop := str(spec.prop)
	var label := _label(str(spec.label), 150)
	parent.add_child(label)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)

	var slider := HSlider.new()
	slider.min_value = float(spec.min)
	slider.max_value = float(spec.max)
	slider.step = _step_for_range(slider.min_value, slider.max_value)
	slider.value = float(ProceduralMusic.get(prop))
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size = Vector2(220, 26)
	row.add_child(slider)

	var value_label := _label(_fmt(slider.value), 76)
	row.add_child(value_label)
	_sliders[prop] = {"slider": slider, "label": value_label}
	slider.value_changed.connect(func(v: float) -> void:
		if _suppress_slider_updates:
			return
		ProceduralMusic.set(prop, v)
		if prop == "music_db":
			ProceduralMusic.set_energy(ProceduralMusic.get_energy(), true)
		value_label.text = _fmt(v))


func _add_channel_controls(parent: VBoxContainer) -> void:
	var grid := GridContainer.new()
	grid.columns = 6
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 4)
	parent.add_child(grid)

	var label := Label.new()
	label.text = "CHANNELS"
	label.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0))
	label.add_theme_font_size_override("font_size", 13)
	grid.add_child(label)
	grid.add_child(Control.new())
	grid.add_child(Control.new())
	grid.add_child(Control.new())
	grid.add_child(Control.new())
	grid.add_child(Control.new())

	for spec in CHANNELS:
		grid.add_child(_label(str(spec.label), 58))
		grid.add_child(_channel_toggle_button("S", str(spec.solo), Color(0.2, 0.82, 0.42)))
		grid.add_child(_channel_toggle_button("M", str(spec.mute), Color(0.95, 0.33, 0.28)))


func _energy_button(level: int) -> Button:
	var btn := Button.new()
	btn.text = "E%d" % level
	btn.toggle_mode = true
	btn.focus_mode = Control.FOCUS_NONE
	btn.custom_minimum_size = Vector2(46, 34)
	btn.pressed.connect(_set_energy.bind(level))
	_energy_buttons[level] = btn
	_set_energy_button_visual(btn, level == ProceduralMusic.get_energy())
	return btn


func _toggle_button(text: String, prop: String, width: float = 142.0) -> Button:
	var btn := Button.new()
	btn.toggle_mode = true
	btn.focus_mode = Control.FOCUS_NONE
	btn.custom_minimum_size = Vector2(width, 34)
	btn.set_meta("base_text", text)
	var initial := bool(ProceduralMusic.get(prop))
	btn.button_pressed = initial
	_set_toggle_visual(btn, initial)
	btn.toggled.connect(func(on: bool) -> void:
		ProceduralMusic.set(prop, on)
		_set_toggle_visual(btn, on))
	_toggles[prop] = btn
	return btn


func _channel_toggle_button(text: String, prop: String, active_color: Color) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.toggle_mode = true
	btn.focus_mode = Control.FOCUS_NONE
	btn.custom_minimum_size = Vector2(34, 30)
	btn.set_meta("active_color", active_color)
	var initial := bool(ProceduralMusic.get(prop))
	btn.button_pressed = initial
	_set_channel_toggle_visual(btn, initial)
	btn.toggled.connect(func(on: bool) -> void:
		ProceduralMusic.set(prop, on)
		_set_channel_toggle_visual(btn, on))
	_toggles[prop] = btn
	return btn


func _set_toggle_visual(btn: Button, on: bool) -> void:
	var base_text := str(btn.get_meta("base_text", btn.text))
	btn.text = "%s: %s" % [base_text, "ON" if on else "OFF"]
	var active_color := Color(0.74, 1.0, 0.72)
	var inactive_color := Color(0.72, 0.74, 0.78)
	btn.add_theme_color_override("font_color", active_color if on else inactive_color)
	btn.add_theme_color_override("font_pressed_color", active_color)
	btn.add_theme_color_override("font_hover_color", Color.WHITE)
	_set_button_fill(btn, on, Color(0.15, 0.34, 0.18), Color(0.08, 0.08, 0.095))


func _set_channel_toggle_visual(btn: Button, on: bool) -> void:
	var active_color := btn.get_meta("active_color", Color(0.35, 0.75, 1.0)) as Color
	btn.add_theme_color_override("font_color", Color.WHITE if on else Color(0.72, 0.74, 0.78))
	btn.add_theme_color_override("font_pressed_color", Color.WHITE)
	btn.add_theme_color_override("font_hover_color", Color.WHITE)
	_set_button_fill(btn, on, active_color.darkened(0.35), Color(0.075, 0.075, 0.09))


func _set_energy_button_visual(btn: Button, on: bool) -> void:
	btn.set_pressed_no_signal(on)
	btn.add_theme_color_override("font_color", Color.WHITE if on else Color(0.72, 0.74, 0.78))
	btn.add_theme_color_override("font_pressed_color", Color.WHITE)
	btn.add_theme_color_override("font_hover_color", Color.WHITE)
	_set_button_fill(btn, on, Color(0.12, 0.36, 0.74), Color(0.075, 0.075, 0.09))


func _set_button_fill(btn: Button, active: bool, active_color: Color, inactive_color: Color) -> void:
	var normal := StyleBoxFlat.new()
	normal.bg_color = active_color if active else inactive_color
	normal.border_color = Color(0.55, 0.85, 1.0, 0.9) if active else Color(0.22, 0.24, 0.28, 1.0)
	normal.set_border_width_all(1)
	normal.set_corner_radius_all(5)
	btn.add_theme_stylebox_override("normal", normal)
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = normal.bg_color.lightened(0.12)
	btn.add_theme_stylebox_override("hover", hover)
	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = normal.bg_color.lightened(0.2)
	btn.add_theme_stylebox_override("pressed", pressed)


func _button(text: String, cb: Callable) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.focus_mode = Control.FOCUS_NONE
	btn.custom_minimum_size = Vector2(72, 34)
	btn.pressed.connect(cb)
	return btn


func _label(text: String, width: float) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.custom_minimum_size = Vector2(width, 0)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 12)
	return lbl


func _apply_seed_from_text() -> void:
	var clean := _seed_edit.text.strip_edges()
	if clean == "":
		clean = "0"
	_apply_seed(clampi(int(clean), 0, SEED_MAX))


func _random_seed() -> void:
	_apply_seed(randi_range(0, SEED_MAX))


func _apply_seed(seed: int) -> void:
	_seed_edit.text = str(seed)
	ProceduralMusic.generate_track(seed, 0)
	_refresh_sliders()
	_refresh_toggles()


func _set_energy(level: int) -> void:
	ProceduralMusic.set_energy(level, true)
	if _energy_label:
		_energy_label.text = "Energy %d" % level
	_refresh_energy_buttons(level)


func _refresh_sliders() -> void:
	_suppress_slider_updates = true
	for prop in _sliders:
		var data: Dictionary = _sliders[prop]
		var value := float(ProceduralMusic.get(str(prop)))
		(data.slider as HSlider).value = value
		(data.label as Label).text = _fmt(value)
	_suppress_slider_updates = false


func _refresh_toggles() -> void:
	for prop in _toggles:
		var btn := _toggles[prop] as Button
		var on := bool(ProceduralMusic.get(str(prop)))
		btn.set_pressed_no_signal(on)
		if btn.has_meta("active_color"):
			_set_channel_toggle_visual(btn, on)
		else:
			_set_toggle_visual(btn, on)


func _refresh_energy_buttons(active_level: int = -1) -> void:
	var level := active_level
	if level < 0:
		level = ProceduralMusic.get_energy()
	for key in _energy_buttons:
		var btn := _energy_buttons[key] as Button
		_set_energy_button_visual(btn, int(key) == level)


func _step_for_range(min_value: float, max_value: float) -> float:
	var span := max_value - min_value
	if span <= 1.0:
		return 0.001
	if span <= 10.0:
		return 0.01
	return 0.1


func _fmt(v: float) -> String:
	if absf(v) >= 100.0:
		return "%.1f" % v
	if absf(v) >= 10.0:
		return "%.2f" % v
	return "%.3f" % v
