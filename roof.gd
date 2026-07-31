extends StaticBody3D
# ─────────────────────────────────────────────────────────────────────────────
# Roof — the "structure with a roof" piece. A shallow four-sided pyramid slab
# that caps a keep or a corner tower, turning an open ring of blocks into an
# enclosed, roofed building. Built as a StaticBody3D on the STRUCTURE collision
# layer (bit 4 / collision_layer 8), exactly like block.gd/fence.gd, so:
#   • the AI (mask 1) phases through it and never jams on it, and
#   • it's still a real, group-findable node.
# collision_mask is 0 as well — a roof sits high in the air on top of walls, so
# it should never itself collide with or trap anything.
#
# COSMETIC-STRUCTURAL: take_damage() is a no-op. Conquest is still gated ONLY by
# a camp's teepees + stockpile (see world_tribe.damage_camp) — a roof, like a
# curtain-wall block, is extra structure that must NOT make a camp unconquerable.
# In group "roof".
# ─────────────────────────────────────────────────────────────────────────────

# Set BEFORE add_child() by the placer (world_tribe._place_segment) so _ready
# builds the mesh at the right size. Sensible defaults keep a bare roof.new()
# from looking broken.
var footprint: float = 6.0     # width/depth of the square the roof covers
var roof_height: float = 3.0   # how tall the pyramid rises above its base
var tint: Color = Color(0.48, 0.20, 0.13)   # weathered timber/thatch red-brown

func _ready() -> void:
	add_to_group("roof")
	# same structure layer as block.gd — AI phases through, only the player masks
	# it. mask 0 so the roof never collides against anything itself.
	collision_layer = 8
	collision_mask = 0
	_build()

func _build() -> void:
	# REAL ASSET (2026-07-27): Kenney Survival Kit's structure-roof.glb (CC0,
	# downloaded not generated), textured, scaled non-uniformly to fit
	# whatever footprint/roof_height this instance was placed with -- same
	# "scale a real mesh to a variable footprint" trick already used for the
	# turtle shell and the boat hull. No material_override (the asset is
	# textured, and overriding would flatten its baked look) -- the `tint`
	# per-tribe color variation only applies to the old primitive fallback.
	if not _try_real_roof():
		var mi := MeshInstance3D.new()
		var pm := CylinderMesh.new()
		pm.top_radius = 0.0
		# corner-reach: a 4-gon inscribed in this radius has its flat sides at
		# radius/sqrt(2); we want the sides to reach the footprint edge, so scale up.
		pm.bottom_radius = footprint * 0.5 * sqrt(2.0)
		pm.height = roof_height
		pm.radial_segments = 4
		mi.mesh = pm
		mi.rotation.y = PI * 0.25
		# CylinderMesh is centred on its origin; lift so the pyramid BASE sits at
		# local y=0 (i.e. exactly on top of the wall the caller placed us at).
		mi.position.y = roof_height * 0.5
		mi.material_override = MatCache.flat(tint, 0.9, 0.0)
		add_child(mi)

	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(footprint, roof_height, footprint)
	col.shape = shape
	col.position = Vector3(0, roof_height * 0.5, 0)
	add_child(col)

## Real Kenney roof piece, measured local AABB roughly 0.5 x 0.657 x 0.5 (the
## main slab; a small "Group" trim child hangs slightly below, kept as-is).
## Scaled non-uniformly so footprint/height match exactly whatever this
## instance was placed with, same math as world_tribe.gd's turtle shell.
const ROOF_GLB := "res://assets/survival/structure-roof.glb"
const ROOF_MEASURED_XZ := 0.5
const ROOF_MEASURED_Y := 0.657183

func _try_real_roof() -> bool:
	if not ResourceLoader.exists(ROOF_GLB):
		return false
	var packed: PackedScene = load(ROOF_GLB)
	var inst := packed.instantiate()
	if not (inst is Node3D):
		inst.queue_free()
		return false
	(inst as Node3D).scale = Vector3(footprint / ROOF_MEASURED_XZ, roof_height / ROOF_MEASURED_Y, footprint / ROOF_MEASURED_XZ)
	add_child(inst)
	return true

# Cosmetic-structural: conquest routes through teepees + stockpile only, so a
# roof simply absorbs and ignores blows rather than gating defeat.
func take_damage(_d: float, _attacker = null) -> void:
	pass
