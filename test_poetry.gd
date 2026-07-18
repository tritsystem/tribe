extends Node
# Headless test for TribePoetry -- members composing their own poems/songs,
# grounded in real memory and what they're actually sensing. Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path . res://test_poetry.tscn --quit

const SpatialGrid = preload("res://spatial_grid.gd")

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  TRIBE POETRY -- composing from experience")
	print("=".repeat(60))
	TribeMemory._mem.clear()
	TribeMemory._pending.clear()

	# scenario A: pick_form() is a real coin flip, not always one form
	_check("pick_form() returns 'song' for a low roll", TribePoetry.pick_form(0.1) == "song")
	_check("pick_form() returns 'poem' for a high roll", TribePoetry.pick_form(0.9) == "poem")

	# scenario B: situation_for() is grounded in what's ACTUALLY sensed right
	# now, with a real priority order, not a generic/blank prompt
	var m := _spawn_member("Poet")
	m.sees_raider = true
	m.hears_danger = true
	m.sees_prey = true
	m.hunger = 90.0
	_check("a member who sees a raider writes from THAT, even if other things are also true",
		"rival" in TribePoetry.situation_for(m))
	m.sees_raider = false
	_check("with no raider, danger heard nearby takes priority over prey/hunger",
		"danger" in TribePoetry.situation_for(m))
	m.hears_danger = false
	_check("with nothing else, spotted prey is the situation",
		"game" in TribePoetry.situation_for(m))
	m.sees_prey = false
	_check("with nothing sensed but real hunger, that's the situation",
		"hungry" in TribePoetry.situation_for(m))
	m.hunger = 0.0
	_check("with nothing notable at all, an ordinary-camp-life situation is still given (never blank)",
		TribePoetry.situation_for(m) != "")

	# scenario C: fallback verses are real, distinct per personality AND per
	# form -- not the same canned line regardless of who's asked
	m.personality = "Brave"
	var brave_song: String = TribePoetry.fallback_verse(m, "song")
	var brave_poem: String = TribePoetry.fallback_verse(m, "poem")
	_check("a Brave member's song fallback and poem fallback actually differ",
		brave_song != brave_poem and brave_song != "" and brave_poem != "")
	m.personality = "Wary"
	var wary_poem: String = TribePoetry.fallback_verse(m, "poem")
	_check("a different personality gets a genuinely different fallback verse",
		wary_poem != brave_poem)

	# scenario D: composing is a real end-to-end act -- it reaches TribeLLM,
	# comes back (via fallback, since Ollama isn't warm in a headless test),
	# gets SPOKEN by the member, and is written back as a real memory --
	# "thinking based on experience" actually compounding into more of it.
	m.personality = "Steady"
	m.current_thought = "..."
	TribePoetry._cd = 0.0
	TribePoetry._last_compose.clear()
	TribePoetry._try_compose()
	_check("composing actually changes what the member is currently saying/thinking",
		m.current_thought != "..." and m.current_thought != "")
	_check("the composition is written back as a real, retrievable memory",
		_has_memory_type("Poet", "composed"))

	# scenario E: a member who just composed won't be picked again immediately
	# (PER_NPC_COOLDOWN) -- composing is a considered act, not constant chatter
	_check("a member who just composed is not immediately eligible again",
		not TribePoetry._eligible(m))

	m.free()

	print("\n" + "-".repeat(42))
	print("  %d passed, %d FAILED" % [_pass, _fail])
	print("-".repeat(42) + "\n")
	get_tree().quit(1 if _fail > 0 else 0)

func _has_memory_type(agent: String, event_type: String) -> bool:
	for mem in TribeMemory._mem.get(agent, []):
		if mem["type"] == event_type:
			return true
	return false

func _spawn_member(name_: String) -> Node3D:
	var m := CharacterBody3D.new()
	m.set_script(load("res://tribemember.gd"))
	add_child(m)
	m.member_name = name_
	SpatialGrid.update(m)
	return m

func _check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  ok    %s" % label)
	else:
		_fail += 1
		print("  FAIL  %s" % label)
