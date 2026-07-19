extends Node
# Headless test for the two remaining architecturally-large gaps: real
# per-settlement economies, and deeper AI-to-AI diplomacy (mutual defense
# between allies). Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path . res://test_settlement_economy_and_diplomacy.tscn --quit

const TribeManagerScript = preload("res://Tribemanager.gd")

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  PER-SETTLEMENT ECONOMIES + MUTUAL DEFENSE")
	print("=".repeat(60))

	var mgr := TribeManagerScript.new()
	add_child(mgr)
	mgr._cat_lines = {"you": [], "tribe": [], "tribes": []}
	mgr.food = 50; mgr.wood = 50; mgr.materials = 50

	mgr.found_outpost(Vector3(400, 0, 0))
	var settlement = mgr.outposts[0]

	# ── per-settlement economies ──
	_check("a resident position resolves to the real outpost stockpile",
		mgr._outpost_at(Vector3(400, 0, 0)) == settlement)
	_check("a non-resident position resolves to no outpost (falls to the shared camp)",
		mgr._outpost_at(Vector3.ZERO) == null)

	mgr.add_food_at(Vector3(400, 0, 0), 10)
	_check("depositing at a settlement grows ITS local food, not the shared camp's",
		settlement.local_food == 10 and mgr.food == 50)

	mgr.add_food_at(Vector3.ZERO, 10)
	_check("depositing away from any settlement still grows the shared camp as before",
		mgr.food == 60)

	_check("spending from a settlement's local food succeeds when it has enough",
		mgr.spend_food_at(Vector3(400, 0, 0), 4) and settlement.local_food == 6)
	_check("spending more than a settlement's local food fails outright (no silent overdraft)",
		not mgr.spend_food_at(Vector3(400, 0, 0), 999) and settlement.local_food == 6)
	_check("...and does NOT fall back to draining the shared camp's food instead",
		mgr.food == 60)

	mgr.add_wood_at(Vector3(400, 0, 0), 7)
	mgr.add_materials_at(Vector3(400, 0, 0), 3)
	_check("wood and materials route to the settlement's own local stock too",
		settlement.local_wood == 7 and settlement.local_materials == 3)

	# a resident member's real deposit/feeding/crafting flow
	var resident := CharacterBody3D.new()
	resident.set_script(load("res://tribemember.gd"))
	add_child(resident)
	resident.member_name = "Resident"
	resident.manager = mgr
	resident.home_pos = Vector3(400, 0, 0)
	resident.current_rank = "Friend"
	resident._task_kind = "gather"
	resident._task_food = 20
	resident.inv_food = 0
	resident._complete_task()
	_check("a resident's real task completion deposits the surplus into their OWN settlement",
		settlement.local_food > 10)   # started at 6 after the spend check above
	_check("...not into the shared camp (still 60)", mgr.food == 60)

	# _complete_task() above ran its own _update_rank() (relationship only
	# just started growing from 0), which silently reverted current_rank
	# back to "Stranger" -- re-assert trust explicitly so this checks the
	# stockpile-draw branch (current_rank != "Stranger"), not the "hasn't
	# earned it yet" one right above it.
	resident.current_rank = "Friend"
	resident.hunger = 90.0
	resident.inv_food = 0   # empty personal ration -- otherwise _hunger_step() eats from THAT first, never reaching the stockpile-draw branch this checks
	var before_local_food: int = settlement.local_food
	resident._hunger_step(1.0)
	_check("a resident self-feeds from their OWN settlement's local food",
		settlement.local_food < before_local_food)

	resident.free()

	# the stockpile's own display reflects the LOCAL economy for a settlement,
	# not the shared camp's (which sits at 60 food -- very different numbers)
	settlement._process(0.0)
	var label_text: String = str(settlement._label.text)
	_check("a settlement's own display shows its LOCAL food total",
		("Food %d" % settlement.local_food) in label_text)
	_check("...not the shared camp's completely different total",
		not ("Food %d" % mgr.food) in label_text)
	mgr.free()

	# ── mutual defense: allies react to an attack on their friend, not just
	# after the fact if the friend actually falls ──
	var aggressor := _fake_tribe("Raiders")
	var defender := _fake_tribe("Foragers")
	var ally := _fake_tribe("Traders")
	var stranger := _fake_tribe("Nomads")
	defender.bonds["Traders"] = 0.8   # a real, formal alliance (>= ALLY_THRESHOLD)

	var mgr2 := TribeManagerScript.new()
	add_child(mgr2)
	mgr2._cat_lines = {"you": [], "tribe": [], "tribes": []}
	mgr2.world_tribes = [aggressor, defender, ally, stranger]

	var ally_grudge_rose := false
	var stranger_grudge_moved := false
	for i in range(60):
		ally.opinions.clear()
		stranger.opinions.clear()
		mgr2._rally_allies_against(aggressor, defender)
		if float(ally.opinions.get("Raiders", 0.0)) > 0.0:
			ally_grudge_rose = true
		if float(stranger.opinions.get("Raiders", 0.0)) != 0.0:
			stranger_grudge_moved = true
	_check("an ally genuinely takes an attack on its friend personally over enough trials",
		ally_grudge_rose)
	_check("an unrelated, non-allied tribe is never dragged into it",
		not stranger_grudge_moved)

	mgr2.free()
	aggressor.free(); defender.free(); ally.free(); stranger.free()

	print("\n" + "-".repeat(42))
	print("  %d passed, %d FAILED" % [_pass, _fail])
	print("-".repeat(42) + "\n")
	get_tree().quit(1 if _fail > 0 else 0)

func _fake_tribe(name_: String) -> Node3D:
	var script := GDScript.new()
	script.source_code = """
extends Node3D
var tribe_name: String = ""
var defeated: bool = false
var opinions: Dictionary = {}
var bonds: Dictionary = {}
const ALLY_THRESHOLD := 0.5
func grudge_toward(n: String) -> float:
	return float(opinions.get(n, 0.0))
func add_grudge(n: String, amt: float) -> void:
	opinions[n] = clampf(grudge_toward(n) + amt, 0.0, 1.0)
func bond_with(n: String) -> float:
	return float(bonds.get(n, 0.0))
func is_allied_with(n: String) -> bool:
	return bond_with(n) >= ALLY_THRESHOLD
func allies() -> Array:
	var out: Array = []
	for k in bonds.keys():
		if float(bonds[k]) >= ALLY_THRESHOLD:
			out.append(k)
	return out
"""
	script.reload()
	var n := Node3D.new()
	n.set_script(script)
	add_child(n)
	n.tribe_name = name_
	return n

func _check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  ok    %s" % label)
	else:
		_fail += 1
		print("  FAIL  %s" % label)
