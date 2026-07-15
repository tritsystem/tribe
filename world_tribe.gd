extends Node3D
# ─────────────────────────────────────────────────────────────────────────────
# WorldTribe — one of the AI clans that populate the world. Owns a roster of
# npc.gd members, a totem (the rally point attackers walk up to and swing at),
# and its own simple economy (food/clubs/strength). Tribes fight each other
# over time (Tribemanager._war_tick), grow a palisade once established, and
# elect a leader from their most productive member.
#
# CONQUEST: the totem itself is no longer what falls — it's just where the
# fight happens. Every blow against it (damage_camp, from either the player
# or a rival war party) is routed to the camp's actual infrastructure: every
# standing teepee.gd must be knocked down first, one at a time, THEN the
# stockpile. The clan is only defeated once both are gone — see
# damage_camp() below and teepees / stockpile_hp.
# ─────────────────────────────────────────────────────────────────────────────

const SpatialGrid = preload("res://spatial_grid.gd")
const BlockScript = preload("res://block.gd")
const TribeRegistry = preload("res://tribe_registry.gd")

# MATERIAL CULTURE & PERSONALITY — both now DATA, not code. Each archetype's
# material, leader trait bias, and greeting speech live in a plain text file
# at res://tribes/<archetype>.tribe (see tribe_dsl.gd for the format) and get
# loaded once, cached, and shared by every tribe of that archetype via
# TribeRegistry. A writer edits a .tribe file to change a whole archetype's
# personality — no GDScript, no recompiling. Tribes slowly stockpile their
# material as they grow (see _grow()); sacking a camp (conquer(), called
# from damage_camp when by_player) hands whatever they'd stockpiled to the
# player as real loot — see Tribemanager.add_special_material(). Not flavor
# text: the player can spend it to forge a masterwork club.
var material_stock: int = 0
const MATERIAL_STOCK_CAP := 40

func material_name() -> String:
	return str(TribeRegistry.get_archetype(archetype).get("material", "Stone"))

# the line this tribe's leader greets you with, based on player_opinion —
# pulled from the archetype's .tribe file (speech: hostile/neutral/friendly/
# trusted/bonded). Falls back gracefully if a tier isn't defined for it.
func greeting() -> String:
	var speech: Dictionary = TribeRegistry.get_archetype(archetype).get("speech", {})
	var tier := "neutral"
	if player_opinion >= 0.7: tier = "bonded"
	elif player_opinion >= 0.4: tier = "trusted"
	elif player_opinion >= 0.15: tier = "friendly"
	elif player_opinion <= -0.3: tier = "hostile"
	if speech.has(tier):
		return str(speech[tier])
	return str(speech.get("neutral", "..."))

var tribe_name: String = "Rivals"
var strength: int = 60
var archetype: String = "Foragers"
var defeated: bool = false
var discovered: bool = false
var abandoned: bool = false

var member_count: int = 0
var member_cap: int = 16
var territory_radius: float = 16.0
var color: Color = Color(0.7, 0.2, 0.2)
var npcs: Array = []
var deaths: int = 0

var camp_hp: float = 50.0        # cosmetic "how hard-fought" stat shown to the
								  # player — see damage_camp(); doesn't gate
								  # conquest anymore, teepees+stockpile do
var teepees: Array = []          # every standing teepee.gd this tribe built
var built_teepee_count: int = 0  # total ever built (teepees.size() only counts survivors)
var stockpile_hp: float = 40.0
var stockpile_max_hp: float = 40.0
var stockpile_destroyed: bool = false
var food: int = 0
var clubs: int = 0
var wood: int = 0                # spent on blocks for the camp's wall/maze — see
								  # setup() for the starting pool and _build()
								  # for the grove of trees spawned beside camp
var blocks: Array = []           # every standing block.gd this tribe placed

var built: bool = false
var _fence_plan: Array = []
var _fence_accum: float = 0.0

# ── coordinated war musters ──
var war_party: Array = []
var at_war_with = null

# ── leadership: the most PRODUCTIVE member runs the tribe ──
var leader = null
var leader_score: int = 0
var _leader_accum: float = 0.0
var _growth_accum: float = 0.0

var _totem_label: Label3D = null
var manager = null   # the player's TribeManager, for raid resolution callbacks
var _stockpile_pile: MeshInstance3D = null
var _stockpile_clubs: MeshInstance3D = null

# ── HIVE MIND: one shared Spikeling brain for the whole tribe, per
# spikeling.gd's own design ("Run ONE of these per horde, not one per
# zombie"). Every member npc.gd points its own `brain` var at THIS instance
# (set in npc.gd's setup()) instead of running an individual copy. The tribe
# steps it once per tick here and members just read the result. ──
var brain: Spikeling
const BRAIN := """# Spikeling Neural Configuration
neuron SeeDanger threshold=50 leak=25
neuron Calm      threshold=100 leak=4
neuron Alarm     threshold=100 leak=10
synapse SeeDanger -> Alarm weight=120
refractory=2
"""
var hive_alarmed: bool = false   # members read this instead of stepping their own brain
var _brain_tick_accum: float = 0.0
const BRAIN_TICK_HZ := 8.0

# ── SIMULATION LOD — the actual answer to "can this scale to 1000 tribes,"
# not occlusion culling (that only saves rendering, not the per-member AI
# cost that runs every physics frame regardless of visibility). We check our
# distance to the player a couple times a second — cheap, one node per tribe
# — and push a tier down to every member (npc.gd.set_lod): full sim nearby,
# throttled-tick sim at mid range, and physics_process switched off entirely
# (zero cost) once we're far enough off that the player can't tell. The
# tribe's own economy (_grow, opinions, leader election) keeps running here
# regardless of tier, so a frozen-far tribe still grows/changes quietly.
const LOD_NEAR_DIST := 50.0
const LOD_MID_DIST := 150.0
const LOD_CHECK_INTERVAL := 0.5
var _lod_accum: float = 0.0
var _lod_tier: int = 0   # cached tier from last _tick_lod; 2 = far (brain skipped)

# ── LEADER PERSONALITY — each tribe's leader has traits that bias the whole
# tribe's behavior (raid frequency/target choice, recruiting eagerness).
# Randomized at creation with a bias read from the archetype's .tribe file
# (TribeRegistry/tribe_dsl.gd), so a "Raiders" tribe tends aggressive but
# isn't guaranteed to be — some variance keeps the world from feeling
# templated. Re-rolled (drifted) on leadership change in _elect_leader(),
# not fully reset, so a tribe's character evolves instead of flipping
# randomly every 4s re-election. ──
var leader_traits: Dictionary = {
	"aggression": 0.5,   # higher = raids more often, prefers grudge targets
	"greed":      0.5,   # higher = hoards food before recruiting/building
	"honor":      0.5,   # higher = grudges fade slower, holds them longer
	"paranoia":   0.5,   # higher = treats neutral tribes as threats sooner
}

# ── CROSS-TRIBE OPINIONS — how this tribe feels about every other tribe
# (keyed by tribe_name, since object refs go stale when a tribe is freed)
# and specifically about the player. Grudges drive raid target selection
# (Tribemanager._resolve_war_round) and decay slowly over time unless the
# leader is high-honor (holds grudges longer). ──
var opinions: Dictionary = {}    # tribe_name -> grudge float (0 = neutral, 1 = blood feud)
var player_opinion: float = 0.0  # -1 hostile .. +1 friendly, ripples from other tribes' fates

func setup(nm: String, col: Color, arch: String, p_size: int, mgr) -> void:
	tribe_name = nm
	color = col
	archetype = arch
	manager = mgr
	member_count = p_size
	camp_hp = 45.0 + p_size * 8.0
	stockpile_hp = 30.0 + p_size * 6.0
	stockpile_max_hp = stockpile_hp
	strength = 30 + p_size * 10
	food = 16   # enough for an early growth tick almost immediately — a clan
				# that's meant to steadily grow and go raiding shouldn't spend
				# its first couple minutes just earning the right to grow
	# every clan starts with a resource pool of its own — a wood stockpile
	# (usable immediately, no physical presence needed) and a grove of trees
	# right beside camp. The wood stockpile is granted here; the trees are
	# physical nodes and are spawned later in _ensure_spawned(), not here —
	# see that comment below for why.
	wood = 24 + p_size * 6
	_roll_leader_traits()
	brain = Spikeling.new()
	brain.load_from_text(BRAIN)
	_build()
	# member roster spawn (and the resource grove) is DEFERRED — see
	# _ensure_spawned(), triggered by _tick_lod() once the player is
	# actually close enough to matter. At 1000 tribes, eagerly instantiating
	# every tribe's full member roster AND a grove of trees here would mean
	# tens of thousands of nodes — and just as many freshly-allocated
	# materials — built synchronously in a single frame at boot, which is
	# almost certainly what was tripping a Vulkan "uniforms never supplied"
	# error and a visible hitch/black-frame right at startup. The totem/camp/
	# stockpile (visible from a distance as "a tribe exists here") still
	# builds immediately above; only the individual walking-around members
	# and the tree grove wait.
	_refresh_label()

var _spawned: bool = false

func _ensure_spawned() -> void:
	if _spawned:
		return
	_spawned = true
	_spawn_npcs()
	_spawn_resource_grove()

# a visible pool of resources right next to camp from the moment the tribe
# is placed — a small grove of trees just outside the palisade line, not
# clear across the map. Doesn't (yet) feed an NPC wood-chopping job — wood
# itself comes from the starting pool granted in setup() — but it's a real,
# raidable resource sitting beside every camp, and the obvious hook for that
# job later.
func _spawn_resource_grove() -> void:
	var count := randi_range(4, 7)
	for i in range(count):
		var ang := randf() * TAU
		var r := territory_radius * randf_range(0.75, 1.15)
		var pos := global_position + Vector3(cos(ang) * r, 0.0, sin(ang) * r)
		var t = StaticBody3D.new()
		t.set_script(load("res://tree.gd"))
		get_parent().add_child(t)
		t.global_position = pos

# keeps a spawned-in camp from sitting next to a picked-clean wasteland —
# the global ecology tick (Tribemanager._ecology_tick) replenishes resources
# map-wide on a slow, even pace with no idea a SPECIFIC camp is starved.
# This checks each camp's own immediate surroundings on a much faster
# cadence and, if any resource type is scarce nearby, drops a fresh one in
# close — only runs once the tribe is actually spawned in (LOD), so it's
# not extra cost for camps nobody's near.
var _resource_check_accum: float = 0.0
const LOCAL_RESOURCE_INTERVAL := 4.0
const LOCAL_RESOURCE_MIN := 2

func _tick_local_resources(delta: float) -> void:
	if not _spawned:
		return
	_resource_check_accum -= delta
	if _resource_check_accum > 0.0:
		return
	_resource_check_accum = LOCAL_RESOURCE_INTERVAL
	var radius := territory_radius * 1.8

	var near_trees := 0
	for t in get_tree().get_nodes_in_group("tree"):
		var tn := t as Node3D
		if tn and is_instance_valid(tn) and global_position.distance_to(tn.global_position) <= radius:
			near_trees += 1
			if near_trees >= LOCAL_RESOURCE_MIN:
				break
	if near_trees < LOCAL_RESOURCE_MIN:
		var tr = StaticBody3D.new()
		tr.set_script(load("res://tree.gd"))
		get_parent().add_child(tr)
		tr.global_position = _local_resource_spot(radius)

	var near_food := 0
	for f in get_tree().get_nodes_in_group("food_source"):
		var fn := f as Node3D
		if fn and is_instance_valid(fn) and global_position.distance_to(fn.global_position) <= radius:
			near_food += 1
			if near_food >= LOCAL_RESOURCE_MIN:
				break
	if near_food < LOCAL_RESOURCE_MIN:
		var b = Node3D.new()
		b.set_script(load("res://food_source.gd"))
		get_parent().add_child(b)
		b.global_position = _local_resource_spot(radius)

	var near_animals := 0
	for a in get_tree().get_nodes_in_group("animal"):
		var an := a as Node3D
		if an and is_instance_valid(an) and global_position.distance_to(an.global_position) <= radius:
			near_animals += 1
			if near_animals >= LOCAL_RESOURCE_MIN:
				break
	if near_animals < LOCAL_RESOURCE_MIN and manager and manager.has_method("_spawn_animal"):
		manager._spawn_animal(_local_resource_spot(radius))

func _local_resource_spot(radius: float) -> Vector3:
	var ang := randf() * TAU
	var r := radius * randf_range(0.5, 0.95)
	return global_position + Vector3(cos(ang) * r, 0.0, sin(ang) * r)

func _roll_leader_traits() -> void:
	var bias: Dictionary = TribeRegistry.get_archetype(archetype).get("traits", {})
	for k in leader_traits.keys():
		var v: float = 0.5 + randf_range(-0.2, 0.2) + float(bias.get(k, 0.0))
		leader_traits[k] = clampf(v, 0.05, 0.95)

func grudge_toward(other_name: String) -> float:
	return float(opinions.get(other_name, 0.0))

func add_grudge(other_name: String, amount: float) -> void:
	opinions[other_name] = clampf(grudge_toward(other_name) + amount, 0.0, 1.0)

# grudges and your reputation here both fade back toward neutral over time —
# otherwise the world ratchets into permanent total war the longer a game
# runs. A high-honor leader holds grudges longer (slower decay); paranoia
# isn't involved here, just honor's "we don't forget, but we're not petty
# forever either" character.
const OPINION_DECAY_RATE := 0.01   # per second, at honor = 0.5 (the default)
func _decay_opinions(delta: float) -> void:
	var honor: float = float(leader_traits.get("honor", 0.5))
	var rate: float = OPINION_DECAY_RATE * (1.5 - honor)   # higher honor = slower decay
	for k in opinions.keys():
		opinions[k] = move_toward(float(opinions[k]), 0.0, rate * delta)
	player_opinion = move_toward(player_opinion, 0.0, rate * delta * 0.6)

func _build() -> void:
	# the totem: a banner the whole camp rallies behind
	var pole := MeshInstance3D.new()
	var pm := CylinderMesh.new()
	pm.top_radius = 0.08
	pm.bottom_radius = 0.1
	pm.height = 3.2
	pole.mesh = pm
	pole.position = Vector3(0, 1.6, 0)
	var pmat := StandardMaterial3D.new()
	pmat.albedo_color = Color(0.4, 0.3, 0.2)
	pole.material_override = pmat
	add_child(pole)

	var banner := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(1.4, 1.0, 0.06)
	banner.mesh = bm
	banner.position = Vector3(0, 2.6, 0)
	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = color
	banner.material_override = bmat
	add_child(banner)

	var col := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 0.4
	shape.height = 3.2
	col.shape = shape
	col.position = Vector3(0, 1.6, 0)
	var body := StaticBody3D.new()
	body.add_child(col)
	body.add_to_group("camp_core")
	body.set_meta("tribe", self)
	add_child(body)

	_totem_label = Label3D.new()
	_totem_label.position = Vector3(0, 4.0, 0)
	_totem_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_totem_label.font_size = 32
	add_child(_totem_label)

	_build_stockpile()

# every camp has its own supply pile, just like the player's — visible proof
# the tribe's food/clubs are real, physical things sitting in the world
func _build_stockpile() -> void:
	var base := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(2.4, 0.25, 2.4)
	base.mesh = bm
	base.position = Vector3(2.8, 0.125, 0)
	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = Color(0.40, 0.28, 0.16)
	base.material_override = bmat
	add_child(base)

	_stockpile_pile = MeshInstance3D.new()
	var pm := BoxMesh.new()
	pm.size = Vector3(1.6, 0.8, 1.6)
	_stockpile_pile.mesh = pm
	_stockpile_pile.position = Vector3(2.8, 0.65, 0)
	var pmat := StandardMaterial3D.new()
	pmat.albedo_color = Color(0.85, 0.7, 0.35)
	_stockpile_pile.material_override = pmat
	add_child(_stockpile_pile)

	_stockpile_clubs = MeshInstance3D.new()
	var cm := BoxMesh.new()
	cm.size = Vector3(0.22, 0.22, 1.0)
	_stockpile_clubs.mesh = cm
	_stockpile_clubs.position = Vector3(3.7, 0.5, 0)
	var cmat := StandardMaterial3D.new()
	cmat.albedo_color = Color(0.45, 0.30, 0.15)
	_stockpile_clubs.material_override = cmat
	add_child(_stockpile_clubs)

func _update_stockpile_visual() -> void:
	if _stockpile_pile:
		var s := clampf(float(food) / 25.0, 0.1, 2.8)
		_stockpile_pile.scale = Vector3(1.0, s, 1.0)
		_stockpile_pile.visible = food > 0 and not stockpile_destroyed
	if _stockpile_clubs:
		_stockpile_clubs.visible = clubs > 0 and not stockpile_destroyed

func _spawn_npcs() -> void:
	for i in range(member_count):
		_make_npc()

func _make_npc() -> Node:
	# while still unspawned (player hasn't come near, see _ensure_spawned),
	# growth/recruiting stay purely abstract — member_count rises but no
	# real node is created until the tribe actually gets spawned in.
	if not _spawned:
		return null
	var n = CharacterBody3D.new()
	n.set_script(load("res://npc.gd"))
	add_child(n)
	var ang := randf() * TAU
	var r := randf() * territory_radius * 0.22   # central courtyard, clear of huts
	n.position = Vector3(cos(ang) * r, 1.0, sin(ang) * r)
	n.setup(self, global_position, territory_radius, color)
	npcs.append(n)
	return n

# the totem takes a beating — from the player, or from a rival war party —
# but the totem is just where the fight happens. The blow is routed to the
# camp's actual structures: every standing teepee falls first (one at a
# time), then the stockpile. Only once BOTH are gone does the clan fall.
func damage_camp(d: float, by_player: bool, attacker = null) -> void:
	if defeated:
		return
	camp_hp = maxf(0.0, camp_hp - d * 0.4)   # cosmetic "under siege" stat only
	_refresh_label()

	while not teepees.is_empty() and not is_instance_valid(teepees[0]):
		teepees.pop_front()   # drop stale refs (freed some other way)
	if not teepees.is_empty():
		var target = teepees[0]
		target.take_damage(d, attacker)
		_refresh_label()
		return

	if not stockpile_destroyed:
		stockpile_hp -= d
		if stockpile_hp <= 0.0:
			stockpile_hp = 0.0
			stockpile_destroyed = true
			food = 0
			clubs = 0
		_update_stockpile_visual()
		_refresh_label()
		if not stockpile_destroyed:
			return   # stockpile took the hit but survived — fight continues

	# every teepee AND the stockpile are gone — the clan falls
	var fallen_name := tribe_name   # capture before defeat()/conquer() can free this node
	if by_player:
		if manager and manager.has_method("ripple_player_reputation"):
			manager.ripple_player_reputation(fallen_name)
		var j := conquer(manager)
		if manager and manager.has_method("notify"):
			manager.notify("The %s camp falls! %d of their kin (and fallen) join you." % [fallen_name, j])
	elif attacker != null and is_instance_valid(attacker) and attacker.has_method("absorb_rival"):
		if manager and manager.has_method("_ripple_opinions_on_defeat"):
			manager._ripple_opinions_on_defeat(attacker, fallen_name)
		attacker.absorb_rival(self)
		defeat()
	else:
		defeat()

# a teepee we own was knocked down elsewhere (shouldn't happen outside
# damage_camp, but keep the roster honest either way)
func on_teepee_lost(t) -> void:
	teepees.erase(t)

func on_block_lost(b) -> void:
	blocks.erase(b)

# ── muster a coordinated war party to march on a rival camp ──
const WAR_FORMATION := "phalanx"   # war parties always march in a shield wall

func muster_war_party(target, size: int) -> int:
	if defeated or target == null or not is_instance_valid(target):
		return 0
	war_party.clear()
	at_war_with = target
	var facing: Vector3 = (target.global_position - global_position)
	# the elected leader marches first — they earned the crown by being the
	# most productive member, and now they're the one actually commanding
	# the party on the ground, not just decorating the roster
	if leader != null and is_instance_valid(leader) and not leader.get("at_war") and leader.has_method("set_war_order"):
		war_party.append(leader)
	for n in npcs:
		if war_party.size() >= size:
			break
		if n == leader or not is_instance_valid(n) or n.get("at_war"):
			continue
		if n.has_method("set_war_order"):
			war_party.append(n)
	var total := war_party.size()
	for i in range(total):
		var n = war_party[i]
		var off := formation_offset(i, total, WAR_FORMATION, facing)
		n.set_war_order(target, target.global_position, off)
	return total

# same formation math as Tribemanager.formation_offset — duplicated rather
# than shared because rival AI tribes have no reference to the player's
# manager (and shouldn't; they're a fully independent faction)
func formation_offset(index: int, total: int, kind: String, facing: Vector3) -> Vector3:
	if kind == "loose" or total <= 1:
		return Vector3.ZERO
	var f := facing
	f.y = 0.0
	if f.length() < 0.01:
		f = Vector3(0, 0, -1)
	f = f.normalized()
	var right := f.rotated(Vector3.UP, PI / 2.0)
	var cols: int = maxi(1, int(ceil(sqrt(float(total)))))
	match kind:
		"phalanx":
			var row := int(index / cols)
			var col := index % cols
			var sp := 1.7
			return right * (col - (cols - 1) / 2.0) * sp - f * row * sp
		"testudo":
			var row2 := int(index / cols)
			var col2 := index % cols
			var sp2 := 1.05
			return right * (col2 - (cols - 1) / 2.0) * sp2 - f * row2 * sp2
		"wedge":
			var row3 := 0
			var i := index
			while i >= row3 + 1:
				i -= (row3 + 1)
				row3 += 1
			var sp3 := 1.7
			return right * (i - row3 / 2.0) * sp3 - f * row3 * sp3 * 0.9
	return Vector3.ZERO

func recall_war_party() -> void:
	for n in war_party:
		if is_instance_valid(n) and n.has_method("end_war"):
			n.end_war()
	war_party.clear()
	at_war_with = null

# spawn a fresh raider at the edge of the player's land and send it at the base
# (used by the last empire to lay siege — they appear close so they actually arrive)
func spawn_siege_raider(base_pos: Vector3) -> void:
	if defeated:
		return
	var n = CharacterBody3D.new()
	n.set_script(load("res://npc.gd"))
	add_child(n)
	n.setup(self, global_position, territory_radius, color)   # home stays our camp
	var ang := randf() * TAU
	var p := base_pos + Vector3(cos(ang), 0, sin(ang)) * randf_range(26.0, 34.0)
	p.y = 1.0
	n.global_position = p
	npcs.append(n)
	member_count += 1
	if n.has_method("set_raid_player"):
		n.set_raid_player(base_pos)

# everyone who EVER belonged here — living and dead — swears to the conqueror
func conquer(mgr) -> int:
	var count := npcs.size() + deaths
	var joined := 0
	if mgr and mgr.has_method("absorb_members"):
		joined = mgr.absorb_members(count, global_position)
	# sacking the camp loots whatever material culture it had stockpiled —
	# capture before defeat() frees this node
	if mgr and material_stock > 0 and mgr.has_method("add_special_material"):
		mgr.add_special_material(material_name(), material_stock)
	defeat()
	return joined

# a defeated rival (player or AI) surrenders a member at this spot — used
# when their tribe is dismantled (Tribemanager.dismantle_tribe). Capped by
# member_cap like every other path that grows the roster.
func recruit_at(pos: Vector3) -> bool:
	if defeated or member_count >= member_cap:
		return false
	var n := _make_npc()
	if n != null:
		(n as Node3D).global_position = pos
	member_count += 1
	strength += 4
	_refresh_label()
	return true

# NPCs bring food/skins home; skins harden the tribe (better tools = strength)
func deposit(f: int, s: int) -> void:
	if stockpile_destroyed:
		return   # nowhere left to put it — the stockpile is rubble
	food += f
	if s > 0:
		strength += s * 2
		_refresh_label()

func add_club() -> void:
	if stockpile_destroyed:
		return
	clubs += 1

func has_club() -> bool:
	return clubs > 0

# a thrower gives up their club whether the throw lands or not — same rule
# as the player's throw (Tribemanager.consume_club)
func use_club() -> bool:
	if clubs <= 0:
		return false
	clubs -= 1
	return true

func wants_food() -> bool:
	return food < member_count * 4

func can_recruit() -> bool:
	return not defeated and member_count < member_cap

# convert a neutral wanderer into one of our own
func recruit(neutral_npc) -> void:
	if defeated or member_count >= member_cap or neutral_npc == null or not is_instance_valid(neutral_npc):
		return
	var pos: Vector3 = neutral_npc.global_position
	neutral_npc.queue_free()
	var n := _make_npc()
	if n != null:
		(n as Node3D).global_position = pos
	member_count += 1
	strength += 8
	material_stock = mini(MATERIAL_STOCK_CAP, material_stock + 1)
	_refresh_label()

# the tribe's actual growth tick — called periodically from _process().
# Prefers recruiting a real neutral wanderer if one strayed close enough —
# but a member has to physically WALK there and reach them first (handled
# by _tick_recruiting, same pattern as the builder system); recruiting used
# to just happen instantly by tribe fiat regardless of distance. Otherwise
# the population grows on its own from food surplus (a "birth"). Either way
# member_count goes up over time, capped at member_cap.
var _recruiter = null         # the NPC currently walking to reach a wanderer
var _recruit_target = null    # the wanderer they're chasing down
var _recruit_check_accum: float = 0.0
func _grow() -> void:
	if defeated or member_count >= member_cap:
		return

	# Clear stale recruiter if they finished or became invalid
	if _recruiter != null:
		if not is_instance_valid(_recruiter) or not _recruiter.get("building"):
			_recruiter = null
			_recruit_target = null

	if _recruiter != null:
		return  # Still actively recruiting

	var nearby_neutral: Node = _nearest_neutral_wanderer()
	if nearby_neutral != null:
		var rec: Node = _pick_builder()
		if rec != null:
			_recruiter = rec
			_recruit_target = nearby_neutral
			rec.assign_build((nearby_neutral as Node3D).global_position)
		return

	# a greedy leader hoards food rather than spending it on a birth — the
	# tribe still grows, just more cautiously, banking a bigger surplus first.
	# Tuned down from the original (member_count*3+6)*(1+greed*0.6): with a
	# typical 2-4 starting members and only 10 starting food, the OLD upkeep
	# (~15-19) was higher than the tribe could ever afford on its first
	# growth tick, so "steady growth" actually meant "stalled until enough
	# successful forage trips happened" — not the reliable, visible growth
	# curve a raiding, castle-building clan should have.
	var greed: float = float(leader_traits.get("greed", 0.5))
	var upkeep: int = int((member_count * 2 + 4) * (1.0 + greed * 0.4))
	if food >= upkeep:
		food -= upkeep
		_make_npc()
		member_count += 1
		strength += 5
		material_stock = mini(MATERIAL_STOCK_CAP, material_stock + 1)
		_refresh_label()

# checked every frame (lightly throttled) — keeps the recruiter chasing the
# wanderer as they wander, and finalizes the recruitment once actually close
func _tick_recruiting(delta: float) -> void:
	if _recruiter == null or not is_instance_valid(_recruiter) or not _recruiter.get("building"):
		_recruiter = null
		_recruit_target = null
		return
	_recruit_check_accum -= delta
	if _recruit_check_accum > 0.0:
		return
	_recruit_check_accum = 0.3
	var w = _recruit_target
	if w == null or not is_instance_valid(w):
		_recruiter.cancel_build()
		_recruiter = null
		_recruit_target = null
		return
	var rpos: Vector3 = (_recruiter as Node3D).global_position
	var wpos: Vector3 = (w as Node3D).global_position
	if rpos.distance_to(wpos) <= 1.8:
		_recruiter.cancel_build()
		recruit(w)
		_recruiter = null
		_recruit_target = null
	else:
		_recruiter.assign_build(wpos)   # keep chasing as they wander off

func _nearest_neutral_wanderer() -> Node:
	var best: Node = null
	var bd := territory_radius * 2.2   # only reach out to reasonably nearby wanderers
	for o in SpatialGrid.query(global_position, bd, "neutral"):
		var n := o as Node3D
		if n == null or not is_instance_valid(n):
			continue
		var d := global_position.distance_to(n.global_position)
		if d < bd:
			bd = d
			best = n
	return best

func _process(delta: float) -> void:
	if defeated:
		return

	_tick_hive_brain(delta)
	_tick_lod(delta)

	# inner-tribe politics: the most PRODUCTIVE member becomes the leader
	_leader_accum += delta
	if _leader_accum >= 4.0:
		_leader_accum = 0.0
		_elect_leader()

	# the tribe actively grows: recruits any neutral wanderer that strays
	# close, or — failing that — gains a new member from food surplus. This
	# is what makes "tribes are recruiting and growing" actually true; before
	# this, member_count never changed except by conquest.
	_growth_accum += delta
	if _growth_accum >= 10.0:
		_growth_accum = randf_range(8.0, 14.0)
		_grow()
	_tick_recruiting(delta)

	# a builder emerges and raises the palisade once the tribe has utility
	if not built and member_count >= 3 and food >= 6:
		_build_palisade(delta)

	_tick_local_resources(delta)
	_decay_opinions(delta)

	if member_count <= 0 and npcs.is_empty():
		abandoned = true
	_refresh_label()
	_update_stockpile_visual()

# step the shared hive-mind brain ONCE for the whole tribe (not once per
# member — that's the bug this whole change fixes). Senses the nearest
# threat to ANY member or the totem; members read hive_alarmed to decide
# whether to flee, instead of running their own copy of this network.
func _tick_hive_brain(delta: float) -> void:
	if brain == null:
		return
	# Skip neural work entirely for tribes the player can't see or interact with.
	# Drain the accumulator so there's no burst of catch-up ticks on LOD re-entry.
	if _lod_tier == 2:
		_brain_tick_accum = 0.0
		return
	_brain_tick_accum += delta
	var interval := 1.0 / BRAIN_TICK_HZ
	while _brain_tick_accum >= interval:
		_brain_tick_accum -= interval
		var p := get_tree().get_first_node_in_group("player")
		if p and is_instance_valid(p):
			var bd := global_position.distance_to(p.global_position)
			var nearby_support := 0
			for n in npcs:
				if is_instance_valid(n):
					var d: float = (n as Node3D).global_position.distance_to(p.global_position)
					if d < bd:
						bd = d
					if d < 10.0:
						nearby_support += 1
			if bd < 6.0:
				# better judgment, not blind instinct: a lone member near the
				# player is genuinely scared (full stimulus), but with a real
				# numbers advantage nearby the tribe is emboldened instead —
				# confidence dampens the fear stimulus so Alarm doesn't fire
				# and they fall through to the territorial-defense/skirmish
				# logic and actually fight, instead of fleeing 3-on-1 fights
				# they'd obviously win.
				var confidence: float = clampf(float(nearby_support) / 3.0, 0.0, 0.85)
				var stim: float = (45.0 + 45.0 * (1.0 - bd / 6.0)) * (1.0 - confidence)
				brain.stimulate("SeeDanger", stim)
		brain.stimulate("Calm", 1.0)
		var fired: Array = brain.step()
		hive_alarmed = "Alarm" in fired

# distance-based tier check — see LOD comment above. A simple periodic
# poll rather than per-frame: distance doesn't change fast enough to need
# more, and this is the entire CPU cost of the whole tiering system.
func _tick_lod(delta: float) -> void:
	_lod_accum -= delta
	if _lod_accum > 0.0:
		return
	_lod_accum = LOD_CHECK_INTERVAL
	var p := get_tree().get_first_node_in_group("player")
	if p == null or not is_instance_valid(p):
		return
	var d := global_position.distance_to((p as Node3D).global_position)
	var tier := 2
	if d < LOD_NEAR_DIST:
		tier = 0
	elif d < LOD_MID_DIST:
		tier = 1
	if tier < 2:
		_ensure_spawned()

	# RENDER LOD — the simulation LOD above stops far tribes from running
	# AI, but it never stopped them from being DRAWN: the totem, stockpile,
	# every fence/teepee/block, and every member are all children of this
	# node, so they were rendering every frame regardless of distance. At
	# 1000 tribes that's the actual frame-time killer (12fps), far more
	# than the simulation cost ever was. Hiding the whole node for FAR
	# tribes drops their entire subtree from the render — cheap, since
	# Node3D.visible=false already removes children from the draw list,
	# no need to touch each mesh individually.
	visible = (tier != 2)
	_lod_tier = tier

	if not _spawned:
		return
	for n in npcs:
		if is_instance_valid(n) and n.has_method("set_lod"):
			n.set_lod(tier)

# raises the camp's fence/teepee/block plan for real — builder NPCs are
# assigned and must physically WALK to each waypoint before anything gets
# placed. A SQUAD of builders works the plan in parallel (not just one at a
# time) — with ~50 segments in a full castle plan, a single sequential
# builder made the whole thing crawl badly enough that blocks effectively
# never showed up in a normal session. Each entry: {"npc": Node3D, "i": int}.
const MAX_BUILDERS := 4
var _builders: Array = []
var _claimed: Dictionary = {}   # segment index -> true, while a builder is en route

func _build_palisade(delta: float) -> void:
	if _fence_plan.is_empty():
		_plan_fences()
	if _builders.is_empty() and _claimed.size() >= _fence_plan.size():
		built = true
		return

	_fence_accum -= delta
	if _fence_accum > 0.0:
		return
	_fence_accum = 0.3   # how often we re-check builder progress / hand out new work

	# drop workers who died, were called to war, or otherwise lost their job
	for w in _builders.duplicate():
		var n = w["npc"]
		if n == null or not is_instance_valid(n) or n.get("at_war"):
			_claimed.erase(w["i"])
			_builders.erase(w)

	# top up the squad with whoever's free, assigning each the next open segment
	while _builders.size() < MAX_BUILDERS:
		var idx := _next_open_segment()
		if idx == -1:
			break
		var n := _pick_builder()
		if n == null:
			break
		_claimed[idx] = true
		n.assign_build(global_position + (_fence_plan[idx]["pos"] as Vector3))
		_builders.append({"npc": n, "i": idx})

	# advance anyone who's arrived — HORIZONTAL distance only. Block segments
	# can sit at y=3.0 (the second course, stacked on the first); a builder
	# walking on the ground can never close a 2-unit VERTICAL gap, so a full
	# 3D distance_to() here would leave that worker waiting at the right XZ
	# spot forever — permanently occupying a builder slot and looking, from
	# the outside, exactly like "NPCs frozen, nothing gets built."
	for w in _builders.duplicate():
		var n = w["npc"]
		var idx: int = w["i"]
		var seg: Dictionary = _fence_plan[idx]
		var target: Vector3 = global_position + (seg["pos"] as Vector3)
		var gp: Vector3 = (n as Node3D).global_position
		if Vector2(gp.x - target.x, gp.z - target.z).length() > 1.7:
			continue   # still walking there
		_place_segment(seg, target)
		n.cancel_build()
		_builders.erase(w)

func _next_open_segment() -> int:
	for i in range(_fence_plan.size()):
		if not _claimed.has(i):
			return i
	return -1

func _place_segment(seg: Dictionary, target: Vector3) -> void:
	var kind: String = seg.get("kind", "fence")
	if kind == "teepee":
		# untyped: t's script (and so its owner_tribe property) is attached
		# AFTER .new(), so a `:=` (StaticBody3D-typed) var can't see it — see
		# the same fix used for world_tribe spawning in Tribemanager.gd
		var t = StaticBody3D.new()
		t.set_script(load("res://teepee.gd"))
		add_child(t)
		t.global_position = target
		t.owner_tribe = self
		teepees.append(t)
		built_teepee_count += 1
	elif kind == "block":
		if wood < 1:
			return   # out of wood — segment stays claimed-but-unbuilt, harmless
		wood -= 1
		var b = StaticBody3D.new()
		b.set_script(load("res://block.gd"))
		add_child(b)
		b.global_position = BlockScript.snap(target)
		b.owner_tribe = self
		blocks.append(b)
	else:
		var f := StaticBody3D.new()
		f.set_script(load("res://fence.gd"))
		add_child(f)
		f.global_position = target
		f.rotation.y = float(seg["yaw"])

func _pick_builder() -> Node3D:
	for n in npcs:
		if is_instance_valid(n) and not n.get("at_war") and not n.get("building"):
			var already := false
			for w in _builders:
				if w["npc"] == n:
					already = true
					break
			if not already:
				return n
	return null

# true everywhere a ring of segments gets built around camp (radians of
# angular clearance to either side of a gate angle counts as "the gate")
const GATE_HALF_WIDTH := 0.5

func _near_gate(ang: float, gate_angles: Array) -> bool:
	for ga in gate_angles:
		if absf(wrapf(ang - ga, -PI, PI)) <= GATE_HALF_WIDTH:
			return true
	return false

# GRID PATTERN — a literal square ring of block cells on the shared
# block.gd grid (SIZE units), two courses tall, instead of blocks scattered
# along a circle/curve at arbitrary float positions. Builders (the squad in
# _build_palisade) walk to and place at real grid coordinates (gx,gz)*SIZE,
# so the finished wall is a straight-edged square a player actually reads
# as "built on a grid." gate_angles (shared with the fence ring) carve
# openings out of the square by world angle, so entrances still align
# through both rings even though their shapes differ.
func _grid_square_wall(half_size: float, gate_angles: Array) -> Array:
	var segs: Array = []
	var size: float = BlockScript.SIZE
	var n: int = maxi(2, int(round(half_size / size)))
	for gx in range(-n, n + 1):
		for gz in range(-n, n + 1):
			if abs(gx) != n and abs(gz) != n:
				continue   # interior cell — only the perimeter is a wall
			var x := float(gx) * size
			var z := float(gz) * size
			if _near_gate(atan2(z, x), gate_angles):
				continue
			segs.append({"kind": "block", "pos": Vector3(x, 1.0, z)})
			segs.append({"kind": "block", "pos": Vector3(x, 3.0, z)})
	return segs

func _plan_fences() -> void:
	var r := territory_radius * 0.6
	var fence_segs: Array = []
	var teepee_segs: Array = []
	var block_segs: Array = []

	# pick gate ANGLES once, shared by every ring (fence + block wall) so
	# the openings radially line up into one real corridor all the way
	# through the castle. Previously each ring chose its own gate pattern
	# independently by segment INDEX, with different segment counts per
	# ring — a gap in the fence ring usually had no matching gap in the
	# block wall beyond it, so the "entrance" didn't actually go anywhere.
	var gate_count := 2
	var gate_angles: Array = []
	for g in range(gate_count):
		gate_angles.append(TAU * float(g) / float(gate_count))

	var count := 14
	for i in range(count):
		var ang := TAU * float(i) / float(count)
		if _near_gate(ang, gate_angles):
			continue
		fence_segs.append({
			"kind": "fence",
			"pos": Vector3(cos(ang) * r, 0.0, sin(ang) * r),
			"yaw": ang + PI * 0.5,
		})
	# a few teepees inside the fence line — homes for the camp
	var teepee_count := 3
	var tr := r * 0.55
	for i in range(teepee_count):
		var ang2 := TAU * float(i) / float(teepee_count) + (TAU / float(teepee_count) * 0.5)
		teepee_segs.append({
			"kind": "teepee",
			"pos": Vector3(cos(ang2) * tr, 0.0, sin(ang2) * tr),
			"yaw": 0.0,
		})
	# a block (block.gd) outer wall, two courses tall, beyond the fence
	# line — same "castle" treatment Tribemanager.gd gives the player's own
	# camp. Gated by wood, so a poor/young tribe just gets the fence ring.
	#
	# GRID PATTERN — not a circle, not a curve: a literal square ring on the
	# block grid (block.gd.SIZE). Builders walk to and place blocks at
	# actual grid cells (gx,gz)*SIZE, so the squad collectively raises a
	# straight-walled, square castle instead of scattering blocks at
	# arbitrary float positions. Gates are cut from the grid sides at the
	# same world angle as the fence ring's gates so the openings still align.
	block_segs = _grid_square_wall(r * 1.4, gate_angles)

	# interleave rather than append-in-order — with ~50 total segments built
	# one at a time by a single builder, putting all the blocks dead last
	# meant the actual "castle" walls never appeared until the (slower)
	# fence+teepee ring was 100% finished first. Round-robin so fence,
	# teepee, and block construction all visibly start together.
	var i1 := 0; var i2 := 0; var i3 := 0
	while i1 < fence_segs.size() or i2 < teepee_segs.size() or i3 < block_segs.size():
		if i1 < fence_segs.size():
			_fence_plan.append(fence_segs[i1]); i1 += 1
		if i2 < teepee_segs.size():
			_fence_plan.append(teepee_segs[i2]); i2 += 1
		for _k in range(2):   # blocks are the bulk of the plan — let 2 through per round
			if i3 < block_segs.size():
				_fence_plan.append(block_segs[i3]); i3 += 1

# ── AI-vs-AI conquest: fold a beaten rival's might into our own (NOT the player's
# clan — that path goes through TribeManager.absorb_members instead) ──
func absorb_rival(loser) -> void:
	if defeated or loser == null or not is_instance_valid(loser):
		return
	strength += int(maxf(8.0, loser.strength * 0.5))
	food += int(max(0, loser.food))
	# a couple of the conquered swell our ranks and march home with us
	for i in range(2):
		if member_count < member_cap:
			_make_npc()
			member_count += 1
	camp_hp = minf(camp_hp + 20.0, 220.0)
	_refresh_label()

# an empire's final strength swells as it consolidates the world
func fortify(amount: int) -> void:
	strength += amount
	camp_hp = minf(camp_hp + 6.0, 260.0)
	_refresh_label()

func weaken(amount: int) -> void:
	strength = maxi(0, strength - amount)
	_refresh_label()

func discover() -> void:
	discovered = true
	_refresh_label()

func defeat() -> void:
	defeated = true
	for n in npcs:
		if is_instance_valid(n):
			n.queue_free()
	npcs.clear()
	queue_free()

# a member fell — the tribe weakens and remembers
func on_member_died(n) -> void:
	npcs.erase(n)
	member_count = maxi(0, member_count - 1)
	deaths += 1
	if leader == n:
		leader = null

# ── leadership: re-elect every 4s from whoever has the highest contrib ──
func _elect_leader() -> void:
	var best = null
	var best_score := -1
	for n in npcs:
		if not is_instance_valid(n):
			continue
		var sc: int = int(n.contrib)
		if sc > best_score:
			best_score = sc
			best = n
	var changed: bool = best != leader
	leader = best
	leader_score = max(0, best_score)
	if changed:
		# a new leader nudges the tribe's character rather than rerolling it
		# outright — a single re-election shouldn't flip a tribe's whole
		# personality, but leadership turnover over a long game should
		# visibly shift it
		for k in leader_traits.keys():
			var v: float = float(leader_traits[k]) + randf_range(-0.15, 0.15)
			leader_traits[k] = clampf(v, 0.05, 0.95)
	_refresh_label()
	# mark the champion so you can spot who leads
	for n in npcs:
		if is_instance_valid(n) and n.has_method("set_champion"):
			n.set_champion(n == leader)

func _refresh_label() -> void:
	if _totem_label == null:
		return
	if abandoned:
		_totem_label.text = "%s\n(abandoned — smash totem to claim)" % tribe_name
	elif discovered:
		var champ := "  ★champion %d" % leader_score if leader_score > 0 else ""
		var cmd := ""
		if at_war_with != null and is_instance_valid(at_war_with) and not war_party.is_empty():
			var foe_name: String = at_war_with.tribe_name if "tribe_name" in at_war_with else "a rival"
			cmd = "\n⚔ leader commands %d to war on %s" % [war_party.size(), foe_name]
		var stance := ""
		if player_opinion > 0.3: stance = "  ☺ favors you"
		elif player_opinion < -0.3: stance = "  ☹ resents you"
		var siege := ""
		if teepees.size() < built_teepee_count or stockpile_destroyed:
			siege = "\n⚒ %d/%d teepees standing · stockpile %s" % [
				teepees.size(), built_teepee_count,
				"DESTROYED" if stockpile_destroyed else "%d%%" % int(stockpile_hp / maxf(1.0, stockpile_max_hp) * 100.0)]
		_totem_label.text = "%s  [%d]\n%s · str %d · works %s (%d)%s%s%s%s" % [
			tribe_name, member_count, archetype, strength, material_name(), material_stock, champ, stance, cmd, siege]
	else:
		_totem_label.text = "%s\n(unscouted)" % tribe_name
