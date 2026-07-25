extends RefCounted
class_name HysteresisGate
# ─────────────────────────────────────────────────────────────────────────────
# HysteresisGate -- a real dual-threshold state machine, the "genuinely
# solid part" of the pattern discussed: instead of one threshold (which
# flickers when a signal wobbles right around it), two thresholds with a
# dead zone between them. Once triggered, the gate stays triggered until
# the signal falls CLEARLY back below the low bar; once relaxed, it stays
# relaxed until the signal rises CLEARLY above the high bar.
#
# Deliberately tiny and dependency-free (no LLM, no RAG, no agent
# framework) so it can be dropped in anywhere a real 0..1 signal needs a
# stable binary decision -- here, driven by a live Spikeling neuron's own
# potential; the same class would work verbatim as tribe_llm.gd's
# "call the LLM vs use a canned fallback" gate if a confidence signal were
# fed into it there.
# ─────────────────────────────────────────────────────────────────────────────

enum State { LOW, HIGH }

var state: int = State.LOW
var low_threshold: float = 0.3    # must fall BELOW this to drop from HIGH -> LOW
var high_threshold: float = 0.7   # must rise ABOVE this to climb from LOW -> HIGH
var flips: int = 0                # real transition count, for the UI to show

func _init(lo: float = 0.3, hi: float = 0.7) -> void:
	low_threshold = lo
	high_threshold = hi

## Feed the current signal (0..1) in; returns true if the gate is in HIGH
## state after this update. Only flips state on a CLEAR crossing of the
## threshold on the far side of the dead zone -- a signal wobbling anywhere
## between low_threshold and high_threshold changes nothing, by design.
func update(signal_value: float) -> bool:
	var before := state
	if state == State.LOW and signal_value >= high_threshold:
		state = State.HIGH
	elif state == State.HIGH and signal_value < low_threshold:
		state = State.LOW
	if state != before:
		flips += 1
	return state == State.HIGH

func state_name() -> String:
	return "HIGH" if state == State.HIGH else "LOW"
