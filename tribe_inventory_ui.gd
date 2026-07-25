extends Node
# ─────────────────────────────────────────────────────────────────────────────
# TribeInventoryUI — "give inventory dedicated UI panel and profession UI
# with progression ability". Two sections in one panel: your own personal
# inventory (see FPSPlayer.gd's new inventory dict), and every tribe
# member's profession + skill tier + a real progress bar toward their next
# tier (SKILL_TIER_STEP, same numbers craft_weapon()/practice_profession()
# already use -- this is a window onto real state, not a separate system).
#
# Autoload singleton, same shape as the other UI panels this session.
# Toggle key: 8 (9 is the trading post, T/Q/TAB/B/U/F1 all taken).
# ─────────────────────────────────────────────────────────────────────────────
const UITheme = preload("res://ui_theme.gd")

var open: bool = false
var manager: Node = null
var player: Node = null

var _panel: PanelContainer = null
var _inv_box: VBoxContainer = null
var _prof_box: VBoxContainer = null

func _ready() -> void:
	call_deferred("_build_ui")
	set_process_unhandled_input(true)

func _build_ui() -> void:
	var ui := get_tree().root.find_child("UI", true, false)
	if ui == null:
		push_warning("TribeInventoryUI: no UI CanvasLayer found -- panel disabled")
		return
	_panel = PanelContainer.new()
	_panel.name = "InventoryProfessionPanel"
	var w := 620.0; var h := 540.0
	_panel.custom_minimum_size = Vector2(w, h)
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.offset_left = -w / 2.0
	_panel.offset_right = w / 2.0
	_panel.offset_top = -h / 2.0
	_panel.offset_bottom = h / 2.0
	_panel.visible = false
	UITheme.style_panel(_panel, UITheme.ACCENT_SAGE)
	ui.add_child(_panel)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(w - 32.0, h - 32.0)
	_panel.add_child(scroll)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 14)
	scroll.add_child(root)

	root.add_child(UITheme.heading("🎒  Your Inventory"))
	_inv_box = VBoxContainer.new()
	_inv_box.add_theme_constant_override("separation", 4)
	root.add_child(_inv_box)

	root.add_child(UITheme.styled_separator())
	root.add_child(UITheme.heading("🛠  Professions"))
	_prof_box = VBoxContainer.new()
	_prof_box.add_theme_constant_override("separation", 6)
	root.add_child(_prof_box)

	var close_btn := Button.new()
	close_btn.text = "Close (8)"
	close_btn.custom_minimum_size = Vector2(100, 30)
	UITheme.style_button(close_btn, UITheme.ACCENT_RED)
	close_btn.pressed.connect(close_panel)
	root.add_child(close_btn)

func toggle_panel() -> void:
	if open:
		close_panel()
	else:
		open_panel()

func open_panel() -> void:
	if manager == null or not is_instance_valid(manager):
		manager = get_tree().get_first_node_in_group("tribe_manager")
	if player == null or not is_instance_valid(player):
		player = get_tree().get_first_node_in_group("player")
	if _panel == null:
		return
	open = true
	_panel.visible = true
	_refresh()

func close_panel() -> void:
	open = false
	if _panel:
		_panel.visible = false

func _clear(box: VBoxContainer) -> void:
	for c in box.get_children():
		c.queue_free()

func _refresh() -> void:
	_refresh_inventory()
	_refresh_professions()

func _refresh_inventory() -> void:
	_clear(_inv_box)
	var inv: Dictionary = player.inventory if (player and is_instance_valid(player) and "inventory" in player) else {}
	if inv.is_empty():
		var lbl := Label.new()
		lbl.text = "Empty-handed -- mine, loot, or trade for something."
		lbl.add_theme_color_override("font_color", UITheme.TEXT_MUTED)
		_inv_box.add_child(lbl)
		return
	for item in inv.keys():
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		var name_lbl := Label.new()
		name_lbl.text = str(item)
		name_lbl.custom_minimum_size = Vector2(240, 24)
		name_lbl.add_theme_color_override("font_color", UITheme.TEXT_PRIMARY)
		row.add_child(name_lbl)
		row.add_child(UITheme.pill("x%d" % int(inv[item]), UITheme.ACCENT_GOLD))
		_inv_box.add_child(row)

func _refresh_professions() -> void:
	_clear(_prof_box)
	if manager == null or not ("members" in manager):
		return
	var any_shown := false
	for m in manager.members:
		if not is_instance_valid(m) or not ("profession" in m):
			continue
		var prof: String = str(m.profession)
		if prof == "":
			continue
		any_shown = true
		_prof_box.add_child(_build_profession_row(m, prof))
	if not any_shown:
		var lbl := Label.new()
		lbl.text = "No member has taken up a profession yet."
		lbl.add_theme_color_override("font_color", UITheme.TEXT_MUTED)
		_prof_box.add_child(lbl)

func _build_profession_row(m, prof: String) -> Control:
	var card := PanelContainer.new()
	UITheme.style_panel(card, UITheme.ACCENT_SAGE, UITheme.BG_ELEVATED)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	card.add_child(vb)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 10)
	vb.add_child(top)
	var name_lbl := Label.new()
	name_lbl.text = "%s -- %s" % [str(m.member_name), prof]
	name_lbl.custom_minimum_size = Vector2(260, 24)
	name_lbl.add_theme_color_override("font_color", UITheme.TEXT_PRIMARY)
	top.add_child(name_lbl)
	var skill: float = m.skill_in(prof) if m.has_method("skill_in") else 0.0
	var tier: String = m.skill_tier(prof) if m.has_method("skill_tier") else "Untrained"
	top.add_child(UITheme.pill(tier, UITheme.tier_color(tier)))

	# REAL PROGRESSION BAR (2026-07-19): "profession UI with progression
	# ability" -- shows exactly how far into the CURRENT tier this member
	# is, using the same SKILL_TIER_STEP practice_profession() advances by.
	var step: float = float(m.SKILL_TIER_STEP) if "SKILL_TIER_STEP" in m else 25.0
	var into_tier: float = fmod(skill, step)
	var bar := ProgressBar.new()
	bar.min_value = 0.0; bar.max_value = step
	bar.value = into_tier
	bar.custom_minimum_size = Vector2(0, 14)
	bar.show_percentage = false
	vb.add_child(bar)
	var pct_lbl := Label.new()
	pct_lbl.text = "%.0f / %.0f toward next tier (%.0f total)" % [into_tier, step, skill]
	pct_lbl.add_theme_color_override("font_color", UITheme.TEXT_MUTED)
	pct_lbl.add_theme_font_size_override("font_size", 11)
	vb.add_child(pct_lbl)
	return card

func _unhandled_input(event: InputEvent) -> void:
	if not open:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_8 or event.keycode == KEY_ESCAPE:
			close_panel()
			get_viewport().set_input_as_handled()
