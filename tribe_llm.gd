extends Node
# ─────────────────────────────────────────────────────────────────────────────
# TribeLLM — async local-LLM voice for NPCs, via Ollama.
# Autoload singleton: TribeLLM
#
# MODEL CHOICE (grounded, not assumed): checked what's actually installed --
# llama3.2 (2.0GB) is the smallest GENERATIVE model present, so it's the lowest
# latency. deepseek-r1 are reasoning models (way too slow to speak in real time)
# and qwen2.5-coder is for code. If llama3.2 is missing we degrade to canned
# lines rather than hanging the sim.
#
# PERFORMANCE (hard-won lessons in this repo):
#   * HTTPRequest is ASYNC -- never block a frame waiting on a token.
#   * ONE request in flight at a time, globally. 10 NPCs each firing a 2GB model
#     would thrash the machine that just had framerate trouble.
#   * A queue with a max depth; overflow DROPS rather than piles up latency.
#   * Every call has a timeout and a canned fallback, so a dead Ollama degrades
#     the flavour, not the simulation.
# ─────────────────────────────────────────────────────────────────────────────

# 127.0.0.1, NOT "localhost" -- ON THIS MACHINE localhost RESOLVES TO ::1 (IPv6)
# while Ollama binds 127.0.0.1 (IPv4). curl/python silently fall back to IPv4 and
# hide this; Godot's HTTPRequest does NOT, so the warmup hit a refused connection,
# flipped available=false, and EVERY npc line silently fell back to a canned one.
# (Measured: `ping localhost` -> [::1]; /api/ps showed llama3.2 loaded and healthy
# the whole time. The model was never the problem -- the address was.)
# NAME THE HOLES, DON'T PLEAD FOR ACCURACY.
#
# The prompt already said "don't invent history" and the model cheerfully ignored
# it. Measured, in play: Mok said "I was talking with Ka the other day and they
# said it would RAIN today". There is no weather in this codebase, no day/night
# cycle, no calendar -- checked the groups and every script. Mok invented an
# entire climate out of nothing.
#
# This is the same shape as the name problem and it takes the same fix. The model
# isn't confabulating freely; it's filling holes in the world it was handed. Told
# only "you are in a stone-age tribe" it reaches for what stone-age stories
# contain -- weather, seasons, yesterday. Handing it the roster killed the
# name-shaped holes ("Leader Kanaq", "Zog"). Handing it the world's real contents
# kills the world-shaped ones. Asking a 3B model to be careful does nothing;
# removing the hole does.
#
# Cheap: static text in a prompt already being sent. A verification pass would
# double the measured 2.5-4.2s latency on every single line.
const WORLD := """
This world contains ONLY: berry bushes/herbs/roots/mushrooms/nuts/grain,
trees to chop, ore/stone/gems/coal/clay/sand to mine, animals to hunt, carved
clubs and crafted weapons/armor, teepees, a stockpile of food, a trading
post (if one has been built), a blacksmith's forge (in a Crafting
settlement), a real campfire at camp, dogs, rival tribes who raid and
trade, hunger, and the Leader (the player).
There IS a day/night cycle now. At night the tribe gathers at the real
campfire to gossip, laugh, and dance -- you may mention this if it fits.
It has NO weather beyond rain/storm/fog/clear (no seasons, no calendar).
Never mention "today", "yesterday", "tomorrow", "the other day", or any
event that is not in your memories below. If you have no memory of
something, do not invent one -- say you don't know, or speak about what
you DO remember. Only mention a building or landmark if it is listed here
as existing, or you have a real memory of it below -- never invent one.
"""

const OLLAMA_URL := "http://127.0.0.1:11434/api/generate"
const MODEL := "llama3.2"          # verified installed; NOT gemma3:1b (not present)
# MEASURED, not guessed: cold start (Ollama loading the 2GB model) took >60s and
# blew a 60s test timeout. WARM calls with the real NPC prompt: 2.5-4.2s.
# So we PRE-WARM at startup with a long leash, then hold gameplay calls to a
# short one. A long gameplay timeout would be worse than useless -- it'd hang an
# NPC mid-conversation for a minute instead of just falling back to a canned line.
const TIMEOUT := 15.0              # warm calls (2.5-4.2s measured -> comfortable margin)
const WARMUP_TIMEOUT := 180.0      # cold model load; one-off at startup
const MAX_QUEUE := 4               # overflow is dropped -- stale NPC chatter is worthless
const MAX_TOKENS := 60             # NPCs speak in one or two lines, not essays

signal line_ready(speaker: String, listener: String, text: String, tag: String)

var _http: HTTPRequest
var _busy := false
var _queue: Array = []             # [{speaker, listener, prompt, tag, fallback}]
var _current: Dictionary = {}
var _elapsed := 0.0
var available := true              # flipped false if Ollama errors out
var warm := false                  # model loaded? until then, NPCs use fallbacks
var _warming := false

# HYSTERESIS QUEUE GATE (2026-07-19): the queue-backlog check below used to
# be a single flat threshold (_queue.size() >= MAX_QUEUE). The queue fills
# and drains constantly as NPCs talk -- sitting right at that boundary, an
# ongoing conversation could flip between real LLM lines and canned
# fallbacks mid-exchange for no real reason (one line queued vs one line
# just popped). Real dual-threshold hysteresis fixes this the same way it
# stabilizes Project Thought's brain sandbox: once the queue is genuinely
# backed up (>=85% full), stay in fallback mode until it's genuinely
# drained (<=25% full), not just one line under the cap.
const HysteresisGateScript = preload("res://hysteresis_gate.gd")
var _queue_gate: HysteresisGate

func _ready() -> void:
	_http = HTTPRequest.new()
	add_child(_http)
	_http.request_completed.connect(_on_done)
	_queue_gate = HysteresisGateScript.new(0.25, 0.85)
	_warmup()
	set_process(true)

## True if the queue is genuinely backed up right now -- hysteresis-gated so
## draining by one line right at the cap doesn't immediately let a new call
## back in, only to hit the cap again a moment later.
func _queue_backed_up() -> bool:
	var load: float = float(_queue.size()) / float(MAX_QUEUE)
	return _queue_gate.update(load)

## Load the model NOW with a long leash, so no NPC ever eats the cold-start cost.
## Until this lands, say_as() returns canned lines -- the camp murmurs from the
## first second and simply gets more articulate once the model is resident.
func _warmup() -> void:
	_warming = true
	_busy = true
	_http.timeout = WARMUP_TIMEOUT
	var body := JSON.stringify({
		"model": MODEL, "prompt": "hi", "stream": false,
		"options": {"num_predict": 1},
	})
	var err := _http.request(OLLAMA_URL, ["Content-Type: application/json"],
		HTTPClient.METHOD_POST, body)
	if err != OK:
		_warming = false
		_busy = false
		available = false
		push_warning("TribeLLM: Ollama unreachable -- NPCs will use canned lines")

func _process(delta: float) -> void:
	if _busy:
		_elapsed += delta
		return
	if _queue.is_empty():
		return
	_send(_queue.pop_front())

## Ask an NPC to say something. Returns immediately; listen for `line_ready`.
## `fallback` is used verbatim if the LLM is unavailable or too slow -- the sim
## must keep talking even with Ollama off.
func say_as(speaker: String, listener: String, persona: String, memories: String,
		situation: String, fallback: String, tag: String = "chat", roster: String = "") -> void:
	# not warm yet (model still loading) or backed up -> speak a canned line NOW
	# rather than queue latency. An NPC saying something plain beats an NPC
	# standing mute for a minute waiting on a cold model.
	if not available or not warm or _queue_backed_up():
		line_ready.emit(speaker, listener, fallback, tag)
		return
	# ROSTER: the measured hallucinations were name-SHAPED -- "Leader Kanaq",
	# "Zog did good work today". The model wasn't confabulating freely, it was
	# filling name-shaped holes. Handing it the real cast removes the hole.
	# Cheaper and more targeted than a verification pass, which would double the
	# measured 2.5-4.2s latency for every line.
	var who := ""
	if roster != "":
		who = "\nThe only people who exist are: %s. NEVER use a name that is not in that list.\n" % roster
	var prompt := """You are %s, a member of a stone-age tribe. %s
%s%s
What you remember (this is your ACTUAL past -- speak from it, don't invent history):
%s

Situation: %s

Reply as %s in ONE short spoken line (max 20 words). Plain speech, no quotes, no
narration, no asterisks. If a memory above is relevant, let it colour what you say.""" % [
		speaker, persona, who, WORLD, memories, situation, speaker]
	_queue.append({"speaker": speaker, "listener": listener, "prompt": prompt,
		"tag": tag, "fallback": fallback})

const POEM_MAX_TOKENS := 120   # a short verse needs more room than a single spoken line

## Ask an NPC to COMPOSE a short poem or song (not just speak a line) --
## grounded the same way say_as() is (real memories, the same world-contents
## guardrail against inventing weather/history), but with room for a few
## lines of verse instead of one sentence, and told explicitly whether to
## write a poem or a song so the shape of what comes back actually varies.
func compose_as(speaker: String, persona: String, memories: String, situation: String,
		form: String, fallback: String, tag: String = "compose") -> void:
	if not available or not warm or _queue_backed_up():
		line_ready.emit(speaker, speaker, fallback, tag)
		return
	var prompt := """You are %s, a member of a stone-age tribe. %s
%s
What you remember (this is your ACTUAL past -- draw on it, don't invent history):
%s

%s

Write a short %s (3-5 lines) as %s, in your own voice and personality. Plain
text, no quotes, no title, no narration, no asterisks. Base it on what you
actually remember and what's happening right now -- not invented events.""" % [
		speaker, persona, WORLD, memories, situation, form, speaker]
	_queue.append({"speaker": speaker, "listener": speaker, "prompt": prompt,
		"tag": tag, "fallback": fallback, "max_tokens": POEM_MAX_TOKENS})

func _send(job: Dictionary) -> void:
	_busy = true
	_elapsed = 0.0
	_current = job
	var body := JSON.stringify({
		"model": MODEL,
		"prompt": job["prompt"],
		"stream": false,
		"options": {"num_predict": int(job.get("max_tokens", MAX_TOKENS)), "temperature": 0.8},
	})
	var err := _http.request(OLLAMA_URL, ["Content-Type: application/json"],
		HTTPClient.METHOD_POST, body)
	if err != OK:
		_fail("request error %d" % err)

func _on_done(_result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	# the startup warmup shares this callback -- it is NOT an NPC line, so it must
	# never reach line_ready or it'd put "hi" above someone's head
	if _warming:
		_warming = false
		_busy = false
		_http.timeout = TIMEOUT        # back to the short gameplay leash
		warm = (code == 200)
		available = warm
		print("[TribeLLM] model '%s' %s" % [MODEL,
			"warm -- NPCs will speak via the LLM" if warm else "unavailable (HTTP %d) -- canned lines" % code])
		return
	if code != 200:
		_fail("HTTP %d" % code)
		return
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("response"):
		_fail("bad payload")
		return
	var text: String = str(parsed["response"]).strip_edges()
	# the model sometimes wraps the line in quotes or adds a name prefix -- strip it.
	# NOTE explicit String types here: _current is an untyped Dictionary, so
	# indexing it yields a Variant and `:=` would refuse to infer (see the
	# gdscript-type-inference lesson -- this exact trap broke a build already).
	text = text.trim_prefix("\"").trim_suffix("\"").strip_edges()
	var pre: String = str(_current["speaker"]) + ":"
	if text.begins_with(pre):
		text = text.substr(pre.length()).strip_edges()
	if text == "":
		text = str(_current["fallback"])
	line_ready.emit(str(_current["speaker"]), str(_current["listener"]), text, str(_current["tag"]))
	_busy = false
	_current = {}

func _fail(reason: String) -> void:
	push_warning("TribeLLM unavailable (%s) -- falling back to canned lines" % reason)
	if not _current.is_empty():
		line_ready.emit(str(_current["speaker"]), str(_current["listener"]),
			str(_current["fallback"]), str(_current["tag"]))
	# one hard failure disables the LLM for the session rather than stuttering on
	# every single line; the sim keeps running on fallbacks.
	if reason.begins_with("HTTP") or reason.begins_with("request error"):
		available = false
	_busy = false
	_current = {}
