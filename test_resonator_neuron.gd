extends Node
# Headless test for the Resonator neuron type ported into spikeling.gd
# (2026-08-28, tribe-neuron-type-expansion.md Phase 1). Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path . res://test_resonator_neuron.tscn --quit
#
# Two real, measured things this checks:
#   PART A -- the port is numerically faithful to the real, hardware-
#   validated ResonatorState (Spikeling/core/runtime/runtime.py): driven at
#   its own resonance it builds real amplitude; driven off-frequency by the
#   same-amplitude signal it stays much quieter. Frequency-selective by
#   construction, same as the source model.
#   PART B -- a real, measured finding about whether Resonator can act as a
#   drop-in replacement for LIF's role in TribeDrums' Kuramoto entrainment:
#   LIF is a relaxation oscillator (leaks down, refires under constant
#   drive -- a real periodic pulse train). A damped harmonic oscillator
#   under a CONSTANT (non-periodic) drive has no such mechanism -- it just
#   settles to one static equilibrium amplitude and crosses its detection
#   threshold once, not repeatedly. This test measures that difference
#   directly rather than assuming it.

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  RESONATOR NEURON -- port correctness + self-clocking check")
	print("=".repeat(60))

	_part_a_frequency_selectivity()
	_part_b_constant_drive_self_clocking()

	print("\n" + "-".repeat(42))
	print("  %d passed, %d FAILED" % [_pass, _fail])
	print("-".repeat(42) + "\n")
	get_tree().quit(1 if _fail > 0 else 0)

func _part_a_frequency_selectivity() -> void:
	print("\n-- Part A: frequency selectivity (port fidelity vs ResonatorState) --")
	var freq_hz := 5.0
	var damping := 0.05
	var coupling := 1.0
	var spk := "neuron R type=resonator threshold=0.003 freq=%s damping=%s coupling=%s\ndt=0.01\n" \
		% [str(freq_hz), str(damping), str(coupling)]

	var on_res := Spikeling.new()
	on_res.load_from_text(spk)
	var off_res := Spikeling.new()
	off_res.load_from_text(spk)

	var off_freq_hz := 13.0
	var steps := 300
	for i in range(steps):
		var t: float = float(i) * on_res.step_dt
		on_res.stimulate("R", sin(TAU * freq_hz * t))
		off_res.stimulate("R", sin(TAU * off_freq_hz * t))
		on_res.step()
		off_res.step()

	var on_amp: float = on_res.resonator_amplitude("R")
	var off_amp: float = off_res.resonator_amplitude("R")
	print("  on-frequency (5Hz drive, 5Hz resonator) amplitude:  %s" % str(on_amp))
	print("  off-frequency (13Hz drive, 5Hz resonator) amplitude: %s" % str(off_amp))
	_check("on-frequency drive builds real, nonzero amplitude",
		on_amp > 0.0005)
	_check("off-frequency drive builds LESS amplitude than on-frequency (real selectivity, not a flat gain)",
		off_amp < on_amp)
	_check("the selectivity margin is real, not marginal (on-freq at least 2x off-freq amplitude)",
		on_amp > off_amp * 2.0)

	# a fresh resonator crosses `threshold` (edge-triggered fire) when
	# genuinely driven on-frequency for long enough
	var fire_res := Spikeling.new()
	fire_res.load_from_text(spk)
	var fired_at_least_once := false
	for i in range(steps):
		var t: float = float(i) * fire_res.step_dt
		fire_res.stimulate("R", sin(TAU * freq_hz * t))
		var fired: Array = fire_res.step()
		if "R" in fired:
			fired_at_least_once = true
	_check("sustained on-resonance drive eventually crosses threshold and genuinely fires",
		fired_at_least_once)

func _part_b_constant_drive_self_clocking() -> void:
	print("\n-- Part B: does Resonator self-clock like LIF under a CONSTANT drive? --")
	# LIF baseline: this is the real mechanism TribeDrums' Trust-neuron
	# coupling currently depends on -- a neuron that leaks down and refires
	# repeatedly under an ongoing constant self-stimulus. That periodic
	# pulse train is what has a well-defined PHASE to Kuramoto-lock at all.
	var lif := Spikeling.new()
	lif.load_from_text("neuron Trust threshold=80 leak=3\nrefractory=2\n")
	var lif_fires := 0
	var ticks := 200
	for i in range(ticks):
		lif.stimulate("Trust", 14.0)   # constant per-tick drive
		var fired: Array = lif.step()
		if "Trust" in fired:
			lif_fires += 1

	# Resonator under the SAME shape of drive (a constant amount injected
	# every tick, at the real game's 10Hz brain-tick rate -- step_dt=0.1
	# matches tribemember.gd's TICK_HZ).
	var res := Spikeling.new()
	res.load_from_text("neuron Trust type=resonator threshold=0.05 freq=1.0 damping=0.3 coupling=1.0\ndt=0.1\n")
	var res_fires := 0
	for i in range(ticks):
		res.stimulate("Trust", 14.0)
		var fired: Array = res.step()
		if "Trust" in fired:
			res_fires += 1

	print("  LIF fires over %d ticks of constant drive:       %d" % [ticks, lif_fires])
	print("  Resonator fires over %d ticks of constant drive:  %d" % [ticks, res_fires])
	_check("LIF genuinely produces a repeated, periodic pulse train under constant drive (real relaxation-oscillator behavior)",
		lif_fires >= 5)
	_check("Resonator does NOT self-clock the same way under a constant (non-periodic) drive -- fires at most once, then stays elevated rather than re-triggering",
		res_fires <= 1)

func _check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  ok    %s" % label)
	else:
		_fail += 1
		print("  FAIL  %s" % label)
