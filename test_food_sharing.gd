extends Node
# Headless test for NPC-to-NPC food sharing (_maybe_share_food()). Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path . res://test_food_sharing.tscn --quit
#
# Previously the only food transfers in this game were player->member and
# member->shared-stockpile; members never helped each other directly. A
# member sitting on a surplus would let a tribemate right next to them
# starve.

const SpatialGrid = preload("res://spatial_grid.gd")

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  FOOD SHARING -- NPC-to-NPC transfers")
	print("=".repeat(60))
	TribeMemory._mem.clear()
	TribeMemory._pending.clear()

	# scenario A: real surplus + a genuinely hungry tribemate nearby -> shares
	var giver := _spawn_member("Giver", Vector3.ZERO)
	giver.inv_food = 14   # clearly above SHARE_SURPLUS_MIN, not just at the boundary
	var hungry := _spawn_member("Hungry", Vector3(3, 0, 0))
	hungry.inv_food = 0
	hungry.hunger = 90.0
	giver._maybe_share_food()
	_check("a surplus member shares food with a genuinely hungry tribemate nearby",
		hungry.inv_food == 1)
	_check("giver's own food actually decreases", giver.inv_food == 13)
	_check("recipient's hunger actually drops", hungry.hunger < 90.0)
	_check("the giver remembers the act of generosity",
		_has_memory_type("Giver", "shared_food"))
	_check("the recipient remembers being helped",
		_has_memory_type("Hungry", "shared_food"))
	giver.queue_free()
	hungry.queue_free()

	# scenario B: no real surplus -> must not share (never risk their own hunger)
	TribeMemory._mem.clear()
	var stingy := _spawn_member("Stingy", Vector3.ZERO)
	stingy.inv_food = 2   # at/below RATION_RESERVE, no real surplus
	var hungry2 := _spawn_member("Hungry2", Vector3(3, 0, 0))
	hungry2.inv_food = 0
	hungry2.hunger = 90.0
	stingy._maybe_share_food()
	_check("a member with no real surplus does NOT share (protects their own hunger)",
		hungry2.inv_food == 0)
	stingy.queue_free()
	hungry2.queue_free()

	# scenario C: nearby tribemate isn't hungry enough -> no share needed
	TribeMemory._mem.clear()
	var giver2 := _spawn_member("Giver2", Vector3.ZERO)
	giver2.inv_food = 14
	var fine := _spawn_member("Fine", Vector3(3, 0, 0))
	fine.inv_food = 5
	fine.hunger = 20.0
	giver2._maybe_share_food()
	_check("a tribemate who isn't genuinely hungry doesn't get food pushed on them",
		fine.inv_food == 5)
	giver2.queue_free()
	fine.queue_free()

	# scenario D: too far away -> no share (sharing a meal means being close,
	# not just able to see them across camp)
	TribeMemory._mem.clear()
	var giver3 := _spawn_member("Giver3", Vector3.ZERO)
	giver3.inv_food = 14
	var far := _spawn_member("Far", Vector3(50, 0, 0))
	far.inv_food = 0
	far.hunger = 90.0
	giver3._maybe_share_food()
	_check("a hungry tribemate far outside SHARE_RADIUS does not receive food",
		far.inv_food == 0)
	giver3.queue_free()
	far.queue_free()

	# scenario E: a dog (shares the "tribe" group, no hunger/inv_food) must be
	# safely skipped, not crash
	TribeMemory._mem.clear()
	var giver4 := _spawn_member("Giver4", Vector3.ZERO)
	giver4.inv_food = 14
	var dog := Node3D.new()
	add_child(dog)
	dog.add_to_group("tribe")
	dog.global_position = Vector3(2, 0, 0)
	SpatialGrid.update(dog)
	giver4._maybe_share_food()   # must not crash despite the dog having no hunger/inv_food
	_check("a non-ration-having tribe member (e.g. a dog) is safely skipped, no crash",
		giver4.inv_food == 14)
	giver4.queue_free()
	dog.queue_free()
	SpatialGrid.remove(dog)

	print("\n" + "-".repeat(42))
	print("  %d passed, %d FAILED" % [_pass, _fail])
	print("-".repeat(42) + "\n")
	get_tree().quit(1 if _fail > 0 else 0)

func _has_memory_type(agent: String, event_type: String) -> bool:
	for m in TribeMemory._mem.get(agent, []):
		if m["type"] == event_type:
			return true
	return false

func _spawn_member(name_: String, pos: Vector3) -> Node3D:
	var m := CharacterBody3D.new()
	m.set_script(load("res://tribemember.gd"))
	add_child(m)
	m.member_name = name_
	m.global_position = pos
	SpatialGrid.update(m)
	return m

func _check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  ok    %s" % label)
	else:
		_fail += 1
		print("  FAIL  %s" % label)
