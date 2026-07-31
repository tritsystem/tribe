extends Node
# Headless test for the "buildings/trees/resources still in wrong spot" bug
# (2026-07-27): npc.gd's assign_build() used to snapshot _build_target as a
# bare world-space Vector3, never refreshed as a turtle island drifts. A
# builder walking toward that fixed point got stranded once the camp moved
# on, and the segment stayed permanently claimed-but-unbuilt. Fix welds
# _build_target to the tribe's CURRENT global_position + a captured offset,
# refreshed every _move() tick (mirrors the home/home_pos weld fixes already
# applied elsewhere).
# Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path . res://test_build_target_drift_weld.tscn --quit

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  BUILD-TARGET DRIFT WELD")
	print("=".repeat(60))

	var tribe := Node3D.new()
	add_child(tribe)
	tribe.global_position = Vector3(0, 0, 0)

	var n := CharacterBody3D.new()
	n.set_script(load("res://npc.gd"))
	add_child(n)
	n.global_position = Vector3(2, 1, 2)
	n.tribe = tribe

	var offset := Vector3(3, 0, 3)
	n.assign_build(tribe.global_position + offset)
	_check("assign_build sets the initial target correctly",
		n._build_target == Vector3(3, 0, 3))
	_check("assign_build captures the right offset from the tribe",
		n._build_offset == offset)

	# simulate the island drifting 40m away over several ticks, the way
	# turtle_island.gd's _turtle_tick nudges global_position each frame
	for i in range(20):
		tribe.global_position += Vector3(2.0, 0.0, 0.0)   # 40m of total drift
		n._move(0.1)

	var expected_target: Vector3 = tribe.global_position + offset
	_check("after 40m of drift, _build_target tracks the tribe's CURRENT position (not the stale spawn-time point)",
		n._build_target.distance_to(expected_target) < 0.01)
	_check("the stale (pre-fix) point is now far from the refreshed target",
		n._build_target.distance_to(Vector3(3, 0, 3)) > 30.0)

	n.free()
	tribe.free()

	print("\n" + "-".repeat(42))
	print("  %d passed, %d FAILED" % [_pass, _fail])
	print("-".repeat(42) + "\n")
	get_tree().quit(1 if _fail > 0 else 0)

func _check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  ok    %s" % label)
	else:
		_fail += 1
		print("  FAIL  %s" % label)
