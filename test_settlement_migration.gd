extends Node
# Headless test for settlement migration (Phase 5 of "cities, communicate,
# and live amongst other tribes") -- OTHER members can now join an
# existing settlement too, not just its founder. Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path . res://test_settlement_migration.tscn --quit

const TribeManagerScript = preload("res://Tribemanager.gd")

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  SETTLEMENT MIGRATION -- other members join existing settlements")
	print("=".repeat(60))
	TribeMemory._mem.clear()
	TribeMemory._pending.clear()

	var mgr := TribeManagerScript.new()
	add_child(mgr)
	mgr._cat_lines = {"you": [], "tribe": [], "tribes": []}

	# two founded settlements: A has 1 resident already, B has none
	mgr.found_outpost(Vector3(200, 0, 0))
	mgr.found_outpost(Vector3(-200, 0, 0))
	var settlement_a = mgr.outposts[0]
	var settlement_b = mgr.outposts[1]

	var resident := CharacterBody3D.new()
	resident.set_script(load("res://tribemember.gd"))
	add_child(resident)
	resident.member_name = "Resident"
	resident.home_pos = settlement_a.global_position
	mgr.members.append(resident)

	_check("resident count at the already-populated settlement A is 1",
		mgr._resident_count(settlement_a.global_position) == 1)
	_check("resident count at the still-empty settlement B is 0",
		mgr._resident_count(settlement_b.global_position) == 0)

	var migrant := CharacterBody3D.new()
	add_child(migrant)
	migrant.global_position = Vector3.ZERO
	mgr.members.append(migrant)

	var dest = mgr.least_populated_outpost(Vector3.ZERO)   # migrant "lives" at the old camp
	_check("a member not yet resident anywhere is pointed at the LEAST populated settlement (B, not A)",
		dest == settlement_b)

	# a member ALREADY living at settlement A must not be offered A again
	var dest2 = mgr.least_populated_outpost(settlement_a.global_position)
	_check("a member already resident at a settlement is never offered THAT one again",
		dest2 != settlement_a)

	# ── the actual migration task on tribemember.gd ──
	var m := CharacterBody3D.new()
	m.set_script(load("res://tribemember.gd"))
	add_child(m)
	m.member_name = "Migrant"
	m.home_pos = Vector3.ZERO
	m.global_position = settlement_b.global_position   # simulate having arrived
	m._start_migrate(settlement_b.global_position)
	_check("starting a migration marks the member busy on a real 'migrate' task",
		m.is_busy and m._task_kind == "migrate")

	m._complete_task()
	_check("completing a migration re-anchors home_pos at the destination settlement",
		m.home_pos == settlement_b.global_position)
	_check("a real memory of migrating is recorded",
		_has_memory_type("Migrant", "migrated"))

	resident.free(); migrant.free(); m.free()
	mgr.free()

	print("\n" + "-".repeat(42))
	print("  %d passed, %d FAILED" % [_pass, _fail])
	print("-".repeat(42) + "\n")
	get_tree().quit(1 if _fail > 0 else 0)

func _has_memory_type(agent: String, event_type: String) -> bool:
	for mem in TribeMemory._mem.get(agent, []):
		if mem["type"] == event_type:
			return true
	return false

func _check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  ok    %s" % label)
	else:
		_fail += 1
		print("  FAIL  %s" % label)
