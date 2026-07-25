class_name MatCache
extends RefCounted
# ─────────────────────────────────────────────────────────────────────────────
# Shared StandardMaterial3D cache.
#
# The world spawns thousands of trees/animals/npcs/props, and each one used to
# call StandardMaterial3D.new() for its static colors (trunk brown, leaf green,
# species fur, googly-eye white/black, etc.). At Epic scale that produced ~7,600
# UNIQUE materials — thousands of un-batched draw calls plus shader-pipeline
# compile stalls (the "lag" AND the "colors not loading / pop-in": a mesh renders
# with the default material until its unique one finishes compiling).
#
# flat() returns ONE shared material per (quantized colour, roughness, metallic)
# key, collapsing those thousands down to a few dozen. Identical-looking meshes
# now share a resource and batch.
#
# CRITICAL: only route STATIC-coloured materials through here. A material fetched
# from the cache is SHARED — mutating it (albedo_color/emission/alpha changes at
# runtime: hurt flash, tint, selection, grazed-berry fade, faction tint) would
# change every mesh that shares it. Those sites keep their own .new() instance.
# ─────────────────────────────────────────────────────────────────────────────

static var _cache: Dictionary = {}

# Quantisation buckets: near-identical colours collapse to one material. 32 steps
# per channel is far finer than the eye needs here but still merges the randf()
# leaf-green spread and other tiny per-instance jitter.
const _COL_STEPS := 32.0
const _RM_STEPS := 20.0

static func flat(color: Color, roughness: float = 1.0, metallic: float = 0.0) -> StandardMaterial3D:
	var qr := int(round(color.r * _COL_STEPS))
	var qg := int(round(color.g * _COL_STEPS))
	var qb := int(round(color.b * _COL_STEPS))
	var qa := int(round(color.a * _COL_STEPS))
	var qrough := int(round(roughness * _RM_STEPS))
	var qmet := int(round(metallic * _RM_STEPS))
	var key := "%d_%d_%d_%d_%d_%d" % [qr, qg, qb, qa, qrough, qmet]
	var existing = _cache.get(key)
	if existing != null:
		return existing as StandardMaterial3D
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	m.metallic = metallic
	if color.a < 0.999:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_cache[key] = m
	return m

# Diagnostics only: how many distinct materials the cache is holding.
static func count() -> int:
	return _cache.size()
