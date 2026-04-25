extends Node3D

# Audio sandbox: full arena, real Player bots fighting each other with random
# card builds, free-look camera, and a sidebar of sliders that retune the
# SFX volume knobs live.
#
# Run: godot --scene res://scenes/audio_lab.tscn  (or set as main scene).

const PLAYER_SCENE := preload("res://scenes/player.tscn")
const ARENA_SCENE := preload("res://scenes/arena.tscn")
const NUM_BOTS := 5
const CARDS_PER_BOT := 4
# Stand-in for game state — Player._bot_physics gates firing on
# `scene.get("state") == State.PLAYING` (== 1).
const PLAYING_STATE := 1
const HP_FLOOR := 50  # if any bot drops below this we top them back up

const MOVE_SPEED := 8.0
const FAST_MULT := 4.0
const MOUSE_SENS := 0.0025

# Public, so Player._bot_physics's `scene.get("state")` resolves to PLAYING.
var state: int = PLAYING_STATE
# Player paths look up `scene.local_player` in a few places (death-cam, etc.).
# Leaving it null is fine — every consumer is null-guarded.
var local_player: Node = null

var _camera: Camera3D
var _yaw: float = 0.0
var _pitch: float = -0.2
var _bots: Array[Node] = []
var _firing_paused: bool = false

func _ready() -> void:
	_build_arena()
	_build_camera()
	_spawn_bots()
	_build_ui()
	# Visible cursor so the slider panel works; RMB captures for look.
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# Top up HP every second so bots can't actually die.
	var hp_timer := Timer.new()
	hp_timer.wait_time = 1.0
	hp_timer.autostart = true
	hp_timer.timeout.connect(_top_up_bots)
	add_child(hp_timer)

# -------------------- input / camera --------------------

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		Input.mouse_mode = (
			Input.MOUSE_MODE_VISIBLE
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
			else Input.MOUSE_MODE_CAPTURED
		)
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * MOUSE_SENS
		_pitch = clampf(_pitch - event.relative.y * MOUSE_SENS, -1.4, 1.4)
		if _camera:
			_camera.rotation = Vector3(_pitch, _yaw, 0)

func _process(delta: float) -> void:
	if _camera == null:
		return
	# Bot Players keep trying to make their own camera current — re-claim ours.
	if not _camera.current:
		_camera.make_current()
	var fwd: Vector3 = -_camera.global_transform.basis.z
	var right: Vector3 = _camera.global_transform.basis.x
	var up: Vector3 = Vector3.UP
	var move := Vector3.ZERO
	if Input.is_key_pressed(KEY_W): move += fwd
	if Input.is_key_pressed(KEY_S): move -= fwd
	if Input.is_key_pressed(KEY_D): move += right
	if Input.is_key_pressed(KEY_A): move -= right
	if Input.is_key_pressed(KEY_E): move += up
	if Input.is_key_pressed(KEY_Q): move -= up
	if move.length_squared() > 0.0:
		var speed := MOVE_SPEED * (FAST_MULT if Input.is_key_pressed(KEY_SHIFT) else 1.0)
		_camera.global_position += move.normalized() * speed * delta

# -------------------- world setup --------------------

func _build_arena() -> void:
	var arena: Node = ARENA_SCENE.instantiate()
	arena.name = "Arena"
	add_child(arena)
	# Players group container — bot AI looks up siblings via get_parent().get_children().
	var players_root := Node3D.new()
	players_root.name = "Players"
	add_child(players_root)

func _build_camera() -> void:
	_camera = Camera3D.new()
	_camera.fov = 75.0
	_camera.rotation = Vector3(_pitch, _yaw, 0)
	add_child(_camera)
	_camera.global_position = Vector3(0, 6, 14)
	_camera.make_current()
	# Raytraced-audio listener tracks the active camera. One per scene.
	# Owner must be a node with a transform — the plugin reads
	# owner.transform.basis.x in _update_ambient (would crash if null).
	var listener := RaytracedAudioListener.new()
	_camera.add_child(listener)
	listener.owner = _camera

# -------------------- bots --------------------

func _spawn_bots() -> void:
	var players_root: Node = $Players
	if players_root == null:
		return
	var spawns := _gather_spawn_points()
	for i in NUM_BOTS:
		var pid := 9000 + i
		var bot := PLAYER_SCENE.instantiate()
		bot.name = str(pid)
		bot.set("player_id", pid)
		bot.set("player_name", "Bot_%d" % i)
		bot.set("is_bot", true)
		var pos: Vector3 = spawns[i % spawns.size()] if not spawns.is_empty() else _random_spread_pos(i)
		bot.position = pos
		players_root.add_child(bot)
		_bots.append(bot)
		# Apply random cards once Player is in tree (CardLibrary etc. are global).
		await get_tree().process_frame
		_apply_random_cards(bot)
		# Effectively-infinite HP so audio test never grinds to a halt.
		bot.set("health", 999999)
	# Final pass: make sure our free cam owns "current" after Player.
	_camera.make_current()

func _gather_spawn_points() -> Array[Vector3]:
	var out: Array[Vector3] = []
	for n in get_tree().get_nodes_in_group("spawnpoints"):
		if n is Node3D:
			out.append((n as Node3D).global_position)
	return out

func _random_spread_pos(i: int) -> Vector3:
	var angle := float(i) / float(NUM_BOTS) * TAU
	return Vector3(cos(angle) * 8.0, 1.5, sin(angle) * 8.0)

func _apply_random_cards(bot: Node) -> void:
	var cards := CardLibrary.random_ids(CARDS_PER_BOT, 1.0)
	for cid in cards:
		# Use the local apply path (not RPC) — we're a single-peer sandbox.
		if bot.has_method("apply_card"):
			bot.call("apply_card", str(cid))

func _top_up_bots() -> void:
	for b in _bots:
		if not is_instance_valid(b):
			continue
		var hp: int = int(b.get("health"))
		if hp < HP_FLOOR:
			b.set("health", 999999)
			# If they entered ghost or got frozen, snap them out.
			if bool(b.get("ghost_mode")):
				b.call("set_ghost_mode", false)
			if bool(b.get("frozen")):
				b.set("frozen", false)

# -------------------- UI sliders (same as before) --------------------

func _build_ui() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.position = Vector2(12, 12)
	panel.custom_minimum_size = Vector2(380, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.65)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	panel.add_theme_stylebox_override("panel", sb)
	canvas.add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	panel.add_child(vb)

	var title := Label.new()
	title.text = "AUDIO LAB — RMB look, WASD/QE move, Shift sprint"
	title.add_theme_font_size_override("font_size", 14)
	title.add_theme_color_override("font_color", Color(1, 0.95, 0.6))
	vb.add_child(title)

	var knobs := [
		["shot self dB",          "shot_self_db",          -40.0,  6.0],
		["shot world dB",         "shot_world_db",         -30.0, 12.0],
		["shot dmg / doubling",   "shot_dmg_per_double_db", 0.0,  18.0],
		["shot pitch / doubling", "shot_pitch_per_double",  0.0,   0.6],
		["explosion bang dB",     "explosion_bang_db",     -10.0, 24.0],
		["explosion rumble dB",   "explosion_rumble_db",   -10.0, 24.0],
		["footstep dB",           "footstep_db",           -50.0,-10.0],
		["jump dB",               "jump_db",               -30.0,  6.0],
		["landing max dB",        "landing_max_db",        -10.0, 18.0],
		["hurt SELF dB",          "hurt_self_db",          -50.0,  0.0],
		["hurt world dB",         "hurt_world_db",         -40.0,  6.0],
		["death SELF dB",         "death_self_db",         -50.0,  0.0],
		["death world dB",        "death_world_db",        -40.0,  6.0],
		["hit_received dB",       "hit_received_db",       -40.0,  6.0],
		["bullet zip CLOSE dB",   "bullet_zip_close_db",   -50.0,  0.0],
		["bullet zip FAR dB",     "bullet_zip_far_db",     -60.0,-10.0],
		["shot wet send dB",      "shot_wet_db",           -40.0,  6.0],
		["shot rumble dB",        "shot_rumble_db",        -40.0,  6.0],
		["unit_size (m)",         "unit_size",               1.0, 40.0],
	]
	for k in knobs:
		_add_slider(vb, k[0], k[1], k[2], k[3])

	var hb := HBoxContainer.new()
	vb.add_child(hb)
	var quiet_btn := Button.new()
	quiet_btn.text = "Toggle bot fire"
	quiet_btn.focus_mode = Control.FOCUS_NONE
	quiet_btn.pressed.connect(_toggle_firefight)
	hb.add_child(quiet_btn)
	var reroll_btn := Button.new()
	reroll_btn.text = "Reroll cards"
	reroll_btn.focus_mode = Control.FOCUS_NONE
	reroll_btn.pressed.connect(_reroll_all_cards)
	hb.add_child(reroll_btn)

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
	# Each entry maps to the prefix matched against debug_label in sfx.gd.
	# "" silences nothing. Anything else mutes everything that doesn't start
	# with that prefix (so "explosion" catches both bang and rumble, etc.).
	var solo_choices := [
		["All sounds",   ""],
		["shot",          "shot"],
		["explosion",     "explosion"],
		["footstep",      "footstep"],
		["jump",          "jump"],
		["landing",       "landing"],
		["dash",          "dash"],
		["hurt",          "hurt"],
		["death",         "death"],
		["hit_received",  "hit_received"],
		["hitmarker",     "hitmarker"],
		["bullet_zip",    "bullet_zip"],
		["grenade_launch","grenade_launch"],
		["melee",         "melee"],
		["card_flip",     "card_flip"],
		["reload",        "reload"],
	]
	for i in solo_choices.size():
		solo_opt.add_item(solo_choices[i][0], i)
	solo_opt.selected = 0
	solo_opt.item_selected.connect(func(idx: int) -> void:
		SFX.solo_kind = solo_choices[idx][1])
	solo_row.add_child(solo_opt)

func _toggle_firefight() -> void:
	_firing_paused = not _firing_paused
	for b in _bots:
		if is_instance_valid(b):
			b.set("frozen", _firing_paused)

func _reroll_all_cards() -> void:
	for b in _bots:
		if not is_instance_valid(b):
			continue
		# Reset to base, then re-apply 4 fresh random cards.
		if b.has_method("reset_weapon"):
			b.call("reset_weapon")
		_apply_random_cards(b)

func _add_slider(vb: VBoxContainer, label_text: String, prop: String, lo: float, hi: float) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var lbl := Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size = Vector2(160, 0)
	lbl.add_theme_font_size_override("font_size", 12)
	row.add_child(lbl)
	# Snapshot the initial (game) value so the reset button can restore it.
	var initial: float = float(SFX.get(prop))
	var slider := HSlider.new()
	slider.min_value = lo
	slider.max_value = hi
	# Auto step: ~200 increments across the slider's range. Fine knobs
	# (e.g. 0..0.6) get 0.003 steps; coarse dB knobs get 0.1 steps.
	slider.step = maxf((hi - lo) / 200.0, 0.001)
	slider.value = initial
	slider.custom_minimum_size = Vector2(140, 18)
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
