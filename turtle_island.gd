extends Node3D
# ─────────────────────────────────────────────────────────────────────────────
# TurtleIsland — the shared "float + carry children + collide + bond" turtle
# body, used by BOTH world_tribe.gd (rival AI camps) and player_island.gd (the
# player's own camp). Extracted 2026-07-27 at the user's explicit request:
# every turtle-specific bug this session (freeboard, spacing, collision-stick
# overlap, the map-extent clamp gap) had to be found and fixed TWICE across
# two duplicated copies. Keeping this in one place means the next fix only
# needs to happen once, and a future "which turtle does THIS player control"
# multiplayer mode becomes a mode switch on one class instead of a second
# script to keep in sync.
#
# Deliberately narrow scope: this is ONLY the turtle body/drift/collision
# concern. world_tribe.gd's rival-AI roster/diplomacy/quests/economy and
# player_island.gd's own minimal wiring both stay in their own subclass --
# neither belongs here, same reasoning the original two-script split gave for
# not just making player_island.gd "a world_tribe.gd instance."
#
# TINT/MESSAGE OVERRIDES: world_tribe.gd (rival islands) and player_island.gd
# (the player's own camp) each want the shell/limbs to read as visually
# distinct at a glance, and a different collision-notification message.
# Rather than force identical output, this exposes `tint_shell`/`tint_neck`/
# `tint_head`/`tint_leg`/`stick_message` as plain instance vars with defaults
# matching the original rival palette -- a subclass overrides them (see
# player_island.gd's setup()) BEFORE calling _build_turtle_body().
# ─────────────────────────────────────────────────────────────────────────────

var manager = null
var is_turtle: bool = false
var drift_heading: float = 0.0
var steerable: bool = false
var turtle_radius: float = 0.0   # set by whoever builds the body -- world_tribe.gd derives it from territory_radius, player_island.gd sets it directly

const TURTLE_DRIFT_SPEED := 2.2       # m/s, slow enough to actually watch it happen
const TURTLE_HEADING_JITTER := 0.5    # radians/sec of random heading wander (default "float among each other")
const TURTLE_SPACING_MARGIN := 12.0   # clear gap kept beyond bare shell contact
const TURTLE_FREEBOARD := 4.0         # how far the shell's crest sits above the waterline, any island size --
	# raised from 1.2 ("make the turtle shell more above water" -- at 1.2 only a
	# sliver of the crest broke the surface, especially on the bigger islands
const TURTLE_SHELL_Y_SQUASH := 0.5    # vertical flatten factor for the real turtle mesh (a shell should read as a low dome)

var tint_shell: Color = Color(0.22, 0.42, 0.20)
var tint_neck: Color = Color(0.28, 0.40, 0.22)
var tint_head: Color = Color(0.30, 0.42, 0.24)
var tint_leg: Color = Color(0.26, 0.38, 0.20)
var stick_message: String = "Two islands collide and lash together in the current!"

## Local Y of the shell's actual standing surface (its crest) above this
## turtle's own root position -- callers that place something ON the shell
## (spawning the player/members, seating camp-relative props) need this
## instead of a stale hardcoded offset, so they stay correct if
## TURTLE_FREEBOARD is ever retuned again. `const` isn't reliably readable
## through a duck-typed `var player_island = null` reference, so this is
## exposed as a method instead.
func deck_height() -> float:
	return TURTLE_FREEBOARD + 0.6

## GAP FIX (2026-07-28): "put all resources on every shell" -- minerals had
## NO spawn path at all in turtle-islands mode. Tribemanager._spawn_minerals()
## is part of the ambient wilderness-wide scatter, which is deliberately
## skipped entirely once turtle_islands is on (there's no open land to
## scatter across -- see _spawn_world()'s own comment), and nothing ever
## replaced it with a per-shell equivalent the way trees/food/animals already
## got (world_tribe.gd's _spawn_resource_grove()/_tick_local_resources()).
## Shared here (not world_tribe.gd-only) so the player's own island gets real
## stone/ore/gem finds too, not just rival camps. Weights match
## Tribemanager._spawn_minerals()'s own "mountain" table (a turtle island IS
## the whole world in this mode, so it earns that variety, not just Stone).
const MINERAL_WEIGHTED := [
	["Gems", 0.08, 2], ["Obsidian", 0.06, 2], ["Gold", 0.08, 2],
	["Silver", 0.10, 2], ["Coal", 0.18, 3], ["Iron", 0.22, 3], ["Copper", 0.28, 3],
]

func spawn_local_mineral(radius: float) -> void:
	var ang := randf() * TAU
	var r := radius * randf_range(0.4, 0.85)
	var roll := randf()
	var cum := 0.0
	var kind := "Stone"
	var amt := 3
	for entry in MINERAL_WEIGHTED:
		cum += float(entry[1])
		if roll < cum:
			kind = str(entry[0])
			amt = int(entry[2])
			break
	var m := StaticBody3D.new()
	m.set_script(load("res://mineral.gd"))
	m.set("mat_type", kind)
	m.set("amount", amt)
	add_child(m)
	m.position = Vector3(cos(ang) * r, deck_height(), sin(ang) * r)

## Is (x,z) over this turtle's island (for the player-weld check in
## FPSPlayer.gd and any future "who's aboard" logic)? Plain XZ-distance
## check -- the shell is circular, no need for anything fancier. Guards
## against a non-turtle instance (a static land camp, is_turtle == false,
## turtle_radius still 0.0) ever reporting a false positive.
func is_on_turtle(x: float, z: float) -> bool:
	if not is_turtle or turtle_radius <= 0.0:
		return false
	return Vector2(x - global_position.x, z - global_position.z).length() <= turtle_radius

## Default behavior: a slow random-walk heading, "floating among each other" --
## plus a soft repulsion so two islands don't drift into/through one another.
## When `steerable` and a player is actively driving (FPSPlayer sets
## manager._steering_turtle == self, wired in Phase 4), player input overrides
## the heading below instead of this random walk.
func _turtle_tick(delta: float) -> void:
	if not is_turtle:
		return
	if steerable and manager != null and manager.get("_steering_turtle") == self:
		return   # Phase 4: FPSPlayer drives global_position directly while steering

	# ── STUCK TOGETHER (collision bonding) ──────────────────────────────────
	# While bonded to a collision partner, ride along at a FROZEN relative
	# offset instead of drifting independently. This is what stops two
	# islands from ever sliding into/through each other ("morphing"): the
	# offset is fixed at exactly the distance they were at on first contact
	# and never shrinks, for as long as the bond holds.
	if _stuck_to != null:
		if not is_instance_valid(_stuck_to) or not bool(_stuck_to.get("is_turtle")):
			_stuck_to = null
		else:
			_stuck_timer -= delta
			global_position = _stuck_to.global_position + _stuck_offset
			_clamp_to_map()
			if _stuck_timer <= 0.0:
				_release_stick()
			return

	# RELEASE PUSH, spread over time -- see _release_stick()'s own comment
	# for why an instant multi-unit teleport here was a problem. Consumed a
	# little each tick instead of applied all at once.
	if _release_push_remaining > 0.0:
		var step: float = minf(_release_push_remaining, TURTLE_DRIFT_SPEED * 2.5 * delta)
		global_position += _release_push_dir * step
		_release_push_remaining -= step
		_clamp_to_map()

	drift_heading += randf_range(-TURTLE_HEADING_JITTER, TURTLE_HEADING_JITTER) * delta
	var dir := Vector3(cos(drift_heading), 0.0, sin(drift_heading))
	# SOFT "personal space" repulsion -- checked against every other rival AND
	# the player's own island. `other == self` correctly no-ops the
	# self-reference when THIS instance IS the player's own island (its own
	# entry in `manager.get("player_island")` is itself). Threshold is the
	# real shell-to-shell contact distance for THIS pair plus a clear-space
	# margin, not a flat constant.
	var _repel_candidates: Array = []
	if manager != null and "world_tribes" in manager:
		_repel_candidates.append_array(manager.world_tribes)
	if manager != null:
		var _repel_home = manager.get("player_island")
		if _repel_home != null:
			_repel_candidates.append(_repel_home)
	for other in _repel_candidates:
		if other == self or not is_instance_valid(other) or not bool(other.get("is_turtle")):
			continue
		var away: Vector3 = global_position - other.global_position
		away.y = 0.0
		var d := away.length()
		var personal_space: float = turtle_radius + float(other.get("turtle_radius")) + TURTLE_SPACING_MARGIN
		if d > 0.01 and d < personal_space:
			dir += away.normalized() * ((personal_space - d) / personal_space) * 2.0
	var next_pos: Vector3 = global_position
	if dir.length() > 0.01:
		dir = dir.normalized()
		next_pos = global_position + dir * TURTLE_DRIFT_SPEED * delta
		# face the head (built along local +X, see _build_turtle_body()) the
		# way the island is actually swimming -- rotates ONLY the decorative
		# shell/head/legs sub-node, never `self` (the whole camp is parented
		# here too, and spinning the WHOLE root would visibly swing every
		# teepee/totem/resource-grove around like a carousel every time the
		# heading jitters).
		if _turtle_body_visual != null and is_instance_valid(_turtle_body_visual):
			_turtle_body_visual.rotation.y = -atan2(dir.z, dir.x)

	# HARD CONTACT: at true shell-to-shell distance (tighter than the soft
	# repulsion range above, which is just a "personal space" nudge that can
	# still be overwhelmed by several islands converging at once) -- bond
	# instead of overlapping. This is the actual collision trigger.
	var collided_with = _check_hard_collision(next_pos)
	if collided_with != null:
		_begin_stick(collided_with)
		_clamp_to_map()
		return

	global_position = next_pos
	_clamp_to_map()

## Keeps a drifting/bonded/releasing turtle inside the map -- called after
## EVERY position-writing path above, not just the plain-drift one. A prior
## version of this only clamped at the tail of plain drift, which let
## _begin_stick()'s own safe-gap snap (able to move a turtle by up to
## roughly its own radius + the other turtle's radius in a single instant)
## push a turtle past MAP_EXTENT with nothing to pull it back for the whole
## stuck duration -- especially likely right at the map edge, exactly where
## spacing pressure forces tighter contact.
func _clamp_to_map() -> void:
	if manager != null and "MAP_EXTENT" in manager:
		var extent: float = float(manager.MAP_EXTENT)
		global_position.x = clampf(global_position.x, -extent, extent)
		global_position.z = clampf(global_position.z, -extent, extent)

# ── COLLISION STICKING ───────────────────────────────────────────────────────
var _stuck_to = null                    # the turtle we're bonded to, or null
var _stuck_offset: Vector3 = Vector3.ZERO   # OUR position relative to _stuck_to's, frozen at the moment of contact
var _stuck_timer: float = 0.0
const STICK_DURATION := 30.0            # how long a collision bond holds before the pair separates
const STICK_SEPARATE_PUSH := 6.0        # total shove apart on release, spread over time (see _release_stick())
const STICK_SAFE_GAP := 1.5             # minimum clear space kept between shells while bonded -- see _begin_stick()
var _release_push_dir: Vector3 = Vector3.ZERO
var _release_push_remaining: float = 0.0

## True shell-to-shell contact (not the softer TURTLE_SPACING_MARGIN "personal
## space" range above) against any other rival turtle OR the player's own
## island. `home != self` correctly skips the self-reference when THIS
## instance IS the player's own island. Returns the turtle we'd hit at
## `next_pos`, or null.
func _check_hard_collision(next_pos: Vector3):
	if manager == null:
		return null
	if "world_tribes" in manager:
		for other in manager.world_tribes:
			if other == self or not is_instance_valid(other) or not bool(other.get("is_turtle")):
				continue
			var contact: float = turtle_radius + float(other.get("turtle_radius"))
			if Vector2(next_pos.x - other.global_position.x, next_pos.z - other.global_position.z).length() <= contact:
				return other
	var home = manager.get("player_island")
	if home != null and home != self and is_instance_valid(home):
		var contact2: float = turtle_radius + float(home.get("turtle_radius"))
		if Vector2(next_pos.x - home.global_position.x, next_pos.z - home.global_position.z).length() <= contact2:
			return home
	return null

## Two things had to be fixed here, both confirmed via live debug tests.
## (1) The old hard-collision check let a single drift step land AT OR
## SLIGHTLY PAST exact tangency, and the bond then held that (possibly
## overlapping) distance frozen for the full 30s with no separation -- a
## player standing at that seam could get physically wedged between two
## solid StaticBody3D shells with nowhere for move_and_slide() to push them
## out to. Fixed by snapping to a guaranteed clear gap (STICK_SAFE_GAP) the
## instant the bond begins. (2) only the turtle whose OWN _turtle_tick()
## happened to detect the collision used to freeze -- its partner had no idea
## it was "stuck" to anyone, so it kept drifting/soft-repelling normally,
## continually re-pressing into its now partly-frozen partner. Fixed by
## bonding both sides at once (guarded against infinite recursion via the
## `_reciprocal` flag and the `_stuck_to == null` check).
func _begin_stick(other, _reciprocal: bool = false) -> void:
	_stuck_to = other
	var raw_offset: Vector3 = global_position - other.global_position
	var min_gap: float = turtle_radius + float(other.get("turtle_radius")) + STICK_SAFE_GAP
	if raw_offset.length() < min_gap:
		var dir: Vector3 = raw_offset.normalized() if raw_offset.length() > 0.01 else Vector3(1, 0, 0)
		raw_offset = dir * min_gap
		global_position = other.global_position + raw_offset
	_stuck_offset = raw_offset
	_stuck_timer = STICK_DURATION
	if not _reciprocal:
		if other.has_method("_begin_stick") and other.get("_stuck_to") == null:
			other._begin_stick(self, true)
		if manager != null and manager.has_method("notify_cat"):
			manager.notify_cat("tribes", stick_message)

func _release_stick() -> void:
	var away: Vector3 = _stuck_offset
	away.y = 0.0
	_stuck_to = null
	_stuck_offset = Vector3.ZERO
	drift_heading = randf_range(0.0, TAU)   # a fresh heading so it doesn't immediately drift back into its old partner
	# spread the separation out over the next several ticks instead of one
	# instant teleport -- see _turtle_tick()'s own consumption of this.
	if away.length() > 0.01:
		_release_push_dir = away.normalized()
		_release_push_remaining = STICK_SEPARATE_PUSH

## A modest static shell + collider, added as a CHILD of this node (so it
## inherits the same "moves for free when the parent moves" behavior as
## every other structure parented onto the camp root). Not a piece of the
## world's terrain -- terrain_gen.gd is one static global heightmap and can't
## have a piece cut out and moved; this is new, separate local geometry that
## rides alongside the static ocean. Caller must set `turtle_radius` (and any
## tint_*/stick_message overrides) BEFORE calling this.
var _turtle_body_visual: Node3D = null   # wraps shell+head+legs so drift-facing rotation doesn't spin the whole camp

func _build_turtle_body() -> void:
	# All the decorative "this is a real turtle" geometry lives under its own
	# sub-node so _turtle_tick() can rotate it to face the swim direction
	# without spinning `self` (which is also the parent of every teepee/
	# totem/resource-grove in a tribe's camp -- rotating THAT would swing the
	# whole camp around like a carousel every time the heading jitters).
	_turtle_body_visual = Node3D.new()
	add_child(_turtle_body_visual)

	# REAL ASSET: a genuine turtle model (CC0, from OpenGameArt -- a
	# different source than the Kenney packs used elsewhere in this project,
	# since neither Kenney nor Quaternius had a turtle) instead of a bare
	# cylinder disc. Recolored (material_override) -- the model has no baked
	# texture, so this is safe. Falls back to the old cylinder if the asset
	# is ever missing.
	var shell := _try_real_turtle_shell(turtle_radius)
	if shell == null:
		shell = MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = turtle_radius
		cm.bottom_radius = turtle_radius * 0.85
		cm.height = 3.0
		shell.mesh = cm
		shell.position = Vector3(0, TURTLE_FREEBOARD - 1.5, 0)
	shell.material_override = MatCache.flat(tint_shell)
	_turtle_body_visual.add_child(shell)

	# HEAD + NECK, poking out along local +X (the direction _turtle_tick()
	# faces the visual root toward) -- what actually reads this as "a turtle"
	# instead of a floating disc. Raised above the local waterline (Y 0,
	# since this node's parent sits at global Y == water_level).
	var neck := MeshInstance3D.new()
	var neck_mesh := CapsuleMesh.new()
	neck_mesh.radius = turtle_radius * 0.10
	neck_mesh.height = turtle_radius * 0.55
	neck.mesh = neck_mesh
	neck.rotation.z = deg_to_rad(90.0)
	neck.position = Vector3(turtle_radius * 1.05, TURTLE_FREEBOARD * 0.5, 0)
	neck.material_override = MatCache.flat(tint_neck)
	_turtle_body_visual.add_child(neck)

	var head := MeshInstance3D.new()
	var head_radius: float = turtle_radius * 0.16
	var head_mesh := SphereMesh.new()
	head_mesh.radius = head_radius
	head_mesh.height = head_radius * 2.0
	head.mesh = head_mesh
	head.position = Vector3(turtle_radius * 1.32, TURTLE_FREEBOARD * 0.75, 0)
	head.material_override = MatCache.flat(tint_head)
	_turtle_body_visual.add_child(head)

	# EYES: two small dark spheres on the head so the turtle actually reads
	# as a face up close, not a blank ball. Children of `head` so they
	# inherit its position for free.
	for side in [1.0, -1.0]:
		var eye := MeshInstance3D.new()
		var eye_r: float = head_radius * 0.28
		var eye_mesh := SphereMesh.new()
		eye_mesh.radius = eye_r
		eye_mesh.height = eye_r * 2.0
		eye.mesh = eye_mesh
		eye.position = Vector3(head_radius * 0.65, head_radius * 0.15, side * head_radius * 0.75)
		eye.material_override = MatCache.flat(Color(0.05, 0.05, 0.05))
		head.add_child(eye)

	# LEGS -- 4 stubby flippers angled down/outward at the diagonals, so the
	# silhouette from any angle reads as a turtle paddling, not a cylinder.
	# These stay underwater (correct for paddling flippers) -- unaffected by
	# the freeboard math, which only concerns parts meant to show above water.
	var leg_offsets := [Vector2(1, 1), Vector2(1, -1), Vector2(-1, 1), Vector2(-1, -1)]
	var leg_radius: float = turtle_radius * 0.09
	var leg_height: float = turtle_radius * 0.5
	var body := StaticBody3D.new()
	for lo in leg_offsets:
		var leg := MeshInstance3D.new()
		var leg_mesh := CapsuleMesh.new()
		leg_mesh.radius = leg_radius
		leg_mesh.height = leg_height
		leg.mesh = leg_mesh
		leg.rotation.x = deg_to_rad(70.0) * lo.y
		leg.rotation.z = deg_to_rad(20.0) * -lo.x
		leg.position = Vector3(turtle_radius * 0.75 * lo.x, -1.7, turtle_radius * 0.75 * lo.y)
		leg.material_override = MatCache.flat(tint_leg)
		_turtle_body_visual.add_child(leg)

		# LIMB COLLISION -- "make sure turtle is physically solid limbs too."
		# Matches the visual leg's own transform exactly.
		var leg_col := CollisionShape3D.new()
		var leg_shape := CapsuleShape3D.new()
		leg_shape.radius = leg_radius
		leg_shape.height = leg_height
		leg_col.shape = leg_shape
		leg_col.position = leg.position
		leg_col.rotation = leg.rotation
		body.add_child(leg_col)

	# HEAD + NECK COLLISION -- same "solid limbs" fix, so the head/neck can't
	# be walked or swum through either.
	var head_col := CollisionShape3D.new()
	var head_shape := SphereShape3D.new()
	head_shape.radius = head_radius
	head_col.shape = head_shape
	head_col.position = head.position
	body.add_child(head_col)

	var neck_col := CollisionShape3D.new()
	var neck_shape := CapsuleShape3D.new()
	neck_shape.radius = neck_mesh.radius
	neck_shape.height = neck_mesh.height
	neck_col.shape = neck_shape
	neck_col.position = neck.position
	neck_col.rotation = neck.rotation
	body.add_child(neck_col)

	# Shell collision stays on `self` directly (not the rotating visual root)
	# -- is_on_turtle()/the player-weld check are plain XZ-distance tests
	# that don't care about facing, and the collider shouldn't wobble as the
	# heading jitters.
	#
	# BUG FIX (2026-07-28): "still cant swim under water and jump out of
	# water back onto land" -- this used to be a flat-topped CylinderShape3D:
	# a sheer vertical wall from the waterline up to the crest. Swimming into
	# it, physics has nothing to do but push you back out HORIZONTALLY (the
	# only separating direction a straight wall offers) -- there's no slope
	# for buoyancy + move_and_slide to carry you up and out onto the deck.
	# Replaced with a real sloped frustum (wide base at the waterline,
	# tapering up to a flat plateau at the crest) via _build_dome_shape(),
	# so approaching a shell while swimming actually climbs you out like a
	# real shoreline, and the flat plateau at the top is still generous
	# enough to build a whole camp on.
	var col := CollisionShape3D.new()
	col.shape = _build_dome_shape()
	body.add_child(col)
	body.add_to_group("turtle_body")
	add_child(body)

## Builds a sloped-frustum ConvexPolygonShape3D approximating the shell's
## domed silhouette: wide at the waterline, tapering up to a flat plateau at
## the crest (PLATEAU_FRACTION of the full radius -- generous enough to hold
## a whole camp's footprint on flat ground; see world_tribe.gd's grove trees,
## which spread out to ~0.82 * turtle_radius). Godot computes the actual
## convex hull from these ring points itself (ConvexPolygonShape3D.points),
## so this only has to supply a point on each ring, not faces/indices.
const DOME_RING_SEGMENTS := 16
const DOME_PLATEAU_FRACTION := 0.85

func _build_dome_shape() -> ConvexPolygonShape3D:
	var plateau_r: float = turtle_radius * DOME_PLATEAU_FRACTION
	var pts := PackedVector3Array()
	# ring A: the wide base, a little below the waterline so there's no gap
	# between "swimming" and "touching the slope" right at the surface.
	# ring B: where the slope meets the flat plateau.
	# ring C: the plateau's own top surface (a little thickness, not a
	# zero-height disc, so nothing can dig in from directly above).
	var rings := [
		{"r": turtle_radius, "y": -1.0},
		{"r": plateau_r,     "y": TURTLE_FREEBOARD - 0.3},
		{"r": plateau_r,     "y": TURTLE_FREEBOARD + 1.0},
	]
	for ring in rings:
		var r: float = ring["r"]
		var y: float = ring["y"]
		for i in range(DOME_RING_SEGMENTS):
			var a := TAU * float(i) / float(DOME_RING_SEGMENTS)
			pts.append(Vector3(cos(a) * r, y, sin(a) * r))
	var shape := ConvexPolygonShape3D.new()
	shape.points = pts
	return shape

## Loads the real turtle model (OpenGameArt CC0), scaled to fill this
## island's actual footprint. The raw mesh measures roughly 1.8 half-width x
## 1.17 half-depth (an oval shell, not a circle) -- AVG_HALF_EXTENT is the
## mean of those, used as the reference "radius" to scale against
## turtle_radius. Flattened vertically (TURTLE_SHELL_Y_SQUASH) since a shell
## should read as a low dome at island scale, not a tall lump. Returns null
## (caller falls back to the old procedural cylinder) if the asset is missing.
const TURTLE_SHELL_GLB := "res://assets/nature/turtle.glb"
const TURTLE_SHELL_AVG_HALF_EXTENT := 1.485

func _try_real_turtle_shell(radius: float) -> MeshInstance3D:
	if not ResourceLoader.exists(TURTLE_SHELL_GLB):
		return null
	var packed: PackedScene = load(TURTLE_SHELL_GLB)
	var inst := packed.instantiate()
	var found := _find_mesh_child(inst)
	if found == null:
		inst.queue_free()
		return null
	found.get_parent().remove_child(found)
	inst.queue_free()
	# FREEBOARD: solve for the offset from the mesh's own measured AABB so
	# the crest always sits exactly TURTLE_FREEBOARD above the waterline,
	# for any radius, instead of a fixed offset that only coincidentally
	# works at one specific radius.
	var local_aabb: AABB = found.get_aabb()
	var s: float = radius / TURTLE_SHELL_AVG_HALF_EXTENT
	found.scale = Vector3(s, s * TURTLE_SHELL_Y_SQUASH, s)
	var top_local: float = (local_aabb.position.y + local_aabb.size.y) * s * TURTLE_SHELL_Y_SQUASH
	found.position = Vector3(0, TURTLE_FREEBOARD - top_local, 0)
	return found

func _find_mesh_child(root_node: Node) -> MeshInstance3D:
	if root_node is MeshInstance3D:
		return root_node as MeshInstance3D
	for c in root_node.get_children():
		var f := _find_mesh_child(c)
		if f != null:
			return f
	return null
