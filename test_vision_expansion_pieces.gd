extends Node
# Headless test for three related fixes:
#   1. task targeting is vision-gated (SIGHT_RADIUS) with progressive
#      outward search when nothing qualifies
#   2. clan expansion: outpost stockpiles, one per 100m radius
#   3. advanced building pieces: stair / roof / small, distinct from a plain
#      wall block
# Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path . res://test_vision_expansion_pieces.tscn --quit

const SpatialGrid = preload("res://spatial_grid.gd")
const TribeManagerScript = preload("res://Tribemanager.gd")
const BuildPieceScript = preload("res://build_piece.gd")

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  VISION-GATED WORK + CLAN EXPANSION + ADVANCED PIECES")
	print("=".repeat(60))

	# scenario A: a food source OUTSIDE sight radius is not picked, even
	# though it's the only candidate in the whole world
	var far_bush := _fake_food_source(Vector3(40, 0, 0))
	var lonely := _spawn_member("Lonely", Vector3.ZERO)
	_check("a food source outside SIGHT_RADIUS is not picked",
		lonely._nearest_food_source() == null)
	far_bush.free()

	# scenario B: the same food source, now within sight, IS picked
	var near_bush := _fake_food_source(Vector3(5, 0, 0))
	_check("a food source within SIGHT_RADIUS is picked normally",
		lonely._nearest_food_source() == near_bush)
	near_bush.free(); lonely.free()

	# scenario C: progressive outward search -- consecutive failed searches
	# push the target further from the member's CURRENT position each time,
	# not a fixed ring, and it resets once real work is found again
	var searcher := _spawn_member("Searcher", Vector3(100, 0, 100))
	searcher._begin_fallback("looking around...")
	var d1: float = searcher.global_position.distance_to(searcher._target)
	searcher._begin_fallback("still looking...")
	var d2: float = searcher.global_position.distance_to(searcher._target)
	_check("each consecutive failed search reaches further than the last",
		d2 > d1)
	_check("the streak counter actually incremented", searcher._search_streak == 2)
	searcher._search_streak = 0   # simulate finding real work again
	_check("the streak resets to zero once real work is found", searcher._search_streak == 0)
	searcher.free()

	# scenario D: clan expansion -- an outpost too close to the home
	# stockpile is rejected; one far enough away is founded
	var mgr := TribeManagerScript.new()
	add_child(mgr)   # needs to be in the tree for get_tree().get_nodes_in_group() to work
	mgr._cat_lines = {"you": [], "tribe": [], "tribes": []}
	var home_sp := Node3D.new()
	home_sp.set_script(load("res://stockpile.gd"))
	# stockpile.gd's own _ready() calls add_to_group("stockpile") and _build();
	# add it under mgr so group lookups (get_tree) see it as a real stockpile.
	mgr.add_child(home_sp)
	home_sp.global_position = Vector3.ZERO

	_check("an outpost within 100m of the home stockpile is rejected",
		not mgr.found_outpost(Vector3(50, 0, 0)))
	_check("an outpost 100m+ from the home stockpile is founded",
		mgr.found_outpost(Vector3(150, 0, 0)))
	_check("a second outpost too close to the FIRST outpost is also rejected",
		not mgr.found_outpost(Vector3(180, 0, 0)))
	_check("a third outpost far from both existing ones is founded",
		mgr.found_outpost(Vector3(400, 0, 0)))
	_check("outposts are tracked, but kept OUT of the single-stockpile group",
		mgr.outposts.size() == 2 and get_tree().get_nodes_in_group("stockpile").size() == 1)

	# scenario E: advanced building pieces are genuinely distinct kinds, not
	# reskinned wall blocks -- and the fortress plan actually places them
	mgr.wood = 100
	var before_stair: int = get_tree().get_nodes_in_group("build_piece").size()
	_check("try_build_stair spends wood and places a STAIR-kind piece",
		mgr.try_build_stair(Vector3(20, 1.0, 0)))
	_check("try_build_roof spends wood and places a ROOF-kind piece",
		mgr.try_build_roof(Vector3(22, 1.0, 0)))
	_check("try_build_small spends wood and places a SMALL-kind piece",
		mgr.try_build_small(Vector3(24, 1.0, 0)))
	_check("all three pieces actually entered the world (build_piece group grew by 3)",
		get_tree().get_nodes_in_group("build_piece").size() == before_stair + 3)

	var plan: Array = mgr.fence_ring_plan()
	var kinds: Dictionary = {}
	for seg in plan:
		var k: String = str(seg.get("kind", ""))
		kinds[k] = int(kinds.get(k, 0)) + 1
	_check("the fortress plan itself now includes real stair segments",
		int(kinds.get("stair", 0)) > 0)
	_check("...and real roof segments", int(kinds.get("roof", 0)) > 0)
	_check("...and fine-detail small segments", int(kinds.get("small", 0)) > 0)

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
	m.home_pos = pos
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
