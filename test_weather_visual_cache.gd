extends Node
# Headless test for the weather-visuals lookup caching fix. Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path . res://test_weather_visual_cache.tscn --quit
#
# BUG: _apply_weather_visuals() did TWO recursive find_children() searches
# over the entire scene tree (root.find_children("*", ..., true, false))
# every single time weather changed -- a real, measurable per-frame hitch
# on a populated world (tens of thousands of nodes), even though weather
# only changes every 60-180s and the WorldEnvironment/DirectionalLight3D
# it's looking for are scene-authored and never change at runtime. Fixed by
# searching once and caching the result.

const TribeManagerScript = preload("res://Tribemanager.gd")

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  WEATHER VISUALS -- cached lookup, not re-searched every change")
	print("=".repeat(60))

	var mgr := TribeManagerScript.new()
	add_child(mgr)
	mgr._cat_lines = {"you": [], "tribe": [], "tribes": []}

	var we := WorldEnvironment.new()
	we.environment = Environment.new()
	add_child(we)
	var sun := DirectionalLight3D.new()
	add_child(sun)

	_check("the search hasn't run yet before any weather change", not mgr._weather_visuals_searched)

	mgr.current_weather = mgr.Weather.STORM
	mgr._apply_weather_visuals()
	_check("the first call performs the search and caches a real WorldEnvironment",
		mgr._weather_visuals_searched and mgr._cached_world_env == we)
	_check("...and caches the real DirectionalLight3D too",
		mgr._cached_sun == sun)
	_check("the storm's fog settings actually reached the real Environment resource",
		we.environment.fog_enabled and absf(sun.light_energy - 0.45) < 0.01)

	# swap in a SECOND WorldEnvironment/sun -- if the lookup weren't cached,
	# the next weather change would find these instead. It must NOT: the
	# cached references from the first search are what should keep being used.
	var we2 := WorldEnvironment.new()
	we2.environment = Environment.new()
	add_child(we2)
	var sun2 := DirectionalLight3D.new()
	add_child(sun2)

	mgr.current_weather = mgr.Weather.CLEAR
	mgr._apply_weather_visuals()
	_check("a later weather change reuses the CACHED environment, not a fresh re-search",
		mgr._cached_world_env == we and mgr._cached_world_env != we2)
	_check("...and the change still actually applies (clear weather turns fog off)",
		not we.environment.fog_enabled)

	mgr.free()

	print("\n" + "-".repeat(42))
	print("  %d passed, %d FAILED" % [_pass, _fail])
	print("-".repeat(42) + "\n")
	get_tree().quit(1 if _fail > 0 else 0)

func _check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  ok    %s" % label)
	else:
		_fail += 1
		print("  FAIL  %s" % label)
