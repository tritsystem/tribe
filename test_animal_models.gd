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

	# Boar is still on the old gen_animals.py rig (no real downloaded model
	# sourced for it yet -- see ASSET_ALIAS's comment in animal.gd), so it's
	# the one species left that actually has a HeadMarker/Leg0-3 to test
	# against. Deer/Wolf/etc. now use real downloaded models instead.
	var a := CharacterBody3D.new()
	a.set_script(load("res://animal.gd"))
	a.species = "Boar"
	add_child(a)
	var mesh_node := a.get_node_or_null("Mesh")
	_check("a spawned Boar gets a real 'Mesh' node (the imported model, not a bare capsule)",
		mesh_node != null)
	_check("...and it's NOT just a plain CapsuleMesh primitive anymore",
		not (mesh_node is MeshInstance3D and (mesh_node as MeshInstance3D).mesh is CapsuleMesh))
	_check("the model's real HeadMarker was found and used for eye attachment",
		a._head != null and a._head.name == "HeadMarker")
	_check("googly eyes still attach on top of the real model (same signature look)",
		not a._head.get_children().filter(func(c): return c.is_in_group("googly_eye")).is_empty())
	a.free()

	# ── REAL DOWNLOADED MODELS (2026-07-28): Deer/Fox/Wolf/Elk/Rabbit/Bear/Goat
	# now render a real CC0/CC-BY model (Quaternius / molochdadev via
	# poly.pizza) instead of gen_animals.py's primitives. None of those carry
	# a HeadMarker or Leg0-3 -- confirm _build() degrades to "whole model as
	# head, no googly eyes, no leg animation" instead of guessing wrong ──
	var d := CharacterBody3D.new()
	d.set_script(load("res://animal.gd"))
	d.species = "Deer"
	add_child(d)
	_check("a spawned Deer (real downloaded model) still gets a real 'Mesh' node",
		d.get_node_or_null("Mesh") != null)
	_check("...with no HeadMarker, _head falls back to the whole model",
		d._head != null and d._head.name == "Mesh")
	_check("...and no googly eyes get bolted onto its own sculpted face",
		d._head.get_children().filter(func(c): return c.is_in_group("googly_eye")).is_empty())
	_check("...and no Leg0-3 means no manual leg animation is attempted",
		d._legs.is_empty())
	d.free()

	# Hare has no real model of its own -- ASSET_ALIAS redirects it to
	# Rabbit's real mesh while keeping Hare's own distinct stats/brain.
	var h := CharacterBody3D.new()
	h.set_script(load("res://animal.gd"))
	h.species = "Hare"
	add_child(h)
	_check("Hare spawns cleanly via the Rabbit asset alias",
		h.get_node_or_null("Mesh") != null)
	var animal_script := load("res://animal.gd")
	_check("...but keeps its OWN stats (Hare's sense_radius, not Rabbit's)",
		is_equal_approx(h.sense_radius, animal_script.SPECIES["Hare"]["sense"]))
	h.free()

	# ── real leg animation (2026-07-19) -- Boar, the one remaining species
	# still on the old rig with real Leg0-3 nodes to swing ──
	var c := CharacterBody3D.new()
	c.set_script(load("res://animal.gd"))
	c.species = "Boar"
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
