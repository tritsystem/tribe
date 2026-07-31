extends StaticBody3D
# ─────────────────────────────────────────────────────────────────────────────
# BuildPiece — the fine-grained construction family alongside block.gd's
# plain cube. Where block.gd is deliberately ONE shape (a wall cube, shared
# static mesh across every instance for perf), this script gives builders
# real DIFFERENT pieces to place: STAIR (a shallow wedge — climbable half
# steps up a wall or tower), ROOF (a steeper triangular-prism cap — actually
# reads as a roof from outside, not a flat block lid), DOOR (a narrow slab
# that fills a gate opening — a real door, not just an unguarded gap in the
# wall), and SMALL (a half-size cube for fine-tuning: corners, ledges,
# in-fill that shouldn't be forced onto the coarse 2.0-unit wall grid).
#
# ROTATION + SIZE (2026-07-21): every piece now carries its own `yaw`
# (applied to the WHOLE body, not just the mesh, so collision turns with it)
# and `scale_factor` (0.5 small / 1.0 normal / 1.5 large, applied the same
# way) -- BUG FIX: the very first version of this file placed STAIR pieces
# at a fixed inward fraction of a tower's radius with no size/rotation
# awareness at all, which put them physically INSIDE the tower's own block
# columns (the two were less than one block-width apart) -- overlapping
# geometry that looked broken and made it look like "building" itself had
# stopped working, when the pieces were in fact placing successfully, just
# on top of each other. Real rotation + real configurable spacing (see
# Tribemanager._fortress_block_segments) is the actual fix, not a fudge
# factor -- a stair now sits flush OUTSIDE its tower, angled to face it.
#
# SAME PERFORMANCE DISCIPLINE AS block.gd: a castle can mean hundreds of
# these live at once, so mesh/material are cached ONE PER KIND (a static
# Dictionary keyed by Kind), never allocated per-instance. Scale is applied
# to the NODE transform, not baked into the mesh, so the shared-mesh cache
# still holds across every size variant of a given kind.
#
# Godot 4's PrismMesh is the natural fit for STAIR and ROOF: it's a real
# wedge/ridge primitive (a `left_to_right` taper on a box), not a
# hand-modelled shape. Collision uses a plain bounding box for every kind
# (there is no native collision primitive matching a prism, and a slightly
# generous box is the same honest approximation block.gd already uses for
# its own cube).
# In group "build_piece".
# ─────────────────────────────────────────────────────────────────────────────

const FULL_SIZE := 2.0    # matches BlockScript.SIZE so pieces line up on the same grid
const SMALL_SIZE := 1.0   # the fine-detail unit — half a full block

enum Kind { STAIR, ROOF, SMALL, DOOR }

# size configuration ("different sizes", as asked) — a plain multiplier on
# the node transform, so one cached mesh per kind still covers every size.
const SCALE_SMALL  := 0.5
const SCALE_NORMAL := 1.0
const SCALE_LARGE  := 1.5

var kind: Kind = Kind.STAIR
var yaw: float = 0.0             # facing/rotation this piece is placed with
var scale_factor: float = SCALE_NORMAL
var hp: float = 16.0
var owner_tribe = null   # set when a rival WorldTribe places this (cleanup bookkeeping)

static var _mesh_cache: Dictionary = {}   # Kind -> Mesh
static var _mat_cache: Dictionary = {}    # Kind -> StandardMaterial3D
static var _real_mesh_cache: Dictionary = {}   # Kind -> Mesh, or `false` if tried and unavailable

## REAL ASSETS (2026-07-27): Kenney Survival Kit pieces reused for DOOR/ROOF/
## SMALL -- CC0, downloaded not generated. No real stair piece exists in this
## kit (or any downloaded so far), so STAIR stays the procedural PrismMesh
## wedge. structure-roof.glb is the SAME asset roof.gd uses for a whole
## island building's pyramid cap, reused here at grid-tile scale for one
## build_piece -- same "one real asset, several contexts" pattern already
## used for the Dagger across tribemember.gd/FPSPlayer.gd/thrown_club.gd.
const KIND_REAL_GLB := {
	Kind.DOOR:  "res://assets/survival/structure-metal-doorway.glb",
	Kind.ROOF:  "res://assets/survival/structure-roof.glb",
	Kind.SMALL: "res://assets/survival/structure.glb",
}
# measured local AABB size per real piece (X, Y, Z)
const KIND_REAL_MEASURED := {
	Kind.DOOR:  Vector3(0.53543, 0.5, 0.088905),
	Kind.ROOF:  Vector3(0.5, 0.657183, 0.5),
	Kind.SMALL: Vector3(0.5, 0.5, 0.5),
}

func _ready() -> void:
	add_to_group("build_piece")
	# same STRUCTURE collision layer as block.gd (bit 4): the player collides
	# with it, but AI characters (mask 1) phase through so members/raiders
	# never wedge on their own construction — see block.gd's own comment for
	# the full story of why walls moved off the default layer.
	collision_layer = 8
	rotation.y = yaw
	scale = Vector3.ONE * scale_factor
	_build()

func _build() -> void:
	var mesh := MeshInstance3D.new()
	var real_mesh: Mesh = _get_real_mesh(kind)
	if real_mesh != null:
		mesh.mesh = real_mesh
		var measured: Vector3 = KIND_REAL_MEASURED.get(kind, Vector3.ONE)
		var target: Vector3 = _target_size(kind)
		mesh.scale = Vector3(target.x / measured.x, target.y / measured.y, target.z / measured.z)
		# no material_override -- all three of these are textured
	else:
		mesh.mesh = _get_mesh(kind)
		mesh.material_override = _get_mat(kind)
		if kind == Kind.ROOF:
			mesh.rotation.x = PI   # point the ridge upward instead of down into the ground
	add_child(mesh)

	var col := CollisionShape3D.new()
	col.shape = _get_shape(kind)
	add_child(col)

## The real asset's TARGET world size per kind -- matches whatever the old
## procedural mesh measured for that kind, so swapping to a real asset never
## changes a piece's footprint/collision fit.
static func _target_size(k: Kind) -> Vector3:
	match k:
		Kind.DOOR:  return Vector3(FULL_SIZE * 0.7, FULL_SIZE * 1.4, 0.2)
		Kind.ROOF:  return Vector3(FULL_SIZE * 1.15, FULL_SIZE * 1.2, FULL_SIZE * 0.97)
		Kind.SMALL: return Vector3(SMALL_SIZE, SMALL_SIZE, SMALL_SIZE) * 0.97
		_: return Vector3.ONE

static func _get_real_mesh(k: Kind) -> Mesh:
	if _real_mesh_cache.has(k):
		var cached = _real_mesh_cache[k]
		return cached if cached is Mesh else null
	var path: String = str(KIND_REAL_GLB.get(k, ""))
	if path == "" or not ResourceLoader.exists(path):
		_real_mesh_cache[k] = false
		return null
	var packed: PackedScene = load(path)
	var inst := packed.instantiate()
	var found := _find_mesh_recursive(inst)
	if found == null:
		inst.queue_free()
		_real_mesh_cache[k] = false
		return null
	var m: Mesh = found.mesh
	inst.queue_free()
	_real_mesh_cache[k] = m
	return m

static func _find_mesh_recursive(root_node: Node) -> MeshInstance3D:
	if root_node is MeshInstance3D:
		return root_node as MeshInstance3D
	for c in root_node.get_children():
		var f := _find_mesh_recursive(c)
		if f != null:
			return f
	return null

static func _get_mesh(k: Kind) -> Mesh:
	if _mesh_cache.has(k):
		return _mesh_cache[k]
	var m: Mesh
	match k:
		Kind.STAIR:
			# a shallow, wide wedge — climbable half-steps, not a steep ramp
			var p := PrismMesh.new()
			p.size = Vector3(FULL_SIZE * 0.97, FULL_SIZE * 0.5, FULL_SIZE * 0.97)
			m = p
		Kind.ROOF:
			# taller and a touch wider than the wall it caps, so it visibly
			# overhangs rather than sitting flush — a real roofline silhouette
			var p := PrismMesh.new()
			p.size = Vector3(FULL_SIZE * 1.15, FULL_SIZE * 1.2, FULL_SIZE * 0.97)
			m = p
		Kind.SMALL:
			var b := BoxMesh.new()
			b.size = Vector3(SMALL_SIZE, SMALL_SIZE, SMALL_SIZE) * 0.97
			m = b
		Kind.DOOR:
			# a narrow, tall slab — fills a gate opening instead of leaving it
			# an unguarded gap. Deliberately thin (0.2 deep) so it reads as a
			# hinged door, not another wall block wedged into the gateway.
			var b := BoxMesh.new()
			b.size = Vector3(FULL_SIZE * 0.7, FULL_SIZE * 1.4, 0.2)
			m = b
	_mesh_cache[k] = m
	return m

static func _get_mat(k: Kind) -> StandardMaterial3D:
	if _mat_cache.has(k):
		return _mat_cache[k]
	var mat := StandardMaterial3D.new()
	match k:
		Kind.STAIR: mat.albedo_color = Color(0.50, 0.36, 0.20)   # matches the wall it climbs
		Kind.ROOF:  mat.albedo_color = Color(0.28, 0.17, 0.10)   # dark thatch, distinct from the wall
		Kind.SMALL: mat.albedo_color = Color(0.45, 0.32, 0.18)   # same tone as block.gd's default
		Kind.DOOR:  mat.albedo_color = Color(0.34, 0.22, 0.11)   # weathered plank, darker than the wall
	_mat_cache[k] = mat
	return mat

static func _get_shape(k: Kind) -> Shape3D:
	var shape := BoxShape3D.new()
	match k:
		Kind.STAIR: shape.size = Vector3(FULL_SIZE, FULL_SIZE * 0.5, FULL_SIZE)
		Kind.ROOF:  shape.size = Vector3(FULL_SIZE * 1.15, FULL_SIZE * 1.2, FULL_SIZE)
		Kind.SMALL: shape.size = Vector3(SMALL_SIZE, SMALL_SIZE, SMALL_SIZE)
		Kind.DOOR:  shape.size = Vector3(FULL_SIZE * 0.7, FULL_SIZE * 1.4, 0.2)
	return shape

func take_damage(d: float, _attacker = null) -> void:
	hp -= d
	if hp <= 0:
		if owner_tribe != null and is_instance_valid(owner_tribe) and owner_tribe.has_method("on_block_lost"):
			owner_tribe.on_block_lost(self)
		queue_free()
