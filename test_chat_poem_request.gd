extends Node
# Headless test for the poem-request routing fix. Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path . res://test_chat_poem_request.tscn --quit
#
# BUG (caught live): asking a Companion "tell me a poem" in chat got a
# single ordinary sentence ACKNOWLEDGING the request ("I'll share a simple
# poem...") instead of an actual poem -- because EVERY player chat line went
# through _say_to()'s say_as() path, whose own prompt hard-caps replies at
# "ONE short spoken line (max 20 words)", structurally incapable of verse.
# Fixed by detecting a real poem/song request and routing it to
# TribeLLM.compose_as() (the same multi-line-capable call TribePoetry's own
# autonomous composition uses) instead.

const SpatialGrid = preload("res://spatial_grid.gd")

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=".repeat(60))
	print("  CHAT POEM REQUEST -- routes to compose_as(), not say_as()")
	print("=".repeat(60))
	TribeMemory._mem.clear()
	TribeMemory._pending.clear()

	# scenario A: _looks_like_poem_request() recognizes real asks, including
	# the exact phrase from the live bug report
	_check("'tell me a poem' is recognized as a poem request",
		TribeChat._looks_like_poem_request("tell me a poem"))
	_check("'sing me a song' is recognized as a poem request",
		TribeChat._looks_like_poem_request("sing me a song"))
	_check("an unrelated line is NOT misclassified as a poem request",
		not TribeChat._looks_like_poem_request("go hunt some meat"))
	_check("a normal greeting is NOT misclassified as a poem request",
		not TribeChat._looks_like_poem_request("how are you feeling today"))

	# scenario B: asking a member for a poem in chat actually produces a
	# composed memory (routed through compose_as()/TribePoetry's fallback,
	# since Ollama isn't warm in a headless test), not an ordinary "talked"
	# one-line chat reply.
	var m := _spawn_member("Bo")
	m.personality = "Trusting"
	m.current_rank = "Devoted"
	TribeChat._say_to(m, "tell me a poem", 0.0)
	_check("asking for a poem in chat writes a real 'composed' memory",
		_has_memory_type("Bo", "composed"))
	_check("...and does NOT write an ordinary 'talked' one-line-reply memory for this line",
		not _has_memory_of_text("Bo", "talked", "tell me a poem"))

	# scenario C: an ordinary chat line still goes through the normal
	# say_as()/"talked" path, unaffected by the new routing
	TribeMemory._mem.clear()
	var m2 := _spawn_member("Ka")
	TribeChat._say_to(m2, "how is the hunting today", 0.0)
	_check("an ordinary chat line still produces a normal 'talked' reply memory",
		_has_memory_type("Ka", "talked"))
	_check("...and does NOT write a 'composed' memory for ordinary chat",
		not _has_memory_type("Ka", "composed"))

	m.free(); m2.free()

	print("\n" + "-".repeat(42))
	print("  %d passed, %d FAILED" % [_pass, _fail])
	print("-".repeat(42) + "\n")
	get_tree().quit(1 if _fail > 0 else 0)

func _has_memory_type(agent: String, event_type: String) -> bool:
	for mem in TribeMemory._mem.get(agent, []):
		if mem["type"] == event_type:
			return true
	return false

func _has_memory_of_text(agent: String, event_type: String, needle: String) -> bool:
	for mem in TribeMemory._mem.get(agent, []):
		if mem["type"] == event_type and needle in str(mem.get("summary", mem.get("text", ""))):
			return true
	return false

func _spawn_member(name_: String) -> Node3D:
	var m := CharacterBody3D.new()
	m.set_script(load("res://tribemember.gd"))
	add_child(m)
	m.member_name = name_
	SpatialGrid.update(m)
	return m

func _check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  ok    %s" % label)
	else:
		_fail += 1
		print("  FAIL  %s" % label)
