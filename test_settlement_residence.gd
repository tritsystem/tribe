extends Node
# Headless test for settlement residence (Phase 4 of "cities, communicate,
# and live amongst other tribes") -- a member who founds a new outpost
# settlement now actually LIVES there afterward, instead of the outpost
# being a bare prop with no population behaviorally tied to it. Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path . res://test_settlement_residence.tscn --quit

const SpatialGrid = preload("res://spatial_grid.gd")
const TribeManagerScript = preload("res://Tribemanager.gd")

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  SETTLEMENT RESIDENCE -- the founder actually lives there")
	print("=".repeat(60))
	TribeMemory._mem.clear()
	TribeMemory._pending.clear()

	var mgr := TribeManagerScript.new()
	add_child(mgr)
	mgr._cat_lines = {"you": [], "tribe": [], "tribes": []}

	var m := CharacterBody3D.new()
	m.set_script(load("res://tribemember.gd"))
	add_child(m)
	m.member_name = "Founder"
	m.manager = mgr
	m.home_pos = Vector3.ZERO
	m.global_position = Vector3(250, 0, 250)   # far out, as if a real search streak got them here
	SpatialGrid.update(m)

	# force the exact moment _begin_fallback() would found a settlement
	m._search_streak = m.EXPANSION_SEARCH_STREAK

	_check("home_pos starts at the original camp", m.home_pos == Vector3.ZERO)
	m._begin_fallback("looking around...")
	_check("founding a settlement re-plants home_pos at the NEW settlement, not the old camp",
		m.home_pos == m.global_position and m.home_pos != Vector3.ZERO)
	_check("the search streak resets once settled (a real success, not a failed search)",
		m._search_streak == 0)
	_check("a real memory of settling down is recorded",
		_has_memory_type("Founder", "founded_outpost"))

	# a SECOND far-off search (streak builds up again from scratch) must NOT
	# re-found another settlement right on top of this one -- OUTPOST_MIN_SPACING
	# still applies, and this member should just go back to searching normally
	# instead of silently stacking a duplicate settlement at the same spot.
	var home_before_second: Vector3 = m.home_pos
	for i in range(m.EXPANSION_SEARCH_STREAK):
		m._search_streak = m.EXPANSION_SEARCH_STREAK
		m._begin_fallback("still looking...")
	_check("a second attempt too close to the first settlement doesn't relocate home_pos again",
		m.home_pos == home_before_second)

	m.free()
	mgr.free()

	print("\n" + "-".repeat(42))
	print("  %d passed, %d FAILED" % [_pass, _fail])
	print("-".repeat(42) + "\n")
	get_tree().quit(1 if _fail > 0 else 0)

func _has_memory_type(agent: String, event_type: String) -> bool:
	for mem in TribeMemory._mem.get(agent, []):
		if mem["type"] == event_type:
			return true
	return false

func _check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  ok    %s" % label)
	else:
		_fail += 1
		print("  FAIL  %s" % label)
