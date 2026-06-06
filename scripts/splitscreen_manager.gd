extends Node

const RENDER_PLAYER_SCRIPT := preload("res://scripts/render_player.gd")
const SPLIT_PLAYER_ID_BASE := 10000
# Reserved player ID for the keyboard/mouse splitscreen joiner (device == -1).
# Sits well past any plausible controller index so it can't collide with a
# controller-derived ID at SPLIT_PLAYER_ID_BASE + device.
const KEYBOARD_PLAYER_ID := SPLIT_PLAYER_ID_BASE + 999
const _STATE_WAITING := 0

var _game: Node = null
var _enabled: bool = false
var _layer: CanvasLayer = null
var _grid: Control = null
var _join_label: Label = null
var _pause_menu: Control = null
var _pause_device: int = -1
var _pause_selected: int = 0
var _pause_buttons: Array[Button] = []
var _primary_device: int = -1
var _players_by_device: Dictionary = {}
var _renderers_by_player: Dictionary = {}
# Single AudioListener3D parked at the midpoint of all local players' cameras.
# Each SubViewport has its own current Camera3D (for rendering), but the main
# viewport ends up with no current camera in splitscreen mode — without this
# listener, AudioStreamPlayer3D nodes have no reference point and play flat.
var _audio_listener: AudioListener3D = null


func setup(game: Node) -> void:
	_game = game


func is_enabled() -> bool:
	return _enabled


func enable(primary_device: int = -1) -> void:
	_set_primary_device(primary_device)
	if _enabled:
		update_views()
		return
	_enabled = true
	NetworkManager.set_meta("splitscreen_on_start", true)
	if _game and _game.has_method("_clear_render_players"):
		_game._clear_render_players()
	_build_layer()
	_setup_audio_listener()
	update_views.call_deferred()


func _ready() -> void:
	_enabled = NetworkManager.has_meta("splitscreen_on_start") \
		and NetworkManager.get_meta("splitscreen_on_start")
	if _enabled:
		_build_layer()
		_setup_audio_listener()
		_set_primary_device(int(NetworkManager.get_meta("splitscreen_primary_device", -1)))
		update_views.call_deferred()


func _process(_delta: float) -> void:
	if _enabled:
		update_views()
		_update_audio_listener()


func handle_input(event: InputEvent) -> bool:
	if not _enabled:
		return false
	for renderer in _renderers_by_player.values():
		if renderer.handle_input(event):
			return true
	# Mouse-click join — only available when the primary is on a controller
	# (so the mouse is otherwise unused for gameplay), no mouse player has
	# joined yet, and there is no card pick in progress (clicks during card
	# pick must reach the card buttons via _gui_input).
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT \
			and _primary_device >= 0 \
			and _player_for_device(-1) == 0 \
			and not is_card_pick_visible():
		_join_player(-1)
		return true
	if not (event is InputEventJoypadButton) or not event.pressed:
		return false
	var device := event.device
	if _pause_menu and _pause_menu.visible and device == _pause_device:
		if event.button_index == JOY_BUTTON_B or event.button_index == JOY_BUTTON_START:
			_close_pause_menu()
			return true
		if event.button_index == JOY_BUTTON_DPAD_UP or event.button_index == JOY_BUTTON_DPAD_LEFT:
			_select_pause_option(_pause_selected - 1)
			return true
		if event.button_index == JOY_BUTTON_DPAD_DOWN or event.button_index == JOY_BUTTON_DPAD_RIGHT:
			_select_pause_option(_pause_selected + 1)
			return true
		if event.button_index == JOY_BUTTON_A or event.button_index == JOY_BUTTON_X:
			_activate_pause_option()
			return true
	if event.button_index == JOY_BUTTON_X and device != _primary_device and _player_for_device(device) == 0:
		_join_player(device)
		return true
	if event.button_index == JOY_BUTTON_START and _player_for_device(device) != 0:
		_open_pause_menu(device)
		return true
	return false


func active_match_player_count() -> int:
	var count := 0
	for pid in NetworkManager.players:
		if not _is_bot_id(int(pid)):
			count += 1
	return count


func show_card_pick(player_id: int, card_ids: Array) -> bool:
	var renderer := _renderers_by_player.get(player_id) as RenderPlayer
	if renderer == null:
		return false
	renderer.show_card_pick(card_ids)
	return true


func hide_card_pick(player_id: int) -> bool:
	var renderer := _renderers_by_player.get(player_id) as RenderPlayer
	if renderer == null:
		return false
	renderer.hide_card_pick()
	return true


func is_card_pick_visible() -> bool:
	for renderer in _renderers_by_player.values():
		if renderer.is_card_pick_visible():
			return true
	return false


func is_card_pick_visible_for(player_id: int) -> bool:
	var renderer := _renderers_by_player.get(player_id) as RenderPlayer
	if renderer == null:
		return false
	return renderer.is_card_pick_visible()


func show_hitmarker_for(player_id: int, kind: String) -> bool:
	var renderer := _renderers_by_player.get(player_id) as RenderPlayer
	if renderer == null:
		return false
	renderer.show_hitmarker(kind)
	return true


func show_pickup_collected_for(player_id: int, kind: String) -> bool:
	var renderer := _renderers_by_player.get(player_id) as RenderPlayer
	if renderer == null:
		return false
	renderer.show_pickup_toast(kind)
	return true


func show_damage_direction_for(player_id: int, from_pos: Vector3) -> bool:
	var renderer := _renderers_by_player.get(player_id) as RenderPlayer
	if renderer == null:
		return false
	renderer.show_damage_direction(from_pos)
	return true


func show_death_effect_for(player_id: int, show: bool) -> bool:
	var renderer := _renderers_by_player.get(player_id) as RenderPlayer
	if renderer == null:
		return false
	renderer.show_death_effect(show)
	return true


func update_views() -> void:
	if not _grid:
		return
	var ids := _local_player_ids()
	for id in ids:
		if not _renderers_by_player.has(id):
			_create_renderer(id)
	for id in _renderers_by_player.keys():
		if not ids.has(int(id)):
			_remove_renderer(int(id))

	var n := ids.size()
	_join_label.visible = n < 4
	var rect := _grid.get_rect()
	for i in range(n):
		var id := ids[i]
		var renderer := _renderers_by_player[id] as RenderPlayer
		var slot := _slot_rect(i, n, rect.size)
		renderer.position = slot.position
		renderer.size = slot.size
		renderer.layout_for_size(slot.size)


func _setup_audio_listener() -> void:
	if _audio_listener != null and is_instance_valid(_audio_listener):
		return
	if _game == null:
		return
	_audio_listener = AudioListener3D.new()
	_audio_listener.name = "SplitscreenAudioListener"
	_game.add_child(_audio_listener)
	_audio_listener.make_current()


func _update_audio_listener() -> void:
	# Anchor the listener at the host-primary's camera (full transform — basis
	# matters so directional pan tracks where the host is looking). Each
	# additional local player's perspective is folded into the same audio
	# output via "ghost" sources at shifted positions (see ghost_positions_for
	# below) — that gave a cleaner result than averaging the listener.
	if _audio_listener == null or not is_instance_valid(_audio_listener):
		return
	var cam := _host_primary_camera()
	if cam == null:
		return
	_audio_listener.global_transform = cam.global_transform


func _host_primary_camera() -> Camera3D:
	if _game == null:
		return null
	var host_id := multiplayer.get_unique_id()
	var host_player := _game.players_root.get_node_or_null(str(host_id)) as Node3D
	if host_player == null:
		return null
	return host_player.get_node_or_null("Camera") as Camera3D


# For a sound at `world_pos`, return one shifted world position per non-primary
# local player such that, when played through the host-anchored listener, it
# sounds the way that secondary player would have heard the original source.
# Math: take the listener-local vector from secondary→source, then re-project
# it into host-listener space (host_origin + host_basis * v_local).
func ghost_positions_for(world_pos: Vector3) -> Array[Vector3]:
	var out: Array[Vector3] = []
	if not _enabled:
		return out
	var host_cam := _host_primary_camera()
	if host_cam == null:
		return out
	var host_xform := host_cam.global_transform
	var host_id := multiplayer.get_unique_id()
	for id in _local_player_ids():
		if id == host_id:
			continue
		var p := _game.players_root.get_node_or_null(str(id)) as Node3D
		if p == null:
			continue
		var p_cam := p.get_node_or_null("Camera") as Camera3D
		if p_cam == null:
			continue
		var p_xform := p_cam.global_transform
		var v_local: Vector3 = p_xform.basis.inverse() * (world_pos - p_xform.origin)
		out.append(host_xform.origin + host_xform.basis * v_local)
	return out


func _set_primary_device(device: int) -> void:
	_primary_device = device
	NetworkManager.set_meta("splitscreen_primary_device", device)
	_refresh_join_label()
	if _game == null:
		return
	var primary_id := multiplayer.get_unique_id()
	var player: Node = _game.players_root.get_node_or_null(str(primary_id))
	if player:
		player.set("split_screen_local", true)
		player.set("local_input_device", device)
		if player.has_method("_apply_ghost_visuals"):
			player._apply_ghost_visuals()


# Surface the prompt the host should see while waiting on extra players —
# also used by game.gd for the centered _announce banner.
func join_prompt_text() -> String:
	if _primary_device >= 0 and DisplayServer.has_feature(DisplayServer.FEATURE_MOUSE):
		return "PRESS X OR CLICK MOUSE TO JOIN"
	return "PRESS X TO JOIN"


func _refresh_join_label() -> void:
	if _join_label == null:
		return
	_join_label.text = join_prompt_text()


func _build_layer() -> void:
	if _layer:
		return
	_layer = CanvasLayer.new()
	_layer.layer = 0
	add_child(_layer)

	_grid = Control.new()
	_grid.name = "SplitScreenGrid"
	_grid.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(_grid)
	_grid.resized.connect(update_views)

	_join_label = Label.new()
	_join_label.name = "JoinPrompt"
	_join_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_join_label.text = join_prompt_text()
	_join_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_join_label.add_theme_font_size_override("font_size", 22)
	_join_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.45))
	_join_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_join_label.add_theme_constant_override("outline_size", 8)
	_join_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_join_label.offset_top = 18.0
	_join_label.offset_bottom = 48.0
	_layer.add_child(_join_label)
	_build_pause_menu()


func _create_renderer(id: int) -> void:
	var renderer := RENDER_PLAYER_SCRIPT.new() as RenderPlayer
	renderer.name = "RenderPlayer_%d" % id
	_grid.add_child(renderer)
	var device := _device_for_player(id)
	renderer.setup(_game, id, device)
	renderer.card_selected.connect(_game._on_render_player_card_selected)
	_renderers_by_player[id] = renderer


func _remove_renderer(id: int) -> void:
	var renderer := _renderers_by_player.get(id) as Node
	if renderer and is_instance_valid(renderer):
		renderer.queue_free()
	_renderers_by_player.erase(id)


func _device_for_player(id: int) -> int:
	if id == multiplayer.get_unique_id():
		return _primary_device
	for device in _players_by_device:
		if int(_players_by_device[device]) == id:
			return int(device)
	return -1


func _player_for_device(device: int) -> int:
	if device == _primary_device and device >= 0:
		return multiplayer.get_unique_id()
	if _players_by_device.has(device):
		return int(_players_by_device[device])
	return 0


func _join_player(device: int) -> void:
	if not multiplayer.is_server() or _players_by_device.has(device):
		return
	var id := KEYBOARD_PLAYER_ID if device < 0 else SPLIT_PLAYER_ID_BASE + device
	var suffix := _players_by_device.size() + 2
	var pname := "P%d" % suffix
	NetworkManager.players[id] = pname
	_game.round_wins[id] = 0
	_players_by_device[device] = id
	var pick: Dictionary = _game._pick_spawn(_game._current_player_positions())
	_game._do_spawn.rpc(id, pname, pick["pos"], false, device, true, pick["yaw"])
	_game._broadcast_scores.rpc(_game.round_wins)
	_game._maybe_start_match()
	_game._update_scoreboard()
	update_views()


func _leave_player(device: int) -> void:
	if not multiplayer.is_server():
		return
	var id := _player_for_device(device)
	if id == 0:
		return
	if device == _primary_device:
		_primary_device = -1
		NetworkManager.set_meta("splitscreen_primary_device", -1)
	else:
		_players_by_device.erase(device)
	_remove_renderer(id)
	_game._despawn.rpc(id)
	NetworkManager.players.erase(id)
	_game.round_wins.erase(id)
	_game.pending_pick_cards_by_player.erase(id)
	_game.completed_picks.erase(id)
	_game.eliminated_players.erase(id)
	if _game.pending_picker_id == id:
		_game.pending_picker_id = 0
		_game.pending_pick_cards.clear()
		_game._hide_card_pick_for.rpc_id(1, id)
	_game._broadcast_scores.rpc(_game.round_wins)
	_game._update_scoreboard()
	update_views()
	if active_match_player_count() < 2:
		_game.state = _STATE_WAITING
		# Don't blast the central banner — _join_label already prompts at the
		# top while there are open splitscreen slots.


func _local_player_ids() -> Array[int]:
	var ids: Array[int] = []
	var primary_id := multiplayer.get_unique_id()
	if _game.players_root.has_node(str(primary_id)):
		ids.append(primary_id)
	for child in _game.players_root.get_children():
		if bool(child.get("split_screen_local")):
			var pid := int(child.get("player_id"))
			if not ids.has(pid):
				ids.append(pid)
	ids.sort()
	return ids


func _slot_rect(index: int, count: int, view_size: Vector2) -> Rect2:
	if count <= 1:
		return Rect2(Vector2.ZERO, view_size)
	if count == 2:
		var w := view_size.x * 0.5
		return Rect2(Vector2(w * index, 0.0), Vector2(w, view_size.y))
	var w2 := view_size.x * 0.5
	var h2 := view_size.y * 0.5
	return Rect2(Vector2(w2 * float(index % 2), h2 * float(index / 2)), Vector2(w2, h2))


func _build_pause_menu() -> void:
	_pause_menu = PanelContainer.new()
	_pause_menu.visible = false
	_pause_menu.mouse_filter = Control.MOUSE_FILTER_STOP
	_pause_menu.set_anchors_preset(Control.PRESET_CENTER)
	_pause_menu.offset_left = -170.0
	_pause_menu.offset_top = -92.0
	_pause_menu.offset_right = 170.0
	_pause_menu.offset_bottom = 92.0
	_layer.add_child(_pause_menu)

	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 10)
	_pause_menu.add_child(vb)

	var title := Label.new()
	title.text = "PLAYER MENU"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 18)
	vb.add_child(title)

	var hint := Label.new()
	hint.text = "A SELECT   B RESUME"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 13)
	vb.add_child(hint)

	_pause_buttons.clear()
	for label_text in ["RESUME", "LEAVE"]:
		var btn := Button.new()
		btn.text = label_text
		btn.focus_mode = Control.FOCUS_NONE
		btn.custom_minimum_size = Vector2(210, 34)
		vb.add_child(btn)
		_pause_buttons.append(btn)


func _open_pause_menu(device: int) -> void:
	_pause_device = device
	_select_pause_option(0)
	_pause_menu.visible = true


func _close_pause_menu() -> void:
	_pause_device = -1
	if _pause_menu:
		_pause_menu.visible = false


func _select_pause_option(index: int) -> void:
	if _pause_buttons.is_empty():
		return
	_pause_selected = posmod(index, _pause_buttons.size())
	for i in range(_pause_buttons.size()):
		var btn := _pause_buttons[i]
		btn.text = ("> %s <" if i == _pause_selected else "  %s  ") % (["RESUME", "LEAVE"][i])


func _activate_pause_option() -> void:
	if _pause_selected == 0:
		_close_pause_menu()
		return
	var device := _pause_device
	_close_pause_menu()
	_leave_player(device)


func _is_bot_id(pid: int) -> bool:
	return pid >= 9000 and pid < 9100
