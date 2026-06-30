extends StaticBody3D
# ─────────────────────────────────────────────────────────────────────────────
# Tree — solid forest prop you can KNOCK DOWN for wood. Hit it with your club
# (LMB) a few times; when it falls it yields wood to your stockpile. In group
# "tree". Trunk is a thin collider so move_and_slide just slides around the woods.
# ─────────────────────────────────────────────────────────────────────────────

var hp: int = 3
var wood: int = 3
var _fallen: bool = false
var _trunk: MeshInstance3D = null

func _ready() -> void:
	add_to_group("tree")
	_build()

func _build() -> void:
	var h := randf_range(3.0, 6.5)
	hp = 2 + int(h / 2.0)
	wood = 2 + int(h / 1.8)

	_trunk = MeshInstance3D.new()
	var tm := CylinderMesh.new()
	tm.top_radius = 0.22
	tm.bottom_radius = 0.34
	tm.height = h
	_trunk.mesh = tm
	_trunk.position = Vector3(0, h * 0.5, 0)
	var tmat := StandardMaterial3D.new()
	tmat.albedo_color = Color(0.34, 0.24, 0.15)
	_trunk.material_override = tmat
	add_child(_trunk)

	var leaves := MeshInstance3D.new()
	var lm := SphereMesh.new()
	var lr := randf_range(1.5, 2.7)
	lm.radius = lr
	lm.height = lr * 2.0
	leaves.mesh = lm
	leaves.position = Vector3(0, h + lr * 0.35, 0)
	var lmat := StandardMaterial3D.new()
	lmat.albedo_color = Color(0.15, 0.38, 0.17).lerp(Color(0.30, 0.55, 0.22), randf())
	leaves.material_override = lmat
	add_child(leaves)
	# NO collision: a dense forest with no pathfinding would snag wandering NPCs.
	# Trees are still choppable (found by distance), just walk-through.

# returns wood gained if the tree falls this hit, else 0
func chop(dmg: int = 1) -> int:
	if _fallen:
		return 0
	hp -= dmg
	if _trunk:
		_trunk.rotation.z = randf_range(-0.07, 0.07)   # shudder on impact
	if hp <= 0:
		_fallen = true
		var w := wood
		queue_free()
		return w
	return 0
