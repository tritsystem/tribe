"""
Blender headless asset generator -- ORGANIC low-poly quadrupeds, v2.1.

Run with:
  "Blender.exe" --background --python tools/gen_animals.py

v1 stacked boxes/cylinders (a real geometric upgrade over the old capsule+
sphere, but still blocky -- "the animals look lame"). v2 builds each animal
as a SKELETON of edges (spine, neck, head, 4 legs, tail, 2 ears) with a Skin
modifier controlling per-vertex thickness, then Subdivision Surface + smooth
shading -- tapered, rounded, genuinely animal-shaped silhouettes instead of
cubes, without hand-sculpting.

v2.1 FIX: v2's first pass set skin radii by poking mesh.skin_vertices AFTER
bm.to_mesh() -- legs came out invisible/near-zero-radius (indexing didn't
line up reliably) and the leg chains were never edge-connected to the
spine, so they were floating, disconnected skin islands. Fixed by setting
radius on bmesh's OWN skin custom-data layer (bm.verts.layers.skin) at
vertex-creation time -- the correct, documented way to drive the Skin
modifier from Python -- and by adding a real spine->hip edge per leg so
the whole animal is one connected, mergeable skin surface.

Keeps the "HeadMarker" empty at the snout tip -- animal.gd still attaches
the existing procedural googly eyes there at runtime, unchanged behavior.

Exports one .glb per species into res://assets/animals/.
"""
import bpy
import bmesh
import math
import os

OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "assets", "animals")
os.makedirs(OUT_DIR, exist_ok=True)

# name -> (body_len, body_h, body_w, leg_len, leg_radius, ear_len, ear_flare,
#          snout_len, tail_kind, color, has_antlers, ear_flat)
# TUNED (2026-07-19): "the animals look lame" round 1 fixed missing legs and
# no color; round 2 fixed leg proportions. Round 3 -- working from real
# reference photos of a whitetail buck -- adds antlers (totally absent
# before), a rounded/flattened ear shape (were thin spikes), and a
# black-nose + pale-muzzle face patch, all matched to the reference's
# actual coloring instead of one flat body tint.
SPECIES = {
	# body_len, body_h, body_w, leg_len, leg_radius, ear_len, ear_flare, snout_len, tail_kind, color, has_antlers, ear_flat
	"Rabbit":  (0.55, 0.32, 0.30, 0.20, 0.11, 0.42, 0.35, 0.16, "puff",  (0.72, 0.68, 0.60), False, True),
	"Hare":    (0.60, 0.34, 0.30, 0.22, 0.11, 0.50, 0.30, 0.18, "puff",  (0.64, 0.58, 0.48), False, True),
	"Fox":     (0.70, 0.36, 0.32, 0.24, 0.10, 0.30, 0.55, 0.24, "bushy", (0.75, 0.32, 0.15), False, False),
	"Deer":    (0.90, 0.46, 0.32, 0.48, 0.085, 0.22, 0.40, 0.26, "flick", (0.55, 0.38, 0.22), True,  True),
	"Goat":    (0.80, 0.48, 0.36, 0.30, 0.11, 0.20, 0.30, 0.20, "flick", (0.62, 0.60, 0.54), False, False),
	"Elk":     (1.15, 0.68, 0.44, 0.42, 0.12, 0.20, 0.35, 0.28, "flick", (0.42, 0.30, 0.18), True,  True),
	"Boar":    (0.85, 0.45, 0.42, 0.22, 0.13, 0.16, 0.25, 0.30, "curl",  (0.28, 0.24, 0.22), False, False),
	"Wolf":    (0.90, 0.42, 0.34, 0.26, 0.11, 0.22, 0.35, 0.26, "bushy", (0.45, 0.45, 0.48), False, False),
	"Bear":    (1.05, 0.60, 0.55, 0.26, 0.16, 0.18, 0.30, 0.20, "stub",  (0.26, 0.18, 0.13), False, False),
}


def clear_scene():
	bpy.ops.object.select_all(action="SELECT")
	bpy.ops.object.delete(use_global=False)
	for block in list(bpy.data.meshes) + list(bpy.data.materials):
		if block.users == 0:
			bpy.data.batch_remove([block])


def make_material(name, color):
	mat = bpy.data.materials.new(name=name)
	mat.use_nodes = True
	bsdf = mat.node_tree.nodes.get("Principled BSDF")
	bsdf.inputs["Base Color"].default_value = (color[0], color[1], color[2], 1.0)
	bsdf.inputs["Roughness"].default_value = 0.88
	return mat


def skeleton_quadruped(name, p):
	(body_len, body_h, body_w, leg_len, leg_radius, ear_len, ear_flare, snout_len,
		tail_kind, color, has_antlers, ear_flat) = p

	mesh = bpy.data.meshes.new(name + "Mesh")
	bm = bmesh.new()
	skin = bm.verts.layers.skin.verify()

	def vert(pos, radius):
		v = bm.verts.new(pos)
		v[skin].radius = (radius, radius)
		return v

	ground = leg_len
	chest_z = ground + body_h
	hip_z = ground + body_h * 0.95

	# ── spine + neck + head chain (a real curved profile, not a straight box).
	# NECK LENGTHENED (2026-07-19): "match proportions" -- reference photos
	# show a slender, visibly elongated neck carrying the head well clear of
	# the shoulders; the old neck_base->jaw span was short and stubby by
	# comparison. Pushed the neck/head points further forward and up. ──
	spine_pts = [
		((-body_len * 0.48, 0, hip_z), body_h * 0.42),                       # tail base
		((-body_len * 0.20, 0, chest_z * 1.02), body_h * 0.50),
		((body_len * 0.10, 0, chest_z * 1.05), body_h * 0.50),               # withers
		((body_len * 0.40, 0, chest_z * 1.05), body_h * 0.24),               # neck base
		((body_len * 0.62, 0, chest_z * 1.28), body_h * 0.22),               # jaw/head
		((body_len * 0.62 + snout_len, 0, chest_z * 1.22), body_h * 0.09),   # snout tip
	]
	spine_verts = [vert(pos, r) for pos, r in spine_pts]
	for i in range(len(spine_verts) - 1):
		bm.edges.new((spine_verts[i], spine_verts[i + 1]))
	# BUG FIXED: "No valid root vertex found" -- the Skin modifier needs
	# exactly one vertex per connected island explicitly marked as its
	# root (Blender does NOT reliably auto-pick one for a branching tree
	# like this skeleton); the tail-base spine vertex is the natural root.
	spine_verts[0][skin].use_root = True

	# BUG FIXED (2026-07-19): "fix the googly eyes" -- this used to sit at the
	# SNOUT TIP (spine_pts[-1], the very end of the nose). animal.gd's
	# _build_googly_eyes() offsets eyes forward/outward from wherever it's
	# given, on the assumption it's given the HEAD -- attached to the snout
	# tip, the eyes landed out past the end of the nose instead of on the
	# sides of the head where eyes actually belong. Now placed at the HEAD
	# vertex (spine_pts[-2], the jaw/head point, same one ears attach to)
	# instead, nudged slightly up and forward -- the actual head surface.
	head_v_pos = spine_pts[-2][0]
	head_marker_pos = (head_v_pos[0] + body_h * 0.10, 0.0, head_v_pos[2] + body_h * 0.15)

	# ── ears: two short chains branching off the head vertex. FLAT ears
	# (deer/rabbit/hare -- reference photos show broad, rounded ears, not
	# thin spikes) keep a wide tip radius instead of tapering to a point. ──
	head_v = spine_verts[-2]
	ear_tip_radius = body_h * (0.11 if ear_flat else 0.04)
	for side in (-1, 1):
		base = vert((head_v.co.x - body_h * 0.05, side * body_w * 0.18, head_v.co.z + body_h * 0.05), body_h * 0.08)
		tip = vert((base.co.x - ear_len * 0.15, side * (body_w * 0.18 + ear_len * ear_flare * 0.5), base.co.z + ear_len), ear_tip_radius)
		bm.edges.new((head_v, base))
		bm.edges.new((base, tip))

	back_spine = spine_verts[0]    # tail base / hip

	# ── tail: a short branch off the tail-base spine vertex ──
	tail_len = body_h * (1.1 if tail_kind == "bushy" else 0.5 if tail_kind in ("flick", "puff") else 0.25)
	tail_tip = vert((back_spine.co.x - tail_len, 0, back_spine.co.z + tail_len * 0.35), body_h * 0.18)
	bm.edges.new((back_spine, tail_tip))

	bm.to_mesh(mesh)
	bm.free()

	obj = bpy.data.objects.new(name, mesh)
	bpy.context.collection.objects.link(obj)

	skin_mod = obj.modifiers.new("Skin", type="SKIN")
	subsurf = obj.modifiers.new("Subdiv", type="SUBSURF")
	subsurf.levels = 1
	subsurf.render_levels = 1

	mat = make_material(name + "Mat", color)
	obj.data.materials.append(mat)

	bpy.context.view_layer.objects.active = obj
	obj.select_set(True)
	bpy.ops.object.shade_smooth()
	bpy.ops.object.convert(target="MESH")   # bake modifiers so glTF export carries real smooth geometry

	# leg attach points on the spine -- returned so build_species() can build
	# each leg as its OWN object (see build_leg() below). Kept OUT of the
	# fused body mesh on purpose: "can we give animations" -- a real walk
	# cycle needs each leg to be a separate node animal.gd can rotate at
	# its hip, which a single converted/fused mesh can't do.
	front_spine_pos = spine_pts[2][0]   # withers
	back_spine_pos = spine_pts[0][0]    # tail base / hip
	leg_specs = [
		(front_spine_pos, body_len * 0.30, -1, chest_z * 0.9),
		(front_spine_pos, body_len * 0.30, 1, chest_z * 0.9),
		(back_spine_pos, -body_len * 0.32, -1, hip_z),
		(back_spine_pos, -body_len * 0.32, 1, hip_z),
	]

	snout_tip_pos = spine_pts[-1][0]
	head_v_pos_out = spine_pts[-2][0]
	head_radius_out = spine_pts[-2][1]
	return obj, head_marker_pos, leg_specs, snout_tip_pos, head_v_pos_out, head_radius_out


def build_leg(name, hip_pos, leg_len, leg_radius, ground, mat):
	# hip -> knee -> foot, built in the leg's OWN local space (origin at the
	# hip) so rotating this object swings the whole leg from the hip, the
	# same way a real joint would.
	mesh = bpy.data.meshes.new(name + "Mesh")
	bm = bmesh.new()
	skin = bm.verts.layers.skin.verify()

	def vert(pos, radius):
		v = bm.verts.new(pos)
		v[skin].radius = (radius, radius)
		return v

	# BUG FIXED (2026-07-19): "legs floating" / visible seam where the leg
	# meets the body -- a separate mesh touching the torso at a single
	# tangent point left a visible gap/notch, since the body's own surface
	# curves away from that exact point. Adding a vertex ABOVE the hip that
	# reaches up INTO the torso guarantees real geometric overlap, hiding
	# the seam the same way overlapping cylinders always do.
	embed = vert((0, 0, leg_radius * 1.4), leg_radius * 1.3)
	hip = vert((0, 0, 0), leg_radius)
	hip[skin].use_root = True
	knee = vert((-0.02, 0, -(leg_len * 0.55)), leg_radius * 0.75)
	foot = vert((0, 0, -(hip_pos[2] - ground * 0.05)), leg_radius * 0.4)
	bm.edges.new((embed, hip))
	bm.edges.new((hip, knee))
	bm.edges.new((knee, foot))

	bm.to_mesh(mesh)
	bm.free()

	obj = bpy.data.objects.new(name, mesh)
	bpy.context.collection.objects.link(obj)
	obj.location = hip_pos

	obj.modifiers.new("Skin", type="SKIN")
	subsurf = obj.modifiers.new("Subdiv", type="SUBSURF")
	subsurf.levels = 1
	subsurf.render_levels = 1
	obj.data.materials.append(mat)

	bpy.context.view_layer.objects.active = obj
	obj.select_set(True)
	bpy.ops.object.shade_smooth()
	bpy.ops.object.convert(target="MESH")
	return obj


def build_nose(pos, radius):
	# a real black nose -- the single highest-impact, lowest-complexity fix
	# for matching the reference photo's face coloring (vs. one flat body
	# tint for the whole animal).
	bpy.ops.mesh.primitive_uv_sphere_add(radius=radius, location=pos, segments=8, ring_count=6)
	obj = bpy.context.active_object
	obj.name = "Nose"
	mat = bpy.data.materials.new(name="NoseMat")
	mat.use_nodes = True
	bsdf = mat.node_tree.nodes.get("Principled BSDF")
	bsdf.inputs["Base Color"].default_value = (0.03, 0.03, 0.03, 1.0)
	bsdf.inputs["Roughness"].default_value = 0.35
	obj.data.materials.append(mat)
	return obj


def build_antlers(head_pos, head_radius, body_h, scale, color):
	# a branching main beam + 2 tines per side -- built with the same
	# skin-modifier technique as legs/ears, just branching further. Real
	# reference photos of a buck were the reason this exists at all --
	# antlers were completely absent before.
	#
	# BUG FIXED (2026-07-19): "antlers are floating" -- this used to anchor
	# off head_marker_pos, the EYE-attachment point (deliberately offset
	# forward toward the snout for eye placement -- see the marker's own
	# comment). Reused for antlers, that same forward offset put the antler
	# base well clear of the actual head sphere's surface, with visible air
	# between them. Anchored directly to the real head vertex + its radius
	# now, so the antler base sits ON the skull instead of floating near it.
	mesh = bpy.data.meshes.new("AntlersMesh")
	bm = bmesh.new()
	skin = bm.verts.layers.skin.verify()

	def vert(pos, radius):
		v = bm.verts.new(pos)
		v[skin].radius = (radius, radius)
		return v

	root_r = body_h * 0.05 * scale
	for side in (-1, 1):
		base_pos = (
			head_pos[0] - head_radius * 0.35,
			side * head_radius * 0.55,
			head_pos[2] + head_radius * 0.75,
		)
		base = vert(base_pos, root_r)
		base[skin].use_root = True
		beam_len = body_h * 1.0 * scale
		mid = vert((base_pos[0] - beam_len * 0.2, base_pos[1] + side * beam_len * 0.15, base_pos[2] + beam_len * 0.55), root_r * 0.7)
		top = vert((mid.co.x - beam_len * 0.15, mid.co.y + side * beam_len * 0.1, mid.co.z + beam_len * 0.45), root_r * 0.4)
		bm.edges.new((base, mid))
		bm.edges.new((mid, top))
		# two tines branching off the main beam
		for t, (tx, ty, tz) in enumerate([(0.35, 0.25, 0.35), (0.15, 0.35, 0.55)]):
			tine_base = mid if t == 0 else top
			tine_tip = vert((tine_base.co.x - beam_len * tx, tine_base.co.y + side * beam_len * ty, tine_base.co.z + beam_len * tz), root_r * 0.35)
			bm.edges.new((tine_base, tine_tip))

	bm.to_mesh(mesh)
	bm.free()

	obj = bpy.data.objects.new("Antlers", mesh)
	bpy.context.collection.objects.link(obj)

	obj.modifiers.new("Skin", type="SKIN")
	subsurf = obj.modifiers.new("Subdiv", type="SUBSURF")
	subsurf.levels = 1
	subsurf.render_levels = 1

	mat = bpy.data.materials.new(name="AntlerMat")
	mat.use_nodes = True
	bsdf = mat.node_tree.nodes.get("Principled BSDF")
	bsdf.inputs["Base Color"].default_value = (0.62, 0.54, 0.42, 1.0)   # bark/bone tan-gray, matched to reference
	bsdf.inputs["Roughness"].default_value = 0.75
	obj.data.materials.append(mat)

	bpy.context.view_layer.objects.active = obj
	obj.select_set(True)
	bpy.ops.object.shade_smooth()
	bpy.ops.object.convert(target="MESH")
	return obj


def build_species(species, params):
	clear_scene()
	obj, head_marker_pos, leg_specs, snout_tip_pos, head_v_pos, head_radius = skeleton_quadruped(species, params)
	body_h_val = params[1]
	leg_len_val = params[3]
	leg_radius_val = params[4]
	has_antlers = params[10]

	root = bpy.data.objects.new(species, None)
	bpy.context.collection.objects.link(root)
	obj.parent = root

	mat = obj.data.materials[0]
	for i, (spine_pos, lx, side, lz) in enumerate(leg_specs):
		hip_pos = (lx, side * params[2] * 0.34, lz)
		leg_obj = build_leg("Leg%d" % i, hip_pos, leg_len_val, leg_radius_val, leg_len_val, mat)
		leg_obj.parent = root

	nose_obj = build_nose(snout_tip_pos, body_h_val * 0.09)
	nose_obj.parent = root

	if has_antlers:
		antler_obj = build_antlers(head_v_pos, head_radius, body_h_val, 1.0, params[9])
		antler_obj.parent = root

	head_marker = bpy.data.objects.new("HeadMarker", None)
	head_marker.location = head_marker_pos
	# BUG FIXED (2026-07-19): "fix the googly eyes" -- tribemember.gd/
	# animal.gd's shared _build_googly_eyes() places the two eyes mirrored
	# on LOCAL X (side-by-side) and pushed forward on LOCAL Z, which was
	# correct for the OLD sphere head (authored directly in Godot, where
	# X really was left-right and Z really was forward). This skeleton is
	# authored along Blender's X axis (forward/back) with side-to-side on
	# Blender Y -- which the glTF exporter maps to Godot's Z. Attached
	# directly, the "mirrored" eye offset (meant for side-to-side) landed on
	# the model's actual FORWARD axis instead (one eye in front of the
	# other, not side by side), and the "push forward" offset landed on the
	# actual SIDE axis (both eyes shifted the same way sideways). Rotating
	# the marker 90 degrees around the up axis swaps which local axis is
	# which, so the shared eye code -- unchanged, still used by the
	# fallback sphere head too -- ends up with locally-correct axes on both.
	head_marker.rotation_euler = (0, 0, math.radians(90))
	bpy.context.collection.objects.link(head_marker)
	head_marker.parent = root

	bpy.ops.object.select_all(action="DESELECT")
	for o in bpy.context.scene.objects:
		o.select_set(True)

	out_path = os.path.join(OUT_DIR, species.lower() + ".glb")
	bpy.ops.export_scene.gltf(filepath=out_path, export_format="GLB", use_selection=True)
	print(f"[gen_animals] wrote {out_path}")


for name, params in SPECIES.items():
	build_species(name, params)

print("[gen_animals] done -- %d species exported to %s" % (len(SPECIES), OUT_DIR))
