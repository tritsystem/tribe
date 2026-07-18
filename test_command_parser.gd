extends Node
# Headless test for TribeCommand.parse(). Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path . res://test_command_parser.tscn --quit
#
# Runs as a SCENE, not --script, because GDScript resolves autoload names at
# COMPILE time: under --script there are no autoloads, so tribe_command.gd fails
# to compile before a single case runs. A scene loads them normally.
#
# The parser guards an ALWAYS-ON MICROPHONE. A false positive marches the camp
# off on a stray sentence, so the negative cases below are the point of this file
# -- they outnumber the positives deliberately. parse() is pure and takes a
# roster override, so none of this touches a real member.

const ROSTER := ["Ka", "Bo", "Tam", "Ru", "Sef", "Mok", "Wen", "Lir",
	"Dak", "Fenn", "Vel", "Orra", "Kin", "Zol", "Brae", "Cael", "Companion"]

var _pass := 0
var _fail := 0

func _ready() -> void:
	var C = TribeCommand

	print("\n=== SHOULD FIRE (orders) ===")
	_ck(C, "Ka, go get berries",                    "order", "gather", "Ka")
	_ck(C, "Bo go grab some wood",                  "order", "wood",   "Bo")
	_ck(C, "hey Tam, get some meat",                "order", "hunt",   "Tam")
	_ck(C, "Fenn go scout ahead",                   "order", "scout",  "Fenn")
	_ck(C, "hey everyone around me, get wood",      "order", "wood",   "")
	_ck(C, "everybody go gather berries",           "order", "gather", "")
	_ck(C, "Companion, go get some firewood",       "order", "wood",   "Companion")

	# POLITE REQUESTS — "can you go get berries" is a command in manners. This
	# EXACT phrasing failed in play: Ka gave a chat reply and never moved.
	print("\n=== SHOULD FIRE (polite requests) ===")
	_ck(C, "can u go get berries for me",           "order", "gather", "")
	_ck(C, "can you go get berries",                "order", "gather", "")
	_ck(C, "could you grab some wood",              "order", "wood",   "")
	_ck(C, "would you go hunt",                     "order", "hunt",   "")
	_ck(C, "i need you to go scout",                "order", "scout",  "")
	# ...but a polite frame with NO obeyable verb is still just a question
	_no(C, "do you trust me")
	_no(C, "can you swim")
	_no(C, "can I help you")

	print("\n=== SHOULD FIRE (mangled by speech-to-text) ===")
	_ck(C, "car go get berries",                    "order", "gather", "Ka")
	_ck(C, "rue grab some timber",                  "order", "wood",   "Ru")
	_ck(C, "mock go hunt a rabbit",                 "order", "hunt",   "Mok")
	_ck(C, "kale go scout",                         "order", "scout",  "Cael")

	# BARE IMPERATIVES — no name, no "everyone". Aimed at whoever you're stood
	# with. This is how people actually talk to one companion, and it's the
	# exact phrasing that failed in play ("go get berries" did nothing).
	print("\n=== SHOULD FIRE (bare imperative -> nearest member) ===")
	_ck(C, "go get berries",                        "order", "gather", "")
	_ck(C, "go grab some wood",                     "order", "wood",   "")
	_ck(C, "get some meat",                         "order", "hunt",   "")
	_ck(C, "go scout ahead",                        "order", "scout",  "")
	_ck(C, "hey go get berries",                    "order", "gather", "")
	_ck(C, "follow me",                             "order", "come",   "")
	_ck(C, "come here",                             "order", "come",   "")

	print("\n=== SHOULD FIRE (intel) ===")
	_ck(C, "Companion, what have you heard?",       "intel", "",       "Companion")
	_ck(C, "Ka any news?",                          "intel", "",       "Ka")
	_ck(C, "what are they saying?",                 "intel", "",       "")

	print("\n=== MUST NOT FIRE (this is the important half) ===")
	_no(C, "we should get some wood sometime")           # verb, no addressee
	_no(C, "I'm going to go get berries myself")         # verb, no addressee
	_no(C, "the hunt went badly yesterday")              # verb as a noun
	_no(C, "Ka, how are you feeling today")              # name, no verb
	_no(C, "Bo you look tired")                          # name, no verb
	_no(C, "everyone seems hungry")                      # group, no verb
	_no(C, "when we get wood we can build")              # "when" must not be Wen
	_no(C, "that tree over there is enormous")           # verb-word, no addressee

	# Short-name fuzzy collisions. "went"->Wen (sim 0.80) was a REAL failure this
	# corpus caught, not a hypothetical -- see the fuzzy floor in tribe_command.gd.
	# The rest are the same class, kept so a future roster can't reopen it.
	_no(C, "the hunt went badly yesterday")              # "went" is not Wen
	_no(C, "they went to gather already")                # "went" again, with a verb
	_no(C, "keep the wood by the fire")                  # "keep" is not Kin/Ka
	_no(C, "the king wants meat")                        # "king" is not Kin
	_no(C, "be kind and share the berries")              # "kind" is not Kin
	_no(C, "well I could hunt later")                    # "well" is not Vel
	_no(C, "take the logs over there")                   # "take" is not Tam/Dak
	# these were live homophone entries until this corpus caught them
	_no(C, "the duck got away")                          # a duck is prey, not Dak
	_no(C, "help yourself to the berries")               # "self" is not Sef
	# "go hunt..." IS an order now (bare imperative) -- this case's real point was
	# always that "duck" must not become the NAME Dak, so assert names are EMPTY
	# rather than that nothing fires. The old expectation predated imperatives.
	_ck(C, "go hunt the duck by the water",  "order", "hunt", "-")
	# NOTE: no "car"/"mock" negative here on purpose -- those ARE deliberate
	# homophones for Ka/Mok (see HOMOPHONES). Nobody says them at a campfire, and
	# asserting both directions at once is how I briefly broke the positives.
	_no(C, "the last part going good and on")            # the real misfire from before
	_no(C, "I think the raiders are coming")             # no addressee
	_no(C, "there's a rabbit over there")                # no addressee
	_no(C, "nice weather")                               # nothing at all
	_no(C, "yeah okay sounds good to me")                # ambient agreement

	# ── ROUTING: order vs cry vs chat. parse() alone can't see these; the
	# interesting failure is "did that dispatch a work party when I meant to
	# cheer?", which only route() decides.
	# WHICH order, not just "an order". Asserting route alone let a real bug
	# through: "everyone gather round" routed to "order" (pass!) while actually
	# resolving to verb=gather -- the whole camp sent to the berry bushes instead
	# of assembling. A test that only checks the category isn't checking much.
	print("\n=== ROUTE: come here (verb must be 'come', NOT 'gather') ===")
	_ck(C, "hey everyone come here",             "order", "come", "")
	_ck(C, "Ka come here",                       "order", "come", "Ka")
	_ck(C, "everyone gather round",              "order", "come", "")
	_ck(C, "everybody gather around",            "order", "come", "")
	_ck(C, "everyone over here",                 "order", "come", "")
	_ck(C, "Bo, to me",                          "order", "come", "Bo")
	_ck(C, "everyone form up",                   "order", "come", "")
	# ...and the plain gather order must still mean gather
	_ck(C, "everyone go gather berries",         "order", "gather", "")

	print("\n=== ROUTE: repeat after me / cries ===")
	_rt(C, "everybody repeat after me",          "chorus_arm")
	_rt(C, "hey everyone, say it with me",       "chorus_arm")
	_rt(C, "let's go raid!",                     "chorus")
	_rt(C, "everyone, war cry!",                 "chorus")
	_rt(C, "let's go hunt!",                     "chorus")
	_rt(C, "time to raid their camp",            "chorus")
	_rt(C, "let us defend the camp",             "chorus")

	print("\n=== ROUTE: 'let's' is load-bearing — same verb, different meaning ===")
	_rt(C, "Ka, go hunt",                        "order")     # an order
	_rt(C, "everyone, let's hunt!",              "chorus")    # a cry
	_rt(C, "everyone get wood",                  "order")     # still an order
	_rt(C, "everyone, let's get wood!",          "chorus")    # a cry

	print("\n=== ROUTE: must stay conversation ===")
	_rt(C, "the hunt went badly yesterday",      "chat")
	_rt(C, "we should get some wood sometime",   "chat")
	_rt(C, "I think the raiders are coming",     "chat")
	_rt(C, "nice weather",                       "chat")

	# TribeChorus.classify_goal() used to check "raid" as a raw SUBSTRING, not a
	# whole word -- so "raided"/"raiding" (containing "raid") both misclassified
	# as goal="raid". Inert alone (route() also needs group or rally before it
	# acts on a goal), but "everyone, are we getting raided?" hits group=true +
	# goal="raid" + no verb (a question) -- ALL of route()'s interception
	# conditions -- and the whole tribe choruses "Blood and bone!" at an anxious
	# question instead of answering it.
	print("\n=== ROUTE: 'raided' must not misfire as a raid cry ===")
	_rt(C, "are we gonna get raided",             "chat")
	_rt(C, "everyone, are we getting raided?",    "chat")
	_rt(C, "I hope we don't get raided tonight",  "chat")
	# and the real cries must still fire -- whole-word matching must not cost
	# the legitimate "-ing" phrasing along with the bug
	_rt(C, "let's go raiding!",                   "chorus")
	_rt(C, "everyone go hunting",                 "order")     # bare imperative, not a cry

	# "investigate" had no verb mapping at all -- "can you investigate?" fell
	# through to conversation instead of dispatching a scout order. Added as a
	# scout synonym in VERBS AND in IMPERATIVE_STARTS (parse() needs both: one
	# gates whether this counts as an imperative at all, the other maps it to
	# a real order kind). Surfaced a second, more general bug while fixing it:
	# every IMPERATIVE_STARTS entry has a trailing space (built for "verb +
	# object" phrasing like "go get berries"), so a BARE single-word command
	# with nothing following -- exactly what "can you investigate?" strips
	# down to -- could never match. Fixed for every verb in the list, not just
	# this one, by padding the compared string with a trailing space.
	print("\n=== ROUTE: 'investigate' as a scout synonym ===")
	_ck(C, "Ka, investigate the noise",           "order", "scout", "Ka")
	_ck(C, "investigate the noise",               "order", "scout", "-")
	# the bare single-word case that exposed the trailing-space bug
	_ck(C, "can you investigate",                 "order", "scout", "-")
	_ck(C, "can you investigate?",                "order", "scout", "-")
	_ck(C, "investigate",                         "order", "scout", "-")
	# and existing bare single-word imperatives must keep working too --
	# nothing regressed by the trailing-space fix
	_ck(C, "come",                                "order", "come",  "-")
	_ck(C, "scout",                               "order", "scout", "-")

	# DIRECTED weapon crafting: an explicit choice ("Ka, craft a spear")
	# instead of tribemember.gd's random automatic gear upgrade. Multi-word
	# phrases only, deliberately -- a bare "spear"/"bow"/"axe" trigger is
	# exactly the single-common-word risk this parser's own STOPWORDS
	# discipline exists to guard against.
	print("\n=== ROUTE: directed weapon crafting ===")
	_ck(C, "Ka, craft a spear",                   "order", "craft_spear", "Ka")
	_ck(C, "carve a spear",                       "order", "craft_spear", "-")
	_ck(C, "forge a bow",                         "order", "craft_bow",   "-")
	_ck(C, "make an axe",                         "order", "craft_axe",   "-")
	_ck(C, "craft a club",                        "order", "craft_club",  "-")
	# a bare "spear"/"bow"/"axe" alone must NOT fire -- no verb-shaped
	# phrase, just a noun, same discipline as "there's a rabbit over there"
	# staying conversation
	_no(C, "I found a spear")
	_no(C, "nice bow")

	# "here" = WHERE, "around me" = WHO. These two sentences read almost the same
	# and mean different things; nearby=true on a summons silently shrinks it to
	# people already standing next to you.
	print("\n=== 'here' is a destination, 'around me' is a filter ===")
	_nb(C, "everyone come here",            false)   # summon the WHOLE tribe
	_nb(C, "everybody come here",           false)
	_nb(C, "hey everyone around me get wood", true)  # only those in earshot
	_nb(C, "everyone near me, go hunt",     true)

	print("\n──────────────────────────────────────────")
	print("  %d passed, %d FAILED" % [_pass, _fail])
	print("──────────────────────────────────────────\n")
	get_tree().quit(1 if _fail > 0 else 0)

func _ck(C, text: String, mode: String, verb: String, name_has: String) -> void:
	var p: Dictionary = C.parse(text, ROSTER)
	var ok: bool = str(p["mode"]) == mode
	if verb != "" and str(p["verb"]) != verb:
		ok = false
	# "-" means "no name may be matched at all" -- for cases where a common word
	# must NOT be mistaken for a member (duck != Dak) even though the sentence
	# legitimately is an order.
	if name_has == "-":
		if not (p["names"] as Array).is_empty():
			ok = false
	elif name_has != "" and not (p["names"] as Array).has(name_has):
		ok = false
	_report(ok, text, p, "%s/%s/%s" % [mode, verb, name_has])

func _no(C, text: String) -> void:
	var p: Dictionary = C.parse(text, ROSTER)
	_report(str(p["mode"]) == "chat", text, p, "chat")

func _rt(C, text: String, want: String) -> void:
	var r: Dictionary = C.route(text, ROSTER)
	var got: String = str(r["route"])
	if got == want:
		_pass += 1
		print("  ok    %-11s \"%s\"" % [got, text])
	else:
		_fail += 1
		print("  FAIL  \"%s\"\n          want route=%s  got route=%s goal=%s verb=%s names=%s" % [
			text, want, got, r["goal"], (r["parse"] as Dictionary)["verb"],
			(r["parse"] as Dictionary)["names"]])

func _nb(C, text: String, want_nearby: bool) -> void:
	var p: Dictionary = C.parse(text, ROSTER)
	var got: bool = bool(p["nearby"])
	if got == want_nearby:
		_pass += 1
		print("  ok    nearby=%-5s \"%s\"" % [got, text])
	else:
		_fail += 1
		print("  FAIL  \"%s\"\n          want nearby=%s got nearby=%s" % [text, want_nearby, got])

func _report(ok: bool, text: String, p: Dictionary, want: String) -> void:
	if ok:
		_pass += 1
		print("  ok    \"%s\"" % text)
	else:
		_fail += 1
		print("  FAIL  \"%s\"\n          want %s  got mode=%s verb=%s names=%s" % [
			text, want, p["mode"], p["verb"], p["names"]])
