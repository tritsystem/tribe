extends "res://turtle_island.gd"
# ─────────────────────────────────────────────────────────────────────────────
# PlayerIsland — the player's OWN home camp, riding a turtle exactly like
# every rival tribe does. Deliberately its OWN small script, not a
# world_tribe.gd instance: the player's camp has none of that script's
# rival-AI roster, opinions/bonds, or conquest logic -- Tribemanager.gd
# already owns all of that directly for the player's tribe. This is just the
# "float + carry children" concern, so both the player and every rival can
# each have their own turtle without duplicating rival-specific machinery
# into the player's camp (or vice versa).
#
# UNIFIED (2026-07-27): the turtle body/drift/collision-stick logic that used
# to be duplicated here AND in world_tribe.gd now lives once in
# turtle_island.gd (this script's base) -- extracted at the user's explicit
# request, after several turtle bugs each had to be found and fixed twice
# across the two copies. This file is now just the player-specific defaults
# and the palette/message that make the player's own island read as visually
# distinct from a rival's at a glance.
#
# Every structure the player builds at home (stockpile, campfire, teepees,
# blocks, fences -- see Tribemanager.gd's _spawn_stockpile/_spawn_campfire/
# try_build_teepee/try_build_block/try_build_fence) is add_child()'d onto
# THIS node with a LOCAL position, so moving this node's global_position
# each tick moves the whole home camp for free, same trick world_tribe.gd
# already uses for rival camps.
# ─────────────────────────────────────────────────────────────────────────────

func setup(mgr) -> void:
	manager = mgr
	is_turtle = true
	# Phase 4: unlike a rival island (steerable only once earned via Phase 3's
	# trust quests -- see world_tribe.gd), this is the player's OWN camp.
	# There's no one to quest for here; you already command it. Steerable
	# from the start.
	steerable = true
	turtle_radius = 135.0   # 3x (was 45.0) -- generous, the player's camp grows organically via manual building over a whole playthrough, unlike a rival's one-time fixed-radius plan
	# a slightly different tint palette than the base class's rival default,
	# so the player's own island reads as distinct at a glance.
	tint_shell = Color(0.30, 0.48, 0.26)
	tint_neck = Color(0.36, 0.46, 0.28)
	tint_head = Color(0.38, 0.48, 0.30)
	tint_leg = Color(0.32, 0.44, 0.26)
	stick_message = "A rival island collides with yours and lashes on in the current!"
	_build_turtle_body()
	_spawn_starting_resources()

func _process(delta: float) -> void:
	_turtle_tick(delta)
	_tick_local_resources(delta)

# ─────────────────────────────────────────────────────────────────────────────
# RESOURCES ON THE PLAYER'S OWN SHELL (2026-07-28) -- "put all resources on
# every shell". Every rival camp gets a starting grove + a periodic top-up
# (world_tribe.gd's _spawn_resource_grove()/_tick_local_resources()), but the
# player's own island -- being a different subclass, not a world_tribe.gd
# instance -- never got the equivalent: standing at home, there was nothing
# to gather at all. Self-contained here rather than sharing world_tribe.gd's
# copies directly, since those are keyed off territory_radius (a world_tribe-
# only stat the player's camp doesn't have -- see turtle_radius's own comment
# on why it's set directly here instead of derived).
# ─────────────────────────────────────────────────────────────────────────────
const RESOURCE_CHECK_INTERVAL := 4.0
const RESOURCE_MIN := 2
var _resource_check_accum: float = 0.0

func _spawn_starting_resources() -> void:
	for _i in range(randi_range(5, 8)):
		_spawn_local_tree()
	for _i in range(2):
		_spawn_local_food()
	for _i in range(2):
		spawn_local_mineral(turtle_radius * 0.7)

func _tick_local_resources(delta: float) -> void:
	_resource_check_accum -= delta
	if _resource_check_accum > 0.0:
		return
	_resource_check_accum = RESOURCE_CHECK_INTERVAL
	var radius: float = turtle_radius * 0.7

	var near_trees := 0
	for t in get_tree().get_nodes_in_group("tree"):
		var tn := t as Node3D
		if tn and is_instance_valid(tn) and global_position.distance_to(tn.global_position) <= radius:
			near_trees += 1
			if near_trees >= RESOURCE_MIN:
				break
	if near_trees < RESOURCE_MIN:
		_spawn_local_tree()

	var near_food := 0
	for f in get_tree().get_nodes_in_group("food_source"):
		var fn := f as Node3D
		if fn and is_instance_valid(fn) and global_position.distance_to(fn.global_position) <= radius:
			near_food += 1
			if near_food >= RESOURCE_MIN:
				break
	if near_food < RESOURCE_MIN:
		_spawn_local_food()

	var near_minerals := 0
	for mn in get_tree().get_nodes_in_group("mineral"):
		var mnn := mn as Node3D
		if mnn and is_instance_valid(mnn) and global_position.distance_to(mnn.global_position) <= radius:
			near_minerals += 1
			if near_minerals >= RESOURCE_MIN:
				break
	if near_minerals < RESOURCE_MIN:
		spawn_local_mineral(radius)

func _local_offset(radius: float) -> Vector3:
	var ang := randf() * TAU
	var r := radius * randf_range(0.4, 0.85)
	return Vector3(cos(ang) * r, deck_height(), sin(ang) * r)

func _spawn_local_tree() -> void:
	var t = StaticBody3D.new()
	t.set_script(load("res://tree.gd"))
	t.set("species", ["Oak", "Pine", "Pine", "Birch", "Willow", "Cedar"][randi() % 6])
	add_child(t)
	t.position = _local_offset(turtle_radius * 0.7)

func _spawn_local_food() -> void:
	var b = Node3D.new()
	b.set_script(load("res://food_source.gd"))
	b.set("species", ["Berries", "Berries", "Berries", "Herbs", "Herbs", "Roots", "Mushrooms", "Nuts", "Wild Grain"][randi() % 9])
	add_child(b)
	b.position = _local_offset(turtle_radius * 0.7)
