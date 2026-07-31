extends StaticBody3D
# ─────────────────────────────────────────────────────────────────────────────
# mineral.gd — a biome-specific resource quarried from high ground.
# In group "mineral". Type (and colour, and value) is set by the biome it spawns
# in: highland -> Stone, mountain -> Ore or Gems. This is the first resource that
# only exists BECAUSE of the terrain -- you have to go up into the hills for it.
#
# Harvested by proximity: walk up to it and it's collected into the tribe's
# materials over a moment, then the node is spent. Kept deliberately simple (no
# tool required, no mining minigame) so it reads clearly the first time.
# ─────────────────────────────────────────────────────────────────────────────

const SpatialGrid = preload("res://spatial_grid.gd")

@export var mat_type: String = "Stone"
@export var amount: int = 3
var _collect_range := 2.4
var _player: Node3D = null
var _cd := 0.0

## DIVERSITY PASS (2026-07-19): "10x the diversity of ore/glass" -- Stone/
## Ore/Gems were really only 2 real gameplay materials (Ore and Gems both
## just fed the same generic `materials` pool). Real, distinct mat_types now,
## each with its own look here and its own weighted spawn chance in
## Tribemanager._spawn_minerals() below -- Sand specifically exists to feed
## Glassblowing (see tribemember.gd's PROFESSIONS list).
const COLORS := {
	"Stone":    Color(0.55, 0.55, 0.58),
	"Ore":      Color(0.45, 0.35, 0.28),
	"Gems":     Color(0.35, 0.75, 0.85),
	"Copper":   Color(0.72, 0.45, 0.20),
	"Iron":     Color(0.50, 0.48, 0.46),
	"Silver":   Color(0.78, 0.78, 0.80),
	"Gold":     Color(0.85, 0.70, 0.20),
	"Coal":     Color(0.12, 0.12, 0.12),
	"Clay":     Color(0.62, 0.38, 0.28),
	"Sand":     Color(0.86, 0.78, 0.55),
	"Obsidian": Color(0.08, 0.08, 0.12),
}

func _ready() -> void:
	add_to_group("mineral")
	# AWARENESS FIX (2026-07-19): "make sure npcs can see and hear all new
	# objects where it applies" -- minerals were ONLY ever collected by the
	# player's own proximity check below; a tribemember's _nearest_*() family
	# had no way to see them at all (no SpatialGrid registration, no picker).
	# Registering here is what tribemember.gd's new _nearest_mineral() reads.
	call_deferred("_register_with_grid")
	# gems are small and precious, ore chunky, stone broad
	var s := 0.7 if mat_type == "Gems" else (1.1 if mat_type == "Ore" else 1.4)
	var _ore_col: Color = COLORS.get(mat_type, Color(0.6, 0.6, 0.6))
	var _ore_met: float = 0.6 if mat_type == "Ore" else (0.2 if mat_type == "Gems" else 0.0)
	var _ore_rough: float = 0.4 if mat_type == "Gems" else 0.9

	# REAL ASSET (2026-07-27): a real Kenney Nature Kit rock model (CC0,
	# downloaded not generated), still recolored per mat_type via
	# material_override -- same convention as before, just a real rock
	# silhouette under the tint instead of a bare cube. Falls back to the old
	# BoxMesh if the asset is ever missing.
	var mesh: MeshInstance3D = _try_real_rock_mesh()
	if mesh == null:
		mesh = MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(s, s * 0.8, s)
		mesh.mesh = bm
		mesh.position.y = s * 0.4
	else:
		mesh.scale = Vector3(s, s, s)
	mesh.material_override = MatCache.flat(_ore_col, _ore_rough, _ore_met)
	add_child(mesh)

	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(s, s * 0.8, s)
	col.shape = box
	col.position.y = s * 0.4
	add_child(col)
	set_process(true)

## One real rock model reused for every mineral type (recolored per-type
## above), scaled to this instance's size tier. Rock silhouette is generic
## enough that "Gems"/"Ore"/"Stone"/etc. read fine as the same rough shape in
## different materials -- matches how the old BoxMesh was also one shape,
## many colors.
const ROCK_GLB := "res://assets/nature/rock_largeA.glb"

func _try_real_rock_mesh() -> MeshInstance3D:
	if not ResourceLoader.exists(ROCK_GLB):
		return null
	var packed: PackedScene = load(ROCK_GLB)
	var inst := packed.instantiate()
	var found := _find_mesh(inst)
	if found == null:
		inst.queue_free()
		return null
	found.get_parent().remove_child(found)
	inst.queue_free()
	return found

func _find_mesh(root_node: Node) -> MeshInstance3D:
	if root_node is MeshInstance3D:
		return root_node as MeshInstance3D
	for c in root_node.get_children():
		var f := _find_mesh(c)
		if f != null:
			return f
	return null

func _process(delta: float) -> void:
	_cd -= delta
	if _cd > 0.0:
		return
	_cd = 0.4          # cheap: only a distance check a couple times a second
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player") as Node3D
		if _player == null:
			return
	if global_position.distance_to(_player.global_position) <= _collect_range:
		_harvest()

func _harvest() -> void:
	var mgr = get_tree().get_first_node_in_group("tribe_manager")
	if mgr and mgr.has_method("add_special_material"):
		mgr.add_special_material(mat_type, amount)
	elif mgr and mgr.has_method("add_materials"):
		mgr.add_materials(amount)
	if mgr and mgr.has_method("notify"):
		mgr.notify("+%d %s" % [amount, mat_type])
	# INVENTORY (2026-07-19): the tribe's shared stock gets the bulk deposit
	# above; the player ALSO keeps a personal record of what they personally
	# dug up, same as an NPC's own inventory tracks what they personally made.
	if _player != null and is_instance_valid(_player) and _player.has_method("add_item"):
		_player.add_item(mat_type, amount)
	queue_free()

func _register_with_grid() -> void:
	SpatialGrid.update(self)

## Member-driven collection (tribemember.gd's "mine" job) -- distinct from
## the player's own proximity auto-harvest above: a member commits to the
## WHOLE node in one go (no partial harvest like a food_source bush) and the
## caller is responsible for crediting materials/practicing Mining, same
## division of responsibility _do_gather()/food_source.harvest() already use.
func collect() -> Dictionary:
	var out := {"type": mat_type, "amount": amount}
	SpatialGrid.remove(self)
	queue_free()
	return out
