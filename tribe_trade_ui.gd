extends Node
# ─────────────────────────────────────────────────────────────────────────────
# TribeTradeUI — INCOMING trade requests to the PLAYER, with an accept/decline
# prompt. Autoload singleton: TribeTradeUI (mirrors TribeChat's shape).
#
# NPC tribes occasionally send a caravan to the player's camp offering their
# worked material for some of the player's food (see Tribemanager's incoming
# request tick + trade_envoy.gd's to_is_player mode). When such a caravan
# ARRIVES, the manager calls request_from(...) here; we pop a panel on the LEFT
# of the screen: "The Frostpack offer 3 Bone for 12 of your food." with
# Accept (Y) and Decline (N) — both clickable buttons AND the Y/N keys.
#
# The economy math + the return "acceptance courier" live on the manager (single
# source of truth, like every other trade path). This node only owns the QUEUE
# and the PANEL, and calls back into the manager on the player's choice.
#
# INPUT GATING (same subtlety as TribeChat): FPSPlayer/Tribemanager read raw keys
# every frame, so Y would raise a fence and N would do nothing useful. `open` is
# checked by FPSPlayer before it consumes ANY input while a request is showing.
# ─────────────────────────────────────────────────────────────────────────────

var open: bool = false             # FPSPlayer/Tribemanager check this before reading input

var _panel: PanelContainer = null
var _title: RichTextLabel = null
var _body: RichTextLabel = null
var _accept_btn: Button = null
var _decline_btn: Button = null

# Each request: { "tribe": Node, "tribe_name": String, "material": String,
#                 "amount": int, "food": int }. Queued so a flurry of arrivals is
# shown one at a time and none is lost.
var _queue: Array = []
var _current: Dictionary = {}

const UITheme = preload("res://ui_theme.gd")

func _ready() -> void:
	call_deferred("_build_ui")     # wait for the "UI" CanvasLayer to exist
	set_process_unhandled_input(true)

func _build_ui() -> void:
	var ui := get_tree().root.find_child("UI", true, false)
	if ui == null:
		push_warning("TribeTradeUI: no UI CanvasLayer found -- incoming trade prompts disabled")
		return
	_panel = PanelContainer.new()
	_panel.name = "TradeRequestPanel"
	# LEFT side, vertically centred — deliberately clear of the top-centre flash
	# banner and the bottom-left chat log.
	_panel.set_anchors_preset(Control.PRESET_CENTER_LEFT)
	_panel.position = Vector2(16, -90)
	_panel.custom_minimum_size = Vector2(360, 170)
	_panel.visible = false
	# VISUAL PASS (2026-07-19): onto the shared campfire palette (ui_theme.gd)
	# so this reads as the SAME game as the trade menu/overview, not a
	# differently-styled one-off panel.
	UITheme.style_panel(_panel, UITheme.ACCENT_GOLD)
	ui.add_child(_panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	_panel.add_child(vb)

	_title = RichTextLabel.new()
	_title.bbcode_enabled = true
	_title.fit_content = true
	_title.custom_minimum_size = Vector2(332, 24)
	_title.add_theme_color_override("default_color", UITheme.ACCENT_GOLD)
	vb.add_child(_title)

	_body = RichTextLabel.new()
	_body.bbcode_enabled = true
	_body.fit_content = true
	_body.custom_minimum_size = Vector2(332, 64)
	_body.add_theme_color_override("default_color", UITheme.TEXT_PRIMARY)
	vb.add_child(_body)

	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 12)
	vb.add_child(hb)

	_accept_btn = Button.new()
	_accept_btn.text = "Accept (Y)"
	_accept_btn.custom_minimum_size = Vector2(158, 34)
	UITheme.style_button(_accept_btn, UITheme.ACCENT_SAGE)
	_accept_btn.pressed.connect(_accept)
	hb.add_child(_accept_btn)

	_decline_btn = Button.new()
	_decline_btn.text = "Decline (N)"
	_decline_btn.custom_minimum_size = Vector2(158, 34)
	UITheme.style_button(_decline_btn, UITheme.ACCENT_RED)
	_decline_btn.pressed.connect(_decline)
	hb.add_child(_decline_btn)

# Called by Tribemanager when an incoming caravan reaches the player's camp.
# Enqueues the offer and shows it (or leaves it queued behind the current one).
func request_from(tribe: Node, offer_material: String, offer_amount: int, want_food_amount: int) -> void:
	if not is_instance_valid(tribe):
		return
	var req: Dictionary = {
		"tribe": tribe,
		"tribe_name": str(tribe.tribe_name),
		"material": offer_material,
		"amount": offer_amount,
		"food": want_food_amount,
	}
	_queue.append(req)
	if not open:
		_show_next()

# True if this tribe already has a request showing or waiting — the dispatch tick
# uses it so one tribe can't spam the player with parallel offers.
func has_request_from(tribe_name: String) -> bool:
	if not _current.is_empty() and str(_current.get("tribe_name", "")) == tribe_name:
		return true
	for r in _queue:
		if str(r.get("tribe_name", "")) == tribe_name:
			return true
	return false

func _show_next() -> void:
	if _panel == null:
		_queue.clear()
		return
	if _queue.is_empty():
		_close()
		return
	_current = _queue.pop_front()
	# skip a request whose tribe died while it waited in the queue
	var tribe = _current.get("tribe")
	if not is_instance_valid(tribe) or tribe.defeated:
		_current = {}
		_show_next()
		return
	var tname: String = str(_current["tribe_name"])
	var amount: int = int(_current["amount"])
	var material: String = str(_current["material"])
	var want_food: int = int(_current["food"])
	_title.text = "[b]— The %s send an envoy —[/b]" % tname
	_body.text = "They offer [color=#ffd27f]%d %s[/color] for [color=#9fe3ff]%d of your food[/color].\n[i]Accept (Y)   ·   Decline (N)[/i]" % [
		amount, material, want_food]
	open = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE   # let the player actually click
	_panel.visible = true
	if _accept_btn != null:
		_accept_btn.grab_focus()

func _unhandled_input(event: InputEvent) -> void:
	if not open:
		return
	if not (event is InputEventKey and event.pressed):
		return
	var kc: int = (event as InputEventKey).keycode
	if kc == KEY_Y:
		_accept()
		get_viewport().set_input_as_handled()
	elif kc == KEY_N or kc == KEY_ESCAPE:
		_decline()
		get_viewport().set_input_as_handled()

func _accept() -> void:
	if _current.is_empty():
		return
	var tribe = _current.get("tribe")
	var mgr := _manager()
	if mgr == null or not is_instance_valid(tribe) or tribe.defeated:
		_advance()
		return
	# The manager owns the economy math and affordability ruling. It returns false
	# when the player can't spare the food; in that case it flashes "can't spare"
	# and we treat this as a decline (no exchange, request dropped).
	var ok: bool = mgr.accept_trade_request(
		tribe, str(_current["material"]), int(_current["amount"]), int(_current["food"]))
	if not ok:
		# affordability failure already flashed by the manager
		pass
	_advance()

func _decline() -> void:
	if _current.is_empty():
		_advance()
		return
	var tribe = _current.get("tribe")
	var mgr := _manager()
	if mgr != null and is_instance_valid(tribe) and mgr.has_method("decline_trade_request"):
		mgr.decline_trade_request(tribe)
	_advance()

# Drop the current request and show the next queued one, or close if none remain.
func _advance() -> void:
	_current = {}
	if _queue.is_empty():
		_close()
	else:
		_show_next()

func _close() -> void:
	open = false
	_current = {}
	if _panel != null:
		_panel.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _manager() -> Node:
	return get_tree().get_first_node_in_group("tribe_manager")
