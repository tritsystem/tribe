extends Node
# Headless test for directed weapon crafting (craft_weapon()). Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path . res://test_weapon_crafting.tscn --quit
#
# Previously weapon tier only ever advanced via _maybe_upgrade_gear()'s random
# automatic pick. craft_weapon() adds a DIRECTED choice ("Ka, craft a spear"),
# reachable via TribeCommand's new craft_club/craft_spear/craft_bow/craft_axe
# verb kinds (see test_command_parser.gd for the parsing side).

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  WEAPON CRAFTING -- directed tier selection")
	print("=".repeat(60))

	# scenario A: enough materials -> the exact requested tier is set
	# (2026-07-19: craft_weapon() now gates tiers above 0 on real Blacksmithing
	# practice -- see practice_profession()/SKILL_TIER_STEP in tribemember.gd)
	var m1 := _spawn_member()
	m1.manager = _fake_manager(true)
	m1.weapon = 0
	m1.profession_skill["Blacksmithing"] = 25.0
	var ok1: bool = m1.craft_weapon(1)   # 1 == Spear
	_check("craft_weapon(1) succeeds with materials available", ok1)
	_check("...and sets the EXACT requested tier (Spear), not a random one",
		m1.weapon == 1)

	# scenario B: not enough materials -> fails cleanly, tier unchanged
	var m2 := _spawn_member()
	m2.manager = _fake_manager(false)
	m2.weapon = 0
	var ok2: bool = m2.craft_weapon(3)   # 3 == Axe
	_check("craft_weapon() fails cleanly when materials are short", not ok2)
	_check("...and the weapon tier is left unchanged", m2.weapon == 0)

	# scenario C: out-of-range tier index is clamped, not crashed
	var m3 := _spawn_member()
	m3.manager = _fake_manager(true)
	m3.profession_skill["Blacksmithing"] = 100.0
	var ok3: bool = m3.craft_weapon(99)
	_check("an out-of-range tier index is clamped rather than crashing", ok3)
	_check("...clamped to the last real tier (Axe, index 3)", m3.weapon == 3)

	# scenario D: a member can craft a LOWER tier deliberately (e.g. gifting a
	# starter weapon to someone who lost theirs) -- this is a direct choice,
	# not a one-way ratchet like the random auto-upgrade
	var m4 := _spawn_member()
	m4.manager = _fake_manager(true)
	m4.weapon = 3
	var ok4: bool = m4.craft_weapon(0)
	_check("craft_weapon() can deliberately set a LOWER tier too", ok4 and m4.weapon == 0)

	m1.queue_free()
	m2.queue_free()
	m3.queue_free()
	m4.queue_free()

	print("\n" + "-".repeat(42))
	print("  %d passed, %d FAILED" % [_pass, _fail])
	print("-".repeat(42) + "\n")
	get_tree().quit(1 if _fail > 0 else 0)

func _spawn_member() -> Node3D:
	var m := CharacterBody3D.new()
	m.set_script(load("res://tribemember.gd"))
	add_child(m)
	m.member_name = "TestSubject"
	return m

func _fake_manager(has_materials: bool) -> Node:
	var script := GDScript.new()
	script.source_code = """
extends Node
var _has: bool = true
func spend_materials(n: int) -> bool:
	return _has
func spend_materials_at(_pos, n: int) -> bool:
	return spend_materials(n)
func crafting_discount_at(_pos) -> float:
	return 1.0
"""
	script.reload()
	var n := Node.new()
	n.set_script(script)
	n.set("_has", has_materials)
	add_child(n)
	return n

func _check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  ok    %s" % label)
	else:
		_fail += 1
		print("  FAIL  %s" % label)
