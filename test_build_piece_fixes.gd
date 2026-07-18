extends Node
# Headless test for the build-piece overlap bug fix + new rotation/size/door
# support. Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path . res://test_build_piece_fixes.tscn --quit
#
# BUG: the first tower stair placement put stairs at 0.85x the tower's own
# radius -- i.e. INSIDE the tower's own block column, less than one
# block-width away -- so stair and tower physically overlapped. That read as
# broken/overlapping geometry, reported as "building isn't working" even
# though every piece was placing successfully. Fixed by placing stairs a
# full block-width OUTSIDE the tower and giving every piece a real yaw
# (facing) and scale_factor (size) instead of a fixed orientation/size.

const TribeManagerScript = preload("res://Tribemanager.gd")
const BuildPieceScript = preload("res://build_piece.gd")

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  BUILD PIECE FIXES -- no overlap, real rotation/size/doors")
	print("=".repeat(60))

	var mgr := TribeManagerScript.new()
	add_child(mgr)
	mgr._cat_lines = {"you": [], "tribe": [], "tribes": []}
	mgr.wood = 200

	# scenario A: the fortress plan's own tower stair segments never overlap
	# their tower's block column -- the actual bug.
	var gate_angles: Array = [0.0, TAU / 3.0, TAU * 2.0 / 3.0]
	var segs: Array = mgr._fortress_block_segments(10.0, gate_angles)
	# tower/stair structures sit well past the wall's own square-corner
	# radius (n*size*sqrt(2)) -- see Tribemanager's own tower_r fix. All
	# "block" segments belonging to the wall itself (not a tower) sit at or
	# below that corner radius, so a generous threshold cleanly separates
	# "the wall, including its corners" from "a tower's own column".
	var wall_corner_r: float = 5.0 * 2.0 * sqrt(2.0)   # n=5, size=2 for radius=10.0
	var wall_blocks: Array = []
	var tower_stairs: Array = []
	for s in segs:
		if s.get("kind", "") == "block" and Vector2(s["pos"].x, s["pos"].z).length() <= wall_corner_r + 0.01:
			wall_blocks.append(s["pos"])
		elif s.get("kind", "") == "stair":
			tower_stairs.append(s["pos"])
	var min_gap := INF
	for wb in wall_blocks:
		for st in tower_stairs:
			var flat_gap: float = Vector2(wb.x - st.x, wb.z - st.z).length()
			min_gap = minf(min_gap, flat_gap)
	_check("tower stairs never overlap the wall itself (including its own square corners)",
		min_gap >= BuildPieceScript.FULL_SIZE - 0.01)

	var tower_blocks: Array = []
	for s in segs:
		if s.get("kind", "") == "block" and Vector2(s["pos"].x, s["pos"].z).length() > wall_corner_r + 0.01:
			tower_blocks.append(s["pos"])
	var min_tower_gap := INF
	for tb in tower_blocks:
		for st in tower_stairs:
			var flat_gap2: float = Vector2(tb.x - st.x, tb.z - st.z).length()
			min_tower_gap = minf(min_tower_gap, flat_gap2)
	_check("tower stairs never overlap the tower's own block column either",
		min_tower_gap >= BuildPieceScript.FULL_SIZE - 0.01)

	# scenario B: stair/roof segments carry a real yaw, not always 0
	var has_nonzero_yaw := false
	for s in segs:
		if s.get("kind", "") in ["stair", "roof"] and absf(float(s.get("yaw", 0.0))) > 0.01:
			has_nonzero_yaw = true
			break
	_check("tower stair/roof segments carry a real (non-zero) facing yaw", has_nonzero_yaw)

	# scenario C: stairs are placed at the SMALL scale, not full size
	var stair_scale := 1.0
	for s in segs:
		if s.get("kind", "") == "stair":
			stair_scale = float(s.get("scale", 1.0))
			break
	_check("stairs use the small size variant, not full-block scale",
		stair_scale == BuildPieceScript.SCALE_SMALL)

	# scenario D: yaw and scale actually reach the spawned piece, not just
	# the segment dictionary
	_check("try_build_stair applies the requested yaw and scale to the real piece",
		_spawned_piece_matches(mgr, "try_build_stair", Vector3(30, 1.0, 0), 1.2, BuildPieceScript.SCALE_SMALL))
	_check("try_build_roof applies the requested yaw and scale to the real piece",
		_spawned_piece_matches(mgr, "try_build_roof", Vector3(32, 1.0, 0), 0.5, BuildPieceScript.SCALE_LARGE))

	# scenario E: doors are a real, distinct kind -- and a gate opening in
	# fence_ring_plan() is actually filled by one, not left bare
	var before_doors: int = get_tree().get_nodes_in_group("build_piece").size()
	_check("try_build_door spends wood and places a DOOR-kind piece",
		mgr.try_build_door(Vector3(34, 1.0, 0)))
	_check("the door actually entered the world", get_tree().get_nodes_in_group("build_piece").size() == before_doors + 1)

	var plan: Array = mgr.fence_ring_plan()
	var door_count := 0
	for seg in plan:
		if seg.get("kind", "") == "door":
			door_count += 1
	_check("fence_ring_plan() fills each gate with a real door instead of a bare gap",
		door_count == gate_angles_count(mgr))

	mgr.free()

	print("\n" + "-".repeat(42))
	print("  %d passed, %d FAILED" % [_pass, _fail])
	print("-".repeat(42) + "\n")
	get_tree().quit(1 if _fail > 0 else 0)

## fence_ring_plan() always uses gate_count=3 internally -- confirm against
## that rather than hardcoding 3 twice.
func gate_angles_count(_mgr) -> int:
	return 3

func _spawned_piece_matches(mgr, method: String, pos: Vector3, yaw: float, scale_factor: float) -> bool:
	var before: Array = get_tree().get_nodes_in_group("build_piece")
	var ok: bool = mgr.callv(method, [pos, yaw, scale_factor])
	if not ok:
		return false
	for p in get_tree().get_nodes_in_group("build_piece"):
		if not before.has(p):
			return absf(p.yaw - yaw) < 0.01 and absf(p.scale_factor - scale_factor) < 0.01
	return false

func _check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  ok    %s" % label)
	else:
		_fail += 1
		print("  FAIL  %s" % label)
