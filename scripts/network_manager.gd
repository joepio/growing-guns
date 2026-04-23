extends Node

const PORT := 27015
const MAX_PLAYERS := 8
const DEFAULT_ADDRESS := "127.0.0.1"

const DISCOVERY_PORT := 27016
const DISCOVERY_INTERVAL := 1.5

signal player_list_changed
signal game_discovered(games: Dictionary)

var players: Dictionary = {}
var local_player_name: String = "Player"

var discovered_games: Dictionary = {} # addr -> {name, count, time}
var _udp_peer: PacketPeerUDP = null
var _discovery_timer: float = 0.0

func _process(delta: float) -> void:
	if _udp_peer:
		if multiplayer.is_server():
			_discovery_timer += delta
			if _discovery_timer >= DISCOVERY_INTERVAL:
				_discovery_timer = 0.0
				_broadcast_game_status()
		else:
			_listen_for_games()
			_cleanup_old_games(delta)

func start_discovery() -> void:
	discovered_games.clear()
	_udp_peer = PacketPeerUDP.new()
	if multiplayer.is_server():
		_udp_peer.set_broadcast_enabled(true)
		_udp_peer.set_dest_address("255.255.255.255", DISCOVERY_PORT)
	else:
		var err := _udp_peer.bind(DISCOVERY_PORT)
		if err != OK:
			push_error("Failed to bind discovery port: %s" % err)
			_udp_peer = null

func stop_discovery() -> void:
	if _udp_peer:
		_udp_peer.close()
		_udp_peer = null
	discovered_games.clear()

func _broadcast_game_status() -> void:
	if not _udp_peer: return
	var data := {
		"name": local_player_name,
		"players": players.size(),
		"max": MAX_PLAYERS
	}
	var msg := JSON.stringify(data)
	_udp_peer.put_packet(msg.to_utf8_buffer())

func _listen_for_games() -> void:
	while _udp_peer and _udp_peer.get_available_packet_count() > 0:
		var packet: PackedByteArray = _udp_peer.get_packet()
		var addr: String = _udp_peer.get_packet_ip()
		var msg: String = packet.get_string_from_utf8()
		var json: Variant = JSON.parse_string(msg)
		if json is Dictionary:
			discovered_games[addr] = {
				"name": json.get("name", "Unknown"),
				"players": json.get("players", 1),
				"max": json.get("max", MAX_PLAYERS),
				"time": Time.get_ticks_msec()
			}
			game_discovered.emit(discovered_games)

func _cleanup_old_games(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	var changed := false
	for addr in discovered_games.keys():
		if now - discovered_games[addr].time > 5000:
			discovered_games.erase(addr)
			changed = true
	if changed:
		game_discovered.emit(discovered_games)

func host_game(player_name: String) -> bool:
	local_player_name = player_name
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT, MAX_PLAYERS)
	if err != OK:
		push_error("Failed to create server: %s" % err)
		return false
	multiplayer.multiplayer_peer = peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	players[1] = player_name
	player_list_changed.emit()

	start_discovery() # Start broadcasting as soon as we host
	return true

func join_game(address: String, player_name: String) -> bool:
	local_player_name = player_name
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, PORT)
	if err != OK:
		push_error("Failed to create client: %s" % err)
		return false
	multiplayer.multiplayer_peer = peer
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

	stop_discovery() # Stop looking once we join one
	return true

func auto_connect(player_name: String) -> bool:
	for arg in _launch_args():
		if arg == "--host":
			print("[auto_connect] forced HOST via --host")
			return host_game(player_name)
		if arg.begins_with("--join="):
			var address := arg.trim_prefix("--join=").strip_edges()
			if address.is_empty():
				push_error("Auto-connect: --join requires an address")
				return false
			print("[auto_connect] forced JOIN to %s via --join" % address)
			return join_game(address, player_name)

	# First peer to launch binds the port and becomes host; later launches
	# fail to bind and fall back to connecting to that host.
	local_player_name = player_name
	var server_peer := ENetMultiplayerPeer.new()
	var server_err := server_peer.create_server(PORT, MAX_PLAYERS)
	print("[auto_connect] create_server on port %d -> %s" % [PORT, error_string(server_err)])
	if server_err == OK:
		multiplayer.multiplayer_peer = server_peer
		multiplayer.peer_connected.connect(_on_peer_connected)
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
		players[1] = player_name
		player_list_changed.emit()
		print("[auto_connect] became HOST as '%s'" % player_name)
		return true
	var client_peer := ENetMultiplayerPeer.new()
	var client_err := client_peer.create_client(DEFAULT_ADDRESS, PORT)
	print("[auto_connect] create_client to %s:%d -> %s" % [DEFAULT_ADDRESS, PORT, error_string(client_err)])
	if client_err != OK:
		push_error("Auto-connect: failed to create client")
		return false
	multiplayer.multiplayer_peer = client_peer
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	print("[auto_connect] trying to JOIN as '%s'" % player_name)
	return true

func _launch_args() -> Array[String]:
	var out: Array[String] = []
	for arg in OS.get_cmdline_user_args():
		out.append(arg)
	for arg in OS.get_cmdline_args():
		if arg not in out:
			out.append(arg)
	print("[auto_connect] launch args: %s" % str(out))
	return out

func leave_game() -> void:
	stop_discovery()
	if multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	players.clear()
	player_list_changed.emit()

func _on_peer_connected(id: int) -> void:
	# Server registers newcomer; newcomer will send its name via RPC.
	if multiplayer.is_server():
		# Send existing players to the newcomer
		for pid in players:
			_register_player.rpc_id(id, pid, players[pid])

func _on_peer_disconnected(id: int) -> void:
	players.erase(id)
	player_list_changed.emit()
	if multiplayer.is_server():
		_unregister_player.rpc(id)

func _on_connected_to_server() -> void:
	var my_id := multiplayer.get_unique_id()
	players[my_id] = local_player_name
	_register_player.rpc(my_id, local_player_name)
	player_list_changed.emit()

func _on_connection_failed() -> void:
	push_error("Connection failed")
	multiplayer.multiplayer_peer = null

func _on_server_disconnected() -> void:
	stop_discovery()
	players.clear()
	multiplayer.multiplayer_peer = null
	player_list_changed.emit()
	get_tree().change_scene_to_file("res://scenes/main.tscn")

@rpc("any_peer", "call_local", "reliable")
func _register_player(id: int, pname: String) -> void:
	players[id] = pname
	player_list_changed.emit()

@rpc("authority", "call_local", "reliable")
func _unregister_player(id: int) -> void:
	players.erase(id)
	player_list_changed.emit()
