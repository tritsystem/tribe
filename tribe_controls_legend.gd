extends Node
# ─────────────────────────────────────────────────────────────────────────────
# TribeControlsLegend — an always-available on-screen key reference.
#
# "I have no idea how to access anything" -- the game had accumulated dozens
# of real key bindings across FPSPlayer.gd/Tribemanager.gd (feed, build,
# terraform, formations, trade, the new overview/trade-menu panels...) with
# no single place a player could see them. This is that place: a compact
# legend docked in the bottom-right, VISIBLE BY DEFAULT (so a new player sees
# it immediately without having to already know a key to reveal it), toggled
# with F1 (the universal "help" convention) so it can be dismissed once
# learned.
#
# Autoload singleton, same shape as the other UI singletons this session.
# ─────────────────────────────────────────────────────────────────────────────
const UITheme = preload("res://ui_theme.gd")

var visible_legend: bool = true
var _panel: PanelContainer = null

# Grouped for scanability -- a wall of 30 unsorted bindings is not a legend,
# it's a wall. Each group is [heading, [ [key, action], ... ] ].
const GROUPS := [
	["Move & look", [
		["WASD", "move"], ["Mouse", "look"], ["Space/Ctrl", "swim up/down"],
	]],
	["Panels", [
		["F1", "toggle this legend"], ["Q", "tribe overview"], ["T", "trading post"],
		["TAB", "map"], ["B", "brain view"], ["U", "toggle HUD"],
		["Enter", "talk to the nearest member"], ["8", "inventory + professions"],
	]],
	["Direct member orders", [
		["V (hold)", "select who you're looking at"], ["V x3", "select whole tribe"],
		["M", "cycle selection"],
		["1-7", "gather/hunt/scout/wood/build/recruit/guard"],
		["Shift+num", "small order"], ["Ctrl+num", "large order"], ["0", "back to auto"],
	]],
	["Leader (hold R)", [
		["R+1/2/3", "rally gather/hunt/scout"], ["R+4", "raid a scouted rival"],
	]],
	["Player actions", [
		["F", "pick berries"], ["C", "carve a club"], ["X", "scout nearby"],
		["Y", "build fence"], ["L", "build teepee"], ["Z", "build wall block"],
		["N", "raise a forward camp"], ["9", "raise a trading post"],
		[",/.", "terraform down/up (hold, aim)"],
	]],
	["Tribe & allies", [
		["G", "bribe"], ["H", "feed your dog"], ["J", "toggle dog rally"],
		["[ / ]", "cycle raid focus tribe"], ["K", "raid the focused tribe"],
		["'", "send a trade envoy"],
	]],
	["Formation & defense", [
		["O", "cycle formation"], ["I", "cycle defense perimeter"], ["P", "cycle work plan"],
	]],
]

func _ready() -> void:
	call_deferred("_build_ui")
	set_process_unhandled_input(true)

func _build_ui() -> void:
	var ui := get_tree().root.find_child("UI", true, false)
	if ui == null:
		push_warning("TribeControlsLegend: no UI CanvasLayer found -- legend disabled")
		return
	_panel = PanelContainer.new()
	_panel.name = "ControlsLegendPanel"
	_panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	var w := 300.0; var h := 420.0
	_panel.custom_minimum_size = Vector2(w, h)
	_panel.offset_left = -w - 16.0
	_panel.offset_right = -16.0
	_panel.offset_top = -h - 16.0
	_panel.offset_bottom = -16.0
	UITheme.style_panel(_panel, UITheme.ACCENT_GOLD)
	ui.add_child(_panel)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(w - 24.0, h - 24.0)
	_panel.add_child(scroll)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	scroll.add_child(root)

	var title := UITheme.heading("Controls  (F1 to hide)")
	root.add_child(title)

	for group in GROUPS:
		var heading_lbl := Label.new()
		heading_lbl.text = str(group[0])
		heading_lbl.add_theme_color_override("font_color", UITheme.ACCENT_BLUE)
		heading_lbl.add_theme_font_size_override("font_size", 13)
		root.add_child(heading_lbl)
		for binding in group[1]:
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 8)
			row.add_child(UITheme.pill(str(binding[0]), UITheme.ACCENT_GOLD))
			var action_lbl := Label.new()
			action_lbl.text = str(binding[1])
			action_lbl.add_theme_color_override("font_color", UITheme.TEXT_PRIMARY)
			action_lbl.add_theme_font_size_override("font_size", 12)
			row.add_child(action_lbl)
			root.add_child(row)

	_panel.visible = visible_legend

func toggle_legend() -> void:
	visible_legend = not visible_legend
	if _panel:
		_panel.visible = visible_legend

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F1:
			toggle_legend()
			get_viewport().set_input_as_handled()
