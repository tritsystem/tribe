extends Node
# Headless test for TribeMemory's coalesce-through-interleaved-entry fix. Run:
#   Godot_v4.7-stable_win64_console.exe --headless --path . res://test_memory_coalesce.tscn --quit
#
# Reproduces the exact live bug: _update_rank() writes a "bond" memory on every
# Follow-fire, and rapid feeding fires Follow repeatedly -- so a bond memory
# routinely lands BETWEEN two fed events. The old coalesce check only looked at
# arr[-1] (the literal last entry); with a bond wedged in, type mismatch, no
# coalesce. Caught live: 4 real feeds in 4 seconds became 4 separate memories,
# flooding context_for()'s pool with redundant food content.

var _pass := 0
var _fail := 0

func _ready() -> void:
	print("=" .repeat(60))
	print("  TRIBEMEMORY COALESCE -- interleaved-entry regression test")
	print("=" .repeat(60))

	# scenario A: the real bug -- fed, bond, fed, fed, bond, fed (4 feeds, 2 bonds)
	TribeMemory._mem.clear()
	TribeMemory._pending.clear()
	TribeMemory.remember("Bo", "fed", "You", "You gave me food (1 time now).", "grateful", 0.15)
	TribeMemory.remember("Bo", "bond", "You", "My feeling toward you deepened to Friend.", "warm", 0.25)
	TribeMemory.remember("Bo", "fed", "You", "You gave me food (2 times now).", "grateful", 0.15)
	TribeMemory.remember("Bo", "fed", "You", "You gave me food (3 times now).", "grateful", 0.15)
	TribeMemory.remember("Bo", "bond", "You", "My feeling toward you deepened to Loyal.", "warm", 0.25)
	TribeMemory.remember("Bo", "fed", "You", "You gave me food (4 times now).", "grateful", 0.15)

	var mem: Array = TribeMemory._mem.get("Bo", [])
	var fed_count := 0
	var bond_count := 0
	for m in mem:
		if m["type"] == "fed":
			fed_count += 1
		elif m["type"] == "bond":
			bond_count += 1

	_check("4 interleaved feeds coalesce into ONE fed memory (not 4)", fed_count == 1)
	# the 2 bond entries ALSO coalesce with each other -- same type+target,
	# still fresh, same rule as feeds. Coalescing is scoped by TYPE, not by
	# "which specific event pair I'm reasoning about": a bond-rank-change
	# doesn't stay a separate incident just because it's not the type
	# currently being fed-tested. Total ends up 2 (1 fed + 1 bond), not 3.
	_check("the 2 bond memories ALSO coalesce with each other (same type+target rule)",
		bond_count == 1)
	_check("total memory count is 2 (1 coalesced fed + 1 coalesced bond), not 6",
		mem.size() == 2)

	if fed_count == 1:
		var fed_entry: Dictionary = {}
		for m in mem:
			if m["type"] == "fed":
				fed_entry = m
		var expected_trust: float = 0.15 * 4
		_check("trust_change ACCUMULATED across all 4 coalesced feeds (%.2f == %.2f)" % [
			float(fed_entry.get("trust_change", -1.0)), expected_trust],
			absf(float(fed_entry.get("trust_change", -1.0)) - expected_trust) < 0.001)
		_check("summary reflects the LATEST feed, not the first",
			str(fed_entry.get("summary", "")) == "You gave me food (4 times now).")

	# scenario B: coalescing must still respect COALESCE_WINDOW -- an old entry
	# far enough back must NOT be silently merged into forever
	TribeMemory._mem.clear()
	TribeMemory._pending.clear()
	var old_entry := {
		"t": (Time.get_ticks_msec() / 1000.0) - 999.0, "stamp": "old", "type": "fed",
		"target": "You", "summary": "ancient feed", "emotion": "grateful", "trust_change": 0.15,
	}
	TribeMemory._mem["Ka"] = [old_entry]
	TribeMemory._pending["Ka"] = []
	TribeMemory.remember("Ka", "fed", "You", "You gave me food (1 time now).", "grateful", 0.15)
	var ka_mem: Array = TribeMemory._mem.get("Ka", [])
	_check("an entry older than COALESCE_WINDOW does NOT coalesce (stays 2 entries)",
		ka_mem.size() == 2)

	# scenario C: TARGET scoping must hold even with many interleaved entries.
	# Sef getting fed by "You" and separately talking about a DIFFERENT target
	# ("Ka") many times in a row must never let the fed memory accidentally
	# coalesce into (or be overwritten by) the unrelated Ka-directed chatter,
	# no matter how many of those sit in between within the same time window.
	TribeMemory._mem.clear()
	TribeMemory._pending.clear()
	TribeMemory.remember("Sef", "fed", "You", "feed 1", "grateful", 0.1)
	TribeMemory.remember("Sef", "talked", "Ka", "t1", "neutral", 0.02)
	TribeMemory.remember("Sef", "talked", "Ka", "t2", "neutral", 0.02)
	TribeMemory.remember("Sef", "talked", "Ka", "t3", "neutral", 0.02)
	TribeMemory.remember("Sef", "talked", "Ka", "t4", "neutral", 0.02)
	TribeMemory.remember("Sef", "talked", "Ka", "t5", "neutral", 0.02)
	TribeMemory.remember("Sef", "fed", "You", "feed 2", "grateful", 0.1)
	var sef_mem: Array = TribeMemory._mem.get("Sef", [])
	var sef_fed_count := 0
	var sef_talked_ka_count := 0
	for m in sef_mem:
		if m["type"] == "fed" and m["target"] == "You":
			sef_fed_count += 1
		elif m["type"] == "talked" and m["target"] == "Ka":
			sef_talked_ka_count += 1
	_check("the two 'fed'-about-You entries still coalesce into one, despite "
		+ "5 unrelated Ka-directed memories sitting in between",
		sef_fed_count == 1)
	_check("the 5 Ka-directed memories coalesce into their OWN one entry, "
		+ "never merged with the fed-about-You entries (target scoping holds)",
		sef_talked_ka_count == 1)
	_check("total is 2 (1 fed-about-You + 1 talked-about-Ka), not 7 and not 1",
		sef_mem.size() == 2)

	print("\n" + "-".repeat(42))
	print("  %d passed, %d FAILED" % [_pass, _fail])
	print("-".repeat(42) + "\n")
	get_tree().quit(1 if _fail > 0 else 0)

func _check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  ok    %s" % label)
	else:
		_fail += 1
		print("  FAIL  %s" % label)
