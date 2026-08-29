extends RefCounted
class_name Spikeling

# ─────────────────────────────────────────────────────────────────────────────
# Spikeling GDScript runtime  —  the THIRD backend for the Spikeling DSL.
#   .spk (C)   .spk (Verilog)   .spk (GDScript / Godot)  ← this file
#
# Loads a .spk brain (neurons + synapses), steps the spiking dynamics, and
# exposes input injection + spike outputs so a Godot game can use a spiking
# neural network as a live "mind" (e.g. a horde hive-mind).
#
# Designed to be CHEAP: one step() call runs the whole network. Run ONE of
# these per horde, not one per zombie.
#
# .spk format it understands:
#   # Spikeling Neural Configuration
#   neuron PlayerNorth threshold=100 leak=5
#   neuron SwarmNorth  threshold=100 leak=5
#   synapse PlayerNorth -> SwarmNorth weight=60
#   refractory=4
# ─────────────────────────────────────────────────────────────────────────────

class Neuron:
	var name: String
	var threshold: float = 100.0
	var leak: float = 5.0
	var p: float = 0.0          # membrane potential
	var refr_left: int = 0      # ticks remaining in refractory
	var fired: bool = false     # did it fire this step?
	var fire_count: int = 0
	# VELOCITY-SENSITIVE FIRING (2026-07-19): how far potential overshot
	# threshold the moment it fired, 0..1 normalized by threshold -- a
	# neuron that just barely crossed vs. one driven well past it are
	# different EVENTS, not the same binary "fired" flag. Read via
	# fire_strength() right after step(); consumers (e.g. tribe_drums.gd)
	# use it for velocity-sensitive output instead of a flat hit every time.
	var last_fire_strength: float = 0.0
	# STDP (2026-08-28): the step index of this neuron's most recent spike,
	# -1 if it has never fired. Needed to compute pre/post SPIKE TIMING
	# (not just "did both fire this step") for stdp_learn() below.
	var last_fire_step: int = -1

	# RESONATOR (2026-08-28): neuron model selector. "lif" (default) is the
	# existing pulsed/refractory integrate-and-fire model above, untouched.
	# "resonator" switches this neuron to a CONTINUOUSLY-driven damped
	# harmonic oscillator instead -- ported from the real Spikeling engine's
	# ResonatorState (Spikeling/core/runtime/runtime.py), not reinvented
	# here. That model is already physically hardware-validated (real mic
	# input, structured noise nulled at readout -- see
	# spikeling_phononic_bridge). Frequency-selective by construction:
	# unlike LIF, it only builds amplitude when its drive contains energy
	# near its own freq_hz, and never "resets" -- there's no refractory
	# period, just continuous x/v integration.
	var type: String = "lif"
	# resonator-only state/params below -- declared unconditionally (cheap,
	# a handful of floats) so nothing about the LIF path above has to
	# change shape; every field here is inert when type == "lif".
	var freq_hz: float = 1.0
	var damping: float = 0.3
	var coupling: float = 1.0
	var res_x: float = 0.0             # oscillator position
	var res_v: float = 0.0             # oscillator velocity
	var energy_ema: float = 0.0        # exp. moving avg of x^2 -- cheap stand-in for RMS energy
	# below their gate_threshold. Left at 0.0 by default (i.e. off) here --
	# ResonatorState's original 0.00024 default was tuned for a 40kHz
	# audio-hardware amplitude scale; this game's neuron drive magnitudes
	# (stimulate() amounts like 50-400) live on a completely different
	# scale, so gating on an unexamined ported constant could silently
	# suppress real detections. Opt in per-neuron via the .spk
	# `gate_threshold=` key once a real amplitude scale is known.
	var gate_threshold: float = 0.0
	# 0.5s (5 ticks at this project's 10Hz brain tick -- see tribemember.gd
	# TICK_HZ) instead of ResonatorState's original 0.0025s: that constant
	# was correct for its own 40kHz sample rate but would collapse to
	# near-zero smoothing (alpha clamps to 1.0) at this game's much coarser
	# per-step dt -- the exact "sample-rate bug" runtime.py's own docstring
	# warns about, not repeated here.
	var energy_time_constant: float = 0.5

	# IZHIKEVICH (2026-08-28): "type=izhikevich" -- another opt-out of the
	# LIF path, ported from Spikeling/pyspike_neuron_models.py's
	# IzhikevichNeuron (the REAL, verified implementation -- core/runtime/
	# runtime.py's NeuronState + compiler.py's grammar accept `type=
	# Izhikevich` and document the model in core/stdlib/neurons.spk, but a
	# direct read of runtime.py confirmed the DSL parser's NEURON_RE regex
	# never actually captures a/b/c/d and the runtime treats every declared
	# type as plain LIF regardless -- that stdlib line is aspirational
	# documentation, not a wired path. pyspike_neuron_models.py is the real
	# gap-closing implementation with its own passing self-tests, so THAT'S
	# what's ported here, not the never-executed stdlib doc line).
	# Two state variables instead of LIF's one: iz_v (membrane potential,
	# analogous to LIF's `p` but with a real nonlinear ODE, not linear
	# leak) and iz_u (a recovery variable that carries across spikes --
	# unlike LIF, which resets flatly to 0 every time, iz_u only gets
	# INCREMENTED by `d` on each spike and decays back on its own separate
	# timescale, giving this model real spike-history memory LIF cannot
	# represent at all).
	var iz_v: float = -65.0
	var iz_u: float = -13.0            # = b * v0, recomputed properly on load
	var iz_a: float = 0.02             # recovery time-scale (smaller = slower u)
	var iz_b: float = 0.2              # sensitivity of u to sub-threshold v
	var iz_c: float = -65.0            # v is reset to this after a spike
	var iz_d: float = 8.0              # u jumps by this after a spike
	# Real per-outer-tick spike count (see _step_izhikevich/_step_adex):
	# at this game's typical coarse step_dt, the real sub-millisecond model
	# can legitimately cross threshold more than once inside a single
	# step() call. `fired`/fired_now report "did it fire at least once
	# this tick" (same one-event-per-step() contract every other neuron
	# type in this file honors); this field exposes the real underlying
	# count for a consumer that cares about the difference.
	var last_substep_spikes: int = 0

	# ADEX (2026-08-28): "type=adex" -- same rationale/source file as
	# Izhikevich above (pyspike_neuron_models.py's AdExNeuron, the real
	# implementation; core/runtime/runtime.py's declared-but-unwired type).
	# Also two state variables: adex_v (membrane potential) and adex_w (an
	# ADAPTATION variable that accumulates with every spike and actively
	# suppresses the depolarizing current -- LIF has no analogous term at
	# all, so identical repeated stimulation always produces an identical
	# LIF response; AdEx's response measurably weakens over sustained
	# firing). Parameter defaults below are Brette & Gerstner (2005)'s own
	# published regular-spiking values, exactly matching
	# pyspike_neuron_models.py's AdExNeuron() defaults -- not invented.
	var adex_v: float = -70.0
	var adex_w: float = 0.0
	var adex_C: float = 200.0          # membrane capacitance (pF)
	var adex_gL: float = 10.0          # leak conductance (nS)
	var adex_EL: float = -70.0         # leak reversal / resting potential (mV)
	var adex_VT: float = -50.0         # exponential threshold voltage (mV)
	var adex_deltaT: float = 2.0       # exponential slope factor (mV) -- the .spk `delta=` key
	var adex_tau_w: float = 30.0       # adaptation time constant (ms)
	var adex_a: float = 2.0            # sub-threshold adaptation coupling (nS)
	var adex_b: float = 60.0           # spike-triggered adaptation increment (pA)
	var adex_vreset: float = -58.0     # v is reset to this after a spike

class Synapse:
	var src: int                # source neuron index
	var dst: int                # target neuron index
	var weight: float
	var base_weight: float      # innate weight at load — learning relaxes back toward this
	# CONDUCTION DELAY (2026-08-28): real axons take variable time to
	# transmit a spike depending on length/myelination -- Brian2 treats
	# per-synapse `delay` as a first-class primitive (Synapses().delay),
	# distinct from snnTorch/SpikingJelly's usual simplification of
	# instantaneous (1-timestep) propagation. Previously EVERY synapse in
	# this runtime delivered in exactly 1 step regardless of any notion of
	# distance -- this was a real, unexamined simplification, not a
	# deliberate design choice. delay=1 (the old default) preserves
	# existing behavior exactly for every brain already written.
	var delay: int = 1

var neurons: Array = []                  # Array[Neuron]
var synapses: Array = []                 # Array[Synapse]
var _name_to_idx: Dictionary = {}        # String -> int
var refractory_ticks: int = 4
var step_count: int = 0
# RESONATOR (2026-08-28): seconds per step() call. Only meaningful for
# resonator-type neurons (LIF is tick-based, not physically timed, so this
# doesn't touch its behavior at all). Defaults to this project's actual
# brain-tick rate (tribemember.gd TICK_HZ = 10Hz -> 0.1s/tick), overridable
# per-brain via a `dt=` line in the .spk text, same pattern as refractory=.
# NAMED step_dt, not dt: stdp_learn() below already has a local `dt`
# (spike-timing delta, in ticks) -- same short name, different unit and
# meaning entirely; keeping them visually distinct avoids relying on
# GDScript's local-shadows-member rule to keep them apart.
var step_dt: float = 0.1

# spikes scheduled to arrive next step: idx -> accumulated weight
var _pending: Dictionary = {}
# CONDUCTION DELAY (2026-08-28): synaptic spikes now schedule for
# step_count + s.delay, not unconditionally "next step" -- needs a queue
# keyed by the ABSOLUTE future step they land on, not a single one-step-
# ahead dict. _pending (above) stays as the EXTERNAL stimulate() path,
# which is deliberately immediate (arrives the very step you call
# stimulate() before step()) -- unchanged behavior, real axonal delay only
# applies to synapse-to-synapse propagation, not direct sensory injection.
var _scheduled: Dictionary = {}   # int step_count -> Dictionary[int idx -> float weight]

func _idx(n: String) -> int:
	return _name_to_idx.get(n, -1)

# ── Load a brain from .spk text ──────────────────────────────────────────────
func load_from_text(text: String) -> bool:
	neurons.clear()
	synapses.clear()
	_name_to_idx.clear()
	_pending.clear()
	step_count = 0

	var lines := text.split("\n")
	# pass 1: neurons (need them all before synapses can resolve names)
	for raw in lines:
		var line := (raw as String).strip_edges()
		if line.begins_with("neuron "):
			var n := Neuron.new()
			n.name = _grab(line, "neuron ", " ")
			n.threshold = float(_kv(line, "threshold", "100"))
			n.leak = float(_kv(line, "leak", "5"))
			# RESONATOR (2026-08-28): `type=resonator` opts a neuron out of
			# the LIF path entirely. Unrecognized/absent `type=` -> "lif",
			# so every brain written before this change parses identically.
			n.type = _kv(line, "type", "lif")
			if n.type == "resonator":
				n.freq_hz = float(_kv(line, "freq", "1.0"))
				n.damping = float(_kv(line, "damping", "0.3"))
				n.coupling = float(_kv(line, "coupling", "1.0"))
				n.gate_threshold = float(_kv(line, "gate_threshold", str(n.gate_threshold)))
				n.energy_time_constant = float(_kv(line, "energy_time_constant", str(n.energy_time_constant)))
			elif n.type == "izhikevich":
				# Re-default `threshold` here to the model's own real spike
				# condition (30, hardcoded in the reference -- `if v >= 30`,
				# not a tunable in pyspike_neuron_models.py, but exposed as
				# an override anyway for experimentation) instead of the
				# generic LIF-shaped "100" fallback the unconditional parse
				# above already applied -- same reasoning as Resonator's
				# threshold being re-scoped to its own units.
				n.threshold = float(_kv(line, "threshold", "30"))
				n.iz_a = float(_kv(line, "a", "0.02"))
				n.iz_b = float(_kv(line, "b", "0.2"))
				n.iz_c = float(_kv(line, "c", "-65"))
				n.iz_d = float(_kv(line, "d", "8"))
				var iz_v0 := float(_kv(line, "v0", "-65"))
				n.iz_v = iz_v0
				n.iz_u = n.iz_b * iz_v0   # matches IzhikevichNeuron.__init__: u0 = b * v0
			elif n.type == "adex":
				# Same re-default reasoning as Izhikevich above: the real
				# AdExNeuron default spike_threshold is 0.0 (mV-scale, not
				# the generic "100" LIF fallback).
				n.threshold = float(_kv(line, "threshold", "0"))
				n.adex_C = float(_kv(line, "C", "200"))
				n.adex_gL = float(_kv(line, "gL", "10"))
				n.adex_EL = float(_kv(line, "EL", "-70"))
				n.adex_VT = float(_kv(line, "VT", "-50"))
				n.adex_deltaT = float(_kv(line, "delta", "2"))
				n.adex_tau_w = float(_kv(line, "tau_w", "30"))
				n.adex_a = float(_kv(line, "a", "2"))
				n.adex_b = float(_kv(line, "b", "60"))
				n.adex_vreset = float(_kv(line, "vreset", "-58"))
				n.adex_v = n.adex_EL
				n.adex_w = 0.0
			_name_to_idx[n.name] = neurons.size()
			neurons.append(n)
		elif line.begins_with("refractory="):
			refractory_ticks = int(line.replace("refractory=", "").replace("ms", "").strip_edges())
		elif line.begins_with("dt="):
			step_dt = float(line.replace("dt=", "").strip_edges())

	# pass 2: synapses
	for raw in lines:
		var line := (raw as String).strip_edges()
		if line.begins_with("synapse "):
			# synapse SRC -> DST weight=NN
			var body := line.substr("synapse ".length())
			var arrow := body.split("->")
			if arrow.size() != 2:
				continue
			var src_name := (arrow[0] as String).strip_edges()
			var rest := (arrow[1] as String).strip_edges()
			var dst_name := rest.split(" ")[0].strip_edges()
			var w := float(_kv(line, "weight", "50"))
			var d := int(_kv(line, "delay", "1"))
			var si := _idx(src_name)
			var di := _idx(dst_name)
			if si == -1 or di == -1:
				push_warning("Spikeling: synapse references unknown neuron: " + line)
				continue
			var s := Synapse.new()
			s.src = si; s.dst = di; s.weight = w
			s.base_weight = w
			s.delay = maxi(1, d)
			synapses.append(s)

	return neurons.size() > 0

# ── Inject external stimulus into a named input neuron (this step) ────────────
func stimulate(neuron_name: String, amount: float) -> void:
	var i := _idx(neuron_name)
	if i >= 0:
		_pending[i] = _pending.get(i, 0.0) + amount

func stimulate_idx(i: int, amount: float) -> void:
	if i >= 0 and i < neurons.size():
		_pending[i] = _pending.get(i, 0.0) + amount

# ── Advance the whole network one tick ───────────────────────────────────────
# Returns an array of names that fired this step (for the game to react to).
func step() -> Array:
	step_count += 1
	var fired_now: Array = []

	# CONDUCTION DELAY: pull whatever synaptic spikes were scheduled to
	# land on THIS exact step (could have been scheduled 1..N steps ago,
	# depending on each synapse's own delay), then discard that slot --
	# same "consume and clear" shape the old next_pending dict had, just
	# keyed by absolute step instead of always being "the very next one".
	var incoming_synaptic: Dictionary = _scheduled.get(step_count, {})
	_scheduled.erase(step_count)

	for i in range(neurons.size()):
		var n: Neuron = neurons[i]
		n.fired = false

		# RESONATOR (2026-08-28): a completely separate branch, not a
		# modification of the LIF path below -- a resonator neuron has no
		# refractory period and is never "pulsed", so it can't share the
		# leak/threshold-reset mechanics LIF relies on. Kept as its own
		# private helper (_step_resonator) rather than inlined here so the
		# LIF code beneath is textually untouched.
		if n.type == "resonator":
			_step_resonator(n, i, incoming_synaptic, fired_now)
			continue

		# IZHIKEVICH / ADEX (2026-08-28): also fully separate branches, same
		# reasoning as Resonator above -- these have their own real
		# nonlinear ODEs (ported from pyspike_neuron_models.py) with their
		# own reset/adaptation mechanics, so they don't share LIF's
		# leak/threshold/refr_left machinery either.
		if n.type == "izhikevich":
			_step_izhikevich(n, i, incoming_synaptic, fired_now)
			continue
		if n.type == "adex":
			_step_adex(n, i, incoming_synaptic, fired_now)
			continue

		if n.refr_left > 0:
			n.refr_left -= 1
			continue

		# leaky integration
		n.p -= n.leak
		if n.p < 0.0:
			n.p = 0.0
		# incoming stimulus: external (immediate, this step) + synaptic
		# (delayed per-synapse, may have been scheduled several steps ago)
		n.p += _pending.get(i, 0.0) + incoming_synaptic.get(i, 0.0)

		# threshold check
		if n.p >= n.threshold:
			# capture overshoot BEFORE resetting p -- this is the actual
			# "how hard did it fire" signal, gone the instant p is zeroed
			n.last_fire_strength = clampf((n.p - n.threshold) / maxf(1.0, n.threshold), 0.0, 1.0)
			n.p = 0.0
			n.refr_left = refractory_ticks
			n.fired = true
			n.fire_count += 1
			n.last_fire_step = step_count
			fired_now.append(n.name)
			# propagate to targets, landing on step_count + this synapse's
			# OWN delay -- a long-delay synapse's spike arrives later than
			# a short one, even from the same firing event this step.
			for s in synapses:
				if s.src == i:
					var arrival: int = step_count + s.delay
					if not _scheduled.has(arrival):
						_scheduled[arrival] = {}
					var bucket: Dictionary = _scheduled[arrival]
					bucket[s.dst] = bucket.get(s.dst, 0.0) + s.weight

	_pending.clear()
	return fired_now

# ── RESONATOR: continuously-driven damped harmonic oscillator ─────────────────
# Ported from Spikeling/core/runtime/runtime.py's ResonatorState.step() --
# the same formula, same symplectic-Euler integration order (velocity
# updated from acceleration BEFORE position, not the reverse -- the source
# docstring notes plain Euler is numerically unstable here), same amplitude-
# gated energy EMA optimization. Only the two things that are legitimately
# per-project (dt's real-world scale, gate_threshold's default) were
# re-tuned for this game rather than blindly copied -- see the Neuron
# field comments above for why.
#
# Unlike LIF, this is edge-triggered on ENERGY crossing `threshold`, not a
# potential hitting it, and there's no reset/refractory afterward: the
# oscillator just keeps ringing. "Fired" here means "just started being
# loud enough to count as detected", exactly like the real ResonatorState.
func _step_resonator(n: Neuron, i: int, incoming_synaptic: Dictionary, fired_now: Array) -> void:
	var drive: float = _pending.get(i, 0.0) + incoming_synaptic.get(i, 0.0)
	var omega: float = TAU * n.freq_hz
	var accel: float = -(omega * omega) * n.res_x - 2.0 * n.damping * omega * n.res_v
	accel += n.coupling * drive
	n.res_v += accel * step_dt
	n.res_x += n.res_v * step_dt

	var alpha: float = minf(1.0, step_dt / n.energy_time_constant)
	var was_above: bool = sqrt(n.energy_ema) >= n.threshold
	if absf(n.res_x) >= n.gate_threshold:
		n.energy_ema += alpha * (n.res_x * n.res_x - n.energy_ema)
	else:
		n.energy_ema -= alpha * n.energy_ema  # decay only -- skip the x*x multiply
	var now_above: bool = sqrt(n.energy_ema) >= n.threshold

	if now_above and not was_above:
		n.last_fire_strength = clampf((sqrt(n.energy_ema) - n.threshold) / maxf(0.0001, n.threshold), 0.0, 1.0)
		n.fired = true
		n.fire_count += 1
		n.last_fire_step = step_count
		fired_now.append(n.name)
		# same delayed-propagation shape as the LIF branch in step() above
		# (deliberately duplicated, not factored into a shared helper --
		# keeps this branch fully self-contained and easy to verify against
		# ResonatorState in isolation).
		for s in synapses:
			if s.src == i:
				var arrival: int = step_count + s.delay
				if not _scheduled.has(arrival):
					_scheduled[arrival] = {}
				var bucket: Dictionary = _scheduled[arrival]
				bucket[s.dst] = bucket.get(s.dst, 0.0) + s.weight

# ── IZHIKEVICH: two-variable nonlinear spiking model ──────────────────────────
# Ported from Spikeling/pyspike_neuron_models.py's IzhikevichNeuron.step() --
# the real Izhikevich (2003) equations, same substep-Euler scheme (the
# 0.04v^2 term is stiff enough that a single 100ms-scale outer tick would be
# numerically unstable, so the reference sub-steps at 0.5ms and this port
# derives the same substep count from whatever step_dt actually is, same
# idea as Resonator deriving its energy-EMA alpha from dt instead of using a
# fixed constant):
#   v' = 0.04*v^2 + 5*v + 140 - u + I
#   u' = a*(b*v - u)
#   if v >= threshold (30 by default): v <- c, u <- u + d   (spike + reset)
# `u` is the whole point: it is NOT reset to a fixed value like LIF's `p`,
# it's INCREMENTED by `d` and otherwise evolves on its own a-scaled
# timescale -- so the neuron's own recent firing history keeps shaping its
# future response, a structural capability flat-reset LIF does not have.
func _step_izhikevich(n: Neuron, i: int, incoming_synaptic: Dictionary, fired_now: Array) -> void:
	var drive: float = _pending.get(i, 0.0) + incoming_synaptic.get(i, 0.0)
	var dt_ms: float = step_dt * 1000.0
	var substeps: int = maxi(1, int(dt_ms / 0.5))
	var sub_dt: float = dt_ms / float(substeps)
	var any_fired := false
	n.last_substep_spikes = 0
	for _s in range(substeps):
		var dv: float = 0.04 * n.iz_v * n.iz_v + 5.0 * n.iz_v + 140.0 - n.iz_u + drive
		var du: float = n.iz_a * (n.iz_b * n.iz_v - n.iz_u)
		n.iz_v += dv * sub_dt
		n.iz_u += du * sub_dt
		if n.iz_v >= n.threshold:
			n.last_fire_strength = clampf((n.iz_v - n.threshold) / maxf(1.0, absf(n.threshold)), 0.0, 1.0)
			n.iz_v = n.iz_c
			n.iz_u += n.iz_d
			any_fired = true
			n.last_substep_spikes += 1
	n.fired = any_fired
	if any_fired:
		n.fire_count += 1
		n.last_fire_step = step_count
		fired_now.append(n.name)
		# same delayed-propagation shape as LIF/Resonator above (deliberately
		# duplicated rather than shared -- keeps each branch self-contained
		# and easy to verify against its own reference model in isolation).
		for s in synapses:
			if s.src == i:
				var arrival: int = step_count + s.delay
				if not _scheduled.has(arrival):
					_scheduled[arrival] = {}
				var bucket: Dictionary = _scheduled[arrival]
				bucket[s.dst] = bucket.get(s.dst, 0.0) + s.weight

## Izhikevich-only introspection: the recovery variable `u` -- the actual
## state that carries across spikes and makes bursting/adaptation possible.
## 0.0 for non-Izhikevich neurons or unknown names.
func izhikevich_recovery(neuron_name: String) -> float:
	var i := _idx(neuron_name)
	if i < 0 or neurons[i].type != "izhikevich":
		return 0.0
	return neurons[i].iz_u

## Izhikevich-only introspection: raw membrane potential `v`.
func izhikevich_potential(neuron_name: String) -> float:
	var i := _idx(neuron_name)
	return neurons[i].iz_v if i >= 0 else 0.0

# ── ADEX: adaptive exponential integrate-and-fire ──────────────────────────
# Ported from Spikeling/pyspike_neuron_models.py's AdExNeuron.step() -- the
# real Brette & Gerstner (2005) equations, same 0.1ms substep scheme (the
# exponential term is the stiff part here, same reasoning as Izhikevich's
# 0.5ms substeps above):
#   v' = (-gL*(v-EL) + gL*DeltaT*exp((v-VT)/DeltaT) - w + I) / C
#   w' = (a*(v-EL) - w) / tau_w
#   if v >= threshold: v <- vreset, w <- w + b   (spike + reset + adapt)
# `w` is the adaptation variable: it grows by a fixed increment `b` every
# time this neuron spikes, and that accumulated `w` subtracts directly from
# the depolarizing current on every subsequent substep -- so repeated
# stimulation drives progressively WEAKER responses over time (spike-
# frequency adaptation) purely from this state, with no external cooldown
# mechanism required. LIF's leak has no memory of past spikes at all, so it
# cannot reproduce this regardless of how leak/threshold are tuned.
func _step_adex(n: Neuron, i: int, incoming_synaptic: Dictionary, fired_now: Array) -> void:
	var drive: float = _pending.get(i, 0.0) + incoming_synaptic.get(i, 0.0)
	var dt_ms: float = step_dt * 1000.0
	var substeps: int = maxi(1, int(dt_ms / 0.1))
	var sub_dt: float = dt_ms / float(substeps)
	var any_fired := false
	n.last_substep_spikes = 0
	for _s in range(substeps):
		var exp_term: float = n.adex_deltaT * exp(minf(50.0, (n.adex_v - n.adex_VT) / n.adex_deltaT))
		var dv: float = (-n.adex_gL * (n.adex_v - n.adex_EL) + n.adex_gL * exp_term - n.adex_w + drive) / n.adex_C
		var dw: float = (n.adex_a * (n.adex_v - n.adex_EL) - n.adex_w) / n.adex_tau_w
		n.adex_v += dv * sub_dt
		n.adex_w += dw * sub_dt
		if n.adex_v >= n.threshold:
			n.last_fire_strength = clampf((n.adex_v - n.threshold) / maxf(1.0, absf(n.threshold)), 0.0, 1.0)
			n.adex_v = n.adex_vreset
			n.adex_w += n.adex_b
			any_fired = true
			n.last_substep_spikes += 1
	n.fired = any_fired
	if any_fired:
		n.fire_count += 1
		n.last_fire_step = step_count
		fired_now.append(n.name)
		for s in synapses:
			if s.src == i:
				var arrival: int = step_count + s.delay
				if not _scheduled.has(arrival):
					_scheduled[arrival] = {}
				var bucket: Dictionary = _scheduled[arrival]
				bucket[s.dst] = bucket.get(s.dst, 0.0) + s.weight

## AdEx-only introspection: the adaptation variable `w` -- grows with every
## spike and suppresses future response. 0.0 for non-AdEx neurons/unknown names.
func adex_adaptation(neuron_name: String) -> float:
	var i := _idx(neuron_name)
	if i < 0 or neurons[i].type != "adex":
		return 0.0
	return neurons[i].adex_w

## AdEx-only introspection: raw membrane potential `v`.
func adex_potential(neuron_name: String) -> float:
	var i := _idx(neuron_name)
	return neurons[i].adex_v if i >= 0 else 0.0

## Resonator-only introspection: current RMS-style amplitude estimate
## (sqrt of the energy EMA), same units as `threshold`. 0.0 for LIF neurons
## or unknown names.
func resonator_amplitude(neuron_name: String) -> float:
	var i := _idx(neuron_name)
	if i < 0 or neurons[i].type != "resonator":
		return 0.0
	return sqrt(neurons[i].energy_ema)

## Resonator-only introspection: raw oscillator position `x` this step --
## the actual continuous waveform, not just the edge-triggered detection.
func resonator_x(neuron_name: String) -> float:
	var i := _idx(neuron_name)
	return neurons[i].res_x if i >= 0 else 0.0

# ── Hebbian-ish learning: strengthen synapses whose src AND dst fired ─────────
# Call after step() when you want the brain to learn. reward scales the change.
#
# Bounded + homeostatic: a reinforced synapse can thicken only up to GROW_CEIL×
# its innate weight (so you still SEE it learn), and unreinforced synapses relax
# back toward that innate weight. Without this, every weight ratchets to the cap
# over a long session and the personalities (Wary vs Trusting…) wash out into one.
const GROW_CEIL := 1.8          # most a bond can grow past its innate strength
const RELAX_RATE := 0.05        # per-call drift back toward innate weight
func learn(reward: float, rate: float = 1.0) -> void:
	for s in synapses:
		var src_n: Neuron = neurons[s.src]
		var dst_n: Neuron = neurons[s.dst]
		var ceil_w: float = s.base_weight * GROW_CEIL
		if src_n.fired and dst_n.fired:
			s.weight = minf(ceil_w, s.weight + reward * rate)
		else:
			# unused bonds slowly forget back toward their innate strength
			s.weight = move_toward(s.weight, s.base_weight, RELAX_RATE * rate)
		s.weight = clamp(s.weight, 0.0, 255.0)

# ── STDP: real spike-timing-dependent plasticity ──────────────────────────
# Classic exponential STDP window (Bi & Poo 1998 shape), unlike learn()'s
# same-step co-fire rule above: this looks at WHEN src and dst last fired
# relative to each other, not just whether both fired on the current step.
#   pre fires BEFORE post (dt = t_post - t_pre > 0, small)  -> potentiate
#   post fires BEFORE pre (dt = t_post - t_pre < 0, small)  -> depress
#   |dt| beyond STDP_WINDOW steps -> no effect (too far apart to be causal)
# This is the direction Michael's snnTorch/SpikingJelly/Brian2 suggestion
# points toward for biological accuracy -- Brian2 in particular treats this
# timing-dependent rule as a first-class primitive, whereas the co-fire
# learn() above is a simplification snnTorch/SpikingJelly-style frameworks
# also make for training speed. Kept SEPARATE from learn() (not a replace)
# so tribe can compare both side by side rather than assume one is better.
const STDP_WINDOW := 6          # ticks; spikes further apart than this don't interact
const STDP_A_PLUS := 0.35       # potentiation strength (pre before post)
const STDP_A_MINUS := 0.28      # depression strength (post before pre) -- classically
								  # smaller-magnitude-but-present asymmetry between the two
const STDP_TAU := 3.0           # decay time-constant (ticks) of the exponential window
func stdp_learn(rate: float = 1.0) -> void:
	for s in synapses:
		var src_n: Neuron = neurons[s.src]
		var dst_n: Neuron = neurons[s.dst]
		var ceil_w: float = s.base_weight * GROW_CEIL
		if src_n.last_fire_step < 0 or dst_n.last_fire_step < 0:
			# one or both have never fired -- nothing to time against yet
			s.weight = move_toward(s.weight, s.base_weight, RELAX_RATE * rate)
			s.weight = clamp(s.weight, 0.0, 255.0)
			continue
		var dt: int = dst_n.last_fire_step - src_n.last_fire_step  # >0: pre led post
		if dt == 0 or absi(dt) > STDP_WINDOW:
			# simultaneous (ambiguous causality) or too far apart -- relax, don't guess
			s.weight = move_toward(s.weight, s.base_weight, RELAX_RATE * rate)
		elif dt > 0:
			# src (pre) fired before dst (post) -- causal, potentiate
			var delta: float = STDP_A_PLUS * exp(-float(dt) / STDP_TAU) * rate
			s.weight = minf(ceil_w, s.weight + delta)
		else:
			# dst (post) fired before src (pre) -- anti-causal, depress
			var delta_neg: float = STDP_A_MINUS * exp(-float(-dt) / STDP_TAU) * rate
			s.weight = maxf(s.base_weight * 0.2, s.weight - delta_neg)
		s.weight = clamp(s.weight, 0.0, 255.0)

# ── Introspection helpers for visualization / UI ─────────────────────────────
func get_potential(neuron_name: String) -> float:
	var i := _idx(neuron_name)
	return neurons[i].p if i >= 0 else 0.0

func did_fire(neuron_name: String) -> bool:
	var i := _idx(neuron_name)
	return neurons[i].fired if i >= 0 else false

## How hard this neuron fired ITS OWN last time (0..1, overshoot past
## threshold normalized by threshold) -- valid to read right after step()
## for any neuron that fired this step; stale (but harmless) otherwise.
func fire_strength(neuron_name: String) -> float:
	var i := _idx(neuron_name)
	return neurons[i].last_fire_strength if i >= 0 else 0.0

func neuron_count() -> int:
	return neurons.size()

# ── Introspection for the brain visualizer (live read of the whole network) ───
func neuron_states() -> Array:
	var out: Array = []
	for n in neurons:
		out.append({
			"name": n.name, "p": n.p, "threshold": n.threshold,
			"leak": n.leak, "fired": n.fired, "refr": n.refr_left,
			# RESONATOR (2026-08-28): additive keys, harmless/default-valued
			# for existing LIF neurons -- lets the visualizer show the real
			# continuous waveform (res_x) for resonator neurons instead of
			# a meaningless flat "p", without changing the LIF entries at all.
			"type": n.type, "res_x": n.res_x, "res_amplitude": sqrt(n.energy_ema),
			# IZHIKEVICH/ADEX (2026-08-28): also additive, default-valued
			# (0.0) for every other neuron type -- lets the visualizer show
			# the real recovery/adaptation state instead of nothing.
			"iz_v": n.iz_v, "iz_u": n.iz_u,
			"adex_v": n.adex_v, "adex_w": n.adex_w,
		})
	return out

func synapse_states() -> Array:
	var out: Array = []
	for s in synapses:
		out.append({
			"src": s.src, "dst": s.dst, "weight": s.weight,
			"src_name": neurons[s.src].name, "dst_name": neurons[s.dst].name,
		})
	return out

func export_spk() -> String:
	# serialize current brain (with learned weights) back to .spk
	var out := "# Spikeling Neural Configuration\n"
	for n in neurons:
		if n.type == "resonator":
			# RESONATOR (2026-08-28): threshold here is an RMS-amplitude
			# level, not a membrane potential -- keep it a real float
			# (%d would truncate a sub-1.0 value to 0 and silently break
			# re-loading), unlike the LIF branch below which is correctly
			# integer-valued.
			out += "neuron %s type=resonator threshold=%s freq=%s damping=%s coupling=%s\n" % [
				n.name, str(n.threshold), str(n.freq_hz), str(n.damping), str(n.coupling)]
		elif n.type == "izhikevich":
			out += "neuron %s type=izhikevich threshold=%s a=%s b=%s c=%s d=%s\n" % [
				n.name, str(n.threshold), str(n.iz_a), str(n.iz_b), str(n.iz_c), str(n.iz_d)]
		elif n.type == "adex":
			out += "neuron %s type=adex threshold=%s C=%s gL=%s EL=%s VT=%s delta=%s tau_w=%s a=%s b=%s vreset=%s\n" % [
				n.name, str(n.threshold), str(n.adex_C), str(n.adex_gL), str(n.adex_EL),
				str(n.adex_VT), str(n.adex_deltaT), str(n.adex_tau_w), str(n.adex_a),
				str(n.adex_b), str(n.adex_vreset)]
		else:
			out += "neuron %s threshold=%d leak=%d\n" % [n.name, int(n.threshold), int(n.leak)]
	for s in synapses:
		if s.delay > 1:
			out += "synapse %s -> %s weight=%d delay=%d\n" % [neurons[s.src].name, neurons[s.dst].name, int(s.weight), s.delay]
		else:
			out += "synapse %s -> %s weight=%d\n" % [neurons[s.src].name, neurons[s.dst].name, int(s.weight)]
	out += "refractory=%d\n" % refractory_ticks
	if step_dt != 0.1:
		out += "dt=%s\n" % str(step_dt)
	return out

# ── tiny string helpers ──────────────────────────────────────────────────────
func _grab(s: String, after: String, before: String) -> String:
	var a := s.find(after)
	if a == -1: return ""
	a += after.length()
	var b := s.find(before, a)
	if b == -1: b = s.length()
	return s.substr(a, b - a).strip_edges()

func _kv(s: String, key: String, default_val: String) -> String:
	var k := key + "="
	# REAL BUG FOUND AND FIXED HERE (2026-08-28, while porting Izhikevich/AdEx):
	# a naive `s.find(k)` matches "key=" ANYWHERE in the line, including
	# mid-word inside an unrelated key -- e.g. searching for "d=" (Izhikevich's
	# `d` parameter) matches inside "threshol`d=`30" and returns 30 instead of
	# the real d= value later in the line; searching for "a=" (AdEx's `a`
	# parameter) matches inside "delt`a=`2" the same way. Every key used before
	# this change (threshold, leak, type, weight, delay, freq, damping,
	# coupling, gate_threshold, energy_time_constant) happened to never be a
	# suffix of another key, so this was a real latent bug that only a short,
	# collision-prone key name (single letters) actually triggered -- caught
	# by test_izhikevich_neuron.gd genuinely failing before this fix, not by
	# code review alone. Fix: only accept a match at a real key boundary
	# (start of the line, or immediately preceded by whitespace) -- every
	# existing valid `.spk` line already writes space-delimited key=value
	# pairs, so this is a pure bugfix, not a behavior change, for every key
	# that worked correctly before.
	var search_from := 0
	# Bounded by s.length() (a strictly increasing search_from guarantees
	# termination well before that many iterations) instead of `while true`
	# -- GDScript's static analyzer can't prove an unbounded loop always
	# returns, which fails compilation ("Not all code paths return a value")
	# even though this loop provably does.
	for _iter in range(s.length() + 1):
		var a := s.find(k, search_from)
		if a == -1:
			return default_val
		if a == 0 or s[a - 1] == " ":
			a += k.length()
			var b := a
			while b < s.length() and s[b] != " ":
				b += 1
			return s.substr(a, b - a)
		search_from = a + 1
	return default_val
