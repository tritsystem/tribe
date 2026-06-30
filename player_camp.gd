extends Node3D
# ─────────────────────────────────────────────────────────────────────────────
# PlayerCamp — a forward camp (fire + huts) the player builds with wood, via
# Tribemanager.try_build_camp(). In group "player_camp".
#
# Siege order: a camp can't be damaged while any fence still stands — raiders
# (or anyone else) have to clear the perimeter first. See stockpile.gd for the
# next link in the chain (camps must fall before the stockpile is touchable).
# ─────────────────────────────────────────────────────────────────────────────

var hp: float = 50.0
var manager = null

func _ready() -> void:
	add_to_group("player_camp")

func take_damage(d: float, _attacker = null) -> void:
	if not get_tree().get_nodes_in_group("fence").is_empty():
		return  # fences must fall first
	hp -= d
	if hp <= 0.0:
		if manager == null:
			manager = get_tree().get_first_node_in_group("tribe_manager")
		if manager and manager.has_method("notify"):
			manager.notify("A forward camp has been razed!")
		queue_free()
