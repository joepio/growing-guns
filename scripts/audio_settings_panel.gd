class_name AudioSettingsPanel extends CanvasLayer

# Live audio-tuning panel — same sliders as the audio lab but instantiable
# from any scene. Toggle with F2. When open, mouse_mode goes VISIBLE so the
# sliders are clickable; on close, mode is restored.

const KNOBS: Array = [
	["shot self dB",          "shot_self_db",          -40.0,  18.0],
	["shot world dB",         "shot_world_db",         -30.0,  24.0],
	["shot dmg / doubling",   "shot_dmg_per_double_db", 0.0,   18.0],
	["shot pitch / doubling", "shot_pitch_per_double",  0.0,    0.6],
	["explosion bang dB",     "explosion_bang_db",     -10.0,  24.0],
	["explosion rumble dB",   "explosion_rumble_db",   -10.0,  24.0],
	["footstep dB",           "footstep_db",           -50.0, -10.0],
	["jump dB",               "jump_db",               -30.0,   6.0],
	["landing max dB",        "landing_max_db",        -10.0,  18.0],
	["hurt SELF dB",          "hurt_self_db",          -50.0,   0.0],
	["hurt world dB",         "hurt_world_db",         -40.0,   6.0],
	["death SELF dB",         "death_self_db",         -50.0,   0.0],
	["death world dB",        "death_world_db",        -40.0,   6.0],
	["hit_received dB",       "hit_received_db",       -40.0,   6.0],
	["bullet zip CLOSE dB",   "bullet_zip_close_db",   -50.0,   0.0],
	["bullet zip FAR dB",     "bullet_zip_far_db",     -60.0, -10.0],
	["bullet zip base Hz",    "bullet_zip_base_hz",    200.0, 5000.0],
	["bullet zip speed Hz",   "bullet_zip_speed_hz",     0.0, 3000.0],
	["shot wet send dB",      "shot_wet_db",           -40.0,   6.0],
	["shot rumble dB",        "shot_rumble_db",        -40.0,   6.0],
	["explosion wet dB",      "explosion_wet_db",      -40.0,   6.0],
	["big-tail send dB",      "big_tail_send_db",      -60.0,   0.0],
	["big-tail min dB (calm)","big_tail_min_db",       -80.0, -10.0],
	["big-tail max dB (peak)","big_tail_max_db",       -40.0,   6.0],
	["unit_size (m)",         "unit_size",               1.0,  40.0],
]

const SOLO_CHOICES: Array = [
	["All sounds",     ""],
	["shot",           "shot"],
	["explosion",      "explosion"],
	["footstep",       "footstep"],
	["jump",           "jump"],
	["landing",        "landing"],
	["dash",           "dash"],
	["hurt",           "hurt"],
	["death",          "death"],
	["hit_received",   "hit_received"],
	["hitmarker",      "hitmarker"],
	["bullet_zip",     "bullet_zip"],
	["grenade_launch", "grenade_launch"],
	["melee",          "melee"],
	["card_flip",      "card_flip"],
	["reload",         "reload"],
	["next_round",     "next_round"],
	["empty_chamber",  "empty_chamber"],
]

# Mouse mode applied while the panel is open. Default HIDDEN matches game.gd —
# its in-shader / fisheye HUD draws its own cursor, and HIDDEN keeps the OS
# cursor from rendering on top. Hosts without a custom cursor (e.g. the audio
# labs) should set this to MOUSE_MODE_VISIBLE before the panel opens.
@export var open_mouse_mode: int = Input.MOUSE_MODE_HIDDEN
var _saved_mouse_mode: int = Input.MOUSE_MODE_VISIBLE
var _peak_bar: ProgressBar = null
var _peak_label: Label = null
var _hdr_bar: ProgressBar = null
var _hdr_label: Label = null
# Decaying peak (dB) so the meter doesn't strobe — fast attack, slow release.
var _displayed_peak_db: float = -60.0

func _ready() -> void:
	layer = 60  # above HUD (default 1) and explosion flash (50)
	visible = false
	_build_ui()
	set_process(true)

func _process(delta: float) -> void:
	if not visible or _peak_bar == null:
		return
	var master_idx := AudioServer.get_bus_index("Master")
	if master_idx < 0:
		return
	var l := AudioServer.get_bus_peak_volume_left_db(master_idx, 0)
	var r := AudioServer.get_bus_peak_volume_right_db(master_idx, 0)
	var peak: float = maxf(l, r)
	# Fast attack (instant), slow release so the bar holds long enough to read.
	if peak > _displayed_peak_db:
		_displayed_peak_db = peak
	else:
		_displayed_peak_db = move_toward(_displayed_peak_db, peak, delta * 30.0)
	_peak_bar.value = clampf(_displayed_peak_db, -60.0, 6.0)
	_peak_label.text = "%+.1f dB" % _displayed_peak_db
	# HDR window meter: shows current rolling max SPL. Anything below
	# (max - HDR_WINDOW_DB) is being culled. Range 60-180 dB SPL.
	if _hdr_bar:
		_hdr_bar.value = SFX._hdr_max_spl
		_hdr_label.text = "%.0f / cull < %.0f" % [SFX._hdr_max_spl, SFX._hdr_max_spl - SFX.HDR_WINDOW_DB]

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_F2:
		toggle()
		get_viewport().set_input_as_handled()

func toggle() -> void:
	visible = not visible
	if visible:
		_saved_mouse_mode = Input.mouse_mode
		Input.mouse_mode = open_mouse_mode
	else:
		Input.mouse_mode = _saved_mouse_mode

func _build_ui() -> void:
	# Centered, full-height-with-margin panel so the slider list always has
	# room to scroll regardless of viewport size.
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.78)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	panel.add_theme_stylebox_override("panel", sb)
	add_child(panel)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 4)
	panel.add_child(outer)

	var title := Label.new()
	title.text = "AUDIO SETTINGS — F2 to toggle"
	title.add_theme_font_size_override("font_size", 14)
	title.add_theme_color_override("font_color", Color(1, 0.95, 0.6))
	outer.add_child(title)

	# Scroll viewport — fills the rest of the panel; the inner VBox can be
	# arbitrarily tall and the scrollbar lets the user reach every knob.
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	outer.add_child(scroll)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vb)

	_build_meter_row(vb)
	_build_hdr_row(vb)
	_build_compressor_toggles(vb)
	# Spacer between diagnostics and the slider list.
	var sep := Control.new()
	sep.custom_minimum_size = Vector2(0, 6)
	vb.add_child(sep)

	for k in KNOBS:
		_add_slider(vb, k[0], k[1], k[2], k[3])

	var solo_row := HBoxContainer.new()
	solo_row.add_theme_constant_override("separation", 8)
	vb.add_child(solo_row)
	var solo_lbl := Label.new()
	solo_lbl.text = "Solo:"
	solo_lbl.custom_minimum_size = Vector2(48, 0)
	solo_lbl.add_theme_font_size_override("font_size", 12)
	solo_row.add_child(solo_lbl)
	var solo_opt := OptionButton.new()
	solo_opt.focus_mode = Control.FOCUS_NONE
	for i in SOLO_CHOICES.size():
		solo_opt.add_item(SOLO_CHOICES[i][0], i)
	solo_opt.selected = 0
	solo_opt.item_selected.connect(func(idx: int) -> void:
		SFX.solo_kind = SOLO_CHOICES[idx][1])
	solo_row.add_child(solo_opt)

	# Re-center on viewport size changes (window resize, fullscreen toggle).
	_resize_panel(panel)
	get_tree().root.size_changed.connect(_resize_panel.bind(panel))

func _resize_panel(panel: PanelContainer) -> void:
	var vp_size: Vector2 = get_viewport().get_visible_rect().size
	var w: float = clampf(vp_size.x * 0.45, 380.0, 520.0)
	var h: float = clampf(vp_size.y - 80.0, 280.0, vp_size.y - 40.0)
	panel.size = Vector2(w, h)
	panel.position = (vp_size - panel.size) * 0.5

func _build_meter_row(vb: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var lbl := Label.new()
	lbl.text = "Master peak"
	lbl.custom_minimum_size = Vector2(170, 0)
	lbl.add_theme_font_size_override("font_size", 12)
	row.add_child(lbl)
	_peak_bar = ProgressBar.new()
	_peak_bar.min_value = -60.0
	_peak_bar.max_value = 6.0
	_peak_bar.value = -60.0
	_peak_bar.show_percentage = false
	_peak_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_peak_bar.custom_minimum_size = Vector2(150, 18)
	row.add_child(_peak_bar)
	_peak_label = Label.new()
	_peak_label.text = "—"
	_peak_label.custom_minimum_size = Vector2(60, 0)
	_peak_label.add_theme_font_size_override("font_size", 12)
	row.add_child(_peak_label)
	vb.add_child(row)

func _build_hdr_row(vb: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var lbl := Label.new()
	lbl.text = "HDR window (SPL)"
	lbl.custom_minimum_size = Vector2(170, 0)
	lbl.add_theme_font_size_override("font_size", 12)
	row.add_child(lbl)
	_hdr_bar = ProgressBar.new()
	_hdr_bar.min_value = 60.0
	_hdr_bar.max_value = 180.0
	_hdr_bar.value = 60.0
	_hdr_bar.show_percentage = false
	_hdr_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hdr_bar.custom_minimum_size = Vector2(150, 18)
	row.add_child(_hdr_bar)
	_hdr_label = Label.new()
	_hdr_label.text = "—"
	_hdr_label.custom_minimum_size = Vector2(110, 0)
	_hdr_label.add_theme_font_size_override("font_size", 12)
	row.add_child(_hdr_label)
	var toggle := Button.new()
	toggle.toggle_mode = true
	toggle.focus_mode = Control.FOCUS_NONE
	toggle.text = "HDR"
	toggle.add_theme_font_size_override("font_size", 11)
	toggle.button_pressed = SFX.hdr_enabled
	toggle.toggled.connect(func(on: bool) -> void:
		SFX.hdr_enabled = on)
	row.add_child(toggle)
	vb.add_child(row)

# Toggle buttons for each compressor on Master so you can A/B the chain. Bus
# effect indices: 0 = transient comp, 1 = slow comp, 2 = limiter (don't toggle
# the limiter — it's the last-line clip protector).
func _build_compressor_toggles(vb: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var lbl := Label.new()
	lbl.text = "Compressors"
	lbl.custom_minimum_size = Vector2(170, 0)
	lbl.add_theme_font_size_override("font_size", 12)
	row.add_child(lbl)
	row.add_child(_make_comp_toggle("Transient (fast)", 0))
	row.add_child(_make_comp_toggle("Loudness (slow)", 1))
	vb.add_child(row)

func _make_comp_toggle(label_text: String, effect_idx: int) -> Button:
	var master_idx := AudioServer.get_bus_index("Master")
	var btn := Button.new()
	btn.toggle_mode = true
	btn.focus_mode = Control.FOCUS_NONE
	btn.text = label_text
	btn.add_theme_font_size_override("font_size", 11)
	btn.button_pressed = AudioServer.is_bus_effect_enabled(master_idx, effect_idx) if master_idx >= 0 else true
	btn.toggled.connect(func(on: bool) -> void:
		var idx := AudioServer.get_bus_index("Master")
		if idx >= 0:
			AudioServer.set_bus_effect_enabled(idx, effect_idx, on))
	return btn

func _add_slider(vb: VBoxContainer, label_text: String, prop: String, lo: float, hi: float) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var lbl := Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size = Vector2(170, 0)
	lbl.add_theme_font_size_override("font_size", 12)
	row.add_child(lbl)
	var initial: float = float(SFX.get(prop))
	var slider := HSlider.new()
	slider.min_value = lo
	slider.max_value = hi
	slider.step = maxf((hi - lo) / 200.0, 0.001)
	slider.value = initial
	slider.custom_minimum_size = Vector2(150, 18)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(slider)
	var val_lbl := Label.new()
	val_lbl.text = "%+.1f" % slider.value
	val_lbl.custom_minimum_size = Vector2(40, 0)
	val_lbl.add_theme_font_size_override("font_size", 12)
	row.add_child(val_lbl)
	var reset_btn := Button.new()
	reset_btn.text = "↺"
	reset_btn.tooltip_text = "Reset to game value (%.2f)" % initial
	reset_btn.focus_mode = Control.FOCUS_NONE
	reset_btn.custom_minimum_size = Vector2(22, 18)
	reset_btn.add_theme_font_size_override("font_size", 12)
	reset_btn.visible = false
	reset_btn.pressed.connect(func() -> void:
		slider.value = initial)
	row.add_child(reset_btn)
	slider.value_changed.connect(func(v: float) -> void:
		SFX.set(prop, v)
		val_lbl.text = "%+.1f" % v
		reset_btn.visible = not is_equal_approx(v, initial))
	vb.add_child(row)
