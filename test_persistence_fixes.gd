extends Node
# Headless test for the "built castle then it all disappeared and
# restarted" bug report: capture_state()/apply_state() never persisted
# fortress_tier, material_tier, current_weather, player_opinion, or founded
# settlements at all -- every autosave (every 45s!) and every reload
# silently discarded them, even though basic economy numbers carried over
# fine. Also covers the "new features not happening" tuning fix (odds that
# were too low to ever surface in a normal play session). Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path . res://test_persistence_fixes.tscn --quit

const TribeManagerScript = preload("res://Tribemanager.gd")

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  PERSISTENCE FIXES -- fortress/city state survives a reload")
	print("=".repeat(60))

	var mgr := TribeManagerScript.new()
	add_child(mgr)
	mgr._cat_lines = {"you": [], "tribe": [], "tribes": []}
	mgr._started = true

	# build up real, non-default state to round-trip
	mgr.fortress_tier = 2
	mgr.material_tier = 1
	mgr.current_weather = mgr.Weather.STORM
	mgr.found_outpost(Vector3(300, 0, 0))
	var founded_name: String = str(mgr.outposts[0].get("settlement_name"))
	var founded_district: String = str(mgr.outposts[0].get("district"))

	var fake_tribe := _fake_tribe("Foragers")
	fake_tribe.player_opinion = 0.65
	mgr.world_tribes = [fake_tribe]

	var saved: Dictionary = mgr.capture_state()
	_check("capture_state() actually includes fortress_tier", saved.get("fortress_tier") == 2)
	_check("capture_state() actually includes material_tier", saved.get("material_tier") == 1)
	_check("capture_state() actually includes current_weather", saved.get("current_weather") == mgr.Weather.STORM)
	_check("capture_state() includes the founded settlement",
		(saved.get("outposts", []) as Array).size() == 1)
	var saved_tribe: Dictionary = (saved["tribes"] as Array)[0]
	_check("capture_state() includes player_opinion per tribe",
		absf(float(saved_tribe.get("player_opinion", -99.0)) - 0.65) < 0.001)

	# simulate a fresh reload: a brand-new manager, freshly spawned world,
	# with the OLD state (this is exactly what apply_state() is for)
	var mgr2 := TribeManagerScript.new()
	add_child(mgr2)
	var fake_tribe2 := _fake_tribe("Foragers")   # fresh, opinion back at 0 like a real respawn
	mgr2.world_tribes = [fake_tribe2]
	mgr2.apply_state(saved)

	_check("reloading restores fortress_tier instead of resetting to 0",
		mgr2.fortress_tier == 2)
	_check("...and fortress_built reflects it", mgr2.fortress_built)
	_check("reloading restores material_tier", mgr2.material_tier == 1)
	_check("reloading restores current_weather", mgr2.current_weather == mgr.Weather.STORM)
	_check("reloading restores player_opinion instead of resetting to neutral",
		absf(fake_tribe2.player_opinion - 0.65) < 0.001)
	_check("reloading rebuilds the founded settlement",
		mgr2.outposts.size() == 1)
	_check("...with the same name", str(mgr2.outposts[0].get("settlement_name")) == founded_name)
	_check("...and the same district", str(mgr2.outposts[0].get("district")) == founded_district)

	fake_tribe.free(); fake_tribe2.free()
	mgr.free(); mgr2.free()

	# ── tuning: odds that were too low to ever surface in normal play ──
	var m := CharacterBody3D.new()
	m.set_script(load("res://tribemember.gd"))
	add_child(m)
	_check("migration odds were raised to something that actually shows up in a normal session",
		m.MIGRATE_CHANCE > 0.02)
	m.free()

	_check("poetry composes more often than the old, rarely-observed cadence",
		TribePoetry.COMPOSE_INTERVAL < 50.0 and TribePoetry.PER_NPC_COOLDOWN < 240.0)

	print("\n" + "-".repeat(42))
	print("  %d passed, %d FAILED" % [_pass, _fail])
	print("-".repeat(42) + "\n")
	get_tree().quit(1 if _fail > 0 else 0)

func _fake_tribe(name_: String) -> Node3D:
	var script := GDScript.new()
	script.source_code = """
extends Node3D
var tribe_name: String = ""
var archetype: String = "Foragers"
var food: int = 0
var material_stock: int = 0
var wood: int = 0
var strength: int = 40
var member_count: int = 4
var defeated: bool = false
var leader_traits: Dictionary = {}
var opinions: Dictionary = {}
var bonds: Dictionary = {}
var player_opinion: float = 0.0
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
