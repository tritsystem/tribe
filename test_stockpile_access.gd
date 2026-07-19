extends Node
# Headless test for the trust-gated stockpile access fix. Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path . res://test_stockpile_access.tscn --quit
#
# Previously a member's own ration (inv_food) was the ONLY food source they
# could ever draw on -- once empty they starved regardless of trust, and only
# the player could touch the shared stockpile. Fixed: rank Acquaintance+
# ("level 1" trust) can now draw on the shared stockpile via manager.spend_food()
# once their own ration is empty.

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  STOCKPILE ACCESS -- trust-gated self-feeding")
	print("=".repeat(60))

	# scenario A: a Stranger with an empty personal ration must NOT draw on
	# the stockpile -- they haven't earned that access yet
	var stranger := _spawn_member()
	stranger.current_rank = "Stranger"
	stranger.inv_food = 0
	stranger.hunger = 90.0
	var mgr_a := _fake_manager(true)
	stranger.manager = mgr_a
	stranger._hunger_step(1.0)
	_check("a Stranger with empty rations does NOT draw on the stockpile",
		not mgr_a.spend_called)
	_check("...and stays hungry as a result", stranger.hunger > 80.0)

	# scenario B: an Acquaintance+ member with an empty ration CAN draw on a
	# stocked stockpile
	var trusted := _spawn_member()
	trusted.current_rank = "Acquaintance"
	trusted.inv_food = 0
	trusted.hunger = 90.0
	var mgr_b := _fake_manager(true)
	trusted.manager = mgr_b
	trusted._hunger_step(1.0)
	_check("an Acquaintance+ member with empty rations DOES draw on the stockpile",
		mgr_b.spend_called)
	_check("...and hunger actually drops", trusted.hunger < 90.0)

	# scenario C: trusted, but the stockpile itself is empty -- must not fake
	# success or crash; hunger stays high, same as a real empty larder
	var trusted_empty := _spawn_member()
	trusted_empty.current_rank = "Friend"
	trusted_empty.inv_food = 0
	trusted_empty.hunger = 90.0
	var mgr_c := _fake_manager(false)
	trusted_empty.manager = mgr_c
	trusted_empty._hunger_step(1.0)
	_check("trusted but the stockpile is genuinely empty -> stays hungry, no crash",
		trusted_empty.hunger > 80.0)

	# scenario D: personal ration still has food -- must be used FIRST, before
	# ever touching the shared stockpile at all
	var self_sufficient := _spawn_member()
	self_sufficient.current_rank = "Devoted"
	self_sufficient.inv_food = 3
	self_sufficient.hunger = 90.0
	var mgr_d := _fake_manager(true)
	self_sufficient.manager = mgr_d
	self_sufficient._hunger_step(1.0)
	_check("personal ration is used first, even for a fully-trusted member",
		self_sufficient.inv_food == 2 and not mgr_d.spend_called)

	stranger.queue_free()
	trusted.queue_free()
	trusted_empty.queue_free()
	self_sufficient.queue_free()

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

func _fake_manager(has_food: bool) -> Node:
	var script := GDScript.new()
	script.source_code = """
extends Node
var spend_called := false
var _has_food: bool = true
func spend_food(n: int) -> bool:
	spend_called = true
	return _has_food
func spend_food_at(_pos, n: int) -> bool:
	return spend_food(n)
"""
	script.reload()
	var n := Node.new()
	n.set_script(script)
	n.set("_has_food", has_food)
	add_child(n)
	return n

func _check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  ok    %s" % label)
	else:
		_fail += 1
		print("  FAIL  %s" % label)
