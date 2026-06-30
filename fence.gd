extends StaticBody3D
# ─────────────────────────────────────────────────────────────────────────────
# Fence — a buildable, solid palisade segment for walling off your camp. Costs
# wood to raise. It blocks movement and has HP, so raiders (or your own club)
# can knock it down. In group "fence".
# ─────────────────────────────────────────────────────────────────────────────

var hp: int = 6
var tint: Color = Color(0.46, 0.32, 0.18)
var _rail: MeshInstance3D = null

func _ready() -> void:
	add_to_group("fence")
	_build()

func _build() -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = tint
	for x in [-0.7, 0.7]:
		var post := MeshInstance3D.new()
		var pm := BoxMesh.new()
		pm.size = Vector3(0.22, 1.6, 0.22)
		post.mesh = pm
		post.position = Vector3(x, 0.8, 0)
		post.material_override = mat
		add_child(post)
	_rail = MeshInstance3D.new()
	var rm := BoxMesh.new()
	rm.size = Vector3(1.9, 0.28, 0.12)
	_rail.mesh = rm
	_rail.position = Vector3(0, 1.05, 0)
	_rail.material_override = mat
	add_child(_rail)

	var col := CollisionShape3D.new()
	var cs := BoxShape3D.new()
	cs.size = Vector3(1.9, 1.6, 0.35)
	col.shape = cs
	col.position = Vector3(0, 0.8, 0)
	add_child(col)

func take_damage(d: int, _attacker = null) -> void:
	hp -= d
	if _rail:
		_rail.rotation.z = randf_range(-0.1, 0.1)
	if hp <= 0:
		queue_free()
