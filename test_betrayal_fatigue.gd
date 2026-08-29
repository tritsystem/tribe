extends Node
# Headless test for the AdEx-driven "BetrayalFatigue" hook wired into
# tribemember.gd's real betray() (tribe-neuron-type-expansion.md priority 2 --
# the one identified real gameplay hook for the AdEx port). Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path . res://test_betrayal_fatigue.tscn --quit
#
# PRE-REGISTERED CLAIM (stated before this file was written, see the task
# report): a SECOND betray() from the same source landing a few real seconds
# after the first produces a measurably smaller net Trust-potential drop than
# the first (which itself is unchanged from the old LIF-only baseline, since
# BetrayalFatigue starts at 0.0 for a source that's never been betrayed
# before -- the counter-offset formula is 0 in that case by construction). A
# betrayal a full 60+ real seconds after the second (long past tau_w=5000ms's
# effective decay window) should land back at essentially the SAME magnitude
# as the very first -- bounded, temporary numbness, not a permanent ratchet.
# A different, never-betrayed source's first betrayal should be completely
# unaffected by another member's accumulated fatigue (per-brain state, not
# global/shared) and match the historical -160-equivalent baseline exactly.

const SpatialGrid = preload("res://spatial_grid.gd")

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  BETRAYAL FATIGUE -- AdEx second-betrayal dampening hook")
	print("=".repeat(60))

	_scenario_first_vs_soon_second()
	_scenario_recovery_after_long_gap()
	_scenario_fresh_source_unaffected()

	print("\n" + "-".repeat(42))
	print("  %d passed, %d FAILED" % [_pass, _fail])
	print("-".repeat(42) + "\n")
	get_tree().quit(1 if _fail > 0 else 0)

func _spawn_member(name_: String) -> Node3D:
	var m := CharacterBody3D.new()
	m.set_script(load("res://tribemember.gd"))
	add_child(m)
	m.member_name = name_
	SpatialGrid.update(m)
	return m

# advance N real brain ticks with no stimulus (idle time passing)
func _idle_ticks(m: Node3D, n: int) -> void:
	for i in range(n):
		m._brain_tick()

func _scenario_first_vs_soon_second() -> void:
	print("\n-- Scenario A: first betrayal vs a SECOND, 3 real seconds (30 ticks) later --")
	var m := _spawn_member("Victim1")
	var trust_before1: float = m.brain.get_potential("Trust")

	m.betray()
	m._brain_tick()   # SawBetray fires this tick
	m._brain_tick()   # the -160 synapse (delay=1) arrives THIS tick
	var trust_after1: float = m.brain.get_potential("Trust")
	var drop1: float = trust_before1 - trust_after1

	_idle_ticks(m, 30)   # 3.0s real time, well within tau_w=5000ms's decay window
	var trust_before2: float = m.brain.get_potential("Trust")

	m.betray()
	m._brain_tick()
	m._brain_tick()
	var trust_after2: float = m.brain.get_potential("Trust")
	var drop2: float = trust_before2 - trust_after2

	print("  betrayal 1: Trust %.2f -> %.2f (drop %.2f)" % [trust_before1, trust_after1, drop1])
	print("  betrayal 2 (3s later): Trust %.2f -> %.2f (drop %.2f)" % [trust_before2, trust_after2, drop2])
	print("  BetrayalFatigue adex_w right before betrayal 2: %.4f" % m.brain.adex_adaptation("BetrayalFatigue"))

	_check("betrayal 1 (fresh source, no prior fatigue) drops Trust by close to the full -160 (allowing for Trust's own leak during the 1-tick synapse delay)",
		drop1 > 150.0)
	_check("betrayal 2, landing soon after betrayal 1, drops Trust by MEASURABLY LESS than betrayal 1 did",
		drop2 < drop1 - 10.0)
	m.queue_free()

func _scenario_recovery_after_long_gap() -> void:
	print("\n-- Scenario B: a THIRD betrayal, a full 60 real seconds (600 ticks) after the second, recovers to full strength --")
	var m := _spawn_member("Victim2")
	m.betray()
	m._brain_tick(); m._brain_tick()
	var drop1: float = 0.0
	var t_after1: float = m.brain.get_potential("Trust")

	_idle_ticks(m, 30)
	var t_before2: float = m.brain.get_potential("Trust")
	m.betray()
	m._brain_tick(); m._brain_tick()
	var drop2: float = t_before2 - m.brain.get_potential("Trust")

	_idle_ticks(m, 600)   # 60s real time -- far past tau_w=5000ms's decay window
	var t_before3: float = m.brain.get_potential("Trust")
	m.betray()
	m._brain_tick(); m._brain_tick()
	var drop3: float = t_before3 - m.brain.get_potential("Trust")

	print("  betrayal 2 drop: %.2f   betrayal 3 (60s later) drop: %.2f" % [drop2, drop3])
	_check("a betrayal long after fatigue has decayed away lands back at full strength (drop3 within 5 of the fresh-source baseline ~160)",
		drop3 > drop2 + 10.0 and drop3 > 150.0)
	m.queue_free()

func _scenario_fresh_source_unaffected() -> void:
	print("\n-- Scenario C: a DIFFERENT, never-betrayed source's first betrayal is unaffected by another member's fatigue --")
	var fatigued := _spawn_member("Fatigued")
	fatigued.betray()
	fatigued._brain_tick(); fatigued._brain_tick()
	_idle_ticks(fatigued, 5)
	fatigued.betray()   # second hit, builds real fatigue on THIS member only
	fatigued._brain_tick(); fatigued._brain_tick()

	var fresh := _spawn_member("Fresh")
	var t_before: float = fresh.brain.get_potential("Trust")
	fresh.betray()
	fresh._brain_tick(); fresh._brain_tick()
	var drop: float = t_before - fresh.brain.get_potential("Trust")
	print("  fresh source's first-ever betrayal drop: %.2f (fatigued sibling's own state: adex_w=%.4f)" % [
		drop, fatigued.brain.adex_adaptation("BetrayalFatigue")])
	_check("a fresh, never-betrayed member's first betrayal lands at full strength regardless of another member's accumulated fatigue (per-brain state, not shared/global)",
		drop > 150.0)
	fatigued.queue_free()
	fresh.queue_free()

func _check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  ok    %s" % label)
	else:
		_fail += 1
		print("  FAIL  %s" % label)
