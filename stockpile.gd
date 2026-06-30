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
	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = Color(0.40, 0.28, 0.16)
	base.material_override = bmat
	add_child(base)

	# the sack/food pile (scales with supplies)
	_pile = MeshInstance3D.new()
	var pm := BoxMesh.new()
	pm.size = Vector3(2.2, 1.0, 2.2)
	_pile.mesh = pm
	_pile.position = Vector3(0, 0.8, 0)
	var pmat := StandardMaterial3D.new()
	pmat.albedo_color = Color(0.85, 0.7, 0.35)
	_pile.material_override = pmat
	add_child(_pile)

	# a small rack of clubs off to the side
	_clubs_rack = MeshInstance3D.new()
	var cm := BoxMesh.new()
	cm.size = Vector3(0.3, 0.3, 1.4)
	_clubs_rack.mesh = cm
	_clubs_rack.position = Vector3(2.0, 0.6, 0)
	var cmat := StandardMaterial3D.new()
	cmat.albedo_color = Color(0.45, 0.30, 0.15)
	_clubs_rack.material_override = cmat
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

func _process(_delta: float) -> void:
	if manager == null:
		manager = get_tree().get_first_node_in_group("tribe_manager")
	if manager == null:
		return
	var food: int = manager.food
	var skins: int = manager.materials
	var clbs: int = manager.clubs
	var wd: int = manager.wood
	if _pile:
		var s := clampf(float(food + skins * 2) / 30.0, 0.12, 3.2)
		_pile.scale = Vector3(1.0, s, 1.0)
		_pile.visible = food + skins > 0
	if _clubs_rack:
		_clubs_rack.visible = clbs > 0
		_clubs_rack.scale = Vector3(1.0, 1.0, clampf(float(clbs) / 4.0, 0.3, 2.5))
	if _label:
		_label.text = "STOCKPILE\nFood %d · Skins %d · Clubs %d · Wood %d" % [food, skins, clbs, wd]
