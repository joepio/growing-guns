extends Node3D

# Gun lab: one stationary shooter + a free-cam listener. Use to isolate
# gunshot sounds without crossfire chaos. Toggle FPV mode to teleport the
# listener to the shooter's eye position; F1 opens a card panel that applies
# cards to the static shooter so you can hear how each weapon variant sounds.

const PLAYER_SCENE := preload("res://scenes/player.tscn")
const ARENA_SCENE := preload("res://scenes/arena_procedural.tscn")
# Fixed seed so the gun-lab arena stays reproducible across launches.
const ARENA_SEED := 12345
const PLAYING_STATE := 1
# Centre-rear of the arena, facing -Z. Far enough from any wall that bullets
# fly through open space and the listener can move around all sides.
const SHOOTER_POS := Vector3(0.0, 2.0, 18.0)
const SHOOTER_YAW := 0.0  # faces -Z by player convention
const FREE_CAM_INITIAL := Vector3(10.0, 2.5, 18.0)
# Preset listener positions reachable from the panel buttons. Shooter faces -Z
# from z=18 so the target sits down-range along -Z; spectator is off to one
# side, slightly elevated, looking at the bullet path's midpoint.
const TARGET_POS := Vector3(0.0, 1.5, 0.0)
const SPECTATOR_POS := Vector3(14.0, 3.5, 8.0)
const SPECTATOR_LOOK_AT := Vector3(0.0, 1.5, 8.0)
# Side-of-gun close-up — useful for inspecting muzzle flash + reload anims and
# hearing the muzzle blast from a near-field bystander angle.
const GUN_SIDE_POS := Vector3(1.4, 1.6, 17.4)
const GUN_SIDE_LOOK_AT := Vector3(0.0, 1.6, 17.4)
# Authority ID we move the shooter to so player.gd's authority-gated paths
# (mouse-look in _unhandled_input, _input_impl, etc.) don't fire on this lab's
# local peer. 999 is just "anything other than 1".
const FOREIGN_AUTHORITY := 999
const MOVE_SPEED := 8.0
const FAST_MULT := 4.0
const MOUSE_SENS := 0.0025

# Player.gd reads scene.get("state") to gate AI firing — keep PLAYING so the
# shooter's _bot_physics doesn't error, but we set is_bot=true and never
# assign a _bot_target so it never auto-fires from AI.
var state: int = PLAYING_STATE
var local_player: Node = null  # exposed so any reusable panel that reads
								# scene.local_player picks up our shooter.

var _shooter: Node = null
var _free_cam: Camera3D
var _yaw: float = 0.0
var _pitch: float = 0.0
var _firing: bool = false
var _fpv: bool = false
var _card_panel: PanelContainer = null
var _stats_label: Label = null
var _hud_label: Label = null
var _saved_mouse_mode_card: int = Input.MOUSE_MODE_VISIBLE
# Stash the listener pose before entering FPV so TAB can restore it.
var _pre_fpv_pos: Vector3 = FREE_CAM_INITIAL
var _pre_fpv_yaw: float = 0.0
var _pre_fpv_pitch: float = 0.0

func _ready() -> void:
	_build_arena()
	_build_camera()
	_spawn_shooter()
	_build_ui()
	# Reuse the F2 panel from the main game — same sliders, meters, solo. The
	# class self-installs on KEY_F2. open_mouse_mode = VISIBLE because this
	# lab has no in-shader cursor; default HIDDEN would leave the cursor
	# invisible while the panel is open.
	var f2_panel := AudioSettingsPanel.new()
	f2_panel.open_mouse_mode = Input.MOUSE_MODE_VISIBLE
	add_child(f2_panel)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

# -------------------- world setup --------------------

func _build_arena() -> void:
	var arena: Node = ARENA_SCENE.instantiate()
	arena.name = "Arena"
	add_child(arena)
	# arena_procedural is empty until apply_seed runs (regenerate_on_ready=false).
	if arena.has_method("apply_seed"):
		arena.apply_seed(ARENA_SEED)
	# Mirror game.gd's structure — bots/players live under "Players" so player.gd's
	# get_parent().get_children() lookups (target search, RPC routing) work.
	var players_root := Node3D.new()
	players_root.name = "Players"
	add_child(players_root)

func _build_camera() -> void:
	_free_cam = Camera3D.new()
	_free_cam.fov = 75.0
	_free_cam.position = FREE_CAM_INITIAL
	add_child(_free_cam)
	# Initial look-at the shooter's chest so the user sees what they're testing.
	_free_cam.look_at(Vector3(0.0, 1.5, 0.0), Vector3.UP)
	_yaw = _free_cam.rotation.y
	_pitch = _free_cam.rotation.x
	_free_cam.make_current()
	# Listener is parented to the camera and owned by it — the raytraced-audio
	# plugin reads owner.transform.basis.x in _update_ambient.
	var listener := RaytracedAudioListener.new()
	_free_cam.add_child(listener)
	listener.owner = _free_cam

func _spawn_shooter() -> void:
	var players_root: Node = $Players
	var p := PLAYER_SCENE.instantiate()
	# player_id != local unique_id (1) so bullet.gd's shooter-skip doesn't fire
	# and the lab actually hears its own bullet zips. SFX.shot() also takes the
	# "world" path (is_self=false) so the shot reads through 3D positional.
	p.name = "2"
	p.set("player_id", 2)
	p.set("player_name", "Shooter")
	# is_bot=true routes physics through _bot_physics — without a target it
	# just zeros velocity each tick. We trigger fires ourselves from
	# _physics_process so the shooter isn't actually AI-driven.
	p.set("is_bot", true)
	p.position = SHOOTER_POS
	p.rotation = Vector3(0.0, SHOOTER_YAW, 0.0)
	players_root.add_child(p)
	# Authority is set to 1 by player.gd:_enter_tree when is_bot=true (matches
	# our local peer) — that gives the player's _unhandled_input ownership of
	# our mouse, so any mouse-look would rotate the shooter. Hand authority off
	# to a fake peer ID so all the player's authority-gated code paths skip,
	# and we control firing/transform purely externally.
	p.set_multiplayer_authority(FOREIGN_AUTHORITY)
	_shooter = p
	p.set("health", 999999)
	local_player = p

# -------------------- input --------------------

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			Input.mouse_mode = (
				Input.MOUSE_MODE_VISIBLE
				if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
				else Input.MOUSE_MODE_CAPTURED
			)
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		# Mouse-look is allowed in both modes; in FPV the camera position is
		# locked to the shooter's eye but the user can still rotate to listen
		# in different directions.
		_yaw -= event.relative.x * MOUSE_SENS
		_pitch = clampf(_pitch - event.relative.y * MOUSE_SENS, -1.4, 1.4)
		_free_cam.rotation = Vector3(_pitch, _yaw, 0.0)
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_ESCAPE:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			KEY_TAB:
				_set_fpv(not _fpv)
			KEY_F1:
				_toggle_card_panel()
			KEY_SPACE:
				_firing = true
			KEY_R:
				if _shooter:
					_shooter.call("_start_reload")
	elif event is InputEventKey and not event.pressed and event.keycode == KEY_SPACE:
		_firing = false

func _toggle_card_panel() -> void:
	# Save / restore the cursor mode so opening the panel always lands in
	# VISIBLE (clickable UI), and closing returns to whatever the user had
	# before — typically VISIBLE, but CAPTURED if they were flying around.
	_card_panel.visible = not _card_panel.visible
	if _card_panel.visible:
		_saved_mouse_mode_card = Input.mouse_mode
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		Input.mouse_mode = _saved_mouse_mode_card

func _set_fpv(on: bool) -> void:
	if on == _fpv:
		return
	if on and _shooter and is_instance_valid(_shooter):
		# Stash the current listener pose so we can return on toggle-off.
		_pre_fpv_pos = _free_cam.global_position
		_pre_fpv_yaw = _yaw
		_pre_fpv_pitch = _pitch
		_fpv = true
		# Hide the visible body & nameplate — you ARE the shooter, not looking
		# AT them. The body model normally stays visible because is_bot=true.
		var body: Node = _shooter.get_node_or_null("BodyModel")
		if body:
			body.visible = false
		var name_lbl: Node = _shooter.get_node_or_null("NameLabel")
		if name_lbl:
			name_lbl.visible = false
		# Make is_self=true in SFX.shot() — shooter_id needs to equal our local
		# unique_id (always 1 in single-peer). Rename the node to match so
		# player.gd:_rifle_fired's get_node_or_null(str(shooter_id)) still
		# resolves the weapon. Restored on exit.
		_shooter.set("player_id", 1)
		_shooter.name = "1"
		# Align look forward and snap to the eye. Camera tracks the eye each
		# frame in _process so head movement (none, since pinned) is followed.
		_free_cam.rotation = Vector3(0.0, SHOOTER_YAW, 0.0)
		_yaw = SHOOTER_YAW
		_pitch = 0.0
	else:
		_fpv = false
		if _shooter and is_instance_valid(_shooter):
			var body: Node = _shooter.get_node_or_null("BodyModel")
			if body:
				body.visible = true
			var name_lbl: Node = _shooter.get_node_or_null("NameLabel")
			if name_lbl:
				name_lbl.visible = true
			_shooter.set("player_id", 2)
			_shooter.name = "2"
		# Restore the listener pose from before FPV.
		_free_cam.global_position = _pre_fpv_pos
		_yaw = _pre_fpv_yaw
		_pitch = _pre_fpv_pitch
		_free_cam.rotation = Vector3(_pitch, _yaw, 0.0)
	_update_hud()

func _process(delta: float) -> void:
	if _free_cam == null:
		return
	# Bot's _refresh_authority_view tries to clear_current() on the player camera
	# — which is fine — but if anything else makes_current we need to reclaim.
	if not _free_cam.current:
		_free_cam.make_current()
	if _fpv and _shooter and is_instance_valid(_shooter):
		var eye: Node3D = _shooter.get_node_or_null("Camera")
		if eye:
			_free_cam.global_position = eye.global_position
		else:
			_free_cam.global_position = _shooter.global_position + Vector3(0.0, 1.5, 0.0)
	elif Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var fwd: Vector3 = -_free_cam.global_transform.basis.z
		var right: Vector3 = _free_cam.global_transform.basis.x
		var move := Vector3.ZERO
		if Input.is_key_pressed(KEY_W): move += fwd
		if Input.is_key_pressed(KEY_S): move -= fwd
		if Input.is_key_pressed(KEY_D): move += right
		if Input.is_key_pressed(KEY_A): move -= right
		if Input.is_key_pressed(KEY_E): move += Vector3.UP
		if Input.is_key_pressed(KEY_Q): move -= Vector3.UP
		if move.length_squared() > 0.0:
			var speed := MOVE_SPEED * (FAST_MULT if Input.is_key_pressed(KEY_SHIFT) else 1.0)
			_free_cam.global_position += move.normalized() * speed * delta
	_update_hud()

func _physics_process(delta: float) -> void:
	if _shooter == null or not is_instance_valid(_shooter):
		return
	# Pin the shooter every tick. _fire_rifle calls rotate_y() and pushes
	# velocity, _do_explosion_view_punch nudges position offsets, and authority
	# is now foreign so _physics_process inside the player doesn't run gravity
	# or velocity damping — without an explicit pin the shooter would drift
	# on each shot. We also zero recoil_pitch / look_pitch so aim never tips.
	_shooter.global_position = SHOOTER_POS
	_shooter.rotation = Vector3(0.0, SHOOTER_YAW, 0.0)
	_shooter.set("velocity", Vector3.ZERO)
	_shooter.set("recoil_pitch", 0.0)
	_shooter.set("look_pitch", 0.0)
	# _bot_physics is also skipped (foreign authority), so we tick the rifle
	# cooldown + reload completion ourselves.
	var rc: float = float(_shooter.rifle_cooldown)
	rc = maxf(0.0, rc - delta)
	_shooter.set("rifle_cooldown", rc)
	if bool(_shooter.reloading) and rc <= 0.0:
		_shooter.set("mag", _shooter.weapon.get_mag_size())
		_shooter.set("reloading", false)
	# Fire if held: mirrors the input branch in player.gd:_input_impl but skips
	# the MOUSE_MODE_CAPTURED gate (we want to fire while the UI is visible).
	if _firing and rc <= 0.0 and int(_shooter.mag) > 0 and not bool(_shooter.reloading):
		_shooter.set("rifle_cooldown", _shooter.weapon.get_fire_interval())
		_shooter.set("mag", int(_shooter.mag) - 1)
		_shooter.call("_fire_rifle")
		if int(_shooter.mag) <= 0:
			_shooter.call("_start_reload")

# -------------------- UI --------------------

func _build_ui() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)
	# Compact heads-up: mode + ammo + position. Rendered top-right so it stays
	# out of the card panel.
	_hud_label = Label.new()
	_hud_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_hud_label.position = Vector2(-360.0, 10.0)
	_hud_label.size = Vector2(350.0, 100.0)
	_hud_label.add_theme_font_size_override("font_size", 13)
	_hud_label.add_theme_color_override("font_color", Color(1, 1, 1))
	_hud_label.text = ""
	canvas.add_child(_hud_label)
	_build_card_panel(canvas)

func _build_card_panel(canvas: CanvasLayer) -> void:
	_card_panel = PanelContainer.new()
	_card_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_card_panel.position = Vector2(10.0, 10.0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.78)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	_card_panel.add_theme_stylebox_override("panel", sb)
	canvas.add_child(_card_panel)
	# Outer column: title + scroll(cards) + footer(stats).
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 6)
	_card_panel.add_child(outer)
	var title := Label.new()
	title.text = "GUN LAB — F1 hide  ·  TAB FPV  ·  SPACE fire  ·  R reload  ·  RMB look"
	title.add_theme_font_size_override("font_size", 12)
	title.add_theme_color_override("font_color", Color(1, 0.95, 0.6))
	outer.add_child(title)
	# Reset row.
	var reset_row := HBoxContainer.new()
	reset_row.add_theme_constant_override("separation", 8)
	outer.add_child(reset_row)
	var reset_btn := Button.new()
	reset_btn.text = "Reset weapon"
	reset_btn.focus_mode = Control.FOCUS_NONE
	reset_btn.pressed.connect(_reset_weapon)
	reset_row.add_child(reset_btn)
	var fire_btn := Button.new()
	fire_btn.text = "Fire (single)"
	fire_btn.focus_mode = Control.FOCUS_NONE
	fire_btn.pressed.connect(_fire_once)
	reset_row.add_child(fire_btn)
	# Listener-position presets — quick A/B between standard hearing positions.
	var preset_row := HBoxContainer.new()
	preset_row.add_theme_constant_override("separation", 6)
	outer.add_child(preset_row)
	var preset_lbl := Label.new()
	preset_lbl.text = "Listener:"
	preset_lbl.add_theme_font_size_override("font_size", 12)
	preset_lbl.custom_minimum_size = Vector2(60.0, 0.0)
	preset_row.add_child(preset_lbl)
	var target_btn := Button.new()
	target_btn.text = "Target"
	target_btn.tooltip_text = "Down-range, where the shot lands"
	target_btn.focus_mode = Control.FOCUS_NONE
	target_btn.pressed.connect(_listener_to_target)
	preset_row.add_child(target_btn)
	var shooter_btn := Button.new()
	shooter_btn.text = "Shooter"
	shooter_btn.tooltip_text = "FPV — at the shooter's eye"
	shooter_btn.focus_mode = Control.FOCUS_NONE
	shooter_btn.pressed.connect(_listener_to_shooter)
	preset_row.add_child(shooter_btn)
	var spec_btn := Button.new()
	spec_btn.text = "Spectator"
	spec_btn.tooltip_text = "Off to the side, watching the bullet path"
	spec_btn.focus_mode = Control.FOCUS_NONE
	spec_btn.pressed.connect(_listener_to_spectator)
	preset_row.add_child(spec_btn)
	var gun_btn := Button.new()
	gun_btn.text = "Gun side"
	gun_btn.tooltip_text = "Close-up beside the muzzle — inspect the gun visually"
	gun_btn.focus_mode = Control.FOCUS_NONE
	gun_btn.pressed.connect(_listener_to_gun_side)
	preset_row.add_child(gun_btn)
	# Card list (scrollable so it survives any number of cards).
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(360.0, 360.0)
	outer.add_child(scroll)
	var cards_vb := VBoxContainer.new()
	cards_vb.add_theme_constant_override("separation", 2)
	cards_vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(cards_vb)
	# Sort rare cards to the top — same ordering as game.gd's dev panel.
	var sorted_cards: Array = CardLibrary.all().duplicate()
	sorted_cards.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ra: int = 0 if str(a.get("rarity", "common")) == "rare" else 1
		var rb: int = 0 if str(b.get("rarity", "common")) == "rare" else 1
		if ra != rb:
			return ra < rb
		return str(a.get("name", "")) < str(b.get("name", "")))
	for card in sorted_cards:
		_add_card_row(cards_vb, card)
	# Stats footer.
	_stats_label = Label.new()
	_stats_label.text = ""
	_stats_label.add_theme_font_size_override("font_size", 11)
	_stats_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	_stats_label.custom_minimum_size = Vector2(360.0, 0.0)
	outer.add_child(_stats_label)
	_refresh_stats()

func _add_card_row(vb: VBoxContainer, card: Dictionary) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	vb.add_child(row)
	var btn := Button.new()
	btn.text = "+"
	btn.focus_mode = Control.FOCUS_NONE
	btn.custom_minimum_size = Vector2(28.0, 0.0)
	btn.pressed.connect(_apply_card.bind(str(card.get("id", ""))))
	row.add_child(btn)
	var name_lbl := Label.new()
	name_lbl.text = str(card.get("name", "?"))
	var rare := str(card.get("rarity", "common")) == "rare"
	name_lbl.add_theme_color_override("font_color", Color(1, 0.7, 1) if rare else Color(0.9, 0.9, 0.9))
	name_lbl.add_theme_font_size_override("font_size", 12)
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_lbl)

func _apply_card(card_id: String) -> void:
	if _shooter and _shooter.has_method("apply_card"):
		_shooter.call("apply_card", card_id)
		_refresh_stats()

func _reset_weapon() -> void:
	if _shooter and _shooter.has_method("reset_weapon"):
		_shooter.call("reset_weapon")
		_refresh_stats()

# Down-range listener — what a target hears when the shooter fires at them.
func _listener_to_target() -> void:
	_exit_fpv_for_preset()
	_teleport_listener(TARGET_POS, SHOOTER_POS)

# FPV — at the shooter's eye. Reuses the TAB-toggle path so audio + HUD stay
# consistent.
func _listener_to_shooter() -> void:
	_set_fpv(true)

# Off to the side, watching the bullet's path — like an observer/cameraman.
func _listener_to_spectator() -> void:
	_exit_fpv_for_preset()
	_teleport_listener(SPECTATOR_POS, SPECTATOR_LOOK_AT)

# Side close-up — inspect muzzle flash + reload anims from a near-field
# bystander angle. Useful for visual gun-tuning.
func _listener_to_gun_side() -> void:
	_exit_fpv_for_preset()
	_teleport_listener(GUN_SIDE_POS, GUN_SIDE_LOOK_AT)

# A non-FPV preset was clicked while we're in FPV — go through _set_fpv(false)
# so the body model, name label, and player_id all reset cleanly. We don't
# want the saved-position restore to happen here (the preset is going to set
# its own position immediately), so suppress it for this call.
func _exit_fpv_for_preset() -> void:
	if not _fpv:
		return
	_set_fpv(false)

# Helper: place the free-cam at `pos` and orient it toward `look_target`,
# syncing _yaw/_pitch so subsequent mouse-look picks up where look_at left off.
func _teleport_listener(pos: Vector3, look_target: Vector3) -> void:
	_free_cam.global_position = pos
	_free_cam.look_at(look_target, Vector3.UP)
	_yaw = _free_cam.rotation.y
	_pitch = _free_cam.rotation.x
	_update_hud()

func _fire_once() -> void:
	if _shooter == null:
		return
	var rc: float = float(_shooter.rifle_cooldown)
	if rc > 0.0 or int(_shooter.mag) <= 0 or bool(_shooter.reloading):
		return
	_shooter.set("rifle_cooldown", _shooter.weapon.get_fire_interval())
	_shooter.set("mag", int(_shooter.mag) - 1)
	_shooter.call("_fire_rifle")
	if int(_shooter.mag) <= 0:
		_shooter.call("_start_reload")

func _refresh_stats() -> void:
	if _stats_label == null or _shooter == null:
		return
	var w: Weapon = _shooter.weapon
	if w == null:
		_stats_label.text = "(no weapon)"
		return
	_stats_label.text = (
		"dmg %.1f  ·  fire %.3fs  ·  mag %d  ·  reload %.2fs  ·  spread %.2f°  ·  bullet ×%.2f speed ×%.2f"
		% [w.get_damage(), w.get_fire_interval(), w.get_mag_size(), w.get_reload_time(),
			rad_to_deg(w.spread), w.bullet_scale, w.bullet_speed_mult]
	)

func _update_hud() -> void:
	if _hud_label == null or _shooter == null:
		return
	var listener_pos: Vector3 = _free_cam.global_position
	var muzzle_pos: Vector3 = (_shooter.muzzle.global_position
		if _shooter.muzzle else _shooter.global_position)
	var dist: float = listener_pos.distance_to(muzzle_pos)
	var mode: String = "FPV" if _fpv else "FREE"
	var mag: int = int(_shooter.mag)
	var reloading: bool = bool(_shooter.reloading)
	_hud_label.text = (
		"[%s]  dist %.1fm  ·  mag %d%s\nlistener (%.1f, %.1f, %.1f)"
		% [mode, dist, mag, "  RELOAD" if reloading else "",
			listener_pos.x, listener_pos.y, listener_pos.z]
	)
