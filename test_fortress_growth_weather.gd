extends Node
# Headless test for: repeating fortress expansion (tiers), material
# upgrades (Wood -> Stone -> Metal), and the weather system (visibility +
# hunger effects). Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path . res://test_fortress_growth_weather.tscn --quit

const TribeManagerScript = preload("res://Tribemanager.gd")
const BlockScript = preload("res://block.gd")

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  FORTRESS EXPANSION + MATERIAL UPGRADES + WEATHER")
	print("=".repeat(60))

	var mgr := TribeManagerScript.new()
	add_child(mgr)
	mgr._cat_lines = {"you": [], "tribe": [], "tribes": []}

	# scenario A: on_fortress_built() keeps incrementing a real tier instead
	# of setting a one-shot flag -- it can fire more than once.
	_check("fortress_tier starts at 0", mgr.fortress_tier == 0)
	mgr.on_fortress_built()
	_check("on_fortress_built() increments the tier", mgr.fortress_tier == 1)
	mgr.on_fortress_built()
	_check("on_fortress_built() can fire again -- real repeated expansion, not a one-shot flag",
		mgr.fortress_tier == 2)

	# scenario B: fence_ring_plan() actually scales up with tier -- a bigger,
	# more elaborate ring each time, not the same plan rebuilt in place.
	var plan_tier0: Array = mgr.fence_ring_plan(0)
	var plan_tier2: Array = mgr.fence_ring_plan(2)
	_check("a later-tier fortress plan has more segments than the first",
		plan_tier2.size() > plan_tier0.size())

	# scenario C: suggest_job() keeps proposing "build" across multiple
	# tiers (given enough wood/members), and stops once MAX_FORTRESS_TIER
	# is reached -- expansion is bounded, not infinite.
	mgr.fortress_tier = 0
	mgr.wood = 1000
	mgr.food = 1000
	var fake_member := Node.new()
	add_child(fake_member)
	# suggest_job()'s build gate requires members.size() >= 3 + fortress_tier;
	# a fresh manager's own roster is empty, so seed enough fake bodies for
	# both the tier-0 and tier-MAX_FORTRESS_TIER checks below.
	for i in range(3 + mgr.MAX_FORTRESS_TIER):
		mgr.members.append(Node.new())
	var tries_at_tier0 := 0
	for i in range(300):
		if mgr.suggest_job(fake_member) == "build":
			tries_at_tier0 += 1
	_check("suggest_job() proposes another build at tier 0 given enough wood/members",
		tries_at_tier0 > 0)

	mgr.fortress_tier = mgr.MAX_FORTRESS_TIER
	var tries_at_max := 0
	for i in range(300):
		if mgr.suggest_job(fake_member) == "build":
			tries_at_max += 1
	_check("suggest_job() stops proposing build once MAX_FORTRESS_TIER is reached",
		tries_at_max == 0)
	fake_member.free()
	for m in mgr.members:
		if is_instance_valid(m):
			m.free()
	mgr.members.clear()

	# scenario D: material upgrades are real -- rejected without enough
	# materials, succeed once affordable, and cost scales further tiers
	mgr.fortress_tier = 0
	mgr.materials = 10
	_check("an unaffordable material upgrade is rejected, spends nothing",
		not mgr.try_upgrade_material() and mgr.materials == 10 and mgr.material_tier == 0)
	mgr.materials = 100
	_check("an affordable upgrade succeeds and spends the real cost",
		mgr.try_upgrade_material() and mgr.material_tier == 1
		and mgr.materials == 100 - mgr.MATERIAL_UPGRADE_COST[1])

	# scenario E: try_build_block() actually uses the CURRENT material_tier
	# for every new block, and costs scale with tier -- an honest, immediate
	# upgrade, not retrofitted onto old blocks.
	mgr.wood = 100
	var before: Array = get_tree().get_nodes_in_group("block")
	_check("try_build_block places a block using the tribe's current material tier",
		mgr.try_build_block(Vector3(40, 1.0, 0)))
	var placed: Node = null
	for b in get_tree().get_nodes_in_group("block"):
		if not before.has(b):
			placed = b
			break
	_check("the placed block actually carries material_tier 1 (Stone)",
		placed != null and placed.material_tier == 1)
	_check("a Stone block has more HP than a bare Wood block (TIER_HP, not a flat repaint)",
		placed.hp == BlockScript.TIER_HP[1] and BlockScript.TIER_HP[1] > BlockScript.TIER_HP[0])

	# scenario F: weather has real mechanical effects, not just flavour text
	mgr.current_weather = mgr.Weather.CLEAR
	_check("clear weather doesn't reduce visibility or increase hunger",
		mgr.visibility_mult() == 1.0 and mgr.hunger_mult() == 1.0)
	mgr.current_weather = mgr.Weather.STORM
	_check("a storm meaningfully reduces visibility", mgr.visibility_mult() < 0.5)
	_check("a storm meaningfully increases hunger drain", mgr.hunger_mult() > 1.0)

	# scenario G: a member's effective sight actually shrinks in bad weather
	var m := CharacterBody3D.new()
	m.set_script(load("res://tribemember.gd"))
	add_child(m)
	m.manager = mgr
	mgr.current_weather = mgr.Weather.CLEAR
	var clear_sight: float = m._effective_sight()
	mgr.current_weather = mgr.Weather.STORM
	var storm_sight: float = m._effective_sight()
	_check("a member's effective sight radius shrinks in a storm",
		storm_sight < clear_sight)
	m.free()

	mgr.free()

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
