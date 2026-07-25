extends Node
# Headless test for two fixes:
#   1. members no longer dogpile the same work node (bush/animal/tree/wanderer)
#   2. the fortress build plan is genuinely elaborate (3-course walls + towers)
# Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path . res://test_no_pileup_complex_build.tscn --quit

const SpatialGrid = preload("res://spatial_grid.gd")
const TribeManagerScript = preload("res://Tribemanager.gd")

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  NO SAME-NODE PILEUP + ELABORATE FORTRESS BUILD")
	print("=".repeat(60))

	# scenario A: a single food source, one member already working it -- a
	# second member's own picker must NOT pick the same bush
	var bush := _fake_food_source(Vector3(2, 0, 0))
	var claimer := _spawn_member("Claimer", Vector3(1, 0, 0))
	claimer._target_node = bush
	var seeker := _spawn_member("Seeker", Vector3(3, 0, 0))
	_check("a bush already claimed by another member is not picked again",
		seeker._nearest_food_source() == null)
	# free() not queue_free(): later scenarios reuse the "food_source"/"tribe"
	# groups in the SAME frame, and queue_free() only removes group
	# membership at end-of-frame -- a still-pending-deletion bush from an
	# earlier scenario would otherwise silently compete as a real candidate.
	claimer.free()
	bush.free()
	seeker.free()

	# scenario B: same bush, but nobody has claimed it -- must still be found
	var bush2 := _fake_food_source(Vector3(2, 0, 0))
	var seeker2 := _spawn_member("Seeker2", Vector3(3, 0, 0))
	_check("an unclaimed bush is still found normally",
		seeker2._nearest_food_source() == bush2)
	seeker2.free()
	bush2.free()

	# scenario C: two bushes -- one claimed, one free. The claimed one being
	# CLOSER must not matter; the seeker should still land on the free one.
	var near_claimed := _fake_food_source(Vector3(1, 0, 0))
	var far_free := _fake_food_source(Vector3(6, 0, 0))
	var other := _spawn_member("Other", Vector3(1, 0, 0))
	other._target_node = near_claimed
	var picker := _spawn_member("Picker", Vector3(0, 0, 0))
	_check("a closer but claimed node is skipped in favor of a free one",
		picker._nearest_food_source() == far_free)
	other.free(); picker.free()
	near_claimed.free(); far_free.free()

	# scenario D: the fortress build plan is genuinely more elaborate than a
	# bare two-course ring -- real height (a third course + towers), not just
	# a bigger flat footprint.
	var mgr := TribeManagerScript.new()
	var plan: Array = mgr.fence_ring_plan()
	var max_y := 0.0
	var course5_count := 0
	for seg in plan:
		var y: float = float(seg["pos"].y)
		max_y = maxf(max_y, y)
		if seg.get("kind", "") == "block" and absf(y - 5.0) < 0.01:
			course5_count += 1
	_check("the wall now has real height (a tower course reaches y > 5.0)", max_y > 5.0)
	_check("a genuine third wall course exists (y=5.0 block segments present)", course5_count > 0)
	_check("teepee count grew into a real settlement (8, not the old 4)",
		plan.filter(func(s): return s.get("kind", "") == "teepee").size() == 8)
	mgr.free()

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

## A minimal stand-in exposing exactly what _nearest_food_source() checks:
## group membership, harvest(), and .amount. Real food_source.gd has far
## more, but the picker only ever touches these three.
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
