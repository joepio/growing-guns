class_name RenderPlayer
extends SubViewportContainer

signal card_selected(player_id: int, card_id: String)

const CROSSHAIR_SCRIPT := preload("res://scripts/crosshair.gd")
const HIT_MARKER_SCRIPT := preload("res://scripts/hit_marker.gd")
const DAMAGE_INDICATOR_SCRIPT := preload("res://scripts/damage_indicator.gd")
const PLAYER_VISUAL_LAYER_BASE := 8

var game: Node = null
var player_id: int = 0
var input_device: int = -1

var viewport: SubViewport = null
var camera: Camera3D = null
var _hud: Dictionary = {}
var _card_ids: Array = []
var _card_selected_index: int = 0
var _card_pick_locked: bool = false


func setup(game_node: Node, id: int, device: int = -1) -> void:
	game = game_node
	player_id = id
	input_device = device
	stretch = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if viewport == null:
		_build()


func _process(_delta: float) -> void:
	var player := _player()
	if player == null:
		return
	_apply_owner_cull(player)
	var source := player.get_node_or_null("Camera") as Camera3D
	if source:
		camera.global_transform = source.global_transform
		camera.fov = source.fov
	_update_hud(player)


func handle_input(event: InputEvent) -> bool:
	if not is_card_pick_visible():
		return false
	if _card_pick_locked:
		return true
	if input_device >= 0:
		if not (event is InputEventJoypadButton) or not event.pressed or event.device != input_device:
			return false
		match event.button_index:
			JOY_BUTTON_DPAD_LEFT:
				_select_card(_card_selected_index - 1)
				return true
			JOY_BUTTON_DPAD_RIGHT:
				_select_card(_card_selected_index + 1)
				return true
			JOY_BUTTON_A, JOY_BUTTON_X:
				_emit_selected_card()
				return true
		return true
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_A, KEY_LEFT:
				_select_card(_card_selected_index - 1)
				return true
			KEY_D, KEY_RIGHT:
				_select_card(_card_selected_index + 1)
				return true
			KEY_SPACE, KEY_ENTER, KEY_KP_ENTER:
				_emit_selected_card()
				return true
	return false


func show_card_pick(card_ids: Array) -> void:
	_card_ids = card_ids.duplicate()
	_card_selected_index = 0
	_card_pick_locked = true
	var row: HBoxContainer = _hud.card_row
	for child in row.get_children():
		child.queue_free()
	var index := 0
	for raw_id in _card_ids:
		var card := CardLibrary.by_id(str(raw_id))
		if card.is_empty():
			continue
		row.add_child(_make_card(str(raw_id), card, index))
		index += 1
	_hud.card_overlay.visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	await get_tree().create_timer(0.75).timeout
	if is_card_pick_visible():
		_card_pick_locked = false
		_select_card(0)


func hide_card_pick() -> void:
	_card_ids.clear()
	_card_pick_locked = false
	_hud.card_overlay.visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var row: HBoxContainer = _hud.card_row
	for child in row.get_children():
		child.queue_free()


func is_card_pick_visible() -> bool:
	return bool(_hud.get("card_overlay").visible)


func show_hitmarker(kind: String) -> void:
	_hud.hitmarker.flash(kind)


func show_damage_direction(from_pos: Vector3) -> void:
	var player := _player()
	if player == null:
		return
	var delta: Vector3 = from_pos - player.global_position
	delta.y = 0.0
	if delta.length_squared() < 0.0001:
		return
	var yaw: float = player.rotation.y
	var c := cos(yaw)
	var s := sin(yaw)
	var local_x := c * delta.x - s * delta.z
	var local_z := s * delta.x + c * delta.z
	_hud.damage.flash(atan2(local_x, -local_z))


func show_death_effect(show: bool) -> void:
	var death: ColorRect = _hud.death
	if death.has_meta("tween"):
		var old_tw: Tween = death.get_meta("tween")
		if old_tw and old_tw.is_valid():
			old_tw.kill()
	var tw := death.create_tween()
	death.set_meta("tween", tw)
	if show:
		death.color.a = 0.6
		tw.tween_property(death, "color", Color(0.65, 0.0, 0.0, 1.0), 0.4).set_trans(Tween.TRANS_SINE)
	else:
		tw.tween_property(death, "color:a", 0.0, 0.5).set_trans(Tween.TRANS_CUBIC)


func layout_for_size(view_size: Vector2) -> void:
	if viewport and not stretch:
		viewport.size = Vector2i(maxi(1, int(view_size.x)), maxi(1, int(view_size.y)))
	var scale: float = clampf(minf(view_size.x / 960.0, view_size.y / 540.0), 0.58, 1.0)
	var margin := roundf(14.0 * scale)
	var font_big := maxi(13, int(round(22.0 * scale)))
	var font_small := maxi(11, int(round(16.0 * scale)))

	# Fisheye compensation: shift HUD elements inward from screen edges
	var fisheye_offset := Vector2.ZERO
	if game and game.has_method("_is_retro_enabled") and game.call("_is_retro_enabled"):
		# Max distortion at edges. Pull HUD toward center by ~30% of edge distance.
		fisheye_offset = Vector2(1.0, 0.8) * 25.0 * scale

	var crosshair: Control = _hud.crosshair
	crosshair.set("line_width", maxf(1.0, 1.5 * scale))
	crosshair.set("line_length", maxf(5.0, 8.0 * scale))
	crosshair.set("base_gap", maxf(3.0, 4.0 * scale))

	var health: Label = _hud.health
	health.add_theme_font_size_override("font_size", font_big)

	var y := view_size.y - margin - 32.0 * scale
	for item in [
		{"node": _hud.health, "x": -285.0, "w": 100.0, "font": font_big},
		{"node": _hud.ammo, "x": -150.0, "w": 120.0, "font": font_big},
		{"node": _hud.special, "x": -35.0, "w": 140.0, "font": font_small},
		{"node": _hud.dash, "x": 105.0, "w": 100.0, "font": font_small},
	]:
		var label: Label = item.node
		label.add_theme_font_size_override("font_size", item.font)
		label.anchor_left = 0.5
		label.anchor_right = 0.5
		label.anchor_top = 0.0
		label.anchor_bottom = 0.0
		var base_x: float = float(item.x) * scale
		# Apply fisheye compensation: shift toward center
		# Left side (negative): add offset to move right. Right side (positive): subtract to move left.
		var compensated_x: float = base_x + (fisheye_offset.x if base_x < 0 else -fisheye_offset.x)
		label.offset_left = compensated_x
		label.offset_right = label.offset_left + float(item.w) * scale
		# Y: bottom edge gets pushed down by fisheye, so move upward (negative offset)
		label.offset_top = y - fisheye_offset.y
		label.offset_bottom = y + 30.0 * scale - fisheye_offset.y

	var title: Label = _hud.card_title
	title.add_theme_font_size_override("font_size", maxi(16, int(round(24.0 * scale))))
	var row: HBoxContainer = _hud.card_row
	row.add_theme_constant_override("separation", maxi(6, int(round(10.0 * scale))))
	for child in row.get_children():
		_scale_card(child as Control, scale)


func _build() -> void:
	viewport = SubViewport.new()
	viewport.disable_3d = false
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.world_3d = get_viewport().world_3d
	add_child(viewport)

	camera = Camera3D.new()
	camera.current = true
	viewport.add_child(camera)

	var hud_layer := CanvasLayer.new()
	hud_layer.layer = 10
	viewport.add_child(hud_layer)
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_layer.add_child(root)

	var health := _label(Color(1.0, 0.95, 0.82))
	health.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(health)
	var ammo := _label(Color(1.0, 0.94, 0.62))
	ammo.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(ammo)
	var special := _label(Color(0.7, 1.0, 0.55))
	special.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(special)
	var dash := _label(Color(0.65, 0.9, 1.0))
	dash.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(dash)

	var crosshair := Control.new()
	crosshair.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	crosshair.set_script(CROSSHAIR_SCRIPT)
	root.add_child(crosshair)
	var hitmarker := Control.new()
	hitmarker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hitmarker.set_script(HIT_MARKER_SCRIPT)
	root.add_child(hitmarker)
	var damage := Control.new()
	damage.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	damage.set_script(DAMAGE_INDICATOR_SCRIPT)
	root.add_child(damage)
	var death := ColorRect.new()
	death.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	death.mouse_filter = Control.MOUSE_FILTER_IGNORE
	death.color = Color(0.8, 0.0, 0.0, 0.0)
	root.add_child(death)
	var ghost := ColorRect.new()
	ghost.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ghost.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ghost.color = Color(0.25, 0.55, 0.85, 0.0)
	root.add_child(ghost)

	var card_overlay := _build_card_overlay(root)
	var retro_layer := CanvasLayer.new()
	retro_layer.layer = 100
	viewport.add_child(retro_layer)
	var retro := ColorRect.new()
	retro.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	retro.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var base_mat: ShaderMaterial = game.get("_retro_material") as ShaderMaterial
	if base_mat:
		retro.material = base_mat.duplicate(true)
		(retro.material as ShaderMaterial).set_shader_parameter("cursor_visible", 0.0)
	retro_layer.add_child(retro)

	_hud = {
		"health": health,
		"ammo": ammo,
		"special": special,
		"dash": dash,
		"crosshair": crosshair,
		"hitmarker": hitmarker,
		"damage": damage,
		"death": death,
		"ghost": ghost,
		"card_overlay": card_overlay.overlay,
		"card_row": card_overlay.row,
		"card_title": card_overlay.title,
		"retro_layer": retro_layer,
	}


func _build_card_overlay(root: Control) -> Dictionary:
	var overlay := Control.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.visible = false
	root.add_child(overlay)
	var bg := ColorRect.new()
	bg.color = Color(0.0, 0.0, 0.0, 0.70)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(bg)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(center)
	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 12)
	center.add_child(vb)
	var title := _label(Color(1.0, 0.9, 0.45))
	title.text = "PICK A CARD"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_child(row)
	return {"overlay": overlay, "row": row, "title": title}


func _label(color: Color) -> Label:
	var label := Label.new()
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	label.add_theme_constant_override("outline_size", 5)
	return label


func _make_card(card_id: String, card: Dictionary, index: int) -> Control:
	var rarity := str(card.get("rarity", "common"))
	var root := Control.new()
	root.custom_minimum_size = Vector2(220, 300)
	root.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	root.set_meta("card_id", card_id)

	var idle := Control.new()
	idle.name = "Idle"
	idle.size = Vector2(200, 280)
	idle.position = (root.custom_minimum_size - idle.size) * 0.5
	idle.pivot_offset = idle.size * 0.5
	root.add_child(idle)

	var panel := Panel.new()
	panel.name = "Body"
	panel.custom_minimum_size = Vector2(200, 280)
	panel.size = panel.custom_minimum_size
	panel.pivot_offset = panel.size * 0.5
	idle.add_child(panel)
	root.set_meta("body", panel)
	root.set_meta("idle", idle)

	var sb := StyleBoxFlat.new()
	var col: Color = card.get("color", Color.WHITE)
	if rarity == "rare":
		sb.bg_color = Color(0.06, 0.07, 0.18, 0.98)
		sb.border_color = Color(0.8, 0.9, 1.0)
		sb.shadow_color = Color(0.4, 0.6, 1.0, 0.4)
		sb.shadow_size = 25
	else:
		sb.bg_color = Color(col.r * 0.15, col.g * 0.15, col.b * 0.15, 0.96)
		sb.border_color = col.lerp(Color.WHITE, 0.2)
		sb.shadow_color = Color(0, 0, 0, 0.3)
		sb.shadow_size = 8
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(12)
	panel.add_theme_stylebox_override("panel", sb)

	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 10)
	vb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 14)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(vb)
	root.set_meta("content", vb)

	var title := _label(Color.WHITE)
	title.text = str(card.get("name", card_id)).to_upper()
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.add_theme_font_size_override("font_size", 18)
	vb.add_child(title)

	var desc := _label(Color(0.9, 0.9, 0.9))
	desc.text = str(card.get("desc", ""))
	desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.add_theme_font_size_override("font_size", 14)
	vb.add_child(desc)

	var stats_vbox := VBoxContainer.new()
	stats_vbox.add_theme_constant_override("separation", 1)
	vb.add_child(stats_vbox)
	for diff_line in _card_stat_diff(card_id):
		var slbl := _label(Color(0.75, 0.85, 1.0, 0.85))
		slbl.text = diff_line
		slbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		slbl.add_theme_font_size_override("font_size", 12)
		stats_vbox.add_child(slbl)

	if rarity == "rare":
		_add_holo_overlay(panel, sb)

	var button := Button.new()
	button.flat = true
	button.focus_mode = Control.FOCUS_ALL
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	button.pressed.connect(func() -> void:
		_card_selected_index = _card_ids.find(card_id)
		_emit_selected_card()
	)
	button.mouse_entered.connect(func() -> void:
		if _card_pick_locked:
			return
		var idx := _card_ids.find(card_id)
		if idx >= 0:
			_select_card(idx)
	)
	button.focus_entered.connect(func() -> void:
		if _card_pick_locked:
			return
		var idx := _card_ids.find(card_id)
		if idx >= 0:
			_select_card(idx)
	)
	panel.add_child(button)

	var float_tw := idle.create_tween().set_loops()
	float_tw.tween_property(idle, "position:y", idle.position.y + 4.0, 2.2).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	float_tw.tween_property(idle, "position:y", idle.position.y - 4.0, 2.2).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	root.set_meta("float_tween", float_tw)

	var rot_tw := idle.create_tween().set_loops()
	var rot_mag := randf_range(1.5, 3.5)
	rot_tw.tween_property(idle, "rotation_degrees", rot_mag, 3.1).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	rot_tw.tween_property(idle, "rotation_degrees", -rot_mag, 3.1).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	root.set_meta("rot_tween", rot_tw)

	var front_style := sb
	var back_style := StyleBoxFlat.new()
	back_style.bg_color = Color(0.12, 0.12, 0.15, 1.0)
	back_style.border_color = Color(0.3, 0.3, 0.4)
	back_style.set_corner_radius_all(12)
	panel.add_theme_stylebox_override("panel", back_style)
	panel.position.y = 400.0
	panel.scale.x = 0.001
	vb.visible = false
	var reveal_delay := index * 0.15
	var reveal := panel.create_tween()
	reveal.tween_property(panel, "position:y", 0.0, 0.4)\
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT).set_delay(index * 0.04)
	reveal.tween_interval(reveal_delay)
	reveal.tween_property(panel, "scale:x", 0.001, 0.1)
	reveal.tween_callback(func() -> void:
		vb.visible = true
		panel.add_theme_stylebox_override("panel", front_style)
		SFX.card_flip(0.8 + (index * 0.15))
	)
	reveal.tween_property(panel, "scale:x", 1.0, 0.15).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	return root


func _select_card(index: int) -> void:
	if _card_ids.is_empty():
		return
	_card_selected_index = posmod(index, _card_ids.size())
	var row: HBoxContainer = _hud.card_row
	for i in range(row.get_child_count()):
		_set_card_highlight(row.get_child(i) as Control, i == _card_selected_index)


func _emit_selected_card() -> void:
	if _card_ids.is_empty() or _card_pick_locked:
		return
	_card_pick_locked = true
	var card_id := str(_card_ids[_card_selected_index])
	var row: HBoxContainer = _hud.card_row
	var picked := row.get_child(_card_selected_index) as Control
	for i in range(row.get_child_count()):
		var card := row.get_child(i) as Control
		var body := card.get_meta("body") as Control
		if body == null:
			continue
		var tw := body.create_tween().set_parallel(true)
		if card == picked:
			tw.tween_property(body, "scale", Vector2(1.5, 1.5), 0.42).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
			tw.tween_property(body, "position:y", -100.0, 0.42).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
			tw.tween_property(body, "rotation_degrees", 0.0, 0.2)
		else:
			tw.tween_property(body, "scale", Vector2(0.5, 0.5), 0.35).set_trans(Tween.TRANS_CUBIC)
			tw.tween_property(body, "modulate:a", 0.0, 0.28)
	await get_tree().create_timer(0.48).timeout
	card_selected.emit(player_id, card_id)


func _set_card_highlight(card: Control, highlighted: bool) -> void:
	if card == null:
		return
	var body := card.get_meta("body") as Control
	var idle := card.get_meta("idle") as Control
	if body == null or idle == null:
		card.scale = Vector2(1.08, 1.08) if highlighted else Vector2.ONE
		return
	var float_tw: Tween = card.get_meta("float_tween") as Tween
	var rot_tw: Tween = card.get_meta("rot_tween") as Tween
	var style := body.get_theme_stylebox("panel") as StyleBoxFlat
	var tw := body.create_tween().set_parallel(true)
	if highlighted:
		if float_tw and float_tw.is_running():
			float_tw.pause()
		if rot_tw and rot_tw.is_running():
			rot_tw.pause()
		tw.tween_property(body, "scale", Vector2(1.12, 1.12), 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		tw.tween_property(body, "position:y", -10.0, 0.18).set_trans(Tween.TRANS_CUBIC)
		tw.tween_property(idle, "rotation_degrees", 0.0, 0.14).set_trans(Tween.TRANS_CUBIC)
		body.modulate = Color(1.12, 1.12, 1.12, 1.0)
		if style:
			style.shadow_size = max(style.shadow_size, 36)
			style.shadow_color.a = 0.72
	else:
		tw.tween_property(body, "scale", Vector2.ONE, 0.22).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
		tw.tween_property(body, "position:y", 0.0, 0.22).set_trans(Tween.TRANS_CUBIC)
		body.modulate = Color.WHITE
		if style:
			style.shadow_size = 25 if str(CardLibrary.by_id(str(card.get_meta("card_id"))).get("rarity", "common")) == "rare" else 8
			style.shadow_color.a = 0.4 if style.shadow_size == 25 else 0.3
		if float_tw:
			float_tw.play()
		if rot_tw:
			rot_tw.play()


func _scale_card(card: Control, scale: float) -> void:
	if card == null:
		return
	card.custom_minimum_size = Vector2(220.0, 300.0) * scale
	var idle := card.get_meta("idle") as Control
	var body := card.get_meta("body") as Control
	if idle:
		idle.size = Vector2(200.0, 280.0) * scale
		idle.position = (card.custom_minimum_size - idle.size) * 0.5
		idle.pivot_offset = idle.size * 0.5
	if body:
		body.custom_minimum_size = Vector2(200.0, 280.0) * scale
		body.size = body.custom_minimum_size
		body.pivot_offset = body.size * 0.5


func _add_holo_overlay(panel: Control, style: StyleBoxFlat) -> void:
	var tw_border := panel.create_tween().set_loops()
	tw_border.tween_property(style, "border_color", Color(0.6, 0.9, 1.0), 1.8)
	tw_border.tween_property(style, "border_color", Color(0.9, 0.6, 1.0), 1.8)
	var holo_shader := Shader.new()
	holo_shader.code = "
		shader_type canvas_item;
		render_mode blend_add;
		uniform sampler2D gradient : source_color;
		uniform float speed = 0.5;
		uniform float angle = 0.5;
		uniform float intensity = 0.16;
		uniform vec2 card_size = vec2(200.0, 280.0);
		uniform float corner_radius = 12.0;

		void fragment() {
			vec2 uv = UV;
			float s = sin(angle);
			float c = cos(angle);
			vec2 rot_uv = vec2(uv.x * c - uv.y * s, uv.x * s + uv.y * c);
			float pos = fract(rot_uv.x * 1.5 + TIME * speed);
			vec4 holo_color = texture(gradient, vec2(pos, 0.5));
			float noise = fract(sin(dot(uv, vec2(12.9898, 78.233))) * 43758.5453);
			holo_color.rgb += noise * 0.15;
			vec2 px = uv * card_size;
			vec2 d = max(vec2(0.0), abs(px - card_size * 0.5) - (card_size * 0.5 - corner_radius));
			float dist = length(d) - corner_radius;
			float mask = smoothstep(1.0, -1.0, dist);
			COLOR = vec4(holo_color.rgb * intensity * mask, 1.0);
		}
	"
	var holo_mat := ShaderMaterial.new()
	holo_mat.shader = holo_shader
	var grad := Gradient.new()
	grad.set_offsets(PackedFloat32Array([0.0, 0.25, 0.5, 0.75, 1.0]))
	grad.set_colors(PackedColorArray([
		Color(1.0, 0.3, 0.3),
		Color(1.0, 0.9, 0.3),
		Color(0.3, 1.0, 0.3),
		Color(0.3, 0.6, 1.0),
		Color(1.0, 0.3, 1.0),
	]))
	var grad_tex := GradientTexture1D.new()
	grad_tex.gradient = grad
	holo_mat.set_shader_parameter("gradient", grad_tex)
	var holo_overlay := ColorRect.new()
	holo_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holo_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	holo_overlay.material = holo_mat
	panel.add_child(holo_overlay)
	panel.move_child(holo_overlay, 0)


func _card_stat_diff(card_id: String) -> Array[String]:
	var out: Array[String] = []
	var player := _player()
	if player == null:
		return out
	var base_w: Weapon = player.get("weapon")
	if base_w == null:
		return out
	var card := CardLibrary.by_id(card_id)
	if card.is_empty():
		return out
	var next_w: Weapon = base_w.duplicate()
	card.apply.call(next_w)
	if abs(base_w.damage_mult - next_w.damage_mult) > 0.001:
		out.append("%+d%% Damage" % int(round((next_w.damage_mult / base_w.damage_mult - 1.0) * 100.0)))
	if abs(base_w.fire_rate_mult - next_w.fire_rate_mult) > 0.001:
		out.append("%+d%% Fire Rate" % int(round((next_w.fire_rate_mult / base_w.fire_rate_mult - 1.0) * 100.0)))
	if base_w.mag_size_bonus != next_w.mag_size_bonus:
		out.append("%+d Ammo Capacity" % (next_w.mag_size_bonus - base_w.mag_size_bonus))
	if abs(base_w.reload_mult - next_w.reload_mult) > 0.001:
		out.append("%+d%% Reload Speed" % int(round((next_w.reload_mult / base_w.reload_mult - 1.0) * 100.0)))
	if base_w.extra_projectiles != next_w.extra_projectiles:
		out.append("%+d Projectiles" % (next_w.extra_projectiles - base_w.extra_projectiles))
	if base_w.ricochet_count != next_w.ricochet_count:
		out.append("%+d Bounces" % (next_w.ricochet_count - base_w.ricochet_count))
	if abs(base_w.move_speed_mult - next_w.move_speed_mult) > 0.001:
		out.append("%+d%% Move Speed" % int(round((next_w.move_speed_mult / base_w.move_speed_mult - 1.0) * 100.0)))
	if next_w.explosive_radius > base_w.explosive_radius:
		out.append("Explosive Payload")
	if base_w.max_hp_bonus != next_w.max_hp_bonus:
		out.append("%+d Max HP" % (next_w.max_hp_bonus - base_w.max_hp_bonus))
	if base_w.extra_jumps != next_w.extra_jumps:
		out.append("%+d Extra Jumps" % (next_w.extra_jumps - base_w.extra_jumps))
	return out


func _update_hud(player: Node) -> void:
	var is_ghost := bool(player.get("ghost_mode"))
	var weapon: Weapon = player.get("weapon")
	_hud.health.text = "GHOST" if is_ghost else "HP  %d" % int(player.get("health"))
	if is_ghost:
		_hud.ammo.text = "GHOST"
		_hud.special.text = "MINE"
	else:
		_hud.ammo.text = "%d / %d" % [int(player.get("mag")), weapon.get_mag_size()]
		var special_text := weapon.special.to_upper()
		var special_cd := float(player.get("grenade_cooldown"))
		if special_cd > 0.0:
			special_text = "%.1f" % special_cd
		_hud.special.text = special_text
	_hud.dash.text = "DASH %d" % int(player.get("dash_charges"))
	_hud.crosshair.set("spread", player.call("get_effective_spread"))
	_hud.ghost.color.a = 0.28 if is_ghost and not bool(_hud.card_overlay.visible) else 0.0
	_hud.retro_layer.visible = bool(game.get("_retro_enabled"))


func _player() -> Node3D:
	if game == null:
		return null
	return game.players_root.get_node_or_null(str(player_id)) as Node3D


func _apply_owner_cull(player: Node) -> void:
	var owner_bit := _player_layer_bit(player_id)
	_assign_player_visual_layer(player, owner_bit)
	camera.cull_mask = 0xfffff & ~owner_bit


func _assign_player_visual_layer(player: Node, layer_bit: int) -> void:
	if bool(player.get_meta("render_player_layer_assigned", false)) \
			and int(player.get_meta("render_player_layer_bit", 0)) == layer_bit:
		return
	var body := player.get_node_or_null("BodyModel")
	if body:
		_set_visual_layer_recursive(body, layer_bit)
	player.set_meta("render_player_layer_assigned", true)
	player.set_meta("render_player_layer_bit", layer_bit)


func _set_visual_layer_recursive(node: Node, layer_bit: int) -> void:
	if node is VisualInstance3D:
		(node as VisualInstance3D).layers = layer_bit
	for child in node.get_children():
		_set_visual_layer_recursive(child, layer_bit)


func _player_layer_bit(id: int) -> int:
	if id >= 10000:
		return 1 << (PLAYER_VISUAL_LAYER_BASE + 1 + posmod(id - 10000, 10))
	return 1 << PLAYER_VISUAL_LAYER_BASE
