extends Node
# ─────────────────────────────────────────────────────────────────────────────
# TribeRouteMemory — spreads worn-path knowledge between tribe members who
# actually talk to each other. Autoload singleton: TribeRouteMemory
#
# Mirrors tribe_rumor.gd's shape (a central place that knows who-knows-what,
# fed by tribe_talk.gd's real proximity conversations) but for spatial route
# knowledge instead of gossip: when two members meet and talk, each teaches
# the other their single strongest known route (RouteMemory.top_routes(1)),
# via RouteMemory.learn_taught_route() -- which deliberately gives the
# listener only partial credit (TAUGHT_WEIGHT_FRACTION = 50%), so hearing
# about a shortcut is weaker than having walked it yourself, same asymmetry
# tribe_rumor.gd uses for leader-vs-peer gossip magnitude.
#
# Private-until-shared by design (per the user's explicit request): each
# NPC's RouteMemory starts empty and grows only from ITS OWN movement
# (tribemember.gd's _physics_process calling route_memory.visit()) --
# sharing is the ONLY way knowledge crosses between members, exactly like
# tribe_rumor.gd requires an actual plant()/transmit() call, not ambient
# telepathy.
# ─────────────────────────────────────────────────────────────────────────────

## Called from tribe_talk.gd's _try_start() when two tribe members (not
## cross-tribe rivals -- route knowledge is a tribe secret, matches how
## TribeMemory/relationship data already never crosses tribe lines) meet
## and begin a conversation. Each teaches the other their best route.
func share_on_meet(a: Node, b: Node) -> void:
	if a == null or b == null or not is_instance_valid(a) or not is_instance_valid(b):
		return
	if not ("route_memory" in a) or not ("route_memory" in b):
		return
	_teach(a, b)
	_teach(b, a)

func _teach(teacher: Node, student: Node) -> void:
	var teacher_rm = teacher.get("route_memory")
	var student_rm = student.get("route_memory")
	if teacher_rm == null or student_rm == null:
		return
	var routes: Array = teacher_rm.top_routes(1)
	if routes.is_empty():
		return
	var top: Dictionary = routes[0]
	student_rm.learn_taught_route(str(top["key"]), float(top["weight"]), float(top["base"]))
	print("[ROUTE] %s taught %s a route (strength %.2f)" % [
		str(teacher.get("member_name")), str(student.get("member_name")), float(top["strength"])])
