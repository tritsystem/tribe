extends Node
# Headless test for the "outposts become real named settlements" feature
# (Phase 2 of "build cities, communicate, and live amongst other tribes").
# Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path . res://test_settlement_naming.tscn --quit

const TribeManagerScript = preload("res://Tribemanager.gd")

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  SETTLEMENT NAMING -- outposts become real named places")
	print("=".repeat(60))

	var mgr := TribeManagerScript.new()
	add_child(mgr)
	mgr._cat_lines = {"you": [], "tribe": [], "tribes": []}

	var before_teepees: Array = get_tree().get_nodes_in_group("teepee")
	_check("no teepees exist before any outpost is founded", before_teepees.is_empty())

	var ok := mgr.found_outpost(Vector3(200, 0, 0))
	_check("founding a fresh, far-enough outpost succeeds", ok)

	_check("the outpost is tracked", mgr.outposts.size() == 1)
	var sp = mgr.outposts[0]
	_check("the outpost stockpile actually carries a real, non-empty settlement name",
		str(sp.get("settlement_name")) != "")

	# teepee count is 2, or 3 if this settlement happened to roll the
	# "Gathering" district (see Tribemanager._build_district_structures(),
	# added after this test was first written) -- either way, real homes.
	var after_teepees: Array = get_tree().get_nodes_in_group("teepee")
	_check("founding the outpost raises real teepees near it",
		after_teepees.size() == 2 or after_teepees.size() == 3)
	# PRE-EXISTING TEST BUG (found + fixed 2026-07-28, unrelated to tonight's
	# turtle-island work): a full 3D distance_to() here also counts the
	# teepee's height above ground_y() -- in this isolated test (no real
	# terrain, no turtle built), ground_y()'s "nothing built yet" fallback is
	# a nonzero 10.0, which alone exceeds the old 10.0 threshold regardless of
	# how close the teepee actually is in XZ. HORIZONTAL distance only, same
	# reasoning tribemember.gd's own build-plan navigation already uses.
	for t in after_teepees:
		var flat := Vector2((t as Node3D).global_position.x - 200.0, (t as Node3D).global_position.z - 0.0)
		_check("each teepee is actually placed near the outpost, not at the origin",
			flat.length() < 10.0)

	# CRITICAL: these teepees must NOT be swept up by fortress-ring cleanup --
	# they belong to a separate settlement, not the home ring.
	mgr.fence_ring_plan(0)
	mgr.fence_ring_plan(1)   # a tier change clears the HOME ring's tracked pieces
	var still_alive := true
	for t in after_teepees:
		if not is_instance_valid(t) or (t as Node3D).is_queued_for_deletion():
			still_alive = false
	_check("the settlement's teepees survive a home-fortress tier change (they were never tracked in it)",
		still_alive)

	# a second outpost gets a DIFFERENT name (or at least isn't guaranteed the
	# same one) -- not a strict check since names can coincide by chance, but
	# confirm the generator is actually randomized, not a hardcoded constant,
	# by sampling many names and seeing more than one distinct value.
	var names := {}
	for i in range(30):
		names[mgr._generate_settlement_name()] = true
	_check("the settlement name generator produces real variety, not one fixed string",
		names.size() > 1)

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
