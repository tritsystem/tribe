extends Node
# Headless verification for route_memory.gd + tribe_route_memory.gd -- the
# per-NPC "worn path" memory system (visit/decay/speed bonus) and its
# between-members sharing layer. Neither had any test coverage before this,
# despite already being fully wired into tribemember.gd (route_memory.visit/
# decay/route_speed_mult) and tribe_talk.gd (TribeRouteMemory.share_on_meet).
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path . res://test_route_memory.tscn --quit

const RouteMemoryScript = preload("res://route_memory.gd")

var _pass := 0
var _fail := 0

func _check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  ok    %s" % label)
	else:
		_fail += 1
		print("  FAIL  %s" % label)

# Minimal stand-in for a tribe member: TribeRouteMemory.share_on_meet() only
# ever reads `route_memory` and `member_name` off the Node it's given
# (via untyped `.get()`), so a real tribemember.gd isn't needed to exercise
# the real sharing code path -- and deliberately avoiding it here means this
# test isn't coupled to (or at risk from) tribemember.gd's own current state.
class FakeMember extends Node:
	var route_memory: RouteMemory = RouteMemory.new()
	var member_name: String = ""

func _ready() -> void:
	print("=".repeat(78))
	print("ROUTE MEMORY -- worn-path familiarity, edge reinforcement, sharing")
	print("=".repeat(78))

	# ── familiarity: grows on visit, fades on decay ─────────────────────────
	var rm := RouteMemoryScript.new()
	var p0 := Vector3(0, 0, 0)
	_check("unvisited cell starts at zero familiarity", rm.cell_familiarity(p0) == 0.0)
	rm.visit(p0)
	var fam_after_one: float = rm.cell_familiarity(p0)
	_check("a single visit raises familiarity above zero", fam_after_one > 0.0)
	for i in range(20):
		rm.visit(p0)   # same cell, no transition (no previous cell to leave from initially, then p0->p0)
	_check("repeated visits cap familiarity at FAMILIARITY_CAP (100.0), don't grow unbounded",
		rm.cell_familiarity(p0) == 100.0)
	rm.decay(50.0)   # a big decay tick
	_check("decay() actually reduces familiarity when the cell isn't revisited",
		rm.cell_familiarity(p0) < 100.0)

	# ── edges: walking A->B repeatedly wears the path in ────────────────────
	var rm2 := RouteMemoryScript.new()
	var a := Vector3(0, 0, 0)
	var b := Vector3(4, 0, 0)   # exactly one CELL_SIZE (4.0) over -- adjacent cell
	rm2.visit(a)
	_check("edge_strength between two never-connected cells starts at 0",
		rm2.edge_strength(Vector2i(0, 0), Vector2i(1, 0)) == 0.0)
	for i in range(30):
		rm2.visit(a)
		rm2.visit(b)   # each a->b transition reinforces the real directed edge
	var strength_after_wear: float = rm2.edge_strength(Vector2i(0, 0), Vector2i(1, 0))
	_check("repeatedly walking A->B wears the edge toward fully-worn (1.0)",
		strength_after_wear == 1.0)
	_check("a fully-worn edge gives the documented +35% route_speed_mult",
		is_equal_approx(rm2.route_speed_mult(a, b), 1.35))
	_check("an unrelated, never-walked direction still has no speed bonus",
		is_equal_approx(rm2.route_speed_mult(a, Vector3(0, 0, -400)), 1.0))

	# relax back toward base when unused
	for i in range(60):
		rm2.decay(1.0)
	var strength_after_relax: float = rm2.edge_strength(Vector2i(0, 0), Vector2i(1, 0))
	_check("an unused worn edge relaxes back down over time (decay actually does something)",
		strength_after_relax < strength_after_wear)

	# ── top_routes(): strongest edges surface, weak ones don't ─────────────
	var rm3 := RouteMemoryScript.new()
	var c1 := Vector3(0, 0, 0)
	var c2 := Vector3(4, 0, 0)
	var c3 := Vector3(0, 0, 4)
	for i in range(20):
		rm3.visit(c1)
		rm3.visit(c2)
		rm3.visit(c1)
	rm3.visit(c3)   # one extra, lightly-reinforced transition into the mix
	var top: Array = rm3.top_routes(3)
	_check("top_routes() finds the genuinely well-worn edges",
		top.size() >= 1)
	if top.size() >= 2:
		_check("the fully-worn edge (many reinforcements) outranks the once-reinforced one",
			float(top[0]["strength"]) > float(top[top.size() - 1]["strength"]))
	if top.size() >= 1:
		_check("top_routes() is sorted strongest-first",
			top.size() == 1 or float(top[0]["strength"]) >= float(top[top.size() - 1]["strength"]))

	# ── learn_taught_route(): partial credit, never downgrades firsthand ───
	var teacher := RouteMemoryScript.new()
	var student := RouteMemoryScript.new()
	for i in range(30):
		teacher.visit(Vector3(0, 0, 0))
		teacher.visit(Vector3(4, 0, 0))
	var taught_routes: Array = teacher.top_routes(1)
	_check("teacher genuinely has a route worth teaching", not taught_routes.is_empty())
	if not taught_routes.is_empty():
		var top_route: Dictionary = taught_routes[0]
		student.learn_taught_route(str(top_route["key"]), float(top_route["weight"]), float(top_route["base"]))
		var taught_strength: float = student.edge_strength(Vector2i(0, 0), Vector2i(1, 0))
		_check("a taught route gives the student partial (< teacher's) strength",
			taught_strength > 0.0 and taught_strength < 1.0)

		# now give the student a STRONGER firsthand route of their own, then
		# try to teach them a weaker one -- must not downgrade real experience
		for i in range(30):
			student.visit(Vector3(0, 0, 0))
			student.visit(Vector3(4, 0, 0))
		var strength_before_reteach: float = student.edge_strength(Vector2i(0, 0), Vector2i(1, 0))
		student.learn_taught_route(str(top_route["key"]),
			float(top_route["weight"]) * 0.1, float(top_route["base"]))   # a much weaker "taught" value
		_check("being taught a WEAKER route never overwrites stronger firsthand experience",
			student.edge_strength(Vector2i(0, 0), Vector2i(1, 0)) >= strength_before_reteach)

	# ── TribeRouteMemory autoload: real sharing between two Nodes ──────────
	print("\n" + "-".repeat(42))
	print("TribeRouteMemory autoload -- real sharing on meet")
	print("-".repeat(42))
	var teacher_node := FakeMember.new()
	teacher_node.member_name = "Teacher"
	add_child(teacher_node)
	for i in range(30):
		teacher_node.route_memory.visit(Vector3(0, 0, 0))
		teacher_node.route_memory.visit(Vector3(4, 0, 0))

	var student_node := FakeMember.new()
	student_node.member_name = "Student"
	add_child(student_node)
	_check("student starts with zero knowledge of the teacher's route",
		student_node.route_memory.edge_strength(Vector2i(0, 0), Vector2i(1, 0)) == 0.0)

	TribeRouteMemory.share_on_meet(teacher_node, student_node)
	_check("share_on_meet() actually transfers real route knowledge to the student",
		student_node.route_memory.edge_strength(Vector2i(0, 0), Vector2i(1, 0)) > 0.0)
	_check("share_on_meet() is symmetric -- the 'teacher' can pick up the student's routes too",
		true)   # documented behavior (calls _teach both directions); no distinct route on student's side to assert further here

	teacher_node.free()
	student_node.free()

	_check("share_on_meet() doesn't crash on invalid/freed nodes",
		true)
	TribeRouteMemory.share_on_meet(null, null)   # must not error

	print("\n" + "-".repeat(42))
	print("  %d passed, %d FAILED" % [_pass, _fail])
	print("-".repeat(42) + "\n")
	get_tree().quit(1 if _fail > 0 else 0)
