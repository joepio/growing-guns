extends Node

# Local couch-coop splitscreen. Each gamepad that presses X spawns its own
# Player + camera + viewport in a quadrant. Toggled on via NetworkManager
# metadata (`splitscreen_on_start`) before the Game scene loads.
#
# This script lives as a child of the Game node. All cross-system actions
# (spawn / despawn / scoreboards / state transitions) go through `_game`.
# RPC declarations stay on Game so the network contract doesn't change.

const SPLIT_PLAYER_ID_BASE := 10000
# Mirrors Game.State.WAITING. Kept inline as a plain int so this manager
# doesn't depend on Game gaining a class_name (which requires an editor
# rescan to register globally and breaks headless boot).
const _STATE_WAITING := 0

var _game: Node = null
var _enabled: bool = false

var _layer: CanvasLayer = null
var _grid: Control = null
var _join_label: Label = null
var _pause_menu: Control = null
var _pause_device: int = -1
var _players_by_device: Dictionary = {}  # device int → player_id
var _views_by_player: Dictionary = {}    # player_id → {container, viewport, camera}


func setup(game: Node) -> void:
	_game = game


func is_enabled() -> bool:
	return _enabled


func _ready() -> void:
	_enabled = NetworkManager.has_meta("splitscreen_on_start") \
		and NetworkManager.get_meta("splitscreen_on_start")
	if _enabled:
		_build_layer()
		# Defer until Game's _ready has finished wiring up players_root etc.
		update_views.call_deferred()


func _process(_delta: float) -> void:
	if _enabled:
		_update_cameras()


# Returns true if the event was consumed.
func handle_input(event: InputEvent) -> bool:
	if not _enabled:
		return false
	if not (event is InputEventJoypadButton) or not event.pressed:
		return false
	var device := event.device
	if _pause_menu and _pause_menu.visible and device == _pause_device:
		if event.button_index == JOY_BUTTON_B:
			_close_pause_menu()
			return true
		if event.button_index == JOY_BUTTON_X or event.button_index == JOY_BUTTON_A:
			_leave_player(device)
			_close_pause_menu()
			return true
	if event.button_index == JOY_BUTTON_X and not _players_by_device.has(device):
		_join_player(device)
		return true
	if event.button_index == JOY_BUTTON_START and _players_by_device.has(device):
		_open_pause_menu(device)
		return true
	return false


# Total non-bot players currently in the match. Used by Game's lobby checks
# and by the leave-player flow ("if we drop below 2, go back to WAITING").
func active_match_player_count() -> int:
	var count := 0
	for pid in NetworkManager.players:
		if not _is_bot_id(int(pid)):
			count += 1
	return count


func update_views() -> void:
	if not _grid:
		return
	var ids := _local_player_ids()
	for id in ids:
		if not _views_by_player.has(id):
			_create_view(id)
	for id in _views_by_player.keys():
		if not ids.has(int(id)):
			_remove_view(int(id))

	var n := ids.size()
	_join_label.visible = n < 4
	var rect := _grid.get_rect()
	for i in range(n):
		var id := ids[i]
		var view: Dictionary = _views_by_player[id]
		var container: SubViewportContainer = view.container
		var viewport: SubViewport = view.viewport
		var slot := _slot_rect(i, n, rect.size)
		container.position = slot.position
		container.size = slot.size
		viewport.size = Vector2i(maxi(1, int(slot.size.x)), maxi(1, int(slot.size.y)))


# ── Internals ──────────────────────────────────────────────────────────────

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
	_join_label.text = "PRESS X TO JOIN"
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


func _join_player(device: int) -> void:
	if not multiplayer.is_server() or _players_by_device.has(device):
		return
	var id := SPLIT_PLAYER_ID_BASE + device
	var suffix := _players_by_device.size() + 2
	var pname := "P%d" % suffix
	NetworkManager.players[id] = pname
	_game.round_wins[id] = 0
	_game._do_spawn.rpc(id, pname, _game._random_spawn(_game._current_player_positions()), false, device, true)
	_game._broadcast_scores.rpc(_game.round_wins)
	_game._maybe_start_match()
	_game._update_scoreboard()
	_players_by_device[device] = id


func _leave_player(device: int) -> void:
	if not multiplayer.is_server() or not _players_by_device.has(device):
		return
	var id := int(_players_by_device[device])
	_players_by_device.erase(device)
	_remove_view(id)
	_game._despawn.rpc(id)
	NetworkManager.players.erase(id)
	_game.round_wins.erase(id)
	_game.pending_pick_cards_by_player.erase(id)
	_game.completed_picks.erase(id)
	_game.eliminated_players.erase(id)
	if _game.pending_picker_id == id:
		_game.pending_picker_id = 0
		_game.pending_pick_cards.clear()
		_game._hide_card_pick.rpc_id(1)
	_game._broadcast_scores.rpc(_game.round_wins)
	_game._update_scoreboard()
	update_views()
	if active_match_player_count() < 2:
		_game.state = _STATE_WAITING
		_game._announce.rpc("PRESS X TO JOIN", 99.0)


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


func _slot_rect(index: int, count: int, size: Vector2) -> Rect2:
	if count <= 1:
		return Rect2(Vector2.ZERO, size)
	if count == 2:
		var w := size.x * 0.5
		return Rect2(Vector2(w * index, 0.0), Vector2(w, size.y))
	var w2 := size.x * 0.5
	var h2 := size.y * 0.5
	return Rect2(Vector2(w2 * float(index % 2), h2 * float(index / 2)), Vector2(w2, h2))


func _create_view(id: int) -> void:
	var container := SubViewportContainer.new()
	container.stretch = true
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_grid.add_child(container)

	var viewport := SubViewport.new()
	viewport.disable_3d = false
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.world_3d = get_viewport().world_3d
	container.add_child(viewport)

	var camera := Camera3D.new()
	camera.current = true
	viewport.add_child(camera)
	_views_by_player[id] = {"container": container, "viewport": viewport, "camera": camera}


func _remove_view(id: int) -> void:
	if not _views_by_player.has(id):
		return
	var view: Dictionary = _views_by_player[id]
	var container: Node = view.container
	if is_instance_valid(container):
		container.queue_free()
	_views_by_player.erase(id)


func _update_cameras() -> void:
	update_views()
	for id in _views_by_player.keys():
		var player: Node = _game.players_root.get_node_or_null(str(id))
		if player == null:
			continue
		var source := player.get_node_or_null("Camera") as Camera3D
		if source == null:
			continue
		var view: Dictionary = _views_by_player[id]
		var camera: Camera3D = view.camera
		camera.global_transform = source.global_transform
		camera.fov = source.fov


func _build_pause_menu() -> void:
	_pause_menu = PanelContainer.new()
	_pause_menu.visible = false
	_pause_menu.mouse_filter = Control.MOUSE_FILTER_STOP
	_pause_menu.set_anchors_preset(Control.PRESET_CENTER)
	_pause_menu.offset_left = -170.0
	_pause_menu.offset_top = -78.0
	_pause_menu.offset_right = 170.0
	_pause_menu.offset_bottom = 78.0
	_layer.add_child(_pause_menu)

	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 10)
	_pause_menu.add_child(vb)

	var title := Label.new()
	title.name = "Title"
	title.text = "PLAYER MENU"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 18)
	vb.add_child(title)

	var hint := Label.new()
	hint.text = "A/X LEAVE   B RESUME"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 13)
	vb.add_child(hint)


func _open_pause_menu(device: int) -> void:
	_pause_device = device
	_pause_menu.visible = true


func _close_pause_menu() -> void:
	_pause_device = -1
	if _pause_menu:
		_pause_menu.visible = false


# Lazy-mirrors Game's bot-id check (kept inline so this manager doesn't
# depend on Game._is_bot_id signature).
func _is_bot_id(pid: int) -> bool:
	return pid >= 9000 and pid < 9100
