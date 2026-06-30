extends Control
# ─────────────────────────────────────────────────────────────────────────────
# BrainVisualizer — draws a TribeMember's LIVE Spikeling brain on screen.
#
# Neurons are circles (fill = how charged toward firing; yellow ring = fired
# this tick). Synapses are lines (thicker/brighter = stronger weight — and you
# can watch them thicken as the member learns). Toggle with [B]; it shows the
# brain of whichever member is nearest the player.
#
# The manager builds this in code and feeds it `member` each frame.
# ─────────────────────────────────────────────────────────────────────────────

var member = null

func _process(_delta: float) -> void:
	queue_redraw()

func _draw() -> void:
	var font := ThemeDB.fallback_font

	# panel
	var rect := Rect2(Vector2.ZERO, size)
	draw_rect(rect, Color(0.06, 0.07, 0.10, 0.86))
	draw_rect(rect, Color(0.40, 0.50, 0.62, 0.6), false, 2.0)

	if member == null or member.brain == null:
		draw_string(font, Vector2(14, 28), "Brain view — no one near", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(0.8, 0.85, 0.95))
		return

	var brain = member.brain
	var nstates: Array = brain.neuron_states()
	var sstates: Array = brain.synapse_states()

	draw_string(font, Vector2(14, 26),
		"BRAIN — %s  [%s]" % [member.member_name, member.personality],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(0.92, 0.96, 1.0))

	# ── layout by topology: inputs (no incoming) left, outputs (no outgoing)
	# right, everything else in the middle. Works for any brain — tribe or animal.
	var has_in := {}
	var has_out := {}
	for s in sstates:
		has_out[s["src"]] = true
		has_in[s["dst"]] = true
	var stages: Array = []
	var totals := [0, 0, 0]
	for i in range(nstates.size()):
		var stage := 1
		if not has_in.has(i):
			stage = 0
		elif not has_out.has(i):
			stage = 2
		stages.append(stage)
		totals[stage] += 1

	var col_x := [size.x * 0.18, size.x * 0.50, size.x * 0.82]
	var col_idx := [0, 0, 0]
	var pos: Dictionary = {}
	for i in range(nstates.size()):
		var st: int = stages[i]
		var n_in_col: int = max(1, totals[st])
		var y := 52.0 + (size.y - 78.0) * (float(col_idx[st] + 1) / float(n_in_col + 1))
		col_idx[st] += 1
		pos[i] = Vector2(col_x[st], y)

	# ── synapses (drawn first, under the neurons) ──
	for s in sstates:
		if not pos.has(s["src"]) or not pos.has(s["dst"]):
			continue
		var a: Vector2 = pos[s["src"]]
		var b: Vector2 = pos[s["dst"]]
		var w := float(s["weight"])
		var width := clampf(w / 40.0, 1.0, 6.0)
		var col := Color(0.30, 0.75, 0.40).lerp(Color(1.0, 0.88, 0.30), clampf(w / 200.0, 0.0, 1.0))
		draw_line(a, b, col, width)

	# ── neurons ──
	for i in range(nstates.size()):
		var n = nstates[i]
		var p: Vector2 = pos[i]
		var fill := clampf(float(n["p"]) / maxf(1.0, float(n["threshold"])), 0.0, 1.0)
		var c := Color(0.20, 0.25, 0.35).lerp(Color(0.95, 0.55, 0.20), fill)
		draw_circle(p, 16.0, c)
		if n["fired"]:
			draw_arc(p, 19.0, 0.0, TAU, 24, Color(1.0, 1.0, 0.4), 3.0)
		draw_arc(p, 16.0, 0.0, TAU, 24, Color(0.80, 0.85, 0.95, 0.8), 1.5)
		draw_string(font, p + Vector2(-22, 30), String(n["name"]), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.85, 0.90, 1.0))
