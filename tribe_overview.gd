extends Node
# ─────────────────────────────────────────────────────────────────────────────
# TribeOverview — the single, gorgeous dashboard that surfaces EVERYTHING the
# tribe simulation tracks, in one place: resources, leadership/throne,
# emergent ideology, the full roster (rank, hierarchy role, profession +
# skill tier), settlements, and active rivalries. Nothing here replaces an
# existing panel (chat, trade requests, the trade menu, the map, the brain
# view all stay exactly as they were) -- this is the missing "big picture"
# view tying all of it together, backed by Tribemanager.overview_data().
#
# Autoload singleton, same shape as TribeChat/TribeTradeUI/TribeTradeMenu.
# Toggle key: Q (O was already cycle_formation, see FPSPlayer.gd). Gated the
# same way those are (`open` checked before raw input is consumed elsewhere).
# ─────────────────────────────────────────────────────────────────────────────
const UITheme = preload("res://ui_theme.gd")

var open: bool = false
var manager: Node = null

var _panel: PanelContainer = null
var _header_box: VBoxContainer = null
var _roster_box: VBoxContainer = null
var _settlements_box: VBoxContainer = null
var _rivalries_box: VBoxContainer = null

func _ready() -> void:
	call_deferred("_build_ui")
	set_process_unhandled_input(true)

func _build_ui() -> void:
	var ui := get_tree().root.find_child("UI", true, false)
	if ui == null:
		push_warning("TribeOverview: no UI CanvasLayer found -- overview disabled")
		return
	_panel = PanelContainer.new()
	_panel.name = "TribeOverviewPanel"
	# BUG FIXED (2026-07-19): "the Q menu is totally off center" --
	# set_anchors_preset(PRESET_CENTER) computes its offsets from whatever
	# size the control has AT THAT CALL, which was still zero (custom_
	# minimum_size hadn't been set yet) -- it anchored to the exact center
	# point with a zero-size rect, then grew asymmetrically once the real
	# size was applied. Setting the size FIRST, then anchoring, makes the
	# offsets it computes actually match the real panel.
	var w := 640.0; var h := 560.0
	_panel.custom_minimum_size = Vector2(w, h)
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.offset_left = -w / 2.0
	_panel.offset_right = w / 2.0
	_panel.offset_top = -h / 2.0
	_panel.offset_bottom = h / 2.0
	_panel.visible = false
	UITheme.style_panel(_panel, UITheme.ACCENT_GOLD)
	ui.add_child(_panel)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(608, 532)
	_panel.add_child(scroll)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 14)
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(root)

	_header_box = VBoxContainer.new()
	_header_box.add_theme_constant_override("separation", 6)
	root.add_child(_header_box)

	root.add_child(UITheme.styled_separator())
	root.add_child(UITheme.heading("👥  Roster"))
	_roster_box = VBoxContainer.new()
	_roster_box.add_theme_constant_override("separation", 4)
	root.add_child(_roster_box)

	root.add_child(UITheme.styled_separator())
	root.add_child(UITheme.heading("🏘  Settlements"))
	_settlements_box = VBoxContainer.new()
	_settlements_box.add_theme_constant_override("separation", 4)
	root.add_child(_settlements_box)

	root.add_child(UITheme.styled_separator())
	root.add_child(UITheme.heading("⚔  Rivalries"))
	_rivalries_box = VBoxContainer.new()
	_rivalries_box.add_theme_constant_override("separation", 4)
	root.add_child(_rivalries_box)

	var close_btn := Button.new()
	close_btn.text = "Close (Q)"
	close_btn.custom_minimum_size = Vector2(100, 30)
	UITheme.style_button(close_btn, UITheme.ACCENT_RED)
	close_btn.pressed.connect(close_overview)
	root.add_child(close_btn)

func toggle_overview() -> void:
	if open:
		close_overview()
	else:
		open_overview()

func open_overview() -> void:
	if manager == null or not is_instance_valid(manager):
		manager = get_tree().get_first_node_in_group("tribe_manager")
	if manager == null or _panel == null:
		return
	open = true
	_panel.visible = true
	_refresh()

func close_overview() -> void:
	open = false
	if _panel:
		_panel.visible = false

func _refresh() -> void:
	if manager == null or not manager.has_method("overview_data"):
		return
	var d: Dictionary = manager.overview_data()
	_refresh_header(d)
	_refresh_roster(d)
	_refresh_settlements(d)
	_refresh_rivalries(d)

func _clear(box: VBoxContainer) -> void:
	for c in box.get_children():
		c.queue_free()

func _refresh_header(d: Dictionary) -> void:
	_clear(_header_box)
	_header_box.add_child(UITheme.heading("🔥  %s" % str(d.get("throne_name", "the tribe"))))

	var leader_row := HBoxContainer.new()
	leader_row.add_theme_constant_override("separation", 8)
	_header_box.add_child(leader_row)
	var leader_text: String = "You lead" if bool(d.get("is_leader", false)) \
		else ("%s leads" % str(d.get("npc_leader_name"))) if str(d.get("npc_leader_name", "")) != "" \
		else "No clear leader"
	leader_row.add_child(UITheme.pill(leader_text, UITheme.ACCENT_GOLD))
	leader_row.add_child(UITheme.pill(str(d.get("ideology", "Undefined")), UITheme.ACCENT_BLUE))
	var unrest: float = float(d.get("unrest", 0.0))
	if unrest > 0.5:
		leader_row.add_child(UITheme.pill("unrest %.1f" % unrest, UITheme.ACCENT_RED))

	var res_row := HBoxContainer.new()
	res_row.add_theme_constant_override("separation", 16)
	_header_box.add_child(res_row)
	for entry in [["🍖 Food", d.get("food", 0)], ["🪵 Wood", d.get("wood", 0)], ["🪨 Materials", d.get("materials", 0)]]:
		var lbl := Label.new()
		lbl.text = "%s: %d" % [entry[0], int(entry[1])]
		lbl.add_theme_color_override("font_color", UITheme.TEXT_PRIMARY)
		res_row.add_child(lbl)

func _refresh_roster(d: Dictionary) -> void:
	_clear(_roster_box)
	var roster: Array = d.get("roster", [])
	if roster.is_empty():
		var lbl := Label.new()
		lbl.text = "No members yet."
		lbl.add_theme_color_override("font_color", UITheme.TEXT_MUTED)
		_roster_box.add_child(lbl)
		return
	var quota: int = int(d.get("official_quota", 1))
	var quota_lbl := Label.new()
	quota_lbl.text = "%d members -- Official quota: %d" % [roster.size(), quota]
	quota_lbl.add_theme_color_override("font_color", UITheme.TEXT_MUTED)
	quota_lbl.add_theme_font_size_override("font_size", 12)
	_roster_box.add_child(quota_lbl)
	for m in roster:
		_roster_box.add_child(_build_member_row(m))

func _build_member_row(m: Dictionary) -> Control:
	var card := PanelContainer.new()
	UITheme.style_panel(card, UITheme.ACCENT_GOLD if bool(m.get("is_official", false)) else UITheme.TEXT_MUTED, UITheme.BG_ELEVATED)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 8)
	card.add_child(hb)

	var name_lbl := Label.new()
	name_lbl.text = str(m.get("name", "?"))
	name_lbl.custom_minimum_size = Vector2(120, 24)
	name_lbl.add_theme_color_override("font_color", UITheme.TEXT_PRIMARY)
	hb.add_child(name_lbl)

	hb.add_child(UITheme.pill(str(m.get("rank", "")), UITheme.sentiment_color(float(m.get("relationship", 0.0)) - 1.0)))
	hb.add_child(UITheme.pill(str(m.get("role", "")), UITheme.ACCENT_BLUE))
	var prof: String = str(m.get("profession", ""))
	if prof != "":
		hb.add_child(UITheme.pill("%s (%s)" % [prof, str(m.get("profession_tier", ""))],
			UITheme.tier_color(str(m.get("profession_tier", "")))))
	if bool(m.get("is_official", false)):
		hb.add_child(UITheme.pill("★ Official", UITheme.ACCENT_GOLD))
	return card

func _refresh_settlements(d: Dictionary) -> void:
	_clear(_settlements_box)
	var settlements: Array = d.get("settlements", [])
	if settlements.is_empty():
		var lbl := Label.new()
		lbl.text = "No settlements founded yet."
		lbl.add_theme_color_override("font_color", UITheme.TEXT_MUTED)
		_settlements_box.add_child(lbl)
		return
	for s in settlements:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var lbl := Label.new()
		lbl.text = str(s.get("name", "?"))
		lbl.add_theme_color_override("font_color", UITheme.TEXT_PRIMARY)
		lbl.custom_minimum_size = Vector2(200, 24)
		row.add_child(lbl)
		row.add_child(UITheme.pill(str(s.get("district", "")), UITheme.ACCENT_SAGE))
		_settlements_box.add_child(row)

func _refresh_rivalries(d: Dictionary) -> void:
	_clear(_rivalries_box)
	var rivals: Array = d.get("rivalries", [])
	if rivals.is_empty():
		var lbl := Label.new()
		lbl.text = "No active blood feuds -- for now."
		lbl.add_theme_color_override("font_color", UITheme.TEXT_MUTED)
		_rivalries_box.add_child(lbl)
		return
	for r in rivals:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var lbl := Label.new()
		lbl.text = str(r.get("tribe_name", "?"))
		lbl.add_theme_color_override("font_color", UITheme.TEXT_PRIMARY)
		lbl.custom_minimum_size = Vector2(200, 24)
		row.add_child(lbl)
		row.add_child(UITheme.pill("feud %.0f%%" % (float(r.get("rivalry", 0.0)) * 100.0), UITheme.ACCENT_RED))
		_rivalries_box.add_child(row)

func _unhandled_input(event: InputEvent) -> void:
	if not open:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_Q or event.keycode == KEY_ESCAPE:
			close_overview()
			get_viewport().set_input_as_handled()
