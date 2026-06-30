extends Area3D
# ─────────────────────────────────────────────────────────────────────────────
# ThrownClub — a physically thrown club. Spawned by FPSPlayer._throw_club(),
# it actually flies through the air (with a light gravity arc + tumble) and
# deals damage to whatever it touches, instead of an instant invisible
# raycast. Falls to the ground and despawns if it misses everything.
# ─────────────────────────────────────────────────────────────────────────────

var velocity: Vector3 = Vector3.ZERO
var damage: float = 22.0
var thrower = null
var _life: float = 2.5
var fall_accel: float = 7.0   # named to avoid colliding with Area3D's own native "gravity" property

func _ready() -> void:
	monitoring = true
	body_entered.connect(_on_body_entered)

	var mesh := MeshInstance3D.new()
	var m := BoxMesh.new()
	m.size = Vector3(0.08, 0.08, 0.7)
	mesh.mesh = m
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.45, 0.30, 0.15)
	mesh.material_override = mat
	add_child(mesh)

	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.12, 0.12, 0.7)
	col.shape = shape
	add_child(col)

func launch(from: Vector3, dir: Vector3, speed: float, dmg: float, who) -> void:
	global_position = from
	velocity = dir.normalized() * speed
	damage = dmg
	thrower = who
	if dir.length() > 0.01:
		look_at(global_position + dir, Vector3.UP)

func _physics_process(delta: float) -> void:
	_life -= delta
	if _life <= 0.0:
		queue_free()
		return
	velocity.y -= fall_accel * delta
	global_position += velocity * delta
	rotate_x(delta * 16.0)   # tumble end-over-end while it flies
	if global_position.y < 0.15:
		queue_free()   # hit the ground — lost in the grass

func _on_body_entered(body: Node) -> void:
	if body == thrower:
		return
	var mgr = thrower.manager if (thrower and "manager" in thrower) else null
	if body.is_in_group("npc") and not body.get("neutral") and body.has_method("take_hit"):
		body.take_hit(damage, thrower)
		if mgr and mgr.has_method("notify"):
			mgr.notify("Your thrown club strikes true!")
		queue_free()
	elif body.is_in_group("animal") and body.has_method("killed"):
		var loot: Dictionary = body.killed()
		if mgr:
			mgr.add_food(int(loot.get("food", 0)))
			mgr.add_materials(int(loot.get("skins", 0)))
			if mgr.has_method("notify"):
				mgr.notify("Club throw downs a %s! +%d meat, +%d skins" %
					[loot.get("name", "beast"), int(loot.get("food", 0)), int(loot.get("skins", 0))])
		queue_free()
	elif body.is_in_group("fence") and body.has_method("take_damage"):
		body.take_damage(2)
		queue_free()
