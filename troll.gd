extends CharacterBody3D
# ─────────────────────────────────────────────────────────────────────────────
# TROLL — Phase 6 of the turtle-island revamp: a tough single guardian
# blocking a troll-island's one approach point (the Odysseus/Cyclops flavor
# from the original ask). Duck-types the project's existing hp/take_hit(dmg,
# attacker) combat convention (see npc.gd, fence.gd, block.gd, teepee.gd) --
# no shared Health/Combat base class exists anywhere in this codebase, so this
# follows the same convention rather than inventing one.
#
# Spawned as a CHILD of a world_tribe.gd turtle island (see
# Tribemanager._spawn_world_tribes()), positioned at the island's edge -- the
# "one approach point" a boat/swimmer would land at. Being a child means it
# rides the turtle for free via the same reparent-for-free trick every other
# camp structure already uses; no separate "follow the island" logic needed.
#
# EXPLICIT SCOPE BOUNDARY (see the turtle-island plan's Phase 6 section): this
# is a tough single enemy beatable with the game's EXISTING melee/thrown-club
# combat -- not a telegraphed, multi-phase boss fight. A true Cyclops-style
# encounter (windup tells, dodge/parry, phases) needs player-combat groundwork
# (stamina, dodge, enemy telegraphs) that doesn't exist anywhere in this
# project today; that's a genuine future stretch, not part of this scope.
#
# Not extending animal.gd -- animal.gd has zero combat capability (no hp, no
# take_hit) and isn't a usable base for something meant to fight back.
# ─────────────────────────────────────────────────────────────────────────────

# hp calibrated against real numbers already in the game: normal NPC hp=60,
# player melee 9-18 (27 masterwork), thrown club 22 (33 masterwork) -- 500
# gives a real ~15-40 hit grind without any new player-combat systems.
var hp: float = 500.0
var max_hp: float = 500.0
var home_tribe = null   # the world_tribe.gd this troll guards -- set by whoever spawns it

const ENGAGE_RANGE := 6.0        # close enough that the troll swings back
const ATTACK_DAMAGE := 14.0
const ATTACK_COOLDOWN := 1.6
var _attack_cd: float = 0.0
var _dead: bool = false

## REAL ASSET (2026-07-27): reuses one of the same Kenney "Mini Characters"
## already downloaded for every human in the game (assets/humans_real/) --
## scaled way up instead of sourcing a dedicated troll/ogre model that
## doesn't exist in any of the CC0 packs already in this project. A giant
## human-shaped guardian towering over the island fits the Odysseus/Cyclops
## brief well enough, and it comes with a real rig + real idle/attack/die
## animations for free (see AnimationPlayer wiring below), instead of a bare
## capsule. A FIXED pick (not random like ordinary villagers) so "the troll"
## reads as one consistent, recognisable guardian rather than a random NPC.
const TROLL_MODEL := "character-male-b"
const TROLL_SCALE := 5.0   # towers over a normal human (which uses scale 2.6 -- see npc.gd/tribemember.gd)
var _anim_player: AnimationPlayer = null

## REAL ASSET UPGRADE (2026-07-27): same Quaternius swap as npc.gd/
## tribemember.gd (see those files' own comment blocks for the full
## Blender-pipeline story -- combined base body + hairstyle onto the shared
## 65-bone rig, animation library clips renamed onto this codebase's clip
## convention). Tried FIRST, same FIXED-pick reasoning as TROLL_MODEL above
## (one consistent, recognisable guardian, not a random villager) -- picked
## the bearded male variant, reads as a bigger, gruffer figure even before
## TROLL_SCALE blows it up.
const TROLL_QUATERNIUS_MODEL := "quaternius_male_bearded"

## LAVENDER (2026-07-27): user asked to make the giant trolls lavender.
## Overrides EVERY MeshInstance3D found on the real model (skin, hair,
## clothes alike) to one flat lavender -- a deliberate exception to this
## project's usual "don't material_override a textured asset" rule, since
## here the whole point is a uniform monstrous color, not preserving the
## human character's original look.
const TROLL_COLOR := Color(0.68, 0.55, 0.78)

func _ready() -> void:
	add_to_group("troll")
	if not (_try_quaternius_model() or _try_real_model()):
		_build_visual()
	_build_collision()
	if _anim_player != null and _anim_player.has_animation("idle"):
		_anim_player.play("idle")

func _try_quaternius_model() -> bool:
	var glb_path := "res://assets/humans_quaternius/%s.glb" % TROLL_QUATERNIUS_MODEL
	if not ResourceLoader.exists(glb_path):
		return false
	var packed: PackedScene = load(glb_path)
	var model := packed.instantiate()
	var ap := _find_node_named(model, "AnimationPlayer") as AnimationPlayer
	if ap == null:
		model.queue_free()
		return false
	model.scale = Vector3(TROLL_SCALE, TROLL_SCALE, TROLL_SCALE)
	add_child(model)
	_anim_player = ap
	_tint_all_meshes(model, TROLL_COLOR)
	# loop_mode isn't reliably set on glTF-imported clips -- shared Animation
	# resource, so this covers every troll using this same character file.
	if ap.has_animation("idle"):
		ap.get_animation("idle").loop_mode = Animation.LOOP_LINEAR
	return true

func _try_real_model() -> bool:
	var glb_path := "res://assets/humans_real/%s.glb" % TROLL_MODEL
	if not ResourceLoader.exists(glb_path):
		return false
	var packed: PackedScene = load(glb_path)
	var model := packed.instantiate()
	var ap := _find_node_named(model, "AnimationPlayer") as AnimationPlayer
	if ap == null:
		model.queue_free()
		return false
	model.scale = Vector3(TROLL_SCALE, TROLL_SCALE, TROLL_SCALE)
	add_child(model)
	_anim_player = ap
	_tint_all_meshes(model, TROLL_COLOR)
	# loop_mode isn't reliably set on glTF-imported clips -- shared Animation
	# resource, so this covers every troll using this same character file.
	if ap.has_animation("idle"):
		ap.get_animation("idle").loop_mode = Animation.LOOP_LINEAR
	return true

func _find_node_named(root_node: Node, part_name: String) -> Node:
	if root_node.name == part_name:
		return root_node
	for c in root_node.get_children():
		var found := _find_node_named(c, part_name)
		if found != null:
			return found
	return null

## Recursively material_override every MeshInstance3D under `root_node` to one
## flat color -- used to make the whole troll (skin, hair, clothes alike)
## uniformly lavender regardless of which real-model tier loaded.
func _tint_all_meshes(root_node: Node, color: Color) -> void:
	if root_node is MeshInstance3D:
		(root_node as MeshInstance3D).material_override = MatCache.flat(color)
	for c in root_node.get_children():
		_tint_all_meshes(c, color)

func _build_visual() -> void:
	var body := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 1.1
	cap.height = 3.4
	body.mesh = cap
	body.position = Vector3(0, 1.7, 0)
	body.material_override = MatCache.flat(TROLL_COLOR)
	add_child(body)

func _build_collision() -> void:
	var col := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 1.1
	shape.height = 3.4
	col.shape = shape
	col.position = Vector3(0, 1.7, 0)
	add_child(col)

## No chase AI -- this is a rooted gate-guardian ("blocking the one approach
## point"), not a hunter. It simply hits back whenever an intruder is close
## enough, which is enough to make "reacts to intrusion" real without new AI.
func _process(delta: float) -> void:
	if _dead:
		return
	_attack_cd = maxf(0.0, _attack_cd - delta)
	var p := get_tree().get_first_node_in_group("player")
	if p != null and is_instance_valid(p):
		var d: float = global_position.distance_to((p as Node3D).global_position)
		if d <= ENGAGE_RANGE and _attack_cd <= 0.0:
			_attack_cd = ATTACK_COOLDOWN
			if p.has_method("take_hit"):
				p.take_hit(ATTACK_DAMAGE, self)
			if p.has_method("screen_shake"):
				p.screen_shake(0.07)
			if _anim_player != null:
				var clip: String = "attack-melee-left" if randf() < 0.5 else "attack-melee-right"
				if _anim_player.has_animation(clip):
					_anim_player.play(clip)
	# resume idle once a one-shot attack clip finishes playing
	if _anim_player != null and not _anim_player.is_playing() and _anim_player.has_animation("idle"):
		_anim_player.play("idle")

## Duck-typed entry point every attacker in this game already calls this way
## (FPSPlayer._swing_club(), thrown_club.gd's body_entered branch list).
func take_hit(dmg: float, _attacker) -> void:
	if _dead:
		return
	hp = maxf(0.0, hp - dmg)
	if hp <= 0.0:
		_die()

func _die() -> void:
	_dead = true
	if home_tribe != null and is_instance_valid(home_tribe):
		home_tribe.troll_defeated = true
		var mgr = home_tribe.get("manager")
		if mgr != null and mgr.has_method("notify_cat"):
			mgr.notify_cat("tribes", "The guardian troll of the %s island falls -- the way is open." % str(home_tribe.tribe_name))
	# the real model's own baked "die" animation IS the death beat when
	# available; falls back to the old sink+fade tween otherwise (primitive
	# capsule, or a "die" clip that somehow isn't present).
	if _anim_player != null and _anim_player.has_animation("die"):
		_anim_player.play("die")
		var wait_time: float = _anim_player.get_animation("die").length
		get_tree().create_timer(wait_time).timeout.connect(queue_free)
		return
	var tw := create_tween()
	tw.tween_property(self, "position:y", position.y - 3.0, 1.4)
	tw.tween_callback(queue_free)
