extends RefCounted
class_name PlayerReputation

# ─────────────────────────────────────────────────────────────────────────────
# PlayerReputation — "SNN NPCs remember you, reputation builds over repeat
# interactions" (2026-08-28).
#
# Distinct from `relationship` (the existing Trust/Follow-brain-driven trust
# meter that already exists and drives ranks Stranger..Devoted) -- this is a
# SEPARATE recognition layer that answers "does this member specifically
# remember a real PATTERN of good or bad treatment from you," not just a
# single scalar number. Two real Spikeling neurons:
#   GoodDeed -- stimulated on a real positive interaction (contribute, i.e.
#               being fed/helped -- see contribute() in tribemember.gd)
#   BadDeed  -- stimulated on a real negative interaction (betray())
# Reputation is read as the NET of accumulated real firing events for each
# (same "track real firing events, not raw potential" fix used in
# sword_memory.gd/weapon_preference.gd -- see the vault lesson on why
# reading potential directly is wrong).
#
# REAL EFFECT: once net reputation crosses a real threshold, relationship-
# building actions (contribute()) land somewhat FASTER for a player this
# member specifically remembers being consistently good (or slower for one
# remembered as consistently bad) -- see reputation_gain_mult() below, wired
# into contribute()'s FOLLOW_FIRE_REL_GAIN path. Deliberately did NOT touch
# betray()'s Trust-wipe (that's an intentional one-shot mechanic per its own
# existing code comment, not something reputation should soften).
# ─────────────────────────────────────────────────────────────────────────────

const ReputationBrainScript = preload("res://spikeling.gd")

const BRAIN_TEXT := """# Spikeling Neural Configuration (player reputation)
neuron GoodDeed threshold=40 leak=6
neuron BadDeed  threshold=40 leak=6
refractory=1
"""

const DEED_STIMULUS := 45.0
const GOOD_BUMP := 0.10
const BAD_BUMP := 0.18          # a betrayal weighs more than a kindness, matching
                                  # betray()'s own existing asymmetric design elsewhere
const DECAY := 0.01
const MAX_BONUS := 0.35         # up to +35% relationship gain at max good reputation
const MAX_PENALTY := 0.5        # up to -50% relationship gain at max bad reputation

var _brain: Spikeling = null
var _good: float = 0.0
var _bad: float = 0.0

func _get_brain() -> Spikeling:
	if _brain == null:
		_brain = ReputationBrainScript.new()
		_brain.load_from_text(BRAIN_TEXT)
	return _brain

func on_good_deed() -> void:
	var b := _get_brain()
	b.stimulate("GoodDeed", DEED_STIMULUS)
	var fired: Array = b.step()
	_good = maxf(0.0, _good - DECAY)
	_bad = maxf(0.0, _bad - DECAY)
	if "GoodDeed" in fired:
		_good = clampf(_good + GOOD_BUMP, 0.0, 1.0)

func on_bad_deed() -> void:
	var b := _get_brain()
	b.stimulate("BadDeed", DEED_STIMULUS)
	var fired: Array = b.step()
	_good = maxf(0.0, _good - DECAY)
	_bad = maxf(0.0, _bad - DECAY)
	if "BadDeed" in fired:
		_bad = clampf(_bad + BAD_BUMP, 0.0, 1.0)

## Net reputation, -1.0 (thoroughly remembered as bad) .. +1.0 (thoroughly
## remembered as good). 0.0 = unrecognized / neutral / never interacted.
func net() -> float:
	return clampf(_good - _bad, -1.0, 1.0)

## Multiplier for relationship-building gains (e.g. contribute()'s
## FOLLOW_FIRE_REL_GAIN). 1.0 = no effect (unrecognized player).
func reputation_gain_mult() -> float:
	var n := net()
	if n >= 0.0:
		return 1.0 + n * MAX_BONUS
	return 1.0 + n * MAX_PENALTY   # n is negative here, so this SUBTRACTS

func is_well_regarded() -> bool:
	return net() > 0.3

func is_distrusted() -> bool:
	return net() < -0.3
