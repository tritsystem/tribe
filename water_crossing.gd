extends RefCounted
# ─────────────────────────────────────────────────────────────────────────────
# WATER CROSSING — a shared, reusable boat-crossing state machine.
#
# On island maps a straight land->land route can run through the sea; a mover
# that just walks toward its goal marches into the water and stalls. This object
# stages a boat crossing exactly like trade_envoy.gd used to do inline: find the
# nearest shore on the way to the goal (TO_SHORE — the caller walks the mover
# there), pay wood for a boat, ride it straight across the gap (FERRY — this
# object positions the mover on the deck), and step off on the far island (back
# to OFF — the caller resumes walking).
#
# It is deliberately mover-agnostic: it owns the boat, the shoreline geometry,
# the crossing budget, payment and the safety timeout, but it does NOT drive the
# mover on foot — the caller does that (a trade_envoy sets global_position; an
# npc uses velocity + move_and_slide). The one exception is FERRY, where the
# mover is welded to the boat deck via global_position (physics is bypassed for
# that leg by both callers).
#
# On continuous / non-island maps manager.path_crosses_water() is ALWAYS false,
# so begin() returns 0 and none of this ever runs — behaviour is unchanged.
# ─────────────────────────────────────────────────────────────────────────────

const OFF := 0        # not crossing — caller walks normally
const TO_SHORE := 1   # crossing staged — caller must walk the mover to `embark`, then call launch()
const FERRY := 2      # riding the boat — this object positions the mover each tick_ferry()

var state: int = OFF
var mover: Node3D = null      # the node being ferried (envoy or npc)
var manager = null            # TribeManager — water-nav primitives + ground_y

var boat_speed: float = 8.0
var boat_timeout: float = 30.0   # a wedged boat frees itself + lands the mover
var max_crossings: int = 4       # bounds wood spend / infinite island-hopping
var crossings: int = 0

var embark: Vector3 = Vector3.INF     # shore we board at
var disembark: Vector3 = Vector3.INF  # far shore we land on
var _ferry_to: Vector3 = Vector3.ZERO # boat's straight-line destination (at water level)
var _boat: Node3D = null
var _boat_age: float = 0.0

func setup(m: Node3D, mgr) -> void:
	mover = m
	manager = mgr

## Decide whether the straight path from -> target needs a boat, and if so stage
## the crossing (paying for the boat up front via the `charge` Callable, which
## must return bool). Returns:
##    0  no crossing needed — caller walks toward target as normal
##    1  crossing staged — caller walks the mover toward `embark`, then launch()
##   -1  a crossing is needed but couldn't be arranged (unaffordable / no sea
##       route) — caller must ABORT (turn back / give up) rather than walk to sea
func begin(from: Vector3, target: Vector3, charge: Callable) -> int:
	if state != OFF:
		return 1
	if crossings >= max_crossings:
		return 0   # spent our hop budget — walk (bounded; timeout still guards)
	if manager == null or not manager.has_method("path_crosses_water"):
		return 0
	if not manager.path_crosses_water(from, target):
		return 0
	if not manager.has_method("shoreline_toward") or not manager.has_method("far_shore"):
		return 0
	var em: Vector3 = manager.shoreline_toward(from, target)
	var land_far: Vector3 = Vector3.INF
	if em != Vector3.INF:
		land_far = manager.far_shore(em, target)
	if em == Vector3.INF or land_far == Vector3.INF:
		return -1   # no workable sea route — abort, don't wade in
	if not charge.call():
		return -1   # couldn't pay for the boat — abort gracefully
	embark = em
	disembark = land_far
	state = TO_SHORE
	return 1

## Called by the caller once the mover has reached `embark`: spawn the boat, seat
## the mover on it, begin ferrying.
func launch() -> void:
	var wl: float = _water_level()
	_boat = _build_boat()
	if mover != null and is_instance_valid(mover) and mover.get_parent() != null:
		mover.get_parent().add_child(_boat)
		_boat.global_position = Vector3(embark.x, wl, embark.z)
	_ferry_to = Vector3(disembark.x, wl, disembark.z)
	_boat_age = 0.0
	state = FERRY

## Ride the boat straight toward the far shore, carrying the mover on the deck.
## Lands the mover (state -> OFF) on arrival or on the safety timeout so a stuck
## boat can never strand the mover. Returns true while still ferrying.
func tick_ferry(delta: float) -> bool:
	_boat_age += delta
	if _boat == null or not is_instance_valid(_boat):
		_land()
		return false
	var wl: float = _water_level()
	var bp := _boat.global_position
	var to_t := _ferry_to - bp
	to_t.y = 0.0
	var dist := to_t.length()
	if dist > 0.05:
		var step: float = minf(boat_speed * delta, dist)
		bp += to_t.normalized() * step
	bp.y = wl + sin(_boat_age * 2.0) * 0.06   # gentle bob on the swell
	_boat.global_position = bp
	if mover != null and is_instance_valid(mover):
		mover.global_position = Vector3(bp.x, wl + 0.35, bp.z)
	if dist <= 1.0 or _boat_age > boat_timeout:
		_land()
		return false
	return true

## End the ferry: free the boat, count the crossing, step onto dry land.
func _land() -> void:
	if _boat != null and is_instance_valid(_boat):
		_boat.queue_free()
	_boat = null
	crossings += 1
	_place_at(disembark)
	state = OFF

## Bail out of a crossing safely from anywhere: free any boat and put the mover
## on solid land. Leaves state OFF so a fresh crossing can start later.
func abort() -> void:
	if _boat != null and is_instance_valid(_boat):
		_boat.queue_free()
		_boat = null
	if mover != null and is_instance_valid(mover):
		_place_at(mover.global_position)
	state = OFF

func _build_boat() -> Node3D:
	var boat := Node3D.new()
	var hull := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(2.2, 0.35, 3.4)
	hull.mesh = bm
	hull.material_override = MatCache.flat(Color(0.42, 0.28, 0.14))
	boat.add_child(hull)
	return boat

func _water_level() -> float:
	if manager != null:
		var t = manager.get("terrain")
		if t != null and is_instance_valid(t):
			return float(t.get("water_level"))
	return 10.0

## Seat the mover on dry land at (p.x, p.z), nudged to the nearest shore if that
## spot is water. The one place the mover is placed after a crossing/bail.
func _place_at(p: Vector3) -> void:
	if mover == null or not is_instance_valid(mover):
		return
	var gp := p
	if manager != null and manager.has_method("_land_spot"):
		var land: Vector3 = manager._land_spot(p.x, p.z)
		if land != Vector3.INF:
			gp = land
	if manager != null and manager.has_method("ground_y"):
		gp.y = manager.ground_y(gp.x, gp.z) + 0.05
	mover.global_position = gp
