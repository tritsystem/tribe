extends StaticBody3D
# ─────────────────────────────────────────────────────────────────────────────
# Block — a single placeable wall cube, the building unit for player- and
# NPC-built fortresses (think Minecraft): walls, mazes, towers are all just
# many of these placed on a fixed grid (SIZE units) so they actually align
# and stack cleanly. Builders (player or any NPC with the walk-to-and-place
# pattern in tribemember.gd/world_tribe.gd) must be standing right next to
# the target cell to place one — see BUILD_RANGE in whichever script is
# doing the placing. Destroyable like any other built structure.
# In group "block".
#
# MATERIAL TIERS (2026-07-22): a block now carries a `material_tier` (0 Wood,
# 1 Stone, 2 Metal) set by whoever places it (see Tribemanager.try_build_block
# / material_tier) -- a real "upgrade to better material" as the tribe's
# stockpile of raw materials grows, not just a repaint. Each tier gets its
# own HP (a stone wall genuinely outlasts a wooden one) and colour.
#
# BUG FIX: the OLD version had a single `color` instance var that was never
# actually used past the very FIRST block ever built -- `_shared_mat` was
# built once, lazily, from whichever instance happened to construct it
# first, and every block after that reused that one material regardless of
# its own `color`. That's why every block in the game always looked
# identical no matter what callers set. Fixed by caching material PER TIER
# (a small, fixed-size Dictionary keyed by material_tier) instead of a
# single lazily-built shared material -- still one shared instance per tier
# (same batching/perf win the old code was going for), just correctly keyed
# this time. The mesh geometry itself doesn't change between tiers (a block
# is a block regardless of material), so it stays a single shared BoxMesh.
# ─────────────────────────────────────────────────────────────────────────────

const SIZE := 2.0

const TIER_NAMES  := ["Wood", "Stone", "Metal"]
const TIER_HP     := [16.0, 32.0, 56.0]
const TIER_COLORS := [Color(0.45, 0.32, 0.18), Color(0.55, 0.55, 0.58), Color(0.74, 0.76, 0.80)]

## REAL ASSETS (2026-07-27): Kenney Survival Kit's structure.glb (Wood) and
## structure-metal.glb (Metal) -- CC0, downloaded not generated. No Stone
## equivalent exists in this kit, so tier 1 stays the flat-colored primitive
## (same "some tiers stay primitive when nothing fits" call already made for
## the Bow weapon tier). Both real pieces measure almost exactly a unit cube
## already (Kenney's modular-building convention), scaled here to fill
## block.gd's own SIZE*0.97 seam-gap grid exactly -- MUST stay grid-accurate
## since blocks tile edge-to-edge for wall/fortress building; a mismatched
## scale would show gaps or overlaps other tiers don't have.
const TIER_REAL_GLB := {
	0: "res://assets/survival/structure.glb",
	2: "res://assets/survival/structure-metal.glb",
}
# measured local AABB size per real piece (X/Z, Y) -- see TIER_REAL_GLB's own
# comment for why these must stay accurate to the grid.
const TIER_REAL_MEASURED := {
	0: Vector2(0.5, 0.5),
	2: Vector2(0.53543, 0.5),
}

var material_tier: int = 0
var hp: float = 16.0
var owner_tribe = null   # set when a rival WorldTribe places this (cleanup bookkeeping)

# one shared mesh for every block regardless of tier — a castle wall is
# 30-60+ of these, and at 1000 tribes a NEAR/MID cluster can mean hundreds
# live at once. Unique meshes per-instance kill batching and pile up GPU
# resources fast; this was a real contributor to both the low framerate and
# the earlier Vulkan "uniforms never supplied" error during heavy spawn
# bursts. Real-asset tiers keep the same "one shared Mesh resource reused
# across every instance" property -- only material_tier 1 (Stone, no real
# asset) still needs the procedural BoxMesh.
static var _shared_mesh: BoxMesh = null
static var _mat_cache: Dictionary = {}   # material_tier -> StandardMaterial3D
static var _real_mesh_cache: Dictionary = {}   # material_tier -> Mesh, or `false` if tried and unavailable

func _ready() -> void:
	add_to_group("block")
	# STRUCTURE COLLISION LAYER (bit 4). Walls used to sit on the default layer 1,
	# so tribe members physically JAMMED on their own walls with no pathfinding to
	# route around them -- and the stuck-recovery bashed the wall to escape,
	# wrecking the fortress. Now walls are on layer 4: the PLAYER masks it (walls
	# still block you -- siege feel + your own gated camp), but AI characters
	# (mask 1) phase through, so members/raiders never wedge on a wall. Walls are
	# still real nodes found by group+distance for attacks/conquest (HP-gated),
	# just not a physical trap for the AI.
	collision_layer = 8
	var t: int = clampi(material_tier, 0, TIER_HP.size() - 1)
	hp = TIER_HP[t]
	_build(t)

func _build(t: int) -> void:
	var mesh := MeshInstance3D.new()
	var real_mesh: Mesh = _get_real_mesh(t)
	if real_mesh != null:
		mesh.mesh = real_mesh
		var measured: Vector2 = TIER_REAL_MEASURED.get(t, Vector2(0.5, 0.5))
		var target: float = SIZE * 0.97
		mesh.scale = Vector3(target / measured.x, target / measured.y, target / measured.x)
		# no material_override -- textured, and tinting would wipe the
		# distinct wood-grain/metal-panel look that's the whole point of
		# using a real per-tier asset instead of a single recolored box.
	else:
		if _shared_mesh == null:
			_shared_mesh = BoxMesh.new()
			_shared_mesh.size = Vector3(SIZE, SIZE, SIZE) * 0.97   # tiny gap so adjoining faces don't z-fight
		mesh.mesh = _shared_mesh
		mesh.material_override = _get_mat(t)
	add_child(mesh)

	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(SIZE, SIZE, SIZE)
	col.shape = shape
	add_child(col)

static func _get_real_mesh(t: int) -> Mesh:
	if _real_mesh_cache.has(t):
		var cached = _real_mesh_cache[t]
		return cached if cached is Mesh else null
	var path: String = str(TIER_REAL_GLB.get(t, ""))
	if path == "" or not ResourceLoader.exists(path):
		_real_mesh_cache[t] = false
		return null
	var packed: PackedScene = load(path)
	var inst := packed.instantiate()
	var found := _find_mesh_recursive(inst)
	if found == null:
		inst.queue_free()
		_real_mesh_cache[t] = false
		return null
	var m: Mesh = found.mesh
	inst.queue_free()
	_real_mesh_cache[t] = m
	return m

static func _find_mesh_recursive(root_node: Node) -> MeshInstance3D:
	if root_node is MeshInstance3D:
		return root_node as MeshInstance3D
	for c in root_node.get_children():
		var f := _find_mesh_recursive(c)
		if f != null:
			return f
	return null

static func _get_mat(t: int) -> StandardMaterial3D:
	if _mat_cache.has(t):
		return _mat_cache[t]
	var mat := StandardMaterial3D.new()
	mat.albedo_color = TIER_COLORS[clampi(t, 0, TIER_COLORS.size() - 1)]
	_mat_cache[t] = mat
	return mat

func take_damage(d: float, _attacker = null) -> void:
	hp -= d
	if hp <= 0:
		if owner_tribe != null and is_instance_valid(owner_tribe) and owner_tribe.has_method("on_block_lost"):
			owner_tribe.on_block_lost(self)
		queue_free()

# snap any world position onto the block grid — every builder (player, your
# tribe, rival tribes) uses this so structures from different builders still
# line up into one consistent grid instead of overlapping/gapping randomly.
# Y is passed through UNCHANGED, not snapped: callers already compute the
# correct center height themselves (1.0 for a block resting on a y=0 floor,
# 3.0 for the course stacked on top of it, etc — always an odd multiple of
# SIZE/2, never a multiple of SIZE). Rounding Y the same way as X/Z would
# snap a ground-level block's center from 1.0 up to the nearest multiple of
# 2.0 — i.e. to 2.0 — floating every single block a full unit off the
# ground. That was exactly the "blocks floating" bug.
static func snap(pos: Vector3) -> Vector3:
	return Vector3(
		round(pos.x / SIZE) * SIZE,
		pos.y,
		round(pos.z / SIZE) * SIZE)
