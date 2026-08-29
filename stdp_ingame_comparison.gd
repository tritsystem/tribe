extends SceneTree

# Headless in-game-realistic comparison: uses the ACTUAL brain wiring from
# tribemember.gd's _brain_text() (Steady personality: contrib=80,
# trust_leak=2, follow_w=120 -- copied verbatim, not simplified), and
# replays the REAL game loop shape: _brain_tick() runs every physics tick
# (step() + learn()), while feeding is a discrete player action that lands
# on whatever tick the player happens to press E -- i.e. NOT synced to the
# brain's step rate. That desync is exactly the real-world condition where
# co-fire Hebbian learning and timing-based STDP diverge.
#
# PRE-REGISTERED PREDICTION: STDP should reach the same trust/loyalty
# milestones (Follow neuron first firing = member starts backing the
# player) in fewer feed actions than the co-fire rule, because it can
# credit SawContribute->Trust even when they don't land on the exact same
# tick (the common case once Trust's own leak/threshold delay is real).

const BRAIN_TEXT := """# Spikeling Neural Configuration
neuron SawContribute threshold=50 leak=20
neuron SawHelpClear  threshold=50 leak=20
neuron SawDefend     threshold=50 leak=20
neuron SawBetray     threshold=50 leak=20
neuron Trust  threshold=100 leak=2
neuron Follow threshold=100 leak=5
synapse SawContribute -> Trust weight=80
synapse SawHelpClear  -> Trust weight=70
synapse SawDefend     -> Trust weight=95
synapse SawBetray     -> Trust weight=-160
synapse Trust -> Follow weight=120
neuron SawRaider  threshold=50 leak=30
neuron SawPrey    threshold=50 leak=30
neuron HeardDanger threshold=50 leak=30
refractory=2
"""

const BRAIN_TEXT_WARY := """# Spikeling Neural Configuration (Wary personality: contrib=55, trust_leak=5)
neuron SawContribute threshold=50 leak=20
neuron SawHelpClear  threshold=50 leak=20
neuron SawDefend     threshold=50 leak=20
neuron SawBetray     threshold=50 leak=20
neuron Trust  threshold=100 leak=5
neuron Follow threshold=100 leak=5
synapse SawContribute -> Trust weight=55
synapse SawHelpClear  -> Trust weight=70
synapse SawDefend     -> Trust weight=95
synapse SawBetray     -> Trust weight=-160
synapse Trust -> Follow weight=90
neuron SawRaider  threshold=50 leak=30
neuron SawPrey    threshold=50 leak=30
neuron HeardDanger threshold=50 leak=30
refractory=2
"""

const TICKS_BETWEEN_FEEDS := 14   # player walks off, does other things, comes back
const MAX_FEEDS := 25

func _init():
	print("=== In-game realistic comparison: ticks/feeds until Follow FIRST fires ===")
	print("(Follow firing == the real moment a tribe member starts backing the player,")
	print(" per tribemember.gd's _brain_tick(): 'if \"Follow\" in fired: ... is_backing_you = true')")
	print("")
	print("## Steady personality (contrib=80, close to Trust threshold=100 already) ##")
	_run("HEBBIAN", false, BRAIN_TEXT)
	_run("STDP", true, BRAIN_TEXT)
	print("## Wary personality (contrib=55, weaker synapse -- single feed alone can't cross threshold) ##")
	_run("HEBBIAN", false, BRAIN_TEXT_WARY)
	_run("STDP", true, BRAIN_TEXT_WARY)
	quit()

func _run(label: String, use_stdp: bool, brain_text: String) -> void:
	var brain: Spikeling = load("res://spikeling.gd").new()
	brain.load_from_text(brain_text)
	var total_ticks := 0
	var feeds := 0
	var backing := false
	print("--- %s ---" % label)
	for f in range(MAX_FEEDS):
		feeds += 1
		# player feeds: SawContribute stimulated (mirrors contribute("food"))
		brain.stimulate("SawContribute", 80.0)
		for t in range(TICKS_BETWEEN_FEEDS):
			var fired: Array = brain.step()
			total_ticks += 1
			if use_stdp:
				brain.stdp_learn(0.5)
			else:
				brain.learn(1.0, 0.5)
			if "Follow" in fired and not backing:
				backing = true
				print("  -> Follow fired first at feed #%d (tick %d). Trust synapse weight now %.2f"
					% [feeds, total_ticks, brain.synapse_states()[0]["weight"]])
				break
		if backing:
			break
	if not backing:
		print("  -> Follow never fired within %d feeds (%d ticks). Final SawContribute->Trust weight: %.2f"
			% [MAX_FEEDS, total_ticks, brain.synapse_states()[0]["weight"]])
	print("")
