extends RefCounted
class_name SwordMemory

# ─────────────────────────────────────────────────────────────────────────────
# SwordMemory — "the weapon remembers the player" (2026-08-28), ported from
# horde-defense-beta's sword.gd/sword_memory.gd, adapted for tribe: tribe is
# single-player (FPSPlayer.gd has no player_id/team_id system), so this is a
# SINGLE persistent bond, not per-identity -- the horde-beta version's
# per-player_id dictionary is unnecessary here and would just be dead
# complexity for a game with exactly one wielder.
#
# One real Spikeling brain, same LIF mechanics as every other Spikeling
# brain in this portfolio:
#   Wielded  -- stimulated each landed combat hit (club vs. rival/tribesperson)
#   Bonded   -- fires once enough sustained hitting has accumulated
#
# DESIGN NOTE (carried over from horde-beta's real bug): attunement is NOT
# read from synapse weight via stdp_learn() -- verified in horde-beta that
# this fails for a fast-repeating-stimulus 2-neuron chain (Bonded fires far
# less often than Wielded, so most stdp_learn() calls land in the "too far
# apart to be causal" relax branch and the weight never grows). Instead,
# attunement is a simple bounded accumulator incremented ONLY on the real
# event of Bonded firing -- still fully SNN-gated (nothing grows without a
# real spike), just not leaning on a learning-rule subtlety that doesn't fit
# this shape.
# ─────────────────────────────────────────────────────────────────────────────

const SwordBrainScript = preload("res://spikeling.gd")

const BRAIN_TEXT := """# Spikeling Neural Configuration (weapon attunement)
neuron Wielded threshold=40 leak=8
neuron Bonded  threshold=100 leak=3
synapse Wielded -> Bonded weight=30
refractory=2
"""

const SAVE_PATH := "user://weapon_memory.json"
const MAX_DAMAGE_BONUS := 0.15    # +15% damage at full attunement -- capped, real but modest
const WIELD_STIMULUS := 45.0      # per landed hit
const BOND_STEP := 0.12           # attunement gained each time Bonded actually fires

var _brain: Spikeling = null
var _bond: float = 0.0

func _get_brain() -> Spikeling:
	if _brain == null:
		_brain = SwordBrainScript.new()
		_brain.load_from_text(BRAIN_TEXT)
	return _brain

## Call on every landed hit (not every swing -- a whiff shouldn't build a
## bond any more than a whiffed swing builds real combat skill).
func on_hit() -> void:
	var b := _get_brain()
	b.stimulate("Wielded", WIELD_STIMULUS)
	var fired: Array = b.step()
	if "Bonded" in fired:
		_bond = clampf(_bond + BOND_STEP, 0.0, 1.0)

## 0.0 (never wielded / no bond) .. 1.0 (fully bonded).
func attunement() -> float:
	return _bond

## The actual gameplay effect: a real, capped damage multiplier.
func attunement_damage_mult() -> float:
	return 1.0 + _bond * MAX_DAMAGE_BONUS

func recognizes() -> bool:
	return _bond > 0.3

# ── persistence ──────────────────────────────────────────────────────────
func save_to_disk() -> void:
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify({"bond": _bond}))
	file.close()

func load_from_disk() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		return
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed is Dictionary and parsed.has("bond"):
		_bond = clampf(float(parsed["bond"]), 0.0, 1.0)
