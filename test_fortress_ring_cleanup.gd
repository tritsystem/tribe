extends Node
# Headless test for the fortress-ring accumulation perf bug fix. Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path . res://test_fortress_ring_cleanup.tscn --quit
#
# BUG: each fortress tier ADDED a whole new, bigger ring on top of the
# previous one -- the old ring was never removed. A tribe that reached
# MAX_FORTRESS_TIER (4) accumulated four overlapping rings' worth of real
# StaticBody3D+collision nodes (roughly 128+178+196+240 = 742 for this
# tribe alone). That's a real, measured contributor to reported
# "game crashed, its super laggy" once expansion had run a few cycles.
# Fixed: fence_ring_plan() now clears the previous tier's tracked pieces
# the moment a NEW tier's plan is actually requested, so at most one ring's
# worth of real nodes exists at a time.

const TribeManagerScript = preload("res://Tribemanager.gd")

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  FORTRESS RING CLEANUP -- no cross-tier accumulation")
	print("=".repeat(60))

	var mgr := TribeManagerScript.new()
	add_child(mgr)
	mgr._cat_lines = {"you": [], "tribe": [], "tribes": []}
	mgr.wood = 100000

	# scenario A: requesting tier 0's plan tracks nothing yet to clear
	_check("no fortress pieces are tracked before any ring has been built",
		mgr._fortress_pieces.is_empty())

	# scenario B: actually PLACE tier 0's ring (a handful of real pieces),
	# confirm they're tracked, then request tier 1's plan -- the tier-0
	# pieces must be freed, not left standing underneath tier 1's.
	var plan0: Array = mgr.fence_ring_plan(0)
	var placed0: Array = []
	for seg in plan0.slice(0, 6):   # a representative sample is enough
		var pos: Vector3 = seg["pos"]
		var kind: String = seg.get("kind", "block")
		var ok := false
		match kind:
			"block": ok = mgr.try_build_block(pos)
			"fence": ok = mgr.try_build_fence(pos, float(seg.get("yaw", 0.0)))
			"teepee": ok = mgr.try_build_teepee(pos)
			"stair": ok = mgr.try_build_stair(pos, float(seg.get("yaw", 0.0)))
			"roof": ok = mgr.try_build_roof(pos, float(seg.get("yaw", 0.0)))
			"door": ok = mgr.try_build_door(pos, float(seg.get("yaw", 0.0)))
			"small": ok = mgr.try_build_small(pos, float(seg.get("yaw", 0.0)))
		if ok:
			placed0.append(true)
	_check("tier 0 pieces were actually placed and tracked",
		not mgr._fortress_pieces.is_empty())
	var tier0_pieces: Array = mgr._fortress_pieces.duplicate()

	mgr.fence_ring_plan(1)   # requesting tier 1's plan should clear tier 0's pieces
	_check("requesting a NEW tier's plan clears the previous tier's tracked pieces",
		mgr._fortress_pieces.is_empty())
	var all_freed := true
	for n in tier0_pieces:
		if is_instance_valid(n) and not n.is_queued_for_deletion():
			all_freed = false
	_check("the previous tier's actual nodes are freed (queued for deletion), not left standing",
		all_freed)

	# scenario C: player-placed pieces (by_player=true, the FPSPlayer.gd path)
	# must NEVER be swept up by fortress-ring cleanup -- only the autonomous
	# ring-building path (by_player=false, tribemember.gd's _build_step) is
	# tracked at all.
	mgr.fence_ring_plan(2)   # settle onto tier 2 so the next check starts clean
	var before_count: int = mgr._fortress_pieces.size()
	_check("tier 2's plan starts with a clean tracked-pieces slate", before_count == 0)
	mgr.try_build_block(Vector3(999, 1.0, 999), true)   # by_player=true
	_check("a player-placed block is NOT tracked for fortress-ring cleanup",
		mgr._fortress_pieces.is_empty())

	mgr.free()

	print("\n" + "-".repeat(42))
	print("  %d passed, %d FAILED" % [_pass, _fail])
	print("-".repeat(42) + "\n")
	get_tree().quit(1 if _fail > 0 else 0)

func _check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  ok    %s" % label)
	else:
		_fail += 1
		print("  FAIL  %s" % label)
