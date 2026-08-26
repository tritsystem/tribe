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
## ZEROED (2026-07-19): "my tribe should be 0% food, my members should feed
## them until they earn access to stockpile" -- a free 16-food head start
## meant the whole "earn your way onto the stockpile" trust economy
## (test_stockpile_access.gd -- Acquaintance+ before self-feeding from it)
## never actually got exercised at the very start of a game; there was
## always a painless buffer to coast on first. Real members personally
## feeding the player/each other (_maybe_share_food(), the founding
## companion's own _maybe_feed_a_stranger()) is what's meant to carry the
## tribe through this gap now, not a starting handout.
@export var starting_food: int          = 0
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
# Only a wipeout the PLAYER caused ends the game (see _check_victory). The AI
# left alone trends to peace, so this essentially never trips on its own.
var _player_caused_wipeout: bool = false

# Terrain: a flag so it can be switched off in one place if it misbehaves, and a
# seed so a world regenerates identically (persistence stores the seed only).
const USE_TERRAIN := true
var _terrain_seed: int = 12345
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
	notify_cat(CAT_YOU, "Looted %d %s from the fallen camp! (forge a masterwork club with [C])" % [amount, mat_name])  # player looted

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

# ── FORTRESS EXPANSION + MATERIAL UPGRADES (2026-07-22) ────────────────────
# Previously fortress_built was a one-shot flag: the tribe raised ONE
# fortress and then suggest_job() never proposed "build" again, ever.
# fortress_tier replaces that dead end with real, repeated growth -- each
# completed ring bumps the tier, fence_ring_plan() scales radius/gate count/
# teepee count with it, and suggest_job() keeps proposing bigger builds
# (gated by steeper wood/member requirements per tier, same as the original
# one-shot gate's own resource check) until MAX_FORTRESS_TIER.
#
# material_tier is the separate "better material" upgrade: a wooden fortress
# can become a stone one, then a metal one, as the tribe accumulates real
# `materials` (skins) -- see try_upgrade_material()/_material_upgrade_tick().
# It's genuinely mechanical, not a repaint: block.gd's own TIER_HP means a
# Stone/Metal wall actually outlasts a Wood one, and every NEW block placed
# after an upgrade uses the tribe's current best material automatically.
const MAX_FORTRESS_TIER    := 4
const FORTRESS_BASE_RADIUS := 10.0
const FORTRESS_RADIUS_GROWTH := 4.0
var fortress_tier: int = 0

# PERF BUG FIX (2026-07-24): each tier used to ADD a whole new, bigger ring
# on top of the previous one -- the old ring was never removed, so a tribe
# that reached MAX_FORTRESS_TIER accumulated FOUR overlapping rings' worth
# of real StaticBody3D+collision nodes (roughly 128+178+196+240 = 742 for
# this tribe alone), which is a real, measured contributor to "game crashed,
# its super laggy" once expansion had run a few cycles. fence_ring_plan()
# now clears the PREVIOUS tier's tracked pieces the moment a NEW tier's
# plan is actually requested (see _fortress_pieces/_fortress_pieces_tier),
# so at most one ring's worth of real nodes exists at a time -- the
# fortress still reads as "keeps growing bigger and better" (each ring IS
# strictly larger/more elaborate than the last), it just doesn't leave
# every previous ring standing as dead weight underneath it.
var _fortress_pieces: Array = []
var _fortress_pieces_tier: int = -1

func _track_fortress_piece(n) -> void:
	if n != null and is_instance_valid(n):
		_fortress_pieces.append(n)

func _clear_fortress_ring() -> void:
	for n in _fortress_pieces:
		if is_instance_valid(n):
			n.queue_free()
	_fortress_pieces.clear()

const MATERIAL_TIER_NAMES := ["Wood", "Stone", "Metal"]
# materials needed to REACH that tier index (index 0 is free -- you start in Wood)
const MATERIAL_UPGRADE_COST := [0, 40, 90]
var material_tier: int = 0
var _material_upgrade_cd: float = 8.0

# ── ENVIRONMENT / WEATHER (2026-07-22) ──────────────────────────────────────
# A real, mechanical weather cycle -- not just an announcement. current_weather
# changes on a randomized timer and has two genuine effects other systems
# actually read: visibility_mult() scales every vision-gated pick/sense check
# in tribemember.gd (fog/storm means members work with a smaller effective
# SIGHT_RADIUS and are more likely to be caught off guard by a raider they
# didn't see coming), and hunger_mult() scales hunger drain (a storm is cold
# and miserable, not free). Visuals piggyback on the SAME WorldEnvironment/
# DirectionalLight3D lookup graphics_quality.gd already uses, so a real storm
# actually looks darker and hazier, not just a text notification.
enum Weather { CLEAR, RAIN, STORM, FOG }
const WEATHER_NAMES := ["Clear", "Rain", "Storm", "Fog"]
const WEATHER_VISIBILITY := { Weather.CLEAR: 1.0, Weather.RAIN: 0.7, Weather.STORM: 0.45, Weather.FOG: 0.5 }
const WEATHER_HUNGER_MULT := { Weather.CLEAR: 1.0, Weather.RAIN: 1.05, Weather.STORM: 1.25, Weather.FOG: 1.0 }
# CLEAR weighted heaviest so bad weather is a real event, not half of all time
const WEATHER_CHOICES := [Weather.CLEAR, Weather.CLEAR, Weather.CLEAR, Weather.RAIN, Weather.STORM, Weather.FOG]
const WEATHER_MIN_DURATION := 60.0
const WEATHER_MAX_DURATION := 180.0

var current_weather: int = Weather.CLEAR
var _weather_timer: float = 20.0   # a short calm start before the first shift
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
const STAIR_COST      := 1   # same grade as a wall block — it's a wall block cut in half
const ROOF_COST       := 2   # a capping piece; costs a bit more than a plain wall course
const SMALL_COST      := 1   # fine-detail unit — small, so priced like a stair
const DOOR_COST       := 2   # a real hinged slab, priced like a roof
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
# DIVERSITY PASS (2026-07-19): weighted so common/low-yield species (Rabbit,
# Hare, Deer) still dominate the population, with rarer/tougher ones
# (Wolf, Bear) genuinely uncommon -- matches animal.gd's own SPECIES table.
const ANIMAL_POOL := [
	"Rabbit", "Rabbit", "Rabbit", "Hare", "Hare",
	"Deer", "Deer", "Deer", "Fox", "Goat",
	"Boar", "Boar", "Elk", "Wolf", "Bear",
]
const BUSH_POOL := [
	"Berries", "Berries", "Berries", "Herbs", "Herbs",
	"Roots", "Mushrooms", "Nuts", "Wild Grain",
]
const TREE_POOL := ["Oak", "Pine", "Pine", "Birch", "Willow", "Cedar"]
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
# ── the knobs that decide whether this world settles into commerce or war ──
# WAR_PRESSURE_MIN: below this a tribe is fed enough that it simply will not
#   march. Raise it for a peaceful world, lower it for a desperate one.
const WAR_PRESSURE_MIN := 0.55   # raised from 0.35: war is now a LAST resort. A
	# tribe has to be genuinely desperate, not just a bit peckish, before it
	# marches -- the world should be "mostly harmonious" and only tip into
	# violence under real strain (see the environmental shocks below).
const TRADE_GRUDGE_MAX := 0.7    # raised from 0.55: they'll deal across all but
	# outright blood feuds, so trade is the norm and war the exception.
const TRADE_GOODWILL := 0.14     # a completed trade cools the grudge both ways
const TRADE_BOND := 0.12         # ...and warms the alliance bond. Repeated trade
	# crosses ALLY_THRESHOLD (0.5) in ~4-5 deals -> a formal alliance forms.
const TRADE_RANGE := 130.0       # tribes must be near enough to actually carry
	# goods between camps. No more instant trades across the whole map -- a
	# caravan has to be plausible. Distant tribes simply aren't trade partners.

# ── PHYSICAL TRADE ENVOYS ──
# A wanted trade no longer settles instantly: the buyer dispatches a walking
# ENVOY (trade_envoy.gd) that carries a note to the seller's camp and only THEN
# closes the deal (see _on_envoy_arrived). This gives trade a visible, physical
# presence and makes distance/alliance actually cost time. The instant _try_trade
# is kept as the crisis-relief path (war resolution) where waiting isn't an option.
const ENVOY_MAX_IN_FLIGHT := 4   # keep the world readable; a few caravans at once
const ENVOY_ALLY_FOOD_BONUS := 0.30  # allies deal on better terms: +30% food back
var _active_envoys: Array = []   # trade_envoy.gd nodes currently walking
var _envoy_pairs: Dictionary = {} # "A|B" -> true, so one pair never double-dispatches

const FORMATION_KINDS    := ["loose", "phalanx", "wedge", "testudo"]
const PERIMETER_PRESETS  := [10.0, 16.0, 24.0, 34.0]

# ─────────────────────────────────────────────────────────────────────────────
# GAME SCALE
# ─────────────────────────────────────────────────────────────────────────────
enum Scale { SKIRMISH, STANDARD, EPIC, MASSIVE }

const SCALE_PRESETS := {
	Scale.SKIRMISH: {
		"name": "Skirmish", "minutes": "~5 min",
		"tribes": 24, "tribe_cap": 24, "start_size": 2, "player_cap": 30,
		"neutrals": 26, "animals": 90, "bushes": 30, "trees": 1000,
		"dogs": 10, "war_interval": 5.0,  "dominion": 60.0, "map_extent": 230.0,
		"islands": false,
	},
	Scale.STANDARD: {
		"name": "Standard", "minutes": "~12 min",
		"tribes": 34, "tribe_cap": 50, "start_size": 3, "player_cap": 50,
		"neutrals": 45, "animals": 140, "bushes": 44, "trees": 1800,
		"dogs": 17, "war_interval": 9.0,  "dominion": 100.0, "map_extent": 300.0,
		"islands": false,
	},
	Scale.EPIC: {
		"name": "Epic",     "minutes": "~30 min",
		"tribes": 48, "tribe_cap": 80, "start_size": 4, "player_cap": 70,
		"neutrals": 70, "animals": 200, "bushes": 60, "trees": 2600,
		"dogs": 28, "war_interval": 13.0, "dominion": 150.0, "map_extent": 420.0,
		"islands": true,
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
		"islands": true,
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

# ─────────────────────────────────────────────────────────────────────────────
# CATEGORIZED NOTIFICATION BOXES (three stacked logs down the RIGHT edge).
# "tribes" = wider-world / rival-tribe events; "tribe" = the player's OWN tribe
# and its members; "you" = the player's own actions/status. Each box keeps the
# most recent few lines; lines expire after CAT_LINE_TTL seconds.
# ─────────────────────────────────────────────────────────────────────────────
const CAT_TRIBES: String = "tribes"   # rival/world events
const CAT_TRIBE:  String = "tribe"    # the player's own tribe / members
const CAT_YOU:    String = "you"      # the player's own actions / status
const CAT_LINE_TTL:  float = 8.0
const CAT_MAX_LINES: int   = 5
var _cat_boxes: Dictionary = {}   # category -> Label (with dark stylebox)
var _cat_lines: Dictionary = {}   # category -> Array[{ "text": String, "t": float }]
const CAT_TITLES: Dictionary = {
	"tribes": "TRIBES",
	"tribe":  "YOUR TRIBE",
	"you":    "YOU",
}

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
	# keep game_scale in lockstep with what we're applying: _build_terrain reads
	# SCALE_PRESETS[game_scale]["islands"], so if a caller applied a scale without
	# also setting game_scale, islands (and the scale name) would silently read
	# the wrong preset. _choose_scale already sets both; this makes it robust
	# against any future caller that forgets.
	game_scale = s
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

	# NEW GAME: no save file means this is a genuinely fresh playthrough -- wipe
	# any memory/vault notes left over from an earlier one before anything in
	# this run can write new memories, or the LLM would read last game's
	# betrayals and conversations back as if they'd happened in this one.
	if not TribePersist.has_save():
		TribeMemory.reset_all()

	# RESTORE + CATCH UP. The world is now fully spawned; if a save exists, overlay
	# it and fast-forward by the real time you were away, then tell you what
	# changed. Runs once here, after everything exists to apply state onto.
	var recap: String = TribePersist.load_and_catch_up()
	if recap != "":
		_flash(recap, 16.0)
		print("[PERSIST] ", recap.replace("\n", " | "))
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
		notify_cat(CAT_YOU, "No loyal dogs yet — feed a stray with [H].")
	else:
		notify_cat(CAT_YOU, "Dogs %s — %d loyal." % [
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
	# EXPERT RECRUITER, BASE-LINE (2026-07-19): "the base companion every
	# tribe starts with is an expert recruiter and feeds strangers to at
	# least 30% as a base" -- the very first companion has no one to have
	# earned this from (there's no elder to have practiced Recruiting under
	# yet), so it's innate rather than practiced like every other profession
	# skill. Skill maxed at the "Expert" tier bar (see SKILL_TIER_STEP) and
	# marked so is_founding_recruiter's own baseline behaviors kick in.
	if "profession" in s: s.profession = "Recruiting"
	if "profession_skill" in s: s.profession_skill["Recruiting"] = 75.0
	if "is_founding_recruiter" in s: s.is_founding_recruiter = true
	print("Your loyal Companion stands with you -- a natural recruiter.")

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
	_spawn_campfire(Vector3(3.0, 0.0, 3.0))

## Every camp gets a real campfire (2026-07-19: "make campfires real" --
## previously the LLM claimed one existed with nothing built; see
## campfire.gd's own header). Seated just off the stockpile, close enough to
## be the obvious night gathering point.
func _spawn_campfire(pos: Vector3) -> void:
	var fire := StaticBody3D.new()
	fire.set_script(load("res://campfire.gd"))
	add_child(fire)
	fire.global_position = Vector3(pos.x, ground_y(pos.x, pos.z) + 0.05, pos.z)

# ── CLAN EXPANSION: outpost stockpiles (2026-07-20) ─────────────────────────
# A member who's genuinely wandered far out (see tribemember.gd's
# _search_streak / EXPANSION_SEARCH_STREAK) can found a new stockpile right
# where they're standing -- but only one per OUTPOST_MIN_SPACING radius, so
# expansion actually spreads the clan across the map instead of clustering a
# pile of stockpiles on top of each other the moment one member wanders off.
#
# HONEST SCOPE: this reuses stockpile.gd's own display, which already just
# mirrors this SINGLE manager's food/wood/materials/clubs totals (see its
# _process()) -- there is one tribe economy in this codebase, not a
# per-camp inventory system. An outpost is a real, distinctly-grouped world
# object (group "outpost_stockpile", deliberately NOT "stockpile" -- roughly
# a dozen call sites in this file assume get_first_node_in_group("stockpile")
# resolves to the ONE home camp, e.g. where raid members return to; adding
# outposts to that same group would make those sites nondeterministic) that
# visibly marks the clan's expansion and enforces real geographic spread,
# without silently faking a multi-economy simulation this codebase doesn't
# actually have.
const OUTPOST_MIN_SPACING := 100.0
var outposts: Array = []

# CITIES (2026-07-29): the first real step past "a stockpile marker" toward
# an actual named settlement -- a real name (so the clan's expansion reads
# as founding a PLACE, not just planting an economy prop) and a couple of
# teepees actually standing there, so it looks like somewhere people live.
# Built directly here rather than through try_build_teepee(): that function
# both build-range-gates against the HOME stockpile (which an outpost, by
# definition, is 100m+ away from -- it would always reject) and tracks the
# piece for fortress-ring cleanup, which is wrong for a structure that
# belongs to a separate settlement, not the home ring (see
# _clear_fortress_ring()'s own comment -- it clears ALL tracked pieces on
# a tier change, home ring or not).
const SETTLEMENT_PREFIXES := ["North", "South", "East", "West", "Far", "New", "Little", "Great"]
const SETTLEMENT_SUFFIXES := ["Hollow", "Reach", "Landing", "Hearth", "Rest", "Watch", "Bend", "Crossing"]

func _generate_settlement_name() -> String:
	var pre: String = SETTLEMENT_PREFIXES[randi() % SETTLEMENT_PREFIXES.size()]
	var suf: String = SETTLEMENT_SUFFIXES[randi() % SETTLEMENT_SUFFIXES.size()]
	return "%s %s" % [pre, suf]

func found_outpost(pos: Vector3) -> bool:
	for grp in ["stockpile", "outpost_stockpile"]:
		for s in get_tree().get_nodes_in_group(grp):
			var sn := s as Node3D
			if sn and is_instance_valid(sn) and sn.global_position.distance_to(pos) < OUTPOST_MIN_SPACING:
				return false
	var settlement_name: String = _generate_settlement_name()
	var district: String = DISTRICT_TYPES[randi() % DISTRICT_TYPES.size()]
	var sp := Node3D.new()
	sp.name = "OutpostStockpile"
	sp.set_script(load("res://stockpile.gd"))
	add_child(sp)
	sp.global_position = pos
	sp.set("manager", self)
	sp.set("settlement_name", settlement_name)
	sp.set("district", district)
	sp.remove_from_group("stockpile")
	sp.add_to_group("outpost_stockpile")
	outposts.append(sp)
	_build_district_structures(district, pos)
	notify_cat("tribe", "The clan has founded %s -- a %s settlement far from camp." % [settlement_name, district])
	return true

## Every settlement's baseline homes plus a real structure distinct to its
## district, not just a different name. Split out from found_outpost() so
## the actual construction is directly testable without depending on the
## random district roll.
func _build_district_structures(district: String, pos: Vector3) -> void:
	var teepee_count: int = 3 if district == "Gathering" else 2
	for i in range(teepee_count):
		var ang := TAU * float(i) / float(teepee_count) + randf() * 0.3
		var hut_pos: Vector3 = pos + Vector3(cos(ang) * 3.0, 0.0, sin(ang) * 3.0)
		var hut := StaticBody3D.new()
		hut.set_script(load("res://teepee.gd"))
		add_child(hut)
		hut.global_position = Vector3(hut_pos.x, ground_y(hut_pos.x, hut_pos.z) + 2.5, hut_pos.z)
	match district:
		"Watch":
			# a genuine lookout tower -- real height (3 block courses + a
			# roof cap), matching the mechanical sight bonus below.
			for course in range(3):
				var b := StaticBody3D.new()
				b.set_script(load("res://block.gd"))
				add_child(b)
				b.global_position = Vector3(pos.x, ground_y(pos.x, pos.z) + 1.0 + float(course) * 2.0, pos.z + 4.0)
			var roof := StaticBody3D.new()
			roof.set_script(BuildPieceScript)
			roof.kind = BuildPieceScript.Kind.ROOF
			add_child(roof)
			roof.global_position = Vector3(pos.x, ground_y(pos.x, pos.z) + 1.0 + 3.0 * 2.0, pos.z + 4.0)
		"Crafting":
			# a workshop marker -- a single worked block, distinct from the
			# raw wall material a fortress course uses.
			var workshop := StaticBody3D.new()
			workshop.set_script(load("res://block.gd"))
			workshop.material_tier = maxi(1, material_tier)
			add_child(workshop)
			workshop.global_position = Vector3(pos.x + 4.0, ground_y(pos.x + 4.0, pos.z) + 1.0, pos.z)
			# REAL WORKSTATION (2026-07-19): "make sure both npc and player
			# tribes are creating blacksmiths" -- a Crafting settlement now
			# raises an actual named forge (blacksmith_forge.gd), not just an
			# unlabeled block. crafting_discount_at() already applies here via
			# RESIDENCE_RADIUS -- this is the visible structure that payoff
			# was always missing.
			var forge := StaticBody3D.new()
			forge.set_script(load("res://blacksmith_forge.gd"))
			add_child(forge)
			forge.global_position = Vector3(pos.x - 4.0, ground_y(pos.x - 4.0, pos.z) + 1.0, pos.z)
		"Gathering":
			pass   # the extra teepee above IS gathering's own distinct structure

const DISTRICT_TYPES := ["Watch", "Gathering", "Crafting"]
const WATCH_SIGHT_BONUS := 1.3   # a lookout tower genuinely extends how far residents see

## Real mechanical payoff for district specialization -- a member living
## near a "Watch" settlement sees farther, checked the same way weather's
## visibility_mult() already scales a member's effective sight radius.
func sight_bonus_at(pos: Vector3) -> float:
	for o in outposts:
		if is_instance_valid(o) and str(o.get("district")) == "Watch" \
				and (o as Node3D).global_position.distance_to(pos) <= RESIDENCE_RADIUS:
			return WATCH_SIGHT_BONUS
	return 1.0

# DISTRICT BONUSES (2026-08-03): Watch got a real payoff (sight_bonus_at,
# above) when districts first shipped; Gathering and Crafting only got
# distinct STRUCTURES, no actual mechanical effect -- a real, flagged gap.
# Closed the same way: read by tribemember.gd wherever the matching action
# already happens (_do_gather(), gear crafting), gated on RESIDENCE_RADIUS
# the same way sight_bonus_at() already is.
const GATHERING_YIELD_BONUS := 1.25   # a Gathering settlement's foragers bring back more
const CRAFTING_COST_DISCOUNT := 0.75  # a Crafting settlement's workshop cuts material cost

func gathering_bonus_at(pos: Vector3) -> float:
	var bonus := 1.0
	for o in outposts:
		if is_instance_valid(o) and str(o.get("district")) == "Gathering" \
				and (o as Node3D).global_position.distance_to(pos) <= RESIDENCE_RADIUS:
			bonus = GATHERING_YIELD_BONUS
			break
	if dominant_ideology() == "Hearthkeepers":
		bonus *= IDEOLOGY_HEARTH_GATHER_BONUS
	return bonus

# ── EMERGENT SOCIETAL IDEOLOGY (2026-07-19) ─────────────────────────────────
# Not a slider or a player choice -- read out of the tribe's ACTUAL, current
# personality mix (courage, from PERSONALITIES) and its actual cohesion
# (average relationship/trust). Two tribes with the same members in a
# different emotional state genuinely register as a different "ideology",
# and it can change on its own as members drift (see tribemember.gd's
# _maybe_shift_personality) or bond/fray.
const IDEOLOGY_COHESION_BAR := 1.2      # avg relationship needed to call the tribe "united" at all
const IDEOLOGY_COURAGE_BAR  := 5.0      # avg courage needed to call it "bold" rather than "cautious"
const IDEOLOGY_HEARTH_GATHER_BONUS := 1.10   # a united, cautious tribe forages more carefully/thoroughly

func dominant_ideology() -> String:
	var alive: Array = []
	for m in members:
		if is_instance_valid(m):
			alive.append(m)
	if alive.is_empty():
		return "Undefined"
	var total_courage := 0.0
	var total_rel := 0.0
	for m in alive:
		total_courage += float(m.courage()) if m.has_method("courage") else 0.0
		total_rel += float(m.get("relationship"))
	var avg_courage: float = total_courage / alive.size()
	var avg_rel: float = total_rel / alive.size()
	if avg_rel < IDEOLOGY_COHESION_BAR:
		return "Fractured"
	return "Warband" if avg_courage >= IDEOLOGY_COURAGE_BAR else "Hearthkeepers"

# ── TRIBE OVERVIEW (2026-07-19): "a better UI, include everything the game
# has to offer" -- one real data aggregator backing a single dashboard
# (tribe_overview.gd) that surfaces every system built this session in one
# place: resources, leadership/throne, ideology, the roster with rank/role/
# profession, the Official hierarchy, settlements, and active rivalries.
# Nothing here is new game logic -- it's read-only, gathered from state that
# already exists all over this file and tribemember.gd.
func overview_data() -> Dictionary:
	var roster: Array = []
	for m in members:
		if not is_instance_valid(m):
			continue
		roster.append({
			"name": str(m.get("member_name")),
			"rank": str(m.get("current_rank")),
			"role": str(m.get("social_role")),
			"profession": str(m.get("profession")),
			"profession_tier": m.skill_tier(str(m.get("profession"))) if m.has_method("skill_tier") and str(m.get("profession")) != "" else "",
			"relationship": float(m.get("relationship")),
			"is_official": is_official(m),
		})
	var settlements: Array = []
	for o in outposts:
		if is_instance_valid(o):
			settlements.append({
				"name": str(o.get("settlement_name")),
				"district": str(o.get("district")),
			})
	var rivals: Array = []
	for k in rivalries.keys():
		if float(rivalries[k]) > 0.01:
			rivals.append({"tribe_name": k, "rivalry": float(rivalries[k])})
	return {
		"throne_name": throne_name,
		"is_leader": is_leader,
		"npc_leader_name": npc_leader_name,
		"food": food, "wood": wood, "materials": materials,
		"ideology": dominant_ideology(),
		"unrest": unrest,
		"roster": roster,
		"official_quota": official_quota(),
		"settlements": settlements,
		"rivalries": rivals,
	}

func crafting_discount_at(pos: Vector3) -> float:
	for o in outposts:
		if is_instance_valid(o) and str(o.get("district")) == "Crafting" \
				and (o as Node3D).global_position.distance_to(pos) <= RESIDENCE_RADIUS:
			return CRAFTING_COST_DISCOUNT
	return 1.0

# ── SOCIETAL HIERARCHY (2026-08-03) ─────────────────────────────────────────
# The "small select group of officials" side of tribemember.gd's social_role
# system lives HERE rather than per-member, because "who's an Official" is a
# genuinely TRIBE-WIDE comparison (the most loyal, relative to everyone
# else), not something one member can answer about themselves in isolation.
# The quota itself GROWS with the tribe (roughly one Official per 10
# members, always at least one, never more than a real minority) -- a
# bigger tribe has room for a bigger (but still small) governing circle.
func official_quota() -> int:
	return maxi(1, int(ceil(float(members.size()) / 10.0)))

## Is `member` one of the tribe's Officials right now? Only ever true for a
## Devoted member (checked by the caller too, but re-checked here so this
## stays correct even if called directly) who ranks in the top
## official_quota() by relationship among every OTHER Devoted member --
## reaching Devoted rank alone is not enough on its own; officialdom is a
## real, scarce, comparative honor.
func is_official(member) -> bool:
	if not is_instance_valid(member) or str(member.get("current_rank")) != "Devoted":
		return false
	var devoted: Array = []
	for m in members:
		if is_instance_valid(m) and str(m.get("current_rank")) == "Devoted":
			devoted.append(m)
	devoted.sort_custom(func(a, b): return float(a.get("relationship")) > float(b.get("relationship")))
	var quota: int = official_quota()
	for i in range(mini(quota, devoted.size())):
		if devoted[i] == member:
			return true
	return false

## Is `pos` (a member's own home_pos) at one of the tribe's founded
## settlements? Backs the "Outpostman" role -- earned by literally having
## founded or migrated to a settlement (see tribemember.gd's
## _begin_fallback()/_start_migrate(), which are the only two places
## home_pos ever moves off the original camp), not just a job tally.
func is_outpostman(pos: Vector3) -> bool:
	for o in outposts:
		if is_instance_valid(o) and (o as Node3D).global_position.distance_to(pos) <= RESIDENCE_RADIUS:
			return true
	return false

## The outpost stockpile `pos` is resident at, or null if `pos` isn't at any
## founded settlement (the main camp, or nowhere).
func _outpost_at(pos: Vector3):
	for o in outposts:
		if is_instance_valid(o) and (o as Node3D).global_position.distance_to(pos) <= RESIDENCE_RADIUS:
			return o
	# TRUST PARITY (2026-07-19): a forward camp (player_camp.gd) now gets the
	# exact same local-economy treatment a founded outpost settlement does --
	# same resolution helper, same RESIDENCE_RADIUS, same trust gate on the
	# member's own rank. See player_camp.gd's own local_food/wood/materials.
	for c in get_tree().get_nodes_in_group("player_camp"):
		if is_instance_valid(c) and (c as Node3D).global_position.distance_to(pos) <= RESIDENCE_RADIUS:
			return c
	return null

# PER-SETTLEMENT ECONOMIES (2026-08-04): previously flagged as an honest,
# unimplemented gap ("there is one tribe economy in this codebase, not a
# per-camp inventory system" -- see found_outpost()'s own scope note when
# outposts first shipped). A resident (home_pos at a founded outpost) now
# deposits into and draws from THAT settlement's own local_food/local_wood/
# local_materials (stockpile.gd) instead of the shared camp economy -- a
# real, separate stockpile, not just a different display. A non-resident
# (home_pos not at any outpost, which is everyone before this feature and
# everyone at the main camp after it) behaves EXACTLY as before through the
# plain add_food()/spend_food()/etc. these wrap -- nothing about the main
# camp's own economy changes.
#
# SCOPE: this covers a resident's own personal economic actions (gathering/
# hunting deposits, self-feeding, crafting) -- the clearest, safest slice.
# Fortress/settlement CONSTRUCTION costs (try_build_*, found_outpost's own
# material_tier upgrades) still draw from the one shared wood/materials pool
# regardless of where the builder lives; splitting those too would need
# building itself to become settlement-aware, a separate, larger change.
func add_food_at(pos: Vector3, n: int) -> void:
	var o = _outpost_at(pos)
	if o: o.local_food += n
	else: add_food(n)

func add_wood_at(pos: Vector3, n: int) -> void:
	var o = _outpost_at(pos)
	if o: o.local_wood += n
	else: add_wood(n)

func add_materials_at(pos: Vector3, n: int) -> void:
	var o = _outpost_at(pos)
	if o: o.local_materials += n
	else: add_materials(n)

func spend_food_at(pos: Vector3, n: int) -> bool:
	var o = _outpost_at(pos)
	if o:
		if o.local_food >= n:
			o.local_food -= n
			return true
		return false
	return spend_food(n)

func spend_materials_at(pos: Vector3, n: int) -> bool:
	var o = _outpost_at(pos)
	if o:
		if o.local_materials >= n:
			o.local_materials -= n
			return true
		return false
	return spend_materials(n)

# MIGRATION (2026-07-31): so a member can find and join an EXISTING
# settlement instead of only the founder ever living there. Residency is
# read straight off each member's own home_pos (the same field
# tribemember.gd's _begin_fallback()/_start_migrate() re-anchor on
# arrival) -- no separate roster to keep in sync.
const RESIDENCE_RADIUS := 20.0

func _resident_count(pos: Vector3) -> int:
	var c := 0
	for m in members:
		if is_instance_valid(m) and "home_pos" in m and (m.home_pos as Vector3).distance_to(pos) <= RESIDENCE_RADIUS:
			c += 1
	return c

## The least-populated founded settlement that `exclude_near` (a member's
## OWN current home_pos) isn't already living at -- so this never suggests
## "migrating" to the settlement a member already calls home.
func least_populated_outpost(exclude_near: Vector3):
	var best = null
	var best_count := 999999
	for o in outposts:
		if not is_instance_valid(o):
			continue
		var opos: Vector3 = (o as Node3D).global_position
		if opos.distance_to(exclude_near) <= RESIDENCE_RADIUS:
			continue
		var c := _resident_count(opos)
		if c < best_count:
			best_count = c
			best = o
	return best

var terrain: Node3D = null   # TerrainGen, if enabled — the ground everything sits on

## Ground height at world x,z. The ONE place spawn code asks "where's the
## surface here". Returns 0 with no terrain, so the flat-world path is unchanged.
func ground_y(x: float, z: float) -> float:
	if terrain != null and is_instance_valid(terrain) and terrain.has_method("height_at"):
		return terrain.height_at(x, z)
	return 0.0

## Public passthrough so other scripts (e.g. animal.gd wandering) can keep off the
## ocean without reaching into the untyped `terrain` var themselves. False with no
## terrain / island_mode off, so callers stay land-locked-agnostic.
func terrain_is_water(x: float, z: float) -> bool:
	if terrain != null and is_instance_valid(terrain) and terrain.has_method("is_water"):
		return bool(terrain.is_water(x, z))
	return false

## Confirmation that an order landed -- so you always know a member took (or
## refused) it, even one across camp you can't hear. Called from _accept_order /
## _refuse_order in tribemember.gd.
func flash_order_ack(who: String, kind: String, accepted: bool) -> void:
	if accepted:
		notify_cat(CAT_TRIBE, "✔ %s → %s" % [who, kind])  # order ack = your tribe
	else:
		notify_cat(CAT_TRIBE, "✗ %s refused %s" % [who, kind])

## Prepare a spot to build on: flatten a small footprint to the ground height
## there and return that height. This is BUILDING = TERRAFORMING -- a structure
## sits on level ground it made, which is why blocks stop floating on slopes and
## members stop getting wedged on an incline mid-build. Returns 0 with no terrain.
func seat_build(x: float, z: float, radius: float) -> float:
	var gy := ground_y(x, z)
	if terrain != null and is_instance_valid(terrain) and terrain.has_method("flatten_area"):
		terrain.flatten_area(x, z, radius, gy, 0.85)
	return gy

func _spawn_world() -> void:
	# TERRAIN FIRST -- built before anything scatters, because _scatter() samples
	# it to place things on the surface. Physics does the rest: members, NPCs, the
	# player all move with gravity + is_on_floor(), so once the ground has real
	# height they walk it without any other change. Only SPAWNING assumed a flat
	# plane, and that funnels through _scatter().
	_build_terrain()
	# One MultiMeshInstance3D PER SPECIES (tree_field.gd) draws the whole forest --
	# 5 real-model batches + a procedural fallback batch, a handful of draw calls
	# instead of one per tree. Built before any tree spawns so each tree's
	# mark_dirty() has a field to notify. Every tree.gd node is now an invisible
	# gameplay record; the field draws them all.
	_spawn_tree_field()
	_spawn_vegetation()
	# BERRIES grow in the low, wet ground -- valleys and plains, not on bare rock.
	for _i in range(bush_count):
		var b = Node3D.new()
		b.set_script(load("res://food_source.gd"))
		b.set("species", BUSH_POOL[randi() % BUSH_POOL.size()])   # must be set before add_child -- _ready() reads it immediately
		add_child(b)
		b.position = _scatter_biome(6.0, RESOURCE_EXTENT, 0.0, ["valley", "plains"])
	# GAME roams the open plains and valleys, not the peaks.
	for _i in range(animal_count):
		_spawn_animal(_scatter_biome(10.0, RESOURCE_EXTENT, 1.0, ["valley", "plains", "highland"]))
	# MINERALS -- stone, ore, gems -- are quarried from the highlands and
	# mountains. New biome-specific resource; see mineral.gd.
	_spawn_minerals()
	for _i in range(neutral_count):
		# spread across the whole map, not clustered just outside your camp —
		# wanderers should feel like they're out in the world, same range
		# rival tribe camps use, not bunched at the inner edge of RESOURCE_EXTENT
		_spawn_neutral(_scatter(30.0, MAP_EXTENT, 1.0))
	_spawn_world_tribes()

func _spawn_minerals() -> void:
	# roughly one mineral node per two bushes, up in the hills. Type by biome:
	# highland gives Stone, mountain gives Ore, with the odd Gem seam up high.
	var count := int(bush_count * 0.6) + 6
	for _i in range(count):
		var pos := _scatter_biome(20.0, MAP_EXTENT, 0.0, ["highland", "mountain"])
		var biome: String = "highland"
		if terrain and terrain.has_method("biome_at"):
			biome = str(terrain.biome_at(pos.x, pos.z))
		# DIVERSITY PASS (2026-07-19): was a flat Stone/Ore/(rare)Gems choice --
		# real, distinct ore/mineral variety per biome now (see mineral.gd's
		# own COLORS table), still weighted so the rarest finds stay rare.
		var kind := "Stone"
		var amt := 3
		if biome == "mountain":
			var roll := randf()
			if roll < 0.08:
				kind = "Gems"; amt = 2
			elif roll < 0.14:
				kind = "Obsidian"; amt = 2
			elif roll < 0.22:
				kind = "Gold"; amt = 2
			elif roll < 0.32:
				kind = "Silver"; amt = 2
			elif roll < 0.50:
				kind = "Coal"; amt = 3
			elif roll < 0.72:
				kind = "Iron"; amt = 3
			else:
				kind = "Copper"; amt = 3
		elif biome == "highland" and randf() < 0.25:
			kind = "Clay" if randf() < 0.5 else "Sand"
			amt = 4
		var m := StaticBody3D.new()
		m.set_script(load("res://mineral.gd"))
		m.set("mat_type", kind)
		m.set("amount", amt)
		add_child(m)
		m.global_position = pos

func _spawn_vegetation() -> void:
	var groves := int(tree_count / 11.0)
	for _g in range(groves):
		# groves cluster in wooded ground -- plains and highland hillsides --
		# rather than bare mountaintops or open valley floor
		var c := _scatter_biome(12.0, MAP_EXTENT, 0.0, ["plains", "highland"])
		var n := 8 + randi() % 8
		for _i in range(n):
			var off := Vector3(randf_range(-6.0, 6.0), 0.0, randf_range(-6.0, 6.0))
			_build_tree(c + off)

# One MultiMeshInstance3D PER SPECIES (tree_field.gd) draws the whole forest --
# 5 real-model batches + a procedural fallback batch, a handful of draw calls
# instead of one per tree. Built before any tree spawns so each tree's
# mark_dirty() has a field to notify. Every tree.gd node is now an invisible
# gameplay record; the field draws them all.
func _spawn_tree_field() -> void:
	if get_tree().get_first_node_in_group("tree_field") != null:
		return
	var tf := Node3D.new()
	tf.set_script(load("res://tree_field.gd"))
	add_child(tf)

func _build_tree(pos: Vector3) -> void:
	# untyped for consistency with the rest of the spawners; tree.gd has no
	# custom calls right after attach today, but keeping this pattern uniform
	# avoids this silently breaking the next time someone adds one.
	var t = StaticBody3D.new()
	t.set_script(load("res://tree.gd"))
	t.set("species", TREE_POOL[randi() % TREE_POOL.size()])   # must be set before add_child -- _ready() reads it immediately
	add_child(t)
	# seat on the surface at the TREE'S own x,z -- a grove's trees are offset from
	# the grove centre, so using the centre's height floated the outer trees on a
	# slope. Every static prop must sample ground where it actually stands. In
	# island mode the offset can push an outer tree past the shoreline into the
	# sea, so nudge each tree onto land (no-op when islands are off).
	var spot: Vector3 = _land_spot(pos.x, pos.z)
	if spot != Vector3.INF:
		pos = spot
	else:
		pos.y = ground_y(pos.x, pos.z)
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
		var pos: Vector3 = _find_camp_spot(placed)
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
	# Prefer FLAT ground. A camp on a hillside can't be fully levelled without
	# gouging a plateau into the slope, so pick the flattest of several spaced-out
	# candidates instead -- flattening a valley floor is cheap, flattening a
	# mountainside looks wrong. Falls through to any spaced spot if all are hilly.
	var best := Vector3.INF
	var best_var := INF
	for _try in range(24):
		var p := _scatter(34.0, MAP_EXTENT, 0.0)
		# a camp must be on dry land -- reject any spot in the sea. _scatter already
		# nudges toward shore, so this mainly rejects the rare deep-ocean fallback.
		if terrain != null and is_instance_valid(terrain) and terrain.has_method("is_water"):
			var wet: bool = terrain.is_water(p.x, p.z)
			if wet:
				continue
		var ok := true
		for q in placed:
			if p.distance_to(q) < 34.0:
				ok = false
				break
		if not ok:
			continue
		var v := _terrain_variation(p.x, p.z, 16.0)
		if v < 2.0:
			return p                    # flat enough, take it immediately
		if v < best_var:
			best_var = v
			best = p
	return best if best != Vector3.INF else _scatter(34.0, MAP_EXTENT, 0.0)

## Max-min ground height in a disc -- how hilly a spot is. 0 = dead flat.
func _terrain_variation(cx: float, cz: float, r: float) -> float:
	var lo := INF
	var hi := -INF
	for a in range(0, 360, 45):
		var h := ground_y(cx + cos(deg_to_rad(a)) * r, cz + sin(deg_to_rad(a)) * r)
		lo = minf(lo, h)
		hi = maxf(hi, h)
	return hi - lo

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

## Nudge (x,z) onto dry land. Returns the ground-seated position if it's already
## land (or island_mode is off / no terrain), else the nearest shore via the
## terrain, else Vector3.INF to signal "deep ocean, pick a new spot". This is the
## single land-gate every spawn site routes through. When island_mode is OFF,
## terrain.is_water() is false everywhere, so this always returns the input point
## seated on the ground -- the flat/continuous-land behaviour is unchanged.
func _land_spot(x: float, z: float) -> Vector3:
	if terrain == null or not is_instance_valid(terrain) or not terrain.has_method("is_water"):
		return Vector3(x, ground_y(x, z), z)
	var water: bool = terrain.is_water(x, z)
	if not water:
		return Vector3(x, ground_y(x, z), z)
	# in the sea -- walk out to the closest shoreline (generous radius). May still
	# come back Vector3.INF if this is open ocean far from any island.
	var land: Vector3 = terrain.nearest_land(x, z, 240.0)
	return land

# ─────────────────────────────────────────────────────────────────────────────
# WATER TRAVEL — the navigation primitives the boat crossing (trade_envoy.gd)
# leans on. All three are NO-OPS on continuous maps: on a Standard/non-island
# map island_mode is off, terrain.is_water() is false everywhere, so
# path_crosses_water always returns false and no boat is ever built. Only when a
# straight land->land route actually runs through the sea does a crossing kick in.
# ─────────────────────────────────────────────────────────────────────────────
const WATER_SAMPLE_STEP := 6.0   # how finely we probe a route for water
const SHORE_STEP := 4.0          # marching resolution when hunting a shoreline

## Does the straight segment from -> to run through open water at any point? This
## is the single gate that decides "this traveller needs a boat." False whenever
## there's no island terrain, so continuous-land maps are completely unaffected.
func path_crosses_water(from: Vector3, to: Vector3) -> bool:
	if terrain == null or not is_instance_valid(terrain) or not terrain.has_method("is_water"):
		return false
	if not bool(terrain.get("island_mode")):
		return false
	var d := Vector2(to.x - from.x, to.z - from.z).length()
	if d < 0.01:
		return false
	var steps: int = maxi(1, int(d / WATER_SAMPLE_STEP))
	for i in range(steps + 1):
		var t := float(i) / float(steps)
		var x := lerpf(from.x, to.x, t)
		var z := lerpf(from.z, to.z, t)
		var w: bool = terrain.is_water(x, z)
		if w:
			return true
	return false

## March from a land point `from` toward `to` and return the LAST dry spot before
## the route enters the sea -- the shoreline where a traveller boards a boat.
## Vector3.INF if the whole route stays dry (caller then just walks).
func shoreline_toward(from: Vector3, to: Vector3) -> Vector3:
	if terrain == null or not is_instance_valid(terrain) or not terrain.has_method("is_water"):
		return Vector3.INF
	var dir := Vector2(to.x - from.x, to.z - from.z)
	var dist := dir.length()
	if dist < 0.01:
		return Vector3.INF
	dir = dir / dist
	var last_land := Vector3(from.x, ground_y(from.x, from.z), from.z)
	var walked := 0.0
	while walked < dist:
		walked += SHORE_STEP
		var px := from.x + dir.x * walked
		var pz := from.z + dir.y * walked
		var w: bool = terrain.is_water(px, pz)
		if w:
			return last_land
		last_land = Vector3(px, ground_y(px, pz), pz)
	return Vector3.INF

## From the embark shore, continue across the water toward `to` and return the
## FIRST dry spot on the far side -- where the traveller disembarks. Falls back to
## the nearest land around the target if the march never re-lands.
func far_shore(embark: Vector3, to: Vector3) -> Vector3:
	if terrain == null or not is_instance_valid(terrain) or not terrain.has_method("is_water"):
		return Vector3.INF
	var dir := Vector2(to.x - embark.x, to.z - embark.z)
	var dist := dir.length()
	if dist < 0.01:
		return Vector3.INF
	dir = dir / dist
	var walked := 0.0
	var in_water := false
	while walked < dist + 12.0:
		walked += SHORE_STEP
		var px := embark.x + dir.x * walked
		var pz := embark.z + dir.y * walked
		var w: bool = terrain.is_water(px, pz)
		if w:
			in_water = true
		elif in_water:
			return Vector3(px, ground_y(px, pz), pz)
	# never re-landed on the march -> snap to the nearest shore by the target
	var nl: Vector3 = terrain.nearest_land(to.x, to.z, 240.0)
	return nl

func _scatter(min_r: float, max_r: float, y: float) -> Vector3:
	# In island mode a raw (x,z) can land in the ocean; _land_spot nudges it to the
	# nearest shore, and if that spot is open sea we re-roll a few times. With no
	# terrain / island_mode off, the first _land_spot call always succeeds and this
	# is identical to the old flat behaviour.
	for _try in range(6):
		var ang := randf() * TAU
		var r   := randf_range(min_r, max_r)
		var x := cos(ang) * r
		var z := sin(ang) * r
		var spot: Vector3 = _land_spot(x, z)
		if spot != Vector3.INF:
			# `y` is an offset ABOVE the ground: y=0 sits on the surface, y=1 drops
			# in a metre up so gravity settles it.
			return Vector3(spot.x, spot.y + y, spot.z)
	# deep-ocean fallback (rare): give up nudging and drop at a raw spot rather
	# than fail to spawn. Home island around origin means this almost never trips.
	var fang := randf() * TAU
	var fr   := randf_range(min_r, max_r)
	var fx := cos(fang) * fr
	var fz := sin(fang) * fr
	return Vector3(fx, ground_y(fx, fz) + y, fz)

## Scatter that PREFERS certain biomes -- berries want valleys, game wants
## plains, minerals want mountains. Tries a handful of spots and takes the first
## in an allowed biome; falls back to any spot so nothing fails to spawn. With no
## terrain, biome_at is always "plains", so an allow-list that includes plains
## behaves like the old scatter.
func _scatter_biome(min_r: float, max_r: float, y: float, allowed: Array) -> Vector3:
	for _try in range(10):
		var p := _scatter(min_r, max_r, y)
		if terrain == null or not terrain.has_method("biome_at"):
			return p
		if allowed.has(terrain.biome_at(p.x, p.z)):
			return p
	return _scatter(min_r, max_r, y)

## Build the heightmapped world. Seeded off the map size so a given world regen-
## erates identically -- persistence stores the seed, not the whole heightmap.
func _build_terrain() -> void:
	if not USE_TERRAIN:
		return
	var tscript = load("res://terrain_gen.gd")
	if tscript == null:
		return
	terrain = Node3D.new()
	terrain.set_script(tscript)
	add_child(terrain)
	# ISLANDS: large scales (Epic/Massive) become archipelagos, small ones stay a
	# single continuous landmass. Must be set BEFORE generate() -- the generator
	# reads island_mode to decide land-vs-ocean. When off, is_land() is true
	# everywhere and every land-gate below is a no-op, so small maps are unchanged.
	var islands: bool = bool(SCALE_PRESETS[game_scale].get("islands", false))
	terrain.island_mode = islands
	terrain.generate(MAP_EXTENT, _terrain_seed)
	# the old flat plane would z-fight the terrain at valley floors and collide as
	# a false floor -- retire it now that the terrain is the ground.
	_disable_flat_floor()

	# lift the player onto the surface so they don't spawn buried or fall through
	# the moment the flat floor vanishes (they're near origin, in the flat basin,
	# so this is a small nudge -- but an explicit one beats trusting gravity to
	# catch a player who started below the new ground).
	var pl := get_tree().get_first_node_in_group("player") as Node3D
	if pl:
		pl.global_position.y = ground_y(pl.global_position.x, pl.global_position.z) + 2.0
		# gather your tribe AROUND you on the home island. On a huge island map the
		# pre-placed companion could end up a stretch away (or, before this, on the
		# wrong side of a shore); plant every starting member in a tight ring right
		# next to the player so "you spawn with your tribe" is literally true.
		for i in range(members.size()):
			var mem = members[i]
			if not (is_instance_valid(mem) and mem is Node3D):
				continue
			var a := TAU * float(i) / float(maxi(1, members.size()))
			var mx: float = pl.global_position.x + cos(a) * 3.0
			var mz: float = pl.global_position.z + sin(a) * 3.0
			mem.global_position = Vector3(mx, ground_y(mx, mz) + 1.0, mz)
			if "home_pos" in mem:
				mem.home_pos = mem.global_position

	# SEAT THE STOCKPILE ON THE TERRAIN. It spawns at Vector3.ZERO (y=0), which is
	# fine on flat maps but BURIES it on island maps -- the home island sits ~17m
	# above sea level, so the player was spawning with their stockpile 17m
	# underground ("I don't spawn with stockpile"). Lift it onto the surface at
	# origin now that the terrain exists.
	var sp := get_tree().get_first_node_in_group("stockpile") as Node3D
	if sp:
		sp.global_position.y = ground_y(sp.global_position.x, sp.global_position.z)

func _disable_flat_floor() -> void:
	var fb := get_tree().get_first_node_in_group("world_floor")
	if fb == null:
		fb = get_node_or_null("/root/Main/Floor")
	if fb == null:
		return
	var mesh_node := fb.get_node_or_null("Mesh")
	if mesh_node:
		mesh_node.visible = false
	var col := fb.get_node_or_null("Collision") as CollisionShape3D
	if col:
		col.disabled = true

# ─────────────────────────────────────────────────────────────────────────────
# MEMBER SPAWNING
# ─────────────────────────────────────────────────────────────────────────────
func _spawn_members() -> void:
	for i in range(spawn_count):
		var ang := TAU * float(i) / float(spawn_count)
		var mx := cos(ang) * spawn_radius
		var mz := sin(ang) * spawn_radius
		var pos := Vector3(mx, ground_y(mx, mz) + 1.5, mz)   # drop in above surface
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

## NOTE (2026-07-27): this used to also try loading the real human.glb model
## directly here, but the player's very FIRST companion is actually a
## hand-placed node in main.tscn (TribeManager/TribeMember, its OWN baked
## CapsuleMesh) -- a THIRD construction site this function never touches.
## Rather than fix 3 separate places (this one, the empty tribemember.tscn,
## and the scene-authored node) and risk them drifting out of sync, the real-
## model swap now happens ONCE, centrally, in tribemember.gd's own _ready()
## (_maybe_upgrade_to_real_model()) -- it runs no matter which of the 3 paths
## built this body. This function goes back to just the plain primitive body.
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
	face.material_override = MatCache.flat(Color(0.1, 0.1, 0.12))
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
		eye.material_override = MatCache.flat(Color(1, 1, 1))
		face.add_child(eye)

		var pupil := MeshInstance3D.new()
		var ps := SphereMesh.new()
		ps.radius = 0.022
		ps.height = 0.044
		pupil.mesh = ps
		pupil.position = Vector3(randf_range(-0.015, 0.015), randf_range(-0.015, 0.015), 0.045)
		pupil.material_override = MatCache.flat(Color(0.05, 0.05, 0.05))
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
		notify_cat(CAT_YOU, "Need %d wood to carve a club — chop a tree first." % CLUB_COST)
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
			notify_cat(CAT_YOU, "You forge a %s club — it bites harder." % player_club_material)
	else:
		clubs += 1
	return true

func consume_club() -> bool:
	if clubs_available() <= 0:
		return false
	clubs -= 1
	return true

# Legacy entry point. Most external callers (FPSPlayer, mineral, thrown_club)
# report the PLAYER'S own actions, so plain notify() routes to the "You" box.
# Callers about the wider world or the player's tribe use notify_cat() directly.
func notify(t: String) -> void:
	notify_cat(CAT_YOU, t)

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
		notify_cat(CAT_YOU, "Too far from camp — stay within %d of the stockpile." % int(BUILD_RANGE))
		return false
	if wood < FENCE_COST:
		notify_cat(CAT_YOU, "Need %d wood for a fence — chop trees with your club." % FENCE_COST)
		return false
	wood -= FENCE_COST
	var f = StaticBody3D.new()
	f.set_script(load("res://fence.gd"))
	add_child(f)
	pos.y = seat_build(pos.x, pos.z, 2.0)   # level the ground, sit the fence on it
	f.global_position = pos
	f.rotation.y      = yaw
	notify_cat(CAT_YOU, "Fence raised. (wood left: %d)" % wood)
	if not by_player: _track_fortress_piece(f)
	return true

func try_build_teepee(pos: Vector3, by_player: bool = false) -> bool:
	if by_player and not _within_build_range(pos):
		notify_cat(CAT_YOU, "Too far from camp — stay within %d of the stockpile." % int(BUILD_RANGE))
		return false
	if wood < TEEPEE_COST:
		notify_cat(CAT_YOU, "Need %d wood for a teepee — chop more trees." % TEEPEE_COST)
		return false
	wood -= TEEPEE_COST
	var t = StaticBody3D.new()
	t.set_script(load("res://teepee.gd"))
	add_child(t)
	pos.y = seat_build(pos.x, pos.z, 2.5)
	t.global_position = pos
	notify_cat(CAT_YOU, "Teepee raised. (wood left: %d)" % wood)
	if not by_player: _track_fortress_piece(t)
	return true

const BlockScript = preload("res://block.gd")

# a single placeable wall block (block.gd) — the building unit for player-
# and NPC-raised fortresses/mazes. Builders (player or any walk-to-and-place
# NPC) must already be standing next to `pos`; this just spends the wood and
# places it, snapped to the shared block grid so different builders' work
# still lines up.
#
# MATERIAL UPGRADE (2026-07-22): every new block automatically uses the
# tribe's CURRENT material_tier (Wood/Stone/Metal — see try_upgrade_material())
# -- an upgrade takes effect on whatever gets built from that point on, real
# and immediate, not retrofitted onto blocks already standing. Better
# material costs a bit more wood too (worked stone/metal takes more effort
# to place than raw timber), on top of the real `materials` spent once to
# unlock the tier in the first place.
func try_build_block(pos: Vector3, by_player: bool = false) -> bool:
	var cost: int = BLOCK_COST + material_tier
	if by_player and not _within_build_range(pos):
		notify_cat(CAT_YOU, "Too far from camp — stay within %d of the stockpile." % int(BUILD_RANGE))
		return false
	if wood < cost:
		notify_cat(CAT_YOU, "Need %d wood for a block — chop more trees." % cost)
		return false
	wood -= cost
	var b = StaticBody3D.new()
	b.set_script(load("res://block.gd"))
	b.material_tier = material_tier
	add_child(b)
	# flatten the footprint, then stack the block ON the levelled ground: pos.y is
	# the course height (1 = ground course, 3 = second course), added to the seat
	# height so a wall built on a slope rises in even courses instead of floating.
	var seat := seat_build(pos.x, pos.z, 1.4)
	var snapped: Vector3 = BlockScript.snap(pos)
	snapped.y = seat + pos.y
	b.global_position = snapped
	if not by_player: _track_fortress_piece(b)
	return true

## Spend real `materials` to unlock the NEXT construction material tier
## (Wood -> Stone -> Metal). Returns false, spending nothing, if there's no
## further tier or the stockpile can't afford it yet -- same fail-honestly
## contract as every other try_build_*().
func try_upgrade_material() -> bool:
	var next: int = material_tier + 1
	if next >= MATERIAL_TIER_NAMES.size():
		return false
	if materials < MATERIAL_UPGRADE_COST[next]:
		return false
	materials -= MATERIAL_UPGRADE_COST[next]
	material_tier = next
	notify_cat(CAT_TRIBE, "The tribe has learned to build in %s." % MATERIAL_TIER_NAMES[material_tier])
	return true

## Background check, same pattern as _recruit_tick()/_raid_tick(): the
## tribe upgrades material the moment it can genuinely afford to, without
## needing a specific member to walk anywhere or perform an action -- this
## is a stockpile-level decision (what future construction is BUILT FROM),
## not a physical task.
func _material_upgrade_tick(delta: float) -> void:
	_material_upgrade_cd -= delta
	if _material_upgrade_cd > 0.0:
		return
	_material_upgrade_cd = 20.0
	if material_tier + 1 < MATERIAL_TIER_NAMES.size() \
			and materials >= MATERIAL_UPGRADE_COST[material_tier + 1]:
		try_upgrade_material()

## Members multiply their SIGHT_RADIUS-based checks by this — 1.0 in clear
## weather (no change from before this system existed), lower in rain/storm/
## fog. Callers that don't check for weather at all are unaffected (they
## simply never call this), so this is purely additive.
func visibility_mult() -> float:
	return float(WEATHER_VISIBILITY.get(current_weather, 1.0))

## Hunger drains faster in bad weather (cold, wet, miserable) — read by
## tribemember.gd's _hunger_step().
func hunger_mult() -> float:
	return float(WEATHER_HUNGER_MULT.get(current_weather, 1.0))

func _weather_tick(delta: float) -> void:
	_weather_timer -= delta
	if _weather_timer > 0.0:
		return
	_weather_timer = randf_range(WEATHER_MIN_DURATION, WEATHER_MAX_DURATION)
	var new_weather: int = WEATHER_CHOICES[randi() % WEATHER_CHOICES.size()]
	if new_weather == current_weather:
		return
	current_weather = new_weather
	notify_cat(CAT_TRIBES, "The weather turns to %s." % WEATHER_NAMES[current_weather])
	_apply_weather_visuals()

var _cached_world_env: WorldEnvironment = null
var _cached_sun: DirectionalLight3D = null
var _weather_visuals_searched := false
var _weather_sun_energy: float = 1.0

# ─────────────────────────────────────────────────────────────────────────────
# DAY/NIGHT CYCLE (2026-07-19): "make night time come and tribes light
# campfires, gossip, talk, laugh, and do ceremonial dances around the fire"
# -- previously tribe_llm.gd's own WORLD prompt flatly said there was NO
# night or day at all. Real now: a continuous cycle darkens the sun (see
# _apply_weather_visuals() above, which this multiplies against) and flips
# is_night, which tribemember.gd's _night_campfire_behavior() reads to send
# idle members to the nearest real campfire (see campfire.gd) instead of
# their usual autonomous work.
# ─────────────────────────────────────────────────────────────────────────────
const DAY_LENGTH := 480.0     # seconds for a full day/night cycle
const NIGHT_SUN_MULT := 0.30
var time_of_day: float = 0.5  # 0..1, 0 = midnight, 0.5 = noon
var is_night: bool = false

func _update_day_night(delta: float) -> void:
	time_of_day = fmod(time_of_day + delta / DAY_LENGTH, 1.0)
	var was_night := is_night
	is_night = time_of_day < 0.2 or time_of_day > 0.8
	if is_night and not was_night:
		notify_cat(CAT_TRIBE, "🌙 Night falls -- the tribe gathers at the fire.")
	elif was_night and not is_night:
		notify_cat(CAT_TRIBE, "☀ Dawn breaks -- the camp stirs back to work.")
	_apply_weather_visuals()

## Best-effort visual: reuses graphics_quality.gd's own WorldEnvironment/
## DirectionalLight3D lookup pattern. If the scene has neither (a headless
## test, a minimal scene), this is a harmless no-op — the mechanical effects
## above (visibility_mult/hunger_mult) work regardless.
##
## PERF FIX (2026-07-26): find_children("*", ..., true, false) is a
## recursive search over the ENTIRE scene tree (tens of thousands of nodes
## in a populated world) -- done TWICE, every single time weather changes.
## Harmless on its own (weather changes every 60-180s), but a real,
## measurable per-frame HITCH each time it fired, on top of everything else
## going on that frame. The result never changes at runtime (the world's
## WorldEnvironment/DirectionalLight3D are scene-authored, not
## created/destroyed during play), so it only needs to be found ONCE and
## cached -- every weather change after that is pure property assignment.
func _apply_weather_visuals() -> void:
	if not _weather_visuals_searched:
		_weather_visuals_searched = true
		var we_nodes: Array = get_tree().root.find_children("*", "WorldEnvironment", true, false)
		if not we_nodes.is_empty():
			_cached_world_env = we_nodes[0] as WorldEnvironment
		var sun_nodes: Array = get_tree().root.find_children("*", "DirectionalLight3D", true, false)
		if not sun_nodes.is_empty():
			_cached_sun = sun_nodes[0] as DirectionalLight3D
	var we: WorldEnvironment = _cached_world_env
	if we == null or we.environment == null:
		return
	var env := we.environment
	var sun: DirectionalLight3D = _cached_sun
	match current_weather:
		Weather.CLEAR:
			env.fog_enabled = false
			_weather_sun_energy = 1.0
		Weather.RAIN:
			env.fog_enabled = true
			env.fog_light_color = Color(0.55, 0.58, 0.62)
			env.fog_density = 0.008
			_weather_sun_energy = 0.75
		Weather.STORM:
			env.fog_enabled = true
			env.fog_light_color = Color(0.30, 0.32, 0.36)
			env.fog_density = 0.02
			_weather_sun_energy = 0.45
		Weather.FOG:
			env.fog_enabled = true
			env.fog_light_color = Color(0.75, 0.75, 0.75)
			env.fog_density = 0.05
			_weather_sun_energy = 0.85
	# DAY/NIGHT (2026-07-19): multiplies weather's own baseline rather than
	# fighting it for control of the same sun -- night is dark whether it's
	# clear or stormy, but a clear night is still brighter than a stormy day.
	if sun:
		sun.light_energy = _weather_sun_energy * (NIGHT_SUN_MULT if is_night else 1.0)

const BuildPieceScript = preload("res://build_piece.gd")

# A shallow wedge — climbable half-steps up a wall or watchtower. Same
# grid-snap + course-height convention as try_build_block() so a staircase
# actually lines up flush against the wall it's climbing. `yaw` orients the
# piece (a stair should face the structure it climbs, not always point the
# same default direction) and `scale_factor` picks a real size variant
# (BuildPieceScript.SCALE_SMALL/NORMAL/LARGE) rather than every piece being
# forced to one fixed size.
func try_build_stair(pos: Vector3, yaw: float = 0.0,
		scale_factor: float = BuildPieceScript.SCALE_NORMAL, by_player: bool = false) -> bool:
	if by_player and not _within_build_range(pos):
		notify_cat(CAT_YOU, "Too far from camp — stay within %d of the stockpile." % int(BUILD_RANGE))
		return false
	if wood < STAIR_COST:
		notify_cat(CAT_YOU, "Need %d wood for a stair — chop more trees." % STAIR_COST)
		return false
	wood -= STAIR_COST
	var b = StaticBody3D.new()
	b.set_script(BuildPieceScript)
	b.kind = BuildPieceScript.Kind.STAIR
	b.yaw = yaw
	b.scale_factor = scale_factor
	add_child(b)
	var seat := seat_build(pos.x, pos.z, 1.4)
	var snapped: Vector3 = BlockScript.snap(pos)
	snapped.y = seat + pos.y
	b.global_position = snapped
	if not by_player: _track_fortress_piece(b)
	return true

# A steep triangular-prism cap — reads as an actual roofline, not a flat lid.
func try_build_roof(pos: Vector3, yaw: float = 0.0,
		scale_factor: float = BuildPieceScript.SCALE_NORMAL, by_player: bool = false) -> bool:
	if by_player and not _within_build_range(pos):
		notify_cat(CAT_YOU, "Too far from camp — stay within %d of the stockpile." % int(BUILD_RANGE))
		return false
	if wood < ROOF_COST:
		notify_cat(CAT_YOU, "Need %d wood for a roof — chop more trees." % ROOF_COST)
		return false
	wood -= ROOF_COST
	var b = StaticBody3D.new()
	b.set_script(BuildPieceScript)
	b.kind = BuildPieceScript.Kind.ROOF
	b.yaw = yaw
	b.scale_factor = scale_factor
	add_child(b)
	var seat := seat_build(pos.x, pos.z, 1.4)
	var snapped: Vector3 = BlockScript.snap(pos)
	snapped.y = seat + pos.y
	b.global_position = snapped
	if not by_player: _track_fortress_piece(b)
	return true

# A half-size fine-detail unit — corners, ledges, in-fill that shouldn't be
# forced onto the coarse 2.0-unit wall grid. Deliberately NOT grid-snapped
# to BlockScript's grid: the whole point is finer placement than that grid
# allows.
func try_build_small(pos: Vector3, yaw: float = 0.0,
		scale_factor: float = BuildPieceScript.SCALE_NORMAL, by_player: bool = false) -> bool:
	if by_player and not _within_build_range(pos):
		notify_cat(CAT_YOU, "Too far from camp — stay within %d of the stockpile." % int(BUILD_RANGE))
		return false
	if wood < SMALL_COST:
		notify_cat(CAT_YOU, "Need %d wood for detail work — chop more trees." % SMALL_COST)
		return false
	wood -= SMALL_COST
	var b = StaticBody3D.new()
	b.set_script(BuildPieceScript)
	b.kind = BuildPieceScript.Kind.SMALL
	b.yaw = yaw
	b.scale_factor = scale_factor
	add_child(b)
	var seat := seat_build(pos.x, pos.z, 1.0)
	b.global_position = Vector3(pos.x, seat + pos.y, pos.z)
	if not by_player: _track_fortress_piece(b)
	return true

# A narrow slab that fills a gate opening — a real door, not just an
# unguarded gap in the wall. Same yaw/scale_factor configuration as the
# other pieces; a gate's own facing angle is what's normally passed in.
func try_build_door(pos: Vector3, yaw: float = 0.0,
		scale_factor: float = BuildPieceScript.SCALE_NORMAL, by_player: bool = false) -> bool:
	if by_player and not _within_build_range(pos):
		notify_cat(CAT_YOU, "Too far from camp — stay within %d of the stockpile." % int(BUILD_RANGE))
		return false
	if wood < DOOR_COST:
		notify_cat(CAT_YOU, "Need %d wood for a door — chop more trees." % DOOR_COST)
		return false
	wood -= DOOR_COST
	var b = StaticBody3D.new()
	b.set_script(BuildPieceScript)
	b.kind = BuildPieceScript.Kind.DOOR
	b.yaw = yaw
	b.scale_factor = scale_factor
	add_child(b)
	var seat := seat_build(pos.x, pos.z, 1.0)
	b.global_position = Vector3(pos.x, seat + pos.y, pos.z)
	if not by_player: _track_fortress_piece(b)
	return true

# ─────────────────────────────────────────────────────────────────────────────
# TRADING POST (2026-07-19): "allow trading post to be built before its used"
# -- a real, buildable structure gating every trade action. See trade_partners()
# /propose_trade_with()/player_send_trade_envoy()/_incoming_request_tick()
# below, all of which now refuse to act at all until trading_post_built().
# ─────────────────────────────────────────────────────────────────────────────
const TRADING_POST_COST_WOOD := 20
const TRADING_POST_COST_MATERIALS := 10
var trading_post: Node = null

func trading_post_built() -> bool:
	return trading_post != null and is_instance_valid(trading_post)

## Where envoys/couriers actually walk to/from -- the post once built, else
## the stockpile (so nothing crashes before the player's raised one, it's
## just that trade_partners()/propose_trade_with() etc. refuse to run at all
## until then).
func trading_post_position() -> Vector3:
	if trading_post_built():
		return (trading_post as Node3D).global_position
	var sp := get_tree().get_first_node_in_group("stockpile") as Node3D
	return sp.global_position if sp != null else Vector3.ZERO

func build_trading_post(pos: Vector3, by_player: bool = false) -> bool:
	if trading_post_built():
		notify_cat(CAT_YOU, "The trading post is already standing.")
		return false
	if by_player and not _within_build_range(pos):
		notify_cat(CAT_YOU, "Too far from camp — stay within %d of the stockpile." % int(BUILD_RANGE))
		return false
	if wood < TRADING_POST_COST_WOOD or materials < TRADING_POST_COST_MATERIALS:
		notify_cat(CAT_YOU, "Need %d wood and %d materials for a trading post." % [
			TRADING_POST_COST_WOOD, TRADING_POST_COST_MATERIALS])
		return false
	wood -= TRADING_POST_COST_WOOD
	materials -= TRADING_POST_COST_MATERIALS
	var post := StaticBody3D.new()
	post.set_script(load("res://trading_post.gd"))
	add_child(post)
	pos.y = seat_build(pos.x, pos.z, 3.0)
	post.global_position = pos
	trading_post = post
	notify_cat(CAT_YOU, "Trading post raised! Envoys and merchants can now be received.")
	return true

func try_build_camp(pos: Vector3, by_player: bool = false) -> bool:
	if by_player and not _within_build_range(pos):
		notify_cat(CAT_YOU, "Too far from camp — stay within %d of the stockpile." % int(BUILD_RANGE))
		return false
	if wood < CAMP_COST:
		notify_cat(CAT_YOU, "Need %d wood for a camp — chop more trees." % CAMP_COST)
		return false
	wood -= CAMP_COST
	var camp = Node3D.new()
	camp.set_script(load("res://player_camp.gd"))
	add_child(camp)
	pos.y = seat_build(pos.x, pos.z, 8.0)   # level the whole forward-camp footprint
	camp.global_position = pos
	camp.set("manager", self)
	_build_camp_visuals(camp)
	notify_cat(CAT_YOU, "Forward camp raised! (wood left: %d)" % wood)
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

	# BUG FIXED (2026-07-19): "player camp doesn't have fire but all tribe
	# members do" -- this was a bare ambient OmniLight3D, not a real campfire
	# (not in group "campfire", so _nearest_campfire()/the night-gathering
	# behavior could never find it -- residents here had nowhere to gather).
	# A real campfire.gd carries its own flickering light, so the old light
	# is replaced rather than doubled up.
	var fire := StaticBody3D.new()
	fire.set_script(load("res://campfire.gd"))
	camp.add_child(fire)
	fire.position = Vector3(0, 0.0, 0)

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
		mi.material_override = MatCache.flat(Color(0.6, 0.5, 0.35))
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
	fortress_tier += 1
	if fortress_tier < MAX_FORTRESS_TIER:
		notify_cat(CAT_TRIBE, "The tribe's fortress has grown -- tier %d now stands." % fortress_tier)
	else:
		notify_cat(CAT_TRIBE, "The tribe's fortress has reached its full might.")

func suggest_job(_member) -> String:
	var have_bushes  := not get_tree().get_nodes_in_group("food_source").is_empty()
	var have_animals := not get_tree().get_nodes_in_group("animal").is_empty()
	var have_trees   := not get_tree().get_nodes_in_group("tree").is_empty()

	# SCARCITY FIRST (2026-07-19): "tribe members need to focus on scarcity
	# unless directed otherwise -- still delegate guarding/scouting/
	# everything, but make sure necessities are taken care of." Previously
	# only FOOD had a real hard-priority floor checked before the optional
	# extras (hunt/scout/recruit/build/mine) got their chance-based rolls --
	# wood and materials could stay critically short indefinitely while the
	# tribe kept rolling for a hunt or a scout instead. Now whichever of the
	# three is WORST off wins outright, every single time, before any of
	# those optional rolls run at all. A standing/forced player order still
	# overrides this completely -- suggest_job() is never even consulted for
	# those (see _start_job(job, forced=true)).
	var food_need: float = float(members.size() * 2) - float(food)
	var wood_need: float = 8.0 - float(wood)
	var mat_need: float = float(members.size() * 2) - float(materials)
	if maxf(food_need, maxf(wood_need, mat_need)) > 0.0:
		if food_need >= wood_need and food_need >= mat_need and have_bushes:
			return "gather"
		if wood_need >= mat_need and have_trees:
			return "wood"
		if mat_need > 0.0 and not get_tree().get_nodes_in_group("mineral").is_empty():
			return "mine"
	# the tribe keeps raising bigger fortresses, same as rival camps do
	# autonomously (world_tribe.gd._build_palisade) — previously this only
	# ever happened ONCE (fortress_built was a one-shot flag that stopped
	# "build" from ever being suggested again). fortress_tier replaces that
	# dead end: on_fortress_built() increments it each time a ring finishes,
	# fence_ring_plan() scales the whole plan up with it, and this gate keeps
	# proposing "build" (up to MAX_FORTRESS_TIER) with steeper wood/member
	# requirements each time -- a bigger fortress genuinely needs a bigger
	# tribe and more lumber, not just a bigger number on a flag.
	# ONE self-assigned builder at a time. A self-triggered build calls
	# begin_build() with the default offset=0/stride=1, so EVERY member who
	# picks "build" independently builds the WHOLE ring from segment 0 -- they
	# all converge on the same spots, stack blocks on one another, and jam. A
	# whole-tribe RALLY build is different (it hands each member a distinct
	# offset/stride slice); that path is untouched. This only gates the
	# uncoordinated solo case, which is the pile-up you saw.
	# EASED (2026-07-19): "build and expand more efficiently, progress is too
	# slow" -- lower wood/member bar and a real chance bump, so the fortress
	# actually keeps growing at a pace a player can feel across a session.
	if fortress_tier < MAX_FORTRESS_TIER and not _someone_building() \
			and wood >= 22 + fortress_tier * 14 \
			and members.size() >= 2 + fortress_tier and randf() < 0.20:
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
	# AWARENESS FIX (2026-07-19): minerals existed in the world but no
	# autonomous job ever reached for them -- see mineral.gd's SpatialGrid
	# registration and tribemember.gd's new _nearest_mineral()/_do_mine().
	# Gated on genuinely needing materials, same spirit as the wood/food
	# gates above, so it doesn't compete with gather/wood for no reason.
	if materials < members.size() * 3 and not get_tree().get_nodes_in_group("mineral").is_empty() and randf() < 0.3:
		return "mine"
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
	notify_cat(CAT_TRIBE, "Your camp has fallen! %d survivors swear to the %s." % [joined, foe])  # your tribe's fate

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

const UNREST_ON_DEATH := 0.6
const UNREST_ON_PLAYER_KILL := 1.5   # the leader killing their OWN is a real crisis, not ordinary loss
const UNREST_ON_STARVATION := 1.0    # negligence -- the leader let this happen, not an outside threat
const WITNESS_TRAUMA_CHANCE := 0.4

func on_member_died(m, attacker = null, cause: String = "") -> void:
	members.erase(m)
	if focus_tribe == m:
		focus_tribe = null
	var nm: String = m.member_name if (m and "member_name" in m) else "A member"
	# REAL REACTION (2026-07-19): "if i kill a tribe member the tribe should
	# have a reaction" -- relationship already dropped for everyone (below,
	# unchanged), but nothing else registered the loss as an EVENT: no unrest
	# cost, no lasting memory, no chance it actually changes how a survivor
	# sees the world. A killing by the LEADER specifically spikes unrest far
	# harder than an ordinary death (raid, starvation) -- that's a betrayal
	# of the whole tribe, not just bad luck.
	var by_player: bool = attacker != null and is_instance_valid(attacker) and attacker.is_in_group("player")
	# REAL CAUSE, NOT ASSUMED (2026-07-19): "they need to react to the real
	# reason an npc died, not assume it's food related... they shouldn't get
	# mad if they have access" -- "starvation" (no stockpile access ever
	# earned -- a real Stranger) is genuine negligence; "starvation_had_access"
	# (Acquaintance+, the stockpile itself just ran dry) is a supply failure,
	# not the leader denying anyone anything -- distinct reactions below.
	var denied_access: bool = cause == "starvation"
	var starved_with_access: bool = cause == "starvation_had_access"
	var by_starvation: bool = denied_access or starved_with_access
	if denied_access:
		unrest += UNREST_ON_STARVATION
	elif starved_with_access:
		unrest += UNREST_ON_STARVATION * 0.5   # a supply failure, not negligence -- still bad, less blame-worthy
	else:
		unrest += UNREST_ON_PLAYER_KILL if by_player else UNREST_ON_DEATH
	for o in members:
		if not is_instance_valid(o):
			continue
		if "relationship" in o:
			# Genuine negligence (denied access entirely) hits trust harder
			# than a supply failure someone with real access still fell to.
			var rel_hit: float = 0.7 if denied_access else (0.5 if starved_with_access else 0.4)
			o.relationship = maxf(0.0, o.relationship - rel_hit)
		if o.has_method("blame_leader_for_hunger_death") and by_starvation:
			o.blame_leader_for_hunger_death(nm, denied_access)
		elif o.has_method("witness_tribemate_death"):
			o.witness_tribemate_death(nm, by_player)
	var death_line: String = "%s has fallen. The tribe mourns (trust shaken)." % nm
	if denied_access:
		death_line = "%s starved to death, never trusted enough to feed themselves. The tribe blames your negligence." % nm
	elif starved_with_access:
		death_line = "%s starved to death despite having earned stockpile access -- the stores simply ran dry." % nm
	notify_cat(CAT_TRIBE, death_line)  # your member died
	# MURDER RIVALRY (2026-07-19): "when tribes murder other tribe members
	# build up rivalry between" -- a rival npc killing one of YOUR members
	# now leaves a real, lasting mark: the killer's own tribe registers as a
	# genuine rival (add_rivalry, below) and that tribe's OWN player_opinion
	# sours immediately, same lasting-consequence shape as a lost war (see
	# _ripple_opinions_on_defeat) but triggered by a single killing, not a
	# whole raid's outcome.
	if attacker != null and is_instance_valid(attacker) and "tribe" in attacker:
		var rival = attacker.tribe
		if rival != null and is_instance_valid(rival) and "tribe_name" in rival:
			add_rivalry(str(rival.tribe_name), MURDER_RIVALRY_HIT)
			if "player_opinion" in rival:
				# a player with a real history of raids/blame gets hit HARDER for
				# the same murder than a mostly-peaceful one would -- adapted,
				# not identical for every player (see player_aggression_score()).
				var hit: float = MURDER_OPINION_HIT * (0.6 + player_aggression_score())
				rival.player_opinion = clampf(float(rival.player_opinion) - hit, -1.0, 1.0)

# ── RIVALRY (2026-07-19): a persistent, decaying record of which rival
# tribes have real blood between them and the player, distinct from the
# per-rival-tribe `opinions`/grudge_toward() ladder those tribes use against
# EACH OTHER. Fed by murders in both directions (see here and world_tribe.gd's
# own on_member_died) -- it never resets to 0 instantly, so a single killing
# has a lasting footprint, but it does fade if nothing further happens.
const MURDER_RIVALRY_HIT := 0.35
const MURDER_OPINION_HIT := 0.30
const RIVALRY_DECAY_RATE := 0.01   # per second -- a real feud outlasts a single session
var rivalries: Dictionary = {}     # tribe_name -> float 0..1

# ── ADAPTIVE RIVAL LEADER (2026-07-19): "an opponent that's adapted to you,
# not a fixed AI." A small, actually-TRAINED linear model (see
# rival_adaptation_model.gd) reads the player's real, aggregated history --
# how often their OWN tribe has blamed them, how often they've fed members,
# how many raids they've personally triggered -- into one adapted aggression
# score, which scales how hard rival tribes react to a murder or a greeting.
# player_war_trigger_count is a real counter (see order_raid() above);
# blame/feed are read live off the real per-member counters that already
# exist (player_caused_deaths_witnessed, feed_count) rather than duplicated.
const RivalAdaptationModelScript = preload("res://rival_adaptation_model.gd")
var _rival_model: RivalAdaptationModel = null
var player_war_trigger_count: int = 0

func _ensure_rival_model() -> RivalAdaptationModel:
	if _rival_model == null:
		_rival_model = RivalAdaptationModelScript.new()
	return _rival_model

## Normalizes the player's real aggregate behavior (0..1 each, /10 events is
## "a lot" for a single playthrough) and returns the trained model's read on
## how aggressively rivals should treat this specific player right now.
func player_aggression_score() -> float:
	var blame_total := 0
	var feed_total := 0
	for m in members:
		if is_instance_valid(m):
			blame_total += int(m.get("player_caused_deaths_witnessed"))
			feed_total += int(m.get("feed_count"))
	var blame_freq: float = clampf(float(blame_total) / 10.0, 0.0, 1.0)
	var feed_freq: float = clampf(float(feed_total) / 10.0, 0.0, 1.0)
	var war_freq: float = clampf(float(player_war_trigger_count) / 10.0, 0.0, 1.0)
	return _ensure_rival_model().predict(blame_freq, feed_freq, war_freq)

func add_rivalry(tribe_name: String, amount: float) -> void:
	rivalries[tribe_name] = clampf(float(rivalries.get(tribe_name, 0.0)) + amount, 0.0, 1.0)

func rivalry_toward(tribe_name: String) -> float:
	return float(rivalries.get(tribe_name, 0.0))

func _decay_rivalries(delta: float) -> void:
	for k in rivalries.keys():
		rivalries[k] = maxf(0.0, float(rivalries[k]) - RIVALRY_DECAY_RATE * delta)

# ═════════════════════════════════════════════════════════════════════════════
# SCOUTING
# ═════════════════════════════════════════════════════════════════════════════
# COMMUNICATION (2026-07-28): a real, direct way for the player to build
# player_opinion with a specific rival tribe -- distinct from the existing
# passive trade/raid/war ripple effects (see try_trade_with_tribe() and the
# war-outcome ripples below). Reuses the scout action: an undiscovered camp
# in range is scouted as before (first contact always counts as a
# greeting too), but once nothing new is left to discover, the SAME action
# greets an already-known tribe within reach instead -- so it keeps being a
# meaningful thing to do long after the map's fully scouted, not a
# one-time-per-tribe interaction that goes dead.
const GREET_RANGE := 14.0
const GREET_OPINION_GAIN := 0.06
const GREET_COOLDOWN := 40.0
var _last_greet: Dictionary = {}   # tribe_name -> Time.get_ticks_msec()/1000.0

func player_scout(from_pos: Vector3) -> void:
	var undiscovered = _nearest_tribe_from(from_pos, false)
	if undiscovered != null and from_pos.distance_to(undiscovered.global_position) <= SCOUT_RANGE:
		undiscovered.discover()
		var line: String = undiscovered.greeting() if undiscovered.has_method("greeting") else ""
		notify_cat(CAT_YOU, "You scouted the %s — %s, strength %d.%s" % [
			undiscovered.tribe_name, undiscovered.archetype, undiscovered.strength,
			"\n\"%s\"" % line if line != "" else ""])
		_greet_tribe(undiscovered, true)
		return
	var known = _nearest_tribe_from(from_pos, true)
	if known != null and from_pos.distance_to(known.global_position) <= GREET_RANGE:
		_greet_tribe(known)
		return
	if undiscovered == null and known == null:
		notify_cat(CAT_YOU, "No tribes to scout or greet nearby.")
	else:
		notify_cat(CAT_YOU, "Too far — walk within %d of a camp to scout or greet it." \
			% int(maxf(SCOUT_RANGE, GREET_RANGE)))

## Real, mechanical communication: nudges player_opinion up a small amount.
## `is_first_contact` (a fresh scout) always lands, bypassing the cooldown --
## first impressions matter and shouldn't be swallowed by a timer that
## hasn't started yet. Repeat greetings of an already-known tribe are
## cooldown-gated so this can't be spammed into an instant alliance.
func _greet_tribe(t, is_first_contact: bool = false) -> void:
	if t == null or not is_instance_valid(t):
		return
	var now := Time.get_ticks_msec() / 1000.0
	var last: float = float(_last_greet.get(t.tribe_name, -999.0))
	if not is_first_contact and now - last < GREET_COOLDOWN:
		notify_cat(CAT_YOU, "The %s have nothing new to say -- give it time." % t.tribe_name)
		return
	_last_greet[t.tribe_name] = now
	if "player_opinion" in t:
		# a rival with a real read on this player as aggressive stays skeptical
		# of a friendly gesture -- the SAME greeting warms a peaceful player's
		# standing more than a warmonger's, because the model has actually
		# adapted to that specific player's history.
		var gain: float = GREET_OPINION_GAIN * (1.3 - player_aggression_score())
		t.player_opinion = clampf(float(t.player_opinion) + gain, -1.0, 1.0)
	if not is_first_contact:
		var line: String = t.greeting() if t.has_method("greeting") else ""
		notify_cat(CAT_YOU, "You greet the %s.%s" % [t.tribe_name, "\n\"%s\"" % line if line != "" else ""])

func nearest_undiscovered_camp(from_pos: Vector3):
	return _nearest_tribe_from(from_pos, false)

func discover_near(pos: Vector3) -> void:
	var t = _nearest_tribe_from(pos, false)
	if t != null and pos.distance_to(t.global_position) <= SCOUT_RANGE:
		t.discover()
		notify_cat(CAT_TRIBE, "Scouts mapped the %s — %s, strength %d." % [t.tribe_name, t.archetype, t.strength])  # your member-scouts' report

func discover_rival(_report: String) -> void:
	var t = _nearest_undiscovered_tribe()
	if t == null:
		notify_cat(CAT_TRIBE, "Scouts range far but turn up no new camps.")
		return
	t.discover()
	notify_cat(CAT_TRIBE, "Scouts found the %s — %s, strength %d. (R+4 to raid the nearest)" % [
		t.tribe_name, t.archetype, t.strength])

func cycle_focus(dir: int) -> void:
	var known: Array = []
	for t in world_tribes:
		if is_instance_valid(t) and not t.defeated and t.discovered:
			known.append(t)
	if known.is_empty():
		focus_tribe = null
		notify_cat(CAT_YOU, "No scouted tribes yet — scout with [T].")
		return
	var idx := known.find(focus_tribe)
	idx = (idx + dir + known.size()) % known.size()
	focus_tribe = known[idx]
	notify_cat(CAT_YOU, "Focused: %s — %s, strength %d   ([K] to raid)" % [
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
	player_war_trigger_count += 1
	_launch_raid(_nearest_discovered_tribe())

func _launch_raid(target) -> void:
	if not _raid.is_empty() and _raid.get("live", false):
		notify_cat(CAT_YOU, "A raid is already underway.")
		return
	if target == null:
		notify_cat(CAT_YOU, "No scouted camp to raid — scout with [T] first.")
		return
	var party: Array = []
	for m in members:
		if is_instance_valid(m) and m.get("is_backing_you") and not m.get("is_busy"):
			party.append(m)
	if party.is_empty():
		notify_cat(CAT_YOU, "No free backers to raid with — win some loyalty first.")
		return
	var strength := 8
	for m in party:
		strength += m.get_might()
		m.dispatch_to(target.global_position, "raid", 14.0)
	_raid = {"tribe": target, "party": party, "strength": strength, "timer": 8.0, "live": true}
	notify_cat(CAT_TRIBE, "RAID! %d march on the %s (your strength %d)." % [  # your fighters marching
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
		_player_caused_wipeout = true   # a rival fell to YOUR raid -- see _check_victory
		var joined: int = target.conquer(self)
		var sub := "  %d swear to your clan!" % joined if joined > 0 else ""
		notify_cat(CAT_TRIBE, "RAID WON vs %s! +%d food, +%d skins. Camp razed.%s" % [
			fallen_name, loot_f, loot_m, sub])
	else:
		unrest += 0.5
		for m in _raid["party"]:
			if not is_instance_valid(m): continue
			if m.has_method("take_hit"): m.take_hit(randf_range(25.0, 65.0), null)
			if is_instance_valid(m) and "relationship" in m:
				m.relationship = maxf(0.0, m.relationship - 0.3)
		notify_cat(CAT_TRIBE, "RAID LOST vs %s — fighters wounded, some fell." % target.tribe_name)
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
	_mood_tick(delta)

	# leader-only rally + raid commands (hold R)
	if is_leader and Input.is_key_pressed(KEY_R):
		if _key_just(KEY_1): rally_order("gather")
		elif _key_just(KEY_2): rally_order("hunt")
		elif _key_just(KEY_3): rally_order("scout")
		elif _key_just(KEY_4): order_raid()

	# While the chat box is open, these global hotkeys must stand down -- typing
	# "grab wood" shouldn't toggle the brain panel on 'b', and TAB is the chat's
	# own "switch who I'm talking to" key. FPSPlayer already gates movement on
	# TribeChat.open; these were reading raw keys and bypassing that gate.
	if not TribeChat.open and not TribeTradeUI.open and not TribeTradeMenu.open and not TribeOverview.open and not TribeInventoryUI.open:
		if _key_just(KEY_B): _toggle_brain_panel()
		if _key_just(KEY_U): _toggle_ui()
		if _key_just(KEY_TAB): _toggle_map()
		if _key_just(KEY_T): TribeTradeMenu.toggle_menu()
		if _key_just(KEY_Q): TribeOverview.toggle_overview()
		if _key_just(KEY_8): TribeInventoryUI.toggle_panel()
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
	_tribe_growth(delta)
	_decay_rivalries(delta)
	_auto_trade_tick(delta)
	_update_day_night(delta)
	_recruit_tick(delta)
	_raid_tick(delta)
	_faction_tick(delta)
	_respawn_tick(delta)
	_neutral_tick(delta)
	_ecology_tick(delta)
	_material_upgrade_tick(delta)
	_weather_tick(delta)
	_war_tick(delta)
	_check_victory()

	_update_ui_positions()
	_update_brain_panel()
	_update_status()
	_update_flash()
	_update_cat_boxes(delta)
	_update_player_label()
	_update_factions_label()
	_update_feed_hint(delta)
	_cull_eyes(delta)

# ── DECORATIVE MESH CULL for googly eyes. Every animal/npc/member carries 2 eye
# meshes (each with a pupil child) = up to 4 tiny spheres apiece. They read as
# eyes only up close; past a few metres they're a sub-pixel smear yet still cost
# a draw call each — hundreds of them across a big herd + population. Hide the
# eye node (which takes its pupil child with it) beyond EYE_CULL_DIST. Purely
# visual: nothing gameplay reads eye visibility. Throttled like the tree cull.
const EYE_CULL_DIST := 32.0
var _eye_cull_accum: float = 0.0

func _cull_eyes(delta: float) -> void:
	_eye_cull_accum -= delta
	if _eye_cull_accum > 0.0:
		return
	_eye_cull_accum = 0.4
	var p := get_tree().get_first_node_in_group("player") as Node3D
	if p == null or not is_instance_valid(p):
		return
	var pp := p.global_position
	var cull2 := EYE_CULL_DIST * EYE_CULL_DIST
	for e in get_tree().get_nodes_in_group("googly_eye"):
		var en := e as Node3D
		if en == null:
			continue
		var want: bool = pp.distance_squared_to(en.global_position) <= cull2
		if en.visible != want:
			en.visible = want

# ── RENDER CULL for the forest — RETIRED. The forest is now drawn by ONE
# MultiMeshInstance3D (tree_field.gd), so the whole woods is a single batched draw
# call regardless of distance. The old per-node visibility far-cull (toggling
# .visible on thousands of individual tree MeshInstance3Ds every 0.4s) is obsolete
# and would only waste cycles fighting the MultiMesh — trees no longer own a mesh
# to hide. Removed from _update_ui; tree gameplay (group "tree", distance chop) is
# unchanged. If a per-instance distance fade is ever wanted, set the field's
# visibility_range_end instead of hiding gameplay nodes.

# ─────────────────────────────────────────────────────────────────────────────
# VICTORY / DEFEAT
# ─────────────────────────────────────────────────────────────────────────────
func _check_victory() -> void:
	# NO FORCED WINNER. The world is meant to be mostly harmonious and to keep
	# running indefinitely -- you can leave and come back to it, so it must never
	# resolve to a "you win" end state on its own. This used to declare victory
	# the instant every rival fell; now the world simply persists.
	#
	# The only end kept is one the PLAYER deliberately caused: if YOU personally
	# wiped out every rival camp, that's an achievement worth marking. But the AI
	# left to itself trends toward trade and alliance (war is a rare, last-resort
	# response to real scarcity), so all rivals falling on their own basically
	# doesn't happen -- and if it somehow did, the survivors just carry on.
	if game_over:
		return
	if _live_tribe_count() == 0 and world_tribe_count > 0 and _player_caused_wipeout:
		game_over = true
		won = true
		_flash("Every rival camp has fallen — by YOUR hand. The land is yours.")

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
	notify_cat(CAT_TRIBE, "RALLY %s → %d marched out, %d refused" % [kind, accepted, refused])  # your tribe responding

# ─────────────────────────────────────────────────────────────────────────────
# CATCH-UP GROWTH (2026-07-19): "player tribe needs to grow at the same pace
# as npc tribe clans" -- rival clans birth new members from a food surplus
# ALONE (see world_tribe.gd._grow()), on top of recruiting wanderers. The
# player's tribe previously had ONLY the wanderer-recruit path (walk up,
# spend food, per member) -- a real structural growth-rate gap, not a
# balance nuance. Mirrors the rival tribe's own formula (scaled upkeep,
# capped by member_cap) so the player isn't left behind just for not
# manually chasing down wanderers.
# ─────────────────────────────────────────────────────────────────────────────
var _growth_cd: float = 15.0

func _tribe_growth(delta: float) -> void:
	_growth_cd -= delta
	if _growth_cd > 0.0:
		return
	# SPED UP (2026-07-19): "progress is too slow" -- was 20-30s between
	# growth attempts; a real, tangible pace increase without breaking the
	# food-cost gate that actually limits growth.
	_growth_cd = randf_range(12.0, 18.0)
	if members.size() >= member_cap:
		return
	var upkeep: int = members.size() * 2 + 4
	if food < upkeep:
		return
	food -= upkeep
	var ang := randf() * TAU
	var mx := cos(ang) * spawn_radius
	var mz := sin(ang) * spawn_radius
	var pos := Vector3(mx, ground_y(mx, mz) + 1.5, mz)
	_spawn_one_member(_next_member_name(), PERSONALITY_POOL[randi() % PERSONALITY_POOL.size()], pos)
	notify_cat(CAT_TRIBE, "A new member was born into the tribe -- the clan grows.")

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
		notify_cat(CAT_TRIBE, "The challenge fades — the tribe is fed and content.")
	if unrest >= 2.2:
		_lose_leadership()

func _lose_leadership() -> void:
	var deposed_unrest := unrest
	is_leader  = false
	challenged = false
	unrest     = 1.0
	for m in members:
		if is_instance_valid(m) and m.get("is_backing_you"):
			m.is_backing_you = false
	_flash("⚠ THE TRIBE HAS TURNED ON YOU — you are no longer leader.")
	# OVERTHROW + RENAME THE THRONE (2026-07-19): losing backers used to just
	# strip the title with nothing else changing -- no successor, no lasting
	# consequence past an unrest reset. A genuinely SUSTAINED crisis (well
	# past the ordinary threshold, not one bad afternoon) now installs a real
	# successor from the tribe's own hierarchy and renames the settlement --
	# the chain of command the tribe already has (is_official()) resolving a
	# real crisis of confidence, not the player just quietly regaining the
	# title next time unrest dips.
	if deposed_unrest >= OVERTHROW_UNREST:
		_attempt_overthrow()

signal overthrown(new_leader_name: String, new_throne_name: String)
const OVERTHROW_UNREST := 3.0
const THRONE_NAMES := ["Ember Hold", "Stonewatch", "Green Hollow", "Ashfall Rest", "Wolfmere", "Highstead"]
var throne_name: String = "the tribe"
var npc_leader_name: String = ""

func _attempt_overthrow() -> void:
	var officials: Array = []
	for m in members:
		if is_instance_valid(m) and is_official(m):
			officials.append(m)
	if officials.is_empty():
		return   # no one in the hierarchy is ready to actually take the throne
	officials.sort_custom(func(a, b): return float(a.get("relationship")) > float(b.get("relationship")))
	var successor = officials[0]
	npc_leader_name = str(successor.get("member_name"))
	throne_name = THRONE_NAMES[randi() % THRONE_NAMES.size()]
	overthrown.emit(npc_leader_name, throne_name)
	notify_cat(CAT_TRIBE, "%s has claimed the throne of %s." % [npc_leader_name, throne_name])

# ─────────────────────────────────────────────────────────────────────────────
# RECRUITING
# ─────────────────────────────────────────────────────────────────────────────
func _recruit_tick(delta: float) -> void:
	_recruit_accum += delta
	if _recruit_accum < 30.0: return
	_recruit_accum = 0.0
	if food > members.size() * 2 and members.size() < member_cap and unrest < 0.5:
		_spawn_one_member(_next_member_name(), _random_personality(), _edge_position())
		notify_cat(CAT_TRIBE, "A wanderer drifts toward your well-fed camp...")  # potential new member of your tribe

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
			notify_cat(CAT_TRIBES, "The abandoned %s camp crumbles." % nm)  # world event
	alive = _live_world_tribes()

	# HARMONIOUS_WORLD skips ALL the endgame machinery -- the scripted "final
	# battle" when 2-3 clans remain, and the dominion countdown that crowns a
	# survivor. Those exist to DRIVE a world to a winner; this mode is meant to
	# run forever without one. (In practice tribes rarely thin this far now that
	# war is a last resort and allies don't fight, but disabling it explicitly is
	# what guarantees the world never resolves itself while you're away.)
	if not HARMONIOUS_WORLD:
		if not _final_battle_triggered and world_tribe_count > 2 \
				and alive.size() >= 2 and alive.size() <= 3:
			_trigger_final_battle(alive)
		if alive.size() == 1 and world_tribe_count > 1:
			_tick_dominion(alive[0], delta)
			return
		_dominion = null

	# peacetime economy: trade and environment run every tick, war only sometimes
	_peace_tick(delta)
	_incoming_request_tick(delta)
	_environment_tick(delta)

	_war_accum += delta
	if _war_accum < war_interval: return
	_war_accum = 0.0
	if alive.size() >= 2:
		_resolve_war_round(alive)

# ─────────────────────────────────────────────────────────────────────────────
# PEACETIME ECONOMY — trade and environment, the engine of a harmonious world
# ─────────────────────────────────────────────────────────────────────────────
const HARMONIOUS_WORLD := true   # no forced winner; endgame machinery disabled
const PEACE_TRADE_INTERVAL := 8.0
const ENV_SHOCK_INTERVAL := 90.0     # a season turns roughly this often
var _peace_accum: float = 0.0
var _env_accum: float = 0.0
var _season: String = "fair"

# Trade WITHOUT waiting for war pressure. The old economy only traded as a way to
# avoid a raid, so two content tribes never dealt -- "make them trade more" means
# trade has to be a normal peacetime activity, not just crisis relief. Any tribe
# even mildly short of food will buy from a near neighbour with a surplus.
func _peace_tick(delta: float) -> void:
	_peace_accum += delta
	if _peace_accum < PEACE_TRADE_INTERVAL:
		return
	_peace_accum = 0.0
	var alive := _live_world_tribes()
	if alive.size() < 2:
		return
	var wanting: Array = []
	for t in alive:
		# a low bar on purpose: even a small dip below comfortable makes a tribe
		# shop around. This is what turns trade from rare into routine.
		if t.has_method("hunger_pressure") and t.hunger_pressure() > 0.15:
			wanting.append(t)
	if not wanting.is_empty():
		# PEACETIME trade goes by physical envoy now -- a caravan walks the goods
		# between camps and the deal only closes on arrival. (War-round trade still
		# uses the instant _try_trade: a starving tribe about to march can't wait
		# for a courier to stroll across the map.)
		_try_dispatch_envoy(wanting, alive)

# The world is HARMONIOUS but not static. Seasons turn: a lean season (drought,
# hard winter) drains every tribe's stores, which raises hunger, which makes
# trade busier and -- if a tribe can't buy its way out -- can tip the desperate
# into war. A good season refills. This is the "susceptible to changing
# environments / low resources" part: peace is the default, scarcity is the
# thing that occasionally breaks it, exactly as asked.
# SEASONAL MOOD MIGRATION -- "a tribe whose average Trust/Follow firing has
# been low for a sustained stretch actually splits or relocates, driven by
# real brain state, not a scripted event." Distinct from the existing
# per-member defection (relationship < DEFECT_THRESHOLD, tribemember.gd):
# THIS is a collective consequence of the whole camp's real, aggregate
# brain activity staying low, not any one member's own number crossing a
# line. Members with the lowest individual relationship are the ones who
# actually leave, once the tribe-wide mood has been bad for long enough.
const MOOD_CHECK_INTERVAL := 20.0
const MOOD_EMA_DECAY := 0.85          # smooths the tribe-wide mood across checks
const LOW_MOOD_THRESHOLD := 0.12      # below this, Trust/Follow are barely firing at all
const LOW_MOOD_SUSTAIN_CHECKS := 3    # ~60s of sustained low mood before anyone leaves
const MOOD_MIGRATION_FRACTION := 0.3  # the least-trusting third goes
const MIGRATION_COOLDOWN := 300.0     # don't repeat every 60s once triggered
var _tribe_mood_ema: float = 1.0
var _mood_check_accum: float = 0.0
var _low_mood_streak: int = 0
var _last_migration_time: float = -1.0e9

func _mood_tick(delta: float) -> void:
	_mood_check_accum += delta
	if _mood_check_accum < MOOD_CHECK_INTERVAL:
		return
	_mood_check_accum = 0.0
	if members.is_empty():
		return
	var total := 0.0
	var n := 0
	for m in members:
		if is_instance_valid(m) and m.has_method("trust_follow_mood"):
			total += float(m.trust_follow_mood())
			n += 1
	if n == 0:
		return
	var sample: float = total / float(n)
	_tribe_mood_ema = _tribe_mood_ema * MOOD_EMA_DECAY + sample * (1.0 - MOOD_EMA_DECAY)
	if _tribe_mood_ema < LOW_MOOD_THRESHOLD:
		_low_mood_streak += 1
	else:
		_low_mood_streak = 0
	var now: float = Time.get_ticks_msec() / 1000.0
	if _low_mood_streak >= LOW_MOOD_SUSTAIN_CHECKS and members.size() >= 4 \
			and now - _last_migration_time > MIGRATION_COOLDOWN:
		_trigger_mood_migration(now)

func _trigger_mood_migration(now: float) -> void:
	_last_migration_time = now
	_low_mood_streak = 0
	var sorted_members: Array = members.duplicate()
	sorted_members.sort_custom(func(a, b): return float(a.get("relationship")) < float(b.get("relationship")))
	var leave_count: int = maxi(1, int(sorted_members.size() * MOOD_MIGRATION_FRACTION))
	var left_names: Array[String] = []
	for i in range(mini(leave_count, sorted_members.size())):
		var m = sorted_members[i]
		if is_instance_valid(m) and m.has_method("mass_migrate_out"):
			m.mass_migrate_out("The tribe's spirit has been low for too long. I'm leaving to find somewhere better.")
			left_names.append(str(m.get("member_name")))
	print("[Tribemanager] MOOD MIGRATION: %d member(s) leaving after sustained low tribe-wide trust/follow: %s" % [
		left_names.size(), ", ".join(left_names)])

func _environment_tick(delta: float) -> void:
	_env_accum += delta
	if _env_accum < ENV_SHOCK_INTERVAL:
		return
	_env_accum = 0.0
	var alive := _live_world_tribes()
	if alive.is_empty():
		return
	var roll := randf()
	if roll < 0.30:
		_season = "lean"
		for t in alive:
			t.food = int(t.food * 0.6)         # stores drain -> hunger rises
		notify_cat(CAT_TRIBES, "🌧 A lean season sets in. Stores run short across the land.")  # world season
		TribeMemory.record_event("Season: lean", "A hard season thinned every tribe's stores.", "world")
	elif roll < 0.55:
		_season = "bountiful"
		for t in alive:
			t.food += 8 + t.member_count       # plenty -> peace deepens
		notify_cat(CAT_TRIBES, "🌞 A bountiful season. Camps are fat and content.")
		TribeMemory.record_event("Season: bountiful", "A rich season filled every stockpile.", "world")
	else:
		_season = "fair"

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

# A hungry tribe would rather BUY than bleed. Each archetype works a different
# material (tribes/*.tribe `material:`), so a hungry Builder holding Glass and a
# fat Forager holding food have an obvious deal -- and taking the deal builds the
# trade history that alliances are later made of.
#
# Refuses when the pair genuinely hate each other: a big grudge, or a paranoid /
# dishonourable leader, means they'd sooner raid you than sell to you. That's the
# knob that decides whether a world settles into commerce or into war.
func _try_trade(hungry: Array, alive: Array) -> bool:
	for buyer in hungry:
		if not buyer.has_method("material_surplus"):
			continue
		if buyer.material_surplus() <= 0:
			continue                       # nothing to pay with -> they may have to fight
		for seller in alive:
			if seller == buyer or not seller.has_method("food_surplus"):
				continue
			if seller.food_surplus() <= 0:
				continue                   # no spare food to sell
			# PHYSICALLY CLOSE ENOUGH TO CARRY GOODS. Trade used to fire between
			# any two tribes regardless of where their camps were -- goods
			# teleported across the map. A trade is a caravan; it needs a
			# plausible distance. Allied tribes reach a little further for each
			# other, the way real partners do.
			var reach: float = TRADE_RANGE
			if buyer.has_method("is_allied_with") and buyer.is_allied_with(seller.tribe_name):
				reach *= 1.5
			if (buyer as Node3D).global_position.distance_to((seller as Node3D).global_position) > reach:
				continue
			# would they even deal with each other?
			var grudge: float = buyer.grudge_toward(seller.tribe_name) if buyer.has_method("grudge_toward") else 0.0
			var g2: float = seller.grudge_toward(buyer.tribe_name) if seller.has_method("grudge_toward") else 0.0
			if maxf(grudge, g2) > TRADE_GRUDGE_MAX:
				continue                   # too much bad blood to trade
			var honor: float = float(seller.leader_traits.get("honor", 0.5))
			var paranoia: float = float(buyer.leader_traits.get("paranoia", 0.5))
			if honor < 0.25 or paranoia > 0.8:
				continue                   # a crook won't deal fairly; a paranoiac won't risk it

			var food_moved: int = mini(seller.food_surplus(), buyer.upkeep_cost())
			var mat_moved: int = maxi(1, int(round(float(food_moved) / 6.0)))
			mat_moved = mini(mat_moved, buyer.material_surplus())
			if food_moved <= 0 or mat_moved <= 0:
				continue

			seller.food -= food_moved
			buyer.food += food_moved
			buyer.material_stock -= mat_moved
			seller.material_stock += mat_moved
			# trading warms both sides: cools any grudge AND builds the alliance
			# bond. Repeated deals cross ALLY_THRESHOLD and an alliance forms --
			# this is the "what alliances are built on" comment made real.
			var was_allied: bool = buyer.has_method("is_allied_with") and buyer.is_allied_with(seller.tribe_name)
			if buyer.has_method("add_grudge"):
				buyer.add_grudge(seller.tribe_name, -TRADE_GOODWILL)
				buyer.add_bond(seller.tribe_name, TRADE_BOND)
			if seller.has_method("add_grudge"):
				seller.add_grudge(buyer.tribe_name, -TRADE_GOODWILL)
				seller.add_bond(buyer.tribe_name, TRADE_BOND)
			if not was_allied and buyer.has_method("is_allied_with") \
					and buyer.is_allied_with(seller.tribe_name):
				notify_cat(CAT_TRIBES, "🤝 The %s and the %s are now ALLIES." % [
					buyer.tribe_name, seller.tribe_name])  # AI-AI alliance = world
				TribeMemory.record_event("Alliance: %s + %s" % [buyer.tribe_name, seller.tribe_name],
					"Years of fair trade made allies of the %s and the %s." % [
						buyer.tribe_name, seller.tribe_name], "alliance")
			notify_cat(CAT_TRIBES, "🤝 The %s trade %d %s to the %s for %d food." % [
				buyer.tribe_name, mat_moved, buyer.material_name(), seller.tribe_name, food_moved])  # AI-AI trade
			print("[TRADE] %s -%d %s +%d food  <->  %s (buyer hunger now %.2f)" % [
				buyer.tribe_name, mat_moved, buyer.material_name(), food_moved,
				seller.tribe_name, buyer.hunger_pressure()])
			TribeMemory.record_event("Trade: %s and %s" % [buyer.tribe_name, seller.tribe_name],
				"The %s gave %d %s to the %s for %d food. Both sides walked away warmer." % [
					buyer.tribe_name, mat_moved, buyer.material_name(), seller.tribe_name, food_moved],
				"trade")
			return true
	return false

# ─────────────────────────────────────────────────────────────────────────────
# PHYSICAL TRADE ENVOYS — the visible, walking version of _try_trade.
#
# Eligibility (who CAN deal) mirrors _try_trade exactly: a hungry buyer with a
# material surplus, a near-enough seller with a food surplus, no blood feud, no
# crooked/paranoid leader. The difference is WHEN the goods move: here nothing
# changes at dispatch. A courier walks to the seller and the exchange+warm only
# happens on arrival (_on_envoy_arrived), where it's re-validated against the
# world as it is by then.
# ─────────────────────────────────────────────────────────────────────────────
func _try_dispatch_envoy(hungry: Array, alive: Array) -> bool:
	_prune_envoys()
	if _active_envoys.size() >= ENVOY_MAX_IN_FLIGHT:
		return false
	for buyer in hungry:
		if not buyer.has_method("material_surplus") or buyer.material_surplus() <= 0:
			continue
		for seller in alive:
			if seller == buyer or not seller.has_method("food_surplus"):
				continue
			if seller.food_surplus() <= 0:
				continue
			if _pair_busy(buyer.tribe_name, seller.tribe_name):
				continue                   # a caravan is already walking this route
			var reach: float = TRADE_RANGE
			if buyer.has_method("is_allied_with") and buyer.is_allied_with(seller.tribe_name):
				reach *= 1.5               # allies reach further, as in _try_trade
			if (buyer as Node3D).global_position.distance_to((seller as Node3D).global_position) > reach:
				continue
			var grudge: float = buyer.grudge_toward(seller.tribe_name) if buyer.has_method("grudge_toward") else 0.0
			var g2: float = seller.grudge_toward(buyer.tribe_name) if seller.has_method("grudge_toward") else 0.0
			if maxf(grudge, g2) > TRADE_GRUDGE_MAX:
				continue
			var honor: float = float(seller.leader_traits.get("honor", 0.5))
			var paranoia: float = float(buyer.leader_traits.get("paranoia", 0.5))
			if honor < 0.25 or paranoia > 0.8:
				continue
			# provisional offer -- final amounts are recomputed on arrival
			var food_moved: int = mini(seller.food_surplus(), buyer.upkeep_cost())
			var mat_moved: int = maxi(1, int(round(float(food_moved) / 6.0)))
			mat_moved = mini(mat_moved, buyer.material_surplus())
			if food_moved <= 0 or mat_moved <= 0:
				continue
			_spawn_envoy(buyer, seller, false, mat_moved, food_moved,
				str(buyer.tribe_name), str(seller.tribe_name))
			return true
	return false

# Build and launch one courier from the sender's camp toward the host camp.
func _spawn_envoy(sender: Node, host: Node, is_player: bool,
		mat: int, food: int, sname: String, hname: String) -> void:
	var envoy := Node3D.new()
	envoy.set_script(load("res://trade_envoy.gd"))
	add_child(envoy)
	# seat it at the sender's camp (or the player's trading post) on the terrain.
	# ROUTED VIA TRADING POST (2026-07-19): used to start at the abstract
	# stockpile position; every player-side envoy now walks from the actual
	# building the player raised (gated on trading_post_built() by every
	# caller of this function -- see propose_trade_with()/player_send_trade_envoy()).
	var start: Vector3
	if is_player:
		start = trading_post_position()
	else:
		start = (sender as Node3D).global_position
	start.y = ground_y(start.x, start.z) + 0.05
	envoy.global_position = start
	envoy.setup(self, sender, host, is_player, mat, food, sname, hname)
	_active_envoys.append(envoy)
	_envoy_pairs[_pair_key(sname, hname)] = true
	notify_cat(CAT_TRIBES, "📜 A %s envoy sets out for the %s, offering %d %s for food." % [
		sname, hname, mat, (sender.material_name() if not is_player else "goods")])  # world diplomacy

# ARRIVAL RULING — the deal actually happens here, re-checked against the world
# as it stands now. Mirrors _try_trade's accept/exchange/warm, plus the
# alliance/disposition terms the brief asks for.
func _on_envoy_arrived(envoy: Node) -> void:
	# An NPC caravan sent TO the player has no to_tribe — it carries an OFFER the
	# player rules on via a panel, not a deal we settle here. Handle it first,
	# before the host-validity check below (which would reject a null to_tribe).
	if envoy.get("to_is_player") == true:
		_on_incoming_request_arrived(envoy)
		return
	var host = envoy.to_tribe
	if not is_instance_valid(host) or host.defeated:
		return                              # nobody home; envoy just walks back
	if envoy.from_is_player:
		# A note-only courier (the player's acceptance) carries no goods: the
		# exchange already happened when the player clicked Accept. Just confirm.
		if envoy.get("note_only") == true:
			notify_cat(CAT_TRIBE, "📜 The %s receive your note — the trade is sealed." % host.tribe_name)  # your tribe's trade
			return
		_resolve_player_envoy(envoy, host)
		return
	var buyer = envoy.from_tribe
	if not is_instance_valid(buyer) or buyer.defeated:
		return
	var seller = host
	# ── would they still deal? (disposition may have soured en route) ──
	var grudge: float = buyer.grudge_toward(seller.tribe_name)
	var g2: float = seller.grudge_toward(buyer.tribe_name)
	var allied: bool = buyer.is_allied_with(seller.tribe_name)
	if not allied and maxf(grudge, g2) > TRADE_GRUDGE_MAX:
		notify_cat(CAT_TRIBES, "✗ The %s turn the %s envoy away — too much bad blood." % [
			seller.tribe_name, buyer.tribe_name])  # AI-AI
		return
	# ── recompute the exchange against current stores ──
	var food_moved: int = mini(seller.food_surplus(), buyer.upkeep_cost())
	if allied:
		food_moved = int(round(food_moved * (1.0 + ENVOY_ALLY_FOOD_BONUS)))
		food_moved = mini(food_moved, seller.food)   # never overdraw the seller
	var mat_moved: int = maxi(1, int(round(float(envoy.food_amt) / 6.0)))
	mat_moved = mini(mat_moved, buyer.material_surplus())
	if food_moved <= 0 or mat_moved <= 0:
		notify_cat(CAT_TRIBES, "✗ The %s deal falls through — nothing left to trade." % seller.tribe_name)  # AI-AI
		return
	# ── close it: goods change hands, both sides warm (identical to _try_trade) ──
	seller.food -= food_moved
	buyer.food += food_moved
	buyer.material_stock -= mat_moved
	seller.material_stock += mat_moved
	var was_allied: bool = allied
	buyer.add_grudge(seller.tribe_name, -TRADE_GOODWILL)
	buyer.add_bond(seller.tribe_name, TRADE_BOND)
	seller.add_grudge(buyer.tribe_name, -TRADE_GOODWILL)
	seller.add_bond(buyer.tribe_name, TRADE_BOND)
	if not was_allied and buyer.is_allied_with(seller.tribe_name):
		notify_cat(CAT_TRIBES, "🤝 The %s and the %s are now ALLIES." % [buyer.tribe_name, seller.tribe_name])  # AI-AI
		TribeMemory.record_event("Alliance: %s + %s" % [buyer.tribe_name, seller.tribe_name],
			"Years of fair trade made allies of the %s and the %s." % [
				buyer.tribe_name, seller.tribe_name], "alliance")
	notify_cat(CAT_TRIBES, "🤝 Envoy delivered: the %s trade %d %s to the %s for %d food." % [
		buyer.tribe_name, mat_moved, buyer.material_name(), seller.tribe_name, food_moved])  # AI-AI
	print("[ENVOY] %s -%d %s +%d food  <->  %s (allied=%s)" % [
		buyer.tribe_name, mat_moved, buyer.material_name(), food_moved, seller.tribe_name, str(was_allied)])
	TribeMemory.record_event("Trade: %s and %s" % [buyer.tribe_name, seller.tribe_name],
		"A %s envoy carried %d %s to the %s and returned with %d food. Both sides warmed." % [
			buyer.tribe_name, mat_moved, buyer.material_name(), seller.tribe_name, food_moved], "trade")

# PLAYER-sent envoy: the player offers material for food. The host's willingness
# rides on player_opinion (the player's standing with that tribe) rather than the
# rival-to-rival grudge dict, since the player isn't a world_tribe.
func _resolve_player_envoy(envoy: Node, host: Node) -> void:
	if float(host.player_opinion) <= -0.3:
		notify_cat(CAT_TRIBE, "✗ The %s refuse your envoy — they don't trust you." % host.tribe_name)  # your envoy
		return
	if host.food_surplus() <= 0:
		notify_cat(CAT_TRIBE, "✗ The %s have no food to spare for your envoy." % host.tribe_name)
		return
	# ECONOMIC SENSE (2026-07-19): "only have tribes take trade if it actually
	# makes sense -- abundance of requested and scarcity of received" -- food
	# food_surplus() above already covers "abundance of what's requested of
	# them"; this covers the other half, "scarcity of what they'd receive".
	# A tribe already swimming in materials has no real reason to want more,
	# no matter how much food they can spare.
	if host.has_method("material_pressure") and float(host.material_pressure()) < 0.15:
		notify_cat(CAT_TRIBE, "✗ The %s have no real need for more goods right now." % host.tribe_name)
		return
	var mat_moved: int = mini(envoy.mat_amt, materials)
	if mat_moved <= 0:
		notify_cat(CAT_TRIBE, "✗ Your envoy arrived empty-handed — no goods to trade.")
		return
	var food_moved: int = mini(host.food_surplus(), mat_moved * 6)
	if float(host.player_opinion) >= 0.4:
		food_moved = int(round(food_moved * (1.0 + ENVOY_ALLY_FOOD_BONUS)))  # a trusted friend deals better
	food_moved = mini(food_moved, host.food)
	if food_moved <= 0:
		notify_cat(CAT_TRIBE, "✗ The %s deal falls through — nothing to send back." % host.tribe_name)
		return
	# goods change hands: player pays material, gains food; host the reverse
	materials -= mat_moved
	food += food_moved
	host.food -= food_moved
	host.material_stock += mat_moved
	host.player_opinion = clampf(float(host.player_opinion) + 0.12, -1.0, 1.0)  # trading warms them to you
	notify_cat(CAT_TRIBE, "🤝 Your envoy trades %d goods to the %s for %d food." % [
		mat_moved, host.tribe_name, food_moved])  # your tribe's trade
	TribeMemory.record_event("Trade: your tribe and %s" % host.tribe_name,
		"Your envoy carried %d goods to the %s and returned with %d food." % [
			mat_moved, host.tribe_name, food_moved], "trade")

# PLAYER ACTION — send a trade envoy to the nearest eligible rival, offering
# material for food. Bound to a key in FPSPlayer.gd.
# ─────────────────────────────────────────────────────────────────────────────
# TRADING MENU (2026-07-19): player_send_trade_envoy() below always auto-picks
# the nearest willing partner and a fixed offer size -- there was no way for
# the player to actually CHOOSE who to trade with or how much. This is the
# real backend a menu UI (tribe_trade_menu.gd) reads/drives: a live list of
# every discovered, non-hostile tribe with what they're offering and what
# they'd want, and a directed propose action for a specific tribe/amount.
# ─────────────────────────────────────────────────────────────────────────────
func trade_partners() -> Array:
	var out: Array = []
	if not trading_post_built():
		return out
	for t in _live_world_tribes():
		if not bool(t.get("discovered")):
			continue
		if float(t.player_opinion) <= -0.3:
			continue
		out.append({
			"tribe": t,
			"tribe_name": str(t.tribe_name),
			"player_opinion": float(t.player_opinion),
			"rivalry": rivalry_toward(str(t.tribe_name)),
			"material": str(t.material_name()) if t.has_method("material_name") else "goods",
			"surplus": int(t.material_surplus()) if t.has_method("material_surplus") else 0,
			"resources": t.island_resources() if t.has_method("island_resources") else [],
		})
	return out

## Directed version of player_send_trade_envoy() -- a specific tribe and a
## specific offer size, chosen from the menu, instead of always auto-picking
## the nearest willing partner at a fixed amount.
func propose_trade_with(tribe: Node, offer_amt: int) -> bool:
	if not trading_post_built():
		notify_cat(CAT_YOU, "Raise a trading post first — press 9 near camp.")
		return false
	_prune_envoys()
	if not is_instance_valid(tribe) or tribe.defeated:
		return false
	if materials <= 0:
		notify_cat(CAT_YOU, "You have no goods to trade — loot or craft some first.")
		return false
	if _active_envoys.size() >= ENVOY_MAX_IN_FLIGHT:
		notify_cat(CAT_YOU, "Your envoys are already on the road — wait for one to return.")
		return false
	if float(tribe.player_opinion) <= -0.3:
		notify_cat(CAT_YOU, "The %s would never receive your courier." % str(tribe.tribe_name))
		return false
	if _pair_busy("You", str(tribe.tribe_name)):
		notify_cat(CAT_YOU, "You already have a courier on the way to the %s." % str(tribe.tribe_name))
		return false
	var offer: int = clampi(offer_amt, 1, maxi(1, materials))
	_spawn_envoy(null, tribe, true, offer, offer * 6, "You", str(tribe.tribe_name))
	return true

func player_send_trade_envoy() -> void:
	if not trading_post_built():
		notify_cat(CAT_YOU, "Raise a trading post first — press 9 near camp.")  # player pre-check
		return
	_prune_envoys()
	if materials <= 0:
		notify_cat(CAT_YOU, "You have no goods to trade — loot or craft some first.")  # player pre-check
		return
	if _active_envoys.size() >= ENVOY_MAX_IN_FLIGHT:
		notify_cat(CAT_YOU, "Your envoys are already on the road — wait for one to return.")  # player pre-check
		return
	var origin: Vector3 = trading_post_position()
	var best = null
	var best_d := INF
	for t in _live_world_tribes():
		if float(t.player_opinion) <= -0.3:
			continue                        # they'd never receive your courier
		if not t.has_method("food_surplus") or t.food_surplus() <= 0:
			continue
		if _pair_busy("You", str(t.tribe_name)):
			continue
		var d: float = origin.distance_to((t as Node3D).global_position)
		if d > TRADE_RANGE * 1.5:
			continue                        # too far to walk a caravan
		if d < best_d:
			best_d = d
			best = t
	if best == null:
		notify_cat(CAT_YOU, "No willing trade partner within reach right now.")  # player pre-check
		return
	var offer: int = maxi(1, mini(materials, 4))
	_spawn_envoy(null, best, true, offer, offer * 6, "You", str(best.tribe_name))

# ─────────────────────────────────────────────────────────────────────────────
# INCOMING TRADE REQUESTS TO THE PLAYER
# Periodically an eligible rival sends a caravan to the PLAYER's camp proposing a
# trade (their worked material for some of the player's food). On arrival the
# player gets an accept/decline panel (TribeTradeUI). Accept performs the
# exchange, warms the tribe, and sends a return "acceptance courier" back.
# ─────────────────────────────────────────────────────────────────────────────
const INCOMING_REQUEST_INTERVAL := 22.0   # throttle: at most one dispatch attempt this often
var _incoming_accum: float = 0.0

# ─────────────────────────────────────────────────────────────────────────────
# AUTONOMOUS TRADE (2026-07-19): "generally this should be what drives worker
# actions around camp, gated by trust of course" -- the tribe can now decide
# ON ITS OWN to trade a real materials surplus for food, same as it already
# autonomously gathers/hunts/builds. Requires BOTH a real surplus (not just
# any materials) AND at least one Loyal+ member actually present to have
# earned the standing to risk the tribe's goods on a deal -- the same trust
# principle every other autonomous action added this session already uses
# (see suggest_job()/_start_migrate()'s own gates).
# ─────────────────────────────────────────────────────────────────────────────
const AUTO_TRADE_MIN_MATERIALS := 8
const AUTO_TRADE_TRUSTED_RANKS := ["Loyal", "Devoted"]
var _auto_trade_cd: float = 30.0

func _auto_trade_tick(delta: float) -> void:
	if not trading_post_built():
		return
	_auto_trade_cd -= delta
	if _auto_trade_cd > 0.0:
		return
	_auto_trade_cd = randf_range(30.0, 45.0)
	if materials < AUTO_TRADE_MIN_MATERIALS:
		return
	if not _has_trusted_trader():
		return
	var partners: Array = trade_partners()
	if partners.is_empty():
		return
	var best = null
	var best_surplus := -1
	for p in partners:
		if int(p["surplus"]) > best_surplus:
			best_surplus = int(p["surplus"])
			best = p["tribe"]
	if best != null and best_surplus > 0:
		propose_trade_with(best, mini(materials, 4))

func _has_trusted_trader() -> bool:
	for m in members:
		if is_instance_valid(m) and str(m.get("current_rank")) in AUTO_TRADE_TRUSTED_RANKS:
			return true
	return false

func _incoming_request_tick(delta: float) -> void:
	_incoming_accum += delta
	if _incoming_accum < INCOMING_REQUEST_INTERVAL:
		return
	_incoming_accum = 0.0
	if not trading_post_built():
		return   # nowhere for a rival caravan to actually arrive yet
	_prune_envoys()
	if _active_envoys.size() >= ENVOY_MAX_IN_FLIGHT:
		return
	var candidates: Array = []
	for t in _live_world_tribes():
		# not hostile to the player
		if float(t.player_opinion) <= -0.3:
			continue
		# has a surplus of its own material to offer...
		if not t.has_method("material_surplus") or t.material_surplus() <= 0:
			continue
		# ...and actually wants food
		if not t.has_method("hunger_pressure") or t.hunger_pressure() <= 0.15:
			continue
		# no request from this tribe already pending or in-flight
		if _incoming_pending_from(str(t.tribe_name)):
			continue
		candidates.append(t)
	if candidates.is_empty():
		return
	var pick = candidates[randi() % candidates.size()]
	_spawn_incoming_request_envoy(pick)

# True if this tribe already has a caravan walking to the player OR a request
# still showing/queued in the panel — so it can't stack parallel offers.
func _incoming_pending_from(tribe_name: String) -> bool:
	for e in _active_envoys:
		if is_instance_valid(e) and e.get("to_is_player") == true and str(e.from_name) == tribe_name:
			return true
	if TribeTradeUI != null and TribeTradeUI.has_method("has_request_from"):
		if TribeTradeUI.has_request_from(tribe_name):
			return true
	return false

# Launch a caravan from a rival camp toward the player's camp carrying an OFFER.
func _spawn_incoming_request_envoy(tribe: Node) -> void:
	var offer_amt: int = maxi(1, mini(tribe.material_surplus(), 3))
	var want_food: int = offer_amt * 4    # a modest ask (matches "3 for 12") so the player can usually afford
	var envoy := Node3D.new()
	envoy.set_script(load("res://trade_envoy.gd"))
	# set the mode fields BEFORE add_child, so the envoy's _ready()/_update_target
	# already know it's walking to the player (not toward a null to_tribe).
	envoy.to_is_player = true
	envoy.offer_material = str(tribe.material_name())
	add_child(envoy)
	var start: Vector3 = (tribe as Node3D).global_position
	start.y = ground_y(start.x, start.z) + 0.05
	envoy.global_position = start
	envoy.setup(self, tribe, null, false, offer_amt, want_food, str(tribe.tribe_name), "You")
	_active_envoys.append(envoy)
	_envoy_pairs[_pair_key(str(tribe.tribe_name), "You")] = true
	notify_cat(CAT_TRIBE, "📜 A %s envoy approaches your camp with an offer…" % tribe.tribe_name)  # trade request TO player

# The offer caravan reached the player's camp — hand the offer to the panel.
func _on_incoming_request_arrived(envoy: Node) -> void:
	var tribe = envoy.from_tribe
	if not is_instance_valid(tribe) or tribe.defeated:
		return
	if TribeTradeUI != null and TribeTradeUI.has_method("request_from"):
		TribeTradeUI.request_from(tribe, str(envoy.offer_material), int(envoy.mat_amt), int(envoy.food_amt))

# PLAYER ACCEPTS an incoming offer. Player pays food, receives the material,
# the tribe warms to the player, and a return acceptance courier sets out.
# Returns false (and flashes) if the player can't spare the food -> treat as decline.
func accept_trade_request(tribe: Node, material: String, amount: int, want_food: int) -> bool:
	if not is_instance_valid(tribe) or tribe.defeated:
		return false
	if food < want_food:
		notify_cat(CAT_TRIBE, "✗ You can't spare that — the %s offer needs %d food you don't have." % [
			tribe.tribe_name, want_food])  # your tribe's trade decision
		return false
	# goods change hands: player gives food, receives the worked material
	food -= want_food
	tribe.food += want_food
	tribe.material_stock = maxi(0, int(tribe.material_stock) - amount)
	materials_owned[material] = int(materials_owned.get(material, 0)) + amount
	# warm the relationship: move the player-facing opinion up, and register a bond
	# toward the player (mirrors how _on_envoy_arrived warms trading tribes).
	tribe.player_opinion = clampf(float(tribe.player_opinion) + 0.15, -1.0, 1.0)
	if tribe.has_method("add_bond"):
		tribe.add_bond("You", TRADE_BOND)
	# send the note back accepting — an explicit courier from the player's camp
	_spawn_acceptance_envoy(tribe)
	notify_cat(CAT_TRIBE, "🤝 You accept the %s offer: +%d %s for %d food. A courier carries your note back." % [
		tribe.tribe_name, amount, material, want_food])  # your tribe's trade
	TribeMemory.record_event("Trade: your tribe and %s" % tribe.tribe_name,
		"The %s brought you %d %s and you gave %d food. They warmed to you." % [
			tribe.tribe_name, amount, material, want_food], "trade")
	return true

# PLAYER DECLINES an incoming offer. No exchange; a tiny relationship cool.
func decline_trade_request(tribe: Node) -> void:
	if not is_instance_valid(tribe) or tribe.defeated:
		return
	tribe.player_opinion = clampf(float(tribe.player_opinion) - 0.03, -1.0, 1.0)
	notify_cat(CAT_TRIBE, "You wave the %s envoy off. They turn for home." % tribe.tribe_name)  # your tribe's trade decision

# The return "acceptance courier": walks from the player's camp back to the
# offering tribe carrying only a note (note_only -> no exchange on arrival).
func _spawn_acceptance_envoy(tribe: Node) -> void:
	_prune_envoys()
	if _active_envoys.size() >= ENVOY_MAX_IN_FLIGHT:
		return   # roads are full — the deal still stands, we just skip the visible courier
	var envoy := Node3D.new()
	envoy.set_script(load("res://trade_envoy.gd"))
	envoy.note_only = true
	add_child(envoy)
	var sp := get_tree().get_first_node_in_group("stockpile") as Node3D
	var start: Vector3 = sp.global_position if sp != null else Vector3.ZERO
	start.y = ground_y(start.x, start.z) + 0.05
	envoy.global_position = start
	envoy.setup(self, null, tribe, true, 0, 0, "You", str(tribe.tribe_name))
	_active_envoys.append(envoy)
	_envoy_pairs[_pair_key("You", str(tribe.tribe_name))] = true

# ── envoy bookkeeping ──
func _pair_key(a: String, b: String) -> String:
	return a + "|" + b

func _pair_busy(a: String, b: String) -> bool:
	return _envoy_pairs.has(_pair_key(a, b)) or _envoy_pairs.has(_pair_key(b, a))

# Called by an envoy when it gets home (or times out): drop it from the books so
# the route frees up and the in-flight count is accurate.
func _on_envoy_home(envoy: Node) -> void:
	_active_envoys.erase(envoy)
	_envoy_pairs.erase(_pair_key(str(envoy.from_name), str(envoy.to_name)))

# Sweep out any envoys freed without calling home (defeated tribe, scene reload).
func _prune_envoys() -> void:
	var live: Array = []
	for e in _active_envoys:
		if is_instance_valid(e):
			live.append(e)
	_active_envoys = live

func _resolve_war_round(alive: Array) -> void:
	# WAR IS NOW A CONSEQUENCE OF NEED, NOT A DICE ROLL ON A TIMER.
	# Before: aggressor = weighted(strength x WARLIKE x aggression) every
	# war_interval, with NO resource precondition -- so well-fed clans rushed each
	# other for nothing but the clock. Now a tribe must actually WANT for
	# something. A fed tribe with full stores has nothing to march for and simply
	# doesn't; strength/archetype/aggression only AMPLIFY a real hunger.
	var weights: Array = []
	var total   := 0.0
	var hungry: Array = []
	for t in alive:
		var pressure: float = t.war_pressure() if t.has_method("war_pressure") else 0.5
		if pressure < WAR_PRESSURE_MIN:
			weights.append(0.0)
			continue          # fed and content -> no reason to march on anyone
		hungry.append(t)
		var amb: float = maxf(1.0, float(t.strength)) * float(WARLIKE.get(t.archetype, 1.0)) * pressure
		weights.append(amb)
		total += amb
	if total <= 0.0:
		return                # NOBODY is hungry enough to fight -> peace holds

	# Before anyone marches: can this be SOLVED by trade instead? A tribe that can
	# buy food doesn't need to take it. This is what makes peace an equilibrium
	# rather than just a pause between raids.
	if _try_trade(hungry, alive):
		return

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
	notify_cat(CAT_TRIBES, "⚔ The %s muster %d and march on the %s!" % [
		aggressor.tribe_name, mustered, defender.tribe_name])  # AI-AI war

# MUTUAL DEFENSE (2026-08-04): deeper AI-to-AI diplomacy on top of the
# existing alliance system (trade-built bonds already stop allies raiding
# each other and shape how they react to a defeat -- see
# _ripple_opinions_on_defeat()). This closes the remaining real gap: an
# ally previously never took an attack on its FRIEND personally in the
# moment it happened, only after the fact if the friend actually fell.
# Now an ally has a real, non-guaranteed chance to gain its own grudge
# against the aggressor the instant its friend is attacked -- a mutual
# defense pact is a real relationship with real solidarity, not just an
# agreement not to fight each other.
const MUTUAL_DEFENSE_CHANCE := 0.5
const MUTUAL_DEFENSE_GRUDGE := 0.2

func _rally_allies_against(aggressor, defender) -> void:
	if not defender.has_method("allies"):
		return
	for ally_name in defender.allies():
		if str(ally_name) == aggressor.tribe_name:
			continue   # an "ally" that's also the aggressor isn't a real ally right now
		for t in world_tribes:
			if not is_instance_valid(t) or t.defeated or t == aggressor or t == defender:
				continue
			if t.tribe_name != ally_name:
				continue
			if randf() < MUTUAL_DEFENSE_CHANCE and t.has_method("add_grudge"):
				t.add_grudge(aggressor.tribe_name, MUTUAL_DEFENSE_GRUDGE)
				notify_cat(CAT_TRIBES, "🛡 The %s stand by their ally the %s against the %s." % [
					t.tribe_name, defender.tribe_name, aggressor.tribe_name])
			break

func _abstract_clash(aggressor, defender) -> void:
	if not is_instance_valid(aggressor) or not is_instance_valid(defender) or defender.defeated:
		return
	_rally_allies_against(aggressor, defender)
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
		notify_cat(CAT_TRIBES, "⚔ The %s overran the %s. (%d tribes left)" % [  # AI-AI war
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
			notify_cat(CAT_TRIBES, "⚔ The %s stormed a rival camp! (%d tribes left)" % [
				a.tribe_name, _live_tribe_count()])  # AI-AI war
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
		# ALLIES DON'T RAID ALLIES. A tribe will go hungry a while before turning
		# on a friend -- that's what makes an alliance mean something and what
		# keeps the map from dissolving back into all-against-all.
		if src.has_method("is_allied_with") and src.is_allied_with(t.tribe_name):
			continue
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
		b.set("species", BUSH_POOL[randi() % BUSH_POOL.size()])
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
		notify_cat(CAT_YOU, "Selection cleared.")  # player UI
		return
	selected_member = live[idx]
	var nm: String = selected_member.member_name if "member_name" in selected_member else "member"
	notify_cat(CAT_TRIBE, "Commanding %s— [1]gather [2]hunt [3]scout [4]wood [5]build [0]auto" % nm)

# triple-tap [V] — command everyone backing you at once instead of one member
func select_whole_tribe() -> void:
	selected_member = null
	selected_group.clear()
	for m in members:
		if is_instance_valid(m) and m.get("is_backing_you"):
			selected_group.append(m)
	if selected_group.is_empty():
		notify_cat(CAT_YOU, "No loyal members to command yet.")
	else:
		notify_cat(CAT_TRIBE, "Commanding your WHOLE TRIBE (%d) — [1]gather [2]hunt [3]scout [4]wood [5]build [6]recruit [7]guard [0]auto" % selected_group.size())

func command_selected(job: String, amount: int = -1) -> void:
	if not selected_group.is_empty():
		var live: Array = []
		for m in selected_group:
			if is_instance_valid(m): live.append(m)
		selected_group = live
		if selected_group.is_empty():
			notify_cat(CAT_TRIBE, "Your commanded group has scattered.")
			return
		for i in range(selected_group.size()):
			_apply_command(selected_group[i], job, amount, i, selected_group.size())
		notify_cat(CAT_TRIBE, "Whole tribe (%d) ordered: %s" % [selected_group.size(), job])
		return
	if selected_member == null or not is_instance_valid(selected_member):
		notify_cat(CAT_YOU, "No member selected — hold [V] while looking at one (tap 3x for the whole tribe), or [M] to cycle.")
		return
	_apply_command(selected_member, job, amount)
	var nm: String = selected_member.member_name if "member_name" in selected_member else "member"
	if job == "auto":
		notify_cat(CAT_TRIBE, "%s returns to self-directed work." % nm)
	else:
		var target: int = amount if amount >= 0 else STANDING_QUOTA.get(job, 0)
		var goal := " until %d" % target if target > 0 else ""
		notify_cat(CAT_TRIBE, "%s will %s%s." % [nm, job, goal])

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
	notify_cat(CAT_TRIBE, "Commanding %s— [1]gather [2]hunt [3]scout [4]wood [5]build [6]recruit [7]guard [0]auto" % nm)

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
			notify_cat(CAT_TRIBE, "Work plan: AUTO — everyone self-directs.")  # order to your tribe
		1:
			_distribute(crew, ["gather"])
			notify_cat(CAT_TRIBE, "Work plan: ALL FORAGING.")
		2:
			_distribute(crew, ["gather", "wood"])
			notify_cat(CAT_TRIBE, "Work plan: food + wood, split evenly.")
		3:
			_distribute(crew, ["gather", "wood", "hunt"])
			notify_cat(CAT_TRIBE, "Work plan: food + wood + hunt.")
		4:
			_distribute(crew, ["gather", "wood", "hunt", "scout"])
			notify_cat(CAT_TRIBE, "Work plan: balanced + scouting.")
		5:
			raid_focus()
			_distribute(crew, ["gather", "wood"])
			notify_cat(CAT_TRIBE, "Work plan: WAR FOOTING — raiders march, rest supply them.")

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
	notify_cat(CAT_TRIBE, "Formation: %s" % formation_kind.to_upper())  # order to your tribe

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
	notify_cat(CAT_TRIBE, "Defense perimeter set to %d units." % int(perimeter_radius))

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

# BUG FIX (2026-07-22): fence_ring_plan() started scaling gate_count up with
# fortress tier (more gates for a bigger fortress), but _near_gate() used a
# FIXED angular half-width regardless of how many gates there were. With
# GATE_HALF_WIDTH=0.5 rad, each gate already eats 1.0 rad of the ring; at
# gate_count=6 that's 6.0 of the ring's 6.283 total radians -- nearly the
# ENTIRE wall was "near a gate", so the wall itself nearly disappeared and
# a bigger-tier fortress ended up with FEWER real wall segments than a
# smaller one. half_width now scales so total gate coverage stays roughly
# constant regardless of gate_count (more, but each one narrower), which is
# what actually lets the wall grow monotonically with tier.
func _near_gate(ang: float, gate_angles: Array, half_width: float = GATE_HALF_WIDTH) -> bool:
	for ga in gate_angles:
		if absf(wrapf(ang - ga, -PI, PI)) <= half_width:
			return true
	return false

# EXPANSION (2026-07-22): `tier` picks which ring gets planned -- defaulting
# to the tribe's CURRENT fortress_tier, i.e. "the next ring to build" (tier 0
# the first time, tier 1 after on_fortress_built() has fired once, etc).
# Every dimension scales up with it: a bigger radius, more gates, more
# teepees -- a real bigger-and-better fortress each time, not the same plan
# rebuilt on top of itself.
func fence_ring_plan(tier: int = -1) -> Array:
	var t: int = tier if tier >= 0 else fortress_tier
	# a NEW tier's plan being requested means the previous ring is about to
	# be superseded -- clear it now, once, rather than letting it pile up
	# underneath every ring that follows (see _fortress_pieces' own comment).
	if t != _fortress_pieces_tier:
		_clear_fortress_ring()
		_fortress_pieces_tier = t
	var radius: float = FORTRESS_BASE_RADIUS + float(t) * FORTRESS_RADIUS_GROWTH
	var fence_radius: float = radius - 3.0

	var fence_segs: Array = []
	var teepee_segs: Array = []

	# pick gate ANGLES once, shared by the fence ring AND the block wall
	# ring (_fortress_block_segments) so their openings line up into one
	# real corridor. Previously each ring picked gaps by segment INDEX with
	# a different segment count per ring, so a gap in the fence usually had
	# no matching gap in the block wall beyond it — no actual way in.
	var gate_count := mini(3 + t, 6)
	var gate_angles: Array = []
	for g in range(gate_count):
		gate_angles.append(TAU * float(g) / float(gate_count))
	# keep TOTAL gate coverage roughly constant regardless of gate_count (see
	# _near_gate()'s own comment) -- more gates on a bigger fortress, each one
	# narrower, instead of the wall itself disappearing as gates multiply.
	var gate_half_width: float = GATE_HALF_WIDTH * 3.0 / float(gate_count)

	# more segments for a bigger ring, so the fence posts stay evenly spaced
	# instead of stretching thinner and thinner as radius grows.
	var count: int = maxi(18, int(round(18.0 * radius / FORTRESS_BASE_RADIUS)))
	for i in range(count):
		var ang := TAU * float(i) / float(count)
		if _near_gate(ang, gate_angles, gate_half_width): continue
		fence_segs.append({"kind": "fence", "pos": Vector3(cos(ang) * fence_radius, 0.0, sin(ang) * fence_radius), "yaw": ang + PI * 0.5})
	# DOORS (2026-07-21): a gate used to just be a bare gap where the fence
	# ring skipped a segment -- an unguarded hole, not an actual gate. A real
	# door piece now fills each one, oriented the same way a fence segment at
	# that angle would be (yaw = ang + PI/2, tangent to the ring).
	for ga in gate_angles:
		var gx := cos(float(ga)) * fence_radius
		var gz := sin(float(ga)) * fence_radius
		fence_segs.append({"kind": "door", "pos": Vector3(gx, 1.0, gz), "yaw": float(ga) + PI * 0.5})
	# a ring of teepees just inside the fence line — homes for the camp,
	# growing with the tribe's own expansion (more tiers, more households)
	var teepee_count := 8 + t * 4
	for i in range(teepee_count):
		var ang2 := TAU * float(i) / float(teepee_count) + (TAU / float(teepee_count) * 0.5)
		teepee_segs.append({"kind": "teepee", "pos": Vector3(cos(ang2) * (fence_radius - 3.0), 0.0, sin(ang2) * (fence_radius - 3.0)), "yaw": 0.0})
	var block_segs: Array = _fortress_block_segments(radius, gate_angles, gate_half_width)

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
func _fortress_block_segments(radius: float, gate_angles: Array,
		gate_half_width: float = GATE_HALF_WIDTH) -> Array:
	var segs: Array = []
	var size: float = BlockScript.SIZE
	var n: int = maxi(2, int(round(radius / size)))
	for gx in range(-n, n + 1):
		for gz in range(-n, n + 1):
			if abs(gx) != n and abs(gz) != n:
				continue   # interior cell — only the perimeter is a wall
			var x := float(gx) * size
			var z := float(gz) * size
			if _near_gate(atan2(z, x), gate_angles, gate_half_width): continue
			segs.append({"kind": "block", "pos": Vector3(x, 1.0, z)})
			segs.append({"kind": "block", "pos": Vector3(x, 3.0, z)})
			# THIRD COURSE (2026-07-19): a two-course wall sits chest-high on
			# an NPC -- close enough to read as a fence, not a fortress. One
			# more course per perimeter cell (same placement loop, same
			# per-segment cost) makes the wall itself read as a real
			# defensive structure from outside camp, not just up close.
			segs.append({"kind": "block", "pos": Vector3(x, 5.0, z)})
	# CORNER WATCHTOWERS (2026-07-19): four freestanding stacks at the
	# diagonals, one course taller than the wall itself, so they read as
	# towers rather than a slightly-taller stretch of wall.
	#
	# BUG FIX (2026-07-21): tower_r used to be `radius + size`, sized as if
	# the wall were a CIRCLE -- but the wall is a SQUARE ring (the gx/gz loop
	# above), whose own corner cells reach out to n*size*sqrt(2), well past a
	# plain `radius + size`. Towers sit on the same 45°/135°/225°/315°
	# diagonals as those corner cells, so the old radius put a tower's stair
	# (one more block-width further out again) almost exactly on top of the
	# wall's own corner column -- real overlapping geometry, not just a close
	# call. tower_r is now measured from the wall's ACTUAL corner radius, so
	# neither the tower nor its stair can ever coincide with it.
	var wall_corner_r: float = float(n) * size * sqrt(2.0)
	var tower_r := wall_corner_r + size
	for i in range(4):
		var ang := PI * 0.25 + TAU * float(i) / 4.0
		var tx := cos(ang) * tower_r
		var tz := sin(ang) * tower_r
		for course in range(4):
			segs.append({"kind": "block", "pos": Vector3(tx, 1.0 + course * 2.0, tz)})
		# STAIR + ROOF (2026-07-20): each tower gets a real climbable approach
		# and a genuine roofline capping it, instead of standing there as a
		# bare stack of cubes.
		#
		# BUG FIX (2026-07-21): the first version placed stairs at 0.85 of the
		# tower's OWN radius -- i.e. INSIDE it, less than one block-width from
		# the tower's own column -- so the stair and the tower physically
		# overlapped. Visually that read as broken/overlapping geometry, which
		# is what got reported as "building isn't working" even though every
		# piece was placing successfully. Fixed by placing the stair a full
		# block-width OUTSIDE the tower (stair_r = tower_r + FULL_SIZE) so the
		# two never occupy the same space, oriented (yaw) to face back toward
		# the tower it climbs, and sized SMALL -- a finer, narrower step
		# instead of a full-width block wedge.
		var stair_r: float = tower_r + BuildPieceScript.FULL_SIZE
		var sx := cos(ang) * stair_r
		var sz := sin(ang) * stair_r
		for course in range(4):
			segs.append({"kind": "stair", "pos": Vector3(sx, 1.0 + course * 2.0, sz),
				"yaw": ang + PI, "scale": BuildPieceScript.SCALE_SMALL})
		segs.append({"kind": "roof", "pos": Vector3(tx, 1.0 + 4 * 2.0, tz), "yaw": ang})
	# FINE-DETAIL CORNERS (2026-07-20): the smaller building unit gets real
	# use here -- a half-size piece tucked into each gate's inner corner,
	# the kind of fine-tuning the coarse 2.0-unit wall grid can't place.
	for ga in gate_angles:
		var gx := cos(float(ga)) * (radius - size * 0.5)
		var gz := sin(float(ga)) * (radius - size * 0.5)
		segs.append({"kind": "small", "pos": Vector3(gx, 1.0, gz), "yaw": float(ga)})
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
	# narrower so it can't collide with the status (left) / resources (right)
	# corner labels, plus line spacing + a dark backing panel so multi-line
	# banners (season notes, trade news, the welcome-back recap) read as a clean
	# block instead of cramped text jammed against the top edge.
	flash_label.custom_minimum_size = Vector2(560, 0)
	flash_label.add_theme_constant_override("line_spacing", 7)
	var fbg := StyleBoxFlat.new()
	fbg.bg_color = Color(0.05, 0.06, 0.08, 0.82)
	fbg.set_corner_radius_all(6)
	fbg.content_margin_left = 16
	fbg.content_margin_right = 16
	fbg.content_margin_top = 10
	fbg.content_margin_bottom = 10
	flash_label.add_theme_stylebox_override("normal", fbg)
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

	# Three categorized notification boxes, stacked down the RIGHT edge.
	# Order top-to-bottom: Tribes, Your Tribe, You. Positioned each frame in
	# _update_ui_positions() below the resources/factions corner labels.
	_cat_boxes.clear()
	_cat_lines.clear()
	for cat in [CAT_TRIBES, CAT_TRIBE, CAT_YOU]:
		var box := Label.new()
		box.name = "CatBox_" + cat
		ui.add_child(box)
		box.set_anchors_preset(Control.PRESET_TOP_LEFT)
		box.autowrap_mode = TextServer.AUTOWRAP_WORD
		box.custom_minimum_size = Vector2(340, 0)
		box.add_theme_constant_override("line_spacing", 4)
		var cbg := StyleBoxFlat.new()
		cbg.bg_color = Color(0.05, 0.06, 0.08, 0.80)
		cbg.set_corner_radius_all(6)
		cbg.content_margin_left = 12
		cbg.content_margin_right = 12
		cbg.content_margin_top = 8
		cbg.content_margin_bottom = 8
		box.add_theme_stylebox_override("normal", cbg)
		_style_label(box, 14)
		box.visible = false
		_cat_boxes[cat] = box
		_cat_lines[cat] = []

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
		+ "[G] bribe  [X] scout  [T] chat  [Y] fence  [L] teepee(%dwood)  [N] camp(%dwood)  "
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

	# TOP-CENTER, dropped below the corner labels so it never overlaps them
	if flash_label:
		var fw := flash_label.custom_minimum_size.x
		flash_label.position = Vector2((W - fw) * 0.5, 84)

	# TOP-RIGHT: resources, factions just below
	if resource_label:
		resource_label.position = Vector2(W - resource_label.custom_minimum_size.x - 20, 20)
	if factions_label:
		factions_label.position = Vector2(W - factions_label.custom_minimum_size.x - 20, 56)

	# RIGHT EDGE, stacked below the resources/factions corner labels:
	# Tribes (top), Your Tribe (middle), You (bottom). Each box grows with its
	# content, so we stack using each box's actual measured height.
	var box_w: float = 340.0
	var box_x: float = W - box_w - 20.0
	var box_y: float = 92.0   # clear of resources (y=20) + factions (y=56)
	for cat in [CAT_TRIBES, CAT_TRIBE, CAT_YOU]:
		var box: Label = _cat_boxes.get(cat)
		if box == null:
			continue
		box.position = Vector2(box_x, box_y)
		if box.visible:
			box_y += box.size.y + 8.0

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

# Categorized entry point. `category` is one of CAT_TRIBES / CAT_TRIBE / CAT_YOU.
# Unknown categories fall back to "you" so a bad caller can never drop a message.
func notify_cat(category: String, text: String) -> void:
	var cat: String = category
	if not _cat_lines.has(cat):
		cat = CAT_YOU
	var arr: Array = _cat_lines[cat]
	arr.append({ "text": text, "t": CAT_LINE_TTL })
	while arr.size() > CAT_MAX_LINES:
		arr.pop_front()

# Test / introspection helper: current visible lines of one box, oldest first.
func cat_box_lines(category: String) -> Array:
	if not _cat_lines.has(category):
		return []
	var out: Array = []
	for e in _cat_lines[category]:
		out.append(String(e["text"]))
	return out

func _update_cat_boxes(delta: float) -> void:
	for cat in [CAT_TRIBES, CAT_TRIBE, CAT_YOU]:
		var box: Label = _cat_boxes.get(cat)
		if box == null:
			continue
		var arr: Array = _cat_lines[cat]
		# expire old lines (walk backwards so remove_at is safe)
		var i: int = arr.size() - 1
		while i >= 0:
			arr[i]["t"] = float(arr[i]["t"]) - delta
			if float(arr[i]["t"]) <= 0.0:
				arr.remove_at(i)
			i -= 1
		if arr.is_empty() or _ui_hidden:
			box.visible = false
			continue
		box.visible = true
		var title: String = str(CAT_TITLES.get(cat, cat))
		var lines: String = "— %s —" % title
		for e in arr:
			lines += "\n" + String(e["text"])
		box.text = lines

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
				notify_cat(CAT_TRIBES, "You stumble onto the %s camp — %s, strength %d.%s" % [  # discovering a rival = world
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
	var x := cos(ang) * 40.0
	var z := sin(ang) * 40.0
	# keep drifting wanderers on land in island mode (no-op when islands are off)
	var spot: Vector3 = _land_spot(x, z)
	if spot != Vector3.INF:
		return Vector3(spot.x, spot.y + 1.5, spot.z)
	return Vector3(x, ground_y(x, z) + 1.5, z)

## Is any member already building the fortress? Scanned live (no counter to drift
## out of sync when a build ends by completion, timeout, or abandonment). Gates
## suggest_job so solo builders don't pile onto the same segments.
func _someone_building() -> bool:
	for m in members:
		if is_instance_valid(m) and str(m.get("_task_kind")) == "build":
			return true
	return false

# ─────────────────────────────────────────────────────────────────────────────
# PERSISTENCE — the manager owns its own state shape; TribePersist owns the file,
# the timing, and the offline catch-up. Keeping the serialisation HERE means the
# save format can't fall out of sync with what the fields actually are.
# ─────────────────────────────────────────────────────────────────────────────
func capture_state() -> Dictionary:
	var tribes: Array = []
	for t in world_tribes:
		if not is_instance_valid(t):
			continue
		tribes.append({
			"name": t.tribe_name, "archetype": t.archetype,
			"x": t.global_position.x, "z": t.global_position.z,
			"food": t.food, "material": t.material_stock, "wood": t.wood,
			"strength": t.strength, "members": t.member_count,
			"defeated": t.defeated,
			"traits": t.leader_traits.duplicate(),
			"opinions": t.opinions.duplicate(),
			"bonds": t.bonds.duplicate(),
			# BUG FIX (2026-08-02): player_opinion was never saved at all --
			# every relationship built through greeting/trade/coexistence
			# reset to 0 (neutral) on reload, undoing real diplomatic
			# progress silently. Reported live as "it all disappeared and
			# restarted".
			"player_opinion": t.player_opinion,
		})
	var outpost_list: Array = []
	for o in outposts:
		if is_instance_valid(o):
			outpost_list.append({
				"name": str(o.get("settlement_name")), "district": str(o.get("district")),
				"x": (o as Node3D).global_position.x, "z": (o as Node3D).global_position.z,
			})
	var mem_list: Array = []
	for m in members:
		if is_instance_valid(m) and "member_name" in m:
			mem_list.append({
				"name": str(m.get("member_name")),
				"personality": str(m.get("personality")),
				"relationship": float(m.get("relationship")),
			})
	var pl := get_tree().get_first_node_in_group("player") as Node3D
	return {
		"food": food, "materials": materials, "wood": wood, "unrest": unrest,
		"materials_owned": materials_owned.duplicate(),
		"player_x": pl.global_position.x if pl else 0.0,
		"player_z": pl.global_position.z if pl else 0.0,
		"tribes": tribes, "members": mem_list,
		"season": _season,
		# BUG FIX (2026-08-02): none of this was saved either -- a built
		# fortress' TIER (and the material it was upgraded to) and any
		# founded settlements vanished on every reload even though the
		# economy numbers above carried over fine. Reported live as a built
		# castle "disappearing and restarting". The physical blocks
		# themselves still aren't restored (an honest, separate limitation --
		# see apply_state()'s own comment), but restoring fortress_tier means
		# the next autonomous build re-raises the SAME tier's ring instead of
		# starting over from tier 0, and restoring outposts fully rebuilds
		# each settlement's real structures.
		"fortress_tier": fortress_tier,
		"material_tier": material_tier,
		"current_weather": current_weather,
		"outposts": outpost_list,
	}

## Overwrite the freshly-spawned world with saved state. Tribes are matched by
## name (spawn order isn't guaranteed stable); a saved tribe that's since
## defeated is marked so rather than resurrected.
func apply_state(d: Dictionary) -> void:
	food = int(d.get("food", food))
	materials = int(d.get("materials", materials))
	wood = int(d.get("wood", wood))
	unrest = float(d.get("unrest", unrest))
	if d.has("materials_owned"):
		materials_owned = (d["materials_owned"] as Dictionary).duplicate()
	_season = str(d.get("season", "fair"))
	# BUG FIX (2026-08-02): restore what a built fortress/city actually
	# depends on -- see capture_state()'s own comment on why this was
	# missing (reported as a castle "disappearing and restarting"). Reading
	# these back means the NEXT autonomous build re-raises the SAME tier's
	# ring (fence_ring_plan() reads fortress_tier directly) instead of
	# starting over from tier 0.
	fortress_tier = int(d.get("fortress_tier", fortress_tier))
	fortress_built = fortress_tier > 0
	material_tier = int(d.get("material_tier", material_tier))
	current_weather = int(d.get("current_weather", current_weather))

	var by_name: Dictionary = {}
	for t in world_tribes:
		if is_instance_valid(t):
			by_name[t.tribe_name] = t
	for ts in d.get("tribes", []):
		var t = by_name.get(str(ts["name"]))
		if t == null:
			continue
		# re-sample ground Y at the saved x,z: a save made on the old flat world
		# (or before terrain regenerated) would otherwise drop the camp at y=1,
		# floating over valleys or buried in hills. Always sit it on the surface.
		var tx: float = float(ts["x"])
		var tz: float = float(ts["z"])
		t.global_position = Vector3(tx, ground_y(tx, tz), tz)
		t.food = int(ts["food"])
		t.material_stock = int(ts["material"])
		t.wood = int(ts.get("wood", 0))
		t.strength = int(ts["strength"])
		t.member_count = int(ts["members"])
		t.leader_traits = (ts["traits"] as Dictionary).duplicate()
		t.opinions = (ts["opinions"] as Dictionary).duplicate()
		t.bonds = (ts.get("bonds", {}) as Dictionary).duplicate()
		# BUG FIX (2026-08-02): player_opinion (built via greeting/trade/
		# coexistence -- see Tribemanager._greet_tribe(), the whole point of
		# this session's diplomacy work) was never restored, silently
		# resetting every relationship to neutral on reload.
		if "player_opinion" in ts:
			t.player_opinion = float(ts["player_opinion"])
		if bool(ts.get("defeated", false)) and t.has_method("defeat"):
			t.defeat()

	# BUG FIX (2026-08-02): founded settlements (name, district, position)
	# vanished on reload along with everything else -- rebuild each one's
	# real stockpile + structures. HONEST LIMITATION: this restores the
	# settlement itself, not every individual block a member may have added
	# to it since founding (those, like the home fortress' own blocks, are
	# not yet tracked for persistence at all).
	outposts.clear()
	for os in d.get("outposts", []):
		var ox: float = float(os.get("x", 0.0))
		var oz: float = float(os.get("z", 0.0))
		var opos := Vector3(ox, ground_y(ox, oz), oz)
		var sp := Node3D.new()
		sp.name = "OutpostStockpile"
		sp.set_script(load("res://stockpile.gd"))
		add_child(sp)
		sp.global_position = opos
		sp.set("manager", self)
		sp.set("settlement_name", str(os.get("name", "")))
		sp.set("district", str(os.get("district", "")))
		sp.remove_from_group("stockpile")
		sp.add_to_group("outpost_stockpile")
		outposts.append(sp)
		_build_district_structures(str(os.get("district", "")), opos)

	# restore named members' bonds (they respawn generically on _start_game; here
	# we re-apply who they were and how they felt about you)
	var saved_members: Array = d.get("members", [])
	for i in range(mini(members.size(), saved_members.size())):
		var m = members[i]
		var sm: Dictionary = saved_members[i]
		if is_instance_valid(m):
			if "member_name" in m: m.member_name = str(sm["name"])
			if "personality" in m: m.personality = str(sm["personality"])
			if "relationship" in m:
				m.relationship = float(sm["relationship"])
				if m.has_method("_update_rank"): m._update_rank()
