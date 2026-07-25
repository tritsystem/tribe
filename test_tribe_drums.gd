extends Node
# Headless test for TribeDrums -- real generative percussion driven by real
# Spikeling neuron fire events (2026-07-19). Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path . res://test_tribe_drums.tscn --quit

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  TRIBE DRUMS -- neuron fire events as real percussion")
	print("=".repeat(60))

	TribeDrums._active_hits.clear()
	TribeDrums._sample_pos = 0

	# ── a real hit actually produces a real, audible waveform ──
	TribeDrums.on_neuron_fired("Trust", true)
	_check("a fired neuron with a real voice mapping queues a real hit",
		TribeDrums._active_hits.size() == 1)
	# a real sine starts at exactly 0 by definition (sin(0) == 0) -- check
	# just after onset, not the onset sample itself, for real nonzero output
	var peak: float = TribeDrums._render_sample(20)
	_check("the hit's waveform is genuinely nonzero just after its own onset",
		absf(peak) > 0.0001)

	# ── the envelope genuinely decays, this isn't a flat drone ──
	var early: float = absf(TribeDrums._render_sample(100))
	var late: float = absf(TribeDrums._render_sample(int(TribeDrums.MIX_RATE * 2.0)))
	_check("the percussion envelope genuinely decays toward silence over time",
		late < early)

	# ── an unmapped/unknown neuron name is silently ignored, not a crash ──
	TribeDrums._active_hits.clear()
	TribeDrums.on_neuron_fired("SomeUnmappedNeuron", true)
	_check("an unmapped neuron name produces no hit at all (no crash, no silent garbage)",
		TribeDrums._active_hits.is_empty())

	# ── different neurons really do sound different (distinct real voices) ──
	var betray: Dictionary = TribeDrums.VOICE["SawBetray"]
	var trust: Dictionary = TribeDrums.VOICE["Trust"]
	_check("a real conflict neuron (SawBetray) and a real bonding neuron (Trust) are genuinely distinct voices",
		betray["pitch"] != trust["pitch"] and betray["decay"] != trust["decay"])

	# ── audibility is gated -- day/distance from the fire silences it ──
	TribeDrums._active_hits.clear()
	var member := _spawn_member()
	member.manager = _fake_manager(false)   # is_night = false
	member.global_position = Vector3.ZERO
	var fire := StaticBody3D.new()
	fire.set_script(load("res://campfire.gd"))
	add_child(fire)
	fire.global_position = Vector3.ZERO
	member._drum_fired_neurons(["Trust"])
	_check("daytime firing near the campfire produces NO audible hit",
		TribeDrums._active_hits.is_empty())

	member.manager = _fake_manager(true)   # is_night = true, but far from any fire
	member.global_position = Vector3(500, 0, 500)
	member._drum_fired_neurons(["Trust"])
	_check("nighttime firing FAR from any campfire also produces no hit",
		TribeDrums._active_hits.is_empty())

	member.global_position = Vector3(1, 0, 1)   # now genuinely at the fire, at night
	member._drum_fired_neurons(["Trust", "SawBetray"])
	_check("gathered at the real campfire, at night, real fires genuinely become audible hits",
		TribeDrums._active_hits.size() == 2)

	member.free(); fire.free()
	TribeDrums._active_hits.clear()

	# ── velocity-sensitive hits (2026-07-19) ──
	var soft_brain := Spikeling.new()
	soft_brain.load_from_text("neuron X threshold=100 leak=0\nrefractory=2\n")
	soft_brain.stimulate("X", 100.0)   # just barely crosses -- a soft tap
	soft_brain.step()
	var soft_strength: float = soft_brain.fire_strength("X")

	var hard_brain := Spikeling.new()
	hard_brain.load_from_text("neuron X threshold=100 leak=0\nrefractory=2\n")
	hard_brain.stimulate("X", 400.0)  # driven well past threshold -- a hard strike
	hard_brain.step()
	var hard_strength: float = hard_brain.fire_strength("X")

	_check("Spikeling reports a real, distinct fire strength for a bare-threshold crossing vs a hard drive",
		hard_strength > soft_strength and soft_strength >= 0.0)

	TribeDrums._active_hits.clear()
	TribeDrums.on_neuron_fired("Trust", true, 0.05)
	var soft_hit: Dictionary = TribeDrums._active_hits[0]
	TribeDrums._active_hits.clear()
	TribeDrums.on_neuron_fired("Trust", true, 1.0)
	var hard_hit: Dictionary = TribeDrums._active_hits[0]
	_check("a low-velocity fire produces a real, quieter hit than a full-velocity one",
		float(soft_hit["amp"]) < float(hard_hit["amp"]))
	_check("...and a shorter ring, not just quieter",
		float(soft_hit["decay"]) < float(hard_hit["decay"]))
	_check("even a bare-threshold (near-zero velocity) fire is still genuinely audible, not silent",
		float(soft_hit["amp"]) > 0.0)
	TribeDrums._active_hits.clear()

	# ── emergent synchronization wiring (2026-07-19) ──
	# TribeDrums.ambient_level() reflects real active hits...
	_check("ambient_level() is zero with no active hits",
		TribeDrums.ambient_level() == 0.0)
	TribeDrums.on_neuron_fired("Trust", true, 1.0)
	_check("ambient_level() becomes nonzero the instant a real hit is queued",
		TribeDrums.ambient_level() > 0.0)
	TribeDrums._active_hits.clear()

	# ...and _drum_fired_neurons() actually feeds it back into the SAME
	# member's own brain (the confirmed coupling mechanism), not just audio.
	var m2 := _spawn_member()
	m2.manager = _fake_manager(true)
	m2.global_position = Vector3(1, 0, 1)
	var fire2 := StaticBody3D.new()
	fire2.set_script(load("res://campfire.gd"))
	add_child(fire2)
	fire2.global_position = Vector3(1, 0, 1)
	TribeDrums.on_neuron_fired("Trust", true, 1.0)   # pre-existing ambient from elsewhere
	m2.brain.step()   # let any prior pending settle before measuring the delta
	var trust_before: float = m2.brain.get_potential("Trust")
	m2._drum_fired_neurons(["SawContribute"])   # this queues a stimulate(); it only lands on the NEXT step()
	m2.brain.step()
	var trust_after: float = m2.brain.get_potential("Trust")
	_check("gathered at the fire, a real ambient level feeds back into this member's own Trust neuron",
		trust_after > trust_before)
	m2.free(); fire2.free()
	TribeDrums._active_hits.clear()

	# ── feeding must NOT drive the sync coupling (2026-07-19) ──
	TribeDrums.on_neuron_fired("SawContribute", true, 1.0)   # a real feeding event
	_check("feeding is still audible (a real drum hit is queued)",
		TribeDrums._active_hits.size() == 1)
	_check("...but feeding contributes NOTHING to the sync-driving ambient level",
		TribeDrums.ambient_level() == 0.0)
	TribeDrums._active_hits.clear()
	TribeDrums.on_neuron_fired("Trust", true, 1.0)   # a real trust/conflict event
	_check("a real trust/conflict neuron DOES contribute to the sync-driving ambient level",
		TribeDrums.ambient_level() > 0.0)
	TribeDrums._active_hits.clear()

	print("\n" + "-".repeat(42))
	print("  %d passed, %d FAILED" % [_pass, _fail])
	print("-".repeat(42) + "\n")
	get_tree().quit(1 if _fail > 0 else 0)

func _spawn_member() -> Node3D:
	var m := CharacterBody3D.new()
	m.set_script(load("res://tribemember.gd"))
	add_child(m)
	m.member_name = "Drummer"
	return m

func _fake_manager(night: bool) -> Node:
	var script := GDScript.new()
	script.source_code = "extends Node\nvar is_night: bool = %s\n" % ("true" if night else "false")
	script.reload()
	var n := Node.new()
	n.set_script(script)
	add_child(n)
	return n

func _check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  ok    %s" % label)
	else:
		_fail += 1
		print("  FAIL  %s" % label)
