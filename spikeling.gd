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

class Synapse:
	var src: int                # source neuron index
	var dst: int                # target neuron index
	var weight: float
	var base_weight: float      # innate weight at load — learning relaxes back toward this

var neurons: Array = []                  # Array[Neuron]
var synapses: Array = []                 # Array[Synapse]
var _name_to_idx: Dictionary = {}        # String -> int
var refractory_ticks: int = 4
var step_count: int = 0

# spikes scheduled to arrive next step: idx -> accumulated weight
var _pending: Dictionary = {}

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
			_name_to_idx[n.name] = neurons.size()
			neurons.append(n)
		elif line.begins_with("refractory="):
			refractory_ticks = int(line.replace("refractory=", "").replace("ms", "").strip_edges())

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
			var si := _idx(src_name)
			var di := _idx(dst_name)
			if si == -1 or di == -1:
				push_warning("Spikeling: synapse references unknown neuron: " + line)
				continue
			var s := Synapse.new()
			s.src = si; s.dst = di; s.weight = w
			s.base_weight = w
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
	var next_pending: Dictionary = {}

	for i in range(neurons.size()):
		var n: Neuron = neurons[i]
		n.fired = false

		if n.refr_left > 0:
			n.refr_left -= 1
			continue

		# leaky integration
		n.p -= n.leak
		if n.p < 0.0:
			n.p = 0.0
		# incoming stimulus (external + synaptic) scheduled for this step
		n.p += _pending.get(i, 0.0)

		# threshold check
		if n.p >= n.threshold:
			n.p = 0.0
			n.refr_left = refractory_ticks
			n.fired = true
			n.fire_count += 1
			fired_now.append(n.name)
			# propagate to targets next step
			for s in synapses:
				if s.src == i:
					next_pending[s.dst] = next_pending.get(s.dst, 0.0) + s.weight

	_pending = next_pending
	return fired_now

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

# ── Introspection helpers for visualization / UI ─────────────────────────────
func get_potential(neuron_name: String) -> float:
	var i := _idx(neuron_name)
	return neurons[i].p if i >= 0 else 0.0

func did_fire(neuron_name: String) -> bool:
	var i := _idx(neuron_name)
	return neurons[i].fired if i >= 0 else false

func neuron_count() -> int:
	return neurons.size()

# ── Introspection for the brain visualizer (live read of the whole network) ───
func neuron_states() -> Array:
	var out: Array = []
	for n in neurons:
		out.append({
			"name": n.name, "p": n.p, "threshold": n.threshold,
			"leak": n.leak, "fired": n.fired, "refr": n.refr_left,
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
		out += "neuron %s threshold=%d leak=%d\n" % [n.name, int(n.threshold), int(n.leak)]
	for s in synapses:
		out += "synapse %s -> %s weight=%d\n" % [neurons[s.src].name, neurons[s.dst].name, int(s.weight)]
	out += "refractory=%d\n" % refractory_ticks
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
	var a := s.find(k)
	if a == -1: return default_val
	a += k.length()
	var b := a
	while b < s.length() and s[b] != " ":
		b += 1
	return s.substr(a, b - a)
