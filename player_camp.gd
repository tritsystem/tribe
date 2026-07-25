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

# TRUST PARITY (2026-07-19): "tribe camp and player camp should be trusted
# the same" -- a forward camp had NO local economy at all, unlike a founded
# outpost settlement (see Tribemanager._outpost_at()/add_food_at() and
# friends). A resident living at a forward camp now gets the exact same
# per-settlement local stock -- and the exact same Acquaintance+ trust gate
# on drawing from it (that gate is on the MEMBER's own rank, not the
# location, so it was always going to be identical once the location itself
# was recognized).
var local_food: int = 0
var local_wood: int = 0
var local_materials: int = 0

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
			# The player's OWN forward camp being razed -> "Your Tribe" box.
			if manager.has_method("notify_cat"):
				manager.notify_cat("tribe", "A forward camp has been razed!")
			else:
				manager.notify("A forward camp has been razed!")
		queue_free()
