extends StaticBody3D
# ─────────────────────────────────────────────────────────────────────────────
# Block — a single placeable wood cube, the building unit for player- and
# NPC-built fortresses (think Minecraft): walls, mazes, towers are all just
# many of these placed on a fixed grid (SIZE units) so they actually align
# and stack cleanly. Builders (player or any NPC with the walk-to-and-place
# pattern in tribemember.gd/world_tribe.gd) must be standing right next to
# the target cell to place one — see BUILD_RANGE in whichever script is
# doing the placing. Destroyable like any other built structure.
# In group "block".
# ─────────────────────────────────────────────────────────────────────────────

const SIZE := 2.0

var hp: float = 16.0
var owner_tribe = null   # set when a rival WorldTribe places this (cleanup bookkeeping)
var color: Color = Color(0.45, 0.32, 0.18)

# one material and one mesh shared by every block in the game, rather than
# each instance allocating its own — a castle wall is 30-60+ of these, and
# at 1000 tribes a NEAR/MID cluster can mean hundreds live at once. Unique
# materials per-instance kill batching and pile up GPU resources fast; this
# was a real contributor to both the low framerate and the earlier Vulkan
# "uniforms never supplied" error during heavy spawn bursts.
static var _shared_mesh: BoxMesh = null
static var _shared_mat: StandardMaterial3D = null

func _ready() -> void:
	add_to_group("block")
	_build()

func _build() -> void:
	if _shared_mesh == null:
		_shared_mesh = BoxMesh.new()
		_shared_mesh.size = Vector3(SIZE, SIZE, SIZE) * 0.97   # tiny gap so adjoining faces don't z-fight
	if _shared_mat == null:
		_shared_mat = StandardMaterial3D.new()
		_shared_mat.albedo_color = color
	var mesh := MeshInstance3D.new()
	mesh.mesh = _shared_mesh
	mesh.material_override = _shared_mat
	add_child(mesh)

	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(SIZE, SIZE, SIZE)
	col.shape = shape
	add_child(col)

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
