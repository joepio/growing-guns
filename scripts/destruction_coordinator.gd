extends Node

const DestructibleManager = preload("res://scripts/destructible_manager.gd")

# Flushes batched destructible mesh rebuilds once per physics tick.


func _physics_process(_delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	DestructibleManager.flush()
	var t1 := Time.get_ticks_usec()
	Trace.prof("destruct_flush", t1 - t0)
	if BenchFlags.active:
		DestructibleManager.bench_destruct_prof("destruct_flush", t1 - t0)
