extends Node3D

# ─────────────────────────────────────────────────────────────────────────────
# TribeManager — turns a pile of tribesmen into a TRIBE, and runs the whole
# game loop on top of them:
#
#   • SPAWN a tribe of members, each with a different PERSONALITY (=different brain)
#   • ECONOMY: a shared FOOD/SKINS stockpile. Feeding costs food; gather/hunt
#     orders refill it. HUNGER drains food over time — let it hit zero and morale
#     rots, members defect, and your leadership can be challenged.
#   • LEADERSHIP: when enough members back you, you lead. Then you can RALLY the
#     whole tribe (hold R + 1/2/3) and RAID scouted rivals (hold R + 4).
#   • RIVALS: scouting reveals enemy camps you can raid for loot and converts.
#   • BRAIN VIEW: press B to see the live Spikeling brain of the nearest member.
#
# Controls:
#   E  feed nearest member (costs 1 food)      1/2/3  order nearest: gather/hunt/scout
#   hold R + 1/2/3  rally ALL                   hold R + 4  raid a scouted rival
#   B  toggle brain view                        Esc  free the mouse
# ─────────────────────────────────────────────────────────────────────────────

signal became_leader()

# ─────────────────────────────────────────────────────────────────────────────
# EXPORTS
# ─────────────────────────────────────────────────────────────────────────────
@export var leadership_threshold: int   = 3
@export var spawn_count: int            = 0      # you start with 1 loyal companion
@export var spawn_radius: float         = 7.0
@export var member_scene: PackedScene
@export var starting_food: int          = 16
@export var member_cap: int             = 20
@export var bush_count: int             = 28
@export var animal_count: int           = 20
@export var world_tribe_count: int      = 22
@export var neutral_count: int          = 12
@export var tree_count: int             = 1700
@export var war_interval: float         = 6.0
@export var dominion_grace: float       = 90.0

# ─────────────────────────────────────────────────────────────────────────────
# STATE
# ─────────────────────────────────────────────────────────────────────────────
var members: Array       = []
var world_tribes: Array  = []
var factions: Array      = []
var focus_tribe          = null
var selected_member      = null
var work_preset: int     = 0
var game_over: bool      = false
var won: bool            = false
var lost: bool           = false
var is_leader: bool      = false
var backers: int         = 0
var _loser_name: String  = ""
var _name_cursor: int    = 0

# economy / morale
var food: int       = 0
var materials: int  = 0
var clubs: int      = 0   # the SHARED tribe armory — tribemembers reserve/release
						  # from this for their own hunts (see reserve_club below)
var _clubs_out: int = 0
var player_holds_club: bool = false   # the player's OWN club — separate from the
									   # shared armory so a tribemember grabbing a
									   # club for a hunt can't make the player's
									   # own crafted club seem to vanish out from
									   # under them ("my club constantly disappears")
var wood: int       = 0
var unrest: float   = 0.0
var challenged: bool = false

# MATERIAL CULTURE — every tribe archetype works its own material, defined
# in res://tribes/<archetype>.tribe (see tribe_dsl.gd) and read via
# world_tribe.material_name()/material_stock; sacking a camp loots whatever
# they'd stockpiled. Spent forging a masterwork club — see
# craft_club()/player_club_material.
var materials_owned: Dictionary = {}   # material name -> count
var player_club_material: String = ""  # "" = plain club, else the masterwork material

func add_special_material(mat_name: String, amount: int) -> void:
	if amount <= 0:
		return
	materials_owned[mat_name] = int(materials_owned.get(mat_name, 0)) + amount
	_flash("Looted %d %s from the fallen camp! (forge a masterwork club with [C])" % [amount, mat_name])

# formation / perimeter
var formation_kind: String  = "loose"
var perimeter_radius: float = 16.0

# dogs
var dogs: Array       = []
var dogs_heel: bool   = false
var _dog_count: int   = 10
var _dog_spawn_cd: float = 30.0

# world scale
var game_scale: int  = Scale.STANDARD
var _started: bool   = false
var start_menu       = null
var _tribe_cap: int  = 16
var _start_size: int = 3
var fortress_built: bool = false   # set once an autonomous solo build run finishes
									# the whole fence_ring_plan() — see suggest_job()
									# and tribemember.gd's begin_build()/_build_step()

# war / dominion
var _dominion                    = null
var _dominion_timer: float       = 0.0
var _dominion_buff_accum: float  = 0.0
var _final_battle_triggered: bool = false
var _ai_raids: Array             = []

# accumulators
var _war_accum: float      = 0.0
var _faction_accum: float  = 0.0
var _respawn_accum: float  = 0.0
var _neutral_accum: float  = 0.0
var _ecology_accum: float  = 0.0
var _recruit_accum: float  = 0.0
var _siege_accum: float    = 0.0

# input
var _keys_down: Dictionary = {}

# flash notification
var _flash_text: String  = ""
var _flash_timer: float  = 0.0

# active player raid: {tribe, party, strength, timer, live}
var _raid: Dictionary = {}

# ─────────────────────────────────────────────────────────────────────────────
# CONSTANTS
# ─────────────────────────────────────────────────────────────────────────────
const STANDING_QUOTA := {"gather": 50, "wood": 10, "hunt": 20, "scout": 3, "recruit": 1, "guard": 1}
const SCOUT_RANGE    := 30.0
const CAMP_COST      := 15
const FENCE_COST     := 2
const TEEPEE_COST    := 6
const BLOCK_COST      := 1   # cheap — fortresses/mazes need many of these
const CLUB_COST      := 4
const BUILD_RANGE    := 45.0
var MAP_EXTENT       := 170.0   # scaled per-preset in _apply_scale — Massive needs
								 # far more room to actually spread 1000 tribes out
								 # (camp placement wants ~34 units of separation each)
var RESOURCE_EXTENT   := 110.0   # kept in lockstep with MAP_EXTENT in _apply_scale
								  # — trees/bushes/animals/wanderers must spread as
								  # far as tribes do, or large-MAP presets (Massive)
								  # spawn tribes in camps with nothing around them
const FACTION_RADIUS := 12.0
const DOG_POPULATION_MULT := 1.6

const COMPAT := {
	"Steady":   ["Steady", "Trusting", "Brave", "Wary"],
	"Trusting": ["Trusting", "Steady", "Brave"],
	"Brave":    ["Brave", "Steady", "Trusting"],
	"Wary":     ["Wary", "Steady"],
	"Greedy":   ["Greedy"],
}

const FACTION_NAMES  := ["Stonekin", "Emberfolk", "Brightband", "Greenkin", "Duskclan"]
const FACTION_COLORS := [
	Color(0.95, 0.45, 0.30), Color(0.40, 0.70, 1.0), Color(1.0, 0.85, 0.30),
	Color(0.45, 0.85, 0.45), Color(0.75, 0.55, 0.95),
]

const PERSONALITY_POOL := ["Steady", "Trusting", "Wary", "Brave", "Greedy"]
const ANIMAL_POOL      := ["Rabbit", "Rabbit", "Deer", "Deer", "Deer", "Boar"]
const MEMBER_NAMES := [
	"Ka", "Bo", "Tam", "Ru", "Sef", "Mok", "Wen", "Lir",
	"Dak", "Fenn", "Vel", "Orra", "Kin", "Zol", "Brae", "Cael",
]

const ARCHETYPES := [
	"Foragers", "Hunters", "Raiders", "Traders", "Nomads", "Warriors",
	"Fishers", "Herders", "Mystics", "Builders", "Wanderers", "Slavers",
]
const NAME_A := [
	"Stone", "Ash", "River", "Thorn", "Bone", "Cinder", "Frost",
	"Iron", "Moss", "Storm", "Dune", "Hollow", "Crow", "Salt", "Ember",
]
const NAME_B := ["clan", "pack", "kin", "horde", "tribe", "folk", "host", "band"]

const WARLIKE := {"Raiders": 1.7, "Warriors": 1.55, "Slavers": 1.4, "Hunters": 1.2}

const FORMATION_KINDS    := ["loose", "phalanx", "wedge", "testudo"]
const PERIMETER_PRESETS  := [10.0, 16.0, 24.0, 34.0]

# ─────────────────────────────────────────────────────────────────────────────
# GAME SCALE
# ─────────────────────────────────────────────────────────────────────────────
enum Scale { SKIRMISH, STANDARD, EPIC, MASSIVE }

const SCALE_PRESETS := {
	Scale.SKIRMISH: {
		"name": "Skirmish", "minutes": "~5 min",
		"tribes": 14, "tribe_cap": 24, "start_size": 2, "player_cap": 30,
		"neutrals": 20, "animals": 80, "bushes": 22, "trees": 900,
		"dogs": 10, "war_interval": 5.0,  "dominion": 60.0, "map_extent": 170.0,
	},
	Scale.STANDARD: {
		"name": "Standard", "minutes": "~12 min",
		"tribes": 20, "tribe_cap": 50, "start_size": 3, "player_cap": 50,
		"neutrals": 35, "animals": 120, "bushes": 32, "trees": 1500,
		"dogs": 17, "war_interval": 9.0,  "dominion": 100.0, "map_extent": 170.0,
	},
	Scale.EPIC: {
		"name": "Epic",     "minutes": "~30 min",
		"tribes": 26, "tribe_cap": 80, "start_size": 4, "player_cap": 70,
		"neutrals": 50, "animals": 160, "bushes": 42, "trees": 2200,
		"dogs": 28, "war_interval": 13.0, "dominion": 150.0, "map_extent": 170.0,
	},
	# only viable BECAUSE of the simulation LOD (npc.gd/world_tribe.gd) and
	# the spatial grid (spatial_grid.gd) — without those, 1000 tribes would
	# either never finish booting (eager member spawn) or tank the frame
	# rate (full-group proximity scans). map_extent is far larger than the
	# other presets so tribes actually spread out across distance tiers
	# instead of nearly all sitting in NEAR/MID range at once.
	Scale.MASSIVE: {
		"name": "Massive",  "minutes": "~60+ min",
		"tribes": 1000, "tribe_cap": 16, "start_size": 2, "player_cap": 70,
		"neutrals": 80, "animals": 250, "bushes": 60, "trees": 3000,
		"dogs": 30, "war_interval": 20.0, "dominion": 240.0, "map_extent": 1400.0,
	},
}

# ─────────────────────────────────────────────────────────────────────────────
# UI NODES (all Label / Control — built in _build_ui, positioned every frame)
# ─────────────────────────────────────────────────────────────────────────────
var status_label:   Label   = null
var resource_label: Label   = null
var help_label:     Label   = null
var player_label:   Label   = null
var factions_label: Label   = null
var flash_label:    Label   = null
var ui_hint_label:   Label   = null
var _feed_hint_label: Label  = null
var _feed_hint_alpha: float  = 1.0
var brain_panel:     Control = null
var _ui_hidden: bool         = false

# ═════════════════════════════════════════════════════════════════════════════
# READY
# ═════════════════════════════════════════════════════════════════════════════
func setup(_arg = null) -> void:
	pass  # called externally; initialization happens in _ready

func _ready() -> void:
	randomize()
	add_to_group("tribe_manager")
	food = starting_food
	_build_ui()
	_build_start_menu()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# quick-launch from command line:  godot -- --scale=epic
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--scale="):
			var nm := arg.substr(8).to_lower()
			var s  := Scale.STANDARD
			if   nm == "skirmish": s = Scale.SKIRMISH
			elif nm == "epic":     s = Scale.EPIC
			elif nm == "massive":  s = Scale.MASSIVE
			call_deferred("_choose_scale", s)

# ═════════════════════════════════════════════════════════════════════════════
# START MENU
# ═════════════════════════════════════════════════════════════════════════════
func _build_start_menu() -> void:
	var ui := _get_or_create_ui()
	start_menu = Control.new()
	start_menu.name = "StartMenu"
	start_menu.set_anchors_preset(Control.PRESET_FULL_RECT)

	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.06, 0.09, 0.93)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	start_menu.add_child(bg)

	var box := VBoxContainer.new()
	box.anchor_left   = 0.5; box.anchor_top    = 0.5
	box.anchor_right  = 0.5; box.anchor_bottom = 0.5
	box.offset_left   = -200; box.offset_top   = -180
	box.offset_right  =  200; box.offset_bottom =  210
	box.add_theme_constant_override("separation", 14)
	start_menu.add_child(box)

	var title := Label.new()
	title.text = "T R I B E"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 48)
	box.add_child(title)

	var sub := Label.new()
	sub.text = "Choose your world"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 20)
	box.add_child(sub)

	for s in [Scale.SKIRMISH, Scale.STANDARD, Scale.EPIC, Scale.MASSIVE]:
		var p: Dictionary = SCALE_PRESETS[s]
		var b := Button.new()
		b.text = "%s     %s · %d tribes" % [p["name"], p["minutes"], int(p["tribes"])]
		b.custom_minimum_size = Vector2(400, 56)
		b.add_theme_font_size_override("font_size", 22)
		b.pressed.connect(_choose_scale.bind(s))
		box.add_child(b)

	ui.add_child(start_menu)

func _choose_scale(s: int) -> void:
	game_scale = s
	_apply_scale(s)
	if start_menu and is_instance_valid(start_menu):
		start_menu.queue_free()
	start_menu = null
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_start_game()

func _apply_scale(s: int) -> void:
	var p: Dictionary = SCALE_PRESETS[s]
	world_tribe_count = int(p["tribes"])
	member_cap        = int(p["player_cap"])
	neutral_count     = int(p["neutrals"])
	animal_count      = int(p["animals"])
	bush_count        = int(p["bushes"])
	tree_count        = int(p["trees"])
	_dog_count        = int(p["dogs"])
	_tribe_cap        = int(p["tribe_cap"])
	_start_size       = int(p["start_size"])
	war_interval      = float(p["war_interval"])
	dominion_grace    = float(p["dominion"])
	MAP_EXTENT        = float(p["map_extent"])
	RESOURCE_EXTENT   = MAP_EXTENT * 0.9
	_resize_floor(MAP_EXTENT)

# ═════════════════════════════════════════════════════════════════════════════
# GAME START
# ═════════════════════════════════════════════════════════════════════════════
# the floor in main.tscn is a fixed 360x360 PlaneMesh sized for the default
# 170-unit MAP_EXTENT — large presets (Massive) spread tribes/resources far
# past that, so the ground has to grow to match or you'd walk off the edge
# of the world. Resized in code rather than baked per-scene since extent now
# varies per scale preset, not per scene.
func _resize_floor(extent: float) -> void:
	var floor_body := get_tree().get_first_node_in_group("world_floor")
	if floor_body == null:
		floor_body = get_node_or_null("/root/Main/Floor")
	if floor_body == null:
		return
	var size := extent * 2.2   # a margin beyond the furthest tribe/resource scatter
	var mesh_node := floor_body.get_node_or_null("Mesh") as MeshInstance3D
	if mesh_node and mesh_node.mesh is PlaneMesh:
		(mesh_node.mesh as PlaneMesh).size = Vector2(size, size)
	var col_node := floor_body.get_node_or_null("Collision") as CollisionShape3D
	if col_node and col_node.shape is BoxShape3D:
		var box := col_node.shape as BoxShape3D
		box.size = Vector3(size, box.size.y, size)

func _start_game() -> void:
	_started = true
	if spawn_count > 0:
		_spawn_members()
	# adopt any pre-placed tribe members in the scene tree
	for c in get_children():
		if c.has_method("give_order") and c not in members:
			members.append(c)
	for m in get_tree().get_nodes_in_group("tribe"):
		if m.has_method("give_order") and m not in members:
			members.append(m)
	for m in members:
		if "manager" in m:
			m.manager = self
	_make_loyal_companion()
	_spawn_stockpile()
	_spawn_world()
	_spawn_dogs()
	print("TribeManager: %s — %d members, %d tribes" % [
		SCALE_PRESETS[game_scale]["name"], members.size(), world_tribe_count])
	_flash(
		"Commands are keybinds — hold [V] looking at someone to pick them, "
		+ "then [1-7]/[0] to order. See the bar below for the full list.", 12.0)
	if _feed_hint_label:
		_feed_hint_label.visible = true
		_feed_hint_alpha = 1.0
		_feed_hint_label.modulate = Color(1, 1, 1, 1)

# ─────────────────────────────────────────────────────────────────────────────
# DOGS
# ─────────────────────────────────────────────────────────────────────────────
func _spawn_dogs() -> void:
	for _i in range(_dog_count):
		_spawn_one_dog()

func _spawn_one_dog() -> void:
	# NOTE: must be untyped (`=`, not `:=`) — set_script() attaches dog.gd at
	# runtime, and the static type checker only knows about CharacterBody3D
	# at the point .new() is called. A `:=` here would make `setup()` below
	# fail with "Invalid call. Nonexistent function 'setup' in base
	# 'CharacterBody3D'" even though the attached script defines it fine.
	var d = CharacterBody3D.new()
	d.set_script(load("res://dog.gd"))
	add_child(d)
	var pos := _scatter(8.0, 72.0, 1.0)
	d.global_position = pos
	d.setup(self, Vector3.ZERO, pos)

func _maybe_spawn_stray_dog() -> void:
	var cap := int(_dog_count * DOG_POPULATION_MULT)
	if get_tree().get_nodes_in_group("dog").size() >= cap:
		return
	_spawn_one_dog()

func toggle_dog_rally() -> void:
	dogs_heel = not dogs_heel
	var n := 0
	for i in range(dogs.size() - 1, -1, -1):
		if not is_instance_valid(dogs[i]):
			dogs.remove_at(i)
			continue
		if dogs[i].has_method("rally"):
			dogs[i].rally(dogs_heel)
			n += 1
	if n == 0:
		_flash("No loyal dogs yet — feed a stray with [H].")
	else:
		_flash("Dogs %s — %d loyal." % [
			"called to HEEL" if dogs_heel else "sent to GUARD the camp", n])

# ─────────────────────────────────────────────────────────────────────────────
# COMPANION
# ─────────────────────────────────────────────────────────────────────────────
func _make_loyal_companion() -> void:
	if members.is_empty():
		return
	var s = members[0]
	if "relationship"    in s: s.relationship    = 2.4
	if "is_backing_you"  in s: s.is_backing_you  = true
	if "follow_fires"    in s: s.follow_fires     = 99
	if "member_name"     in s: s.member_name      = "Companion"
	print("Your loyal Companion stands with you.")

# ─────────────────────────────────────────────────────────────────────────────
# WORLD SPAWNING
# ─────────────────────────────────────────────────────────────────────────────
func _spawn_stockpile() -> void:
	# untyped: setup happens via custom script (stockpile.gd) attached at runtime
	var sp = Node3D.new()
	sp.set_script(load("res://stockpile.gd"))
	add_child(sp)
	sp.position = Vector3.ZERO
	sp.set("manager", self)

func _spawn_world() -> void:
	_spawn_vegetation()
	for _i in range(bush_count):
		var b = Node3D.new()
		b.set_script(load("res://food_source.gd"))
		add_child(b)
		b.position = _scatter(6.0, RESOURCE_EXTENT, 0.0)
	for _i in range(animal_count):
		_spawn_animal(_scatter(10.0, RESOURCE_EXTENT, 1.0))
	for _i in range(neutral_count):
		# spread across the whole map, not clustered just outside your camp —
		# wanderers should feel like they're out in the world, same range
		# rival tribe camps use, not bunched at the inner edge of RESOURCE_EXTENT
		_spawn_neutral(_scatter(30.0, MAP_EXTENT, 1.0))
	_spawn_world_tribes()

func _spawn_vegetation() -> void:
	var groves := int(tree_count / 11.0)
	for _g in range(groves):
		var c := _scatter(12.0, MAP_EXTENT, 0.0)
		var n := 8 + randi() % 8
		for _i in range(n):
			var off := Vector3(randf_range(-6.0, 6.0), 0.0, randf_range(-6.0, 6.0))
			_build_tree(c + off)

func _build_tree(pos: Vector3) -> void:
	# untyped for consistency with the rest of the spawners; tree.gd has no
	# custom calls right after attach today, but keeping this pattern uniform
	# avoids this silently breaking the next time someone adds one.
	var t = StaticBody3D.new()
	t.set_script(load("res://tree.gd"))
	add_child(t)
	t.position = pos

func _spawn_neutral(pos: Vector3) -> void:
	var n = CharacterBody3D.new()
	n.set_script(load("res://npc.gd"))
	add_child(n)
	n.position = pos
	if "home_pos"   in n: n.home_pos   = pos
	if "is_neutral" in n: n.is_neutral = true
	if n.has_method("setup_neutral"): n.setup_neutral(pos)

func _spawn_world_tribes() -> void:
	var placed: Array      = []
	var used_names: Dictionary = {}
	for i in range(world_tribe_count):
		var pos  := _find_camp_spot(placed)
		placed.append(pos)
		var hue  := fmod(float(i) / float(world_tribe_count) + randf() * 0.04, 1.0)
		var col  := Color.from_hsv(hue, 0.65, 0.95)
		var arch : String = ARCHETYPES[i % ARCHETYPES.size()]
		var nm   := _unique_tribe_name(used_names)
		# untyped: this is the fix — world_tribe.gd's setup()/member_cap can't
		# resolve on a `:=`-typed Node3D var, since set_script() runs after
		# the type is already locked in by .new()
		var wt    = Node3D.new()
		wt.set_script(load("res://world_tribe.gd"))
		add_child(wt)
		wt.global_position = pos
		wt.setup(nm, col, arch, _start_size, self)
		wt.member_cap = _tribe_cap
		world_tribes.append(wt)
	print("World: spawned %d tribes" % world_tribes.size())

func _find_camp_spot(placed: Array) -> Vector3:
	for _try in range(24):
		var p := _scatter(34.0, MAP_EXTENT, 0.0)
		var ok := true
		for q in placed:
			if p.distance_to(q) < 34.0:
				ok = false
				break
		if ok:
			return p
	return _scatter(34.0, MAP_EXTENT, 0.0)

func _unique_tribe_name(used: Dictionary) -> String:
	for _try in range(40):
		var nm := "%s%s" % [NAME_A[randi() % NAME_A.size()], NAME_B[randi() % NAME_B.size()]]
		if not used.has(nm):
			used[nm] = true
			return nm
	return "%s%s%d" % [
		NAME_A[randi() % NAME_A.size()],
		NAME_B[randi() % NAME_B.size()],
		randi() % 99,
	]

func _spawn_animal(pos: Vector3) -> void:
	# species AND position must be set BEFORE add_child() — animal.gd's
	# _ready() (which fires the instant add_child runs) reads species to
	# pick stats and captures home_pos = global_position immediately, so
	# setting either afterward was silently ignored: every animal locked in
	# the default species ("Deer") and a home position of (0,0,0).
	var a = CharacterBody3D.new()
	a.set_script(load("res://animal.gd"))
	a.set("species", ANIMAL_POOL[randi() % ANIMAL_POOL.size()])
	a.position = pos
	add_child(a)

func _scatter(min_r: float, max_r: float, y: float) -> Vector3:
	var ang := randf() * TAU
	var r   := randf_range(min_r, max_r)
	return Vector3(cos(ang) * r, y, sin(ang) * r)

# ─────────────────────────────────────────────────────────────────────────────
# MEMBER SPAWNING
# ─────────────────────────────────────────────────────────────────────────────
func _spawn_members() -> void:
	for i in range(spawn_count):
		var ang := TAU * float(i) / float(spawn_count)
		var pos := Vector3(cos(ang) * spawn_radius, 1.0, sin(ang) * spawn_radius)
		_spawn_one_member(
			_next_member_name(),
			PERSONALITY_POOL[i % PERSONALITY_POOL.size()],
			pos)

func _spawn_one_member(nm: String, pers: String, pos: Vector3) -> Node:
	var m: Node = member_scene.instantiate() if member_scene else _build_member_in_code()
	add_child(m)
	m.position = pos
	if "member_name" in m: m.member_name = nm
	if "personality"  in m: m.personality  = pers
	if "manager"      in m: m.manager      = self
	m.add_to_group("tribe")
	if m not in members:
		members.append(m)
	return m

func _next_member_name() -> String:
	var name: String = MEMBER_NAMES[_name_cursor % MEMBER_NAMES.size()]
	_name_cursor += 1
	return name

func _build_member_in_code() -> Node:
	var body := CharacterBody3D.new()
	# script set after add_child in _spawn_one_member; children added here are
	# fine because body isn't in the tree yet — they attach when body does.
	body.set_script(load("res://tribemember.gd"))

	var mesh := MeshInstance3D.new()
	mesh.name = "Mesh"
	mesh.mesh = CapsuleMesh.new()
	mesh.position = Vector3(0, 1, 0)
	body.add_child(mesh)

	var face := MeshInstance3D.new()
	face.name = "Face"
	var bm := BoxMesh.new()
	bm.size = Vector3(0.5, 0.22, 0.16)
	face.mesh = bm
	face.position = Vector3(0, 1.45, 0.45)
	var fmat := StandardMaterial3D.new()
	fmat.albedo_color = Color(0.1, 0.1, 0.12)
	face.material_override = fmat
	body.add_child(face)
	_build_googly_eyes_flat(face)

	var trust := Label3D.new()
	trust.name = "TrustLabel"
	trust.position = Vector3(0, 2.6, 0)
	trust.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	body.add_child(trust)

	var thought := Label3D.new()
	thought.name = "ThoughtLabel"
	thought.position = Vector3(0, 3.3, 0)
	thought.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	thought.modulate = Color(0.85, 0.9, 1.0)
	body.add_child(thought)

	var col   := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.height = 2.0
	shape.radius = 0.5
	col.shape    = shape
	col.position = Vector3(0, 1, 0)
	body.add_child(col)

	return body

# googly eyes for a flat face box (0.5 x 0.22 x 0.16) — small spheres sitting
# just in front of the face, with off-center pupils for the classic wobble look
func _build_googly_eyes_flat(face: Node3D) -> void:
	for side in [-1.0, 1.0]:
		var eye := MeshInstance3D.new()
		var es := SphereMesh.new()
		es.radius = 0.05
		es.height = 0.1
		eye.mesh = es
		eye.position = Vector3(side * 0.14, 0.02, 0.1)
		var emat := StandardMaterial3D.new()
		emat.albedo_color = Color(1, 1, 1)
		eye.material_override = emat
		face.add_child(eye)

		var pupil := MeshInstance3D.new()
		var ps := SphereMesh.new()
		ps.radius = 0.022
		ps.height = 0.044
		pupil.mesh = ps
		pupil.position = Vector3(randf_range(-0.015, 0.015), randf_range(-0.015, 0.015), 0.045)
		var pmat := StandardMaterial3D.new()
		pmat.albedo_color = Color(0.05, 0.05, 0.05)
		pupil.material_override = pmat
		eye.add_child(pupil)

# ═════════════════════════════════════════════════════════════════════════════
# ECONOMY API  (members call these)
# ═════════════════════════════════════════════════════════════════════════════
func spend_food(n: int) -> bool:
	if food >= n:
		food -= n
		return true
	return false

func add_food(n: int) -> void:
	food += n

func add_materials(n: int) -> void:
	materials += n

func spend_materials(n: int) -> bool:
	if materials >= n:
		materials -= n
		return true
	return false

func add_wood(n: int) -> void:
	wood += n

func clubs_available() -> int:
	return clubs - _clubs_out

func reserve_club() -> bool:
	if clubs - _clubs_out > 0:
		_clubs_out += 1
		return true
	return false

func release_club() -> void:
	_clubs_out = max(0, _clubs_out - 1)

# for_player=true (the player carving with [C]) goes to the player's own
# player_holds_club, NOT the shared armory — a tribemember's autonomous
# "carve" job (tribemember.gd) still calls this with the default false and
# adds to the shared `clubs` pool as before.
func craft_club(for_player: bool = false) -> bool:
	if wood < CLUB_COST:
		_flash("Need %d wood to carve a club — chop a tree first." % CLUB_COST)
		return false
	wood -= CLUB_COST
	if for_player:
		player_holds_club = true
		# spend one looted material, if you have any, to forge a masterwork
		# club instead of a plain one — see player_club_material's use in
		# FPSPlayer.gd's swing/throw damage
		player_club_material = ""
		for mat_name in materials_owned.keys():
			if int(materials_owned[mat_name]) > 0:
				materials_owned[mat_name] -= 1
				player_club_material = mat_name
				break
		if player_club_material != "":
			_flash("You forge a %s club — it bites harder." % player_club_material)
	else:
		clubs += 1
	return true

func consume_club() -> bool:
	if clubs_available() <= 0:
		return false
	clubs -= 1
	return true

func notify(t: String) -> void:
	_flash(t)

# ─────────────────────────────────────────────────────────────────────────────
# BUILDING
# ─────────────────────────────────────────────────────────────────────────────
func _within_build_range(pos: Vector3) -> bool:
	var sp := get_tree().get_first_node_in_group("stockpile")
	if sp == null:
		return true
	return (sp as Node3D).global_position.distance_to(pos) <= BUILD_RANGE

func try_build_fence(pos: Vector3, yaw: float, by_player: bool = false) -> bool:
	if by_player and not _within_build_range(pos):
		_flash("Too far from camp — stay within %d of the stockpile." % int(BUILD_RANGE))
		return false
	if wood < FENCE_COST:
		_flash("Need %d wood for a fence — chop trees with your club." % FENCE_COST)
		return false
	wood -= FENCE_COST
	var f = StaticBody3D.new()
	f.set_script(load("res://fence.gd"))
	add_child(f)
	f.global_position = pos
	f.rotation.y      = yaw
	_flash("Fence raised. (wood left: %d)" % wood)
	return true

func try_build_teepee(pos: Vector3, by_player: bool = false) -> bool:
	if by_player and not _within_build_range(pos):
		_flash("Too far from camp — stay within %d of the stockpile." % int(BUILD_RANGE))
		return false
	if wood < TEEPEE_COST:
		_flash("Need %d wood for a teepee — chop more trees." % TEEPEE_COST)
		return false
	wood -= TEEPEE_COST
	var t = StaticBody3D.new()
	t.set_script(load("res://teepee.gd"))
	add_child(t)
	t.global_position = pos
	_flash("Teepee raised. (wood left: %d)" % wood)
	return true

const BlockScript = preload("res://block.gd")

# a single placeable wood block (block.gd) — the building unit for player-
# and NPC-raised fortresses/mazes. Builders (player or any walk-to-and-place
# NPC) must already be standing next to `pos`; this just spends the wood and
# places it, snapped to the shared block grid so different builders' work
# still lines up.
func try_build_block(pos: Vector3, by_player: bool = false) -> bool:
	if by_player and not _within_build_range(pos):
		_flash("Too far from camp — stay within %d of the stockpile." % int(BUILD_RANGE))
		return false
	if wood < BLOCK_COST:
		_flash("Need %d wood for a block — chop more trees." % BLOCK_COST)
		return false
	wood -= BLOCK_COST
	var b = StaticBody3D.new()
	b.set_script(load("res://block.gd"))
	add_child(b)
	b.global_position = BlockScript.snap(pos)
	return true

func try_build_camp(pos: Vector3, by_player: bool = false) -> bool:
	if by_player and not _within_build_range(pos):
		_flash("Too far from camp — stay within %d of the stockpile." % int(BUILD_RANGE))
		return false
	if wood < CAMP_COST:
		_flash("Need %d wood for a camp — chop more trees." % CAMP_COST)
		return false
	wood -= CAMP_COST
	var camp = Node3D.new()
	camp.set_script(load("res://player_camp.gd"))
	add_child(camp)
	camp.global_position = pos
	camp.set("manager", self)
	_build_camp_visuals(camp)
	_flash("Forward camp raised! (wood left: %d)" % wood)
	return true

func _build_camp_visuals(camp: Node3D) -> void:
	# a camp is just a small cluster of teepees — the same dwelling every
	# other camp (yours, a rival's) uses, not a separate fire/hut prop. The
	# camp node itself still carries the HP/take_damage and "player_camp"
	# group membership the siege order (fence -> camp -> stockpile, see
	# stockpile.gd) depends on; only the look changed.
	var count := 2
	for i in range(count):
		var ang := TAU * float(i) / float(count) + PI * 0.25
		var t = StaticBody3D.new()
		t.set_script(load("res://teepee.gd"))
		camp.add_child(t)
		t.position = Vector3(cos(ang) * 1.6, 0.0, sin(ang) * 1.6)

	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.7, 0.4)
	light.omni_range  = 10.0
	light.position    = Vector3(0, 3.0, 0)
	camp.add_child(light)

	# three surrounding huts
	for i in range(3):
		var ang := TAU * float(i) / 3.0
		var hut := StaticBody3D.new()
		hut.position = Vector3(cos(ang) * 4.0, 1.7, sin(ang) * 4.0)
		var mi := MeshInstance3D.new()
		var hm := CylinderMesh.new()
		hm.top_radius    = 0.0
		hm.bottom_radius = 2.0
		hm.height        = 3.4
		mi.mesh          = hm
		var hmat := StandardMaterial3D.new()
		hmat.albedo_color   = Color(0.6, 0.5, 0.35)
		mi.material_override = hmat
		hut.add_child(mi)
		var cs  := CollisionShape3D.new()
		var csh := CylinderShape3D.new()
		csh.radius = 1.7
		csh.height = 3.4
		cs.shape   = csh
		hut.add_child(cs)
		camp.add_child(hut)

# ─────────────────────────────────────────────────────────────────────────────
# JOB SUGGESTION  (idle members call this to pick their next task)
# ─────────────────────────────────────────────────────────────────────────────
func on_fortress_built() -> void:
	fortress_built = true

func suggest_job(_member) -> String:
	var have_bushes  := not get_tree().get_nodes_in_group("food_source").is_empty()
	var have_animals := not get_tree().get_nodes_in_group("animal").is_empty()
	var have_trees   := not get_tree().get_nodes_in_group("tree").is_empty()

	if food < members.size() * 2 and have_bushes:
		return "gather"
	# the tribe raises its own fortress once, same as rival camps do
	# autonomously (world_tribe.gd._build_palisade) — previously this only
	# ever happened if the player manually ordered [5] build; nobody built
	# anything on their own. fortress_built (set once a solo run finishes
	# the whole plan, see tribemember.gd) stops this from re-triggering
	# forever once it's up.
	if not fortress_built and wood >= 30 and members.size() >= 3 and randf() < 0.12:
		return "build"
	if clubs_available() < 1:
		# used to unconditionally suggest "carve" here even with zero wood —
		# craft_club() would then fail every single time (needs CLUB_COST
		# wood), and since nothing changed, the very next suggestion was
		# "carve" again: an infinite carve-fail loop that never gathered the
		# wood needed to actually break out of it. Get wood first if short.
		#
		# A second bug lived right next to that one: the instant wood hit
		# EXACTLY CLUB_COST, the next suggestion flipped straight to "carve"
		# and consumed it immediately — every single time. Gathering could
		# never build any real stockpile beyond the bare minimum because the
		# moment enough existed for one club, it got siphoned off, so the
		# player just saw a tight gather→home→carve→home loop ("running in
		# circles") with wood never visibly accumulating. Now carve only
		# fires once there's a real surplus above the cost, and even then
		# only about half the time — gathering gets real uninterrupted runs.
		if wood >= CLUB_COST + 4 and randf() < 0.5:
			return "carve"
		elif have_trees:
			return "wood"
	if wood < 6 and have_trees and randf() < 0.35:
		return "wood"
	if food < members.size() * 5 and have_bushes:
		return "gather"
	if clubs_available() >= 1 and have_animals and randf() < 0.6:
		return "hunt"
	if randf() < 0.15:
		return "scout"
	# BUG FIXED (2026-07-18): "recruit" was never a candidate here at all --
	# _start_job()'s "recruit" case and tribemember.gd's _do_recruit() already
	# handle the whole flow correctly (including gathering food first if the
	# tribe's short), but nothing ever CHOSE to try it autonomously. The only
	# way a member ever recruited was the player explicitly ordering it
	# (numeric key [6] or a typed/spoken "recruit" command). Existence-only
	# check (no distance cap), matching have_bushes/have_animals/have_trees'
	# own style above -- _do_recruit() itself has no distance cap either.
	if not get_tree().get_nodes_in_group("neutral").is_empty() and randf() < 0.2:
		return "recruit"
	if have_bushes:
		return "gather"
	return ""

# ─────────────────────────────────────────────────────────────────────────────
# MEMBER MANAGEMENT
# ─────────────────────────────────────────────────────────────────────────────
func _prune_members() -> void:
	# Remove any freed/invalid nodes so size() is always accurate
	for i in range(members.size() - 1, -1, -1):
		if not is_instance_valid(members[i]):
			members.remove_at(i)

func absorb_members(count: int, pos: Vector3) -> int:
	var joined := 0
	for _i in range(count):
		if members.size() >= member_cap:
			break
		var off := Vector3(randf_range(-3.0, 3.0), 1.0, randf_range(-3.0, 3.0))
		var sub := _spawn_one_member(_next_member_name(), _random_personality(), pos + off)
		if "relationship"   in sub: sub.relationship   = 0.3
		if "is_backing_you" in sub: sub.is_backing_you = true
		joined += 1
	return joined

func dismantle_tribe(attacker) -> void:
	var attacker_valid: bool = attacker != null and is_instance_valid(attacker)
	var joined := 0
	for m in members.duplicate():
		if not is_instance_valid(m):
			continue
		var pos: Vector3 = (m as Node3D).global_position
		m.queue_free()
		if attacker_valid and attacker.has_method("recruit_at") and attacker.recruit_at(pos):
			joined += 1
	members.clear()
	selected_member = null

	var foe: String = attacker.tribe_name \
		if (attacker_valid and "tribe_name" in attacker) else "raiders"
	notify("Your camp has fallen! %d survivors swear to the %s." % [joined, foe])

	var p := get_tree().get_first_node_in_group("player")
	if p and is_instance_valid(p):
		var rally: Vector3 = attacker.global_position if attacker_valid else Vector3.ZERO
		var off := Vector3(randf_range(-4.0, 4.0), 1.0, randf_range(-4.0, 4.0))
		if "global_position" in p: p.global_position = rally + off
		if "hp" in p and "max_hp" in p: p.hp = p.max_hp

func recruit_neutral(npc) -> Node:
	if members.size() >= member_cap or npc == null or not is_instance_valid(npc):
		return null
	var pos: Vector3 = npc.global_position
	npc.queue_free()
	var m := _spawn_one_member(_next_member_name(), _random_personality(), pos)
	if "relationship" in m: m.relationship = 0.5
	return m

func on_member_died(m) -> void:
	members.erase(m)
	if focus_tribe == m:
		focus_tribe = null
	for o in members:
		if is_instance_valid(o) and "relationship" in o:
			o.relationship = maxf(0.0, o.relationship - 0.4)
	var nm: String = m.member_name if (m and "member_name" in m) else "A member"
	_flash("%s has fallen. The tribe mourns (trust shaken)." % nm)

# ═════════════════════════════════════════════════════════════════════════════
# SCOUTING
# ═════════════════════════════════════════════════════════════════════════════
func player_scout(from_pos: Vector3) -> void:
	var t = _nearest_tribe_from(from_pos, false)
	if t == null:
		_flash("No unknown camps remain.")
		return
	if from_pos.distance_to(t.global_position) > SCOUT_RANGE:
		_flash("Too far to scout — walk within %d of a camp." % int(SCOUT_RANGE))
		return
	t.discover()
	var line: String = t.greeting() if t.has_method("greeting") else ""
	_flash("You scouted the %s — %s, strength %d.%s" % [
		t.tribe_name, t.archetype, t.strength,
		"\n\"%s\"" % line if line != "" else ""])

func nearest_undiscovered_camp(from_pos: Vector3):
	return _nearest_tribe_from(from_pos, false)

func discover_near(pos: Vector3) -> void:
	var t = _nearest_tribe_from(pos, false)
	if t != null and pos.distance_to(t.global_position) <= SCOUT_RANGE:
		t.discover()
		_flash("Scouts mapped the %s — %s, strength %d." % [t.tribe_name, t.archetype, t.strength])

func discover_rival(_report: String) -> void:
	var t = _nearest_undiscovered_tribe()
	if t == null:
		_flash("Scouts range far but turn up no new camps.")
		return
	t.discover()
	_flash("Scouts found the %s — %s, strength %d. (R+4 to raid the nearest)" % [
		t.tribe_name, t.archetype, t.strength])

func cycle_focus(dir: int) -> void:
	var known: Array = []
	for t in world_tribes:
		if is_instance_valid(t) and not t.defeated and t.discovered:
			known.append(t)
	if known.is_empty():
		focus_tribe = null
		_flash("No scouted tribes yet — scout with [T].")
		return
	var idx := known.find(focus_tribe)
	idx = (idx + dir + known.size()) % known.size()
	focus_tribe = known[idx]
	_flash("Focused: %s — %s, strength %d   ([K] to raid)" % [
		focus_tribe.tribe_name, focus_tribe.archetype, focus_tribe.strength])

# ═════════════════════════════════════════════════════════════════════════════
# RAIDS
# ═════════════════════════════════════════════════════════════════════════════
func raid_focus() -> void:
	var target = focus_tribe \
		if (focus_tribe and is_instance_valid(focus_tribe) and not focus_tribe.defeated) \
		else _nearest_discovered_tribe()
	_launch_raid(target)

func order_raid() -> void:
	_launch_raid(_nearest_discovered_tribe())

func _launch_raid(target) -> void:
	if not _raid.is_empty() and _raid.get("live", false):
		_flash("A raid is already underway.")
		return
	if target == null:
		_flash("No scouted camp to raid — scout with [T] first.")
		return
	var party: Array = []
	for m in members:
		if is_instance_valid(m) and m.get("is_backing_you") and not m.get("is_busy"):
			party.append(m)
	if party.is_empty():
		_flash("No free backers to raid with — win some loyalty first.")
		return
	var strength := 8
	for m in party:
		strength += m.get_might()
		m.dispatch_to(target.global_position, "raid", 14.0)
	_raid = {"tribe": target, "party": party, "strength": strength, "timer": 8.0, "live": true}
	_flash("RAID! %d march on the %s (your strength %d)." % [
		party.size(), target.tribe_name, strength])

func _raid_tick(delta: float) -> void:
	if _raid.is_empty() or not _raid.get("live", false):
		return
	_raid["timer"] -= delta
	if _raid["timer"] > 0.0:
		return
	_raid["live"] = false
	var target = _raid["tribe"]
	if not is_instance_valid(target):
		_raid = {}
		return
	var ours  : int = _raid["strength"]
	var theirs: int = int(target.strength * randf_range(0.85, 1.2))
	if ours >= theirs:
		var loot_f := 6 + int((ours - theirs) / 2.0)
		var loot_m := 3 + int(target.strength / 25.0)
		add_food(loot_f)
		add_materials(loot_m)
		for m in _raid["party"]:
			if is_instance_valid(m) and "relationship" in m:
				m.relationship = minf(3.0, m.relationship + 0.2)
		var fallen_name: String = target.tribe_name   # capture before conquer() can free this node
		ripple_player_reputation(fallen_name)
		var joined: int = target.conquer(self)
		var sub := "  %d swear to your clan!" % joined if joined > 0 else ""
		_flash("RAID WON vs %s! +%d food, +%d skins. Camp razed.%s" % [
			fallen_name, loot_f, loot_m, sub])
	else:
		unrest += 0.5
		for m in _raid["party"]:
			if not is_instance_valid(m): continue
			if m.has_method("take_hit"): m.take_hit(randf_range(25.0, 65.0), null)
			if is_instance_valid(m) and "relationship" in m:
				m.relationship = maxf(0.0, m.relationship - 0.3)
		_flash("RAID LOST vs %s — fighters wounded, some fell." % target.tribe_name)
	_raid = {}

# ═════════════════════════════════════════════════════════════════════════════
# MAIN LOOP
# ═════════════════════════════════════════════════════════════════════════════
func _process(delta: float) -> void:
	if not _started:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		return

	_prune_members()
	_update_backers()

	# leader-only rally + raid commands (hold R)
	if is_leader and Input.is_key_pressed(KEY_R):
		if _key_just(KEY_1): rally_order("gather")
		elif _key_just(KEY_2): rally_order("hunt")
		elif _key_just(KEY_3): rally_order("scout")
		elif _key_just(KEY_4): order_raid()

	if _key_just(KEY_B): _toggle_brain_panel()
	if _key_just(KEY_U): _toggle_ui()
	if _key_just(KEY_TAB): _toggle_map()
	if _map_panel and _map_panel.visible:
		# throttled, not per-frame: MapView._draw() calls draw_string once per
		# discovered tribe, and redrawing every single frame was hammering the
		# dynamic font glyph atlas hard enough to trip a Vulkan uniform-set
		# error (positions barely change frame to frame anyway — no need)
		_map_redraw_accum -= delta
		if _map_redraw_accum <= 0.0:
			_map_redraw_accum = 0.2
			_update_map()
	_check_proximity_discovery(delta)

	_dog_spawn_cd -= delta
	if _dog_spawn_cd <= 0.0:
		_dog_spawn_cd = randf_range(30.0, 55.0)
		_maybe_spawn_stray_dog()

	if _flash_timer > 0.0:
		_flash_timer -= delta

	_hunger(delta)
	_recruit_tick(delta)
	_raid_tick(delta)
	_faction_tick(delta)
	_respawn_tick(delta)
	_neutral_tick(delta)
	_ecology_tick(delta)
	_war_tick(delta)
	_check_victory()

	_update_ui_positions()
	_update_brain_panel()
	_update_status()
	_update_flash()
	_update_player_label()
	_update_factions_label()
	_update_feed_hint(delta)

# ─────────────────────────────────────────────────────────────────────────────
# VICTORY / DEFEAT
# ─────────────────────────────────────────────────────────────────────────────
func _check_victory() -> void:
	if game_over: return
	if _live_tribe_count() == 0 and world_tribe_count > 0:
		game_over = true
		won       = true
		_flash("LAST TRIBE STANDING — YOU WIN! Every rival camp has fallen.")

# ─────────────────────────────────────────────────────────────────────────────
# LEADERSHIP
# ─────────────────────────────────────────────────────────────────────────────
func _update_backers() -> void:
	var count := 0
	for m in members:
		if is_instance_valid(m) and m.get("is_backing_you"):
			count += 1
	backers = count
	if not is_leader and backers >= leadership_threshold:
		_become_leader()

func _become_leader() -> void:
	is_leader = true
	print("=== YOU ARE NOW TRIBE LEADER (%d backers) ===" % backers)
	became_leader.emit()

func rally_order(kind: String) -> void:
	var accepted := 0; var refused := 0
	for m in members:
		if is_instance_valid(m) and m.has_method("give_order"):
			if m.give_order(kind): accepted += 1
			else:                  refused  += 1
	_flash("RALLY %s → %d marched out, %d refused" % [kind, accepted, refused])

# ─────────────────────────────────────────────────────────────────────────────
# HUNGER & UNREST
# ─────────────────────────────────────────────────────────────────────────────
func _hunger(delta: float) -> void:
	if food <= 0 and members.size() > 0:
		unrest += delta * 0.08
	else:
		unrest = maxf(0.0, unrest - delta * 0.08)

	if not is_leader: return
	if unrest > 1.0:
		challenged = true
	if challenged and unrest <= 0.35:
		challenged = false
		_flash("The challenge fades — the tribe is fed and content.")
	if unrest >= 2.2:
		_lose_leadership()

func _lose_leadership() -> void:
	is_leader  = false
	challenged = false
	unrest     = 1.0
	for m in members:
		if is_instance_valid(m) and m.get("is_backing_you"):
			m.is_backing_you = false
	_flash("⚠ THE TRIBE HAS TURNED ON YOU — you are no longer leader.")

# ─────────────────────────────────────────────────────────────────────────────
# RECRUITING
# ─────────────────────────────────────────────────────────────────────────────
func _recruit_tick(delta: float) -> void:
	_recruit_accum += delta
	if _recruit_accum < 30.0: return
	_recruit_accum = 0.0
	if food > members.size() * 2 and members.size() < member_cap and unrest < 0.5:
		_spawn_one_member(_next_member_name(), _random_personality(), _edge_position())
		_flash("A wanderer drifts toward your well-fed camp...")

# ─────────────────────────────────────────────────────────────────────────────
# INTER-TRIBE WAR
# ─────────────────────────────────────────────────────────────────────────────
func _war_tick(delta: float) -> void:
	if game_over: return
	_ai_raid_tick(delta)
	var alive := _live_world_tribes()

	# crumble abandoned camps
	for t in alive:
		if t.abandoned:
			var nm: String = t.tribe_name
			t.defeat()
			if focus_tribe == t: focus_tribe = null
			_flash("The abandoned %s camp crumbles." % nm)
	alive = _live_world_tribes()

	# final battle when only 2-3 clans remain
	if not _final_battle_triggered and world_tribe_count > 2 \
			and alive.size() >= 2 and alive.size() <= 3:
		_trigger_final_battle(alive)

	# dominion countdown
	if alive.size() == 1 and world_tribe_count > 1:
		_tick_dominion(alive[0], delta)
		return
	_dominion = null

	_war_accum += delta
	if _war_accum < war_interval: return
	_war_accum = 0.0
	if alive.size() >= 2:
		_resolve_war_round(alive)

func _trigger_final_battle(alive: Array) -> void:
	_final_battle_triggered = true
	var center := Vector3.ZERO
	for t in alive:
		center += t.global_position
	center /= float(alive.size())

	var total_mustered := 0
	for t in alive:
		if not is_instance_valid(t) or t.defeated: continue
		var enemy = _nearest_world_tribe_to(t, alive)
		if enemy == null: continue
		var party_size: int = max(3, t.member_count)
		var mustered: int   = t.muster_war_party(enemy, party_size)
		total_mustered += mustered
		for n in t.war_party:
			if is_instance_valid(n): n.set("_war_pos", center)

	# pull player backers into the fight too
	for m in members:
		if is_instance_valid(m) and m.get("is_backing_you") and m.has_method("dispatch_to"):
			m.dispatch_to(center, "raid", 60.0)

	_flash("⚔⚔⚔ THE FINAL BATTLE — every remaining clan marches on the same ground! ⚔⚔⚔", 10.0)
	print("ENDGAME: final battle — %d clans, %d warriors" % [alive.size(), total_mustered])

func _live_world_tribes() -> Array:
	var out: Array = []
	for t in world_tribes:
		if is_instance_valid(t) and not t.defeated:
			out.append(t)
	return out

func _resolve_war_round(alive: Array) -> void:
	# weighted ambition: warlike + strong tribes fight more often, and a
	# leader's own aggression trait now matters as much as archetype does —
	# two "Foragers" tribes can behave very differently depending on who
	# happens to be leading them
	var weights: Array = []
	var total   := 0.0
	for t in alive:
		var leader_aggro: float = float(t.leader_traits.get("aggression", 0.5)) if "leader_traits" in t else 0.5
		var amb: float = maxf(1.0, float(t.strength)) * float(WARLIKE.get(t.archetype, 1.0)) * (0.5 + leader_aggro)
		weights.append(amb)
		total += amb
	if total <= 0.0: return

	var roll := randf() * total
	var aggressor = alive[alive.size() - 1]
	for i in range(alive.size()):
		roll -= weights[i]
		if roll <= 0.0:
			aggressor = alive[i]
			break

	# one war per tribe at a time
	for r in _ai_raids:
		if r["aggressor"] == aggressor or r["defender"] == aggressor:
			return
	var defender = _pick_war_target(aggressor, alive)
	if defender == null: return
	for r in _ai_raids:
		if r["defender"] == defender or r["aggressor"] == defender:
			return

	var party_size: int = clampi(int(round(aggressor.member_count * 0.6)), 1, 6)
	var mustered: int   = aggressor.muster_war_party(defender, party_size)
	if mustered <= 0:
		_abstract_clash(aggressor, defender)
		return
	_ai_raids.append({"aggressor": aggressor, "defender": defender, "timer": 42.0})
	_flash("⚔ The %s muster %d and march on the %s!" % [
		aggressor.tribe_name, mustered, defender.tribe_name])

func _abstract_clash(aggressor, defender) -> void:
	if not is_instance_valid(aggressor) or not is_instance_valid(defender) or defender.defeated:
		return
	var a_power := float(aggressor.strength) * randf_range(0.85, 1.30)
	var d_power := float(defender.strength)  * randf_range(0.85, 1.20)
	if defender.built: d_power *= 1.25
	if a_power >= d_power:
		var ln: String = defender.tribe_name
		# settling the score — surviving tribes react based on how THEY felt
		# about the tribe that just fell: sympathizers grow wary of the
		# victor, tribes who disliked the loser quietly approve
		_ripple_opinions_on_defeat(aggressor, ln)
		aggressor.absorb_rival(defender)
		defender.defeat()
		if focus_tribe == defender: focus_tribe = null
		_flash("⚔ The %s overran the %s. (%d tribes left)" % [
			aggressor.tribe_name, ln, _live_tribe_count()])
	else:
		aggressor.weaken(1)
		defender.fortify(6)
		if defender.has_method("add_grudge"):
			defender.add_grudge(aggressor.tribe_name, 0.3)   # a real, earned grudge from being attacked

# when a tribe falls, every OTHER surviving tribe reacts based on how they
# already felt about the one that just fell — this is the actual "rivalries
# and alliances trickle down" mechanic: nobody scripted these reactions
func _ripple_opinions_on_defeat(victor, defeated_name: String) -> void:
	for t in world_tribes:
		if not is_instance_valid(t) or t.defeated or t == victor:
			continue
		if not t.has_method("grudge_toward"):
			continue
		var felt: float = t.grudge_toward(defeated_name)
		if felt < 0.2:
			t.add_grudge(victor.tribe_name, 0.15)    # sympathized with the loser — wary of the victor now
		elif felt > 0.5:
			t.add_grudge(victor.tribe_name, -0.1)    # glad to see a rival fall

# YOU are the victor here — every surviving tribe's player_opinion shifts
# the same way, based on how THEY felt about the tribe you just razed. Allies
# of the fallen resent you; the fallen tribe's enemies warm to you. This is
# what makes "who you raid" actually shape your reputation across the world,
# not just with the tribe you fought.
func ripple_player_reputation(defeated_name: String) -> void:
	for t in world_tribes:
		if not is_instance_valid(t) or t.defeated:
			continue
		if not t.has_method("grudge_toward") or not ("player_opinion" in t):
			continue
		var felt: float = t.grudge_toward(defeated_name)
		if felt < 0.2:
			t.player_opinion = clampf(t.player_opinion - 0.15, -1.0, 1.0)
		elif felt > 0.5:
			t.player_opinion = clampf(t.player_opinion + 0.15, -1.0, 1.0)

func _ai_raid_tick(delta: float) -> void:
	for i in range(_ai_raids.size() - 1, -1, -1):
		var r: Dictionary = _ai_raids[i]
		var a = r["aggressor"]
		var d = r["defender"]
		if not is_instance_valid(a) or a.defeated:
			if is_instance_valid(a): a.recall_war_party()
			_ai_raids.remove_at(i)
			continue
		if not is_instance_valid(d) or d.defeated:
			a.recall_war_party()
			if focus_tribe == d: focus_tribe = null
			_flash("⚔ The %s stormed a rival camp! (%d tribes left)" % [
				a.tribe_name, _live_tribe_count()])
			_ai_raids.remove_at(i)
			continue
		r["timer"] -= delta
		if r["timer"] <= 0.0:
			a.recall_war_party()
			_abstract_clash(a, d)
			_ai_raids.remove_at(i)

# grudges drive who a tribe actually wants to attack — old scores get
# settled, not just the nearest neighbor every time. Falls back to nearest
# when no one's holding a real grudge yet, so the world doesn't sit idle
# waiting for opinions to form.
func _pick_war_target(src, alive: Array):
	var best = null
	var best_score := -INF
	for t in alive:
		if t == src: continue
		var d: float = src.global_position.distance_to(t.global_position)
		var grudge: float = src.grudge_toward(t.tribe_name) if src.has_method("grudge_toward") else 0.0
		var score: float = grudge * 400.0 - d
		if score > best_score:
			best_score = score
			best = t
	return best

func _nearest_world_tribe_to(src, alive: Array):
	var best = null; var bd := INF
	for t in alive:
		if t == src: continue
		var d: float = src.global_position.distance_to(t.global_position)
		if d < bd: bd = d; best = t
	return best

func _tick_dominion(last, delta: float) -> void:
	if _dominion != last:
		_dominion             = last
		_dominion_timer       = dominion_grace
		_dominion_buff_accum  = 0.0
		_siege_accum          = 0.0
		_flash("⚑ The %s are the last great power — raze their camp in %ds!" % [
			last.tribe_name, int(dominion_grace)])

	_dominion_timer      -= delta
	_dominion_buff_accum += delta
	if _dominion_buff_accum >= 5.0:
		_dominion_buff_accum = 0.0
		if is_instance_valid(last): last.fortify(5)

	_siege_accum += delta
	if _siege_accum >= 9.0 and is_instance_valid(last):
		_siege_accum = 0.0
		var wave := 2 + randi() % 3
		for _i in range(wave): last.spawn_siege_raider(Vector3.ZERO)
		_flash("⚑ The %s hurl raiders at your camp!" % last.tribe_name)

	if _dominion_timer <= 0.0:
		game_over   = true
		won         = false
		lost        = true
		_loser_name = last.tribe_name if is_instance_valid(last) else "rivals"
		_flash("✖ The %s have conquered the world. Your tribe is no more." % _loser_name)

# ─────────────────────────────────────────────────────────────────────────────
# TRIBE QUERIES
# ─────────────────────────────────────────────────────────────────────────────
func _nearest_undiscovered_tribe():
	return _nearest_tribe(false)

func _nearest_discovered_tribe():
	return _nearest_tribe(true)

func _nearest_tribe(want_discovered: bool):
	return _nearest_tribe_from(global_position, want_discovered)

func _nearest_tribe_from(from_pos: Vector3, want_discovered: bool):
	var best = null; var bd := INF
	for t in world_tribes:
		if not is_instance_valid(t) or t.defeated: continue
		if t.discovered != want_discovered: continue
		var d: float = (t.global_position - from_pos).length()
		if d < bd: bd = d; best = t
	return best

func _known_tribe_count() -> int:
	var c := 0
	for t in world_tribes:
		if is_instance_valid(t) and not t.defeated and t.discovered: c += 1
	return c

func _live_tribe_count() -> int:
	var c := 0
	for t in world_tribes:
		if is_instance_valid(t) and not t.defeated: c += 1
	return c

# ═════════════════════════════════════════════════════════════════════════════
# EMERGENT FACTIONS
# ═════════════════════════════════════════════════════════════════════════════
func _faction_tick(delta: float) -> void:
	_faction_accum += delta
	if _faction_accum < 2.5: return
	_faction_accum = 0.0
	_recompute_factions()

func _compatible(a: String, b: String) -> bool:
	return (b in COMPAT.get(a, [])) and (a in COMPAT.get(b, []))

func _find(parent: Array, i: int) -> int:
	while parent[i] != i:
		parent[i] = parent[parent[i]]
		i = parent[i]
	return i

func _union(parent: Array, a: int, b: int) -> void:
	var ra := _find(parent, a)
	var rb := _find(parent, b)
	if ra != rb: parent[rb] = ra

func _recompute_factions() -> void:
	var valid: Array = []
	for m in members:
		if is_instance_valid(m): valid.append(m)

	var n := valid.size()
	var parent: Array = range(n)   # parent[i] = i

	for i in range(n):
		for j in range(i + 1, n):
			if _compatible(valid[i].personality, valid[j].personality):
				if valid[i].global_position.distance_to(valid[j].global_position) <= FACTION_RADIUS:
					_union(parent, i, j)

	var groups: Dictionary = {}
	for i in range(n):
		var r := _find(parent, i)
		if not groups.has(r): groups[r] = []
		groups[r].append(i)

	for m in valid:
		m.faction_id    = -1
		m.faction_vouch = 0.0

	factions = []
	var fid := 0
	for r in groups.keys():
		var idxs: Array = groups[r]
		if idxs.size() < 2: continue
		var centroid := Vector3.ZERO
		var bk := 0
		for i in idxs:
			centroid += valid[i].global_position
			if valid[i].is_backing_you: bk += 1
		centroid /= float(idxs.size())
		var col   : Color  = FACTION_COLORS[fid % FACTION_COLORS.size()]
		var fname : String = FACTION_NAMES[fid % FACTION_NAMES.size()]
		var vouch  := float(bk) / float(idxs.size())
		for i in idxs:
			valid[i].faction_id       = fid
			valid[i].faction_name     = fname
			valid[i].faction_color    = col
			valid[i].faction_centroid = centroid
			valid[i].faction_vouch    = vouch
		factions.append({"name": fname, "color": col, "size": idxs.size(), "backers": bk})
		fid += 1

# ─────────────────────────────────────────────────────────────────────────────
# ECOLOGY TICKS
# ─────────────────────────────────────────────────────────────────────────────
func _respawn_tick(delta: float) -> void:
	_respawn_accum += delta
	if _respawn_accum < 5.0: return
	_respawn_accum = 0.0
	# burst, not one at a time — animal_count now runs up to 250 (Massive),
	# and trickling in a single animal per 5s would take the better part of
	# 20+ minutes just to reach a fresh-boot population
	var have := get_tree().get_nodes_in_group("animal").size()
	if have < animal_count:
		var burst: int = mini(8, animal_count - have)
		for _i in range(burst):
			_spawn_animal(_scatter(22.0, MAP_EXTENT, 1.0))

func _neutral_tick(delta: float) -> void:
	_neutral_accum += delta
	if _neutral_accum < 2.5: return
	_neutral_accum = 0.0
	var have := get_tree().get_nodes_in_group("neutral").size()
	if have < neutral_count:
		# spawn in a burst, not one at a time — with tribes now actively
		# recruiting (world_tribe.gd._grow), the wanderer pool needs to
		# replenish fast enough to keep up with demand, not trickle in
		var burst: int = mini(4, neutral_count - have)
		for _i in range(burst):
			_spawn_neutral(_scatter(30.0, MAP_EXTENT, 1.0))

func _ecology_tick(delta: float) -> void:
	_ecology_accum += delta
	if _ecology_accum < 5.0: return
	_ecology_accum = 0.0
	var pop          := members.size() + get_tree().get_nodes_in_group("npc").size()
	var bush_target  := mini(70, bush_count   + int(pop / 4.0))
	# was a flat mini(55, ...) cap — harmless when animal_count maxed out
	# around 32, but now that presets ask for up to 250 animals, that fixed
	# cap would've clamped every preset above Skirmish right back down to 55.
	var animal_target := mini(animal_count + 40, animal_count + int(pop / 7.0))
	if get_tree().get_nodes_in_group("food_source").size() < bush_target:
		var b = Node3D.new()
		b.set_script(load("res://food_source.gd"))
		add_child(b)
		b.position = _scatter(8.0, RESOURCE_EXTENT, 0.0)
	if get_tree().get_nodes_in_group("animal").size() < animal_target:
		_spawn_animal(_scatter(12.0, RESOURCE_EXTENT, 1.0))
	var trees := get_tree().get_nodes_in_group("tree").size()
	if trees < tree_count:
		for _i in range(mini(10, tree_count - trees)):
			_build_tree(_scatter(10.0, MAP_EXTENT, 0.0))

# ═════════════════════════════════════════════════════════════════════════════
# INDIVIDUAL COMMANDS
# ═════════════════════════════════════════════════════════════════════════════
var selected_group: Array = []   # populated by select_whole_tribe(); command_selected() applies to everyone in it

func cycle_selection() -> void:
	selected_group.clear()
	var live: Array = []
	for m in members:
		if is_instance_valid(m): live.append(m)
	if live.is_empty():
		selected_member = null
		return
	var idx := live.find(selected_member) + 1
	if idx >= live.size():
		selected_member = null
		_flash("Selection cleared.")
		return
	selected_member = live[idx]
	var nm: String = selected_member.member_name if "member_name" in selected_member else "member"
	_flash("Commanding %s — [1]gather [2]hunt [3]scout [4]wood [5]build [0]auto" % nm)

# triple-tap [V] — command everyone backing you at once instead of one member
func select_whole_tribe() -> void:
	selected_member = null
	selected_group.clear()
	for m in members:
		if is_instance_valid(m) and m.get("is_backing_you"):
			selected_group.append(m)
	if selected_group.is_empty():
		_flash("No loyal members to command yet.")
	else:
		_flash("Commanding your WHOLE TRIBE (%d) — [1]gather [2]hunt [3]scout [4]wood [5]build [6]recruit [7]guard [0]auto" % selected_group.size())

func command_selected(job: String, amount: int = -1) -> void:
	if not selected_group.is_empty():
		var live: Array = []
		for m in selected_group:
			if is_instance_valid(m): live.append(m)
		selected_group = live
		if selected_group.is_empty():
			_flash("Your commanded group has scattered.")
			return
		for i in range(selected_group.size()):
			_apply_command(selected_group[i], job, amount, i, selected_group.size())
		_flash("Whole tribe (%d) ordered: %s" % [selected_group.size(), job])
		return
	if selected_member == null or not is_instance_valid(selected_member):
		_flash("No member selected — hold [V] while looking at one (tap 3x for the whole tribe), or [M] to cycle.")
		return
	_apply_command(selected_member, job, amount)
	var nm: String = selected_member.member_name if "member_name" in selected_member else "member"
	if job == "auto":
		_flash("%s returns to self-directed work." % nm)
	else:
		var target: int = amount if amount >= 0 else STANDING_QUOTA.get(job, 0)
		var goal := " until %d" % target if target > 0 else ""
		_flash("%s will %s%s." % [nm, job, goal])

# shared per-member order logic — used for both a single selected_member and
# every member in selected_group (whole-tribe orders). offset/stride only
# matter for "build": they let a whole-tribe order divide fence_ring_plan()
# among everyone ordered instead of every member racing through the exact
# same plan from segment 0 (which looked like only one member ever did
# anything, while the rest just stood around).
func _apply_command(m, job: String, amount: int, offset: int = 0, stride: int = 1) -> void:
	if job == "auto":
		if m.has_method("clear_standing"): m.clear_standing()
		return
	if job == "build":
		if m.has_method("begin_build"): m.begin_build(offset, stride)
		return
	var target: int = amount if amount >= 0 else STANDING_QUOTA.get(job, 0)
	if m.has_method("set_standing"): m.set_standing(job, target)

func select_lookat(from_pos: Vector3, dir: Vector3, max_dist: float = 20.0) -> void:
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from_pos, from_pos + dir * max_dist)
	query.collide_with_areas = false
	var hit := space.intersect_ray(query)
	if hit.is_empty(): return
	var body = hit.get("collider")
	if body == null or not body.is_in_group("tribe"): return
	if selected_member == body: return
	selected_group.clear()
	selected_member = body
	var nm: String = body.member_name if "member_name" in body else "member"
	_flash("Commanding %s — [1]gather [2]hunt [3]scout [4]wood [5]build [6]recruit [7]guard [0]auto" % nm)

# ─────────────────────────────────────────────────────────────────────────────
# WORK PLANS
# ─────────────────────────────────────────────────────────────────────────────
func cycle_work_plan() -> void:
	work_preset = (work_preset + 1) % 6
	var crew: Array = []
	for m in members:
		if is_instance_valid(m) and m.get("is_backing_you"):
			crew.append(m)
	match work_preset:
		0:
			for m in crew:
				if m.has_method("clear_standing"): m.clear_standing()
			_flash("Work plan: AUTO — everyone self-directs.")
		1:
			_distribute(crew, ["gather"])
			_flash("Work plan: ALL FORAGING.")
		2:
			_distribute(crew, ["gather", "wood"])
			_flash("Work plan: food + wood, split evenly.")
		3:
			_distribute(crew, ["gather", "wood", "hunt"])
			_flash("Work plan: food + wood + hunt.")
		4:
			_distribute(crew, ["gather", "wood", "hunt", "scout"])
			_flash("Work plan: balanced + scouting.")
		5:
			raid_focus()
			_distribute(crew, ["gather", "wood"])
			_flash("Work plan: WAR FOOTING — raiders march, rest supply them.")

func _distribute(crew: Array, jobs: Array) -> void:
	for i in range(crew.size()):
		if crew[i].has_method("set_standing"):
			crew[i].set_standing(jobs[i % jobs.size()], 0)

# ─────────────────────────────────────────────────────────────────────────────
# FORMATIONS
# ─────────────────────────────────────────────────────────────────────────────
func cycle_formation() -> void:
	var idx := FORMATION_KINDS.find(formation_kind)
	formation_kind = FORMATION_KINDS[(idx + 1) % FORMATION_KINDS.size()]
	_flash("Formation: %s" % formation_kind.to_upper())

func formation_offset(index: int, total: int, kind: String, facing: Vector3) -> Vector3:
	if kind == "loose" or total <= 1:
		return Vector3.ZERO
	var f := facing; f.y = 0.0
	if f.length() < 0.01: f = Vector3(0, 0, -1)
	f = f.normalized()
	var right := f.rotated(Vector3.UP, PI / 2.0)
	var cols: int = maxi(1, int(ceil(sqrt(float(total)))))
	match kind:
		"phalanx":
			var row := int(index / cols); var col := index % cols
			return right * (col - (cols - 1) / 2.0) * 1.7 - f * row * 1.7
		"testudo":
			var row := int(index / cols); var col := index % cols
			return right * (col - (cols - 1) / 2.0) * 1.05 - f * row * 1.05
		"wedge":
			var row := 0; var i := index
			while i >= row + 1: i -= (row + 1); row += 1
			return right * (i - row / 2.0) * 1.7 - f * row * 1.7 * 0.9
	return Vector3.ZERO

# ─────────────────────────────────────────────────────────────────────────────
# DEFENSE PERIMETER
# ─────────────────────────────────────────────────────────────────────────────
func cycle_perimeter() -> void:
	var idx := PERIMETER_PRESETS.find(perimeter_radius)
	if idx < 0: idx = 0
	perimeter_radius = PERIMETER_PRESETS[(idx + 1) % PERIMETER_PRESETS.size()]
	_flash("Defense perimeter set to %d units." % int(perimeter_radius))

func perimeter_point(index: int, total: int) -> Vector3:
	var sp := get_tree().get_first_node_in_group("stockpile")
	var center: Vector3 = (sp as Node3D).global_position if sp else Vector3.ZERO
	if total <= 0: return center
	var ang := TAU * float(index) / float(total)
	return center + Vector3(cos(ang), 0.0, sin(ang)) * perimeter_radius

func count_guards() -> int:
	var c := 0
	for m in members:
		if is_instance_valid(m) and m.get("_task_kind") == "guard" and m.get("is_busy"):
			c += 1
	return c

# a stable, self-correcting perimeter slot for ONE guard among all current
# guards. count_guards()+perimeter_point() used to be combined into a single
# snapshot taken once when a member was first assigned to guard duty — fine
# for one member at a time, but ordering several at once (e.g. the whole
# tribe) meant each member's "total" was stale the moment the next one
# joined, so their spots overlapped instead of spreading out. This recomputes
# from the CURRENT live roster every time it's called, sorted by a stable
# id so the same guard always lands in the same relative slot.
func assigned_perimeter_point(member) -> Vector3:
	var guards: Array = []
	for m in members:
		if is_instance_valid(m) and m.get("_task_kind") == "guard" and m.get("is_busy"):
			guards.append(m)
	if guards.is_empty():
		return perimeter_point(0, 1)
	guards.sort_custom(func(a, b): return a.get_instance_id() < b.get_instance_id())
	var idx := guards.find(member)
	if idx < 0:
		idx = guards.size()   # not yet counted as busy this frame — slot in past the end
	return perimeter_point(idx, max(guards.size(), idx + 1))

# ─────────────────────────────────────────────────────────────────────────────
# FENCE RING PLAN
# ─────────────────────────────────────────────────────────────────────────────
# true everywhere a ring of segments gets built around the stockpile
# (radians of angular clearance to either side of a gate angle)
const GATE_HALF_WIDTH := 0.5

func _near_gate(ang: float, gate_angles: Array) -> bool:
	for ga in gate_angles:
		if absf(wrapf(ang - ga, -PI, PI)) <= GATE_HALF_WIDTH:
			return true
	return false

func fence_ring_plan() -> Array:
	var fence_segs: Array = []
	var teepee_segs: Array = []

	# pick gate ANGLES once, shared by the fence ring AND the block wall
	# ring (_fortress_block_segments) so their openings line up into one
	# real corridor. Previously each ring picked gaps by segment INDEX with
	# a different segment count per ring, so a gap in the fence usually had
	# no matching gap in the block wall beyond it — no actual way in.
	var gate_count := 3
	var gate_angles: Array = []
	for g in range(gate_count):
		gate_angles.append(TAU * float(g) / float(gate_count))

	var count  := 18
	for i in range(count):
		var ang := TAU * float(i) / float(count)
		if _near_gate(ang, gate_angles): continue
		fence_segs.append({"kind": "fence", "pos": Vector3(cos(ang) * 7.0, 0.0, sin(ang) * 7.0), "yaw": ang + PI * 0.5})
	# a ring of teepees just inside the fence line — homes for the camp
	var teepee_count := 4
	for i in range(teepee_count):
		var ang2 := TAU * float(i) / float(teepee_count) + (TAU / float(teepee_count) * 0.5)
		teepee_segs.append({"kind": "teepee", "pos": Vector3(cos(ang2) * 4.0, 0.0, sin(ang2) * 4.0), "yaw": 0.0})
	var block_segs: Array = _fortress_block_segments(10.0, gate_angles)

	# interleave instead of append-in-order — blocks were dead last in the
	# plan, so with a single builder and a finite work timer, the fence ring
	# would finish (or time out) before the castle part ever even started.
	var plan: Array = []
	var i1 := 0; var i2 := 0; var i3 := 0
	while i1 < fence_segs.size() or i2 < teepee_segs.size() or i3 < block_segs.size():
		if i1 < fence_segs.size():
			plan.append(fence_segs[i1]); i1 += 1
		if i2 < teepee_segs.size():
			plan.append(teepee_segs[i2]); i2 += 1
		for _k in range(2):
			if i3 < block_segs.size():
				plan.append(block_segs[i3]); i3 += 1
	return plan

# GRID PATTERN — a literal square ring of block cells on the shared
# block.gd grid (BlockScript.SIZE), two courses tall, instead of blocks
# scattered along a curve at arbitrary float positions. Builders walk to
# and place at real grid coordinates (gx,gz)*SIZE, so the whole tribe
# (a whole-tribe build order splits this plan across everyone — see
# command_selected/begin_build's offset/stride) collectively raises a
# straight-edged square castle. gate_angles must match whatever ring this
# wall surrounds (fence_ring_plan passes the same angles used for the fence
# ring) so the openings actually align between rings.
func _fortress_block_segments(radius: float, gate_angles: Array) -> Array:
	var segs: Array = []
	var size: float = BlockScript.SIZE
	var n: int = maxi(2, int(round(radius / size)))
	for gx in range(-n, n + 1):
		for gz in range(-n, n + 1):
			if abs(gx) != n and abs(gz) != n:
				continue   # interior cell — only the perimeter is a wall
			var x := float(gx) * size
			var z := float(gz) * size
			if _near_gate(atan2(z, x), gate_angles): continue
			segs.append({"kind": "block", "pos": Vector3(x, 1.0, z)})
			segs.append({"kind": "block", "pos": Vector3(x, 3.0, z)})
	return segs

# ═════════════════════════════════════════════════════════════════════════════
# UI — BUILD
# All labels use PRESET_TOP_LEFT. Pixel positions are computed each frame
# from the real viewport size in _update_ui_positions() — no fractional
# anchors, no negative offsets, nothing stacked in the corner.
# ═════════════════════════════════════════════════════════════════════════════
func _build_ui() -> void:
	var ui := _get_or_create_ui()

	status_label = ui.get_node_or_null("TribeStatus")
	if status_label == null:
		status_label = Label.new()
		status_label.name = "TribeStatus"
		ui.add_child(status_label)
	status_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	status_label.custom_minimum_size = Vector2(480, 0)
	_style_label(status_label, 20)

	flash_label = Label.new()
	flash_label.name = "Flash"
	ui.add_child(flash_label)
	flash_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	flash_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	flash_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	flash_label.custom_minimum_size = Vector2(700, 0)
	_style_label(flash_label, 18)
	flash_label.visible = false

	resource_label = Label.new()
	resource_label.name = "Resources"
	ui.add_child(resource_label)
	resource_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	resource_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	resource_label.custom_minimum_size = Vector2(440, 0)
	_style_label(resource_label, 18)

	factions_label = Label.new()
	factions_label.name = "Factions"
	ui.add_child(factions_label)
	factions_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	factions_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	factions_label.custom_minimum_size = Vector2(440, 0)
	_style_label(factions_label, 14)

	player_label = Label.new()
	player_label.name = "PlayerStatus"
	ui.add_child(player_label)
	player_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_style_label(player_label, 18)

	help_label = Label.new()
	help_label.name = "Help"
	ui.add_child(help_label)
	help_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	help_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	help_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	help_label.custom_minimum_size = Vector2(900, 0)
	_style_label(help_label, 13)
	help_label.text = (
		"[M]/hold[V]+look select (tap[V]x3=whole tribe) → [1]gather [2]hunt [3]scout [4]wood [5]build "
		+ "[6]recruit [7]guard [0]auto  (+Shift small +Ctrl large)  "
		+ "[P] work plan  [O] formation  [I] perimeter\n"
		+ "[F] berries  [LMB] club/strike  [RMB] throw  [C] carve(%dwood)  "
		+ "[G] bribe  [T] scout  [Y] fence  [L] teepee(%dwood)  [N] camp(%dwood)  "
		+ "[H] feed dog  [J] rally dogs  [[ ]] focus  [K] RAID  [B] brain  [TAB] map  [Z] block(%dwood, stacks)"
	) % [CLUB_COST, TEEPEE_COST, CAMP_COST, BLOCK_COST]

	brain_panel = Control.new()
	brain_panel.name = "BrainPanel"
	brain_panel.visible = false
	brain_panel.set_script(load("res://brain_visualizer.gd"))
	ui.add_child(brain_panel)

	# always visible — never hidden by [U] so the player can always find it
	ui_hint_label = Label.new()
	ui_hint_label.name = "UIHint"
	ui.add_child(ui_hint_label)
	ui_hint_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_style_label(ui_hint_label, 14)
	ui_hint_label.text = "[U] hide UI"

	# first-run onboarding hint — visible at game start, fades permanently after
	# the player feeds a tribe member for the first time
	_feed_hint_label = Label.new()
	_feed_hint_label.name = "FeedHint"
	ui.add_child(_feed_hint_label)
	_feed_hint_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_feed_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_feed_hint_label.custom_minimum_size = Vector2(700, 0)
	_style_label(_feed_hint_label, 22)
	_feed_hint_label.text = "Walk up to a tribe member and press [E] to give food — feeding builds trust"
	_feed_hint_label.visible = false   # shown only once the game actually starts

	# _update_ui_positions() is only ever called from _process(), which
	# returns immediately while `_started` is false (still on the start
	# menu) — so every label above just sits at its construction-time
	# default position, which for a freshly-created Control is (0,0). All
	# of them stacking at the same top-left corner is exactly the "jumbled
	# text" seen before a world is even chosen. Position them correctly
	# right away instead of waiting for the game to actually start.
	_update_ui_positions()

# ─────────────────────────────────────────────────────────────────────────────
# UI — POSITION  (called every frame from _process)
# ─────────────────────────────────────────────────────────────────────────────
func _update_ui_positions() -> void:
	var vp := get_viewport().get_visible_rect().size
	var W  := vp.x
	var H  := vp.y

	# TOP-LEFT: leadership status
	if status_label:
		status_label.position = Vector2(20, 20)

	# TOP-CENTER: transient flash banner
	if flash_label:
		var fw := flash_label.custom_minimum_size.x
		flash_label.position = Vector2((W - fw) * 0.5, 20)

	# TOP-RIGHT: resources, factions just below
	if resource_label:
		resource_label.position = Vector2(W - resource_label.custom_minimum_size.x - 20, 20)
	if factions_label:
		factions_label.position = Vector2(W - factions_label.custom_minimum_size.x - 20, 56)

	# BOTTOM-LEFT: player vitals
	if player_label:
		player_label.position = Vector2(20, H - 88)

	# BOTTOM-CENTER: help / keybind bar
	if help_label:
		var hw := help_label.custom_minimum_size.x
		help_label.position = Vector2((W - hw) * 0.5, H - 64)

	# BOTTOM-LEFT corner: always-visible UI toggle
	if ui_hint_label:
		ui_hint_label.position = Vector2(20, H - 26)

	if _feed_hint_label and _feed_hint_label.visible:
		var fw := _feed_hint_label.custom_minimum_size.x
		_feed_hint_label.position = Vector2((W - fw) * 0.5, H * 0.38)

# ─────────────────────────────────────────────────────────────────────────────
# UI — UPDATE
# ─────────────────────────────────────────────────────────────────────────────
func _update_status() -> void:
	if status_label == null: return
	if won:
		status_label.text = "★★★  VICTORY — LAST TRIBE STANDING  ★★★"
		return
	if lost:
		status_label.text = "✖✖✖  DEFEAT — THE %s CONQUERED THE WORLD  ✖✖✖" % _loser_name.to_upper()
		return
	if is_leader:
		var warn := "   ⚠ a challenge brews!" if challenged else ""
		status_label.text = "TRIBE: you are LEADER  |  %d/%d backing you%s" % [
			backers, members.size(), warn]
	else:
		status_label.text = "TRIBE: earn trust to lead  |  %d/%d backing (need %d)" % [
			backers, members.size(), leadership_threshold]
	if _dominion != null and is_instance_valid(_dominion):
		status_label.text += "\n⚑ The %s rule — %ds to raze their camp!" % [
			_dominion.tribe_name, int(maxf(0.0, _dominion_timer))]

	if resource_label:
		resource_label.text = "Food: %d   Skins: %d   Clubs: %d   Wood: %d   Tribes: %d known / %d out there" % [
			food, materials, clubs, wood, _known_tribe_count(), _live_tribe_count()]

func _update_flash() -> void:
	if flash_label == null: return
	if _flash_timer > 0.0 and not _ui_hidden:
		flash_label.visible = true
		flash_label.text    = "» %s" % _flash_text
	else:
		flash_label.visible = false

func _update_player_label() -> void:
	if player_label == null: return
	var p := get_tree().get_first_node_in_group("player")
	var hunger  := 0.0
	var php     := 100.0
	if p and "hunger" in p: hunger = p.hunger
	if p and "hp"     in p: php    = p.hp
	var warn := "   ⚠ STARVING — eat!" if hunger >= 100.0 else ""
	var foc  := ""
	if focus_tribe != null and is_instance_valid(focus_tribe):
		foc = "   ▶ target: %s (str %d)" % [focus_tribe.tribe_name, focus_tribe.strength]
	player_label.text = "YOU — HP %d   Hunger %d%%%s%s" % [int(php), int(hunger), warn, foc]

func _update_factions_label() -> void:
	if factions_label == null: return
	if factions.is_empty():
		factions_label.text = "Sub-tribes: none yet"
		return
	var parts: Array = []
	for f in factions:
		var star := "  ★%d" % int(f["backers"]) if int(f["backers"]) > 0 else ""
		parts.append("%s(%d%s)" % [f["name"], int(f["size"]), star])
	factions_label.text = "Sub-tribes: " + ", ".join(parts)

func _update_feed_hint(delta: float) -> void:
	if _feed_hint_label == null or not _feed_hint_label.visible:
		return
	var fed := false
	for m in members:
		if is_instance_valid(m) and int(m.get("feed_count")) > 0:
			fed = true
			break
	if fed:
		_feed_hint_alpha = maxf(0.0, _feed_hint_alpha - delta / 2.5)
		_feed_hint_label.modulate = Color(1, 1, 1, _feed_hint_alpha)
		if _feed_hint_alpha <= 0.0:
			_feed_hint_label.visible = false

func _update_brain_panel() -> void:
	if brain_panel == null or not brain_panel.visible: return
	var vp := get_viewport().get_visible_rect().size
	brain_panel.size     = Vector2(360, 260)
	brain_panel.position = Vector2(vp.x - 376, 16)
	brain_panel.set("member", _nearest_brain_to_player())

func _toggle_brain_panel() -> void:
	if brain_panel: brain_panel.visible = not brain_panel.visible

# ─────────────────────────────────────────────────────────────────────────────
# WORLD MAP — [TAB]. Every existing camp shows up immediately as a dot (the
# player always knows roughly how the world is laid out) but stays an
# anonymous gray dot — no name, no real color — until that tribe is
# `discovered` (scout with [T], or just walk close — see
# _check_proximity_discovery below). Built lazily on first open.
# ─────────────────────────────────────────────────────────────────────────────
const MapView = preload("res://map_view.gd")
var _map_panel: Control = null
var _map_redraw_accum: float = 0.0

func _toggle_map() -> void:
	if _map_panel == null:
		var ui := _get_or_create_ui()
		_map_panel = Control.new()
		_map_panel.name = "WorldMap"
		_map_panel.set_script(MapView)
		ui.add_child(_map_panel)
	_map_panel.visible = not _map_panel.visible
	if _map_panel.visible:
		_update_map()

func _update_map() -> void:
	var vp := get_viewport().get_visible_rect().size
	var sz := minf(vp.x, vp.y) * 0.82
	_map_panel.size = Vector2(sz, sz)
	_map_panel.position = (vp - _map_panel.size) * 0.5

	var p := get_tree().get_first_node_in_group("player")
	if p and is_instance_valid(p):
		_map_panel.player_pos = Vector2((p as Node3D).global_position.x, (p as Node3D).global_position.z)
		_map_panel.player_dir = (p as Node3D).rotation.y

	_map_panel.world_extent = MAP_EXTENT
	var arr: Array = []
	for t in world_tribes:
		if is_instance_valid(t) and not t.defeated:
			arr.append({
				"pos": Vector2(t.global_position.x, t.global_position.z),
				"color": t.color,
				"name": t.tribe_name,
				"discovered": t.discovered,
			})
	_map_panel.tribes = arr
	_map_panel.queue_redraw()

# walking near an undiscovered camp reveals it, same as scouting with [T] —
# scouting (longer range, deliberate) and proximity (just stumbling up to
# one) are now both valid ways to learn a camp's name and allegiance.
const WALK_DISCOVER_RANGE := 16.0
var _discover_check_accum: float = 0.0

func _check_proximity_discovery(delta: float) -> void:
	_discover_check_accum -= delta
	if _discover_check_accum > 0.0:
		return
	_discover_check_accum = 0.5
	var p := get_tree().get_first_node_in_group("player")
	if p == null or not is_instance_valid(p):
		return
	var ppos: Vector3 = (p as Node3D).global_position
	for t in world_tribes:
		if is_instance_valid(t) and not t.defeated and not t.discovered:
			if ppos.distance_to(t.global_position) <= WALK_DISCOVER_RANGE:
				t.discover()
				var line: String = t.greeting() if t.has_method("greeting") else ""
				_flash("You stumble onto the %s camp — %s, strength %d.%s" % [
					t.tribe_name, t.archetype, t.strength,
					"\n\"%s\"" % line if line != "" else ""])

func _toggle_ui() -> void:
	_ui_hidden = not _ui_hidden
	for l in [status_label, resource_label, help_label, player_label, factions_label]:
		if l: l.visible = not _ui_hidden
	if flash_label    and _ui_hidden: flash_label.visible   = false
	if brain_panel    and _ui_hidden: brain_panel.visible   = false
	if ui_hint_label:
		ui_hint_label.text = "[U] show UI" if _ui_hidden else "[U] hide UI"

func _style_label(l: Label, fs: int) -> void:
	l.add_theme_color_override("font_color",         Color(1, 1, 1))
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	l.add_theme_constant_override("outline_size",    5)
	l.add_theme_font_size_override("font_size",      fs)

# ═════════════════════════════════════════════════════════════════════════════
# HELPERS
# ═════════════════════════════════════════════════════════════════════════════
func _get_or_create_ui() -> Node:
	var ui := get_node_or_null("../UI")
	if ui == null:
		ui      = CanvasLayer.new()
		ui.name = "UI"
		get_parent().add_child(ui)
	return ui

func _flash(t: String, duration: float = 5.0) -> void:
	_flash_text  = t
	_flash_timer = duration

func _nearest_brain_to_player():
	var brains  := get_tree().get_nodes_in_group("has_brain")
	if brains.is_empty(): return null
	var players := get_tree().get_nodes_in_group("player")
	if players.is_empty(): return brains[0]
	var p := players[0] as Node3D
	var best = null; var bd := INF
	for b in brains:
		if not is_instance_valid(b): continue
		var d: float = (b.global_position - p.global_position).length()
		if d < bd: bd = d; best = b
	return best

func _key_just(code: int) -> bool:
	var down := Input.is_key_pressed(code)
	var was: bool = _keys_down.get(code, false)
	_keys_down[code] = down
	return down and not was

func _random_personality() -> String:
	return PERSONALITY_POOL[randi() % PERSONALITY_POOL.size()]

func _edge_position() -> Vector3:
	var ang := randf() * TAU
	return Vector3(cos(ang) * 40.0, 1.0, sin(ang) * 40.0)
