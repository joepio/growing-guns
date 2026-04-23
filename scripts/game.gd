extends Node3D

const PLAYER_SCENE := preload("res://scenes/player.tscn")

enum State { WAITING, PLAYING, PICKING_CARD, MATCH_OVER }

const ROUNDS_TO_WIN := 3
const CARDS_PER_PICK := 3
const SPAWN_CAPSULE_RADIUS := 0.4
const SPAWN_CAPSULE_HEIGHT := 1.8

@onready var players_root: Node3D = $Players
@onready var health_label: Label = $HUD/HealthPanel/HealthLabel
@onready var scoreboard: Label = $HUD/Scoreboard
@onready var hitmarker: Label = $HUD/Hitmarker
@onready var hitmarker_timer: Timer = $HUD/HitmarkerTimer
@onready var rifle_bar: ProgressBar = $HUD/AbilityBar/Rifle/Bar
@onready var grenade_bar: ProgressBar = $HUD/AbilityBar/Grenade/Bar
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
var local_player: Node3D

func _ready() -> void:
	if not multiplayer.multiplayer_peer:
		get_tree().change_scene_to_file("res://scenes/main.tscn")
		return

	NetworkManager.player_list_changed.connect(_update_scoreboard)
	hitmarker_timer.timeout.connect(func() -> void: hitmarker.visible = false)
	banner_timer.timeout.connect(func() -> void: round_banner.visible = false)
	pick_overlay.visible = false
	round_banner.visible = false

	if multiplayer.is_server():
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
		for pid in NetworkManager.players:
			round_wins[pid] = 0
			_spawn_player(pid, NetworkManager.players[pid])
		_maybe_start_match()
	else:
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
		health_label.text = "HP  %d" % local_player.health
		_refresh_cooldowns()

func _refresh_cooldowns() -> void:
	var w: Weapon = local_player.weapon
	if local_player.reloading:
		rifle_bar.value = 1.0 - (local_player.rifle_cooldown / max(0.01, w.get_reload_time()))
	else:
		rifle_bar.value = float(local_player.mag) / float(w.get_mag_size())
	grenade_bar.value = 1.0 - (local_player.grenade_cooldown / local_player.GRENADE_RELOAD)
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
	if NetworkManager.players.size() < 2:
		state = State.WAITING
		_hide_card_pick.rpc()
		_announce.rpc("WAITING FOR PLAYERS…", 99.0)

@rpc("any_peer", "call_local", "reliable")
func _request_spawn(pname: String) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = 1
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
	var pos := _random_spawn()
	_do_spawn.rpc(id, pname, pos)

func _random_spawn() -> Vector3:
	var spawns := get_tree().get_nodes_in_group("spawnpoints")
	if spawns.is_empty():
		return Vector3(0, 3, 0)
	spawns.shuffle()
	for spawn in spawns:
		var pos: Vector3 = spawn.global_position
		if _spawn_is_clear(pos):
			return pos
	return spawns[0].global_position

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
func _do_spawn(id: int, pname: String, pos: Vector3) -> void:
	if players_root.has_node(str(id)):
		return
	var p := PLAYER_SCENE.instantiate()
	p.name = str(id)
	p.player_id = id
	p.player_name = pname
	p.global_position = pos
	players_root.add_child(p, true)
	if id == multiplayer.get_unique_id():
		local_player = p

@rpc("authority", "call_local", "reliable")
func _despawn(id: int) -> void:
	var node := players_root.get_node_or_null(str(id))
	if node:
		node.queue_free()

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
	_start_round_now()

func _start_round_now() -> void:
	# Respawn everyone, reset HP + cooldowns, unfreeze, announce.
	for pid in NetworkManager.players:
		var p := players_root.get_node_or_null(str(pid))
		if not p:
			continue
		p.server_respawn.rpc_id(pid, _random_spawn())
		p.set_frozen.rpc(false)
	_announce.rpc("ROUND %d" % current_round, 1.4)

func report_kill(killer_id: int, victim_id: int) -> void:
	# Called on the server by Player._report_death. Ends the round.
	if not multiplayer.is_server():
		return
	if state != State.PLAYING:
		return
	# Self-kill (pit death, etc.): award the round to the other player in 2p;
	# for larger lobbies, pick the first other player as the winner.
	if killer_id == victim_id or killer_id == 0:
		killer_id = 0
		for pid in NetworkManager.players:
			if int(pid) != victim_id:
				killer_id = int(pid)
				break
	_end_round(killer_id, victim_id)

func _end_round(winner_id: int, loser_id: int) -> void:
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
	# Freeze all, prompt loser to pick a card.
	state = State.PICKING_CARD
	pending_picker_id = loser_id
	pending_pick_cards = CardLibrary.random_ids(CARDS_PER_PICK)
	for pid in NetworkManager.players:
		var p := players_root.get_node_or_null(str(pid))
		if p:
			p.set_frozen.rpc(true)
	_show_card_pick.rpc(loser_id, pending_pick_cards)

# -------------------- CARD PICK UI --------------------

@rpc("authority", "call_local", "reliable")
func _show_card_pick(loser_id: int, card_ids: Array) -> void:
	pick_overlay.visible = true
	var my_id := multiplayer.get_unique_id()
	var is_me := loser_id == my_id
	var loser_name: String = NetworkManager.players.get(loser_id, "Player")
	if is_me:
		pick_title.text = "PICK A CARD"
		pick_subtitle.text = "you lost the round — choose an upgrade"
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		pick_title.text = "ROUND OVER"
		pick_subtitle.text = "waiting for %s to pick a card…" % loser_name
	_populate_cards(card_ids, is_me)

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
	if state != State.PICKING_CARD:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = multiplayer.get_unique_id()
	if sender != pending_picker_id:
		return
	if not pending_pick_cards.has(card_id):
		return
	var p := players_root.get_node_or_null(str(pending_picker_id))
	if p:
		p.apply_card.rpc(card_id)
	_hide_card_pick.rpc()
	current_round += 1
	state = State.PLAYING
	_start_round_now()

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
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

@rpc("authority", "call_local", "reliable")
func _broadcast_scores(scores: Dictionary) -> void:
	round_wins = scores
	_update_scoreboard()

func show_hitmarker(is_headshot: bool) -> void:
	hitmarker.text = "X!" if is_headshot else "X"
	hitmarker.modulate = Color(1, 0.3, 0.3) if not is_headshot else Color(1, 0.9, 0.2)
	hitmarker.visible = true
	hitmarker_timer.start()

func _update_scoreboard() -> void:
	var lines: Array[String] = ["— ROUNDS —"]
	for id in NetworkManager.players:
		var wins := int(round_wins.get(id, 0))
		var marker := "  ★" if wins >= ROUNDS_TO_WIN else ""
		lines.append("%s  %d/%d%s" % [NetworkManager.players[id], wins, ROUNDS_TO_WIN, marker])
	scoreboard.text = "\n".join(lines)
