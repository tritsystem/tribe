extends Node
# Headless test for the Izhikevich neuron type ported into spikeling.gd
# (2026-08-28, tribe-neuron-type-expansion.md Phase 1 priority 3). Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path . res://test_izhikevich_neuron.tscn --quit
#
# The real ODE (ported from Spikeling/pyspike_neuron_models.py's IzhikevichNeuron,
# the actual gap-closing implementation -- core/runtime/runtime.py declares
# `type=Izhikevich` but never implements distinct dynamics for it, confirmed by
# direct read before writing this):
#   v' = 0.04*v^2 + 5*v + 140 - u + I
#   u' = a*(b*v - u)
#   if v >= threshold (30): v <- c, u <- u + d   (spike + reset)
#
# PART A -- port fidelity vs the real reference's own self-test
# (_selftest_izhikevich_chattering_bursts): the "chattering" preset (c=-50, d=2)
# must burst (high-variance ISI) while "regular_spiking" (c=-65, d=8) under the
# SAME constant current fires far more uniformly. Directly measured, not assumed.
#
# PART B -- the structural claim from the scope doc: the recovery variable `u`
# actually carries across spikes (incremented by `d`, not reset to a fixed value),
# which LIF's flat reset-to-0 `p` structurally cannot do. Measured directly on both.

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  IZHIKEVICH NEURON -- port fidelity + structural-difference check")
	print("=".repeat(60))

	_part_a_chattering_vs_regular_bursting()
	_part_b_recovery_variable_persists_across_spikes()

	print("\n" + "-".repeat(42))
	print("  %d passed, %d FAILED" % [_pass, _fail])
	print("-".repeat(42) + "\n")
	get_tree().quit(1 if _fail > 0 else 0)

func _isis(steps: Array) -> Array:
	var out: Array = []
	for i in range(1, steps.size()):
		out.append(steps[i] - steps[i - 1])
	return out

func _part_a_chattering_vs_regular_bursting() -> void:
	print("\n-- Part A: chattering preset bursts, regular_spiking doesn't (vs reference self-test) --")
	# Same constant current + substep granularity as pyspike_neuron_models.py's own
	# _selftest_izhikevich_chattering_bursts(): dt=0.5ms substeps, T=300ms, I=10.
	# dt=0.0005 (seconds) here == 0.5ms per outer step() call, so this port's own
	# substep auto-derivation collapses to exactly 1 substep/call, reproducing the
	# reference self-test's own step shape 1:1.
	var chatter := Spikeling.new()
	chatter.load_from_text("neuron Iz type=izhikevich threshold=30 a=0.02 b=0.2 c=-50 d=2\ndt=0.0005\n")
	var regular := Spikeling.new()
	regular.load_from_text("neuron Iz type=izhikevich threshold=30 a=0.02 b=0.2 c=-65 d=8\ndt=0.0005\n")

	var chatter_spike_steps: Array = []
	var regular_spike_steps: Array = []
	var steps := 600   # 600 * 0.5ms = 300ms, matches T=300 in the reference self-test
	for i in range(steps):
		chatter.stimulate("Iz", 10.0)
		var fired_c: Array = chatter.step()
		if "Iz" in fired_c:
			chatter_spike_steps.append(i)
		regular.stimulate("Iz", 10.0)
		var fired_r: Array = regular.step()
		if "Iz" in fired_r:
			regular_spike_steps.append(i)

	var isi_c := _isis(chatter_spike_steps)
	var isi_r := _isis(regular_spike_steps)
	print("  chattering:      %d spikes" % chatter_spike_steps.size())
	print("  regular_spiking: %d spikes" % regular_spike_steps.size())
	_check("chattering preset produces multiple real spikes (>5), same as reference self-test",
		chatter_spike_steps.size() > 5)
	_check("regular_spiking preset also produces real spikes (a genuine comparison, not one dead neuron)",
		regular_spike_steps.size() > 2)

	if isi_c.size() > 2 and isi_r.size() > 2:
		var ratio_c: float = float(isi_c.max()) / maxf(1.0, float(isi_c.min()))
		var ratio_r: float = float(isi_r.max()) / maxf(1.0, float(isi_r.min()))
		print("  chattering ISI max/min ratio:      %s" % str(ratio_c))
		print("  regular_spiking ISI max/min ratio: %s" % str(ratio_r))
		_check("chattering shows real burst structure (uneven ISI) that regular_spiking does not -- genuinely different dynamics from the same equations under the same drive, matching the real reference's own self-test finding",
			ratio_c > ratio_r * 1.5)
	else:
		_check("enough spikes fired in both presets to compare ISI structure", false)

func _part_b_recovery_variable_persists_across_spikes() -> void:
	print("\n-- Part B: recovery variable `u` carries across spikes (LIF structurally cannot) --")
	var iz := Spikeling.new()
	iz.load_from_text("neuron Iz type=izhikevich threshold=30 a=0.02 b=0.2 c=-65 d=8\ndt=0.0005\n")
	var u_before_any_spike: float = iz.izhikevich_recovery("Iz")
	var u_after_spikes: Array = []
	var spikes := 0
	for i in range(600):
		iz.stimulate("Iz", 10.0)
		var fired: Array = iz.step()
		if "Iz" in fired:
			spikes += 1
			u_after_spikes.append(iz.izhikevich_recovery("Iz"))

	print("  u before any spike: %s" % str(u_before_any_spike))
	if u_after_spikes.size() >= 3:
		print("  u right after the first 3 spikes: %s, %s, %s" % [str(u_after_spikes[0]), str(u_after_spikes[1]), str(u_after_spikes[2])])
	_check("neuron actually fired multiple times under sustained constant drive",
		spikes >= 3)
	_check("u is NOT reset to a fixed value after each spike -- it keeps varying across spikes (real accumulated state, not a flat reset like LIF's p)",
		u_after_spikes.size() >= 3 and u_after_spikes[0] != u_after_spikes[1] and u_after_spikes[1] != u_after_spikes[2])
	_check("u moved meaningfully away from its pre-spike value (the recovery variable is actually doing something, not inert)",
		u_after_spikes.size() > 0 and absf(u_after_spikes[0] - u_before_any_spike) > 0.01)

	# LIF contrast: under constant drive, membrane potential resets to EXACTLY
	# the same value (0.0) after every spike -- no possible history-dependent
	# variation, by construction. This is the actual structural gap the scope
	# doc points at, measured directly rather than assumed.
	var lif := Spikeling.new()
	lif.load_from_text("neuron L threshold=80 leak=3\nrefractory=2\n")
	var lif_p_after_spikes: Array = []
	for i in range(200):
		lif.stimulate("L", 14.0)
		var fired: Array = lif.step()
		if "L" in fired:
			lif_p_after_spikes.append(lif.get_potential("L"))
	print("  LIF p right after each spike (first 3): %s" % str(lif_p_after_spikes.slice(0, mini(3, lif_p_after_spikes.size()))))
	_check("LIF resets to the exact SAME value after every spike (0.0, always) -- structurally incapable of the history-dependent variation Izhikevich's u shows above",
		lif_p_after_spikes.size() >= 3 and lif_p_after_spikes[0] == 0.0 and lif_p_after_spikes[1] == 0.0 and lif_p_after_spikes[2] == 0.0)

func _check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  ok    %s" % label)
	else:
		_fail += 1
		print("  FAIL  %s" % label)
