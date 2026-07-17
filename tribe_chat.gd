extends Node
# ─────────────────────────────────────────────────────────────────────────────
# TribeChat — talk to your tribe in plain language; they answer FROM memory.
# Autoload singleton: TribeChat
#
# Press [T] to talk to the nearest member. Type, Enter to send, Esc to close.
# Their reply is generated from what they ACTUALLY remember about you (feeds,
# rank shifts, past conversations) plus their personality and standing -- and
# the exchange is itself written back to memory, so what you say to Ka today is
# something Ka can bring up with Ru tomorrow.
#
# INPUT GATING (this is the subtle part): FPSPlayer reads raw keys
# (Input.is_key_pressed(KEY_W)) and raw mouse motion every frame. Without a gate,
# typing "we should hunt" would walk you across camp and swing your club. So
# `open` is checked by FPSPlayer before it consumes ANY input.
# ─────────────────────────────────────────────────────────────────────────────

const TALK_RANGE := 8.0        # how close you must be to address someone
const HOLD := 6.0              # seconds their reply stays above their head
const LOG_LINES := 8

var open := false              # FPSPlayer checks this before reading input

var _panel: PanelContainer
var _log: RichTextLabel
var _entry: LineEdit
var _target: Node = null       # who we're addressing (null while _broadcast)
var _broadcast := false         # TAB'd past the last member -> talk to everyone
var _history: Array[String] = []

func _ready() -> void:
	TribeLLM.line_ready.connect(_on_line)
	call_deferred("_build_ui")     # wait for the scene tree to exist
	set_process_unhandled_input(true)

func _build_ui() -> void:
	var ui := get_tree().root.find_child("UI", true, false)
	if ui == null:
		push_warning("TribeChat: no UI CanvasLayer found -- chat disabled")
		return
	_panel = PanelContainer.new()
	_panel.name = "ChatPanel"
	_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_panel.position = Vector2(16, -260)
	_panel.custom_minimum_size = Vector2(600, 240)
	_panel.visible = false

	# AN OPAQUE BACKGROUND. PanelContainer's default theme is near-transparent, so
	# the HUD behind it (trust %, hunger, the [1]gather [2]hunt hints) rendered
	# straight through the dialogue and both became unreadable. A conversation
	# window has to be a surface, not a sheet of glass laid over the game.
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.07, 0.09, 0.62)   # more transparent — see the world behind
	sb.border_color = Color(0.45, 0.40, 0.30, 0.9)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	_panel.add_theme_stylebox_override("panel", sb)
	ui.add_child(_panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	_panel.add_child(vb)

	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.custom_minimum_size = Vector2(576, 176)
	_log.scroll_following = true
	# the log sits ON the panel, so it must not paint its own backdrop
	_log.add_theme_color_override("default_color", Color(0.90, 0.89, 0.86))
	vb.add_child(_log)

	_entry = LineEdit.new()
	_entry.placeholder_text = "say something…  (Enter to send, Esc to close)"
	_entry.custom_minimum_size = Vector2(576, 32)
	var eb := StyleBoxFlat.new()
	eb.bg_color = Color(0.02, 0.02, 0.03, 0.78)
	eb.border_color = Color(0.35, 0.32, 0.26, 0.9)
	eb.set_border_width_all(1)
	eb.set_corner_radius_all(4)
	eb.content_margin_left = 8
	eb.content_margin_right = 8
	_entry.add_theme_stylebox_override("normal", eb)
	_entry.add_theme_stylebox_override("focus", eb)
	_entry.text_submitted.connect(_on_submit)
	vb.add_child(_entry)

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed):
		return
	if not open and event.keycode == KEY_T:
		_open_chat()
		get_viewport().set_input_as_handled()
	elif open and event.keycode == KEY_ESCAPE:
		_close_chat()
		get_viewport().set_input_as_handled()
	elif open and event.keycode == KEY_TAB:
		# TAB cycles who you're addressing: each nearby member in turn, then an
		# EVERYONE slot that broadcasts to the whole cluster. This is the answer
		# to "switch who I'm talking to while chat is open / talk to everyone" --
		# you no longer have to close and reopen next to a different person.
		_cycle_target()
		get_viewport().set_input_as_handled()

func _open_chat() -> void:
	if _panel == null:
		return
	_broadcast = false
	_target = _nearest_member()
	if _target == null:
		return
	open = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE   # let them actually click/type
	_panel.visible = true
	_entry.grab_focus()
	_push(_header())

func _header() -> String:
	if _broadcast:
		var n := _nearby_members().size()
		return "[i][color=#9cf]— speaking to EVERYONE nearby (%d) —  [TAB] switch[/color][/i]" % n
	if _target == null or not is_instance_valid(_target):
		return "[i]— no one in range —[/i]"
	return "[i]— talking to %s (%s, %s)  —  [TAB] switch —[/i]" % [
		_target.get("member_name"), _target.get("personality"), _target.get("current_rank")]

## TAB steps through each nearby member, then a broadcast slot, then wraps.
func _cycle_target() -> void:
	var near := _nearby_members()
	if near.is_empty():
		_broadcast = false
		_target = null
		_push(_header())
		return
	if _broadcast:
		# was on EVERYONE -> wrap back to the first member
		_broadcast = false
		_target = near[0]
	else:
		var idx := -1
		for i in range(near.size()):
			if near[i] == _target:
				idx = i
				break
		if idx + 1 < near.size():
			_target = near[idx + 1]         # next member
		else:
			_broadcast = true               # past the last -> EVERYONE
			_target = null
	_push(_header())

func _close_chat() -> void:
	open = false
	if _panel:
		_panel.visible = false
	_entry.text = ""
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_target = null
	_broadcast = false

## All members within talking range, nearest first -- the set TAB cycles through.
func _nearby_members() -> Array:
	var p := get_tree().get_first_node_in_group("player") as Node3D
	if p == null:
		return []
	var out: Array = []
	for m in get_tree().get_nodes_in_group("tribe"):
		if not (m.has_method("_think") and "member_name" in m):
			continue          # group "tribe" also holds dogs
		if p.global_position.distance_to((m as Node3D).global_position) <= TALK_RANGE:
			out.append(m)
	out.sort_custom(func(a, b):
		return p.global_position.distance_to((a as Node3D).global_position) \
			< p.global_position.distance_to((b as Node3D).global_position))
	return out

func _nearest_member() -> Node:
	var near := _nearby_members()
	return near[0] if not near.is_empty() else null

func _on_submit(text: String) -> void:
	text = text.strip_edges()
	_entry.text = ""
	if text == "":
		return

	# ORDERS FIRST, whoever you're addressing. "Ka, go get berries" must not be
	# fed to the LLM as small talk, nor classified as a rumour. TribeCommand
	# writes its own memories for whoever it reaches. This runs the same in
	# broadcast mode -- "everyone come here" is an order either way.
	if TribeCommand.try_execute(text, "chat"):
		_push("[color=#7fd]You:[/color] %s" % text)
		_push("[i][color=#8f8]— order given —[/color][/i]")
		return

	# BROADCAST: say it to the whole nearby cluster, each answers in turn. This is
	# the "talk to everyone" path -- one line, many replies, staggered so they
	# don't all speak on the same frame.
	if _broadcast:
		_push("[color=#7fd]You (to all):[/color] %s" % text)
		var near := _nearby_members()
		if near.is_empty():
			_push("[i]— no one close enough to hear —[/i]")
			return
		for i in range(near.size()):
			_say_to(near[i], text, float(i) * 0.5)
		return

	if _target == null or not is_instance_valid(_target):
		_push("[i]— no one in range (TAB to pick someone) —[/i]")
		return
	_push("[color=#7fd]You:[/color] %s" % text)
	_say_to(_target, text, 0.0)

## Send one line to one member: they remember it, it may seed a rumour, and they
## reply via the LLM. Shared by the single-target and broadcast paths so the two
## can't drift apart. `delay` staggers broadcast replies off the same frame.
func _say_to(member: Node, text: String, delay: float) -> void:
	if member == null or not is_instance_valid(member):
		return
	# NOT `name` -- that shadows Node.name and would silently bite later
	var npc_name: String = str(member.get("member_name"))

	# THEY REMEMBER WHAT YOU SAID -- this is the whole point. It lands in their
	# vault note and can surface in a later conversation with someone else.
	TribeMemory.remember(npc_name, "heard", "You", "You said to me: \"%s\"" % text, "neutral", 0.03)

	# INFORMATION AS A WEAPON: if what you said is ABOUT someone and carries a
	# charge, it becomes a rumour this member can carry into the gossip network.
	# In broadcast this only plants once (on the first hearer) to avoid seeding
	# the same rumour N times from one sentence.
	if delay <= 0.0:
		var roster: Array = TribeTalk.roster_names()
		var c: Dictionary = TribeRumor.classify(text, roster)
		if str(c["subject"]) != "" and float(c["sentiment"]) != 0.0:
			TribeRumor.plant(text, str(c["subject"]), float(c["sentiment"]), "You", npc_name)
			_push("[i][color=#f88]— %s takes that in… —[/color][/i]" % npc_name)

	if delay > 0.0:
		await get_tree().create_timer(delay).timeout
		if not is_instance_valid(member):
			return

	var brain_text: String = str(member.call("brain_snapshot")) if member.has_method("brain_snapshot") else ""
	var persona: String = "%s Your standing with the leader is '%s'. %s" % [
		_flavour(str(member.get("personality"))), str(member.get("current_rank")), brain_text]
	# Answering the LEADER directly gets an extra guard the model needs (see the
	# tribe_llm hallucination notes): don't claim a memory you weren't given, and
	# answer trust questions from actual standing.
	var guard := " Do not claim to remember a past conversation unless it is in " \
		+ "your memories above. Answer from your CURRENT feelings; your standing " \
		+ "is '%s', so let it decide how much you trust the Leader." % str(member.get("current_rank"))
	TribeLLM.say_as(npc_name, "You", persona,
		TribeMemory.context_for(npc_name, "You"),
		"Your leader just said to you: \"%s\". Answer them directly.%s" % [text, guard],
		_fallback(str(member.get("personality"))), "player", TribeTalk.roster_string())

func _flavour(p: String) -> String:
	var f: Dictionary = {
		"Steady": "You are level-headed and plain-spoken.",
		"Trusting": "You are warm and quick to believe the best of people.",
		"Wary": "You are suspicious and slow to trust; you hedge.",
		"Brave": "You are bold and blunt, keen for a fight.",
		"Greedy": "You care about food and what you're owed.",
	}
	return str(f.get(p, "You are level-headed."))

func _fallback(p: String) -> String:
	var f: Dictionary = {
		"Steady": "Aye, I hear you.",
		"Trusting": "Whatever you say, friend.",
		"Wary": "…if you say so.",
		"Brave": "Say the word and it's done.",
		"Greedy": "And what's in it for me?",
	}
	return str(f.get(p, "Mm."))

func _on_line(speaker: String, listener: String, text: String, tag: String) -> void:
	if tag != "player":        # NPC<->NPC chatter is TribeTalk's business, not ours
		return
	_push("[color=#fd7]%s:[/color] %s" % [speaker, text])
	if _target != null and is_instance_valid(_target) and str(_target.get("member_name")) == speaker:
		# force: you asked THIS member a direct question and are stood in front of
		# them. Their answer interrupts idle camp chatter rather than being dropped
		# because someone across the fire happened to be mid-sentence.
		_target.say(text, HOLD, true)   # above their head, and out loud
	# and they remember answering you
	TribeMemory.remember(speaker, "talked", "You", "I told you: \"%s\"" % text, "neutral", 0.02)

func _push(line: String) -> void:
	_history.append(line)
	while _history.size() > LOG_LINES:
		_history.pop_front()
	if _log:
		_log.text = "\n".join(_history)
