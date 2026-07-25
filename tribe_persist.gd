extends Node
# ─────────────────────────────────────────────────────────────────────────────
# TribePersist — save the world, and let it LIVE while you're gone.
# Autoload singleton: TribePersist
#
# A Godot game cannot run while it's closed -- there is no server. So "leave for a
# week and it's still running" is delivered in two halves:
#   1. SAVE the whole world on quit (and periodically, so a crash costs minutes).
#   2. On return, CATCH UP: fast-forward the world by however much real time
#      passed. Tribes traded, grew, formed and lost alliances, weathered lean
#      seasons -- so you walk back into a world that lived without you, not a
#      freeze-frame. That's the honest version of "still running".
#
# The manager owns capture_state()/apply_state() (it knows its own fields). This
# node owns the file, the timing, and the catch-up simulation -- which runs on
# the SAVED numbers, not the live scene, so it's cheap no matter how long you were
# away (a year away is the same handful of coarse steps as a day).
#
# SAVE LOCATION: user://tribe_save.json -- same user:// dir as the vault, so the
# whole game state lives in one place and moves with the profile.
# ─────────────────────────────────────────────────────────────────────────────

const SAVE_PATH := "user://tribe_save.json"
const AUTOSAVE_INTERVAL := 45.0
const SECONDS_PER_DAY := 180.0   # 3 real minutes of ABSENCE = one simulated day
const MAX_CATCHUP_DAYS := 40     # a year away still resolves in <1s and doesn't
	# fast-forward the world into an unrecognisable state -- there's a limit to
	# how much should change behind your back.

var _accum := 0.0
var last_summary: String = ""    # shown by the manager after a catch-up load

func _ready() -> void:
	set_process(true)

func _process(delta: float) -> void:
	_accum += delta
	if _accum >= AUTOSAVE_INTERVAL:
		_accum = 0.0
		save()

# Save on window close -- the autosave timer alone would lose up to 45s. Only the
# CLOSE_REQUEST: PREDELETE fires during teardown when the tree is already gone,
# and touching get_tree() there crashes.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		save()

func _manager() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	return tree.get_first_node_in_group("tribe_manager")

func has_save() -> bool:
	return FileAccess.file_exists(SAVE_PATH)

func save() -> void:
	var mgr := _manager()
	if mgr == null or not mgr.has_method("capture_state"):
		return
	if not mgr.get("_started"):
		return                       # nothing meaningful to save on the menu
	var data: Dictionary = mgr.capture_state()
	data["saved_at"] = Time.get_unix_time_from_system()
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		push_warning("[PERSIST] could not open save file for writing")
		return
	f.store_string(JSON.stringify(data))
	f.close()

## Call AFTER the world has spawned. Restores saved state onto it and runs the
## offline catch-up. Returns a human summary, or "" if there was no save.
func load_and_catch_up() -> String:
	if not has_save():
		return ""
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return ""
	var raw := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(raw)
	if not (parsed is Dictionary):
		push_warning("[PERSIST] save file corrupt -- ignoring")
		return ""
	var data: Dictionary = parsed

	var mgr := _manager()
	if mgr == null or not mgr.has_method("apply_state"):
		return ""

	# elapsed REAL time since the save -> simulated days
	var now := Time.get_unix_time_from_system()
	var elapsed: float = maxf(0.0, now - float(data.get("saved_at", now)))
	var days: int = clampi(int(elapsed / SECONDS_PER_DAY), 0, MAX_CATCHUP_DAYS)

	# fast-forward the SAVED numbers before applying them to the live world
	var summary := _simulate_days(data, days)
	mgr.apply_state(data)
	last_summary = summary
	return summary

# ─────────────────────────────────────────────────────────────────────────────
# OFFLINE CATCH-UP — run the diplomacy/economy loop on the saved snapshot, in
# coarse day-steps. This is a DELIBERATELY SIMPLIFIED echo of the live systems
# (trade cools grudges + builds bonds, growth toward cap, seasons, rare war), not
# a re-run of the real per-frame code -- it only has to feel like the same world
# advanced, and it has to be fast and bounded.
# ─────────────────────────────────────────────────────────────────────────────
func _simulate_days(data: Dictionary, days: int) -> String:
	var tribes: Array = data.get("tribes", [])
	if days <= 0 or tribes.is_empty():
		return ""

	var alive: Array = []
	for t in tribes:
		if not bool(t.get("defeated", false)):
			alive.append(t)

	var new_alliances: Array = []
	var lean_days := 0
	var bountiful_days := 0
	var trades := 0

	for _day in range(days):
		# season
		var r := randf()
		var season_mult := 1.0
		if r < 0.22:
			season_mult = 0.85           # lean: stores drain
			lean_days += 1
		elif r < 0.45:
			season_mult = 1.12           # bountiful
			bountiful_days += 1

		for a in alive:
			# economy: food drifts with the season and the tribe's size
			var upkeep: int = int(a["members"]) + 2
			a["food"] = maxi(0, int(round((float(a["food"]) + upkeep) * season_mult)) - upkeep)
			# growth toward a soft cap of 16, only when fed
			if int(a["food"]) > upkeep * 2 and int(a["members"]) < 16 and randf() < 0.25:
				a["members"] = int(a["members"]) + 1
			# fade grudges and (much slower) bonds toward neutral
			for k in (a["opinions"] as Dictionary).keys():
				a["opinions"][k] = maxf(0.0, float(a["opinions"][k]) - 0.05)
			for k in (a["bonds"] as Dictionary).keys():
				a["bonds"][k] = maxf(0.0, float(a["bonds"][k]) - 0.008)

		# trade: pair nearby tribes, one short of food with one in surplus
		for a in alive:
			if int(a["food"]) >= int(a["members"]) + 2:
				continue                 # not hungry -> not shopping
			for b in alive:
				if b == a or int(b["food"]) <= int(b["members"]) * 3:
					continue
				var dx: float = float(a["x"]) - float(b["x"])
				var dz: float = float(a["z"]) - float(b["z"])
				if dx * dx + dz * dz > 130.0 * 130.0:
					continue             # too far to carry goods (matches TRADE_RANGE)
				var grudge: float = float((a["opinions"] as Dictionary).get(b["name"], 0.0))
				if grudge > 0.7:
					continue
				# do the deal
				var moved: int = mini(6, int(b["food"]) - int(b["members"]) * 3)
				a["food"] = int(a["food"]) + moved
				b["food"] = int(b["food"]) - moved
				trades += 1
				var was := _bonded(a, b)
				_warm(a, b, 0.12)
				_warm(b, a, 0.12)
				if not was and _bonded(a, b):
					new_alliances.append([str(a["name"]), str(b["name"])])
				break

	return _summarise(days, new_alliances, trades, lean_days, bountiful_days, alive)

func _bonded(a: Dictionary, b: Dictionary) -> bool:
	return float((a["bonds"] as Dictionary).get(b["name"], 0.0)) >= 0.5

func _warm(a: Dictionary, b: Dictionary, amt: float) -> void:
	var bonds: Dictionary = a["bonds"]
	bonds[b["name"]] = minf(1.0, float(bonds.get(b["name"], 0.0)) + amt)
	var ops: Dictionary = a["opinions"]
	if ops.has(b["name"]):
		ops[b["name"]] = maxf(0.0, float(ops[b["name"]]) - amt * 0.5)

func _summarise(days: int, allies: Array, trades: int, lean: int, bounty: int, alive: Array) -> String:
	var lines: Array[String] = ["— Welcome back. %d day%s passed while you were away. —" % [
		days, "" if days == 1 else "s"]]
	if trades > 0:
		lines.append("• %d trade%s moved between the camps." % [trades, "" if trades == 1 else "s"])
	for pair in allies.slice(0, 3):
		lines.append("• The %s and the %s became allies." % [pair[0], pair[1]])
	if lean > bounty and lean > 0:
		lines.append("• Lean seasons dominated — stores ran thin.")
	elif bounty > 0:
		lines.append("• Good seasons kept the camps fed.")
	# note the biggest tribe, a bit of colour
	var top = null
	for a in alive:
		if top == null or int(a["members"]) > int(top["members"]):
			top = a
	if top != null:
		lines.append("• The %s are the largest tribe now, %d strong." % [top["name"], int(top["members"])])
	return "\n".join(lines)
