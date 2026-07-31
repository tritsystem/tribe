extends Node3D
class_name TreeField
# ─────────────────────────────────────────────────────────────────────────────
# TreeField — draws the ENTIRE forest in a handful of draw calls via one
# MultiMesh PER SPECIES.
#
# REAL ASSETS (2026-07-27): each of tree.gd's 5 species (Oak/Pine/Birch/
# Willow/Cedar -- previously a stats-only distinction, "a per-species tint
# would need real per-instance MultiMesh colour data, a separate rendering
# change" per tree.gd's own old comment) now draws its own real Kenney
# Nature Kit model (assets/nature/*.glb, downloaded CC0, not generated)
# instead of the one shared procedural cone+sphere mesh. Still THE draw-call
# fix: 5 MultiMeshInstance3D children (one per species) instead of 1700
# individual MeshInstance3Ds -- a handful of batched draws instead of
# thousands, same idea as before, just no longer forcing every tree to look
# identical.
#
# Falls back to the old procedural mesh (one more MultiMeshInstance3D, used
# for any tree whose species model failed to load, or an unrecognised
# species) so a missing/renamed asset degrades gracefully instead of hiding
# trees.
#
# Stays in sync with the gameplay trees the SIMPLE, robust way: whenever a
# tree spawns or is chopped, it calls mark_dirty(); this node then rebuilds
# every species' instance buffer from the current live "tree" group on the
# next throttled tick.
# ─────────────────────────────────────────────────────────────────────────────

var _dirty: bool = true
var _accum: float = 0.0
const REBUILD_INTERVAL := 0.2   # coalesce a whole spawn burst / rapid chops into one rebuild

# path + extra uniform scale (each real model measured at a different native
# height; this rescales it onto tree.gd's CANON_H so the existing per-tree
# render_basis height-variety math -- (h / CANON_H) * s -- keeps working
# completely unchanged; see tree.gd).
const SPECIES_MODELS := {
	"Oak":    {"path": "res://assets/nature/tree_oak.glb",       "scale": 3.670},
	"Pine":   {"path": "res://assets/nature/tree_pineTallA.glb", "scale": 2.942},
	"Birch":  {"path": "res://assets/nature/tree_thin.glb",      "scale": 3.020},
	"Willow": {"path": "res://assets/nature/tree_detailed.glb",  "scale": 3.377},
	"Cedar":  {"path": "res://assets/nature/tree_tall.glb",      "scale": 2.666},
}

var _species_mm: Dictionary = {}         # species name -> {"node": MultiMeshInstance3D, "scale": float}
var _fallback_mm: MultiMeshInstance3D = null

const FIELD_AABB := AABB(Vector3(-4000, -1000, -4000), Vector3(8000, 2000, 8000))

func _ready() -> void:
	add_to_group("tree_field")
	for sp in SPECIES_MODELS.keys():
		var info: Dictionary = SPECIES_MODELS[sp]
		var mmi := _build_species_multimesh(str(info["path"]))
		if mmi != null:
			add_child(mmi)
			_species_mm[sp] = {"node": mmi, "scale": float(info["scale"])}

	# fallback: the original procedural mesh, for any species whose real
	# model didn't load (or an unrecognised species string)
	_fallback_mm = MultiMeshInstance3D.new()
	var fmm := MultiMesh.new()
	fmm.transform_format = MultiMesh.TRANSFORM_3D
	fmm.use_colors = false
	fmm.mesh = TreeProp.build_shared_mesh()
	fmm.instance_count = 0
	_fallback_mm.multimesh = fmm
	_fallback_mm.custom_aabb = FIELD_AABB
	add_child(_fallback_mm)

	_dirty = true

func _build_species_multimesh(glb_path: String) -> MultiMeshInstance3D:
	if not ResourceLoader.exists(glb_path):
		return null
	var packed: PackedScene = load(glb_path)
	var inst := packed.instantiate()
	var mesh_node := _find_mesh(inst)
	if mesh_node == null:
		inst.queue_free()
		return null
	var mmi := MultiMeshInstance3D.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = false
	mm.mesh = mesh_node.mesh
	mm.instance_count = 0
	mmi.multimesh = mm
	mmi.custom_aabb = FIELD_AABB
	inst.queue_free()
	return mmi

func _find_mesh(root_node: Node) -> MeshInstance3D:
	if root_node is MeshInstance3D:
		return root_node as MeshInstance3D
	for c in root_node.get_children():
		var f := _find_mesh(c)
		if f != null:
			return f
	return null

func mark_dirty() -> void:
	_dirty = true

# DRIFT RE-BAKE (2026-07-27): "the trees aren't stuck to the islands" -- a
# turtle-owned tree.gd node IS correctly parented onto its island (see
# world_tribe.gd's _spawn_resource_grove()/_tick_local_resources()) and its
# real global_position silently tracks the drift for free, same as any other
# child node. But this field only ever baked that position into the
# MultiMesh's instance transform on mark_dirty() (spawn or chop) -- nothing
# ever re-baked it just because a tree's parent island kept moving in
# between those events, so the RENDERED mesh froze at spawn position while
# the actual (invisible) logic node kept drifting along underneath it. Only
# worth the periodic cost in turtle_islands mode, where trees can actually
# move after spawning at all.
var _drift_recheck_accum: float = 0.0
const DRIFT_RECHECK_INTERVAL := 0.5

func _process(delta: float) -> void:
	_drift_recheck_accum -= delta
	if _drift_recheck_accum <= 0.0:
		_drift_recheck_accum = DRIFT_RECHECK_INTERVAL
		if _turtle_islands_active():
			_dirty = true
	if not _dirty:
		return
	_accum -= delta
	if _accum > 0.0:
		return
	_accum = REBUILD_INTERVAL
	_dirty = false
	_rebuild()

func _turtle_islands_active() -> bool:
	var mgr = get_tree().get_first_node_in_group("tribe_manager")
	return mgr != null and bool(mgr.get("turtle_islands"))

# Rebuild every species' instance buffer from the current live trees. Skips
# nodes queued for deletion, so a just-chopped tree (queue_free()d, still
# briefly in the group this frame) is correctly dropped.
func _rebuild() -> void:
	var buckets: Dictionary = {}   # species (or "_fallback") -> Array[Node3D]
	for t in get_tree().get_nodes_in_group("tree"):
		var n := t as Node3D
		if n == null or not is_instance_valid(n):
			continue
		if n.is_queued_for_deletion():
			continue
		if not ("render_basis" in n):
			continue
		var sp: String = str(n.get("species")) if "species" in n else ""
		var key: String = sp if _species_mm.has(sp) else "_fallback"
		if not buckets.has(key):
			buckets[key] = []
		(buckets[key] as Array).append(n)

	for sp in _species_mm.keys():
		var entry: Dictionary = _species_mm[sp]
		var mmi: MultiMeshInstance3D = entry["node"]
		var extra_scale: float = entry["scale"]
		var list: Array = buckets.get(sp, [])
		var mm := mmi.multimesh
		mm.instance_count = list.size()
		for i in range(list.size()):
			var n: Node3D = list[i]
			var b: Basis = n.render_basis.scaled(Vector3(extra_scale, extra_scale, extra_scale))
			mm.set_instance_transform(i, Transform3D(b, n.global_position))

	var fb_list: Array = buckets.get("_fallback", [])
	var fmm := _fallback_mm.multimesh
	fmm.instance_count = fb_list.size()
	for i in range(fb_list.size()):
		var n: Node3D = fb_list[i]
		var b: Basis = n.render_basis
		fmm.set_instance_transform(i, Transform3D(b, n.global_position))

# Diagnostics: how many instances the forest is currently drawing (== live trees).
func drawn_count() -> int:
	var total := 0
	for sp in _species_mm.keys():
		total += (_species_mm[sp]["node"] as MultiMeshInstance3D).multimesh.instance_count
	if _fallback_mm != null:
		total += _fallback_mm.multimesh.instance_count
	return total
