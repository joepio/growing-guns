extends Node

const DestructibleManager = preload("res://scripts/destructible_manager.gd")

# Flushes batched destructible mesh rebuilds once per physics tick.


func _physics_process(_delta: float) -> void:
	DestructibleManager.update_exposure_lod()
	var t0 := Time.get_ticks_usec()
	DestructibleManager.flush()
	var t1 := Time.get_ticks_usec()
	Violence.flush_destruction_debris()
	var t2 := Time.get_ticks_usec()
	Trace.prof("destruct_flush", t1 - t0)
	Trace.prof("debris_flush", t2 - t1)
	if BenchFlags.active:
		DestructibleManager.bench_destruct_prof("destruct_flush", t1 - t0)
		DestructibleManager.bench_destruct_prof("debris_flush", t2 - t1)
