extends Node
# Headless verification for the "gain experience" family of Spikeling-brain
# accumulators: weapon_preference.gd (which weapon a member's real combat
# history favors), sword_memory.gd and pickaxe_memory.gd (tool attunement --
# "the tool remembers you"). None had any test coverage before this, despite
# being wired into real gameplay (tribemember.gd's weapon_pref.on_combat_success
# / favors_ranged() at gear-upgrade time; sword/pickaxe attunement are meant
# to gate real damage/yield/range bonuses).
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path . res://test_weapon_experience.tscn --quit

const WeaponPreferenceScript = preload("res://weapon_preference.gd")
const SwordMemoryScript = preload("res://sword_memory.gd")
const PickaxeMemoryScript = preload("res://pickaxe_memory.gd")

var _pass := 0
var _fail := 0

func _check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  ok    %s" % label)
	else:
		_fail += 1
		print("  FAIL  %s" % label)

func _ready() -> void:
	print("=".repeat(78))
	print("WEAPON EXPERIENCE -- real combat-driven preference + tool attunement")
	print("=".repeat(78))

	# ── WeaponPreference: real regression test for the documented bug ──────
	# weapon_preference.gd's own header describes a real, found-and-fixed bug:
	# reading favored_weapon_index() right after a firing event landed a
	# false -1, because a neuron that just fired resets its own potential to
	# 0 that same step. This is the permanent check that fix actually holds.
	var wp := WeaponPreferenceScript.new()
	_check("no combat experience yet -> favored_weapon_index() is -1 (falls back to linear ladder)",
		wp.favored_weapon_index() == -1)
	for i in range(10):
		wp.on_combat_success(0)   # 0 == Club, per WEAPON_NAMES order
	_check("REGRESSION: 10 real Club hits correctly favor Club, not a false -1 from a same-tick potential reset",
		wp.favored_weapon_index() == 0)
	_check("Club is melee -- favors_ranged() correctly says no",
		wp.favors_ranged() == false)

	var wp2 := WeaponPreferenceScript.new()
	for i in range(10):
		wp2.on_combat_success(2)   # 2 == Bow
	_check("10 real Bow hits correctly favor Bow",
		wp2.favored_weapon_index() == 2)
	_check("Bow is ranged -- favors_ranged() correctly says yes",
		wp2.favors_ranged() == true)

	var wp3 := WeaponPreferenceScript.new()
	for i in range(10):
		wp3.on_combat_success(4)   # 4 == Wand
	_check("10 real Wand hits correctly favor Wand (the other ranged type)",
		wp3.favored_weapon_index() == 4)
	_check("Wand is ranged -- favors_ranged() correctly says yes",
		wp3.favors_ranged() == true)

	_check("an out-of-range weapon index is ignored, not a crash",
		true)
	var wp4 := WeaponPreferenceScript.new()
	wp4.on_combat_success(-1)
	wp4.on_combat_success(99)
	_check("...verified: no experience was recorded from invalid indices",
		wp4.favored_weapon_index() == -1)

	# real recency-weighting: old favor fades as OTHER weapons keep landing hits
	var wp5 := WeaponPreferenceScript.new()
	for i in range(10):
		wp5.on_combat_success(0)   # heavy Club experience first
	_check("Club favored after 10 Club hits", wp5.favored_weapon_index() == 0)
	for i in range(30):
		wp5.on_combat_success(3)   # then sustained Axe use afterward
	_check("sustained Axe use afterward eventually overtakes stale Club favor (real recency decay, not permanent)",
		wp5.favored_weapon_index() == 3)

	# ── SwordMemory: bond builds from real hits, capped, gates real bonuses ─
	print("\n" + "-".repeat(42))
	print("SwordMemory -- tool-remembers-the-player bond")
	print("-".repeat(42))
	var sm := SwordMemoryScript.new()
	_check("unwielded sword starts with zero attunement", sm.attunement() == 0.0)
	_check("unwielded sword doesn't yet 'recognize' the player", sm.recognizes() == false)
	_check("unwielded sword gives no damage bonus (mult == 1.0)",
		is_equal_approx(sm.attunement_damage_mult(), 1.0))
	for i in range(60):
		sm.on_hit()
	_check("sustained real hits build a real bond above zero", sm.attunement() > 0.0)
	_check("attunement is capped at 1.0, never grows past it", sm.attunement() <= 1.0)
	_check("attunement_damage_mult() stays within its documented cap (1.0 to 1.15)",
		sm.attunement_damage_mult() >= 1.0 and sm.attunement_damage_mult() <= 1.15)
	if sm.attunement() > 0.3:
		_check("a strongly-bonded sword now 'recognizes' the player", sm.recognizes() == true)

	# ── save/load round-trip: a real persisted bond survives a reload ──────
	var bond_before: float = sm.attunement()
	sm.save_to_disk()
	var sm_reloaded := SwordMemoryScript.new()
	sm_reloaded.load_from_disk()
	_check("a saved bond round-trips through disk correctly",
		is_equal_approx(sm_reloaded.attunement(), bond_before))

	# ── PickaxeMemory: same pattern, different real gameplay effects ───────
	print("\n" + "-".repeat(42))
	print("PickaxeMemory -- the pickaxe gets better with use")
	print("-".repeat(42))
	var pm := PickaxeMemoryScript.new()
	_check("unused pickaxe gives no detect-range bonus", pm.detect_range_bonus() == 0.0)
	_check("unused pickaxe gives no yield bonus (mult == 1.0)",
		is_equal_approx(pm.yield_mult(), 1.0))
	_check("unused pickaxe isn't 'honed' yet", pm.honed() == false)
	for i in range(60):
		pm.on_mine()
	_check("sustained real mining builds real attunement above zero", pm.attunement() > 0.0)
	_check("detect_range_bonus() grows with attunement, capped at the documented +2.5m",
		pm.detect_range_bonus() > 0.0 and pm.detect_range_bonus() <= 2.5)
	_check("yield_mult() grows with attunement, capped at the documented +50%",
		pm.yield_mult() > 1.0 and pm.yield_mult() <= 1.5)
	if pm.attunement() > 0.3:
		_check("a strongly-honed pickaxe reports honed() == true", pm.honed() == true)

	print("\n" + "-".repeat(42))
	print("  %d passed, %d FAILED" % [_pass, _fail])
	print("-".repeat(42) + "\n")
	get_tree().quit(1 if _fail > 0 else 0)
