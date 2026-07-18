extends Node
# Headless test for tribemember.gd's environmental senses. Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path . res://test_sense_environment.tscn --quit
#
# Live playtesting couldn't confirm this deterministically -- a Skirmish-scale
# world is sparse, and nothing wandered into range during the observation
# window. This test places real entities at known positions instead, so the
# result doesn't depend on world randomness.

const SpatialGrid = preload("res://spatial_grid.gd")

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  ENVIRONMENTAL SENSES -- deterministic regression test")
	print("=".repeat(60))

	var member := _spawn_member()

	# scenario A: nothing nearby at all
	member._sense_environment()
	_check("nothing nearby -> sees_raider false", member.sees_raider == false)
	_check("nothing nearby -> sees_prey false", member.sees_prey == false)
	_check("nothing nearby -> hears_danger false", member.hears_danger == false)

	# scenario B: a hostile "npc" well within SIGHT_RADIUS
	# NOTE: stimulate() only QUEUES a drive; the neuron only actually
	# integrates/fires on the next brain.step() (same real timing as the
	# game itself -- _sense_environment() and _brain_tick() run on separate
	# cooldowns in _physics_process()). Checking get_potential() right after
	# _sense_environment() alone checks state from BEFORE the stimulation was
	# ever applied -- caught by this test's own first run (a bare
	# "potential > 0" assertion failed even though sees_raider was correctly
	# true, because nothing had processed the queued drive yet).
	var raider := _spawn_fake(member.global_position + Vector3(3, 0, 0), "npc")
	member._sense_environment()
	_check("hostile npc at 3m (SIGHT_RADIUS=%.0f) -> sees_raider true" % member.SIGHT_RADIUS,
		member.sees_raider == true)
	member.brain.step()
	_check("SawRaider neuron actually fired once its stimulation was processed",
		member.brain.did_fire("SawRaider"))
	raider.queue_free()
	SpatialGrid.remove(raider)

	# scenario C: a NEUTRAL npc must NOT register as a raider
	var neutral := _spawn_neutral(member.global_position + Vector3(3, 0, 0))
	member._sense_environment()
	_check("a NEUTRAL npc nearby does NOT register as sees_raider", member.sees_raider == false)
	neutral.queue_free()
	SpatialGrid.remove(neutral)

	# scenario D: hostile far enough to be heard, not seen
	var distant := _spawn_fake(member.global_position + Vector3(0, 0, 18), "npc")
	member._sense_environment()
	var d_label: String = "hostile at 18m (beyond SIGHT_RADIUS=%.0f, within HEARING_RADIUS=%.0f) -> sees_raider false" % [
		member.SIGHT_RADIUS, member.HEARING_RADIUS]
	_check(d_label, member.sees_raider == false)
	_check("...but hears_danger true", member.hears_danger == true)
	distant.queue_free()
	SpatialGrid.remove(distant)

	# scenario E: huntable prey
	var prey := _spawn_fake(member.global_position + Vector3(-2, 0, 0), "animal")
	member._sense_environment()
	_check("animal at 2m -> sees_prey true", member.sees_prey == true)
	prey.queue_free()
	SpatialGrid.remove(prey)

	# scenario G: REAL EVENT-BASED HEARING -- a combat hit landing nearby,
	# broadcast once (not polled), reaches a member who can't currently see
	# anything (no rival/animal in range at all right now). This is the
	# distinct "hearing" the ambient sees_raider/hears_danger polling above
	# can't express: a sudden noise from an event, not a steadily-present body.
	member.sees_raider = false
	member.hears_danger = false
	var witness := _spawn_member_at(member.global_position + Vector3(0, 0, 10))
	# no class_name is declared on tribemember.gd (real members are attached
	# via set_script(), not referenced by class name anywhere) -- called via
	# an instance reference instead, which GDScript allows for static methods.
	member._broadcast_combat_sound(member.global_position)
	_check("a combat hit broadcast from 10m away sets hears_danger on a witness "
		+ "with nothing else in sight", witness.hears_danger == true)
	witness.brain.step()
	_check("...and the witness's HeardDanger neuron actually fires from it",
		witness.brain.did_fire("HeardDanger"))
	var far_witness := _spawn_member_at(member.global_position + Vector3(0, 0, 999))
	member._broadcast_combat_sound(member.global_position)
	_check("a witness far beyond HEARING_RADIUS does NOT hear it",
		far_witness.hears_danger == false)
	witness.queue_free()
	SpatialGrid.remove(witness)
	far_witness.queue_free()
	SpatialGrid.remove(far_witness)

	# scenario F: the graded-drive formula itself (mirrors the real Arduino
	# sensor rig's drive = max(0, 120 - 4*distance) shape)
	_check("_proximity_drive(0, 12) == 100 (max intensity at zero distance)",
		absf(member._proximity_drive(0.0, 12.0) - 100.0) < 0.01)
	_check("_proximity_drive(12, 12) == 0 (zero intensity exactly at the radius edge)",
		absf(member._proximity_drive(12.0, 12.0) - 0.0) < 0.01)
	_check("_proximity_drive(6, 12) == 50 (linear midpoint)",
		absf(member._proximity_drive(6.0, 12.0) - 50.0) < 0.01)
	_check("_proximity_drive never goes negative beyond the radius",
		member._proximity_drive(999.0, 12.0) >= 0.0)

	member.queue_free()
	SpatialGrid.remove(member)

	print("\n" + "-".repeat(42))
	print("  %d passed, %d FAILED" % [_pass, _fail])
	print("-".repeat(42) + "\n")
	get_tree().quit(1 if _fail > 0 else 0)

## Mirrors Tribemanager.gd's _build_member_in_code(): real members are built
## as a bare CharacterBody3D with tribemember.gd attached via set_script(),
## NOT instantiated from tribemember.tscn -- that scene file's root is
## declared as plain Node3D (stale relative to the script's own `extends
## CharacterBody3D`), so PackedScene.instantiate() fails outright. Caught by
## this test itself on the first run: "Script inherits from native type
## 'CharacterBody3D', so it can't be assigned to an object of type 'Node3D'."
## _ready() itself needs no pre-built children (_apply_tint()/_anim_parts()
## use get_node_or_null and degrade gracefully; _build_combat_visuals()
## builds its own nodes), so no visual rig is needed for this test.
func _spawn_member() -> Node3D:
	return _spawn_member_at(Vector3.ZERO)

func _spawn_member_at(pos: Vector3) -> Node3D:
	var m := CharacterBody3D.new()
	m.set_script(load("res://tribemember.gd"))
	add_child(m)
	m.member_name = "TestSubject"
	m.global_position = pos
	SpatialGrid.update(m)
	return m

## A bare Node3D with no script has no declared "neutral" property, so
## n.get("neutral") returns null (falsy) -- read as "not neutral", i.e.
## hostile. That's exactly the real rival-npc default (non-neutral raiders
## are the common case), so this is a genuine stand-in, not a cheat.
func _spawn_fake(pos: Vector3, group: String) -> Node3D:
	var n := Node3D.new()
	add_child(n)
	n.global_position = pos
	n.add_to_group(group)
	SpatialGrid.update(n)
	return n

## A genuinely neutral npc needs a real declared "neutral" property for
## n.get("neutral") to find -- built via a tiny anonymous script.
func _spawn_neutral(pos: Vector3) -> Node3D:
	var script := GDScript.new()
	script.source_code = "extends Node3D\nvar neutral: bool = true\n"
	script.reload()
	var n := Node3D.new()
	n.set_script(script)
	add_child(n)
	n.global_position = pos
	n.add_to_group("npc")
	SpatialGrid.update(n)
	return n

func _check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  ok    %s" % label)
	else:
		_fail += 1
		print("  FAIL  %s" % label)
