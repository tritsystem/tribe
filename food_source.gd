extends Node3D
# ─────────────────────────────────────────────────────────────────────────────
# FoodSource (berry bush) — a regrowing food node in the world.
#   • Tribe members walk here on a GATHER order and harvest() it.
#   • Wild animals graze() from it when their Hunger neuron fires.
#   • It slowly regrows, so the world isn't permanently stripped bare.
# In group "food_source" so members and animals can find the nearest one.
# ─────────────────────────────────────────────────────────────────────────────

var amount: float = 6.0
var max_amount: float = 6.0
var regrow_rate: float = 0.35

var _berries: MeshInstance3D = null
var _label: Label3D = null

func _ready() -> void:
	add_to_group("food_source")
	_build()
	_refresh()

func _build() -> void:
	var base := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.7
	cyl.bottom_radius = 0.85
	cyl.height = 0.4
	base.mesh = cyl
	base.position = Vector3(0, 0.2, 0)
	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = Color(0.35, 0.25, 0.15)
	base.material_override = bmat
	add_child(base)

	_berries = MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = 0.6
	sph.height = 1.2
	_berries.mesh = sph
	_berries.position = Vector3(0, 0.95, 0)
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.25, 0.6, 0.2)
	_berries.material_override = gmat
	add_child(_berries)

	_label = Label3D.new()
	_label.position = Vector3(0, 2.0, 0)
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.modulate = Color(0.7, 1.0, 0.6)
	add_child(_label)

func _process(delta: float) -> void:
	if amount < max_amount:
		amount = minf(max_amount, amount + regrow_rate * delta)
		_refresh()

func _refresh() -> void:
	if _berries:
		var f := clampf(amount / max_amount, 0.0, 1.0)
		var s := 0.25 + 0.75 * f
		_berries.scale = Vector3(s, s, s)
		var mat := _berries.material_override as StandardMaterial3D
		if mat:
			mat.albedo_color = Color(0.5, 0.35, 0.2).lerp(Color(0.25, 0.65, 0.2), f)
		_berries.visible = amount > 0.2
	if _label:
		_label.text = "Berries: %d" % int(round(amount))

# Members call this to take food; returns how much was actually taken.
func harvest(n: float) -> int:
	var take: float = minf(amount, n)
	amount -= take
	_refresh()
	return int(round(take))

# Animals nibble continuously while grazing.
func graze(delta: float) -> void:
	amount = maxf(0.0, amount - delta * 0.6)
	_refresh()
