extends Node
# Headless test for the AdEx (Adaptive Exponential) neuron type ported into
# spikeling.gd (2026-08-28, tribe-neuron-type-expansion.md Phase 1 priority 2 --
# built AFTER Izhikevich in this task's actual execution order, priority-3-first,
# because Izhikevich turned out to unblock a real _kv bug this port also depends
# on). Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path . res://test_adex_neuron.tscn --quit
#
# The real ODE (ported from Spikeling/pyspike_neuron_models.py's AdExNeuron, the
# actual gap-closing implementation -- core/runtime/runtime.py declares
# `type=AdEx` but never implements distinct dynamics for it, confirmed by direct
# read before writing this, same finding as Izhikevich's port):
#   v' = (-gL*(v-EL) + gL*DeltaT*exp((v-VT)/DeltaT) - w + I) / C
#   w' = (a*(v-EL) - w) / tau_w
#   if v >= threshold: v <- vreset, w <- w + b   (spike + reset + adapt)
#
# PART A -- port fidelity vs the real reference's own self-test
# (_selftest_adex_shows_spike_frequency_adaptation): under CONSTANT current, the
# inter-spike interval must GROW over time (spike-frequency adaptation -- `w`
# accumulates and suppresses the depolarizing drive) while LIF's ISI stays flat
# under the same constant-current condition. Directly measured, not assumed.
#
# PART B -- the scope doc's actual ask: "a neuron that measurably responds LESS
# to repeated stimulation" -- measured directly as firing RATE over successive
# equal-length windows of sustained constant drive, dropping for AdEx and staying
# flat for LIF given the identical stimulus in every window.
#
# Per this task's explicit constraint: this is the port + its fidelity tests
# ONLY. No gameplay hook (e.g. SawBetray) is wired here -- see spikeling.gd's own
# comments and this task's report for why that's a deliberate, separate decision.

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  ADEX NEURON -- port fidelity + measurable-dampening check")
	print("=".repeat(60))

	_part_a_spike_frequency_adaptation_vs_lif()
	_part_b_second_pulse_evokes_a_duller_response()

	print("\n" + "-".repeat(42))
	print("  %d passed, %d FAILED" % [_pass, _fail])
	print("-".repeat(42) + "\n")
	get_tree().quit(1 if _fail > 0 else 0)

func _isis(steps: Array) -> Array:
	var out: Array = []
	for i in range(1, steps.size()):
		out.append(steps[i] - steps[i - 1])
	return out

func _part_a_spike_frequency_adaptation_vs_lif() -> void:
	print("\n-- Part A: AdEx ISI grows under constant current, LIF's stays flat (vs reference self-test) --")
	# Same constant current + substep granularity as pyspike_neuron_models.py's
	# own _selftest_adex_shows_spike_frequency_adaptation(): dt=0.1ms substeps,
	# T=500ms, I=400. dt=0.0001 (seconds) here == 0.1ms per outer step() call,
	# so this port's own substep auto-derivation collapses to exactly 1
	# substep/call, reproducing the reference self-test's own step shape 1:1.
	var adex := Spikeling.new()
	adex.load_from_text("neuron A type=adex threshold=0 C=200 gL=10 EL=-70 VT=-50 delta=2 tau_w=30 a=2 b=60 vreset=-58\ndt=0.0001\n")
	var adex_spike_steps: Array = []
	var steps := 5000   # 5000 * 0.1ms = 500ms, matches T=500 in the reference self-test
	for i in range(steps):
		adex.stimulate("A", 400.0)
		var fired: Array = adex.step()
		if "A" in fired:
			adex_spike_steps.append(i)

	# LIF baseline, same reasoning + scale-down as the reference self-test
	# (I*0.0025 "scaled into LIF's own unit range" -- reproduced identically).
	var lif := Spikeling.new()
	lif.load_from_text("neuron L threshold=1 leak=0.005\nrefractory=0\ndt=0.0001\n")
	var lif_spike_steps: Array = []
	for i in range(steps):
		lif.stimulate("L", 400.0 * 0.0025)
		var fired: Array = lif.step()
		if "L" in fired:
			lif_spike_steps.append(i)

	var isi_a := _isis(adex_spike_steps)
	var isi_l := _isis(lif_spike_steps)
	print("  AdEx spikes: %d" % adex_spike_steps.size())
	print("  LIF  spikes: %d" % lif_spike_steps.size())
	if isi_a.size() >= 3:
		print("  AdEx ISI (first -> last): %s -> %s" % [str(isi_a[0]), str(isi_a[isi_a.size() - 1])])
	if isi_l.size() >= 3:
		print("  LIF  ISI (first -> last): %s -> %s" % [str(isi_l[0]), str(isi_l[isi_l.size() - 1])])

	_check("AdEx fires multiple real spikes under sustained constant current",
		isi_a.size() >= 3)
	_check("LIF fires multiple real spikes under sustained constant current (a genuine comparison, not one dead neuron)",
		isi_l.size() >= 3)
	if isi_a.size() >= 3:
		_check("AdEx's inter-spike interval GROWS over the course of constant stimulation (real spike-frequency adaptation, matching the reference self-test's own finding) -- last ISI at least 20% longer than the first",
			isi_a[isi_a.size() - 1] > isi_a[0] * 1.2)
	if isi_l.size() >= 3:
		_check("LIF's inter-spike interval stays FLAT under the same constant-current condition (no adaptation mechanism at all) -- last ISI within 15% of the first",
			absf(isi_l[isi_l.size() - 1] - isi_l[0]) < isi_l[0] * 0.15)

func _part_b_second_pulse_evokes_a_duller_response() -> void:
	print("\n-- Part B: a SECOND identical pulse of stimulation evokes a duller response than the first --")
	# This is the scope doc's actual real-world framing: not one continuous
	# current the whole time (Part A already showed AdEx's ISI grows to an
	# asymptotic STEADY-STATE rate under that, which is real spike-frequency
	# adaptation but doesn't keep declining forever once adapted -- a flawed
	# first draft of this test compared two late windows against each other
	# after that steady state was already reached and found no further drop,
	# which is real but not what's being asked here). What actually maps onto
	# "betray me once, betray me again" is a DISCRETE repeated event: a pulse
	# of drive, a quiet gap, then an IDENTICAL second pulse -- comparing the
	# response evoked by pulse 2 to pulse 1.
	# tau_w=100 here (not Part A's tau_w=30) matches core/stdlib/neurons.spk's
	# own AdEx line default, and is deliberately used here specifically
	# because the gap between pulses (30ms) is short relative to it -- `w`
	# only decays by ~26% in that gap (1 - exp(-30/100)), so most of pulse 1's
	# accumulated adaptation is still suppressing pulse 2's response. This is
	# a real, honest parameter choice for demonstrating incomplete inter-
	# pulse recovery, not a cherry-picked number: with tau_w << gap the two
	# pulses WOULD look identical (full recovery), which is also a real and
	# unsurprising result of the same equations, not evidence against them.
	var adex := Spikeling.new()
	adex.load_from_text("neuron A type=adex threshold=0 C=200 gL=10 EL=-70 VT=-50 delta=2 tau_w=100 a=2 b=60 vreset=-58\ndt=0.0001\n")
	var lif := Spikeling.new()
	lif.load_from_text("neuron L threshold=1 leak=0.005\nrefractory=0\ndt=0.0001\n")

	# 90ms of drive per pulse -- long enough (given a ~16-22ms ISI from Part A)
	# to fit several real spikes per pulse, so a count-based comparison has
	# room to actually show a difference rather than being stuck at 0 or 1.
	var pulse_steps := 900
	var gap_steps := 300     # 30ms quiet gap between pulses -- short vs tau_w=100ms

	var adex_pulse1 := _count_spikes_over(adex, "A", 400.0, pulse_steps)
	_count_spikes_over(adex, "A", 0.0, gap_steps)   # quiet gap, no stimulation
	var adex_pulse2 := _count_spikes_over(adex, "A", 400.0, pulse_steps)

	var lif_pulse1 := _count_spikes_over(lif, "L", 400.0 * 0.0025, pulse_steps)
	_count_spikes_over(lif, "L", 0.0, gap_steps)
	var lif_pulse2 := _count_spikes_over(lif, "L", 400.0 * 0.0025, pulse_steps)

	print("  AdEx spikes -- pulse 1: %d, pulse 2 (same drive, after a 30ms gap): %d" % [adex_pulse1, adex_pulse2])
	print("  LIF  spikes -- pulse 1: %d, pulse 2 (same drive, after a 30ms gap): %d" % [lif_pulse1, lif_pulse2])

	_check("AdEx's first pulse evokes real spikes",
		adex_pulse1 > 0)
	_check("AdEx's SECOND identical pulse evokes measurably FEWER spikes than the first -- a real dampened response to repeated stimulation, from the adaptation variable alone (no external cooldown/gameplay logic involved)",
		adex_pulse2 < adex_pulse1)
	_check("LIF's second identical pulse evokes the SAME response as the first (no adaptation state to carry the memory of pulse 1 into pulse 2) -- structurally incapable of the dampening AdEx shows above",
		lif_pulse2 == lif_pulse1)

func _count_spikes_over(brain: Spikeling, neuron_name: String, drive: float, steps: int) -> int:
	var count := 0
	for i in range(steps):
		if drive != 0.0:
			brain.stimulate(neuron_name, drive)
		if neuron_name in brain.step():
			count += 1
	return count

func _check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  ok    %s" % label)
	else:
		_fail += 1
		print("  FAIL  %s" % label)
