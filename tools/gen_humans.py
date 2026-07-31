"""
Blender headless asset generator -- a real low-poly HUMAN body, matching the
technique tools/gen_animals.py already established for the animal roster
(bmesh skeleton + Skin modifier + Subdivision Surface + smooth shading,
converted to a static mesh so glTF export carries real baked geometry).

WHY THIS EXISTS: every human in the game (the player's own tribemembers --
Tribemanager._build_member_in_code() -- and rival NPCs -- npc.gd's _build())
is still a bare CapsuleMesh with a flat googly-eyed face slapped on, while
animals got a real modeled upgrade in an earlier pass. This closes that gap
with the SAME toolchain instead of inventing a new one.

Run with:
  "Blender.exe" --background --python tools/gen_humans.py

ONE generic body (not a per-species roster like animals) -- humans in this
game are distinguished by a runtime tint color (faction/personality/archetype)
and gear tier, not by shape. tribemember.gd/npc.gd already apply a single
material_override to reskin the whole body per-instance; this keeps that
exact convention (see the GDScript wiring: the tint functions recolor "Mesh"
AND "Leg0"/"Leg1", not just one part, so the two separate leg objects below
don't visibly mismatch the torso).

Keeps the same "HeadMarker" empty at the head (for the existing googly-eye
code to attach to, same as the animals) and the same "Leg0"/"Leg1" naming so
the walk-cycle code can rotate each leg from its own hip pivot -- just TWO
legs here (biped), not four.
"""
import bpy
import bmesh
import os

OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "assets", "humans")
os.makedirs(OUT_DIR, exist_ok=True)

# Proportions in meters -- a generic adult human, roughly 1.75m standing,
# matching the old CapsuleMesh's rough real-world scale so nothing else in
# the game (camera height, interact ranges, club reach) needs re-tuning.
LEG_LEN = 0.92          # hip to foot
HIP_Z = LEG_LEN
CHEST_Z = HIP_Z + 0.42
NECK_Z = CHEST_Z + 0.20
HEAD_Z = NECK_Z + 0.14
HIP_WIDTH = 0.24
SHOULDER_WIDTH = 0.34
TORSO_RADIUS = 0.17
NECK_RADIUS = 0.075
HEAD_RADIUS = 0.115
LEG_RADIUS = 0.085
ARM_RADIUS = 0.055
SKIN_TONE = (0.80, 0.62, 0.48)


def clear_scene():
	bpy.ops.object.select_all(action="SELECT")
	bpy.ops.object.delete(use_global=False)
	for block in list(bpy.data.meshes) + list(bpy.data.materials):
		if block.users == 0:
			bpy.data.batch_remove([block])


def make_material(name, color, roughness=0.85):
	mat = bpy.data.materials.new(name=name)
	mat.use_nodes = True
	bsdf = mat.node_tree.nodes.get("Principled BSDF")
	bsdf.inputs["Base Color"].default_value = (color[0], color[1], color[2], 1.0)
	bsdf.inputs["Roughness"].default_value = roughness
	return mat


def build_torso():
	# Spine + neck + head chain (skin-modifier skeleton, same technique as
	# gen_animals.py's quadruped spine) plus 2 arms branching off the chest --
	# all ONE connected mesh so it converts/exports as a single "Mesh" object,
	# matching tribemember.gd/npc.gd's existing single-material tint convention.
	mesh = bpy.data.meshes.new("HumanMesh")
	bm = bmesh.new()
	skin = bm.verts.layers.skin.verify()

	def vert(pos, radius):
		v = bm.verts.new(pos)
		v[skin].radius = (radius, radius)
		return v

	hip = vert((0, 0, HIP_Z), TORSO_RADIUS * 0.9)
	hip[skin].use_root = True
	chest = vert((0, 0, CHEST_Z), TORSO_RADIUS)
	neck = vert((0, 0, NECK_Z), NECK_RADIUS)
	head = vert((0, 0, HEAD_Z), HEAD_RADIUS)
	bm.edges.new((hip, chest))
	bm.edges.new((chest, neck))
	bm.edges.new((neck, head))

	head_marker_pos = (HEAD_RADIUS * 0.15, 0.0, HEAD_Z + HEAD_RADIUS * 0.1)

	# arms: shoulder -> elbow -> hand, branching off the chest vertex, resting
	# slightly out and down at the sides (a static "at ease" pose -- not
	# animated, same scope tradeoff animal.gd made for ears/tail)
	for side in (-1, 1):
		shoulder = vert((0, side * SHOULDER_WIDTH * 0.5, CHEST_Z + 0.05), ARM_RADIUS * 1.2)
		bm.edges.new((chest, shoulder))
		elbow = vert((0.02, side * (SHOULDER_WIDTH * 0.5 + 0.06), CHEST_Z - 0.22), ARM_RADIUS)
		bm.edges.new((shoulder, elbow))
		hand = vert((0.04, side * (SHOULDER_WIDTH * 0.5 + 0.08), CHEST_Z - 0.48), ARM_RADIUS * 0.65)
		bm.edges.new((elbow, hand))

	bm.to_mesh(mesh)
	bm.free()

	obj = bpy.data.objects.new("Human", mesh)
	bpy.context.collection.objects.link(obj)

	obj.modifiers.new("Skin", type="SKIN")
	subsurf = obj.modifiers.new("Subdiv", type="SUBSURF")
	subsurf.levels = 1
	subsurf.render_levels = 1

	mat = make_material("HumanBodyMat", SKIN_TONE)
	obj.data.materials.append(mat)

	bpy.context.view_layer.objects.active = obj
	obj.select_set(True)
	bpy.ops.object.shade_smooth()
	bpy.ops.object.convert(target="MESH")

	return obj, head_marker_pos, mat


def build_leg(name, side, mat):
	# hip -> knee -> foot, in the leg's OWN local space (origin = hip), same
	# technique as gen_animals.py's build_leg() -- a separate object so
	# GDScript can rotate it from the hip for a real walk cycle.
	mesh = bpy.data.meshes.new(name + "Mesh")
	bm = bmesh.new()
	skin = bm.verts.layers.skin.verify()

	def vert(pos, radius):
		v = bm.verts.new(pos)
		v[skin].radius = (radius, radius)
		return v

	embed = vert((0, 0, LEG_RADIUS * 1.3), LEG_RADIUS * 1.2)   # overlaps up into the hip, hides the seam
	hip = vert((0, 0, 0), LEG_RADIUS)
	hip[skin].use_root = True
	knee = vert((0.01, 0, -LEG_LEN * 0.52), LEG_RADIUS * 0.8)
	foot = vert((0.05, 0, -LEG_LEN * 0.98), LEG_RADIUS * 0.55)
	bm.edges.new((embed, hip))
	bm.edges.new((hip, knee))
	bm.edges.new((knee, foot))

	bm.to_mesh(mesh)
	bm.free()

	obj = bpy.data.objects.new(name, mesh)
	bpy.context.collection.objects.link(obj)
	obj.location = (0, side * HIP_WIDTH * 0.5, HIP_Z)

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


def build_human():
	clear_scene()
	torso, head_marker_pos, mat = build_torso()

	root = bpy.data.objects.new("Human", None)
	bpy.context.collection.objects.link(root)
	torso.parent = root
	torso.name = "Mesh"   # tribemember.gd/npc.gd both look up a child literally named "Mesh"

	leg0 = build_leg("Leg0", -1, mat)   # left
	leg0.parent = root
	leg1 = build_leg("Leg1", 1, mat)    # right
	leg1.parent = root

	head_marker = bpy.data.objects.new("HeadMarker", None)
	head_marker.location = head_marker_pos
	# Same 90-degree axis fix gen_animals.py applies -- this skeleton is
	# authored with forward on Blender X and side-to-side on Blender Y, which
	# glTF remaps to Godot Z; rotating the marker keeps the shared
	# _build_googly_eyes()-style code's left/right and forward/back axes
	# correct without changing that shared code itself.
	import math
	head_marker.rotation_euler = (0, 0, math.radians(90))
	bpy.context.collection.objects.link(head_marker)
	head_marker.parent = root

	bpy.ops.object.select_all(action="DESELECT")
	for o in bpy.context.scene.objects:
		o.select_set(True)

	out_path = os.path.join(OUT_DIR, "human.glb")
	bpy.ops.export_scene.gltf(filepath=out_path, export_format="GLB", use_selection=True)
	print(f"[gen_humans] wrote {out_path}")


build_human()
print("[gen_humans] done")
