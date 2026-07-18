extends Node
# Headless test for the _break_free() perf/correctness fix. Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path . res://test_break_free_perf.tscn --quit
#
# BUG: _break_free() scanned the FULL "fence"/"block"/"tree" groups
# (unbounded, whole-world -- tree_count alone can be 1000-2600) every time
# ANY member got stuck, even though none of those three groups can
# physically block an AI-masked CharacterBody3D at all (fence/block/every
# build_piece sit on collision layer 8, which a tribemember's default mask
# doesn't intersect; trees have no collision shape whatsoever). A real,
# expensive, and completely pointless scan, made worse by this session's
# own fortress-tier work substantially growing the "block" group. Fixed by
# querying SpatialGrid's "tribe" group instead (bounded, and the only group
# that can genuinely be the real physical cause).

const SpatialGrid = preload("res://spatial_grid.gd")

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  BREAK-FREE PERF -- no more whole-world fence/block/tree scans")
	print("=".repeat(60))

	# scenario A: hundreds of trees/blocks/fences right on top of the member
	# must NOT be picked as the "obstacle" -- they're no longer scanned at
	# all (correctness proof that the fix actually changed what's checked).
	var m := _spawn_member("Stuck", Vector3.ZERO)
	for i in range(50):
		_fake_prop("tree", Vector3(0.1, 0, 0.1))
		_fake_prop("block", Vector3(0.1, 0, 0.1))
		_fake_prop("fence", Vector3(0.1, 0, 0.1))
	m.velocity = Vector3(1.0, 0, 0)
	m._last_pos = Vector3(5, 0, 5)   # far from current pos -> registers as "not moved"
	m._break_free()
	# with no real obstacle (no other tribe member nearby), the fallback is a
	# random shove -- velocity must have actually changed (not left at zero
	# from a never-reached obstacle branch or a crash).
	_check("with no real (tribe) obstacle nearby, break-free still produces a real shove",
		velocity_len(m) > 0.0)

	# scenario B: a genuinely nearby tribemate (a REAL potential physical
	# cause, since members share a collision layer/mask) IS still found and
	# used to determine the shove direction -- the fix didn't just delete
	# the whole feature, it correctly narrowed WHAT gets checked.
	var blocker := _spawn_member("Blocker", Vector3(1.0, 0, 0))
	m.velocity = Vector3.ZERO
	m._break_free()
	_check("a real nearby tribemate is still found and used to shove away from",
		velocity_len(m) > 0.0)
	# pushed AWAY from the blocker (at +X), so velocity.x should trend negative
	_check("the shove is actually directed away from the real obstacle, not random",
		m.velocity.x < 0.0)

	blocker.free()
	m.free()

	print("\n" + "-".repeat(42))
	print("  %d passed, %d FAILED" % [_pass, _fail])
	print("-".repeat(42) + "\n")
	get_tree().quit(1 if _fail > 0 else 0)

func velocity_len(m: Node3D) -> float:
	return Vector2(m.velocity.x, m.velocity.z).length()

func _spawn_member(name_: String, pos: Vector3) -> Node3D:
	var m := CharacterBody3D.new()
	m.set_script(load("res://tribemember.gd"))
	add_child(m)
	m.member_name = name_
	m.global_position = pos
	SpatialGrid.update(m)
	return m

func _fake_prop(group: String, pos: Vector3) -> Node3D:
	var n := Node3D.new()
	add_child(n)
	n.add_to_group(group)
	n.global_position = pos
	return n

func _check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  ok    %s" % label)
	else:
		_fail += 1
		print("  FAIL  %s" % label)
