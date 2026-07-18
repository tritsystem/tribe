extends Node
# Headless test for settlement district specialization (Phase 6 of "cities,
# communicate, and live amongst other tribes") -- settlements now have real
# variety (Watch/Gathering/Crafting) instead of being identical copies, with
# an actual mechanical payoff (a Watch settlement's residents see farther).
# Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path . res://test_settlement_districts.tscn --quit

const TribeManagerScript = preload("res://Tribemanager.gd")

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  SETTLEMENT DISTRICTS -- real variety + a mechanical payoff")
	print("=".repeat(60))

	var mgr := TribeManagerScript.new()
	add_child(mgr)
	mgr._cat_lines = {"you": [], "tribe": [], "tribes": []}

	# scenario A: founding always assigns a REAL, valid district
	mgr.found_outpost(Vector3(300, 0, 0))
	var sp = mgr.outposts[0]
	_check("a founded settlement is assigned one of the real district types",
		str(sp.get("district")) in mgr.DISTRICT_TYPES)

	# scenario B: sight_bonus_at() -- deterministic, bypassing the random
	# district roll by directly crafting a Watch settlement stand-in
	var watch_sp := Node3D.new()
	add_child(watch_sp)
	watch_sp.set_script(load("res://stockpile.gd"))
	watch_sp.global_position = Vector3(500, 0, 0)
	watch_sp.district = "Watch"
	mgr.outposts.append(watch_sp)

	_check("a position right at a Watch settlement gets the real sight bonus",
		mgr.sight_bonus_at(Vector3(500, 0, 0)) > 1.0)
	_check("a position far from any Watch settlement gets no bonus",
		mgr.sight_bonus_at(Vector3(0, 0, 0)) == 1.0)

	# scenario C: the bonus actually reaches a member's own _effective_sight()
	var m := CharacterBody3D.new()
	m.set_script(load("res://tribemember.gd"))
	add_child(m)
	m.manager = mgr
	m.home_pos = Vector3(500, 0, 0)   # lives at the Watch settlement
	var watch_sight: float = m._effective_sight()
	m.home_pos = Vector3(0, 0, 0)     # lives nowhere near it
	var normal_sight: float = m._effective_sight()
	_check("a member living at a Watch settlement genuinely sees farther than one who doesn't",
		watch_sight > normal_sight)
	m.free()

	# scenario D: a Watch settlement's OWN structures include real block+roof
	# pieces beyond the baseline teepees -- a genuine lookout tower, not just
	# a differently-labelled prop.
	var before_blocks: int = get_tree().get_nodes_in_group("block").size()
	var before_pieces: int = get_tree().get_nodes_in_group("build_piece").size()
	mgr._build_district_structures("Watch", Vector3(700, 0, 0))
	_check("founding a Watch settlement raises real block courses for its tower",
		get_tree().get_nodes_in_group("block").size() > before_blocks)
	_check("...and a real roof piece capping it",
		get_tree().get_nodes_in_group("build_piece").size() > before_pieces)

	mgr.free()

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
