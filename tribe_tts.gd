extends Node
# ─────────────────────────────────────────────────────────────────────────────
# TribeTTS — your tribe out loud. Autoload singleton: TribeTTS
#
# REPLACED (2026-07-28): was Windows SAPI via DisplayServer.tts_speak() (David/
# Zira -- robotic). Swapped to Piper (github.com/rhasspy/piper), a local neural
# TTS engine -- genuinely more natural-sounding, still fully offline, nothing
# leaves the machine, same as SAPI was. Bundled at res://piper/piper.exe with
# two voice models (res://piper/voices/en_US-{amy,ryan}-medium.onnx) -- amy is
# the "female" slot, ryan the "male" slot, same two-voice-pool shape SAPI had.
#
# Piper has no equivalent to SAPI's `pitch` argument, so per-NPC pitch
# variation now happens at PLAYBACK time via AudioStreamPlayer3D.pitch_scale
# instead of being baked into the synthesis call. Rate DOES have a real
# synthesis-time knob (--length_scale, inverse of speed), so personality-based
# pace still happens the "real" way, same as before.
#
# THE CONSTRAINT THAT SHAPES THIS WHOLE FILE (unchanged from the SAPI version):
#   Only ONE utterance plays at a time. Ten members shouting a war cry is not a
#   roar -- it's ten lines played one after another for half a minute, with the
#   last one arriving long after the moment has gone. So we DROP rather than
#   queue: if a voice is busy, the line stays text-only above the speaker's
#   head. Overlapping dialogue is bad in games anyway; a backlog of stale
#   dialogue is worse.
#
# THREADING: piper.exe synthesis is fast (~0.1-0.3s measured for a line) but
# still too slow to call synchronously without a frame hitch, so each speak()
# spawns a Thread that shells out to piper.exe, writes a WAV to a per-call temp
# file, then hands playback back to the main thread via call_deferred. A
# `_request_id` guards against a stale/cancelled synthesis (e.g. a `force`
# line interrupting one already in flight) landing late and playing anyway.
# ─────────────────────────────────────────────────────────────────────────────

const HEAR_RADIUS := 18.0      # beyond this you don't hear them at all
const CLOSE_RADIUS := 6.0      # inside this it's full volume
const MAX_CHARS := 180         # don't let the LLM monologue at you
const MIN_GAP := 0.25          # floor between utterances

const PIPER_EXE_REL := "piper/piper.exe"              # relative to project root (needs a real OS path, not res://, to exec)
const PIPER_VOICE_FEMALE := "res://piper/voices/en_US-amy-medium.onnx"
const PIPER_VOICE_MALE   := "res://piper/voices/en_US-ryan-medium.onnx"
const TEMP_SUBDIR := "tts_tmp"

var enabled := true
var available := false

var _gap := 0.0
var _busy := false
var _request_id := 0
var _player: AudioStreamPlayer3D
var _piper_exe_path: String = ""
var _voice_female_path: String = ""
var _voice_male_path: String = ""
var _temp_dir_path: String = ""

func _ready() -> void:
	# ProjectSettings.globalize_path turns res://piper/piper.exe into a real
	# OS filesystem path -- OS.execute can't run a res:// URI directly.
	_piper_exe_path   = ProjectSettings.globalize_path("res://" + PIPER_EXE_REL)
	_voice_female_path = ProjectSettings.globalize_path(PIPER_VOICE_FEMALE)
	_voice_male_path   = ProjectSettings.globalize_path(PIPER_VOICE_MALE)

	var udir := DirAccess.open("user://")
	if udir and not udir.dir_exists(TEMP_SUBDIR):
		udir.make_dir(TEMP_SUBDIR)
	_temp_dir_path = ProjectSettings.globalize_path("user://" + TEMP_SUBDIR)

	available = FileAccess.file_exists("res://" + PIPER_EXE_REL) \
		and FileAccess.file_exists(PIPER_VOICE_FEMALE) \
		and FileAccess.file_exists(PIPER_VOICE_MALE)
	if available:
		print("[TTS] Piper ready (2 voices: amy/female, ryan/male)")
	else:
		push_warning("[TTS] Piper engine/voices not found under res://piper/ -- staying silent (text still shows)")

	_player = AudioStreamPlayer3D.new()
	_player.name = "PiperVoice"
	_player.max_distance = HEAR_RADIUS
	_player.unit_size = 1.0
	add_child(_player)
	_player.finished.connect(_on_playback_finished)
	set_process(true)

func _process(delta: float) -> void:
	_gap = maxf(0.0, _gap - delta)

## Speak `text` as `who` (a member Node3D), if the player is close enough to hear.
## Returns true if it actually STARTED synthesizing -- callers use that only for
## debug; the line is ALWAYS shown above the head regardless, so a dropped
## voice line is a quieter camp, never a lost one.
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
	if not force and (_gap > 0.0 or _busy):
		return false
	if force and _busy:
		_player.stop()
		_busy = false

	var clean := _clean(text)
	if clean == "":
		return false
	_gap = MIN_GAP
	_busy = true
	_request_id += 1
	var my_id := _request_id

	_player.global_position = (who as Node3D).global_position
	_player.volume_db = _volume_db(d)
	_player.pitch_scale = _pitch_for(who)

	var voice_path := _voice_path_for(who)
	var length_scale := 1.0 / _rate_for(who)   # piper's knob is INVERSE speed
	var out_wav := _temp_dir_path.path_join("line_%d.wav" % my_id)

	var t := Thread.new()
	t.start(_synthesize_worker.bind(clean, voice_path, length_scale, out_wav, my_id, t))
	return true

## Runs OFF the main thread. Shells to piper.exe (text via stdin -- it has no
## --input_file flag, only stdin or --output_raw). Goes through PowerShell's
## `Get-Content | & "exe"` rather than cmd.exe's `type | "exe"` -- TESTED
## directly (2026-07-28): cmd.exe's pipe parser fails to resolve a quoted exe
## path immediately after a pipe ("'"piper.exe"' is not recognized"), while
## PowerShell's call operator `&` handles the same quoted path correctly.
func _synthesize_worker(text: String, voice_path: String, length_scale: float,
		out_wav: String, my_id: int, self_thread: Thread) -> void:
	var txt_path := out_wav.replace(".wav", ".txt")
	var f := FileAccess.open(txt_path, FileAccess.WRITE)
	if f:
		f.store_string(text)
		f.close()
	var ps := "Get-Content -Raw \"%s\" | & \"%s\" --model \"%s\" --length_scale %s --output_file \"%s\" --quiet" \
		% [txt_path, _piper_exe_path, voice_path, str(length_scale), out_wav]
	OS.execute("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", ps])
	call_deferred("_on_synthesis_done", out_wav, txt_path, my_id, self_thread)

## Back on the main thread: load the WAV Piper wrote and actually play it, but
## only if nothing newer/force has superseded this request while it rendered.
func _on_synthesis_done(out_wav: String, txt_path: String, my_id: int, self_thread: Thread) -> void:
	self_thread.wait_to_finish()
	if my_id != _request_id:
		_cleanup_temp(out_wav, txt_path)
		return   # a `force` line (or a race) already moved on -- don't play a stale line
	if not FileAccess.file_exists(out_wav):
		push_warning("[TTS] piper produced no output for request %d" % my_id)
		_busy = false
		return
	var stream := AudioStreamWAV.load_from_file(out_wav, {})
	if stream == null:
		push_warning("[TTS] failed to load synthesized wav for request %d" % my_id)
		_busy = false
		_cleanup_temp(out_wav, txt_path)
		return
	_player.stream = stream
	_player.play()
	_cleanup_temp(out_wav, txt_path)

func _cleanup_temp(out_wav: String, txt_path: String) -> void:
	if FileAccess.file_exists(txt_path):
		DirAccess.remove_absolute(txt_path)
	# out_wav is intentionally left until AFTER playback -- AudioStreamWAV.load_from_file
	# already read it fully into memory by the time we get here, so it's safe to
	# delete now too; kept as a separate call in case that ever changes.
	if FileAccess.file_exists(out_wav):
		DirAccess.remove_absolute(out_wav)

func _on_playback_finished() -> void:
	_busy = false

## Stable per-member voice slot: same member always sounds the same. Only two
## Piper voices exist here (one male, one female), so PITCH does most of the
## remaining work of telling people apart -- hashed off the name so it never
## drifts between runs.
func _voice_path_for(who: Node) -> String:
	var h: int = abs(str(who.get("member_name")).hash())
	return _voice_female_path if h % 2 == 0 else _voice_male_path

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
func _volume_db(d: float) -> float:
	var t: float = clampf((d - CLOSE_RADIUS) / (HEAR_RADIUS - CLOSE_RADIUS), 0.0, 1.0)
	return lerpf(0.0, -24.0, t)

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
		_player.stop()
		_busy = false
		_request_id += 1   # orphan any in-flight synthesis so it won't play late
