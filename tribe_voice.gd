extends Node
# ─────────────────────────────────────────────────────────────────────────────
# TribeVoice — speak to your tribe. Autoload singleton: TribeVoice
#
# Godot has no built-in speech-to-text, so transcription happens in a tiny
# sidecar (tribe_mic.py) and arrives here as text. This node does exactly one
# job: turn new lines in a file into TribeCommand.try_execute(..., "voice").
#
# WHY A FILE AND NOT A SOCKET:
#   A file has no port to collide with, no bind-address trap, no handshake, and
#   survives either side restarting independently. We already got bitten once by
#   localhost resolving to ::1 while Ollama sat on 127.0.0.1 -- that class of bug
#   costs an evening and buys nothing here. Append-only text is boring and boring
#   is the point. Both sides derive the same path with no negotiation:
#     Godot:  user://voice_in.txt
#     Python: %APPDATA%/Godot/app_userdata/tribe/voice_in.txt
#
# PARTIAL LINES: the sidecar may be mid-write when we poll. We only ever consume
# up to the last "\n" and leave the remainder for the next tick, so a half-written
# transcript is never parsed.
#
# THE MIC IS ALWAYS ON, so this node does NOT route unmatched speech to the LLM.
# Ambient conversation must not become chat prompts (or orders). TribeCommand
# decides; anything it declines is shown as "heard" and dropped. If it turns out
# the parser is too loose in practice, the fix is push-to-talk (gate the sidecar
# on a key) -- but measure first rather than build it on a guess.
# ─────────────────────────────────────────────────────────────────────────────

const IN_FILE := "user://voice_in.txt"
const POLL := 0.25             # seconds; the file is tiny
const SHOW_HEARD := true       # flash unmatched speech so you can see mishears

var enabled := true
var _consumed: int = 0         # how many COMPLETE lines we've already handled
var _t := 0.0

func _ready() -> void:
	# Start from the END: a stale transcript from a previous run must never march
	# the camp the moment you press play.
	_consumed = _complete_lines(_read_all())
	print("[VOICE] listening for: %s" % ProjectSettings.globalize_path(IN_FILE))
	print("[VOICE] skipping %d existing line(s); start the mic with: python tribe_mic.py" % _consumed)
	set_process(true)

func _process(delta: float) -> void:
	if not enabled:
		return
	_t -= delta
	if _t > 0.0:
		return
	_t = POLL
	_drain()

func _read_all() -> String:
	if not FileAccess.file_exists(IN_FILE):
		return ""
	var f := FileAccess.open(IN_FILE, FileAccess.READ)
	if f == null:
		return ""
	var s := f.get_as_text()
	f.close()
	return s

## Number of lines that are definitely FINISHED (i.e. followed by a newline).
## "a\nb\n" -> split gives ["a","b",""] -> 2 complete.
## "a\nb"   -> split gives ["a","b"]    -> 1 complete; "b" may still be mid-write.
## Dropping the last element is what protects against parsing a half-written
## transcript, and it's exact rather than a guess about buffering.
func _complete_lines(all: String) -> int:
	if all == "":
		return 0
	return maxi(0, all.split("\n").size() - 1)

## COUNT LINES, DON'T TRACK BYTES.
#
# The previous version did `f.seek(_offset)` then `f.get_as_text()` -- and
# get_as_text() IGNORES the seek and returns the WHOLE FILE. Measured, not
# assumed: seek(9) on an 18-byte file still returns all 18 bytes (get_line()
# does respect seek; get_as_text() does not). So every poll re-read everything,
# the byte arithmetic ran past the real length, `size < _offset` tripped the
# "file was truncated" reset, and it started over from zero -- forever. The
# bridge never worked, and it never could have.
#
# Counting completed lines needs no seek, no byte/UTF-8 length reconciliation,
# and no assumption about an API I'd have had to go and check anyway. Re-reading
# a few KB four times a second is free; being clever here bought nothing.
func _drain() -> void:
	var all := _read_all()
	var total := _complete_lines(all)
	if total < _consumed:
		_consumed = 0          # sidecar restarted and truncated the log
	if total == _consumed:
		return
	var lines: PackedStringArray = all.split("\n")
	while _consumed < total:
		var t := str(lines[_consumed]).strip_edges()
		_consumed += 1
		if t != "":
			_handle(t)

func _handle(text: String) -> void:
	print("[VOICE] heard: \"%s\"" % text)
	if TribeCommand.try_execute(text, "voice"):
		return
	# Not a command. Deliberately NOT sent to the LLM -- see header.
	if SHOW_HEARD:
		var mgr := get_tree().get_first_node_in_group("tribe_manager")
		if mgr and mgr.has_method("notify_cat"):
			mgr.notify_cat("you", "🎙 heard \"%s\" (not an order)" % text)  # your own speech feedback
		elif mgr and mgr.has_method("_flash"):
			mgr._flash("🎙 heard \"%s\" (not an order)" % text, 2.0)
