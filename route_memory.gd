extends RefCounted
class_name RouteMemory

# ─────────────────────────────────────────────────────────────────────────────
# RouteMemory — private per-NPC "muscle memory" of the map (2026-08-28).
#
# NOT literally new Spikeling neurons wired into the trust brain -- tribemember.gd
# already explicitly warns against that ("bolting sight/hearing onto Trust/
# Follow blind risks destabilizing a calibrated system... a separate,
# deliberate one"). Instead this reuses SPIKELING'S OWN LEARNING MECHANICS
# (leaky decay + bounded-Hebbian growth, same GROW_CEIL/RELAX_RATE shape as
# spikeling.gd's learn()) on a spatial grid: each visited cell is a
# "place cell" in spirit (fires/strengthens when occupied, forgets when not),
# and each cell-to-cell transition an NPC actually walks is a directed edge
# that grows stronger the more it's used and relaxes back down when it isn't
# -- literal worn-path behavior, not flavor text.
#
# Private by design: an instance of this belongs to ONE NPC. Sharing between
# NPCs happens externally (see TribeRouteMemory autoload) when two members
# talk, mirroring how tribe_rumor.gd shares gossip -- one NPC's well-worn
# route can be taught to another without that NPC having walked it itself.
# ─────────────────────────────────────────────────────────────────────────────

const CELL_SIZE := 4.0          # meters per grid cell (matches tribe_talk.gd's TALK_RADIUS scale)
const FAMILIARITY_GAIN := 8.0   # per-visit reinforcement to a cell's familiarity
const FAMILIARITY_LEAK := 0.15  # per-tick forgetting if not revisited
const FAMILIARITY_CAP := 100.0
const EDGE_BASE_WEIGHT := 10.0  # innate edge weight the first time a transition is walked
const EDGE_GROW_CEIL := 3.0     # a worn edge can strengthen up to 3x its base weight
const EDGE_GAIN := 6.0          # per-use edge reinforcement
const EDGE_RELAX_RATE := 0.08   # per-tick relax toward base when unused
const SPEED_BONUS_AT_CEIL := 0.35  # +35% move speed on a fully worn path

var familiarity: Dictionary = {}     # cell_key(Vector2i) -> float
var edges: Dictionary = {}           # "from_key|to_key" -> {weight: float, base: float}
var _last_cell: Vector2i = Vector2i(999999, 999999)  # sentinel: "no previous cell yet"

func _cell_key(pos: Vector3) -> Vector2i:
	return Vector2i(int(floor(pos.x / CELL_SIZE)), int(floor(pos.z / CELL_SIZE)))

func _edge_key(a: Vector2i, b: Vector2i) -> String:
	return "%d,%d|%d,%d" % [a.x, a.y, b.x, b.y]

## Call once per physics/movement tick with the NPC's current world position.
## Reinforces the current cell's familiarity and, if this is a NEW cell since
## the last call, reinforces the directed edge from the previous cell to this
## one -- the actual "I walked this way" signal.
func visit(pos: Vector3) -> void:
	var key := _cell_key(pos)
	familiarity[key] = minf(FAMILIARITY_CAP, float(familiarity.get(key, 0.0)) + FAMILIARITY_GAIN)
	if key != _last_cell and _last_cell != Vector2i(999999, 999999):
		_reinforce_edge(_last_cell, key)
	_last_cell = key

func _reinforce_edge(a: Vector2i, b: Vector2i) -> void:
	var k := _edge_key(a, b)
	if not edges.has(k):
		edges[k] = {"weight": EDGE_BASE_WEIGHT, "base": EDGE_BASE_WEIGHT}
	var e: Dictionary = edges[k]
	var ceil_w: float = float(e["base"]) * EDGE_GROW_CEIL
	e["weight"] = minf(ceil_w, float(e["weight"]) + EDGE_GAIN)
	edges[k] = e

## Call once per tick (or on a slower cadence) to let unused memory fade --
## same "unreinforced bonds relax back toward innate strength" idea as
## spikeling.gd's learn(), so old/unused routes and cells genuinely fade
## rather than accumulating forever.
func decay(rate: float = 1.0) -> void:
	for key in familiarity.keys():
		familiarity[key] = maxf(0.0, float(familiarity[key]) - FAMILIARITY_LEAK * rate)
	for k in edges.keys():
		var e: Dictionary = edges[k]
		e["weight"] = move_toward(float(e["weight"]), float(e["base"]), EDGE_RELAX_RATE * rate)
		edges[k] = e

## How well-worn is the direct transition from cell A to cell B? 0 (unknown)
## to 1 (fully worn, at EDGE_GROW_CEIL). Used to bias movement speed/target.
func edge_strength(a: Vector2i, b: Vector2i) -> float:
	var k := _edge_key(a, b)
	if not edges.has(k):
		return 0.0
	var e: Dictionary = edges[k]
	var ceil_w: float = float(e["base"]) * EDGE_GROW_CEIL
	return clampf((float(e["weight"]) - float(e["base"])) / maxf(1.0, ceil_w - float(e["base"])), 0.0, 1.0)

## Speed multiplier for moving from world position `from` toward `to`, based
## on how worn that specific cell-to-cell transition is. 1.0 = no bonus,
## up to 1.0 + SPEED_BONUS_AT_CEIL on a fully worn route -- this is the
## actual "efficient known routes" behavior change, not just flavor.
func route_speed_mult(from: Vector3, to: Vector3) -> float:
	var s := edge_strength(_cell_key(from), _cell_key(to))
	return 1.0 + s * SPEED_BONUS_AT_CEIL

func cell_familiarity(pos: Vector3) -> float:
	return float(familiarity.get(_cell_key(pos), 0.0))

## For the TribeRouteMemory autoload: this NPC's strongest, most-worn edges
## (candidates worth teaching another member), sorted by strength descending.
func top_routes(n: int = 3) -> Array:
	var scored: Array = []
	for k in edges.keys():
		var e: Dictionary = edges[k]
		var ceil_w: float = float(e["base"]) * EDGE_GROW_CEIL
		var s: float = clampf((float(e["weight"]) - float(e["base"])) / maxf(1.0, ceil_w - float(e["base"])), 0.0, 1.0)
		if s > 0.05:
			scored.append({"key": k, "strength": s, "weight": e["weight"], "base": e["base"]})
	scored.sort_custom(func(a, b): return float(a["strength"]) > float(b["strength"]))
	return scored.slice(0, n)

## Learn a route taught by another NPC (via TribeRouteMemory sharing). Does
## NOT overwrite a stronger route this NPC already has of its own -- being
## TOLD about a shortcut is weaker evidence than having walked it yourself.
const TAUGHT_WEIGHT_FRACTION := 0.5   # a taught route starts at 50% of the teacher's strength
func learn_taught_route(edge_key: String, taught_weight: float, taught_base: float) -> void:
	if edges.has(edge_key) and float(edges[edge_key]["weight"]) >= taught_weight * TAUGHT_WEIGHT_FRACTION:
		return   # already know it at least this well from firsthand experience
	edges[edge_key] = {"weight": taught_weight * TAUGHT_WEIGHT_FRACTION, "base": taught_base}
