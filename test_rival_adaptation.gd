extends Node
# Headless test for the adaptive rival leader (2026-07-19): a real, trained
# linear model reads the player's aggregate history (blame/feed/war) and
# shapes how rival tribes react, instead of every rival treating the same
# action identically regardless of who the player has been.
# Run: Godot_v4.7-stable_win64_console.exe --headless --path . res://test_rival_adaptation.tscn --quit

const TribeManagerScript = preload("res://Tribemanager.gd")

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  ADAPTIVE RIVAL LEADER -- a real trained readout, not a fixed AI")
	print("=".repeat(60))

	# ── the model itself: sensible, monotonic behavior on its trained axes ──
	var model := RivalAdaptationModel.new()
	var peaceful: float = model.predict(0.0, 1.0, 0.0)
	var warmonger: float = model.predict(0.0, 0.0, 1.0)
	var blamed: float = model.predict(1.0, 0.0, 0.0)
	var neutral: float = model.predict(0.0, 0.0, 0.0)
	print("\n  predicted aggression -- neutral: %.2f  peaceful/generous: %.2f  warmonger: %.2f  blamed: %.2f" % [
		neutral, peaceful, warmonger, blamed])
	_check("a generous, peaceful player reads as LESS aggressive than neutral",
		peaceful < neutral)
	_check("a warmonger reads as MORE aggressive than neutral",
		warmonger > neutral)
	_check("a leader who's own tribe blames them constantly also reads as more aggressive/unstable",
		blamed > neutral)
	_check("a warmonger who's ALSO blamed reads as the most aggressive of all",
		model.predict(1.0, 0.0, 1.0) > warmonger and model.predict(1.0, 0.0, 1.0) > blamed)
	_check("predictions always stay in the real 0..1 range",
		peaceful >= 0.0 and peaceful <= 1.0 and warmonger >= 0.0 and warmonger <= 1.0)

	# ── wiring: Tribemanager aggregates REAL per-member counters, not a fake stat ──
	var mgr := TribeManagerScript.new()
	add_child(mgr)
	mgr._cat_lines = {"you": [], "tribe": [], "tribes": []}
	var m1 := _spawn_member("A")
	var m2 := _spawn_member("B")
	m1.feed_count = 8
	m2.feed_count = 6
	mgr.members = [m1, m2]
	var gentle_score: float = mgr.player_aggression_score()
	_check("a player who's fed their tribe a lot reads as low aggression",
		gentle_score < 0.3)

	mgr.player_war_trigger_count = 9
	m1.player_caused_deaths_witnessed = 5
	m2.player_caused_deaths_witnessed = 4
	var harsh_score: float = mgr.player_aggression_score()
	print("  gentle player aggression score: %.2f   after wars+blame: %.2f" % [gentle_score, harsh_score])
	_check("the SAME player's aggregate score rises for real after real war/blame history accrues",
		harsh_score > gentle_score)

	# ── the two real, live opinion hooks actually scale by this score ──
	var rival := _fake_rival()
	# reset to a clean, low-aggression state for a controlled comparison
	mgr.player_war_trigger_count = 0
	m1.player_caused_deaths_witnessed = 0
	m2.player_caused_deaths_witnessed = 0
	mgr._greet_tribe(rival, true)
	var gentle_gain: float = float(rival.get("player_opinion"))

	rival.set("player_opinion", 0.0)
	mgr.player_war_trigger_count = 10
	m1.player_caused_deaths_witnessed = 10
	m2.player_caused_deaths_witnessed = 10
	mgr._last_greet.clear()
	mgr._greet_tribe(rival, true)
	var harsh_gain: float = float(rival.get("player_opinion"))
	print("  greeting opinion gain -- gentle history: %.4f   hostile history: %.4f" % [gentle_gain, harsh_gain])
	_check("a rival greeted by a player with a HOSTILE history warms up measurably less than one with a gentle history",
		harsh_gain < gentle_gain)
	_check("...but still warms up at least a little -- a greeting is never actively punished",
		harsh_gain > 0.0)

	m1.free(); m2.free(); rival.free(); mgr.free()

	print("\n" + "-".repeat(42))
	print("  %d passed, %d FAILED" % [_pass, _fail])
	print("-".repeat(42) + "\n")
	get_tree().quit(1 if _fail > 0 else 0)

func _fake_rival() -> Node:
	var script := GDScript.new()
	script.source_code = "extends Node\nvar tribe_name: String = \"TestRival\"\nvar player_opinion: float = 0.0\nfunc greeting() -> String:\n\treturn \"\"\n"
	script.reload()
	var n := Node.new()
	n.set_script(script)
	add_child(n)
	return n

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
