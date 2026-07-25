extends Node
# ─────────────────────────────────────────────────────────────────────────────
# TribeTradeMenu — a real, player-DRIVEN trading menu. Autoload singleton
# (mirrors TribeChat/TribeTradeUI's shape).
#
# Previously the only way to trade was player_send_trade_envoy(), which
# auto-picked the nearest willing partner and a fixed offer size -- there was
# no way to actually CHOOSE who to trade with or how much. Toggled with T:
# lists every discovered, non-hostile tribe (Tribemanager.trade_partners())
# with what they're offering and how they currently stand with you, each row
# with its own "Propose" button that sends an envoy for a chosen amount
# (Tribemanager.propose_trade_with()).
#
# VISUAL PASS (2026-07-19): reskinned onto the shared campfire palette
# (ui_theme.gd) -- semantic-color stance/rivalry pills instead of plain text,
# an amount stepper instead of a fixed offer, consistent rounded cards.
#
# INPUT GATING: same pattern as TribeChat/TribeTradeUI -- `open` is checked by
# FPSPlayer/Tribemanager before consuming raw keys while this is showing.
# ─────────────────────────────────────────────────────────────────────────────
const UITheme = preload("res://ui_theme.gd")

var open: bool = false
var manager: Node = null

var _panel: PanelContainer = null
var _rows_box: VBoxContainer = null
var _empty_label: Label = null
var _offer_amt: int = 3
var _amt_label: Label = null

func _ready() -> void:
	call_deferred("_build_ui")
	set_process_unhandled_input(true)

func _build_ui() -> void:
	var ui := get_tree().root.find_child("UI", true, false)
	if ui == null:
		push_warning("TribeTradeMenu: no UI CanvasLayer found -- trade menu disabled")
		return
	_panel = PanelContainer.new()
	_panel.name = "TradeMenuPanel"
	# BUG FIXED (2026-07-19): same off-center bug as tribe_overview.gd -- size
	# must be set BEFORE anchoring so PRESET_CENTER's offsets are computed
	# from the real panel size, not a zero-size rect.
	var w := 460.0; var h := 340.0
	_panel.custom_minimum_size = Vector2(w, h)
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.offset_left = -w / 2.0
	_panel.offset_right = w / 2.0
	_panel.offset_top = -h / 2.0
	_panel.offset_bottom = h / 2.0
	_panel.visible = false
	UITheme.style_panel(_panel, UITheme.ACCENT_BLUE)
	ui.add_child(_panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	_panel.add_child(vb)

	vb.add_child(UITheme.heading("🏕  Trading Post"))
	var subtitle := Label.new()
	subtitle.text = "known tribes willing to deal with you"
	subtitle.add_theme_color_override("font_color", UITheme.TEXT_MUTED)
	subtitle.add_theme_font_size_override("font_size", 12)
	vb.add_child(subtitle)
	vb.add_child(UITheme.styled_separator())

	_rows_box = VBoxContainer.new()
	_rows_box.add_theme_constant_override("separation", 6)
	vb.add_child(_rows_box)

	_empty_label = Label.new()
	_empty_label.text = "No willing trade partners discovered yet -- go scout."
	_empty_label.add_theme_color_override("font_color", UITheme.TEXT_MUTED)
	_empty_label.visible = false
	vb.add_child(_empty_label)

	vb.add_child(UITheme.styled_separator())

	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 10)
	vb.add_child(footer)

	var amt_lbl_tag := Label.new()
	amt_lbl_tag.text = "Offer amount:"
	amt_lbl_tag.add_theme_color_override("font_color", UITheme.TEXT_PRIMARY)
	footer.add_child(amt_lbl_tag)

	var minus_btn := Button.new()
	minus_btn.text = "-"
	minus_btn.custom_minimum_size = Vector2(30, 28)
	UITheme.style_button(minus_btn, UITheme.ACCENT_GOLD)
	minus_btn.pressed.connect(func(): _change_offer(-1))
	footer.add_child(minus_btn)

	_amt_label = Label.new()
	_amt_label.text = str(_offer_amt)
	_amt_label.add_theme_color_override("font_color", UITheme.ACCENT_GOLD)
	_amt_label.custom_minimum_size = Vector2(24, 28)
	_amt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	footer.add_child(_amt_label)

	var plus_btn := Button.new()
	plus_btn.text = "+"
	plus_btn.custom_minimum_size = Vector2(30, 28)
	UITheme.style_button(plus_btn, UITheme.ACCENT_GOLD)
	plus_btn.pressed.connect(func(): _change_offer(1))
	footer.add_child(plus_btn)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(spacer)

	var close_btn := Button.new()
	close_btn.text = "Close (T)"
	close_btn.custom_minimum_size = Vector2(100, 28)
	UITheme.style_button(close_btn, UITheme.ACCENT_RED)
	close_btn.pressed.connect(close_menu)
	footer.add_child(close_btn)

func _change_offer(delta: int) -> void:
	_offer_amt = clampi(_offer_amt + delta, 1, 99)
	if _amt_label:
		_amt_label.text = str(_offer_amt)
	_refresh_rows()

func toggle_menu() -> void:
	if open:
		close_menu()
	else:
		open_menu()

func open_menu() -> void:
	if manager == null or not is_instance_valid(manager):
		manager = get_tree().get_first_node_in_group("tribe_manager")
	if manager == null or _panel == null:
		return
	open = true
	_panel.visible = true
	_refresh_rows()

func close_menu() -> void:
	open = false
	if _panel:
		_panel.visible = false

func _refresh_rows() -> void:
	if _rows_box == null:
		return
	for c in _rows_box.get_children():
		c.queue_free()
	if manager == null:
		return
	# GATED ON THE BUILDING (2026-07-19): "allow trading post to be built
	# before its used" -- no partner list, no proposing, until one actually
	# stands. The menu itself is the clearest place to say so and point at
	# the fix, rather than silently doing nothing when 9 gets pressed.
	if manager.has_method("trading_post_built") and not manager.trading_post_built():
		_empty_label.visible = true
		_empty_label.text = "No trading post yet -- press [9] near camp to raise one (%d wood, %d materials)." % [
			manager.TRADING_POST_COST_WOOD, manager.TRADING_POST_COST_MATERIALS]
		return
	if not manager.has_method("trade_partners"):
		return
	var partners: Array = manager.trade_partners()
	_empty_label.visible = partners.is_empty()
	_empty_label.text = "No willing trade partners discovered yet -- go scout."
	for p in partners:
		_rows_box.add_child(_build_row(p))

func _build_row(p: Dictionary) -> Control:
	var card := PanelContainer.new()
	UITheme.style_panel(card, UITheme.ACCENT_BLUE, UITheme.BG_ELEVATED)

	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 10)
	card.add_child(hb)

	var name_col := VBoxContainer.new()
	name_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(name_col)

	var name_lbl := Label.new()
	name_lbl.text = str(p.get("tribe_name", "?"))
	name_lbl.add_theme_color_override("font_color", UITheme.TEXT_PRIMARY)
	name_lbl.add_theme_font_size_override("font_size", 16)
	name_col.add_child(name_lbl)

	var detail_lbl := Label.new()
	detail_lbl.text = "%d %s to spare" % [int(p.get("surplus", 0)), str(p.get("material", "goods"))]
	detail_lbl.add_theme_color_override("font_color", UITheme.TEXT_MUTED)
	detail_lbl.add_theme_font_size_override("font_size", 12)
	name_col.add_child(detail_lbl)

	var opinion: float = float(p.get("player_opinion", 0.0))
	var stance_text: String = "friendly" if opinion > 0.15 else ("wary" if opinion > -0.3 else "hostile")
	hb.add_child(UITheme.pill(stance_text, UITheme.sentiment_color(opinion)))

	var rivalry: float = float(p.get("rivalry", 0.0))
	if rivalry > 0.01:
		hb.add_child(UITheme.pill("feud %.0f%%" % (rivalry * 100.0), UITheme.ACCENT_RED))

	var btn := Button.new()
	btn.text = "Propose (%d)" % _offer_amt
	btn.custom_minimum_size = Vector2(110, 30)
	UITheme.style_button(btn, UITheme.ACCENT_SAGE)
	var tribe_ref: Node = p.get("tribe")
	btn.pressed.connect(func(): _propose(tribe_ref))
	hb.add_child(btn)
	return card

func _propose(tribe: Node) -> void:
	if manager and manager.has_method("propose_trade_with"):
		manager.propose_trade_with(tribe, _offer_amt)
	_refresh_rows()

func _unhandled_input(event: InputEvent) -> void:
	if not open:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_T or event.keycode == KEY_ESCAPE:
			close_menu()
			get_viewport().set_input_as_handled()
