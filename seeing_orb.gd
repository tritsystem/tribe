extends Node3D
class_name SeeingOrb

# ─────────────────────────────────────────────────────────────────────────────
# SeeingOrb — "a seeing orb SNN that can see other tribes from birds-eye view.
# if you see objects in your community map than allow it to piece together
# rest of the map" (2026-08-28).
#
# Thin Node3D wrapper (visual + scene-tree glue) around seeing_orb_brain.gd,
# which holds the actual real SNN scan/discover logic (kept separate so the
# logic itself is standalone-testable -- see that file's header comment).
#
# Ties into the REAL existing map/discovery system (map_view.gd +
# Tribemanager's `discovered` flag) rather than inventing a parallel one --
# every camp already appears as an anonymous gray dot on [TAB]'s map the
# instant it exists; discovery just reveals its name/color/allegiance,
# currently only via scouting [T] or walking within WALK_DISCOVER_RANGE
# (16m). This orb is a THIRD path: a long-range, real object with genuine
# spatial recognition (has to accumulate enough real "spotted" signal per
# tribe over several scans, not an instant reveal-everything cheat).
# ─────────────────────────────────────────────────────────────────────────────

const SeeingOrbBrainScript = preload("res://seeing_orb_brain.gd")

@export var scan_radius: float = 90.0
@export var scan_interval: float = 1.0

var _orb_brain: SeeingOrbBrain = SeeingOrbBrainScript.new()
var _scan_cd: float = 0.0
var manager = null   # set externally to the real Tribemanager, same convention as tribemember.gd

func _ready() -> void:
	add_to_group("seeing_orb")
	_orb_brain.scan_radius = scan_radius
	_build_visual()

func _process(delta: float) -> void:
	_scan_cd -= delta
	if _scan_cd > 0.0:
		return
	_scan_cd = scan_interval
	if manager == null or not ("world_tribes" in manager):
		return
	var notify_cb = Callable(manager, "notify") if manager.has_method("notify") else null
	_orb_brain.scan(manager.world_tribes, global_position, notify_cb)

func _build_visual() -> void:
	var mesh := MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = 0.35
	sph.height = 0.7
	mesh.mesh = sph
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.35, 0.75, 0.95)
	mat.emission_enabled = true
	mat.emission = Color(0.45, 0.85, 1.0)
	mat.emission_energy_multiplier = 3.0
	mesh.material_override = mat
	add_child(mesh)
	var light := OmniLight3D.new()
	light.light_color = Color(0.45, 0.85, 1.0)
	light.omni_range = 6.0
	light.light_energy = 0.9
	add_child(light)
