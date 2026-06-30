class_name SpatialGrid
extends RefCounted
# ─────────────────────────────────────────────────────────────────────────────
# SpatialGrid — a flat world-space hash so "who's near me" queries don't have
# to scan every node in a group. get_tree().get_nodes_in_group("npc") returns
# EVERY npc in the world, near or far — fine at a few hundred, but at 1000
# tribes (tens of thousands of members) every proximity check (intruder
# detection, skirmish targeting, outnumber counts, war-party targeting) was
# paying that full-list cost, regardless of the simulation LOD tier. This
# buckets entities into CELL-sized cells by their XZ position; a query only
# walks the handful of cells actually within range.
#
# GDScript static vars are shared across the whole class (Godot 4+), so this
# needs no autoload/singleton wiring — just call SpatialGrid.update(self) /
# SpatialGrid.remove(self) from the entities that want to be findable, and
# SpatialGrid.query(pos, radius, group) wherever a full-group scan used to be.
# ─────────────────────────────────────────────────────────────────────────────

const CELL := 12.0

static var _cells: Dictionary = {}        # Vector2i -> Array[Node3D]
static var _entity_cell: Dictionary = {}  # instance_id -> Vector2i

static func _key(pos: Vector3) -> Vector2i:
	return Vector2i(int(floor(pos.x / CELL)), int(floor(pos.z / CELL)))

# call periodically (a few times a second is plenty — CELL is coarse) as an
# entity moves. Cheap no-op if it hasn't crossed into a new cell.
static func update(entity: Node3D) -> void:
	if entity == null or not is_instance_valid(entity):
		return
	var id := entity.get_instance_id()
	var k := _key(entity.global_position)
	if _entity_cell.get(id) == k:
		return
	remove(entity)
	if not _cells.has(k):
		_cells[k] = []
	_cells[k].append(entity)
	_entity_cell[id] = k

# call when an entity dies/despawns, or it'll linger as a phantom query hit
static func remove(entity: Node3D) -> void:
	if entity == null:
		return
	var id := entity.get_instance_id()
	if not _entity_cell.has(id):
		return
	var old: Vector2i = _entity_cell[id]
	if _cells.has(old):
		_cells[old].erase(entity)
		if _cells[old].is_empty():
			_cells.erase(old)
	_entity_cell.erase(id)

# every registered entity within `radius` of pos, optionally filtered to one
# group (still cheaper than get_nodes_in_group + distance check, since only
# nearby cells are walked instead of every entity in the world)
static func query(pos: Vector3, radius: float, group: String = "") -> Array:
	var result: Array = []
	var span := int(ceil(radius / CELL))
	var center := _key(pos)
	for dx in range(-span, span + 1):
		for dz in range(-span, span + 1):
			var k := Vector2i(center.x + dx, center.y + dz)
			if _cells.has(k):
				for e in _cells[k]:
					if is_instance_valid(e) and (group == "" or e.is_in_group(group)):
						result.append(e)
	return result
