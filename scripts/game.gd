extends Node3D

const PLAYER_SCENE := preload("res://scenes/player.tscn")

enum State { WAITING, PLAYING, PICKING_CARD, MATCH_OVER }

const ROUNDS_TO_WIN := 10
const CARDS_PER_PICK := 3
const SPAWN_CAPSULE_RADIUS := 0.4
const SPAWN_CAPSULE_HEIGHT := 1.8
const BOT_ID := 9999
const BOT_NAME := "BOT"
const SPAWN_MIN_SPACING := 8.0   # meters — two fresh spawns must be at least this far apart

@onready var players_root: Node3D = $Players
@onready var health_label: Label = $HUD/HealthPanel/HealthLabel
@onready var scoreboard: Label = $HUD/Scoreboard
@onready var hitmarker: Control = $HUD/Hitmarker
@onready var damage_indicator: Control = $HUD/DamageIndicator
@onready var rifle_bar: ProgressBar = $HUD/AbilityBar/Rifle/Bar
@onready var grenade_bar: ProgressBar = $HUD/AbilityBar/Grenade/Bar
@onready var grenade_label: Label = $HUD/AbilityBar/Grenade/Label
@onready var melee_bar: ProgressBar = $HUD/AbilityBar/Melee/Bar
@onready var dash_bar: ProgressBar = $HUD/AbilityBar/Dash/Bar
@onready var round_banner: Label = $HUD/RoundBanner
@onready var banner_timer: Timer = $HUD/BannerTimer
@onready var pick_overlay: Control = $HUD/CardPickOverlay
@onready var pick_title: Label = $HUD/CardPickOverlay/Center/VBox/Title
@onready var pick_subtitle: Label = $HUD/CardPickOverlay/Center/VBox/Subtitle
@onready var pick_row: HBoxContainer = $HUD/CardPickOverlay/Center/VBox/CardRow

var state: int = State.WAITING
var round_wins: Dictionary = {}
var current_round: int = 1
var pending_pick_cards: Array = []
var pending_picker_id: int = 0
var pending_pick_cards_by_player: Dictionary = {}
var completed_picks: Dictionary = {}
var eliminated_players: Dictionary = {}
var round_winner_id: int = 0
var local_player: Node3D

# --- Match over / rematch ---
var _rematch_overlay: Control = null
var _rematch_title: Label = null
var _rematch_subtitle: Label = null
var _rematch_button: Button = null
var _rematch_requested: bool = false

# --- Dev panel (F1) ---
var _dev_root: PanelContainer = null
var _dev_content: VBoxContainer

# --- Pause menu (ESC) ---
var _pause_menu: Control = null
var _ghost_overlay: Control = null
var _ghost_label: Label = null

func _ready() -> void:
	# No menu — bootstrap networking on the fly. First launcher hosts, later
	# launches fall back to client. Note: Godot 4 installs a default
	# OfflineMultiplayerPeer so a plain null check isn't enough — we have to
	# check for a real ENet peer.
	if multiplayer.multiplayer_peer == null \
			or multiplayer.multiplayer_peer is OfflineMultiplayerPeer:
		var auto_name := "Player_%d" % (randi() % 1000)
		if not NetworkManager.auto_connect(auto_name):
			push_error("Could not start or join a game.")
			return

	NetworkManager.player_list_changed.connect(_update_scoreboard)
	banner_timer.timeout.connect(func() -> void: round_banner.visible = false)
	pick_overlay.visible = false
	round_banner.visible = false
	_build_rematch_overlay()
	_build_ghost_overlay()

	if multiplayer.is_server():
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
		for pid in NetworkManager.players:
			round_wins[pid] = 0
			_spawn_player(pid, NetworkManager.players[pid])
		_maybe_start_match()
		# SP fallback: if nobody else has joined yet, give us a bot to fight.
		_maybe_spawn_bot.call_deferred()
	else:
		# Instantly show the client state — makes it obvious when you thought
		# you were solo but actually joined an orphan on port 27015.
		round_banner.text = "CONNECTING TO HOST…"
		round_banner.visible = true
		banner_timer.stop()
		_client_request_spawn_when_ready()

	_update_scoreboard()

func _client_request_spawn_when_ready() -> void:
	# The scene change happens before `connected_to_server` fires, so the
	# client can reach _ready with a peer that isn't fully connected yet.
	# RPCs sent in that window are dropped silently — wait for the signal.
	var peer := multiplayer.multiplayer_peer
	if peer and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		_request_spawn.rpc_id(1, NetworkManager.local_player_name)
		return
	multiplayer.connected_to_server.connect(
		func() -> void: _request_spawn.rpc_id(1, NetworkManager.local_player_name),
		CONNECT_ONE_SHOT,
	)

func _process(_delta: float) -> void:
	if local_player and is_instance_valid(local_player):
		health_label.text = "GHOST" if local_player.get("ghost_mode") == true else "HP  %d" % local_player.health
		_refresh_cooldowns()
		_update_ghost_overlay()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F1:
		_toggle_dev_panel()
		return
	if event.is_action_pressed("ui_cancel"):
		if _dev_root and _dev_root.visible:
			_toggle_dev_panel()
			return
		_toggle_pause_menu()

func _refresh_cooldowns() -> void:
	var w: Weapon = local_player.weapon
	if local_player.get("ghost_mode") == true:
		rifle_bar.value = 0.0
		grenade_bar.value = 1.0 - (local_player.grenade_cooldown / local_player.MINE_RELOAD)
		grenade_label.text = "LMB  MINE"
		melee_bar.value = 0.0
		var ghost_charge_progress: float = local_player.dash_recharge_timer / local_player.DASH_RECHARGE_TIME
		dash_bar.value = (float(local_player.dash_charges) + ghost_charge_progress) / float(local_player.MAX_DASH_CHARGES)
		return
	if local_player.reloading:
		rifle_bar.value = 1.0 - (local_player.rifle_cooldown / max(0.01, w.get_reload_time()))
	else:
		rifle_bar.value = float(local_player.mag) / float(w.get_mag_size())
	# The RMB slot hosts multiple specials with different cooldowns. Normalize
	# against the max cooldown of the equipped special so the bar reads right.
	var special_max: float = local_player.GRENADE_RELOAD
	match w.special:
		Weapon.SPECIAL_TELEPORT: special_max = local_player.TELEPORT_RELOAD
		Weapon.SPECIAL_SHIELD:   special_max = local_player.SHIELD_RELOAD
		Weapon.SPECIAL_INVISIBLE: special_max = local_player.INVISIBLE_RELOAD
	grenade_bar.value = 1.0 - (local_player.grenade_cooldown / special_max)
	grenade_label.text = "RMB  %s" % w.special.to_upper()
	melee_bar.value = 1.0 - (local_player.melee_cooldown / local_player.MELEE_RELOAD)
	var charge_progress: float = local_player.dash_recharge_timer / local_player.DASH_RECHARGE_TIME
	dash_bar.value = (float(local_player.dash_charges) + charge_progress) / float(local_player.MAX_DASH_CHARGES)

# -------------------- SPAWN / DESPAWN --------------------

func _on_peer_disconnected(id: int) -> void:
	if not multiplayer.is_server():
		return
	var node := players_root.get_node_or_null(str(id))
	if node:
		_despawn.rpc(id)
	round_wins.erase(id)
	_broadcast_scores.rpc(round_wins)
	if state == State.PICKING_CARD and id == pending_picker_id:
		_hide_card_pick.rpc()
		state = State.PLAYING
	pending_pick_cards_by_player.erase(id)
	completed_picks.erase(id)
	eliminated_players.erase(id)
	if NetworkManager.players.size() < 2:
		state = State.WAITING
		_hide_card_pick.rpc()
		_hide_rematch_overlay.rpc()
		_announce.rpc("WAITING FOR PLAYERS…", 99.0)

@rpc("any_peer", "call_local", "reliable")
func _request_spawn(pname: String) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = 1
	# A real peer is joining — boot the SP bot if one is around.
	_despawn_bot_if_any()
	NetworkManager.players[sender] = pname
	if not round_wins.has(sender):
		round_wins[sender] = 0
	_spawn_player(sender, pname)
	for pid in NetworkManager.players:
		if players_root.has_node(str(pid)) and pid != sender:
			_do_spawn.rpc_id(sender, pid, NetworkManager.players[pid],
				players_root.get_node(str(pid)).global_position)
	_broadcast_scores.rpc(round_wins)
	_maybe_start_match()

func _spawn_player(id: int, pname: String) -> void:
	# Avoid dropping a new player on top of anyone already in the arena.
	var pos := _random_spawn(_current_player_positions())
	_do_spawn.rpc(id, pname, pos)

func _current_player_positions() -> Array[Vector3]:
	var out: Array[Vector3] = []
	for child in players_root.get_children():
		if child is Node3D:
			out.append((child as Node3D).global_position)
	return out

func _random_spawn(avoid: Array[Vector3] = []) -> Vector3:
	var spawns := get_tree().get_nodes_in_group("spawnpoints")
	if spawns.is_empty():
		return Vector3(0, 3, 0)
	spawns.shuffle()
	# Prefer a spawn that's clear of geometry AND far from every used spawn.
	for spawn in spawns:
		var pos: Vector3 = spawn.global_position
		if not _spawn_is_clear(pos):
			continue
		if _too_close_to_any(pos, avoid):
			continue
		return pos
	# Fallback 1: relax spacing but still require physics clearance.
	for spawn in spawns:
		if _spawn_is_clear(spawn.global_position):
			return spawn.global_position
	return spawns[0].global_position

func _too_close_to_any(pos: Vector3, others: Array[Vector3]) -> bool:
	var min_sq := SPAWN_MIN_SPACING * SPAWN_MIN_SPACING
	for o in others:
		if pos.distance_squared_to(o) < min_sq:
			return true
	return false

func _spawn_is_clear(pos: Vector3) -> bool:
	var shape := CapsuleShape3D.new()
	shape.radius = SPAWN_CAPSULE_RADIUS
	shape.height = SPAWN_CAPSULE_HEIGHT
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = Transform3D(Basis.IDENTITY, pos)
	query.collision_mask = 1
	return get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty()

@rpc("authority", "call_local", "reliable")
func _do_spawn(id: int, pname: String, pos: Vector3, bot: bool = false) -> void:
	if players_root.has_node(str(id)):
		return
	var p := PLAYER_SCENE.instantiate()
	p.name = str(id)
	p.player_id = id
	p.is_bot = bot
	p.player_name = pname
	players_root.add_child(p, true)
	# global_position must be set after add_child — it requires being in-tree.
	p.global_position = pos
	if id == multiplayer.get_unique_id():
		local_player = p

@rpc("authority", "call_local", "reliable")
func _despawn(id: int) -> void:
	var node := players_root.get_node_or_null(str(id))
	if node:
		node.queue_free()

# -------------------- SINGLE-PLAYER BOT --------------------

func _maybe_spawn_bot() -> void:
	if not multiplayer.is_server():
		return
	if NetworkManager.players.size() >= 2:
		return
	if players_root.has_node(str(BOT_ID)):
		return
	NetworkManager.players[BOT_ID] = BOT_NAME
	round_wins[BOT_ID] = 0
	NetworkManager.player_list_changed.emit()
	_do_spawn.rpc(BOT_ID, BOT_NAME, _random_spawn(_current_player_positions()), true)
	_broadcast_scores.rpc(round_wins)
	_maybe_start_match()

func _despawn_bot_if_any() -> void:
	if not players_root.has_node(str(BOT_ID)):
		return
	_despawn.rpc(BOT_ID)
	NetworkManager.players.erase(BOT_ID)
	round_wins.erase(BOT_ID)
	NetworkManager.player_list_changed.emit()
	_broadcast_scores.rpc(round_wins)
	if state == State.PICKING_CARD:
		_hide_card_pick.rpc()
	_hide_rematch_overlay.rpc()
	pending_pick_cards_by_player.erase(BOT_ID)
	completed_picks.erase(BOT_ID)
	eliminated_players.erase(BOT_ID)
	state = State.WAITING

# -------------------- ROUND FLOW --------------------

func _maybe_start_match() -> void:
	if not multiplayer.is_server():
		return
	if state != State.WAITING:
		return
	if NetworkManager.players.size() < 2:
		_announce.rpc("WAITING FOR PLAYERS…", 99.0)
		return
	state = State.PLAYING
	current_round = 1
	_reset_round_tracking()
	_start_round_now()

func _start_round_now() -> void:
	_reset_round_tracking()
	# Respawn everyone, reset HP + cooldowns, unfreeze, announce.
	# Track already-assigned spawn positions so nobody lands on top of another.
	var used: Array[Vector3] = []
	for pid in NetworkManager.players:
		var p := players_root.get_node_or_null(str(pid))
		if not p:
			continue
		var pos := _random_spawn(used)
		used.append(pos)
		p.set_ghost_mode.rpc(false)
		p.server_respawn.rpc_id(p.get_multiplayer_authority(), pos)
		p.set_frozen.rpc(false)
		p.clear_ragdoll.rpc()
	_hide_rematch_overlay.rpc()
	_announce.rpc("ROUND %d" % current_round, 1.4)

func _reset_round_tracking() -> void:
	pending_picker_id = 0
	pending_pick_cards.clear()
	pending_pick_cards_by_player.clear()
	completed_picks.clear()
	eliminated_players.clear()
	round_winner_id = 0

func report_kill(killer_id: int, victim_id: int) -> void:
	# Called on the server by Player._report_death. In 3+ player rounds,
	# deaths eliminate players; the last survivor wins the round.
	if not multiplayer.is_server():
		return
	if state != State.PLAYING:
		return
	if eliminated_players.has(victim_id):
		return
	eliminated_players[victim_id] = true
	if killer_id != 0 and killer_id != victim_id:
		var killer_node := players_root.get_node_or_null(str(killer_id))
		if killer_node:
			# Route via authority so server-owned bots receive their own RPC.
			killer_node.confirm_kill.rpc_id(killer_node.get_multiplayer_authority())
	var victim_node := players_root.get_node_or_null(str(victim_id))
	if victim_node:
		victim_node.set_ghost_mode.rpc(true)
	_begin_card_pick_for_loser(victim_id)

	var alive := _alive_player_ids()
	if alive.size() <= 1:
		var winner_id := int(alive[0]) if alive.size() == 1 else _fallback_round_winner(victim_id)
		_end_round(winner_id)

func _alive_player_ids() -> Array[int]:
	var alive: Array[int] = []
	for raw_id in NetworkManager.players:
		var pid := int(raw_id)
		if eliminated_players.has(pid):
			continue
		if not players_root.has_node(str(pid)):
			continue
		alive.append(pid)
	return alive

func _fallback_round_winner(victim_id: int) -> int:
	for raw_id in NetworkManager.players:
		var pid := int(raw_id)
		if pid != victim_id:
			return pid
	return 0

func _end_round(winner_id: int) -> void:
	round_winner_id = winner_id
	if winner_id != 0:
		round_wins[winner_id] = int(round_wins.get(winner_id, 0)) + 1
		_broadcast_scores.rpc(round_wins)
	# Match over?
	if winner_id != 0 and int(round_wins[winner_id]) >= ROUNDS_TO_WIN:
		state = State.MATCH_OVER
		for pid in NetworkManager.players:
			var pn := players_root.get_node_or_null(str(pid))
			if pn:
				pn.set_frozen.rpc(true)
		_match_over.rpc(winner_id)
		return
	# Freeze the survivor and wait for every eliminated player to finish their pick.
	state = State.PICKING_CARD
	for pid in NetworkManager.players:
		var p := players_root.get_node_or_null(str(pid))
		if p:
			p.set_frozen.rpc(true)
	for raw_loser_id in eliminated_players.keys():
		var loser_id := int(raw_loser_id)
		if not completed_picks.has(loser_id) and not pending_pick_cards_by_player.has(loser_id):
			_begin_card_pick_for_loser(loser_id)
		elif completed_picks.has(loser_id):
			_show_spectating.rpc_id(_peer_for_player(loser_id), "WAITING FOR OTHER PICKS…")
	_show_round_winner_wait.rpc(winner_id)
	_maybe_finish_card_picks()

func _begin_card_pick_for_loser(loser_id: int) -> void:
	if completed_picks.has(loser_id) or pending_pick_cards_by_player.has(loser_id):
		return
	var cards := CardLibrary.random_ids(CARDS_PER_PICK)
	pending_pick_cards_by_player[loser_id] = cards
	pending_picker_id = loser_id
	pending_pick_cards = cards
	var peer := _peer_for_player(loser_id)
	if peer != 0 and loser_id != BOT_ID:
		_show_card_pick.rpc_id(peer, loser_id, cards)
	if loser_id == BOT_ID:
		_bot_auto_pick.call_deferred(loser_id)

func _bot_auto_pick(loser_id: int) -> void:
	await get_tree().create_timer(1.2).timeout
	if not pending_pick_cards_by_player.has(loser_id):
		return
	var cards: Array = pending_pick_cards_by_player[loser_id]
	if cards.is_empty():
		return
	var pick: String = str(cards[randi() % cards.size()])
	_finalize_card_pick(loser_id, pick)

func _finalize_card_pick(player_id_to_apply: int, card_id: String) -> void:
	var p := players_root.get_node_or_null(str(player_id_to_apply))
	if p:
		p.apply_card.rpc(card_id)
	completed_picks[player_id_to_apply] = true
	pending_pick_cards_by_player.erase(player_id_to_apply)
	var peer := _peer_for_player(player_id_to_apply)
	if peer != 0:
		_hide_card_pick.rpc_id(peer)
		if state == State.PLAYING:
			_show_spectating.rpc_id(peer, "SPECTATING…")
		elif state == State.PICKING_CARD:
			_show_spectating.rpc_id(peer, "WAITING FOR OTHER PICKS…")
	_maybe_finish_card_picks()

func _maybe_finish_card_picks() -> void:
	if state != State.PICKING_CARD:
		return
	for raw_loser_id in eliminated_players.keys():
		var loser_id := int(raw_loser_id)
		if not completed_picks.has(loser_id):
			return
	current_round += 1
	state = State.PLAYING
	_start_round_now()

func _peer_for_player(pid: int) -> int:
	var p := players_root.get_node_or_null(str(pid))
	if p:
		return int(p.get_multiplayer_authority())
	return pid

@rpc("authority", "call_local", "reliable")
func _show_spectating(text: String = "SPECTATING…") -> void:
	pick_overlay.visible = false
	for c in pick_row.get_children():
		c.queue_free()
	round_banner.text = text
	round_banner.visible = true
	banner_timer.stop()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

@rpc("authority", "call_local", "reliable")
func _show_round_winner_wait(winner_id: int) -> void:
	if multiplayer.get_unique_id() != winner_id:
		return
	round_banner.text = "ROUND WON — WAITING FOR PICKS…"
	round_banner.visible = true
	banner_timer.stop()

# -------------------- CARD PICK UI --------------------

@rpc("authority", "call_local", "reliable")
func _show_card_pick(loser_id: int, card_ids: Array) -> void:
	var my_id := multiplayer.get_unique_id()
	var is_me := loser_id == my_id
	var loser_name: String = NetworkManager.players.get(loser_id, "Player")
	if not is_me:
		# Winner keeps roaming — no full-screen overlay, just a banner.
		pick_overlay.visible = false
		round_banner.text = "%s IS PICKING A CARD…" % loser_name
		round_banner.visible = true
		banner_timer.stop()
		return
	# Loser: full overlay + cursor + card buttons.
	pick_overlay.visible = true
	pick_title.text = "PICK A CARD"
	pick_subtitle.text = "you lost the round — choose an upgrade"
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_populate_cards(card_ids, true)
	# 1-second grace period before the loser can actually click — avoids
	# accidental picks mid-death animation / mid-mouse-release.
	for btn in pick_row.get_children():
		if btn is Button:
			(btn as Button).disabled = true
	await get_tree().create_timer(1.0).timeout
	if not pick_overlay.visible:
		return
	for btn in pick_row.get_children():
		if btn is Button:
			(btn as Button).disabled = false

func _populate_cards(card_ids: Array, clickable: bool) -> void:
	for c in pick_row.get_children():
		c.queue_free()
	for raw_id in card_ids:
		var cid := str(raw_id)
		var card: Dictionary = CardLibrary.by_id(cid)
		if card.is_empty():
			continue
		pick_row.add_child(_make_card_button(cid, card, clickable))

func _make_card_button(card_id: String, card: Dictionary, clickable: bool) -> Button:
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(220, 260)
	btn.focus_mode = Control.FOCUS_NONE
	btn.text = "%s\n\n%s" % [card.name, card.desc]
	btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	btn.add_theme_font_size_override("font_size", 20)
	btn.add_theme_color_override("font_color", Color(1, 1, 1))
	btn.add_theme_color_override("font_hover_color", card.color)
	var col: Color = card.color
	var rarity: String = str(card.get("rarity", "common"))
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(col.r * 0.18, col.g * 0.18, col.b * 0.18, 0.95)
	sb.border_color = col
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 14
	sb.content_margin_bottom = 14
	var sb_hover := sb.duplicate() as StyleBoxFlat
	sb_hover.bg_color = Color(col.r * 0.32, col.g * 0.32, col.b * 0.32, 0.95)
	sb_hover.set_border_width_all(5)
	if rarity == "rare":
		sb.bg_color = Color(0.08, 0.12, 0.22, 0.98)
		sb.border_color = Color(0.95, 0.82, 1.0)
		sb.shadow_color = Color(0.25, 0.9, 1.0, 0.55)
		sb.shadow_size = 12
		sb_hover.bg_color = Color(0.14, 0.2, 0.34, 1.0)
		sb_hover.border_color = Color(1.0, 0.92, 0.72)
		sb_hover.shadow_color = Color(0.45, 0.95, 1.0, 0.8)
		sb_hover.shadow_size = 18
		btn.text = "RARE\n%s\n\n%s" % [card.name, card.desc]
		btn.add_theme_color_override("font_color", Color(0.95, 0.98, 1.0))
		btn.add_theme_color_override("font_hover_color", Color(1.0, 0.95, 0.72))
	btn.add_theme_stylebox_override("normal", sb)
	btn.add_theme_stylebox_override("pressed", sb_hover)
	btn.add_theme_stylebox_override("hover", sb_hover)
	btn.add_theme_stylebox_override("focus", sb)
	btn.add_theme_stylebox_override("disabled", sb)
	btn.disabled = not clickable
	if clickable:
		btn.pressed.connect(func() -> void: _on_card_button(card_id))
	return btn

func _on_card_button(card_id: String) -> void:
	if multiplayer.is_server():
		_server_card_picked(card_id)
	else:
		_server_card_picked.rpc_id(1, card_id)

@rpc("any_peer", "call_local", "reliable")
func _server_card_picked(card_id: String) -> void:
	if not multiplayer.is_server():
		return
	if state != State.PICKING_CARD and state != State.PLAYING:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = multiplayer.get_unique_id()
	if not pending_pick_cards_by_player.has(sender):
		return
	var cards: Array = pending_pick_cards_by_player[sender]
	if not cards.has(card_id):
		return
	_finalize_card_pick(sender, card_id)

@rpc("authority", "call_local", "reliable")
func _hide_card_pick() -> void:
	pick_overlay.visible = false
	for c in pick_row.get_children():
		c.queue_free()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

@rpc("authority", "call_local", "reliable")
func _announce(text: String, duration: float) -> void:
	round_banner.text = text
	round_banner.visible = true
	banner_timer.stop()
	if duration < 90.0:
		banner_timer.wait_time = duration
		banner_timer.start()

@rpc("authority", "call_local", "reliable")
func _match_over(winner_id: int) -> void:
	var winner_name: String = NetworkManager.players.get(winner_id, "Player")
	var is_me := winner_id == multiplayer.get_unique_id()
	round_banner.text = "YOU WIN THE MATCH" if is_me else "%s WINS THE MATCH" % winner_name
	round_banner.visible = true
	banner_timer.stop()
	_show_rematch_overlay(winner_id)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _build_rematch_overlay() -> void:
	_rematch_overlay = Control.new()
	_rematch_overlay.name = "RematchOverlay"
	_rematch_overlay.anchor_right = 1.0
	_rematch_overlay.anchor_bottom = 1.0
	_rematch_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_rematch_overlay.visible = false
	$HUD.add_child(_rematch_overlay)

	var center := CenterContainer.new()
	center.anchor_right = 1.0
	center.anchor_bottom = 1.0
	_rematch_overlay.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(420, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.035, 0.06, 0.92)
	sb.border_color = Color(1.0, 0.9, 0.35, 0.9)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 28
	sb.content_margin_right = 28
	sb.content_margin_top = 22
	sb.content_margin_bottom = 22
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	panel.add_child(vb)

	_rematch_title = Label.new()
	_rematch_title.text = "MATCH OVER"
	_rematch_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_rematch_title.add_theme_font_size_override("font_size", 34)
	_rematch_title.add_theme_color_override("font_color", Color(1.0, 0.95, 0.5))
	vb.add_child(_rematch_title)

	_rematch_subtitle = Label.new()
	_rematch_subtitle.text = ""
	_rematch_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_rematch_subtitle.add_theme_font_size_override("font_size", 18)
	_rematch_subtitle.add_theme_color_override("font_color", Color(0.86, 0.86, 0.95))
	vb.add_child(_rematch_subtitle)

	_rematch_button = Button.new()
	_rematch_button.text = "REMATCH"
	_rematch_button.custom_minimum_size = Vector2(260, 46)
	_rematch_button.focus_mode = Control.FOCUS_NONE
	_rematch_button.pressed.connect(_on_rematch_pressed)
	vb.add_child(_rematch_button)

func _show_rematch_overlay(winner_id: int) -> void:
	if _rematch_overlay == null:
		_build_rematch_overlay()
	var winner_name: String = NetworkManager.players.get(winner_id, "Player")
	var is_me := winner_id == multiplayer.get_unique_id()
	_rematch_requested = false
	_rematch_title.text = "YOU WIN" if is_me else "%s WINS" % winner_name
	_rematch_subtitle.text = "start a fresh match with reset scores and cards"
	_rematch_button.text = "REMATCH"
	_rematch_button.disabled = false
	_rematch_overlay.visible = true

func _build_ghost_overlay() -> void:
	_ghost_overlay = Control.new()
	_ghost_overlay.name = "GhostOverlay"
	_ghost_overlay.anchor_right = 1.0
	_ghost_overlay.anchor_bottom = 1.0
	_ghost_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ghost_overlay.visible = false
	$HUD.add_child(_ghost_overlay)

	var veil := ColorRect.new()
	veil.anchor_right = 1.0
	veil.anchor_bottom = 1.0
	veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	veil.color = Color(0.45, 0.9, 1.0, 0.04)
	_ghost_overlay.add_child(veil)

	_ghost_label = Label.new()
	_ghost_label.text = "GHOST MODE"
	_ghost_label.anchor_left = 0.5
	_ghost_label.anchor_right = 0.5
	_ghost_label.anchor_top = 1.0
	_ghost_label.anchor_bottom = 1.0
	_ghost_label.offset_left = -70
	_ghost_label.offset_right = 70
	_ghost_label.offset_top = -34
	_ghost_label.offset_bottom = -12
	_ghost_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_ghost_label.add_theme_font_size_override("font_size", 14)
	_ghost_label.add_theme_color_override("font_color", Color(0.78, 0.95, 1.0, 0.72))
	_ghost_overlay.add_child(_ghost_label)

func _update_ghost_overlay() -> void:
	if _ghost_overlay == null:
		return
	var show: bool = local_player != null and is_instance_valid(local_player) and local_player.get("ghost_mode") == true
	_ghost_overlay.visible = show

func _on_rematch_pressed() -> void:
	if _rematch_requested:
		return
	_rematch_requested = true
	_rematch_button.text = "REMATCH REQUESTED"
	_rematch_button.disabled = true
	if multiplayer.is_server():
		_server_rematch_requested()
	else:
		_server_rematch_requested.rpc_id(1)

@rpc("any_peer", "call_local", "reliable")
func _server_rematch_requested() -> void:
	if not multiplayer.is_server():
		return
	if state != State.MATCH_OVER:
		return
	_start_rematch()

func _start_rematch() -> void:
	_reset_round_tracking()
	current_round = 1
	for pid in NetworkManager.players:
		round_wins[pid] = 0
		var p := players_root.get_node_or_null(str(pid))
		if p:
			p.reset_weapon.rpc()
			p.set_ghost_mode.rpc(false)
			p.set_frozen.rpc(false)
			p.clear_ragdoll.rpc()
	_broadcast_scores.rpc(round_wins)
	_hide_rematch_overlay.rpc()
	state = State.PLAYING
	_start_round_now()

@rpc("authority", "call_local", "reliable")
func _hide_rematch_overlay() -> void:
	if _rematch_overlay:
		_rematch_overlay.visible = false
	_rematch_requested = false

@rpc("authority", "call_local", "reliable")
func _broadcast_scores(scores: Dictionary) -> void:
	round_wins = scores
	_update_scoreboard()

func show_hitmarker(kind: String, dmg: int = 0) -> void:
	hitmarker.flash(kind)
	if kind == "kill":
		SFX.kill_confirm()
	else:
		SFX.hitmarker(kind, dmg)

func is_any_modal_open() -> bool:
	# Used by Player._unhandled_input to avoid recapturing the mouse when a
	# UI overlay (card pick, dev panel, pause menu) is visible.
	if pick_overlay and pick_overlay.visible:
		return true
	if _dev_root and _dev_root.visible:
		return true
	if _pause_menu and _pause_menu.visible:
		return true
	return false

# -------------------- PAUSE MENU (ESC) --------------------

func _toggle_pause_menu() -> void:
	if _pause_menu == null:
		_build_pause_menu()
	_pause_menu.visible = not _pause_menu.visible
	if _pause_menu.visible:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		# Don't recapture if another modal (card pick, match over) is up.
		if not (pick_overlay and pick_overlay.visible) and state != State.MATCH_OVER:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _build_pause_menu() -> void:
	var root := Control.new()
	root.name = "PauseMenu"
	root.anchor_right = 1.0
	root.anchor_bottom = 1.0
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	$HUD.add_child(root)

	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.55)
	bg.anchor_right = 1.0
	bg.anchor_bottom = 1.0
	root.add_child(bg)

	var center := CenterContainer.new()
	center.anchor_right = 1.0
	center.anchor_bottom = 1.0
	root.add_child(center)

	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.08, 0.1, 0.95)
	sb.border_color = Color(0.35, 0.7, 1.0)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 24
	sb.content_margin_right = 24
	sb.content_margin_top = 20
	sb.content_margin_bottom = 20
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	panel.add_child(vb)

	var title := Label.new()
	title.text = "PAUSED"
	title.add_theme_font_size_override("font_size", 32)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)

	var resume := Button.new()
	resume.text = "RESUME"
	resume.custom_minimum_size = Vector2(260, 44)
	resume.pressed.connect(_toggle_pause_menu)
	vb.add_child(resume)

	var leave := Button.new()
	leave.text = "LEAVE TO MAIN MENU"
	leave.custom_minimum_size = Vector2(260, 44)
	leave.pressed.connect(_leave_to_main_menu)
	vb.add_child(leave)

	_pause_menu = root
	_pause_menu.visible = false

func _leave_to_main_menu() -> void:
	NetworkManager.leave_game()
	get_tree().change_scene_to_file("res://scenes/main.tscn")

func show_damage_direction(from_pos: Vector3) -> void:
	if not local_player or not is_instance_valid(local_player):
		return
	var delta: Vector3 = from_pos - local_player.global_position
	delta.y = 0.0
	if delta.length_squared() < 0.0001:
		return
	# Rotate the horizontal world vector into the player's local frame using
	# only their yaw (camera pitch doesn't affect damage direction).
	var yaw: float = local_player.rotation.y
	var c := cos(yaw)
	var s := sin(yaw)
	var local_x := c * delta.x - s * delta.z
	var local_z := s * delta.x + c * delta.z
	# Forward in local space is -Z. Angle convention: 0 forward, +π/2 right.
	var angle := atan2(local_x, -local_z)
	damage_indicator.flash(angle)

func _update_scoreboard() -> void:
	var lines: Array[String] = ["— ROUNDS —"]
	for id in NetworkManager.players:
		var wins := int(round_wins.get(id, 0))
		var marker := "  ★" if wins >= ROUNDS_TO_WIN else ""
		lines.append("%s  %d/%d%s" % [NetworkManager.players[id], wins, ROUNDS_TO_WIN, marker])
	scoreboard.text = "\n".join(lines)

# -------------------- DEV PANEL (F1) --------------------

func _toggle_dev_panel() -> void:
	if _dev_root == null:
		_build_dev_panel()
	_dev_root.visible = not _dev_root.visible
	if _dev_root.visible:
		_refresh_dev_panel()
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _build_dev_panel() -> void:
	_dev_root = PanelContainer.new()
	_dev_root.anchor_left = 0.5
	_dev_root.anchor_right = 0.5
	_dev_root.anchor_top = 0.0
	_dev_root.anchor_bottom = 1.0
	_dev_root.offset_left = -420.0
	_dev_root.offset_right = 420.0
	_dev_root.offset_top = 30.0
	_dev_root.offset_bottom = -30.0
	_dev_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_dev_root.visible = false
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.05, 0.08, 0.96)
	style.set_border_width_all(2)
	style.border_color = Color(0.4, 0.8, 1.0)
	style.set_corner_radius_all(6)
	style.content_margin_left = 16
	style.content_margin_right = 16
	style.content_margin_top = 12
	style.content_margin_bottom = 12
	_dev_root.add_theme_stylebox_override("panel", style)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_dev_root.add_child(scroll)
	_dev_content = VBoxContainer.new()
	_dev_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_dev_content.add_theme_constant_override("separation", 6)
	scroll.add_child(_dev_content)
	$HUD.add_child(_dev_root)

func _refresh_dev_panel() -> void:
	for c in _dev_content.get_children():
		c.queue_free()
	_dev_heading("DEV  ·  F1 to close", Color(0.5, 0.9, 1.0), 20)
	_dev_heading("— WEAPON STATS —", Color(1.0, 0.9, 0.5), 15)
	if local_player and is_instance_valid(local_player):
		var w: Weapon = local_player.weapon
		_dev_stat("damage", "%.1f  (base %.0f × %.2f)" % [w.get_damage(), Weapon.BASE_DAMAGE, w.damage_mult])
		_dev_stat("fire interval", "%.3fs  (×%.2f)  %s" % [w.get_fire_interval(), w.fire_rate_mult, "FULL-AUTO" if w.full_auto else "semi-auto"])
		_dev_stat("mag size", "%d  (base %d %+d)" % [w.get_mag_size(), Weapon.BASE_MAG_SIZE, w.mag_size_bonus])
		_dev_stat("reload time", "%.2fs  (×%.2f)" % [w.get_reload_time(), w.reload_mult])
		_dev_stat("headshot mult", "×%.2f" % w.get_headshot_mult())
		_dev_stat("shots / trigger", str(w.get_shots_per_trigger()))
		_dev_stat("pierce", str(w.pierce_count))
		_dev_stat("ricochet", str(w.ricochet_count))
		_dev_stat("spread", "%.4f rad  (%.2f°)" % [w.spread, rad_to_deg(w.spread)])
		_dev_stat("lifesteal", "%.0f%%" % (w.lifesteal * 100.0))
		_dev_stat("explosive radius / dmg", "%.1fm  /  %.1f" % [w.explosive_radius, w.explosive_damage])
		_dev_stat("bullet scale", "%.2f" % w.bullet_scale)
		_dev_stat("bullet color", "#%s" % w.bullet_color.to_html(false))
	else:
		_dev_note("(local player not spawned)")
	_dev_heading("— APPLIED CARDS —", Color(0.8, 1.0, 0.5), 15)
	if local_player and is_instance_valid(local_player):
		var applied: Array = local_player.weapon.applied_cards
		if applied.is_empty():
			_dev_note("(none)")
		else:
			for card_id in applied:
				_dev_applied_row(str(card_id))
	_dev_heading("— ALL CARDS —", Color(1.0, 0.6, 0.9), 15)
	for card in CardLibrary.all():
		_dev_available_row(card)

func _dev_heading(text: String, color: Color, font_size: int) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", color)
	lbl.add_theme_font_size_override("font_size", font_size)
	_dev_content.add_child(lbl)

func _dev_stat(stat_name: String, value: String) -> void:
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
	_dev_content.add_child(hbox)

func _dev_note(text: String) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.7))
	_dev_content.add_child(lbl)

func _dev_applied_row(card_id: String) -> void:
	var card: Dictionary = CardLibrary.by_id(card_id)
	var label_text := card_id
	var col := Color(1, 1, 1)
	if not card.is_empty():
		label_text = "%s  —  %s" % [card.name, card.desc]
		col = card.color
	var hbox := HBoxContainer.new()
	var n := Label.new()
	n.text = label_text
	n.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	n.add_theme_color_override("font_color", col)
	hbox.add_child(n)
	var btn := Button.new()
	btn.text = "Remove"
	btn.focus_mode = Control.FOCUS_NONE
	btn.pressed.connect(_dev_remove_card.bind(card_id))
	hbox.add_child(btn)
	_dev_content.add_child(hbox)

func _dev_available_row(card: Dictionary) -> void:
	var hbox := HBoxContainer.new()
	var n := Label.new()
	n.text = "%s  —  %s" % [card.name, card.desc]
	n.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	n.add_theme_color_override("font_color", card.color)
	hbox.add_child(n)
	var btn := Button.new()
	btn.text = "Apply"
	btn.focus_mode = Control.FOCUS_NONE
	btn.pressed.connect(_dev_apply_card.bind(card.id))
	hbox.add_child(btn)
	_dev_content.add_child(hbox)

func _dev_apply_card(card_id: String) -> void:
	if not local_player or not is_instance_valid(local_player):
		return
	local_player.apply_card.rpc(card_id)
	call_deferred("_refresh_dev_panel")

func _dev_remove_card(card_id: String) -> void:
	# Cards mutate weapon cumulatively and have no inverse — easiest way to
	# drop one is to reset and reapply every OTHER card in the stack.
	if not local_player or not is_instance_valid(local_player):
		return
	var remaining: Array = local_player.weapon.applied_cards.duplicate()
	var idx := remaining.find(card_id)
	if idx >= 0:
		remaining.remove_at(idx)
	local_player.reset_weapon.rpc()
	for c in remaining:
		local_player.apply_card.rpc(str(c))
	call_deferred("_refresh_dev_panel")
