extends RefCounted
class_name DirectVoice
# ─────────────────────────────────────────────────────────────────────────────
# DirectVoice -- a genuinely LLM-free "spikes-to-text" voice path.
#
# WHY THIS EXISTS (2026-08-26): a public LinkedIn comment on this project
# correctly pointed out that calling Ollama the NPC's SNN "voice" is a
# category error -- an LLM is not a spiking architecture, and a real "voice"
# for a spiking network would be a deterministic decoder from spike/neuron
# state to text, not a separate general model improvising from a prose
# summary of that state (see tribe_llm.gd's say_as(), which is exactly that,
# and stays exactly as it was -- this file does NOT replace it, it sits
# alongside it as a second, switchable mode).
#
# This function takes the SAME raw neuron-state numbers brain_snapshot() and
# core_memory_blame_line() already read (tribemember.gd:2468 / :848) --
# Trust neuron potential, betrayed_count, and NPCCoreMemory.recall()
# confidence -- and produces a line by BANDING those numbers into a small,
# fixed, personality-keyed phrase table. No network call, no generation, no
# randomness: the exact same inputs always produce the exact same line. That
# determinism is the honest point of this mode, not a limitation to hide --
# it is legibly template-driven, on purpose, so "the SNN's own voice" is
# literally true here: the words are a pure function of the neurons.
#
# SCOPE, STATED PLAINLY: this is NOT trying to sound as varied or as fluent
# as the Ollama path. Five personalities x five trust bands x an optional
# memory clause is intentionally small. It will repeat itself. That is the
# honest cost of removing the LLM from this path, and it is disclosed here
# rather than papered over.
# ─────────────────────────────────────────────────────────────────────────────

# Same 0.08 confidence threshold core_memory_blame_line() uses (tribemember.gd:864)
# -- deliberately reused, not re-derived, so both voice paths treat "does a
# core memory still land" identically.
const RECALL_VIVID_THRESHOLD := 0.08

# Trust potential bands. The Trust neuron's threshold is 100 (see
# tribemember.gd's _brain_text()), so live potential normally reads in
# roughly [0, 100), with a real, documented exception: a same-tick betrayal
# slam (-160 synapse) CAN transiently read negative for exactly one tick
# before the leak-clamp floors it back to 0 (see tribemember.gd's betray()
# comment) -- so "hostile" below is a real, reachable band, not dead code.
const BAND_WARY_MAX := 20.0
const BAND_NEUTRAL_MAX := 55.0
const BAND_WARMING_MAX := 85.0

## Deterministic mapping from a raw Trust potential to one of 5 named bands.
static func trust_band(trust: float) -> String:
	if trust < 0.0:
		return "hostile"
	if trust < BAND_WARY_MAX:
		return "wary"
	if trust < BAND_NEUTRAL_MAX:
		return "neutral"
	if trust < BAND_WARMING_MAX:
		return "warming"
	return "trusting"

# One fixed line per personality per band. Deliberately small and plainly a
# lookup table -- the point of this mode is that it's legible, not that it's
# expressive. Each personality's tone follows directly from its real
# PERSONALITIES entry in tribemember.gd (contrib/trust_leak/courage), so the
# banding is consistent with what that brain actually IS, not just a label.
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
const DEFAULT_PERSONALITY := "Steady"   # mirrors tribemember.gd PERSONALITIES fallback

## Fixed, shared clause appended when the Leader has struck this NPC at
## least once -- same betrayed_count brain_snapshot() reports (tribemember.gd:2476).
static func _betrayed_clause(betrayed_count: int) -> String:
	if betrayed_count <= 0:
		return ""
	var s := "" if betrayed_count == 1 else "s"
	return " You've struck me %d time%s. I haven't forgotten." % [betrayed_count, s]

## Fixed, shared clause for a core memory, gated on the SAME 0.08 confidence
## threshold core_memory_blame_line() uses -- vivid above it, hazy below,
## silent if there's no core memory (described_memory == "") at all.
static func _memory_clause(recall_confidence: float, described_memory: String) -> String:
	if described_memory == "" or recall_confidence <= 0.0:
		return ""
	if recall_confidence >= RECALL_VIVID_THRESHOLD:
		return " I still see %s clearly." % described_memory
	return " Something bad happened between us once. It's gone hazy now."

## The actual deterministic "spikes-to-text" decode. Pure function of its
## inputs -- same numbers in, same line out, every time, no LLM anywhere in
## this call.
##   personality           -- tribemember.gd's `personality` (Steady/Trusting/Wary/Brave/Greedy)
##   trust                 -- brain.get_potential("Trust"), the SAME read brain_snapshot() takes
##   betrayed_count        -- tribemember.gd's `betrayed_count`
##   recall_confidence     -- NPCCoreMemory.recall(tag) for this NPC's best core tag (0 if none)
##   described_memory      -- _describe_core_tag(tag) for that same tag, or "" if none
static func compose_line(personality: String, trust: float, betrayed_count: int,
		recall_confidence: float, described_memory: String) -> String:
	var bank: Dictionary = PHRASE_BANK.get(personality, PHRASE_BANK[DEFAULT_PERSONALITY])
	var band := trust_band(trust)
	var base: String = str(bank.get(band, bank["neutral"]))
	return base + _betrayed_clause(betrayed_count) + _memory_clause(recall_confidence, described_memory)
