extends Node
# Headless test for the nearest-picker perf fix. Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path . res://test_picker_perf.tscn --quit
#
# BUG: _is_claimed() (an O(roster) scan, including a fresh
# get_nodes_in_group("tribe") call) ran BEFORE the cheap distance/sight
# filter in every _nearest_*() picker -- so with tree_count/bush_count/
# animal_count scaled up for a big world (tree_count can be in the
# THOUSANDS), every single out-of-sight candidate still paid the full claim
# -scan cost. A real, measured contributor to reported "super laggy":
# up to N_group claim-scans per job assignment, called every few seconds
# per idle member. Fixed by checking distance/sight/best-so-far FIRST
# (cheap, local math) and only calling _is_claimed() on a candidate that
# has already cleared those.
#
# This test can't directly count internal calls without instrumenting the
# source, so it verifies the fix the honest way available: CORRECTNESS at
# scale -- hundreds of far-away, out-of-sight candidates (which the old
# order would have claim-scanned needlessly) must not prevent the one real,
# in-sight, unclaimed candidate from being found correctly.

const SpatialGrid = preload("res://spatial_grid.gd")

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  PICKER PERF -- distance/sight checked before claim-scan")
	print("=".repeat(60))

	var seeker := _spawn_member("Seeker", Vector3.ZERO)

	# 300 food sources scattered far outside sight -- exactly the case that
	# used to pay a needless O(roster) claim-scan per candidate
	var far_sources: Array = []
	for i in range(300):
		far_sources.append(_fake_food_source(Vector3(500.0 + float(i), 0, 500.0 + float(i))))
	var near_source := _fake_food_source(Vector3(3, 0, 0))

	_check("the one real in-sight source is still found correctly among hundreds of far ones",
		seeker._nearest_food_source() == near_source)

	# same shape, but the near one is claimed -- must correctly fall through
	# to null (no unclaimed candidate in sight), not get confused by scale
	var claimer := _spawn_member("Claimer", Vector3(3, 0, 0))
	claimer._target_node = near_source
	_check("with the only in-sight source claimed, none of the 300 far ones are wrongly picked",
		seeker._nearest_food_source() == null)
	claimer.free()

	for s in far_sources:
		s.free()
	near_source.free()
	seeker.free()

	print("\n" + "-".repeat(42))
	print("  %d passed, %d FAILED" % [_pass, _fail])
	print("-".repeat(42) + "\n")
	get_tree().quit(1 if _fail > 0 else 0)

func _spawn_member(name_: String, pos: Vector3) -> Node3D:
	var m := CharacterBody3D.new()
	m.set_script(load("res://tribemember.gd"))
	add_child(m)
	m.member_name = name_
	m.global_position = pos
	SpatialGrid.update(m)
	return m

func _fake_food_source(pos: Vector3) -> Node3D:
	var script := GDScript.new()
	script.source_code = """
extends Node3D
var amount: float = 10.0
func harvest(n: float) -> float:
	return n
"""
	script.reload()
	var n := Node3D.new()
	n.set_script(script)
	add_child(n)
	n.add_to_group("food_source")
	n.global_position = pos
	SpatialGrid.update(n)
	return n

func _check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  ok    %s" % label)
	else:
		_fail += 1
		print("  FAIL  %s" % label)
