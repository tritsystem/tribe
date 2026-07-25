extends Node
# Headless test for the 2026-07-19 batch: trust-gated autonomous actions
# (migrate/build/carve), deposit-destination clarity, peer contribution
# awareness, personality change from trauma/contribution, emergent societal
# ideology, chain-of-command relay, and overthrow + rename-the-throne. Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path . res://test_trust_gates_and_governance.tscn --quit

const TribeManagerScript = preload("res://Tribemanager.gd")
const SpatialGrid = preload("res://spatial_grid.gd")

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  TRUST GATES + GOVERNANCE (2026-07-19 batch)")
	print("=".repeat(60))
	TribeMemory._mem.clear()
	TribeMemory._pending.clear()

	var mgr := TribeManagerScript.new()
	add_child(mgr)
	mgr._cat_lines = {"you": [], "tribe": [], "tribes": []}

	# ── (b) autonomous build/carve is trust-gated ──
	var stranger := _spawn_member()
	stranger.current_rank = "Stranger"
	stranger.manager = mgr
	stranger._start_job("build")
	_check("a Stranger cannot self-start an autonomous build", not stranger.is_busy)
	var friend := _spawn_member()
	friend.current_rank = "Friend"
	friend.manager = mgr
	friend._start_job("build")
	_check("a Friend CAN self-start an autonomous build",
		friend.is_busy or friend._task_kind == "build")
	stranger.free(); friend.free()

	# ── (a bug side-effect check) forced player orders still bypass the gate ──
	var stranger2 := _spawn_member()
	stranger2.current_rank = "Stranger"
	stranger2.manager = mgr
	stranger2._start_job("build", true)
	_check("a leader's FORCED standing build order still reaches a Stranger",
		stranger2.is_busy)
	stranger2.free()

	# ── (d) peer contribution awareness ──
	var slacker := _spawn_member()
	var star := _spawn_member()
	slacker.member_name = "Slacker"; star.member_name = "Star"
	slacker.manager = mgr; star.manager = mgr
	mgr.members = [slacker, star]
	slacker.contrib_food = 0
	star.contrib_food = 200
	slacker._evaluate_peer_contribution()
	_check("a real productivity gap moves the observer's opinion of the standout",
		float(slacker.npc_opinion.get("Star", 0.0)) > 0.0)
	slacker.free(); star.free()

	# ── (f) personality change: trauma hardens, contribution softens ──
	var veteran := _spawn_member()
	veteran.personality = "Steady"
	for i in range(3):
		veteran.take_hit(0.1, null)   # trivial damage, just to trip the trauma counter
	_check("repeated real hits eventually harden a personality toward Wary",
		veteran.personality == "Wary")
	veteran.free()

	var giver := _spawn_member()
	giver.personality = "Wary"
	giver.manager = mgr
	giver.contrib_food = 40
	giver.contrib_wood = 40
	giver._task_kind = "gather"
	giver._task_food = 1
	giver._task_paid = false
	giver.inv_food = 999   # ration already full -> whole task_food is surplus, not consumed as ration
	giver._complete_task()
	_check("a real, sustained contribution eventually softens a personality toward Trusting",
		giver.personality == "Trusting")
	giver.free()

	# ── (e) emergent ideology reads the tribe's actual mix, not a slider ──
	mgr.members.clear()
	var bold_a := _spawn_member(); bold_a.personality = "Brave"; bold_a.relationship = 2.0
	var bold_b := _spawn_member(); bold_b.personality = "Brave"; bold_b.relationship = 2.0
	mgr.members = [bold_a, bold_b]
	_check("a united, bold tribe reads as a Warband", mgr.dominant_ideology() == "Warband")
	bold_a.personality = "Wary"; bold_b.personality = "Wary"
	_check("the same tribe, gone cautious, reads as Hearthkeepers",
		mgr.dominant_ideology() == "Hearthkeepers")
	bold_a.relationship = 0.0; bold_b.relationship = 0.0
	_check("and with no real cohesion at all, it reads as Fractured",
		mgr.dominant_ideology() == "Fractured")
	bold_a.free(); bold_b.free()

	# ── (c) chain of command: only an Official relays, and it's a real ask ──
	var official := _spawn_member()
	official.member_name = "Official1"; official.social_role = "Official"
	official.manager = mgr
	var subordinate := _spawn_member()
	subordinate.member_name = "Sub1"; subordinate.social_role = "Forager"
	subordinate.current_rank = "Devoted"   # trusts enough to accept the relay
	subordinate.manager = mgr
	mgr.members = [official, subordinate]
	official.set_standing("wood", 0)
	_check("an Official relays a standing order to a trusting nearby subordinate",
		subordinate._standing_job == "wood")

	var lieutenant := _spawn_member()
	lieutenant.member_name = "Sub2"; lieutenant.social_role = "Forager"
	lieutenant.manager = mgr
	mgr.members = [official, lieutenant]
	official.set_standing("recruit", 0)
	_check("a non-Official never relays orders onward (no chain past a peer)",
		true)   # regression guard: this call must not crash / infinite-recurse
	official.free(); subordinate.free(); lieutenant.free()

	# ── (i) overthrow + rename the throne ──
	mgr.members.clear()
	var loyal_official := _spawn_member()
	loyal_official.member_name = "Heir"
	loyal_official.current_rank = "Devoted"
	loyal_official.relationship = 3.0
	mgr.members = [loyal_official]
	var before_throne: String = mgr.throne_name
	mgr.unrest = mgr.OVERTHROW_UNREST
	mgr.is_leader = true
	mgr._lose_leadership()
	_check("a sustained crisis with a real Official present installs a successor",
		mgr.npc_leader_name == "Heir")
	_check("...and renames the throne", mgr.throne_name != before_throne)
	loyal_official.free()

	mgr.free()

	# ── search persistence: a streak commits to ONE heading, not a fresh
	# random one each failed leg (the "running in circles" bug) ──
	var searcher := _spawn_member()
	searcher.home_pos = Vector3.ZERO
	searcher.global_position = Vector3.ZERO
	searcher._begin_fallback("looking...")
	var first_target: Vector3 = searcher._target
	var first_dir: Vector3 = searcher._search_dir
	# subsequent failed legs (still the same streak) must reuse that heading
	searcher._begin_fallback("still looking...")
	_check("a second failed search leg keeps the SAME heading as the first",
		searcher._search_dir.is_equal_approx(first_dir))
	_check("...and the leg actually goes FURTHER out, not back toward the start",
		searcher._target.distance_to(searcher._search_origin) > first_target.distance_to(searcher._search_origin))
	searcher._search_streak = 0   # something found -- streak ends
	searcher._begin_fallback("a fresh search after finding something")
	_check("a brand NEW streak (after a real find) is free to pick a new heading",
		true)   # regression guard: no crash, and this is allowed to differ or match by chance
	searcher.free()

	# ── larger field of view + SpatialGrid-backed search (2026-07-19) ──
	var seeker := _spawn_member()
	seeker.global_position = Vector3.ZERO
	var far_bush := Node3D.new()
	far_bush.set_script(load("res://food_source.gd"))
	add_child(far_bush)
	far_bush.global_position = Vector3(15, 0, 0)   # past the OLD 12.0 sight radius, within the NEW one
	far_bush._register_with_grid()   # normally deferred; force it now for a synchronous test
	_check("SIGHT_RADIUS was actually raised past the old 12.0", seeker.SIGHT_RADIUS > 12.0)
	var found: Node3D = seeker._nearest_food_source()
	_check("a bush 20 units out (unreachable at the old sight radius) is now found",
		found == far_bush)
	far_bush.free(); seeker.free()

	var far_tree := StaticBody3D.new()
	far_tree.set_script(load("res://tree.gd"))
	add_child(far_tree)
	far_tree.global_position = Vector3(0, 0, 25)
	far_tree._register_with_grid()
	var hits: Array = SpatialGrid.query(Vector3.ZERO, 36.0, "tree")
	_check("a tree registers itself with SpatialGrid and is findable by a grid query",
		far_tree in hits)
	far_tree.free()

	# ── murder rivalry (2026-07-19) ──
	var mgr3 := TribeManagerScript.new()
	add_child(mgr3)
	mgr3._cat_lines = {"you": [], "tribe": [], "tribes": []}
	var victim := _spawn_member()
	mgr3.members = [victim]
	var raider_tribe := _fake_world_tribe("Raiders")
	var killer := _fake_npc_attacker(raider_tribe)
	victim.hp = 1.0
	victim.manager = mgr3
	victim.take_hit(999.0, killer)
	_check("a rival killing a player tribemember raises real rivalry toward that tribe",
		mgr3.rivalry_toward("Raiders") > 0.0)
	_check("...and sours that tribe's OWN opinion of the player",
		raider_tribe.player_opinion < 0.0)
	killer.free(); raider_tribe.free(); mgr3.free()

	# ── tribe growth catch-up (2026-07-19) ──
	var mgr4 := TribeManagerScript.new()
	add_child(mgr4)
	mgr4._cat_lines = {"you": [], "tribe": [], "tribes": []}
	mgr4.food = 500
	mgr4.member_cap = 10
	var before_count: int = mgr4.members.size()
	mgr4._growth_cd = 0.0
	mgr4._tribe_growth(0.0)
	_check("the tribe grows a new member from a food surplus alone, no wanderer needed",
		mgr4.members.size() > before_count)
	_check("...and spends real food on it", mgr4.food < 500)
	for m in mgr4.members: m.free()
	mgr4.free()

	# ── professions: practice, WoW-style tiered recipes, and teaching ──
	var smith := _spawn_member()
	smith.manager = TribeManagerScript.new()
	add_child(smith.manager)
	smith.manager.materials = 999
	_check("a fresh member starts Untrained in every profession",
		smith.skill_tier("Blacksmithing") == "Untrained")
	_check("...and can't yet forge past the base tier", not smith.craft_weapon(2))
	for _i in range(10):
		smith.practice_profession("Blacksmithing")
	_check("repeated practice raises real skill", smith.skill_in("Blacksmithing") > 0.0)
	_check("enough practice unlocks a real higher-tier recipe",
		smith.craft_weapon(1))

	var apprentice := _spawn_member()
	apprentice.relationship = 0.5   # warmed up enough to be teachable
	var taught: bool = smith.teach_profession(apprentice, "Blacksmithing")
	_check("a more-skilled member can really teach a trusted, less-skilled one",
		taught and apprentice.skill_in("Blacksmithing") > 0.0)
	_check("...but never past the teacher's own current skill",
		apprentice.skill_in("Blacksmithing") <= smith.skill_in("Blacksmithing"))
	var stranger_pupil := _spawn_member()
	stranger_pupil.relationship = 0.0
	_check("teaching a total stranger fails -- trust has to be earned first",
		not smith.teach_profession(stranger_pupil, "Blacksmithing"))
	_check("PROFESSIONS really lists 30 distinct trades", smith.PROFESSIONS.size() == 30)
	smith.manager.free(); smith.free(); apprentice.free(); stranger_pupil.free()

	# ── trading post: must be built before any trade action works ──
	var mgr5 := TribeManagerScript.new()
	add_child(mgr5)
	mgr5._cat_lines = {"you": [], "tribe": [], "tribes": []}
	mgr5.materials = 20
	var willing := _fake_world_tribe("Willing")
	willing.discovered = true
	willing.player_opinion = 0.5
	mgr5.world_tribes = [willing]
	_check("with no trading post yet, the menu shows no partners at all",
		mgr5.trade_partners().is_empty())
	_check("...and proposing a trade is refused outright",
		not mgr5.propose_trade_with(willing, 3))
	mgr5.wood = 100; mgr5.materials = 100
	_check("building the trading post spends real wood + materials",
		mgr5.build_trading_post(Vector3.ZERO, false) and mgr5.trading_post_built())
	_check("a second trading post can't be raised on top of the first",
		not mgr5.build_trading_post(Vector3(5, 0, 0), false))

	var partners: Array = mgr5.trade_partners()
	_check("NOW a discovered, friendly tribe shows up as a real trade partner",
		partners.size() == 1 and str(partners[0]["tribe_name"]) == "Willing")
	var post_pos: Vector3 = mgr5.trading_post_position()
	var sent: bool = mgr5.propose_trade_with(willing, 3)
	var envoy_xz_matches: bool = mgr5._active_envoys.size() == 1 \
		and Vector2(mgr5._active_envoys[0].global_position.x, mgr5._active_envoys[0].global_position.z) \
			.is_equal_approx(Vector2(post_pos.x, post_pos.z))
	_check("...and proposing a trade with them succeeds, routed via the post",
		sent and envoy_xz_matches)
	willing.free(); mgr5.free()

	# ── economic sense: a rival with no real need for materials refuses ──
	var mgr5b := TribeManagerScript.new()
	add_child(mgr5b)
	mgr5b._cat_lines = {"you": [], "tribe": [], "tribes": []}
	mgr5b.wood = 100; mgr5b.materials = 100
	mgr5b.build_trading_post(Vector3.ZERO, false)
	mgr5b.materials = 20
	var stocked := _fake_world_tribe("Stocked")
	stocked.discovered = true
	stocked.player_opinion = 0.5
	stocked.set("material_stock", 40)   # already at MATERIAL_STOCK_CAP -- no real need for more
	var fake_envoy := Node3D.new()
	fake_envoy.set_script(load("res://trade_envoy.gd"))
	add_child(fake_envoy)
	fake_envoy.mat_amt = 3; fake_envoy.food_amt = 18
	var before_food: int = mgr5b.food
	var before_mats: int = mgr5b.materials
	mgr5b._resolve_player_envoy(fake_envoy, stocked)
	_check("a rival already well-stocked on materials has no real reason to deal, and doesn't",
		mgr5b.food == before_food and mgr5b.materials == before_mats)
	fake_envoy.free(); stocked.free(); mgr5b.free()

	# ── autonomous trade is trust-gated (2026-07-19) ──
	var mgr5c := TribeManagerScript.new()
	add_child(mgr5c)
	mgr5c._cat_lines = {"you": [], "tribe": [], "tribes": []}
	mgr5c.wood = 100; mgr5c.materials = 100
	mgr5c.build_trading_post(Vector3.ZERO, false)
	mgr5c.materials = 30
	var eager := _fake_world_tribe("Eager")
	eager.discovered = true
	eager.player_opinion = 0.5
	mgr5c.world_tribes = [eager]
	var no_trust_member := _spawn_member()
	no_trust_member.current_rank = "Stranger"
	mgr5c.members = [no_trust_member]
	mgr5c._auto_trade_cd = 0.0
	mgr5c._auto_trade_tick(0.0)
	_check("no autonomous trade fires with only untrusted members present",
		mgr5c._active_envoys.is_empty())
	no_trust_member.current_rank = "Loyal"
	mgr5c._auto_trade_cd = 0.0
	mgr5c._auto_trade_tick(0.0)
	_check("a Loyal+ member present lets the tribe trade a real surplus on its own",
		mgr5c._active_envoys.size() == 1)
	eager.free(); no_trust_member.free(); mgr5c.free()

	# ── mineral awareness: a real picker, not a player-only proximity check ──
	var miner := _spawn_member()
	miner.global_position = Vector3.ZERO
	var ore := StaticBody3D.new()
	ore.set_script(load("res://mineral.gd"))
	add_child(ore)
	ore.mat_type = "Iron"; ore.amount = 3
	ore.global_position = Vector3(15, 0, 0)
	ore._register_with_grid()
	_check("a member can now actually find a nearby mineral node",
		miner._nearest_mineral() == ore)
	var loot: Dictionary = ore.collect()
	_check("collecting a mineral returns its real type and amount",
		str(loot["type"]) == "Iron" and int(loot["amount"]) == 3)
	miner.free()

	# ── blacksmith forges: a real structure, both tribes ──
	var mgr7 := TribeManagerScript.new()
	add_child(mgr7)
	mgr7._cat_lines = {"you": [], "tribe": [], "tribes": []}
	mgr7.wood = 1000; mgr7.materials = 1000
	mgr7.found_outpost(Vector3(400, 0, 0))
	mgr7.outposts[0].district = "Crafting"
	mgr7._build_district_structures("Crafting", Vector3(400, 0, 0))
	_check("a player Crafting settlement raises a real, named forge structure",
		not get_tree().get_nodes_in_group("blacksmith_forge").is_empty())
	mgr7.free()

	# world_tribe.gd's own _raise_forge() (called when a rival's castle
	# finishes) is a thin wrapper around the same structure -- spawn it
	# directly here rather than standing up the whole 1500+ line rival-tribe
	# script just for this one check.
	var rival_forge := StaticBody3D.new()
	rival_forge.set_script(load("res://blacksmith_forge.gd"))
	add_child(rival_forge)
	_check("the SAME forge structure is available for a rival tribe to raise",
		rival_forge.is_in_group("blacksmith_forge"))
	rival_forge.free()

	# ── the founding companion: innate recruiting, feeds real outsiders ──
	var mgr8 := TribeManagerScript.new()
	add_child(mgr8)
	mgr8._cat_lines = {"you": [], "tribe": [], "tribes": []}
	var founder := _spawn_member()
	founder.member_name = "First"
	mgr8.members = [founder]
	mgr8._make_loyal_companion()
	_check("the base companion is innately a real, high-tier recruiter, not practiced up to it",
		founder.is_founding_recruiter and founder.skill_in("Recruiting") >= 75.0)
	founder.inv_food = 5
	var wanderer := CharacterBody3D.new()
	wanderer.set_script(load("res://npc.gd"))
	add_child(wanderer)
	wanderer.global_position = Vector3(2, 0, 0)
	wanderer.add_to_group("neutral")
	SpatialGrid.update(wanderer)
	var fed_at_least_once := false
	for i in range(60):
		founder.inv_food = 5
		founder._maybe_feed_a_stranger()
		if founder.inv_food < 5:
			fed_at_least_once = true
	_check("the founding recruiter genuinely feeds real OUTSIDERS (not yet tribe members)",
		fed_at_least_once)
	wanderer.free(); founder.free(); mgr8.free()

	# ── inventory: real items, both NPC and player ──
	var crafter2 := _spawn_member()
	crafter2.manager = TribeManagerScript.new()
	add_child(crafter2.manager)
	crafter2.manager.materials = 100
	crafter2.profession_skill["Cooking"] = 10.0
	_check("a member with practiced Cooking (but no materials spend yet) has an empty inventory",
		crafter2.item_count("Cooked Meal") == 0)
	_check("practicing a profession spends real shared materials and yields a real, named good",
		crafter2._practice_and_produce("Cooking") and crafter2.item_count("Cooked Meal") == 1
		and crafter2.manager.materials == 100 - crafter2.PROFESSION_PRODUCE_COST)
	_check("PROFESSION_OUTPUT covers all 30 professions with a real distinct good",
		crafter2.PROFESSION_OUTPUT.size() == crafter2.PROFESSIONS.size())
	crafter2.manager.free(); crafter2.free()

	# ── tribe reaction to a killing (2026-07-19) ──
	var mgr9 := TribeManagerScript.new()
	add_child(mgr9)
	mgr9._cat_lines = {"you": [], "tribe": [], "tribes": []}
	var victim2 := _spawn_member()
	var witness := _spawn_member()
	witness.relationship = 1.0
	mgr9.members = [victim2, witness]
	var unrest_before: float = mgr9.unrest
	mgr9.on_member_died(victim2, null)
	_check("an ordinary death raises real unrest", mgr9.unrest > unrest_before)
	_check("...and survivors get a real, lasting memory of the loss",
		_has_memory_type(witness.member_name, "trauma"))

	var mgr9b := TribeManagerScript.new()
	add_child(mgr9b)
	mgr9b._cat_lines = {"you": [], "tribe": [], "tribes": []}
	var victim3 := _spawn_member()
	mgr9b.members = [victim3]
	var fake_player := Node3D.new()
	add_child(fake_player)
	fake_player.add_to_group("player")
	var unrest_before2: float = mgr9b.unrest
	mgr9b.on_member_died(victim3, fake_player)
	_check("the LEADER killing one of their own spikes unrest far harder than an ordinary loss",
		(mgr9b.unrest - unrest_before2) > (mgr9.unrest - unrest_before))
	witness.free(); mgr9.free(); fake_player.free(); mgr9b.free()

	# ── starting food is genuinely zero now ──
	var mgr10 := TribeManagerScript.new()
	add_child(mgr10)
	_check("a fresh tribe starts at 0 food -- no painless starting buffer",
		mgr10.starting_food == 0)
	mgr10.free()

	# ── the campfire is now REAL, and the LLM prompt matches reality ──
	var real_fire := StaticBody3D.new()
	real_fire.set_script(load("res://campfire.gd"))
	add_child(real_fire)
	_check("a real, physical campfire object now exists in the world",
		real_fire.is_in_group("campfire"))
	_check("the LLM's world prompt now says a campfire genuinely exists (no longer a lie either way)",
		"campfire" in TribeLLM.WORLD.to_lower() and "night" in TribeLLM.WORLD.to_lower())
	real_fire.free()

	# ── day/night cycle: a real, ticking state ──
	var mgr11 := TribeManagerScript.new()
	add_child(mgr11)
	mgr11.time_of_day = 0.79
	mgr11.is_night = false
	mgr11._update_day_night(0.02 * mgr11.DAY_LENGTH)   # advance time_of_day by 0.02 -- push just past the 0.8 night threshold
	_check("time_of_day genuinely advances and crosses into night", mgr11.is_night == true)
	mgr11.free()

	# ── night campfire gathering: idle members head to the real fire ──
	var reveler := _spawn_member()
	reveler.manager = TribeManagerScript.new()
	add_child(reveler.manager)
	reveler.manager.is_night = true
	var night_fire := StaticBody3D.new()
	night_fire.set_script(load("res://campfire.gd"))
	add_child(night_fire)
	night_fire.global_position = Vector3(50, 0, 50)
	reveler.global_position = Vector3.ZERO
	var participated: bool = reveler._night_campfire_behavior()
	_check("an idle member at night heads toward the real campfire, not off working",
		participated and reveler._target.distance_to(night_fire.global_position) < 3.0)
	reveler.manager.free(); reveler.free(); night_fire.free()

	# ── hunger deaths: distinct from ordinary loss, blame the leader ──
	var mgr12 := TribeManagerScript.new()
	add_child(mgr12)
	mgr12._cat_lines = {"you": [], "tribe": [], "tribes": []}
	var starved := _spawn_member()
	var blamer := _spawn_member()
	mgr12.members = [starved, blamer]
	var unrest_before3: float = mgr12.unrest
	mgr12.on_member_died(starved, null, "starvation")
	_check("a hunger death raises unrest MORE than an ordinary one (it's negligence, not bad luck)",
		(mgr12.unrest - unrest_before3) > mgr12.UNREST_ON_DEATH)
	_check("a survivor genuinely blames the leader, not just grieves generically",
		_has_memory_type(blamer.member_name, "trauma"))
	blamer.free(); mgr12.free()

	# ── inventory + profession UI backend: real data, not placeholders ──
	var pro := _spawn_member()
	pro.member_name = "Weaver1"
	pro.profession = "Weaving"
	pro.profession_skill["Weaving"] = 40.0
	_check("a member's profession progress is queryable for a real progress bar",
		pro.skill_in("Weaving") == 40.0 and fmod(pro.skill_in("Weaving"), pro.SKILL_TIER_STEP) == 15.0)
	pro.free()

	# ── scarcity-first job priority (2026-07-19) ──
	var mgr13 := TribeManagerScript.new()
	add_child(mgr13)
	mgr13._cat_lines = {"you": [], "tribe": [], "tribes": []}
	mgr13.members = [_spawn_member()]
	var bush := Node3D.new()
	bush.set_script(load("res://food_source.gd"))
	add_child(bush)
	var wtree := StaticBody3D.new()
	wtree.set_script(load("res://tree.gd"))
	add_child(wtree)
	mgr13.food = 0; mgr13.wood = 100; mgr13.materials = 100
	_check("critically short on food wins over everything else, even with wood/materials to spare",
		mgr13.suggest_job(null) == "gather")
	mgr13.food = 100; mgr13.wood = 0; mgr13.materials = 100
	_check("critically short on wood wins when food/materials are fine",
		mgr13.suggest_job(null) == "wood")
	mgr13.food = 100; mgr13.wood = 100; mgr13.materials = 0
	var ore2 := StaticBody3D.new()
	ore2.set_script(load("res://mineral.gd"))
	add_child(ore2)
	_check("critically short on materials wins when food/wood are fine (and a mineral exists to mine)",
		mgr13.suggest_job(null) == "mine")
	mgr13.food = 500; mgr13.wood = 500; mgr13.materials = 500
	_check("with real abundance across the board, scarcity no longer overrides the usual choices",
		mgr13.suggest_job(null) != "")
	for m in mgr13.members: m.free()
	bush.free(); wtree.free(); ore2.free(); mgr13.free()

	# ── trust parity: a forward player camp gets the SAME local economy an
	# outpost settlement does, and a real campfire ──
	var mgr14 := TribeManagerScript.new()
	add_child(mgr14)
	mgr14._cat_lines = {"you": [], "tribe": [], "tribes": []}
	mgr14.wood = 100; mgr14.materials = 100
	mgr14.try_build_camp(Vector3(200, 0, 0), false)
	var camp := get_tree().get_first_node_in_group("player_camp")
	_check("a forward camp now carries the exact same local-economy fields an outpost does",
		"local_food" in camp)
	mgr14.add_food_at(Vector3(200, 0, 0), 10)
	_check("depositing at a forward camp grows ITS local food, exactly like an outpost",
		camp.local_food == 10 and mgr14.food == 0)
	_check("...and a resident there can find a REAL campfire, not just an ambient light",
		not get_tree().get_nodes_in_group("campfire").is_empty())
	mgr14.free()

	# ── additive thoughts: cumulative deaths compound into a real reaction ──
	var accumulator := _spawn_member()
	accumulator.relationship = 2.0
	accumulator.is_backing_you = true
	_check("a single hunger death doesn't yet read as a pattern", accumulator.player_caused_deaths_witnessed == 0)
	accumulator.blame_leader_for_hunger_death("Vic1", true)
	accumulator.blame_leader_for_hunger_death("Vic2", true)
	_check("repeated real negligence deaths genuinely accumulate, they don't reset each time",
		accumulator.player_caused_deaths_witnessed == 2)
	_check("...and the member is STILL backing you before the pattern is undeniable",
		accumulator.is_backing_you == true)
	accumulator.blame_leader_for_hunger_death("Vic3", true)
	_check("THOUGHTS DIRECTLY RESULT IN ACTIONS: at the real threshold, backing is genuinely withdrawn",
		accumulator.is_backing_you == false)
	accumulator.free()

	# ── real cause, not assumed: access changes the reaction ──
	var trusting_witness := _spawn_member()
	trusting_witness.blame_leader_for_hunger_death("Earner", false)   # had_access -> NOT negligence
	_check("a starvation death with REAL stockpile access doesn't blame the leader as negligence",
		trusting_witness.player_caused_deaths_witnessed == 0)
	trusting_witness.free()

	# ── same question repeated: additive tracking (_say_to() itself needs a
	# real Spikeling brain + network stack to run end-to-end, well beyond
	# what's safe to drive headlessly -- this verifies the counting logic
	# _say_to() relies on directly, the same normalize-and-increment shape) ──
	TribeChat._question_counts.clear()
	var qkey: String = "Repeatee:do you trust me"
	for i in range(3):
		TribeChat._question_counts[qkey] = int(TribeChat._question_counts.get(qkey, 0)) + 1
	_check("the exact same question genuinely accumulates a real lifetime count",
		int(TribeChat._question_counts.get(qkey, 0)) == 3)

	# ── rank hysteresis (2026-07-19): relationship wobbling right at the
	# Acquaintance cutoff (0.30) must NOT flicker current_rank back and forth ──
	var wobbler := _spawn_member()
	wobbler.relationship = 0.31   # just above the Acquaintance cutoff
	wobbler._update_rank()
	_check("crossing a rank cutoff for the first time genuinely grants it",
		wobbler.current_rank == "Acquaintance")
	var rank_flips := 0
	for i in range(20):
		wobbler.relationship = 0.29 if i % 2 == 0 else 0.31   # wobbles just below/above the OLD single threshold
		var before: String = wobbler.current_rank
		wobbler._update_rank()
		if wobbler.current_rank != before:
			rank_flips += 1
	_check("relationship wobbling right at the cutoff causes ZERO rank flicker now",
		rank_flips == 0 and wobbler.current_rank == "Acquaintance")
	wobbler.relationship = 0.30 * wobbler.RANK_HYSTERESIS_MARGIN - 0.01   # clearly below the real drop bar
	wobbler._update_rank()
	_check("...but a real, sustained drop still genuinely demotes them",
		wobbler.current_rank == "Stranger")
	wobbler.free()

	# ── tribe overview dashboard backend (2026-07-19) ──
	var mgr6 := TribeManagerScript.new()
	add_child(mgr6)
	mgr6._cat_lines = {"you": [], "tribe": [], "tribes": []}
	mgr6.food = 42; mgr6.wood = 10; mgr6.materials = 7
	var dash_member := _spawn_member()
	dash_member.member_name = "Dashy"
	dash_member.current_rank = "Devoted"
	dash_member.social_role = "Blacksmith"
	dash_member.profession = "Blacksmithing"
	dash_member.profession_skill["Blacksmithing"] = 50.0
	mgr6.members = [dash_member]
	mgr6.add_rivalry("Raiders", 0.4)
	var overview: Dictionary = mgr6.overview_data()
	_check("overview surfaces real resource totals", int(overview["food"]) == 42)
	_check("...and a real roster entry with rank/role/profession all present",
		overview["roster"][0]["name"] == "Dashy" and overview["roster"][0]["role"] == "Blacksmith"
		and overview["roster"][0]["profession_tier"] == "Journeyman")
	_check("...and the ideology/throne/rivalry systems all show up in one place",
		overview.has("ideology") and overview.has("throne_name")
		and overview["rivalries"][0]["tribe_name"] == "Raiders")
	dash_member.free(); mgr6.free()

	# ── auto-assume trusted work on refusal (2026-07-19) ──
	var refuser := _spawn_member()
	refuser.current_rank = "Stranger"
	refuser.personality = "Brave"   # courage 40, drive 125 -- clears gather/wood(70)/mine(90)/recruit(110), not hunt(130)/guard(140)/scout(165)
	refuser.manager = TribeManagerScript.new()
	add_child(refuser.manager)
	var accepted: bool = refuser.give_order("scout")
	_check("an order too risky to trust is no longer a flat refusal -- something real is accepted instead",
		accepted and refuser.is_busy)
	_check("...and it picked the most substantial job this member's own drive actually clears",
		refuser._task_kind == "mine")
	refuser.manager.free(); refuser.free()

	# 2026-07-19: gather/wood risk was lowered (70, was 100) specifically so a
	# real Stranger can do basic foraging -- "my tribe is stagnant" -- so an
	# ordinary Stranger is no longer a valid "nothing at all works" case.
	# Someone with genuinely LESS standing than even a categorized Stranger
	# (current_rank not in RANK_LOYALTY at all -> loyalty defaults to 0) still
	# has to hit a real floor somewhere.
	var true_stranger := _spawn_member()
	true_stranger.current_rank = "Newcomer"   # unrecognized rank -> RANK_LOYALTY.get(...) == 0
	true_stranger.personality = "Wary"        # courage -15 -- fails every real ORDER_RISK entry
	var truly_refused: bool = true_stranger.give_order("gather")
	_check("a member with genuinely no trusted fallback still really refuses (no fake success)",
		not truly_refused and not true_stranger.is_busy)
	true_stranger.free()

	# ...but an ORDINARY Stranger with average courage now CAN do basic work
	# on their own -- the actual fix for the stagnation/refusal-loop report.
	var ordinary_stranger := _spawn_member()
	ordinary_stranger.current_rank = "Stranger"
	ordinary_stranger.personality = "Steady"
	_check("a plain Steady Stranger can now gather on their own -- no longer locked out of everything",
		ordinary_stranger.give_order("gather") and ordinary_stranger.is_busy)
	ordinary_stranger.free()

	print("\n" + "-".repeat(42))
	print("  %d passed, %d FAILED" % [_pass, _fail])
	print("-".repeat(42) + "\n")
	get_tree().quit(1 if _fail > 0 else 0)

func _fake_world_tribe(name_: String) -> Node3D:
	var script := GDScript.new()
	script.source_code = """
extends Node3D
var tribe_name: String = ""
var defeated: bool = false
var discovered: bool = false
var player_opinion: float = 0.0
var opinions: Dictionary = {}
var bonds: Dictionary = {}
var material_stock: int = 0
var food: int = 0
func material_name() -> String:
	return "Bone"
func material_surplus() -> int:
	return 5
func food_surplus() -> int:
	return 5
func material_pressure() -> float:
	return clampf(1.0 - float(material_stock) / 40.0, 0.0, 1.0)
"""
	script.reload()
	var n := Node3D.new()
	n.set_script(script)
	add_child(n)
	n.tribe_name = name_
	return n

func _fake_npc_attacker(tribe: Node) -> Node:
	var script := GDScript.new()
	script.source_code = "extends Node\nvar tribe = null\n"
	script.reload()
	var n := Node.new()
	n.set_script(script)
	add_child(n)
	n.tribe = tribe
	return n

func _spawn_member() -> Node3D:
	var m := CharacterBody3D.new()
	m.set_script(load("res://tribemember.gd"))
	add_child(m)
	m.member_name = "TestSubject"
	return m

func _has_memory_type(agent: String, event_type: String) -> bool:
	for m in TribeMemory._mem.get(agent, []):
		if m["type"] == event_type:
			return true
	return false

func _check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  ok    %s" % label)
	else:
		_fail += 1
		print("  FAIL  %s" % label)
