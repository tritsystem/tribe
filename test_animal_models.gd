extends Node
# Headless test for the Blender-generated animal models (tools/gen_animals.py).
# Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path . res://test_animal_models.tscn --quit

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  ANIMAL MODELS -- real Blender-generated assets load correctly")
	print("=".repeat(60))

	for species in ["Rabbit", "Hare", "Fox", "Deer", "Goat", "Elk", "Boar", "Wolf", "Bear"]:
		var glb_path := "res://assets/animals/%s.glb" % species.to_lower()
		_check("%s's .glb asset exists on disk" % species, ResourceLoader.exists(glb_path))

	var a := CharacterBody3D.new()
	a.set_script(load("res://animal.gd"))
	a.species = "Deer"
	add_child(a)
	var mesh_node := a.get_node_or_null("Mesh")
	_check("a spawned Deer gets a real 'Mesh' node (the imported model, not a bare capsule)",
		mesh_node != null)
	_check("...and it's NOT just a plain CapsuleMesh primitive anymore",
		not (mesh_node is MeshInstance3D and (mesh_node as MeshInstance3D).mesh is CapsuleMesh))
	_check("the model's real HeadMarker was found and used for eye attachment",
		a._head != null and a._head.name == "HeadMarker")
	_check("googly eyes still attach on top of the real model (same signature look)",
		not a._head.get_children().filter(func(c): return c.is_in_group("googly_eye")).is_empty())
	a.free()

	# ── real leg animation (2026-07-19) ──
	var c := CharacterBody3D.new()
	c.set_script(load("res://animal.gd"))
	c.species = "Wolf"
	add_child(c)
	_check("the model carries 4 separate, individually-animatable leg objects",
		c._legs.size() == 4)
	var before_rot: float = c._legs[0].rotation.x
	c._animate_legs(0.1, 3.0)   # a real walking speed
	_check("walking actually swings the legs from their hips, not a static pose",
		c._legs[0].rotation.x != before_rot)
	_check("front-left and back-right swing together (diagonal trot gait)",
		is_equal_approx(c._legs[0].rotation.x, c._legs[3].rotation.x))
	_check("...opposite to front-right and back-left",
		sign(c._legs[0].rotation.x) != sign(c._legs[1].rotation.x))
	var mid_swing: float = absf(c._legs[0].rotation.x)
	c._animate_legs(0.5, 0.0)   # stopped -- legs must settle back toward rest
	_check("standing still relaxes the legs back toward a neutral pose",
		absf(c._legs[0].rotation.x) < mid_swing)
	c.free()

	# fallback safety: a species with no matching asset must still spawn cleanly
	var b := CharacterBody3D.new()
	b.set_script(load("res://animal.gd"))
	b.species = "NoSuchSpecies"
	add_child(b)
	_check("an unknown species with no matching .glb falls back to the old primitive body, not a crash",
		b.get_node_or_null("Mesh") != null)
	b.free()

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
