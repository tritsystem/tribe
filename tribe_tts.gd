extends Node
# ─────────────────────────────────────────────────────────────────────────────
# TribeTTS — your tribe out loud. Autoload singleton: TribeTTS
#
# Godot has TTS built in (DisplayServer.tts_*). On Windows it drives the OS SAPI
# voices, so this is LOCAL and OFFLINE with nothing to install -- unlike the mic
# side, which currently uploads audio to Google. Nothing here leaves the machine.
#
# MEASURED ON THIS MACHINE (2026-07-15):
#   SAPI voices : Microsoft David Desktop (en-US), Microsoft Zira Desktop (en-US)
#   Godot needs `audio/general/text_to_speech=true` -- it is OFF by default and
#   tts_get_voices() returns [] SILENTLY until you set it. No error, no warning.
#   --headless ALSO returns [] (the dummy DisplayServer has no speech), so this
#   cannot be verified from a headless run. It has to be heard.
#
# THE CONSTRAINT THAT SHAPES THIS WHOLE FILE:
#   SAPI HAS ONE CHANNEL. Utterances QUEUE; they do not overlap. Ten members
#   shouting a war cry is not a roar -- it's ten lines played one after another
#   for half a minute, with the last one arriving long after the moment has gone.
#   So we DROP rather than queue: if a voice is busy, the line stays text-only
#   above the speaker's head. Overlapping dialogue is bad in games anyway; a
#   backlog of stale dialogue is worse. Only TWO voices exist, so a "chorus"
#   of distinct speakers is a fiction we don't attempt: the chorus is CARRIED BY
#   THE TEXT (everyone shouts) and only a couple of voices actually sound.
# ─────────────────────────────────────────────────────────────────────────────

const HEAR_RADIUS := 18.0      # beyond this you don't hear them at all
const CLOSE_RADIUS := 6.0      # inside this it's full volume
const MAX_CHARS := 180         # don't let the LLM monologue at you
const MIN_GAP := 0.25          # floor between utterances

var enabled := true
var available := false

var _voices: Array = []        # voice ids, en first
var _gap := 0.0

func _ready() -> void:
	_voices = DisplayServer.tts_get_voices_for_language("en")
	if _voices.is_empty():
		# fall back to whatever exists rather than going mute in another locale
		for v in DisplayServer.tts_get_voices():
			if v is Dictionary and v.has("id"):
				_voices.append(v["id"])
	available = not _voices.is_empty()
	if available:
		print("[TTS] %d voice(s) ready: %s" % [_voices.size(), ", ".join(_short_names())])
	else:
		push_warning("[TTS] no voices -- is audio/general/text_to_speech=true? "
			+ "(also always empty under --headless)")
	set_process(true)

func _short_names() -> Array[String]:
	var out: Array[String] = []
	for v in DisplayServer.tts_get_voices():
		if v is Dictionary and v.has("name"):
			out.append(str(v["name"]))
	return out

func _process(delta: float) -> void:
	_gap = maxf(0.0, _gap - delta)

## Speak `text` as `who` (a member Node3D), if the player is close enough to hear.
## Returns true if it actually sounded -- callers use that only for debug; the
## line is ALWAYS shown above the head regardless, so a dropped voice line is a
## quieter camp, never a lost one.
func speak(who: Node, text: String, force: bool = false) -> bool:
	if not (enabled and available) or text.strip_edges() == "":
		return false
	var pl := get_tree().get_first_node_in_group("player") as Node3D
	if pl == null or not (who is Node3D):
		return false
	var d: float = pl.global_position.distance_to((who as Node3D).global_position)
	if d > HEAR_RADIUS:
		return false                       # too far to hear -- not a failure

	# ONE CHANNEL: drop instead of queueing (see header). `force` is for lines
	# that must land -- your Companion answering a direct question, mainly.
	if not force and (_gap > 0.0 or DisplayServer.tts_is_speaking()):
		return false
	if force:
		DisplayServer.tts_stop()

	var clean := _clean(text)
	if clean == "":
		return false
	_gap = MIN_GAP
	DisplayServer.tts_speak(clean, _voice_for(who), _volume(d), _pitch_for(who),
		_rate_for(who), 0, true if force else false)
	return true

## Stable per-member voice: same member always sounds the same. Only two SAPI
## voices exist here (one male, one female), so PITCH does most of the work of
## telling people apart -- hashed off the name so it never drifts between runs.
func _voice_for(who: Node) -> String:
	if _voices.is_empty():
		return ""
	var h: int = abs(str(who.get("member_name")).hash())
	return str(_voices[h % _voices.size()])

func _pitch_for(who: Node) -> float:
	var h: int = abs(str(who.get("member_name")).hash())
	return 0.82 + float((h / 7) % 36) / 100.0        # 0.82 .. 1.17

func _rate_for(who: Node) -> float:
	var h: int = abs(str(who.get("member_name")).hash())
	var base: float = 0.95 + float((h / 13) % 20) / 100.0   # 0.95 .. 1.14
	# Brave/Greedy talk faster, Wary drags -- personality you can HEAR
	match str(who.get("personality")):
		"Brave":  return base + 0.12
		"Greedy": return base + 0.06
		"Wary":   return base - 0.10
		_:        return base

## Falls off with distance so a shout across camp reads as distant.
func _volume(d: float) -> int:
	if d <= CLOSE_RADIUS:
		return 60
	var t: float = clampf((d - CLOSE_RADIUS) / (HEAR_RADIUS - CLOSE_RADIUS), 0.0, 1.0)
	return int(lerpf(60.0, 12.0, t))

## BBCode and stage directions would be read out literally ("asterisk grins
## asterisk"), which is exactly the kind of thing that only shows up once you
## actually listen to it.
func _clean(t: String) -> String:
	var s := t.strip_edges()
	var re := RegEx.new()
	re.compile("\\[/?[^\\]]+\\]")        # [color=...] ... [/color]
	s = re.sub(s, "", true)
	re.compile("\\*[^*]*\\*")            # *shrugs*
	s = re.sub(s, "", true)
	s = s.replace("\"", "").replace("—", ", ").replace("…", ".")
	s = s.strip_edges()
	if s.length() > MAX_CHARS:
		s = s.substr(0, MAX_CHARS) + "."
	return s

func stop() -> void:
	if available:
		DisplayServer.tts_stop()
