extends StaticBody3D
# ─────────────────────────────────────────────────────────────────────────────
# Teepee — a dwelling raised around a camp (player or NPC tribe). Destroyable
# like any built structure — and for a rival WorldTribe, owner_tribe is set
# (world_tribe.gd._build_palisade) so losing this teepee actually counts:
# damage_camp() routes every blow through the standing teepees first, then
# the stockpile, and only once both are gone does the clan fall.
# In group "teepee".
# ─────────────────────────────────────────────────────────────────────────────

var hp: float = 20.0
var tint: Color = Color(0.55, 0.42, 0.28)
var owner_tribe = null   # set by world_tribe.gd when it raises this teepee

func _ready() -> void:
	add_to_group("teepee")
	_build()

func _build() -> void:
	var cone := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.05
	cm.bottom_radius = 1.1
	cm.height = 2.6
	cone.mesh = cm
	cone.position = Vector3(0, 1.3, 0)
	cone.material_override = MatCache.flat(tint)
	add_child(cone)

	# a dark smoke-hole gap at the top
	var cap := MeshInstance3D.new()
	var cs := CylinderMesh.new()
	cs.top_radius = 0.06
	cs.bottom_radius = 0.18
	cs.height = 0.3
	cap.mesh = cs
	cap.position = Vector3(0, 2.55, 0)
	cap.material_override = MatCache.flat(Color(0.08, 0.07, 0.06))
	add_child(cap)

	# NO collision: same reasoning as tree.gd. Camps cluster 2-4 of these
	# tightly together, and bashing through one only to immediately wedge on
	# the next made "stuck on teepees" take many seconds to resolve even
	# with the stuck-bash fallback in npc.gd/tribemember.gd. take_damage()
	# is still reachable for combat (siege routing, melee range checks) —
	# those are distance/array based, not physics-collision based — so
	# teepees stay fully destroyable, just not a movement obstacle.

func take_damage(d: float, _attacker = null) -> void:
	hp -= d
	if hp <= 0:
		if owner_tribe != null and is_instance_valid(owner_tribe) and owner_tribe.has_method("on_teepee_lost"):
			owner_tribe.on_teepee_lost(self)
		queue_free()
