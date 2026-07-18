extends Node
# Headless test for NPC<->NPC feelings + the emotional-override/grudge system.
# Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path . res://test_npc_grudges.tscn --quit
#
# Previously NPC<->NPC trust was explicitly NOT modelled (see tribe_rumor.gd's
# own scope note). Now real conversation exchanges move npc_opinion and
# resentment based on the LOYALTY-RANK gap between the two talkers, and
# resentment crossing RESENTMENT_BOIL forces a hostile action (_foe set)
# regardless of the Spikeling brain's own Trust/Follow state -- that's the
# "emotion overtakes neuron threshold" ask. Grudges (grudge_target/intensity)
# outlive the resentment spike that created them.

const SpatialGrid = preload("res://spatial_grid.gd")

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  NPC GRUDGES -- peer feelings + emotional override")
	print("=".repeat(60))
	TribeMemory._mem.clear()
	TribeMemory._pending.clear()

	# scenario A: talking with a MORE loyal peer -- opinion of them rises,
	# my own resentment eases
	var lowly := _spawn_member("Lowly")
	lowly.current_rank = "Stranger"          # loyalty_score 15
	lowly.resentment = 0.5
	var loyal := _spawn_member("Loyal1")
	loyal.current_rank = "Devoted"           # loyalty_score 125
	lowly.npc_talk_effect("Loyal1", loyal.loyalty_score())
	_check("talking with a more-loyal peer raises my opinion of them",
		float(lowly.npc_opinion.get("Loyal1", 0.0)) > 0.0)
	_check("...and eases my own resentment", lowly.resentment < 0.5)

	# scenario B: talking with a LESS loyal peer -- opinion of them falls,
	# my own resentment rises (the grumbler rubs off)
	var steady := _spawn_member("Steady1")
	steady.current_rank = "Devoted"
	steady.resentment = 0.2
	var grumbler := _spawn_member("Grumbler")
	grumbler.current_rank = "Stranger"
	steady.npc_talk_effect("Grumbler", grumbler.loyalty_score())
	_check("talking with a less-loyal peer lowers my opinion of them",
		float(steady.npc_opinion.get("Grumbler", 0.0)) < 0.0)
	_check("...and raises my own resentment", steady.resentment > 0.2)

	# scenario C: resentment below boiling point -- no override, brain state
	# (is_backing_you) is irrelevant, nothing happens
	var calm := _spawn_member("Calm")
	calm.resentment = 0.4
	calm.is_backing_you = true
	calm._emotion_step(1.0)
	_check("resentment below RESENTMENT_BOIL does not force an action",
		calm._foe == null and calm.grudge_target == "")

	# scenario D: resentment AT/OVER boiling point -- overrides even a fully
	# "Devoted"/backing brain state and picks the peer they resent most nearby
	var boiling := _spawn_member("Boiling", Vector3.ZERO)
	boiling.is_backing_you = true            # brain says this member is fully loyal
	boiling.current_rank = "Devoted"
	boiling.resentment = 1.5
	boiling.npc_opinion = {"Rival": -0.4, "Friendly": 0.3}
	var rival := _spawn_member("Rival", Vector3(2, 0, 0))
	var friendly := _spawn_member("Friendly", Vector3(2, 0, 0))
	boiling._emotion_step(1.0)
	_check("emotion overrides brain state (is_backing_you=true, Devoted) and still boils over",
		boiling.grudge_target != "")
	_check("the grudge lands on the peer they resent most, not a random target",
		boiling.grudge_target == "Rival")
	_check("_foe is actually set to that peer's node (real combat engagement)",
		boiling._foe == rival)
	_check("boiling over vents some heat but doesn't fully reset resentment",
		boiling.resentment > 0.0 and boiling.resentment < 1.5)
	_check("boiling over leaves a real memory of the act",
		_has_memory_type("Boiling", "boiled_over"))

	# scenario E: no peer nearby is genuinely resented -- grudge falls on the
	# leader instead
	var lone := _spawn_member("Lone", Vector3(500, 0, 500))   # far from anyone
	lone.resentment = 1.2
	var player := Node3D.new()
	add_child(player)
	player.add_to_group("player")
	player.global_position = Vector3(500, 0, 500)
	lone._emotion_step(1.0)
	_check("with no peer grudge nearby, the leader becomes the target",
		lone.grudge_target == "You" and lone._foe == player)
	player.queue_free()

	# scenario F: a grudge persists and decays slowly, not instantly
	var grudger := _spawn_member("Grudger")
	grudger.grudge_target = "SomePeer"
	grudger.grudge_intensity = 1.0
	grudger.resentment = 0.0                 # already vented, no new boil-over this tick
	grudger._emotion_step(1.0)
	_check("a grudge does not vanish the instant resentment is gone",
		grudger.grudge_target == "SomePeer" and grudger.grudge_intensity < 1.0 and grudger.grudge_intensity > 0.0)

	lowly.queue_free(); loyal.queue_free()
	steady.queue_free(); grumbler.queue_free()
	calm.queue_free()
	boiling.queue_free(); rival.queue_free(); friendly.queue_free()
	lone.queue_free()
	grudger.queue_free()

	print("\n" + "-".repeat(42))
	print("  %d passed, %d FAILED" % [_pass, _fail])
	print("-".repeat(42) + "\n")
	get_tree().quit(1 if _fail > 0 else 0)

func _has_memory_type(agent: String, event_type: String) -> bool:
	for m in TribeMemory._mem.get(agent, []):
		if m["type"] == event_type:
			return true
	return false

func _spawn_member(name_: String, pos: Vector3 = Vector3.ZERO) -> Node3D:
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
