extends Area3D
# ─────────────────────────────────────────────────────────────────────────────
# TribeArrow — a real fired arrow projectile, same physical-flight pattern as
# thrown_club.gd (velocity + gravity arc, body_entered hit detection) but
# faster/flatter (an arrow, not a tumbling thrown club) and reusable by both
# the player (if ever given a bow) and NPCs at WEAPON_TIERS index 2 ("Bow").
# Added 2026-08-28 as part of giving tribe NPCs bow+arrow as a real ranged
# option distinct from melee/club-throw.
# ─────────────────────────────────────────────────────────────────────────────

var velocity: Vector3 = Vector3.ZERO
var damage: float = 14.0
var thrower = null
var _life: float = 3.0
var fall_accel: float = 3.5   # flatter arc than a thrown club -- an arrow flies true longer

func _ready() -> void:
	monitoring = true
	add_to_group("thrown_club")   # reuse the same "incoming projectile" sense group animals already flinch from
	body_entered.connect(_on_body_entered)

	var mesh := MeshInstance3D.new()
	var m := CylinderMesh.new()
	m.top_radius = 0.015
	m.bottom_radius = 0.025
	m.height = 0.6
	mesh.mesh = m
	mesh.rotation_degrees.x = 90.0
	mesh.material_override = MatCache.flat(Color(0.42, 0.30, 0.16))
	add_child(mesh)

	var col := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 0.03
	shape.height = 0.6
	col.shape = shape
	col.rotation_degrees.x = 90.0
	add_child(col)

func launch(from: Vector3, dir: Vector3, speed: float, dmg: float, who) -> void:
	global_position = from
	velocity = dir.normalized() * speed
	damage = dmg
	thrower = who
	if dir.length() > 0.01:
		look_at(global_position + dir, Vector3.UP)
		rotate_object_local(Vector3.RIGHT, deg_to_rad(90.0))

func _physics_process(delta: float) -> void:
	_life -= delta
	if _life <= 0.0:
		queue_free()
		return
	velocity.y -= fall_accel * delta
	global_position += velocity * delta
	if global_position.y < 0.1:
		queue_free()

func _on_body_entered(body: Node) -> void:
	if body == thrower:
		return
	var mgr = thrower.manager if (thrower and "manager" in thrower) else null
	if body.is_in_group("npc") and not body.get("neutral") and body.has_method("take_hit"):
		body.take_hit(damage, thrower)
		if thrower and "weapon_pref" in thrower:
			thrower.weapon_pref.on_combat_success(2)   # Bow
		if mgr and mgr.has_method("notify"):
			mgr.notify("An arrow finds its mark!")
		queue_free()
	elif body.is_in_group("tribe") and body.has_method("take_hit"):
		body.take_hit(damage, thrower)
		queue_free()
	elif body.is_in_group("troll") and body.has_method("take_hit"):
		body.take_hit(damage, thrower)
		queue_free()
	elif body.is_in_group("animal") and body.has_method("killed"):
		var loot: Dictionary = body.killed()
		if mgr:
			mgr.add_food(int(loot.get("food", 0)))
			mgr.add_materials(int(loot.get("skins", 0)))
		queue_free()
	elif body.is_in_group("fence") and body.has_method("take_damage"):
		body.take_damage(1)
		queue_free()
