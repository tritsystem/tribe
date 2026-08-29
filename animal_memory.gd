extends RefCounted
class_name AnimalMemory

# ─────────────────────────────────────────────────────────────────────────────
# AnimalMemory — "animals remember where food is found + develop a preferred
# biome" (2026-08-28).
#
# Two real, distinct mechanisms, not one hand-waved system:
#
# 1) PREFERRED BIOME -- a real Spikeling brain with ONE neuron per biome
#    (valley/plains/highland/mountain -- ocean excluded, animals don't graze
#    underwater). Each successful graze stimulates that biome's neuron; the
#    brain's own leaky decay means biomes NOT recently fed in fade out, so
#    "preferred" reflects sustained recent success, not a lifetime tally that
#    can never change. This is a REAL preference signal (read via
#    get_potential()), not a label -- see preferred_biome() below.
#
# 2) REMEMBERED FOOD SPOTS -- a small capped list of actual world positions
#    where this animal has successfully grazed, reused directly as extra
#    wander-target candidates (animal.gd's _wander() picks a random point
#    around home_pos; this adds "or go back to a spot that worked before").
#    Deliberately NOT the full RouteMemory grid system (tribe.gd's route
#    memory) -- an animal's whole world is a handful of remembered good
#    bushes, not a worn-path transportation network; a simpler capped list
#    fits what's actually needed here.
# ─────────────────────────────────────────────────────────────────────────────

const AnimalBrainScript = preload("res://spikeling.gd")

const BIOMES := ["valley", "plains", "highland", "mountain"]   # ocean excluded

const BRAIN_TEXT := """# Spikeling Neural Configuration (biome preference)
neuron valley   threshold=60 leak=4
neuron plains   threshold=60 leak=4
neuron highland threshold=60 leak=4
neuron mountain threshold=60 leak=4
refractory=1
"""

const GRAZE_STIMULUS := 25.0
const MAX_REMEMBERED_SPOTS := 5

var _brain: Spikeling = null
var _food_spots: Array = []   # Array[Vector3], most-recent-first, capped

func _get_brain() -> Spikeling:
	if _brain == null:
		_brain = AnimalBrainScript.new()
		_brain.load_from_text(BRAIN_TEXT)
	return _brain

## Call whenever this animal successfully grazes (food actually gained, not
## just walking near a bush). Feeds the biome neuron for where it happened
## AND remembers the exact spot.
func on_graze_success(biome: String, world_pos: Vector3) -> void:
	var b := _get_brain()
	if biome in BIOMES:
		b.stimulate(biome, GRAZE_STIMULUS)
	b.step()
	_remember_spot(world_pos)

func _remember_spot(pos: Vector3) -> void:
	# de-dupe near-identical spots (same bush revisited) instead of piling
	# up redundant entries
	for existing in _food_spots:
		if (existing as Vector3).distance_to(pos) < 3.0:
			return
	_food_spots.push_front(pos)
	if _food_spots.size() > MAX_REMEMBERED_SPOTS:
		_food_spots.resize(MAX_REMEMBERED_SPOTS)

## The biome with the strongest CURRENT (leaky, recency-weighted) signal, or
## "" if nothing has ever been grazed successfully. Real read of brain state,
## not a separately tracked counter.
func preferred_biome() -> String:
	if _brain == null:
		return ""
	var best := ""
	var best_p := 0.0
	for biome in BIOMES:
		var p: float = _brain.get_potential(biome)
		if p > best_p:
			best_p = p
			best = biome
	return best

## A remembered food spot to wander toward, or Vector3.INF if none known yet.
## Picks randomly among remembered spots so an animal doesn't camp the exact
## same bush forever once it has more than one good memory.
func recall_food_spot() -> Vector3:
	if _food_spots.is_empty():
		return Vector3.INF
	return _food_spots[randi() % _food_spots.size()]

func has_memory() -> bool:
	return not _food_spots.is_empty()

# NOTE ON PERSISTENCE (2026-08-28): deliberately NOT saved to disk. Each
# individual wild animal gets its own AnimalMemory instance (same as its own
# `brain` in animal.gd) -- persisting per-SPECIES to one shared file would
# have every Deer on the map overwrite each other's memory on save (last
# individual to save wins), a real collision bug, not a shortcut. An
# in-session-only memory that resets when the animal despawns is the honest
# scope for wildlife -- unlike the player's own weapon/pickaxe (one player,
# one persistent bond makes sense), there is no single "the deer" identity
# to persist across sessions here.
