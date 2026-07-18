extends StaticBody3D
# ─────────────────────────────────────────────────────────────────────────────
# BuildPiece — the fine-grained construction family alongside block.gd's
# plain cube. Where block.gd is deliberately ONE shape (a wall cube, shared
# static mesh across every instance for perf), this script gives builders
# real DIFFERENT pieces to place: STAIR (a shallow wedge — climbable half
# steps up a wall or tower), ROOF (a steeper triangular-prism cap — actually
# reads as a roof from outside, not a flat block lid), and SMALL (a
# half-size cube for fine-tuning: corners, ledges, in-fill that shouldn't be
# forced onto the coarse 2.0-unit wall grid).
#
# SAME PERFORMANCE DISCIPLINE AS block.gd: a castle can mean hundreds of
# these live at once, so mesh/material are cached ONE PER KIND (a static
# Dictionary keyed by Kind), never allocated per-instance. That's what
# actually lets these look genuinely different from each other without
# paying block.gd's own reason for going shared-static in the first place.
#
# Godot 4's PrismMesh is the natural fit for both STAIR and ROOF: it's a
# real wedge/ridge primitive (a `left_to_right` taper on a box), not a
# hand-modelled shape — a stair is a prism laid low and wide, a roof is the
# same primitive stood taller and narrower so it reads as a ridge, not a
# ramp. Collision uses a plain bounding box for both (there is no native
# collision primitive matching a prism, and a slightly generous box is the
# same honest approximation block.gd already uses for its own cube).
# In group "build_piece".
# ─────────────────────────────────────────────────────────────────────────────

const FULL_SIZE := 2.0    # matches BlockScript.SIZE so pieces line up on the same grid
const SMALL_SIZE := 1.0   # the fine-detail unit — half a full block

enum Kind { STAIR, ROOF, SMALL }

var kind: Kind = Kind.STAIR
var hp: float = 16.0
var owner_tribe = null   # set when a rival WorldTribe places this (cleanup bookkeeping)

static var _mesh_cache: Dictionary = {}   # Kind -> Mesh
static var _mat_cache: Dictionary = {}    # Kind -> StandardMaterial3D

func _ready() -> void:
	add_to_group("build_piece")
	# same STRUCTURE collision layer as block.gd (bit 4): the player collides
	# with it, but AI characters (mask 1) phase through so members/raiders
	# never wedge on their own construction — see block.gd's own comment for
	# the full story of why walls moved off the default layer.
	collision_layer = 8
	_build()

func _build() -> void:
	var mesh := MeshInstance3D.new()
	mesh.mesh = _get_mesh(kind)
	mesh.material_override = _get_mat(kind)
	if kind == Kind.ROOF:
		mesh.rotation.x = PI   # point the ridge upward instead of down into the ground
	add_child(mesh)

	var col := CollisionShape3D.new()
	col.shape = _get_shape(kind)
	add_child(col)

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
	_mat_cache[k] = mat
	return mat

static func _get_shape(k: Kind) -> Shape3D:
	var shape := BoxShape3D.new()
	match k:
		Kind.STAIR: shape.size = Vector3(FULL_SIZE, FULL_SIZE * 0.5, FULL_SIZE)
		Kind.ROOF:  shape.size = Vector3(FULL_SIZE * 1.15, FULL_SIZE * 1.2, FULL_SIZE)
		Kind.SMALL: shape.size = Vector3(SMALL_SIZE, SMALL_SIZE, SMALL_SIZE)
	return shape

func take_damage(d: float, _attacker = null) -> void:
	hp -= d
	if hp <= 0:
		if owner_tribe != null and is_instance_valid(owner_tribe) and owner_tribe.has_method("on_block_lost"):
			owner_tribe.on_block_lost(self)
		queue_free()
