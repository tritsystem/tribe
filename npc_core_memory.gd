extends RefCounted
class_name NPCCoreMemory
# ─────────────────────────────────────────────────────────────────────────────
# NPCCoreMemory -- the SSH edge-vs-bulk topological-protection result, wired
# into an actual NPC feature, not just a research finding.
#
# CONFIRMED (project_thought/ssh_chiral_experiment.gd, 5/5 seeds, 2026-07-19):
# on a real Spikeling LIF chain built with SSH-style alternating synapse
# weights, EDGE-group neurons retain ~70% of their memory capacity under
# synaptic disorder while BULK-group neurons retain only ~22%. Same chain,
# same disorder, different position -- edges are just more robust.
#
# Feature: each NPC gets one small SSH chain as a "core memory" register.
# CORE memories (witnessed betrayal, a tribemate's death caused by the
# player) are written to the chain's EDGE neurons. Routine memories (a
# declined trade, a minor slight) go to the BULK neurons. When the NPC is
# under real threat (see tribemember.gd's _nearest_base_threat()), call
# apply_stress() -- this jitters the chain's synapse weights exactly like
# the "hopping disorder" in the experiment, i.e. real panic degrading recall.
#
# Payoff: a panicked NPC mid-raid still reliably recalls "the leader let
# my friend die" (edge-anchored) MUCH more often than petty grudges
# (bulk-anchored) survive the same panic -- the topology finding becomes
# the reason NPCs hold grudges that matter and forget the ones that don't,
# instead of an arbitrary flag.
#
# Mechanism note (measured, not assumed): recall confidence is the WEAKEST
# synapse margin along the path from the chain's nearest boundary to the
# memory's slot. Disorder jitter is multiplicative and roughly symmetric,
# so it does NOT reliably lower the AVERAGE margin on any one hop -- what
# actually degrades under panic is RELIABILITY (chance every hop on the
# path survives at once). Edge slots need 1-2 hops; bulk slots need ~5-6 --
# more links that all have to hold, same "AND across hops" mechanism the
# original SSH memory-capacity experiment measured at the network level.
# ─────────────────────────────────────────────────────────────────────────────

const SpikelingScript = preload("res://spikeling.gd")

const N := 12
const V_WEIGHT := 110.0   # intra-cell hopping -- values proven to reliably
const W_WEIGHT := 180.0   # cross threshold in the SSH chiral experiment
## Deliberately NOT [0, N-1] themselves -- recall() injects its cue at the
## nearest boundary (0 or N-1) and lets it propagate through the chain, so
## anchoring a memory AT the boundary would test 0 hops (bypassing the
## chain -- and its disorder -- entirely, an uninterestingly trivial case).
## 1-2 hops is close enough to be a real "edge mode" while still actually
## exercising real, disorder-exposed synapses.
const EDGE_SLOTS: Array = [1, 2, N - 3, N - 2]
const BULK_SLOTS: Array = [N / 2 - 1, N / 2]
const WRITE_STIMULUS := 150.0

var brain: Spikeling
var _tag_to_slot: Dictionary = {}   # String tag -> neuron index
var _tag_is_core: Dictionary = {}   # String tag -> bool (true = core/edge, false = routine/bulk)
var _next_edge: int = 0
var _next_bulk: int = 0
var rng := RandomNumberGenerator.new()

## The tags actually worth bringing up in dialogue -- the core (edge-anchored)
## ones. Callers combine this with recall() to decide whether a grudge is
## still felt strongly enough to voice right now.
func core_tags() -> Array:
	var out: Array = []
	for t in _tag_to_slot.keys():
		if _tag_is_core.get(t, false):
			out.append(t)
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

## Write a memory. is_core=true anchors it at an EDGE slot (survives panic);
## false anchors it at a BULK slot (washes out under the same panic).
func remember(tag: String, is_core: bool) -> void:
	if _tag_to_slot.has(tag):
		return
	var slot: int
	if is_core:
		slot = EDGE_SLOTS[_next_edge % EDGE_SLOTS.size()]
		_next_edge += 1
	else:
		slot = BULK_SLOTS[_next_bulk % BULK_SLOTS.size()]
		_next_bulk += 1
	_tag_to_slot[tag] = slot
	_tag_is_core[tag] = is_core
	# a narrative "encoding" pulse -- recall does NOT depend on this; it
	# depends on the chain's own weights (see recall() below), same as a
	# real SSH edge mode being a property of the chain, not the one neuron.
	brain.stimulate_idx(slot, WRITE_STIMULUS)
	brain.step()

## Real panic: jitters the chain's synapse weights, same mechanism (and same
## magnitude knob) as the confirmed "hopping disorder" in the SSH experiment.
## intensity 0..1 (0 = calm, 1 = full raid-level panic).
func apply_stress(intensity: float) -> void:
	var jitter: float = clampf(intensity, 0.0, 1.0) * 0.35
	if jitter <= 0.0:
		return
	for s in brain.synapses:
		s.weight *= 1.0 + jitter * (rng.randf() * 2.0 - 1.0)
		s.weight = clampf(s.weight, 0.0, 255.0)

## A neuron fires if incoming weight clears (threshold - leak headroom); this
## is the margin above that a single hop's weight currently has, 0..1 --
## 0 = that hop could no longer reliably fire the next neuron on its own,
## 1 = comfortably clear. Deterministic function of the CURRENT (possibly
## disorder-jittered) synapse weight, not a one-off stochastic firing roll.
const FIRE_MARGIN_SPAN := 80.0   # W_WEIGHT(180) - threshold(100): the full healthy range
func _hop_margin(a: int, b: int) -> float:
	for s in brain.synapses:
		if s.src == a and s.dst == b:
			return clampf((s.weight - 100.0) / FIRE_MARGIN_SPAN, 0.0, 1.0)
	return 0.0

## Recall as an actual property of the CHAIN, not of the one slot neuron:
## the cue would have to propagate hop-by-hop from the chain's nearest
## boundary (n0 or n[N-1]) through the (possibly disorder-jittered) synapse
## chain to reach the slot. Confidence = the WEAKEST hop's margin along that
## path (a chain is only as strong as its weakest link). Edge slots are 1-2
## hops from a boundary; bulk slots are ~5-6 -- exactly mirroring how a real
## SSH edge mode is localized near the boundary and largely insulated from
## bulk disorder, while a bulk state has to survive disorder across many
## more hops (more chances for one weak link to break the chain).
func recall(tag: String) -> float:
	if not _tag_to_slot.has(tag):
		return 0.0
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
