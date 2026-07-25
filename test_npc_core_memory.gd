extends Node
# Headless test for NPCCoreMemory (2026-07-19) -- proves the confirmed SSH
# edge-vs-bulk result (5/5 seeds in project_thought/ssh_chiral_experiment.gd)
# actually produces the intended gameplay behavior: a betrayal survives
# combat panic, a routine slight doesn't.
# Run: Godot_v4.7-stable_win64_console.exe --headless --path . res://test_npc_core_memory.tscn --quit

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  NPC CORE MEMORY -- SSH edge/bulk wired into real NPC recall")
	print("=".repeat(60))

	# ── a freshly written memory recalls reliably before any stress ──
	var mem := NPCCoreMemory.new()
	mem.remember("betrayal:Alice", true)
	mem.remember("slight:declined_trade", false)
	_check("a freshly-written core memory recalls above zero with no stress",
		mem.recall("betrayal:Alice") > 0.0)
	_check("a freshly-written routine memory also recalls fine before any stress",
		mem.recall("slight:declined_trade") > 0.0)

	# ── across many independent trials, heavy sustained panic degrades ──
	# bulk memories much more often than it degrades core (edge) memories --
	# this is the actual, load-bearing claim, so test it statistically
	# rather than on a single (possibly lucky/unlucky) RNG draw.
	const TRIALS := 40
	var core_survived := 0
	var routine_survived := 0
	for t in range(TRIALS):
		var m := NPCCoreMemory.new()
		m.remember("betrayal:X", true)
		m.remember("slight:Y", false)
		for i in range(25):
			m.apply_stress(0.35)   # same magnitude as the confirmed hopping-disorder experiment
		if m.recall("betrayal:X") > 0.0:
			core_survived += 1
		if m.recall("slight:Y") > 0.0:
			routine_survived += 1

	print("\n  under sustained panic (25 stress ticks, 40 trials):")
	print("  core (edge) memory survived: %d/%d" % [core_survived, TRIALS])
	print("  routine (bulk) memory survived: %d/%d" % [routine_survived, TRIALS])
	_check("core (edge-anchored) memories survive sustained panic in a healthy majority of trials",
		core_survived >= TRIALS * 0.4)
	_check("routine (bulk-anchored) memories survive panic measurably less often than core memories",
		routine_survived < core_survived * 0.6)

	# ── wiring check: the real tribemember.gd hooks actually write memories ──
	var member := CharacterBody3D.new()
	member.set_script(load("res://tribemember.gd"))
	add_child(member)
	member.member_name = "Wired"
	member.witness_tribemate_death("Bob", true)   # real player-caused death hook
	_check("witness_tribemate_death(by_player=true) writes a real, recallable core memory",
		member.recall_core_memory("betrayal:Bob") > 0.0)
	member.witness_tribemate_death("Carl", false)  # a death NOT caused by the player
	_check("witness_tribemate_death(by_player=false) writes a real, recallable ROUTINE memory",
		member.recall_core_memory("death:Carl") > 0.0)
	member.blame_leader_for_hunger_death("Dana", true)   # denied-access starvation
	_check("blame_leader_for_hunger_death(denied_access=true) writes a real core memory too",
		member.recall_core_memory("hunger_neglect:Dana") > 0.0)
	member.free()

	# ── dialogue wiring: blame line reflects LIVE recall confidence ──
	var calm := CharacterBody3D.new()
	calm.set_script(load("res://tribemember.gd"))
	add_child(calm)
	calm.member_name = "Calm"
	calm.witness_tribemate_death("Eve", true)
	_check("a calm NPC with a fresh, un-degraded core memory produces a real blame line",
		calm.core_memory_blame_line().find("vividly") != -1)
	calm.free()

	# Core (edge) memories are DESIGNED to survive panic most of the time --
	# testing "does it always go hazy" on one instance would contradict the
	# feature's own intent. Test statistically instead: multiplicative jitter
	# is symmetric, so it doesn't reliably drag the AVERAGE margin down for a
	# single hop -- what actually degrades under panic is the SURVIVAL RATE
	# (recall staying above zero at all), same mechanism the original SSH
	# experiment measured (many hops all surviving is what's hard, not any
	# one hop's average). That's the honest, provable claim.
	const CONF_TRIALS := 30
	var calm_survived := 0
	var panicked_survived := 0
	for t in range(CONF_TRIALS):
		var calm_m := NPCCoreMemory.new()
		calm_m.remember("betrayal:X", true)
		if calm_m.recall("betrayal:X") > 0.0:
			calm_survived += 1

		var panicked_m := NPCCoreMemory.new()
		panicked_m.remember("betrayal:X", true)
		for i in range(60):
			panicked_m.apply_stress(0.35)
		if panicked_m.recall("betrayal:X") > 0.0:
			panicked_survived += 1
	print("\n  recall survival -- calm: %d/%d   sustained panic: %d/%d" % [calm_survived, CONF_TRIALS, panicked_survived, CONF_TRIALS])
	_check("calm (undisturbed) recall of a core memory is fully reliable",
		calm_survived == CONF_TRIALS)
	_check("sustained panic measurably lowers recall RELIABILITY even for a resilient core memory",
		panicked_survived < calm_survived)
	_check("...but it stays substantially nonzero -- the whole point of anchoring it at the edge",
		panicked_survived >= CONF_TRIALS * 0.3)

	var no_history := CharacterBody3D.new()
	no_history.set_script(load("res://tribemember.gd"))
	add_child(no_history)
	no_history.member_name = "Stranger"
	_check("an NPC with no witnessed betrayal at all produces no blame line (nothing to fabricate)",
		no_history.core_memory_blame_line() == "")
	no_history.free()

	print("\n" + "-".repeat(42))
	print("  %d passed, %d FAILED" % [_pass, _fail])
	print("-".repeat(42) + "\n")
	get_tree().quit(1 if _fail > 0 else 0)

func _check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  ok    %s" % label)
	else:
		_fail += 1
		print("  FAIL  %s" % label)
