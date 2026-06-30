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

var _tick_accum: float = 0.0
const TICK_HZ := 10.0
var _e_was_down: bool = false
var _keys_down: Dictionary = {}
var _player_node: Node3D = null

@onready var trust_label: Label3D = get_node_or_null("TrustLabel")
@onready var thought_label: Label3D = get_node_or_null("ThoughtLabel")
@export var interact_range: float = 3.5

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
	t += "neuron Trust  threshold=100 leak=%d\n" % int(p["trust_leak"])
	t += "neuron Follow threshold=100 leak=5\n"
	t += "synapse SawContribute -> Trust weight=%d\n" % int(p["contrib"])
	t += "synapse SawHelpClear  -> Trust weight=70\n"
	t += "synapse SawDefend     -> Trust weight=95\n"
	t += "synapse Trust -> Follow weight=%d\n" % int(p["follow_w"])
	t += "refractory=2\n"
	return t

# ── Trust ranks — deeper bonds take progressively longer to earn. ──
const RANKS := [
	["Stranger", 0.00],
	["Acquaintance", 0.30],
	["Friend", 0.70],
	["Loyal", 1.30],
	["Devoted", 2.20],
]
var current_rank: String = "Stranger"

# ── thought system ──
var current_thought: String = "..."
var _thought_timer: float = 0.0
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
var _leaving: bool = false               # starved out — wandering off

# ── orders / tasks ──
const RANK_LOYALTY := {
	"Stranger": 15, "Acquaintance": 45, "Friend": 75, "Loyal": 100, "Devoted": 125,
}
const ORDER_RISK := {"gather": 100, "hunt": 130, "scout": 165, "wood": 100}
const ORDER_BASE := 70
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

func clear_standing() -> void:
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
var _hp_bar: Label3D = null
var _sel_mark: MeshInstance3D = null

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
	brain = Spikeling.new()
	if not brain.load_from_text(_brain_text()):
		push_error("TribeMember: brain failed to load")
	home_pos = global_position
	_target = home_pos
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
	var clm := BoxMesh.new()
	clm.size = Vector3(0.1, 0.1, 0.8)
	_club_model.mesh = clm
	_club_model.position = Vector3(0.35, 1.05, 0.3)
	_club_model.rotation_degrees = Vector3(55, 0, 0)
	var cmat := StandardMaterial3D.new()
	cmat.albedo_color = Color(0.45, 0.30, 0.15)
	_club_model.material_override = cmat
	_club_model.visible = false
	add_child(_club_model)

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

func take_hit(dmg: float, attacker) -> void:
	hp -= dmg
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
		if not n.get("_raid_player") and not n.get("at_war"):
			continue
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
	# step the brain at a fixed rate (cheap)
	_tick_accum += delta
	var interval := 1.0 / TICK_HZ
	while _tick_accum >= interval:
		_tick_accum -= interval
		_brain_tick()

	# register in the world spatial grid so rival npc.gd's "tribe" group
	# queries (intruder/outnumber/war-target checks) can find us without
	# scanning every member in the world — see spatial_grid.gd
	_grid_cd -= delta
	if _grid_cd <= 0.0:
		_grid_cd = 0.25
		SpatialGrid.update(self)

	# decay the bond slowly so trust must be maintained, not just spiked once
	relationship = maxf(0.0, relationship - delta * 0.004)
	# my faction vouches for you: if my compatible friends back you, I warm too
	if faction_vouch > 0.0 and not is_backing_you:
		relationship = minf(3.0, relationship + delta * faction_vouch * 0.06)
	_update_rank()
	_update_faction_mark()
	trust_display = lerpf(trust_display, clampf(relationship / 2.2, 0.0, 1.0), delta * 4.0)

	# thoughts
	_thought_timer -= delta
	_idle_cycle += delta
	if _idle_cycle >= 3.0:
		_idle_cycle = 0.0
		_idle_pick = (_idle_pick + 1) % 4
	if _thought_timer <= 0.0:
		current_thought = _ambient_thought()
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
	# trapped on a fence or a built block wall? bash through it — teepees are
	# walk-through (see teepee.gd), not a movement obstacle in the first place
	for grp in ["fence", "block"]:
		for f in get_tree().get_nodes_in_group(grp):
			var fn := f as Node3D
			if fn and is_instance_valid(fn) and global_position.distance_to(fn.global_position) < 1.9 and fn.has_method("take_damage"):
				fn.take_damage(3)
	# shove sideways to dislodge and rethink the route
	var a := randf() * TAU
	velocity.x += cos(a) * move_speed * 2.0
	velocity.z += sin(a) * move_speed * 2.0
	if state == St.WANDER:
		_target = _anchor()

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
		var placed := false
		if kind == "teepee" and manager and manager.has_method("try_build_teepee"):
			placed = manager.try_build_teepee(pos)
		elif kind == "block" and manager and manager.has_method("try_build_block"):
			placed = manager.try_build_block(pos)
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

# ── eat from the tribe stockpile when hungry; starve if the larder is bare ──
func _hunger_step(delta: float) -> void:
	hunger = minf(100.0, hunger + delta * HUNGER_RATE)
	# members eat their OWN rations — only YOU (the leader) draw from the stockpile
	if hunger >= EAT_AT and inv_food > 0:
		inv_food -= 1
		hunger = maxf(0.0, hunger - EAT_RESTORE)
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
	print("[%s] fed (%d total), Trust now %.0f" % [member_name, feed_count, brain.get_potential("Trust")])

func _brain_tick() -> void:
	var fired: Array = brain.step()
	if "Follow" in fired:
		follow_fires += 1
		relationship = minf(3.0, relationship + 0.18)
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

# ── thoughts ──
func _think(text: String, hold: float = 2.5) -> void:
	current_thought = text
	_thought_timer = hold

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
func give_order(kind: String, paid: bool = false) -> bool:
	if is_busy:
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
		"gather":
			_target_node = _nearest_food_source()
			if _target_node:
				_think("Berries! On my way.", 2.0)
			else:
				_begin_fallback("No berries close by... I'll look around.")
		"hunt":
			if manager and manager.has_method("reserve_club") and manager.reserve_club():
				_has_club = true
				_target_node = _nearest_animal()
				if _target_node:
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
				_think("Off to win over a wanderer...", 2.0)
			else:
				_begin_fallback("No wanderers nearby to recruit...")
	state = St.AWAY
	print("[%s] ACCEPTED order: %s (rank %s)" % [member_name, kind, current_rank])

# go to a random distant spot (used by scout, or when nothing's around to work)
func _begin_fallback(msg: String) -> void:
	var ang := randf() * TAU
	_target = home_pos + Vector3(cos(ang), 0.0, sin(ang)) * 10.0
	_target.y = home_pos.y
	_target_node = null
	_think(msg, 2.2)

const DEPOSIT_RANGE := 3.0   # how close to the stockpile counts as "back" — generous on
							  # purpose so a crowd converging on one exact point doesn't
                              # perpetually jostle for position via separation forces

func _begin_return() -> void:
	state = St.RETURN
	# walk back to the STOCKPILE specifically to deposit — not our own
	# individual home_pos (where we originally spawned, which could be
	# scattered anywhere near camp). With many members all converging on
	# the same tiny home_pos at a tight 0.5-unit arrival radius, separation
	# forces pushing them apart meant they could circle the pile forever
	# without ever all satisfying that check at once — looked exactly like
	# getting stuck on the stockpile.
	var sp := get_tree().get_first_node_in_group("stockpile")
	_target = (sp as Node3D).global_position if sp else home_pos

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

func _nearest_food_source() -> Node3D:
	var best: Node3D = null
	var bd := INF
	for b in get_tree().get_nodes_in_group("food_source"):
		var n := b as Node3D
		if n and is_instance_valid(n) and n.has_method("harvest") and float(n.amount) >= 1.0:
			var d := global_position.distance_to(n.global_position)
			if d < bd:
				bd = d
				best = n
	return best

func _nearest_animal() -> Node3D:
	var best: Node3D = null
	var bd := INF
	for a in get_tree().get_nodes_in_group("animal"):
		var n := a as Node3D
		if n and is_instance_valid(n):
			var d := global_position.distance_to(n.global_position)
			if d < bd:
				bd = d
				best = n
	return best

func _nearest_neutral() -> Node3D:
	var best: Node3D = null
	var bd := INF
	for n in get_tree().get_nodes_in_group("neutral"):
		var nn := n as Node3D
		if nn and is_instance_valid(nn):
			var d := global_position.distance_to(nn.global_position)
			if d < bd:
				bd = d
				best = nn
	return best

const RECRUIT_FOOD_COST := 3

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
		manager.notify("%s won over a wanderer using food." % member_name)

func _nearest_tree() -> Node3D:
	var best: Node3D = null
	var bd := INF
	for t in get_tree().get_nodes_in_group("tree"):
		var n := t as Node3D
		if n and is_instance_valid(n) and n.has_method("chop"):
			var d := global_position.distance_to(n.global_position)
			if d < bd:
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
		"hunt":  _think("Hunt? I don't trust you enough for that.", 2.5)
		"scout": _think("Scout a rival tribe? No. Too dangerous.", 2.5)
		_:       _think("...no.", 2.0)
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
		relationship = minf(3.0, relationship + 0.2)
		_update_rank()
	_task_paid = false

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
	return int(p["might"]) + int(RANK_LOYALTY.get(current_rank, 0) / 10.0) + int(p["courage"] / 10.0)

# ── starvation: called every frame by the manager while the tribe has no food ──
func starve(delta: float) -> void:
	relationship = maxf(0.0, relationship - delta * 0.06)
	_update_rank()
	if is_backing_you and relationship < 0.7:
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
		# formation positioning itself only needs SOME trust (relationship >
		# 0, matching the rest of the formation fixes) — it used to require
		# is_backing_you here too, so even though _auto_work correctly
		# stopped a partial-trust member from picking a new chore, they'd
		# just fall through to plain _wander() instead of actually moving
		# into their formation slot. is_backing_you still gates the
		# unrelated "trail me everywhere"/"approach when I'm close" behavior.
		var formation_active: bool = fkind != "loose" and relationship > 0.0 and dp <= FORMATION_RALLY_RANGE
		if (is_backing_you and (dp > 6.0 or (player_in_range and fkind != "loose"))) or formation_active:
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
	trust_label.text = "%s  [%s · %s]\nTrust: %d%%%s%s" % [member_name, current_rank, personality, pct, status, hint]
	trust_label.modulate = trust_label.modulate.lerp(Color.WHITE, 0.05)

func _update_thought_label() -> void:
	if not thought_label:
		return
	thought_label.text = '"%s"' % current_thought
