extends RefCounted
class_name SeeingOrbBrain

# ─────────────────────────────────────────────────────────────────────────────
# SeeingOrbBrain — the real SNN scan/piece-together logic for seeing_orb.gd,
# split into a plain RefCounted (like every other *_memory.gd in this
# session) so it's standalone-testable without needing a live scene tree
# (Node3D.global_position can't be set outside is_inside_tree(), confirmed
# via a direct standalone test -- see the vault's own
# godot-standalone-scenetree-test-autoload-blindspot lesson for the same
# class of issue). seeing_orb.gd is now a thin Node3D wrapper that owns the
# visual + calls into this for the actual logic.
# ─────────────────────────────────────────────────────────────────────────────

const OrbBrainScript = preload("res://spikeling.gd")

var scan_radius: float = 90.0
var spot_threshold: float = 100.0
var _brain: Spikeling = null

func _get_brain() -> Spikeling:
	if _brain == null:
		_brain = OrbBrainScript.new()
	return _brain

## `world_tribes`: Array of real world_tribe.gd instances (or anything with
## .tribe_name/.global_position/.defeated/.discovered/.discover()).
## `origin`: the orb's own world position.
## `notify_cb`: optional Callable(String) for a real notification, or null.
## Returns the array of tribes newly discovered THIS scan (for tests/logging).
func scan(world_tribes: Array, origin: Vector3, notify_cb = null) -> Array:
	var b := _get_brain()
	var spotted_this_scan: Array = []
	for t in world_tribes:
		if not is_instance_valid(t) or t.defeated or t.discovered:
			continue
		var tname: String = str(t.tribe_name)
		var neuron_name := "Spotted_" + tname
		if b._idx(neuron_name) == -1:
			_add_tribe_neuron(b, neuron_name)
		var dist: float = origin.distance_to(t.global_position)
		if dist > scan_radius:
			continue
		var closeness: float = 1.0 - clampf(dist / scan_radius, 0.0, 1.0)
		b.stimulate(neuron_name, 20.0 + 80.0 * closeness)
		spotted_this_scan.append({"tribe": t, "neuron": neuron_name})

	var fired: Array = b.step()
	var newly_discovered: Array = []
	for entry in spotted_this_scan:
		if entry["neuron"] in fired:
			var t = entry["tribe"]
			if t.has_method("discover"):
				t.discover()
				newly_discovered.append(t)
				if notify_cb != null:
					notify_cb.call("The orb reveals the %s camp from afar." % str(t.tribe_name))
	return newly_discovered

func _add_tribe_neuron(b: Spikeling, neuron_name: String) -> void:
	var n = b.Neuron.new()
	n.name = neuron_name
	n.threshold = spot_threshold
	n.leak = 6.0
	b._name_to_idx[neuron_name] = b.neurons.size()
	b.neurons.append(n)
