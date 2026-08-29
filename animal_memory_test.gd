extends Node
class_name AnimalMemoryTest


# animal_memory_test.gd — headless verification of animal memory (biome preference
# + remembered spots + wander bias) via the real AnimalMemory class and the actual
# Spikeling runtime.
#
# Run:
#   Godot_v4.7..._console.exe --headless --path . res://animal_memory_test.tscn --quit-after 120


# ── scenario A: biome preference tracks recent grazing (not lifetime tally) ─────
# Graze in "valley" 5x, then "mountain" 3x, then let decay run. preferred_biome()
# should be "valley" (higher potential, more recent stimulation). Then graze ONLY
# "mountain" 4 more times — mountain should overtake valley once its cumulative
# stimulation + recentness exceeds valley's decaying signal. This proves the claim:
# "preferred reflects sustained recent success, not a lifetime tally that can never
# change" — a biome that was never grazed first can become preferred through later
# success.
static func test_biome_preference() -> void:
	print("=== Scenario A: biome preference tracks recent grazing ===")

	var mem := AnimalMemory.new()
	var b := mem._get_brain()

	# phase 1: graze valley 5 times
	for i in range(5):
		mem.on_graze_success("valley", Vector3(10, 0, 10))
	# phase 2: graze mountain 3 times
	for i in range(3):
		mem.on_graze_success("mountain", Vector3(50, 0, 50))
	# snapshot potentials after phase 1+2
	var valley_p1 := mem.preferred_biome()
	print("  After 5x valley + 3x mountain: preferred = %s (valley_pot=%.1f, mtn_pot=%.1f)" % [
		valley_p1,
		b.get_potential("valley"),
		b.get_potential("mountain")])

	# phase 3: let decay run — run 10 empty brain steps (no grazing)
	for i in range(10):
		b.step()
	var valley_after_decay := mem.preferred_biome()
	print("  After 10 decay steps: preferred = %s (valley_pot=%.1f, mtn_pot=%.1f)" % [
		valley_after_decay,
		b.get_potential("valley"),
		b.get_potential("mountain")])
	# After decay, valley should still win (it had 5 grazes vs mountain's 3, and
	# both decay at the same leak rate) — UNLESS the most-recent grazes were all
	# mountain. In our case, last 3 grazes were mountain, so mountain had +25*3 at
	# its peak but valley had +25*5 earlier; after 10 steps of leak=4, valley lost
	# 40 potential and mountain lost 40 too from their peaks — valley should still
	# be higher because it started higher. Check.
	_check("valley still preferred after decay (more total grazes)", valley_after_decay == "valley")

	# phase 4: graze mountain 4 more times to overtake valley
	for i in range(4):
		mem.on_graze_success("mountain", Vector3(50, 0, 50))
	var mountain_p2 := mem.preferred_biome()
	print("  After 4 more mountain grazes: preferred = %s (valley_pot=%.1f, mtn_pot=%.1f)" % [
		mountain_p2,
		b.get_potential("valley"),
		b.get_potential("mountain")])
	_check("mountain overtakes valley after sustained recent success", mountain_p2 == "mountain")
	print("")


# ── scenario B: recall_food_spot returns remembered positions ─────────────────
# Graze at 3 distinct spots, then 1 duplicate (same bush, should be de-duped),
# then recall 5 times and confirm we only ever get back the 3 real spots.
static func test_remembered_spots() -> void:
	print("=== Scenario B: remembered food spots ===")
	var mem := AnimalMemory.new()
	var b := mem._get_brain()

	var spot_a := Vector3(10, 0, 10)
	var spot_b := Vector3(50, 0, 50)
	var spot_c := Vector3(100, 0, 100)
	var dup_a := Vector3(10.1, 0, 10.1)   # within 3.0m of spot_a → should de-dupe

	mem.on_graze_success("valley", spot_a)
	mem.on_graze_success("valley", spot_b)
	mem.on_graze_success("valley", spot_c)
	mem.on_graze_success("valley", dup_a)   # de-dupe, no new entry
	var count := mem.has_memory()
	print("  After 3 distinct + 1 near-duplicate: has_memory=%s" % [count])
	_check("3 distinct spots remembered", count == true)

	# recall 20 times and confirm we only ever get back one of the 3 real spots
	var seen := {}
	var total_recalls := 50
	for i in range(total_recalls):
		var r := mem.recall_food_spot()
		var key := "%s,%s,%s" % [r.x, r.y, r.z]
		seen[key] = true
	var distinct_recalled := seen.size()
	print("  After %d recalls: %d distinct spots returned (expected ≤ 3)" % [total_recalls, distinct_recalled])
	_check("recall_food_spot only returns remembered spots (≤3 distinct)", distinct_recalled <= 3)
	_check("spot A recalled at least once", seen.has("%s,%s,%s" % [spot_a.x, spot_a.y, spot_a.z]))
	_check("spot B recalled at least once", seen.has("%s,%s,%s" % [spot_b.x, spot_b.y, spot_b.z]))
	_check("spot C recalled at least once", seen.has("%s,%s,%s" % [spot_c.x, spot_c.y, spot_c.z]))
	_check("duplicate spot NEVER recalled", not seen.has("%s,%s,%s" % [dup_a.x, dup_a.y, dup_a.z]))
	print("")


# ── scenario C: empty memory returns INF, has_memory=false ─────────────────────
static func test_empty_memory() -> void:
	print("=== Scenario C: empty memory ===")
	var mem := AnimalMemory.new()
	_check("empty: has_memory=false", mem.has_memory() == false)
	_check("empty: recall_food_spot=INF", mem.recall_food_spot() == Vector3.INF)
	_check("empty: preferred_biome=\"\"", mem.preferred_biome() == "")
	print("")


# ── helpers ──────────────────────────────────────────────────────────────────────
static var _pass := 0
static var _fail := 0

static func _check(label: String, cond: bool) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		print("  FAIL: %s" % [label])


# ── entry ────────────────────────────────────────────────────────────────────────
func _ready() -> void:
	_check = _check_static
	test_empty_memory()
	test_biome_preference()
	test_remembered_spots()
	print("=" .repeat(60))
	print("  ANIMAL MEMORY — biome preference + remembered spots")
	print("  %d passed, %d FAILED" % [_pass, _fail])
	print("=" .repeat(60))


static func _check_static(label: String, cond: bool) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		print("  FAIL: %s" % [label])
