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
const HysteresisGateScript = preload("res://hysteresis_gate.gd")

@export var member_name: String = "Tribesman"
@export var personality: String = "Steady"
@export var follow_threshold_hits: int = 2   # how many Follow-fires to back you

# ── brain / trust state ──
var brain: Spikeling
var anim: BodyAnim                       # procedural "alive" body motion
var _legs: Array = []                    # Leg0/Leg1 (real model only) -- see _animate_legs()
var _leg_phase: float = 0.0
var manager                              # TribeManager — set by the manager
var player_in_range: bool = false
var trust_display: float = 0.0           # 0..1 for the bar (smoothed)
var follow_fires: int = 0
var is_backing_you: bool = false
var relationship: float = 0.0            # smooth 0..3 bond meter (drives ranks)
var feed_count: int = 0
var betrayed_count: int = 0              # times the PLAYER has struck this member (see betray())

# ── BETRAYAL FATIGUE (2026-08-28) ── see the neuron comment in _brain_text().
# Counter-stimulus queued by betray() to land on Trust exactly TWO ticks
# later -- matching the real SawBetray -> Trust synapse's own actual arrival
# timing, not one tick. SawBetray fires on the FIRST _brain_tick() after
# betray() (its own stimulate() is immediate), but its synapse (delay=1)
# doesn't arrive on Trust until the SECOND _brain_tick() after that. A first
# draft of this queued the counter for the first following tick and measured
# a real bug from it -- Trust briefly went POSITIVE before crashing to the
# delayed -160 a tick later, because the counter landed a full tick before
# the hit it was supposed to be offsetting. Each entry: ticks_left counts
# down once per _brain_tick(); applied the instant it reaches 0, matching
# the same tick the real -160 arrives.
var _pending_betrayal_counters: Array = []   # [{"ticks_left": int, "amount": float}, ...]
# How much accumulated BetrayalFatigue `w` counts as "fully fatigued" --
# calibrated empirically (calib_probe.gd) to roughly the w reached by ONE
# fresh betrayal event under this neuron's real params (drive=80, tau_w=5000).
const BETRAYAL_FATIGUE_SATURATION := 0.25
# Max points of the -160 SawBetray hit this can counter-offset, at full
# saturation. Deliberately well under 160 -- a second betrayal should read as
# measurably DULLER, never neutralized or reversed into a non-event.
const BETRAYAL_FATIGUE_MAX_OFFSET := 60.0

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
const TRUST_BAR_SCALE      := 3.40  # relationship value that fills the trust bar to 100% (equals Soulbound threshold)

# ── rank thresholds (relationship value needed to reach each rank) ──
# SOULBOUND (2026-07-28): added as the ceiling above Devoted -- the "mentally
# linked, see through their eyes" tier. Gap from Devoted (1.20) is the widest
# yet, following the existing widening-gap pattern (0.30/0.40/0.60/0.90) --
# this is meant to be rare, a capstone bond, not something most of a roster
# reaches in one playthrough.
const RANKS := [
	["Stranger",     0.00],
	["Acquaintance", 0.30],
	["Friend",       0.70],
	["Loyal",        1.30],
	["Devoted",      2.20],
	["Soulbound",    3.40],   # must equal TRUST_BAR_SCALE
]

# RANK HYSTERESIS (2026-07-19): "does it save tokens" -> "what's the best use
# case" -- the same real dual-threshold gate proven on tribe_llm.gd's queue
# backlog, applied here to a much more consequential wobble: `relationship`
# drifts constantly (BOND_DECAY_RATE pulls it down every second, WORK_REL_GAIN
# etc. push it up) and a member sitting right at a rank's cutoff used to be
# able to cross back and forth on tiny fluctuations -- each crossing fires a
# REAL memory ("my feeling toward you deepened/cooled"), a social_role
# recompute, and (on the loyalty math) changes whether they'll accept a risky
# order. One gate per rank boundary; a rank is only lost once relationship
# falls to RANK_HYSTERESIS_MARGIN of its entry point, not the instant it dips
# below the entry point itself.
const RANK_HYSTERESIS_MARGIN := 0.85
var _rank_gates: Dictionary = {}   # rank name -> HysteresisGate (all ranks except "Stranger")

func _ensure_rank_gates() -> void:
	if not _rank_gates.is_empty():
		return
	for r in RANKS:
		var name: String = String(r[0])
		if name == "Stranger":
			continue
		var cutoff: float = float(r[1])
		_rank_gates[name] = HysteresisGateScript.new(cutoff * RANK_HYSTERESIS_MARGIN, cutoff)

# ── loyalty score each rank contributes toward accepting a risky order ──
const RANK_LOYALTY := {
	"Stranger": 15, "Acquaintance": 45, "Friend": 75, "Loyal": 100, "Devoted": 125, "Soulbound": 160,
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
# RETUNED (2026-07-19): "my tribe is stagnant" + "keeps doing the hunt i
# dont trust you enough repetitive loop" -- at gather/wood=100, drive=
# ORDER_BASE(70)+loyalty+courage meant a Stranger(loyalty 15) needed +15
# courage just to clear BASIC FORAGING, so Steady(0)/Wary(-15)/Greedy(-5)
# personalities -- the majority of the roster -- could do NOTHING at all
# autonomously until Acquaintance, no matter how mundane the task. That's
# not a loyalty system working as intended, it's most of the tribe locked
# out of basic survival work and repeatedly refusing/idling instead.
# Foraging/woodcutting are genuinely low-risk (in sight of camp, no
# confrontation) -- lowered so an average-courage Stranger can actually
# pull their weight from day one, while hunt/scout/guard (real physical
# danger) are UNCHANGED and still have to be earned.
const ORDER_RISK := {"come": 80, "gather": 70, "hunt": 130, "scout": 165, "wood": 70,
	"recruit": 110, "guard": 140, "mine": 90}

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
	# BETRAYAL FATIGUE (2026-08-28, tribe-neuron-type-expansion.md priority 2):
	# an ADDITIVE AdEx neuron stimulated ALONGSIDE SawBetray (see betray()
	# below) -- not a replacement for anything, and Trust itself below is
	# left completely untouched (same type, same leak, same synapses as
	# always). AdEx's adaptation variable `w` grows with sustained/repeated
	# depolarization and decays back down over its own timescale -- exactly
	# the "measurably duller on a second hit, recovers if enough time
	# passes" shape LIF cannot represent (LIF always resets flat to 0).
	# threshold=0 is deliberately never reached by a single betrayal's
	# drive=80 (calibrated empirically, see calib_probe.gd scratch run) --
	# this neuron is used purely for its CONTINUOUS subthreshold `w` state
	# (read via adex_adaptation()), not for discrete spiking.
	# tau_w=5000 (5 real seconds) is a DELIBERATE game-scale retuning, not
	# the bio-realistic 30-100ms default AdExNeuron/neurons.spk documents --
	# calibration showed that at this project's real step_dt=0.1 (10Hz), the
	# AdEx substep clock runs 1:1 with real wall-clock ms, so a bio-realistic
	# tau_w decays to exactly 0.0 within a single real second, long before a
	# player can physically trigger a second betray() -- the same
	# "hardware-tuned constant doesn't survive translation to this game's
	# scale" lesson Resonator's energy_time_constant already documented.
	# 5s means a second betrayal within a few seconds is measurably
	# dampened; a betrayal a minute later lands at full, undampened
	# strength -- "still catching their breath," not a permanent ratchet.
	t += "neuron BetrayalFatigue type=adex threshold=0 C=200 gL=10 EL=-70 VT=-50 delta=2 tau_w=5000 a=2 b=60 vreset=-58\n"
	# BURST TRAUMA (2026-08-28, tribe-neuron-type-expansion.md, Izhikevich hook
	# -- see the const block above _trauma_hit_count for the full pre-
	# registered claim). Chattering preset (c=-50, d=2 -- Izhikevich 2003's
	# own named regime) with `a` retuned from the 0.02 literature default to
	# 0.001 (tau=1000ms) so the recovery variable's decay lines up with this
	# game's real-second combat pacing instead of a real neuron's ms pacing.
	t += "neuron BurstTrauma type=izhikevich threshold=30 a=0.001 b=0.2 c=-50 d=2\n"
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

# ── SOCIETAL HIERARCHY (2026-08-03) ─────────────────────────────────────────
# A real social structure on top of the trust-rank ladder above: current_rank
# is "how much do I trust the Leader"; social_role is "what am I actually IN
# this tribe" -- a title that reflects what a member genuinely DOES
# (_job_counts, incremented once per real completed task in _complete_task())
# rather than something assigned once and forgotten. Grows WITH the tribe:
# Official is a small, genuinely elite slot (Tribemanager.official_quota()
# scales with roster size, never more than a real minority), and Outpostman
# is earned by literally having founded or migrated to a settlement (see
# home_pos -- the same real anchor tribemember.gd already re-plants on
# founding/migrating), not just a job tally.
const ROLE_HIERARCHY := [
	"Official", "Outpostman", "Trader", "Forager", "Hunter",
	"Builder", "Elite Builder", "Warrior", "Spy",
]
var social_role: String = "Forager"
var _job_counts: Dictionary = {}   # job kind -> completions

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

# ── ROUTE MEMORY (2026-08-28): private per-member "muscle memory" of the map.
# NOT wired into the Spikeling trust brain (see the deliberate note above
# _brain_text() re: not bolting senses onto a calibrated system blind) --
# reuses the SAME leaky-reinforcement/bounded-growth mechanics as
# spikeling.gd's own learn(), applied to a spatial grid instead. Private by
# default; shared tribe-wide only when members actually talk (see
# TribeRouteMemory autoload + tribe_talk.gd's _on_line hook below).
var route_memory: RouteMemory = RouteMemory.new()
var _route_decay_accum: float = 0.0
const ROUTE_DECAY_INTERVAL := 2.0     # seconds between decay ticks (cheap, not every physics frame)

# ── orders / tasks ──
const RANK_COLORS := {
	"Stranger":     Color(0.60, 0.60, 0.60),
	"Acquaintance": Color(0.85, 0.85, 0.40),
	"Friend":       Color(0.35, 0.90, 0.40),
	"Loyal":        Color(0.40, 0.65, 1.00),
	"Devoted":      Color(1.00, 0.80, 0.20),
	"Soulbound":    Color(0.65, 0.30, 0.90),
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
## RAISED (2026-07-19): "npcs need larger field of view, they suck at
## searching" -- at 12.0 a member frequently had NOTHING in sight even
## standing right next to a moderately sparse bush/tree/animal, forcing
## _begin_fallback()'s blind outward search to do almost all the real work.
## Raised to a range that covers a much bigger work radius around camp before
## falling back to search at all. Kept BELOW HEARING_RADIUS (24.0) on purpose
## -- "hear danger before you can see it" is a real, load-bearing design
## invariant elsewhere (hears_danger/_sense_environment()); sight overtaking
## hearing would make that mechanic unreachable through ordinary proximity.
## Safe to raise this much now that the _nearest_*() lookups below query
## SpatialGrid instead of scanning every node in the group -- cost no longer
## scales with how far this reaches.
const SIGHT_RADIUS := 20.0
const HEARING_RADIUS := 24.0
const SENSE_INTERVAL := 1.5      # seconds; environment doesn't need 10Hz precision
var _sense_cd: float = 0.0

## SIGHT_RADIUS scaled by the current weather's visibility (see
## Tribemanager.visibility_mult() — 1.0 in clear weather, lower in rain/
## storm/fog). Every vision-gated check in this file (task-target pickers,
## sees_raider/sees_prey) reads this instead of the bare constant, so bad
## weather genuinely narrows what a member notices, not just what a
## notification says.
func _effective_sight() -> float:
	var mult := 1.0
	if manager and manager.has_method("visibility_mult"):
		mult *= manager.visibility_mult()
	# DISTRICTS (2026-08-01): a member living near a "Watch" settlement
	# genuinely sees farther -- real payoff for the district a settlement
	# was founded as, not just a different name/structure.
	if manager and manager.has_method("sight_bonus_at"):
		mult *= manager.sight_bonus_at(home_pos)
	return SIGHT_RADIUS * mult

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
# EASED (2026-07-19): "build and expand more efficiently, progress is too
# slow" -- was 4 consecutive failed searches before a member would consider
# founding a new settlement; a real, felt reduction in how long expansion
# takes to actually start happening.
const EXPANSION_SEARCH_STREAK := 3
var _search_streak: int = 0
# BUG FIXED (2026-07-19): "npc can't find far away nodes, they run in circles"
# -- _begin_fallback() re-rolled a brand new RANDOM angle on every single
# failed search, from wherever the last random leg happened to leave them.
# The radius genuinely grew with the streak, but with no persistent
# direction each leg was as likely to double back toward camp as away from
# it, so net displacement across a whole streak was closer to a random walk
# than an actual outward search -- a real far-off bush/tree/animal could sit
# just past SEARCH_RADIUS_MAX and never once get reached. Now a streak locks
# in ONE heading (and one origin) on its first failure and keeps walking
# further along THAT SAME line each subsequent failure, only giving up the
# heading once something is actually found (streak resets to 0 elsewhere).
var _search_dir: Vector3 = Vector3.ZERO
var _search_origin: Vector3 = Vector3.ZERO

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
	_relay_to_subordinates(job, target)

# ── CHAIN OF COMMAND (2026-07-19) ───────────────────────────────────────────
# Previously every order (player-issued or self-directed) reached whichever
# single member it targeted with no notion of rank at all -- an Outpostman
# and the newest Stranger were equally "told" by the player, and nobody ever
# relayed anything to anyone else. Real trickle-down: only an Official (the
# top of the tribe's own hierarchy, see Tribemanager.is_official()) passes an
# order it just received on to nearby SUBORDINATES (non-Officials). Each
# subordinate still weighs it through their own give_order() loyalty check --
# this is delegation, not a bypass; a distrustful subordinate can still
# refuse their Official same as they could the player.
const RELAY_RADIUS := 40.0

## PEER CONTRIBUTION AWARENESS (2026-07-19): previously a member only ever
## reasoned about their OWN contrib_score() (gear upgrades, role tally) --
## they had no notion of how anyone ELSE was pulling their weight. Each idle
## tick, sample one real nearby tribemate and let a genuine gap in
## contribution actually move npc_opinion, the same real channel gossip
## already uses (see tribe_rumor.gd's GOSSIP_HIT/GOSSIP_BOOST) -- so a
## freeloader is gradually resented and a standout is gradually respected,
## from firsthand observation rather than hearsay.
const PEER_EVAL_RADIUS := 30.0
const PEER_EVAL_GAP := 15          # contrib_score() gap before it registers at all
const PEER_EVAL_SHIFT := 0.04

func _evaluate_peer_contribution() -> void:
	if manager == null:
		return
	var mine: int = productivity()
	for m in manager.members:
		if not is_instance_valid(m) or m == self or not ("member_name" in m):
			continue
		if global_position.distance_to(m.global_position) > PEER_EVAL_RADIUS:
			continue
		var theirs: int = m.productivity() if m.has_method("productivity") else 0
		var gap: int = theirs - mine
		if absi(gap) < PEER_EVAL_GAP:
			continue
		var peer_name: String = str(m.member_name)
		var delta: float = PEER_EVAL_SHIFT if gap > 0 else -PEER_EVAL_SHIFT
		npc_opinion[peer_name] = clampf(float(npc_opinion.get(peer_name, 0.0)) + delta, -1.0, 1.0)
		return   # one real observation per tick — not an instant tribe-wide audit

func _relay_to_subordinates(job: String, target: int) -> void:
	if social_role != "Official" or manager == null or job == "":
		return
	for m in manager.members:
		if not is_instance_valid(m) or m == self:
			continue
		if str(m.get("social_role")) == "Official":
			continue   # peers, not subordinates -- the player/leader orders Officials directly
		if global_position.distance_to(m.global_position) > RELAY_RADIUS:
			continue
		if m.has_method("give_order") and m.give_order(job) and m.has_method("set_standing"):
			m.set_standing(job, target)   # safe: subordinates return immediately above, no relay chain

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
	{"name": "Wand",  "mult": 1.3},
]
# BLACKSMITH_MAX_WEAPON_TIER (2026-08-28 bugfix): the last tier reachable via
# the normal linear Club->Spear->Bow->Axe ladder (both the directed
# craft_weapon() order and _maybe_upgrade_gear()'s random automatic raise) --
# NOT the same thing as "last index in WEAPON_TIERS". Wand (index 4) is a
# real, separate case: it's only ever reached through WeaponPreference's
# favors_ranged() redirect (a member's actual combat experience), never
# forged/ordered/auto-climbed to like the other four. Before this constant
# existed, several places used `WEAPON_TIERS.size() - 1` as a stand-in for
# "top of the forgeable ladder" -- that was silently correct only because
# the array's last index and the ladder's top happened to be the same
# number (3) until Wand was appended as a 5th entry with a different
# acquisition path, which broke that assumption without anyone changing
# the assuming code (craft_weapon(99) started clamping to Wand instead of
# Axe, and the ordinary +1 upgrade ladder could silently climb a member
# onto a "magic" weapon they never earned through combat at all).
const BLACKSMITH_MAX_WEAPON_TIER := 3   # Axe
const ARMOR_TIERS := [
	{"name": "None",  "reduction": 0.0},
	{"name": "Hide",  "reduction": 0.15},
	{"name": "Bone",  "reduction": 0.30},
	{"name": "Metal", "reduction": 0.45},
]
var weapon: int = 0
var armor: int = 0

# ── WEAPON PREFERENCE (2026-08-28): "wire spike thoughts into actions" --
# see weapon_preference.gd. Real combat-experience-driven weapon choice,
# not just equipment history.
const WeaponPreferenceScript = preload("res://weapon_preference.gd")
var weapon_pref: WeaponPreference = WeaponPreferenceScript.new()

# ── PLAYER REPUTATION (2026-08-28): "remembers you, reputation builds over
# repeat interactions" -- see player_reputation.gd. Distinct from
# `relationship` (the existing single trust scalar) -- a separate recognition
# layer for a real PATTERN of good/bad treatment, feeding back into how fast
# relationship itself builds.
const PlayerReputationScript = preload("res://player_reputation.gd")
var player_rep: PlayerReputation = PlayerReputationScript.new()

# ── PROFESSIONS (2026-07-19): "30 professions, tie it all together" -- one
# shared skill-progression mechanic every profession uses (practice ->
# skill -> WoW-style tiered recipe unlocks -> can teach a lower-skilled
# peer), rather than 30 hand-built unique systems. Blacksmithing is the one
# with real recipe-gating wired in below (craft_weapon/craft_armor); the
# rest are real, assignable, practice-trackable roles a member can commit
# to and grow in, ready for the same treatment as they get their own
# recipes/actions.
const PROFESSIONS := [
	"Blacksmithing", "Leatherworking", "Woodworking", "Glassblowing", "Masonry",
	"Tanning", "Weaving", "Pottery", "Bowyer", "Fletching",
	"Herbalism", "Alchemy", "Cooking", "Brewing", "Fishing",
	"Trapping", "Mining", "Gemcutting", "Jewelcrafting", "Tailoring",
	"Carpentry", "Shipwrighting", "Farming", "Beekeeping", "Dyeing",
	"Papermaking", "Scribing", "Engineering", "Tinkering", "Animal Husbandry",
]
const SKILL_TIER_NAMES := ["Untrained", "Novice", "Journeyman", "Expert", "Master"]
const SKILL_TIER_STEP := 25.0     # skill points per tier -- 4 real tiers above Untrained
const PRACTICE_GAIN := 3.0        # skill earned per successful craft/use
const TEACH_TRUST_BAR := 0.30     # matches Acquaintance -- must have warmed up at all first

var profession: String = ""              # "" = none chosen yet
var profession_skill: Dictionary = {}    # profession name -> float 0..100

## INVENTORY (2026-07-19): "add npc and player inventory" -- distinct from
## inv_food (personal rations) and weapon/armor tiers (equipped gear, one
## slot each): a general-purpose item count, mainly populated by
## _practice_and_produce() below -- what a profession actually YIELDS, kept
## on the member who made it (a personal keepsake/stock), not dumped into
## the shared stockpile the way raw gather/mine/chop output is.
var inventory: Dictionary = {}   # item name -> int count

func add_item(item: String, n: int = 1) -> void:
	inventory[item] = int(inventory.get(item, 0)) + n

func item_count(item: String) -> int:
	return int(inventory.get(item, 0))

## PROFESSIONS PRODUCE REAL GOODS (2026-07-19): "professions have to use
## real materials from in game" + "across all 30 professions" -- one shared
## conversion every profession uses (spend real shared materials -> gain a
## named good in personal inventory + real practice), rather than 30
## bespoke recipes. Blacksmithing keeps its own bespoke weapon/armor tiers
## (craft_weapon/craft_armor) on top of this; every OTHER profession gets
## this as its real, working action.
const PROFESSION_OUTPUT := {
	"Blacksmithing": "Ingot", "Leatherworking": "Leather Roll", "Woodworking": "Carved Idol",
	"Glassblowing": "Glass Vial", "Masonry": "Cut Stone", "Tanning": "Tanned Hide",
	"Weaving": "Woven Cloth", "Pottery": "Clay Pot", "Bowyer": "Bow Stave",
	"Fletching": "Arrow Bundle", "Herbalism": "Herb Bundle", "Alchemy": "Tonic",
	"Cooking": "Cooked Meal", "Brewing": "Brewed Cask", "Fishing": "Smoked Fish",
	"Trapping": "Cured Pelt", "Mining": "Ore Sack", "Gemcutting": "Cut Gem",
	"Jewelcrafting": "Fine Jewelry", "Tailoring": "Stitched Garment", "Carpentry": "Timber Frame",
	"Shipwrighting": "Hull Plank", "Farming": "Grain Sack", "Beekeeping": "Honeycomb",
	"Dyeing": "Dyed Cloth", "Papermaking": "Paper Sheet", "Scribing": "Written Scroll",
	"Engineering": "Rigged Contraption", "Tinkering": "Tinkered Gadget", "Animal Husbandry": "Bred Stock",
}
const PROFESSION_PRODUCE_COST := 3   # shared materials spent per unit produced

## YIELD SCALES WITH SKILL (2026-08-28): skill previously only unlocked
## flavor text (skill_tier() name) and teaching -- _practice_and_produce()
## always granted exactly 1 unit of output regardless of tier, so a Master
## and an Untrained crafter were equally "bountiful." This is the real gap:
## same materials cost (PROFESSION_PRODUCE_COST doesn't change), MORE output
## per batch as skill grows -- a genuine efficiency reward for practice, not
## just a label. Kept as a simple, inspectable step table rather than a
## formula, matching PROFESSIONS/SKILL_TIER_NAMES' own hand-tuned-table style.
const YIELD_BY_TIER := [1, 1, 2, 2, 3]   # Untrained, Novice, Journeyman, Expert, Master
func _yield_for(prof: String) -> int:
	var idx: int = clampi(int(skill_in(prof) / SKILL_TIER_STEP), 0, SKILL_TIER_NAMES.size() - 1)
	return YIELD_BY_TIER[idx]

func _practice_and_produce(prof: String) -> bool:
	if skill_in(prof) <= 0.0 or manager == null or not manager.has_method("spend_materials_at"):
		return false
	if not manager.spend_materials_at(home_pos, PROFESSION_PRODUCE_COST):
		return false
	var output: String = str(PROFESSION_OUTPUT.get(prof, "Goods"))
	var qty: int = _yield_for(prof)
	add_item(output, qty)
	practice_profession(prof)
	if qty > 1:
		_think("Made: %d %s! (skill paying off)" % [qty, output], 2.0)
	else:
		_think("Made: %s." % output, 2.0)
	TribeMemory.remember(member_name, "crafted", "You",
		"I put my %s to work and made %s %s." % [prof, str(qty), output], "proud", 0.02)
	return true

## Set once, by Tribemanager._make_loyal_companion(), on the very first
## companion every tribe starts with -- see _maybe_feed_a_stranger() below
## for the baseline behavior this actually turns on.
var is_founding_recruiter: bool = false
const FOUNDING_RECRUITER_FEED_CHANCE := 0.30

func skill_in(prof: String) -> float:
	return float(profession_skill.get(prof, 0.0))

func skill_tier(prof: String) -> String:
	var idx: int = clampi(int(skill_in(prof) / SKILL_TIER_STEP), 0, SKILL_TIER_NAMES.size() - 1)
	return SKILL_TIER_NAMES[idx]

## Practicing a profession is how every recipe past the basics gets learned --
## no slider, no instant mastery. Also nudges `profession` itself toward
## whatever's actually being practiced, the same way social_role emerges from
## job tally rather than being hand-assigned.
func practice_profession(prof: String, amount: float = PRACTICE_GAIN) -> void:
	if not (prof in PROFESSIONS):
		return
	var before: float = skill_in(prof)
	var after: float = clampf(before + amount, 0.0, 100.0)
	profession_skill[prof] = after
	if profession == "":
		profession = prof
	if int(after / SKILL_TIER_STEP) > int(before / SKILL_TIER_STEP):
		_think("My %s has grown to %s." % [prof, skill_tier(prof)], 2.4)
		TribeMemory.remember(member_name, "trauma", "You",
			"Practice paid off -- my %s reached %s." % [prof, skill_tier(prof)], "proud", 0.03)

## TEACH & GUIDE (2026-07-19): a genuinely more-skilled member can pass real
## progress to a nearby, trusted, less-skilled one -- capped so a pupil can
## never leapfrog past their teacher's own current skill in one lesson, and
## gated on the same warmed-up-at-all bar _auto_work() already uses (a total
## Stranger can't be taught, same principle as every other trust gate added
## this session).
func teach_profession(pupil, prof: String) -> bool:
	if pupil == null or not is_instance_valid(pupil) or not ("relationship" in pupil):
		return false
	if float(pupil.get("relationship")) < TEACH_TRUST_BAR:
		return false
	var mine: float = skill_in(prof)
	var theirs: float = pupil.skill_in(prof) if pupil.has_method("skill_in") else 0.0
	if mine <= theirs:
		return false   # nothing real to teach -- the pupil already knows as much
	var gain: float = minf(SKILL_TIER_STEP * 0.5, mine - theirs)
	if pupil.has_method("practice_profession"):
		pupil.practice_profession(prof, gain)
	TribeMemory.remember(str(pupil.get("member_name")), "ordered", str(member_name),
		"%s taught me a real lesson in %s." % [member_name, prof], "neutral", 0.02)
	return true

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
## WoW-STYLE RECIPE GATING (2026-07-19): tier 0 (bare Club) needs no skill at
## all; each tier above that needs Blacksmithing at the matching tier
## (SKILL_TIER_STEP per tier -- Spear at Novice, Bow at Journeyman, Axe at
## Expert). A member with no practice literally cannot forge the good stuff
## yet, no matter how many materials are on hand -- skill has to be earned by
## actually crafting (see practice_profession() below), same as a real trade.
## Clamped to BLACKSMITH_MAX_WEAPON_TIER, not WEAPON_TIERS.size() - 1: a
## smith can't forge a Wand on request (no craft_wand order verb exists --
## see tribe_command.gd's CRAFT_TIERS -- and it isn't a Blacksmithing
## recipe), so an out-of-range request clamps to the top of the ladder
## that's actually forgeable (Axe), same as before Wand existed.
func craft_weapon(tier: int) -> bool:
	if manager == null or not manager.has_method("spend_materials_at"):
		return false
	tier = clampi(tier, 0, BLACKSMITH_MAX_WEAPON_TIER)
	if float(tier) * SKILL_TIER_STEP > skill_in("Blacksmithing"):
		_think("I haven't learned to forge a %s yet -- needs more practice." % str(WEAPON_TIERS[tier]["name"]), 2.2)
		return false
	# DISTRICT BONUS (2026-08-03): a Crafting settlement's workshop genuinely
	# cuts material cost for its own residents.
	var cost: int = _GEAR_MAT_COST
	if manager.has_method("crafting_discount_at"):
		cost = maxi(1, int(round(float(_GEAR_MAT_COST) * manager.crafting_discount_at(home_pos))))
	# PER-SETTLEMENT ECONOMIES (2026-08-04): a resident crafts from their own
	# settlement's local materials (spend_materials_at() falls through to the
	# original shared spend_materials() for everyone else).
	if not manager.spend_materials_at(home_pos, cost):
		_think("Not enough materials to craft that yet.", 2.0)
		return false
	weapon = tier
	practice_profession("Blacksmithing")
	var wname: String = str(WEAPON_TIERS[tier]["name"])
	_think("Crafted a %s." % wname, 2.0)
	TribeMemory.remember(member_name, "crafted", "You",
		"You had me craft a %s." % wname, "neutral", 0.02)
	return true

## Armor's the same recipe-gating shape as craft_weapon() above, same
## Blacksmithing skill (a smith forges both, same trade).
func craft_armor(tier: int) -> bool:
	if manager == null or not manager.has_method("spend_materials_at"):
		return false
	tier = clampi(tier, 0, ARMOR_TIERS.size() - 1)
	if float(tier) * SKILL_TIER_STEP > skill_in("Blacksmithing"):
		_think("I haven't learned to forge %s armor yet -- needs more practice." % str(ARMOR_TIERS[tier]["name"]), 2.2)
		return false
	var cost: int = _GEAR_MAT_COST
	if manager.has_method("crafting_discount_at"):
		cost = maxi(1, int(round(float(_GEAR_MAT_COST) * manager.crafting_discount_at(home_pos))))
	if not manager.spend_materials_at(home_pos, cost):
		_think("Not enough materials to craft that yet.", 2.0)
		return false
	armor = tier
	practice_profession("Blacksmithing")
	var aname: String = str(ARMOR_TIERS[tier]["name"])
	_think("Crafted %s armor." % aname, 2.0)
	TribeMemory.remember(member_name, "crafted", "You",
		"You had me craft %s armor." % aname, "neutral", 0.02)
	return true

# productivity — feeds the "who should lead" calculation
var contrib_food: int = 0
var contrib_wood: int = 0

# ── personality change from lived experience (2026-07-19) ──────────────────
# PERSONALITIES is a fixed archetype table (hand-tuned brain weights), so
# "changing" means reassigning `personality` to a neighboring archetype, not
# mutating the table. Two independent triggers, matching the two the player
# actually asked for: repeated real hardship (take_hit, below) nudges toward
# "Wary"; repeated real contribution (_complete_task, above) nudges toward
# "Trusting". Both are rate-limited (a threshold that keeps climbing) so one
# bad afternoon or one lucky haul can't flip someone's whole personality.
const CONTRIB_SHIFT_INTERVAL := 60          # combined food+wood contribution per shift
const TRAUMA_HITS_PER_SHIFT := 3            # real hits taken per shift
var _next_contrib_shift_at: int = CONTRIB_SHIFT_INTERVAL
var _trauma_hit_count: int = 0

# ── BURST TRAUMA (2026-08-28, tribe-neuron-type-expansion.md, Izhikevich hook)
# PRE-REGISTERED CLAIM (stated before this was built): _trauma_hit_count
# above only counts REAL HITS -- it has zero awareness of WHEN they landed.
# 3 hits taken in a single rapid ambush and 3 hits taken across an hour-long,
# on-and-off fight currently trigger the identical Wary personality shift,
# identically -- LIF/plain counters structurally can't represent the
# difference. An ADDITIVE Izhikevich neuron, `BurstTrauma`, stimulated
# alongside (not instead of) the ordinary trauma count in take_hit() below,
# will show its recovery variable `iz_u` (read via the already-existing
# izhikevich_recovery() introspection API, no engine change needed) still
# measurably ELEVATED (>0.0, vs a resting/fully-decayed baseline around
# -13/-14) when a hit lands within about 1 real second of the previous one,
# but DECAYED back near that resting baseline (<0.0) when the previous hit
# landed 3+ real seconds earlier. Real numbers from calibration
# (calib_burst_probe.gd, since deleted, a=0.001/tau=1000ms): prior_u=13.29 at
# a 1.0s gap, prior_u=-11.57 at a 3.0s gap, prior_u=-14.00 at a 60s gap
# (baseline=-13.00) -- BURST_TRAUMA_ELEVATED_U=0.0 sits cleanly between those.
# USE: at the moment a hit lands, if BurstTrauma's iz_u (read from BEFORE
# this hit's own stimulation, same "read prior state first" pattern as
# BetrayalFatigue) is already elevated, this hit also adds one extra
# "phantom" trauma count on top of the real one -- so a burst of hits
# landing within ~1s of each other reaches TRAUMA_HITS_PER_SHIFT=3 (and the
# Wary shift) after only 2 REAL hits, while the same 3 total hits spread 3+
# real seconds apart still require all 3 real hits, exactly as before this
# change. `a` (0.001) is a real, documented, game-scale retuning of the
# 0.02 literature default -- same "hardware-tuned constant doesn't survive
# translation to this game's scale" lesson Resonator's energy_time_constant
# and BetrayalFatigue's tau_w already hit; c=-50/d=2 (the "chattering" preset,
# Izhikevich 2003's own named regime, not invented) are left at their real
# literature values, untouched.
const BURST_TRAUMA_ELEVATED_U := 0.0
var _trauma_burst_bonus_count: int = 0      # how many phantom counts have fired, for the test/debug read below

## this member's archetype courage score -- read by Tribemanager.dominant_ideology()
## to classify the tribe's emergent temperament from its actual personality mix.
func courage() -> int:
	return int(PERSONALITIES.get(personality, PERSONALITIES["Steady"])["courage"])

## A real tribe-wide reaction to a real loss (2026-07-19) -- called on every
## survivor by Tribemanager.on_member_died(). Distinct from take_hit()'s own
## trauma counter (that's for being personally attacked); this is grief at
## losing one of your own, worse and more likely to change you if the
## LEADER did it.
const WITNESS_TRAUMA_CHANCE := 0.4

## ADDITIVE THOUGHTS (2026-07-19): "allow npc thoughts to have additive
## properties, witnessing 3 members die one by one = you let 3 members die"
## -- separate cumulative counters for deaths genuinely caused by the
## leader (denied stockpile access, or a direct killing) so repeated real
## failures actually compound into an escalating line and a real
## consequence, instead of each death being independently forgotten.
var player_caused_deaths_witnessed: int = 0
const LOST_FAITH_DEATH_THRESHOLD := 3

## Core-memory SSH chain (npc_core_memory.gd) -- betrayals/deaths caused by
## the player are written to EDGE slots (survive panic); routine slights go
## to BULK slots (wash out under the same panic). See that file's header for
## the confirmed experiment this is built on.
const NPCCoreMemoryScript = preload("res://npc_core_memory.gd")
var _core_memory: NPCCoreMemory = null
func _ensure_core_memory() -> NPCCoreMemory:
	if _core_memory == null:
		_core_memory = NPCCoreMemoryScript.new()
	return _core_memory

## Called every tick a real threat is nearby (see _nearest_base_threat()) --
## the actual panic that degrades bulk (routine) memories while edge (core)
## memories stay reliable, same mechanism as the SSH chiral experiment's
## hopping disorder.
func _apply_memory_stress(intensity: float) -> void:
	_ensure_core_memory().apply_stress(intensity)

## How reliably this NPC still recalls a given core memory right now (0..1,
## 0 = truly forgotten). Real gameplay hook: trust/dialogue decisions can
## check this instead of an eternal, undegradeable flag.
func recall_core_memory(tag: String) -> float:
	return _ensure_core_memory().recall(tag)

## Turns a stored core-memory tag into an actual sentence a player would
## recognize, keyed off the exact tags written by witness_tribemate_death()
## and blame_leader_for_hunger_death() above.
func _describe_core_tag(tag: String) -> String:
	var parts: PackedStringArray = tag.split(":", true, 1)
	if parts.size() != 2:
		return "something that happened between you"
	var kind: String = parts[0]
	var who: String = parts[1]
	match kind:
		"betrayal":
			return "you killing %s with your own hands" % who
		"hunger_neglect":
			return "%s starving while you left them locked out of the stockpile" % who
		_:
			return "what happened to %s" % who

## Wired into dialogue (tribe_chat.gd's persona string): the SSH edge-vs-bulk
## result made real -- how strongly this NPC brings up a past betrayal right
## NOW depends on live recall confidence, not a permanent flag. A calm NPC
## recalls vividly; one who's just been through real combat panic (see
## _apply_memory_stress()) may genuinely have it worn hazy, same as a routine
## grudge would under the same stress.
func core_memory_blame_line() -> String:
	if _core_memory == null:
		return ""
	var tags: Array = _core_memory.core_tags()
	if tags.is_empty():
		return ""
	var best_tag: String = ""
	var best_conf: float = -1.0
	for t in tags:
		var c: float = recall_core_memory(str(t))
		if c > best_conf:
			best_conf = c
			best_tag = str(t)
	if best_conf <= 0.0:
		return ""
	var described: String = _describe_core_tag(best_tag)
	if best_conf >= 0.08:
		return " You vividly remember %s -- it colors how much you trust the Leader right now, and you should let it show." % described
	return " Some part of you remembers something bad involving the Leader, but everything since has worn it hazy -- you're not sure it should still weigh on you."

## Same best-core-tag selection as core_memory_blame_line() above, but
## returns the RAW numbers instead of an LLM-facing sentence -- for
## direct_voice.gd's deterministic decoder, which bands these itself rather
## than reusing prose written for a language model to riff on. Kept as a
## real accessor (not duplicated inline in direct_voice.gd) so both voice
## paths read the exact same recall() confidence for the exact same tag.
## Raw Trust neuron potential -- the SAME brain.get_potential("Trust") read
## brain_snapshot() and core_memory_best_recall()'s callers already take.
## Exposed as a real accessor (not inlined at each call site) so code that
## only has `member` typed as a plain `Node` (e.g. tribe_chat.gd's _say_to())
## can reach it via .call() the same way it already reaches brain_snapshot()
## and core_memory_best_recall() -- calling `.brain.get_potential(...)`
## directly on a Node-typed variable is the exact untyped-member-access
## gotcha this repo avoids elsewhere in this file's own callers.
func get_trust_potential() -> float:
	return brain.get_potential("Trust")

func core_memory_best_recall() -> Dictionary:
	if _core_memory == null:
		return {"confidence": 0.0, "described": ""}
	var tags: Array = _core_memory.core_tags()
	if tags.is_empty():
		return {"confidence": 0.0, "described": ""}
	var best_tag: String = ""
	var best_conf: float = -1.0
	for t in tags:
		var c: float = recall_core_memory(str(t))
		if c > best_conf:
			best_conf = c
			best_tag = str(t)
	if best_conf <= 0.0:
		return {"confidence": 0.0, "described": ""}
	return {"confidence": best_conf, "described": _describe_core_tag(best_tag)}

## "if npcs die to hunger have other npcs blame leader for negligence" --
## distinct from witness_tribemate_death() below (an outside threat/raid):
## this is specifically about the LEADER'S stockpile failing to feed the
## tribe. `denied_access` distinguishes real negligence (a Stranger who
## never earned access at all) from a supply failure (Acquaintance+, had
## real access, the stores just ran dry) -- "they shouldn't get mad if they
## have access": only the denied-access case blames the leader personally.
func blame_leader_for_hunger_death(fallen_name: String, denied_access: bool = true) -> void:
	if not denied_access:
		TribeMemory.remember(member_name, "trauma", "You",
			"%s starved even with real stockpile access -- the stores just ran dry." % fallen_name,
			"grieving", -0.05)
		_think("%s starved despite everything. The stores just ran out." % fallen_name, 2.6)
		return
	player_caused_deaths_witnessed += 1
	var n: int = player_caused_deaths_witnessed
	_ensure_core_memory().remember("hunger_neglect:%s" % fallen_name, true)
	var cumulative: String = " You've let %d of us die now." % n if n >= 2 else ""
	TribeMemory.remember(member_name, "trauma", "You",
		"%s starved while you let the stockpile run dry. That's on you.%s" % [fallen_name, cumulative],
		"resentful", -0.20)
	_think("%s is dead because you didn't feed us!%s" % [fallen_name, cumulative], 2.6)
	if n >= LOST_FAITH_DEATH_THRESHOLD:
		# THOUGHTS DIRECTLY RESULT IN ACTIONS (2026-07-19): not just an
		# escalating line -- real, permanent consequences once the pattern
		# is undeniable, same as any other real betrayal in this game.
		if is_backing_you:
			is_backing_you = false
			_think("I can't keep following a leader who lets this happen, again and again.", 3.0)
		_maybe_shift_personality("Wary", "After watching %d of us starve, I've lost faith in your leadership." % n)
	elif randf() < WITNESS_TRAUMA_CHANCE:
		_maybe_shift_personality("Wary", "After watching %s starve, I trust your leadership less." % fallen_name)

func witness_tribemate_death(fallen_name: String, by_player: bool) -> void:
	if by_player:
		player_caused_deaths_witnessed += 1
		_ensure_core_memory().remember("betrayal:%s" % fallen_name, true)
	else:
		_ensure_core_memory().remember("death:%s" % fallen_name, false)
	var n: int = player_caused_deaths_witnessed
	var cumulative: String = " You've let %d of us die now." % n if by_player and n >= 2 else ""
	var reason: String = ("%s is gone. The Leader did that to us.%s" % [fallen_name, cumulative]) if by_player \
		else ("%s is gone. I won't forget it." % fallen_name)
	TribeMemory.remember(member_name, "trauma", "You", reason, "grieving", -0.15 if by_player else -0.05)
	if by_player and n >= LOST_FAITH_DEATH_THRESHOLD:
		if is_backing_you:
			is_backing_you = false
			_think("I can't stay loyal to someone who keeps killing us.", 3.0)
		_maybe_shift_personality("Wary", "After %d of us dead by your hand, I've lost faith in you." % n)
	elif randf() < WITNESS_TRAUMA_CHANCE:
		_maybe_shift_personality("Wary", "After losing %s, I trust the world less now." % fallen_name)

func _maybe_shift_personality(target: String, reason: String) -> void:
	if personality == target or not PERSONALITIES.has(target):
		return
	personality = target
	TribeMemory.remember(member_name, "trauma", "You", reason, "neutral", 0.0)
	_think(reason, 2.4)

## Named destination for a just-made deposit, or "" for the shared camp --
## used to spell out where a resident's surplus actually went instead of
## leaving the player to guess why the home stockpile didn't move.
func _deposit_destination_name() -> String:
	if manager == null or not manager.has_method("_outpost_at"):
		return ""
	var o = manager._outpost_at(home_pos)
	if o == null or not is_instance_valid(o):
		return ""
	return str(o.get("settlement_name"))
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
	_maybe_upgrade_to_real_model()
	brain = Spikeling.new()
	if not brain.load_from_text(_brain_text()):
		push_error("TribeMember: brain failed to load")
	home_pos = global_position
	_target = home_pos
	_fidget_cd = randf_range(4.0, 14.0)   # stagger so members don't all fidget simultaneously
	# real model only -- the old capsule fallback has no separate leg objects
	for leg_name in ["Leg0", "Leg1"]:
		var leg := get_node_or_null(leg_name)
		if leg != null and leg is Node3D:
			_legs.append(leg)
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

## REAL MODELED ASSETS: a tribemember can come from any of 3 different
## construction sites -- Tribemanager._build_member_in_code()'s plain
## capsule, the empty tribemember.tscn via member_scene, or a hand-placed
## scene node (main.tscn's "TribeManager/TribeMember", the very FIRST
## companion every game starts with, with its own baked CapsuleMesh). Rather
## than fix all 3 separately and risk them drifting out of sync, the real-
## model swap happens ONCE, here, on every tribemember regardless of origin.
##
## Three tiers, best first: Quaternius's CC0 "Universal Base Characters" +
## "Universal Animation Library" (a genuinely higher-fidelity rig/mesh than
## Kenney's blocky look -- see the QUATERNIUS_CHARACTERS block below for the
## full story), else Kenney's CC0 "Mini Characters" (real rig + real baked
## walk/idle animations -- assets/humans_real/, downloaded, not generated) if
## present, else the Blender-generated body (tools/gen_humans.py) as a
## fallback, else the old capsule stays untouched.
const KENNEY_CHARACTERS := [
	"character-male-a", "character-male-b", "character-male-c",
	"character-male-d", "character-male-e", "character-male-f",
	"character-female-a", "character-female-b", "character-female-c",
	"character-female-d", "character-female-e", "character-female-f",
]
# Kenney's "Mini" characters ship at a stylized ~0.67m-tall scale -- this
# game's existing humans (capsule collision height ~1.6-2.0m) are full adult
# scale, so scale up to match everything else (camera height, club reach,
# interact ranges) instead of everyone suddenly being knee-high.
const KENNEY_SCALE := 2.6
var _kenney_anim: AnimationPlayer = null

## QUATERNIUS UPGRADE (2026-07-27): "feels like Roblox" -- the user's own
## complaint about Kenney's chunky/blocky chibi look, wanting a real upgrade.
## Built via a Blender headless pipeline (combines a Quaternius base body
## with a hairstyle mesh onto their shared 65-bone rig -- confirmed identical
## bone naming across the base-character and animation-library glTFs before
## writing any retargeting code, so this was a same-rig NLA bake, not real
## cross-rig retargeting) that renames the animation library's own clip names
## onto this codebase's "idle"/"walk"/"attack-melee-left"/
## "attack-melee-right"/"die" convention. See assets/humans_quaternius/ -- 6
## body+hair combinations.
const QUATERNIUS_CHARACTERS := [
	"quaternius_male_buzzed", "quaternius_male_simpleparted", "quaternius_male_bearded",
	"quaternius_female_long", "quaternius_female_buns", "quaternius_female_buzzed",
]
# the combined body+hair export measures ~1.81m tall unscaled (already
# full-adult scale, unlike Kenney's stylized ~0.67m) -- scaled down slightly
# to match this game's existing ~1.75m human convention exactly.
const QUATERNIUS_SCALE := 0.97
var _quaternius_anim: AnimationPlayer = null

func _maybe_upgrade_to_real_model() -> void:
	if get_node_or_null("Leg0") != null or get_node_or_null("KenneyModel") != null or get_node_or_null("QuaterniusModel") != null:
		return   # already real (built fresh, or already upgraded once)
	if _try_quaternius_model():
		return
	if _try_kenney_model():
		return
	_try_generated_model()

func _clear_old_primitive_body() -> void:
	# free the old parts IMMEDIATELY (not queue_free -- that's deferred to the
	# next idle frame, so a new node also named "Mesh" added right after would
	# get auto-renamed to avoid a collision with the still-present old one,
	# and anim.setup()'s later get_node_or_null("Mesh") would grab that stale,
	# about-to-be-freed reference instead of the new real model -- exactly the
	# "previously freed instance" crash this avoids).
	var old_mesh := get_node_or_null("Mesh")
	if old_mesh != null:
		remove_child(old_mesh)
		old_mesh.free()
	var old_face := get_node_or_null("Face")
	if old_face != null:
		remove_child(old_face)
		old_face.free()

func _try_quaternius_model() -> bool:
	var pick: String = QUATERNIUS_CHARACTERS[randi() % QUATERNIUS_CHARACTERS.size()]
	var glb_path := "res://assets/humans_quaternius/%s.glb" % pick
	if not ResourceLoader.exists(glb_path):
		return false
	var packed: PackedScene = load(glb_path)
	var model := packed.instantiate()
	var ap := _find_node_named(model, "AnimationPlayer") as AnimationPlayer
	if ap == null:
		model.queue_free()
		return false
	_clear_old_primitive_body()
	model.name = "QuaterniusModel"
	model.scale = Vector3(QUATERNIUS_SCALE, QUATERNIUS_SCALE, QUATERNIUS_SCALE)
	add_child(model)
	_quaternius_anim = ap
	# loop_mode isn't reliably set on glTF-imported clips -- these Animation
	# resources are shared across every instance using this same character
	# file, so setting it once here is enough for all of them.
	for clip_name in ["walk", "idle"]:
		if ap.has_animation(clip_name):
			ap.get_animation(clip_name).loop_mode = Animation.LOOP_LINEAR
	ap.play("idle")
	return true

func _try_kenney_model() -> bool:
	var pick: String = KENNEY_CHARACTERS[randi() % KENNEY_CHARACTERS.size()]
	var glb_path := "res://assets/humans_real/%s.glb" % pick
	if not ResourceLoader.exists(glb_path):
		return false
	var packed: PackedScene = load(glb_path)
	var model := packed.instantiate()
	var ap := _find_node_named(model, "AnimationPlayer") as AnimationPlayer
	if ap == null:
		model.queue_free()
		return false
	_clear_old_primitive_body()
	model.name = "KenneyModel"
	model.scale = Vector3(KENNEY_SCALE, KENNEY_SCALE, KENNEY_SCALE)
	add_child(model)
	_kenney_anim = ap
	# loop_mode isn't reliably set on glTF-imported clips -- these Animation
	# resources are shared across every instance using this same character
	# file, so setting it once here is enough for all of them.
	for clip_name in ["walk", "idle"]:
		if ap.has_animation(clip_name):
			ap.get_animation(clip_name).loop_mode = Animation.LOOP_LINEAR
	ap.play("idle")
	return true

func _try_generated_model() -> bool:
	var glb_path := "res://assets/humans/human.glb"
	if not ResourceLoader.exists(glb_path):
		return false
	var packed: PackedScene = load(glb_path)
	var model := packed.instantiate()
	var mesh_node := _find_node_named(model, "Mesh")
	if mesh_node == null:
		model.queue_free()
		return false
	_clear_old_primitive_body()
	for part_name in ["Mesh", "Leg0", "Leg1", "HeadMarker"]:
		var part := _find_node_named(model, part_name)
		if part != null:
			part.get_parent().remove_child(part)
			add_child(part)
	model.queue_free()
	var hm := get_node_or_null("HeadMarker")
	if hm != null and hm is Node3D:
		_build_googly_eyes_marker(hm, 0.115)
	return true

## Recursive child-name search -- same small helper animal.gd/npc.gd each
## keep their own copy of.
func _find_node_named(root: Node, part_name: String) -> Node:
	if root.name == part_name:
		return root
	for c in root.get_children():
		var found := _find_node_named(c, part_name)
		if found != null:
			return found
	return null

# Same shared googly-eye look, attached to the real model's HeadMarker empty.
func _build_googly_eyes_marker(parent: Node3D, head_radius: float) -> void:
	for side in [-1.0, 1.0]:
		var eye := MeshInstance3D.new()
		var es := SphereMesh.new()
		es.radius = head_radius * 0.32
		es.height = head_radius * 0.64
		eye.mesh = es
		eye.position = Vector3(side * head_radius * 0.55, head_radius * 0.25, head_radius * 0.85)
		eye.material_override = MatCache.flat(Color(1, 1, 1))
		parent.add_child(eye)

		var pupil := MeshInstance3D.new()
		var ps := SphereMesh.new()
		ps.radius = head_radius * 0.14
		ps.height = head_radius * 0.28
		pupil.mesh = ps
		pupil.position = Vector3(randf_range(-0.04, 0.04) * head_radius, randf_range(-0.04, 0.04) * head_radius, head_radius * 0.3)
		pupil.material_override = MatCache.flat(Color(0.05, 0.05, 0.05))
		eye.add_child(pupil)

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
	var spd := Vector2(velocity.x, velocity.z).length()
	# Kenney/Quaternius model: a REAL rig with its own baked walk/idle clips
	# -- play those instead of BodyAnim's procedural bob (anim.tick()/
	# _animate_legs() already no-op safely for this body since _anim_parts()/
	# _legs stay empty when there's no "Mesh"/"Leg0" to find, but skip the
	# dead work anyway). Quaternius checked first since it's the
	# higher-priority tier (see _maybe_upgrade_to_real_model()); only one of
	# the two is ever non-null on a given member.
	var real_anim: AnimationPlayer = _quaternius_anim if _quaternius_anim != null else _kenney_anim
	if real_anim != null:
		var clip := "walk" if spd > 0.3 else "idle"
		if real_anim.has_animation(clip) and real_anim.current_animation != clip:
			real_anim.play(clip)
		return
	if anim == null:
		return
	# alert & upright when bonded and fed; slumped when hungry or walking out
	var m := clampf(relationship * 0.45 - hunger / 110.0, -1.0, 1.0)
	if _leaving:
		m = -1.0
	anim.mood = m
	# nerves from a fresh hit fade out over a second or so
	anim.tension = maxf(0.0, anim.tension - delta * 1.5)
	anim.tick(delta, spd, is_on_floor())
	_animate_legs(delta, spd)

## Real per-leg walk cycle for the biped model -- alternating gait (left/right
## swing opposite), the natural walk for 2 legs, same rotate-from-hip
## technique as animal.gd's 4-leg version. No-op on the old capsule fallback
## (_legs stays empty there).
const LEG_SWING_MAX := 0.5
const LEG_SWING_REF_SPEED := 2.0

## AXIS FIX (2026-07-27): "legs go sideways not forward/backward" -- see
## animal.gd's own copy of this fix for the full explanation. Rotating LOCAL
## Z (not X) is what swings the foot fore-and-aft after the Blender->glTF
## Y-up export remaps axes (forward/back stays Godot X, Blender's side-to-
## side Y becomes Godot Z).
func _animate_legs(delta: float, speed: float) -> void:
	if _legs.size() < 2:
		return
	var move := clampf(speed / LEG_SWING_REF_SPEED, 0.0, 1.0)
	if move < 0.03:
		for l in _legs:
			(l as Node3D).rotation.z = move_toward((l as Node3D).rotation.z, 0.0, delta * 6.0)
		return
	_leg_phase += delta * (5.0 + speed * 2.0)
	var swing := LEG_SWING_MAX * move
	(_legs[0] as Node3D).rotation.z = sin(_leg_phase) * swing
	(_legs[1] as Node3D).rotation.z = sin(_leg_phase + PI) * swing

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
const REAL_AXE_GLB := "res://assets/survival/tool-axe.glb"
# REAL ASSETS (2026-07-27): joe345's "Low Poly Simple Melee Weapon Pack"
# (itch.io, CC0, downloaded not generated) -- a different source than the
# Kenney/OpenGameArt packs used everywhere else, per "let's use a bunch of
# assets from different sources". Both are single-mesh, multiple flat
# (untextured) material slots baked per-part -- confirmed via inspection, so
# material_override is deliberately left null to keep their baked coloring
# (recoloring would flatten blade/handle/grip to one solid color and lose
# the multi-tone look these were modeled with).
const REAL_DAGGER_GLB := "res://assets/weapons/Dagger.glb"
const REAL_SPEAR_GLB := "res://assets/weapons/Spear.glb"
var _real_axe_mesh: Mesh = null   # cached so repeated tier-swaps don't re-load the file
var _real_dagger_mesh: Mesh = null
var _real_spear_mesh: Mesh = null

func _update_weapon_visual() -> void:
	_visual_weapon = weapon
	var mesh: Mesh
	var mat: StandardMaterial3D = null   # null = use the real model's own baked texture, not a flat override
	var rot := Vector3(55, 0, 0)
	var scl := Vector3.ONE
	match weapon:
		1:  # Spear -- REAL ASSET: joe345's Spear.glb, same long Y-axis shaft
			# the old CylinderMesh (height 1.3) used, so the same default
			# rot=(55,0,0) this codebase already held it at still applies.
			mesh = _get_real_spear_mesh()
			if mesh != null:
				scl = Vector3(0.6, 0.6, 0.6)   # measured height 2.196 -- scaled to the old cylinder's 1.3
			else:
				var cyl := CylinderMesh.new()
				cyl.top_radius = 0.03
				cyl.bottom_radius = 0.03
				cyl.height = 1.3
				mesh = cyl
				mat = MatCache.flat(Color(0.62, 0.56, 0.42))
		2:  # Bow -- a squashed ring read edge-on as a curved bow silhouette
			# (no bow in the melee weapon pack -- stays a primitive)
			var tor := TorusMesh.new()
			tor.inner_radius = 0.22
			tor.outer_radius = 0.27
			mesh = tor
			mat = MatCache.flat(Color(0.35, 0.22, 0.12))
			rot = Vector3(0, 0, 90)
			scl = Vector3(0.45, 1.0, 1.0)   # squash the torus into a bow curve
		3:  # Axe -- REAL ASSET (2026-07-27): Kenney Survival Kit's
			# tool-axe.glb (CC0, downloaded not generated), textured, used
			# AS-IS (mat stays null -- no override). Falls back to the old
			# flat box head if the asset is missing.
			mesh = _get_real_axe_mesh()
			if mesh != null:
				rot = Vector3(0, 0, 0)
				scl = Vector3(2.2, 2.2, 2.2)   # tool-axe.glb measured ~0.11x0.256x0.03 -- scaled to a held-weapon size
			else:
				var box := BoxMesh.new()
				box.size = Vector3(0.34, 0.06, 0.30)
				mesh = box
				mat = MatCache.flat(Color(0.6, 0.62, 0.66), 0.4, 0.6)
		_:  # Club (0, and any unrecognised tier) -- REAL ASSET: joe345's
			# Dagger.glb, the smallest/plainest blade in the pack, standing
			# in for the starting-tier weapon. Falls back to the original
			# plain stick if missing.
			mesh = _get_real_dagger_mesh()
			if mesh != null:
				scl = Vector3(2.5, 2.5, 2.5)   # measured height 0.312 -- scaled to the old club box's 0.8 length
			else:
				var clm := BoxMesh.new()
				clm.size = Vector3(0.1, 0.1, 0.8)
				mesh = clm
				mat = MatCache.flat(Color(0.45, 0.30, 0.15))
	_club_model.mesh = mesh
	_club_model.material_override = mat
	_club_model.rotation_degrees = rot
	_club_model.scale = scl

func _get_real_axe_mesh() -> Mesh:
	if _real_axe_mesh != null:
		return _real_axe_mesh
	if not ResourceLoader.exists(REAL_AXE_GLB):
		return null
	var packed: PackedScene = load(REAL_AXE_GLB)
	var inst := packed.instantiate()
	var found := _find_node_named(inst, "tool-axe")
	if found == null or not (found is MeshInstance3D):
		inst.queue_free()
		return null
	_real_axe_mesh = (found as MeshInstance3D).mesh
	inst.queue_free()
	return _real_axe_mesh

func _get_real_dagger_mesh() -> Mesh:
	if _real_dagger_mesh != null:
		return _real_dagger_mesh
	if not ResourceLoader.exists(REAL_DAGGER_GLB):
		return null
	var packed: PackedScene = load(REAL_DAGGER_GLB)
	var inst := packed.instantiate()
	var found := _find_node_named(inst, "Dagger")
	if found == null or not (found is MeshInstance3D):
		inst.queue_free()
		return null
	_real_dagger_mesh = (found as MeshInstance3D).mesh
	inst.queue_free()
	return _real_dagger_mesh

func _get_real_spear_mesh() -> Mesh:
	if _real_spear_mesh != null:
		return _real_spear_mesh
	if not ResourceLoader.exists(REAL_SPEAR_GLB):
		return null
	var packed: PackedScene = load(REAL_SPEAR_GLB)
	var inst := packed.instantiate()
	var found := _find_node_named(inst, "Spear")
	if found == null or not (found is MeshInstance3D):
		inst.queue_free()
		return null
	_real_spear_mesh = (found as MeshInstance3D).mesh
	inst.queue_free()
	return _real_spear_mesh

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
	# BURST TRAUMA: read BurstTrauma's recovery variable BEFORE this hit's own
	# stimulation (same "read prior state first" pattern as BetrayalFatigue's
	# betray()) -- captures whether the PREVIOUS hit is still "ringing" in this
	# neuron's state right now, elevated (>BURST_TRAUMA_ELEVATED_U) only if it
	# landed within about a real second of this one. See the pre-registered
	# claim above _trauma_hit_count for the real calibration numbers.
	var _burst_prior_u: float = brain.izhikevich_recovery("BurstTrauma")
	brain.stimulate("BurstTrauma", 80.0)
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
	_trauma_hit_count += 1
	# BURST TRAUMA: a hit landing while the previous one is still "ringing"
	# (BurstTrauma's iz_u still elevated from it) counts as an extra, phantom
	# trauma hit ON TOP OF the real one -- an ambush of rapid blows reaches
	# the Wary shift on fewer REAL hits than the same total spread out. Never
	# fires for anyone who never takes burst damage (iz_u stays at/below the
	# resting baseline the whole time, this branch is simply never taken,
	# _trauma_hit_count behaves exactly as it always has).
	if _burst_prior_u > BURST_TRAUMA_ELEVATED_U:
		_trauma_hit_count += 1
		_trauma_burst_bonus_count += 1
	if _trauma_hit_count >= TRAUMA_HITS_PER_SHIFT:
		_trauma_hit_count = 0
		_maybe_shift_personality("Wary", "After everything I've survived, I trust the world less now.")
	if hp <= 0.0:
		die(attacker)
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
	var sight := _effective_sight()
	var was_seeing_raider := sees_raider
	var raider_d := _nearest_distance("npc", sight, true)
	sees_raider = raider_d >= 0.0
	if sees_raider:
		brain.stimulate("SawRaider", _proximity_drive(raider_d, sight))
		if not was_seeing_raider:
			TribeMemory.remember(member_name, "saw_raider", "You",
				"I spotted a rival tribesperson nearby.", "wary", 0.0)

	var was_seeing_prey := sees_prey
	var prey_d := _nearest_distance("animal", sight, false)
	sees_prey = prey_d >= 0.0
	if sees_prey:
		brain.stimulate("SawPrey", _proximity_drive(prey_d, sight))
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

## "feeds strangers to at least 30% as a base" -- distinct from
## _maybe_share_food() above, which only ever shares with EXISTING tribe
## members (group "tribe"). This reaches actual outsiders (group "neutral",
## not yet recruited at all) -- the founding recruiter's whole reason for
## being good at winning people over. Rolled independently, so it doesn't
## compete with or reduce the ordinary tribe-only sharing chance.
func _maybe_feed_a_stranger() -> void:
	if not is_founding_recruiter or inv_food <= 0:
		return
	if randf() > FOUNDING_RECRUITER_FEED_CHANCE:
		return
	for o in SpatialGrid.query(global_position, SHARE_RADIUS, "neutral"):
		var n := o as Node3D
		if n == null or not is_instance_valid(n):
			continue
		inv_food -= 1
		TribeMemory.remember(member_name, "shared_food", str(n.get("member_name")),
			"I gave food to a stranger -- word of my tribe's generosity spreads.", "warm", 0.0)
		return

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

func die(attacker = null, cause: String = "") -> void:
	print("[%s] has fallen. (%s)" % [member_name, cause if cause != "" else "unknown cause"])
	if manager and manager.has_method("on_member_died"):
		manager.on_member_died(self, attacker, cause)
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
		weapon_pref.on_combat_success(weapon)

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
		weapon_pref.on_combat_success(0)   # club-throw is always the Club type, regardless of equipped weapon tier
	return true

# ── BOW (2026-08-28): a member with WEAPON_TIERS[2] "Bow" equipped fires a
# real physical arrow (tribe_arrow.gd) at range, instead of relying on the
# club-throw path above (which is gated on the shared club stock, a
# different resource). Longer range than THROW_RANGE, no ammo cost -- an
# equipped bow is the resource, matching how equipped armor has no per-use
# cost either.
const BOW_RANGE := 14.0
var _bow_cd: float = 0.0
func _try_shoot_arrow_at(foe) -> bool:
	if weapon != 2:   # WEAPON_TIERS index 2 == "Bow"
		return false
	if _bow_cd > 0.0 or foe == null or not is_instance_valid(foe):
		return false
	_bow_cd = 1.4
	var f := (foe as Node3D).global_position - global_position
	f.y = 0.0
	if f.length() < 0.01:
		return false
	rotation.y = lerp_angle(rotation.y, atan2(f.x, f.z), 0.5)
	var dmg := 6.0 + float(get_might()) * 0.7
	dmg *= weapon_mult()
	var arrow = load("res://tribe_arrow.gd").new()
	get_tree().current_scene.add_child(arrow)
	var origin: Vector3 = global_position + Vector3.UP * 1.3
	var dir: Vector3 = ((foe as Node3D).global_position + Vector3.UP * 0.9 - origin).normalized()
	arrow.launch(origin, dir, 22.0, dmg, self)
	if anim:
		anim.pop(0.25)
	return true

# ── WAND / SPELLS (2026-08-28): a member with WEAPON_TIERS[4] "Wand"
# equipped casts a real magic bolt (tribe_spell_bolt.gd) with a burn DoT --
# tribe's first "magic" weapon. Same range-preference shape as the bow.
const WAND_RANGE := 12.0
var _wand_cd: float = 0.0
func _try_cast_at(foe) -> bool:
	if weapon != 4:   # WEAPON_TIERS index 4 == "Wand"
		return false
	if _wand_cd > 0.0 or foe == null or not is_instance_valid(foe):
		return false
	_wand_cd = 1.8
	var f := (foe as Node3D).global_position - global_position
	f.y = 0.0
	if f.length() < 0.01:
		return false
	rotation.y = lerp_angle(rotation.y, atan2(f.x, f.z), 0.5)
	var dmg := 5.0 + float(get_might()) * 0.6
	dmg *= weapon_mult()
	var bolt = load("res://tribe_spell_bolt.gd").new()
	get_tree().current_scene.add_child(bolt)
	var origin: Vector3 = global_position + Vector3.UP * 1.3
	var dir: Vector3 = ((foe as Node3D).global_position + Vector3.UP * 0.9 - origin).normalized()
	bolt.launch(origin, dir, 16.0, dmg, 3.0, self)
	if anim:
		anim.pop(0.25)
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
	# the real model's legs are SEPARATE MeshInstance3D objects (see
	# tools/gen_humans.py) -- recolor them too so the whole body reads as one
	# uniformly-tinted person instead of a mismatched torso+legs.
	for leg in _legs:
		if leg is MeshInstance3D:
			leg.material_override = mat

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
			_maybe_feed_a_stranger()

	# register in the world spatial grid so rival npc.gd's "tribe" group
	# queries (intruder/outnumber/war-target checks) can find us without
	# scanning every member in the world — see spatial_grid.gd
	_grid_cd -= delta
	if _grid_cd <= 0.0:
		_grid_cd = 0.25
		SpatialGrid.update(self)

	# ROUTE MEMORY: record this position as visited (reinforces the cell +
	# any transition from the last cell), then periodically let unused
	# cells/edges decay -- same LOD gate as the brain since a member the
	# player can't see doesn't need route learning either.
	if not _far_from_player:
		route_memory.visit(global_position)
	_route_decay_accum += delta
	if _route_decay_accum >= ROUTE_DECAY_INTERVAL:
		_route_decay_accum = 0.0
		route_memory.decay(1.0)

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
	# PERF/CORRECTNESS FIX (2026-07-27): this used to scan the FULL "fence",
	# "block", AND "tree" groups (unbounded, whole-world) every time ANY
	# member got stuck -- tree_count alone can be 1000-2600 at Skirmish/Epic
	# scale, and this session's own fortress-tier work (a 3rd wall course +
	# four watchtowers) made "block" substantially bigger too. But NONE of
	# those three groups can EVER be the real physical cause of a member
	# being stuck: fence/block (and every build_piece: stair/roof/door/
	# small) sit on collision layer 8, which a tribemember's default
	# collision mask doesn't intersect at all -- "Walls are now on collision
	# layer 4 which AI doesn't mask... members phase through them" (see
	# block.gd's own comment, which already said "this recovery is only for
	# terrain steps / each other now" -- the expensive scan just never
	# actually got removed to match). Trees have NO collision shape at all
	# (see tree.gd). Replaced with a bounded SpatialGrid query against
	# "tribe" -- other members ARE real, same-layer colliders, already
	# indexed there for exactly this kind of proximity check, and are the
	# one group that can genuinely be the cause.
	var obstacle: Node3D = null
	var od := 2.2
	for o in SpatialGrid.query(global_position, od, "tribe"):
		var fn := o as Node3D
		if fn == null or fn == self or not is_instance_valid(fn):
			continue
		var d := global_position.distance_to(fn.global_position)
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
	_evaluate_peer_contribution()
	if manager == null or not manager.has_method("suggest_job"):
		return
	# NIGHT AT THE FIRE (2026-07-19): "make night time come and tribes light
	# campfires, gossip, talk, laugh, and do ceremonial dances around the
	# fire" -- most idle members head to the real campfire (see
	# campfire.gd/Tribemanager.is_night) instead of self-assigning ordinary
	# work; a standing leader order (checked above, before this point) still
	# overrides it, same precedence every other autonomous choice respects.
	if manager.get("is_night") == true and randf() < 0.7 and _night_campfire_behavior():
		return
	# EXPERT RECRUITER (2026-07-19): the founding companion actively looks
	# for a wanderer to win over rather than waiting on the tribe-wide
	# suggest_job() roll (which only tries "recruit" ~20% of the time) --
	# this is what "expert" actually means for them.
	if is_founding_recruiter and _nearest_neutral() != null:
		_start_job("recruit")
		return
	# PRACTICE-DRIVEN CRAFTING (2026-07-19): "professions have to use real
	# materials from in game" + "npcs need to do all the abilities I've given
	# them" -- a member who's already put real practice into Blacksmithing
	# (skill_in > 0, so they've earned at least the next tier) occasionally
	# forges their own upgrade on their own initiative, through the SAME
	# gated craft_weapon()/craft_armor() path a player-directed order uses --
	# real materials spent, same skill-tier gate, just self-initiated.
	if RANK_LOYALTY.get(current_rank, 0) >= RANK_LOYALTY["Acquaintance"] and skill_in("Blacksmithing") > 0.0 and randf() < 0.15:
		# bounded to BLACKSMITH_MAX_WEAPON_TIER (Axe), not WEAPON_TIERS.size() - 1:
		# a member already at Axe has nothing left to self-forge (Wand isn't a
		# Blacksmithing recipe -- see craft_weapon()'s own note above).
		var next_weapon: int = mini(weapon + 1, BLACKSMITH_MAX_WEAPON_TIER)
		if next_weapon > weapon and craft_weapon(next_weapon):
			return
		var next_armor: int = mini(armor + 1, ARMOR_TIERS.size() - 1)
		if next_armor > armor and craft_armor(next_armor):
			return
	# ALL 30 PROFESSIONS PRODUCE (2026-07-19): the generic counterpart to the
	# Blacksmithing-specific weapon/armor path above -- ANY profession this
	# member has practiced at all gets a real, working, materials-spending
	# action, not just skill numbers that never do anything. Same trust bar
	# as the crafting path (Acquaintance+ -- a total Stranger doesn't get to
	# spend the tribe's shared materials on their own initiative).
	if RANK_LOYALTY.get(current_rank, 0) >= RANK_LOYALTY["Acquaintance"] and profession != "" \
			and profession != "Blacksmithing" and skill_in(profession) > 0.0 and randf() < 0.15:
		if _practice_and_produce(profession):
			return
	# MIGRATION (2026-07-31): so far only a settlement's FOUNDER ever actually
	# lived there -- everyone else stayed anchored at the original camp
	# forever. A small, ongoing chance for an otherwise-idle member to join
	# an existing settlement instead of picking a normal job spreads real
	# population across the clan's cities rather than leaving each one a
	# population of one. Picks the LEAST populated settlement so migrants
	# spread out instead of piling onto whichever was founded first.
	# BUG FIXED (2026-07-19): this fired for EVERY member regardless of trust --
	# a total Stranger could relocate to (and start drawing from/depositing
	# into) a settlement's economy with zero loyalty earned, unlike every
	# other autonomous action (which routes through give_order()'s
	# ORDER_RISK/RANK_LOYALTY check). Migrating is a real commitment, not a
	# chore, so gate it at the same bar as a trusted, self-directed gather.
	if randf() < MIGRATE_CHANCE and RANK_LOYALTY.get(current_rank, 0) >= RANK_LOYALTY["Acquaintance"] \
			and manager.has_method("least_populated_outpost"):
		var dest = manager.least_populated_outpost(home_pos)
		if dest != null:
			_start_migrate((dest as Node3D).global_position)
			return
	_start_job(manager.suggest_job(self))

# TUNING (2026-08-02): was 0.02 -- with an idle job-pick roughly every 3-7s,
# that's an EXPECTED ~4-8 MINUTES before a single member even rolls the
# check once, let alone finds a valid destination. Reported live as "new
# features not happening" -- the ability existed but at odds too low to
# actually surface in a normal play session. Raised to a rate that shows up
# within a couple of minutes of idle time instead of requiring a long
# unattended session to ever observe.
const MIGRATE_CHANCE := 0.08   # per idle job-pick

func _start_migrate(dest: Vector3) -> void:
	is_busy = true
	_task_kind = "migrate"
	_task_paid = false
	_target_node = null
	_task_food = 0
	_task_mats = 0
	_task_wood = 0
	_task_result = ""
	_target = dest
	_work_time = 240.0   # a settlement can be well over 100m away -- allow the trek
	state = St.AWAY
	_think("Time to join the new settlement.", 2.5)

func _start_job(job: String, forced: bool = false) -> void:
	# BUG FIXED (2026-07-19): "build"/"carve" bypass give_order()'s ORDER_RISK
	# check by design (see the comment above ORDER_RISK -- they're not in that
	# table at all), which meant an UNFORCED (self-picked) build/carve had NO
	# trust gate whatsoever: a total Stranger could raise fortress walls or
	# spend the tribe's wood on a club the moment they wandered in. A leader's
	# forced standing order still bypasses this untouched (that's deliberate --
	# see _accept_order above); only the autonomous self-pick is gated now.
	if not forced and job in ["build", "carve"] and current_rank == "Stranger":
		return
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
	# WEATHER (2026-07-22): a storm is cold and miserable, not free -- see
	# Tribemanager.hunger_mult() (1.0 in clear/fog, higher in rain/storm).
	var weather_mult: float = manager.hunger_mult() if (manager and manager.has_method("hunger_mult")) else 1.0
	hunger = minf(100.0, hunger + delta * HUNGER_RATE * weather_mult)
	if hunger >= EAT_AT and inv_food > 0:
		inv_food -= 1
		hunger = maxf(0.0, hunger - EAT_RESTORE)
	elif hunger >= EAT_AT and current_rank != "Stranger" \
			and manager and manager.has_method("spend_food_at"):
		# TRUST-GATED STOCKPILE ACCESS (2026-07-17): previously a member's own
		# ration (inv_food, replenished only by their own gathering) was the
		# ONLY source of food they could ever draw on -- once it ran dry they
		# starved regardless of how much you trusted them, and only the
		# PLAYER could ever touch the shared stockpile. A Stranger hasn't
		# earned that access; anyone Acquaintance rank or better ("level 1"
		# trust -- the first real tier above the untrusted default) now can.
		# PER-SETTLEMENT ECONOMIES (2026-08-04): a resident draws from their
		# OWN settlement's local stockpile first (spend_food_at() falls
		# through to the original shared spend_food() for everyone else).
		if manager.spend_food_at(home_pos, 1):
			hunger = maxf(0.0, hunger - EAT_RESTORE)
			TribeMemory.remember(member_name, "self_fed", "You",
				"I helped myself to the stockpile -- you trust me enough for that now.",
				"neutral", 0.0)
	if hunger >= 100.0:
		starve(delta)                       # bond rots, may defect
		hp = maxf(0.0, hp - delta * 2.0)    # and they physically weaken
		if hp <= 0.0:
			# REAL CAUSE, NOT ASSUMED (2026-07-19): "they need to react to the
			# real reason an npc died... they shouldn't get mad if they have
			# access" -- a Stranger who starved was genuinely denied trust-
			# based stockpile access (see the elif above); an Acquaintance+
			# member who starved anyway HAD access -- the stockpile itself
			# ran dry, a supply failure, not the leader denying them anything.
			# on_member_died()/blame_leader_for_hunger_death() react
			# differently to each.
			die(null, "starvation" if current_rank == "Stranger" else "starvation_had_access")

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
	# PLAYER REPUTATION (2026-08-28): this is a real positive interaction --
	# feeds the recognition layer distinct from `relationship` itself.
	player_rep.on_good_deed()
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
	# BETRAYAL FATIGUE: read whatever fatigue accumulated from a PRIOR
	# betrayal (0.0 for a source's first-ever hit, or once enough real time
	# has passed for tau_w to decay it away -- see the neuron comment above)
	# BEFORE this event's own stimulation adds to it, then queue a partial
	# counter-offset to land on Trust the same tick the real -160 synapse
	# does. The -160 SawBetray->Trust synapse itself is completely
	# unmodified below -- this only adds a separate, smaller, opposing
	# stimulus alongside it.
	var _fatigue_prior: float = brain.adex_adaptation("BetrayalFatigue")
	var _counter: float = BETRAYAL_FATIGUE_MAX_OFFSET * clampf(_fatigue_prior / BETRAYAL_FATIGUE_SATURATION, 0.0, 1.0)
	# ticks_left=1: skip the next _brain_tick() (the one where SawBetray
	# itself fires), apply on the one after that (where its synapse arrives).
	_pending_betrayal_counters.append({"ticks_left": 1, "amount": _counter})
	brain.stimulate("SawBetray", 80.0)
	brain.stimulate("BetrayalFatigue", 80.0)
	betrayed_count += 1
	_attend_idle_time = 0.0
	# PLAYER REPUTATION (2026-08-28): a real negative interaction.
	player_rep.on_bad_deed()
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

## SEASONAL MOOD MIGRATION (2026-07-19): a real, continuously-updated read of
## how often THIS member's own Trust/Follow neurons are actually firing --
## the tribe-wide aggregate of this (see Tribemanager._mood_tick()) is what
## decides whether the tribe splits, driven by real brain activity instead
## of a scripted "morale" number.
const TRUST_FOLLOW_EMA_DECAY := 0.995
var _trust_follow_ema: float = 0.5
func trust_follow_mood() -> float:
	return _trust_follow_ema

func _brain_tick() -> void:
	# BETRAYAL FATIGUE: apply any queued counter-offset(s) whose delay has
	# elapsed NOW, immediately before step() -- lands in the exact same
	# step() call as the real SawBetray -> Trust synapse's delay=1 arrival
	# (see betray()'s comment), not one tick early or late.
	if not _pending_betrayal_counters.is_empty():
		var _still_pending: Array = []
		for entry in _pending_betrayal_counters:
			if entry["ticks_left"] <= 0:
				brain.stimulate("Trust", entry["amount"])
			else:
				entry["ticks_left"] -= 1
				_still_pending.append(entry)
		_pending_betrayal_counters = _still_pending
	var fired: Array = brain.step()
	if not fired.is_empty():
		_drum_fired_neurons(fired)
	var tf: float = 1.0 if ("Trust" in fired or "Follow" in fired) else 0.0
	_trust_follow_ema = _trust_follow_ema * TRUST_FOLLOW_EMA_DECAY + tf * (1.0 - TRUST_FOLLOW_EMA_DECAY)
	if "Follow" in fired:
		follow_fires += 1
		# PLAYER REPUTATION (2026-08-28): a real-remembered pattern of good/bad
		# treatment speeds up or slows down how fast trust builds from here.
		relationship = minf(RELATIONSHIP_MAX, relationship + FOLLOW_FIRE_REL_GAIN * player_rep.reputation_gain_mult())
		_update_rank()
		if follow_fires >= follow_threshold_hits and not is_backing_you:
			is_backing_you = true
			_on_now_backing_you()
	# strengthen trust connections that just co-fired (visible learning)
	# STDP mode (2026-08-28, opt-in via ProjectSettings "tribe/use_stdp"):
	# real spike-TIMING-dependent plasticity instead of same-step co-fire.
	# Kept switchable, not a silent replace, so behavior can be A/B compared.
	if ProjectSettings.get_setting("tribe/use_stdp", false):
		brain.stdp_learn(0.5)
	else:
		brain.learn(1.0, 0.5)

## Called externally by Tribemanager when the TRIBE'S aggregate mood (not
## this member's own relationship threshold) has been low for too long --
## a real collective consequence, distinct from the existing individual
## defection path (relationship < DEFECT_THRESHOLD, see _process below).
func mass_migrate_out(reason: String) -> void:
	if _leaving:
		return
	is_backing_you = false
	_leaving = true
	_think(reason, 3.0)

## GENERATIVE DRUM CIRCLE (2026-07-19): "the tribe's actual trust/fear/hunger
## dynamics becoming the literal rhythm of their music" -- every real neuron
## fire is a real, timestamped event already; this is the ONLY place that
## decides whether it's audible right now (TribeDrums itself just owns the
## synthesis, not this judgment). Scoped to gathered, idle members at the
## real campfire at night -- the actual drum circle moment this game
## already has, not constant background noise from the whole map.
## Real, measured mechanism (npc_rhythm_sync_experiment.gd, 6/6 seeds,
## 2026-07-19): completely independent brains phase-lock into a real drum
## circle purely from each one hearing the SAME shared ambient level and
## feeding a little of it back into its own firing. Every gathered member
## reads TribeDrums' one shared ambient scalar and feeds it back into its
## own "Trust" neuron -- the confirmed coupling mechanism, pointed at the
## real trust-economy brain instead of a bare test oscillator.
const RHYTHM_COUPLING := 0.20   # the value the experiment found already saturates near-full lock
func _drum_fired_neurons(fired: Array) -> void:
	if manager == null or manager.get("is_night") != true:
		return
	var fire := _nearest_campfire()
	if fire == null or global_position.distance_to(fire.global_position) > TribeDrums.CAMPFIRE_AUDIBLE_RANGE:
		return
	for name in fired:
		var velocity: float = brain.fire_strength(str(name)) if brain.has_method("fire_strength") else 1.0
		TribeDrums.on_neuron_fired(str(name), true, velocity)
	var ambient: float = TribeDrums.ambient_level()
	if ambient > 0.0:
		brain.stimulate("Trust", RHYTHM_COUPLING * ambient * 50.0)

func _update_rank() -> void:
	_ensure_rank_gates()
	var new_rank := "Stranger"
	for r in RANKS:
		var name: String = String(r[0])
		if name == "Stranger":
			continue
		var attained: bool = (_rank_gates[name] as HysteresisGate).update(relationship)
		if attained:
			new_rank = name   # RANKS is ascending, so the last attained gate wins
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
		_update_social_role()   # a rank change can immediately make/unmake an Official

# a real job kind maps to the role that best reflects it -- "raid"/"guard"
# both read as martial work, "wood"/"carve" as basic labor, "build" (raising
# the actual fortress ring) as the more skilled trade.
const JOB_TO_ROLE := {
	"gather": "Forager", "hunt": "Hunter", "wood": "Builder",
	"carve": "Builder", "build": "Elite Builder", "scout": "Spy",
	"guard": "Warrior", "raid": "Warrior", "recruit": "Trader",
}

## Recomputes social_role from what this member actually does. Official and
## Outpostman are checked FIRST and override the job-tally result entirely --
## both are earned through something bigger than any single task (sustained
## top-tier loyalty within a real, tribe-size-scaled quota; or literally
## having founded/migrated to a settlement), not just "did this job most".
func _update_social_role() -> void:
	if current_rank == "Devoted" and manager and manager.has_method("is_official") and manager.is_official(self):
		social_role = "Official"
		return
	if manager and manager.has_method("is_outpostman") and manager.is_outpostman(home_pos):
		social_role = "Outpostman"
		return
	var best_job := ""
	var best_count := 0
	for k in _job_counts:
		var c: int = int(_job_counts[k])
		if c > best_count:
			best_count = c
			best_job = k
	social_role = str(JOB_TO_ROLE.get(best_job, "Forager"))

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
		"Soulbound": return "I feel you now, even when you're far away."
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
	# AUTO-ASSUME TRUSTED WORK (2026-07-19): "npcs constantly refusing work
	# orders, they should auto assume work if they don't trust enough to do
	# it, only auto assign what trust allows" -- a flat refusal used to just
	# leave them standing idle until the next autonomous re-roll (which could
	# propose the exact same too-risky job right back, on a self-directed
	# pick). Now a refusal falls through to the MOST substantial real work
	# this member's own current drive genuinely clears -- real delegation
	# downward, not a bypass: it's still gated by the same drive/risk math,
	# just against a lower bar than what was actually asked for.
	var fallback: String = _best_trusted_fallback(drive, kind)
	if fallback != "":
		_think("I don't trust you enough for that yet -- I'll %s instead." % fallback, 2.4)
		TribeMemory.remember(member_name, "ordered", "You",
			"You asked me to %s, but I only trust you enough to %s." % [kind, fallback], "neutral", 0.0)
		_accept_order(fallback, false)
		return true
	_refuse_order(kind)
	return false

## Highest-risk (most substantial) order kind this member's CURRENT drive
## actually clears, excluding the one just refused and "come" (a summons,
## not real work). Empty string if nothing at all is trusted yet -- a true
## Stranger with a timid personality genuinely has nothing to fall back to.
const FALLBACK_ORDER := ["scout", "guard", "hunt", "mine", "recruit", "gather", "wood"]

func _best_trusted_fallback(drive: int, exclude_kind: String) -> String:
	for k in FALLBACK_ORDER:
		if k == exclude_kind:
			continue
		if k == "hunt" and (manager == null or not manager.has_method("clubs_available") or manager.clubs_available() <= 0):
			continue
		if drive >= int(ORDER_RISK.get(k, 999)):
			return k
	return ""

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
		"mine":
			_work_time = 26.0   # minerals sit up in the hills -- a real hike
			_target_node = _nearest_mineral()
			if _target_node:
				_search_streak = 0
				_think("Off to the hills to mine.", 2.0)
			else:
				_begin_fallback("No ore or stone nearby to mine...")
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
			# RESIDENCE (2026-07-31): the founder becomes the settlement's
			# first real resident, not just its builder -- home_pos is the
			# actual anchor _wander()/_begin_fallback() center a member's
			# whole local life on, so re-planting it here means this member
			# genuinely lives at the new settlement from now on instead of
			# drifting back toward the original camp once idle.
			home_pos = global_position
			TribeMemory.remember(member_name, "founded_outpost", "You",
				"I'd wandered far enough from camp that I raised a new stockpile right here -- this is home now.",
				"proud", 0.05)
			_think("New ground -- a stockpile goes here! I'll settle here.", 2.8)
			return
	var radius: float = minf(SEARCH_RADIUS_MAX,
		SEARCH_RADIUS_BASE + float(_search_streak - 1) * SEARCH_RADIUS_GROWTH)
	if _search_streak <= 1:
		# first failure of a fresh streak -- lock in a heading and an origin,
		# both held fixed for the rest of this streak (see the comment on
		# _search_dir above)
		var ang := randf() * TAU
		_search_dir = Vector3(cos(ang), 0.0, sin(ang))
		_search_origin = global_position
	_target = _search_origin + _search_dir * radius
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

## AWARENESS FIX (2026-07-19): minerals never had a picker at all -- see
## mineral.gd's own SpatialGrid registration comment. Mirrors _nearest_tree().
func _nearest_mineral() -> Node3D:
	var best: Node3D = null
	var bd := INF
	var sight := _effective_sight()
	for m in SpatialGrid.query(global_position, sight, "mineral"):
		var n := m as Node3D
		if n == null or not is_instance_valid(n) or not n.has_method("collect"):
			continue
		var d := global_position.distance_to(n.global_position)
		if d > sight or d >= bd:
			continue
		if _is_claimed(n):
			continue
		bd = d
		best = n
	return best

func _do_mine() -> void:
	if _target_node and _target_node.has_method("collect"):
		var loot: Dictionary = _target_node.collect()
		var got: int = int(loot.get("amount", 0))
		_task_mats += got
		_task_result = "%s x%d" % [str(loot.get("type", "ore")), got]
		practice_profession("Mining")

const NIGHT_CAMPFIRE_RANGE := 2.5
const NIGHT_FIRE_LINES := [
	"Ha! You should have seen it -- I nearly lost my footing chasing that deer.",
	"They say the next valley over has better hunting grounds.",
	"Did you hear? Someone spotted a rival scout near the tree line today.",
	"I'm just glad to sit a while. My feet ache.",
	"Dance with me -- the fire's warm and the night is young!",
	"Gossip travels faster than any courier around this fire.",
]

func _nearest_campfire() -> Node3D:
	var best: Node3D = null
	var bd := INF
	for f in get_tree().get_nodes_in_group("campfire"):
		var n := f as Node3D
		if n == null or not is_instance_valid(n):
			continue
		var d := global_position.distance_to(n.global_position)
		if d < bd:
			bd = d
			best = n
	return best

## Idle members gather at the real campfire at night -- gossip, laughter,
## a bit of dancing (a playful spin via anim.pop, no dedicated dance
## animation exists). Returns true if this member is participating this
## tick (so _auto_work() knows not to also assign ordinary work).
func _night_campfire_behavior() -> bool:
	var fire := _nearest_campfire()
	if fire == null:
		return false
	if global_position.distance_to(fire.global_position) > NIGHT_CAMPFIRE_RANGE:
		var ang := randf() * TAU
		_target = fire.global_position + Vector3(cos(ang), 0.0, sin(ang)) * 1.5
		_target.y = home_pos.y
		_target_node = null
		state = St.WANDER
		return true
	if randf() < 0.25:
		say(NIGHT_FIRE_LINES[randi() % NIGHT_FIRE_LINES.size()], 2.5)
		if anim:
			anim.pop(0.6)   # a little spin/bounce -- the closest thing to a dance step
	return true

func _do_gather() -> void:
	if _target_node and _target_node.has_method("harvest"):
		var got: int = _target_node.harvest(4.0)
		# DISTRICT BONUS (2026-08-03): a Gathering settlement's own foragers
		# genuinely bring back more -- the real payoff Watch already got,
		# closed for the other two districts too.
		if manager and manager.has_method("gathering_bonus_at"):
			got = int(round(float(got) * manager.gathering_bonus_at(home_pos)))
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
## PERF FIX (2026-07-25): _is_claimed() was checked BEFORE the distance
## filter -- so with tree_count/bush_count/animal_count scaled up for a big
## world (e.g. 1700 trees), every single candidate in the group ran a full
## O(roster) claim-scan (a fresh get_nodes_in_group("tribe") call apiece)
## even for candidates far outside sight that the cheap distance check
## would have thrown out anyway. A real, measured contributor to reported
## lag: up to N_group * O(roster) group-lookups per job assignment, called
## every few seconds per idle member. Distance/sight/best-so-far are now
## checked FIRST (cheap, local math, no group lookup); _is_claimed() only
## runs on a candidate that has already cleared all of those -- for a
## typical camp that's a handful of calls per pick, not one per tree.
## SEARCH-EFFICIENCY FIX (2026-07-19): these four pickers used to scan
## get_tree().get_nodes_in_group(...) -- EVERY food_source/tree/animal/neutral
## in the whole world -- on every single call, discarding almost all of them
## on the cheap distance check right after. Now that food_source/tree/animal
## register with SpatialGrid (see their own scripts) and npc.gd already does
## for "neutral", these query only the handful of grid cells actually within
## sight -- the search got both LONGER RANGE (SIGHT_RADIUS above) and CHEAPER
## per call at the same time, instead of those trading off against each other.
func _nearest_food_source() -> Node3D:
	var best: Node3D = null
	var bd := INF
	var sight := _effective_sight()
	for b in SpatialGrid.query(global_position, sight, "food_source"):
		var n := b as Node3D
		if n == null or not is_instance_valid(n) or not n.has_method("harvest") or float(n.amount) < 1.0:
			continue
		var d := global_position.distance_to(n.global_position)
		if d > sight or d >= bd:
			continue
		if _is_claimed(n):
			continue
		bd = d
		best = n
	return best

func _nearest_animal() -> Node3D:
	var best: Node3D = null
	var bd := INF
	var sight := _effective_sight()
	for a in SpatialGrid.query(global_position, sight, "animal"):
		var n := a as Node3D
		if n == null or not is_instance_valid(n):
			continue
		var d := global_position.distance_to(n.global_position)
		if d > sight or d >= bd:
			continue
		if _is_claimed(n):
			continue
		bd = d
		best = n
	return best

func _nearest_neutral() -> Node3D:
	var best: Node3D = null
	var bd := INF
	var sight := _effective_sight()
	for n in SpatialGrid.query(global_position, sight, "neutral"):
		var nn := n as Node3D
		if nn == null or not is_instance_valid(nn):
			continue
		var d := global_position.distance_to(nn.global_position)
		if d > sight or d >= bd:
			continue
		if _is_claimed(nn):
			continue
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
	var sight := _effective_sight()
	# tree_count can be in the THOUSANDS on a big world -- see the perf-fix
	# comment on _nearest_food_source() above; the same cheap-first ordering
	# matters even more here.
	for t in SpatialGrid.query(global_position, sight, "tree"):
		var n := t as Node3D
		if n == null or not is_instance_valid(n) or not n.has_method("chop"):
			continue
		var d := global_position.distance_to(n.global_position)
		if d > sight or d >= bd:
			continue
		if _is_claimed(n):
			continue
		bd = d
		best = n
	return best

func _retarget() -> Node3D:
	match _task_kind:
		"hunt": return _nearest_animal()
		"gather": return _nearest_food_source()
		"wood": return _nearest_tree()
		"recruit": return _nearest_neutral()
		"mine": return _nearest_mineral()
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
	# SOCIETAL HIERARCHY (2026-08-03): track how many times each job kind has
	# actually been completed, so a member's real role in the tribe (see
	# _update_social_role()) reflects what they actually DO, not just a
	# fixed title -- a real hierarchy that grows out of behavior.
	_job_counts[k] = int(_job_counts.get(k, 0)) + 1
	_update_social_role()
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
	if k == "migrate":
		# arrived at the destination settlement -- re-anchor home_pos here,
		# the same real "I live here now" hook the founder already gets (see
		# _begin_fallback()'s own found_outpost() branch).
		home_pos = global_position
		TribeMemory.remember(member_name, "migrated", "You",
			"I left the old camp behind and settled at the new one.", "hopeful", 0.03)
		_think("I've settled in.", 2.5)
		return
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

	# keep personal rations first, then drop the SURPLUS in your stockpile --
	# PER-SETTLEMENT ECONOMIES (2026-08-04): a resident deposits into their
	# OWN settlement's local stockpile instead of the shared camp one (see
	# Tribemanager.add_food_at() and friends -- a non-resident falls straight
	# through to the original add_food()/add_materials()/add_wood(), so
	# nothing changes for the main camp).
	if _task_food > 0:
		var room := maxi(0, RATION_RESERVE - inv_food)
		var keep := mini(room, _task_food)
		inv_food += keep
		var surplus := _task_food - keep
		if surplus > 0 and manager and manager.has_method("add_food_at"):
			manager.add_food_at(home_pos, surplus)
			# BUG FIXED (2026-07-19): "stockpile shows no value change" was
			# real player confusion, not a routing bug -- per-settlement
			# economies (added earlier) mean a resident's surplus grows THEIR
			# settlement's local_food, not the shared camp's, so watching the
			# home stockpile while a settlement resident deposits legitimately
			# shows nothing moving. Naming the actual destination here removes
			# the ambiguity instead of leaving it to guesswork.
			var dest := _deposit_destination_name()
			if dest != "":
				_task_result = "%s (into %s)" % [_task_result, dest]
		contrib_food += _task_food
	if _task_mats > 0 and manager and manager.has_method("add_materials_at"):
		manager.add_materials_at(home_pos, _task_mats)
	if _task_wood > 0 and manager and manager.has_method("add_wood_at"):
		manager.add_wood_at(home_pos, _task_wood)
		contrib_wood += _task_wood
	_task_wood = 0
	# loyalty only grows from work done WILLINGLY — paid mercenaries earn nothing
	if not _task_paid and (_task_food > 0 or _task_mats > 0 or _task_wood > 0 or k == "scout"):
		relationship = minf(RELATIONSHIP_MAX, relationship + WORK_REL_GAIN)
		_update_rank()
	_task_paid = false

	# a well-supplied camp lets members forge better gear from looted materials
	_maybe_upgrade_gear()

	# a real, positive contribution to the tribe can gradually soften someone
	# into a more trusting archetype -- the counterpart to take_hit()'s
	# trauma-hardening below, both driven by lived experience, not a slider
	if not _task_paid and (contrib_food + contrib_wood) >= _next_contrib_shift_at:
		_maybe_shift_personality("Trusting", "Helping this tribe again and again... I believe in this now.")
		_next_contrib_shift_at += CONTRIB_SHIFT_INTERVAL

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
	# BLACKSMITH_MAX_WEAPON_TIER, not WEAPON_TIERS.size() - 1: a member already
	# holding a Wand (reached only via the favors_ranged() redirect below, not
	# this early-out) still counts as weapon-maxed for the purposes of "is
	# there anything left to auto-upgrade via the normal ladder" -- there is
	# nothing further to raise it TO. See the same note on wmax below.
	if weapon >= BLACKSMITH_MAX_WEAPON_TIER and armor >= ARMOR_TIERS.size() - 1:
		return
	if randf() > 0.35:
		return
	if not manager.has_method("spend_materials") or not ("materials" in manager):
		return
	if int(manager.materials) < _GEAR_MAT_COST:
		return
	# WEAPON PREFERENCE (2026-08-28): "wire spike thoughts into actions" --
	# real combat experience can redirect an upgrade toward a ranged type
	# (Bow/Wand) the member has actually been succeeding with, rather than
	# blindly marching the fixed Club->Spear->Bow->Axe ladder every member
	# follows regardless of how they fight. Only kicks in when there's a
	# CLEAR preference for the other combat style (favors_ranged()) and
	# they're not already using it -- a member who simply favors whatever
	# they're currently equipped with (the common case) isn't redirected.
	if weapon_pref.favors_ranged() and weapon != 2 and weapon != 4:
		var favored: int = weapon_pref.favored_weapon_index()
		if manager.spend_materials(_GEAR_MAT_COST):
			weapon = favored
			_think("My spear-arm's proven itself with a %s -- switching to it." % str(WEAPON_TIERS[favored]["name"]), 2.4)
			return
		return
	# raise whichever track is lower (armor wins ties, so survivability comes first),
	# respecting each track's ceiling
	# wmax uses BLACKSMITH_MAX_WEAPON_TIER (Axe), not WEAPON_TIERS.size() - 1:
	# the normal +1 ladder below tops out at Axe -- it must NEVER walk a
	# member onto Wand on its own (that's a real preference, earned through
	# actual combat, not a random roll). A member already on Wand (weapon==4)
	# also reads as wmax here, correctly routing further upgrades to armor.
	var wmax: bool = weapon >= BLACKSMITH_MAX_WEAPON_TIER
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
			# real panic (SSH "hopping disorder") -- see npc_core_memory.gd.
			# small per-tick jitter so a whole fight compounds real stress
			# rather than one instant spike.
			_apply_memory_stress(0.08)
			_defend_attack_cd = maxf(0.0, _defend_attack_cd - delta)
			_throw_cd = maxf(0.0, _throw_cd - delta)
			_bow_cd = maxf(0.0, _bow_cd - delta)
			_wand_cd = maxf(0.0, _wand_cd - delta)
			var fp: Vector3 = (_foe as Node3D).global_position
			var fd := global_position.distance_to(fp)
			if weapon == 4 and fd < WAND_RANGE and fd > 1.7 and _try_cast_at(_foe):
				_chase_timer = CHASE_GIVEUP_TIME
			elif weapon == 2 and fd < BOW_RANGE and fd > 1.7 and _try_shoot_arrow_at(_foe):
				_chase_timer = CHASE_GIVEUP_TIME
			elif fd < 1.7:
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
				# ("mine" uses the HARVEST_RANGE fallback above -- same one-shot
				# arrival pattern as gather/hunt, see below)
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
				elif _task_kind == "mine":
					_do_mine()
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
	# ROUTE MEMORY: worn paths let this member move faster toward a target
	# they've walked this way to before -- literal "efficient known routes",
	# not just a label. Multiplier is 1.0 (no bonus) on unfamiliar ground.
	spd *= route_memory.route_speed_mult(global_position, p)
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
