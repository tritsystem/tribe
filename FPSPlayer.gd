extends CharacterBody3D
class_name FPSPlayer

# ─────────────────────────────────────────────────────────────────────────────
# FPS controller + the player's own SURVIVAL actions.
#   WASD move, mouse look, Space jump, Esc free mouse.
#   You get HUNGRY — you auto-eat from the tribe stockpile, and starve (and slow)
#   if it's empty.
#   [F] pick berries from a nearby bush      [C] carve a club
#   [LMB] swing your club at a nearby deer (needs a club!) for meat + skins
#   [E] near a member feeds them (handled by the member's own script)
# Put this on a CharacterBody3D in group "player".
# ─────────────────────────────────────────────────────────────────────────────

@export var speed: float = 5.0
@export var jump_velocity: float = 4.5
@export var mouse_sensitivity: float = 0.003
@export var look_smoothing: float = 7.0   # lerp speed toward target angle; higher = snappier, lower = floatier

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)

@onready var camera: Camera3D = $Camera3D
@onready var _fps_label: Label = $"../UI/FPSLabel"

# survival
var manager
var hunger: float = 0.0

## INVENTORY (2026-07-19): "add npc and player inventory" -- mirrors
## tribemember.gd's own inventory (item name -> count). Populated by
## personally mined ore/stone/gems (see mineral.gd's player-only _harvest())
## on top of whatever gets banked in the shared stockpile.
var inventory: Dictionary = {}

func add_item(item: String, n: int = 1) -> void:
	inventory[item] = int(inventory.get(item, 0)) + n

func item_count(item: String) -> int:
	return int(inventory.get(item, 0))

const HUNGER_RATE := 0.9          # gentler — easier to keep fed
const EAT_AT := 60.0
const EAT_RESTORE := 62.0
var _starving: bool = false

# health — camp defenders can drive you off
var hp: float = 100.0
var max_hp: float = 100.0

const REACH := 3.0           # how close to pick berries
const CLUB_REACH := 2.8      # how close to club a deer
const THROW_RANGE := 20.0    # how far a thrown club can reach
const THROW_DAMAGE := 22.0
var _target_yaw: float = 0.0
var _target_pitch: float = 0.0
var _carve_cd: float = 0.0
var _keys_down: Dictionary = {}
var _club_model: MeshInstance3D = null
var _throw_anim_active: bool = false   # suppresses the per-frame visibility sync during the windup tween
var _v_tap_count: int = 0   # discrete [V] presses within the window — 3 selects the whole tribe
var _v_tap_window: float = 0.0
var _shake_amt: float = 0.0      # current shake magnitude (world units); decays to 0
var _cam_base_pos: Vector3 = Vector3.ZERO
var _hurt_flash: float = 0.0            # 1.0 on hit, fades -> red damage vignette
var _hurt_overlay: ColorRect = null

# ── WATER: swimming + a player-built boat (island maps only) ──
const SWIM_SPEED := 3.0        # horizontal paddle speed (slower than walking's 5)
const SWIM_VERT := 3.5         # max up/down swim speed (and the clamp on bobbing)
const BUOYANCY := 9.0          # upward accel per metre of depth — floats you to the surface
const WATER_VDRAG := 10.0      # vertical drag so you never rocket up or plummet
const PLAYER_BOAT_WOOD := 6    # wood cost to launch a boat
const BOAT_SPEED := 8.0        # how fast the boat sails
var _boat: MeshInstance3D = null
var _on_boat: bool = false

# ── TURTLE ISLANDS: welded (not reparented) onto whichever turtle you're
# standing on, so normal walking/gravity/move_and_slide still work exactly as
# on static land -- only the island's own frame-to-frame drift gets added on
# top each physics tick. Reparenting a live camera-holding CharacterBody3D
# into a different subtree mid-motion is the real risk this sidesteps (see
# the turtle-island plan's Phase 1 note); this is the same "weld" idiom
# _drive_boat() already uses for the player riding a boat. ──
var _riding_turtle = null
var _riding_turtle_last_pos: Vector3 = Vector3.ZERO

# ── TURTLE STEERING (Phase 4) — [Alt] toggles driving whichever turtle you're
# currently welded to (_riding_turtle above), IF it's steerable (world_tribe.gd
# sets that true once you've earned "trusted" trust with it via Phase 3's
# quests; player_island.gd defaults it true -- it's your own camp, you don't
# need to quest for the right to steer it). Alt was the one key confirmed
# genuinely free after auditing every other binding in the project.
var _steering_turtle_ref = null
const TURTLE_STEER_SPEED := 4.0        # brisker than ambient drift (2.2) -- deliberate driving should read as faster
const TURTLE_STEER_SPACING_MARGIN := 12.0   # mirrors world_tribe.gd's TURTLE_SPACING_MARGIN

# MIGRATION WHISTLE RESPONSE LAG (2026-07-28): world_tribe.gd's turtle_trust
# (0..1, the SAME scalar that already gates whether a rival island is
# steerable at all -- "trusted" tier, 0.60+) now also gates HOW WELL it
# responds once you're steering it: sluggish right at 0.60, crisp by 0.85+
# ("bonded"). Real reason to keep questing after steering unlocks, not just a
# binary permission flag. player_island.gd has no turtle_trust var at all (by
# design -- "you already command it, no quest needed"), so its steering stays
# exactly as instant/precise as before this change; the lag ONLY applies to a
# turtle that actually HAS the property, checked via `"turtle_trust" in ...`.
var _steer_heading: Vector3 = Vector3.ZERO   # smoothed direction, only used when a trust-lag applies

# SOULBOUND EYE-LINK (2026-07-28): [B] confirmed free (Alt/R/WASD/Space/Ctrl/F/
# C/G/X/Y/L/Z/Period/Comma/H/J/[/]/K/M/V/Shift/1-7/0/O/I/P/Apostrophe/N/9 all
# taken -- see the audit that picked Alt above). No range gate on purpose: the
# whole point of Soulbound ("I feel you now, even when you're far away" --
# tribemember.gd's rank-up line) is that distance stops mattering once a bond
# is that deep. Position-only follow -- rotation still comes from the
# player's own mouse look (reusing the existing rotation.y/camera.rotation.x
# lerp above), not the NPC's own facing, so looking around from their vantage
# point doesn't feel like fighting an autopilot.
var _soul_link_ref: Node3D = null
const SOUL_LINK_EYE_HEIGHT := 1.6

func _ready() -> void:
	add_to_group("player")
	# walk hills smoothly: snap to the surface so you don't bounce down slopes,
	# and allow a steeper climb before it counts as a wall (see terrain work)
	floor_snap_length = 0.8
	floor_max_angle = deg_to_rad(54.0)
	floor_constant_speed = true
	# collide with STRUCTURES (layer 4): walls/fences still physically block YOU
	# (siege feel + your own gated camp), even though AI phases through them so it
	# can't jam. See block.gd.
	set_collision_mask_value(4, true)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_target_yaw = rotation.y
	_target_pitch = 0.0
	_build_club_model()
	_build_hurt_overlay()
	if camera:
		_cam_base_pos = camera.position

# A full-screen red vignette that flashes when you take a hit -- the SEEN half
# of combat feedback (screen_shake is the FELT half). Without this, rival
# attacks were invisible and read as "npcs ignore me".
func _build_hurt_overlay() -> void:
	var ui := get_node_or_null("../UI")
	if ui == null:
		return
	_hurt_overlay = ColorRect.new()
	_hurt_overlay.name = "HurtFlash"
	_hurt_overlay.color = Color(0.75, 0.05, 0.05, 0.0)
	_hurt_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hurt_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui.add_child(_hurt_overlay)

func _build_club_model() -> void:
	# a club held in view, shown only while the tribe actually has one to wield.
	# REAL ASSET (2026-07-27): joe345's Dagger.glb (itch.io, CC0) -- see
	# tribemember.gd's own weapon-tier 0 for the same asset and reasoning.
	_club_model = MeshInstance3D.new()
	var real_dagger := _get_real_dagger_mesh()
	if real_dagger != null:
		_club_model.mesh = real_dagger
		_club_model.scale = Vector3(2.0, 2.0, 2.0)   # measured height 0.312 -- viewmodel-sized
	else:
		var m := BoxMesh.new()
		m.size = Vector3(0.08, 0.08, 0.7)
		_club_model.mesh = m
		_club_model.material_override = MatCache.flat(Color(0.45, 0.30, 0.15))
	_club_model.position = Vector3(0.35, -0.30, -0.6)
	_club_model.rotation_degrees = Vector3(-20, 0, 0)
	_club_model.visible = false
	if camera:
		camera.add_child(_club_model)

var _real_dagger_mesh: Mesh = null   # cached so repeated builds don't re-load the file

func _get_real_dagger_mesh() -> Mesh:
	if _real_dagger_mesh != null:
		return _real_dagger_mesh
	var glb_path := "res://assets/weapons/Dagger.glb"
	if not ResourceLoader.exists(glb_path):
		return null
	var packed: PackedScene = load(glb_path)
	var inst := packed.instantiate()
	var found := _find_dagger_mesh(inst)
	if found == null:
		inst.queue_free()
		return null
	_real_dagger_mesh = found.mesh
	inst.queue_free()
	return _real_dagger_mesh

func _find_dagger_mesh(root_node: Node) -> MeshInstance3D:
	if root_node is MeshInstance3D and root_node.name == "Dagger":
		return root_node as MeshInstance3D
	for c in root_node.get_children():
		var f := _find_dagger_mesh(c)
		if f != null:
			return f
	return null

func _unhandled_input(event: InputEvent) -> void:
	# CHAT GATE: while the chat box is open we read NO input at all. This reads
	# raw keys/mouse, so without the gate typing "we should hunt" would walk you
	# across camp (W), carve a club (C), and swing (LMB) as you type.
	if TribeChat.open or TribeTradeUI.open or TribeTradeMenu.open or TribeOverview.open or TribeInventoryUI.open:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_target_yaw -= event.relative.x * mouse_sensitivity
		_target_pitch = clampf(_target_pitch - event.relative.y * mouse_sensitivity, -1.4, 1.4)
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if event is InputEventKey and event.pressed and event.keycode == KEY_F3:
		if _fps_label:
			_fps_label.visible = not _fps_label.visible
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_swing_club()
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		_throw_club()

func _process(delta: float) -> void:
	if _fps_label and _fps_label.visible:
		_fps_label.text = "FPS: %d" % Engine.get_frames_per_second()
	if _hurt_flash > 0.0:
		_hurt_flash = maxf(0.0, _hurt_flash - delta * 2.2)   # ~0.45s fade
		if _hurt_overlay:
			_hurt_overlay.color.a = _hurt_flash * 0.42

func _physics_process(delta: float) -> void:
	if manager == null:
		manager = get_tree().get_first_node_in_group("tribe_manager")

	var t := minf(look_smoothing * delta, 1.0)
	rotation.y = lerp_angle(rotation.y, _target_yaw, t)
	if camera:
		camera.rotation.x = lerpf(camera.rotation.x, _target_pitch, t)
		if _shake_amt > 0.001:
			camera.position = _cam_base_pos + Vector3(
				randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), 0.0) * _shake_amt
			_shake_amt = move_toward(_shake_amt, 0.0, delta * 0.25)
		else:
			_shake_amt = 0.0
			camera.position = _cam_base_pos

	_survival(delta)

	# Applies BEFORE the normal walk/water logic below, so this frame's turtle
	# drift is folded into global_position before gravity/move_and_slide runs
	# on top of it -- an ADDITIVE weld, not a takeover like boat-driving. Skips
	# itself while on a boat (that already fully owns global_position writes)
	# or while actively steering (_drive_turtle already applies the same-frame
	# move directly, so the weld would double it).
	if not _on_boat and _steering_turtle_ref == null:
		_update_turtle_weld()

	# CHAT GATE: no movement/jump keys while typing (gravity + move_and_slide still
	# run below, so you settle on the ground instead of freezing mid-air)
	var chatting: bool = TribeChat.open or TribeTradeUI.open or TribeTradeMenu.open or TribeOverview.open or TribeInventoryUI.open

	# [Alt] toggles steering the turtle you're currently welded to (Phase 4).
	# Not while on a boat -- that's its own separate takeover of global_position.
	if not _on_boat and not chatting and _key_just(KEY_ALT):
		_toggle_turtle_steering()

	if _steering_turtle_ref != null:
		_drive_turtle(delta, chatting)
		return

	# [B] toggles the Soulbound eye-link. Checked after steering (steering the
	# turtle and seeing through a member's eyes are both "possess something
	# else" modes -- mutually exclusive, steering wins if somehow both keys
	# land the same frame, same precedence the boat/steer checks already use).
	if not _on_boat and not chatting and _key_just(KEY_B):
		_toggle_soul_link()

	if _soul_link_ref != null:
		_drive_soul_link(delta)
		return

	# ── WATER dispatch (island maps only; a non-island / no-terrain map skips ALL of
	# this and drops straight to the unchanged walk path below). ──
	var terr = null
	if manager != null:
		terr = manager.get("terrain")
	var island: bool = terr != null and is_instance_valid(terr) and terr.get("island_mode") == true

	if island and not chatting and _key_just(KEY_R):
		if _on_boat:
			_exit_boat(terr)
		else:
			_build_boat(terr)

	if _on_boat and is_instance_valid(_boat):
		_drive_boat(terr, delta, chatting)
		return
	elif _on_boat:
		_on_boat = false   # boat was freed out from under us — fall through to swim/walk

	if island:
		var wl: float = float(terr.get("water_level"))
		# submerged = this column is ocean AND our body is below the surface. Standing
		# on a hill (is_water false) or above the waterline resumes walking seamlessly.
		if terr.is_water(global_position.x, global_position.z) and global_position.y < wl:
			_swim(wl, delta, chatting)
			return

	# ── normal walk (unchanged) ──
	if not is_on_floor():
		velocity.y -= gravity * delta

	if Input.is_action_just_pressed("ui_accept") and is_on_floor() and not chatting:
		velocity.y = jump_velocity

	var input_dir := Vector2.ZERO
	if not chatting:
		if Input.is_key_pressed(KEY_W): input_dir.y -= 1
		if Input.is_key_pressed(KEY_S): input_dir.y += 1
		if Input.is_key_pressed(KEY_A): input_dir.x -= 1
		if Input.is_key_pressed(KEY_D): input_dir.x += 1
	input_dir = input_dir.normalized()

	var spd: float = speed * (0.6 if _starving else 1.0)   # sluggish when starving
	var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	if direction:
		velocity.x = direction.x * spd
		velocity.z = direction.z * spd
	else:
		velocity.x = move_toward(velocity.x, 0, spd)
		velocity.z = move_toward(velocity.z, 0, spd)

	move_and_slide()

# ─────────────────────────────────────────────────────────────────────────────
# SWIMMING & BOATING  (only reached when island_mode is on and terrain exists)
# ─────────────────────────────────────────────────────────────────────────────

# Buoyancy floats you up toward the surface and you bob there; WASD paddles you
# along at a reduced speed; Space swims up, Ctrl dives. You never sink to the
# seafloor and never get launched — vertical speed is drag-damped and clamped.
func _swim(wl: float, delta: float, chatting: bool) -> void:
	var depth: float = wl - global_position.y   # >0 while below the surface
	velocity.y += clampf(depth, 0.0, 2.5) * BUOYANCY * delta
	if not chatting:
		if Input.is_key_pressed(KEY_SPACE): velocity.y += SWIM_VERT * delta
		if Input.is_key_pressed(KEY_CTRL):  velocity.y -= SWIM_VERT * delta
	if depth < 0.0:                            # head breached — gently pulled back to bob
		velocity.y -= gravity * delta
	velocity.y = move_toward(velocity.y, 0.0, WATER_VDRAG * delta)
	velocity.y = clampf(velocity.y, -SWIM_VERT, SWIM_VERT)

	var input_dir := Vector2.ZERO
	if not chatting:
		if Input.is_key_pressed(KEY_W): input_dir.y -= 1
		if Input.is_key_pressed(KEY_S): input_dir.y += 1
		if Input.is_key_pressed(KEY_A): input_dir.x -= 1
		if Input.is_key_pressed(KEY_D): input_dir.x += 1
	input_dir = input_dir.normalized()
	var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	if direction:
		velocity.x = direction.x * SWIM_SPEED
		velocity.z = direction.z * SWIM_SPEED
	else:
		velocity.x = move_toward(velocity.x, 0.0, SWIM_SPEED)
		velocity.z = move_toward(velocity.z, 0.0, SWIM_SPEED)
	move_and_slide()

# ── TURTLE ISLAND WELD ──
# Finds whichever turtle-island (if any) the player is currently standing on
# and adds that island's frame-to-frame drift to global_position -- the same
# weld idiom _drive_boat() uses below, just additive instead of a full
# position takeover, since walking around a moving camp should still feel
# like normal walking (gravity, collision with fences/teepees, etc. all keep
# working -- only the ground itself is quietly sliding).
func _update_turtle_weld() -> void:
	if manager == null or not bool(manager.get("turtle_islands")):
		return
	var found = null
	# Check the player's OWN island first (the common case -- most of a
	# playthrough happens at home) before scanning every rival.
	var home = manager.get("player_island")
	if home != null and is_instance_valid(home) and home.has_method("is_on_turtle") \
			and home.is_on_turtle(global_position.x, global_position.z):
		found = home
	if found == null and "world_tribes" in manager:
		for wt in manager.world_tribes:
			if wt == null or not is_instance_valid(wt) or not bool(wt.get("is_turtle")):
				continue
			if wt.has_method("is_on_turtle") and wt.is_on_turtle(global_position.x, global_position.z):
				found = wt
				break
	if found != _riding_turtle:
		_riding_turtle = found
		if _riding_turtle != null and is_instance_valid(_riding_turtle):
			_riding_turtle_last_pos = _riding_turtle.global_position
	if _riding_turtle != null and is_instance_valid(_riding_turtle):
		var turtle_delta: Vector3 = _riding_turtle.global_position - _riding_turtle_last_pos
		turtle_delta.y = 0.0   # horizontal drift only -- vertical stays governed by normal gravity/floor snap
		global_position += turtle_delta
		_riding_turtle_last_pos = _riding_turtle.global_position
	else:
		_riding_turtle = null

## [Alt] — engage/release steering on whichever turtle _update_turtle_weld()
## says you're currently standing on. Mirrors _build_boat()/_exit_boat()'s
## shape: a toggle, gated on eligibility, with a flash message either way.
func _toggle_turtle_steering() -> void:
	if _steering_turtle_ref != null:
		_steering_turtle_ref = null
		if manager: manager.set("_steering_turtle", null)
		_boat_flash("You lower the whistle — the island drifts on its own again.")
		return
	if _riding_turtle == null or not is_instance_valid(_riding_turtle):
		_boat_flash("Nothing to steer here.")
		return
	if not bool(_riding_turtle.get("steerable")):
		_boat_flash("This island doesn't trust you enough to steer it yet.")
		return
	_steering_turtle_ref = _riding_turtle
	_steer_heading = Vector3.ZERO
	if manager: manager.set("_steering_turtle", _riding_turtle)
	_boat_flash("You blow the migration whistle — WASD to steer, [Alt] to lower it.")

## Direct position write on the turtle's root, exactly like _drive_boat()'s
## direct write on the boat mesh -- children (camp, NPCs) come along for free
## via normal scene-tree parenting. The player is moved by the same delta in
## the same frame (no weld lag) so you stay anchored on deck while driving.
func _drive_turtle(delta: float, chatting: bool) -> void:
	if _steering_turtle_ref == null or not is_instance_valid(_steering_turtle_ref):
		_steering_turtle_ref = null
		if manager: manager.set("_steering_turtle", null)
		return
	var input_dir := Vector2.ZERO
	if not chatting:
		if Input.is_key_pressed(KEY_W): input_dir.y -= 1
		if Input.is_key_pressed(KEY_S): input_dir.y += 1
		if Input.is_key_pressed(KEY_A): input_dir.x -= 1
		if Input.is_key_pressed(KEY_D): input_dir.x += 1
	input_dir = input_dir.normalized()
	var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	velocity = Vector3.ZERO
	# WHISTLE RESPONSE LAG: only turtles with a turtle_trust stat (rivals, once
	# earned) get smoothed/sluggish response -- see the field comment above
	# _steer_heading. player_island.gd has no such property, so `has_trust_stat`
	# is false there and direction passes through untouched, exactly as before.
	var has_trust_stat: bool = "turtle_trust" in _steering_turtle_ref
	if has_trust_stat and direction.length() >= 0.01:
		var trust: float = float(_steering_turtle_ref.get("turtle_trust"))
		# trust < 0.60 shouldn't be steerable at all (see steerable's own gate),
		# but clamp defensively rather than trust that invariant blindly here.
		var t: float = clampf((trust - 0.60) / 0.40, 0.0, 1.0)   # 0 at bare "trusted", 1 at "bonded"+
		var response_rate: float = lerpf(1.4, 12.0, t)   # sluggish drift -> crisp, near-instant
		_steer_heading = _steer_heading.lerp(direction, clampf(response_rate * delta, 0.0, 1.0))
		if _steer_heading.length() > 0.01:
			direction = _steer_heading.normalized()
	if direction.length() < 0.01:
		return
	var cur: Vector3 = _steering_turtle_ref.global_position
	var next_pos: Vector3 = cur + direction * TURTLE_STEER_SPEED * delta
	if manager != null and "MAP_EXTENT" in manager:
		var extent: float = float(manager.MAP_EXTENT)
		next_pos.x = clampf(next_pos.x, -extent, extent)
		next_pos.z = clampf(next_pos.z, -extent, extent)
	# don't steer INTO another turtle -- the steered turtle skips its own
	# ambient-drift repulsion tick while a player is driving it (see
	# world_tribe.gd's _turtle_tick), so that check has to happen here instead.
	# Per-pair radius-based threshold (not a flat constant) -- see
	# world_tribe.gd's TURTLE_SPACING_MARGIN comment for why a flat distance
	# doesn't work once islands have genuinely different radii.
	var steer_radius: float = float(_steering_turtle_ref.get("turtle_radius"))
	if manager != null:
		if "world_tribes" in manager:
			for other in manager.world_tribes:
				if other == _steering_turtle_ref or not is_instance_valid(other) or not bool(other.get("is_turtle")):
					continue
				var need: float = steer_radius + float(other.get("turtle_radius")) + TURTLE_STEER_SPACING_MARGIN
				if Vector2(next_pos.x - other.global_position.x, next_pos.z - other.global_position.z).length() < need:
					return   # blocked -- too close, hold position this frame
		var home = manager.get("player_island")
		if home != null and home != _steering_turtle_ref and is_instance_valid(home):
			var need_home: float = steer_radius + float(home.get("turtle_radius")) + TURTLE_STEER_SPACING_MARGIN
			if Vector2(next_pos.x - home.global_position.x, next_pos.z - home.global_position.z).length() < need_home:
				return
	var applied: Vector3 = next_pos - cur
	_steering_turtle_ref.global_position = next_pos
	global_position += applied

## [B] — link to whichever tribe member has reached Soulbound with you (there's
## no rank-based cycling yet: first Soulbound member found in manager.members
## wins. Fine for now since Soulbound is the rarest rank by a wide margin --
## see tribemember.gd's widened final rank gap -- multiple at once will be
## uncommon; revisit with a cycle key if that stops being true).
func _toggle_soul_link() -> void:
	if _soul_link_ref != null:
		_soul_link_ref = null
		_boat_flash("The link fades. You're back in your own eyes.")
		return
	if manager == null or not ("members" in manager):
		_boat_flash("No one to link with.")
		return
	for m in manager.members:
		if is_instance_valid(m) and str(m.get("current_rank")) == "Soulbound":
			_soul_link_ref = m
			_boat_flash("You see through %s's eyes. [B] to return." % str(m.get("member_name")))
			return
	_boat_flash("No one is Soulbound to you yet.")

## Position-only follow (see the field comment above _soul_link_ref for why
## rotation is deliberately left to the player's own mouse look). Zeroes
## velocity same as _drive_turtle -- the player's own body just holds still
## at whatever spot it linked from until the link ends.
func _drive_soul_link(delta: float) -> void:
	if _soul_link_ref == null or not is_instance_valid(_soul_link_ref):
		_soul_link_ref = null
		return
	velocity = Vector3.ZERO
	if camera:
		camera.global_position = (_soul_link_ref as Node3D).global_position + Vector3(0, SOUL_LINK_EYE_HEIGHT, 0)

# [R] launches a boat on the water ahead of you (costs PLAYER_BOAT_WOOD) and
# boards you onto it. Press [R] again to disembark onto the nearest land.
func _build_boat(terr) -> void:
	if manager == null:
		return
	var have: int = int(manager.wood)
	if have < PLAYER_BOAT_WOOD:
		_boat_flash("Need %d wood for a boat — chop more trees." % PLAYER_BOAT_WOOD)
		return
	var wl: float = float(terr.get("water_level"))
	var fwd := -global_transform.basis.z
	fwd.y = 0.0
	if fwd.length() < 0.01:
		fwd = Vector3(0, 0, -1)
	fwd = fwd.normalized()
	var spot := global_position + fwd * 3.5
	var ahead_water: bool = terr.is_water(spot.x, spot.z)
	if not ahead_water:
		# fall back to launching from right under you if you're already in the water
		var here_water: bool = terr.is_water(global_position.x, global_position.z)
		if here_water:
			spot = global_position
		else:
			_boat_flash("No open water ahead to launch a boat.")
			return
	manager.wood = have - PLAYER_BOAT_WOOD
	_boat = MeshInstance3D.new()
	_boat.name = "PlayerBoat"
	# REAL ASSET (2026-07-27): Kenney Watercraft Kit's boat-row-small.glb hull
	# mesh (CC0, downloaded not generated) instead of a bare brown box. _boat
	# stays a single MeshInstance3D (its type is used elsewhere in this file),
	# so this pulls just the hull's real mesh resource out rather than
	# swapping in the whole model subtree -- no material_override on the real
	# mesh (would wipe its baked texture). Falls back to the old box if the
	# asset is missing.
	var real_hull := _get_real_boat_mesh()
	if real_hull != null:
		_boat.mesh = real_hull
		_boat.scale = Vector3(1.5, 1.5, 1.5)   # measured ~2.37m long -- scaled to the old raft's ~3.6m length
	else:
		var bm := BoxMesh.new()
		bm.size = Vector3(2.4, 0.5, 3.6)   # a small brown raft with a bit of size
		_boat.mesh = bm
		_boat.material_override = MatCache.flat(Color(0.42, 0.28, 0.14))
	_boat.add_to_group("player_boat")
	get_tree().current_scene.add_child(_boat)
	_boat.global_position = Vector3(spot.x, wl, spot.z)
	_on_boat = true
	velocity = Vector3.ZERO
	global_position = _boat.global_position + Vector3(0, 1.2, 0)   # ride on top
	_boat_flash("You launch a boat! WASD to sail, [R] to step ashore.")

var _real_boat_mesh: Mesh = null   # cached so repeated launches don't re-load the file

func _get_real_boat_mesh() -> Mesh:
	if _real_boat_mesh != null:
		return _real_boat_mesh
	var glb_path := "res://assets/watercraft/boat-row-small.glb"
	if not ResourceLoader.exists(glb_path):
		return null
	var packed: PackedScene = load(glb_path)
	var inst := packed.instantiate()
	var found := _find_boat_hull(inst)
	if found == null:
		inst.queue_free()
		return null
	_real_boat_mesh = found.mesh
	inst.queue_free()
	return _real_boat_mesh

func _find_boat_hull(root_node: Node) -> MeshInstance3D:
	if root_node is MeshInstance3D and root_node.name == "boat-row-small":
		return root_node as MeshInstance3D
	for c in root_node.get_children():
		var f := _find_boat_hull(c)
		if f != null:
			return f
	return null

# WASD drives the boat across the water; it floats at the waterline and refuses
# to sail onto dry land (stops at the shoreline) so it can't strand on the beach.
func _drive_boat(terr, delta: float, chatting: bool) -> void:
	var wl: float = float(terr.get("water_level"))
	var input_dir := Vector2.ZERO
	if not chatting:
		if Input.is_key_pressed(KEY_W): input_dir.y -= 1
		if Input.is_key_pressed(KEY_S): input_dir.y += 1
		if Input.is_key_pressed(KEY_A): input_dir.x -= 1
		if Input.is_key_pressed(KEY_D): input_dir.x += 1
	input_dir = input_dir.normalized()
	var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	var next_pos: Vector3 = _boat.global_position
	if direction:
		next_pos += direction * BOAT_SPEED * delta
	var next_water: bool = terr.is_water(next_pos.x, next_pos.z)
	if next_water:
		_boat.global_position = Vector3(next_pos.x, wl, next_pos.z)
	else:
		_boat.global_position.y = wl   # blocked by shore — hold position
	velocity = Vector3.ZERO
	global_position = _boat.global_position + Vector3(0, 1.2, 0)

# Step off onto the nearest dry land and free the boat cleanly (no leak).
func _exit_boat(terr) -> void:
	var from: Vector3 = _boat.global_position if is_instance_valid(_boat) else global_position
	var land := Vector3.INF
	if terr != null and is_instance_valid(terr) and terr.has_method("nearest_land"):
		land = terr.nearest_land(from.x, from.z, 250.0)
	if land != Vector3.INF:
		global_position = Vector3(land.x, land.y + 1.5, land.z)
	else:
		global_position = from + Vector3(0, 1.0, 0)   # fallback: just hop off in place
	velocity = Vector3.ZERO
	_on_boat = false
	if is_instance_valid(_boat):
		_boat.queue_free()
	_boat = null
	_boat_flash("You step ashore.")

func _boat_flash(t: String) -> void:
	if manager != null and manager.has_method("notify"):
		manager.notify(t)

# ── hunger + survival inputs ──
func take_hit(dmg: float, _attacker) -> void:
	hp -= dmg
	# FEEDBACK -- this used to be completely silent: no flash, no shake, no sound.
	# Rivals WERE chasing and clubbing the player the whole time, but with hp only
	# shown as a small number in a label (and 3hp/s regen quietly topping it back
	# up), an attack was literally imperceptible and read as "npcs ignore me".
	_hurt_flash = 1.0
	screen_shake(0.05 + minf(dmg, 20.0) * 0.004)   # harder hits shake harder
	if hp <= 0.0:
		hp = max_hp
		# BUG FIXED (2026-07-17): this used to hard-code Vector3(0, 1, 5) --
		# fine back when the world was a flat plane at y=0, but real terrain
		# (hills, valleys, islands) means a fixed point can sit well below
		# the actual generated surface there. Caught live: a player respawned
		# under the map after dying. Tribemanager.gd's own initial-spawn code
		# already asks ground_y() where the real surface is at a given x/z
		# (see _build_terrain()'s "lift the player onto the surface" comment)
		# -- this path just never got the same treatment.
		var rx := 0.0
		var rz := 5.0
		var ry := 1.0
		if manager and manager.has_method("ground_y"):
			ry = manager.ground_y(rx, rz) + 1.0
		global_position = Vector3(rx, ry, rz)   # beaten back to your own camp
		velocity = Vector3.ZERO
		if manager and manager.has_method("notify"):
			manager.notify("You were driven off and limped back to camp!")

# Trigger a short camera shake. strength is in world-space metres of peak offset
# (0.04 is a modest thud; 0.08 would be a heavy blow). Multiple callers in one
# frame take the strongest — the effect decays at 0.25 units/s.
func screen_shake(strength: float = 0.04) -> void:
	_shake_amt = maxf(_shake_amt, strength)

func _survival(delta: float) -> void:
	hp = minf(max_hp, hp + delta * 3.0)   # slowly recover
	hunger = minf(100.0, hunger + delta * HUNGER_RATE)
	if hunger >= EAT_AT and manager and manager.has_method("spend_food"):
		if manager.spend_food(1):
			hunger = maxf(0.0, hunger - EAT_RESTORE)
	_starving = hunger >= 100.0

	_carve_cd = maxf(0.0, _carve_cd - delta)
	if _key_just(KEY_F):
		_pick_berries()
	if _key_just(KEY_C):
		_carve_club()
	if _key_just(KEY_G):
		_bribe()
	if _key_just(KEY_X):
		_scout()   # moved off T -- T is the chat key (TribeChat), they collided
	if _key_just(KEY_Y):
		_build_fence()
	if _key_just(KEY_L):
		_build_teepee()
	if _key_just(KEY_Z):
		_build_block()
	# TERRAFORM: hold [,] to lower the land ahead, [.] to raise it. Held, not
	# tapped, so you sculpt by dragging your aim -- the terrain throttles its own
	# rebuilds so this stays smooth. Works on the spot you're looking at.
	if Input.is_key_pressed(KEY_PERIOD):
		_terraform(1.0, delta)
	elif Input.is_key_pressed(KEY_COMMA):
		_terraform(-1.0, delta)
	if _key_just(KEY_H):
		_feed_dog()
	if _key_just(KEY_J) and manager and manager.has_method("toggle_dog_rally"):
		manager.toggle_dog_rally()
	if _key_just(KEY_BRACKETLEFT) and manager and manager.has_method("cycle_focus"):
		manager.cycle_focus(-1)
	if _key_just(KEY_BRACKETRIGHT) and manager and manager.has_method("cycle_focus"):
		manager.cycle_focus(1)
	if _key_just(KEY_K) and manager and manager.has_method("raid_focus"):
		manager.raid_focus()
	# individual command: [M] cycles selection, or hold [V] while looking at
	# someone to select them directly — then number keys direct them.
	if _key_just(KEY_M) and manager and manager.has_method("cycle_selection"):
		manager.cycle_selection()
	if Input.is_key_pressed(KEY_V) and manager and manager.has_method("select_lookat") and camera:
		manager.select_lookat(camera.global_position, -camera.global_transform.basis.z)
	# triple-tap [V] (as discrete presses, not the hold-to-look-select above)
	# selects your whole tribe at once instead of one member.
	if _key_just(KEY_V):
		_v_tap_count += 1
		_v_tap_window = 0.6
		if _v_tap_count >= 3:
			_v_tap_count = 0
			if manager and manager.has_method("select_whole_tribe"):
				manager.select_whole_tribe()
	if _v_tap_window > 0.0:
		_v_tap_window -= delta
		if _v_tap_window <= 0.0:
			_v_tap_count = 0
	var has_selection: bool = manager != null and (
		manager.get("selected_member") != null
		or (manager.get("selected_group") != null and not manager.selected_group.is_empty())
	)
	if has_selection and manager.has_method("command_selected"):
		# plain number = default quota. Shift+number = a small order (15).
		# Ctrl+number = a large order (80). Stand-ins for "say a quantity" —
		# see Tribemanager.command_selected()'s docstring for the real hook.
		var amt := -1
		if Input.is_key_pressed(KEY_SHIFT): amt = 15
		elif Input.is_key_pressed(KEY_CTRL): amt = 80
		if _key_just(KEY_1): manager.command_selected("gather", amt)
		elif _key_just(KEY_2): manager.command_selected("hunt", amt)
		elif _key_just(KEY_3): manager.command_selected("scout", amt)
		elif _key_just(KEY_4): manager.command_selected("wood", amt)
		elif _key_just(KEY_5): manager.command_selected("build")
		elif _key_just(KEY_6): manager.command_selected("recruit", amt)
		elif _key_just(KEY_7): manager.command_selected("guard")
		elif _key_just(KEY_0): manager.command_selected("auto")
	# [O] cycle formation — phalanx / wedge / testudo / loose. Applies to
	# backers following you AND to any war party your tribe musters.
	if _key_just(KEY_O) and manager and manager.has_method("cycle_formation"):
		manager.cycle_formation()
	# [I] cycle how far out the defense perimeter sits ([7] posts a guard there)
	if _key_just(KEY_I) and manager and manager.has_method("cycle_perimeter"):
		manager.cycle_perimeter()
	# [P] cycle how the whole workforce divides its labour
	if _key_just(KEY_P) and manager and manager.has_method("cycle_work_plan"):
		manager.cycle_work_plan()
	# ['] send a trade ENVOY from your tribe to the nearest willing rival — offers
	# your looted goods for their food. A courier physically walks it there and
	# back; the outcome flashes. See Tribemanager.player_send_trade_envoy().
	if _key_just(KEY_APOSTROPHE) and manager and manager.has_method("player_send_trade_envoy"):
		manager.player_send_trade_envoy()
	# [N] raise a forward camp where you stand (costs wood)
	if _key_just(KEY_N) and manager and manager.has_method("try_build_camp"):
		var f := -global_transform.basis.z
		f.y = 0.0
		if f.length() < 0.01:
			f = Vector3(0, 0, -1)
		manager.try_build_camp(global_position + f.normalized() * 5.0, true)
	# [9] raise a trading post where you stand (costs wood + materials) --
	# required before any trade action works, see Tribemanager.build_trading_post()
	if _key_just(KEY_9) and manager and manager.has_method("build_trading_post"):
		var f9 := -global_transform.basis.z
		f9.y = 0.0
		if f9.length() < 0.01:
			f9 = Vector3(0, 0, -1)
		manager.build_trading_post(global_position + f9.normalized() * 5.0, true)

	if _club_model and manager and not _throw_anim_active:
		_club_model.visible = manager.get("player_holds_club") == true

func _key_just(code: int) -> bool:
	# CHAT GATE at the source: every survival hotkey (F berries, C carve, G bribe,
	# Y fence, L teepee, Z block, H feed dog...) routes through here, and [T] is
	# the chat key itself -- so typing would fire all of them. Swallow them while
	# the chat box is open, but still track key state so nothing latches.
	if TribeChat.open or TribeTradeUI.open or TribeTradeMenu.open or TribeOverview.open or TribeInventoryUI.open:
		_keys_down[code] = Input.is_key_pressed(code)
		return false
	var down := Input.is_key_pressed(code)
	var was: bool = _keys_down.get(code, false)
	_keys_down[code] = down
	return down and not was

func _pick_berries() -> void:
	if manager == null:
		return
	var bush := _nearest_in_group("food_source", REACH)
	if bush and bush.has_method("harvest"):
		var got: int = bush.harvest(3.0)
		if got > 0:
			manager.add_food(got)
			hunger = maxf(0.0, hunger - 12.0)   # snack while you pick
			manager.notify("You pick %d berries." % got)
		else:
			manager.notify("This bush is picked bare.")
	else:
		manager.notify("No bush within reach to pick.")

func _carve_club() -> void:
	if manager == null:
		return
	if manager.get("player_holds_club") == true:
		manager.notify("You already have a club.")
		return
	if _carve_cd > 0.0:
		manager.notify("Still carving... (%.0fs left)" % _carve_cd)
		return
	if not manager.craft_club(true):
		return   # craft_club() already posted the "need wood" notice
	_carve_cd = 3.0
	# craft_club() already posted a "forge a masterwork club" flash if a
	# looted material got spent — don't stomp it with a generic message
	if manager.get("player_club_material") == "":
		manager.notify("You carve a sturdy club.")

func _swing_club() -> void:
	if manager == null:
		return
	_play_swing_anim()
	var has_club: bool = manager.get("player_holds_club") == true
	# a masterwork club (forged from a looted tribe material — see
	# Tribemanager.craft_club/materials_owned) hits harder than a plain one
	var club_mat: String = str(manager.get("player_club_material"))
	var dmg_mult: float = 1.5 if club_mat != "" else 1.0
	# 1) strike a tribesperson (rival or camp defender) — not neutrals
	var foe := _nearest_in_group("npc", CLUB_REACH)
	if foe and not foe.get("neutral") and foe.has_method("take_hit"):
		foe.take_hit((18.0 if has_club else 9.0) * dmg_mult, self)
		manager.notify("You strike a tribesperson!")
		return
	# 1b) strike one of YOUR OWN tribe members — betrayal. Previously the
	# swing could only ever reach the rival "npc" group; own members (group
	# "tribe") were never a valid melee target at all.
	var own := _nearest_in_group("tribe", CLUB_REACH)
	if own and own.has_method("take_hit"):
		own.take_hit((18.0 if has_club else 9.0) * dmg_mult, self)
		manager.notify("You strike %s! They will not forget this." % str(own.get("member_name")))
		return
	# 1c) strike a troll guarding an island (Phase 6, turtle-island revamp) --
	# its own group + priority slot, same spot in the chain as other combatants
	var troll := _nearest_in_group("troll", CLUB_REACH)
	if troll and troll.has_method("take_hit"):
		troll.take_hit((18.0 if has_club else 9.0) * dmg_mult, self)
		manager.notify("You strike the troll!")
		return
	# 2) smash an enemy camp's totem — the blow is routed to their actual
	# infrastructure (teepees first, then the stockpile); knock both down to
	# conquer the tribe and convert their whole roster
	var core := _nearest_in_group("camp_core", 4.5)
	if core and core.has_meta("tribe"):
		var t = core.get_meta("tribe")
		if is_instance_valid(t) and t.has_method("damage_camp"):
			t.damage_camp((18.0 if has_club else 9.0) * dmg_mult, true)
			if is_instance_valid(t):
				if t.stockpile_destroyed:
					manager.notify("The %s stockpile is rubble — one more strike and they fall!" % t.tribe_name)
				else:
					manager.notify("You batter the %s camp! %d teepees standing, stockpile %d%%" % [
						t.tribe_name, t.teepees.size(), int(t.stockpile_hp / maxf(1.0, t.stockpile_max_hp) * 100.0)])
			return
	# 3) club a deer (needs a club)
	var deer := _nearest_in_group("animal", CLUB_REACH)
	if deer and deer.has_method("killed"):
		if not has_club:
			manager.notify("You've no club to hunt! Press C to carve one.")
			return
		var loot: Dictionary = deer.killed()
		manager.add_food(int(loot.get("food", 0)))
		manager.add_materials(int(loot.get("skins", 0)))
		manager.notify("You club a %s! +%d meat, +%d skins" % [loot.get("name", "beast"), int(loot.get("food", 0)), int(loot.get("skins", 0))])
		return
	# 2) chop a tree for wood (a club bites harder)
	var tree := _nearest_in_group("tree", 2.6)
	if tree and tree.has_method("chop"):
		var got: int = tree.chop(2 if has_club else 1)
		if got > 0:
			manager.add_wood(got)
			manager.notify("Timber! +%d wood (wood: %d)" % [got, manager.wood])
		else:
			manager.notify("You hack at the tree...")
		return
	# 3) knock down a fence (yours or in your way)
	var fence := _nearest_in_group("fence", 2.4)
	if fence and fence.has_method("take_damage"):
		fence.take_damage(2)
		manager.notify("You batter the fence.")
		return
	# 4) smash a block (yours, a rival's wall, anyone's maze) — same plain
	# swing as a fence; RMB-thrown clubs and other attackers can also hit
	# these since take_damage is the universal entry point
	var blk := _nearest_in_group("block", 2.6)
	if blk and blk.has_method("take_damage"):
		blk.take_damage(4 if has_club else 2)
		manager.notify("You smash a block.")
		return
	manager.notify("You swing at empty air.")

# RMB: actually hurl the club — a real projectile flies out and deals damage
# on whatever it physically touches (see thrown_club.gd), instead of an
# instant invisible raycast. The club is gone either way (hit or miss) —
# carve a new one with [C] (costs wood now, see Tribemanager.craft_club).
func _throw_club() -> void:
	if manager == null:
		return
	if manager.get("player_holds_club") != true:
		manager.notify("No club to throw! Press C to carve one.")
		return
	var club_mat: String = str(manager.get("player_club_material"))
	var dmg_mult: float = 1.5 if club_mat != "" else 1.0
	manager.player_holds_club = false
	manager.player_club_material = ""   # the club (and whatever it was forged from) is gone

	var dir := -camera.global_transform.basis.z
	_play_throw_anim()

	var proj := Area3D.new()
	proj.set_script(load("res://thrown_club.gd"))
	get_tree().current_scene.add_child(proj)
	var launch_pos := camera.global_position + dir * 0.6 - camera.global_transform.basis.y * 0.2
	proj.launch(launch_pos, dir, 26.0, THROW_DAMAGE * dmg_mult, self)
	if club_mat != "":
		manager.notify("You hurl your %s club!" % club_mat)
	else:
		manager.notify("You hurl your club!")

# wind up and "release" the club model before the real projectile takes over.
# Sets _throw_anim_active so the per-frame visibility sync (which would
# otherwise hide the model the instant player_holds_club drops to false)
# doesn't cut the windup short.
func _play_throw_anim() -> void:
	if _club_model == null:
		return
	_throw_anim_active = true
	_club_model.visible = true
	var tw := create_tween()
	tw.tween_property(_club_model, "rotation_degrees", Vector3(-100, -15, 35), 0.09)
	tw.tween_callback(func():
		if _club_model:
			_club_model.visible = false   # thrown — gone until a new one's carved
			_club_model.rotation_degrees = Vector3(-20, 0, 0)
		_throw_anim_active = false
	)

# swing the held club through a quick arc on melee hits
func _play_swing_anim() -> void:
	if _club_model == null:
		return
	var base_rot: Vector3 = Vector3(-20, 0, 0)
	var tw := create_tween()
	tw.tween_property(_club_model, "rotation_degrees", Vector3(-75, 10, -30), 0.06)
	tw.tween_property(_club_model, "rotation_degrees", base_rot, 0.14)

func _build_fence() -> void:
	if manager == null or not manager.has_method("try_build_fence"):
		return
	var fwd := -global_transform.basis.z
	fwd.y = 0.0
	if fwd.length() < 0.01:
		fwd = Vector3(0, 0, -1)
	fwd = fwd.normalized()
	var pos := global_position + fwd * 2.2
	# BUG FIX (2026-07-28): a flat pos.y=0.0 assumed world ground level sat at
	# Y=0 -- true for the old flat-floor game, wrong on a turtle island (deck
	# sits near water_level + the shell's freeboard). ground_y() is the
	# canonical "surface height here" query and is turtle-aware.
	pos.y = manager.ground_y(pos.x, pos.z) if manager.has_method("ground_y") else 0.0
	manager.try_build_fence(pos, atan2(fwd.x, fwd.z), true)

func _terraform(dir: float, delta: float) -> void:
	if manager == null:
		return
	var t = manager.get("terrain")
	if t == null or not is_instance_valid(t) or not t.has_method("raise_area"):
		return
	# aim a few metres ahead on the XZ plane, same as block-building targets
	var fwd := -global_transform.basis.z
	fwd.y = 0.0
	if fwd.length() < 0.01:
		fwd = Vector3(0, 0, -1)
	fwd = fwd.normalized()
	var target := global_position + fwd * 4.0
	t.raise_area(target.x, target.z, 6.0, dir * 9.0 * delta)   # metres/sec at centre

func _build_block() -> void:
	if manager == null or not manager.has_method("try_build_block"):
		return
	var fwd := -global_transform.basis.z
	fwd.y = 0.0
	if fwd.length() < 0.01:
		fwd = Vector3(0, 0, -1)
	fwd = fwd.normalized()
	var target := global_position + fwd * 2.4
	manager.try_build_block(Vector3(target.x, _stack_top(target), target.z), true)

# scan existing blocks on this XZ grid column and return the height to stack
# the next one on top of (ground level if the column is empty) — this is
# what lets you build UP into walls/towers, not just a flat scatter of cubes
func _stack_top(at: Vector3) -> float:
	var col_x: float = round(at.x / 2.0) * 2.0
	var col_z: float = round(at.z / 2.0) * 2.0
	# BUG FIX (2026-07-28): a flat 1.0 assumed world ground level sat at Y=0
	# (block center at half its own height) -- wrong on a turtle island, where
	# ground_y() (turtle-aware) is the real surface height at this spot.
	var base_y := 1.0
	if manager and manager.has_method("ground_y"):
		base_y = manager.ground_y(at.x, at.z) + 1.0
	var top := base_y   # ground-level block center
	for b in get_tree().get_nodes_in_group("block"):
		var bn := b as Node3D
		if bn == null or not is_instance_valid(bn):
			continue
		if absf(bn.global_position.x - col_x) < 0.5 and absf(bn.global_position.z - col_z) < 0.5:
			top = maxf(top, bn.global_position.y + 2.0)
	return top

func _build_teepee() -> void:
	if manager == null or not manager.has_method("try_build_teepee"):
		return
	var fwd := -global_transform.basis.z
	fwd.y = 0.0
	if fwd.length() < 0.01:
		fwd = Vector3(0, 0, -1)
	fwd = fwd.normalized()
	var pos := global_position + fwd * 2.6
	# same ground_y() fix as _build_fence() above
	pos.y = manager.ground_y(pos.x, pos.z) if manager.has_method("ground_y") else 0.0
	manager.try_build_teepee(pos, true)

func _feed_dog() -> void:
	if manager == null:
		return
	var dog := _nearest_in_group("dog", 3.6)
	if dog == null:
		manager.notify("No dog within reach to feed.")
		return
	if not manager.spend_food(1):
		manager.notify("No food to feed the dog.")
		return
	var was_loyal: bool = dog.has_method("is_loyal") and dog.is_loyal()
	if dog.has_method("feed"):
		dog.feed()
	if not was_loyal and dog.has_method("is_loyal") and dog.is_loyal():
		manager.notify("The stray is yours now — a loyal guard dog! [J] to rally.")
	elif was_loyal:
		manager.notify("Your hound wolfs the scrap down, tail wagging.")
	else:
		manager.notify("You coax the wary stray... it's warming to you.")

func _bribe() -> void:
	if manager == null:
		return
	var npc := _nearest_in_group("neutral", 3.5)
	if npc == null:
		manager.notify("No wanderer within reach to bribe.")
		return
	var paid := false
	if manager.spend_food(3):
		paid = true
	elif manager.spend_materials(2):
		paid = true
	if not paid:
		manager.notify("Need 3 food or 2 skins to bribe a wanderer.")
		return
	manager.recruit_neutral(npc)
	manager.notify("A wanderer takes your gift and joins your clan!")

func _scout() -> void:
	if manager and manager.has_method("player_scout"):
		manager.player_scout(global_position)

func _nearest_in_group(grp: String, maxd: float) -> Node3D:
	var best: Node3D = null
	var bd := maxd
	for n in get_tree().get_nodes_in_group(grp):
		var nn := n as Node3D
		if nn and is_instance_valid(nn):
			var d := global_position.distance_to(nn.global_position)
			if d < bd:
				bd = d
				best = nn
	return best
