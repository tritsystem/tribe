extends Area3D
# ─────────────────────────────────────────────────────────────────────────────
# TribeSpellBolt — a real magic bolt projectile, same physical-flight pattern
# as tribe_arrow.gd/thrown_club.gd but glowing + carries a real burn DoT
# effect on hit (not just flat damage) -- added 2026-08-28 as tribe's first
# "magic" weapon, wands for WEAPON_TIERS[4].
# ─────────────────────────────────────────────────────────────────────────────

var velocity: Vector3 = Vector3.ZERO
var damage: float = 10.0
var dot_damage: float = 3.0
var dot_ticks: int = 3
var thrower = null
var _life: float = 2.2

func _ready() -> void:
	monitoring = true
	add_to_group("thrown_club")
	body_entered.connect(_on_body_entered)

	var mesh := MeshInstance3D.new()
	var m := SphereMesh.new()
	m.radius = 0.14
	m.height = 0.28
	mesh.mesh = m
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.55, 0.25, 0.95)
	mat.emission_enabled = true
	mat.emission = Color(0.65, 0.30, 1.0)
	mat.emission_energy_multiplier = 4.0
	mesh.material_override = mat
	add_child(mesh)

	var light := OmniLight3D.new()
	light.light_color = Color(0.65, 0.30, 1.0)
	light.omni_range = 3.0
	light.light_energy = 1.2
	add_child(light)

	var col := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = 0.16
	col.shape = shape
	add_child(col)

func launch(from: Vector3, dir: Vector3, speed: float, dmg: float, dot_dmg: float, who) -> void:
	global_position = from
	velocity = dir.normalized() * speed
	damage = dmg
	dot_damage = dot_dmg
	thrower = who

func _physics_process(delta: float) -> void:
	_life -= delta
	if _life <= 0.0:
		queue_free()
		return
	global_position += velocity * delta   # magic bolt flies straight, no gravity

func _on_body_entered(body: Node) -> void:
	if body == thrower:
		return
	var mgr = thrower.manager if (thrower and "manager" in thrower) else null
	var target = null
	if body.is_in_group("npc") and not body.get("neutral") and body.has_method("take_hit"):
		target = body
	elif body.is_in_group("tribe") and body.has_method("take_hit"):
		target = body
	elif body.is_in_group("troll") and body.has_method("take_hit"):
		target = body
	if target != null:
		target.take_hit(damage, thrower)
		_apply_dot(target, 0)
		if thrower and "weapon_pref" in thrower:
			thrower.weapon_pref.on_combat_success(4)   # Wand
		if mgr and mgr.has_method("notify"):
			mgr.notify("A bolt of magic strikes true!")
		queue_free()
		return
	if body.is_in_group("animal") and body.has_method("killed"):
		var loot: Dictionary = body.killed()
		if mgr:
			mgr.add_food(int(loot.get("food", 0)))
			mgr.add_materials(int(loot.get("skins", 0)))
		queue_free()
		return
	if body.is_in_group("fence") and body.has_method("take_damage"):
		body.take_damage(1)
		queue_free()

## Real burn DoT -- separate timer-based ticks, same "dedicated helper avoids
## nested-lambda capture bugs" pattern horde-beta's sword.gd uses for its
## own enchantment DoTs.
func _apply_dot(target: Node, tick: int) -> void:
	if not is_instance_valid(target) or tick >= dot_ticks:
		return
	if target.has_method("take_hit"):
		target.take_hit(dot_damage, thrower)
	var t := target.get_tree().create_timer(0.8)
	t.timeout.connect(_apply_dot.bind(target, tick + 1), CONNECT_ONE_SHOT)
