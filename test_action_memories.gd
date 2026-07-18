extends Node
# Headless test confirming actions, stockpile access, vision, and sound all
# become real memories tied into the LLM context. Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path . res://test_action_memories.tscn --quit
#
# Before this: orders given through the numeric-key path (_apply_command() ->
# set_standing()/begin_build()/clear_standing()) never became memories at
# all -- only orders typed/spoken through TribeCommand did. And sight/hearing
# were live brain state ONLY, never anything an NPC could recall afterward.

const SpatialGrid = preload("res://spatial_grid.gd")

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  ACTION MEMORIES -- orders, vision, and hearing all persist")
	print("=".repeat(60))

	TribeMemory._mem.clear()
	TribeMemory._pending.clear()

	# scenario A: a numeric-key-path order (set_standing) must leave a memory
	var m1 := _spawn_member()
	m1.set_standing("gather", 50)
	_check("set_standing() (the numeric-key order path) writes a real memory",
		_has_memory_type("TestSubject", "ordered"))

	# scenario B: clearing standing orders ([0] auto) also leaves a memory
	TribeMemory._mem.clear()
	m1.clear_standing()
	_check("clear_standing() ([0] auto) also writes a real memory",
		_has_memory_type("TestSubject", "ordered"))

	# scenario C: begin_build() ([5] build) writes a memory too, guarded by
	# a fake manager exposing fence_ring_plan()
	TribeMemory._mem.clear()
	var m2 := _spawn_member()
	m2.manager = _fake_build_manager()
	m2.begin_build()
	_check("begin_build() ([5] build) writes a real memory",
		_has_memory_type("TestSubject", "ordered"))

	# scenario D: a genuine sighting (not-seeing -> seeing) writes a memory
	TribeMemory._mem.clear()
	var m3 := _spawn_member()
	var rival := _spawn_fake(m3.global_position + Vector3(3, 0, 0), "npc")
	m3._sense_environment()
	_check("a new sighting of a rival writes a real 'saw_raider' memory",
		_has_memory_type("TestSubject", "saw_raider"))

	# scenario E: staying in sight (already seeing) must NOT spam a new
	# memory every poll -- one sighting is one memory, not one per tick
	var before_count: int = TribeMemory._mem.get("TestSubject", []).size()
	m3._sense_environment()
	m3._sense_environment()
	var after_count: int = TribeMemory._mem.get("TestSubject", []).size()
	_check("staying in sight across repeated polls does NOT add new memories "
		+ "(transition-gated, not spammed every 1.5s)", after_count == before_count)
	rival.queue_free()
	SpatialGrid.remove(rival)

	# scenario F: a real combat-noise event (hearing, not sight) writes a
	# memory every time it happens -- this one IS already event-based
	# (called once per hit), not polled, so no transition-gate is needed
	TribeMemory._mem.clear()
	var m4 := _spawn_member()
	m4._hear_combat(10.0)
	_check("a heard (not seen) combat event writes a real 'heard_danger' memory",
		_has_memory_type("TestSubject", "heard_danger"))

	# scenario G: all of this is reachable through context_for(), the exact
	# channel that feeds the LLM prompt -- not just sitting in _mem unused
	TribeMemory._mem.clear()
	TribeMemory._pending.clear()
	TribeMemory.remember("TestSubject", "saw_raider", "You",
		"I spotted a rival tribesperson nearby.", "wary", 0.0)
	var ctx: String = TribeMemory.context_for("TestSubject", "You")
	_check("a vision memory actually surfaces through context_for() -- the "
		+ "same call tribe_chat.gd/tribe_talk.gd use to build the LLM prompt",
		"spotted a rival" in ctx)

	m1.queue_free()
	m2.queue_free()
	m3.queue_free()
	m4.queue_free()

	print("\n" + "-".repeat(42))
	print("  %d passed, %d FAILED" % [_pass, _fail])
	print("-".repeat(42) + "\n")
	get_tree().quit(1 if _fail > 0 else 0)

func _has_memory_type(agent: String, event_type: String) -> bool:
	for m in TribeMemory._mem.get(agent, []):
		if m["type"] == event_type:
			return true
	return false

func _spawn_member() -> Node3D:
	var m := CharacterBody3D.new()
	m.set_script(load("res://tribemember.gd"))
	add_child(m)
	m.member_name = "TestSubject"
	m.global_position = Vector3.ZERO
	SpatialGrid.update(m)
	return m

func _spawn_fake(pos: Vector3, group: String) -> Node3D:
	var n := Node3D.new()
	add_child(n)
	n.global_position = pos
	n.add_to_group(group)
	SpatialGrid.update(n)
	return n

func _fake_build_manager() -> Node:
	var script := GDScript.new()
	script.source_code = """
extends Node
func fence_ring_plan() -> Array:
	return []
"""
	script.reload()
	var n := Node.new()
	n.set_script(script)
	add_child(n)
	return n

func _check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  ok    %s" % label)
	else:
		_fail += 1
		print("  FAIL  %s" % label)
