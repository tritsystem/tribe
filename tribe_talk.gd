extends Node
# ─────────────────────────────────────────────────────────────────────────────
# TribeTalk — NPC↔NPC conversation, spoken FROM memory.
# Autoload singleton: TribeTalk
#
# This is the payoff of the memory layer: members don't emit generic barks, they
# speak from what actually happened to them ("you kept feeding me", "my feeling
# toward you cooled"). Two members near each other -> one opens, the other
# answers, and BOTH remember the exchange -- so a conversation is itself a
# memory that can be spoken about later. That's how gossip becomes possible.
#
# REUSES what already exists (no parallel systems):
#   _think()      -- members already have a ThoughtLabel above their head
#   personality   -- Steady/Trusting/Wary/Brave/Greedy => the LLM persona
#   current_rank  -- their standing with the player colours what they say
#   TribeMemory   -- the actual past
#   TribeLLM      -- async, 1-in-flight, canned fallback if Ollama is down
#
# PACING: one conversation attempt every TALK_INTERVAL globally, per-NPC
# cooldown, and the LLM itself is single-flight. A camp of 10 NPCs must never
# turn into 10 concurrent 2GB model calls -- this machine has a framerate budget.
# ─────────────────────────────────────────────────────────────────────────────

const TALK_INTERVAL := 14.0     # seconds between conversation attempts (global)
# 6.0 was too tight: members now stay near where they WORKED rather than
# returning to the player (see the stay-near-work change), and social clustering
# isn't built yet -- so the camp is spread out and pairs were never within 6m.
const TALK_RADIUS := 12.0
const PER_NPC_COOLDOWN := 45.0  # a given NPC won't chat again this soon
const HOLD := 5.0               # seconds the spoken line stays above their head
const DEBUG_TALK := true        # TEMP: prints WHY a conversation didn't start

var _cd := 4.0                  # small head start so it doesn't fire on frame 1
var _last_talk: Dictionary = {} # member_name -> seconds
var _speakers: Dictionary = {}  # member_name -> node (to route the reply back)
var _open_line: String = ""     # what A said, so B can actually answer IT
var _pending_rumor: Dictionary = {}   # the rumour currently being retold, if any

func _ready() -> void:
	TribeLLM.line_ready.connect(_on_line)
	set_process(true)

func _process(delta: float) -> void:
	_cd -= delta
	if _cd > 0.0:
		return
	_cd = TALK_INTERVAL
	_try_start()

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

func _eligible(m: Node) -> bool:
	# group "tribe" also holds loyal DOGS -- only real members talk
	if not (m.has_method("_think") and "personality" in m and "member_name" in m):
		return false
	# NOTE: `is_busy` is deliberately NOT excluded. Members self-assign chores
	# almost constantly (the console is a stream of ACCEPTED order: wood/hunt),
	# so excluding busy members meant almost nobody was ever eligible and the
	# camp stayed silent. People talk while they work.
	if m.get("_leaving"):
		return false
	return _now() - float(_last_talk.get(m.get("member_name"), -999.0)) > PER_NPC_COOLDOWN

func _try_start() -> void:
	# NOTE: we deliberately still run when TribeLLM.available is false -- the
	# canned fallbacks keep the camp murmuring with Ollama off, which is the
	# whole point of having them.
	var pool: Array = []
	for m in get_tree().get_nodes_in_group("tribe"):
		if is_instance_valid(m) and _eligible(m):
			pool.append(m)
	if pool.is_empty():
		if DEBUG_TALK:
			print("[TALK] no eligible member this round (llm warm=%s)" % TribeLLM.warm)
		return
	pool.shuffle()
	var a = pool[0]
	var b = null
	var nearest := 9999.0
	# CROSS-TRIBE (2026-07-30): only meaningful with 2+ eligible tribemates
	# nearby, so this loop is skipped entirely when there's just one -- the
	# rival fallback below still gets a chance regardless of pool size.
	for cand in pool.slice(1, pool.size()):
		var d: float = (a as Node3D).global_position.distance_to((cand as Node3D).global_position)
		nearest = minf(nearest, d)
		if d <= TALK_RADIUS:
			b = cand
			break
	var cross_tribe := false
	if b == null:
		# No tribemate in range (or none besides `a` at all) -- try a nearby
		# rival NPC instead, but only from a tribe that's genuinely friendly
		# (the same opinion threshold npc.gd's _find_intruder() now uses to
		# decide a camp is safe to walk through). Safe to do at all only
		# because rival NPCs are individually named now (see npc.gd's
		# RIVAL_NAMES) -- they used to all share their tribe's own name,
		# which would have collided in _last_talk/_speakers below.
		b = _find_friendly_rival(a)
		cross_tribe = b != null
	if b == null:
		if DEBUG_TALK:
			print("[TALK] %d eligible but nearest pair is %.1fm apart (need <=%.0fm), no friendly rival nearby either" % [
				pool.size(), nearest, TALK_RADIUS])
		return
	if DEBUG_TALK:
		print("[TALK] %s -> %s%s (%.1fm apart, llm warm=%s)" % [
			a.get("member_name"), b.get("member_name"), " [cross-tribe]" if cross_tribe else "",
			(a as Node3D).global_position.distance_to((b as Node3D).global_position), TribeLLM.warm])

	var an: String = str(a.get("member_name"))
	var bn: String = str(b.get("member_name"))
	_last_talk[an] = _now()
	if not cross_tribe:
		_last_talk[bn] = _now()   # a rival isn't in the "tribe" eligibility pool at all -- nothing to cool down
	_speakers[an] = a
	_speakers[bn] = b

	if cross_tribe:
		var b_tribe = b.get("tribe")
		var b_tribe_name: String = str(b_tribe.tribe_name) if b_tribe and is_instance_valid(b_tribe) else "a rival clan"
		TribeLLM.say_as(an, bn, _persona(a), TribeMemory.context_for(an),
			"You are near a friendly rival, %s of the %s. Say something to them -- greet them, or ask about their clan." % [bn, b_tribe_name],
			_fallback_open(a, bn), "open:" + bn, roster_string())
		return

	# GOSSIP takes priority over small talk: if A carries a rumour B hasn't heard,
	# A passes it on -- RETOLD in A's own words. That retelling becomes the rumour
	# (see TribeRumor.transmit), so the truth drifts by the real mechanism rather
	# than a fudge factor.
	var rid: int = TribeRumor.pick_unheard(an, bn)
	if rid >= 0 and randf() < TribeRumor.SPREAD_CHANCE:
		_pending_rumor = {"id": rid, "from": an, "to": bn}
		var r: Dictionary = TribeRumor.rumors[rid]
		TribeLLM.say_as(an, bn, _persona(a), TribeMemory.context_for(an),
			"You heard this and you believe it: \"%s\". Pass it on to %s in your OWN words." % [r["text"], bn],
			str(r["text"]), "gossip:" + bn, roster_string())
		return

	TribeLLM.say_as(an, bn, _persona(a), TribeMemory.context_for(an),
		"You are at camp beside %s. Say something to them -- about the leader, the work, or how you feel." % bn,
		_fallback_open(a, bn), "open:" + bn, roster_string())

## The real cast, so the model stops inventing "Kanaq"/"Zog" to fill name holes.
func roster_string() -> String:
	var names: Array[String] = ["the Leader (the player, who you speak to as 'Leader')"]
	for n in roster_names():
		names.append(str(n))
	return ", ".join(names)

## Just the member names (used for rumour subject-detection too).
func roster_names() -> Array:
	var names: Array = []
	for m in get_tree().get_nodes_in_group("tribe"):
		if is_instance_valid(m) and "member_name" in m:
			var n: String = str(m.get("member_name"))
			if n != "" and not names.has(n):
				names.append(n)
	return names

## A nearby rival NPC willing to talk -- only from a tribe that's genuinely
## friendly (opinion >= 0.3, the same threshold npc.gd's own _find_intruder()
## uses to decide a camp is safe to walk through). Safe to key by
## member_name at all because rival NPCs are individually named now (see
## npc.gd's RIVAL_NAMES) -- they used to all share their tribe's own name.
func _find_friendly_rival(near: Node) -> Node:
	var best: Node = null
	var bd := TALK_RADIUS
	for o in get_tree().get_nodes_in_group("npc"):
		if not is_instance_valid(o) or o.get("neutral"):
			continue
		var t = o.get("tribe")
		if t == null or not is_instance_valid(t):
			continue
		var op = t.get("player_opinion")
		if op == null or float(op) < 0.3:
			continue
		var d: float = (near as Node3D).global_position.distance_to((o as Node3D).global_position)
		if d <= bd:
			bd = d
			best = o
	return best

## Dispatches to the right persona builder: a real tribemate (has current_rank)
## uses the full _persona() below; a rival NPC (npc.gd has no such property,
## no hunger tracking, no brain_snapshot()) gets its own, separate builder --
## reusing _persona() unmodified for a rival risked float(m.get("hunger"))
## on a property that plain doesn't exist there.
func _persona_for(m: Node) -> String:
	if "current_rank" in m:
		return _persona(m)
	return _rival_persona(m)

func _rival_persona(m: Node) -> String:
	var archetype: String = str(m.get("personality"))
	var t = m.get("tribe")
	var tribe_name: String = str(t.tribe_name) if t and is_instance_valid(t) else "a rival clan"
	return "You belong to the %s, a %s clan. You are currently on good terms with the Leader." \
		% [tribe_name, archetype]

func _persona(m: Node) -> String:
	var p: String = str(m.get("personality"))
	var rank: String = str(m.get("current_rank"))
	var hungry: bool = float(m.get("hunger")) > 60.0
	# explicit String: Dictionary.get() returns a Variant, so `:=` cannot infer
	# (gdscript-type-inference lesson -- note this one hid in a MULTI-LINE
	# expression, where the `:=` and the `.get()` sit on different lines)
	var flavour: String = {
		"Steady": "You are level-headed and plain-spoken.",
		"Trusting": "You are warm and quick to believe the best of people.",
		"Wary": "You are suspicious and slow to trust; you hedge.",
		"Brave": "You are bold and blunt, keen for a fight.",
		"Greedy": "You care about food and what you're owed.",
	}.get(p, "You are level-headed.")
	var brain_text: String = str(m.call("brain_snapshot")) if m.has_method("brain_snapshot") else ""
	return "%s Your standing with the leader is '%s'.%s %s" % [
		flavour, rank, " You are hungry." if hungry else "", brain_text]

func _fallback_open(m: Node, other: String) -> String:
	# used verbatim when Ollama is unavailable -- the camp still murmurs
	var p: String = str(m.get("personality"))
	var lines: Dictionary = {
		"Steady": "Quiet day, %s." % other,
		"Trusting": "Good to see you, %s." % other,
		"Wary": "Keep your eyes open, %s." % other,
		"Brave": "I could use a hunt, %s." % other,
		"Greedy": "Is there food left, %s?" % other,
	}
	return str(lines.get(p, "Well met, %s." % other))   # .get() -> Variant; func returns String

func _on_line(speaker: String, listener: String, text: String, tag: String) -> void:
	var sp = _speakers.get(speaker)
	if sp == null or not is_instance_valid(sp):
		return
	# say() not _think(): NPC<->NPC dialogue is real speech, so it gets a voice if
	# you're near enough to overhear. Not forced -- eavesdropping is best-effort,
	# and a conversation across camp shouldn't cut off your Companion answering you.
	#
	# CROSS-TRIBE FIX (2026-07-30): a rival NPC (npc.gd) has no say()/_think()
	# -- that's a tribemember.gd-only thought-bubble system. Extending
	# dialogue to rivals without this guard crashed with "Nonexistent
	# function 'say'" the instant a rival's own reply came back. The
	# mechanical side (memory, TribeRumor) still happens regardless; only
	# the above-head text/voice is skipped for a participant that has
	# nowhere to display it.
	if sp.has_method("say"):
		sp.say(text, HOLD)
	elif DEBUG_TALK:
		print("[TALK] %s (no speech display): %s" % [speaker, text])

	if tag.begins_with("gossip:"):
		# A retold the rumour -> that retelling IS the rumour now (drift), B learns
		# the drifted version, and if it's about the Leader it moves B's loyalty.
		if not _pending_rumor.is_empty():
			TribeRumor.transmit(int(_pending_rumor["id"]), str(_pending_rumor["from"]),
				str(_pending_rumor["to"]), text)
			_pending_rumor = {}
		TribeMemory.remember(speaker, "gossip", listener,
			"I told %s: \"%s\"" % [listener, text], "wary", 0.0)
		return

	if tag.begins_with("open:"):
		# A spoke -> B answers what A ACTUALLY said (not a generic reply)
		_open_line = text
		var lb = _speakers.get(listener)
		if lb == null or not is_instance_valid(lb):
			return
		TribeLLM.say_as(listener, speaker, _persona_for(lb),
			TribeMemory.context_for(listener, speaker),
			"%s just said to you: \"%s\". Answer them." % [speaker, text],
			_fallback_reply(lb), "reply:" + speaker, roster_string())
		# A remembers speaking
		TribeMemory.remember(speaker, "talked", listener,
			"I said to %s: \"%s\"" % [listener, text], "neutral", 0.02)
	else:
		# B answered -> the exchange is itself a memory, for BOTH of them.
		# This is what later lets gossip exist: they can talk about having talked.
		TribeMemory.remember(speaker, "talked", listener,
			"I told %s: \"%s\"" % [listener, text], "neutral", 0.02)
		TribeMemory.remember(listener, "heard", speaker,
			"%s said to me: \"%s\"" % [speaker, text], "neutral", 0.03)
		# NPC<->NPC feelings, driven by the loyalty-rank gap between the two --
		# see tribemember.gd's npc_talk_effect() for the real mechanic.
		var spk_node = _speakers.get(speaker)
		var lst_node = _speakers.get(listener)
		if spk_node and is_instance_valid(spk_node) and spk_node.has_method("npc_talk_effect") \
				and lst_node and is_instance_valid(lst_node) and lst_node.has_method("loyalty_score"):
			spk_node.npc_talk_effect(listener, lst_node.loyalty_score())
		if lst_node and is_instance_valid(lst_node) and lst_node.has_method("npc_talk_effect") \
				and spk_node and is_instance_valid(spk_node) and spk_node.has_method("loyalty_score"):
			lst_node.npc_talk_effect(speaker, spk_node.loyalty_score())

func _fallback_reply(m: Node) -> String:
	var p: String = str(m.get("personality"))
	var lines: Dictionary = {
		"Steady": "Aye. That's how it is.",
		"Trusting": "You're right, friend.",
		"Wary": "Maybe. Maybe not.",
		"Brave": "Then let's do something about it.",
		"Greedy": "So long as I'm fed.",
	}
	return str(lines.get(p, "Mm."))   # .get() -> Variant; func returns String
