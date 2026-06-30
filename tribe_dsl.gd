class_name TribeDSL
extends RefCounted
# ─────────────────────────────────────────────────────────────────────────────
# TribeDSL — loads tribe archetype personality from plain text files in
# res://tribes/*.tribe instead of hardcoded dictionaries in world_tribe.gd.
# This is the actual format (two-space indentation = nested under the last
# top-level key; '#' starts a comment; bare numbers parse as floats, quoted
# strings as strings, everything else as a literal string):
#
#   archetype: Raiders
#   material: Obsidian
#   traits:
#     aggression: 0.75
#     greed: 0.55
#     honor: 0.40
#     paranoia: 0.60
#   speech:
#     hostile: "Leave our lands, stranger."
#     neutral: "State your purpose."
#     friendly: "You are known to us."
#     trusted: "Walk freely among the Raiders."
#
# A writer (or a thousand of them) fills out a .tribe file per archetype —
# no GDScript, no recompiling — and world_tribe.gd reads it. Results are
# cached per archetype name so 1000 tribes parse their file once, not once
# each (see TribeRegistry.get_archetype below).
# ─────────────────────────────────────────────────────────────────────────────

static func load_file(path: String) -> Dictionary:
	var result: Dictionary = {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("TribeDSL: couldn't open %s" % path)
		return result
	var section_stack: Array = [result]   # [0] = root dict; deeper = nested dicts
	var indent_stack: Array = [-1]        # matching indent level for each stack entry
	while not f.eof_reached():
		var raw := f.get_line()
		if raw.strip_edges() == "" or raw.strip_edges().begins_with("#"):
			continue
		var indent := 0
		while indent < raw.length() and (raw[indent] == " " or raw[indent] == "\t"):
			indent += 1
		var line := raw.strip_edges()
		var colon := line.find(":")
		if colon == -1:
			continue
		var key := line.substr(0, colon).strip_edges()
		var val := line.substr(colon + 1).strip_edges()

		# pop back to the right nesting level for this indent
		while indent <= indent_stack[indent_stack.size() - 1] and section_stack.size() > 1:
			section_stack.pop_back()
			indent_stack.pop_back()
		var here: Dictionary = section_stack[section_stack.size() - 1]

		if val == "":
			var nested: Dictionary = {}
			here[key] = nested
			section_stack.append(nested)
			indent_stack.append(indent)
		else:
			here[key] = _parse_value(val)
	f.close()
	return result

static func _parse_value(s: String):
	if s.begins_with('"') and s.ends_with('"') and s.length() >= 2:
		return s.substr(1, s.length() - 2)
	if s.is_valid_float():
		return s.to_float()
	# comma-separated list, e.g. "obsidian, stone"
	if s.find(",") != -1:
		var out: Array = []
		for part in s.split(","):
			out.append(part.strip_edges())
		return out
	return s
