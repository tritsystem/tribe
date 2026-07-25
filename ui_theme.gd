class_name TribeUITheme
extends RefCounted
# ─────────────────────────────────────────────────────────────────────────────
# TribeUITheme — one shared visual language for every tribe UI panel
# (trade menu, incoming trade requests, the new tribe overview, chat, etc.),
# instead of each panel hand-rolling its own StyleBoxFlat with slightly
# different colors. A campfire palette (warm charcoal ground, ember/gold
# accent, sage for growth/positive, deep red for danger/rivalry) fits a
# tribal survival game better than a generic UI blue.
#
# Static helpers only -- no instancing needed. `const SpatialGrid = preload(...)`-
# style usage: `const UITheme = preload("res://ui_theme.gd")` then
# `UITheme.panel_style()`, `UITheme.section_label(text)`, etc.
# ─────────────────────────────────────────────────────────────────────────────

# ── palette ──
const BG            := Color(0.07, 0.065, 0.06, 0.94)   # warm near-black, not pure black
const BG_ELEVATED   := Color(0.11, 0.10, 0.09, 0.96)     # a row/card sitting "above" the panel
const BG_ROW_ALT    := Color(0.095, 0.088, 0.078, 0.9)
const ACCENT_GOLD   := Color(0.92, 0.72, 0.32)           # embers / firelight -- the primary accent
const ACCENT_SAGE   := Color(0.55, 0.72, 0.45)           # growth, trust, positive
const ACCENT_RED    := Color(0.82, 0.32, 0.28)           # danger, rivalry, hostility
const ACCENT_BLUE   := Color(0.45, 0.62, 0.78)           # trade, water, calm
const TEXT_PRIMARY  := Color(0.94, 0.91, 0.85)
const TEXT_MUTED    := Color(0.68, 0.63, 0.56)
const TEXT_GOLD     := ACCENT_GOLD

static func panel_style(accent: Color = ACCENT_GOLD, bg: Color = BG) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = accent
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = 14
	sb.content_margin_bottom = 14
	sb.shadow_color = Color(0, 0, 0, 0.35)
	sb.shadow_size = 8
	return sb

static func row_style(alt: bool = false) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = BG_ROW_ALT if alt else BG_ELEVATED
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	return sb

static func button_style(accent: Color = ACCENT_GOLD) -> Dictionary:
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(accent.r, accent.g, accent.b, 0.18)
	normal.border_color = accent
	normal.set_border_width_all(1)
	normal.set_corner_radius_all(6)
	normal.content_margin_left = 10
	normal.content_margin_right = 10
	normal.content_margin_top = 5
	normal.content_margin_bottom = 5
	var hover := normal.duplicate()
	hover.bg_color = Color(accent.r, accent.g, accent.b, 0.32)
	var pressed := normal.duplicate()
	pressed.bg_color = Color(accent.r, accent.g, accent.b, 0.48)
	return {"normal": normal, "hover": hover, "pressed": pressed}

static func style_button(btn: Button, accent: Color = ACCENT_GOLD) -> void:
	var styles: Dictionary = button_style(accent)
	btn.add_theme_stylebox_override("normal", styles["normal"])
	btn.add_theme_stylebox_override("hover", styles["hover"])
	btn.add_theme_stylebox_override("pressed", styles["pressed"])
	btn.add_theme_color_override("font_color", TEXT_PRIMARY)
	btn.add_theme_color_override("font_hover_color", accent)

static func style_panel(panel: PanelContainer, accent: Color = ACCENT_GOLD, bg: Color = BG) -> void:
	panel.add_theme_stylebox_override("panel", panel_style(accent, bg))

## A consistent section heading -- gold, bold via bbcode, slight letter feel
## via a thin rule underneath drawn as a following HSeparator's color.
static func heading(text: String) -> RichTextLabel:
	var l := RichTextLabel.new()
	l.bbcode_enabled = true
	l.fit_content = true
	l.text = "[b][color=#%s]%s[/color][/b]" % [ACCENT_GOLD.to_html(false), text]
	return l

static func styled_separator() -> HSeparator:
	var sep := HSeparator.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(ACCENT_GOLD.r, ACCENT_GOLD.g, ACCENT_GOLD.b, 0.35)
	sb.content_margin_top = 1
	sb.content_margin_bottom = 1
	sep.add_theme_stylebox_override("separator", sb)
	return sep

## Small colored status pill (rank/role/tier/stance) -- encodes state as a
## shape+color, not just a number, the same "semantic color, glanceable"
## principle a good dashboard uses everywhere.
static func pill(text: String, accent: Color) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(accent.r, accent.g, accent.b, 0.22)
	sb.border_color = accent
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(9)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	p.add_theme_stylebox_override("panel", sb)
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", accent)
	l.add_theme_font_size_override("font_size", 13)
	p.add_child(l)
	return p

## Maps a 0..1 (or -1..1) sentiment/skill value to a semantic color -- used
## everywhere a number needs to read at a glance (opinion, rivalry, skill tier).
static func sentiment_color(v: float) -> Color:
	if v >= 0.4: return ACCENT_SAGE
	if v <= -0.3: return ACCENT_RED
	return TEXT_MUTED

static func tier_color(tier: String) -> Color:
	match tier:
		"Master": return ACCENT_GOLD
		"Expert": return ACCENT_SAGE
		"Journeyman": return ACCENT_BLUE
		"Novice": return TEXT_MUTED
		_: return Color(TEXT_MUTED.r, TEXT_MUTED.g, TEXT_MUTED.b, 0.6)
