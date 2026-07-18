extends Node
# ─────────────────────────────────────────────────────────────────────────────
# TribeChorus — "everybody repeat after me". Autoload singleton: TribeChorus
#
#   "hey everyone come here"          -> they walk to you  (that's the "come" order)
#   "everybody repeat after me"       -> ARMED: the next thing you say is echoed
#   "war cry!"                        -> the camp roars
#   "let's go raid!"                  -> the camp shouts RAID lines, not raid ones
#
# NOT LITERAL PARROTING. The ask was "the whole tribe repeats DIFFERENT PHRASES
# REITERATING THE GOAL" -- ten identical strings is a photocopier, not a tribe.
# So each member draws a distinct line from the bank for the goal you named, in
# their own personality's voice: Brave roars, Wary hedges even mid-war-cry, Greedy
# asks what's in it. The goal is shared; the words aren't.
#
# WHY THE BANKS ARE CANNED AND NOT LLM-GENERATED:
#   Ollama is a MEASURED 2.5-4.2s warm on this machine. A war cry that lands four
#   seconds after you shout it isn't a war cry, it's an awkward silence followed
#   by muttering. A chorus is a TIMING effect -- it has to hit within a beat or
#   the whole thing is dead. This is the one place in the game where canned lines
#   beat the model outright, so they're canned and unapologetic about it.
#
# "LET'S" IS LOAD-BEARING:
#   "hunt" is a real order verb, so "everyone, let's go hunt!" would otherwise
#   dispatch a hunting party instead of raising a cheer. RALLY_MARKERS ("let's",
#   "time to", "we march") is what separates a RALLYING CRY from an ORDER. Say
#   "Ka, go hunt" and Ka goes hunting; say "let's go hunt!" and the camp shouts
#   about it. Both are things you'd actually say, and they mean different things.
#
# THE AUDIO IS DELIBERATELY THIN -- see TribeTTS: SAPI has ONE channel and two
# voices. Ten simultaneous shouts would queue into half a minute of sequential
# mumbling. So the chorus is CARRIED BY THE TEXT (everyone shouts, above their
# heads) while only the two or three whose turn lands in a gap actually sound.
# The stagger below is tuned so those few CHAIN into a ragged roar instead of
# stepping on each other. It's a compromise with the OS, and it's the honest one.
# ─────────────────────────────────────────────────────────────────────────────

const RADIUS := 16.0             # who's close enough to join in
const STAGGER_MIN := 0.30        # a chorus is ragged, not a drill team
const STAGGER_MAX := 0.75
const HOLD := 4.0
const ARM_TIMEOUT := 25.0        # "repeat after me" expires if you never follow up

var armed := false
var _arm_t := 0.0

const RALLY_MARKERS := ["let's", "lets", "let us", "time to", "we march",
	"we go", "who's with me", "whos with me"]

const ARM_PHRASES := ["repeat after me", "say after me", "repeat what i say",
	"follow my lead", "say it with me", "after me"]

# goal -> lines. Short on purpose: they're shouted, and short lines chain through
# the one TTS channel instead of blocking it.
const BANKS := {
	"warcry": ["RAAAGH!", "HOO! HOO! HOO!", "AAAAAH!", "YAAAH!", "HAAA!",
		"WOOO!", "RRRAAA!", "AI-AI-AI!"],
	"raid": ["To the raid!", "We march!", "Take it all!", "Their camp burns!",
		"No mercy!", "Blood and bone!", "They have what's ours!", "Break them!"],
	"hunt": ["Meat tonight!", "Run it down!", "To the hunt!", "Sharp and quiet!",
		"We eat well!", "Track it!"],
	"gather": ["Berries!", "Fill the baskets!", "To the bushes!", "We'll not starve!",
		"Pick them clean!"],
	"wood": ["Timber!", "To the trees!", "Fell them all!", "Wood for the fire!",
		"Swing hard!"],
	"defend": ["Hold the camp!", "They'll not pass!", "Stand fast!", "To the wall!",
		"Guard the fire!"],
}

# personality-specific lines, mixed in so a chorus isn't a monoculture. Wary
# hedging in the middle of a war cry is the joke, and it's also characterisation.
const FLAVOUR := {
	"Brave":    ["I'm first through!", "Finally!", "Let them come!"],
	"Wary":     ["...if you're sure about this.", "This had better work.",
		"I don't like it. But I'm with you."],
	"Greedy":   ["And I take a share!", "What's my cut?", "First pick is mine!"],
	"Trusting": ["With you, Leader!", "Always!", "Say it and it's done!"],
	"Steady":   ["Aye.", "Right then.", "Ready."],
}

signal chorus_performed(goal: String, voices: int)

func _process(delta: float) -> void:
	if not armed:
		return
	_arm_t -= delta
	if _arm_t <= 0.0:
		armed = false
		_flash("— the tribe stops waiting for you to speak —", 2.0)

func _ready() -> void:
	set_process(true)

## "everybody repeat after me" -- they turn and wait for the next thing you say.
func arm() -> void:
	var crowd := _crowd()
	if crowd.is_empty():
		_flash("Nobody close enough to hear you.")
		return
	armed = true
	_arm_t = ARM_TIMEOUT
	for m in crowd:
		m._think("...", 1.2)
	_flash("🗣 %d listen, waiting for your word…" % crowd.size(), 3.0)

## Is `text` an arming phrase? (pure -- testable)
func is_arm_phrase(low: String) -> bool:
	for p in ARM_PHRASES:
		if str(p) in low:
			return true
	return false

## Is `text` a rallying cry rather than an order? (pure -- testable)
func is_rally(low: String) -> bool:
	for m in RALLY_MARKERS:
		if str(m) in low:
			return true
	return false

## What are we shouting about? (pure -- testable). "" = no bank, echo the player.
##
## BUG FIXED (2026-07-17): every check here was a raw substring test ("raid" in
## low), not the whole-word match tribe_command.gd's _find_verb() already takes
## care to use (see its own comment: "log" won't fire on "along"). classify_goal()
## never got that same discipline, so "raided"/"raiding" both contain "raid" --
## a genuine QUESTION like "are we going to get raided?" classified as goal=
## "raid". On its own that's inert (route() also needs group or rally to be
## true before acting on a goal), but combine it with an addressed phrasing --
## "everyone, are we getting raided?" -- and group=true + goal="raid" + no verb
## (a question, not an order) satisfies ALL of route()'s interception
## conditions: the whole tribe choruses "Blood and bone!" in response to an
## anxious question. Fixed by requiring whole-word boundaries, same as
## _find_verb(); -ing/plural forms added back explicitly so real rally phrasing
## ("let's go raiding!", "everyone go hunting") isn't lost along with the bug.
##
## REGRESSION CAUGHT BY THE EXISTING TEST SUITE before this ever shipped: the
## first version of this fix broke "let's go raid!" -- this function's OWN
## `low` never stripped punctuation the way route()'s/parse()'s do, so "raid!"
## no longer matched " raid " (the "!" sat where the trailing space needed to
## be). Whole-word matching needs consistent punctuation stripping to mean
## anything; added the same replace() chain used elsewhere in this file.
func classify_goal(text: String) -> String:
	var low: String = " " + text.to_lower().replace("!", " ").replace("?", " ") \
		.replace(",", " ").replace(".", " ") + " "
	if "war cry" in low or "warcry" in low or "battle cry" in low or " cry " in low \
			or " roar " in low or " shout " in low:
		return "warcry"
	for w in ["raid", "raiding", "attack", "war", "charge", "march on", "sack"]:
		if (" " + str(w) + " ") in low:
			return "raid"
	for w in ["defend", "defending", "defence", "defense", "hold the", "protect", "guard"]:
		if (" " + str(w) + " ") in low:
			return "defend"
	for w in ["hunt", "hunting", "meat", "animal", "animals", "deer", "rabbit", "rabbits"]:
		if (" " + str(w) + " ") in low:
			return "hunt"
	for w in ["berries", "berry", "gather", "gathering", "forage", "foraging", "food"]:
		if (" " + str(w) + " ") in low:
			return "gather"
	for w in ["wood", "timber", "tree", "trees", "chop", "chopping", "log", "logs"]:
		if (" " + str(w) + " ") in low:
			return "wood"
	return ""

## The whole thing. `text` is whatever you just said.
func perform(text: String) -> void:
	armed = false
	var crowd := _crowd()
	if crowd.is_empty():
		_flash("Nobody close enough to hear you.")
		return

	var goal: String = classify_goal(text)
	var bank: Array = BANKS.get(goal, [])
	var pool: Array = bank.duplicate()
	pool.shuffle()

	crowd.shuffle()
	var voiced := 0
	for i in range(crowd.size()):
		var m = crowd[i]
		if not is_instance_valid(m):
			continue
		var line: String = _line_for(m, pool, i, goal, text)
		# Stagger: each member shouts a beat after the last. This is what turns
		# the chorus from a wall of simultaneous text into something that reads
		# as people picking it up one by one -- and it's what lets a couple of
		# short cries CHAIN through the single TTS channel rather than all but
		# one being dropped on arrival.
		var delay: float = float(i) * randf_range(STAGGER_MIN, STAGGER_MAX)
		_speak_later(m, line, delay)
		voiced += 1

	if goal == "":
		_flash("🗣 \"%s\" — %d take up your words" % [text, voiced], 5.0)
	else:
		_flash("🗣 %d take up the cry — %s!" % [voiced, goal.to_upper()], 5.0)
	chorus_performed.emit(goal, voiced)

## Distinct line per member: bank first (so nobody doubles up while lines remain),
## then personality flavour, then -- if there's no bank at all -- your own words
## back at you, which is what "repeat after me" literally asked for.
func _line_for(m: Node, pool: Array, i: int, goal: String, spoken: String) -> String:
	var p: String = str(m.get("personality"))
	# roughly a third speak in character rather than from the bank
	if randf() < 0.34:
		var fl: Array = FLAVOUR.get(p, [])
		if not fl.is_empty():
			return str(fl[randi() % fl.size()])
	if not pool.is_empty():
		return str(pool[i % pool.size()])      # pool is shuffled -> no clustering
	return _echo(spoken, p)

## No bank matched -> genuine repeat-after-me, bent by who's saying it.
func _echo(spoken: String, p: String) -> String:
	var s := spoken.strip_edges().rstrip("!.?")
	match p:
		"Brave":  return s.to_upper() + "!"
		"Wary":   return s + "...?"
		"Greedy": return s + " — and a share for me!"
		_:        return s + "!"

func _speak_later(m: Node, line: String, delay: float) -> void:
	if delay <= 0.01:
		_do_say(m, line)
		return
	var t := get_tree().create_timer(delay)
	t.timeout.connect(_do_say.bind(m, line))

func _do_say(m: Node, line: String) -> void:
	if not is_instance_valid(m):
		return
	# say() = text above the head + a voice if TribeTTS has a free channel and
	# you're in earshot. The text is guaranteed; the audio is best-effort.
	if m.has_method("say"):
		m.say(line, HOLD)
	elif m.has_method("_think"):
		m._think(line, HOLD)
	TribeMemory.remember(str(m.get("member_name")), "chorus", "You",
		"We all took up the cry: \"%s\"" % line, "warm", 0.03)

## Everyone near enough to hear you. Dogs aren't members and don't chant.
func _crowd() -> Array:
	var pl := get_tree().get_first_node_in_group("player") as Node3D
	if pl == null:
		return []
	var out: Array = []
	for m in get_tree().get_nodes_in_group("tribe"):
		if not (is_instance_valid(m) and "member_name" in m and m.has_method("_think")):
			continue
		if pl.global_position.distance_to((m as Node3D).global_position) <= RADIUS:
			out.append(m)
	return out

func _flash(t: String, dur: float = 4.0) -> void:
	# Rallying / speaking to your own crowd -> "Your Tribe" box.
	var mgr := get_tree().get_first_node_in_group("tribe_manager")
	if mgr and mgr.has_method("notify_cat"):
		mgr.notify_cat("tribe", t)
	elif mgr and mgr.has_method("_flash"):
		mgr._flash(t, dur)
	else:
		print("[CHORUS] " + t)
