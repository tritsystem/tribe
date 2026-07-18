extends Node
# Headless test for cross-tribe dialogue (Phase 3 of "cities, communicate,
# and live amongst other tribes") -- player tribe members can now actually
# TALK to a nearby rival NPC once relations are friendly, not just walk
# safely through their camp. Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path . res://test_cross_tribe_talk.tscn --quit
#
# PREREQUISITE FIX this depends on: rival NPCs used to all share their
# tribe's own name as member_name -- extending TribeTalk (which keys
# _last_talk/_speakers by member_name) to them without fixing that would
# have silently collided two different rivals from the same tribe. npc.gd
# now individually names each one from RIVAL_NAMES.

const SpatialGrid = preload("res://spatial_grid.gd")

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  CROSS-TRIBE TALK -- real dialogue once relations are friendly")
	print("=".repeat(60))
	TribeMemory._mem.clear()
	TribeMemory._pending.clear()

	# ── prerequisite: rival NPCs are individually named, not all named
	# after their tribe (the real collision-safety fix) ──
	var fake_tribe := _fake_tribe("Foragers", 0.5)
	var rival1 := CharacterBody3D.new()
	rival1.set_script(load("res://npc.gd"))
	add_child(rival1)
	rival1.setup(fake_tribe, Vector3.ZERO, 20.0, Color.WHITE)
	var rival2 := CharacterBody3D.new()
	rival2.set_script(load("res://npc.gd"))
	add_child(rival2)
	rival2.setup(fake_tribe, Vector3.ZERO, 20.0, Color.WHITE)
	rival2.global_position = Vector3(9999, 0, 9999)   # out of the way for every distance-based check below
	_check("a rival NPC's member_name is NOT just its tribe's name (the collision this whole fix exists to prevent)",
		str(rival1.member_name) != fake_tribe.tribe_name)
	_check("two rivals from the SAME tribe reliably get assigned names (a real bank, not blank/broken)",
		str(rival1.member_name) != "" and str(rival2.member_name) != "")

	# ── _find_friendly_rival(): opinion-gated, distance-gated ──
	var mate := CharacterBody3D.new()
	mate.set_script(load("res://tribemember.gd"))
	add_child(mate)
	mate.member_name = "Ka"
	mate.global_position = Vector3.ZERO
	SpatialGrid.update(mate)

	rival1.global_position = Vector3(5, 0, 0)   # within TALK_RADIUS
	_check("a rival from a friendly tribe within range is found as a talk partner",
		TribeTalk._find_friendly_rival(mate) == rival1)

	fake_tribe.player_opinion = 0.1   # below the friendly threshold
	_check("a rival from a NOT-yet-friendly tribe is not offered as a talk partner",
		TribeTalk._find_friendly_rival(mate) == null)
	fake_tribe.player_opinion = 0.5

	rival1.global_position = Vector3(500, 0, 0)   # far outside TALK_RADIUS
	_check("a friendly rival too far away is not offered as a talk partner",
		TribeTalk._find_friendly_rival(mate) == null)
	rival1.global_position = Vector3(5, 0, 0)

	# ── _persona_for() dispatches safely -- the real risk this whole
	# feature had to avoid (calling the tribemate-only _persona() on a
	# rival would hit float(m.get("hunger")) on a property that doesn't
	# exist there) ──
	var persona_text: String = TribeTalk._persona_for(rival1)
	_check("building a rival's persona does not crash and produces real text",
		persona_text != "")
	_check("a rival's persona correctly reflects their OWN tribe, not the player's",
		"Foragers" in persona_text)

	# ── a full cross-tribe exchange end-to-end (fallback path, since
	# TribeLLM isn't warm in a headless test) actually produces a real
	# memory for the player's tribemate, without crashing on the rival
	# side (which has no npc_talk_effect/loyalty_score to call) ──
	TribeTalk._last_talk.clear()
	TribeTalk._speakers.clear()
	TribeTalk._try_start()
	_check("a cross-tribe conversation attempt writes a real memory for the player's own tribemate",
		_has_memory_type("Ka", "talked") or _has_memory_type("Ka", "heard"))

	rival1.free(); rival2.free(); mate.free(); fake_tribe.free()

	print("\n" + "-".repeat(42))
	print("  %d passed, %d FAILED" % [_pass, _fail])
	print("-".repeat(42) + "\n")
	get_tree().quit(1 if _fail > 0 else 0)

func _has_memory_type(agent: String, event_type: String) -> bool:
	for m in TribeMemory._mem.get(agent, []):
		if m["type"] == event_type:
			return true
	return false

func _fake_tribe(name_: String, opinion: float) -> Node3D:
	var script := GDScript.new()
	script.source_code = """
extends Node3D
var tribe_name: String = ""
var archetype: String = "Foragers"
var player_opinion: float = 0.0
var brain = null
"""
	script.reload()
	var n := Node3D.new()
	n.set_script(script)
	add_child(n)
	n.tribe_name = name_
	n.player_opinion = opinion
	return n

func _check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  ok    %s" % label)
	else:
		_fail += 1
		print("  FAIL  %s" % label)
