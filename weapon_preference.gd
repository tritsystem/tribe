extends RefCounted
class_name WeaponPreference

# ─────────────────────────────────────────────────────────────────────────────
# WeaponPreference — "wire spike thoughts into actions: based on experience
# and preferred weapon" (2026-08-28).
#
# Real per-member Spikeling brain, one neuron per WEAPON_TIERS name (Club,
# Spear, Bow, Axe, Wand). Stimulated on every REAL successful combat action
# with that weapon type (a landed strike/arrow/spell-bolt hit, not equipping
# it) -- so "preference" tracks actual lived combat experience, not just
# equipment history. Leaky decay means a weapon type not used recently fades
# out of favor, same recency-weighted design as animal_memory.gd's biome
# preference.
#
# WIRED INTO A REAL ACTION: _maybe_upgrade_gear() in tribemember.gd normally
# always raises weapon tier by a strict linear +1 ("Axe is just better").
# With real combat experience favoring a ranged type (Bow/Wand), a member
# now explicitly favors continuing to level UP that ranged type rather than
# blindly marching toward Axe -- a genuine choice driven by spike history,
# not the same fixed ladder for every member regardless of how they've
# actually been fighting.
# ─────────────────────────────────────────────────────────────────────────────

const PrefBrainScript = preload("res://spikeling.gd")

const WEAPON_NAMES := ["Club", "Spear", "Bow", "Axe", "Wand"]

const BRAIN_TEXT := """# Spikeling Neural Configuration (weapon preference)
neuron Club  threshold=60 leak=5
neuron Spear threshold=60 leak=5
neuron Bow   threshold=60 leak=5
neuron Axe   threshold=60 leak=5
neuron Wand  threshold=60 leak=5
refractory=1
"""

# BUG FOUND + FIXED (2026-08-28, same lesson as sword_memory.gd): the first
# version read favored_weapon_index() straight off get_potential() -- but a
# neuron that just fired resets its potential to 0 THAT SAME STEP, so
# reading potential right after a real firing event can show a FALSE zero
# for the very weapon that just proved itself. Verified via a direct test:
# 10 real Club hits still returned favored_weapon_index() == -1 because the
# read landed right after a reset. Fixed the same way sword_memory.gd was
# fixed: track REAL FIRING EVENTS in a small recency-weighted counter,
# not momentary potential.
const HIT_STIMULUS := 20.0
const FIRE_BUMP := 0.30      # credit added each time a weapon's neuron actually fires
const FIRE_DECAY := 0.02     # per real combat-success call, so old experience fades

var _brain: Spikeling = null
var _experience: Array = [0.0, 0.0, 0.0, 0.0, 0.0]   # parallel to WEAPON_NAMES

func _get_brain() -> Spikeling:
	if _brain == null:
		_brain = PrefBrainScript.new()
		_brain.load_from_text(BRAIN_TEXT)
	return _brain

## Call on every real landed combat hit, tagged with which weapon index
## (WEAPON_TIERS index, matching WEAPON_NAMES order) delivered it.
func on_combat_success(weapon_index: int) -> void:
	if weapon_index < 0 or weapon_index >= WEAPON_NAMES.size():
		return
	var b := _get_brain()
	b.stimulate(WEAPON_NAMES[weapon_index], HIT_STIMULUS)
	var fired: Array = b.step()
	for i in range(_experience.size()):
		_experience[i] = maxf(0.0, _experience[i] - FIRE_DECAY)
	if WEAPON_NAMES[weapon_index] in fired:
		_experience[weapon_index] = _experience[weapon_index] + FIRE_BUMP

## The weapon type this member's combat EXPERIENCE currently favors most
## (real, recency-weighted count of actual SNN firing events for that
## weapon), or -1 if no real combat experience with anything yet (falls
## back to the normal linear ladder).
func favored_weapon_index() -> int:
	var best_i := -1
	var best_p := 0.0
	for i in range(_experience.size()):
		var p: float = _experience[i]
		if p > best_p:
			best_p = p
			best_i = i
	return best_i

## Is the favored weapon a genuinely different CATEGORY (ranged: Bow/Wand)
## from the linear melee ladder (Club/Spear/Axe)? Used to decide whether to
## deviate from the default +1 ladder at all -- a member who simply favors
## whatever they're currently using (the common case, since that's the only
## thing generating experience) shouldn't get yanked off course; only a
## clear, real preference for the OTHER combat style should redirect them.
func favors_ranged() -> bool:
	var fw := favored_weapon_index()
	return fw == 2 or fw == 4   # Bow or Wand
