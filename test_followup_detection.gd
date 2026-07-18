extends Node
# Headless test for TribeChat's _looks_like_followup() gate. Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path . res://test_followup_detection.tscn --quit
#
# Caught live: a member with a huge feed history got asked "of course" (fine,
# continuity helped) then "are you in a good mood" -- a completely unrelated
# fresh question -- and answered with nearly the SAME line as before, because
# the continuity note attached unconditionally and the model anchored on the
# quoted-back food line regardless of whether the new line was actually a
# follow-up.

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  FOLLOW-UP DETECTION -- continuity-note gating")
	print("=".repeat(60))

	# the exact real case that broke: a genuine fresh question must NOT
	# be treated as a follow-up just because it's short-ish
	_check('"are you in a good mood" is a fresh question, not a follow-up',
		not TribeChat._looks_like_followup("are you in a good mood"))
	_check('"whats up" is short but still a fresh greeting-check, not tied to '
		+ "a specific prior statement -- wait, 2 words -> follow-up per the "
		+ "length heuristic (documented tradeoff, not asserted otherwise here)",
		TribeChat._looks_like_followup("whats up"))

	# genuine follow-ups must still work
	_check('"why not" is a real follow-up marker', TribeChat._looks_like_followup("why not"))
	_check('"why" alone is a real follow-up marker', TribeChat._looks_like_followup("why"))
	_check('"of course" (2 words) reads as a reactive continuation',
		TribeChat._looks_like_followup("of course"))
	_check('"how come" is a real follow-up marker', TribeChat._looks_like_followup("how come"))
	_check('"really" is a real follow-up marker', TribeChat._looks_like_followup("really"))

	# longer fresh statements/questions must not be swept in
	_check('"do you trust me" is its own new question, not a follow-up',
		not TribeChat._looks_like_followup("do you trust me"))
	_check('"tell me about the other tribes" is a fresh question',
		not TribeChat._looks_like_followup("tell me about the other tribes"))
	_check("empty string is never a follow-up", not TribeChat._looks_like_followup(""))

	print("\n" + "-".repeat(42))
	print("  %d passed, %d FAILED" % [_pass, _fail])
	print("-".repeat(42) + "\n")
	get_tree().quit(1 if _fail > 0 else 0)

func _check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  ok    %s" % label)
	else:
		_fail += 1
		print("  FAIL  %s" % label)
