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

var brain: Spikeling
var anim: BodyAnim
var _head: MeshInstance3D
@export var species: String = "Deer"
@export var member_name: String = "Deer"     # lets the brain-viewer label it
@export var personality: String = "Wild"     # ditto (duck-typed with members)

var sense_radius: float = 7.0
var wander_speed: float = 1.7
var flee_speed: float = 2.4
var food_yield: int = 2
var skins_yield: int = 1

# species table: stats + how readily the brain panics (threat_w on SeeThreat->Flee)
const SPECIES := {
	"Rabbit": {"color": Color(0.80, 0.78, 0.72), "scale": 0.55, "wander": 2.1, "flee": 3.3, "sense": 9.5, "food": 1, "skins": 0, "threat_w": 160},
	"Deer":   {"color": Color(0.55, 0.40, 0.28), "scale": 1.0,  "wander": 1.7, "flee": 2.5, "sense": 7.0, "food": 2, "skins": 1, "threat_w": 130},
	"Boar":   {"color": Color(0.34, 0.30, 0.28), "scale": 1.15, "wander": 1.3, "flee": 1.9, "sense": 5.0, "food": 3, "skins": 2, "threat_w": 95},
}

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

func _build(sp: Dictionary) -> void:
	var s := float(sp["scale"])
	var mat := StandardMaterial3D.new()
	mat.albedo_color = sp["color"]

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
		var emat := StandardMaterial3D.new()
		emat.albedo_color = Color(1, 1, 1)
		eye.material_override = emat
		parent.add_child(eye)

		var pupil := MeshInstance3D.new()
		var ps := SphereMesh.new()
		ps.radius = head_radius * 0.14
		ps.height = head_radius * 0.28
		pupil.mesh = ps
		# pupils sit slightly off-center for the classic googly-eye wobble look
		pupil.position = Vector3(randf_range(-0.04, 0.04), randf_range(-0.04, 0.04), head_radius * 0.3)
		var pmat := StandardMaterial3D.new()
		pmat.albedo_color = Color(0.05, 0.05, 0.05)
		pupil.material_override = pmat
		eye.add_child(pupil)

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

# ── one spiking tick: feed senses in, read drives out ──
func _brain_tick() -> void:
	var threat := _nearest_threat()
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

func _move(delta: float) -> void:
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
	queue_free()
	return loot
