# Tribe — SNN architecture, side by side

The real spiking-neural-network code behind Tribe's NPCs, in one place:
the LIF engine, the topological (SSH) memory system, the brain wiring on
each NPC, and both dialogue voices — the LLM-based one and the new
deterministic, LLM-free one — shown together so the boundary between them
is visible in the code itself, not just described.

---

## 1. `spikeling.gd` — the core LIF spiking-neuron runtime

The actual spiking engine: leaky-integrate-and-fire neurons, synaptic
propagation, refractory periods, Hebbian-ish learning. This is what
"brain" means everywhere else in this codebase.

```gdscript
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
	var last_fire_strength: float = 0.0

class Synapse:
	var src: int                # source neuron index
	var dst: int                # target neuron index
	var weight: float
	var base_weight: float      # innate weight at load — learning relaxes back toward this

var neurons: Array = []
var synapses: Array = []
var _name_to_idx: Dictionary = {}
var refractory_ticks: int = 4
var step_count: int = 0
var _pending: Dictionary = {}

func _idx(n: String) -> int:
	return _name_to_idx.get(n, -1)

func load_from_text(text: String) -> bool:
	neurons.clear(); synapses.clear(); _name_to_idx.clear(); _pending.clear()
	step_count = 0
	var lines := text.split("\n")
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
	for raw in lines:
		var line := (raw as String).strip_edges()
		if line.begins_with("synapse "):
			var body := line.substr("synapse ".length())
			var arrow := body.split("->")
			if arrow.size() != 2: continue
			var src_name := (arrow[0] as String).strip_edges()
			var rest := (arrow[1] as String).strip_edges()
			var dst_name := rest.split(" ")[0].strip_edges()
			var w := float(_kv(line, "weight", "50"))
			var si := _idx(src_name); var di := _idx(dst_name)
			if si == -1 or di == -1:
				push_warning("Spikeling: synapse references unknown neuron: " + line)
				continue
			var s := Synapse.new()
			s.src = si; s.dst = di; s.weight = w; s.base_weight = w
			synapses.append(s)
	return neurons.size() > 0

func stimulate(neuron_name: String, amount: float) -> void:
	var i := _idx(neuron_name)
	if i >= 0: _pending[i] = _pending.get(i, 0.0) + amount

func stimulate_idx(i: int, amount: float) -> void:
	if i >= 0 and i < neurons.size(): _pending[i] = _pending.get(i, 0.0) + amount

# ── Advance the whole network one tick ───────────────────────────────────────
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
		n.p -= n.leak
		if n.p < 0.0: n.p = 0.0
		n.p += _pending.get(i, 0.0)
		if n.p >= n.threshold:
			n.last_fire_strength = clampf((n.p - n.threshold) / maxf(1.0, n.threshold), 0.0, 1.0)
			n.p = 0.0
			n.refr_left = refractory_ticks
			n.fired = true
			n.fire_count += 1
			fired_now.append(n.name)
			for s in synapses:
				if s.src == i:
					next_pending[s.dst] = next_pending.get(s.dst, 0.0) + s.weight
	_pending = next_pending
	return fired_now

# ── Hebbian-ish learning, bounded + homeostatic ───────────────────────────────
const GROW_CEIL := 1.8
const RELAX_RATE := 0.05
func learn(reward: float, rate: float = 1.0) -> void:
	for s in synapses:
		var src_n: Neuron = neurons[s.src]; var dst_n: Neuron = neurons[s.dst]
		var ceil_w: float = s.base_weight * GROW_CEIL
		if src_n.fired and dst_n.fired:
			s.weight = minf(ceil_w, s.weight + reward * rate)
		else:
			s.weight = move_toward(s.weight, s.base_weight, RELAX_RATE * rate)
		s.weight = clamp(s.weight, 0.0, 255.0)

func get_potential(neuron_name: String) -> float:
	var i := _idx(neuron_name)
	return neurons[i].p if i >= 0 else 0.0

func did_fire(neuron_name: String) -> bool:
	var i := _idx(neuron_name)
	return neurons[i].fired if i >= 0 else false
```
*(full file: `spikeling.gd`, 240 lines — introspection/export helpers omitted here for length)*

---

## 2. `npc_core_memory.gd` — the SSH edge-vs-bulk topological memory

A prior physics-style finding (SSH edge modes retaining ~70% of memory
capacity under synaptic disorder vs. ~22% for bulk modes, confirmed 5/5
seeds) wired into an actual gameplay feature: betrayals get anchored at
edge slots and survive panic; petty grudges get anchored at bulk slots
and wash out under the same panic.

```gdscript
extends RefCounted
class_name NPCCoreMemory

const SpikelingScript = preload("res://spikeling.gd")

const N := 12
const V_WEIGHT := 110.0
const W_WEIGHT := 180.0
const EDGE_SLOTS: Array = [1, 2, N - 3, N - 2]
const BULK_SLOTS: Array = [N / 2 - 1, N / 2]
const WRITE_STIMULUS := 150.0

var brain: Spikeling
var _tag_to_slot: Dictionary = {}
var _tag_is_core: Dictionary = {}
var _next_edge: int = 0
var _next_bulk: int = 0
var rng := RandomNumberGenerator.new()

func core_tags() -> Array:
	var out: Array = []
	for t in _tag_to_slot.keys():
		if _tag_is_core.get(t, false): out.append(t)
	return out

func _init() -> void:
	rng.randomize()
	_build_chain()

func _build_chain() -> void:
	var lines: Array[String] = ["# NPC core-memory SSH chain"]
	for i in range(N):
		lines.append("neuron m%d threshold=100 leak=6" % i)
	for i in range(N - 1):
		var w: float = V_WEIGHT if i % 2 == 0 else W_WEIGHT
		lines.append("synapse m%d -> m%d weight=%.1f" % [i, i + 1, w])
		lines.append("synapse m%d -> m%d weight=%.1f" % [i + 1, i, w])
	lines.append("refractory=2")
	brain = SpikelingScript.new()
	brain.load_from_text("\n".join(lines))

## is_core=true anchors it at an EDGE slot (survives panic);
## false anchors it at a BULK slot (washes out under the same panic).
func remember(tag: String, is_core: bool) -> void:
	if _tag_to_slot.has(tag): return
	var slot: int
	if is_core:
		slot = EDGE_SLOTS[_next_edge % EDGE_SLOTS.size()]; _next_edge += 1
	else:
		slot = BULK_SLOTS[_next_bulk % BULK_SLOTS.size()]; _next_bulk += 1
	_tag_to_slot[tag] = slot
	_tag_is_core[tag] = is_core
	brain.stimulate_idx(slot, WRITE_STIMULUS)
	brain.step()

## Real panic: jitters the chain's synapse weights, same mechanism as the
## confirmed "hopping disorder" in the SSH experiment. 0=calm, 1=full panic.
func apply_stress(intensity: float) -> void:
	var jitter: float = clampf(intensity, 0.0, 1.0) * 0.35
	if jitter <= 0.0: return
	for s in brain.synapses:
		s.weight *= 1.0 + jitter * (rng.randf() * 2.0 - 1.0)
		s.weight = clampf(s.weight, 0.0, 255.0)

const FIRE_MARGIN_SPAN := 80.0
func _hop_margin(a: int, b: int) -> float:
	for s in brain.synapses:
		if s.src == a and s.dst == b:
			return clampf((s.weight - 100.0) / FIRE_MARGIN_SPAN, 0.0, 1.0)
	return 0.0

## Confidence = the WEAKEST hop's margin from the chain's nearest boundary
## to the memory's slot -- a chain is only as strong as its weakest link.
## Edge slots are 1-2 hops from a boundary; bulk slots are ~5-6.
func recall(tag: String) -> float:
	if not _tag_to_slot.has(tag): return 0.0
	var slot: int = _tag_to_slot[tag]
	var near_boundary: int = 0 if slot <= (N - 1) / 2 else N - 1
	var step: int = 1 if slot >= near_boundary else -1
	var min_margin: float = 1.0
	var idx: int = near_boundary
	while idx != slot:
		var nxt: int = idx + step
		min_margin = minf(min_margin, _hop_margin(idx, nxt))
		idx = nxt
	return min_margin
```
*(full file: `npc_core_memory.gd`, 150 lines)*

---

## 3. `tribemember.gd` — the brain wiring on each NPC (excerpts)

The full file is ~4,000 lines (movement, tasks, hunger, combat, social
hierarchy — the rest of what an NPC *is*). These are the pieces that are
actually SNN-related: the personality-to-brain mapping, the betrayal
event, and the two accessor paths each voice backend reads from.

```gdscript
# ── Per-personality brain parameters -- five different NPCs are five
# different real neuron/synapse configurations, not five dialogue scripts ──
const PERSONALITIES := {
	"Steady":   {"contrib": 80, "trust_leak": 2, "follow_w": 120, "courage": 0,   "might": 10, "color": Color(0.70, 0.55, 0.40)},
	"Trusting": {"contrib": 95, "trust_leak": 1, "follow_w": 140, "courage": 15,  "might": 8,  "color": Color(0.52, 0.70, 0.45)},
	"Wary":     {"contrib": 60, "trust_leak": 4, "follow_w": 100, "courage": -15, "might": 11, "color": Color(0.45, 0.52, 0.66)},
	"Brave":    {"contrib": 78, "trust_leak": 2, "follow_w": 120, "courage": 40,  "might": 16, "color": Color(0.78, 0.45, 0.40)},
	"Greedy":   {"contrib": 70, "trust_leak": 3, "follow_w": 110, "courage": -5,  "might": 9,  "color": Color(0.78, 0.66, 0.30)},
}

func _brain_text() -> String:
	var p: Dictionary = PERSONALITIES.get(personality, PERSONALITIES["Steady"])
	var t := "# Spikeling Neural Configuration\n"
	t += "neuron SawContribute threshold=50 leak=20\n"
	t += "neuron SawHelpClear  threshold=50 leak=20\n"
	t += "neuron SawDefend     threshold=50 leak=20\n"
	t += "neuron SawBetray     threshold=50 leak=20\n"
	t += "neuron Trust  threshold=100 leak=%d\n" % int(p["trust_leak"])
	t += "neuron Follow threshold=100 leak=5\n"
	t += "synapse SawContribute -> Trust weight=%d\n" % int(p["contrib"])
	t += "synapse SawHelpClear  -> Trust weight=70\n"
	t += "synapse SawDefend     -> Trust weight=95\n"
	t += "synapse SawBetray     -> Trust weight=-160\n"
	t += "synapse Trust -> Follow weight=%d\n" % int(p["follow_w"])
	t += "neuron SawRaider  threshold=50 leak=30\n"
	t += "neuron SawPrey    threshold=50 leak=30\n"
	t += "neuron HeardDanger threshold=50 leak=30\n"
	t += "refractory=2\n"
	return t

# ── the betrayal event: a real -160 synapse slam, not a flag flip ──────────
func betray() -> void:
	brain.stimulate("SawBetray", 80.0)
	betrayed_count += 1
	_attend_idle_time = 0.0
	if trust_label: trust_label.modulate = Color(1.0, 0.2, 0.2)
	if anim: anim.pop(0.25)
	_think("...you did that to me?", 2.2)
	TribeMemory.remember(member_name, "betrayed", "You",
		"You betrayed me. Whatever trust I had is gone.", "betrayed", -0.9)
	print("[%s] betrayed, Trust now %.0f" % [member_name, brain.get_potential("Trust")])

# ── PATH A: the LLM-facing summary -- prose, for say_as()'s prompt ─────────
func brain_snapshot() -> String:
	var trust: float = brain.get_potential("Trust")
	var parts: Array[String] = []
	parts.append("Your trust in the Leader currently sits around %d out of 100." % int(trust))
	if is_backing_you:
		parts.append("You are currently backing them loyally (it took %d real moments of trust to get there)." % follow_fires)
	else:
		parts.append("You are not currently backing them.")
	if betrayed_count > 0:
		parts.append("The Leader has struck you %d time%s. You have not forgotten it." % [
			betrayed_count, "" if betrayed_count == 1 else "s"])
	if sees_raider:
		parts.append("You can see a rival tribesperson nearby right now, and it's putting you on edge.")
	if sees_prey:
		parts.append("There's huntable game in sight nearby.")
	if hears_danger:
		parts.append("You can hear signs of a rival nearby, even though you can't see them.")
	return " ".join(parts)

func core_memory_blame_line() -> String:
	if _core_memory == null: return ""
	var tags: Array = _core_memory.core_tags()
	if tags.is_empty(): return ""
	var best_tag: String = ""; var best_conf: float = -1.0
	for t in tags:
		var c: float = recall_core_memory(str(t))
		if c > best_conf: best_conf = c; best_tag = str(t)
	if best_conf <= 0.0: return ""
	var described: String = _describe_core_tag(best_tag)
	if best_conf >= 0.08:
		return " You vividly remember %s -- it colors how much you trust the Leader right now, and you should let it show." % described
	return " Some part of you remembers something bad involving the Leader, but everything since has worn it hazy -- you're not sure it should still weigh on you."

# ── PATH B: the raw-number accessors -- for direct_voice.gd's decoder,
# which bands these itself instead of reading prose written for an LLM.
# Both voice paths read the exact same brain state through these. ─────────
func get_trust_potential() -> float:
	return brain.get_potential("Trust")

func core_memory_best_recall() -> Dictionary:
	if _core_memory == null: return {"confidence": 0.0, "described": ""}
	var tags: Array = _core_memory.core_tags()
	if tags.is_empty(): return {"confidence": 0.0, "described": ""}
	var best_tag: String = ""; var best_conf: float = -1.0
	for t in tags:
		var c: float = recall_core_memory(str(t))
		if c > best_conf: best_conf = c; best_tag = str(t)
	if best_conf <= 0.0: return {"confidence": 0.0, "described": ""}
	return {"confidence": best_conf, "described": _describe_core_tag(best_tag)}
```

---

## 4. `tribe_llm.gd` — both voices, same file, same signal

`say_as()` (Ollama, prose in → free text out) and `say_as_direct()`
(deterministic, numbers in → banded text out) live side by side, both
emitting the same `line_ready` signal so callers can pick either without
touching anything downstream.

```gdscript
extends Node
# TribeLLM — async local-LLM voice for NPCs, via Ollama. Autoload singleton.

const OLLAMA_URL := "http://127.0.0.1:11434/api/generate"
const MODEL := "llama3.2"
const TIMEOUT := 15.0
const WARMUP_TIMEOUT := 180.0
const MAX_QUEUE := 4
const MAX_TOKENS := 60

signal line_ready(speaker: String, listener: String, text: String, tag: String)

var _http: HTTPRequest
var _busy := false
var _queue: Array = []
var available := true
var warm := false

const DirectVoiceScript = preload("res://direct_voice.gd")

## PATH B: the deterministic, LLM-free backend. Every argument here is a
## real number already read off this NPC's own Spikeling brain -- see
## tribemember.gd's get_trust_potential() / core_memory_best_recall(),
## the exact same reads say_as()'s callers already take.
func say_as_direct(speaker: String, listener: String, personality: String, trust: float,
		betrayed_count: int, recall_confidence: float, described_memory: String,
		tag: String = "chat") -> void:
	var text: String = DirectVoiceScript.compose_line(
		personality, trust, betrayed_count, recall_confidence, described_memory)
	line_ready.emit(speaker, listener, text, tag)

## PATH A: the LLM backend. Returns immediately; listen for line_ready.
func say_as(speaker: String, listener: String, persona: String, memories: String,
		situation: String, fallback: String, tag: String = "chat", roster: String = "") -> void:
	if not available or not warm or _queue_backed_up():
		line_ready.emit(speaker, listener, fallback, tag)
		return
	var who := ""
	if roster != "":
		who = "\nThe only people who exist are: %s. NEVER use a name that is not in that list.\n" % roster
	var prompt := """You are %s, a member of a stone-age tribe. %s
%s%s
What you remember (this is your ACTUAL past -- speak from it, don't invent history):
%s

Situation: %s

Reply as %s in ONE short spoken line (max 20 words). Plain speech, no quotes, no
narration, no asterisks. If a memory above is relevant, let it colour what you say.""" % [
		speaker, persona, who, WORLD, memories, situation, speaker]
	_queue.append({"speaker": speaker, "listener": listener, "prompt": prompt,
		"tag": tag, "fallback": fallback})
```
*(full file: `tribe_llm.gd`, 282 lines — HTTP plumbing, queue hysteresis, and
`compose_as()` for NPC poems omitted here for length)*

---

## 5. `direct_voice.gd` — the deterministic spikes-to-text decoder

A pure function: real neuron numbers in, text out. No network call, no
generation, no randomness — the same inputs always produce the same line.

```gdscript
extends RefCounted
class_name DirectVoice
# A genuinely LLM-free "spikes-to-text" voice path, sitting alongside
# say_as() (Ollama) as a second, switchable mode -- neither replaces
# the other.

const RECALL_VIVID_THRESHOLD := 0.08
const BAND_WARY_MAX := 20.0
const BAND_NEUTRAL_MAX := 55.0
const BAND_WARMING_MAX := 85.0

static func trust_band(trust: float) -> String:
	if trust < 0.0: return "hostile"
	if trust < BAND_WARY_MAX: return "wary"
	if trust < BAND_NEUTRAL_MAX: return "neutral"
	if trust < BAND_WARMING_MAX: return "warming"
	return "trusting"

const PHRASE_BANK := {
	"Steady": {
		"hostile":  "Get away from me. I mean that.",
		"wary":     "I'm keeping my distance from you right now.",
		"neutral":  "I'll work with you. I'm not sure about you yet.",
		"warming":  "You've been fair with me lately. That counts for something.",
		"trusting": "I stand with you, plain and simple.",
	},
	"Trusting": {
		"hostile":  "Even now, some part of me wants to believe this can be fixed.",
		"wary":     "I want to trust you. Right now that's hard.",
		"neutral":  "I still want to believe in you.",
		"warming":  "I believe in you. I really do.",
		"trusting": "I'd follow you anywhere. You've earned that.",
	},
	"Wary": {
		"hostile":  "Stay back. I don't trust a single thing about this.",
		"wary":     "I'm watching you. Closely.",
		"neutral":  "I'm not convinced. Prove it, don't say it.",
		"warming":  "You haven't given me a reason to doubt you. Yet.",
		"trusting": "Fine. You've held up your end. I'll hold up mine.",
	},
	"Brave": {
		"hostile":  "Cross me again and see what happens.",
		"wary":     "I'll fight for this camp. Not for you, right now.",
		"neutral":  "I'll do what needs doing. Don't test me.",
		"warming":  "I'll stand at your side in a fight. That's real, from me.",
		"trusting": "Point me at the danger. I trust you to lead it.",
	},
	"Greedy": {
		"hostile":  "You've cost me. I don't forget who costs me.",
		"wary":     "What's in it for me, exactly, if I stick with you?",
		"neutral":  "Keep the food coming and we won't have a problem.",
		"warming":  "You've kept your word on the stockpile. Noted.",
		"trusting": "You've made this worth my while. I'm in.",
	},
}
const DEFAULT_PERSONALITY := "Steady"

static func _betrayed_clause(betrayed_count: int) -> String:
	if betrayed_count <= 0: return ""
	var s := "" if betrayed_count == 1 else "s"
	return " You've struck me %d time%s. I haven't forgotten." % [betrayed_count, s]

static func _memory_clause(recall_confidence: float, described_memory: String) -> String:
	if described_memory == "" or recall_confidence <= 0.0: return ""
	if recall_confidence >= RECALL_VIVID_THRESHOLD:
		return " I still see %s clearly." % described_memory
	return " Something bad happened between us once. It's gone hazy now."

## The actual deterministic decode. Same numbers in, same line out, every
## time -- no LLM anywhere in this call.
static func compose_line(personality: String, trust: float, betrayed_count: int,
		recall_confidence: float, described_memory: String) -> String:
	var bank: Dictionary = PHRASE_BANK.get(personality, PHRASE_BANK[DEFAULT_PERSONALITY])
	var band := trust_band(trust)
	var base: String = str(bank.get(band, bank["neutral"]))
	return base + _betrayed_clause(betrayed_count) + _memory_clause(recall_confidence, described_memory)
```
*(full file: `direct_voice.gd`, 135 lines)*

---

## Where each piece sits, and what reads what

```
spikeling.gd (LIF engine)
      ├── used by → npc_core_memory.gd (SSH edge/bulk chain, 12 neurons)
      └── used by → tribemember.gd's per-NPC brain (_brain_text(), PERSONALITIES)
                         │
                         ├── brain_snapshot() + core_memory_blame_line()  → PATH A: prose
                         │         → tribe_llm.gd say_as()  → Ollama (llama3.2) → free text
                         │
                         └── get_trust_potential() + core_memory_best_recall()  → PATH B: raw numbers
                                   → tribe_llm.gd say_as_direct()  → direct_voice.gd → banded text
```

Both paths read the same live brain. Nothing about the SNN itself changes
depending on which voice is speaking — only what happens to its numbers
once they leave the brain.
