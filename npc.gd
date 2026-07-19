extends CharacterBody3D
# ─────────────────────────────────────────────────────────────────────────────
# NPC — a member of a WorldTribe (or a lone neutral wanderer).
#
# Tribe NPCs now LIVE: they forage berries, hunt animals (if their tribe has a
# club), carve new clubs, carry the spoils back to camp, recruit neutral
# wanderers into their tribe, and SCRAP with rival NPCs over the same resources
# (the weaker flees). Neutrals just amble, calm and bribeable.
#
# Still carries a tiny Spikeling brain (SeeDanger -> Alarm). Groups: "npc",
# "has_brain", plus "neutral" if unaffiliated.
# ─────────────────────────────────────────────────────────────────────────────

const SpatialGrid = preload("res://spatial_grid.gd")

var brain: Spikeling
var anim: BodyAnim
var member_name: String = "Tribesperson"
var personality: String = "Wild"

var tribe                       # WorldTribe (null if neutral)
var neutral: bool = false
var home: Vector3 = Vector3.ZERO
var territory: float = 10.0
var color: Color = Color(0.7, 0.7, 0.7)
@export var speed: float = 1.8
@export var flee_speed: float = 3.2
@export var hunt_speed: float = 3.7   # faster than any animal (rabbit flees 3.3)
# The PLAYER runs at 5.0 -- hunt_speed was tuned to catch ANIMALS, so a rival
# literally could never catch him and you could jog through any camp untouched.
# Chasing the player uses this instead. The margin matters: at 5.8 they close
# 0.8 m/s, so from ~6m (walking into a camp) they reach melee (1.7m) in ~5s --
# inside the 7s CHASE_GIVEUP_TIME, so camps are genuinely dangerous. But spotted
# from ~15m they'd need ~17s to close, so they give up first and you escape.
# Close = caught, far = you get away. Tune this number to taste.
@export var chase_speed: float = 5.8

const BRAIN := """# Spikeling Neural Configuration
neuron SeeDanger threshold=50 leak=25
neuron Calm      threshold=100 leak=4
neuron Alarm     threshold=100 leak=10
synapse SeeDanger -> Alarm weight=120
refractory=2
"""

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)

# health & combat
var hp: float = 60.0
var max_hp: float = 60.0
var inv_food: int = 0          # personal rations (NPCs eat their own, not a shared pile)
var _hunger: float = 0.0
var _attack_cd: float = 0.0
var contrib: int = 0           # productivity score → who becomes tribe leader
# MEMORY: grudges against tribes that hurt me, and battle experience. Wiped when
# I'm converted to a new tribe (fresh allegiance, fresh mind).
var grudges: Dictionary = {}
var experience: int = 0
var warrior: bool = false      # marched out to war on a rival camp
var _champion: bool = false
var _club_model: MeshInstance3D = null
var _hp_bar: Label3D = null
var _crown: MeshInstance3D = null

enum St { WANDER, GO, BACK, CARVE }
var state: int = St.WANDER
var _job_kind: String = ""
var _target_node: Node3D = null
var _carry_food: int = 0
var _carry_skins: int = 0
var _job_cd: float = 0.0
var _work: float = 0.0
var _skirmish_cd: float = 0.0
var _defend_cd: float = 0.0
var _foe: Node3D = null         # intruder we're driving off
var _chase_timer: float = 0.0   # patience left to actually catch _foe before giving up
const CHASE_GIVEUP_TIME := 7.0

# ── coordinated raid: mustered into a war party, marching on a target ──
var at_war: bool = false
var _raid_player: bool = false  # true = harassing the player's base, not a camp
var _war_tribe = null           # the enemy WorldTribe whose camp we're razing
var _war_pos: Vector3 = Vector3.ZERO
var _war_formation_offset: Vector3 = Vector3.ZERO   # holds a formation slot while marching
var _war_reach: float = 4.0     # how close to the objective before we strike it
var _war_time: float = 0.0      # patience before we give up and march home
var _bash_cd: float = 0.0
var _last_pos: Vector3 = Vector3.ZERO
var _war_foe_cd: float = 0.0    # throttles _war_foe()'s full-group scan
var _war_foe_cache: Node3D = null
var _siege_cd: float = 0.0      # throttles _compute_siege_target()'s group scans
var _siege_cache: Node3D = null
const OUTNUMBER_RADIUS := 14.0
const OUTNUMBER_THRESHOLD := 4   # this many nearby threats and we run instead of fighting
var _stuck_cd: float = 0.6

var _wander_target: Vector3 = Vector3.ZERO
var _wander_pause: float = 0.0
var _flee_timer: float = 0.0
var _flee_from: Node3D = null
var _player: Node3D = null
var _tick_accum: float = 0.0
const TICK_HZ := 8.0
const ARRIVE := 0.6

# ── SIMULATION LOD — driven by our tribe (world_tribe._tick_lod), which
# checks distance to the player every ~0.5s and assigns a tier to its whole
# roster at once. This is what makes "1000 tribes" survivable: occlusion
# culling only saves rendering cost, but each NPC's full AI (group scans,
# pathing, brain ticks) runs every physics frame regardless of whether it's
# on screen. Tiering below caps that cost by distance:
#   0 NEAR — full simulation, exactly as before.
#   1 MID  — same logic, just run at a much lower tick rate (still alive and
#            correct, just coarser — fine for something far off and small).
#   2 FAR  — physics_process is switched OFF entirely (zero CPU cost). The
#            tribe's own economy keeps ticking abstractly in world_tribe.gd
#            (_grow, opinions, etc — already cheap, one node per tribe) so
#            the tribe still grows/changes while its members are frozen.
# A war party or an active builder is exempted from FAR (capped at MID)
# so a raid or construction in progress never visibly stalls mid-stride.
var lod: int = 0

func set_lod(tier: int) -> void:
	if tier == 2 and (at_war or building):
		tier = 1
	if tier == lod:
		return
	lod = tier
	set_physics_process(tier != 2)

var _grid_cd: float = 0.0

func _exit_tree() -> void:
	SpatialGrid.remove(self)

# ── building: assigned by our tribe to physically walk to a spot and raise a
# structure there (world_tribe.gd._build_palisade). Overrides everything else
# until cancelled — this is what makes "the builder must be close" real
# instead of structures just appearing at the tribe's own position. ──
var building: bool = false
var _build_target: Vector3 = Vector3.ZERO

func assign_build(pos: Vector3) -> void:
	building = true
	_build_target = pos

func cancel_build() -> void:
	building = false

func _ready() -> void:
	add_to_group("npc")
	add_to_group("has_brain")
	brain = Spikeling.new()
	brain.load_from_text(BRAIN)
	_build()
	anim = BodyAnim.new()
	anim.setup([get_node_or_null("Mesh")])

# INDIVIDUAL IDENTITY (2026-07-30): every rival NPC from the same tribe used
# to share the exact same member_name (the tribe's own name) -- fine while
# nothing ever addressed one individually, but a real blocker for extending
# real dialogue (TribeTalk) to rival NPCs: that system keys _last_talk/
# _speakers by member_name, so two different "Foragers" would silently
# collide, overwrite each other's cooldowns, and misroute replies. Each
# rival NPC now gets its own name from this bank (separate from
# Tribemanager.MEMBER_NAMES so a rival isn't likely to be confused for one
# of your own members) -- tribe_name/archetype are unaffected and still
# drive everything that reads them (persona, UI, combat logs).
const RIVAL_NAMES := [
	"Sarn", "Ivo", "Rask", "Nera", "Tolek", "Ymir", "Sable", "Corvin",
	"Alba", "Dresk", "Ottavia", "Quinlen", "Fenrik", "Bryn", "Hesper", "Yara",
]

# SOCIETAL HIERARCHY (2026-08-03) -- every tribe has real social structure,
# not just the player's own. Rival NPCs are ephemeral under this game's own
# LOD design (spawned/despawned as the player moves near/away, see
# world_tribe.gd's _ensure_spawned()/_tick_lod()), so a persistent, growing
# hierarchy per individual the way tribemember.gd tracks one isn't viable
# here -- instead each rival gets a REAL role at spawn, weighted toward
# their own tribe's archetype (a Raiders clan skews Warrior/Spy, a Traders
# clan skews Trader, etc.), with a small, genuinely rare chance of being one
# of that tribe's Officials.
const ROLE_HIERARCHY := [
	"Official", "Outpostman", "Trader", "Forager", "Hunter",
	"Builder", "Elite Builder", "Warrior", "Spy",
]
const ARCHETYPE_ROLE_BIAS := {
	"Foragers": ["Forager", "Forager", "Outpostman"],
	"Hunters": ["Hunter", "Hunter", "Warrior"],
	"Raiders": ["Warrior", "Warrior", "Spy"],
	"Traders": ["Trader", "Trader", "Outpostman"],
	"Nomads": ["Outpostman", "Forager", "Spy"],
	"Warriors": ["Warrior", "Warrior", "Elite Builder"],
	"Fishers": ["Forager", "Hunter", "Trader"],
	"Herders": ["Forager", "Outpostman", "Trader"],
	"Mystics": ["Spy", "Trader", "Official"],
	"Builders": ["Builder", "Elite Builder", "Elite Builder"],
	"Wanderers": ["Outpostman", "Forager", "Spy"],
	"Slavers": ["Warrior", "Spy", "Trader"],
}
const OFFICIAL_CHANCE := 0.05   # genuinely rare -- a real minority, same spirit as the player tribe's quota
var social_role: String = "Forager"

func setup(t, h: Vector3, terr: float, col: Color) -> void:
	tribe = t
	home = h
	territory = terr
	color = col
	_wander_target = h
	_job_cd = randf_range(1.0, 4.0)
	if t:
		member_name = RIVAL_NAMES[randi() % RIVAL_NAMES.size()]
		personality = t.archetype
		if randf() < OFFICIAL_CHANCE:
			social_role = "Official"
		else:
			var bias: Array = ARCHETYPE_ROLE_BIAS.get(str(t.archetype), ["Forager"])
			social_role = str(bias[randi() % bias.size()])
		# HIVE MIND: point at the tribe's one shared brain instead of running
		# an individual copy — matches spikeling.gd's own design intent
		# ("Run ONE of these per horde, not one per zombie").
		if "brain" in t and t.brain != null:
			brain = t.brain
	_apply_color()

func setup_neutral(h: Vector3) -> void:
	neutral = true
	add_to_group("neutral")
	home = h
	territory = 26.0
	color = Color(0.6, 0.62, 0.55)
	member_name = "Wanderer"
	personality = "Neutral"
	_wander_target = h
	_apply_color()

func _build() -> void:
	var body := MeshInstance3D.new()
	body.name = "Mesh"
	var cap := CapsuleMesh.new()
	cap.radius = 0.35
	cap.height = 1.6
	body.mesh = cap
	body.position = Vector3(0, 0.9, 0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	body.material_override = mat
	add_child(body)
	_build_googly_eyes(body, 0.35, 0.55)   # no separate head sphere — bias up toward the capsule top

	var col := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 0.35
	shape.height = 1.7
	col.shape = shape
	col.position = Vector3(0, 0.9, 0)
	add_child(col)

	# a club held in hand, shown when the tribe is armed
	_club_model = MeshInstance3D.new()
	var clm := BoxMesh.new()
	clm.size = Vector3(0.09, 0.09, 0.7)
	_club_model.mesh = clm
	_club_model.position = Vector3(0.3, 1.0, 0.25)
	_club_model.rotation_degrees = Vector3(60, 0, 0)
	var cmat := StandardMaterial3D.new()
	cmat.albedo_color = Color(0.45, 0.30, 0.15)
	_club_model.material_override = cmat
	_club_model.visible = false
	add_child(_club_model)

	_hp_bar = Label3D.new()
	_hp_bar.position = Vector3(0, 2.0, 0)
	_hp_bar.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_hp_bar.font_size = 28
	_hp_bar.visible = false
	add_child(_hp_bar)

	# a gold crown shown when this NPC is the tribe's elected leader
	_crown = MeshInstance3D.new()
	var crm := CylinderMesh.new()
	crm.top_radius = 0.0
	crm.bottom_radius = 0.28
	crm.height = 0.45
	_crown.mesh = crm
	_crown.position = Vector3(0, 2.35, 0)
	var crmat := StandardMaterial3D.new()
	crmat.albedo_color = Color(1.0, 0.84, 0.2)
	crmat.emission_enabled = true
	crmat.emission = Color(0.8, 0.6, 0.1)
	_crown.material_override = crmat
	_crown.visible = false
	add_child(_crown)

func set_champion(on: bool) -> void:
	_champion = on
	if _crown:
		_crown.visible = on

# two white sphere "eyes" with off-center black pupils. height_offset biases
# them up when there's no separate head sphere to anchor to (just a capsule).
func _build_googly_eyes(parent: Node3D, head_radius: float, height_offset: float = 0.0) -> void:
	for side in [-1.0, 1.0]:
		var eye := MeshInstance3D.new()
		var es := SphereMesh.new()
		es.radius = head_radius * 0.32
		es.height = head_radius * 0.64
		eye.mesh = es
		eye.position = Vector3(side * head_radius * 0.55, head_radius * 0.25 + height_offset, head_radius * 0.85)
		var emat := StandardMaterial3D.new()
		emat.albedo_color = Color(1, 1, 1)
		eye.material_override = emat
		parent.add_child(eye)

		var pupil := MeshInstance3D.new()
		var ps := SphereMesh.new()
		ps.radius = head_radius * 0.14
		ps.height = head_radius * 0.28
		pupil.mesh = ps
		pupil.position = Vector3(randf_range(-0.04, 0.04), randf_range(-0.04, 0.04), head_radius * 0.3)
		var pmat := StandardMaterial3D.new()
		pmat.albedo_color = Color(0.05, 0.05, 0.05)
		pupil.material_override = pmat
		eye.add_child(pupil)

func _apply_color() -> void:
	var mi := get_node_or_null("Mesh") as MeshInstance3D
	if mi:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = color
		mi.material_override = mat

func _physics_process(delta: float) -> void:
	# MID tier used to skip whole physics_process calls and replay them with
	# an accumulated delta to save CPU — but move_and_slide() (called later,
	# inside _move()) always integrates using Godot's REAL per-frame physics
	# delta internally, not the delta variable we pass around for our own
	# timers. Skipping frames meant move_and_slide() only ever got to act on
	# ONE frame's worth of motion before being skipped again for several
	# frames straight — net result, NPCs crawled at a fraction of their
	# real speed instead of just ticking their AI less often. The existing
	# per-mechanism cooldowns (_defend_cd, _skirmish_cd, _war_foe_cd, etc.)
	# already throttle the expensive group scans independent of this, so
	# movement now always runs at full rate regardless of LOD tier; only
	# FAR (tier 2) actually stops physics_process via set_lod().
	_tick_accum += delta
	var interval := 1.0 / TICK_HZ
	while _tick_accum >= interval:
		_tick_accum -= interval
		_brain_tick()
	_grid_cd -= delta
	if _grid_cd <= 0.0:
		_grid_cd = 0.25
		SpatialGrid.update(self)
	_attack_cd = maxf(0.0, _attack_cd - delta)
	_throw_cd = maxf(0.0, _throw_cd - delta)
	if not neutral:
		_npc_hunger(delta)
	_update_combat_visuals()
	_move(delta)
	_check_stuck(delta)
	_animate_body(delta)

# bob/breathe; wariness rises from the SeeDanger neuron, posture sinks with hunger
func _animate_body(delta: float) -> void:
	if anim == null:
		return
	var spd := Vector2(velocity.x, velocity.z).length()
	var fear := brain.get_potential("SeeDanger") / 50.0
	anim.tension = clampf(maxf(anim.tension - delta * 1.2, fear), 0.0, 1.0)
	anim.mood = -clampf(_hunger / 120.0, 0.0, 1.0) * 0.6
	anim.tick(delta, spd, is_on_floor())

func _check_stuck(delta: float) -> void:
	_stuck_cd -= delta
	if _stuck_cd > 0.0:
		return
	_stuck_cd = 0.6
	var moved := global_position.distance_to(_last_pos)
	_last_pos = global_position
	if Vector2(velocity.x, velocity.z).length() > 0.4 and moved < 0.15:
		# bash a fence (or a built block wall) we're snagged on, and shove
		# free — teepees are walk-through (see teepee.gd), so they're not a
		# movement obstacle in the first place
		for grp in ["fence", "block"]:
			for f in get_tree().get_nodes_in_group(grp):
				var fn := f as Node3D
				if fn and is_instance_valid(fn) and global_position.distance_to(fn.global_position) < 1.9 and fn.has_method("take_damage"):
					fn.take_damage(3)
		var a := randf() * TAU
		velocity.x += cos(a) * speed * 2.0
		velocity.z += sin(a) * speed * 2.0
		_wander_target = home

# NPCs suppress hunger from their OWN rations (what they carry), not a shared pile
func _npc_hunger(delta: float) -> void:
	_hunger += delta * 0.7
	if _hunger >= 55.0:
		if _carry_food > 0:
			_carry_food -= 1
			_hunger = maxf(0.0, _hunger - 60.0)
		elif inv_food > 0:
			inv_food -= 1
			_hunger = maxf(0.0, _hunger - 60.0)
		elif _hunger >= 100.0:
			hp = maxf(0.0, hp - delta * 3.0)   # starving
			if hp <= 0.0:
				die()

func _update_combat_visuals() -> void:
	if _club_model:
		_club_model.visible = (not neutral) and tribe != null and is_instance_valid(tribe) and tribe.has_club()
	if _hp_bar:
		if hp < max_hp - 0.5:
			_hp_bar.visible = true
			_hp_bar.text = "HP %d%%" % int(hp / max_hp * 100.0)
			_hp_bar.modulate = Color(1.0, 0.3, 0.3).lerp(Color(0.4, 1.0, 0.4), hp / max_hp)
		else:
			_hp_bar.visible = false

func take_hit(dmg: float, attacker) -> void:
	hp -= dmg
	if anim:
		anim.pop(0.5)
		anim.tension = 1.0
	if hp <= 0.0:
		die()
		return
	if hp < max_hp * 0.3 and attacker:
		# badly hurt — break off and run regardless of anything else
		_flee_timer = 1.8
		_flee_from = attacker as Node3D
		_foe = null
		return
	if neutral or attacker == null or not is_instance_valid(attacker):
		return
	# self-defense: fight back even outside our own territory — UNLESS
	# clearly surrounded, in which case running beats a hopeless brawl
	if _nearby_rival_count() >= OUTNUMBER_THRESHOLD:
		_flee_timer = 1.8
		_flee_from = attacker as Node3D
		_foe = null
	else:
		_foe = attacker as Node3D
		_rally_defenders(_foe)   # attacked -> call the base to help drive them off

# how many likely-hostile units (rival npcs, player-tribe members, the
# player) are near us right now — used to decide fight vs flee when hit
func _nearby_rival_count() -> int:
	var count := 0
	for o in SpatialGrid.query(global_position, OUTNUMBER_RADIUS, "npc"):
		var n := o as Node3D
		if n == null or n == self or not is_instance_valid(n):
			continue
		if n.get("neutral"):
			continue
		if n.get("tribe") == tribe:
			continue
		if global_position.distance_to(n.global_position) <= OUTNUMBER_RADIUS:
			count += 1
	for o in SpatialGrid.query(global_position, OUTNUMBER_RADIUS, "tribe"):
		var n := o as Node3D
		if n and is_instance_valid(n) and global_position.distance_to(n.global_position) <= OUTNUMBER_RADIUS:
			count += 1
	var p := get_tree().get_first_node_in_group("player")
	if p and is_instance_valid(p) and global_position.distance_to(p.global_position) <= OUTNUMBER_RADIUS:
		count += 1
	return count

func die() -> void:
	if tribe and is_instance_valid(tribe) and tribe.has_method("on_member_died"):
		tribe.on_member_died(self)
	queue_free()

# ── one spiking tick: feed senses in, read drives out ──
func _brain_tick() -> void:
	if not neutral:
		_player = get_tree().get_first_node_in_group("player")
	# HIVE MIND: a tribe member's brain IS the tribe's shared Spikeling
	# instance (see setup()) — the tribe steps it once per tick for the
	# whole roster (world_tribe.gd._tick_hive_brain). Stimulating/stepping
	# it again here, per-NPC, would advance the shared network N times per
	# tick instead of once, so members just read the result instead.
	if not neutral and tribe != null and is_instance_valid(tribe) and "hive_alarmed" in tribe:
		if tribe.hive_alarmed:
			_flee_timer = 1.3
			_flee_from = _player
			if anim: anim.pop(0.6)
		return
	if not neutral and _player and is_instance_valid(_player):
		var d := global_position.distance_to(_player.global_position)
		if d < 6.0:
			brain.stimulate("SeeDanger", 45.0 + 45.0 * (1.0 - d / 6.0))
	brain.stimulate("Calm", 1.0)
	var fired: Array = brain.step()
	if "Alarm" in fired:
		_flee_timer = 1.3
		_flee_from = _player
		if anim: anim.pop(0.6)       # spooked — a quick startle

func _move(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = 0.0

	# BUILDING — walk to the assigned site and wait there; world_tribe.gd
	# polls our distance and places the structure once we've actually arrived.
	if building:
		var to := _build_target - global_position
		to.y = 0.0
		if to.length() > 1.6:
			_drive(to.normalized(), speed)
		else:
			_halt()
		_apply_separation()
		move_and_slide()
		return

	# AT WAR — a mustered raider overrides everything to march on the objective
	# and fight there. This is what a coordinated raid looks like on the ground.
	if at_war:
		_war_move(delta)
		_apply_separation()
		move_and_slide()
		return

	# TERRITORIAL DEFENSE takes priority over fear: a tribe NPC will stand and
	# FIGHT an intruder (the player or a rival) inside its land, not flee.
	if not neutral and tribe != null and is_instance_valid(tribe):
		_defend_cd -= delta
		# only auto-pick a NEW foe via territory scanning if we don't already
		# have one — take_hit() may have just set _foe to an attacker outside
		# our territory (self-defense), and this used to stomp that every
		# 0.5s by re-scanning for intruders and overwriting it with null
		if _defend_cd <= 0.0:
			_defend_cd = 0.5
			if _foe == null or not is_instance_valid(_foe):
				var new_foe := _find_intruder()
				if new_foe != null:
					_foe = new_foe
					_chase_timer = CHASE_GIVEUP_TIME
					_rally_defenders(_foe)   # spotted an intruder -> alert the base
		if _foe != null and is_instance_valid(_foe):
			_flee_timer = 0.0
			var fp := (_foe as Node3D).global_position
			var fd := global_position.distance_to(fp)
			if fd < 1.7:
				_attack(_foe)
				_halt()
				_chase_timer = CHASE_GIVEUP_TIME   # landed in range — patience restored
			elif fd < THROW_RANGE and _try_throw_at(_foe):
				_halt()
				_chase_timer = CHASE_GIVEUP_TIME
			elif fd < 22.0:
				# can't catch them — after a while chasing without closing the
				# gap, give up and go back to normal life instead of running
				# them down across the whole map
				_chase_timer -= delta
				if _chase_timer <= 0.0:
					_foe = null
				else:
					var to := fp - global_position
					to.y = 0.0
					if to.length() > 0.01:
						# only the player needs the faster pace -- rival-vs-rival
						# chases keep their original balance
						var pace: float = chase_speed if _foe.is_in_group("player") else hunt_speed
						_drive(to.normalized(), pace)
			else:
				_foe = null
			if _foe != null:
				_apply_separation()
				move_and_slide()
				return

	if _flee_timer > 0.0:
		_flee_timer -= delta
		var src: Node3D = _flee_from if (_flee_from and is_instance_valid(_flee_from)) else _player
		var dir := Vector3.ZERO
		if src and is_instance_valid(src):
			dir = global_position - src.global_position
		dir.y = 0.0
		if dir.length() < 0.01:
			dir = Vector3(randf() - 0.5, 0, randf() - 0.5)
		_drive(dir.normalized(), flee_speed)
	elif neutral or tribe == null:
		_wander(delta)
	else:
		_work_state(delta)
		_skirmish(delta)

	_apply_separation()
	move_and_slide()

# Alert nearby same-tribe members to converge on our foe, so attacking one
# defender (or spotting an intruder) brings the whole base to its defense
# instead of members reacting one at a time. Only recruits members who aren't
# already fighting someone.
func _rally_defenders(foe: Node3D) -> void:
	if foe == null or not is_instance_valid(foe):
		return
	for o in SpatialGrid.query(global_position, 14.0, "npc"):
		var on := o as Node3D
		if on == self or on == null or not is_instance_valid(on):
			continue
		if on.get("neutral") or on.get("tribe") != tribe:
			continue
		if on.get("_foe") == null:
			on.set("_foe", foe)
			on.set("_chase_timer", CHASE_GIVEUP_TIME)

# find the nearest intruder (rival NPC or the player) inside our territory
func _find_intruder() -> Node3D:
	if tribe == null or not is_instance_valid(tribe):
		return null
	var best: Node3D = null
	var bd := 18.0
	var p := get_tree().get_first_node_in_group("player") as Node3D
	if p and is_instance_valid(p):
		var dp := global_position.distance_to(p.global_position)
		# The player used to only count as an intruder inside our CAMP radius
		# (home +/- territory), so any rival out foraging ignored him completely,
		# and even a tribe that hated him never attacked unless he walked into
		# camp. Three ways he's a target now:
		#   1. inside our territory  -- classic camp defense
		#   2. right on top of us    -- territorial reaction to personal space
		#   3. our tribe is hostile to him / raiding him -- hunt him on sight
		var opinion: float = 0.0
		if tribe != null and is_instance_valid(tribe):
			var po = tribe.get("player_opinion")
			if po != null:
				opinion = float(po)
		var friendly: bool = opinion >= 0.3          # they like him -- don't jump him
		# COEXISTENCE (2026-07-28): in_territory used to count as intrusion
		# UNCONDITIONALLY, regardless of opinion -- so even a "bonded" tribe
		# (opinion 0.7+, their own leader greeting you warmly) still treated
		# you setting foot in their camp as a threat to repel. That's the
		# concrete thing blocking "living amongst other tribes": there was no
		# opinion level at which a rival camp was actually safe to walk
		# through. A friendly-or-better relationship now means their own
		# territory genuinely stops being hostile ground.
		var in_territory: bool = home.distance_to(p.global_position) < territory and not friendly
		var too_close: bool = dp < 6.0 and not friendly
		var hostile_to_player: bool = _raid_player or opinion <= -0.3
		if (in_territory or too_close or hostile_to_player) and dp < bd:
			bd = dp
			best = p
	for o in SpatialGrid.query(global_position, bd, "npc"):
		var on := o as Node3D
		if on == self or not is_instance_valid(on):
			continue
		if on.get("neutral"):
			continue
		var ot = on.get("tribe")
		if ot == tribe or ot == null:
			continue
		if home.distance_to(on.global_position) < territory:
			var d := global_position.distance_to(on.global_position)
			if d < bd:
				bd = d
				best = on
	# the player's own loyal members AND loyal dogs (both in group "tribe")
	# count as intruders too if they wander into our territory — dogs are
	# now real targets, not just something raiders happen to bump into
	# during a siege.
	#
	# COEXISTENCE (2026-07-28): this scan had no opinion gate at all -- a
	# player's own tribemates were treated as intruders in a rival camp
	# regardless of how good relations with the player were. Reuses the same
	# `friendly` opinion this function already computed for the player
	# himself: a tribe that welcomes the leader welcomes his people too.
	var member_friendly: bool = false
	if tribe != null and is_instance_valid(tribe):
		var po2 = tribe.get("player_opinion")
		if po2 != null:
			member_friendly = float(po2) >= 0.3
	if not member_friendly:
		for o in SpatialGrid.query(global_position, bd, "tribe"):
			var tn := o as Node3D
			if tn == null or not is_instance_valid(tn):
				continue
			if home.distance_to(tn.global_position) < territory:
				var d2 := global_position.distance_to(tn.global_position)
				if d2 < bd:
					bd = d2
					best = tn
	return best

func _wander(delta: float) -> void:
	if _wander_pause > 0.0:
		_wander_pause -= delta
		_halt()
		return
	var ang := randf() * TAU
	var r := randf() * territory * 0.8
	var flat := global_position - _wander_target
	flat.y = 0.0
	if flat.length() <= ARRIVE:
		_wander_target = home + Vector3(cos(ang), 0, sin(ang)) * r
		_wander_target.y = home.y
		_wander_pause = randf_range(0.8, 2.8)
		_halt()
		return
	var to := _wander_target - global_position
	to.y = 0.0
	if to.length() > 0.001:
		_drive(to.normalized(), speed)

func _nearest_resource(grp: String, need_amount: bool) -> Node3D:
	var best: Node3D = null
	var bd := 50.0
	for b in get_tree().get_nodes_in_group(grp):
		var n := b as Node3D
		if n == null or not is_instance_valid(n):
			continue
		if need_amount and (not n.has_method("harvest") or float(n.amount) < 1.0):
			continue
		var d := global_position.distance_to(n.global_position)
		if d < bd:
			bd = d
			best = n
	return best

func _nearest_in_group(grp: String, maxd: float) -> Node3D:
	var best: Node3D = null
	var bd := maxd
	for o in get_tree().get_nodes_in_group(grp):
		var n := o as Node3D
		if n and is_instance_valid(n):
			var d := global_position.distance_to(n.global_position)
			if d < bd:
				bd = d
				best = n
	return best

# the next structure a siege raider should march on — fences first, then
# forward camps, and only the stockpile once both are gone (see player_camp.gd
# and stockpile.gd, which enforce the same order independently on the
# defending side)
func _compute_siege_target() -> Node3D:
	var f := _nearest_in_group("fence", 9999.0)
	if f != null:
		return f
	var c := _nearest_in_group("player_camp", 9999.0)
	if c != null:
		return c
	return get_tree().get_first_node_in_group("stockpile")

# (throttled like tribemember.gd's version — see comment there)
var _separation_cd: float = 0.0
var _separation_cache: Vector3 = Vector3.ZERO

func _apply_separation() -> void:
	if tribe == null:
		return
	_separation_cd -= get_physics_process_delta_time()
	if _separation_cd <= 0.0:
		_separation_cd = randf_range(0.12, 0.18)
		var push := Vector3.ZERO
		for o in tribe.npcs:
			var on := o as Node3D
			if on == self or not is_instance_valid(on):
				continue
			var d := global_position - on.global_position
			d.y = 0.0
			var dist := d.length()
			if dist > 0.01 and dist < 1.5:
				push += d.normalized() * (1.5 - dist)
		_separation_cache = push
	if _separation_cache.length() > 0.001:
		velocity.x += _separation_cache.x * speed
		velocity.z += _separation_cache.z * speed

# ── work: forage/hunt/carve for our tribe, carry the spoils home ──
func _work_state(delta: float) -> void:
	match state:
		St.WANDER:
			_job_cd -= delta
			if _job_cd > 0.0:
				_wander(delta)
				return
			_job_cd = randf_range(2.5, 6.0)
			_pick_job()
		St.GO:
			if _target_node == null or not is_instance_valid(_target_node):
				state = St.WANDER
				return
			var d := global_position.distance_to(_target_node.global_position)
			if d > 1.8:
				_drive((_target_node.global_position - global_position).normalized(), speed)
				return
			_halt()
			_do_job()
		St.BACK:
			var d := global_position.distance_to(home)
			if d > 2.2:
				_drive((home - global_position).normalized(), speed)
				return
			_halt()
			_deposit_home()
		St.CARVE:
			_work -= delta
			_halt()
			if _work <= 0.0:
				if tribe and is_instance_valid(tribe):
					tribe.add_club()
				state = St.WANDER

func _pick_job() -> void:
	if tribe == null or not is_instance_valid(tribe):
		state = St.WANDER
		return
	if not tribe.has_club() and randf() < 0.4:
		_job_kind = "carve"
		_work = 4.0
		state = St.CARVE
		return
	if tribe.wants_food() or randf() < 0.5:
		var bush := _nearest_resource("food_source", true)
		if bush:
			_job_kind = "gather"
			_target_node = bush
			state = St.GO
			return
	if tribe.has_club():
		var prey := _nearest_resource("animal", false)
		if prey:
			_job_kind = "hunt"
			_target_node = prey
			state = St.GO
			return
	# default: gather whatever's around
	var b2 := _nearest_resource("food_source", true)
	if b2:
		_job_kind = "gather"
		_target_node = b2
		state = St.GO

func _do_job() -> void:
	if _job_kind == "gather" and _target_node.has_method("harvest"):
		var got: int = _target_node.harvest(3.0)
		_carry_food += got
		state = St.BACK
	elif _job_kind == "hunt" and _target_node.has_method("killed"):
		var loot: Dictionary = _target_node.killed()
		_carry_food += int(loot.get("food", 0))
		_carry_skins += int(loot.get("skins", 0))
		contrib += 5
		state = St.BACK
	else:
		state = St.WANDER

func _deposit_home() -> void:
	if tribe and is_instance_valid(tribe):
		var f := _carry_food
		var s := _carry_skins
		tribe.deposit(f, s)
		contrib += f
	_carry_food = 0
	_carry_skins = 0
	state = St.WANDER

# ── actually FIGHT a rival NPC standing on the same ground: trade blows ──
func _skirmish(delta: float) -> void:
	_skirmish_cd -= delta
	if _skirmish_cd > 0.0:
		return
	_skirmish_cd = 0.5
	if _foe != null and is_instance_valid(_foe):
		return   # already locked on — the top-priority _foe block in _move() handles it
	# notice a rival from further away than melee range so crossing paths
	# actually starts a real fight (chase + throw + melee), not a one-off
	# attack-if-we-happen-to-be-touching that left most encounters as a
	# non-event when the gap wasn't exactly right at the 0.5s check.
	var best: Node3D = null
	var bd := 12.0
	for o in SpatialGrid.query(global_position, bd, "npc"):
		var on := o as Node3D
		if on == self or not is_instance_valid(on):
			continue
		if on.get("neutral"):
			continue
		var ot = on.get("tribe")
		if ot == tribe or ot == null:
			continue
		var d := global_position.distance_to(on.global_position)
		if d < bd:
			bd = d
			best = on
	if best != null:
		_foe = best
		_chase_timer = CHASE_GIVEUP_TIME

func _attack(foe) -> void:
	if _attack_cd > 0.0:
		return
	_attack_cd = 0.6
	# face the foe and swing
	var f := (foe as Node3D).global_position - global_position
	f.y = 0.0
	if f.length() > 0.01:
		rotation.y = lerp_angle(rotation.y, atan2(f.x, f.z), 0.5)
	var dmg := 6.0 + float(int(tribe.strength) % 12)
	if tribe and is_instance_valid(tribe) and tribe.has_club():
		dmg += 8.0   # armed hits harder
	if tribe and is_instance_valid(tribe) and tribe.get("leader") == self:
		dmg += 6.0   # the elected leader fights harder, not just looks the part
	if foe.has_method("take_hit"):
		var foe_hp = foe.get("hp")
		if foe_hp != null and float(foe_hp) - dmg <= 0.0:
			contrib += 8   # credit for the kill
		foe.take_hit(dmg, self)

# throw a club at a foe still out of melee range — same idea as the player's
# RMB throw: it's gone whether the throw lands or not (world_tribe.use_club)
const THROW_RANGE := 9.0
var _throw_cd: float = 0.0

func _try_throw_at(foe) -> bool:
	if _throw_cd > 0.0:
		return false
	if tribe == null or not is_instance_valid(tribe) or not tribe.has_method("use_club"):
		return false
	if not tribe.use_club():
		return false
	_throw_cd = 2.5
	var f := (foe as Node3D).global_position - global_position
	f.y = 0.0
	if f.length() > 0.01:
		rotation.y = lerp_angle(rotation.y, atan2(f.x, f.z), 0.5)
	var dmg := 10.0 + float(int(tribe.strength) % 10)
	if foe.has_method("take_hit"):
		foe.take_hit(dmg, self)
	return true

# ─────────────────────────────────────────────────────────────────────────────
# WAR PARTY — mustered by our tribe to assault a rival camp (or harry the
# player's base). We march together, cut down defenders, and batter the enemy
# totem (or fences/camps/stockpile, in that order, when raiding the player).
# ─────────────────────────────────────────────────────────────────────────────
func set_war_order(enemy_tribe, pos: Vector3, formation_offset: Vector3 = Vector3.ZERO) -> void:
	at_war = true
	_raid_player = false
	_war_tribe = enemy_tribe
	_war_pos = pos
	_war_formation_offset = formation_offset
	_war_reach = 4.0
	if enemy_tribe and is_instance_valid(enemy_tribe):
		_war_reach = float(enemy_tribe.territory_radius) * 0.5 + 3.5
	_war_time = 34.0

func set_raid_player(pos: Vector3) -> void:
	at_war = true
	_raid_player = true
	_war_tribe = null
	_war_pos = pos
	_war_reach = 3.0
	_war_time = 40.0

func end_war() -> void:
	at_war = false
	_raid_player = false
	_war_tribe = null
	state = St.WANDER

func _war_move(delta: float) -> void:
	_war_time -= delta
	var target_gone: bool = (not _raid_player) and (_war_tribe == null or not is_instance_valid(_war_tribe) or _war_tribe.defeated)
	if _war_time <= 0.0 or target_gone:
		end_war()
		return
	# 1) cut down any enemy fighter blocking the advance
	# (full-group scan is expensive — refresh it a few times a second, not
	#  every physics frame; re-validate the cached target in between)
	_war_foe_cd -= delta
	if _war_foe_cd <= 0.0 or _war_foe_cache == null or not is_instance_valid(_war_foe_cache):
		_war_foe_cd = 0.35
		_war_foe_cache = _war_foe()
	var foe := _war_foe_cache
	if foe != null and is_instance_valid(foe):
		var tf := (foe as Node3D).global_position - global_position
		tf.y = 0.0
		if tf.length() <= 1.7:
			_attack(foe)
			_halt()
		elif tf.length() <= THROW_RANGE and _try_throw_at(foe):
			_halt()
		elif tf.length() > 0.01:
			_drive(tf.normalized(), hunt_speed)
		return
	# 2) press toward the objective
	if _raid_player:
		# Siege order: fences must fall before camps, camps before the
		# stockpile — _compute_siege_target() always hands back the highest
		# priority structure still standing, so raiders naturally march on
		# the perimeter first and only ever reach the stockpile last.
		_siege_cd -= delta
		if _siege_cd <= 0.0 or _siege_cache == null or not is_instance_valid(_siege_cache):
			_siege_cd = 0.4
			_siege_cache = _compute_siege_target()
		var target := _siege_cache
		if target == null:
			_halt()
			return
		var td := (target as Node3D).global_position - global_position
		td.y = 0.0
		if td.length() > 1.8:
			_drive(td.normalized(), hunt_speed)
		else:
			_halt()
			rotation.y = lerp_angle(rotation.y, atan2(td.x, td.z), 0.2)
			_bash_cd -= delta
			if _bash_cd <= 0.0:
				_bash_cd = 0.5
				if target.has_method("take_damage"):
					target.take_damage(8.0, tribe)
		return
	# hold formation while still marching; once within striking range of the
	# objective, converge on the real point so everyone can actually reach it
	var formation_pos := _war_pos + _war_formation_offset
	var to := formation_pos - global_position
	to.y = 0.0
	var dist := global_position.distance_to(_war_pos)
	if dist > _war_reach:
		_drive(to.normalized(), hunt_speed)
	else:
		_halt()
		rotation.y = lerp_angle(rotation.y, atan2(to.x, to.z), 0.2)
		_bash_cd -= delta
		if _bash_cd <= 0.0:
			_bash_cd = 0.5
			if _war_tribe and is_instance_valid(_war_tribe) and _war_tribe.has_method("damage_camp"):
				var dmg := 6.0
				if tribe and is_instance_valid(tribe) and tribe.has_club():
					dmg += 4.0   # an armed war party cracks a totem faster
				_war_tribe.damage_camp(dmg, false, tribe)

# who a raider strikes: player-side units when sieging the base, otherwise the
# camp's defenders (and any guard dogs)
func _war_foe() -> Node3D:
	var best: Node3D = null
	var bd := 7.0
	var groups: Array = ["tribe", "loyal_dog", "player"] if _raid_player else ["npc", "dog"]
	for grp in groups:
		var candidates: Array = SpatialGrid.query(global_position, bd, grp) if grp != "player" else get_tree().get_nodes_in_group("player")
		for o in candidates:
			var n := o as Node3D
			if n == null or n == self or not is_instance_valid(n):
				continue
			if grp == "npc":
				if n.get("neutral"):
					continue
				if n.get("tribe") == tribe:   # never our own kin
					continue
			elif grp == "dog" and not n.is_in_group("loyal_dog"):
				continue
			var d := global_position.distance_to(n.global_position)
			if d < bd:
				bd = d
				best = n
	return best

func _drive(dir: Vector3, spd: float) -> void:
	velocity.x = dir.x * spd
	velocity.z = dir.z * spd
	if dir.length() > 0.01:
		rotation.y = lerp_angle(rotation.y, atan2(dir.x, dir.z), 0.15)

func _halt() -> void:
	velocity.x = move_toward(velocity.x, 0.0, speed * 2.0)
	velocity.z = move_toward(velocity.z, 0.0, speed * 2.0)
