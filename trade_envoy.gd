extends Node3D
# ─────────────────────────────────────────────────────────────────────────────
# TRADE ENVOY — a PHYSICAL trade caravan, one walking node carrying a note.
#
# WHY a dedicated node instead of commandeering a real member (npc.gd /
# tribemember.gd): real members are driven every frame by the economy/order AI
# and the war muster. Yanking one out mid-order to walk it cross-map fights that
# AI for control and reliably desyncs the tribe's worker counts (the exact class
# of bug the project has been bitten by before). An envoy is a throwaway visual
# courier: it owns nothing but its route and its offer, so nothing else breaks
# if it gets stuck, times out, or its target camp is wiped out mid-journey.
#
# The envoy holds an OFFER but does NOT decide the deal — all economy math and
# the accept/refuse ruling live in Tribemanager (single source of truth, mirrors
# _try_trade). The envoy just walks there, tells the manager it arrived, walks
# home, and frees itself.
# ─────────────────────────────────────────────────────────────────────────────

var manager: Node = null                 # the TribeManager, for ground_y + resolve callbacks

# The parties. from_tribe is a world_tribe.gd Node3D, OR null when the PLAYER is
# the sender (the player's economy lives on the manager itself, not a world_tribe).
var from_tribe: Node = null
var to_tribe: Node = null                 # always a world_tribe.gd Node3D (the host camp)
var from_is_player: bool = false
var from_name: String = "?"
var to_name: String = "?"

# ── "to the PLAYER" mode ──────────────────────────────────────────────────────
# An NPC tribe can send a caravan to the PLAYER's camp (not another world_tribe)
# to PROPOSE a trade. When to_is_player is set, to_tribe is null and the envoy
# walks to the player's stockpile; on arrival the manager pops an accept/decline
# panel instead of settling a deal outright. offer_material is carried so the UI
# can name the good ("3 Bone for 12 food"). note_only marks a courier that just
# carries a message (the player's acceptance note) and triggers NO exchange on
# arrival — the goods already changed hands when the player clicked Accept.
var to_is_player: bool = false
var note_only: bool = false
var offer_material: String = "goods"

# The proposed offer, computed at dispatch. Re-validated at arrival because the
# world moves on while the envoy walks (stores drain, grudges shift).
var mat_amt: int = 0                       # material the sender offers
var food_amt: int = 0                      # food the sender wants in return

var _home_pos: Vector3 = Vector3.ZERO      # where to walk back to and vanish
var _target_pos: Vector3 = Vector3.ZERO    # current leg's destination (xz meaningful)
var _returning: bool = false               # false = outbound to host, true = walking home
var _resolved: bool = false                # deal already ruled on (guards double-fire)
var _age: float = 0.0                      # total lifetime, for the safety timeout

const SPEED := 6.0                         # units/s — a plausible walking caravan
const ARRIVE_RADIUS := 6.0                 # "close enough to the camp to parley"
const TIMEOUT := 60.0                      # a stuck envoy must not live forever

var _note: MeshInstance3D = null

# ── BOAT CROSSING (island maps only) ─────────────────────────────────────────
# On island scales the straight land->land route can run through the sea, and the
# old envoy would just walk into the water. Instead it now stages a boat crossing:
# walk to the nearest shore on the way to the target (EMBARK), pay wood for a
# boat, ride it straight across the gap (FERRY), step off on the far island, and
# resume walking. Every leg (outbound AND the return trip) checks independently,
# so a courier that crossed to trade also sails home. On continuous maps
# path_crosses_water is always false, so none of this ever runs — the envoy walks
# exactly as before.
enum { LAND, EMBARK, FERRY }               # travel mode for the current leg
const BOAT_WOOD_COST := 8                  # wood the SENDING tribe spends per boat
const BOAT_SPEED := 8.0                    # ferry glides a touch faster than walking
const BOAT_TIMEOUT := 30.0                 # a wedged boat frees itself + lands the traveller
const MAX_CROSSINGS := 4                   # out + back + a spare island hop; bounds wood/loops

var _mode: int = LAND
var _boat: Node3D = null
var _embark: Vector3 = Vector3.ZERO        # shore we board at
var _disembark: Vector3 = Vector3.ZERO     # far shore we land on
var _ferry_to: Vector3 = Vector3.ZERO      # boat's straight-line destination (at water level)
var _boat_age: float = 0.0
var _crossings: int = 0

func setup(mgr: Node, sender: Node, host: Node, is_player: bool,
		mat: int, food: int, sender_name: String, host_name: String) -> void:
	manager       = mgr
	from_tribe    = sender
	to_tribe      = host
	from_is_player = is_player
	mat_amt       = mat
	food_amt      = food
	from_name     = sender_name
	to_name       = host_name

func _ready() -> void:
	_home_pos   = global_position
	_build_visual()
	_update_target()

func _build_visual() -> void:
	# a stubby courier body so the caravan reads on screen...
	var body := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.3
	cap.height = 1.3
	body.mesh = cap
	body.position = Vector3(0, 0.75, 0)
	body.material_override = MatCache.flat(Color(0.85, 0.78, 0.5))   # neutral tan — a traveller, not a warrior
	add_child(body)

	# ...carrying a visible "note"/parcel floating over the head — the marker the
	# brief asks for, so a passing player can see a trade is in motion.
	_note = MeshInstance3D.new()
	var nm := BoxMesh.new()
	nm.size = Vector3(0.35, 0.35, 0.06)
	_note.mesh = nm
	_note.position = Vector3(0, 1.9, 0)
	_note.material_override = MatCache.flat(Color(0.95, 0.92, 0.75))
	add_child(_note)

func _update_target() -> void:
	# outbound aims at the host camp (live position, in case it drifts); the
	# return leg aims at the recorded home spot (home camp may have been wiped
	# out, so we never dereference it on the way back).
	if _returning:
		# an envoy sent TO the player has no _home_pos worth trusting (it was
		# seated at the sender camp AFTER _ready recorded home), so aim the return
		# leg at the sender tribe's live camp instead.
		if to_is_player and is_instance_valid(from_tribe):
			_target_pos = (from_tribe as Node3D).global_position
		else:
			_target_pos = _home_pos
	elif to_is_player:
		_target_pos = _player_camp()
	elif is_instance_valid(to_tribe):
		_target_pos = (to_tribe as Node3D).global_position
	else:
		_target_pos = _home_pos   # host gone mid-journey -> just go home

# ROUTED VIA TRADING POST (2026-07-19): "envoys should be routed via trading
# post" -- a caravan bound for the player now walks to the actual trading
# post building if one's been raised (see Tribemanager.build_trading_post()),
# falling back to the stockpile/player position only if it's somehow missing
# (shouldn't happen in practice -- every caller that spawns a to_is_player
# envoy is already gated on trading_post_built()).
func _player_camp() -> Vector3:
	var tp := get_tree().get_first_node_in_group("trading_post") as Node3D
	if tp != null and is_instance_valid(tp):
		return tp.global_position
	var sp := get_tree().get_first_node_in_group("stockpile") as Node3D
	if sp != null and is_instance_valid(sp):
		return sp.global_position
	var p := get_tree().get_first_node_in_group("player") as Node3D
	if p != null and is_instance_valid(p):
		return p.global_position
	return Vector3.ZERO

func _process(delta: float) -> void:
	_age += delta
	if _age > TIMEOUT:
		# gave up — put the traveller on solid land first (never strand at sea),
		# then quietly retire so a wedged envoy can't leak or block its pair.
		_place_on_land()
		_finish()
		return

	# ── riding the boat: glide straight across the gap, skip normal walking ──
	if _mode == FERRY:
		_tick_ferry(delta)
		return

	# the host camp can be destroyed while we walk; abandon the errand and head home.
	# (a to_is_player envoy legitimately has no to_tribe — the player's camp is the
	# destination — so it is exempt from this "host gone" check.)
	if not _returning and not to_is_player and not is_instance_valid(to_tribe):
		_returning = true
	_update_target()

	# this frame's on-foot destination: the embark shore if a crossing is staged,
	# otherwise the leg's real target.
	var goal: Vector3 = _embark if _mode == EMBARK else _target_pos

	# ── does the straight path to the target cross the sea? on island maps only,
	# and only up to MAX_CROSSINGS so a courier can't loop forever burning wood. ──
	if _mode == LAND and _crossings < MAX_CROSSINGS and manager != null \
			and manager.has_method("path_crosses_water") \
			and manager.path_crosses_water(global_position, _target_pos):
		if not _begin_crossing():
			return   # aborted (couldn't afford / no route) — _begin_crossing retired us
		goal = _embark

	var pos := global_position
	var to_t := goal - pos
	to_t.y = 0.0
	var dist := to_t.length()
	if dist > 0.05:
		var step: float = minf(SPEED * delta, dist)
		pos += to_t.normalized() * step
	# seat on the terrain each frame so the caravan follows hills instead of
	# floating or sinking (mirrors how the manager seats everything else).
	if manager != null and manager.has_method("ground_y"):
		pos.y = manager.ground_y(pos.x, pos.z) + 0.05
	global_position = pos

	# bob the note a little so it reads as "carried", not welded on
	if _note != null:
		_note.position.y = 1.9 + sin(_age * 4.0) * 0.08

	# reached the embark shore -> build the boat and start the ferry
	if _mode == EMBARK and dist <= 1.5:
		_launch_boat()
		return

	if _mode == LAND and dist <= ARRIVE_RADIUS:
		if _returning:
			_finish()
		elif not _resolved:
			_resolved = true
			# hand the ruling to the manager, then turn for home regardless of
			# whether the deal closed (a refused envoy still walks back).
			if manager != null and manager.has_method("_on_envoy_arrived"):
				manager._on_envoy_arrived(self)
			_returning = true
			_update_target()

# ── BOAT CROSSING HELPERS ────────────────────────────────────────────────────

## Work out the sea route and pay for the boat. Returns false only when the
## crossing was ABANDONED (already retired the envoy); true means either the
## crossing is staged (mode -> EMBARK) or there's no real water route and we
## should just keep walking.
func _begin_crossing() -> bool:
	if not manager.has_method("shoreline_toward") or not manager.has_method("far_shore"):
		return true   # helpers absent — walk normally
	var embark: Vector3 = manager.shoreline_toward(global_position, _target_pos)
	var land_far: Vector3 = Vector3.INF
	if embark != Vector3.INF:
		land_far = manager.far_shore(embark, _target_pos)
	if embark == Vector3.INF or land_far == Vector3.INF:
		# couldn't resolve a workable sea route -> abandon rather than walk into
		# the sea. Put the traveller back on land and retire.
		_place_on_land()
		_finish()
		return false
	if not _charge_boat():
		return false   # can't afford it — _charge_boat flashed + retired us
	_embark = embark
	_disembark = land_far
	_mode = EMBARK
	return true

## The sending tribe spends wood on the boat. Player couriers cross free (the
## player already committed the goods). Fails gracefully if the tribe is broke.
func _charge_boat() -> bool:
	if from_is_player or from_tribe == null or not is_instance_valid(from_tribe):
		return true
	var w: int = int(from_tribe.get("wood"))
	if w < BOAT_WOOD_COST:
		if manager != null and manager.has_method("notify_cat"):
			manager.notify_cat("tribes", "🪵 The %s can't afford a boat — the crossing to the %s is called off." % [from_name, to_name])
		_place_on_land()
		_finish()
		return false
	from_tribe.set("wood", w - BOAT_WOOD_COST)
	if manager != null and manager.has_method("notify_cat"):
		manager.notify_cat("tribes", "⛵ The %s build a boat (%d wood) to cross to the %s." % [from_name, BOAT_WOOD_COST, to_name])
	return true

## Spawn the boat at the embark shore, seat the traveller on it, start ferrying.
func _launch_boat() -> void:
	var wl: float = _water_level()
	_boat = _build_boat()
	get_parent().add_child(_boat)
	_boat.global_position = Vector3(_embark.x, wl, _embark.z)
	_ferry_to = Vector3(_disembark.x, wl, _disembark.z)
	_boat_age = 0.0
	_mode = FERRY

## Ride the boat straight toward the far shore; land the traveller on arrival or
## on the safety timeout so a stuck boat can never strand the courier.
func _tick_ferry(delta: float) -> void:
	_boat_age += delta
	if _boat == null or not is_instance_valid(_boat):
		_end_ferry()
		return
	var wl: float = _water_level()
	var bp := _boat.global_position
	var to_t := _ferry_to - bp
	to_t.y = 0.0
	var dist := to_t.length()
	if dist > 0.05:
		var step: float = minf(BOAT_SPEED * delta, dist)
		bp += to_t.normalized() * step
	bp.y = wl + sin(_boat_age * 2.0) * 0.06   # gentle bob on the swell
	_boat.global_position = bp
	# carry the traveller standing on the deck
	global_position = Vector3(bp.x, wl + 0.35, bp.z)
	if _note != null:
		_note.position.y = 1.9 + sin(_age * 4.0) * 0.08
	if dist <= 1.0 or _boat_age > BOAT_TIMEOUT:
		_end_ferry()

## End the ferry: free the boat, count the crossing, step onto dry land.
func _end_ferry() -> void:
	if _boat != null and is_instance_valid(_boat):
		_boat.queue_free()
	_boat = null
	_crossings += 1
	_place_at(_disembark)   # nearest_land-derived, so guaranteed solid ground
	_mode = LAND

## A shallow flat wooden hull floating at the waterline. Uses MatCache (pooled)
## per the project's material rules — never a raw per-instance StandardMaterial3D.
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

## Seat the traveller on dry land at (p.x, p.z), nudged to the nearest shore if
## that spot happens to be water. The one place the envoy is placed after a bail.
func _place_at(p: Vector3) -> void:
	var gp := p
	if manager != null and manager.has_method("_land_spot"):
		var land: Vector3 = manager._land_spot(p.x, p.z)
		if land != Vector3.INF:
			gp = land
	if manager != null and manager.has_method("ground_y"):
		gp.y = manager.ground_y(gp.x, gp.z) + 0.05
	global_position = gp

func _place_on_land() -> void:
	# safety net: never leave the traveller stranded in open water on a bail-out.
	if _boat != null and is_instance_valid(_boat):
		_boat.queue_free()
		_boat = null
	_place_at(global_position)

func _finish() -> void:
	if manager != null and manager.has_method("_on_envoy_home"):
		manager._on_envoy_home(self)
	queue_free()
