class_name TribeRegistry
extends RefCounted
# ─────────────────────────────────────────────────────────────────────────────
# TribeRegistry — loads every res://tribes/*.tribe file once and caches the
# parsed result, keyed by archetype name. world_tribe.gd asks this for trait
# bias / material / speech instead of reading its own hardcoded dictionaries.
# Cache is a static var so it's shared across every WorldTribe instance —
# at 1000 tribes, parsing each archetype's file ONCE instead of per-tribe is
# the difference between a few file reads and a thousand.
# ─────────────────────────────────────────────────────────────────────────────

const TribeDSL = preload("res://tribe_dsl.gd")

static var _cache: Dictionary = {}
static var _loaded_all: bool = false

const DIR := "res://tribes/"

static func _load_all() -> void:
	if _loaded_all:
		return
	_loaded_all = true
	var dir := DirAccess.open(DIR)
	if dir == null:
		push_warning("TribeRegistry: no res://tribes/ folder found")
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.ends_with(".tribe"):
			var data := TribeDSL.load_file(DIR + fname)
			var arch: String = data.get("archetype", fname.get_basename().capitalize())
			_cache[arch] = data
		fname = dir.get_next()
	dir.list_dir_end()

static func get_archetype(name: String) -> Dictionary:
	_load_all()
	return _cache.get(name, {})

static func all_archetype_names() -> Array:
	_load_all()
	return _cache.keys()
