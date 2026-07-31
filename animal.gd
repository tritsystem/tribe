extends CharacterBody3D
# ─────────────────────────────────────────────────────────────────────────────
# Animal — a wild creature run by its OWN Spikeling brain (same engine as the
# tribe). It senses nearby threats and FLEES; it builds Hunger and seeks a bush
# to GRAZE; otherwise it WANDERS.
#
# Now comes in several SPECIES, each with different stats AND a different brain
# (a jumpy Rabbit has a strong SeeThreat->Flee synapse + keen senses; a stubborn
# Boar barely spooks). HUNT orders / the player's club kill them for meat+skins.
# In groups "animal" (huntable) and "has_brain" (B brain-viewer shows it).
# ─────────────────────────────────────────────────────────────────────────────

const SpatialGrid = preload("res://spatial_grid.gd")

var brain: Spikeling
var anim: BodyAnim
## BUG FIXED (2026-07-19): was typed MeshInstance3D -- fine while _head was
## always a real mesh sphere, but the real modeled animals' HeadMarker is a
## plain Node3D empty (no mesh of its own, just an eye-attachment point).
## Assigning a Node3D into a var strictly typed MeshInstance3D silently
## nulled it out instead of erroring, which broke both eye placement AND
## anim.setup()'s head-driven animation for every real model.
var _head: Node3D
var _legs: Array = []      # Leg0..Leg3, each pivoting at its own hip -- see _animate_legs()
var _leg_phase: float = 0.0
@export var species: String = "Deer"
@export var member_name: String = "Deer"     # lets the brain-viewer label it
@export var personality: String = "Wild"     # ditto (duck-typed with members)

var sense_radius: float = 7.0
var wander_speed: float = 1.7
var flee_speed: float = 2.4
var food_yield: int = 2
var skins_yield: int = 1

# DIVERSITY PASS (2026-07-19): "10x the diversity of animals" -- was 3
# species. Same stat shape (color/scale/wander/flee/sense/food/skins/
# threat_w), just more of them, spanning a real range from jumpy/low-yield
# to dangerous/high-yield so hunting still has texture across a whole map.
const SPECIES := {
	"Rabbit":  {"color": Color(0.80, 0.78, 0.72), "scale": 0.55, "wander": 2.1, "flee": 3.3, "sense": 9.5, "food": 1, "skins": 0, "threat_w": 160},
	"Hare":    {"color": Color(0.72, 0.68, 0.60), "scale": 0.50, "wander": 2.3, "flee": 3.6, "sense": 10.0, "food": 1, "skins": 0, "threat_w": 170},
	"Fox":     {"color": Color(0.75, 0.35, 0.18), "scale": 0.70, "wander": 1.9, "flee": 3.0, "sense": 8.5, "food": 1, "skins": 1, "threat_w": 150},
	"Deer":    {"color": Color(0.55, 0.40, 0.28), "scale": 1.0,  "wander": 1.7, "flee": 2.5, "sense": 7.0, "food": 2, "skins": 1, "threat_w": 130},
	"Goat":    {"color": Color(0.68, 0.66, 0.60), "scale": 0.85, "wander": 1.6, "flee": 2.3, "sense": 6.5, "food": 2, "skins": 1, "threat_w": 120},
	"Elk":     {"color": Color(0.42, 0.32, 0.20), "scale": 1.3,  "wander": 1.5, "flee": 2.2, "sense": 6.0, "food": 3, "skins": 2, "threat_w": 110},
	"Boar":    {"color": Color(0.34, 0.30, 0.28), "scale": 1.15, "wander": 1.3, "flee": 1.9, "sense": 5.0, "food": 3, "skins": 2, "threat_w": 95},
	"Wolf":    {"color": Color(0.50, 0.50, 0.52), "scale": 1.05, "wander": 1.8, "flee": 1.6, "sense": 8.0, "food": 2, "skins": 2, "threat_w": 70},
	"Bear":    {"color": Color(0.30, 0.22, 0.16), "scale": 1.6,  "wander": 1.1, "flee": 1.3, "sense": 5.5, "food": 4, "skins": 2, "threat_w": 50},
}

## REAL ASSET SWAP (2026-07-28): "still need better animal skins" -- the
## gen_animals.py primitives (flat baked color, no fur/skin texture) are
## being replaced species-by-species with real downloaded CC0/CC-BY models
## (Quaternius's animated pack + a molochdadev/Poly-by-Google bundle, both via
## poly.pizza). No free, no-login model was found for Hare specifically, so it
## reuses Rabbit's real mesh -- the two read as near-identical animals anyway,
## and Hare keeps its own distinct stats/brain via SPECIES above regardless of
## which model renders it. Boar has no real model yet either; it stays on
## _build_fallback() below until one is sourced.
const ASSET_ALIAS := {"Hare": "Rabbit"}

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
var home_pos: Vector3 = Vector3.ZERO
var _wander_target: Vector3 = Vector3.ZERO
var _wander_pause: float = 0.0
var _threat: Node3D = null
var _flee_timer: float = 0.0
var _graze_timer: float = 0.0
var _look_cd: float = 0.0         # time until next idle "scan around" head/body turn
var _tick_accum: float = 0.0
const TICK_HZ := 10.0
const ARRIVE := 0.6
var _stuck_cd: float = 0.0       # throttles the snagged-on-something check
var _last_pos: Vector3 = Vector3.ZERO

func _ready() -> void:
	add_to_group("animal")
	add_to_group("has_brain")
	# stick to sloping ground instead of bouncing off it (see tribemember)
	floor_snap_length = 0.8
	floor_max_angle = deg_to_rad(54.0)
	floor_constant_speed = true
	var sp: Dictionary = SPECIES.get(species, SPECIES["Deer"])
	wander_speed = sp["wander"]
	flee_speed = sp["flee"]
	sense_radius = sp["sense"]
	food_yield = int(sp["food"])
	skins_yield = int(sp["skins"])
	member_name = species
	brain = Spikeling.new()
	if not brain.load_from_text(_brain_text(sp)):
		push_error("Animal: brain failed to load")
	home_pos = global_position
	_wander_target = home_pos
	_build(sp)
	anim = BodyAnim.new()
	anim.setup([get_node_or_null("Mesh"), _head])

func _brain_text(sp: Dictionary) -> String:
	var t := "# Spikeling Neural Configuration\n"
	t += "neuron SeeThreat threshold=50 leak=25\n"
	t += "neuron Hunger    threshold=100 leak=0\n"
	t += "neuron Flee      threshold=100 leak=12\n"
	t += "neuron Graze     threshold=100 leak=8\n"
	t += "synapse SeeThreat -> Flee weight=%d\n" % int(sp["threat_w"])
	t += "synapse Hunger    -> Graze weight=95\n"
	t += "refractory=2\n"
	return t

## REAL MODELED ASSETS (2026-07-19): a proper low-poly quadruped body
## (torso/head/snout/ears/legs/tail, generated in Blender -- see
## tools/gen_animals.py) instead of a bare capsule+sphere. Each species'
## .glb carries its own proportions and baked material color, matching the
## SPECIES stats they're built from. The googly eyes are deliberately NOT
## baked into the mesh -- they stay a runtime GDScript behavior (the
## existing wobble/pupil-offset look every creature in this game shares),
## just attached to a real "HeadMarker" empty the model leaves at the
## snout instead of to a bare sphere. Falls back to the old primitive body
## if the asset is somehow missing, so a missing file never breaks the game.
## A "scale=1.0" creature should end up roughly this tall (shoulder height,
## in metres) -- calibrated to the old gen_animals.py rig's own native size
## at scale=1.0 (its Deer, leg_len+body_h, comes out to ~0.94), so real
## downloaded models normalize to about the same footprint the old primitives
## already played at.
const ANIMAL_REF_HEIGHT := 1.0

func _build(sp: Dictionary) -> void:
	var s := float(sp["scale"])
	var asset_species: String = ASSET_ALIAS.get(species, species)
	var glb_path := "res://assets/animals/%s.glb" % asset_species.to_lower()
	var packed: PackedScene = load(glb_path) if ResourceLoader.exists(glb_path) else null
	if packed == null:
		_build_fallback(sp)
		return

	var model := packed.instantiate()
	model.name = "Mesh"
	add_child(model)

	# SCALE NORMALIZATION (2026-07-28): "rabbits and bears are HUGE and
	# misshapen" -- `s` (SPECIES[x]["scale"]) was tuned against the old
	# gen_animals.py rig's own native size, where a bare `Vector3(s,s,s)`
	# happened to come out right. A downloaded real-world model (Quaternius /
	# Poly-by-Google) has its OWN native export scale, completely unrelated to
	# that assumption -- multiplying by `s` directly could be wildly wrong in
	# either direction. Measuring the model's actual mesh bounds and solving
	# for the scale that lands it at the species' intended height (same
	# `ANIMAL_REF_HEIGHT * s` target every species already implies) works
	# regardless of what units the source file was exported in.
	var native_height := _mesh_height(model)
	var vscale: float = s
	if native_height > 0.01:
		vscale = (ANIMAL_REF_HEIGHT * s) / native_height
	model.scale = Vector3(vscale, vscale, vscale)

	# HeadMarker only exists on the old gen_animals.py rig -- a downloaded
	# real-world model (Quaternius/Poly-by-Google) already has its own
	# sculpted face, so only bolt on the cartoon googly eyes when that marker
	# is actually present (i.e. still the old primitive-derived rig).
	var marker := _find_node_named(model, "HeadMarker")
	if marker != null:
		_head = marker as Node3D
		_build_googly_eyes(_head, 0.22 * vscale)
	else:
		_head = model

	# REAL LEG ANIMATION (2026-07-19): "can we give animations" -- the model
	# carries 4 separate leg objects (Leg0..Leg3, each pivoting at its own
	# hip -- see tools/gen_animals.py's build_leg()) specifically so they
	# can be rotated individually here instead of only ever being part of a
	# single fused, unanimatable body mesh.
	_legs.clear()
	for i in range(4):
		var leg := _find_node_named(model, "Leg%d" % i)
		if leg != null and leg is Node3D:
			_legs.append(leg)

	var label := Label3D.new()
	label.text = species
	label.position = Vector3(0, 1.8 * vscale, 0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.modulate = Color(0.9, 0.85, 0.7)
	add_child(label)

	var col := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 0.4 * vscale
	shape.height = 1.4 * vscale
	col.shape = shape
	col.position = Vector3(0, 0.7 * vscale, 0)
	add_child(col)

## Measures `root`'s combined mesh bounds (all VisualInstance3D descendants,
## however deep -- Quaternius's animated models carry a skeleton in between)
## and returns the height (Y extent), in root's OWN local space so it's
## independent of wherever root has actually been parented/positioned.
## Requires root to already be inside the tree (global_transform valid).
func _mesh_height(root: Node3D) -> float:
	var combined := AABB()
	var found := false
	var stack: Array = [root]
	while not stack.is_empty():
		var n = stack.pop_back()
		if n is VisualInstance3D:
			var world_aabb: AABB = (n as VisualInstance3D).global_transform * (n as VisualInstance3D).get_aabb()
			var local_aabb: AABB = root.global_transform.affine_inverse() * world_aabb
			combined = local_aabb if not found else combined.merge(local_aabb)
			found = true
		for c in n.get_children():
			stack.append(c)
	return combined.size.y if found else 0.0

func _find_node_named(root: Node, name: String) -> Node:
	if root.name == name:
		return root
	for c in root.get_children():
		var found := _find_node_named(c, name)
		if found != null:
			return found
	return null

## Original primitive body -- kept as a real fallback (not dead code) for
## if a species' .glb is ever missing/fails to load, so a bad asset path
## degrades gracefully instead of leaving the animal invisible/broken.
func _build_fallback(sp: Dictionary) -> void:
	var s := float(sp["scale"])
	var mat := MatCache.flat(sp["color"])

	var body := MeshInstance3D.new()
	body.name = "Mesh"
	var cap := CapsuleMesh.new()
	cap.radius = 0.4 * s
	cap.height = 1.2 * s
	body.mesh = cap
	body.position = Vector3(0, 0.7 * s, 0)
	body.material_override = mat
	add_child(body)

	var head := MeshInstance3D.new()
	var hs := SphereMesh.new()
	hs.radius = 0.25 * s
	hs.height = 0.5 * s
	head.mesh = hs
	head.position = Vector3(0, 0.95 * s, 0.5 * s)
	head.material_override = mat
	add_child(head)
	_head = head
	_build_googly_eyes(head, 0.25 * s)

	var label := Label3D.new()
	label.text = species
	label.position = Vector3(0, 1.6 * s, 0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.modulate = Color(0.9, 0.85, 0.7)
	add_child(label)

	var col := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 0.4 * s
	shape.height = 1.4 * s
	col.shape = shape
	col.position = Vector3(0, 0.7 * s, 0)
	add_child(col)

# two white sphere "eyes" with off-center black pupils, parented to the
# given head node — shared look across animals/npcs/tribemembers
func _build_googly_eyes(parent: Node3D, head_radius: float) -> void:
	for side in [-1.0, 1.0]:
		var eye := MeshInstance3D.new()
		var es := SphereMesh.new()
		es.radius = head_radius * 0.32
		es.height = head_radius * 0.64
		eye.mesh = es
		eye.position = Vector3(side * head_radius * 0.55, head_radius * 0.25, head_radius * 0.85)
		eye.material_override = MatCache.flat(Color(1, 1, 1))
		eye.add_to_group("googly_eye")   # decorative → far-culled centrally
		parent.add_child(eye)

		var pupil := MeshInstance3D.new()
		var ps := SphereMesh.new()
		ps.radius = head_radius * 0.14
		ps.height = head_radius * 0.28
		pupil.mesh = ps
		# pupils sit slightly off-center for the classic googly-eye wobble look
		pupil.position = Vector3(randf_range(-0.04, 0.04), randf_range(-0.04, 0.04), head_radius * 0.3)
		pupil.material_override = MatCache.flat(Color(0.05, 0.05, 0.05))
		eye.add_child(pupil)

# ── SIMULATION LOD — animals aren't owned by a tribe (no world_tribe._tick_lod
# to switch them off), so each one self-manages a cheap distance gate. Beyond
# LOD_FAR_DIST from the player, physics_process is turned OFF entirely (zero
# per-frame AI + move_and_slide + heightmap-collision cost — the single biggest
# saving at scale, since most of the herd is nowhere near you). The gate itself
# runs in _process (which keeps ticking while physics_process is off) on a slow
# ~0.5s poll, so a far animal costs one distance check twice a second and
# nothing else. It re-wakes the moment you get close, resuming exactly where it
# left off. Distance changes slowly relative to the poll, so nothing pops.
const LOD_FAR_DIST := 65.0
var _lod_accum: float = 0.0

func _process(delta: float) -> void:
	_lod_accum -= delta
	if _lod_accum > 0.0:
		return
	_lod_accum = randf_range(0.4, 0.6)
	# PERF/SEARCH FIX (2026-07-19): _nearest_animal() (tribemember.gd) used to
	# scan get_tree().get_nodes_in_group("animal") in full every call. This
	# tick already fires a few times a second regardless of LOD tier, so it's
	# a free place to keep this animal's SpatialGrid cell current as it roams.
	SpatialGrid.update(self)
	var p := get_tree().get_first_node_in_group("player") as Node3D
	if p == null or not is_instance_valid(p):
		return
	var far: bool = global_position.distance_to(p.global_position) > LOD_FAR_DIST
	if far == is_physics_processing():
		# entering FAR while currently processing, or leaving FAR while stopped
		set_physics_process(not far)
		if far:
			_tick_accum = 0.0   # no burst of catch-up brain ticks on re-entry

func _physics_process(delta: float) -> void:
	_tick_accum += delta
	var interval := 1.0 / TICK_HZ
	while _tick_accum >= interval:
		_tick_accum -= interval
		_brain_tick()
	_move(delta)
	_check_stuck(delta)
	_animate_body(delta)

# animals have no club to bash through a fence with — if they're snagged on
# one (or any obstacle) while clearly trying to move, just shove sideways and
# pick a fresh wander target so they path around it instead of jamming forever
func _check_stuck(delta: float) -> void:
	_stuck_cd -= delta
	if _stuck_cd > 0.0:
		return
	_stuck_cd = 0.6
	var moved := global_position.distance_to(_last_pos)
	_last_pos = global_position
	if Vector2(velocity.x, velocity.z).length() > 0.3 and moved < 0.12:
		# find the nearest obstacle (incl. trees animals can't bash) and push
		# directly away from it, heading somewhere clear -- not a random shove
		# that often re-charges the same trunk/fence.
		var obstacle: Node3D = null
		var od := 2.4
		for grp in ["tree", "block", "fence"]:
			for f in get_tree().get_nodes_in_group(grp):
				var fn := f as Node3D
				if fn and is_instance_valid(fn):
					var d := global_position.distance_to(fn.global_position)
					if d < od:
						od = d
						obstacle = fn
		var away := Vector3(randf() - 0.5, 0.0, randf() - 0.5)
		if obstacle != null:
			away = global_position - obstacle.global_position
			away.y = 0.0
		if away.length() < 0.01:
			away = Vector3(randf() - 0.5, 0.0, randf() - 0.5)
		away = away.normalized()
		var perp := Vector3(-away.z, 0.0, away.x)
		if randf() < 0.5:
			perp = -perp
		velocity.x += (away.x * 1.5 + perp.x) * wander_speed
		velocity.z += (away.z * 1.5 + perp.z) * wander_speed
		_wander_target = global_position + (away + perp * 0.5).normalized() * randf_range(3.0, 6.0)
		_wander_target.y = home_pos.y

# walk-bob + breathing, with a nervous tremble that rises straight from the
# SeeThreat neuron as a predator closes in — the brain showing on the body.
func _animate_body(delta: float) -> void:
	if anim == null:
		return
	var spd := Vector2(velocity.x, velocity.z).length()
	anim.tension = clampf(brain.get_potential("SeeThreat") / 50.0, 0.0, 1.0)
	anim.tick(delta, spd, is_on_floor())
	_animate_legs(delta, spd)

## Real per-leg walk cycle -- a diagonal/trot gait (front-left + back-right
## swing together, front-right + back-left opposite), the natural gait for
## a walking quadruped. Rotates each leg from its own hip pivot (each Leg
## object's local origin IS its hip -- see build_leg() in gen_animals.py),
## so this needs no inverse kinematics, just a rotation offset.
const LEG_SWING_MAX := 0.55         # radians at a full stride
const LEG_SWING_REF_SPEED := 2.6    # speed that reads as a full walk

## AXIS FIX (2026-07-27): "legs go sideways not forward/backward" -- these
## legs were rotating on LOCAL X, which swings the foot between "hanging
## down" and "out to the side". The Blender->glTF Y-up export swaps Blender's
## authoring axes (spine/length along Blender X, side-to-side on Blender Y,
## up on Blender Z) onto Godot's (X stays X, Blender Z -> Godot Y, Blender Y
## -> Godot Z) -- see gen_animals.py's own axis-fix comment on HeadMarker,
## which hit the exact same remap for a different node. Rotating LOCAL Z
## (which mixes X="forward/back" and Y="hanging down") is what actually
## swings the foot fore-and-aft; LOCAL X was mixing Y and Z, i.e. down and
## sideways.
func _animate_legs(delta: float, speed: float) -> void:
	if _legs.size() < 4:
		return
	var move := clampf(speed / LEG_SWING_REF_SPEED, 0.0, 1.0)
	if move < 0.03:
		for l in _legs:
			(l as Node3D).rotation.z = move_toward((l as Node3D).rotation.z, 0.0, delta * 6.0)
		return
	_leg_phase += delta * (5.0 + speed * 2.5)
	var swing := LEG_SWING_MAX * move
	(_legs[0] as Node3D).rotation.z = sin(_leg_phase) * swing          # front-left
	(_legs[3] as Node3D).rotation.z = sin(_leg_phase) * swing          # back-right
	(_legs[1] as Node3D).rotation.z = sin(_leg_phase + PI) * swing     # front-right
	(_legs[2] as Node3D).rotation.z = sin(_leg_phase + PI) * swing     # back-left

# ── one spiking tick: feed senses in, read drives out ──
var _threat_scan_cd: float = 0.0

func _brain_tick() -> void:
	# _nearest_threat() scans every player/tribe/npc/club node in the scene —
	# O(active_animals x total_npcs) if run every brain tick (8Hz). At Epic that
	# scan, multiplied across the whole nearby herd, was the animals' dominant
	# per-frame cost. Prey doesn't need 8Hz predator sampling: rescan a few times
	# a second and reuse the cached threat in between. Startle latency stays well
	# under the flee reaction anyone would notice.
	_threat_scan_cd -= 1.0 / TICK_HZ
	if _threat_scan_cd <= 0.0:
		_threat_scan_cd = randf_range(0.3, 0.45)
		_threat = _nearest_threat()
	var threat: Node3D = _threat if is_instance_valid(_threat) else null
	if threat:
		_threat = threat
		var dist := global_position.distance_to(threat.global_position)
		var closeness := 1.0 - clampf(dist / sense_radius, 0.0, 1.0)
		brain.stimulate("SeeThreat", 30.0 + 60.0 * closeness)
	brain.stimulate("Hunger", 2.2)   # appetite builds over time
	var fired: Array = brain.step()
	if "Flee" in fired:
		_flee_timer = 1.6
		if anim: anim.pop(0.7)       # bolt — a sharp startle hop
	if "Graze" in fired:
		_graze_timer = 2.6
		if anim: anim.pop(0.2)       # a calm little nibble-bob

func _nearest_threat() -> Node3D:
	var best: Node3D = null
	var bd := sense_radius
	for grp in ["player", "tribe", "npc", "thrown_club"]:
		for t in get_tree().get_nodes_in_group(grp):
			var n := t as Node3D
			if n and is_instance_valid(n):
				var d := global_position.distance_to(n.global_position)
				if d < bd:
					bd = d
					best = n
	return best

## TURTLE-ISLAND AWARENESS (2026-07-27): see tribemember.gd's own copy of this
## fix for the full reasoning (including two bugs found via a live
## debug-teleport test: running the AI alongside the swim produces a stable
## orbit, and swimming via move_and_slide() orbits too since the disc's
## collision is a solid cylinder whose SIDE a horizontal swim collides with
## and slides along rather than crossing -- fixed by skipping the normal AI
## entirely while swimming, and using a direct position write that climbs
## toward the deck's height instead of move_and_slide()). Animals have no
## owning tribe, so their home turtle is resolved once (nearest to home_pos,
## the land-gated spawn anchor) and cached -- not rescanned every frame.
func _move(delta: float) -> void:
	if _turtle_swim_recovery(delta):
		return
	_move_impl(delta)

const TURTLE_SWIM_SPEED := 3.5
var _cached_home_turtle = null

func _resolve_home_turtle():
	if _cached_home_turtle != null and is_instance_valid(_cached_home_turtle):
		return _cached_home_turtle
	var mgr = get_tree().get_first_node_in_group("tribe_manager")
	if mgr == null:
		return null
	var best = null
	var best_d := INF
	var home = mgr.get("player_island")
	if home != null and is_instance_valid(home):
		best_d = Vector2(home_pos.x - home.global_position.x, home_pos.z - home.global_position.z).length()
		best = home
	if "world_tribes" in mgr:
		for wt in mgr.world_tribes:
			if wt == null or not is_instance_valid(wt):
				continue
			var d := Vector2(home_pos.x - wt.global_position.x, home_pos.z - wt.global_position.z).length()
			if d < best_d:
				best_d = d
				best = wt
	_cached_home_turtle = best
	return best

func _turtle_swim_recovery(delta: float) -> bool:
	var mgr = get_tree().get_first_node_in_group("tribe_manager")
	if mgr == null or not bool(mgr.get("turtle_islands")):
		return false
	var home_turtle = _resolve_home_turtle()
	if home_turtle == null or not is_instance_valid(home_turtle):
		return false
	var r: float = float(home_turtle.get("turtle_radius"))
	if r <= 0.0:
		return false
	var away: Vector3 = global_position - home_turtle.global_position
	away.y = 0.0
	var d := away.length()
	if d <= r - 2.0:
		return false   # safely on the disc -- normal AI movement applies
	var dir: Vector3 = -away.normalized() if d > 0.01 else Vector3.FORWARD
	global_position.x += dir.x * TURTLE_SWIM_SPEED * delta
	global_position.z += dir.z * TURTLE_SWIM_SPEED * delta
	# BUG FIX (2026-07-28): stop duplicating TURTLE_FREEBOARD as a local
	# constant -- it drifted out of sync the moment the real one
	# (turtle_island.gd) got retuned. Ask the turtle itself instead.
	var deck_y: float = home_turtle.global_position.y + float(home_turtle.deck_height()) + 0.5
	global_position.y = move_toward(global_position.y, deck_y, 2.5 * delta)
	velocity = Vector3.ZERO
	return true

func _move_impl(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = 0.0

	if _flee_timer > 0.0:
		_flee_timer -= delta
		var dir := Vector3.ZERO
		if _threat and is_instance_valid(_threat):
			dir = global_position - _threat.global_position
		dir.y = 0.0
		if dir.length() < 0.01:
			dir = Vector3(randf() - 0.5, 0, randf() - 0.5)
		_drive(dir.normalized(), flee_speed, delta)
	elif _graze_timer > 0.0:
		_graze_timer -= delta
		var bush := _nearest_bush()
		if bush and is_instance_valid(bush):
			var to := bush.global_position - global_position
			to.y = 0.0
			if to.length() > 1.3:
				_drive(to.normalized(), wander_speed, delta)
			else:
				_halt()
				_face(bush.global_position, delta)
				if bush.has_method("graze"):
					bush.graze(delta)
		else:
			_wander(delta)
	else:
		_wander(delta)

	move_and_slide()

func _wander(delta: float) -> void:
	if _wander_pause > 0.0:
		_wander_pause -= delta
		_halt()
		_idle_look(delta)
		return
	var d := global_position - _wander_target
	d.y = 0.0
	if d.length() <= ARRIVE:
		var ang := randf() * TAU
		var r := randf() * 8.0
		_wander_target = home_pos + Vector3(cos(ang), 0, sin(ang)) * r
		_wander_target.y = home_pos.y
		# KEEP ANIMALS OUT OF THE SEA. home_pos is on land (land-gated at spawn),
		# but a wander step could wade into the ocean where they'd walk the
		# seafloor. On island maps, reject a watery target and just stay put by
		# home this cycle -- animals graze the land, they don't swim.
		# BUG FIX (2026-07-27): in turtle_islands mode the underlying terrain is
		# PURE ocean everywhere (see terrain_gen.gd's all_ocean) -- this check
		# used to ask the STATIC TERRAIN "is this water?", which is
		# unconditionally true both off a turtle's disc AND on it (turtles
		# aren't part of the terrain heightmap), so it rejected nothing useful.
		# Ask the home TURTLE instead: still inside its disc, or not.
		var mgr = get_tree().get_first_node_in_group("tribe_manager")
		var still_on_turtle := true
		if mgr != null and bool(mgr.get("turtle_islands")):
			var home_turtle = _resolve_home_turtle()
			still_on_turtle = home_turtle != null and is_instance_valid(home_turtle) \
				and home_turtle.has_method("is_on_turtle") \
				and home_turtle.is_on_turtle(_wander_target.x, _wander_target.z)
		elif mgr != null and mgr.has_method("terrain_is_water") and mgr.terrain_is_water(_wander_target.x, _wander_target.z):
			still_on_turtle = false
		if not still_on_turtle:
			_wander_target = home_pos
		_wander_pause = randf_range(0.8, 2.5)
		_halt()
		return
	var to := _wander_target - global_position
	to.y = 0.0
	if to.length() > 0.001:
		_drive(to.normalized(), wander_speed, delta)

# Prey vigilance: while paused, an idle animal occasionally turns to scan a
# new direction with a small alert bob, instead of standing frozen. Reads as a
# nervous grazing creature keeping watch.
func _idle_look(delta: float) -> void:
	if _wander_pause < 0.7:    # not enough pause left for the 0.6s turn to finish before we move again
		return
	_look_cd -= delta
	if _look_cd > 0.0:
		return
	_look_cd = randf_range(1.8, 4.5)
	var target_yaw: float = wrapf(rotation.y + randf_range(-1.2, 1.2), -PI, PI)
	var tw := create_tween()
	tw.tween_property(self, "rotation:y", target_yaw, 0.6)
	if anim:
		anim.pop(0.12)

func _nearest_bush() -> Node3D:
	var best: Node3D = null
	var bd := INF
	for b in get_tree().get_nodes_in_group("food_source"):
		var n := b as Node3D
		if n and is_instance_valid(n) and n.has_method("graze") and float(n.amount) > 0.5:
			var dd := global_position.distance_to(n.global_position)
			if dd < bd:
				bd = dd
				best = n
	return best

func _drive(dir: Vector3, spd: float, delta: float) -> void:
	velocity.x = dir.x * spd
	velocity.z = dir.z * spd
	_face_dir(dir, delta)

func _halt() -> void:
	velocity.x = move_toward(velocity.x, 0.0, wander_speed)
	velocity.z = move_toward(velocity.z, 0.0, wander_speed)

func _face(p: Vector3, delta: float) -> void:
	var to := p - global_position
	to.y = 0.0
	if to.length() > 0.01:
		_face_dir(to.normalized(), delta)

func _face_dir(dir: Vector3, delta: float) -> void:
	var yaw := atan2(dir.x, dir.z)
	rotation.y = lerp_angle(rotation.y, yaw, clampf(delta * 6.0, 0.0, 1.0))

# A hunter caught us. Hand back the loot and vanish.
func killed() -> Dictionary:
	var loot := {
		"name": species,
		"food": food_yield + (randi() % 2),
		"skins": skins_yield + (1 if skins_yield > 0 and randf() < 0.4 else 0),
	}
	SpatialGrid.remove(self)
	queue_free()
	return loot
