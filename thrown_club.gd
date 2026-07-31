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
	add_to_group("thrown_club")   # so nearby animals sense it and flinch/flee
	body_entered.connect(_on_body_entered)

	var mesh := MeshInstance3D.new()
	# REAL ASSET (2026-07-27): joe345's Dagger.glb (itch.io, CC0) -- same
	# asset FPSPlayer.gd's viewmodel and tribemember.gd's tier-0 use, so the
	# thrown projectile matches what was actually thrown. material_override
	# stays null (real mesh, textureless-but-multi-material -- see
	# tribemember.gd's own note on why these aren't recolored).
	var real_dagger := _get_real_dagger_mesh()
	if real_dagger != null:
		mesh.mesh = real_dagger
		mesh.scale = Vector3(2.5, 2.5, 2.5)   # measured height 0.312 -- matches tribemember.gd's tier-0 sizing
	else:
		var m := BoxMesh.new()
		m.size = Vector3(0.08, 0.08, 0.7)
		mesh.mesh = m
		mesh.material_override = MatCache.flat(Color(0.45, 0.30, 0.15))
	add_child(mesh)

	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.12, 0.12, 0.7)
	col.shape = shape
	add_child(col)

static var _real_dagger_mesh: Mesh = null   # cached so repeated throws don't re-load the file

static func _get_real_dagger_mesh() -> Mesh:
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

static func _find_dagger_mesh(root_node: Node) -> MeshInstance3D:
	if root_node is MeshInstance3D and root_node.name == "Dagger":
		return root_node as MeshInstance3D
	for c in root_node.get_children():
		var f := _find_dagger_mesh(c)
		if f != null:
			return f
	return null

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
		if thrower and thrower.has_method("screen_shake"):
			thrower.screen_shake(0.035)
		if mgr and mgr.has_method("notify"):
			mgr.notify("Your thrown club strikes true!")
		queue_free()
	elif body.is_in_group("tribe") and body.has_method("take_hit"):
		# own member -- take_hit() itself detects the player attacker and calls betray()
		body.take_hit(damage, thrower)
		if thrower and thrower.has_method("screen_shake"):
			thrower.screen_shake(0.035)
		if mgr and mgr.has_method("notify"):
			mgr.notify("Your thrown club strikes %s! They will not forget this." % str(body.get("member_name")))
		queue_free()
	elif body.is_in_group("troll") and body.has_method("take_hit"):
		body.take_hit(damage, thrower)
		if thrower and thrower.has_method("screen_shake"):
			thrower.screen_shake(0.045)
		if mgr and mgr.has_method("notify"):
			mgr.notify("Your thrown club strikes the troll!")
		queue_free()
	elif body.is_in_group("animal") and body.has_method("killed"):
		var loot: Dictionary = body.killed()
		if thrower and thrower.has_method("screen_shake"):
			thrower.screen_shake(0.04)
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
