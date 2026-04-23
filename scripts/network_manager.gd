extends Node

const PORT := 27015
const MAX_PLAYERS := 8
const DEFAULT_ADDRESS := "127.0.0.1"

signal player_list_changed

var players: Dictionary = {}
var local_player_name: String = "Player"

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
	return true

func leave_game() -> void:
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
