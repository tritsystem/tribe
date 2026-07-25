extends StaticBody3D
class_name TreeProp
const SpatialGrid = preload("res://spatial_grid.gd")
# ─────────────────────────────────────────────────────────────────────────────
# Tree — a forest prop you can KNOCK DOWN for wood. In group "tree". No collision
# (walk-through woods); found + chopped by DISTANCE (see FPSPlayer / tribemember).
#
# DRAW-CALL FIX (MultiMesh): a tree USED to carry its own MeshInstance3D — one
# draw call per tree, thousands submitted from the CPU every frame at Epic scale.
# Now the tree node renders NOTHING. A single MultiMeshInstance3D (tree_field.gd)
# draws EVERY tree in ~1 draw call, reading each live tree's position + per-tree
# random basis (yaw + slight scale) from `render_basis`. This node is now just an
# invisible gameplay record: a position, hp/wood, and chop() — still in group
# "tree", still choppable exactly as before. When it's chopped it queue_free()s
# and asks the field to drop its instance, so the forest and the game stay in sync.
#
# The canonical tree MESH (trunk brown + leaf green baked into vertex colours, one
# shared material) is built ONCE by the static build_shared_mesh() below and shared
# by the MultiMesh — same merged, vertex-coloured look as before, per-tree variety
# now coming from the instance transform instead of per-tree geometry.
# ─────────────────────────────────────────────────────────────────────────────

var hp: int = 3
var wood: int = 3
var _fallen: bool = false

# The per-tree visual transform basis (random yaw + slight scale, plus a Y-scale
# that reproduces the old per-tree height variety). The field composes this with
# this node's live global_position to place its MultiMesh instance. Read by
# tree_field.gd; kept as a plain var so `"render_basis" in node` is true.
var render_basis: Basis = Basis()

# Canonical mesh dimensions the shared mesh is built at. Per-tree height variety
# is recreated by scaling the instance's Y by (this tree's height / CANON_H).
const CANON_H := 4.5
const CANON_LR := 2.0

# ONE material shared by all trees. Vertex colours carry trunk/leaf hue, so this
# never needs a per-instance variant. Static → built once, reused forever.
static var _tree_mat: StandardMaterial3D = null
static var _shared_mesh: ArrayMesh = null

static func _shared_mat() -> StandardMaterial3D:
	if _tree_mat == null:
		var m := StandardMaterial3D.new()
		m.vertex_color_use_as_albedo = true
		m.roughness = 1.0
		m.metallic = 0.0
		_tree_mat = m
	return _tree_mat

# The ONE canonical tree mesh, shared by the MultiMesh across every tree. Trunk
# (brown) + leaves (green) baked into vertex colours on a single surface with the
# single shared material — identical merged look to the old per-tree mesh.
static func build_shared_mesh() -> ArrayMesh:
	if _shared_mesh != null:
		return _shared_mesh

	var h := CANON_H
	var lr := CANON_LR
	var trunk_col := Color(0.34, 0.24, 0.15)
	var leaf_col := Color(0.22, 0.46, 0.19)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# trunk: cylinder, centred at h*0.5
	var tm := CylinderMesh.new()
	tm.top_radius = 0.22
	tm.bottom_radius = 0.34
	tm.height = h
	tm.radial_segments = 6      # low-poly: a distant trunk needs no more
	_append_mesh(st, tm, Transform3D(Basis(), Vector3(0, h * 0.5, 0)), trunk_col)

	# leaves: sphere, seated above the trunk
	var lm := SphereMesh.new()
	lm.radius = lr
	lm.height = lr * 2.0
	lm.radial_segments = 8
	lm.rings = 5
	_append_mesh(st, lm, Transform3D(Basis(), Vector3(0, h + lr * 0.35, 0)), leaf_col)

	st.generate_normals()
	st.set_material(_shared_mat())
	_shared_mesh = st.commit()
	return _shared_mesh

# Append every triangle of `src` (a PrimitiveMesh) into `st`, transformed and
# flat-coloured — an un-indexed triangle soup with a per-vertex colour so the
# whole tree is one surface. Static so both the mesh builder and any caller share it.
static func _append_mesh(st: SurfaceTool, src: Mesh, xf: Transform3D, col: Color) -> void:
	var arrays: Array = src.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var basis := xf.basis
	if indices.size() > 0:
		for idx in indices:
			var n: Vector3 = basis * normals[idx]
			st.set_color(col)
			st.set_normal(n)
			st.add_vertex(xf * verts[idx])
	else:
		for i in range(verts.size()):
			var n2: Vector3 = basis * normals[i]
			st.set_color(col)
			st.set_normal(n2)
			st.add_vertex(xf * verts[i])

## DIVERSITY PASS (2026-07-19): "10x the diversity of wood" -- functional
## variety (yield/hardness) rather than new geometry, since the canonical
## mesh is shared vertex-colour geometry drawn in one MultiMesh draw call
## (see the file header) -- a per-species tint would need real per-instance
## MultiMesh colour data, a separate rendering change from this pass.
const SPECIES := {
	"Oak":    {"wood_mult": 1.3, "hardness": 1.2},
	"Pine":   {"wood_mult": 1.0, "hardness": 0.9},
	"Birch":  {"wood_mult": 0.8, "hardness": 0.7},
	"Willow": {"wood_mult": 0.7, "hardness": 0.6},
	"Cedar":  {"wood_mult": 1.1, "hardness": 1.0},
}
@export var species: String = "Pine"

func _ready() -> void:
	add_to_group("tree")
	var stats: Dictionary = SPECIES.get(species, SPECIES["Pine"])
	var h := randf_range(3.0, 6.5)
	hp = maxi(1, int((2 + int(h / 2.0)) * float(stats["hardness"])))
	wood = maxi(1, int((2 + int(h / 1.8)) * float(stats["wood_mult"])))

	# per-tree visual variety, applied as the MultiMesh instance basis: a random
	# yaw so the forest isn't clones, a slight uniform scale, and a Y-scale that
	# reproduces the old per-tree height spread from the ONE canonical mesh.
	var yaw := randf() * TAU
	var s := randf_range(0.85, 1.15)
	var ys := (h / CANON_H) * s
	render_basis = Basis(Vector3.UP, yaw).scaled(Vector3(s, ys, s))

	# NO MeshInstance3D, NO collision. The field draws this tree; the woods stay
	# walk-through. Ask the field to (re)build so this new tree shows up. Position
	# is usually set by the spawner AFTER _ready, so the field reads global_position
	# live at rebuild time (throttled/deferred), by which point it's correct.
	_mark_field_dirty()
	# PERF FIX (2026-07-19): _nearest_tree() (tribemember.gd) used to scan
	# get_tree().get_nodes_in_group("tree") in full every single call -- the
	# comments right there already flagged tree_count reaching the THOUSANDS
	# on a big world as a real cost. Registering with SpatialGrid lets that
	# search walk only the handful of nearby cells instead. Deferred for the
	# same reason _mark_field_dirty() reads global_position live rather than
	# now -- the spawner sets our real position AFTER _ready, in this same frame.
	call_deferred("_register_with_grid")

func _register_with_grid() -> void:
	SpatialGrid.update(self)

func _mark_field_dirty() -> void:
	var field := get_tree().get_first_node_in_group("tree_field")
	if field != null and field.has_method("mark_dirty"):
		field.mark_dirty()

# returns wood gained if the tree falls this hit, else 0
func chop(dmg: int = 1) -> int:
	if _fallen:
		return 0
	hp -= dmg
	if hp <= 0:
		_fallen = true
		var w := wood
		SpatialGrid.remove(self)
		queue_free()
		# drop this tree's instance from the forest MultiMesh. The field skips
		# queued-for-deletion nodes on rebuild, so this reliably removes the right one.
		_mark_field_dirty()
		return w
	# shudder on impact — tilt this tree's instance a touch, then redraw
	render_basis = render_basis.rotated(Vector3.FORWARD, randf_range(-0.06, 0.06))
	_mark_field_dirty()
	return 0
