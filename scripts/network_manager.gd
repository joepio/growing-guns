extends Node

# Multiplayer transport coordinator. Iroh-only — see scripts/dev_panel.gd
# AGENTS.md notes for the LAN/ENet history. This script:
#   • host_game_iroh(name) → "" or game_id            (start as host)
#   • join_game_iroh(id, name) → bool                 (start as client)
#   • leave_game()                                    (tear down peer + bookkeeping)
#   • current_iroh_game_id                            (the game ID we're hosting; "" if client)
#   • players: Dictionary[int peer_id → String name]  (replicated via _register_player RPC)
#   • signals: player_list_changed                    (UI hooks listen)

signal player_list_changed
signal network_status_changed(message: String, is_error: bool)

var players: Dictionary = {}
var local_player_name: String = "Player"
var last_network_error: String = ""

# Current iroh server's game ID (the connection string peers paste to join).
# Empty when not hosting via iroh — e.g. when this peer is an iroh client.
var current_iroh_game_id: String = ""


# ── Iroh (internet P2P, no port forwarding) ────────────────────────────────
# Uses the godot-iroh GDExtension (addons/godot_iroh). Two peers connect via
# QUIC over iroh's relay/hole-punching network using a node-id "game ID"
# string — no LAN-only assumption, no public IP needed.

# Host a game over iroh. Returns the game ID (node connection string) on
# success — share it with peers. Returns "" on failure.
func host_game_iroh(player_name: String) -> String:
	local_player_name = player_name
	last_network_error = ""
	if not ClassDB.class_exists("IrohServer"):
		return _fail("Iroh networking failed to load. Re-extract the zip so MoreRounds.exe, MoreRounds.pck, and godot_iroh.dll are in the same folder.")
	_emit_status("Starting online host...", false)
	var server = ClassDB.class_call_static("IrohServer", "start")
	if server == null:
		return _fail("Couldn't start the online host. Windows Firewall or security software most likely blocked it — allow \"Growing Guns\" through the firewall, or check your network connection.")
	multiplayer.multiplayer_peer = server
	_connect_host_signals_once()
	players[1] = player_name
	current_iroh_game_id = server.connection_string()
	if current_iroh_game_id.is_empty():
		return _fail("Iroh host started but did not return a match ID.")
	player_list_changed.emit()
	_emit_status("Online host ready.", false)
	return current_iroh_game_id

# Join a game over iroh by its game ID. Returns true if the connection
# attempt was kicked off (the actual handshake is async — listen on
# multiplayer.connected_to_server / connection_failed).
func join_game_iroh(game_id: String, player_name: String) -> bool:
	local_player_name = player_name
	last_network_error = ""
	if not ClassDB.class_exists("IrohClient"):
		_fail("Iroh networking failed to load. Re-extract the zip so MoreRounds.exe, MoreRounds.pck, and godot_iroh.dll are in the same folder.")
		return false
	_emit_status("Connecting to host...", false)
	var client = ClassDB.class_call_static("IrohClient", "connect", game_id)
	if client == null:
		_fail("Could not start the iroh client. Check the match ID, firewall, and whether the game folder was fully extracted.")
		return false
	multiplayer.multiplayer_peer = client
	_connect_client_signals_once()
	current_iroh_game_id = ""  # we're a client; we don't have our own game ID to share
	return true

# Tear down whatever peer we have (host or client). Used by the pause menu's
# Join flow before swapping to an IrohClient and reloading game.tscn.
func leave_game() -> void:
	if multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	players.clear()
	current_iroh_game_id = ""
	last_network_error = ""
	player_list_changed.emit()


# ── Signal wiring (idempotent) ─────────────────────────────────────────────
# Both host and client paths route through the same player-list bookkeeping
# below, so the signal handlers are wired once per role and re-used.

func _connect_host_signals_once() -> void:
	if not multiplayer.peer_connected.is_connected(_on_peer_connected):
		multiplayer.peer_connected.connect(_on_peer_connected)
	if not multiplayer.peer_disconnected.is_connected(_on_peer_disconnected):
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)


func _connect_client_signals_once() -> void:
	if not multiplayer.connected_to_server.is_connected(_on_connected_to_server):
		multiplayer.connected_to_server.connect(_on_connected_to_server)
	if not multiplayer.connection_failed.is_connected(_on_connection_failed):
		multiplayer.connection_failed.connect(_on_connection_failed)
	if not multiplayer.server_disconnected.is_connected(_on_server_disconnected):
		multiplayer.server_disconnected.connect(_on_server_disconnected)


# ── Peer/player bookkeeping ────────────────────────────────────────────────

func _on_peer_connected(id: int) -> void:
	# Server registers newcomer; newcomer will send its name via _register_player RPC.
	if multiplayer.is_server():
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
	_emit_status("Connected to host.", false)


func _on_connection_failed() -> void:
	var message := "Connection failed. Confirm the match ID, make sure the host is still running, and allow the game through Windows Firewall."
	_fail(message)
	multiplayer.multiplayer_peer = null
	players.clear()
	current_iroh_game_id = ""
	set_meta("network_notice", message)
	player_list_changed.emit()
	get_tree().change_scene_to_file("res://scenes/game.tscn")


func _on_server_disconnected() -> void:
	players.clear()
	current_iroh_game_id = ""
	multiplayer.multiplayer_peer = null
	var message := "Disconnected from host. Returning to solo play."
	_fail(message)
	set_meta("network_notice", message)
	player_list_changed.emit()
	# No main menu in the new flow — reloading game.tscn re-hosts a fresh
	# iroh server in _ready, putting the user back into solo-vs-AI.
	get_tree().change_scene_to_file("res://scenes/game.tscn")


@rpc("any_peer", "call_local", "reliable")
func _register_player(id: int, pname: String) -> void:
	players[id] = pname
	player_list_changed.emit()


@rpc("authority", "call_local", "reliable")
func _unregister_player(id: int) -> void:
	players.erase(id)
	player_list_changed.emit()


func _emit_status(message: String, is_error: bool) -> void:
	if is_error:
		push_error(message)
	else:
		print(message)
	network_status_changed.emit(message, is_error)


func _fail(message: String) -> String:
	last_network_error = message
	_emit_status(message, true)
	return ""
