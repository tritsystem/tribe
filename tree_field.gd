extends MultiMeshInstance3D
class_name TreeField
# ─────────────────────────────────────────────────────────────────────────────
# TreeField — draws the ENTIRE forest in ~1 draw call via a single MultiMesh.
#
# THE DRAW-CALL FIX. Every tree used to be its own MeshInstance3D = one CPU-side
# draw call submitted every frame; at Epic scale that's thousands. Now each tree
# (tree.gd, group "tree") renders nothing, and this one MultiMeshInstance3D holds
# an instance per live tree — the whole woods becomes a single batched submission.
#
# It stays in sync with the gameplay trees the SIMPLE, robust way: whenever a tree
# spawns or is chopped, it calls mark_dirty(); this node then rebuilds the instance
# buffer from the current live "tree" group on the next throttled tick. Chops are
# infrequent and a rebuild over a few thousand nodes is sub-millisecond, so the
# simplest-correct approach (rebuild-from-truth) is used over fiddly swap-remove
# bookkeeping — there is no index to get wrong, so chopping can't desync.
# ─────────────────────────────────────────────────────────────────────────────

var _dirty: bool = true
var _accum: float = 0.0
const REBUILD_INTERVAL := 0.2   # coalesce a whole spawn burst / rapid chops into one rebuild

func _ready() -> void:
	add_to_group("tree_field")
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = false          # colours are baked into the shared mesh's vertices
	mm.use_custom_data = false
	mm.mesh = TreeProp.build_shared_mesh()
	mm.instance_count = 0
	multimesh = mm

	# The forest is drawn in one call regardless of distance — far cheaper than the
	# old per-node distance cull (which is now removed). A large custom AABB keeps
	# the whole field from being wrongly frustum-culled when the origin/mesh-space
	# bounds fall off-screen (MultiMesh instance transforms don't grow the render
	# AABB reliably); size it well past any map extent.
	custom_aabb = AABB(Vector3(-4000, -1000, -4000), Vector3(8000, 2000, 8000))
	_dirty = true

func mark_dirty() -> void:
	_dirty = true

func _process(delta: float) -> void:
	if not _dirty:
		return
	_accum -= delta
	if _accum > 0.0:
		return
	_accum = REBUILD_INTERVAL
	_dirty = false
	_rebuild()

# Rebuild the instance buffer from the current live trees. Skips nodes queued for
# deletion, so a just-chopped tree (queue_free()d, still briefly in the group this
# frame) is correctly dropped.
func _rebuild() -> void:
	var live: Array = []
	for t in get_tree().get_nodes_in_group("tree"):
		var n := t as Node3D
		if n == null or not is_instance_valid(n):
			continue
		if n.is_queued_for_deletion():
			continue
		if not ("render_basis" in n):
			continue
		live.append(n)

	var mm := multimesh
	mm.instance_count = live.size()
	for i in range(live.size()):
		var n: Node3D = live[i]
		var b: Basis = n.render_basis
		mm.set_instance_transform(i, Transform3D(b, n.global_position))

# Diagnostics: how many instances the forest is currently drawing (== live trees).
func drawn_count() -> int:
	if multimesh == null:
		return 0
	return multimesh.instance_count
