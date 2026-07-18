extends CharacterBody3D
# (class_name removed to avoid "hides a global script class" — the scene
#  references this script by path, so the global name isn't needed.)

# ─────────────────────────────────────────────────────────────────────────────
# TribeMember — A LIVING NPC with a Spikeling brain AND a body that moves.
#
# What this one node now does:
#   • BRAIN: feed it (E) → its Trust neuron charges → Follow fires → it backs you.
#   • BODY: it wanders, turns to look at you, walks toward you as it warms up,
#     and physically marches OFF on the map to do gather/hunt/scout orders, then
#     walks home. All that hidden trust state is now visible in how it moves.
#   • PERSONALITY: each member gets a literally-different brain (the Spikeling
#     config below is built from its personality) — Trusting ones warm fast,
#     Wary ones resist, Brave ones will scout/raid when others won't.
#   • SURVIVAL: feeding costs the tribe food (via the TribeManager). If the tribe
#     starves, members lose trust and can defect.
#
# The TribeManager sets `manager`, `personality`, `member_name` before adding us.
# ─────────────────────────────────────────────────────────────────────────────

const SpatialGrid = preload("res://spatial_grid.gd")

@export var member_name: String = "Tribesman"
@export var personality: String = "Steady"
@export var follow_threshold_hits: int = 2   # how many Follow-fires to back you

# ── brain / trust state ──
var brain: Spikeling
var anim: BodyAnim                       # procedural "alive" body motion
var manager                              # TribeManager — set by the manager
var player_in_range: bool = false
var trust_display: float = 0.0           # 0..1 for the bar (smoothed)
var follow_fires: int = 0
var is_backing_you: bool = false
var relationship: float = 0.0            # smooth 0..3 bond meter (drives ranks)
var feed_count: int = 0
var betrayed_count: int = 0              # times the PLAYER has struck this member (see betray())

var _tick_accum: float = 0.0
const TICK_HZ := 10.0
var _e_was_down: bool = false
var _keys_down: Dictionary = {}
var _player_node: Node3D = null

@onready var trust_label: Label3D = get_node_or_null("TrustLabel")
@onready var thought_label: Label3D = get_node_or_null("ThoughtLabel")
@export var interact_range: float = 3.5

# ─────────────────────────────────────────────────────────────────────────────
# TUNABLES — all trust and rank numbers live here.
# Change these to re-tune the progression; no other code needs touching.
# ─────────────────────────────────────────────────────────────────────────────

# ── relationship meter (0 → RELATIONSHIP_MAX) ──
const RELATIONSHIP_MAX     := 3.0   # hard ceiling on the bond value
const FOLLOW_FIRE_REL_GAIN := 0.18  # bond gained each time the Follow neuron fires
const BOND_DECAY_RATE      := 0.004 # bond lost per second passively (trust must be maintained)
const FACTION_VOUCH_RATE   := 0.06  # bond nudged upward per second by faction-mate support
const WORK_REL_GAIN        := 0.2   # bond gained for completing a voluntary (unpaid) task
const STARVE_DECAY_RATE    := 0.06  # bond eroded per second while the tribe is starving
const DEFECT_THRESHOLD     := 0.7   # starving backers leave when bond drops below this
const TRUST_BAR_SCALE      := 2.20  # relationship value that fills the trust bar to 100% (equals Devoted threshold)

# ── rank thresholds (relationship value needed to reach each rank) ──
const RANKS := [
	["Stranger",     0.00],
	["Acquaintance", 0.30],
	["Friend",       0.70],
	["Loyal",        1.30],
	["Devoted",      2.20],   # must equal TRUST_BAR_SCALE
]

# ── loyalty score each rank contributes toward accepting a risky order ──
const RANK_LOYALTY := {
	"Stranger": 15, "Acquaintance": 45, "Friend": 75, "Loyal": 100, "Devoted": 125,
}

# ── order acceptance: drive = ORDER_BASE + rank_loyalty + courage; must beat ORDER_RISK ──
const ORDER_BASE := 70                                                        # flat base score
# threshold per task type. ANYTHING NOT LISTED HERE IS REFUSED 100% OF THE TIME
# (give_order does ORDER_RISK.get(kind, 999)) -- a silent, total failure, so a new
# verb must be added here or it does not exist. "build"/"carve" are deliberately
# absent: they route through _start_job -> begin_build()/_begin_carve() instead.
#
# "come" at 80 is the cheapest ask in the game -- walking over is not dangerous.
# drive = 70 + rank_loyalty + courage, so at Stranger (loyalty 15) this lands
# exactly where it should: a Wary stranger (courage -15 -> drive 70) will NOT
# come when you call, a Greedy one (-5 -> 80) just barely will, and everyone
# Steady or better does. Being ignored by someone who doesn't trust you yet is
# the loyalty system doing its job, not the order failing.
# BUG FIXED (2026-07-17): "recruit" and "guard" were real order kinds
# ([6]/[7], see FPSPlayer.gd) but were never added here, despite this exact
# comment block warning that anything missing is refused 100% of the time.
# Every recruit/guard order -- player-issued AND the autonomous self-directed
# kind (the gather-then-retry-recruit call in _complete_task()) --
# silently failed no matter how loyal the member was, because drive (at most
# ~70+125+40=235 for a maximally loyal, brave member) can never beat the
# default 999. Caught live: "commands 5 6 7 0 don't work" -- 6 and 7 were
# genuinely broken; 5 (build) and 0 (auto) bypass ORDER_RISK entirely (route
# through begin_build()/clear_standing() directly) and traced clean.
# recruit=110: a bit more socially involved than plain gather (approaching an
# unknown wanderer) but not physically dangerous, so priced close to gather.
# guard=140: stationed defense duty draws real raider attention (that's the
# point of a guard post), priced a notch above hunt but well under scout's
# solo-in-hostile-territory risk.
const ORDER_RISK := {"come": 80, "gather": 100, "hunt": 130, "scout": 165, "wood": 100,
	"recruit": 110, "guard": 140}

# ── brain LOD: skip Spikeling ticks for members beyond this distance ──
const BRAIN_LOD_RADIUS := 80.0

# ── tribe food spent to recruit a neutral wanderer ──
const RECRUIT_FOOD_COST := 3

# ─────────────────────────────────────────────────────────────────────────────
# PERSONALITIES — each is a different BRAIN + different traits. This is where the
# Spikeling tech earns its keep: a "Trusting" member literally has stronger
# trust synapses and a slower-leaking Trust neuron than a "Wary" one.
#   contrib    = SawContribute -> Trust synapse weight (how much a gift moves them)
#   trust_leak = Trust neuron leak (how fast goodwill fades)
#   follow_w   = Trust -> Follow weight (how readily trust becomes loyalty)
#   courage    = bonus willingness to obey risky orders / raid might
#   might      = base combat strength in raids
# ─────────────────────────────────────────────────────────────────────────────
const PERSONALITIES := {
	"Steady":   {"contrib": 80, "trust_leak": 2, "follow_w": 120, "courage": 0,   "might": 10, "color": Color(0.70, 0.55, 0.40)},
	"Trusting": {"contrib": 95, "trust_leak": 1, "follow_w": 140, "courage": 15,  "might": 8,  "color": Color(0.52, 0.70, 0.45)},
	"Wary":     {"contrib": 60, "trust_leak": 4, "follow_w": 100, "courage": -15, "might": 11, "color": Color(0.45, 0.52, 0.66)},
	"Brave":    {"contrib": 78, "trust_leak": 2, "follow_w": 120, "courage": 40,  "might": 16, "color": Color(0.78, 0.45, 0.40)},
	"Greedy":   {"contrib": 70, "trust_leak": 3, "follow_w": 110, "courage": -5,  "might": 9,  "color": Color(0.78, 0.66, 0.30)},
}

func _brain_text() -> String:
	var p: Dictionary = PERSONALITIES.get(personality, PERSONALITIES["Steady"])
	var t := "# Spikeling Neural Configuration\n"
	t += "neuron SawContribute threshold=50 leak=20\n"
	t += "neuron SawHelpClear  threshold=50 leak=20\n"
	t += "neuron SawDefend     threshold=50 leak=20\n"
	t += "neuron SawBetray     threshold=50 leak=20\n"
	t += "neuron Trust  threshold=100 leak=%d\n" % int(p["trust_leak"])
	t += "neuron Follow threshold=100 leak=5\n"
	t += "synapse SawContribute -> Trust weight=%d\n" % int(p["contrib"])
	t += "synapse SawHelpClear  -> Trust weight=70\n"
	t += "synapse SawDefend     -> Trust weight=95\n"
	t += "synapse SawBetray     -> Trust weight=-160\n"
	t += "synapse Trust -> Follow weight=%d\n" % int(p["follow_w"])
	# ── environmental senses (2026-07-17) ── deliberately NOT wired into
	# Trust/Follow: this brain's trust economy is hand-tuned and already
	# verified (test_pyspike_orchestrator_parity.py's sibling here is this
	# file's own real playtesting) -- bolting sight/hearing onto it blind
	# risks destabilizing a calibrated system for a feature that was asked
	# for as PERCEPTION, not as a trust modifier. These neurons exist so the
	# brain genuinely REGISTERS its environment (fires, has real membrane
	# state, is inspectable) and so brain_snapshot() can report real local
	# awareness to the LLM -- grounding conversation in what's actually
	# nearby right now, not just remembered history. Wiring them into
	# behavior is a real next step, but a separate, deliberate one.
	t += "neuron SawRaider  threshold=50 leak=30\n"
	t += "neuron SawPrey    threshold=50 leak=30\n"
	t += "neuron HeardDanger threshold=50 leak=30\n"
	t += "refractory=2\n"
	return t

var current_rank: String = "Stranger"

# ── thought system ──
var current_thought: String = "..."
var _thought_timer: float = 0.0

# ── speech log: the last few things this member actually SAID, shown above their
# head when you're close enough to be part of the conversation. Ambient thoughts
# bypass _think() (they assign current_thought directly), so this log only ever
# fills with real lines -- which is what makes it readable rather than noise.
const SPEECH_LOG_MAX := 3
const SPEECH_LOG_TTL := 22.0     # a line older than this drops out of the log
const SPEECH_LOG_RADIUS := 9.0   # stand this close and you see the log
var _speech_log: Array = []      # [{text: String, t: float}]
var _idle_pick: int = 0
var _idle_cycle: float = 0.0

# ─────────────────────────────────────────────────────────────────────────────
# MOVEMENT — the body. A tiny state machine steers a CharacterBody3D around.
# ─────────────────────────────────────────────────────────────────────────────
enum St { WANDER, AWAY, RETURN }
var state: int = St.WANDER
@export var move_speed: float = 2.6
@export var wander_radius: float = 9.0
const ARRIVE := 0.5
const STANDOFF := 2.2
const FORMATION_RALLY_RANGE := 20.0   # how far a non-loose formation pulls backers in to hold position
var _attend_idle_time: float = 0.0    # how long we've waited near you with no input
const ATTEND_PATIENCE := 6.0          # after this long, give up waiting and go about business
var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
var home_pos: Vector3 = Vector3.ZERO
var _target: Vector3 = Vector3.ZERO
var _wander_pause: float = 0.0
var _fidget_cd: float = 0.0              # time until next idle fidget
var _leaving: bool = false               # starved out — wandering off

# ── orders / tasks ──
const RANK_COLORS := {
	"Stranger":     Color(0.60, 0.60, 0.60),
	"Acquaintance": Color(0.85, 0.85, 0.40),
	"Friend":       Color(0.35, 0.90, 0.40),
	"Loyal":        Color(0.40, 0.65, 1.00),
	"Devoted":      Color(1.00, 0.80, 0.20),
}
var is_busy: bool = false
var _task_kind: String = ""
var _work_time: float = 0.0
var _target_node: Node3D = null          # the bush/animal we're working
var _task_food: int = 0
var _task_mats: int = 0
var _task_result: String = ""
const CATCH_RANGE := 1.8
const HARVEST_RANGE := 2.0
# personal hunger — members eat from the tribe stockpile, and starve if it's bare
var hunger: float = 0.0
const HUNGER_RATE := 0.9          # gentler than before — easier to maintain
const EAT_AT := 58.0
const EAT_RESTORE := 62.0
var _has_club: bool = false      # holding a club while out on a hunt
var _job_cd: float = 3.0         # autonomous-work cooldown
# seconds a summoned member stands with you before going back to work. Long
# enough to say the next thing ("...now repeat after me"); short enough that a
# forgotten summons doesn't idle the whole camp.
const SUMMON_HOLD := 12.0
var _summon_hold: float = 0.0
# where to stand RELATIVE to the leader when summoned -- see _accept_order("come")
var _come_offset: Vector3 = Vector3.ZERO
var _scouted_camp = null         # the WorldTribe a scout actually walked up to —
								  # remembered so the report at home names THIS
								  # camp, not whatever's nearest once we're back
var _pending_recruit: bool = false   # told to recruit but short on food — gather
									  # first, then _complete_task() retries recruit

# ── self-defense: members never used to fight back at all. Now, getting hit
# sets _foe (engage) or, if badly outnumbered, _flee_from (run) — checked at
# the top of _move() every frame, overriding whatever task was in progress ──
var _foe: Node3D = null
var _flee_from: Node3D = null
var _flee_timer: float = 0.0
var _defend_attack_cd: float = 0.0
const OUTNUMBER_RADIUS := 14.0
const OUTNUMBER_THRESHOLD := 4   # this many nearby rival npcs and we run instead of fighting
var _base_defense_cd: float = 0.0
const BASE_DEFENSE_RADIUS := 26.0   # how far from the stockpile we'll proactively respond to a raider
var _chase_timer: float = 0.0       # patience left to actually catch _foe before giving up — matches npc.gd

# ── environmental senses: what this member can currently SEE or HEAR nearby ──
# SIGHT is close-range and specific (you can tell WHAT it is); HEARING is
# wider but coarser (you know something's there, not necessarily what). Both
# are distance-only, same honest proxy every other proximity check in this
# file already uses (_nearby_rival_count, _nearest_base_threat) -- no line of
# sight/occlusion anywhere in this codebase, so this doesn't invent one.
const SIGHT_RADIUS := 12.0
const HEARING_RADIUS := 24.0
const SENSE_INTERVAL := 1.5      # seconds; environment doesn't need 10Hz precision
var _sense_cd: float = 0.0

# ── vision-gated work + progressive outward search (2026-07-20) ───────────
# Task targets are now restricted to SIGHT_RADIUS (see the _nearest_*()
# pickers) -- a member should work what's actually in front of them, not
# beeline across the map to the globally-nearest node. When nothing
# qualifying is in sight, _begin_fallback() SEARCHES instead of idling: each
# consecutive failed search pushes the search point further out from the
# member's CURRENT position (not back toward home), so a camp that's
# stripped its immediate surroundings genuinely walks its working range
# outward over time rather than orbiting the same starting radius forever.
# _search_streak resets to 0 the instant a real target is found again (see
# the gather/hunt/wood/recruit branches above) -- it's "how long have I come
# up empty", not a ratchet that only ever grows.
const SEARCH_RADIUS_BASE   := 10.0   # first failed search — same as the old fixed fallback
const SEARCH_RADIUS_GROWTH := 6.0    # extra distance per additional consecutive failure
const SEARCH_RADIUS_MAX    := 90.0   # cap — still findable/walkable, not an ever-growing trek
# a member who has searched this many times running (i.e. is genuinely far
# out, not just unlucky once) is a real candidate to found a new outpost
# stockpile instead of just wandering — see Tribemanager.found_outpost().
const EXPANSION_SEARCH_STREAK := 4
var _search_streak: int = 0

# ── NPC-to-NPC food sharing (2026-07-18) ──────────────────────────────────
# Previously the only food transfers in this whole game were player->member
# (contribute()) and member->shared-stockpile (the trust-gated self-feeding
# above). Members never helped EACH OTHER -- a member sitting on a surplus
# would let a tribemate right next to them starve. Checked on the same poll
# as _sense_environment() (SHARE_RADIUS is deliberately much tighter than
# SIGHT_RADIUS -- sharing a meal means being right next to someone, not
# just able to see them across camp).
const SHARE_RADIUS := 6.0
const SHARE_SURPLUS_MIN := RATION_RESERVE + 2   # only give if comfortably above own reserve
const SHARE_HUNGER_THRESHOLD := 70.0            # share with someone this hungry or worse
var sees_raider: bool = false    # a non-neutral rival npc within SIGHT_RADIUS

# ── NPC-to-NPC feelings + emotional override (2026-07-18) ──────────────────
# Previously NPC<->NPC trust was explicitly NOT modelled (see tribe_rumor.gd's
# own honest scope note) -- talking to a peer was flavour with nothing real to
# move. Now every real conversation exchange (tribe_talk.gd's _on_line "reply"
# case, the completed A<->B exchange) nudges how each feels about the OTHER,
# driven by the gap between their standings with the LEADER (loyalty_score()):
# talking with someone more loyal than you is reassuring (you think better of
# them, and it calms your own resentment); talking with someone LESS loyal
# than you drags on both -- you think a little less of them, and hearing a
# grumbler rubs off as resentment even if your own brain's Trust/Follow
# neurons are otherwise perfectly happy.
#
# THE OVERRIDE: resentment is deliberately NOT wired through the Spikeling
# brain at all -- it is checked directly in _emotion_step() regardless of
# is_backing_you/Follow-neuron state. That is the actual "emotion overtakes
# neuron threshold" ask: a member can be numerically "Devoted" by the brain's
# own bookkeeping (fed constantly, Follow neuron saturated) and still boil
# over, because resentment is a separate accumulator the brain doesn't gate.
# Once it boils, the grudge_target/grudge_intensity it leaves behind persists
# and decays far slower than the resentment spike itself -- a real grudge,
# not a passing mood that resets the moment the meter dips.
const RESENTMENT_BOIL      := 1.0    # emotion overrides brain state at this level
const RESENTMENT_DECAY     := 0.01   # passive fade per second once below boiling
const GRUDGE_DECAY         := 0.004  # grudges outlive the resentment spike that made them
const LOYALTY_GAP_FOR_EFFECT := 20   # rank-loyalty gap that counts as a real difference
const TALK_OPINION_SCALE   := 400.0  # bigger = gentler opinion swings per conversation
const TALK_RESENT_GAIN     := 0.05   # a conversation with someone less loyal than me
const TALK_RESENT_RELIEF   := 0.03   # a conversation with someone more loyal than me
const OPINION_GRUDGE_PICK  := -0.15  # how sour npc_opinion must be to pick a peer target

var npc_opinion: Dictionary = {}     # peer member_name -> float -1..1, how I feel about them
var resentment: float = 0.0          # slow-building disgruntlement, separate from the brain
var grudge_target: String = ""       # "" none, "You" = the leader, else a peer's member_name
var grudge_intensity: float = 0.0    # persists once formed; decays far slower than resentment
var _emotion_cd: float = 0.0
var sees_prey: bool = false      # a huntable animal within SIGHT_RADIUS
var hears_danger: bool = false   # a non-neutral rival within HEARING_RADIUS but beyond sight
const CHASE_GIVEUP_TIME := 7.0

# a LEADER-set standing order overrides the member's own AI until met
var _standing_job: String = ""
var _standing_target: int = 0    # 0 = until told otherwise
var _standing_done: int = 0

# stuck detection (trapped on a fence / structure)
var _last_pos: Vector3 = Vector3.ZERO
var _stuck_cd: float = 0.6

func set_standing(job: String, target: int) -> void:
	_standing_job = job
	_standing_target = target
	_standing_done = 0
	_think("Orders: %s%s." % [job, (" x%d" % target) if target > 0 else " (until told)"], 2.5)
	# BUG FIXED (2026-07-17): orders given through this numeric-key path
	# (_apply_command() -> set_standing(), and the [P] work-plan crew
	# assignment) never became a memory at all -- only orders typed/spoken
	# through TribeCommand's natural-language path did (_do_order()'s own
	# "ordered"/"refused" entries). Every real action should leave a real
	# trace this member's own memory (and therefore the LLM) can draw on.
	TribeMemory.remember(member_name, "ordered", "You",
		"You told me to %s%s." % [job, (" (%d)" % target) if target > 0 else ""],
		"neutral", 0.0)

func clear_standing() -> void:
	TribeMemory.remember(member_name, "ordered", "You",
		"You told me to go back to working things out for myself.", "neutral", 0.0)
	_standing_job = ""
	_standing_target = 0
	_standing_done = 0

# health & personal rations (members eat their OWN food; only YOU touch the stockpile)
var hp: float = 100.0
var max_hp: float = 100.0
var inv_food: int = 6
const RATION_RESERVE := 8        # how much food a member keeps for itself
var _chop_cd: float = 0.0
var _task_wood: int = 0
var _build_plan: Array = []
var _build_i: int = 0
var _club_model: MeshInstance3D = null
var _armor_model: MeshInstance3D = null
var _visual_weapon: int = -1   # last tier the weapon mesh was built for; -1 forces first build
var _visual_armor: int = -1    # same for armor
var _hp_bar: Label3D = null
var _sel_mark: MeshInstance3D = null

# ── WEAPONS & ARMOR ──────────────────────────────────────────────────────────
# Mirrors npc.gd's system for the player's own members: weapon multiplies the
# damage they deal, armor reduces damage they take. They forge upgrades from the
# tribe's looted-material surplus (_maybe_upgrade_gear), so a well-supplied camp
# ends up better armed. Default is the plain Club / no armor.
const WEAPON_TIERS := [
	{"name": "Club",  "mult": 1.0},
	{"name": "Spear", "mult": 1.4},
	{"name": "Bow",   "mult": 1.6},
	{"name": "Axe",   "mult": 1.8},
]
const ARMOR_TIERS := [
	{"name": "None",  "reduction": 0.0},
	{"name": "Hide",  "reduction": 0.15},
	{"name": "Bone",  "reduction": 0.30},
	{"name": "Metal", "reduction": 0.45},
]
var weapon: int = 0
var armor: int = 0

func weapon_mult() -> float:
	return float(WEAPON_TIERS[clampi(weapon, 0, WEAPON_TIERS.size() - 1)]["mult"])

func armor_reduction() -> float:
	return float(ARMOR_TIERS[clampi(armor, 0, ARMOR_TIERS.size() - 1)]["reduction"])

func set_gear(w: int, a: int) -> void:
	weapon = clampi(w, 0, WEAPON_TIERS.size() - 1)
	armor = clampi(a, 0, ARMOR_TIERS.size() - 1)

## DIRECTED weapon crafting -- an explicit choice ("Ka, craft a spear"),
## as opposed to _maybe_upgrade_gear()'s random automatic upgrade. Spends the
## same shared materials pool at the same cost; bypasses ORDER_RISK entirely
## (crafting isn't dangerous, same precedent as "build"/"carve" -- see the
## comment on ORDER_RISK). Returns false (and does nothing) if materials are
## short, same fail-soft discipline as _maybe_upgrade_gear().
func craft_weapon(tier: int) -> bool:
	if manager == null or not manager.has_method("spend_materials"):
		return false
	tier = clampi(tier, 0, WEAPON_TIERS.size() - 1)
	if not manager.spend_materials(_GEAR_MAT_COST):
		_think("Not enough materials to craft that yet.", 2.0)
		return false
	weapon = tier
	var wname: String = str(WEAPON_TIERS[tier]["name"])
	_think("Crafted a %s." % wname, 2.0)
	TribeMemory.remember(member_name, "crafted", "You",
		"You had me craft a %s." % wname, "neutral", 0.02)
	return true

# productivity — feeds the "who should lead" calculation
var contrib_food: int = 0
var contrib_wood: int = 0
var contrib_kills: int = 0
var contrib_recruits: int = 0
func productivity() -> int:
	return contrib_food + contrib_wood * 2 + contrib_kills * 8 + contrib_recruits * 5

# paid (mercenary) work: skins buy obedience but NOT loyalty
var _task_paid: bool = false
const ORDER_COST := {"gather": 1, "hunt": 2, "scout": 3}   # in skins

# emergent sub-tribe (faction) this member belongs to — set by the TribeManager
var faction_id: int = -1
var faction_name: String = ""
var faction_color: Color = Color(1, 1, 1)
var faction_centroid: Vector3 = Vector3.ZERO
var faction_vouch: float = 0.0   # fraction of my faction that backs you (0..1)
var _faction_mark: MeshInstance3D = null

signal order_completed(member, kind, result)

func _ready() -> void:
	add_to_group("tribe")
	add_to_group("has_brain")
	_setup_slope_walking()
	brain = Spikeling.new()
	if not brain.load_from_text(_brain_text()):
		push_error("TribeMember: brain failed to load")
	home_pos = global_position
	_target = home_pos
	_fidget_cd = randf_range(4.0, 14.0)   # stagger so members don't all fidget simultaneously
	_apply_tint()
	# faction-mark floating orbs were removed — too many same-ish colored dots
	# bobbing over members' heads read as visual noise rather than useful
	# information. faction_id/faction_color/vouching logic is untouched,
	# only the marker mesh is gone (_update_faction_mark() no-ops safely
	# since _faction_mark stays null).
	_build_combat_visuals()
	anim = BodyAnim.new()
	anim.setup(_anim_parts())
	# TrustLabel/ThoughtLabel are scene-defined (main.tscn) with no explicit
	# font_size, so they fell back to Label3D's engine default (48) — way
	# too large up close. Label3D has no "max apparent screen size" built
	# in, so as the camera (or several labeled members/the stockpile)
	# clusters near spawn, oversized billboards stack into an unreadable
	# jumble. Sizing down here, in code, since these nodes live in the
	# scene file rather than being built procedurally like everything else.
	if trust_label:
		trust_label.font_size = 22
		trust_label.outline_size = 6
	if thought_label:
		thought_label.font_size = 18
	_update_label()

# On flat ground the defaults were fine; on terrain they weren't. floor_snap
# glues the body to the surface so it walks DOWN a hill instead of launching off
# every lip and bouncing (which read as "stuck" and made members stall on
# slopes). A wider floor_max_angle lets them climb steeper ground before the
# engine calls it a wall. Applied to every moving body (member/npc/animal/player).
func _setup_slope_walking() -> void:
	floor_snap_length = 0.8
	floor_max_angle = deg_to_rad(54.0)
	floor_stop_on_slope = true
	floor_constant_speed = true

# the visual parts BodyAnim drives — the body and (if present) the face block
func _anim_parts() -> Array:
	var out: Array = []
	var mesh := get_node_or_null("Mesh")
	if mesh: out.append(mesh)
	var face := get_node_or_null("Face")
	if face: out.append(face)
	return out

# breathe, bob, lean, and let trust/hunger show in the posture
func _animate_body(delta: float) -> void:
	if anim == null:
		return
	var spd := Vector2(velocity.x, velocity.z).length()
	# alert & upright when bonded and fed; slumped when hungry or walking out
	var m := clampf(relationship * 0.45 - hunger / 110.0, -1.0, 1.0)
	if _leaving:
		m = -1.0
	anim.mood = m
	# nerves from a fresh hit fade out over a second or so
	anim.tension = maxf(0.0, anim.tension - delta * 1.5)
	anim.tick(delta, spd, is_on_floor())

func _build_combat_visuals() -> void:
	_club_model = MeshInstance3D.new()
	_club_model.position = Vector3(0.35, 1.05, 0.3)
	_club_model.visible = false
	add_child(_club_model)
	_update_weapon_visual()   # builds the tier-0 (Club) mesh immediately

	_armor_model = MeshInstance3D.new()
	_armor_model.position = Vector3(0, 1.15, 0)
	_armor_model.visible = false
	add_child(_armor_model)
	_update_armor_visual()    # tier 0 (None) stays hidden

	_hp_bar = Label3D.new()
	_hp_bar.position = Vector3(0, 2.25, 0)
	_hp_bar.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_hp_bar.font_size = 28
	_hp_bar.visible = false
	add_child(_hp_bar)

	# a cyan diamond shown when YOU have this member individually selected
	_sel_mark = MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.18
	sm.height = 0.36
	_sel_mark.mesh = sm
	_sel_mark.position = Vector3(0, 3.4, 0)
	var smat := StandardMaterial3D.new()
	smat.albedo_color = Color(0.2, 0.9, 1.0)
	smat.emission_enabled = true
	smat.emission = Color(0.1, 0.7, 0.9)
	_sel_mark.material_override = smat
	_sel_mark.visible = false
	add_child(_sel_mark)

func _update_combat_visuals() -> void:
	if _club_model:
		# you can SEE who's armed: backers carry a club whenever the rack has one
		_club_model.visible = is_backing_you and manager != null and manager.has_method("clubs_available") and manager.clubs > 0
		if weapon != _visual_weapon:
			_update_weapon_visual()
	if _armor_model and armor != _visual_armor:
		_update_armor_visual()
	if _sel_mark:
		var in_group: bool = manager != null and "selected_group" in manager and self in manager.selected_group
		_sel_mark.visible = (manager != null and manager.selected_member == self) or in_group
	if _hp_bar:
		if hp < max_hp - 0.5:
			_hp_bar.visible = true
			_hp_bar.text = "HP %d%%" % int(hp / max_hp * 100.0)
			_hp_bar.modulate = Color(1.0, 0.3, 0.3).lerp(Color(0.4, 1.0, 0.4), hp / max_hp)
		else:
			_hp_bar.visible = false

## Real visual per weapon tier, not just the one generic brown stick every
## tier used to render as. Primitive meshes only, matching this project's
## existing style everywhere else (no imported models/sprites anywhere in
## the codebase) -- shape, size, AND color all differ per tier so they read
## as genuinely different weapons at a glance, not just a recolor.
func _update_weapon_visual() -> void:
	_visual_weapon = weapon
	var mesh: Mesh
	var mat: StandardMaterial3D
	var rot := Vector3(55, 0, 0)
	match weapon:
		1:  # Spear -- long, thin, pale wood shaft
			var cyl := CylinderMesh.new()
			cyl.top_radius = 0.03
			cyl.bottom_radius = 0.03
			cyl.height = 1.3
			mesh = cyl
			mat = MatCache.flat(Color(0.62, 0.56, 0.42))
		2:  # Bow -- a squashed ring read edge-on as a curved bow silhouette
			var tor := TorusMesh.new()
			tor.inner_radius = 0.22
			tor.outer_radius = 0.27
			mesh = tor
			mat = MatCache.flat(Color(0.35, 0.22, 0.12))
			rot = Vector3(0, 0, 90)
		3:  # Axe -- wide, flat, metallic head instead of a slim shaft
			var box := BoxMesh.new()
			box.size = Vector3(0.34, 0.06, 0.30)
			mesh = box
			mat = MatCache.flat(Color(0.6, 0.62, 0.66), 0.4, 0.6)
		_:  # Club (0, and any unrecognised tier) -- the original plain stick
			var clm := BoxMesh.new()
			clm.size = Vector3(0.1, 0.1, 0.8)
			mesh = clm
			mat = MatCache.flat(Color(0.45, 0.30, 0.15))
	_club_model.mesh = mesh
	_club_model.material_override = mat
	_club_model.rotation_degrees = rot
	if weapon == 2:
		_club_model.scale = Vector3(0.45, 1.0, 1.0)   # squash the torus into a bow curve
	else:
		_club_model.scale = Vector3.ONE

## Real visual per armor tier -- previously armor had NO visual at all despite
## having real stat effects (armor_reduction()). A flattened chest-mounted
## box, colored per tier; None stays hidden since there's nothing to show.
func _update_armor_visual() -> void:
	_visual_armor = armor
	if armor <= 0:
		_armor_model.visible = false
		return
	_armor_model.visible = true
	var mat: StandardMaterial3D
	match armor:
		2:  # Bone -- pale, bleached plates
			mat = MatCache.flat(Color(0.85, 0.80, 0.70))
		3:  # Metal -- real sheen, the top-tier protection actually looks like it
			mat = MatCache.flat(Color(0.55, 0.57, 0.60), 0.3, 0.7)
		_:  # Hide (1, and any unrecognised positive tier) -- plain tanned leather
			mat = MatCache.flat(Color(0.50, 0.36, 0.22))
	var box := BoxMesh.new()
	box.size = Vector3(0.42, 0.5, 0.26)
	_armor_model.mesh = box
	_armor_model.material_override = mat

func take_hit(dmg: float, attacker) -> void:
	dmg *= (1.0 - armor_reduction())   # armor soaks part of the blow
	hp -= dmg
	# REAL HEARING, not just passive proximity: a hit landing is a genuine
	# loud EVENT, broadcast at the moment it happens to every member within
	# earshot -- including ones who can't currently SEE the fight (behind an
	# obstacle, working elsewhere in camp). This is distinct from
	# _sense_environment()'s continuous "is a rival body nearby" polling,
	# which only ever detects a rival that's ALREADY visible/audible right
	# now -- it can't represent a sudden noise from something not otherwise
	# in range at all (a strike landing just beyond HEARING_RADIUS's steady
	# check, or a hit that happens between two polling ticks).
	_broadcast_combat_sound(global_position)
	# betrayal: the PLAYER struck one of their own. Erodes Trust through the
	# brain (see betray()) on top of the ordinary damage/self-defense below —
	# a betrayed member still fights or flees like any other attack, they just
	# also lose whatever trust they'd built up.
	if attacker and is_instance_valid(attacker) and attacker.is_in_group("player"):
		betray()
	if trust_label:
		trust_label.modulate = Color(1.0, 0.4, 0.3)
	if anim:
		anim.pop(0.5)            # flinch
		anim.tension = 1.0       # and a moment of rattled nerves
	if hp <= 0.0:
		die()
		return
	if attacker == null or not is_instance_valid(attacker):
		return
	# self-defense: fight back regardless of who attacked us — UNLESS we're
	# clearly surrounded, in which case running beats a hopeless brawl
	if _nearby_rival_count() >= OUTNUMBER_THRESHOLD:
		_foe = null
		_flee_from = attacker as Node3D
		_flee_timer = 2.0
	else:
		_flee_timer = 0.0
		_foe = attacker as Node3D
		_chase_timer = CHASE_GIVEUP_TIME

# how many likely-hostile npcs (rival tribe, non-neutral) are near us right
# now — used to decide fight vs flee when we're hit
func _nearby_rival_count() -> int:
	var count := 0
	for o in get_tree().get_nodes_in_group("npc"):
		var n := o as Node3D
		if n == null or not is_instance_valid(n):
			continue
		if n.get("neutral"):
			continue
		if global_position.distance_to(n.global_position) <= OUTNUMBER_RADIUS:
			count += 1
	return count

# ── environmental senses: what's actually near us right now, fed to the brain
# as real stimulation (see SawRaider/SawPrey/HeardDanger in _brain_text()) and
# read back by brain_snapshot() for LLM conversation grounding. Uses
# SpatialGrid.query() rather than a raw group scan -- same idiom npc.gd
# already uses for its own proximity checks (see its OUTNUMBER_RADIUS query),
# and exactly the class of check spatial_grid.gd's own docstring names as the
# intended use case.
#
# GRADED DRIVE, mirrored from the real hardware sensor rig this project
# already built (Spikeling/bridge.py + proximity_grid.spk -- 5 real HC-SR04
# ultrasonic sensors, each driving its own LIF neuron): that rig computes
# drive = max(0, 120 - 4*distance_cm), so something at the sensor's face
# hits hard and something at the edge of range barely registers, instead of
# a flat "in range = fire" boolean. _proximity_drive() below is the same
# shape adapted to this game's radii/units -- physically-grounded intensity
# falloff, not a threshold trigger, same as the real sensor array.
func _sense_environment() -> void:
	# VISION/HEARING AS REAL MEMORY (2026-07-17): previously these were live
	# brain state ONLY -- real for brain_snapshot() to report in the instant,
	# but nothing an NPC could ever recall in conversation a minute later,
	# unlike every other real event in this file (fed/betrayed/ordered/...).
	# Written only on a TRUE transition (not-seeing -> seeing), not every
	# 1.5s poll while something stays in range -- one sighting is one memory,
	# same as a person doesn't form a new memory every second they keep
	# looking at the same thing. Coalescing (see TribeMemory.remember())
	# still folds repeated sightings within its window into one entry.
	var was_seeing_raider := sees_raider
	var raider_d := _nearest_distance("npc", SIGHT_RADIUS, true)
	sees_raider = raider_d >= 0.0
	if sees_raider:
		brain.stimulate("SawRaider", _proximity_drive(raider_d, SIGHT_RADIUS))
		if not was_seeing_raider:
			TribeMemory.remember(member_name, "saw_raider", "You",
				"I spotted a rival tribesperson nearby.", "wary", 0.0)

	var was_seeing_prey := sees_prey
	var prey_d := _nearest_distance("animal", SIGHT_RADIUS, false)
	sees_prey = prey_d >= 0.0
	if sees_prey:
		brain.stimulate("SawPrey", _proximity_drive(prey_d, SIGHT_RADIUS))
		if not was_seeing_prey:
			TribeMemory.remember(member_name, "saw_prey", "You",
				"I spotted game nearby -- good hunting grounds.", "neutral", 0.0)

	# HEARD is deliberately "within hearing but NOT already seen" -- otherwise
	# a raider standing right next to you would double-stimulate both SawRaider
	# and HeardDanger for the same single real event, which isn't two things
	# happening, it's one thing described twice.
	var was_hearing_danger := hears_danger
	hears_danger = false
	if not sees_raider:
		var heard_d := _nearest_distance("npc", HEARING_RADIUS, true)
		hears_danger = heard_d >= 0.0
		if hears_danger:
			brain.stimulate("HeardDanger", _proximity_drive(heard_d, HEARING_RADIUS))
			if not was_hearing_danger:
				TribeMemory.remember(member_name, "heard_danger", "You",
					"I heard signs of a rival nearby, though I couldn't see them.", "wary", 0.0)

## Give one unit of this member's OWN surplus food to a hungry tribemate
## standing right next to them. Previously the only food transfers in this
## game were player->member and member->shared-stockpile; members never
## helped each other directly. Real, narrow conditions: must have a real
## surplus above their own reserve (never share down into their own hunger
## risk), the recipient must be genuinely hungry (not just "not full"), and
## it only ever gives to ONE tribemate per poll (a single meaningful act,
## not a food-teleportation network). Dogs share the "tribe" group too --
## guarded with real property checks, not a name/type assumption.
func _maybe_share_food() -> void:
	if inv_food <= SHARE_SURPLUS_MIN:
		return
	for o in SpatialGrid.query(global_position, SHARE_RADIUS, "tribe"):
		var n := o as Node3D
		if n == null or not is_instance_valid(n) or n == self:
			continue
		var h = n.get("hunger")
		var nf = n.get("inv_food")
		if h == null or nf == null:
			continue   # not a real tribemember (e.g. a dog) -- no ration system to share into
		if float(h) < SHARE_HUNGER_THRESHOLD:
			continue
		var d: float = global_position.distance_to(n.global_position)
		if d > SHARE_RADIUS:
			continue
		inv_food -= 1
		n.inv_food = int(nf) + 1
		n.hunger = maxf(0.0, float(h) - EAT_RESTORE)
		var giver_name: String = member_name
		var recv_name: String = str(n.get("member_name"))
		if n.has_method("_think"):
			n._think("%s shared food with me." % giver_name, 2.0)
		TribeMemory.remember(giver_name, "shared_food", recv_name,
			"I shared some of my food with %s." % recv_name, "warm", 0.0)
		TribeMemory.remember(recv_name, "shared_food", giver_name,
			"%s shared their food with me when I was hungry." % giver_name, "grateful", 0.02)
		return   # one act of generosity per poll, not a firehose

## How much this member's standing with the leader is worth toward accepting
## risky orders -- reused here as the "loyalty ranking" that peer talk and
## grudges are driven by (see RANK_LOYALTY at the top of the file).
func loyalty_score() -> int:
	return int(RANK_LOYALTY.get(current_rank, 0))

## Called once per completed NPC<->NPC conversation exchange (both directions
## -- see tribe_talk.gd's _on_line "reply" branch) with the PEER's own
## loyalty_score(). Moves my opinion of them and my own resentment based on
## the gap between our standings with the leader -- a real, mechanical
## consequence of "who talks to whom", not flavour text.
func npc_talk_effect(peer_name: String, peer_loyalty: int) -> void:
	var gap: int = peer_loyalty - loyalty_score()   # positive: peer more loyal than me
	var delta: float = clampf(float(gap) / TALK_OPINION_SCALE, -0.08, 0.08)
	npc_opinion[peer_name] = clampf(float(npc_opinion.get(peer_name, 0.0)) + delta, -1.0, 1.0)
	if gap >= LOYALTY_GAP_FOR_EFFECT:
		resentment = maxf(0.0, resentment - TALK_RESENT_RELIEF)   # a steadier peer calms me
	elif gap <= -LOYALTY_GAP_FOR_EFFECT:
		resentment = minf(RESENTMENT_BOIL * 2.0, resentment + TALK_RESENT_GAIN)  # a grumbler rubs off

## Background pass for the slow-building emotional layer above: decays
## resentment and any standing grudge over time, and checks whether raw
## disgruntlement has crossed its own boiling point -- DELIBERATELY not
## gated on brain state (is_backing_you, Follow-neuron fire count) at all.
## That's the actual override: the Spikeling brain can be perfectly content
## while resentment, an entirely separate accumulator, still boils over.
func _emotion_step(delta: float) -> void:
	resentment = maxf(0.0, resentment - RESENTMENT_DECAY * delta)
	if grudge_target != "":
		grudge_intensity = maxf(0.0, grudge_intensity - GRUDGE_DECAY * delta)
		if grudge_intensity <= 0.0:
			grudge_target = ""
	if resentment < RESENTMENT_BOIL or (_foe != null and is_instance_valid(_foe)) or _leaving:
		return
	_boil_over()

## Extremely disgruntled: turn on whoever they resent most nearby, or the
## leader if no peer stands out. Sets _foe directly -- the SAME mechanism
## take_hit()'s self-defense and the perimeter-guard threat-scan already use,
## so the fight itself runs through the existing, already-tested combat loop
## (_strike_foe()/_try_throw_at in _physics_process). The grudge that's left
## behind outlives the resentment spike that caused it (GRUDGE_DECAY).
func _boil_over() -> void:
	var target_name := ""
	var target_node: Node3D = null
	var worst: float = OPINION_GRUDGE_PICK
	for o in SpatialGrid.query(global_position, SHARE_RADIUS, "tribe"):
		var n := o as Node3D
		if n == null or n == self or not is_instance_valid(n):
			continue
		var nm = n.get("member_name")
		if nm == null:
			continue   # not a real tribemember (e.g. a dog) -- nothing to hold a grudge against
		var op: float = float(npc_opinion.get(str(nm), 0.0))
		if op < worst:
			worst = op
			target_name = str(nm)
			target_node = n
	if target_node == null:
		var pl := get_tree().get_first_node_in_group("player") as Node3D
		if pl == null:
			return
		target_name = "You"
		target_node = pl
	grudge_target = target_name
	grudge_intensity = 1.0
	_foe = target_node
	_chase_timer = CHASE_GIVEUP_TIME
	_think("I've had ENOUGH of this.", 2.5)
	TribeMemory.remember(member_name, "boiled_over", target_name,
		"I couldn't take it anymore -- I turned on %s." % target_name, "furious",
		-0.15 if target_name == "You" else 0.0)
	resentment = RESENTMENT_BOIL * 0.5   # vents some heat, but the grudge itself lingers

## Closest matching entity's distance within `radius`, or -1.0 if none.
## `rivals_only` filters to non-neutral (hostile) members of the group --
## used for "npc" (rival tribespeople), irrelevant for "animal".
func _nearest_distance(group: String, radius: float, rivals_only: bool) -> float:
	# BUG FIXED (2026-07-17): SpatialGrid.query() is a CELL-based pre-filter,
	# not an exact-radius one -- it walks every cell that could possibly
	# contain something within `radius` (a square block of cells), which is a
	# superset of the actual circle. A hit in the corner of that block can be
	# meaningfully farther than `radius` in real straight-line distance.
	# npc.gd's own SpatialGrid usage already re-checks exact distance after
	# querying for exactly this reason; this function was missing that same
	# recheck. Caught by this feature's own regression test: an entity placed
	# 18 units away registered as "seen" under a 12-unit SIGHT_RADIUS query.
	var best := -1.0
	for o in SpatialGrid.query(global_position, radius, group):
		var n := o as Node3D
		if n == null or not is_instance_valid(n):
			continue
		if rivals_only and n.get("neutral"):
			continue
		var d: float = global_position.distance_to(n.global_position)
		if d > radius:
			continue
		if best < 0.0 or d < best:
			best = d
	return best

## Same shape as the real sensor rig's drive = max(0, 120 - 4*distance):
## full intensity at distance 0, tapering linearly to 0 exactly at `radius`.
func _proximity_drive(distance: float, radius: float) -> float:
	return maxf(0.0, 100.0 * (1.0 - distance / radius))

## Broadcasts a real, one-off combat sound from `pos` to every tribe member
## within HEARING_RADIUS -- called once per hit landed (see take_hit()), not
## polled. Every member in earshot gets their HeardDanger neuron stimulated
## directly, graded by distance from the EVENT (not from each listener's own
## unrelated position check), so someone standing right next to a fight hears
## it far more sharply than someone at the edge of earshot. Uses the "tribe"
## group (own members) rather than "npc" -- this is about a member reacting
## to a fight happening near THEM, regardless of who's fighting whom.
static func _broadcast_combat_sound(pos: Vector3) -> void:
	for o in SpatialGrid.query(pos, HEARING_RADIUS, "tribe"):
		var n := o as Node3D
		if n == null or not is_instance_valid(n) or not n.has_method("_hear_combat"):
			continue
		var d: float = pos.distance_to(n.global_position)
		if d > HEARING_RADIUS:
			continue
		n._hear_combat(d)

## Applies real HeardDanger stimulation from a heard (not necessarily seen)
## combat event -- see _broadcast_combat_sound(). Also updates hears_danger
## so brain_snapshot() reflects it immediately rather than waiting for the
## next _sense_environment() poll.
func _hear_combat(distance: float) -> void:
	if brain == null:
		return
	hears_danger = true
	brain.stimulate("HeardDanger", _proximity_drive(distance, HEARING_RADIUS))
	# already event-based (called once per real hit landed, not polled), so
	# unlike _sense_environment()'s transition-gating this can log every time
	TribeMemory.remember(member_name, "heard_danger", "You",
		"I heard a fight break out nearby.", "wary", 0.0)

# the nearest actual threat to the camp — a raider actively sieging the base,
# or anyone already at war, within reach of the stockpile. Deliberately NOT
# "any rival npc anywhere" — a distant rival just passing by shouldn't pull
# every gatherer off their task.
func _nearest_base_threat() -> Node3D:
	var sp := get_tree().get_first_node_in_group("stockpile")
	if sp == null:
		return null
	var center: Vector3 = (sp as Node3D).global_position
	var best: Node3D = null
	var bd := BASE_DEFENSE_RADIUS
	for o in get_tree().get_nodes_in_group("npc"):
		var n := o as Node3D
		if n == null or not is_instance_valid(n) or n.get("neutral"):
			continue
		# ANY non-neutral rival this close to our stockpile is a threat to defend
		# against -- not only ones already flagged as raiding/at-war. Members were
		# ignoring hostiles standing right in camp because they weren't flagged.
		# (Own members are in group "tribe", not "npc", so no friendly fire.)
		if center.distance_to(n.global_position) > BASE_DEFENSE_RADIUS:
			continue
		var d := global_position.distance_to(n.global_position)
		if d < bd:
			bd = d
			best = n
	return best

func die() -> void:
	print("[%s] has fallen." % member_name)
	if manager and manager.has_method("on_member_died"):
		manager.on_member_died(self)
	queue_free()

# swing at whoever's attacking us — a club in hand (the tribe's shared rack)
# hits harder, same as the player's own strikes
func _strike_foe() -> void:
	if _defend_attack_cd > 0.0 or _foe == null or not is_instance_valid(_foe):
		return
	_defend_attack_cd = 0.6
	var f := (_foe as Node3D).global_position - global_position
	f.y = 0.0
	if f.length() > 0.01:
		rotation.y = lerp_angle(rotation.y, atan2(f.x, f.z), 0.5)
	var dmg := 5.0 + float(get_might())
	if manager and manager.has_method("clubs_available") and manager.clubs > 0:
		dmg += 6.0
	dmg *= weapon_mult()   # a better weapon swings for more
	if anim:
		anim.pop(0.4)
	if _foe.has_method("take_hit"):
		_foe.take_hit(dmg, self)

# throw a club at a foe still out of melee range — npc.gd has always been
# able to do this; loyal members couldn't, despite drawing from the same
# shared club stock the player's own throw uses (Tribemanager.consume_club)
const THROW_RANGE := 9.0
var _throw_cd: float = 0.0

func _try_throw_at(foe) -> bool:
	if _throw_cd > 0.0 or foe == null or not is_instance_valid(foe):
		return false
	if manager == null or not manager.has_method("clubs_available") or manager.clubs_available() <= 0:
		return false
	if not manager.has_method("consume_club") or not manager.consume_club():
		return false
	_throw_cd = 2.5
	var f := (foe as Node3D).global_position - global_position
	f.y = 0.0
	if f.length() > 0.01:
		rotation.y = lerp_angle(rotation.y, atan2(f.x, f.z), 0.5)
	var dmg := 8.0 + float(get_might())
	dmg *= weapon_mult()
	if anim:
		anim.pop(0.4)
	if foe.has_method("take_hit"):
		foe.take_hit(dmg, self)
	return true

func _build_faction_mark() -> void:
	# a small floating orb above the head, colored by emergent sub-tribe
	_faction_mark = MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = 0.22
	sph.height = 0.44
	_faction_mark.mesh = sph
	_faction_mark.position = Vector3(0, 3.05, 0)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_faction_mark.material_override = mat
	_faction_mark.visible = false
	add_child(_faction_mark)

func _update_faction_mark() -> void:
	if _faction_mark == null:
		return
	_faction_mark.visible = faction_id >= 0
	if faction_id >= 0:
		var mat := _faction_mark.material_override as StandardMaterial3D
		if mat:
			mat.albedo_color = faction_color

func _apply_tint() -> void:
	var mi := get_node_or_null("Mesh") as MeshInstance3D
	if mi == null:
		return
	var p: Dictionary = PERSONALITIES.get(personality, PERSONALITIES["Steady"])
	var mat := StandardMaterial3D.new()
	mat.albedo_color = p["color"]
	mi.material_override = mat

# ── per-physics-frame: brain ticks, bond decay, thoughts, and movement ──
var _grid_cd: float = 0.0

func _exit_tree() -> void:
	SpatialGrid.remove(self)

func _physics_process(delta: float) -> void:
	# LOD: skip Spikeling ticks for members the player can't see. Drain the
	# accumulator so there's no burst of catch-up ticks when re-entering range.
	var _far_from_player: bool = _player_node != null \
		and global_position.distance_to(_player_node.global_position) > BRAIN_LOD_RADIUS
	if _far_from_player:
		_tick_accum = 0.0
	else:
		# step the brain at a fixed rate (cheap)
		_tick_accum += delta
		var interval := 1.0 / TICK_HZ
		while _tick_accum >= interval:
			_tick_accum -= interval
			_brain_tick()
		# environmental senses -- same LOD gate as the brain itself, since a
		# member the brain isn't ticking for has no reason to poll the world
		_sense_cd -= delta
		if _sense_cd <= 0.0:
			_sense_cd = SENSE_INTERVAL
			_sense_environment()
			_maybe_share_food()

	# register in the world spatial grid so rival npc.gd's "tribe" group
	# queries (intruder/outnumber/war-target checks) can find us without
	# scanning every member in the world — see spatial_grid.gd
	_grid_cd -= delta
	if _grid_cd <= 0.0:
		_grid_cd = 0.25
		SpatialGrid.update(self)

	# decay the bond slowly so trust must be maintained, not just spiked once
	relationship = maxf(0.0, relationship - delta * BOND_DECAY_RATE)
	# my faction vouches for you: if my compatible friends back you, I warm too
	if faction_vouch > 0.0 and not is_backing_you:
		relationship = minf(RELATIONSHIP_MAX, relationship + delta * faction_vouch * FACTION_VOUCH_RATE)
	_update_rank()
	_update_faction_mark()
	trust_display = lerpf(trust_display, clampf(relationship / TRUST_BAR_SCALE, 0.0, 1.0), delta * 4.0)
	_emotion_step(delta)

	# thoughts
	_thought_timer -= delta
	_idle_cycle += delta
	if _idle_cycle >= 3.0:
		_idle_cycle = 0.0
		_idle_pick = (_idle_pick + 1) % 4
	if _thought_timer <= 0.0:
		current_thought = _ambient_thought()
	_murmur(delta)
	_update_label()
	_update_thought_label()
	_update_combat_visuals()

	_hunger_step(delta)
	_auto_work(delta)
	_move(delta)
	_check_stuck(delta)
	_animate_body(delta)

# if we're trying to move but going nowhere, we're snagged — break free
func _check_stuck(delta: float) -> void:
	_stuck_cd -= delta
	if _stuck_cd > 0.0:
		return
	_stuck_cd = 0.6
	var moved := global_position.distance_to(_last_pos)
	_last_pos = global_position
	if Vector2(velocity.x, velocity.z).length() > 0.4 and moved < 0.15:
		_break_free()

func _break_free() -> void:
	# trapped on a fence, a built block wall, or a TREE. Bash destructibles
	# (fence/block) — teepees are walk-through (see teepee.gd). Trees can't be
	# bashed, so the only way past is to route AROUND them, which the random
	# sideways shove failed at (it often just re-charged the same trunk).
	var obstacle: Node3D = null
	var od := 2.2
	for grp in ["fence", "block", "tree"]:
		for f in get_tree().get_nodes_in_group(grp):
			var fn := f as Node3D
			if fn == null or not is_instance_valid(fn):
				continue
			var d := global_position.distance_to(fn.global_position)
			# NO LONGER bash fences/blocks to escape -- members were destroying
			# their OWN tribe's fortress to get unstuck. Walls are now on collision
			# layer 4 which AI doesn't mask (block.gd), so members phase through
			# them and never wedge on one; this recovery is only for terrain steps
			# / each other now. (Kept the loop to find the nearest obstacle to
			# shove away from, just without the destructive take_damage.)
			if d < od:
				od = d
				obstacle = fn
	# push directly AWAY from the nearest obstacle (reliable) plus a
	# perpendicular slide, so we round it instead of grinding into it again.
	var away := Vector3(randf() - 0.5, 0.0, randf() - 0.5)
	if obstacle != null:
		away = global_position - obstacle.global_position
		away.y = 0.0
	if away.length() < 0.01:
		away = Vector3(randf() - 0.5, 0.0, randf() - 0.5)
	away = away.normalized()
	var perp := Vector3(-away.z, 0.0, away.x)
	if randf() < 0.5:
		perp = -perp
	velocity.x += (away.x * 1.5 + perp.x) * move_speed
	velocity.z += (away.z * 1.5 + perp.z) * move_speed
	# a HOP as well as a shove. Wedged against a block course or a terrain step,
	# pushing sideways alone just grinds -- a bit of upward velocity lets a member
	# clear a low obstacle (a single block is ~2m; this clears the first course
	# and terrain lips). Only when grounded, so it can't stack into a rocket.
	if is_on_floor():
		velocity.y = 5.5
	# steer the WANDER target away from the obstacle too, so we don't immediately
	# path back into it (task targets reassert themselves on their own next frame)
	if state == St.WANDER:
		_target = global_position + (away + perp * 0.5).normalized() * randf_range(3.0, 6.0)
		_target.y = global_position.y

# ── tribe members help run the economy themselves: hunt, farm, scout, carve
# clubs. Used to require is_backing_you (the FULL trust threshold) just to
# enter this function at all — which meant even a standing order ("obeyed
# even by the disloyal", per the comment that used to be below) could never
# actually reach a member who hadn't fully bonded yet, despite the comment's
# own claim. Now: a direct standing order is obeyed by anyone who isn't a
# total stranger, and members pick their own work on initiative once they
# trust you at all — you don't have to fully win someone over before they
# start pulling their weight. ──
func _auto_work(delta: float) -> void:
	if is_busy or _leaving:
		return
	# CALLED OVER: stand here a moment. Without this the summons "works" and is
	# still useless -- they arrive, and 3-7s later self-assign a chore and walk
	# off before you've said what you called them for. "Everyone come here" is
	# almost always the setup for a SECOND thing ("...repeat after me"), so the
	# order isn't finished when they arrive; it's finished when you've spoken.
	#
	# This sits ABOVE the standing-order check deliberately. A standing job
	# re-dispatches every 0.5-1.5s and would yank them away roughly instantly --
	# a summons has to outrank it, briefly.
	if _summon_hold > 0.0:
		_summon_hold -= delta
		return
	if relationship <= 0.0:
		return   # a true stranger — hasn't warmed up to you at all yet
	# a STANDING ORDER from you overrides their own AI until the objective
	# is met — obeyed even by members who aren't fully backing you yet
	if _standing_job != "":
		if _standing_target > 0 and _standing_done >= _standing_target:
			_think("Objective met: %s." % _standing_job, 2.5)
			clear_standing()
			return
		_job_cd -= delta
		if _job_cd <= 0.0:
			_job_cd = randf_range(0.5, 1.5)
			_start_job(_standing_job, true)
		return
	# otherwise they pick their own work (but pause if you're up close to order
	# them, OR a formation is called — formation used to do nothing visible
	# most of the time because members picked a fresh chore every 3-7s
	# regardless, so the only moment formation ever applied was the brief gap
	# between tasks. With a formation active, backing members within rally
	# range hold position instead of wandering off to gather/hunt.
	#
	# player_in_range used to pause this with NO timeout — stand near a
	# cluster of wanderers/recruits without feeding or commanding them and
	# they'd freeze in "attending you" mode forever. Now they wait a few
	# seconds for you to actually do something, then give up and go back to
	# business. An explicitly selected member (about to be given an order)
	# still waits indefinitely — that one's a real, deliberate pause.
	if manager != null and manager.selected_member == self:
		_attend_idle_time = 0.0
		return
	if player_in_range:
		_attend_idle_time += delta
		if _attend_idle_time < ATTEND_PATIENCE:
			return
	else:
		_attend_idle_time = 0.0
	if relationship > 0.0 and manager != null and manager.get("formation_kind") != "loose" and _player_node != null:
		if global_position.distance_to(_player_node.global_position) <= FORMATION_RALLY_RANGE:
			return
	_job_cd -= delta
	if _job_cd > 0.0:
		return
	_job_cd = randf_range(3.0, 7.0)
	if manager == null or not manager.has_method("suggest_job"):
		return
	_start_job(manager.suggest_job(self))

func _start_job(job: String, forced: bool = false) -> void:
	if job == "carve":
		_begin_carve()
	elif job == "build":
		begin_build()
	elif job == "":
		return
	elif forced:
		_accept_order(job, false)   # a leader's standing order is obeyed regardless of loyalty
	else:
		give_order(job)             # self-directed work still weighs loyalty/risk

# build a gated palisade ring (fence + teepees + a block fortress wall)
# around the stockpile. offset/stride let a whole-tribe build order actually
# DIVIDE the plan among everyone ordered (member 0 takes segments
# 0,stride,2*stride..., member 1 takes 1,stride+1,...) instead of every
# member racing through the exact same plan from segment 0 — which used to
# mean a whole-tribe "build" order looked like only one member ever did
# anything, while the rest just stood around.
var _build_stride: int = 1

func begin_build(offset: int = 0, stride: int = 1) -> void:
	if manager == null or not manager.has_method("fence_ring_plan"):
		return
	TribeMemory.remember(member_name, "ordered", "You",
		"You told me to help raise the palisade.", "neutral", 0.0)
	is_busy = true
	_task_kind = "build"
	_task_paid = false
	_target_node = null
	_task_food = 0
	_task_mats = 0
	_task_wood = 0
	_task_result = ""
	_build_plan = manager.fence_ring_plan()
	_build_i = offset
	_build_stride = max(1, stride)
	# a full castle plan (fence + teepees + block walls) is ~80 segments —
	# the old 90s cap was tuned for a fence-only ring and meant the timer
	# expired long before a single builder ever reached the block portion.
	# Splitting across a whole-tribe order (stride) cuts each member's share
	# proportionally, but give everyone a generous floor regardless.
	_work_time = 360.0
	state = St.AWAY
	_think("Raising the palisade — leaving gates for the runners!", 2.5)

func _build_step(timed_out: bool, delta: float) -> void:
	if _build_i >= _build_plan.size() or timed_out:
		if _task_result == "":
			_task_result = "palisade raised"
			# a stride-1 run (solo, including an autonomous self-triggered
			# build — see Tribemanager.suggest_job) means THIS member's
			# share covered the entire plan, i.e. the whole fortress is up.
			# A whole-tribe order (stride>1) only covers a slice each, so
			# don't claim completion from those.
			if _build_stride <= 1 and manager and manager.has_method("on_fortress_built"):
				manager.on_fortress_built()
		_begin_return()
		return
	var seg: Dictionary = _build_plan[_build_i]
	var pos: Vector3 = seg["pos"]
	var kind: String = seg.get("kind", "fence")
	# HORIZONTAL distance only — block segments can target y=3.0 (the second
	# course); a ground-walking member can't close that vertical gap, so a
	# full 3D distance_to() here would strand them at the right XZ spot
	# forever, stuck mid-build and never advancing to the next segment.
	var flat := Vector2(global_position.x - pos.x, global_position.z - pos.z)
	if flat.length() > 1.6:
		_steer_to(pos, delta)
	else:
		_halt()
		# yaw/scale are optional on a segment (plain "block"/"teepee" pieces
		# don't carry either) -- default to no rotation and normal size so
		# older/simpler segment kinds are unaffected.
		var seg_yaw: float = float(seg.get("yaw", 0.0))
		var seg_scale: float = float(seg.get("scale", 1.0))
		var placed := false
		if kind == "teepee" and manager and manager.has_method("try_build_teepee"):
			placed = manager.try_build_teepee(pos)
		elif kind == "block" and manager and manager.has_method("try_build_block"):
			placed = manager.try_build_block(pos)
		elif kind == "stair" and manager and manager.has_method("try_build_stair"):
			placed = manager.try_build_stair(pos, seg_yaw, seg_scale)
		elif kind == "roof" and manager and manager.has_method("try_build_roof"):
			placed = manager.try_build_roof(pos, seg_yaw, seg_scale)
		elif kind == "small" and manager and manager.has_method("try_build_small"):
			placed = manager.try_build_small(pos, seg_yaw, seg_scale)
		elif kind == "door" and manager and manager.has_method("try_build_door"):
			placed = manager.try_build_door(pos, seg_yaw, seg_scale)
		elif manager and manager.has_method("try_build_fence"):
			placed = manager.try_build_fence(pos, float(seg["yaw"]))
		if placed:
			_build_i += _build_stride
		else:
			_task_result = "ran out of wood to keep building"
			_begin_return()

var _guard_scan_cd: float = 0.0
var _guard_resync_cd: float = 0.0

# hold the assigned perimeter post; periodically scan for a rival npc getting
# close and engage it via the same _foe mechanism take_hit() uses, so a guard
# is the leader's standing answer to "defend the camp's edge". Also
# periodically re-syncs _target — guards joining/leaving the perimeter
# changes everyone's correct slot, not just whoever's assigned this instant.
func _guard_step(delta: float) -> void:
	_guard_resync_cd -= delta
	if _guard_resync_cd <= 0.0:
		_guard_resync_cd = 2.0
		if manager and manager.has_method("assigned_perimeter_point"):
			_target = manager.assigned_perimeter_point(self)
	var d := global_position.distance_to(_target)
	if d > 1.6:
		_steer_to(_target, delta)
		return
	_halt()
	_guard_scan_cd -= delta
	if _guard_scan_cd <= 0.0:
		_guard_scan_cd = 0.6
		var threat := _nearest_rival_npc(11.0)
		if threat != null:
			_foe = threat
			_chase_timer = CHASE_GIVEUP_TIME

func _nearest_rival_npc(maxd: float) -> Node3D:
	var best: Node3D = null
	var bd := maxd
	for o in get_tree().get_nodes_in_group("npc"):
		var n := o as Node3D
		if n == null or not is_instance_valid(n) or n.get("neutral"):
			continue
		var d := global_position.distance_to(n.global_position)
		if d < bd:
			bd = d
			best = n
	return best

func _begin_carve() -> void:
	is_busy = true
	_task_kind = "carve"
	_task_paid = false
	_target_node = null
	_task_food = 0
	_task_mats = 0
	_task_result = ""
	_work_time = 12.0
	var ang := randf() * TAU
	_target = home_pos + Vector3(cos(ang), 0.0, sin(ang)) * 6.0
	_target.y = home_pos.y
	state = St.AWAY
	_think("Off to find wood for a club...", 2.0)

# ── eat from personal rations first; trusted members can then draw on the
# shared stockpile; starve only if truly nothing is available anywhere ──
func _hunger_step(delta: float) -> void:
	hunger = minf(100.0, hunger + delta * HUNGER_RATE)
	if hunger >= EAT_AT and inv_food > 0:
		inv_food -= 1
		hunger = maxf(0.0, hunger - EAT_RESTORE)
	elif hunger >= EAT_AT and current_rank != "Stranger" \
			and manager and manager.has_method("spend_food"):
		# TRUST-GATED STOCKPILE ACCESS (2026-07-17): previously a member's own
		# ration (inv_food, replenished only by their own gathering) was the
		# ONLY source of food they could ever draw on -- once it ran dry they
		# starved regardless of how much you trusted them, and only the
		# PLAYER could ever touch the shared stockpile. A Stranger hasn't
		# earned that access; anyone Acquaintance rank or better ("level 1"
		# trust -- the first real tier above the untrusted default) now can,
		# the same spend_food() the player's own feeding and FPSPlayer's own
		# survival already use.
		if manager.spend_food(1):
			hunger = maxf(0.0, hunger - EAT_RESTORE)
			TribeMemory.remember(member_name, "self_fed", "You",
				"I helped myself to the stockpile -- you trust me enough for that now.",
				"neutral", 0.0)
	if hunger >= 100.0:
		starve(delta)                       # bond rots, may defect
		hp = maxf(0.0, hp - delta * 2.0)    # and they physically weaken
		if hp <= 0.0:
			die()

func _process(_delta: float) -> void:
	# proximity to player (robust direct distance, no Area3D needed)
	var players := get_tree().get_nodes_in_group("player")
	player_in_range = false
	_player_node = null
	if players.size() > 0:
		var p := players[0] as Node3D
		_player_node = p
		if p and global_position.distance_to(p.global_position) <= interact_range:
			player_in_range = true

	# contribute on E (rising edge)
	var e_down := Input.is_key_pressed(KEY_E)
	var e_just := e_down and not _e_was_down
	_e_was_down = e_down
	if player_in_range and e_just:
		contribute("food")

	# give a single member an order with number keys when near.
	# hold SHIFT to PAY skins (mercenary): they obey regardless of trust.
	# (skipped if this member is your individually-SELECTED one — commands route
	#  through the manager then, so you don't double-order it.)
	var selection_active := manager != null and manager.selected_member != null
	if player_in_range and not is_busy and not selection_active:
		var paid := Input.is_key_pressed(KEY_SHIFT)
		if _key_just(KEY_1): give_order("gather", paid)
		elif _key_just(KEY_2): give_order("hunt", paid)
		elif _key_just(KEY_3): give_order("scout", paid)

func _key_just(code: int) -> bool:
	var down := Input.is_key_pressed(code)
	var was: bool = _keys_down.get(code, false)
	_keys_down[code] = down
	return down and not was

# ── A contribution the player makes. Costs the tribe food, feeds a sense neuron ─
func contribute(kind: String) -> void:
	if manager and manager.has_method("spend_food"):
		if not manager.spend_food(1):
			_think("You've nothing to give. Send us to gather!", 1.8)
			if trust_label:
				trust_label.modulate = Color(1.0, 0.5, 0.3)
			return
	# DE-ESCALATE: if this member is currently fighting the PLAYER specifically
	# (self-defense from take_hit() after being struck), being fed by that same
	# person is a real appeasement act -- clear the standoff instead of letting
	# it grind on. BUG FIXED (2026-07-17): _foe only ever cleared on death,
	# moving >16m away, or the chase-giveup timer expiring -- but feeding
	# requires standing close enough to feed, which is also close enough to
	# keep landing strikes, and every successful strike RESETS that same
	# timer (_chase_timer = CHASE_GIVEUP_TIME in the combat loop). Caught
	# live: a struck member kept attacking indefinitely even while being fed,
	# because the two systems never talked to each other -- feeding had no
	# way to interrupt combat state at all.
	if _foe != null and is_instance_valid(_foe) and _foe.is_in_group("player"):
		_foe = null
		_flee_from = null
		_flee_timer = 0.0
		_chase_timer = 0.0
	match kind:
		"food":   brain.stimulate("SawContribute", 80.0)
		"clear":  brain.stimulate("SawHelpClear", 80.0)
		"defend": brain.stimulate("SawDefend", 80.0)
	feed_count += 1
	_attend_idle_time = 0.0   # real interaction — reset their patience clock
	if trust_label:
		trust_label.modulate = Color(0.3, 1.0, 0.3)
	if anim: anim.pop(0.55)          # a grateful little hop
	_think("Food! (%d given) Thank you." % feed_count, 1.5)
	# MEMORY: this is a moment that matters to them -- they'll speak from it later.
	# Recorded with how it FELT and how it moved trust, not just that it happened.
	TribeMemory.remember(member_name, "fed", "You",
		"You gave me food (%d time%s now). I was %s." % [
			feed_count, "" if feed_count == 1 else "s",
			"hungry" if hunger > 60.0 else "glad of it"],
		"grateful", 0.15)
	print("[%s] fed (%d total), Trust now %.0f" % [member_name, feed_count, brain.get_potential("Trust")])

# ── A betrayal the player commits against this member. Wipes whatever Trust
# they'd built up — the SawBetray->Trust synapse is deliberately strong enough
# (-160) to dominate any positive stimulus landing the same tick, so betrayal
# always wins a same-step conflict rather than being partially offset by it.
# Trust then rebuilds from zero through ordinary positive stimulation — this
# is a one-shot wipe, not a lingering suppression (the brain has no floor for
# negative potential across steps; see the leak-clamp in spikeling.gd's step()).
func betray() -> void:
	brain.stimulate("SawBetray", 80.0)
	betrayed_count += 1
	_attend_idle_time = 0.0
	if trust_label:
		trust_label.modulate = Color(1.0, 0.2, 0.2)
	if anim: anim.pop(0.25)          # a small startled flinch (pop() only supports [0,1], no dedicated hurt anim)
	_think("...you did that to me?", 2.2)
	TribeMemory.remember(member_name, "betrayed", "You",
		"You betrayed me. Whatever trust I had is gone.", "betrayed", -0.9)
	print("[%s] betrayed, Trust now %.0f" % [member_name, brain.get_potential("Trust")])

# ── LLM tie-in: a short, honest description of this member's ACTUAL live
# brain state, meant to be appended to the persona string handed to
# TribeLLM.say_as() (see tribe_talk.gd/_persona() and tribe_chat.gd/_say_to()).
# Previously the LLM only ever saw the static personality label (Steady /
# Wary / ...) and current_rank -- never the real Spikeling neuron state
# underneath it, so two members with the same rank but very different Trust
# potential (one freshly wronged, one steadily built) sounded identical.
# Deliberately NOT overprescriptive: states the numbers/facts and lets the
# model's own tone follow from them, same "hand it the real world, don't ask
# it to be careful" lesson tribe_llm.gd's WORLD constant already relies on.
func brain_snapshot() -> String:
	var trust: float = brain.get_potential("Trust")
	var parts: Array[String] = []
	parts.append("Your trust in the Leader currently sits around %d out of 100." % int(trust))
	if is_backing_you:
		parts.append("You are currently backing them loyally (it took %d real moments of trust to get there)." % follow_fires)
	else:
		parts.append("You are not currently backing them.")
	if betrayed_count > 0:
		parts.append("The Leader has struck you %d time%s. You have not forgotten it." % [
			betrayed_count, "" if betrayed_count == 1 else "s"])
	# ENVIRONMENTAL SENSES (2026-07-17): grounds the conversation in what's
	# actually near this member RIGHT NOW, not just remembered history -- see
	# _sense_environment(). Stated as plain fact for the model to react to in
	# its own voice, same discipline as the rest of this function.
	if sees_raider:
		parts.append("You can see a rival tribesperson nearby right now, and it's putting you on edge.")
	if sees_prey:
		parts.append("There's huntable game in sight nearby.")
	if hears_danger:
		parts.append("You can hear signs of a rival nearby, even though you can't see them.")
	return " ".join(parts)

func _brain_tick() -> void:
	var fired: Array = brain.step()
	if "Follow" in fired:
		follow_fires += 1
		relationship = minf(RELATIONSHIP_MAX, relationship + FOLLOW_FIRE_REL_GAIN)
		_update_rank()
		if follow_fires >= follow_threshold_hits and not is_backing_you:
			is_backing_you = true
			_on_now_backing_you()
	# strengthen trust connections that just co-fired (visible learning)
	brain.learn(1.0, 0.5)

func _update_rank() -> void:
	var new_rank := "Stranger"
	for r in RANKS:
		if relationship >= float(r[1]):
			new_rank = String(r[0])
	if new_rank != current_rank:
		var rose: bool = int(RANK_LOYALTY.get(new_rank, 0)) > int(RANK_LOYALTY.get(current_rank, 0))
		current_rank = new_rank
		if rose:
			if anim: anim.pop(0.9)   # a bigger bounce as the bond deepens
			_think(_rank_thought(current_rank))
		# MEMORY: crossing a rank is how a bond is *remembered* -- both directions.
		# A member who fell from Loyal back to Friend remembers that too.
		TribeMemory.remember(member_name, "bond", "You",
			"My feeling toward you %s to %s." % ["deepened" if rose else "cooled", current_rank],
			"warm" if rose else "wary", 0.25 if rose else -0.25)

# UI hint: how much more relationship trust is needed to reach the next rank.
func relationship_to_next_rank() -> float:
	for i in range(RANKS.size()):
		if String(RANKS[i][0]) == current_rank:
			if i + 1 >= RANKS.size():
				return 0.0
			return maxf(0.0, float(RANKS[i + 1][1]) - relationship)
	return 0.0

# ── thoughts ──
# You could SEE members talking (a thought bubble over every head) but never
# HEAR them: _think() and the ambient thoughts are silent -- only LLM dialogue and
# chorus ever reached TTS. So a camp looked chatty and sounded dead. This speaks
# whatever a member is currently "thinking" when you're close enough to overhear,
# on a long per-member cooldown so a crowd murmurs rather than shouts in unison.
# TribeTTS drops it if a voice is busy or you're out of range, so it self-limits.
const MURMUR_RANGE := 9.0
var _murmur_cd: float = 0.0
func _murmur(delta: float) -> void:
	_murmur_cd -= delta
	if _murmur_cd > 0.0:
		return
	# stagger so ten members don't all come due on the same frame
	_murmur_cd = randf_range(7.0, 15.0)
	if _player_node == null or not is_instance_valid(_player_node):
		return
	if global_position.distance_to(_player_node.global_position) > MURMUR_RANGE:
		return
	var t: String = current_thought.strip_edges()
	if t == "" or t == "..." or t == _last_murmur:
		return
	_last_murmur = t
	TribeTTS.speak(self, t, false)   # non-forced: yields to real dialogue
var _last_murmur: String = ""

func _think(text: String, hold: float = 2.5) -> void:
	current_thought = text
	_thought_timer = hold
	_log_line(text)

## say() = _think() + VOICE. Deliberately a separate method: _think() fires for
## routine barks ("I'm already busy!", "We've no club to hunt with!") several
## times a minute, and having the OS read every one of those aloud would be
## unbearable within about a minute of play. Only lines that are genuinely
## SPEECH -- LLM dialogue, chorus, a Companion's report -- get a voice.
## TribeTTS drops the audio if you're out of earshot or a voice is already busy;
## the text always shows either way.
func say(text: String, hold: float = 5.0, force: bool = false) -> void:
	_think(text, hold)
	TribeTTS.speak(self, text, force)

## Recent lines, so standing near someone shows a short conversation log above
## their head instead of one disappearing line. Capped and time-limited: this
## renders every frame for every member in view, so it stays tiny.
func _log_line(text: String) -> void:
	var t: String = text.strip_edges()
	if t == "" or t == "...":
		return
	if not _speech_log.is_empty() and str((_speech_log[-1] as Dictionary)["text"]) == t:
		return                                   # don't log a repeat of the same line
	_speech_log.append({"text": t, "t": Time.get_ticks_msec() / 1000.0})
	while _speech_log.size() > SPEECH_LOG_MAX:
		_speech_log.pop_front()

func _rank_thought(rank: String) -> String:
	match rank:
		"Acquaintance": return "Maybe this one's alright..."
		"Friend": return "I trust you now, friend."
		"Loyal": return "I'd fight beside you."
		"Devoted": return "Lead us. I'm with you to the end."
		_: return "Who is this?"

func _ambient_thought() -> String:
	var trust_p := brain.get_potential("Trust")
	if _leaving:
		return "Hungry... I'm done here."
	if is_busy:
		return "(off doing %s)" % _task_kind
	if is_backing_you:
		if player_in_range and trust_p > 30.0:
			return "For you, chief, anything."
		if player_in_range:
			return "Your orders, chief?"
		var idle := ["My chief.", "We follow you.", "Strong tribe, strong leader.", "The others trust you too."]
		return idle[_idle_pick]
	if player_in_range and trust_p > 50.0:
		return "Another gift? You're generous."
	if player_in_range:
		return "What do you want, stranger?"
	if relationship < 0.3:
		return "Just another wanderer."
	return "Hm."

func _on_now_backing_you() -> void:
	if trust_label:
		trust_label.modulate = Color(1.0, 0.85, 0.2)
	if anim: anim.pop(0.8)
	print("%s now BACKS you as leader!" % member_name)

# ─────────────────────────────────────────────────────────────────────────────
# ORDERS — accept/refuse by loyalty+courage, then PHYSICALLY march off to do it.
# ─────────────────────────────────────────────────────────────────────────────
## `interrupt` = this came from YOU, out loud, just now. It drops whatever chore
## they'd picked for themselves. Self-directed work (_start_job) leaves it false
## and still queues politely behind whatever's in progress.
func give_order(kind: String, paid: bool = false, interrupt: bool = false) -> bool:
	if is_busy:
		# A DIRECT ORDER FROM THE LEADER OUTRANKS A SELF-ASSIGNED CHORE.
		#
		# is_busy is the first gate in this function, and members self-assign work
		# every 3-7s while each task runs 10-30s -- so is_busy is true almost
		# permanently. Anything you said was answered with "I'm already busy!"
		# by nearly everyone, nearly always. "Ka, get berries" only ever worked
		# by catching Ka in the gap between chores; the Companion "not listening"
		# was the same wall with better luck on the other side.
		#
		# That isn't a loyalty system, it's a coin flip on timing. Loyalty decides
		# whether they OBEY -- being mid-errand shouldn't decide whether they even
		# HEARD you. The chore was their own idea; you are their leader.
		#
		# The loyalty check below still runs: interrupting is about is_busy, not
		# obedience, so a wary stranger can and will still tell you no.
		if interrupt or kind == "come":
			_abandon_task()
		else:
			_think("I'm already busy!", 1.5)
			return false
	if kind == "hunt" and (manager == null or not manager.has_method("clubs_available") or manager.clubs_available() <= 0):
		_think("We've no club to hunt with!", 1.8)
		return false
	# PAID: skins buy the work outright, no matter how little they trust you
	if paid:
		var cost: int = ORDER_COST.get(kind, 99)
		if manager and manager.has_method("spend_materials") and manager.spend_materials(cost):
			_think("Skins? ...Fine. Just this once. Business.", 1.8)
			_accept_order(kind, true)
			return true
		_think("You can't pay me enough skins for that.", 1.8)
		return false
	# UNPAID: they weigh loyalty + courage against the risk
	var loyalty: int = RANK_LOYALTY.get(current_rank, 0)
	var courage: int = int(PERSONALITIES.get(personality, PERSONALITIES["Steady"])["courage"])
	var drive: int = ORDER_BASE + loyalty + courage
	var risk: int = ORDER_RISK.get(kind, 999)
	if drive >= risk:
		_accept_order(kind, false)
		return true
	_refuse_order(kind)
	return false

func _accept_order(kind: String, paid: bool = false) -> void:
	is_busy = true
	_task_kind = kind
	_task_paid = paid
	_work_time = 12.0          # timeout: give up the chase/search after this
	_target_node = null
	_task_food = 0
	_task_mats = 0
	_task_wood = 0
	_task_result = ""
	match kind:
		"come":
			# "everyone come here" -- walk to the leader and STAY. Unlike every
			# other task this has no work to do at the far end and does NOT
			# _begin_return() on arrival (see St.AWAY): returning home is the
			# opposite of what was asked. Handled in the state machine's "come"
			# branch, which drops them into WANDER right where you're standing.
			var pl := get_tree().get_first_node_in_group("player") as Node3D
			if pl == null:
				is_busy = false
				return
			_work_time = 30.0        # a long walk across camp is fine; forever isn't
			# Scatter the arrival points, or ten members converge on one pixel and
			# spend the whole time shoving each other (_apply_separation fights it).
			# The ring stays inside interact_range (3.5) so everyone who answers
			# lands close enough to TALK to -- a summons that parks people at 5m
			# is out of chat range and half the point of calling them is gone.
			#
			# The offset is stored, not the destination: St.AWAY re-aims at
			# player_position + _come_offset EVERY FRAME. A snapshot taken here
			# would send them to where you were STANDING when you spoke -- and
			# you're going to keep walking while they cross camp, because that's
			# what anyone does after calling someone over. They'd trail to an
			# empty patch of dirt and stop, which from your side is indis-
			# tinguishable from being ignored. Keeping the offset fixed (rather
			# than re-rolling it) is what stops the ring from jittering.
			var a: float = randf() * TAU
			var r: float = 1.4 + randf() * 1.7      # 1.4 .. 3.1
			_come_offset = Vector3(cos(a) * r, 0.0, sin(a) * r)
			_target = pl.global_position + _come_offset
			_target_node = null
			_think("Coming.", 2.0)
		"gather":
			_target_node = _nearest_food_source()
			if _target_node:
				_search_streak = 0   # something real was in sight -- the outward drift resets
				_think("Berries! On my way.", 2.0)
			else:
				_begin_fallback("No berries close by... I'll look around.")
		"hunt":
			if manager and manager.has_method("reserve_club") and manager.reserve_club():
				_has_club = true
				_target_node = _nearest_animal()
				if _target_node:
					_search_streak = 0
					_think("Club in hand — I'll run it down.", 2.0)
				else:
					_begin_fallback("No animals around... I'll search.")
			else:
				# no club free after all — stand down
				is_busy = false
				_think("No club free to hunt!", 1.8)
				return
		"scout":
			_work_time = 70.0   # camps can be a long trek away
			var camp = manager.nearest_undiscovered_camp(global_position) if (manager and manager.has_method("nearest_undiscovered_camp")) else null
			_scouted_camp = camp
			if camp != null and is_instance_valid(camp):
				_target = (camp as Node3D).global_position
				_target_node = null
				_think("Scouting out a camp...", 2.0)
			else:
				_begin_fallback("Nothing new to scout nearby.")
		"wood":
			_work_time = 22.0   # trees can be a hike away; allow the round trip
			_target_node = _nearest_tree()
			if _target_node:
				_search_streak = 0
				_think("Off to chop wood.", 2.0)
			else:
				_begin_fallback("No trees nearby to chop...")
		"guard":
			_work_time = 999999.0   # indefinite — holds the post until reassigned
			# is_busy/_task_kind are already set above, before this match runs,
			# so we're correctly counted as a guard by the time our own slot
			# is computed (and by anyone else assigned in the same frame)
			if manager and manager.has_method("assigned_perimeter_point"):
				_target = manager.assigned_perimeter_point(self)
			else:
				_target = home_pos
			_target_node = null
			_think("Taking up a post on the perimeter.", 2.0)
		"recruit":
			_work_time = 35.0
			if manager == null or manager.food < RECRUIT_FOOD_COST:
				# realize we're short on food and go gather some first — once
				# that gather completes, _complete_task() re-issues this order
				_pending_recruit = true
				is_busy = false
				_think("Not enough food to recruit — I'll gather some first.", 2.2)
				give_order("gather", paid)
				return
			_target_node = _nearest_neutral()
			if _target_node:
				_search_streak = 0
				_think("Off to win over a wanderer...", 2.0)
			else:
				_begin_fallback("No wanderers nearby to recruit...")
	state = St.AWAY
	# SPEAK the acknowledgement, don't just think it. "so I know if they are doing
	# it" -- the match above set a task-specific line ("Berries! On my way."); this
	# voices it (heard if you're close, once audio's routed) and flashes it up top
	# so you get confirmation the order landed even across camp.
	say(current_thought, 2.5)
	if manager and manager.has_method("flash_order_ack"):
		manager.flash_order_ack(member_name, kind, true)
	print("[%s] ACCEPTED order: %s (rank %s)" % [member_name, kind, current_rank])

# Search for work (used by scout, or when nothing qualifying is in sight).
# Pushes progressively FURTHER from the member's CURRENT position with each
# consecutive failure (see _search_streak above) -- not a fixed ring around
# home_pos, which just meant re-checking the same stripped-bare radius over
# and over. A long enough streak is also this member's cue that they're
# genuinely far out and a real candidate to found a new outpost stockpile.
func _begin_fallback(msg: String) -> void:
	_search_streak += 1
	if _search_streak >= EXPANSION_SEARCH_STREAK and manager and manager.has_method("found_outpost"):
		if manager.found_outpost(global_position):
			_search_streak = 0
			TribeMemory.remember(member_name, "founded_outpost", "You",
				"I'd wandered far enough from camp that I raised a new stockpile right here.",
				"proud", 0.05)
			_think("New ground -- a stockpile goes here!", 2.5)
			return
	var radius: float = minf(SEARCH_RADIUS_MAX,
		SEARCH_RADIUS_BASE + float(_search_streak - 1) * SEARCH_RADIUS_GROWTH)
	var ang := randf() * TAU
	_target = global_position + Vector3(cos(ang), 0.0, sin(ang)) * radius
	_target.y = home_pos.y
	_target_node = null
	_think(msg, 2.2)

const DEPOSIT_RANGE := 3.0   # how close to the stockpile counts as "back" — generous on
							  # purpose so a crowd converging on one exact point doesn't
							  # perpetually jostle for position via separation forces

func _begin_return() -> void:
	if _task_kind == "raid":
		# Raid members walk home so they aren't left stranded at the enemy camp.
		state = St.RETURN
		var sp := get_tree().get_first_node_in_group("stockpile")
		_target = (sp as Node3D).global_position if sp else home_pos
		return
	# For all other tasks: deposit loot in place and wander nearby.
	# Members should stay near where they worked, not sprint back to the player.
	state = St.WANDER
	if is_busy:
		_complete_task()
	# If _complete_task() triggered a new order (e.g. recruit-after-gather),
	# don't clobber its destination.
	if not is_busy:
		var ang := randf() * TAU
		_target = global_position + Vector3(cos(ang), 0.0, sin(ang)) * randf_range(2.0, 4.0)
		_target.y = global_position.y

func _do_gather() -> void:
	if _target_node and _target_node.has_method("harvest"):
		var got: int = _target_node.harvest(4.0)
		_task_food += got
		_task_result = "berries x%d" % got

func _do_catch() -> void:
	if _target_node and _target_node.has_method("killed"):
		var loot: Dictionary = _target_node.killed()
		_task_food += int(loot.get("food", 0))
		_task_mats += int(loot.get("skins", 0))
		_task_result = "%s: %d meat, %d skins" % [loot.get("name", "game"), int(loot.get("food", 0)), int(loot.get("skins", 0))]

## Is `n` already someone ELSE's active work target? Previously every
## _nearest_*() picker chose the globally nearest candidate with no regard
## for whether another member had already claimed it -- two gatherers would
## dogpile the same bush, two hunters chase the same animal, two woodcutters
## queue up on the same tree, two recruiters walk up to the same wanderer.
## Members already expose _target_node externally (see how _maybe_share_food
## reads "hunger"/"inv_food" the same way), so this needs no new shared
## state -- just a live check against the roster before committing to a node.
func _is_claimed(n: Node3D) -> bool:
	for o in get_tree().get_nodes_in_group("tribe"):
		if o == self or not is_instance_valid(o):
			continue
		if not ("member_name" in o):
			continue   # not a real tribemember (e.g. a dog) -- can't claim a work node
		if o.get("_target_node") == n:
			return true
	return false

## VISION-GATED (2026-07-20): a picker used to consider EVERY matching node in
## the whole world, however far away -- a member could get sent on a
## half-map trek for the globally-nearest bush while a dozen closer ones sat
## unseen behind them because they simply hadn't been compared against
## distance at all. Real work should come from what's actually in sight
## (SIGHT_RADIUS -- the same radius _sense_environment() already uses for
## sees_raider/sees_prey); if nothing qualifying is within it, the picker
## returns null and the caller falls to _begin_fallback(), which now SEARCHES
## outward instead of idling (see below) -- that's the intended fallback,
## not a bug to route around by silently widening the search radius here.
func _nearest_food_source() -> Node3D:
	var best: Node3D = null
	var bd := INF
	for b in get_tree().get_nodes_in_group("food_source"):
		var n := b as Node3D
		if n and is_instance_valid(n) and n.has_method("harvest") and float(n.amount) >= 1.0 \
				and not _is_claimed(n):
			var d := global_position.distance_to(n.global_position)
			if d <= SIGHT_RADIUS and d < bd:
				bd = d
				best = n
	return best

func _nearest_animal() -> Node3D:
	var best: Node3D = null
	var bd := INF
	for a in get_tree().get_nodes_in_group("animal"):
		var n := a as Node3D
		if n and is_instance_valid(n) and not _is_claimed(n):
			var d := global_position.distance_to(n.global_position)
			if d <= SIGHT_RADIUS and d < bd:
				bd = d
				best = n
	return best

func _nearest_neutral() -> Node3D:
	var best: Node3D = null
	var bd := INF
	for n in get_tree().get_nodes_in_group("neutral"):
		var nn := n as Node3D
		if nn and is_instance_valid(nn) and not _is_claimed(nn):
			var d := global_position.distance_to(nn.global_position)
			if d <= SIGHT_RADIUS and d < bd:
				bd = d
				best = nn
	return best

# spend tribe food to win over the wanderer we walked up to. If the food
# disappeared between accepting the order and arriving (someone else spent
# it), fall back to gathering more instead of recruiting empty-handed.
func _do_recruit() -> void:
	if manager == null or not is_instance_valid(_target_node):
		_task_result = "the wanderer was gone"
		return
	if manager.food < RECRUIT_FOOD_COST:
		_pending_recruit = true
		_task_result = "not enough food — gathering more"
		return
	manager.spend_food(RECRUIT_FOOD_COST)
	manager.recruit_neutral(_target_node)
	_task_result = "recruited a new member!"
	if manager.has_method("notify"):
		# One of YOUR members recruited a wanderer -> "Your Tribe" box.
		if manager.has_method("notify_cat"):
			manager.notify_cat("tribe", "%s won over a wanderer using food." % member_name)
		else:
			manager.notify("%s won over a wanderer using food." % member_name)

func _nearest_tree() -> Node3D:
	var best: Node3D = null
	var bd := INF
	for t in get_tree().get_nodes_in_group("tree"):
		var n := t as Node3D
		if n and is_instance_valid(n) and n.has_method("chop") and not _is_claimed(n):
			var d := global_position.distance_to(n.global_position)
			if d <= SIGHT_RADIUS and d < bd:
				bd = d
				best = n
	return best

func _retarget() -> Node3D:
	match _task_kind:
		"hunt": return _nearest_animal()
		"gather": return _nearest_food_source()
		"wood": return _nearest_tree()
		"recruit": return _nearest_neutral()
	return null

func _refuse_order(kind: String) -> void:
	match kind:
		"hunt":  say("Hunt? I don't trust you enough for that.", 2.5)
		"scout": say("Scout a rival tribe? No. Too dangerous.", 2.5)
		_:       say("...no.", 2.0)
	if manager and manager.has_method("flash_order_ack"):
		manager.flash_order_ack(member_name, kind, false)
	_play_refuse_anim()
	print("[%s] REFUSED order: %s (rank %s — not loyal enough)" % [member_name, kind, current_rank])
	# is_busy/state are untouched by a refusal — they just resume whatever
	# they were already doing (auto-work picks back up next cycle).

# a quick head-shake "no" — animates the Face child's LOCAL rotation, not
# the body's own (which steering/movement code drives every frame), so it
# can't fight with movement and reads as a head shake on top of it
func _play_refuse_anim() -> void:
	var face := get_node_or_null("Face")
	if face == null:
		return
	var base_yaw: float = face.rotation.y
	var tw := create_tween()
	tw.tween_property(face, "rotation:y", base_yaw + 0.4, 0.1)
	tw.tween_property(face, "rotation:y", base_yaw - 0.4, 0.14)
	tw.tween_property(face, "rotation:y", base_yaw + 0.22, 0.1)
	tw.tween_property(face, "rotation:y", base_yaw, 0.1)

# generic "go to a fixed spot, work a while, come home" — used by RAIDS
func dispatch_to(pos: Vector3, kind: String, work: float) -> void:
	is_busy = true
	_task_kind = kind
	_task_paid = false
	_work_time = work
	_target = pos
	_target_node = null
	_task_food = 0
	_task_mats = 0
	_task_wood = 0
	_task_result = ""
	state = St.AWAY

# called by _move()'s formation-recall check to pull a member out of a
# self-directed chore immediately, instead of formation only ever blocking
# the NEXT chore from starting (which meant anyone already mid-task at the
# moment formation was called just finished it like nothing happened — a
# gather/hunt round trip easily takes 10-30s, so formation looked broken).
# Cleanly releases anything _complete_task() would have, since we're
# bypassing normal completion.
func _abort_chore_for_formation() -> void:
	if _has_club and manager and manager.has_method("release_club"):
		manager.release_club()
		_has_club = false
	is_busy = false
	_task_kind = ""
	_target_node = null
	state = St.WANDER

## Drop whatever you're doing, cleanly. Unlike _complete_task() this banks
## NOTHING -- you never got the haul home, so partial progress is lost. That's
## honest: the cost of being called away mid-chop is the chop.
##
## THE CLUB IS THE WHOLE REASON THIS IS A FUNCTION. A hunt calls
## manager.reserve_club(), and the club only ever goes back to the rack via
## release_club() in _complete_task(). Cancel a hunt without this and the club
## is gone for the rest of the run -- clubs_available() drops by one, silently
## and permanently, until nobody can hunt at all. Interrupting a hunter would
## quietly break hunting.
func _abandon_task() -> void:
	if _has_club and manager and manager.has_method("release_club"):
		manager.release_club()
		_has_club = false
	is_busy = false
	_task_kind = ""
	_target_node = null
	_task_food = 0
	_task_mats = 0
	_task_wood = 0
	_task_result = ""

func _complete_task() -> void:
	var k := _task_kind
	var got_food := _task_food
	var got_mats := _task_mats
	var got_wood := _task_wood
	is_busy = false
	_task_kind = ""
	_target_node = null
	if _has_club and manager and manager.has_method("release_club"):
		manager.release_club()   # return the club to the rack
		_has_club = false
	# count progress toward a standing leader objective
	if _standing_job == k:
		match k:
			"wood": _standing_done += got_wood
			"gather": _standing_done += got_food
			"hunt": _standing_done += got_food + got_mats
			"scout": _standing_done += 1
			"recruit":
				if _task_result == "recruited a new member!":
					_standing_done += 1
	if k == "raid":
		return   # the manager resolves raid loot, not the member
	if k == "carve":
		if manager and manager.has_method("craft_club") and manager.craft_club():
			_think("Made a fresh club.", 2.0)
			print("[%s] carved a club" % member_name)
		else:
			_think("Not enough wood for a club...", 2.0)
		return

	if k == "scout":
		# report on the camp we actually walked up to and scouted — NOT
		# whatever's nearest now that we're back home (that was the bug:
		# discover_near(global_position) here used to fire with our
		# CURRENT position, which is home, so it discovered whatever camp
		# happened to be closest to HOME instead of the one we scouted)
		if _scouted_camp != null and is_instance_valid(_scouted_camp) and _scouted_camp.has_method("discover"):
			_scouted_camp.discover()
			var nm: String = _scouted_camp.tribe_name if "tribe_name" in _scouted_camp else "a camp"
			var st: int = _scouted_camp.strength if "strength" in _scouted_camp else 0
			_task_result = "scouted the %s (strength %d)" % [nm, st]
			if manager and manager.has_method("notify"):
				# Your scout-member reporting back -> "Your Tribe" box.
				if manager.has_method("notify_cat"):
					manager.notify_cat("tribe", "%s reports back: found the %s, strength %d!" % [member_name, nm, st])
				else:
					manager.notify("%s reports back: found the %s, strength %d!" % [member_name, nm, st])
		else:
			_task_result = "found nothing to scout"
		_scouted_camp = null

	# keep personal rations first, then drop the SURPLUS in your stockpile
	if _task_food > 0:
		var room := maxi(0, RATION_RESERVE - inv_food)
		var keep := mini(room, _task_food)
		inv_food += keep
		var surplus := _task_food - keep
		if surplus > 0 and manager and manager.has_method("add_food"):
			manager.add_food(surplus)
		contrib_food += _task_food
	if _task_mats > 0 and manager and manager.has_method("add_materials"):
		manager.add_materials(_task_mats)
	if _task_wood > 0 and manager and manager.has_method("add_wood"):
		manager.add_wood(_task_wood)
		contrib_wood += _task_wood
	_task_wood = 0
	# loyalty only grows from work done WILLINGLY — paid mercenaries earn nothing
	if not _task_paid and (_task_food > 0 or _task_mats > 0 or _task_wood > 0 or k == "scout"):
		relationship = minf(RELATIONSHIP_MAX, relationship + WORK_REL_GAIN)
		_update_rank()
	_task_paid = false

	# a well-supplied camp lets members forge better gear from looted materials
	_maybe_upgrade_gear()

	var msg: String = _task_result if _task_result != "" else "nothing this time"
	_think("Done. %s" % msg, 3.0)
	print("[%s] COMPLETED %s -> %s" % [member_name, k, msg])
	order_completed.emit(self, k, _task_result)

	# the food we just gathered might be enough now — try the recruit again
	if k == "gather" and _pending_recruit:
		_pending_recruit = false
		give_order("recruit", false)
	elif k == "recruit":
		_pending_recruit = false

func _scout_report() -> String:
	var strength: String = ["weak", "moderate", "strong"][randi() % 3]
	var loot: String = ["lots of skins", "little of value", "stockpiled food"][randi() % 3]
	return "rival tribe is %s, has %s" % [strength, loot]

# ── raid / combat helpers (used by the manager) ──
func get_might() -> int:
	var p: Dictionary = PERSONALITIES.get(personality, PERSONALITIES["Steady"])
	# gear counts toward raid might too — weapon adds punch, armor adds staying power
	var gear_might: int = weapon * 3 + armor * 2
	return int(p["might"]) + int(RANK_LOYALTY.get(current_rank, 0) / 10.0) + int(p["courage"] / 10.0) + gear_might

# Forge a gear upgrade when the tribe has looted-material surplus to spare.
# Spends the shared `materials` pool (skins/hides — the camp's common crafting
# stock). Cheap and occasional: called only on task completion, gated by cost
# and a dice roll, so gear creeps up over a session rather than spiking. Weapon
# and armor alternate so members don't end up lopsided. Low-risk: fully guarded,
# does nothing if the manager can't spend.
const _GEAR_MAT_COST := 4
func _maybe_upgrade_gear() -> void:
	if manager == null:
		return
	if weapon >= WEAPON_TIERS.size() - 1 and armor >= ARMOR_TIERS.size() - 1:
		return
	if randf() > 0.35:
		return
	if not manager.has_method("spend_materials") or not ("materials" in manager):
		return
	if int(manager.materials) < _GEAR_MAT_COST:
		return
	# raise whichever track is lower (armor wins ties, so survivability comes first),
	# respecting each track's ceiling
	var wmax: bool = weapon >= WEAPON_TIERS.size() - 1
	var amax: bool = armor >= ARMOR_TIERS.size() - 1
	var raise_weapon: bool
	if amax:
		raise_weapon = true
	elif wmax:
		raise_weapon = false
	else:
		raise_weapon = weapon < armor
	if not manager.spend_materials(_GEAR_MAT_COST):
		return
	if raise_weapon:
		weapon += 1
		_think("Forged a better weapon.", 2.0)
	else:
		armor += 1
		_think("Fashioned some armor.", 2.0)

# ── starvation: called every frame by the manager while the tribe has no food ──
func starve(delta: float) -> void:
	relationship = maxf(0.0, relationship - delta * STARVE_DECAY_RATE)
	_update_rank()
	if is_backing_you and relationship < DEFECT_THRESHOLD:
		is_backing_you = false
		_leaving = true
		var away := Vector3(randf() - 0.5, 0.0, randf() - 0.5)
		if away.length() < 0.01:
			away = Vector3(1, 0, 0)
		home_pos = global_position + away.normalized() * 22.0
		home_pos.y = global_position.y
		_target = home_pos
		_think("Starving... I follow you no more.", 3.0)
		print("[%s] is starving and LEAVES the tribe." % member_name)

# ─────────────────────────────────────────────────────────────────────────────
# THE STEERING — move_and_slide toward a target on the XZ plane, with gravity.
# ─────────────────────────────────────────────────────────────────────────────
func _move(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = 0.0

	# fleeing a fight we're badly outnumbered in — overrides everything else
	if _flee_timer > 0.0:
		_flee_timer -= delta
		var away := global_position
		if _flee_from != null and is_instance_valid(_flee_from):
			away = global_position - (_flee_from as Node3D).global_position
		away.y = 0.0
		if away.length() < 0.01:
			away = Vector3(randf() - 0.5, 0, randf() - 0.5)
		_steer_to(global_position + away.normalized() * 6.0, delta, move_speed * 1.3)
		_apply_separation()
		move_and_slide()
		return

	# FORMATION RECALL: a non-loose formation used to only stop the NEXT
	# self-directed chore from starting — anyone already mid-task when you
	# called formation just finished it like nothing happened (a gather/hunt
	# round trip easily runs 10-30s), which read as "formation gets
	# interrupted, they just go gather". Now it actively pulls a member out
	# of a self-chosen chore (gather/hunt/wood/scout/carve) the moment it's
	# called. It does NOT cancel a standing order (an explicit recent
	# command from you), guard duty, or building — those stay deliberate.
	if _foe == null and _flee_timer <= 0.0 and relationship > 0.0 and not _leaving \
			and _standing_job == "" and manager != null:
		var fkind = manager.get("formation_kind")
		if fkind != null and fkind != "loose" and _player_node != null \
				and global_position.distance_to(_player_node.global_position) <= FORMATION_RALLY_RANGE \
				and state == St.AWAY \
				and _task_kind in ["gather", "hunt", "wood", "scout", "carve"]:
			_abort_chore_for_formation()

	# proactive BASE DEFENSE: rush a raider near the stockpile even if it
	# hasn't personally hit us yet — before this, members only fought back
	# reactively (take_hit), so a siege could walk right up while everyone
	# kept gathering berries until they got struck.
	#
	# Also: notice ANY rival npc within range, anywhere — not just raiders
	# near the stockpile. npc.gd's _skirmish() has always done this (it's
	# the "when npcs cross paths they fight" rule); loyal members only got
	# the base-specific case, so they'd walk right past a rival out in the
	# world without reacting. Base threats still take priority when both
	# are present — defending the camp matters more than a chance encounter.
	if _foe == null and relationship > 0.0 and not _leaving:
		# a non-loose formation is a battle-ready stance, not just a shape to
		# stand in — scan faster and further so a formation actually reacts
		# to a threat quickly, instead of moving at the same idle pace as
		# someone who happens to be guarding the stockpile alone
		var in_formation: bool = manager != null and manager.get("formation_kind") != "loose"
		_base_defense_cd -= delta
		if _base_defense_cd <= 0.0:
			_base_defense_cd = randf_range(0.2, 0.4) if in_formation else randf_range(0.6, 1.0)
			var scan_range := 18.0 if in_formation else 12.0
			var threat := _nearest_base_threat()
			if threat == null:
				threat = _nearest_rival_npc(scan_range)
			if threat != null:
				_foe = threat
				_chase_timer = CHASE_GIVEUP_TIME

	# defending against an attacker — overrides whatever task was in progress
	# until they're dead, flee, or we give up chasing them
	if _foe != null:
		if not is_instance_valid(_foe) or global_position.distance_to((_foe as Node3D).global_position) > 16.0:
			_foe = null
		else:
			_defend_attack_cd = maxf(0.0, _defend_attack_cd - delta)
			_throw_cd = maxf(0.0, _throw_cd - delta)
			var fp: Vector3 = (_foe as Node3D).global_position
			var fd := global_position.distance_to(fp)
			if fd < 1.7:
				_strike_foe()
				_chase_timer = CHASE_GIVEUP_TIME
			elif fd < THROW_RANGE and _try_throw_at(_foe):
				_chase_timer = CHASE_GIVEUP_TIME
			else:
				# can't catch them — give up after a while instead of
				# chasing across the whole map, same patience npc.gd has
				_chase_timer -= delta
				if _chase_timer <= 0.0:
					_foe = null
				else:
					_steer_to(fp, delta, move_speed * 1.4)
			if _foe != null:
				_apply_separation()
				move_and_slide()
				return

	match state:
		St.AWAY:
			_work_time -= delta
			var timed_out := _work_time <= 0.0
			# our target may have vanished (eaten, felled, or another worker got it)
			if _target_node != null and not is_instance_valid(_target_node):
				_target_node = _retarget()
			if _target_node != null:
				var d := global_position.distance_to(_target_node.global_position)
				var reach := CATCH_RANGE if _task_kind == "hunt" else (2.4 if (_task_kind == "wood" or _task_kind == "recruit") else HARVEST_RANGE)
				if d > reach:
					var chase := 3.6 if _task_kind == "hunt" else move_speed   # outrun fleeing prey
					_steer_to(_target_node.global_position, delta, chase)
					if timed_out:
						_begin_return()
				elif _task_kind == "hunt":
					_do_catch()
					_begin_return()
				elif _task_kind == "gather":
					_do_gather()
					_begin_return()
				elif _task_kind == "recruit":
					_do_recruit()
					_begin_return()
				elif _task_kind == "wood":
					# stand and chop until the tree comes down
					_halt()
					_face(_target_node.global_position, delta)
					_chop_cd -= delta
					if _chop_cd <= 0.0:
						_chop_cd = 0.5
						var w: int = _target_node.chop(2)
						if w > 0:
							_task_wood += w
							_task_result = "wood x%d" % w
							_begin_return()
					if timed_out and _task_wood == 0:
						_begin_return()
			elif _task_kind == "build":
				# walk the gated ring, raising a fence at each non-gate waypoint
				_build_step(timed_out, delta)
			elif _task_kind == "guard":
				# hold an assigned post on the leader's perimeter, indefinitely —
				# only ends via reassignment, never times out or auto-returns
				_guard_step(delta)
			elif _task_kind == "come":
				# RE-AIM at the leader every frame. You keep walking after calling
				# people over; a destination snapshotted when you spoke sends them
				# to bare ground and looks exactly like being ignored.
				if _player_node != null:
					_target = _player_node.global_position + _come_offset
					_target.y = global_position.y
				# arrive and STOP. Every other fixed-spot task calls _begin_return()
				# here; "come here" must not — walking home is precisely what you
				# didn't ask for. Drop straight into WANDER so they mill about
				# where you're standing and stay available for the next order.
				if _arrived(_target) or timed_out:
					_halt()
					is_busy = false
					_task_kind = ""
					state = St.WANDER
					_summon_hold = SUMMON_HOLD   # stand here; you called for a reason
					if not timed_out:
						_think("You called?", 2.5)
				else:
					_steer_to(_target, delta)
			else:
				# fixed spot (scout / fallback): go there, then head home.
				# scouts stop at scouting range so they don't march into the camp.
				var scout_close := _task_kind == "scout" and global_position.distance_to(_target) <= 26.0
				if _arrived(_target) or timed_out or scout_close:
					_halt()
					_begin_return()
				else:
					_steer_to(_target, delta)
		St.RETURN:
			if global_position.distance_to(_target) <= DEPOSIT_RANGE:
				_halt()
				state = St.WANDER
				if is_busy:
					_complete_task()
			else:
				_steer_to(_target, delta)
		_:
			_idle_move(delta)

	_apply_separation()
	move_and_slide()

# keep personal space from other members so a tribe reads as people, not a blob
# (the full O(n^2) neighbor scan is expensive — recompute the push a few
#  times a second and coast on the cached value in between; a soft local
#  force like this doesn't need to update every single physics frame)
var _separation_cd: float = 0.0
var _separation_cache: Vector3 = Vector3.ZERO

func _apply_separation() -> void:
	_separation_cd -= get_physics_process_delta_time()
	if _separation_cd <= 0.0:
		_separation_cd = randf_range(0.12, 0.18)  # jittered so members don't all rescan the same frame
		var push := Vector3.ZERO
		for o in get_tree().get_nodes_in_group("tribe"):
			if o == self or not is_instance_valid(o):
				continue
			var d := global_position - (o as Node3D).global_position
			d.y = 0.0
			var dist := d.length()
			if dist > 0.01 and dist < 1.7:
				push += d.normalized() * (1.7 - dist)
		_separation_cache = push
	if _separation_cache.length() > 0.001:
		velocity.x += _separation_cache.x * move_speed
		velocity.z += _separation_cache.z * move_speed

var _formation_index: int = 0
var _formation_cd: float = 0.0

# how many slots back of me in manager.members are also backing the player —
# used as a stable formation index. Recomputed on a timer, not every frame.
# Formation used to only ever apply to fully-backing members (is_backing_you,
# the FULL trust threshold) — most of a tribe never crosses that, so
# formation only ever moved a handful of people. Anyone who trusts you at
# all (relationship > 0, same bar _auto_work uses) now participates.
func _compute_formation_index() -> int:
	if manager == null or not ("members" in manager):
		return 0
	var idx := 0
	for m in manager.members:
		if m == self:
			return idx
		if is_instance_valid(m) and float(m.get("relationship")) > 0.0:
			idx += 1
	return idx

func _count_backers() -> int:
	if manager == null or not ("members" in manager):
		return 1
	var c := 0
	for m in manager.members:
		if is_instance_valid(m) and float(m.get("relationship")) > 0.0:
			c += 1
	return max(1, c)

func _idle_move(delta: float) -> void:
	# loyal members trail the leader; warming members approach; others wander.
	if not _leaving and _player_node != null:
		var dp := global_position.distance_to(_player_node.global_position)
		var fkind: String = manager.formation_kind if (manager and "formation_kind" in manager) else "loose"
		# Members move toward the player only when a formation pulls them in.
		# Removing the old distance-based trailing so members stay near where
		# they worked instead of running back to the player after every task.
		var formation_active: bool = fkind != "loose" and relationship > 0.0 and dp <= FORMATION_RALLY_RANGE
		if formation_active:
			var target_pos := _stand_near(_player_node.global_position)
			if fkind != "loose" and manager and manager.has_method("formation_offset"):
				_formation_cd -= delta
				if _formation_cd <= 0.0:
					_formation_cd = 1.0
					_formation_index = _compute_formation_index()
				var facing := -_player_node.global_transform.basis.z
				var off: Vector3 = manager.formation_offset(_formation_index, _count_backers(), fkind, facing)
				target_pos = _player_node.global_position + facing.normalized() * -3.0 + off
				target_pos.y = global_position.y
			_steer_to(target_pos, delta)
			return
		if player_in_range:
			_face(_player_node.global_position, delta)
			if relationship > 0.1 and dp > STANDOFF:
				_steer_to(_stand_near(_player_node.global_position), delta)
			else:
				_halt()
			return
	_wander(delta)

# where I drift around when idle — my emergent tribe's center if I have one,
# otherwise my own home spot. This is what makes compatible members CLUSTER.
func _anchor() -> Vector3:
	return faction_centroid if faction_id >= 0 else home_pos

func _wander(delta: float) -> void:
	if _wander_pause > 0.0:
		_wander_pause -= delta
		_halt()
		_idle_fidget(delta)
		return
	var center := _anchor()
	var flat := global_position - center
	flat.y = 0.0
	if flat.length() > wander_radius + 3.0:
		# strayed from my tribe — head back toward the group
		_target = center
	elif _arrived(_target):
		var ang := randf() * TAU
		var r := randf() * wander_radius
		_target = center + Vector3(cos(ang), 0.0, sin(ang)) * r
		_target.y = center.y
		_wander_pause = randf_range(0.6, 2.0)
		_halt()
		return
	_steer_to(_target, delta)
	_face(_target, delta)

func _idle_fidget(delta: float) -> void:
	_fidget_cd -= delta
	if _fidget_cd > 0.0:
		return
	_fidget_cd = randf_range(8.0, 20.0)
	# pick something nearby to glance at: player first, then nearest member
	var glance_target: Node3D = null
	if _player_node != null and global_position.distance_to(_player_node.global_position) < 18.0:
		glance_target = _player_node
	else:
		var best_d: float = 12.0
		for o in get_tree().get_nodes_in_group("tribe"):
			if o == self or not is_instance_valid(o):
				continue
			var n := o as Node3D
			var d := global_position.distance_to(n.global_position)
			if d < best_d:
				best_d = d
				glance_target = n
	var face := get_node_or_null("Face")
	if face != null and glance_target != null and randf() < 0.65:
		var to := glance_target.global_position - global_position
		to.y = 0.0
		if to.length() > 0.1:
			var yaw_world := atan2(to.x, to.z)
			var yaw_local := wrapf(yaw_world - rotation.y, -PI, PI)
			yaw_local = clampf(yaw_local, -PI * 0.5, PI * 0.5)
			var base_yaw: float = face.rotation.y
			var tw := create_tween()
			tw.tween_property(face, "rotation:y", yaw_local, 0.25)
			tw.tween_interval(0.7)
			tw.tween_property(face, "rotation:y", base_yaw, 0.3)
			return
	# weight-shift fallback: a tiny body pop
	if anim:
		anim.pop(0.18)

func _arrived(p: Vector3) -> bool:
	var d := global_position - p
	d.y = 0.0
	return d.length() <= ARRIVE

func _steer_to(p: Vector3, delta: float, spd: float = -1.0) -> void:
	if spd < 0.0:
		spd = move_speed
	var to := p - global_position
	to.y = 0.0
	var dist := to.length()
	if dist > 0.001:
		var dir := to / dist
		velocity.x = dir.x * spd
		velocity.z = dir.z * spd
		_face_dir(dir, delta)
	else:
		_halt()

func _halt() -> void:
	velocity.x = move_toward(velocity.x, 0.0, move_speed)
	velocity.z = move_toward(velocity.z, 0.0, move_speed)

func _stand_near(p: Vector3) -> Vector3:
	var to := global_position - p
	to.y = 0.0
	if to.length() < 0.001:
		to = Vector3(1, 0, 0)
	var r := p + to.normalized() * STANDOFF
	r.y = global_position.y
	return r

func _face(p: Vector3, delta: float) -> void:
	var to := p - global_position
	to.y = 0.0
	if to.length() > 0.01:
		_face_dir(to.normalized(), delta)

func _face_dir(dir: Vector3, delta: float) -> void:
	var yaw := atan2(dir.x, dir.z)
	rotation.y = lerp_angle(rotation.y, yaw, clampf(delta * 8.0, 0.0, 1.0))

# ── HUD labels ──
func _update_label() -> void:
	if not trust_label:
		return
	var pct := int(trust_display * 100.0)
	var status := "  ★BACKING YOU" if is_backing_you else ""
	var hint := ""
	if is_busy:
		hint = "\n(away: %s)" % _task_kind
	elif _leaving:
		hint = "\n(leaving...)"
	elif not is_backing_you:
		hint = "\n[E] give food" if player_in_range else "\n(come closer)"
	elif player_in_range:
		hint = "\n[1]gather [2]hunt [3]scout"
	if hunger > 70.0:
		hint += "  (hungry)"
	var next_needed := relationship_to_next_rank()
	var next_hint := (" (+%.1f to next)" % next_needed) if next_needed > 0.0 else ""
	trust_label.text = "%s  [%s · %s]\nTrust: %d%%%s%s%s" % [member_name, current_rank, personality, pct, next_hint, status, hint]
	trust_label.modulate = trust_label.modulate.lerp(RANK_COLORS.get(current_rank, Color.WHITE), 0.05)

## Close enough to be in the conversation -> show the last few lines as a log.
## Further away -> just the current line, as before. The radius is the point:
## a camp of 10 members each showing 3 lines would be an unreadable wall of text
## from across the clearing, and this label renders every frame for everyone in
## view. Proximity is what makes it a conversation rather than a spreadsheet.
func _update_thought_label() -> void:
	if not thought_label:
		return
	if _player_node != null and _speech_log.size() > 1 \
			and global_position.distance_to(_player_node.global_position) <= SPEECH_LOG_RADIUS:
		var now: float = Time.get_ticks_msec() / 1000.0
		var lines: Array[String] = []
		for e in _speech_log:
			var d: Dictionary = e
			if now - float(d["t"]) <= SPEECH_LOG_TTL:
				lines.append(str(d["text"]))
		if lines.size() > 1:
			# oldest at top, newest last -- the newest is also current_thought,
			# so the label reads as a transcript ending in what they just said
			thought_label.text = "\n".join(lines)
			return
	_update_thought_label_single()

func _update_thought_label_single() -> void:
	if not thought_label:
		return
	thought_label.text = '"%s"' % current_thought
