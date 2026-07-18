extends Node
# ─────────────────────────────────────────────────────────────────────────────
# TribePoetry — members write their own poems and songs, grounded in real
# memory and what they're actually sensing right now (not invented).
# Autoload singleton: TribePoetry
#
# "Thinking based on experience" made concrete: this doesn't invent a
# separate creativity system -- it REUSES what already exists.
#   TribeLLM.compose_as()   -- new (see tribe_llm.gd), same guardrails as
#                              say_as() against inventing weather/history
#                              that doesn't exist in this world, but shaped
#                              for a few lines of verse instead of one line
#   TribeMemory.context_for() -- the member's ACTUAL past, so a poem can draw
#                              on a real memory instead of a generic one
#   tribemember.gd's own sensed state (sees_raider/sees_prey/hears_danger/
#                              hunger/current_rank) -- grounds the poem in
#                              something REAL happening right now, not a
#                              blank prompt
# Composing is itself written back as a memory ("composed"), so it can be
# spoken about later (the same way TribeTalk's conversations become
# memories) -- experience compounding into more experience over time.
#
# PACING: same discipline as TribeTalk -- one attempt per global interval,
# a long per-NPC cooldown (poems are a rarer, more considered act than idle
# small talk), and TribeLLM's own single-flight queue does the rest.
# ─────────────────────────────────────────────────────────────────────────────

const COMPOSE_INTERVAL := 50.0     # seconds between attempts (global)
const PER_NPC_COOLDOWN := 240.0    # a member won't compose again this soon
const HOLD := 7.0                  # a poem stays up longer than a spoken line
const DEBUG_POETRY := true         # TEMP: prints why nobody composed this round

var _cd := 15.0                    # small head start so it doesn't fire on frame 1
var _last_compose: Dictionary = {} # member_name -> seconds
var _composers: Dictionary = {}    # member_name -> node (to route the result back)

func _ready() -> void:
	TribeLLM.line_ready.connect(_on_line)
	set_process(true)

func _process(delta: float) -> void:
	_cd -= delta
	if _cd > 0.0:
		return
	_cd = COMPOSE_INTERVAL
	_try_compose()

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

func _eligible(m: Node) -> bool:
	# group "tribe" also holds loyal DOGS -- only real members compose
	if not (m.has_method("_think") and "personality" in m and "member_name" in m):
		return false
	if m.get("_leaving"):
		return false
	return _now() - float(_last_compose.get(m.get("member_name"), -999.0)) > PER_NPC_COOLDOWN

func _try_compose() -> void:
	var pool: Array = []
	for m in get_tree().get_nodes_in_group("tribe"):
		if is_instance_valid(m) and _eligible(m):
			pool.append(m)
	if pool.is_empty():
		if DEBUG_POETRY:
			print("[POETRY] no eligible member this round")
		return
	var m = pool[randi() % pool.size()]
	var mn: String = str(m.get("member_name"))
	_last_compose[mn] = _now()
	_composers[mn] = m

	var form: String = pick_form(randf())
	var situation: String = situation_for(m)
	TribeLLM.compose_as(mn, _persona(m), TribeMemory.context_for(mn), situation, form,
		fallback_verse(m, form), "compose")

## Poem or song -- roughly even odds. Pure/testable: takes the random roll
## as a parameter instead of calling randf() itself.
func pick_form(roll: float) -> String:
	return "song" if roll < 0.5 else "poem"

## A real, current situation to write from -- grounded in what this member
## is ACTUALLY sensing right now (see tribemember.gd's _sense_environment(),
## the same sees_raider/sees_prey/hears_danger this file reads for the
## brain), not a blank or invented prompt. There's always something true to
## write about, even if it's just an ordinary moment at camp.
func situation_for(m: Node) -> String:
	if bool(m.get("sees_raider")):
		return "You have just spotted a rival tribesperson nearby."
	if bool(m.get("hears_danger")):
		return "You heard signs of danger nearby, though you can't see it."
	if bool(m.get("sees_prey")):
		return "You have just spotted game nearby -- good hunting grounds."
	if float(m.get("hunger")) > 60.0:
		return "You are hungry."
	return "It's an ordinary moment at camp."

func _persona(m: Node) -> String:
	var p: String = str(m.get("personality"))
	var rank: String = str(m.get("current_rank"))
	var flavour: String = {
		"Steady": "You are level-headed and plain-spoken.",
		"Trusting": "You are warm and quick to believe the best of people.",
		"Wary": "You are suspicious and slow to trust; you hedge.",
		"Brave": "You are bold and blunt, keen for a fight.",
		"Greedy": "You care about food and what you're owed.",
	}.get(p, "You are level-headed.")
	return "%s Your standing with the leader is '%s'." % [flavour, rank]

## Used verbatim when Ollama is unavailable, OR when it's simply this
## member's turn and the LLM is backed up -- the camp still composes.
## Distinct lines per personality AND per form, so "Brave" reads as bold in
## both a song and a poem, but the two forms don't read identically.
const FALLBACK_VERSES := {
	"Steady":   {"poem": "The fire burns low, the camp lies still --\nwe worked, we ate, and we will still.",
		"song": "Steady hands and a steady heart,\nwe rise each day and do our part."},
	"Trusting": {"poem": "Among my friends I stand, unafraid --\ntogether the long nights are not so grey.",
		"song": "With you beside me I have no fear,\nour bond grows stronger, year by year."},
	"Wary":     {"poem": "Shadows shift where the firelight fades --\nI watch, I wait, my trust is slow-made.",
		"song": "Keep one eye open, keep one hand near --\ntrust is a coin spent slow and dear."},
	"Brave":    {"poem": "Let them come, let the spears all fly --\nI do not flinch, I do not cry.",
		"song": "Blood and bone, we stand and roar --\nbrave hearts never fear the war."},
	"Greedy":   {"poem": "A full sack and a fuller plate --\nthat is the measure of my fate.",
		"song": "Share the meat but mind my cut --\nI'll sing for food, and not for naught."},
}

func fallback_verse(m: Node, form: String) -> String:
	var p: String = str(m.get("personality"))
	var bank: Dictionary = FALLBACK_VERSES.get(p, FALLBACK_VERSES["Steady"])
	return str(bank.get(form, bank.get("poem", "")))

func _on_line(speaker: String, _listener: String, text: String, tag: String) -> void:
	if tag != "compose":
		return   # not ours -- TribeTalk/TribeRumor share the same TribeLLM signal
	var m = _composers.get(speaker)
	if m == null or not is_instance_valid(m):
		return
	m.say(text, HOLD)
	TribeMemory.remember(speaker, "composed", "You",
		"I composed something: \"%s\"" % text, "warm", 0.0)
	print("[POETRY] %s composed:\n%s" % [speaker, text])
