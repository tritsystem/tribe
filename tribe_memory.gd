extends Node
# ─────────────────────────────────────────────────────────────────────────────
# TribeMemory — persistent, per-NPC memory written as Obsidian-readable markdown.
# Autoload singleton: TribeMemory
#
# WHY FILE-BASED, NOT THE OBSIDIAN REST API:
#   An Obsidian vault IS just a folder of markdown files. Writing them directly
#   means: no plugin to install, no HTTP server to be running, no auth key, and
#   the memories exist even with Obsidian closed. The REST API would add a hard
#   dependency and a failure mode while buying nothing. Point Obsidian at
#   VAULT_DIR ("Open folder as vault") and the notes are just there.
#
# PERFORMANCE (this codebase has a framerate budget -- see graphics_quality.gd):
#   Memories live in RAM and are flushed to disk on a timer, never per-event
#   mid-frame. One append-only .md file per NPC, not a file per memory.
# ─────────────────────────────────────────────────────────────────────────────

const VAULT_DIR := "user://TribeVault"     # Obsidian: "Open folder as vault" -> this path
const NPC_DIR := VAULT_DIR + "/NPCs"
const EVENT_DIR := VAULT_DIR + "/Events"
const FLUSH_INTERVAL := 6.0                # seconds; batched so we never hitch a frame
const MAX_RAM_MEMORIES := 40               # per NPC; oldest trimmed (disk keeps everything)
# COALESCE_WINDOW: repeats of the SAME event type about the SAME target inside this
# window update the existing memory instead of appending a near-duplicate.
# Found by RUNNING it, not by reasoning: holding [E] wrote 16 near-identical
# "you gave me food" memories in 11 seconds, and a decaying bond flapping across a
# rank threshold wrote "deepened/cooled/deepened" in 68s. Both would crowd every
# meaningful memory out of an LLM prompt -- an NPC reciting a receipt, not remembering.
# Coalescing keeps the SETTLED truth ("you fed me 16 times", "we ended at Friend").
const COALESCE_WINDOW := 30.0

# npc_name -> Array[Dictionary]  (the live, queryable memory)
var _mem: Dictionary = {}
# npc_name -> Array[String]      (markdown lines not yet written to disk)
var _pending: Dictionary = {}
var _flush_cd: float = FLUSH_INTERVAL

func _ready() -> void:
	for d in [VAULT_DIR, NPC_DIR, EVENT_DIR]:
		DirAccess.make_dir_recursive_absolute(d)   # user:// is handled directly
	_write_readme()
	set_process(true)

func _process(delta: float) -> void:
	_flush_cd -= delta
	if _flush_cd <= 0.0:
		_flush_cd = FLUSH_INTERVAL
		flush()

# ── recording ───────────────────────────────────────────────────────────────

## Record one memory for `agent`. `emotion` and `trust_change` are what make a
## memory *felt* rather than just logged -- they're what later conversations and
## opinion shifts read back.
func remember(agent: String, event_type: String, target: String, summary: String,
		emotion: String = "neutral", trust_change: float = 0.0) -> void:
	if agent == "":
		return
	var m := {
		"t": Time.get_ticks_msec() / 1000.0,
		"stamp": Time.get_datetime_string_from_system(),
		"type": event_type,      # met / fed / helped / attacked / witnessed / told / gossip
		"target": target,
		"summary": summary,
		"emotion": emotion,      # warm / wary / angry / afraid / grateful / betrayed
		"trust_change": trust_change,
	}
	if not _mem.has(agent):
		_mem[agent] = []
		_pending[agent] = []
	var arr: Array = _mem[agent]
	var pend: Array = _pending[agent]
	# COALESCE (see COALESCE_WINDOW): if a RECENT memory is the same kind of
	# thing about the same target and still fresh, fold this into it rather than
	# stacking a near-duplicate. trust_change ACCUMULATES (16 feeds really did
	# move trust 16 times) but it stays ONE remembered event, which is how a
	# person would hold it: "you kept feeding me", not 16 separate incidents.
	#
	# BUG FIXED (2026-07-17): this used to only check arr[-1], the LITERAL last
	# entry. But _update_rank() writes a "bond" memory on every Follow-fire --
	# and rapid feeding fires Follow repeatedly -- so a bond entry routinely
	# lands BETWEEN two fed events. arr[-1] was then "bond", type mismatch, so
	# each feed in a burst became its own separate memory instead of coalescing.
	# Caught live: 4 real feeds in 4 seconds produced 4 separate "fed" memories,
	# flooding context_for()'s candidate pool with redundant food content and
	# crowding out everything else -- three different chat questions all got
	# food-themed replies because food genuinely was ALL of the recent memory.
	#
	# Fixed by scanning backward for the most recent SAME-type+target entry,
	# bounded ONLY by COALESCE_WINDOW (time), not by array distance. A first
	# attempt bounded the scan by a fixed number of array steps instead, and
	# this test file caught why that's wrong: coalescing COMPACTS the array (5
	# interleaved bond events collapse into 1 slot as they coalesce with each
	# other), so a small step-count bound doesn't actually correspond to "how
	# much unrelated stuff happened" once compaction is in play -- it let the
	# scan reach further back than intended in one direction and not far enough
	# in another. Time is the only bound that means what it says regardless of
	# how compact the array gets.
	var idx: int = arr.size() - 1
	while idx >= 0:
		var last: Dictionary = arr[idx]
		if (m["t"] - float(last["t"])) >= COALESCE_WINDOW:
			break   # this and everything before it (array is time-ordered) is too old
		if last["type"] == event_type and last["target"] == target:
			last["summary"] = summary
			last["emotion"] = emotion
			last["stamp"] = m["stamp"]
			last["t"] = m["t"]
			last["trust_change"] = float(last["trust_change"]) + trust_change
			# rewrite the tail pending line only when we coalesced into the actual
			# tail entry; a skip-coalesce (into a non-tail entry, because
			# something else was appended after it) leaves the earlier disk line
			# as-is and appends the settled version fresh -- a minor disk-
			# formatting wrinkle, not a behavior bug: context_for() reads _mem
			# (fixed above), not disk.
			if idx == arr.size() - 1 and pend.size() > 0:
				pend[-1] = _as_markdown(last)
			else:
				pend.append(_as_markdown(last))
			return
		idx -= 1
	arr.append(m)
	if arr.size() > MAX_RAM_MEMORIES:
		arr.pop_front()                  # RAM is a window; disk is the full record
	pend.append(_as_markdown(m))

func _as_markdown(m: Dictionary) -> String:
	var tc: String = ("%+.2f" % m["trust_change"]) if m["trust_change"] != 0.0 else "0"
	return "- **%s** `%s` target:: %s · emotion:: %s · trust:: %s\n  %s" % [
		m["stamp"], m["type"], (m["target"] if m["target"] != "" else "-"),
		m["emotion"], tc, m["summary"]]

# ── querying (what dialogue/opinions read back) ──────────────────────────────

func get_recent(agent: String, n: int = 5) -> Array:
	if not _mem.has(agent):
		return []
	var a: Array = _mem[agent]
	return a.slice(maxi(0, a.size() - n), a.size())

func get_memories_about(agent: String, target: String) -> Array:
	var out: Array = []
	for m in _mem.get(agent, []):
		if m["target"] == target:
			out.append(m)
	return out

## Strongest-felt memories first -- what an NPC would actually bring up.
func get_emotional(agent: String, n: int = 3) -> Array:
	var a: Array = (_mem.get(agent, []) as Array).duplicate()
	a.sort_custom(func(x, y): return absf(x["trust_change"]) > absf(y["trust_change"]))
	return a.slice(0, mini(n, a.size()))

## Compact context string for an LLM prompt. Kept SHORT on purpose: a small local
## model degrades fast with a bloated prompt, and this runs per conversation.
##
## BUG FIXED (2026-07-17): this used to slice get_memories_about() from the
## FRONT (picks.slice(0, n)) -- since memories are appended in chronological
## order, that's the OLDEST n memories about the target, not the most recent.
## A member fed 12 times kept citing their FIRST feed forever, verbatim, no
## matter what the player actually just said -- caught live: Wen gave the
## identical line to "hi wen" and "how are you", because the context fed to
## the LLM literally never changed as new memories piled up behind it.
##
## Also widened beyond "about the target only": half the slots now pull the
## member's most emotionally significant RECENT memories regardless of who
## they're about (gossip, bonds with others, work) -- previously a player
## conversation could only ever surface player-directed memories, so an NPC
## could never bring up anything else going on in their life.
##
## VARIETY (2026-07-17): tracks the memory TYPE (fed/bond/talked/...) cited
## last call per agent+about pair. If the freshest memory is the SAME type as
## last time and a different-typed one is available nearby, lead with that
## instead. This is real recency-correct behavior, not a bug fix -- caught
## live, a member fed twice mid-conversation correctly led with "you fed me"
## both times (that WAS the freshest fact each time), but three turns running
## on the same fact reads as monotonous even when each is individually
## accurate. Only kicks in when an actual alternative exists; never hides a
## genuinely repeated event if it's truly the only recent memory.
var _last_context_type: Dictionary = {}   # "agent:about" -> event_type string

## SELF-LOOP GUARD (2026-07-17): a talked/heard memory from the last
## CONVO_ECHO_WINDOW seconds is an echo of the CURRENT live exchange, not a
## distinct recollection -- excluded from context_for()'s candidate pools
## entirely. Caught live: the type-variety guard above swapped away from a
## repeated "fed" memory, but landed on the NPC's own most recent reply --
## which was itself about the same feed, since it's a record of what she
## just said. Type-diversity alone doesn't help when the alternate-typed
## memory is a self-referential echo of the very thing being avoided; this
## closes that loop at the source instead. Genuinely OLDER talked/heard
## memories (a real past conversation, not this one's own tail) stay fully
## eligible -- only the live exchange's own recent turns are screened out.
const CONVO_ECHO_WINDOW := 90.0

func _is_convo_echo(m: Dictionary) -> bool:
	if m["type"] != "talked" and m["type"] != "heard":
		return false
	return (Time.get_ticks_msec() / 1000.0) - float(m["t"]) < CONVO_ECHO_WINDOW

func context_for(agent: String, about: String = "", n: int = 4) -> String:
	var picks: Array = []
	if about != "":
		var about_mem: Array = (get_memories_about(agent, about) as Array) \
			.filter(func(m): return not _is_convo_echo(m))
		var recent_about: Array = about_mem.slice(maxi(0, about_mem.size() - n), about_mem.size())
		recent_about.reverse()   # most recent first -- this is what should dominate
		var key: String = agent + ":" + about
		var last_type = _last_context_type.get(key, "")
		if recent_about.size() > 1 and last_type != "" and recent_about[0]["type"] == last_type:
			for i in range(1, recent_about.size()):
				if recent_about[i]["type"] != last_type:
					var alt = recent_about[i]
					recent_about.remove_at(i)
					recent_about.insert(0, alt)
					break
		picks.append_array(recent_about.slice(0, mini(n - n / 2, recent_about.size())))
		if not picks.is_empty():
			_last_context_type[key] = picks[0]["type"]
		# fill remaining slots with the member's broader recent/emotional life,
		# skipping anything already picked so the two halves don't duplicate.
		# Fetches a wider pool (n*3) BEFORE filtering echoes so the filter
		# doesn't starve real content down to nothing.
		var picked_summaries: Array = []
		for m in picks:
			picked_summaries.append(m["summary"])
		var wider: Array = (get_emotional(agent, n * 3) as Array) \
			.filter(func(m): return not _is_convo_echo(m))
		for m in wider:
			if picks.size() >= n:
				break
			if not picked_summaries.has(m["summary"]):
				picks.append(m)
	if picks.is_empty():
		picks = (get_emotional(agent, n * 3) as Array).filter(func(m): return not _is_convo_echo(m))
	if picks.is_empty():
		picks = (get_recent(agent, n * 3) as Array).filter(func(m): return not _is_convo_echo(m))
	if picks.is_empty():
		return "You have no strong memories yet."
	var lines: Array[String] = []
	for m in picks.slice(0, mini(n, picks.size())):
		lines.append("- %s (%s)" % [m["summary"], m["emotion"]])
	return "\n".join(lines)

func has_met(agent: String, target: String) -> bool:
	return not get_memories_about(agent, target).is_empty()

## Wipe all persisted memory. Call ONCE, at the start of a genuinely NEW game
## (no save file present -- see Tribemanager.gd's _ready(), right before
## TribePersist.load_and_catch_up()). Without this, starting a fresh
## playthrough after an earlier one left every NPC's markdown note describing
## a life that never happened THIS run -- old betrayals, old conversations,
## stale rumours -- and the LLM would read them back through context_for() as
## if they were real, because to TribeMemory an old memory and a new one are
## indistinguishable once written.
func reset_all() -> void:
	_mem.clear()
	_pending.clear()
	for dir_path in [NPC_DIR, EVENT_DIR]:
		var d := DirAccess.open(dir_path)
		if d == null:
			continue
		d.list_dir_begin()
		var fname := d.get_next()
		while fname != "":
			if not d.current_is_dir():
				d.remove(fname)
			fname = d.get_next()
		d.list_dir_end()
	print("[TribeMemory] new game -- vault reset, previous playthrough's memories cleared")

# ── persistence ─────────────────────────────────────────────────────────────

## Append pending memories to each NPC's markdown file. Batched (see FLUSH_INTERVAL).
func flush() -> void:
	for agent in _pending.keys():
		var lines: Array = _pending[agent]
		if lines.is_empty():
			continue
		var path := "%s/%s.md" % [NPC_DIR, _safe(agent)]
		var existed := FileAccess.file_exists(path)
		var f := FileAccess.open(path, FileAccess.READ_WRITE if existed else FileAccess.WRITE)
		if f == null:
			push_warning("TribeMemory: cannot write %s" % path)
			continue
		if not existed:
			f.store_string("---\nkind: npc-memory\nnpc: %s\n---\n\n# %s\n\n## Memories\n\n" % [agent, agent])
		else:
			f.seek_end()
		for ln in lines:
			f.store_string(ln + "\n")
		f.close()
		_pending[agent] = []

## A world-level event note (wars, rumors) -- the shared history, not one NPC's.
func record_event(title: String, body: String, tags: String = "event") -> void:
	var path := "%s/%s_%s.md" % [EVENT_DIR, Time.get_datetime_string_from_system().replace(":", "-"), _safe(title)]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string("---\nkind: %s\ndate: %s\n---\n\n# %s\n\n%s\n" % [
		tags, Time.get_datetime_string_from_system(), title, body])
	f.close()

func _safe(s: String) -> String:
	var out := ""
	for c in s:
		out += c if c.is_valid_identifier() or c.is_valid_int() or c in "-_ " else "_"
	return out.strip_edges().replace(" ", "_")

func _write_readme() -> void:
	var path := VAULT_DIR + "/README.md"
	if FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string("""# TribeVault

Living memory of the tribe simulation. Every NPC keeps its own note under
`NPCs/`; world events (wars, rumors) land in `Events/`.

Open this folder in Obsidian ("Open folder as vault") to read it. Nothing here
needs the Obsidian REST plugin -- these are plain markdown files written
directly by the game, so they exist whether Obsidian is running or not.

Each memory line records what happened, to whom, how it FELT, and how it moved
trust -- because that's what the NPC reads back when it talks about you later.
""")
	f.close()
