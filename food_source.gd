extends Node3D
# ─────────────────────────────────────────────────────────────────────────────
# FoodSource (berry bush) — a regrowing food node in the world.
#   • Tribe members walk here on a GATHER order and harvest() it.
#   • Wild animals graze() from it when their Hunger neuron fires.
#   • It slowly regrows, so the world isn't permanently stripped bare.
# In group "food_source" so members and animals can find the nearest one.
# ─────────────────────────────────────────────────────────────────────────────
const SpatialGrid = preload("res://spatial_grid.gd")

## DIVERSITY PASS (2026-07-19): "10x the diversity of plants" -- was one
## generic "berry bush" regardless of species. Each real species tints the
## same berry mesh and tunes yield/regrow -- keeps the existing geometry
## (no new art needed) while making the world's plant life actually vary.
const SPECIES := {
	"Berries":  {"color": Color(0.55, 0.15, 0.55), "food_mult": 1.0, "regrow_mult": 1.0},
	"Herbs":    {"color": Color(0.30, 0.55, 0.25), "food_mult": 0.6, "regrow_mult": 1.4},
	"Roots":    {"color": Color(0.55, 0.42, 0.25), "food_mult": 1.3, "regrow_mult": 0.6},
	"Mushrooms":{"color": Color(0.75, 0.60, 0.50), "food_mult": 0.8, "regrow_mult": 1.1},
	"Nuts":     {"color": Color(0.45, 0.32, 0.18), "food_mult": 1.5, "regrow_mult": 0.5},
	"Wild Grain": {"color": Color(0.80, 0.68, 0.25), "food_mult": 0.9, "regrow_mult": 1.6},
}
@export var species: String = "Berries"
var food_mult: float = 1.0

var amount: float = 6.0
var max_amount: float = 6.0
var regrow_rate: float = 0.35

var _berries: MeshInstance3D = null
var _label: Label3D = null

func _ready() -> void:
	add_to_group("food_source")
	var stats: Dictionary = SPECIES.get(species, SPECIES["Berries"])
	food_mult = float(stats["food_mult"])
	regrow_rate *= float(stats["regrow_mult"])
	_build()
	_refresh()
	# PERF/SEARCH FIX (2026-07-19): _nearest_food_source() (tribemember.gd)
	# used to scan get_tree().get_nodes_in_group("food_source") in full every
	# call. Registering with SpatialGrid lets that search walk only nearby
	# cells. Deferred in case a spawner repositions this bush after _ready,
	# same reasoning as tree.gd's own registration.
	call_deferred("_register_with_grid")

func _register_with_grid() -> void:
	SpatialGrid.update(self)

## REAL ASSET (2026-07-27): Kenney Nature Kit's plant_bush.glb (CC0, downloaded
## not generated) for the base foliage. Kept as a separate node from `_berries`
## rather than a full swap -- the ripeness/harvest-progress feedback (scale +
## color lerp in _refresh()) is a real gameplay signal with no real-asset
## equivalent (Kenney doesn't ship a bush that changes color as you pick it),
## so that small sphere stays as a functional accent riding on top of the real
## bush, same tradeoff already used for the turtle's legs/stockpile's scaling.
const BUSH_GLB := "res://assets/nature/plant_bush.glb"
const BUSH_MEASURED_RADIUS := 0.198
const BUSH_TARGET_RADIUS := 0.85

func _build() -> void:
	if not _try_real_bush():
		var base := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.7
		cyl.bottom_radius = 0.85
		cyl.height = 0.4
		base.mesh = cyl
		base.position = Vector3(0, 0.2, 0)
		base.material_override = MatCache.flat(Color(0.35, 0.25, 0.15))
		add_child(base)

	_berries = MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = 0.35
	sph.height = 0.7
	_berries.mesh = sph
	_berries.position = Vector3(0, 0.75, 0)
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.25, 0.6, 0.2)
	_berries.material_override = gmat
	add_child(_berries)

func _try_real_bush() -> bool:
	if not ResourceLoader.exists(BUSH_GLB):
		return false
	var packed: PackedScene = load(BUSH_GLB)
	var inst := packed.instantiate()
	if not (inst is Node3D):
		inst.queue_free()
		return false
	var s: float = BUSH_TARGET_RADIUS / BUSH_MEASURED_RADIUS
	(inst as Node3D).scale = Vector3(s, s, s)
	add_child(inst)
	return true

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
			var ripe: Color = Color(SPECIES.get(species, SPECIES["Berries"])["color"])
			mat.albedo_color = Color(0.5, 0.35, 0.2).lerp(ripe, f)
		_berries.visible = amount > 0.2
	if _label:
		_label.text = "%s: %d" % [species, int(round(amount))]

# Members call this to take food; returns how much was actually taken.
# food_mult (from this bush's own species) reflects that some plants are
# just more/less calorie-dense per harvest than a plain berry bush.
func harvest(n: float) -> int:
	var take: float = minf(amount, n)
	amount -= take
	_refresh()
	return int(round(take * food_mult))

# Animals nibble continuously while grazing.
func graze(delta: float) -> void:
	amount = maxf(0.0, amount - delta * 0.6)
	_refresh()
