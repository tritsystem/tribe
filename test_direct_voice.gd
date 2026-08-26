extends Node
# Headless verification for direct_voice.gd -- the new, deterministic,
# LLM-free "spikes-to-text" voice path (see direct_voice.gd's header for why
# it exists). Mirrors the SAME scenario portfolio_demo/snn_to_llm_demo.py
# already runs for the Ollama path (Steady personality, a positive
# interaction, then a betrayal landing, then the SSH core-memory write) --
# same events, same real tribemember.gd code, just read through
# DirectVoice.compose_line() instead of handed to Ollama.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path . res://test_direct_voice.tscn --quit

const DirectVoiceScript = preload("res://direct_voice.gd")

var _pass := 0
var _fail := 0

func _spawn_member(personality: String) -> Node3D:
	var m := CharacterBody3D.new()
	m.set_script(load("res://tribemember.gd"))
	# personality MUST be set BEFORE add_child() -- tribemember.gd's _ready()
	# builds the actual Spikeling brain from _brain_text(), which reads
	# `personality` at that exact moment (tribemember.gd:979-985). Setting it
	# after add_child() would leave the brain built from the export default
	# ("Steady") regardless of what personality is set to afterward.
	m.personality = personality
	add_child(m)
	m.member_name = "TestSubject"
	return m

func _check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  ok    %s" % label)
	else:
		_fail += 1
		print("  FAIL  %s" % label)

func _ready() -> void:
	print("=".repeat(78))
	print("DIRECT VOICE -- deterministic spikes-to-text decoder, no LLM in this path")
	print("=".repeat(78))

	# ── SCENARIO: 'Mok' (Steady), same beats as snn_to_llm_demo.py ─────────
	var mok := _spawn_member("Steady")

	mok.brain.stimulate("SawContribute", 60.0)
	mok.brain.step()   # SawContribute fires now
	mok.brain.step()   # +80 to Trust lands this tick
	var trust_after_gift: float = mok.brain.get_potential("Trust")
	var line_after_gift: String = DirectVoiceScript.compose_line(
		mok.personality, trust_after_gift, mok.betrayed_count, 0.0, "")
	print("\n[tick] Leader gave a gift.  Trust=%.1f  band=%s" % [trust_after_gift, DirectVoiceScript.trust_band(trust_after_gift)])
	print("  Mok (direct): \"%s\"" % line_after_gift)
	_check("calm/positive state produces a 'warming' or 'trusting' band, not wary/hostile",
		DirectVoiceScript.trust_band(trust_after_gift) in ["warming", "trusting"])
	_check("no betrayal yet -> no 'struck' clause in the line",
		line_after_gift.find("struck") == -1)

	mok.betray()          # real hook: SawBetray stimulate + betrayed_count += 1
	mok.brain.step()      # SawBetray fires now
	mok.brain.step()      # -160 to Trust lands this tick (can read transiently negative)
	var trust_at_betrayal: float = mok.brain.get_potential("Trust")
	mok.brain.step()      # settle: leak-clamp floors it back toward 0
	var trust_settled: float = mok.brain.get_potential("Trust")
	print("\n[tick] BETRAYAL LANDS.  Trust=%.1f (transient)  settled=%.1f" % [trust_at_betrayal, trust_settled])

	# core-memory write, same tag shape witness_tribemate_death() uses
	mok.witness_tribemate_death("Rin", true)
	var recall: Dictionary = mok.core_memory_best_recall()
	var line_after_betrayal: String = DirectVoiceScript.compose_line(
		mok.personality, trust_settled, mok.betrayed_count,
		float(recall["confidence"]), str(recall["described"]))
	print("\n[real core_memory_best_recall()] confidence=%.3f  described=%s" % [recall["confidence"], recall["described"]])
	print("  Mok (direct): \"%s\"" % line_after_betrayal)
	_check("post-betrayal state produces a wary/hostile/neutral band (never 'trusting')",
		DirectVoiceScript.trust_band(trust_settled) != "trusting")
	_check("betrayed_count > 0 now attaches the 'struck' clause",
		line_after_betrayal.find("struck") != -1)
	_check("calm NPC (no stress applied) clears the 0.08 recall threshold",
		float(recall["confidence"]) >= 0.08)
	_check("a vivid (>=0.08) core memory attaches a real memory-reference clause",
		line_after_betrayal.find("see") != -1 and line_after_betrayal.find("clearly") != -1)

	# ── memory clause gating: below-threshold and no-memory-at-all cases ──
	var line_hazy: String = DirectVoiceScript.compose_line("Steady", 30.0, 1, 0.03, "you killing Rin with your own hands")
	_check("recall confidence below 0.08 -> hazy clause, NOT the vivid 'clearly' clause",
		line_hazy.find("hazy") != -1 and line_hazy.find("clearly") == -1)
	var line_none: String = DirectVoiceScript.compose_line("Steady", 30.0, 0, 0.0, "")
	_check("no core memory at all -> no memory clause of either kind",
		line_none.find("hazy") == -1 and line_none.find("clearly") == -1 and line_none.find("struck") == -1)

	mok.free()

	# ── PERSONALITY CHECK: identical stimulation, different real brains ────
	# "personality is a different brain, not a different script" -- the same
	# claim the LinkedIn article already makes about the Ollama path. Prove
	# it holds for direct_voice.gd too: drive Steady/Trusting/Wary through
	# the EXACT same stimulus sequence and confirm their real Trust
	# potentials (and therefore template bands) genuinely diverge, driven by
	# each personality's own trust_leak/contrib synapse weights
	# (tribemember.gd's PERSONALITIES dict), not by anything in this file.
	print("\n" + "=".repeat(78))
	print("PERSONALITY CHECK: identical stimulus, three real (different) brains")
	print("=".repeat(78))
	var trust_by_personality: Dictionary = {}
	var band_by_personality: Dictionary = {}
	for pname in ["Steady", "Trusting", "Wary"]:
		var m := _spawn_member(pname)
		# one modest gift, then let it leak for a few idle ticks -- exactly
		# the kind of divergence trust_leak (2 / 1 / 4) is supposed to cause.
		m.brain.stimulate("SawContribute", 60.0)
		m.brain.step()
		m.brain.step()
		for i in range(6):
			m.brain.step()   # idle leak ticks, no further stimulus
		var t: float = m.brain.get_potential("Trust")
		trust_by_personality[pname] = t
		band_by_personality[pname] = DirectVoiceScript.trust_band(t)
		var line := DirectVoiceScript.compose_line(pname, t, 0, 0.0, "")
		print("  %-9s Trust=%.1f  band=%s  line=\"%s\"" % [pname, t, band_by_personality[pname], line])
		m.free()

	_check("Trusting leaks trust slower than Steady after identical stimulus+idle (real trust_leak=1 vs 2)",
		float(trust_by_personality["Trusting"]) > float(trust_by_personality["Steady"]))
	_check("Wary leaks trust faster than Steady after identical stimulus+idle (real trust_leak=4 vs 2)",
		float(trust_by_personality["Wary"]) < float(trust_by_personality["Steady"]))
	_check("Trusting and Wary produce genuinely different compose_line() output for identical events",
		DirectVoiceScript.compose_line("Trusting", float(trust_by_personality["Trusting"]), 0, 0.0, "")
			!= DirectVoiceScript.compose_line("Wary", float(trust_by_personality["Wary"]), 0, 0.0, ""))
	_check("...and it's not just cosmetic -- at least one of the two differs in TRUST BAND, not only wording",
		band_by_personality["Trusting"] != band_by_personality["Wary"])

	print("\n" + "-".repeat(42))
	print("  %d passed, %d FAILED" % [_pass, _fail])
	print("-".repeat(42) + "\n")
	get_tree().quit(1 if _fail > 0 else 0)
