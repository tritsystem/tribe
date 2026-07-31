extends Node
# Headless test for the player's own island getting real resources (2026-07-28:
# "put all resources on every shell" -- the player's home turtle previously
# had zero trees/food/minerals of its own, unlike every rival camp).
# Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path . res://test_player_island_resources.tscn --quit

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  PLAYER ISLAND RESOURCES -- the home shell isn't empty anymore")
	print("=".repeat(60))

	# untyped: set_script() runs after a `:=`-typed var's type would already be
	# locked in as Node3D, which can't resolve player_island.gd's own members
	# (same fix Tribemanager.gd's _spawn_world_tribes() already uses)
	var pi = Node3D.new()
	pi.set_script(load("res://player_island.gd"))
	add_child(pi)
	pi.setup(null)   # manager=null is fine -- nothing here touches it

	var trees := 0
	var foods := 0
	var minerals := 0
	for c in pi.get_children():
		if c.is_in_group("tree"):
			trees += 1
		elif c.is_in_group("food_source"):
			foods += 1
		elif c.is_in_group("mineral"):
			minerals += 1

	_check("the home island starts with real trees on it", trees >= 5)
	_check("...real food sources too", foods >= 2)
	_check("...and real minerals (previously NONE existed anywhere in turtle mode)", minerals >= 2)

	# every spawned resource must actually be positioned ON the deck (not
	# buried in the shell's collision, not floating at the origin) and within
	# the island's own footprint (not out past the edge, in open water)
	var all_placed_well := true
	for c in pi.get_children():
		if c.is_in_group("tree") or c.is_in_group("food_source") or c.is_in_group("mineral"):
			var p: Vector3 = (c as Node3D).position
			var flat_r := Vector2(p.x, p.z).length()
			if p.y < pi.TURTLE_FREEBOARD or flat_r > pi.turtle_radius:
				all_placed_well = false
	_check("every spawned resource sits on the deck, within the island's own footprint",
		all_placed_well)

	# deplete everything, then confirm the periodic top-up actually replaces it
	for c in pi.get_children().duplicate():
		if c.is_in_group("tree") or c.is_in_group("food_source") or c.is_in_group("mineral"):
			c.free()
	await get_tree().process_frame   # let free()'d nodes actually leave the tree/groups

	pi._resource_check_accum = 0.0   # force the topup check to run on the next tick
	pi._tick_local_resources(0.1)

	var after_trees := 0
	var after_foods := 0
	var after_minerals := 0
	for c in pi.get_children():
		if c.is_in_group("tree"):
			after_trees += 1
		elif c.is_in_group("food_source"):
			after_foods += 1
		elif c.is_in_group("mineral"):
			after_minerals += 1
	_check("a stripped-bare home island gets a tree back via the periodic top-up",
		after_trees >= 1)
	_check("...a food source too", after_foods >= 1)
	_check("...and a mineral (the gap that never had ANY spawn path before)",
		after_minerals >= 1)

	pi.free()

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
