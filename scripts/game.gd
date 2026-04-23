extends Node3D

const PLAYER_SCENE := preload("res://scenes/player.tscn")

enum State { WAITING, PLAYING, PICKING_CARD, MATCH_OVER }

const CARDS_PER_PICK := 3
const SPAWN_CAPSULE_RADIUS := 0.4
const SPAWN_CAPSULE_HEIGHT := 1.8
const BOT_ID := 9999
const BOT_NAME := "BOT"
const SPAWN_MIN_SPACING := 8.0   # meters — two fresh spawns must be at least this far apart

var rounds_to_win: int = 10

@onready var players_root: Node3D = $Players
@onready var health_label: Label = $HUD/HealthPanel/HealthLabel
@onready var scoreboard: Label = $HUD/Scoreboard
@onready var hitmarker: Control = $HUD/Hitmarker
@onready var crosshair_label: Label = $HUD/Crosshair
@onready var damage_indicator: Control = $HUD/DamageIndicator
@onready var rifle_label: Label = $HUD/AbilityBar/Rifle/Label
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
var _custom_crosshair: Control = null
var _stats_panel: Control = null
var _stats_content: GridContainer = null

var _pick_timeout_timer: float = 0.0
var _pick_timeout_active: bool = false
var _last_pling_sec: int = -1

# --- Match over / rematch ---
var _rematch_overlay: Control = null
var _rematch_title: Label = null
var _rematch_subtitle: Label = null
var _rematch_button: Button = null
var _extend_button: Button = null
var _rematch_requested: bool = false
var _extend_votes: Dictionary = {} # id -> bool

# --- Dev panel (F1) ---
var _dev_root: PanelContainer = null
var _dev_content: VBoxContainer

# --- Tab scoreboard overlay ---
var _tab_root: PanelContainer = null
var _tab_content: VBoxContainer = null

# --- Pause menu (ESC) ---
var _pause_menu: Control = null
var _ghost_overlay: Control = null
var _ghost_label: Label = null
var _death_overlay: ColorRect = null

func _ready() -> void:
	# Hide the static label and set up the dynamic one
	if crosshair_label: crosshair_label.visible = false
	_custom_crosshair = Control.new()
	_custom_crosshair.name = "DynamicCrosshair"
	_custom_crosshair.set_anchors_preset(Control.PRESET_FULL_RECT)
	_custom_crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_custom_crosshair.set_script(load("res://scripts/crosshair.gd"))
	$HUD.add_child(_custom_crosshair)
	if crosshair_label: $HUD.move_child(_custom_crosshair, crosshair_label.get_index())

	# Keep the game controller and its UI running when the tree is paused.
	process_mode = Node.PROCESS_MODE_ALWAYS

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
	scoreboard.visible = false
	_build_rematch_overlay()
	_build_ghost_overlay()
	_build_death_overlay()
	_build_retro_filter()
	_build_tab_overlay()
	_build_stats_panel()

	if multiplayer.is_server():
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
		for pid in NetworkManager.players:
			round_wins[pid] = 0
			_spawn_player(pid, NetworkManager.players[pid])

		var bot_requested: bool = NetworkManager.has_meta("spawn_bot_on_start") and NetworkManager.get_meta("spawn_bot_on_start")
		if bot_requested:
			_maybe_spawn_bot()

		_maybe_start_match()

		# SP fallback: if nobody else has joined yet, and no bot was specifically requested,
		# we still give a bot to fight as a default "sandbox" experience.
		if not bot_requested:
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

func _process(delta: float) -> void:
	if local_player and is_instance_valid(local_player):
		health_label.text = "GHOST" if local_player.get("ghost_mode") == true else "HP  %d" % local_player.health
		_refresh_cooldowns()
		_update_ghost_overlay()

		# Update crosshair spread
		if _custom_crosshair:
			_custom_crosshair.spread = local_player.weapon.spread

	if _pick_timeout_active:
		_pick_timeout_timer -= delta
		var sec := int(ceil(_pick_timeout_timer))

		# Show countdown in subtitle
		if pick_overlay.visible:
			pick_subtitle.text = "you lost the round — choose an upgrade (%ds left)" % max(0, sec)

		# Audio feedback in last 3 seconds
		if sec <= 3 and sec > 0 and sec != _last_pling_sec:
			_last_pling_sec = sec
			# Increase by 1 semitone every second
			var semitones := (3 - sec)
			var pitch := pow(2.0, float(semitones) / 12.0)
			SFX.pling(pitch)

		if _pick_timeout_timer <= 0.0:
			_on_pick_timeout()

	# Tab is handled in _input — Godot's GUI focus navigation eats the Tab key
	# before _process polling can see it, so we intercept it earlier.

func _input(event: InputEvent) -> void:
	# Tab hold = scoreboard overlay. Use _input (not _unhandled_input) so we
	# beat the viewport's GUI focus navigation, which would otherwise consume
	# Tab and prevent our polling from ever seeing it.
	if event is InputEventKey and not event.echo and event.keycode == KEY_TAB:
		if event.pressed:
			_show_tab_overlay()
		else:
			_hide_tab_overlay()
		get_viewport().set_input_as_handled()

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
		rifle_label.text = "GHOST"
		rifle_bar.visible = false
		rifle_bar.value = 0.0
		grenade_bar.value = 1.0 - (local_player.grenade_cooldown / local_player.MINE_RELOAD)
		grenade_label.text = "LMB  MINE"
		melee_bar.value = 0.0
		var ghost_charge_progress: float = local_player.dash_recharge_timer / local_player.DASH_RECHARGE_TIME
		dash_bar.value = (float(local_player.dash_charges) + ghost_charge_progress) / float(local_player.MAX_DASH_CHARGES)
		return
	if local_player.reloading:
		rifle_label.text = "RELOADING…"
		rifle_bar.visible = true
		rifle_bar.value = 1.0 - (local_player.rifle_cooldown / max(0.01, w.get_reload_time()))
	else:
		rifle_label.text = "AMMO  %d / %d" % [local_player.mag, w.get_mag_size()]
		rifle_bar.visible = false
		rifle_bar.value = float(local_player.mag) / float(w.get_mag_size())
	# The RMB slot hosts multiple specials with different cooldowns. Normalize
	# against the max cooldown of the equipped special so the bar reads right.
	var special_max: float = local_player.GRENADE_RELOAD
	match w.special:
		Weapon.SPECIAL_TELEPORT: special_max = local_player.TELEPORT_RELOAD
		Weapon.SPECIAL_SHIELD:   special_max = local_player.SHIELD_RELOAD
		Weapon.SPECIAL_INVISIBLE: special_max = local_player.INVISIBLE_RELOAD
	special_max *= w.special_cooldown_mult
	grenade_bar.value = 1.0 - (local_player.grenade_cooldown / max(0.01, special_max))
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
	if victim_node and NetworkManager.players.size() >= 3:
		victim_node.set_ghost_mode.rpc(true)

	var alive := _alive_player_ids()
	if alive.size() <= 1:
		var winner_id := int(alive[0]) if alive.size() == 1 else _fallback_round_winner(victim_id)
		_end_round(winner_id)
	else:
		# Only pick immediately if the round is still going (3+ players)
		_begin_card_pick_for_loser(victim_id)

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
	if winner_id != 0 and int(round_wins[winner_id]) >= rounds_to_win:
		state = State.MATCH_OVER
		for pid in NetworkManager.players:
			var pn := players_root.get_node_or_null(str(pid))
			if pn:
				# Freeze everyone except the winner so they can celebrate
				if int(pid) != winner_id:
					pn.set_frozen.rpc(true)
				pn.reset_weapon.rpc() # Reset cards immediately when match ends
		_match_over.rpc(winner_id)
		return
	# Freeze the losers and wait for them to finish their picks.
	state = State.PICKING_CARD
	for pid in NetworkManager.players:
		var p := players_root.get_node_or_null(str(pid))
		if p:
			# Only freeze the non-winners
			if int(pid) != winner_id:
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

	var score_factor := _get_rarity_score_factor(loser_id)
	var cards := CardLibrary.random_ids(CARDS_PER_PICK, score_factor)
	pending_pick_cards_by_player[loser_id] = cards
	pending_picker_id = loser_id
	pending_pick_cards = cards
	var peer := _peer_for_player(loser_id)
	if peer != 0 and loser_id != BOT_ID:
		_show_card_pick.rpc_id(peer, loser_id, cards)
	if loser_id == BOT_ID:
		_bot_auto_pick.call_deferred(loser_id)

func _get_rarity_score_factor(pid: int) -> float:
	# Calculate score rank.
	# 1.0 = top score, >1.0 = trailing.
	var my_score := int(round_wins.get(pid, 0))
	var max_score := 0
	for other_id in NetworkManager.players:
		max_score = max(max_score, int(round_wins.get(int(other_id), 0)))

	if max_score <= 0:
		return 1.0

	# Trailing players get up to 4x better luck (if they have 0 and someone has 8)
	var diff := float(max_score - my_score)
	return 1.0 + (diff * 0.4)

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
	_stats_panel.visible = true
	_refresh_stats_panel()
	pick_title.text = "PICK A CARD"
	pick_subtitle.text = "you lost the round — choose an upgrade (8s left)"
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_populate_cards(card_ids, true)

	_pick_timeout_timer = 8.0
	_pick_timeout_active = true
	_last_pling_sec = -1

	# 1-second grace period before the loser can actually click — avoids
	# accidental picks mid-death animation / mid-mouse-release.
	_set_card_buttons_disabled(true)
	await get_tree().create_timer(1.0).timeout
	if not pick_overlay.visible:
		return
	_set_card_buttons_disabled(false)

func _set_card_buttons_disabled(disabled: bool) -> void:
	for wrapper in pick_row.get_children():
		var btn := _find_button_recursive(wrapper)
		if btn:
			btn.disabled = disabled

func _find_button_recursive(node: Node) -> Button:
	if node is Button:
		return node
	for child in node.get_children():
		var res := _find_button_recursive(child)
		if res:
			return res
	return null

func _populate_cards(card_ids: Array, clickable: bool) -> void:
	for c in pick_row.get_children():
		c.queue_free()

	var index := 0
	for raw_id in card_ids:
		var cid := str(raw_id)
		var card: Dictionary = CardLibrary.by_id(cid)
		if card.is_empty():
			continue

		var card_node := _make_card_button(cid, card, clickable)
		pick_row.add_child(card_node)

		var body = card_node.get_child(0).get_child(0) # root -> idle_node -> card_body
		var content = body.get_child(0) # VBoxContainer with labels

		# Store the intended 'front' style from the override we just set
		var front_style = body.get_theme_stylebox("panel")

		# 1. Initial 'Face Down' State
		body.position.y = 400.0
		body.scale.x = 0.0 # Narrow for flip
		content.visible = false

		# Create a temporary back-side style
		var back_style := StyleBoxFlat.new()
		back_style.bg_color = Color(0.12, 0.12, 0.15, 1.0)
		back_style.border_color = Color(0.3, 0.3, 0.4)
		back_style.set_corner_radius_all(12)
		body.add_theme_stylebox_override("panel", back_style)

		# 2. Entry + Flip Reveal Sequence
		var reveal_delay := index * 0.3
		var tw := body.create_tween()

		# Pop up from below (still face down)
		tw.tween_property(body, "position:y", 0.0, 0.4)\
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT).set_delay(index * 0.08)

		# Flip animation
		tw.tween_interval(reveal_delay)
		tw.tween_property(body, "scale:x", 0.0, 0.1) # Ensure it's narrow
		tw.tween_callback(func():
			content.visible = true
			body.add_theme_stylebox_override("panel", front_style) # Re-apply front style
			SFX.pling(0.8 + (index * 0.15))
		)
		tw.tween_property(body, "scale:x", 1.0, 0.15).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

		index += 1

func _make_card_button(card_id: String, card: Dictionary, clickable: bool) -> Control:
	var rarity: String = str(card.get("rarity", "common"))
	var col: Color = card.color

	# 1. Root: The stable footprint in the HBox
	var root := Control.new()
	root.custom_minimum_size = Vector2(220, 300)
	root.size_flags_vertical = Control.SIZE_SHRINK_CENTER

	# 2. Idle: Handles the bobbing animation
	var idle_node := Control.new()
	idle_node.size = Vector2(200, 280)
	idle_node.position = (root.custom_minimum_size - idle_node.size) * 0.5
	root.add_child(idle_node)

	# 3. Card Body: Handles scaling and visuals. Use a simple Panel (not Container)
	# to prevent any child from growing the card's physical footprint.
	var card_body := Panel.new()
	card_body.custom_minimum_size = Vector2(200, 280)
	card_body.size = card_body.custom_minimum_size
	card_body.pivot_offset = card_body.size * 0.5
	idle_node.add_child(card_body)

	# Style the card body
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(12)
	sb.set_border_width_all(3)
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
	card_body.add_theme_stylebox_override("panel", sb)

	# 4. Content: Centered VBox inside the card
	var v_content := VBoxContainer.new()
	v_content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 14)
	v_content.add_theme_constant_override("separation", 10)
	card_body.add_child(v_content)

	var title := Label.new()
	title.text = card.name.to_upper()
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.add_theme_font_size_override("font_size", 18) # Slightly smaller to fit
	title.add_theme_color_override("font_color", Color.WHITE if rarity != "rare" else Color(1.0, 0.95, 0.8))
	v_content.add_child(title)

	var desc := Label.new()
	desc.text = card.desc
	desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.add_theme_font_size_override("font_size", 13)
	desc.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
	v_content.add_child(desc)

	# Mathematical Stat Diffs
	var stats_vbox := VBoxContainer.new()
	stats_vbox.add_theme_constant_override("separation", 1)
	v_content.add_child(stats_vbox)

	for diff_line in _get_card_stat_diff(card_id):
		var slbl := Label.new()
		slbl.text = diff_line
		slbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		slbl.add_theme_font_size_override("font_size", 10)
		slbl.add_theme_color_override("font_color", Color(0.7, 0.8, 1.0, 0.7))
		stats_vbox.add_child(slbl)

	# Holographic effects for rare
	if rarity == "rare":
		# Create an internal clipping layer so the outer shadow/glow isn't cut off
		var clip_layer := Control.new()
		clip_layer.name = "HoloClip"
		clip_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
		clip_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		clip_layer.clip_contents = true
		card_body.add_child(clip_layer)

		# Shifting gradient "Holo" sweep
		for i in range(2):
			var shine := TextureRect.new()
			var grad := Gradient.new()
			grad.set_offsets(PackedFloat32Array([0.0, 0.5, 1.0]))
			var tint := Color(0.4, 0.8, 1.0, 0.1) if i == 0 else Color(0.9, 0.5, 1.0, 0.08)
			grad.set_colors(PackedColorArray([Color(tint.r, tint.g, tint.b, 0), tint, Color(tint.r, tint.g, tint.b, 0)]))
			var tex := GradientTexture2D.new()
			tex.gradient = grad
			tex.width = 128
			tex.height = 1
			tex.fill_from = Vector2(0, 0)
			tex.fill_to = Vector2(1, 0)
			shine.texture = tex
			shine.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			shine.size = Vector2(240, 700)
			shine.rotation = deg_to_rad(20)
			shine.position = Vector2(-300, -200)
			shine.mouse_filter = Control.MOUSE_FILTER_IGNORE
			clip_layer.add_child(shine)

			var tw_shine := shine.create_tween().set_loops()
			tw_shine.tween_property(shine, "position:x", 500.0, 3.0 + (i * 0.5)).set_delay(0.2 + (i * 1.8))
			tw_shine.tween_property(shine, "position:x", -300.0, 0.0)

		# Pulsing border color
		var tw_border := card_body.create_tween().set_loops()
		tw_border.tween_property(sb, "border_color", Color(0.7, 0.9, 1.0), 1.8)
		tw_border.tween_property(sb, "border_color", Color(0.9, 0.7, 1.0), 1.8)

	# Clickable overlay
	var btn := Button.new()
	btn.flat = true
	btn.size = card_body.size
	btn.focus_mode = Control.FOCUS_NONE
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	card_body.add_child(btn)

	if clickable:
		btn.pressed.connect(func() -> void: _on_card_button(card_id, root))

		# Idle Float (bobbing)
		var idle_tw := idle_node.create_tween().set_loops()
		idle_tw.tween_property(idle_node, "position:y", 4.0, 2.2).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		idle_tw.tween_property(idle_node, "position:y", -4.0, 2.2).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

		# Initial random tilt
		var base_rot := randf_range(-1.2, 1.2)
		card_body.rotation_degrees = base_rot

		# Hover logic
		btn.mouse_entered.connect(func() -> void:
			_refresh_stats_panel(card_id) # Show projection
			var tw := card_body.create_tween().set_parallel(true)
			tw.tween_property(card_body, "scale", Vector2(1.12, 1.12), 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
			tw.tween_property(card_body, "rotation_degrees", 0.0, 0.15).set_trans(Tween.TRANS_CUBIC)
			tw.tween_property(card_body, "position:y", -10.0, 0.2).set_trans(Tween.TRANS_CUBIC)
			if rarity == "rare":
				sb.shadow_size = 40
				sb.shadow_color.a = 0.7
		)

		btn.mouse_exited.connect(func() -> void:
			_refresh_stats_panel() # Reset to current
			var tw := card_body.create_tween().set_parallel(true)
			tw.tween_property(card_body, "scale", Vector2.ONE, 0.25).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
			tw.tween_property(card_body, "rotation_degrees", base_rot, 0.2).set_trans(Tween.TRANS_CUBIC)
			tw.tween_property(card_body, "position:y", 0.0, 0.25).set_trans(Tween.TRANS_CUBIC)
			if rarity == "rare":
				sb.shadow_size = 25
				sb.shadow_color.a = 0.4
		)

	return root

func _get_card_stat_diff(card_id: String) -> Array[String]:
	var out: Array[String] = []
	if local_player == null or not is_instance_valid(local_player):
		return out

	var card := CardLibrary.by_id(card_id)
	if card.is_empty():
		return out

	# Clone current weapon to simulate the change
	var base_w: Weapon = local_player.weapon
	var next_w: Weapon = base_w.duplicate()
	card.apply.call(next_w)

	# Percent diffs
	if abs(base_w.damage_mult - next_w.damage_mult) > 0.001:
		var d = (next_w.damage_mult / base_w.damage_mult - 1.0) * 100.0
		out.append("%+d%% Damage" % int(round(d)))

	if abs(base_w.fire_rate_mult - next_w.fire_rate_mult) > 0.001:
		var d = (next_w.fire_rate_mult / base_w.fire_rate_mult - 1.0) * 100.0
		out.append("%+d%% Fire Rate" % int(round(d)))

	if base_w.mag_size_bonus != next_w.mag_size_bonus:
		out.append("%+d Ammo Capacity" % (next_w.mag_size_bonus - base_w.mag_size_bonus))

	if abs(base_w.reload_mult - next_w.reload_mult) > 0.001:
		var d = (next_w.reload_mult / base_w.reload_mult - 1.0) * 100.0
		out.append("%+d%% Reload Speed" % int(round(d)))

	if base_w.extra_projectiles != next_w.extra_projectiles:
		out.append("%+d Projectiles" % (next_w.extra_projectiles - base_w.extra_projectiles))

	if base_w.pierce_count != next_w.pierce_count:
		out.append("%+d Pierce" % (next_w.pierce_count - base_w.pierce_count))

	if base_w.ricochet_count != next_w.ricochet_count:
		out.append("%+d Bounces" % (next_w.ricochet_count - base_w.ricochet_count))

	if abs(base_w.move_speed_mult - next_w.move_speed_mult) > 0.001:
		var d = (next_w.move_speed_mult / base_w.move_speed_mult - 1.0) * 100.0
		out.append("%+d%% Move Speed" % int(round(d)))

	if next_w.bullet_speed_mult > base_w.bullet_speed_mult * 1.1:
		out.append("Faster Projectiles")
	elif next_w.bullet_speed_mult < base_w.bullet_speed_mult * 0.9:
		out.append("Slower Projectiles")

	if next_w.spread < base_w.spread * 0.5:
		out.append("Huge Accuracy Boost")
	elif next_w.spread < base_w.spread:
		out.append("Accuracy Up")
	elif next_w.spread > base_w.spread:
		out.append("Spread Increased")

	if next_w.explosive_radius > base_w.explosive_radius:
		out.append("Explosive Payload")

	if next_w.lifesteal > base_w.lifesteal:
		out.append("+%.0f%% Lifesteal" % ((next_w.lifesteal - base_w.lifesteal) * 100.0))

	if base_w.max_hp_bonus != next_w.max_hp_bonus:
		out.append("%+d Max HP" % (next_w.max_hp_bonus - base_w.max_hp_bonus))

	if base_w.extra_jumps != next_w.extra_jumps:
		out.append("%+d Extra Jumps" % (next_w.extra_jumps - base_w.extra_jumps))

	if abs(base_w.get_headshot_mult() - next_w.get_headshot_mult()) > 0.01:
		out.append("%.1fx Headshot Mult" % next_w.get_headshot_mult())

	return out

func _on_pick_timeout() -> void:
	_pick_timeout_active = false
	if not pick_overlay.visible:
		return

	# Pick first available card and find its wrapper for animation
	var card_id := ""
	var wrapper: Control = null
	if not pending_pick_cards.is_empty():
		card_id = str(pending_pick_cards[0])
		if pick_row.get_child_count() > 0:
			wrapper = pick_row.get_child(0)

	if card_id != "":
		_on_card_button(card_id, wrapper)

func _on_card_button(card_id: String, picked_wrapper: Control = null) -> void:
	_pick_timeout_active = false
	_set_card_buttons_disabled(true)

	if picked_wrapper:
		# Selection animation
		var picked_body = picked_wrapper.get_child(0).get_child(0) # root -> idle -> body

		# Move other cards away
		for other in pick_row.get_children():
			if other == picked_wrapper: continue
			var other_body = other.get_child(0).get_child(0)
			var tw_other := other_body.create_tween().set_parallel(true)
			tw_other.tween_property(other_body, "scale", Vector2(0.5, 0.5), 0.4).set_trans(Tween.TRANS_CUBIC)
			tw_other.tween_property(other_body, "modulate:a", 0.0, 0.3)

		# Animate picked card
		var tw_pick := picked_body.create_tween().set_parallel(true)
		tw_pick.tween_property(picked_body, "scale", Vector2(1.5, 1.5), 0.5).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		tw_pick.tween_property(picked_body, "position:y", -100.0, 0.5).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		tw_pick.tween_property(picked_body, "rotation_degrees", 0.0, 0.3)

		await get_tree().create_timer(0.6).timeout

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
	if _stats_panel: _stats_panel.visible = false
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
	_hide_card_pick() # Ensure picker is gone
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

	_extend_button = Button.new()
	_extend_button.text = "5 MORE ROUNDS"
	_extend_button.custom_minimum_size = Vector2(260, 46)
	_extend_button.focus_mode = Control.FOCUS_NONE
	_extend_button.pressed.connect(_on_extend_pressed)
	vb.add_child(_extend_button)

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

	var spirit_shader := Shader.new()
	spirit_shader.code = "
		shader_type canvas_item;
		uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_nearest;
		void fragment() {
			vec4 color = texture(screen_texture, SCREEN_UV);
			float gray = dot(color.rgb, vec3(0.299, 0.587, 0.114));
			vec3 b_w = vec3(gray);
			vec3 tint = vec3(0.5, 0.8, 1.0);
			COLOR.rgb = mix(b_w, tint * (gray + 0.1), 0.35);
			COLOR.a = 1.0;
		}
	"
	var mat := ShaderMaterial.new()
	mat.shader = spirit_shader
	veil.material = mat
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

	# Move to the background of the HUD so it doesn't affect other UI elements
	$HUD.move_child(_ghost_overlay, 0)

func _build_retro_filter() -> void:
	var retro_overlay := ColorRect.new()
	retro_overlay.name = "RetroFilter"
	retro_overlay.anchor_right = 1.0
	retro_overlay.anchor_bottom = 1.0
	retro_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var shader := Shader.new()
	shader.code = "
		shader_type canvas_item;
		uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_nearest;

		const float bayer[16] = {
			0.0/16.0, 8.0/16.0, 2.0/16.0, 10.0/16.0,
			12.0/16.0, 4.0/16.0, 14.0/16.0, 6.0/16.0,
			3.0/16.0, 11.0/16.0, 1.0/16.0, 9.0/16.0,
			15.0/16.0, 7.0/16.0, 13.0/16.0, 5.0/16.0
		};

		void fragment() {
			// 1. Lens Distortion (Fish-eye / Visor Curvature)
			vec2 uv = SCREEN_UV;
			vec2 centered_uv = uv - 0.5;
			float dist = length(centered_uv);

			// Zoom in (0.92 factor) to hide distorted dark edges
			float zoom = 0.92;
			uv = 0.5 + centered_uv * zoom * (1.0 + 0.15 * dist * dist);

			// 2. Pixelation Factor
			int p_size = 3;
			vec2 res = 1.0 / SCREEN_PIXEL_SIZE;
			uv = floor(uv * res / float(p_size)) / (res / float(p_size));

			// 3. Chromatic Aberration (VHS style)
			float amount = 0.001 * (dist * dist);
			float r = texture(screen_texture, uv + vec2(amount, 0.0)).r;
			float g = texture(screen_texture, uv).g;
			float b = texture(screen_texture, uv - vec2(amount, 0.0)).b;
			vec3 color = vec3(r, g, b);

			// 4. Neon Bloom / Light Bleed
			vec3 bleed = vec3(0.0);
			vec2 b_offset = SCREEN_PIXEL_SIZE * float(p_size) * 1.5;
			bleed += texture(screen_texture, uv + vec2(b_offset.x, b_offset.y)).rgb;
			bleed += texture(screen_texture, uv + vec2(-b_offset.x, b_offset.y)).rgb;
			bleed += texture(screen_texture, uv + vec2(b_offset.x, -b_offset.y)).rgb;
			bleed += texture(screen_texture, uv + vec2(-b_offset.x, -b_offset.y)).rgb;
			color += bleed * 0.15;

			// 5. Ordered Dithering
			ivec2 p = ivec2(FRAGCOORD.xy / float(p_size));
			float threshold = bayer[(p.x % 4) * 4 + (p.y % 4)];

			// 6. Color Depth & Vignette
			float levels = 24.0;
			float vignette = clamp(1.0 - dist * 1.4, 0.0, 1.0);
			color = floor(color * levels + threshold) / levels;
			color *= mix(0.7, 1.0, vignette);

			COLOR.rgb = color;
			COLOR.a = 1.0;
		}
	"
	var mat := ShaderMaterial.new()
	mat.shader = shader
	retro_overlay.material = mat

	$HUD.add_child(retro_overlay)
	# Add last so it captures all UI rendered before it

func _update_ghost_overlay() -> void:
	if _ghost_overlay == null:
		return
	var is_ghost: bool = local_player != null and is_instance_valid(local_player) and local_player.get("ghost_mode") == true
	var picking: bool = pick_overlay != null and pick_overlay.visible
	_ghost_overlay.visible = is_ghost and not picking

func _build_stats_panel() -> void:
	_stats_panel = PanelContainer.new()
	_stats_panel.custom_minimum_size = Vector2(600, 0)
	_stats_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stats_panel.visible = false

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.05, 0.08, 0.98) # Dark solid background
	sb.set_border_width_all(2)
	sb.border_color = Color(0.4, 0.8, 1.0, 0.6)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 24
	sb.content_margin_right = 24
	sb.content_margin_top = 14
	sb.content_margin_bottom = 14
	_stats_panel.add_theme_stylebox_override("panel", sb)

	_stats_content = GridContainer.new()
	_stats_content.columns = 6 # label, old, arrow, new, spacer, ...
	_stats_content.add_theme_constant_override("h_separation", 10)
	_stats_content.add_theme_constant_override("v_separation", 6)
	_stats_panel.add_child(_stats_content)

	# Add to the HUD at a fixed bottom position
	_stats_panel.anchor_left = 0.5
	_stats_panel.anchor_right = 0.5
	_stats_panel.anchor_top = 1.0
	_stats_panel.anchor_bottom = 1.0
	_stats_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_stats_panel.offset_left = -300.0
	_stats_panel.offset_right = 300.0
	_stats_panel.offset_bottom = -20.0
	# Remove fixed offset_top to allow dynamic height

	pick_overlay.add_child(_stats_panel)
func _refresh_stats_panel(projected_card_id: String = "") -> void:
	if local_player == null or not is_instance_valid(local_player):
		return

	if projected_card_id == "" or pick_overlay == null or not pick_overlay.visible:
		_animate_stats_panel(false)
		return

	var card := CardLibrary.by_id(projected_card_id)
	if card.is_empty():
		_animate_stats_panel(false)
		return

	# Clear and rebuild content before showing
	for c in _stats_content.get_children():
		c.queue_free()

	var base_w: Weapon = local_player.weapon
	var next_w := base_w.duplicate()
	card.apply.call(next_w)

	_add_stat_comparison("DAMAGE", base_w.get_damage(), next_w.get_damage(), true)
	_add_stat_comparison("FIRE RATE", 1.0/base_w.get_fire_interval(), 1.0/next_w.get_fire_interval(), true)
	_add_stat_comparison("AMMO", base_w.get_mag_size(), next_w.get_mag_size(), true)
	_add_stat_comparison("RELOAD", base_w.get_reload_time(), next_w.get_reload_time(), false)
	_add_stat_comparison("ACCURACY", rad_to_deg(base_w.spread), rad_to_deg(next_w.spread), false)
	_add_stat_comparison("MOVEMENT", base_w.move_speed_mult, next_w.move_speed_mult, true)
	_add_stat_comparison("BOUNCES", base_w.ricochet_count, next_w.ricochet_count, true)
	_add_stat_comparison("PIERCE", base_w.pierce_count, next_w.pierce_count, true)
	_add_stat_comparison("MAX HP", 100.0 + base_w.max_hp_bonus, 100.0 + next_w.max_hp_bonus, true)
	_add_stat_comparison("JUMPS", 2.0 + base_w.extra_jumps, 2.0 + next_w.extra_jumps, true)
	_add_stat_comparison("PROJ SPD", base_w.bullet_speed_mult, next_w.bullet_speed_mult, true)
	_add_stat_comparison("EXPLOSION", base_w.explosive_radius, next_w.explosive_radius, true)
	_add_stat_comparison("KNOCKBACK", base_w.knockback, next_w.knockback, true)

	# Special Cooldown (calculated based on equipped special)
	var base_cd: float = _get_base_special_cd(base_w.special) * base_w.special_cooldown_mult
	var next_cd: float = _get_base_special_cd(next_w.special) * next_w.special_cooldown_mult
	_add_stat_comparison("SPECIAL CD", base_cd, next_cd, false)

	if base_w.special != next_w.special:
		_add_text_comparison("SPECIAL", base_w.special.to_upper(), next_w.special.to_upper(), Color(0.4, 0.8, 1.0))

	_animate_stats_panel(true)

var _stats_tween: Tween = null
func _animate_stats_panel(show: bool) -> void:
	if _stats_panel == null: return

	if _stats_tween and _stats_tween.is_valid():
		_stats_tween.kill()

	if show:
		_stats_panel.visible = true
		_stats_tween = create_tween().set_parallel(true)
		_stats_tween.tween_property(_stats_panel, "modulate:a", 1.0, 0.25).set_trans(Tween.TRANS_CUBIC)
		_stats_tween.tween_property(_stats_panel, "offset_top", -120.0, 0.3).from(-80.0).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	else:
		_stats_tween = create_tween().set_parallel(true)
		_stats_tween.tween_property(_stats_panel, "modulate:a", 0.0, 0.2).set_trans(Tween.TRANS_CUBIC)
		_stats_tween.tween_property(_stats_panel, "offset_top", -80.0, 0.2).set_trans(Tween.TRANS_CUBIC)
		_stats_tween.chain().tween_callback(func(): _stats_panel.visible = false)

func _get_base_special_cd(special_id: String) -> float:
	match special_id:
		Weapon.SPECIAL_TELEPORT: return 2.0
		Weapon.SPECIAL_SHIELD:   return 8.0
		Weapon.SPECIAL_INVISIBLE: return 10.0
		_: return 3.0 # Grenade baseline

func _add_text_comparison(label_text: String, old_val: String, next_val: String, tint: Color) -> void:
	# 1. Stat Label
	var l := Label.new()
	l.text = label_text
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", Color(0.6, 0.6, 0.7))
	_stats_content.add_child(l)

	# 2. Old Value
	var v_old := Label.new()
	v_old.text = old_val
	v_old.add_theme_font_size_override("font_size", 13)
	v_old.add_theme_color_override("font_color", Color.WHITE)
	_stats_content.add_child(v_old)

	# 3. Arrow
	var arr := Label.new()
	arr.text = ">>"
	arr.add_theme_font_size_override("font_size", 11)
	arr.add_theme_color_override("font_color", Color(0.4, 0.4, 0.5))
	_stats_content.add_child(arr)

	# 4. New Value
	var v_new := Label.new()
	v_new.text = next_val
	v_new.add_theme_color_override("font_color", tint)
	v_new.add_theme_font_size_override("font_size", 14)
	_stats_content.add_child(v_new)

	# Spacers
	_stats_content.add_child(Control.new())
	_stats_content.add_child(Control.new())

func _add_stat_comparison(label_text: String, base_val: float, next_val: float, higher_is_better: bool) -> void:
	var diff := next_val - base_val
	if abs(diff) < 0.001:
		return

	# 1. Stat Label (Grey)
	var l := Label.new()
	l.text = label_text
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", Color(0.6, 0.6, 0.7))
	_stats_content.add_child(l)

	# 2. Old Value (White)
	var v_old := Label.new()
	v_old.text = "%.1f" % base_val
	v_old.add_theme_font_size_override("font_size", 13)
	v_old.add_theme_color_override("font_color", Color.WHITE)
	_stats_content.add_child(v_old)

	# 3. Arrow (Neutral)
	var arr := Label.new()
	arr.text = ">>"
	arr.add_theme_font_size_override("font_size", 11)
	arr.add_theme_color_override("font_color", Color(0.4, 0.4, 0.5))
	_stats_content.add_child(arr)

	# 4. New Value (Red/Green)
	var v_new := Label.new()
	v_new.text = "%.1f" % next_val
	var is_better := (diff > 0.001 and higher_is_better) or (diff < -0.001 and not higher_is_better)
	v_new.add_theme_color_override("font_color", Color(0.4, 1.0, 0.4) if is_better else Color(1.0, 0.4, 0.4))
	v_new.add_theme_font_size_override("font_size", 14)
	_stats_content.add_child(v_new)

	# Spacers for GridContainer columns (6 columns total)
	_stats_content.add_child(Control.new())
	_stats_content.add_child(Control.new())

func _build_death_overlay() -> void:
	_death_overlay = ColorRect.new()
	_death_overlay.name = "DeathOverlay"
	_death_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_death_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_death_overlay.color = Color(0.8, 0, 0, 0) # Start transparent red
	$HUD.add_child(_death_overlay)
	# Place it above the ghost shader (index 0) but still at the back of the HUD
	$HUD.move_child(_death_overlay, 1)

func show_death_effect(show: bool) -> void:
	if _death_overlay == null: return

	if _death_overlay.has_meta("tween"):
		var old_tw: Tween = _death_overlay.get_meta("tween")
		if old_tw and old_tw.is_valid():
			old_tw.kill()

	var tw := _death_overlay.create_tween()
	_death_overlay.set_meta("tween", tw)

	if show:
		# Rapidly surge to 100% solid red and HOLD it
		_death_overlay.color.a = 0.6
		tw.tween_property(_death_overlay, "color", Color(0.65, 0.0, 0.0, 1.0), 0.4).set_trans(Tween.TRANS_SINE)
	else:
		# Fade out only when told to (at respawn)
		tw.tween_property(_death_overlay, "color:a", 0.0, 0.5).set_trans(Tween.TRANS_CUBIC)

func _on_rematch_pressed() -> void:
	if _rematch_requested:
		return
	_rematch_requested = true
	_rematch_button.text = "REMATCH REQUESTED"
	_rematch_button.disabled = true
	_extend_button.disabled = true
	if multiplayer.is_server():
		_server_rematch_requested()
	else:
		_server_rematch_requested.rpc_id(1)

func _on_extend_pressed() -> void:
	_extend_button.text = "VOTED TO EXTEND"
	_extend_button.disabled = true
	if multiplayer.is_server():
		_server_extend_vote(multiplayer.get_unique_id())
	else:
		_server_extend_vote.rpc_id(1, multiplayer.get_unique_id())

@rpc("any_peer", "call_local", "reliable")
func _server_extend_vote(player_id: int) -> void:
	if not multiplayer.is_server():
		return
	if state != State.MATCH_OVER:
		return
	_extend_votes[player_id] = true

	# Check if everyone has voted to extend
	var all_voted := true
	for pid in NetworkManager.players:
		# Bots always effectively vote 'yes' instantly
		if pid == BOT_ID:
			continue
		if not _extend_votes.get(pid, false):
			all_voted = false
			break

	if all_voted:
		_extend_match()

func _extend_match() -> void:
	# Increase goal, hide UI, continue match
	var new_goal := rounds_to_win + 5
	_set_rounds_to_win.rpc(new_goal)
	_extend_votes.clear()
	show_death_effect(false) # Clear blood if match continues

	# Start a normal round pick flow for the loser of the last round	state = State.PICKING_CARD
	_hide_rematch_overlay.rpc()

	# Find who lost the last round (usually the one who triggered _match_over)
	# We'll let the person who didn't win pick a card.
	for pid in NetworkManager.players:
		if pid != round_winner_id:
			_begin_card_pick_for_loser(pid)

@rpc("authority", "call_local", "reliable")
func _set_rounds_to_win(count: int) -> void:
	rounds_to_win = count

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
	if _tab_root and _tab_root.visible:
		return true
	return false

# -------------------- PAUSE MENU (ESC) --------------------

func _toggle_pause_menu() -> void:
	if _pause_menu == null:
		_build_pause_menu()
	_pause_menu.visible = not _pause_menu.visible
	if _pause_menu.visible:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		# Pause the world if this is a solo match (local player + bots only).
		if NetworkManager.players.size() <= 1:
			get_tree().paused = true
	else:
		# Unpause if we were paused.
		get_tree().paused = false
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
	get_tree().paused = false
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
		var marker := "  ★" if wins >= rounds_to_win else ""
		var pname := str(NetworkManager.players[id])
		lines.append("%s  %d/%d%s" % [pname, wins, rounds_to_win, marker])

	scoreboard.text = "\n".join(lines)

# -------------------- TAB SCOREBOARD OVERLAY --------------------

func _build_tab_overlay() -> void:
	_tab_root = PanelContainer.new()
	_tab_root.anchor_left = 0.5
	_tab_root.anchor_right = 0.5
	_tab_root.anchor_top = 0.12
	_tab_root.anchor_bottom = 0.88
	_tab_root.offset_left = -360.0
	_tab_root.offset_right = 360.0
	_tab_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tab_root.visible = false
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.04, 0.07, 0.93)
	style.set_border_width_all(2)
	style.border_color = Color(1.0, 0.85, 0.4, 0.8)
	style.set_corner_radius_all(6)
	style.content_margin_left = 20
	style.content_margin_right = 20
	style.content_margin_top = 16
	style.content_margin_bottom = 16
	_tab_root.add_theme_stylebox_override("panel", style)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_tab_root.add_child(scroll)
	_tab_content = VBoxContainer.new()
	_tab_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tab_content.add_theme_constant_override("separation", 10)
	scroll.add_child(_tab_content)
	$HUD.add_child(_tab_root)

func _show_tab_overlay() -> void:
	if _tab_root == null:
		_build_tab_overlay()
	_refresh_tab_overlay()
	_tab_root.visible = true

func _hide_tab_overlay() -> void:
	if _tab_root:
		_tab_root.visible = false

func _refresh_tab_overlay() -> void:
	for c in _tab_content.get_children():
		c.queue_free()
	var header := Label.new()
	header.text = "SCOREBOARD"
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.add_theme_font_size_override("font_size", 28)
	header.add_theme_color_override("font_color", Color(1, 0.9, 0.5))
	_tab_content.add_child(header)
	var sub := Label.new()
	sub.text = "first to %d rounds wins" % rounds_to_win
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 13)
	sub.add_theme_color_override("font_color", Color(0.65, 0.65, 0.8))
	_tab_content.add_child(sub)
	_tab_content.add_child(HSeparator.new())
	for id in NetworkManager.players:
		_tab_content.add_child(_tab_player_row(int(id)))

func _tab_player_row(id: int) -> Control:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	# Name + kills line
	var hbox := HBoxContainer.new()
	var nlbl := Label.new()
	nlbl.text = str(NetworkManager.players.get(id, "Player"))
	nlbl.add_theme_font_size_override("font_size", 20)
	nlbl.add_theme_color_override("font_color", Color(1, 1, 1))
	nlbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(nlbl)
	var wins := int(round_wins.get(id, 0))
	var score_lbl := Label.new()
	score_lbl.text = "%d / %d" % [wins, rounds_to_win]
	score_lbl.add_theme_font_size_override("font_size", 20)
	score_lbl.add_theme_color_override("font_color", Color(1, 0.85, 0.4))
	hbox.add_child(score_lbl)
	row.add_child(hbox)
	# Cards as colored pills (empty for fresh players).
	var p_node := players_root.get_node_or_null(str(id))
	if p_node and p_node.get("weapon") != null:
		var cards: Array = p_node.weapon.applied_cards
		if cards.is_empty():
			var empty_lbl := Label.new()
			empty_lbl.text = "    (no cards)"
			empty_lbl.add_theme_font_size_override("font_size", 12)
			empty_lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
			row.add_child(empty_lbl)
		else:
			var flow := HFlowContainer.new()
			flow.add_theme_constant_override("h_separation", 6)
			flow.add_theme_constant_override("v_separation", 4)
			for cid in cards:
				var cdata := CardLibrary.by_id(str(cid))
				if cdata.is_empty():
					continue
				flow.add_child(_tab_card_pill(str(cdata.get("name", cid)), cdata.get("color", Color.WHITE)))
			row.add_child(flow)
	return row

func _tab_card_pill(text: String, col: Color) -> Control:
	var pc := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(col.r * 0.22, col.g * 0.22, col.b * 0.22, 0.95)
	sb.border_color = col
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(3)
	sb.content_margin_left = 7
	sb.content_margin_right = 7
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	pc.add_theme_stylebox_override("panel", sb)
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.add_theme_color_override("font_color", col)
	pc.add_child(lbl)
	return pc

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
	_dev_heading("— CARDS —", Color(1.0, 0.6, 0.9), 15)
	if local_player and is_instance_valid(local_player):
		var applied: Array = local_player.weapon.applied_cards
		var counts := {}
		for cid in applied:
			counts[cid] = counts.get(cid, 0) + 1

		for card in CardLibrary.all():
			_dev_card_row(card, counts.get(card.id, 0))
	else:
		_dev_note("(local player not spawned)")

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

func _dev_card_row(card: Dictionary, count: int) -> void:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 10)

	var n := Label.new()
	n.text = "%s  —  %s" % [card.name, card.desc]
	n.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	n.add_theme_color_override("font_color", card.color)
	hbox.add_child(n)

	var clbl := Label.new()
	clbl.text = str(count)
	clbl.custom_minimum_size = Vector2(30, 0)
	clbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	clbl.add_theme_color_override("font_color", Color(1, 1, 1) if count > 0 else Color(0.4, 0.4, 0.4))
	hbox.add_child(clbl)

	var btn_minus := Button.new()
	btn_minus.text = "-"
	btn_minus.custom_minimum_size = Vector2(30, 30)
	btn_minus.focus_mode = Control.FOCUS_NONE
	btn_minus.disabled = count <= 0
	btn_minus.pressed.connect(_dev_remove_card.bind(card.id))
	hbox.add_child(btn_minus)

	var btn_plus := Button.new()
	btn_plus.text = "+"
	btn_plus.custom_minimum_size = Vector2(30, 30)
	btn_plus.focus_mode = Control.FOCUS_NONE
	btn_plus.pressed.connect(_dev_apply_card.bind(card.id))
	hbox.add_child(btn_plus)

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
