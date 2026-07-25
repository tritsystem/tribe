








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
var _head: MeshInstance3D = null
var _label: Label3D = null
var _color: Color = Color(0.55, 0.45, 0.32)
var _stuck_cd: float = 0.0       # throttles the snagged-on-something check
var _last_pos: Vector3 = Vector3.ZERO

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
func _build() -> void:
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

	_head = MeshInstance3D.new()
	var hs := SphereMesh.new()
	hs.radius = 0.2
	hs.height = 0.4
	_head.mesh = hs
	_head.position = Vector3(0, 0.62, 0.55)
	_head.material_override = mat
	add_child(_head)

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

func _recolor() -> void:
	# loyal dogs warm to a friendly tan; the collar-flash sells the bond
	_color = Color(0.72, 0.56, 0.30) if is_loyal() else Color(0.5, 0.5, 0.52)
	for n in [get_node_or_null("Mesh"), _head]:
		if n:
			(n as MeshInstance3D).material_override = MatCache.flat(_color)

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
