extends Node
# Headless test for the turtle shell's sloped collision (turtle_island.gd).
# Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path . res://test_turtle_shell_collision.tscn --quit

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  TURTLE SHELL COLLISION -- sloped frustum, not a sheer wall")
	print("=".repeat(60))

	var t := Node3D.new()
	t.set_script(load("res://turtle_island.gd"))
	t.is_turtle = true
	t.turtle_radius = 67.2   # RIVAL_TURTLE_RADIUS, a real in-game value
	add_child(t)
	t._build_turtle_body()

	_check("deck_height() sits above TURTLE_FREEBOARD (a little standing clearance)",
		t.deck_height() > t.TURTLE_FREEBOARD)

	# the collision StaticBody3D isn't named explicitly -- find it via the
	# group instead, matching how the rest of the game locates it.
	var found_body = null
	for c in t.get_children():
		if c.is_in_group("turtle_body"):
			found_body = c
	_check("the shell's collision StaticBody3D exists and is grouped 'turtle_body'",
		found_body != null)

	var dome_col = null
	if found_body != null:
		for c in found_body.get_children():
			if c is CollisionShape3D and c.shape is ConvexPolygonShape3D:
				dome_col = c
	_check("the shell has a ConvexPolygonShape3D collider (not a flat cylinder)",
		dome_col != null)

	if dome_col != null:
		var pts: PackedVector3Array = dome_col.shape.points
		_check("the dome shape has real points (base+plateau rings)", pts.size() > 0)

		var max_r := 0.0
		var min_r := INF
		var max_y := -INF
		var min_y := INF
		for p in pts:
			var r := Vector2(p.x, p.z).length()
			max_r = maxf(max_r, r)
			min_r = minf(min_r, r)
			max_y = maxf(max_y, p.y)
			min_y = minf(min_y, p.y)

		_check("the widest ring reaches out to the full turtle_radius (the waterline base)",
			is_equal_approx(max_r, t.turtle_radius))
		_check("the narrowest ring (the plateau) is meaningfully smaller than the base -- a real taper, not a straight wall",
			min_r < max_r * 0.95 and min_r > max_r * 0.5)
		_check("the shape spans from below the waterline up to above the crest",
			min_y < 0.0 and max_y > t.TURTLE_FREEBOARD)

		# THE ACTUAL BUG: confirm points nearer the base are also nearer the
		# waterline, and points nearer the plateau are higher up -- i.e. radius
		# shrinks as height rises, a genuine slope. A flat-topped cylinder
		# would have every point at the SAME radius regardless of height.
		var radius_at_low_y := -1.0
		var radius_at_high_y := -1.0
		for p in pts:
			var r := Vector2(p.x, p.z).length()
			if is_equal_approx(p.y, -1.0) and radius_at_low_y < 0.0:
				radius_at_low_y = r
			if p.y > t.TURTLE_FREEBOARD and radius_at_high_y < 0.0:
				radius_at_high_y = r
		_check("radius shrinks from the waterline ring to the plateau ring (a real slope)",
			radius_at_low_y > 0.0 and radius_at_high_y > 0.0 and radius_at_high_y < radius_at_low_y)

	t.free()

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
