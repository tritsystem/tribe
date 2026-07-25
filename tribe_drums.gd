extends Node
# ─────────────────────────────────────────────────────────────────────────────
# TribeDrums — real generative percussion, driven by real Spikeling neuron
# fire events. Autoload singleton: TribeDrums.
#
# "the tribe's actual trust/fear/hunger dynamics becoming the literal rhythm
# of their music, not just word choice." Every tribemember's brain already
# fires named neurons every tick (SawContribute/SawHelpClear/SawDefend/
# SawBetray/Trust/Follow -- see tribemember.gd's _brain_tick()). Each fire
# is a real, timestamped event; this synthesizes an actual percussion hit
# from it -- no samples, no external audio files, real DSP (an
# exponentially-decaying sine burst, mixed live into an AudioStreamGenerator
# buffer) driven directly by which neuron fired and how hard.
#
# Deliberately scoped to the campfire at night (see tribemember.gd's
# _night_campfire_behavior()) -- gathered, idle members' brains ARE the
# drum circle, rather than every member on the whole map contributing noise
# constantly. Distant/daytime firing is silent (no hit queued at all), same
# "only where it means something" discipline TribeChorus's own header uses
# for audio.
# ─────────────────────────────────────────────────────────────────────────────

const MIX_RATE := 44100.0
const CAMPFIRE_AUDIBLE_RANGE := 8.0

# neuron name -> (pitch_hz, decay_seconds, amplitude) -- SawBetray/SawDefend
# (real threat/conflict) land as a low, hard hit; Trust/Follow (real bonding)
# land as a brighter, softer tone; the raw SawContribute/SawHelpClear inputs
# sit between the two -- an audible register of the SAME trust economy this
# whole session has been built around, not a separate flavor system.
const VOICE := {
	"SawContribute": {"pitch": 220.0, "decay": 0.12, "amp": 0.35},
	"SawHelpClear":  {"pitch": 246.0, "decay": 0.12, "amp": 0.35},
	"SawDefend":     {"pitch": 110.0, "decay": 0.22, "amp": 0.55},
	"SawBetray":     {"pitch": 82.0,  "decay": 0.30, "amp": 0.65},
	"Trust":         {"pitch": 330.0, "decay": 0.35, "amp": 0.45},
	"Follow":        {"pitch": 392.0, "decay": 0.45, "amp": 0.50},
}

var _player: AudioStreamPlayer
var _playback: AudioStreamGeneratorPlayback
var _active_hits: Array = []   # [{start_sample, pitch, decay, amp}]
var _sample_pos: int = 0
var enabled: bool = true

func _ready() -> void:
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = MIX_RATE
	gen.buffer_length = 0.3
	_player = AudioStreamPlayer.new()
	_player.stream = gen
	_player.bus = "Master"
	add_child(_player)
	_player.play()
	_playback = _player.get_stream_playback()
	set_process(true)

## Called from tribemember.gd's _brain_tick() for every neuron that fired
## this step. `audible` gates whether this actually queues a hit (the
## campfire/night check lives in the caller, not here -- this class only
## owns the synthesis, not the "does this moment deserve a drum" judgment).
##
## VELOCITY-SENSITIVE (2026-07-19): `velocity` (0..1, from Spikeling's own
## fire_strength() -- how far potential overshot threshold) scales both how
## LOUD the hit lands and how long it RINGS. A neuron that barely crossed
## threshold taps softly and dies out fast; one driven well past it strikes
## hard and rings longer -- the same real distinction a physical drum has
## between a tap and a real hit, driven by the actual brain dynamics rather
## than a flat trigger every time.
const VELOCITY_FLOOR := 0.35     # even a bare-threshold fire is audible, not silent
const VELOCITY_DECAY_BOOST := 0.6  # how much extra ring time a full-velocity hit gets

## Which neurons feed the SYNC coupling (see ambient_level() below), separate
## from which neurons are merely audible. Feeding a tribemate (SawContribute/
## SawHelpClear) still plays its own real drum voice -- it just shouldn't be
## what's DRIVING NPCs into rhythmic lock-step with each other. Sync should
## come from the tribe's actual trust/conflict dynamics, not from being fed.
const SYNC_ELIGIBLE := ["SawDefend", "SawBetray", "Trust", "Follow"]

func on_neuron_fired(neuron_name: String, audible: bool = true, velocity: float = 1.0) -> void:
	if not enabled or not audible:
		return
	var voice: Dictionary = VOICE.get(neuron_name, {})
	if voice.is_empty():
		return
	var v: float = clampf(velocity, 0.0, 1.0)
	var vel_mult: float = VELOCITY_FLOOR + (1.0 - VELOCITY_FLOOR) * v
	_active_hits.append({
		"start_sample": _sample_pos,
		"pitch": float(voice["pitch"]),
		"decay": float(voice["decay"]) * (1.0 + VELOCITY_DECAY_BOOST * v),
		"amp": float(voice["amp"]) * vel_mult,
		"sync_eligible": neuron_name in SYNC_ELIGIBLE,
	})
	# cap concurrent hits -- a drum circle, not a wall of noise
	if _active_hits.size() > 24:
		_active_hits.pop_front()

## The actual, measured mechanism behind emergent synchronization
## (project_thought/npc_rhythm_sync_experiment.gd, 2026-07-19): completely
## independent NPC brains, each with its own natural firing rhythm, phase-
## lock into a real drum circle purely from sharing this one ambient level
## back into their own brains (r rose from 0.48 incoherent to ~0.94 locked
## across 6 seeds, monotonic in coupling strength). Only counts SYNC_ELIGIBLE
## hits -- feeding is audible but does not drive the lock-step.
func ambient_level() -> float:
	var total := 0.0
	for h in _active_hits:
		if not h.get("sync_eligible", false):
			continue
		var age: float = float(_sample_pos - int(h["start_sample"])) / MIX_RATE
		if age < 0.0:
			continue
		total += exp(-age / float(h["decay"])) * float(h["amp"])
	return total

func _process(_delta: float) -> void:
	if _playback == null:
		return
	var to_fill: int = _playback.get_frames_available()
	if to_fill <= 0:
		return
	for i in range(to_fill):
		var sample := _render_sample(_sample_pos)
		_playback.push_frame(Vector2(sample, sample))
		_sample_pos += 1
	# prune hits that have fully decayed (5 half-lives is inaudible)
	_active_hits = _active_hits.filter(func(h):
		var age: float = float(_sample_pos - int(h["start_sample"])) / MIX_RATE
		return age < float(h["decay"]) * 6.0)

## The actual DSP: sum every active hit's exponentially-decaying sine at
## this sample position. A real percussion voice, not a beep -- amplitude
## envelope e^(-t/decay) times a sine at the hit's own pitch.
func _render_sample(sample_index: int) -> float:
	var out := 0.0
	for h in _active_hits:
		var age: float = float(sample_index - int(h["start_sample"])) / MIX_RATE
		if age < 0.0:
			continue
		var decay: float = float(h["decay"])
		var envelope: float = exp(-age / decay)
		out += envelope * float(h["amp"]) * sin(TAU * float(h["pitch"]) * age)
	return clampf(out, -1.0, 1.0)
