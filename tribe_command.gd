extends Node
# ─────────────────────────────────────────────────────────────────────────────
# TribeCommand — plain-language orders. Autoload singleton: TribeCommand
#
# "Ka, go get berries"          -> Ka gathers
# "hey everyone around me, get wood" -> every member within GROUP_RADIUS chops
# "Companion, what have you heard?"  -> your Companion reports the gossip network
#
# ONE parser, TWO front ends: typed chat ([T]) and voice (TribeVoice). Both call
# try_execute(). Voice is just another source of a string -- it gets no special
# powers and no separate grammar to drift out of sync.
#
# ORDERS GO THROUGH give_order() -- NOT around it.
#   That method already weighs rank loyalty + courage against the task's risk and
#   can REFUSE. Saying it out loud must not bypass that. A Stranger telling you
#   "no" to a hunt is the loyalty system working, not a bug in the parser. This
#   is the whole reason we don't just set the job directly.
#
# WHY THE PARSER IS DELIBERATELY STINGY:
#   The mic is always on. Every word you say near it lands here. So a command
#   requires BOTH an addressee (a name, or an explicit group phrase) AND a known
#   verb. "we should get some wood sometime" is conversation and stays
#   conversation. When in doubt this returns CHAT and lets the LLM answer --
#   a missed order costs you one repeat, a false order marches your camp away.
#
# HONEST LIMIT -- short names vs speech-to-text:
#   The roster is Ka/Bo/Ru/Wen/Kin/... 2-3 characters. Cloud STT mangles these
#   constantly ("Ka"->"car", "Bo"->"bow", "Ru"->"rue"). HOMOPHONES below buys
#   most of that back. But names that ARE common English words -- Wen("when"),
#   Kin("kin"), Bo("bow"), Brae("break") -- are deliberately NOT given loose
#   homophones, because "when we get wood" would then order Wen to chop trees.
#   Those names need a clear pronunciation or the typed path. That's a real
#   tradeoff and it's better than a camp that marches on stray syllables.
# ─────────────────────────────────────────────────────────────────────────────

const GROUP_RADIUS := 15.0     # "everyone around me"
const NAME_FUZZ := 0.62        # String.similarity() floor for a mangled name
const CONFIRM_HOLD := 4.0

# Spoken verb -> the kind give_order()/rally_order() already understands.
# Keys are matched as whole words, so "log" won't fire on "along".
const VERBS := {
	"gather": ["berries", "berry", "gather", "forage", "pick", "fruit", "bush",
		"bushes", "food", "gathering"],
	"wood":   ["wood", "timber", "logs", "log", "tree", "trees", "chop",
		"lumber", "firewood", "chopping"],
	"hunt":   ["hunt", "hunting", "meat", "animal", "animals", "rabbit",
		"rabbits", "deer", "game", "kill"],
	"scout":  ["scout", "scouting", "explore", "patrol", "recon", "scouts",
		"investigate", "investigating"],
	"come":   ["come here", "come", "gather round", "gather around", "over here",
		"to me", "on me", "rally", "regroup", "form up", "assemble",
		"follow me", "with me"],
	# DIRECTED weapon crafting (2026-07-17): a specific choice ("Ka, craft a
	# spear") instead of tribemember.gd's _maybe_upgrade_gear()'s random
	# automatic pick. Multi-word phrases only, deliberately -- no bare
	# "spear"/"bow"/"axe" trigger, since those are exactly the kind of
	# single common word this parser's own STOPWORDS discipline exists to
	# guard against reintroducing (see the "well"->Vel history above).
	"craft_club":  ["craft a club", "carve a club", "forge a club", "make a club"],
	"craft_spear": ["craft a spear", "carve a spear", "forge a spear", "make a spear"],
	"craft_bow":   ["craft a bow", "carve a bow", "forge a bow", "make a bow"],
	"craft_axe":   ["craft an axe", "carve an axe", "forge an axe", "make an axe"],
}

# verb kind -> tribemember.gd's WEAPON_TIERS index. Used in _do_order() to
# bypass give_order()/ORDER_RISK entirely for crafting -- see its comment
# there for why (not dangerous, same precedent as build/carve).
const CRAFT_TIERS := {"craft_club": 0, "craft_spear": 1, "craft_bow": 2, "craft_axe": 3}

# DELIBERATELY ABSENT: "build" and "carve".
#
# I had them in this table and they were broken 100% of the time, silently.
# give_order() looks up ORDER_RISK.get(kind, 999) and refuses anything above the
# member's drive -- and build/carve are NOT in ORDER_RISK, so every single one
# scored 999 and was refused. They never belonged there: _start_job() routes them
# to _begin_carve()/begin_build(), dedicated entry points with their own
# is_busy lifecycle that bypass give_order entirely.
#
# Wiring them up properly means bolting a loyalty check onto a path that has
# never had one, and they weren't asked for. A verb the game accepts and then
# silently always refuses is worse than a verb that isn't there, so they're out
# until they can be done for real. "come" IS in ORDER_RISK -- see tribemember.gd.

# Hand-curated mishears. Any entry here is an unconditional name match, so the
# bar for adding one is: WOULD YOU EVER SAY THIS WORD AROUND A STONE-AGE CAMP?
# Not "is it an English word" -- that bar is wrong in both directions, and the
# test corpus caught it going both ways:
#
#   removed, because you WOULD say them here:
#     "well" -> Vel   ("well I could hunt later" ordered Vel to hunt -- shipped bug)
#     "duck" -> Dak   (a duck is HUNTABLE PREY; "hunt the duck" would order Dak)
#     "self" -> Sef   ("help yourself to the berries")
#
#   kept, because you never would:
#     "car" -> Ka, "mock" -> Mok. I stripped these out with the others and the
#     corpus failed the POSITIVE cases -- "car" is the single likeliest mishear
#     of "Ka" and no one says "car" at a campfire. Over-correcting cost real
#     recall, which is why the positives are in the corpus too.
#
# STOPWORDS in _find_names() backstops this table so hand-curation can't quietly
# reintroduce the "well" class of failure as the roster grows.
const HOMOPHONES := {
	"Ka":   ["car", "kah", "kaa", "cah", "caw"],
	"Ru":   ["rue", "roo", "rew", "roux"],
	"Tam":  ["tamm", "tahm"],
	"Sef":  ["seth", "saif", "sez"],
	"Mok":  ["mock", "moke", "mach"],
	"Lir":  ["leer", "lear", "lira"],
	"Dak":  ["dack", "dac", "dakh"],
	"Fenn": ["fen", "finn", "fend"],
	"Vel":  ["vell", "veil"],
	"Orra": ["ora", "aura", "aurora"],
	"Zol":  ["zoll", "zole"],
	"Cael": ["kale", "kyle", "cale"],
	"Companion": ["companion", "buddy", "partner"],
}

# Common words that must never fuzzy-match into a name, however close they score.
# The roster is short and invented; ordinary English is not. This is the guard
# that keeps a growing roster from re-introducing the "went"->Wen failure.
const STOPWORDS := ["went", "when", "then", "them", "they", "well", "will",
	"were", "what", "want", "wait", "come", "came", "keep", "kind", "king",
	"take", "took", "look", "make", "more", "most", "much", "know", "over",
	"back", "down", "good", "some", "that", "this", "with", "from", "have",
	"here", "there", "your", "just", "like", "dont", "cant", "were", "very"]

# BARE IMPERATIVES: "go get berries", said to whoever you're standing with.
#
# The parser otherwise demands an addressee (a name or "everyone") before it will
# dispatch anyone, which is right for an always-on mic -- but wrong for how people
# actually speak. You walk up to someone and say "go get berries". You don't say
# "Companion, go get berries" any more than you'd say your friend's full name
# before every sentence. With a one-member tribe it's absurd.
#
# IMPERATIVE POSITION is what makes this safe. A command STARTS with its verb; a
# description doesn't:
#     "go get berries"                     -> starts with "go"  -> an order
#     "I'm going to go get berries myself" -> starts with "i'm" -> just talking
#     "we should get some wood sometime"   -> starts with "we"  -> just talking
#     "the hunt went badly yesterday"      -> starts with "the" -> just talking
# All four contain a verb. Only one is aimed at anybody, and word order says which
# -- so this buys natural phrasing without loosening the always-on-mic gate.
#
# Only verbs that map to a REAL order. "take"/"start"/"stop"/"help"/"run" are
# imperative English but mean nothing this game can dispatch, and including them
# just turns ordinary speech into failed orders -- "take the logs over there"
# would fire a wood order at nobody in particular. If a verb can't be obeyed, it
# doesn't belong here.
const IMPERATIVE_STARTS := ["go ", "get ", "grab ", "fetch ", "bring ", "chop ",
	"gather ", "hunt ", "scout ", "find ", "come ", "follow ", "head ", "investigate ",
	"craft ", "carve ", "forge ", "make "]

const GROUP_WORDS := ["everyone", "everybody", "all of you", "you all", "y'all",
	"everyones", "the tribe", "tribe"]
# Words that narrow WHO is being addressed to those in earshot.
#
# "here" is deliberately NOT one of them, though it reads like it belongs. These
# two sentences use it in opposite ways:
#   "hey everyone AROUND ME, get wood"  -- "around me" filters WHO
#   "everyone come HERE"                -- "here" is WHERE, not who
# With "here" in this list the summons silently restricted itself to members
# already within 15m: you'd call your tribe and only the people already standing
# next to you would answer, which is exactly backwards.
const NEARBY_WORDS := ["around me", "near me", "nearby", "next to me", "with me",
	"beside me"]
const INTEL_WORDS := ["what have you heard", "heard anything", "any news",
	"what's the word", "whats the word", "what do you know", "any gossip",
	"what are they saying", "what's being said", "whats being said",
	"any rumors", "any rumours", "what's going on", "whats going on"]

signal order_issued(targets: Array, verb: String, spoken: String)

## Main entry. Returns true if this string was consumed as a command.
## False means "this is conversation" -- the caller should hand it to the LLM.
##
## The ARMED case is stateful and lives here; every other decision is delegated to
## route(), which is pure and tested.
func try_execute(text: String, source: String = "chat") -> bool:
	# ARMED BEATS EVERYTHING, and it has to be checked before route() because it
	# depends on state route() can't see. You said "repeat after me"; whatever
	# comes next is the thing to repeat -- even if it contains an order verb.
	# "repeat after me!" / "let's go hunt!" must raise a cheer, not empty the camp.
	if TribeChorus.armed:
		TribeChorus.perform(text)
		return true

	var r: Dictionary = route(text)
	var p: Dictionary = r["parse"]
	match str(r["route"]):
		"chorus_arm":
			TribeChorus.arm()
			return true
		"chorus":
			TribeChorus.perform(text)
			return true
		"intel":
			return _do_intel(p, text)
		"order":
			return _do_order(p, text, source)
	return false          # "chat" -- hand it to the LLM

## Pure. What WOULD this text do? Returns {route: "chorus_arm"|"chorus"|"order"|
## "intel"|"chat", goal: String, parse: Dictionary}
##
## ORDER OF CHECKS IS THE DESIGN -- each is only correct because the ones above
## it ran first. Extracted from try_execute SO IT CAN BE TESTED: the interesting
## failures here are routing decisions ("did that dispatch a work party when I
## meant to cheer?"), and those are invisible to a parse()-only test.
func route(text: String, roster_override: Array = []) -> Dictionary:
	var low: String = " " + text.to_lower().replace(",", " ").replace("!", " ") + " "
	var p: Dictionary = parse(text, roster_override)
	var out: Dictionary = {"route": "chat", "goal": "", "parse": p}

	# 1. "everybody repeat after me" -- arm and wait for the next thing you say.
	if TribeChorus.is_arm_phrase(low):
		out["route"] = "chorus_arm"
		return out

	var goal: String = TribeChorus.classify_goal(text)
	var rally: bool = TribeChorus.is_rally(low)
	out["goal"] = goal

	# 2. A RALLYING CRY OUTRANKS AN ORDER -- the whole "let's" distinction.
	#      "Ka, go hunt"            -> Ka goes hunting          (an order)
	#      "everyone, let's hunt!"  -> the camp shouts about it  (a cry)
	#    Without this, every "let's" sentence would silently dispatch a work
	#    party, because "hunt" is a real verb and parse() matches it happily.
	if rally and goal != "":
		out["route"] = "chorus"
		return out

	# 3. Group + goal + NO order verb -> a cry. Catches "everyone, war cry!",
	#    which has no verb to dispatch and nothing else it could be.
	if goal != "" and bool(p["group"]) and str(p["mode"]) != "order":
		out["route"] = "chorus"
		return out

	out["route"] = str(p["mode"])
	return out

## Pure function -- no side effects, so it can be tested without a game running.
## `roster_override` exists SO THAT IT CAN BE: with it, test_command_parser.gd
## drives real sentences through this headlessly and asserts what fires and (more
## importantly) what does NOT. A parser guarding an always-on mic should not be
## taken on trust. Empty = ask the live scene tree, which is what the game does.
## Returns {mode: "order"|"intel"|"chat", names: Array, verb: String, group: bool,
##          nearby: bool}
func parse(text: String, roster_override: Array = []) -> Dictionary:
	var low: String = " " + text.to_lower().replace(",", " ").replace("?", " ") \
		.replace("!", " ").replace(".", " ") + " "
	var out: Dictionary = {"mode": "chat", "names": [], "verb": "",
		"group": false, "nearby": false, "implicit": false}

	# --- who is being addressed? ---
	var group := false
	for g in GROUP_WORDS:
		if (" " + str(g) + " ") in low:
			group = true
			break
	var nearby := false
	for n in NEARBY_WORDS:
		if (" " + str(n) + " ") in low:
			nearby = true
			break
	var names: Array = _find_names(low, roster_override)
	out["names"] = names
	out["group"] = group
	out["nearby"] = nearby

	# --- is this a question to a specific member about gossip? ---
	for q in INTEL_WORDS:
		if q in low:
			# an intel question needs someone to ask; nearest member if unnamed
			out["mode"] = "intel"
			return out

	# Nobody named and no group -> normally conversation. BUT a bare imperative
	# ("go get berries") is aimed at whoever you're standing in front of, and
	# word order is what tells us so -- see IMPERATIVE_STARTS.
	if not group and names.is_empty():
		if not _is_imperative(text):
			return out        # nobody addressed -> conversation
		out["implicit"] = true

	# --- what are they being told to do? ---
	var verb: String = _find_verb(low)
	if verb == "":
		return out            # addressed but no known task -> conversation
	out["verb"] = verb
	out["mode"] = "order"
	return out

## Looked up through the tree rather than naming the TribeTalk singleton directly.
## Referencing an autoload by name is a COMPILE-TIME dependency in GDScript: it
## makes this whole script fail to compile anywhere the autoloads aren't
## registered, which is exactly where a test harness lives. Resolving it at
## runtime keeps parse() testable and degrades to "no names" instead of crashing.
func _live_roster() -> Array:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return []
	var tt := tree.root.get_node_or_null("TribeTalk")
	if tt == null or not tt.has_method("roster_names"):
		return []
	return tt.roster_names()

## Does this sentence OPEN with a command verb? Checked against the raw text's
## first word, not anywhere in it -- "go" mid-sentence ("I'm going to go get
## berries") is describing, not ordering. Position is the whole signal.
func _is_imperative(text: String) -> bool:
	var s: String = text.strip_edges().to_lower().replace("?", "")
	if s == "":
		return false
	if _starts_with_verb(s):
		return true

	# POLITE REQUESTS ARE ORDERS. "can u go get berries for me" got a chat reply
	# and Ka never moved -- because it opens with "can", which SENTENCE_STARTERS
	# protects (for "the hunt went badly"). But "can you <VERB>" is a command
	# dressed in manners, and that's how people actually give them. The tell is a
	# real command verb AFTER the polite frame:
	#     "can you go get berries"  -> strip "can you" -> "go..." -> ORDER
	#     "do you trust me"         -> strip "do you"  -> "trust" isn't a verb we
	#                                  obey -> stays a question. Correct.
	# So this only fires when there's an obeyable verb behind the politeness --
	# it can't turn a genuine question into an order. ("u" = "you", from STT.)
	for pfx in ["can you ", "can u ", "could you ", "could u ", "would you ",
			"would u ", "will you ", "will u ", "can somebody ", "can someone ",
			"i need you to ", "i want you to "]:
		if s.begins_with(pfx) and _starts_with_verb(s.substr(pfx.length()).strip_edges()):
			return true

	# STRIP ONE LEADING JUNK WORD AND RE-CHECK.
	#
	# Speech-to-text mangles the word before the verb constantly -- observed live,
	# all meaning "go get berries":
	#     "call go get berries"    ("Ka" -> "call")
	#     "Drew get berries"
	#     "Seth gay berries"
	# Each matched no name and no imperative, and died. One junk token in front of
	# a clean imperative shouldn't cost you the whole command.
	#
	# The guard is FUNCTION WORDS. A sentence that OPENS with one is describing,
	# not commanding, and must never be stripped into an order:
	#     "the hunt went badly"  -- strip "the" and "hunt went badly" reads as an
	#                               imperative. It isn't one. That's why "the" is
	#                               protected and "Drew" isn't.
	# So: a leading word we don't recognise as English scaffolding is probably a
	# mangled name, and what follows decides.
	var first: String = s.split(" ", false)[0]
	if SENTENCE_STARTERS.has(first):
		return false
	var rest: String = s.substr(first.length()).strip_edges()
	return _starts_with_verb(rest)

## Words that mark a DESCRIPTION rather than an order. If a sentence opens with
## one of these, it is never an imperative and its first word is never stripped.
const SENTENCE_STARTERS := ["the", "a", "an", "i", "i'm", "im", "ive", "i've",
	"we", "we're", "were", "they", "they're", "he", "she", "it", "it's", "its",
	"my", "our", "his", "her", "their", "this", "that", "these", "those",
	"there", "here", "what", "when", "where", "why", "how", "who", "if", "but",
	"so", "or", "is", "was", "are", "am", "do", "does", "did", "don't", "dont",
	"can", "could", "should", "would", "will", "won't", "wont", "maybe",
	"perhaps", "let's", "lets", "everyone", "everybody", "nobody", "someone",
	"yeah", "yes", "no", "not", "just", "still", "already", "about"]

## BUG FIXED (2026-07-17): every IMPERATIVE_STARTS entry has a trailing space
## ("investigate ") because the design assumed a verb is always followed by an
## object ("go get berries"). A bare single-word command with NOTHING after it
## ("can you investigate?" strips to just "investigate") could never match --
## "investigate".begins_with("investigate ") is false, the string is one
## character short of its own required prefix. Padding `s` with a trailing
## space before comparing fixes the single-word case for every verb in the
## list, not just the one that surfaced it, without changing behavior for the
## "verb + object" phrasing the list already handled correctly (appending a
## space to a longer string never changes whether it already started with a
## given prefix).
func _starts_with_verb(s: String) -> bool:
	var padded: String = s + " "
	for w in IMPERATIVE_STARTS:
		if padded.begins_with(str(w)):
			return true
	return false

## Whole-word verb lookup, LONGEST MATCH WINS.
##
## This used to return the first hit in dict order and that was a real bug:
## "everyone gather round" resolved to "gather" -- because the single word
## "gather" is declared before the phrase "gather round" -- and sent the whole
## camp off to pick berries instead of assembling on you. The exact opposite of
## the order given, and it PASSED a routing test that only asserted "order"
## without checking which one.
##
## Longest-match is the general rule that fixes the class: a more specific phrase
## always beats a shorter one it happens to contain, whatever order the table is
## written in. New overlapping verbs can't quietly reopen this.
func _find_verb(low: String) -> String:
	var best := ""
	var best_len := 0
	for kind in VERBS:
		for w in VERBS[kind]:
			var word: String = str(w)
			if word.length() > best_len and (" " + word + " ") in low:
				best = str(kind)
				best_len = word.length()
	return best

## Exact name first, then homophones, then fuzzy -- in that order of trust.
func _find_names(low: String, roster_override: Array = []) -> Array:
	var roster: Array = roster_override if not roster_override.is_empty() \
		else _live_roster()
	var found: Array = []
	var tokens: PackedStringArray = low.strip_edges().split(" ", false)

	for real in roster:
		var rn: String = str(real)
		var rl: String = rn.to_lower()
		if (" " + rl + " ") in low:
			if not found.has(rn):
				found.append(rn)
			continue
		# STOPWORDS guards this path too, not just the fuzzy one below: a
		# hand-written table is exactly where an everyday word slips in ("well"
		# -> Vel shipped and fired on "well I could hunt later"). Any path that
		# GUESSES at a name gets the same guard.
		var hits: Array = HOMOPHONES.get(rn, [])
		var matched := false
		for h in hits:
			var hw: String = str(h)
			if STOPWORDS.has(hw):
				continue
			if (" " + hw + " ") in low:
				matched = true
				break
		if matched:
			if not found.has(rn):
				found.append(rn)
			continue
		# LAST RESORT: fuzzy -- and only for names of 4+ characters.
		#
		# This floor was 3 and it was wrong. Measured, not guessed: the test corpus
		# caught "the hunt went badly yesterday" ordering WEN to hunt, because
		# "went" vs "wen" scores 0.8 on bigram similarity. (I had predicted the
		# risky word was "when" -- that one scores 0.4 and was never a problem. The
		# word that actually broke it wasn't one reasoning found.)
		#
		# The lesson generalises: on a 3-letter name a single changed character is
		# a THIRD of the word, so the similarity score carries almost no signal.
		# Short names get exact matching + HOMOPHONES, which are curated and can't
		# surprise us. STOPWORDS then guards the 4+ names against the same failure
		# as the roster grows.
		if rn.length() >= 4:
			for t in tokens:
				var tok: String = str(t)
				if tok.length() >= 4 and not STOPWORDS.has(tok) \
						and rl.similarity(tok) >= NAME_FUZZ:
					if not found.has(rn):
						found.append(rn)
					break
	return found

# ─────────────────────────────────────────────────────────────────────────────
# EXECUTION
# ─────────────────────────────────────────────────────────────────────────────
func _do_order(p: Dictionary, spoken: String, source: String) -> bool:
	var verb: String = str(p["verb"])
	var targets: Array = _resolve_targets(p)
	# Say out loud what we decided and who we found. "It doesn't work" is not a
	# debuggable report; "3 targets, 3 refused (busy)" is. Cheap -- once per order.
	print("[CMD] verb=%s names=%s group=%s nearby=%s -> %d target(s)" % [
		verb, p["names"], p["group"], p["nearby"], targets.size()])
	if targets.is_empty():
		_flash("Nobody close enough to hear that.")
		return true          # consumed: it WAS an order, there was just no one to take it

	var accepted: Array = []
	var refused: Array = []
	# DIRECTED weapon crafting bypasses give_order()/ORDER_RISK entirely --
	# not dangerous, same precedent this file's own comment gives for
	# build/carve (deliberately absent from ORDER_RISK too).
	var craft_tier: int = CRAFT_TIERS.get(verb, -1)
	for m in targets:
		if not is_instance_valid(m):
			continue
		var nm: String = str(m.get("member_name"))
		if craft_tier >= 0:
			if m.has_method("craft_weapon") and m.craft_weapon(craft_tier):
				accepted.append(nm)
			else:
				refused.append(nm)
			continue
		if not m.has_method("give_order"):
			continue
		# give_order() owns the refusal logic (loyalty + courage vs risk) and
		# already speaks the reason above their head. We only tally.
		# interrupt=true: you SAID this, to them, just now. It beats the chore they
		# picked for themselves -- see give_order. Loyalty still decides obedience.
		if m.give_order(verb, false, true):
			accepted.append(nm)
		else:
			refused.append(nm)
			# WHY they refused is the whole story -- busy vs loyalty are different
			# bugs with different fixes, and from outside they look identical.
			print("[CMD]   %s refused %s (rank=%s busy=%s)" % [
				nm, verb, m.get("current_rank"), m.get("is_busy")])

	var tag: String = "🎙" if source == "voice" else "💬"
	if accepted.is_empty():
		_flash("%s \"%s\" — %s refused." % [tag, spoken, _join(refused)])
	elif refused.is_empty():
		_flash("%s \"%s\" — %s → %s" % [tag, spoken, _join(accepted), verb])
	else:
		_flash("%s \"%s\" — %s → %s (%s refused)" % [
			tag, spoken, _join(accepted), verb, _join(refused)])

	# They remember being ordered about. A Wary member remembering that you only
	# ever speak to them to send them into the woods is a real thing later.
	for n in accepted:
		TribeMemory.remember(str(n), "ordered", "You",
			"You told me: \"%s\"" % spoken, "neutral", 0.0)
	for n in refused:
		TribeMemory.remember(str(n), "refused", "You",
			"You told me: \"%s\" -- I would not." % spoken, "wary", 0.0)

	order_issued.emit(accepted, verb, spoken)
	return true

func _resolve_targets(p: Dictionary) -> Array:
	var out: Array = []
	var names: Array = p["names"]
	if not names.is_empty():
		for m in _members():
			if names.has(str(m.get("member_name"))):
				out.append(m)
		return out
	# A bare imperative ("go get berries") is aimed at whoever you're standing in
	# front of. Range-gated on purpose: shouting an unaddressed order should not
	# reach someone across the camp who can't hear you and has no idea it was
	# meant for them.
	if bool(p.get("implicit", false)):
		var near := _nearest_member()
		if near != null:
			out.append(near)
		return out
	if not bool(p["group"]):
		return out
	# "everyone" -> whole tribe; "everyone AROUND ME" -> only those in earshot.
	if not bool(p["nearby"]):
		return _members()
	var pl := get_tree().get_first_node_in_group("player") as Node3D
	if pl == null:
		return _members()
	for m in _members():
		if pl.global_position.distance_to((m as Node3D).global_position) <= GROUP_RADIUS:
			out.append(m)
	return out

## group "tribe" also holds dogs -- only real members take orders
func _members() -> Array:
	var out: Array = []
	for m in get_tree().get_nodes_in_group("tribe"):
		if is_instance_valid(m) and m.has_method("give_order") and "member_name" in m:
			out.append(m)
	return out

# ─────────────────────────────────────────────────────────────────────────────
# COMPANION INTEL — your Companion reports what the gossip network carries.
#
# The Companion is members[0] with relationship 2.4 (Devoted), so unlike anyone
# else they tell you straight. What makes this real rather than flavour is that
# TribeRumor already tracks `hops` -- how many times a rumour has been retold.
# Hops IS reliability, measured, not invented: a 1-hop rumour came near enough
# first-hand, a 5-hop one has been through the LLM's paraphrase five times and
# has genuinely drifted. So the Companion can tell you HOW MUCH TO TRUST IT
# without any confidence number being made up for the occasion.
# ─────────────────────────────────────────────────────────────────────────────
func _do_intel(p: Dictionary, spoken: String) -> bool:
	var who: Node = null
	var names: Array = p["names"]
	if not names.is_empty():
		for m in _members():
			if names.has(str(m.get("member_name"))):
				who = m
				break
	if who == null:
		who = _nearest_member()
	if who == null:
		_flash("There's no one here to ask.")
		return true

	var npc: String = str(who.get("member_name"))
	var ids: Array = TribeRumor.knows.get(npc, [])
	if ids.is_empty():
		who.say("I've heard nothing worth repeating.", 4.0, true)
		return true

	# freshest first -- fewest hops = least drifted = most worth acting on
	var sorted: Array = ids.duplicate()
	sorted.sort_custom(func(a, b):
		return int(TribeRumor.rumors[a]["hops"]) < int(TribeRumor.rumors[b]["hops"]))

	var lines: Array[String] = []
	for id in sorted.slice(0, 3):
		var r: Dictionary = TribeRumor.rumors[id]
		lines.append("• \"%s\" (about %s — %s)" % [
			r["text"], r["subject"], _reliability(int(r["hops"]))])
	_flash("🗣 %s reports:\n%s" % [npc, "\n".join(lines)], 9.0)

	var top: Dictionary = TribeRumor.rumors[sorted[0]]
	# force: this is a direct answer to a direct question -- it must land.
	who.say("They're saying: \"%s\"" % top["text"], 6.0, true)
	TribeMemory.remember(npc, "reported", "You",
		"You asked me what I'd heard. I told you about %s." % top["subject"],
		"warm", 0.04)
	return true

## hops -> plain words. Not a made-up percentage; hops is a real counter.
func _reliability(hops: int) -> String:
	if hops <= 1:
		return "came to me straight, I'd believe it"
	elif hops <= 3:
		return "been passed around some"
	return "been round the whole camp, who knows what's left of it"

func _nearest_member() -> Node:
	var pl := get_tree().get_first_node_in_group("player") as Node3D
	if pl == null:
		return null
	var best: Node = null
	var bd := 10.0
	for m in _members():
		var d: float = pl.global_position.distance_to((m as Node3D).global_position)
		if d < bd:
			bd = d
			best = m
	return best

func _join(a: Array) -> String:
	var s: Array[String] = []
	for x in a:
		s.append(str(x))
	return ", ".join(s)

func _flash(t: String, dur: float = CONFIRM_HOLD) -> void:
	# Order results directed at the player's own tribe -> "Your Tribe" box.
	var mgr := get_tree().get_first_node_in_group("tribe_manager")
	if mgr and mgr.has_method("notify_cat"):
		mgr.notify_cat("tribe", t)
	elif mgr and mgr.has_method("_flash"):
		mgr._flash(t, dur)
	else:
		print("[CMD] " + t)
