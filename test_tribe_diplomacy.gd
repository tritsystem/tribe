extends Node
# Headless test for two related fixes toward "build cities, communicate,
# and live amongst other tribes":
#   1. a friendly/trusted/bonded relationship (player_opinion) now actually
#      makes a rival tribe's own territory safe -- previously in_territory
#      triggered "classic camp defense" REGARDLESS of opinion, so there was
#      no relationship level at which visiting a rival camp was safe.
#   2. a real, direct way to build player_opinion (player_scout()/_greet_tribe())
#      distinct from the existing passive trade/raid ripple effects.
# Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path . res://test_tribe_diplomacy.tscn --quit

const TribeManagerScript = preload("res://Tribemanager.gd")

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  TRIBE DIPLOMACY -- coexistence + direct communication")
	print("=".repeat(60))

	# ── coexistence: npc.gd's _find_intruder() opinion gating ──
	var npc := CharacterBody3D.new()
	npc.set_script(_npc_stub_script())
	add_child(npc)
	npc.home = Vector3.ZERO
	npc.territory = 20.0

	var hostile_tribe := _fake_tribe("Hostiles", -0.5)
	var friendly_tribe := _fake_tribe("Friends", 0.5)

	var player := Node3D.new()
	add_child(player)
	player.add_to_group("player")
	player.global_position = Vector3(5, 0, 0)   # inside territory (20), not too_close (>6)

	npc.tribe = hostile_tribe
	_check("a hostile tribe still treats the player as an intruder in their own territory",
		npc._find_intruder() == player)

	npc.tribe = friendly_tribe
	_check("a friendly tribe no longer treats the player as an intruder in their own territory",
		npc._find_intruder() == null)

	# a player-tribe member (group "tribe") in a friendly camp
	var mate := Node3D.new()
	add_child(mate)
	mate.add_to_group("tribe")
	mate.global_position = Vector3(3, 0, 0)
	const SpatialGrid = preload("res://spatial_grid.gd")
	SpatialGrid.update(mate)

	npc.tribe = hostile_tribe
	_check("a hostile tribe still treats the player's own tribemate as an intruder",
		npc._find_intruder() == mate)
	npc.tribe = friendly_tribe
	_check("a friendly tribe no longer treats the player's own tribemate as an intruder either",
		npc._find_intruder() == null)

	SpatialGrid.remove(mate)
	npc.free(); player.free(); mate.free()

	# ── communication: player_scout()/_greet_tribe() ──
	var mgr := TribeManagerScript.new()
	add_child(mgr)
	mgr._cat_lines = {"you": [], "tribe": [], "tribes": []}

	var camp := _fake_tribe("Newcomers", 0.0)
	camp.global_position = Vector3(5, 0, 0)
	mgr.world_tribes = [camp]

	# scenario: first contact (scouting) always raises opinion, bypassing cooldown
	mgr.player_scout(Vector3.ZERO)
	_check("scouting a new camp raises player_opinion via a real first greeting",
		camp.player_opinion > 0.0)
	_check("scouting also marks the camp discovered", camp.discovered)
	var after_first: float = camp.player_opinion

	# scenario: re-using the same action (X) on an ALREADY-known camp greets
	# it again instead of going dead -- but is cooldown-gated
	mgr.player_scout(Vector3.ZERO)
	_check("greeting an already-known camp again immediately is cooldown-gated (no extra gain)",
		absf(camp.player_opinion - after_first) < 0.001)

	# scenario: bypass the cooldown by manipulating _last_greet directly, confirm
	# a real repeat greeting DOES land when the cooldown has actually passed
	# Time.get_ticks_msec() measures since ENGINE start, not a fixed epoch --
	# this test runs early in that lifetime, so 0.0 wouldn't reliably be
	# "40+ seconds ago". A large negative value guarantees the cooldown has
	# genuinely elapsed regardless of how early this executes.
	mgr._last_greet[camp.tribe_name] = -99999.0
	mgr.player_scout(Vector3.ZERO)
	_check("a genuine repeat greeting (cooldown elapsed) raises player_opinion further",
		camp.player_opinion > after_first)

	mgr.free()

	print("\n" + "-".repeat(42))
	print("  %d passed, %d FAILED" % [_pass, _fail])
	print("-".repeat(42) + "\n")
	get_tree().quit(1 if _fail > 0 else 0)

## A minimal stand-in exposing exactly what _find_intruder() touches:
## tribe/home/territory, and calling the REAL _find_intruder() by loading
## npc.gd itself would drag in far more (movement, combat, etc.) than this
## test needs -- instead this loads the real script directly so the real
## fixed function runs, just on a bare Node3D rather than the full npc scene.
func _npc_stub_script() -> Script:
	return load("res://npc.gd")

## A minimal fake world_tribe exposing exactly what player_scout()/
## _greet_tribe()/_find_intruder() touch: discovered/defeated/global_position/
## tribe_name/archetype/strength/player_opinion/greeting()/discover().
func _fake_tribe(name_: String, opinion: float) -> Node3D:
	var script := GDScript.new()
	script.source_code = """
extends Node3D
var discovered: bool = false
var defeated: bool = false
var tribe_name: String = ""
var archetype: String = "Foragers"
var strength: int = 40
var player_opinion: float = 0.0
func discover() -> void:
	discovered = true
func greeting() -> String:
	return "Well met."
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
