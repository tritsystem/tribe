extends StaticBody3D
# ─────────────────────────────────────────────────────────────────────────────
# Fence — a buildable, solid palisade segment for walling off your camp. Costs
# wood to raise. It blocks movement and has HP, so raiders (or your own club)
# can knock it down. In group "fence".
# ─────────────────────────────────────────────────────────────────────────────

var hp: int = 6
var tint: Color = Color(0.46, 0.32, 0.18)
var _rail: MeshInstance3D = null
var _real_model: Node3D = null   # set when the real Kenney fence loaded -- shudders on hit instead of _rail

const FENCE_GLB := "res://assets/survival/fence.glb"
# real model measured at height 0.517m; scaled to match this game's existing
# ~1.6m fence-post height.
const FENCE_SCALE := 1.6 / 0.517467

func _ready() -> void:
	add_to_group("fence")
	# layer 4 = structures: player collides (masks it), AI phases through so it
	# can't jam on a fence. See block.gd for the full rationale.
	collision_layer = 8
	_build()

## REAL ASSET (2026-07-27): Kenney Survival Kit's fence.glb (CC0, downloaded
## not generated) instead of two BoxMesh posts + a rail. Textured (shares a
## colormap.png atlas with the rest of the kit) so it's used AS-IS, no
## material_override tint like the old primitive -- overriding would wipe the
## baked texture. Falls back to the old primitive if the asset is missing.
func _build() -> void:
	if _try_real_fence():
		_build_collision()
		return
	var mat := MatCache.flat(tint)
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
	_build_collision()

func _try_real_fence() -> bool:
	if not ResourceLoader.exists(FENCE_GLB):
		return false
	var packed: PackedScene = load(FENCE_GLB)
	var model := packed.instantiate()
	model.scale = Vector3(FENCE_SCALE, FENCE_SCALE, FENCE_SCALE)
	model.position = Vector3(0, 0.8, 0)
	add_child(model)
	_real_model = model
	return true

func _build_collision() -> void:
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
	elif _real_model:
		_real_model.rotation.z = randf_range(-0.1, 0.1)
	if hp <= 0:
		queue_free()
