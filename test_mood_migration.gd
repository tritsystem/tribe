extends Node
# Headless test for the mood-driven mass migration feature (2026-07-19):
# a real, sustained low tribe-wide Trust/Follow firing rate triggers a
# collective split, distinct from any one member's own relationship
# threshold. Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path . res://test_mood_migration.tscn --quit

const TribeManagerScript = preload("res://Tribemanager.gd")

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  MOOD MIGRATION -- sustained low tribe-wide trust/follow")
	print("=".repeat(60))

	# ── trust_follow_mood() itself reflects real brain activity ──
	var m := _spawn_member("Solo")
	_check("a fresh member starts with a real (non-crashing) mood reading",
		m.trust_follow_mood() >= 0.0 and m.trust_follow_mood() <= 1.0)
	m.free()

	# ── healthy tribe: mood stays high, no migration ──
	var mgr := TribeManagerScript.new()
	add_child(mgr)
	mgr._cat_lines = {"you": [], "tribe": [], "tribes": []}
	var healthy: Array = []
	for i in range(5):
		var hm := _spawn_member("Healthy%d" % i)
		hm._trust_follow_ema = 0.9   # a thriving member -- Trust/Follow fire constantly
		hm.relationship = 0.8
		mgr.members.append(hm)
		healthy.append(hm)
	for i in range(20):
		mgr._mood_check_accum = TribeManagerScript.MOOD_CHECK_INTERVAL
		mgr._mood_tick(0.0)
	_check("a genuinely thriving tribe's mood EMA stays high",
		mgr._tribe_mood_ema > 0.5)
	var any_left := false
	for hm in healthy:
		if bool(hm.get("_leaving")):
			any_left = true
	_check("...and nobody leaves",
		not any_left)
	for hm in healthy:
		hm.free()
	mgr.free()

	# ── unhealthy tribe: sustained low mood triggers a real collective split ──
	var mgr2 := TribeManagerScript.new()
	add_child(mgr2)
	mgr2._cat_lines = {"you": [], "tribe": [], "tribes": []}
	var unhealthy: Array = []
	for i in range(6):
		var um := _spawn_member("Low%d" % i)
		um._trust_follow_ema = 0.01   # Trust/Follow essentially never fire
		um.relationship = 0.1 + float(i) * 0.05   # a real spread, so we can check WHO leaves
		mgr2.members.append(um)
		unhealthy.append(um)
	for i in range(20):
		mgr2._mood_check_accum = TribeManagerScript.MOOD_CHECK_INTERVAL
		mgr2._mood_tick(0.0)
	_check("a genuinely unhealthy tribe's mood EMA drops below the low-mood bar",
		mgr2._tribe_mood_ema < TribeManagerScript.LOW_MOOD_THRESHOLD)
	var left_count := 0
	for um in unhealthy:
		if bool(um.get("_leaving")):
			left_count += 1
	_check("sustained low tribe-wide mood triggers a REAL collective migration (someone actually leaves)",
		left_count > 0)
	_check("the migration only takes the least-trusting fraction, not everyone",
		left_count < unhealthy.size())
	# lowest-relationship members (Low0, Low1, ...) should be the ones who left
	var lowest_left: bool = bool(unhealthy[0].get("_leaving"))
	var highest_stayed: bool = not bool(unhealthy[unhealthy.size() - 1].get("_leaving"))
	_check("it's specifically the LEAST-trusting members who leave, not an arbitrary subset",
		lowest_left and highest_stayed)

	# ── cooldown: doesn't re-trigger immediately even if mood stays low ──
	var streak_before: int = mgr2._low_mood_streak
	var last_migration_before: float = mgr2._last_migration_time
	for i in range(3):
		mgr2._mood_check_accum = TribeManagerScript.MOOD_CHECK_INTERVAL
		mgr2._mood_tick(0.0)
	_check("a cooldown stops the migration from re-firing every single check",
		mgr2._last_migration_time == last_migration_before)

	for um in unhealthy:
		um.free()
	mgr2.free()

	print("\n" + "-".repeat(42))
	print("  %d passed, %d FAILED" % [_pass, _fail])
	print("-".repeat(42) + "\n")
	get_tree().quit(1 if _fail > 0 else 0)

func _spawn_member(n: String) -> Node:
	var m := CharacterBody3D.new()
	m.set_script(load("res://tribemember.gd"))
	add_child(m)
	m.member_name = n
	return m

func _check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  ok    %s" % label)
	else:
		_fail += 1
		print("  FAIL  %s" % label)
