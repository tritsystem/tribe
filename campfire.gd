extends StaticBody3D
# ─────────────────────────────────────────────────────────────────────────────
# Campfire — a real, physical structure. Previously tribe_llm.gd's own WORLD
# prompt told the LLM campfires existed when no such object was ever built
# (players reported NPCs "talking about a nonexistent campfire" -- see that
# fix). This is the real thing: every camp (the player's, and every rival
# tribe's) gets one. At night (see Tribemanager's day/night cycle) it's the
# gathering point idle members walk to for gossip/laughter/a ceremonial
# dance -- see tribemember.gd's _night_campfire_behavior().
# In group "campfire".
# ─────────────────────────────────────────────────────────────────────────────

var _flicker_t := 0.0
var _flame: MeshInstance3D
var _light: OmniLight3D

func _ready() -> void:
	add_to_group("campfire")
	_build_visual()

func _build_visual() -> void:
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.6; torus.outer_radius = 0.85
	ring.mesh = torus
	ring.position = Vector3(0, 0.1, 0)
	ring.rotation_degrees = Vector3(90, 0, 0)
	ring.material_override = MatCache.flat(Color(0.35, 0.30, 0.28), 0.9, 0.0)
	add_child(ring)

	_flame = MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.02; cone.bottom_radius = 0.35; cone.height = 0.9
	_flame.mesh = cone
	_flame.position = Vector3(0, 0.55, 0)
	var fmat := StandardMaterial3D.new()
	fmat.albedo_color = Color(1.0, 0.55, 0.15)
	fmat.emission_enabled = true
	fmat.emission = Color(1.0, 0.45, 0.1)
	fmat.emission_energy_multiplier = 2.0
	_flame.material_override = fmat
	add_child(_flame)

	_light = OmniLight3D.new()
	_light.light_color = Color(1.0, 0.55, 0.2)
	_light.omni_range = 9.0
	_light.light_energy = 1.3
	_light.position = Vector3(0, 0.8, 0)
	add_child(_light)

	var col := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 0.85; shape.height = 0.3
	col.shape = shape
	col.position = Vector3(0, 0.15, 0)
	add_child(col)

func _process(delta: float) -> void:
	# a gentle flicker -- cheap (one sine, no per-frame allocation), but
	# enough that the fire doesn't read as a static, dead prop
	_flicker_t += delta * 6.0
	var f := 0.85 + 0.15 * sin(_flicker_t)
	if _light: _light.light_energy = 1.3 * f
	if _flame: _flame.scale = Vector3(1.0, f, 1.0)
