extends Node
# ─────────────────────────────────────────────────────────────────────────────
# TribeRumor — information as a weapon. Autoload singleton: TribeRumor
#
# Say something to ONE member and it spreads through the gossip network, RETOLD
# in each speaker's own words by the LLM -- so the truth genuinely degrades with
# each hop, because a small model paraphrasing a paraphrase is exactly what
# rumour drift IS. No "distortion %" fudge factor needed; the mechanism is real.
#
# MECHANICAL BITE (not just flavour): a rumour carries a sentiment about a
# subject. When it's about the LEADER (you), hearing it moves the listener's
# `relationship` -- the SAME meter that drives ranks Stranger..Devoted. So a lie
# you plant can visibly cost you loyalty, and you can watch ranks fall in the
# trust labels. That's the whole "destabilise without drawing a weapon" idea,
# and it works because tribe already models loyalty properly.
#
# UPDATE (2026-08-03): a rumour about another MEMBER now has real bite too --
# see _apply_effect()'s subject != "You" branch, which moves the hearer's
# npc_opinion of that member (the same meter tribemember.gd's npc_talk_effect()
# already drives through direct conversation). This used to be flavour-only;
# it isn't anymore.
# ─────────────────────────────────────────────────────────────────────────────

const SPREAD_CHANCE := 0.55     # chance a knower gossips instead of small-talk
const MAX_HOPS := 6             # after this many retellings a rumour burns out
const LEADER_HIT := -0.30       # relationship move when a negative rumour about YOU lands
const LEADER_BOOST := 0.15      # ...or a positive one

# id -> {text, subject, sentiment, origin, hops}
var rumors: Dictionary = {}
# npc_name -> Array[id]
var knows: Dictionary = {}
var _next_id := 1

signal rumor_spread(from: String, to: String, text: String, hops: int)

## Plant a rumour. `subject` is who it's ABOUT ("You" = the leader).
func plant(text: String, subject: String, sentiment: float, origin: String, first_hearer: String) -> int:
	var id := _next_id
	_next_id += 1
	rumors[id] = {"text": text, "subject": subject, "sentiment": sentiment,
		"origin": origin, "hops": 0}
	_learn(first_hearer, id)
	print("[RUMOR #%d] planted by %s -> %s: \"%s\" (about %s, sentiment %.2f)" % [
		id, origin, first_hearer, text, subject, sentiment])
	return id

func _learn(npc: String, id: int) -> void:
	if not knows.has(npc):
		knows[npc] = []
	if not (knows[npc] as Array).has(id):
		(knows[npc] as Array).append(id)

func knows_any(npc: String) -> bool:
	return (knows.get(npc, []) as Array).size() > 0

## A rumour `from` knows that `to` has NOT heard -- else -1.
func pick_unheard(from: String, to: String) -> int:
	for id in knows.get(from, []):
		if int(rumors[id]["hops"]) >= MAX_HOPS:
			continue
		if not (knows.get(to, []) as Array).has(id):
			return int(id)
	return -1

## `to` hears `id` as RETOLD by `from` (retold_text is the LLM's paraphrase --
## that paraphrase BECOMES the rumour, which is how the truth drifts).
func transmit(id: int, from: String, to: String, retold_text: String) -> void:
	if not rumors.has(id):
		return
	var r: Dictionary = rumors[id]
	r["hops"] = int(r["hops"]) + 1
	if retold_text.strip_edges() != "":
		r["text"] = retold_text          # the drift is the retelling itself
	_learn(to, id)
	_learn(from, id)

	TribeMemory.remember(to, "gossip", from,
		"%s told me: \"%s\" (about %s)" % [from, r["text"], r["subject"]],
		"wary" if float(r["sentiment"]) < 0.0 else "warm", 0.0)
	rumor_spread.emit(from, to, str(r["text"]), int(r["hops"]))
	print("[RUMOR #%d hop %d] %s -> %s: \"%s\"" % [id, r["hops"], from, to, r["text"]])

	_apply_effect(to, r)

# GOSSIP ABOUT A PEER (2026-08-03): closes the honest gap flagged at the top
# of this file -- a rumour about another MEMBER used to be remembered and
# repeated with no trust meter to move at all. Reuses npc_opinion, the SAME
# dict tribemember.gd's own npc_talk_effect() already drives peer feelings
# through (see the NPC<->NPC grudges/feelings work) -- gossip is just
# another real way that number moves, on top of direct conversation.
# Smaller magnitude than the leader-directed case (a rumour about a peer
# matters less to you than one about your own leader), same asymmetry (a
# bad rumour costs more than a good one gains).
const GOSSIP_HIT  := -0.20
const GOSSIP_BOOST := 0.10

## The bite. Both the leader-directed case (a real trust meter) and a
## peer-directed one (real npc_opinion) move something now.
func _apply_effect(hearer: String, r: Dictionary) -> void:
	var subject: String = str(r["subject"])
	if subject == hearer:
		return   # can't gossip yourself into a different opinion of yourself
	var sent: float = float(r["sentiment"])
	if sent == 0.0:
		return
	for m in get_tree().get_nodes_in_group("tribe"):
		if not (is_instance_valid(m) and "member_name" in m and "relationship" in m):
			continue
		if str(m.get("member_name")) != hearer:
			continue
		if subject == "You":
			var delta: float = LEADER_HIT if sent < 0.0 else LEADER_BOOST
			var before: float = float(m.get("relationship"))
			m.set("relationship", maxf(0.0, before + delta))
			if m.has_method("_update_rank"):
				m._update_rank()              # may drop them a rank -- visible in the label
			TribeMemory.remember(hearer, "opinion", "You",
				"What I heard about the Leader %s how I feel." % ("soured" if sent < 0.0 else "warmed"),
				"wary" if sent < 0.0 else "warm", delta)
			print("[RUMOR effect] %s relationship %.2f -> %.2f (rank %s)" % [
				hearer, before, m.get("relationship"), m.get("current_rank")])
		elif "npc_opinion" in m:
			var op = m.get("npc_opinion")
			var before2: float = float(op.get(subject, 0.0))
			var delta2: float = clampf(before2 + (GOSSIP_HIT if sent < 0.0 else GOSSIP_BOOST), -1.0, 1.0)
			op[subject] = delta2
			m.set("npc_opinion", op)
			TribeMemory.remember(hearer, "opinion", subject,
				"What I heard about %s %s how I feel about them." % [subject, "soured" if sent < 0.0 else "warmed"],
				"wary" if sent < 0.0 else "warm", 0.0)
			print("[RUMOR effect] %s's opinion of %s: %.2f -> %.2f" % [hearer, subject, before2, delta2])
		return

## Crude sentiment + subject detection on what the PLAYER says. Deliberately
## simple and honest: keyword-based, no LLM call. If it can't find a subject in
## the real roster it returns "" and nothing is planted -- better to plant
## nothing than to invent a target.
func classify(text: String, roster: Array) -> Dictionary:
	var low := text.to_lower().strip_edges()

	# A RUMOUR IS AN ASSERTION, NOT A QUESTION. "hey do you trust me" tripped this
	# -- "you" made the subject the Leader, "trust" made it positive, so asking
	# the Companion a question planted gossip that the Leader is trustworthy. But
	# you didn't SAY anything about anyone; you ASKED. Questions carry no claim to
	# spread. Bail before classifying so the "takes that in..." plant never fires
	# on "do you...", "are you...", "what do you think of me", etc.
	if "?" in low:
		return {"subject": "", "sentiment": 0.0}
	for q in ["do you", "did you", "are you", "will you", "can you", "would you",
			"what ", "why ", "how ", "who ", "when ", "where ", "is it", "have you"]:
		if low.begins_with(q) or low.begins_with("hey " + q):
			return {"subject": "", "sentiment": 0.0}

	var subject := ""
	for n in roster:
		if str(n).to_lower() in low:
			subject = str(n)
			break
	if subject == "" and ("leader" in low or "you " in low or low.begins_with("you")):
		subject = "You"
	var neg := ["steal", "stole", "lie", "lied", "liar", "betray", "traitor", "hoard",
		"weak", "coward", "hate", "kill", "attack", "raid", "danger", "starv", "unfair", "favor"]
	var pos := ["brave", "kind", "generous", "trust", "strong", "good", "share", "fair", "hero"]
	var s := 0.0
	for w in neg:
		if w in low:
			s = -1.0
			break
	if s == 0.0:
		for w in pos:
			if w in low:
				s = 1.0
				break
	return {"subject": subject, "sentiment": s}

