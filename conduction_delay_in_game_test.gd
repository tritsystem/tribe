# conduction_delay_in_game_test.gd — headless test via --script
# Pre-registered by vault Research/2026-08-28_conduction-delay-and-stdp-hypothesis-test.md:
#   "wire real, non-1 delay values into any actual TRIBE brain … and re-measuring
#    the in-game effect at production weights, the way the original STDP test did."
#
# Design: one Steady-personality brain (contrib=80, trust_leak=2, follow_w=120,
#         threshold=100 — the STDP finding's baseline), but SawDefend→Trust gets a
#         real conduction delay=2 (defending someone has natural latency: you see the
#         attack, react, they register it later). SawContribute→Trust stays instant
#         (delay=1) — a gift is immediate.
#
# Then feed a realistic event sequence and print where Trust/Follow actually land
# under STDP-on vs Hebbian — same shape as the isolated relay test, but inside the
# real brain at production weights.
#
# Use: Godot_v4.7..._console.exe --headless conduction_delay_test.tscn --quit-after 120
extends Node
class_name ConductionDelayInGameTest


# ── steady personality brain text, SawDefend delay=2 ──────────────────────────
static func steady_brain_text() -> String:
	var t := "## Steady personality (Steady) — baseline from the 2026-08-28 STDP finding\n"
	t += "neuron SawContribute threshold=50 leak=20\n"
	t += "neuron SawHelpClear  threshold=50 leak=20\n"
	t += "neuron SawDefend     threshold=50 leak=20\n"
	t += "neuron SawBetray     threshold=50 leak=20\n"
	t += "neuron Trust  threshold=100 leak=2\n"
	t += "neuron Follow threshold=100 leak=5\n"
	t += "synapse SawContribute -> Trust weight=80\n"        # instant (delay=1 default)
	t += "synapse SawHelpClear  -> Trust weight=70\n"
	t += "synapse SawDefend     -> Trust weight=95 delay=2\n"  # <-- REAL DELAY (the test variable)
	t += "synapse SawBetray     -> Trust weight=-160\n"
	t += "synapse Trust -> Follow weight=120\n"
	t += "refractory=4\n"
	return t


# ── run one simulated session ─────────────────────────────────────────────────
# feed_sequence: list of dictionaries {label, neuron, amount, tick} — stimulus
# injected at the given tick (1-indexed). learn_mode: "stdp" or "hebbian".
static func run_session(feed_sequence: Array, learn_mode: String) -> Dictionary:
	var brain := Spikeling.new()
	assert(brain.load_from_text(steady_brain_text()), "failed to load brain")

	var trust_history: Array = []
	var follow_history: Array = []
	var synapse_history: Array = []
	var event_log: Array = []

	for ev: Dictionary in feed_sequence:
		var label: String = ev["label"]
		var neuron: String = ev["neuron"]
		var amount: float = float(ev["amount"])
		var tick: int = int(ev["tick"])
		# advance to the target tick, injecting the stimulus on that exact step
		while brain.step_count < tick:
			_learn(brain, learn_mode)
			var fired := brain.step()
			_record(brain, trust_history, follow_history, synapse_history, fired)
		# now on the target tick — inject
		brain.stimulate(neuron, amount)
		_learn(brain, learn_mode)
		var fired := brain.step()
		event_log.append({"tick": tick, "label": label, "fired": fired})
		_record(brain, trust_history, follow_history, synapse_history, fired)
	# run a tail of empty ticks so delayed SawDefend→Trust spikes can arrive and
	# Trust/Follow can settle — 12 empty ticks covers delay=2 + refractory + leak
	for extra in range(12):
		_learn(brain, learn_mode)
		var fired := brain.step()
		event_log.append({"tick": brain.step_count, "label": "idle", "fired": fired})
		_record(brain, trust_history, follow_history, synapse_history, fired)

	var saw_defend_w := 0.0
	var saw_contrib_w := 0.0
	for s in brain.synapse_states():
		if s["src_name"] == "SawDefend" and s["dst_name"] == "Trust":
			saw_defend_w = s["weight"]
		if s["src_name"] == "SawContribute" and s["dst_name"] == "Trust":
			saw_contrib_w = s["weight"]

	return {
		"trust_history": trust_history,
		"follow_history": follow_history,
		"synapse_history": synapse_history,
		"event_log": event_log,
		"final_trust": brain.get_potential("Trust"),
		"final_follow": brain.get_potential("Follow"),
		"trust_fire_count": _fire_count(brain, "Trust"),
		"follow_fire_count": _fire_count(brain, "Follow"),
		"saw_defend_weight": saw_defend_w,
		"saw_contrib_weight": saw_contrib_w,
	}


static func _learn(brain: Spikeling, mode: String) -> void:
	if mode == "stdp":
		brain.stdp_learn(0.5)
	else:
		brain.learn(1.0, 0.5)


static func _record(brain: Spikeling, trust_hist: Array, follow_hist: Array, syn_hist: Array, fired: Array) -> void:
	trust_hist.append(brain.get_potential("Trust"))
	follow_hist.append(brain.get_potential("Follow"))
	var snap := {
		"tick": brain.step_count,
		"trust": brain.get_potential("Trust"),
		"follow": brain.get_potential("Follow"),
		"fired": fired,
		"saw_defend_w": _syn_weight(brain, "SawDefend", "Trust"),
		"saw_contrib_w": _syn_weight(brain, "SawContribute", "Trust"),
	}
	syn_hist.append(snap)


static func _syn_weight(brain: Spikeling, src: String, dst: String) -> float:
	for s in brain.synapse_states():
		if s["src_name"] == src and s["dst_name"] == dst:
			return s["weight"]
	return 0.0


static func _fire_count(brain: Spikeling, name: String) -> int:
	var i := brain._idx(name)
	if i >= 0:
		return brain.neurons[i].fire_count
	return 0


# ── print a compact comparison: STDP-on vs Hebbian, same event sequence ──────
static func run_comparison() -> void:
	print("=== Conduction-delay in-game test ===")
	print("Steady brain: SawDefend→Trust delay=2 (SawContribute stays instant)")
	print("")

	# Realistic event sequence:
	#  tick 1: player contributes food/gift  → SawContribute +80  (instant path)
	#  tick 3: player defends an NPC from a raider → SawDefend +80 (delayed path)
	#  then 12 idle ticks so the delayed SawDefend spike lands and Trust/Follow settle
	var feed := [
		{"label": "gift",     "neuron": "SawContribute", "amount": 80.0, "tick": 1},
		{"label": "defend",   "neuron": "SawDefend",     "amount": 80.0, "tick": 3},
	]

	var stdp := run_session(feed, "stdp")
	var hebb := run_session(feed, "hebbian")

	# ── Print STDP run ─────────────────────────────────────────────────────────
	print("--- STDP-on (stdp_learn) ---")
	print("tick  event    Trust  Follow  SawDefend→Trust  SawContrib→Trust  fired")
	var prev_tick: int = -1
	for i in range(stdp.event_log.size()):
		var ev: Dictionary = stdp.event_log[i]
		if ev["tick"] != prev_tick:
			print("%4d  %-8s  %5.0f  %5.0f   %5.1f             %5.1f            %s" % [
				ev["tick"], ev["label"],
				stdp.trust_history[i],
				stdp.follow_history[i],
				stdp.synapse_history[i]["saw_defend_w"],
				stdp.synapse_history[i]["saw_contrib_w"],
				ev["fired"].size() > 0 and str(ev["fired"]) or "—"])
			prev_tick = ev["tick"]
	print("")
	print("  Trust fires: %d   Follow fires: %d" % [stdp.trust_fire_count, stdp.follow_fire_count])
	print("  Final Trust potential: %.1f   Final Follow: %.1f" % [stdp.final_trust, stdp.final_follow])
	print("  SawDefend→Trust weight: %.1f  (base 95, ceil %.1f)" % [stdp.saw_defend_weight, 95.0 * 1.8])
	print("  SawContribute→Trust weight: %.1f  (base 80, ceil %.1f)" % [stdp.saw_contrib_weight, 80.0 * 1.8])
	print("")

	# ── Print Hebbian run ──────────────────────────────────────────────────────
	print("--- Hebbian (learn) ---")
	print("tick  event    Trust  Follow  SawDefend→Trust  SawContrib→Trust  fired")
	prev_tick = -1
	for i in range(hebb.event_log.size()):
		var ev: Dictionary = hebb.event_log[i]
		if ev["tick"] != prev_tick:
			print("%4d  %-8s  %5.0f  %5.0f   %5.1f             %5.1f            %s" % [
				ev["tick"], ev["label"],
				hebb.trust_history[i],
				hebb.follow_history[i],
				hebb.synapse_history[i]["saw_defend_w"],
				hebb.synapse_history[i]["saw_contrib_w"],
				ev["fired"].size() > 0 and str(ev["fired"]) or "—"])
			prev_tick = ev["tick"]
	print("")
	print("  Trust fires: %d   Follow fires: %d" % [hebb.trust_fire_count, hebb.follow_fire_count])
	print("  Final Trust potential: %.1f   Final Follow: %.1f" % [hebb.final_trust, hebb.final_follow])
	print("  SawDefend→Trust weight: %.1f  (base 95, ceil %.1f)" % [hebb.saw_defend_weight, 95.0 * 1.8])
	print("  SawContribute→Trust weight: %.1f  (base 80, ceil %.1f)" % [hebb.saw_contrib_weight, 80.0 * 1.8])
	print("")

	# ── Pre-registered predictions (from vault) ───────────────────────────────
	print("=== Pre-registered predictions vs result ===")
	print("")
	print("HYPOTHESIS (vault): conduction delay resurrects a real STDP-vs-Hebbian")
	print("  difference that the same-step-only test could not see. SawDefend fires")
	print("  tick 3, Trust receives it tick 5 (delay=2) — so SawDefend.last_fire_step")
	print("  ≠ Trust.last_fire_step → Hebbian SAME-STEP co-fire rule should NOT catch")
	print("  it (src not fired this step), while STDP SHOULD (dt=2, inside window=6).")
	print("")

	var stdp_defend_grew: bool = stdp.saw_defend_weight > 95.0 + 0.05
	var hebb_defend_grew: bool = hebb.saw_defend_weight > 95.0 + 0.05
	print("PREDICTION 1: STDP potentiates SawDefend→Trust (delayed pre→post causal).")
	print("  STDP SawDefend→Trust: %.1f  →  %s" % [stdp.saw_defend_weight, stdp_defend_grew and "GROWN ✓" or "flat ✗"])
	print("  Hebbian SawDefend→Trust: %.1f  →  %s" % [hebb.saw_defend_weight, hebb_defend_grew and "GROWN (unexpected) ✓" or "flat (expected) ✓"])
	print("")
	var stdp_contrib_grew: bool = stdp.saw_contrib_weight > 80.0 + 0.05
	var hebb_contrib_grew: bool = hebb.saw_contrib_weight > 80.0 + 0.05
	print("PREDICTION 2: STDP potentiates SawContribute→Trust (instant pre→post causal).")
	print("  STDP SawContribute→Trust: %.1f  →  %s" % [stdp.saw_contrib_weight, stdp_contrib_grew and "GROWN ✓" or "flat ✗"])
	print("  Hebbian SawContribute→Trust: %.1f  →  %s" % [hebb.saw_contrib_weight, hebb_contrib_grew and "GROWN ✓" or "flat (expected) ✓"])
	print("")

	# The real question: do the weight differences actually change the outcome?
	var stdp_follow: int = stdp.follow_fire_count
	var hebb_follow: int = hebb.follow_fire_count
	print("OUTCOME: does the STDP weight growth change whether Follow fires?")
	print("  STDP Follow fires: %d   Hebbian Follow fires: %d" % [stdp_follow, hebb_follow])
	if stdp_follow > hebb_follow:
		print("  → YES: STDP produced more Follow fires than Hebbian (delay matters in-game).")
	elif stdp_follow < hebb_follow:
		print("  → YES but reverse: Hebbian produced more Follow fires (unexpected).")
	else:
		print("  → NO: same Follow-fire count despite different weights — the ~4%% weight")
		print("    difference the relay test found is too small to change the outcome here.")
	print("")
	print("Cautionary note (from vault): this is ONE event sequence on ONE personality.")
	print("A different sequence (more defends, different spacing, different personality)")
	print("might give a different answer. This is a measured data point, not a verdict.")
	print("")


# ── top-level: runs from _ready() (the only entry point Godot 4 allows) ──────
func _ready() -> void:
	if not _ran:
		_ran = true
		run_comparison()


var _ran := false
