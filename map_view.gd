extends Control
class_name MapView
# ─────────────────────────────────────────────────────────────────────────────
# MapView — a top-down world map, opened with [TAB]. Every camp that exists
# shows up as a dot the moment the tribe is placed (so the player always
# knows roughly how the world is laid out), but it's anonymous — just a gray
# dot — until that tribe is `discovered` (by scouting with [T], or now by
# simply walking close enough, see Tribemanager._check_proximity_discovery).
# Discovered camps get their real color and name label.
# ─────────────────────────────────────────────────────────────────────────────

var tribes: Array = []        # Array[Dictionary]: pos(Vector2), color, name, discovered
var player_pos: Vector2 = Vector2.ZERO
var player_dir: float = 0.0
var world_extent: float = 170.0

func _draw() -> void:
	var sz := size
	var pad := 24.0
	var draw_size := minf(sz.x, sz.y) - pad * 2.0
	draw_rect(Rect2(Vector2.ZERO, sz), Color(0.04, 0.05, 0.04, 0.94), true)

	var origin := Vector2(pad, pad)
	draw_rect(Rect2(origin, Vector2(draw_size, draw_size)), Color(0.13, 0.19, 0.11, 1.0), true)
	draw_rect(Rect2(origin, Vector2(draw_size, draw_size)), Color(0.45, 0.55, 0.38, 1.0), false, 2.0)

	var center := origin + Vector2(draw_size, draw_size) * 0.5
	var px_per_unit := (draw_size * 0.5) / maxf(world_extent, 1.0)

	var font := ThemeDB.fallback_font

	for t in tribes:
		var wp: Vector2 = t["pos"]
		var p := center + wp * px_per_unit
		var discovered: bool = t["discovered"]
		if discovered:
			draw_circle(p, 6.0, t["color"])
			draw_circle(p, 6.0, Color(0, 0, 0), false, 1.5)
			draw_string(font, p + Vector2(9, 4), str(t["name"]), HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1, 1, 1))
		else:
			draw_circle(p, 4.0, Color(0.55, 0.55, 0.55, 0.85))

	# player marker — a little triangle pointing the way you're facing
	var pp := center + player_pos * px_per_unit
	var fwd := Vector2(sin(player_dir), cos(player_dir))
	var right := fwd.rotated(PI / 2.0)
	var tri := PackedVector2Array([
		pp + fwd * 10.0,
		pp - fwd * 6.0 + right * 6.0,
		pp - fwd * 6.0 - right * 6.0,
	])
	draw_colored_polygon(tri, Color(1.0, 0.92, 0.3))

	draw_string(font, origin + Vector2(6, -8), "WORLD MAP — gray = undiscovered  [TAB] close",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.9, 0.9, 0.85))
