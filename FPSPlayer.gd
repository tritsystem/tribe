extends CharacterBody3D
class_name FPSPlayer

# ─────────────────────────────────────────────────────────────────────────────
# FPS controller + the player's own SURVIVAL actions.
#   WASD move, mouse look, Space jump, Esc free mouse.
#   You get HUNGRY — you auto-eat from the tribe stockpile, and starve (and slow)
#   if it's empty.
#   [F] pick berries from a nearby bush      [C] carve a club
#   [LMB] swing your club at a nearby deer (needs a club!) for meat + skins
#   [E] near a member feeds them (handled by the member's own script)
# Put this on a CharacterBody3D in group "player".
# ─────────────────────────────────────────────────────────────────────────────

@export var speed: float = 5.0
@export var jump_velocity: float = 4.5
@export var mouse_sensitivity: float = 0.003
@export var look_smoothing: float = 7.0   # lerp speed toward target angle; higher = snappier, lower = floatier

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)

@onready var camera: Camera3D = $Camera3D
@onready var _fps_label: Label = $"../UI/FPSLabel"

# survival
var manager
var hunger: float = 0.0
const HUNGER_RATE := 0.9          # gentler — easier to keep fed
const EAT_AT := 60.0
const EAT_RESTORE := 62.0
var _starving: bool = false

# health — camp defenders can drive you off
var hp: float = 100.0
var max_hp: float = 100.0

const REACH := 3.0           # how close to pick berries
const CLUB_REACH := 2.8      # how close to club a deer
const THROW_RANGE := 20.0    # how far a thrown club can reach
const THROW_DAMAGE := 22.0
var _target_yaw: float = 0.0
var _target_pitch: float = 0.0
var _carve_cd: float = 0.0
var _keys_down: Dictionary = {}
var _club_model: MeshInstance3D = null
var _throw_anim_active: bool = false   # suppresses the per-frame visibility sync during the windup tween
var _v_tap_count: int = 0   # discrete [V] presses within the window — 3 selects the whole tribe
var _v_tap_window: float = 0.0
var _shake_amt: float = 0.0      # current shake magnitude (world units); decays to 0
var _cam_base_pos: Vector3 = Vector3.ZERO
var _hurt_flash: float = 0.0            # 1.0 on hit, fades -> red damage vignette
var _hurt_overlay: ColorRect = null

func _ready() -> void:
	add_to_group("player")
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_target_yaw = rotation.y
	_target_pitch = 0.0
	_build_club_model()
	_build_hurt_overlay()
	if camera:
		_cam_base_pos = camera.position

# A full-screen red vignette that flashes when you take a hit -- the SEEN half
# of combat feedback (screen_shake is the FELT half). Without this, rival
# attacks were invisible and read as "npcs ignore me".
func _build_hurt_overlay() -> void:
	var ui := get_node_or_null("../UI")
	if ui == null:
		return
	_hurt_overlay = ColorRect.new()
	_hurt_overlay.name = "HurtFlash"
	_hurt_overlay.color = Color(0.75, 0.05, 0.05, 0.0)
	_hurt_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hurt_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui.add_child(_hurt_overlay)

func _build_club_model() -> void:
	# a club held in view, shown only while the tribe actually has one to wield
	_club_model = MeshInstance3D.new()
	var m := BoxMesh.new()
	m.size = Vector3(0.08, 0.08, 0.7)
	_club_model.mesh = m
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.45, 0.30, 0.15)
	_club_model.material_override = mat
	_club_model.position = Vector3(0.35, -0.30, -0.6)
	_club_model.rotation_degrees = Vector3(-20, 0, 0)
	_club_model.visible = false
	if camera:
		camera.add_child(_club_model)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_target_yaw -= event.relative.x * mouse_sensitivity
		_target_pitch = clampf(_target_pitch - event.relative.y * mouse_sensitivity, -1.4, 1.4)
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if event is InputEventKey and event.pressed and event.keycode == KEY_F3:
		if _fps_label:
			_fps_label.visible = not _fps_label.visible
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_swing_club()
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		_throw_club()

func _process(delta: float) -> void:
	if _fps_label and _fps_label.visible:
		_fps_label.text = "FPS: %d" % Engine.get_frames_per_second()
	if _hurt_flash > 0.0:
		_hurt_flash = maxf(0.0, _hurt_flash - delta * 2.2)   # ~0.45s fade
		if _hurt_overlay:
			_hurt_overlay.color.a = _hurt_flash * 0.42

func _physics_process(delta: float) -> void:
	if manager == null:
		manager = get_tree().get_first_node_in_group("tribe_manager")

	var t := minf(look_smoothing * delta, 1.0)
	rotation.y = lerp_angle(rotation.y, _target_yaw, t)
	if camera:
		camera.rotation.x = lerpf(camera.rotation.x, _target_pitch, t)
		if _shake_amt > 0.001:
			camera.position = _cam_base_pos + Vector3(
				randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), 0.0) * _shake_amt
			_shake_amt = move_toward(_shake_amt, 0.0, delta * 0.25)
		else:
			_shake_amt = 0.0
			camera.position = _cam_base_pos

	_survival(delta)

	if not is_on_floor():
		velocity.y -= gravity * delta

	if Input.is_action_just_pressed("ui_accept") and is_on_floor():
		velocity.y = jump_velocity

	var input_dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_W): input_dir.y -= 1
	if Input.is_key_pressed(KEY_S): input_dir.y += 1
	if Input.is_key_pressed(KEY_A): input_dir.x -= 1
	if Input.is_key_pressed(KEY_D): input_dir.x += 1
	input_dir = input_dir.normalized()

	var spd: float = speed * (0.6 if _starving else 1.0)   # sluggish when starving
	var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	if direction:
		velocity.x = direction.x * spd
		velocity.z = direction.z * spd
	else:
		velocity.x = move_toward(velocity.x, 0, spd)
		velocity.z = move_toward(velocity.z, 0, spd)

	move_and_slide()

# ── hunger + survival inputs ──
func take_hit(dmg: float, _attacker) -> void:
	hp -= dmg
	# FEEDBACK -- this used to be completely silent: no flash, no shake, no sound.
	# Rivals WERE chasing and clubbing the player the whole time, but with hp only
	# shown as a small number in a label (and 3hp/s regen quietly topping it back
	# up), an attack was literally imperceptible and read as "npcs ignore me".
	_hurt_flash = 1.0
	screen_shake(0.05 + minf(dmg, 20.0) * 0.004)   # harder hits shake harder
	if hp <= 0.0:
		hp = max_hp
		# BUG FIXED (2026-07-17): this used to hard-code Vector3(0, 1, 5) --
		# fine back when the world was a flat plane at y=0, but real terrain
		# (hills, valleys, islands) means a fixed point can sit well below
		# the actual generated surface there. Caught live: a player respawned
		# under the map after dying. Tribemanager.gd's own initial-spawn code
		# already asks ground_y() where the real surface is at a given x/z
		# (see _build_terrain()'s "lift the player onto the surface" comment)
		# -- this path just never got the same treatment.
		var rx := 0.0
		var rz := 5.0
		var ry := 1.0
		if manager and manager.has_method("ground_y"):
			ry = manager.ground_y(rx, rz) + 1.0
		global_position = Vector3(rx, ry, rz)   # beaten back to your own camp
		velocity = Vector3.ZERO
		if manager and manager.has_method("notify"):
			manager.notify("You were driven off and limped back to camp!")

# Trigger a short camera shake. strength is in world-space metres of peak offset
# (0.04 is a modest thud; 0.08 would be a heavy blow). Multiple callers in one
# frame take the strongest — the effect decays at 0.25 units/s.
func screen_shake(strength: float = 0.04) -> void:
	_shake_amt = maxf(_shake_amt, strength)

func _survival(delta: float) -> void:
	hp = minf(max_hp, hp + delta * 3.0)   # slowly recover
	hunger = minf(100.0, hunger + delta * HUNGER_RATE)
	if hunger >= EAT_AT and manager and manager.has_method("spend_food"):
		if manager.spend_food(1):
			hunger = maxf(0.0, hunger - EAT_RESTORE)
	_starving = hunger >= 100.0

	_carve_cd = maxf(0.0, _carve_cd - delta)
	if _key_just(KEY_F):
		_pick_berries()
	if _key_just(KEY_C):
		_carve_club()
	if _key_just(KEY_G):
		_bribe()
	if _key_just(KEY_T):
		_scout()
	if _key_just(KEY_Y):
		_build_fence()
	if _key_just(KEY_L):
		_build_teepee()
	if _key_just(KEY_Z):
		_build_block()
	if _key_just(KEY_H):
		_feed_dog()
	if _key_just(KEY_J) and manager and manager.has_method("toggle_dog_rally"):
		manager.toggle_dog_rally()
	if _key_just(KEY_BRACKETLEFT) and manager and manager.has_method("cycle_focus"):
		manager.cycle_focus(-1)
	if _key_just(KEY_BRACKETRIGHT) and manager and manager.has_method("cycle_focus"):
		manager.cycle_focus(1)
	if _key_just(KEY_K) and manager and manager.has_method("raid_focus"):
		manager.raid_focus()
	# individual command: [M] cycles selection, or hold [V] while looking at
	# someone to select them directly — then number keys direct them.
	if _key_just(KEY_M) and manager and manager.has_method("cycle_selection"):
		manager.cycle_selection()
	if Input.is_key_pressed(KEY_V) and manager and manager.has_method("select_lookat") and camera:
		manager.select_lookat(camera.global_position, -camera.global_transform.basis.z)
	# triple-tap [V] (as discrete presses, not the hold-to-look-select above)
	# selects your whole tribe at once instead of one member.
	if _key_just(KEY_V):
		_v_tap_count += 1
		_v_tap_window = 0.6
		if _v_tap_count >= 3:
			_v_tap_count = 0
			if manager and manager.has_method("select_whole_tribe"):
				manager.select_whole_tribe()
	if _v_tap_window > 0.0:
		_v_tap_window -= delta
		if _v_tap_window <= 0.0:
			_v_tap_count = 0
	var has_selection: bool = manager != null and (
		manager.get("selected_member") != null
		or (manager.get("selected_group") != null and not manager.selected_group.is_empty())
	)
	if has_selection and manager.has_method("command_selected"):
		# plain number = default quota. Shift+number = a small order (15).
		# Ctrl+number = a large order (80). Stand-ins for "say a quantity" —
		# see Tribemanager.command_selected()'s docstring for the real hook.
		var amt := -1
		if Input.is_key_pressed(KEY_SHIFT): amt = 15
		elif Input.is_key_pressed(KEY_CTRL): amt = 80
		if _key_just(KEY_1): manager.command_selected("gather", amt)
		elif _key_just(KEY_2): manager.command_selected("hunt", amt)
		elif _key_just(KEY_3): manager.command_selected("scout", amt)
		elif _key_just(KEY_4): manager.command_selected("wood", amt)
		elif _key_just(KEY_5): manager.command_selected("build")
		elif _key_just(KEY_6): manager.command_selected("recruit", amt)
		elif _key_just(KEY_7): manager.command_selected("guard")
		elif _key_just(KEY_0): manager.command_selected("auto")
	# [O] cycle formation — phalanx / wedge / testudo / loose. Applies to
	# backers following you AND to any war party your tribe musters.
	if _key_just(KEY_O) and manager and manager.has_method("cycle_formation"):
		manager.cycle_formation()
	# [I] cycle how far out the defense perimeter sits ([7] posts a guard there)
	if _key_just(KEY_I) and manager and manager.has_method("cycle_perimeter"):
		manager.cycle_perimeter()
	# [P] cycle how the whole workforce divides its labour
	if _key_just(KEY_P) and manager and manager.has_method("cycle_work_plan"):
		manager.cycle_work_plan()
	# [N] raise a forward camp where you stand (costs wood)
	if _key_just(KEY_N) and manager and manager.has_method("try_build_camp"):
		var f := -global_transform.basis.z
		f.y = 0.0
		if f.length() < 0.01:
			f = Vector3(0, 0, -1)
		manager.try_build_camp(global_position + f.normalized() * 5.0, true)

	if _club_model and manager and not _throw_anim_active:
		_club_model.visible = manager.get("player_holds_club") == true

func _key_just(code: int) -> bool:
	var down := Input.is_key_pressed(code)
	var was: bool = _keys_down.get(code, false)
	_keys_down[code] = down
	return down and not was

func _pick_berries() -> void:
	if manager == null:
		return
	var bush := _nearest_in_group("food_source", REACH)
	if bush and bush.has_method("harvest"):
		var got: int = bush.harvest(3.0)
		if got > 0:
			manager.add_food(got)
			hunger = maxf(0.0, hunger - 12.0)   # snack while you pick
			manager.notify("You pick %d berries." % got)
		else:
			manager.notify("This bush is picked bare.")
	else:
		manager.notify("No bush within reach to pick.")

func _carve_club() -> void:
	if manager == null:
		return
	if manager.get("player_holds_club") == true:
		manager.notify("You already have a club.")
		return
	if _carve_cd > 0.0:
		manager.notify("Still carving... (%.0fs left)" % _carve_cd)
		return
	if not manager.craft_club(true):
		return   # craft_club() already posted the "need wood" notice
	_carve_cd = 3.0
	# craft_club() already posted a "forge a masterwork club" flash if a
	# looted material got spent — don't stomp it with a generic message
	if manager.get("player_club_material") == "":
		manager.notify("You carve a sturdy club.")

func _swing_club() -> void:
	if manager == null:
		return
	_play_swing_anim()
	var has_club: bool = manager.get("player_holds_club") == true
	# a masterwork club (forged from a looted tribe material — see
	# Tribemanager.craft_club/materials_owned) hits harder than a plain one
	var club_mat: String = str(manager.get("player_club_material"))
	var dmg_mult: float = 1.5 if club_mat != "" else 1.0
	# 1) strike a tribesperson (rival or camp defender) — not neutrals
	var foe := _nearest_in_group("npc", CLUB_REACH)
	if foe and not foe.get("neutral") and foe.has_method("take_hit"):
		foe.take_hit((18.0 if has_club else 9.0) * dmg_mult, self)
		manager.notify("You strike a tribesperson!")
		return
	# 2) smash an enemy camp's totem — the blow is routed to their actual
	# infrastructure (teepees first, then the stockpile); knock both down to
	# conquer the tribe and convert their whole roster
	var core := _nearest_in_group("camp_core", 4.5)
	if core and core.has_meta("tribe"):
		var t = core.get_meta("tribe")
		if is_instance_valid(t) and t.has_method("damage_camp"):
			t.damage_camp((18.0 if has_club else 9.0) * dmg_mult, true)
			if is_instance_valid(t):
				if t.stockpile_destroyed:
					manager.notify("The %s stockpile is rubble — one more strike and they fall!" % t.tribe_name)
				else:
					manager.notify("You batter the %s camp! %d teepees standing, stockpile %d%%" % [
						t.tribe_name, t.teepees.size(), int(t.stockpile_hp / maxf(1.0, t.stockpile_max_hp) * 100.0)])
			return
	# 3) club a deer (needs a club)
	var deer := _nearest_in_group("animal", CLUB_REACH)
	if deer and deer.has_method("killed"):
		if not has_club:
			manager.notify("You've no club to hunt! Press C to carve one.")
			return
		var loot: Dictionary = deer.killed()
		manager.add_food(int(loot.get("food", 0)))
		manager.add_materials(int(loot.get("skins", 0)))
		manager.notify("You club a %s! +%d meat, +%d skins" % [loot.get("name", "beast"), int(loot.get("food", 0)), int(loot.get("skins", 0))])
		return
	# 2) chop a tree for wood (a club bites harder)
	var tree := _nearest_in_group("tree", 2.6)
	if tree and tree.has_method("chop"):
		var got: int = tree.chop(2 if has_club else 1)
		if got > 0:
			manager.add_wood(got)
			manager.notify("Timber! +%d wood (wood: %d)" % [got, manager.wood])
		else:
			manager.notify("You hack at the tree...")
		return
	# 3) knock down a fence (yours or in your way)
	var fence := _nearest_in_group("fence", 2.4)
	if fence and fence.has_method("take_damage"):
		fence.take_damage(2)
		manager.notify("You batter the fence.")
		return
	# 4) smash a block (yours, a rival's wall, anyone's maze) — same plain
	# swing as a fence; RMB-thrown clubs and other attackers can also hit
	# these since take_damage is the universal entry point
	var blk := _nearest_in_group("block", 2.6)
	if blk and blk.has_method("take_damage"):
		blk.take_damage(4 if has_club else 2)
		manager.notify("You smash a block.")
		return
	manager.notify("You swing at empty air.")

# RMB: actually hurl the club — a real projectile flies out and deals damage
# on whatever it physically touches (see thrown_club.gd), instead of an
# instant invisible raycast. The club is gone either way (hit or miss) —
# carve a new one with [C] (costs wood now, see Tribemanager.craft_club).
func _throw_club() -> void:
	if manager == null:
		return
	if manager.get("player_holds_club") != true:
		manager.notify("No club to throw! Press C to carve one.")
		return
	var club_mat: String = str(manager.get("player_club_material"))
	var dmg_mult: float = 1.5 if club_mat != "" else 1.0
	manager.player_holds_club = false
	manager.player_club_material = ""   # the club (and whatever it was forged from) is gone

	var dir := -camera.global_transform.basis.z
	_play_throw_anim()

	var proj := Area3D.new()
	proj.set_script(load("res://thrown_club.gd"))
	get_tree().current_scene.add_child(proj)
	var launch_pos := camera.global_position + dir * 0.6 - camera.global_transform.basis.y * 0.2
	proj.launch(launch_pos, dir, 26.0, THROW_DAMAGE * dmg_mult, self)
	if club_mat != "":
		manager.notify("You hurl your %s club!" % club_mat)
	else:
		manager.notify("You hurl your club!")

# wind up and "release" the club model before the real projectile takes over.
# Sets _throw_anim_active so the per-frame visibility sync (which would
# otherwise hide the model the instant player_holds_club drops to false)
# doesn't cut the windup short.
func _play_throw_anim() -> void:
	if _club_model == null:
		return
	_throw_anim_active = true
	_club_model.visible = true
	var tw := create_tween()
	tw.tween_property(_club_model, "rotation_degrees", Vector3(-100, -15, 35), 0.09)
	tw.tween_callback(func():
		if _club_model:
			_club_model.visible = false   # thrown — gone until a new one's carved
			_club_model.rotation_degrees = Vector3(-20, 0, 0)
		_throw_anim_active = false
	)

# swing the held club through a quick arc on melee hits
func _play_swing_anim() -> void:
	if _club_model == null:
		return
	var base_rot: Vector3 = Vector3(-20, 0, 0)
	var tw := create_tween()
	tw.tween_property(_club_model, "rotation_degrees", Vector3(-75, 10, -30), 0.06)
	tw.tween_property(_club_model, "rotation_degrees", base_rot, 0.14)

func _build_fence() -> void:
	if manager == null or not manager.has_method("try_build_fence"):
		return
	var fwd := -global_transform.basis.z
	fwd.y = 0.0
	if fwd.length() < 0.01:
		fwd = Vector3(0, 0, -1)
	fwd = fwd.normalized()
	var pos := global_position + fwd * 2.2
	pos.y = 0.0
	manager.try_build_fence(pos, atan2(fwd.x, fwd.z), true)

func _build_block() -> void:
	if manager == null or not manager.has_method("try_build_block"):
		return
	var fwd := -global_transform.basis.z
	fwd.y = 0.0
	if fwd.length() < 0.01:
		fwd = Vector3(0, 0, -1)
	fwd = fwd.normalized()
	var target := global_position + fwd * 2.4
	manager.try_build_block(Vector3(target.x, _stack_top(target), target.z), true)

# scan existing blocks on this XZ grid column and return the height to stack
# the next one on top of (ground level if the column is empty) — this is
# what lets you build UP into walls/towers, not just a flat scatter of cubes
func _stack_top(at: Vector3) -> float:
	var col_x: float = round(at.x / 2.0) * 2.0
	var col_z: float = round(at.z / 2.0) * 2.0
	var top := 1.0   # ground-level block center
	for b in get_tree().get_nodes_in_group("block"):
		var bn := b as Node3D
		if bn == null or not is_instance_valid(bn):
			continue
		if absf(bn.global_position.x - col_x) < 0.5 and absf(bn.global_position.z - col_z) < 0.5:
			top = maxf(top, bn.global_position.y + 2.0)
	return top

func _build_teepee() -> void:
	if manager == null or not manager.has_method("try_build_teepee"):
		return
	var fwd := -global_transform.basis.z
	fwd.y = 0.0
	if fwd.length() < 0.01:
		fwd = Vector3(0, 0, -1)
	fwd = fwd.normalized()
	var pos := global_position + fwd * 2.6
	pos.y = 0.0
	manager.try_build_teepee(pos, true)

func _feed_dog() -> void:
	if manager == null:
		return
	var dog := _nearest_in_group("dog", 3.6)
	if dog == null:
		manager.notify("No dog within reach to feed.")
		return
	if not manager.spend_food(1):
		manager.notify("No food to feed the dog.")
		return
	var was_loyal: bool = dog.has_method("is_loyal") and dog.is_loyal()
	if dog.has_method("feed"):
		dog.feed()
	if not was_loyal and dog.has_method("is_loyal") and dog.is_loyal():
		manager.notify("The stray is yours now — a loyal guard dog! [J] to rally.")
	elif was_loyal:
		manager.notify("Your hound wolfs the scrap down, tail wagging.")
	else:
		manager.notify("You coax the wary stray... it's warming to you.")

func _bribe() -> void:
	if manager == null:
		return
	var npc := _nearest_in_group("neutral", 3.5)
	if npc == null:
		manager.notify("No wanderer within reach to bribe.")
		return
	var paid := false
	if manager.spend_food(3):
		paid = true
	elif manager.spend_materials(2):
		paid = true
	if not paid:
		manager.notify("Need 3 food or 2 skins to bribe a wanderer.")
		return
	manager.recruit_neutral(npc)
	manager.notify("A wanderer takes your gift and joins your clan!")

func _scout() -> void:
	if manager and manager.has_method("player_scout"):
		manager.player_scout(global_position)

func _nearest_in_group(grp: String, maxd: float) -> Node3D:
	var best: Node3D = null
	var bd := maxd
	for n in get_tree().get_nodes_in_group(grp):
		var nn := n as Node3D
		if nn and is_instance_valid(nn):
			var d := global_position.distance_to(nn.global_position)
			if d < bd:
				bd = d
				best = nn
	return best
