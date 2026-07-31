extends StaticBody3D
# ─────────────────────────────────────────────────────────────────────────────
# BlacksmithForge — a real, distinct workstation structure, not just a plain
# worked block. "make sure both npc and player tribes are creating
# blacksmiths, and other profession-related workstations" -- raised
# automatically wherever a Crafting district settlement is founded (see
# Tribemanager._build_district_structures()) and by rival tribes once their
# own building progression reaches it (see world_tribe.gd). In group
# "blacksmith_forge".
# ─────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	add_to_group("blacksmith_forge")
	_build_visual()

## REAL ASSET (2026-07-27): Kenney Survival Kit's workbench-anvil.glb (CC0,
## downloaded not generated) replaces the old anvil-box + stand-cylinder pair
## with one real, textured anvil-on-a-stump model (it already ships with its
## own hammer resting on top). No material_override -- textured, and this one
## already reads as a distinct workstation on its own without needing tinting.
const ANVIL_GLB := "res://assets/survival/workbench-anvil.glb"
const ANVIL_MEASURED_HEIGHT := 0.29575
const ANVIL_TARGET_HEIGHT := 0.85

func _build_visual() -> void:
	if not _try_real_anvil():
		var anvil := MeshInstance3D.new()
		var abox := BoxMesh.new()
		abox.size = Vector3(0.9, 0.5, 0.5)
		anvil.mesh = abox
		anvil.position = Vector3(0, 0.55, 0)
		anvil.material_override = MatCache.flat(Color(0.15, 0.15, 0.17), 0.3, 0.8)
		add_child(anvil)

		var stand := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.25; cyl.bottom_radius = 0.3; cyl.height = 0.55
		stand.mesh = cyl
		stand.position = Vector3(0, 0.28, 0)
		stand.material_override = MatCache.flat(Color(0.35, 0.24, 0.14))
		add_child(stand)

	var forge := MeshInstance3D.new()
	var fbox := BoxMesh.new()
	fbox.size = Vector3(1.3, 0.8, 1.3)
	forge.mesh = fbox
	forge.position = Vector3(1.6, 0.4, 0)
	forge.material_override = MatCache.flat(Color(0.42, 0.24, 0.16))
	add_child(forge)

	var embers := OmniLight3D.new()
	embers.light_color = Color(1.0, 0.45, 0.15)
	embers.omni_range = 4.0
	embers.light_energy = 1.2
	embers.position = Vector3(1.6, 0.9, 0)
	add_child(embers)

	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(3.2, 1.0, 1.6)
	col.shape = shape
	col.position = Vector3(0.8, 0.5, 0)
	add_child(col)

	var label := Label3D.new()
	label.text = "Blacksmith Forge"
	label.position = Vector3(0.8, 1.6, 0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.modulate = Color(0.85, 0.55, 0.30)
	add_child(label)

func _try_real_anvil() -> bool:
	if not ResourceLoader.exists(ANVIL_GLB):
		return false
	var packed: PackedScene = load(ANVIL_GLB)
	var inst := packed.instantiate()
	if not (inst is Node3D):
		inst.queue_free()
		return false
	var s: float = ANVIL_TARGET_HEIGHT / ANVIL_MEASURED_HEIGHT
	(inst as Node3D).scale = Vector3(s, s, s)
	add_child(inst)
	return true
