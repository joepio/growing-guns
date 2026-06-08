extends Node

const DestructibleManager = preload("res://scripts/destructible_manager.gd")

# Flushes batched destructible mesh rebuilds once per physics tick.


func _physics_process(_delta: float) -> void:
	DestructibleManager.flush()
	Violence.flush_destruction_debris()
