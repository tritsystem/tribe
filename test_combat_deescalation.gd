extends Node
# Headless test for tribemember.gd's feed-to-deescalate fix. Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path . res://test_combat_deescalation.tscn --quit
#
# Caught live: a struck member kept attacking the player indefinitely even
# while being fed, because contribute() never touched _foe (the self-defense
# target) at all, and _foe only otherwise cleared on death, moving >16m
# away, or a chase-giveup timer that every successful strike resets --
# feeding requires standing close enough to also keep getting struck, so the
# timer never actually expired.

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  COMBAT DE-ESCALATION -- feeding an attacker fix")
	print("=".repeat(60))

	var member := _spawn_member()
	var player := Node3D.new()
	add_child(player)
	player.add_to_group("player")

	# scenario A: member is mid-combat against the PLAYER specifically ->
	# feeding them must clear the standoff
	member._foe = player
	member._chase_timer = 5.0
	member._flee_timer = 0.0
	member.contribute("food")
	_check("feeding the player mid-combat clears _foe", member._foe == null)
	_check("...and resets the chase timer", member._chase_timer == 0.0)

	# scenario B: member is fighting someone who ISN'T the player (a real
	# rival raider) -- feeding must NOT interrupt that combat. Only appeasing
	# the actual attacker should de-escalate anything.
	var rival := Node3D.new()
	add_child(rival)
	rival.add_to_group("npc")
	member._foe = rival
	member._chase_timer = 5.0
	member.contribute("food")
	_check("feeding does NOT interrupt combat against a non-player foe",
		member._foe == rival)

	# scenario C: no combat in progress -- feeding must not crash or behave
	# oddly when there's nothing to de-escalate
	member._foe = null
	member.contribute("food")
	_check("feeding with no active _foe is a normal no-op on combat state",
		member._foe == null)

	member.queue_free()
	player.queue_free()
	rival.queue_free()

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

func _check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  ok    %s" % label)
	else:
		_fail += 1
		print("  FAIL  %s" % label)
