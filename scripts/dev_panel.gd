extends PanelContainer

# F1 dev panel — read-mostly inspector for the local-or-targeted player,
# plus quick-action buttons (apply/remove cards, godmode, passive AI).
#
# Lives as a child of $HUD on the Game node. All calls back into Game state
# go through `_game` (set via setup()) so this script doesn't reach into
# game.gd's private members directly.

var _game: Node = null
var _content: VBoxContainer = null
# 0 = "Local player" (follow whoever Game.local_player resolves to);
# any other value is a specific player_id to inspect.
var _target_id: int = 0


func setup(game: Node) -> void:
	_game = game


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 0.0
	anchor_bottom = 1.0
	offset_left = -420.0
	offset_right = 420.0
	offset_top = 30.0
	offset_bottom = -30.0
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.05, 0.08, 0.96)
	style.set_border_width_all(2)
	style.border_color = Color(0.4, 0.8, 1.0)
	style.set_corner_radius_all(6)
	style.content_margin_left = 16
	style.content_margin_right = 16
	style.content_margin_top = 12
	style.content_margin_bottom = 12
	add_theme_stylebox_override("panel", style)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	_content = VBoxContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_theme_constant_override("separation", 6)
	scroll.add_child(_content)


func toggle() -> void:
	visible = not visible
	if visible:
		_refresh()
	_sync_host_mouse_mode()


func is_open() -> bool:
	return visible


func close() -> void:
	if visible:
		toggle()


func refresh_if_visible() -> void:
	if visible:
		call_deferred("_refresh")

func _sync_host_mouse_mode() -> void:
	if _game and _game.has_method("_sync_mouse_mode"):
		_game.call("_sync_mouse_mode")
	else:
		Input.mouse_mode = Input.MOUSE_MODE_HIDDEN if visible else Input.MOUSE_MODE_CAPTURED


# Resolve the currently-targeted player. Used by Game's keybindings so
# F1-driven actions (G/1-5) hit whichever player the panel has selected.
func get_target() -> Node:
	if _target_id == 0:
		var lp = _game.local_player if _game else null
		return lp if (lp and is_instance_valid(lp)) else null
	if _game == null:
		return null
	return _game.players_root.get_node_or_null(str(_target_id))


# Cheat-help on '?' — broadcast through the existing _announce RPC so it
# pops on the round banner like the rest of the dev hints.
func show_help() -> void:
	if _game == null:
		return

	# Toggle off if already showing help
	if _game.round_banner.visible and _game.round_banner.text.begins_with("DEV SHORTCUTS:"):
		_game._announce.rpc("", 0.0)
		return

	var help_text := "DEV SHORTCUTS:\n" + \
		"G: Toggle Godmode\n" + \
		"P: Toggle Passive AI\n" + \
		"M: Restart Match\n" + \
		"L: Trigger Lava\n" + \
		"1: Reset Weapon\n" + \
		"2: Apply Sniper\n" + \
		"3: Apply Shotgun\n" + \
		"4: Apply Uzi\n" + \
		"5: Apply Bazooka\n" + \
		"F1: Full Dev Panel"
	# Use smaller font size (24) for the help block
	_game._announce.rpc(help_text, 10.0, 24)


# ── Content rebuild ────────────────────────────────────────────────────────

func _refresh() -> void:
	if _game == null or _content == null:
		return
	for c in _content.get_children():
		c.queue_free()
	_heading("DEV  ·  F1 to close", Color(0.5, 0.9, 1.0), 20)
	_note("Quick shortcuts: G (god), P (passive AI), M (restart), L (lava), 1-5 (cards), ? (help)")
	_toggle_row("Passive AI (stationary, no shooting)", _game.bots_hold_fire, func(v: bool) -> void:
		_game.bots_hold_fire = v
		call_deferred("_refresh"))

	var target: Node = get_target()
	if target and is_instance_valid(target):
		_toggle_row("God mode (this player)", target.get("god_mode") == true, func(v: bool) -> void:
			target.god_mode = v
			call_deferred("_refresh"))

	_player_picker()
	# Cards first — rare ones (uzi, bazooka, etc.) at the top so they're easy
	# to spam-add for testing. Common cards follow.
	_heading("— CARDS —", Color(1.0, 0.6, 0.9), 15)
	if target and is_instance_valid(target):
		var applied: Array = target.weapon.applied_cards
		var counts := {}
		for cid in applied:
			counts[cid] = counts.get(cid, 0) + 1
		var sorted_cards: Array = CardLibrary.all().duplicate()
		sorted_cards.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			# rare (0) before common (1); stable name order within each.
			var ra: int = 0 if str(a.get("rarity", "common")) == "rare" else 1
			var rb: int = 0 if str(b.get("rarity", "common")) == "rare" else 1
			if ra != rb:
				return ra < rb
			return str(a.get("name", "")) < str(b.get("name", "")))
		for card in sorted_cards:
			_card_row(card, counts.get(card.id, 0))
	else:
		_note("(target player not spawned)")
	_heading("— WEAPON STATS —", Color(1.0, 0.9, 0.5), 15)
	if target and is_instance_valid(target):
		var w: Weapon = target.weapon
		_stat("damage", "%.1f  (base %.0f × %.2f)" % [w.get_damage(), Weapon.BASE_DAMAGE, w.damage_mult])
		_stat("fire interval", "%.3fs  (×%.2f)  %s" % [w.get_fire_interval(), w.fire_rate_mult, "FULL-AUTO" if w.full_auto else "semi-auto"])
		_stat("mag size", "%d  (base %d %+d)" % [w.get_mag_size(), Weapon.BASE_MAG_SIZE, w.mag_size_bonus])
		_stat("reload time", "%.2fs  (×%.2f)" % [w.get_reload_time(), w.reload_mult])
		_stat("headshot mult", "×%.2f" % w.get_headshot_mult())
		_stat("shots / trigger", str(w.get_shots_per_trigger()))
		_stat("ricochet", str(w.ricochet_count))
		_stat("spread", "%.4f rad  (%.2f°)" % [w.spread, rad_to_deg(w.spread)])
		_stat("lifesteal", "%.0f%%" % (w.lifesteal * 100.0))
		_stat("explosive radius / dmg", "%.1fm  /  %.1f" % [w.explosive_radius, w.explosive_damage])
		_stat("bullet scale", "%.2f" % w.bullet_scale)
		_stat("bullet color", "#%s" % w.bullet_color.to_html(false))
	else:
		_note("(target player not spawned)")


# ── Row builders ───────────────────────────────────────────────────────────

func _player_picker() -> void:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	var lbl := Label.new()
	lbl.text = "Edit player:"
	lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.85))
	hbox.add_child(lbl)
	var opt := OptionButton.new()
	opt.focus_mode = Control.FOCUS_NONE
	opt.add_item("Local player", 0)
	var selected_idx: int = 0
	var i: int = 1
	for raw_id in NetworkManager.players:
		var pid := int(raw_id)
		var pname: String = str(NetworkManager.players[raw_id])
		var label_text: String = "%s  (id %d)" % [pname, pid]
		# Reuse Game's bot-id heuristic so the label matches what KEY_M / etc see.
		if _game and _game.has_method("_is_bot_id") and _game.call("_is_bot_id", pid):
			label_text += "  [bot]"
		opt.add_item(label_text, pid)
		if pid == _target_id:
			selected_idx = i
		i += 1
	opt.select(selected_idx)
	opt.item_selected.connect(func(idx: int) -> void:
		_target_id = int(opt.get_item_id(idx))
		call_deferred("_refresh"))
	hbox.add_child(opt)
	_content.add_child(hbox)


func _heading(text: String, color: Color, font_size: int) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", color)
	lbl.add_theme_font_size_override("font_size", font_size)
	_content.add_child(lbl)


func _stat(stat_name: String, value: String) -> void:
	var hbox := HBoxContainer.new()
	var n := Label.new()
	n.text = stat_name
	n.custom_minimum_size = Vector2(220, 0)
	n.add_theme_color_override("font_color", Color(0.7, 0.7, 0.85))
	hbox.add_child(n)
	var v := Label.new()
	v.text = value
	v.add_theme_color_override("font_color", Color(1, 1, 1))
	hbox.add_child(v)
	_content.add_child(hbox)


func _note(text: String) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.7))
	_content.add_child(lbl)


func _toggle_row(label: String, value: bool, on_changed: Callable) -> void:
	var cb := CheckBox.new()
	cb.text = label
	cb.button_pressed = value
	cb.focus_mode = Control.FOCUS_NONE
	cb.add_theme_color_override("font_color", Color(1, 1, 1))
	cb.toggled.connect(on_changed)
	_content.add_child(cb)


func _card_row(card: Dictionary, count: int) -> void:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 10)

	var n := Label.new()
	n.text = "%s  —  %s" % [card.name, card.desc]
	n.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	n.add_theme_color_override("font_color", card.color)
	n.add_theme_font_size_override("font_size", 12)
	hbox.add_child(n)

	var clbl := Label.new()
	clbl.text = str(count)
	clbl.custom_minimum_size = Vector2(30, 0)
	clbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	clbl.add_theme_color_override("font_color", Color(1, 1, 1) if count > 0 else Color(0.4, 0.4, 0.4))
	clbl.add_theme_font_size_override("font_size", 10)
	hbox.add_child(clbl)

	var btn_minus := Button.new()
	btn_minus.text = "-"
	btn_minus.custom_minimum_size = Vector2(30, 30)
	btn_minus.focus_mode = Control.FOCUS_NONE
	btn_minus.disabled = count <= 0
	btn_minus.pressed.connect(_remove_card.bind(card.id))
	hbox.add_child(btn_minus)

	var btn_plus := Button.new()
	btn_plus.text = "+"
	btn_plus.custom_minimum_size = Vector2(30, 30)
	btn_plus.focus_mode = Control.FOCUS_NONE
	btn_plus.pressed.connect(_apply_card.bind(card.id))
	hbox.add_child(btn_plus)

	_content.add_child(hbox)


# ── Card mutation actions ──────────────────────────────────────────────────

func _apply_card(card_id: String) -> void:
	var target: Node = get_target()
	if target == null or not is_instance_valid(target):
		return
	target.apply_card.rpc(card_id)
	call_deferred("_refresh")


func _remove_card(card_id: String) -> void:
	# Cards mutate weapon cumulatively and have no inverse — easiest way to
	# drop one is to reset and reapply every OTHER card in the stack.
	var target: Node = get_target()
	if target == null or not is_instance_valid(target):
		return
	var remaining: Array = target.weapon.applied_cards.duplicate()
	var idx := remaining.find(card_id)
	if idx >= 0:
		remaining.remove_at(idx)
	target.reset_weapon.rpc()
	for c in remaining:
		target.apply_card.rpc(str(c))
	call_deferred("_refresh")
