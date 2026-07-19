extends Node
# Headless test for: (1) closing the flagged district-bonus gap (Gathering
# yield, Crafting discount -- Watch already had a real bonus), (2) gossip
# about a third tribemate now moving real npc_opinion (previously flavour-
# only, a documented gap), and (3) the new societal hierarchy -- Official
# (small, tribe-size-scaled quota, most loyal), Outpostman (earned by really
# living at a settlement), and job-driven roles for everyone else, for BOTH
# the player's own tribe and rival NPCs. Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path . res://test_hierarchy_and_gaps.tscn --quit

const SpatialGrid = preload("res://spatial_grid.gd")
const TribeManagerScript = preload("res://Tribemanager.gd")

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  HIERARCHY + REMAINING GAPS")
	print("=".repeat(60))
	TribeMemory._mem.clear()
	TribeMemory._pending.clear()

	var mgr := TribeManagerScript.new()
	add_child(mgr)
	mgr._cat_lines = {"you": [], "tribe": [], "tribes": []}
	mgr.wood = 1000
	mgr.materials = 1000

	# ── district bonuses: Gathering yield, Crafting discount ──
	mgr.found_outpost(Vector3(300, 0, 0))
	mgr.outposts[0].district = "Gathering"
	mgr.found_outpost(Vector3(-300, 0, 0))
	mgr.outposts[1].district = "Crafting"

	_check("no yield bonus far from any Gathering settlement", mgr.gathering_bonus_at(Vector3.ZERO) == 1.0)
	_check("a real yield bonus right at the Gathering settlement",
		mgr.gathering_bonus_at(Vector3(300, 0, 0)) > 1.0)
	_check("no crafting discount far from any Crafting settlement",
		mgr.crafting_discount_at(Vector3.ZERO) == 1.0)
	_check("a real crafting discount right at the Crafting settlement",
		mgr.crafting_discount_at(Vector3(-300, 0, 0)) < 1.0)

	var forager := CharacterBody3D.new()
	forager.set_script(load("res://tribemember.gd"))
	add_child(forager)
	forager.member_name = "Forager1"
	forager.manager = mgr
	forager.home_pos = Vector3(300, 0, 0)
	var bush_script := GDScript.new()
	bush_script.source_code = "extends Node3D\nfunc harvest(n):\n\treturn int(n)\n"
	bush_script.reload()
	var bush := Node3D.new()
	bush.set_script(bush_script)
	add_child(bush)
	forager._target_node = bush
	forager._do_gather()
	_check("a resident forager at the Gathering settlement actually brings back more food",
		forager._task_food > 4)   # harvest(4.0) truncated to int -> 4 baseline; bonus pushes it over
	forager.free(); bush.free()

	var crafter := CharacterBody3D.new()
	crafter.set_script(load("res://tribemember.gd"))
	add_child(crafter)
	crafter.member_name = "Crafter1"
	crafter.manager = mgr
	crafter.home_pos = Vector3(-300, 0, 0)
	var before_mats: int = mgr.materials
	crafter.craft_weapon(1)
	var spent: int = before_mats - mgr.materials
	_check("crafting at the Crafting settlement spends LESS than the base material cost",
		spent < crafter._GEAR_MAT_COST and spent > 0)
	crafter.free()

	# ── gossip about a third tribemate now moves real npc_opinion ──
	var alice := CharacterBody3D.new()
	alice.set_script(load("res://tribemember.gd"))
	add_child(alice)
	alice.member_name = "Alice"
	TribeRumor.rumors.clear(); TribeRumor.knows.clear()
	var rid: int = TribeRumor.plant("Bo is a coward", "Bo", -1.0, "Someone", "Alice")
	TribeRumor.transmit(rid, "Someone", "Alice", "Bo is a coward")
	_check("gossip about a peer now moves the hearer's real npc_opinion of them",
		float(alice.npc_opinion.get("Bo", 0.0)) < 0.0)
	_check("...and it's remembered as a real event", _has_memory_type("Alice", "opinion"))
	alice.free()

	# ── societal hierarchy: job-driven roles ──
	var hunter := CharacterBody3D.new()
	hunter.set_script(load("res://tribemember.gd"))
	add_child(hunter)
	hunter.member_name = "Hunter1"
	hunter._job_counts = {"hunt": 5, "gather": 1}
	hunter._update_social_role()
	_check("a member who's mostly hunted becomes a real Hunter",
		hunter.social_role == "Hunter")

	# ── Outpostman: earned by really living at a settlement ──
	hunter.manager = mgr
	hunter.home_pos = Vector3(300, 0, 0)   # now lives at the Gathering settlement
	hunter._update_social_role()
	_check("living at a founded settlement earns Outpostman, overriding the job tally",
		hunter.social_role == "Outpostman")
	hunter.free()

	# ── Official: small, tribe-size-scaled quota, most loyal only ──
	mgr.members.clear()
	var loyal_members: Array = []
	for i in range(12):
		var m := CharacterBody3D.new()
		add_child(m)
		m.set_script(load("res://tribemember.gd"))
		m.member_name = "M%d" % i
		m.current_rank = "Devoted"
		m.relationship = float(i)   # each one strictly more loyal than the last
		mgr.members.append(m)
		loyal_members.append(m)
	_check("the official quota grows with tribe size but stays a real minority",
		mgr.official_quota() < mgr.members.size() and mgr.official_quota() >= 1)
	var most_loyal = loyal_members[loyal_members.size() - 1]   # relationship == 11, the highest
	var least_loyal = loyal_members[0]                          # relationship == 0
	_check("the single most loyal Devoted member qualifies as an Official",
		mgr.is_official(most_loyal))
	_check("a Devoted member who is NOT among the most loyal does not",
		not mgr.is_official(least_loyal))
	for m in loyal_members:
		m.free()

	# ── rival tribes get a real hierarchy too ──
	var fake_tribe := _fake_tribe("Raiders")
	var rival := CharacterBody3D.new()
	rival.set_script(load("res://npc.gd"))
	add_child(rival)
	rival.setup(fake_tribe, Vector3.ZERO, 20.0, Color.WHITE)
	_check("a rival NPC is assigned a real role from the hierarchy, not left blank",
		rival.social_role in rival.ROLE_HIERARCHY)
	_check("a Raiders-clan rival is realistically biased toward a martial role",
		rival.social_role in ["Warrior", "Spy", "Official"])
	rival.free(); fake_tribe.free()

	mgr.free()

	print("\n" + "-".repeat(42))
	print("  %d passed, %d FAILED" % [_pass, _fail])
	print("-".repeat(42) + "\n")
	get_tree().quit(1 if _fail > 0 else 0)

func _has_memory_type(agent: String, event_type: String) -> bool:
	for m in TribeMemory._mem.get(agent, []):
		if m["type"] == event_type:
			return true
	return false

func _fake_tribe(archetype: String) -> Node3D:
	var script := GDScript.new()
	script.source_code = """
extends Node3D
var tribe_name: String = "Rivals"
var archetype: String = "Foragers"
var brain = null
"""
	script.reload()
	var n := Node3D.new()
	n.set_script(script)
	add_child(n)
	n.archetype = archetype
	return n

func _check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  ok    %s" % label)
	else:
		_fail += 1
		print("  FAIL  %s" % label)
