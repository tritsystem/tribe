








extends CharacterBody3D
# ─────────────────────────────────────────────────────────────────────────────
# Dog — a wild hound you can FEED to win its loyalty. The same trust idea as the
# tribe, in fur: a few meals and a stray becomes YOURS. Once loyal it GUARDS your
# base — chasing down and biting rival raiders that stray near the stockpile —
# and can be RALLIED to heel at your side, then sent back to guard.
#
# Carries a tiny Spikeling brain (SeeFoe->Bark, SeeThreat->Flee) like everything
# else alive here, and a BodyAnim body so it bounds, startles, and bristles.
# Groups: "dog", "has_brain" (+ "loyal_dog" once tamed).
# ─────────────────────────────────────────────────────────────────────────────

const SpatialGrid = preload("res://spatial_grid.gd")

var brain: Spikeling
var anim: BodyAnim
var manager

enum Mode { WILD, GUARD, HEEL }
var mode: int = Mode.WILD
var loyalty: float = 0.0
const TAME_AT := 1.0             # two meals (0.5 each) earn a stray's loyalty
var member_name: String = "Stray"    # labels for the brain-viewer (duck-typed)
var personality: String = "Hound"

@export var wander_speed: float = 1.9
@export var chase_speed: float = 4.3   # dogs are FAST — they run raiders down
@export var flee_speed: float = 4.0
var hp: float = 45.0
var max_hp: float = 45.0
var bite: float = 8.0
var _attack_cd: float = 0.0

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
var home: Vector3 = Vector3.ZERO     # the base we guard (the stockpile / origin)
var spawn_pos: Vector3 = Vector3.ZERO
const GUARD_SENSE := 17.0            # how far a guard dog spots intruders
const GUARD_LEASH := 32.0            # how far it'll chase from the base
const HEEL_DIST := 2.6
const ARRIVE := 0.7
const FEED_RANGE := 3.4              # the player must be this close to feed it

var _wander_target: Vector3 = Vector3.ZERO
var _wander_pause: float = 0.0
var _foe: Node3D = null
var _foe_cd: float = 0.0
var _player: Node3D = null
var _flee_timer: float = 0.0
var _tick_accum: float = 0.0
const TICK_HZ := 10.0
## BUG FIXED (same as animal.gd's own fix): the real model's HeadMarker is a
## plain Node3D empty (no mesh of its own, just an eye-attachment point), not
## a MeshInstance3D like the old primitive sphere head was.
var _head: Node3D = null
var _label: Label3D = null
var _color: Color = Color(0.55, 0.45, 0.32)
var _stuck_cd: float = 0.0       # throttles the snagged-on-something check
var _last_pos: Vector3 = Vector3.ZERO
var _legs: Array = []            # Leg0..Leg3 (real model only) -- see _animate_legs()
var _leg_phase: float = 0.0
var _tinted_meshes: Array = []   # every MeshInstance3D _recolor() should tint (real model: body+nose+legs; primitive: Mesh+head)

const BRAIN := """# Spikeling Neural Configuration
neuron SeeFoe    threshold=50 leak=22
neuron SeeThreat threshold=50 leak=28
neuron Bark      threshold=100 leak=10
neuron Flee      threshold=100 leak=14
synapse SeeFoe    -> Bark weight=135
synapse SeeThreat -> Flee weight=120
refractory=2
"""

func _ready() -> void:
	add_to_group("dog")
	add_to_group("has_brain")
	brain = Spikeling.new()
	brain.load_from_text(BRAIN)
	_build()
	anim = BodyAnim.new()
	anim.setup([get_node_or_null("Mesh"), _head])

func setup(mgr, base: Vector3, at: Vector3) -> void:
	manager = mgr
	home = base
	spawn_pos = at
	_wander_target = at

func is_loyal() -> bool:
	return loyalty >= TAME_AT

# ── build a low four-ish-legged silhouette (body + head + collision) ──
## REAL ASSET (2026-07-27): reuses assets/animals/wolf.glb (already a real
## Blender-modeled quadruped with a proper leg rig -- see tools/gen_animals.py
## and animal.gd's own "REAL MODELED ASSETS" pass) instead of a bare capsule.
## A dog and a wolf share the same silhouette closely enough that no new
## asset is needed; scaled down slightly and recolored (the model's baked
## material is a flat, non-textured albedo color -- see gen_animals.py's
## make_material() -- so material_override recoloring is safe, unlike the
## downloaded Kenney packs' textured assets). Falls back to the old
## primitive capsule+sphere+boxes if the asset is ever missing.
func _build() -> void:
	if not _try_real_wolf_model():
		var mat := MatCache.flat(_color)

		var body := MeshInstance3D.new()
		body.name = "Mesh"
		var cap := CapsuleMesh.new()
		cap.radius = 0.26
		cap.height = 1.05
		body.mesh = cap
		body.rotation_degrees = Vector3(90, 0, 0)   # lie the capsule on its side
		body.position = Vector3(0, 0.5, 0)
		body.material_override = mat
		add_child(body)
		_tinted_meshes.append(body)

		_head = MeshInstance3D.new()
		var hs := SphereMesh.new()
		hs.radius = 0.2
		hs.height = 0.4
		_head.mesh = hs
		_head.position = Vector3(0, 0.62, 0.55)
		_head.material_override = mat
		add_child(_head)
		_tinted_meshes.append(_head)

		var snout := MeshInstance3D.new()
		var sb := BoxMesh.new()
		sb.size = Vector3(0.14, 0.12, 0.22)
		snout.mesh = sb
		snout.position = Vector3(0, 0.57, 0.74)
		snout.material_override = mat
		add_child(snout)

		var tail := MeshInstance3D.new()
		var tb := BoxMesh.new()
		tb.size = Vector3(0.07, 0.07, 0.4)
		tail.mesh = tb
		tail.position = Vector3(0, 0.62, -0.6)
		tail.rotation_degrees = Vector3(35, 0, 0)
		tail.material_override = mat
		add_child(tail)

		var col := CollisionShape3D.new()
		var shape := CapsuleShape3D.new()
		shape.radius = 0.3
		shape.height = 1.0
		col.shape = shape
		col.rotation_degrees = Vector3(90, 0, 0)
		col.position = Vector3(0, 0.5, 0)
		add_child(col)

	_label = Label3D.new()
	_label.position = Vector3(0, 1.2, 0)
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.font_size = 26
	_label.outline_size = 6
	add_child(_label)
	_update_label()
	_recolor()   # the wolf model's own baked grey isn't the dog's actual tint

func _try_real_wolf_model() -> bool:
	var glb_path := "res://assets/animals/wolf.glb"
	if not ResourceLoader.exists(glb_path):
		return false
	var packed: PackedScene = load(glb_path)
	var model := packed.instantiate()
	model.name = "Mesh"
	model.scale = Vector3(0.85, 0.85, 0.85)   # a dog reads a touch smaller than a wolf
	add_child(model)

	var marker := _find_node_named(model, "HeadMarker")
	_head = (marker as Node3D) if marker != null else model
	_build_googly_eyes(_head, 0.2 * 0.85)

	for i in range(4):
		var leg := _find_node_named(model, "Leg%d" % i)
		if leg != null and leg is Node3D:
			_legs.append(leg)
			_tinted_meshes.append(leg)
	var body_mesh := _find_node_named(model, "Wolf")
	if body_mesh != null:
		_tinted_meshes.append(body_mesh)
	var nose := _find_node_named(model, "Nose")
	if nose != null:
		_tinted_meshes.append(nose)

	var col := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 0.3
	shape.height = 1.0
	col.shape = shape
	col.rotation_degrees = Vector3(90, 0, 0)
	col.position = Vector3(0, 0.5, 0)
	add_child(col)
	return true

## Recursive child-name search -- same small helper animal.gd/npc.gd/
## tribemember.gd each keep their own copy of.
func _find_node_named(root_node: Node, part_name: String) -> Node:
	if root_node.name == part_name:
		return root_node
	for c in root_node.get_children():
		var found := _find_node_named(c, part_name)
		if found != null:
			return found
	return null

# two white sphere "eyes" with off-center black pupils -- same shared look
# every creature in this game uses, attached to the real model's HeadMarker.
func _build_googly_eyes(parent: Node3D, head_radius: float) -> void:
	for side in [-1.0, 1.0]:
		var eye := MeshInstance3D.new()
		var es := SphereMesh.new()
		es.radius = head_radius * 0.32
		es.height = head_radius * 0.64
		eye.mesh = es
		eye.position = Vector3(side * head_radius * 0.55, head_radius * 0.25, head_radius * 0.85)
		eye.material_override = MatCache.flat(Color(1, 1, 1))
		parent.add_child(eye)

		var pupil := MeshInstance3D.new()
		var ps := SphereMesh.new()
		ps.radius = head_radius * 0.14
		ps.height = head_radius * 0.28
		pupil.mesh = ps
		pupil.position = Vector3(randf_range(-0.04, 0.04) * head_radius, randf_range(-0.04, 0.04) * head_radius, head_radius * 0.3)
		pupil.material_override = MatCache.flat(Color(0.05, 0.05, 0.05))
		eye.add_child(pupil)

func _recolor() -> void:
	# loyal dogs warm to a friendly tan; the collar-flash sells the bond
	_color = Color(0.72, 0.56, 0.30) if is_loyal() else Color(0.5, 0.5, 0.52)
	var mat := MatCache.flat(_color)
	for n in _tinted_meshes:
		if n is MeshInstance3D and is_instance_valid(n):
			(n as MeshInstance3D).material_override = mat

func _update_label() -> void:
	if _label == null:
		return
	if is_loyal():
		var m := "guarding" if mode == Mode.GUARD else "at heel"
		_label.text = "%s  ♥ (%s)" % [member_name, m]
		_label.modulate = Color(0.6, 1.0, 0.6)
	else:
		_label.text = "stray dog  [H to feed]" if (_player_near()) else "stray dog"
		_label.modulate = Color(0.85, 0.85, 0.9)

func _player_near() -> bool:
	return _player != null and is_instance_valid(_player) and global_position.distance_to(_player.global_position) <= FEED_RANGE

# ── the player feeds us a scrap; trust grows, and enough of it tames us ──
func feed() -> void:
	loyalty = minf(2.0, loyalty + 0.5)
	hp = minf(max_hp, hp + 8.0)
	if anim: anim.pop(0.8)
	if not is_in_group("loyal_dog") and is_loyal():
		_become_loyal()
	_recolor()
	_update_label()

func _become_loyal() -> void:
	add_to_group("loyal_dog")
	# also a full member of group "tribe" — counts toward your tribe's
	# numbers (outnumber checks, base-defense scans) and is now a real
	# target rival NPCs will engage, not just during a siege
	add_to_group("tribe")
	mode = Mode.HEEL if (manager and manager.get("dogs_heel")) else Mode.GUARD
	if manager and "dogs" in manager and self not in manager.dogs:
		manager.dogs.append(self)
	print("A stray dog joins you!")

# the manager rallies the whole pack between guarding and heeling
func rally(heel: bool) -> void:
	if not is_loyal():
		return
	mode = Mode.HEEL if heel else Mode.GUARD
	if anim: anim.pop(0.4)
	_update_label()

var _grid_cd: float = 0.0

func _exit_tree() -> void:
	SpatialGrid.remove(self)

func _physics_process(delta: float) -> void:
	_tick_accum += delta
	var interval := 1.0 / TICK_HZ
	while _tick_accum >= interval:
		_tick_accum -= interval
		_brain_tick()

	# register in the world spatial grid — see spatial_grid.gd / npc.gd
	_grid_cd -= delta
	if _grid_cd <= 0.0:
		_grid_cd = 0.25
		SpatialGrid.update(self)
	_attack_cd = maxf(0.0, _attack_cd - delta)
	_move(delta)
	_check_stuck(delta)
	_animate_body(delta)

# snagged on a fence (or anything else) while clearly trying to move — shove
# sideways to dislodge, same fix as animal.gd. Dogs don't bash fences either.
func _check_stuck(delta: float) -> void:
	_stuck_cd -= delta
	if _stuck_cd > 0.0:
		return
	_stuck_cd = 0.6
	var moved := global_position.distance_to(_last_pos)
	_last_pos = global_position
	if Vector2(velocity.x, velocity.z).length() > 0.3 and moved < 0.12:
		var a := randf() * TAU
		velocity.x += cos(a) * wander_speed * 2.0
		velocity.z += sin(a) * wander_speed * 2.0
		_wander_target = home + Vector3(cos(a), 0, sin(a)) * randf_range(2.0, 6.0)
		_wander_target.y = home.y

func _animate_body(delta: float) -> void:
	if anim == null:
		return
	var spd := Vector2(velocity.x, velocity.z).length()
	# bristle (tension) when a foe is in sight; alert/up when loyal & on guard
	anim.tension = clampf(brain.get_potential("SeeFoe") / 50.0, 0.0, 1.0)
	anim.mood = 0.4 if (is_loyal() and _foe != null) else (0.15 if is_loyal() else -0.1)
	anim.tick(delta, spd, is_on_floor())
	_animate_legs(delta, spd)

## Real per-leg walk cycle (real model only -- _legs stays empty on the old
## primitive fallback, so this quietly no-ops there). Diagonal/trot gait,
## same technique as animal.gd's 4-leg version, including its Z-axis fix
## ("legs go sideways not forward/backward" -- see that file's own comment).
const LEG_SWING_MAX := 0.55
const LEG_SWING_REF_SPEED := 2.6

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

func _brain_tick() -> void:
	_player = get_tree().get_first_node_in_group("player")
	if is_loyal():
		if _foe != null and is_instance_valid(_foe):
			brain.stimulate("SeeFoe", 70.0)
	else:
		# a wary stray bristles a little at the big two-legs, but won't bolt
		if _player and is_instance_valid(_player) and global_position.distance_to(_player.global_position) < 4.0:
			brain.stimulate("SeeThreat", 20.0)
	var fired: Array = brain.step()
	if "Bark" in fired and anim:
		anim.pop(0.3)

# ─────────────────────────────────────────────────────────────────────────────
func _move(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = 0.0

	match mode:
		Mode.GUARD:
			_guard(delta)
		Mode.HEEL:
			_heel(delta)
		_:
			_wander(delta, spawn_pos, 7.0)

	_apply_separation()
	move_and_slide()

func _guard(delta: float) -> void:
	_foe_cd -= delta
	if _foe_cd <= 0.0:
		_foe_cd = 0.4
		_foe = _find_foe(GUARD_SENSE, home, GUARD_LEASH)
	if _foe != null and is_instance_valid(_foe):
		_engage(_foe, delta)
	else:
		_foe = null
		_wander(delta, home, 12.0)   # patrol the camp

func _heel(delta: float) -> void:
	if _player == null or not is_instance_valid(_player):
		_guard(delta)
		return
	# snap at any rival that comes near the master
	_foe_cd -= delta
	if _foe_cd <= 0.0:
		_foe_cd = 0.4
		_foe = _find_foe(8.0, _player.global_position, 12.0)
	if _foe != null and is_instance_valid(_foe):
		_engage(_foe, delta)
		return
	_foe = null
	var d := global_position.distance_to(_player.global_position)
	if d > HEEL_DIST + 1.2:
		var to := _player.global_position - global_position
		to.y = 0.0
		_drive(to.normalized(), chase_speed if d > 7.0 else wander_speed, delta)
	else:
		_halt()
		_face(_player.global_position, delta)

func _engage(foe: Node3D, delta: float) -> void:
	var to := foe.global_position - global_position
	to.y = 0.0
	var d := to.length()
	if d <= 1.5:
		_halt()
		_face(foe.global_position, delta)
		_attack(foe)
	else:
		_drive(to.normalized(), chase_speed, delta)

func _attack(foe) -> void:
	if _attack_cd > 0.0:
		return
	_attack_cd = 0.55
	if anim: anim.pop(0.45)          # a lunging snap
	if foe.has_method("take_hit"):
		foe.take_hit(bite, self)

# nearest hostile (a non-neutral tribesperson) within `sense` of me and `leash`
# of the anchor point I'm tethered to
func _find_foe(sense: float, anchor: Vector3, leash: float) -> Node3D:
	var best: Node3D = null
	var bd := sense
	for o in get_tree().get_nodes_in_group("npc"):
		var n := o as Node3D
		if n == null or not is_instance_valid(n) or n.get("neutral"):
			continue
		if anchor.distance_to(n.global_position) > leash:
			continue
		var d := global_position.distance_to(n.global_position)
		if d < bd:
			bd = d
			best = n
	return best

func take_hit(dmg: float, attacker) -> void:
	hp -= dmg
	if anim:
		anim.pop(0.5)
		anim.tension = 1.0
	if hp <= 0.0:
		die()
	elif not is_loyal() and attacker:
		_flee_timer = 1.2   # an untamed stray yelps and bolts when struck

func die() -> void:
	if manager and "dogs" in manager and self in manager.dogs:
		manager.dogs.erase(self)
	queue_free()

func _wander(delta: float, center: Vector3, radius: float) -> void:
	if _flee_timer > 0.0:
		_flee_timer -= delta
		if _player and is_instance_valid(_player):
			var away := global_position - _player.global_position
			away.y = 0.0
			if away.length() > 0.01:
				_drive(away.normalized(), flee_speed, delta)
				return
	if _wander_pause > 0.0:
		_wander_pause -= delta
		_halt()
		return
	var flat := global_position - _wander_target
	flat.y = 0.0
	if flat.length() <= ARRIVE or _wander_target.distance_to(center) > radius + 4.0:
		var ang := randf() * TAU
		var r := randf() * radius
		_wander_target = center + Vector3(cos(ang), 0, sin(ang)) * r
		_wander_target.y = center.y
		_wander_pause = randf_range(0.7, 2.4)
		_halt()
		return
	var to := _wander_target - global_position
	to.y = 0.0
	if to.length() > 0.001:
		_drive(to.normalized(), wander_speed, delta)

func _apply_separation() -> void:
	var push := Vector3.ZERO
	for o in get_tree().get_nodes_in_group("dog"):
		if o == self or not is_instance_valid(o):
			continue
		var d := global_position - (o as Node3D).global_position
		d.y = 0.0
		var dist := d.length()
		if dist > 0.01 and dist < 1.2:
			push += d.normalized() * (1.2 - dist)
	if push.length() > 0.001:
		velocity.x += push.x * wander_speed
		velocity.z += push.z * wander_speed

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
	rotation.y = lerp_angle(rotation.y, yaw, clampf(delta * 9.0, 0.0, 1.0))
