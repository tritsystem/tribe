extends Node3D
# ─────────────────────────────────────────────────────────────────────────────
# Stockpile — the physical heart of your camp. Members return here and deposit
# what they gather/hunt; the pile visibly grows with the tribe's supplies, and a
# banner shows the running inventory (food / skins / clubs).
# ─────────────────────────────────────────────────────────────────────────────

var manager
var _pile: MeshInstance3D = null
var _clubs_rack: MeshInstance3D = null
var _label: Label3D = null
var hp: float = 100.0
# CITIES (2026-07-29): the home stockpile leaves this blank -- only OUTPOST
# stockpiles (Tribemanager.found_outpost()) are actual named settlements,
# distinct enough from "your one camp" to deserve an identity of their own.
var settlement_name: String = ""
# DISTRICTS (2026-08-01): which specialty this settlement was founded as
# ("Watch"/"Gathering"/"Crafting") -- see Tribemanager.found_outpost() for
# the real structures/mechanical effects tied to each. Blank on the home
# stockpile, same as settlement_name.
var district: String = ""
# PER-SETTLEMENT ECONOMIES (2026-08-04): previously an explicit, honest gap
# -- "there is one tribe economy in this codebase, not a per-camp inventory
# system". An outpost now carries its own REAL local stockpile: residents
# (see Tribemanager.add_food_at()/spend_food_at() and friends) deposit into
# and draw from these instead of the shared camp economy. Always 0 on the
# home stockpile, which still uses the manager's own totals as it always
# has -- this only applies to settlements founded away from camp.
var local_food: int = 0
var local_wood: int = 0
var local_materials: int = 0

func _ready() -> void:
	add_to_group("stockpile")
	_build()

# the heart of the camp — but it's the LAST thing to fall: fences first, then
# forward camps, only then is the stockpile itself touchable. Enforced here
# directly so it holds no matter who's attacking it.
func take_damage(d: float, attacker = null) -> void:
	if not get_tree().get_nodes_in_group("fence").is_empty():
		return
	if not get_tree().get_nodes_in_group("player_camp").is_empty():
		return
	hp -= d
	if hp <= 0.0:
		if manager == null:
			manager = get_tree().get_first_node_in_group("tribe_manager")
		if manager and manager.has_method("dismantle_tribe"):
			manager.dismantle_tribe(attacker)
		queue_free()

func _build() -> void:
	# a wooden platform
	var base := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(3.2, 0.3, 3.2)
	base.mesh = bm
	base.position = Vector3(0, 0.15, 0)
	base.material_override = MatCache.flat(Color(0.40, 0.28, 0.16))
	add_child(base)

	# the sack/food pile (scales with supplies) -- REAL ASSET (2026-07-27):
	# Kenney Survival Kit's box-large.glb (CC0, downloaded not generated),
	# textured (shares assets/survival/Textures/colormap.png), used AS-IS --
	# no material_override, that would wipe the baked texture. Falls back to
	# the old BoxMesh if the asset is missing. Still scales on Y with supply
	# level exactly as before -- .scale works on any mesh.
	_pile = _try_real_mesh("res://assets/survival/box-large.glb")
	if _pile == null:
		_pile = MeshInstance3D.new()
		var pm := BoxMesh.new()
		pm.size = Vector3(2.2, 1.0, 2.2)
		_pile.mesh = pm
		_pile.material_override = MatCache.flat(Color(0.85, 0.7, 0.35))
	else:
		_pile.scale = Vector3(4.4, 2.0, 2.2)   # box-large.glb measured 0.25x0.25x0.5 -- scaled to the old pile's footprint
	_pile.position = Vector3(0, 0.8, 0)
	add_child(_pile)

	# a small rack of tools off to the side -- Kenney's tool-axe.glb, same
	# real-asset/fallback convention as the pile above.
	_clubs_rack = _try_real_mesh("res://assets/survival/tool-axe.glb")
	if _clubs_rack == null:
		_clubs_rack = MeshInstance3D.new()
		var cm := BoxMesh.new()
		cm.size = Vector3(0.3, 0.3, 1.4)
		_clubs_rack.mesh = cm
		_clubs_rack.material_override = MatCache.flat(Color(0.45, 0.30, 0.15))
	else:
		_clubs_rack.scale = Vector3(2.6, 1.2, 4.5)   # tool-axe.glb measured ~0.11x0.256x0.03 -- scaled to a visible rack size
		_clubs_rack.rotation_degrees = Vector3(0, 0, 90)
	_clubs_rack.position = Vector3(2.0, 0.6, 0)
	add_child(_clubs_rack)

	_label = Label3D.new()
	_label.position = Vector3(0, 2.6, 0)
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.modulate = Color(1.0, 0.95, 0.7)
	_label.font_size = 28   # was 56 — way oversized this close to spawn,
	_label.outline_size = 8 # stacked with the companion's labels into an
	                        # unreadable jumble (Label3D scales with camera
	                        # distance like normal geometry, no built-in cap)
	add_child(_label)

## Loads a real .glb, pulls its first MeshInstance3D out of the glTF's own
## wrapper node, and returns it detached (ready to reposition/scale/add as a
## child) -- or null if the asset is missing. Same small helper shape used
## across mineral.gd/tree_field.gd for the same purpose.
func _try_real_mesh(glb_path: String) -> MeshInstance3D:
	if not ResourceLoader.exists(glb_path):
		return null
	var packed: PackedScene = load(glb_path)
	var inst := packed.instantiate()
	var found := _find_mesh(inst)
	if found == null:
		inst.queue_free()
		return null
	found.get_parent().remove_child(found)
	inst.queue_free()
	return found

func _find_mesh(root_node: Node) -> MeshInstance3D:
	if root_node is MeshInstance3D:
		return root_node as MeshInstance3D
	for c in root_node.get_children():
		var f := _find_mesh(c)
		if f != null:
			return f
	return null

func _process(_delta: float) -> void:
	if manager == null:
		manager = get_tree().get_first_node_in_group("tribe_manager")
	if manager == null:
		return
	# an OUTPOST shows its own real local economy; the home stockpile keeps
	# showing the manager's shared totals exactly as it always has.
	var is_outpost: bool = settlement_name != ""
	var food: int = local_food if is_outpost else manager.food
	var skins: int = local_materials if is_outpost else manager.materials
	var clbs: int = manager.clubs
	var wd: int = local_wood if is_outpost else manager.wood
	if _pile:
		var s := clampf(float(food + skins * 2) / 30.0, 0.12, 3.2)
		_pile.scale = Vector3(1.0, s, 1.0)
		_pile.visible = food + skins > 0
	if _clubs_rack:
		_clubs_rack.visible = clbs > 0
		_clubs_rack.scale = Vector3(1.0, 1.0, clampf(float(clbs) / 4.0, 0.3, 2.5))
	if _label:
		var header: String = settlement_name if settlement_name != "" else "STOCKPILE"
		if district != "":
			header += " (%s)" % district
		_label.text = "%s\nFood %d · Skins %d · Clubs %d · Wood %d" % [header, food, skins, clbs, wd]
