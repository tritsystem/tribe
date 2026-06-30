extends Node3D
# ─────────────────────────────────────────────────────────────────────────────
# RivalTribe — an enemy camp out in the world.
#
# Built in code by the TribeManager when one of your members SCOUTS and finds it.
# It's a cluster of red figures with a banner; its `strength` decides whether
# your raid (R+4 as leader) wins loot or limps home. defeat() clears it.
# ─────────────────────────────────────────────────────────────────────────────

var tribe_name: String = "Rivals"
var strength: int = 60
var defeated: bool = false

func setup(nm: String, str_value: int) -> void:
	tribe_name = nm
	strength = str_value
	_build()

func _build() -> void:
	var count: int = clampi(int(strength / 25.0), 2, 6)
	for i in range(count):
		var fig := MeshInstance3D.new()
		fig.mesh = CapsuleMesh.new()
		var ang := TAU * float(i) / float(count)
		fig.position = Vector3(cos(ang) * 2.0, 1.0, sin(ang) * 2.0)
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.72, 0.25, 0.22)
		fig.material_override = mat
		add_child(fig)

	var banner := Label3D.new()
	banner.text = "%s\n(rival camp · str %d)" % [tribe_name, strength]
	banner.position = Vector3(0, 3.4, 0)
	banner.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	banner.modulate = Color(1.0, 0.6, 0.5)
	banner.font_size = 36
	banner.outline_size = 8
	add_child(banner)

func defeat() -> void:
	defeated = true
	queue_free()
