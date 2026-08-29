extends RefCounted
class_name PickaxeMemory

# ─────────────────────────────────────────────────────────────────────────────
# PickaxeMemory — "the pickaxe gets better with use" (2026-08-28).
#
# Same SwordMemory pattern/lesson (SNN gates WHEN a real skill-building event
# happens; a simple bounded accumulator, incremented only on that real spike,
# is the persisted "how good" value -- not synapse weight/STDP, which was
# proven fragile for this fast-repeating-stimulus shape in sword_memory.gd).
#
# Two real effects, both capped, both driven by the same attunement value:
#   detect_range_bonus()  -- minerals are found/auto-harvested from farther
#                             away as the pickaxe "learns" the player's
#                             prospecting habits (mineral.gd's _collect_range)
#   yield_mult()          -- each harvest yields somewhat more material at
#                             high attunement (skill paying off, same idea
#                             as tribemember.gd's YIELD_BY_TIER for professions)
# ─────────────────────────────────────────────────────────────────────────────

const PickaxeBrainScript = preload("res://spikeling.gd")

const BRAIN_TEXT := """# Spikeling Neural Configuration (pickaxe attunement)
neuron Mined  threshold=40 leak=8
neuron Honed  threshold=100 leak=3
synapse Mined -> Honed weight=30
refractory=2
"""

const SAVE_PATH := "user://pickaxe_memory.json"
const MINE_STIMULUS := 45.0
const HONE_STEP := 0.10
const MAX_RANGE_BONUS := 2.5      # up to +2.5m detect range at full attunement
const MAX_YIELD_BONUS := 0.5      # up to +50% yield at full attunement

var _brain: Spikeling = null
var _bond: float = 0.0

func _get_brain() -> Spikeling:
	if _brain == null:
		_brain = PickaxeBrainScript.new()
		_brain.load_from_text(BRAIN_TEXT)
	return _brain

## Call on every real harvest (a mineral node actually collected).
func on_mine() -> void:
	var b := _get_brain()
	b.stimulate("Mined", MINE_STIMULUS)
	var fired: Array = b.step()
	if "Honed" in fired:
		_bond = clampf(_bond + HONE_STEP, 0.0, 1.0)

func attunement() -> float:
	return _bond

## Additive bonus (meters) to mineral.gd's base _collect_range.
func detect_range_bonus() -> float:
	return _bond * MAX_RANGE_BONUS

## Multiplier applied to harvested amount. 1.0 = no bonus.
func yield_mult() -> float:
	return 1.0 + _bond * MAX_YIELD_BONUS

func honed() -> bool:
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
