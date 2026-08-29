extends Node
# Headless test for the Izhikevich-driven "BurstTrauma" hook wired into
# tribemember.gd's real take_hit() (tribe-neuron-type-expansion.md, the
# Izhikevich priority-3 gameplay hook). Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path . res://test_burst_trauma.tscn --quit
#
# PRE-REGISTERED CLAIM (stated before this file was written, see take_hit()'s
# own comment block above _trauma_hit_count in tribemember.gd for the full
# text): _trauma_hit_count only counts REAL hits with zero awareness of WHEN
# they landed -- 3 hits in one ambush and 3 hits spread across a drawn-out
# fight currently trigger the identical Wary personality shift, identically.
# BurstTrauma (Izhikevich, a=0.001 retuned for real-second game pacing) will
# show its recovery variable iz_u still measurably elevated (>0.0, vs a
# resting baseline around -13/-14) when a hit lands within about a real
# second of the previous one, but decayed back near that baseline (<0.0)
# when the previous hit landed 3+ real seconds earlier. Using that to add one
# phantom trauma count per burst-detected hit: a burst of hits ~1s apart
# should reach the existing TRAUMA_HITS_PER_SHIFT=3 threshold (Wary shift)
# using only 2 REAL hits, while the same 3 total hits spread 3+ real seconds
# apart should still require all 3 real hits, unchanged from current
# behavior.

const SpatialGrid = preload("res://spatial_grid.gd")

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  BURST TRAUMA -- Izhikevich burst-vs-spread damage-pattern hook")
	print("=".repeat(60))

	_scenario_burst_hits_shift_early()
	_scenario_spread_hits_need_all_three()
	_scenario_never_bursts_unaffected()

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

func _idle_ticks(m: Node3D, n: int) -> void:
	for i in range(n):
		m._brain_tick()

func _scenario_burst_hits_shift_early() -> void:
	print("\n-- Scenario A: 3 hits, ~1 real second apart (burst/ambush) --")
	var m := _spawn_member("Burst1")
	print("  personality before: %s" % m.personality)

	m.take_hit(5.0, null)
	m._brain_tick()
	print("  hit 1: trauma_hit_count=%d  burst_bonus_count=%d  personality=%s" % [
		m._trauma_hit_count, m._trauma_burst_bonus_count, m.personality])
	_idle_ticks(m, 10)   # 1.0s real gap -- BurstTrauma's iz_u is still elevated here (calibrated)

	var u_prior_hit2: float = m.brain.izhikevich_recovery("BurstTrauma")
	m.take_hit(5.0, null)
	m._brain_tick()
	print("  hit 2 (1.0s after hit 1): prior_u=%.4f  trauma_hit_count=%d  burst_bonus_count=%d  personality=%s" % [
		u_prior_hit2, m._trauma_hit_count, m._trauma_burst_bonus_count, m.personality])

	_check("BurstTrauma's iz_u is genuinely elevated (>0.0) right before the 2nd hit, 1.0s after the 1st",
		u_prior_hit2 > 0.0)
	_check("the burst shifts personality to Wary after only 2 REAL hits (a phantom 3rd counted from the burst)",
		m.personality == "Wary")
	_check("exactly 1 phantom bonus count was applied to reach it",
		m._trauma_burst_bonus_count == 1)
	m.queue_free()

func _scenario_spread_hits_need_all_three() -> void:
	print("\n-- Scenario B: the SAME 3 hits, 3+ real seconds apart each (drawn-out fight) --")
	var m := _spawn_member("Spread1")

	m.take_hit(5.0, null)
	m._brain_tick()
	_idle_ticks(m, 30)   # 3.0s real gap -- BurstTrauma's iz_u has decayed back near baseline here

	var u_prior_hit2: float = m.brain.izhikevich_recovery("BurstTrauma")
	m.take_hit(5.0, null)
	m._brain_tick()
	print("  hit 2 (3.0s after hit 1): prior_u=%.4f  trauma_hit_count=%d  personality=%s" % [
		u_prior_hit2, m._trauma_hit_count, m.personality])
	_check("BurstTrauma's iz_u has decayed back at/below baseline (<0.0) 3.0s after the previous hit",
		u_prior_hit2 < 0.0)
	_check("personality has NOT shifted yet after only 2 real, well-spaced hits (matches pre-existing behavior)",
		m.personality != "Wary")

	_idle_ticks(m, 30)
	m.take_hit(5.0, null)
	m._brain_tick()
	print("  hit 3 (3.0s after hit 2): trauma_hit_count=%d  burst_bonus_count=%d  personality=%s" % [
		m._trauma_hit_count, m._trauma_burst_bonus_count, m.personality])
	_check("the SAME total 3 hits, spread out, still need the full 3 real hits to shift to Wary -- unchanged from before this change",
		m.personality == "Wary")
	_check("zero phantom bonus counts were applied across this whole spread-out sequence",
		m._trauma_burst_bonus_count == 0)
	m.queue_free()

func _scenario_never_bursts_unaffected() -> void:
	print("\n-- Scenario C: a single isolated hit, no burst, no history -- BurstTrauma stays inert --")
	var m := _spawn_member("Isolated1")
	var u_before: float = m.brain.izhikevich_recovery("BurstTrauma")
	m.take_hit(5.0, null)
	m._brain_tick()
	print("  single hit: trauma_hit_count=%d  burst_bonus_count=%d  personality=%s (baseline iz_u was %.4f)" % [
		m._trauma_hit_count, m._trauma_burst_bonus_count, m.personality, u_before])
	_check("a lone hit with no prior burst history adds exactly 1 to trauma_hit_count, no phantom bonus",
		m._trauma_hit_count == 1 and m._trauma_burst_bonus_count == 0)
	_check("personality is unaffected by a single hit, same as always",
		m.personality != "Wary")
	m.queue_free()

func _check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  ok    %s" % label)
	else:
		_fail += 1
		print("  FAIL  %s" % label)
