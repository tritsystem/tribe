extends Node
# Autoload singleton: GraphicsQuality
# Call set_quality(GraphicsQuality.Quality.LOW / MEDIUM / HIGH) from any script
# or a future settings menu.  Defaults to HIGH to match the scene's baked values.

enum Quality { LOW, MEDIUM, HIGH }

var current: int = Quality.HIGH

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
			if sun:
				sun.shadow_enabled = false
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
			if sun:
				sun.shadow_enabled = true
				sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
