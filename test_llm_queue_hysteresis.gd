extends Node
# Headless test for tribe_llm.gd's hysteresis-gated queue backlog check
# (2026-07-19: "can I use this on my actual gaming pipeline" -- the real
# HysteresisGate class, proven in Project Thought, dropped into the actual
# LLM-vs-fallback decision). Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path . res://test_llm_queue_hysteresis.tscn --quit

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  TRIBE_LLM QUEUE HYSTERESIS")
	print("=".repeat(60))

	TribeLLM.available = true
	TribeLLM.warm = true
	TribeLLM._queue.clear()
	TribeLLM._queue_gate = HysteresisGateScript.new(0.25, 0.85)

	# below the high bar -- never backs up
	for i in range(2):
		TribeLLM._queue.append({})
	_check("a lightly-loaded queue (2/4) is not considered backed up",
		not TribeLLM._queue_backed_up())

	# fill to the cap -- must genuinely back up
	TribeLLM._queue.append({}); TribeLLM._queue.append({})
	_check("a genuinely full queue (4/4) IS considered backed up",
		TribeLLM._queue_backed_up())

	# drain by one -- old flat-threshold code would let calls straight back
	# through here (3 < MAX_QUEUE); the hysteresis gate must NOT, since 3/4
	# is still well above the low bar
	TribeLLM._queue.pop_front()
	_check("draining by ONE line right at the cap does NOT immediately reopen the gate",
		TribeLLM._queue_backed_up())

	# drain further, CLEARLY below the low bar -- NOW it should reopen
	# (0/4, not 1/4 -- 1/4 == 0.25 sits exactly ON the low bar, which correctly
	# does NOT count as "clearly below" it, same principle as the dead zone itself)
	TribeLLM._queue.pop_front(); TribeLLM._queue.pop_front(); TribeLLM._queue.pop_front()
	_check("draining genuinely low (0/4) reopens the gate",
		not TribeLLM._queue_backed_up())

	TribeLLM._queue.clear()
	print("\n" + "-".repeat(42))
	print("  %d passed, %d FAILED" % [_pass, _fail])
	print("-".repeat(42) + "\n")
	get_tree().quit(1 if _fail > 0 else 0)

const HysteresisGateScript = preload("res://hysteresis_gate.gd")

func _check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  ok    %s" % label)
	else:
		_fail += 1
		print("  FAIL  %s" % label)
