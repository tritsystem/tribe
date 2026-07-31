extends Node3D
# ─────────────────────────────────────────────────────────────────────────────
# TerrainGen — turns the flat floor into hills, valleys, and mountains.
# In group "terrain". Built by the manager during world spawn.
#
# WHY THIS IS SAFE TO ADD: members and rival NPCs already move with gravity and
# is_on_floor() (checked in tribemember.gd / npc.gd) -- they were never assuming
# a flat plane, they just happened to be standing on one. Give the floor real
# height with matching collision and they walk up and down it for free. The only
# thing that DID assume flat ground was SPAWNING (everything dropped in at y=1),
# so the fix is one function: height_at(x,z), which spawn code samples to place
# camps, resources, and members ON the surface instead of at a fixed height.
#
# HEIGHTMAP + COLLISION FROM ONE SOURCE: a single noise field feeds both the
# visual mesh and a HeightMapShape3D collider, so what you see is exactly what you
# collide with -- no drift between the two.
#
# BIOMES BY ELEVATION: height_at also underpins biome_at(), which later gates
# which resources spawn where (valleys→berries/water plants, plains→game,
# highlands→stone/ore). Terrain first so biomes have something to sit on.
# ─────────────────────────────────────────────────────────────────────────────

# heightmap grid resolution — ADAPTIVE. A fixed 128 gave 22m cells on a huge
# (1400) map, which reads as blocky low-poly ground. Scaling the sample count
# with the map keeps the cell size roughly constant (~5-11m) from a small map to
# a WoW-sized one, at the cost of a bigger one-time generate (RES^2). Capped so a
# massive map doesn't build a multi-million-triangle mesh.
var RES: int = 128
var extent: float = 180.0        # world half-size; terrain spans [-extent, extent]
var max_height: float = 70.0     # tallest mountain above the base plane

# ── ISLANDS ──────────────────────────────────────────────────────────────────
# When island_mode is on, a low-frequency "continentalness" field decides land vs
# ocean: high -> a landmass rising above water_level, low -> seafloor sunk beneath
# it. That naturally scatters SEPARATE islands with sea between them. The origin
# is forced to be a home island so the player never starts in the water. Kept a
# MODE (default off) so the continuous-land game is untouched until spawn-on-land
# is wired in Tribemanager -- turning the ground into ocean without that would
# drop tribes and trees into the sea.
var island_mode: bool = false
# TURTLE ISLANDS (2026-07-25): when every landmass is a turtle's own moving
# body (see world_tribe.gd/player_island.gd's _build_turtle_body()), the
# terrain itself must be PURE ocean -- no continentalness-noise landmasses,
# no forced "home island" at the origin. Both of those used to coexist with
# the turtle bodies, which is exactly why the player's own island looked
# broken: player_island.gd's shell floated at water_level while the terrain
# ALSO threw a real, static hill up under it at the same spot. Set by
# Tribemanager._build_terrain() only when turtle_islands is on; the old
# archipelago behavior (large SCALE_PRESETS without turtles) is untouched.
var all_ocean: bool = false
var water_level: float = 10.0    # sea surface; terrain below it is underwater
var seafloor: float = -9.0       # how deep the ocean floor sits below water_level
const SEA_THRESHOLD := 0.46      # continentalness above this = land
var _continent: FastNoiseLite = null
var _water_plane: MeshInstance3D = null

var _heights: PackedFloat32Array = PackedFloat32Array()
var _peak: float = 1.0           # actual tallest sample -> biome bands scale to it
var _cell: float = 1.0           # world units between samples
var _noise: FastNoiseLite
var _mesh_inst: MeshInstance3D
var _body: StaticBody3D

## Build terrain sized to `world_extent` (the manager's map half-size). `seed`
## keeps a world reproducible across saves -- the same seed regenerates the same
## mountains, so persistence doesn't have to store the whole heightmap.
func generate(world_extent: float, seed_val: int) -> void:
	extent = maxf(60.0, world_extent)
	# Scale sample count with the map so cells stay ~6-9m from a small map to a
	# huge one, instead of a fixed 128 giving 22m blocks at 1400. Capped at 320
	# (RES^2 samples => ~200k-quad mesh) so a massive map doesn't melt generate().
	RES = clampi(int(extent / 4.5), 128, 320)
	_cell = (extent * 2.0) / float(RES - 1)
	add_to_group("terrain")

	_noise = FastNoiseLite.new()
	_noise.noise_type = FastNoiseLite.TYPE_PERLIN
	_noise.seed = seed_val
	_noise.frequency = 0.0035
	_noise.fractal_octaves = 5
	_noise.fractal_lacunarity = 2.1

	# a second, lower-frequency field carves broad basins (valleys) and raises
	# whole ranges (mountains) so the land reads as regions, not uniform bumps
	var macro := FastNoiseLite.new()
	macro.noise_type = FastNoiseLite.TYPE_PERLIN
	macro.seed = seed_val + 7
	macro.frequency = 0.0011

	# continentalness: low-frequency field that decides island vs ocean. Its
	# frequency sets island SIZE -- lower = fewer, bigger landmasses.
	if island_mode:
		_continent = FastNoiseLite.new()
		_continent.noise_type = FastNoiseLite.TYPE_PERLIN
		_continent.seed = seed_val + 23
		_continent.frequency = 1.6 / extent    # ~a handful of islands across the map

	_heights.resize(RES * RES)
	for j in range(RES):
		for i in range(RES):
			var wx := -extent + float(i) * _cell
			var wz := -extent + float(j) * _cell
			var n := (_noise.get_noise_2d(wx, wz) + 1.0) * 0.5          # 0..1 detail
			var m := (macro.get_noise_2d(wx, wz) + 1.0) * 0.5           # 0..1 region
			# The MACRO field decides the region's character and the detail field
			# textures it. Pushing macro through a steep curve (smoothstep-cubed)
			# splits the world into real lowland BASINS (valleys/canyons near 0)
			# and real RANGES (mountains near 1), instead of everything hovering
			# at mid-elevation as it did at pow(1.8). The detail then rides on top.
			# steepen the macro field into basins and ranges. pow(1.2) keeps more
			# high ground than pow(1.5) did (that buried the peaks), and the detail
			# field adds roughness so highlands read as rugged mountains, not smooth
			# domes.
			var region := m * m * (3.0 - 2.0 * m)            # smoothstep(m)
			region = pow(region, 1.2)
			var h := clampf(region + (n - 0.5) * 0.5 * region, 0.0, 1.0)
			# A flat home BASIN, but a SMALL one -- full-flat only to ~0.10*extent
			# (~17m), rising to full terrain by ~0.28*extent (~50m). Mountains now
			# begin close enough to see from camp and rise to 70, so you're in a
			# valley ringed by real peaks rather than an endless plain.
			var dist := sqrt(wx * wx + wz * wz)
			var flat_inner := extent * 0.10
			var flat_outer := extent * 0.28
			var center_flat := clampf((dist - flat_inner) / (flat_outer - flat_inner), 0.0, 1.0)
			center_flat = center_flat * center_flat * (3.0 - 2.0 * center_flat)

			var hv: float
			if all_ocean:
				# turtle-island mode: no static land ANYWHERE, not even the old
				# forced home island -- every landmass in this mode is a turtle's
				# own moving body (see the class comment above), not terrain.
				hv = seafloor
			elif island_mode:
				# continentalness 0..1; force a home island around origin so the
				# player never starts at sea
				var c := (_continent.get_noise_2d(wx, wz) + 1.0) * 0.5
				var home := clampf(1.0 - dist / (extent * 0.20), 0.0, 1.0)
				c = maxf(c, home)                     # origin is always solid land
				# land_mask: 0 out at sea, 1 well inland, soft shoreline between
				var land := smoothstep(SEA_THRESHOLD - 0.06, SEA_THRESHOLD + 0.10, c)
				# on land the terrain sits ABOVE the water; the home island's
				# centre stays flat for the camp (center_flat), the rest gets the
				# full mountainous shape. Ocean is the sunk seafloor.
				var land_h := water_level + h * max_height * maxf(center_flat, 0.25)
				hv = lerpf(seafloor, land_h, land)
			else:
				hv = h * max_height * center_flat
			_heights[j * RES + i] = hv
			_peak = maxf(_peak, hv)

	if island_mode:
		_build_water_plane()
	_build_mesh()
	_build_collision()

## Ground height at any world x,z (bilinear between samples). THE api spawn code
## uses to sit things on the surface. Clamps at the edge rather than reading OOB.
func height_at(x: float, z: float) -> float:
	if _heights.is_empty():
		return 0.0
	var fi := clampf((x + extent) / _cell, 0.0, RES - 1.001)
	var fj := clampf((z + extent) / _cell, 0.0, RES - 1.001)
	var i := int(fi)
	var j := int(fj)
	var tx := fi - i
	var tz := fj - j
	var h00 := _heights[j * RES + i]
	var h10 := _heights[j * RES + i + 1]
	var h01 := _heights[(j + 1) * RES + i]
	var h11 := _heights[(j + 1) * RES + i + 1]
	return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)

## Is this spot dry land (above the waterline)? The gate spawn code will use to
## keep tribes, resources, and camps out of the ocean in island mode. Always true
## when island_mode is off (no water exists). The small margin keeps things off
## the exact waterline.
func is_land(x: float, z: float) -> bool:
	if all_ocean:
		return false   # the only "land" in this mode is a turtle's own body, not terrain
	if not island_mode:
		return true
	return height_at(x, z) > water_level + 0.5

func is_water(x: float, z: float) -> bool:
	return not is_land(x, z)

## Nearest dry-land spot to (x,z), spiralling outward up to max_r. Returns the
## input if it's already land, or Vector3.INF if none found in range -- spawn code
## uses this to nudge an ocean spawn onto the closest shore.
func nearest_land(x: float, z: float, max_r: float = 120.0) -> Vector3:
	if is_land(x, z):
		return Vector3(x, height_at(x, z), z)
	var step := maxf(_cell, 6.0)
	var r := step
	while r <= max_r:
		for a in range(0, 360, 30):
			var px := x + cos(deg_to_rad(a)) * r
			var pz := z + sin(deg_to_rad(a)) * r
			if is_land(px, pz):
				return Vector3(px, height_at(px, pz), pz)
		r += step
	return Vector3.INF

## Elevation band -> biome name. The hook biome-specific resource spawning will
## use; kept here because it's derived from the same heightmap.
func biome_at(x: float, z: float) -> String:
	# Bands are keyed to ABSOLUTE height, not a fraction of max_height. The noise
	# rarely reaches max_height (peaks land ~20 of a possible 42), so fraction-of-
	# max bands never assigned "mountain". Tuning to the real distribution is what
	# makes all four biomes actually occur; verified against the height histogram.
	# Bands as a fraction of THIS terrain's actual peak (computed once), so the
	# split holds regardless of how the noise tuning shifts the height range --
	# no more re-hardcoding thresholds every time the generator changes.
	if island_mode and height_at(x, z) <= water_level:
		return "ocean"         # underwater -- nothing spawns here
	var f := height_at(x, z) / maxf(1.0, _peak)
	if f < 0.12:
		return "valley"        # low, wet -> berries, reeds, water plants
	elif f < 0.40:
		return "plains"        # gentle -> grass, game animals
	elif f < 0.70:
		return "highland"      # hills -> hardwood, stone
	return "mountain"          # peaks -> ore, gems

# ─────────────────────────────────────────────────────────────────────────────
# TERRAFORMING — reshape the ground at runtime. Both the player and NPC builders
# use this: builders FLATTEN a footprint before building (so blocks sit flat
# instead of floating on a slope, and nobody gets wedged on an incline), and the
# player can raise/lower the land directly.
#
# Rebuilds are THROTTLED: editing marks the terrain dirty and _process rebuilds
# the mesh at most a few times a second, so dragging the land doesn't rebuild a
# 16k-quad mesh every frame. Collision (HeightMapShape3D) is cheap to refresh, so
# it updates immediately -- you never fall through freshly-raised ground.
# ─────────────────────────────────────────────────────────────────────────────
var _dirty := false
var _rebuild_cd := 0.0

func _process(delta: float) -> void:
	if not _dirty:
		return
	_rebuild_cd -= delta
	if _rebuild_cd <= 0.0:
		# BUG FIXED (2026-07-19): "terraform makes my player morph through
		# hills and see through the map" -- collision updates EVERY edit call
		# (up to 60/sec while the key is held), but the mesh only rebuilt
		# every 0.15s (~6.7/sec). While actively terraforming, the ground
		# you're physically standing/walking on (collision) was rising or
		# falling smoothly in real time while the RENDERED hill visually sat
		# frozen at its last 0.15s-old height -- exactly the "camera clips
		# through/floats above the visible terrain" glitch reported. Full
		# lockstep (rebuild every frame) is the 16k-quad-per-frame cost this
		# throttle was written to avoid; closing the gap to 1/20s instead of
		# 1/6.7s keeps that cost bounded while shrinking the visible desync
		# window to something no longer perceptible as morphing.
		_rebuild_cd = 0.05
		_dirty = false
		_refresh_mesh()

## Flatten a disc toward `target` height (world units). `strength` 0..1 = how far
## toward target each sample moves (1 = perfectly flat). Used by builders to
## prepare a footprint. Returns the height they should build at.
func flatten_area(cx: float, cz: float, radius: float, target: float, strength: float = 1.0) -> float:
	_edit_disc(cx, cz, radius, func(h, t): return lerpf(h, target, strength * t))
	return target

## Raise (positive) or lower (negative) a disc, feathered at the edge.
func raise_area(cx: float, cz: float, radius: float, amount: float) -> void:
	_edit_disc(cx, cz, radius, func(h, t): return clampf(h + amount * t, 0.0, max_height * 1.2))

## Apply `fn(height, falloff)->height` to every sample in the disc. falloff is
## 1 at the centre easing to 0 at the rim, so edits blend into the surroundings
## instead of leaving a cylinder punched in the ground.
func _edit_disc(cx: float, cz: float, radius: float, fn: Callable) -> void:
	if _heights.is_empty() or radius <= 0.0:
		return
	var i0 := maxi(0, int((cx - radius + extent) / _cell))
	var i1 := mini(RES - 1, int((cx + radius + extent) / _cell) + 1)
	var j0 := maxi(0, int((cz - radius + extent) / _cell))
	var j1 := mini(RES - 1, int((cz + radius + extent) / _cell) + 1)
	var changed := false
	for j in range(j0, j1 + 1):
		for i in range(i0, i1 + 1):
			var wx := -extent + float(i) * _cell
			var wz := -extent + float(j) * _cell
			var d := sqrt((wx - cx) * (wx - cx) + (wz - cz) * (wz - cz))
			if d > radius:
				continue
			var t := 1.0 - (d / radius)          # 1 centre -> 0 rim
			t = t * t * (3.0 - 2.0 * t)           # smoothstep for a soft lip
			var idx := j * RES + i
			var nh: float = fn.call(_heights[idx], t)
			if nh != _heights[idx]:
				_heights[idx] = nh
				_peak = maxf(_peak, nh)
				changed = true
	if changed:
		# collision now, mesh soon -- see the throttle note
		if _body:
			(_body.get_child(0) as CollisionShape3D).shape.map_data = _heights
		_dirty = true

func _refresh_mesh() -> void:
	if _mesh_inst:
		_mesh_inst.queue_free()
	_build_mesh()

func _build_mesh() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for j in range(RES - 1):
		for i in range(RES - 1):
			var x0 := -extent + float(i) * _cell
			var z0 := -extent + float(j) * _cell
			var x1 := x0 + _cell
			var z1 := z0 + _cell
			var v00 := Vector3(x0, _heights[j * RES + i], z0)
			var v10 := Vector3(x1, _heights[j * RES + i + 1], z0)
			var v01 := Vector3(x0, _heights[(j + 1) * RES + i], z1)
			var v11 := Vector3(x1, _heights[(j + 1) * RES + i + 1], z1)
			for v in [v00, v10, v11, v00, v11, v01]:
				st.set_color(_tint(v.y))
				st.add_vertex(v)
	st.generate_normals()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 1.0
	st.set_material(mat)
	_mesh_inst = MeshInstance3D.new()
	_mesh_inst.mesh = st.commit()
	add_child(_mesh_inst)

## Elevation-tinted so biomes read at a glance: green lowland -> tan hill ->
## grey rock -> white peak. Cheap band colouring, not a texture pipeline.
func _tint(y: float) -> Color:
	var f := clampf(y / max_height, 0.0, 1.0)
	if f < 0.10:
		return Color(0.34, 0.55, 0.30)       # valley green
	elif f < 0.42:
		return Color(0.45, 0.60, 0.32)        # plains
	elif f < 0.72:
		return Color(0.52, 0.47, 0.34).lerp(Color(0.5, 0.5, 0.5), (f - 0.42) / 0.30)
	return Color(0.55, 0.55, 0.57).lerp(Color(0.95, 0.95, 0.97), (f - 0.72) / 0.28)

## A single semi-transparent plane at sea level covering the whole map -- the
## visible ocean. Cheap (one quad); the "islands" read as land poking through it.
func _build_water_plane() -> void:
	if _water_plane and is_instance_valid(_water_plane):
		_water_plane.queue_free()
	var mesh := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(extent * 2.2, extent * 2.2)
	mesh.mesh = pm
	mesh.position.y = water_level
	var mat := StandardMaterial3D.new()
	# OPAQUE, not alpha-blended. A transparent plane the size of the whole map
	# (extent*2.2) fills most of the screen when you look across the sea, and every
	# pixel behind it gets alpha-blended -- full-screen OVERDRAW, a classic GPU
	# sink that headless can't measure. Opaque water is a single cheap pass and
	# still reads as water; the tradeoff (can't see the seafloor through it) is
	# worth a playable framerate.
	mat.albedo_color = Color(0.14, 0.32, 0.50)
	mat.roughness = 0.2
	mat.metallic = 0.25
	# double-sided so it's still visible from under the surface (was the
	# "water disappears when I step in it" fix)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.material_override = mat
	add_child(mesh)
	_water_plane = mesh

func _build_collision() -> void:
	# HeightMapShape3D wants a square map of floats in ROW order, spanning a unit
	# grid centred on the node -- so we scale the body to _cell to map it onto the
	# world. Same _heights array as the mesh, so collision == what you see.
	var shape := HeightMapShape3D.new()
	shape.map_width = RES
	shape.map_depth = RES
	shape.map_data = _heights
	_body = StaticBody3D.new()
	var col := CollisionShape3D.new()
	col.shape = shape
	_body.add_child(col)
	# HeightMapShape3D is centred on origin in grid units; scale to world cells
	# and it lines up with the mesh built from the same samples.
	_body.scale = Vector3(_cell, 1.0, _cell)
	add_child(_body)
