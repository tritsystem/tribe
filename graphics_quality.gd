extends Node
# Autoload singleton: GraphicsQuality
# Call set_quality(GraphicsQuality.Quality.LOW / MEDIUM / HIGH) from any script
# or a future settings menu.  Defaults to HIGH to match the scene's baked values.

enum Quality { LOW, MEDIUM, HIGH }

# Default LOW. MEDIUM still kept GLOW (full-screen bloom), SHADOWS (a whole
# second render pass over every mesh from the sun's view), and MSAA 2x -- on the
# huge island maps those three together made it "insanely laggy, unplayable"
# regardless of mesh count (the real cost was never the meshes). LOW turns all of
# them OFF for a playable framerate; bump to MEDIUM/HIGH from a settings menu once
# the world is smooth. This is the single biggest FPS lever in the project.
var current: int = Quality.LOW

func _ready() -> void:
	set_process(true)   # apply on first frame after main scene is loaded

func set_quality(q: int) -> void:
	current = q
	set_process(true)   # re-apply next frame

func _process(_delta: float) -> void:
	var we_nodes: Array[Node] = get_tree().root.find_children("*", "WorldEnvironment", true, false)
	var sun_nodes: Array[Node] = get_tree().root.find_children("*", "DirectionalLight3D", true, false)
	if we_nodes.is_empty() or sun_nodes.is_empty():
		return   # main scene not ready yet; retry next frame
	set_process(false)

	var vp: Viewport = get_viewport()
	if vp == null:
		return
	var we: WorldEnvironment = we_nodes[0] as WorldEnvironment
	var sun: DirectionalLight3D = sun_nodes[0] as DirectionalLight3D

	match current:
		Quality.LOW:
			vp.msaa_3d = Viewport.MSAA_DISABLED
			if we and we.environment:
				we.environment.ssao_enabled = false
				we.environment.glow_enabled = false   # full-screen bloom -- costly, gone
			if sun:
				sun.shadow_enabled = false             # skips the whole shadow render pass
		Quality.MEDIUM:
			vp.msaa_3d = Viewport.MSAA_2X
			if we and we.environment:
				we.environment.ssao_enabled = false
			if sun:
				sun.shadow_enabled = true
				sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
		_:  # HIGH
			vp.msaa_3d = Viewport.MSAA_4X
			if we and we.environment:
				we.environment.ssao_enabled = true
				# GLOW (2026-07-19): HIGH never actually turned this ON --
				# only LOW explicitly turned it off, so it silently rode
				# whatever the scene's WorldEnvironment resource happened to
				# have baked in. Real embers (campfire.gd/blacksmith_forge.gd
				# both use emissive materials) only actually bloom with this
				# genuinely enabled -- a real, visible payoff for choosing HIGH.
				we.environment.glow_enabled = true
				we.environment.glow_bloom = 0.12
				we.environment.glow_intensity = 0.9
			if sun:
				sun.shadow_enabled = true
				sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
