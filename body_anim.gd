extends RefCounted
class_name BodyAnim

# ─────────────────────────────────────────────────────────────────────────────
# BodyAnim — cheap procedural "this thing is ALIVE" motion for a capsule body.
#
# No rigged model, no animation tracks. Given a body's visual parts (mesh, face,
# head…) it lays four things on top of their RESTING transforms:
#   • a walk-bounce that quickens with speed,
#   • an idle breath when standing still,
#   • a forward lean into a run,
#   • reaction "pops" — a happy hop when fed, a startle when spooked.
#
# Two expression channels let the Spikeling brain leak into the body so the mind
# shows on the outside (the whole point of running a spiking brain per agent):
#   • tension (0..1) — a fine nervous tremor + quick, shallow breathing. Drive it
#     from fear neurons (prey's SeeThreat, an NPC's SeeDanger).
#   • mood (-1..+1) — slumped-and-hungry vs upright-and-alert. Drive it from trust
#     and hunger.
#
# Usage (one per agent):
#   anim = BodyAnim.new()
#   anim.setup([mesh, face])                    # in _ready, after the parts exist
#   anim.mood = 0.3 ; anim.tension = 0.0        # each frame
#   anim.tick(delta, planar_speed, on_floor)    # each frame, AFTER move_and_slide
#   anim.pop(0.8)                               # a one-off reaction impulse (0..1)
# ─────────────────────────────────────────────────────────────────────────────

var parts: Array = []          # visual Node3Ds we drive
var _base_pos: Array = []      # their resting local positions
var _base_rot: Array = []      # resting local rotations (euler)
var _base_scl: Array = []      # resting local scales

# expression channels — the owner sets these each frame
var tension: float = 0.0       # 0..1  nervous tremor + fast shallow breath
var mood: float = 0.0          # -1..+1  slumped/low .. upright/alert

# ── feel tunables ──
const STRIDE_BASE := 6.0       # leg cadence even at a crawl
const STRIDE_PER_SPEED := 2.2  # steps quicken with speed
const REF_SPEED := 2.6         # speed that reads as a "full" walk
const BOB_AMP := 0.07          # walk-bounce height
const LEAN_AMP := 0.16         # forward tilt at a full run (radians)
const BREATH_AMP := 0.035      # idle breathing rise/fall
const POP_HEIGHT := 0.35       # reaction-hop height
const POP_DECAY := 6.0         # how fast a pop springs back to rest

var _phase: float = 0.0        # stride phase
var _breath: float = 0.0       # breathing phase
var _pop: float = 0.0          # live reaction impulse
var _tremor_t: float = 0.0     # nervous-tremble phase

func setup(nodes: Array) -> void:
	parts.clear(); _base_pos.clear(); _base_rot.clear(); _base_scl.clear()
	for n in nodes:
		if n != null and is_instance_valid(n):
			parts.append(n)
			_base_pos.append((n as Node3D).position)
			_base_rot.append((n as Node3D).rotation)
			_base_scl.append((n as Node3D).scale)

# fire a reaction impulse (a hop + a brief squash-and-stretch). 0..1
func pop(strength: float) -> void:
	_pop = maxf(_pop, clampf(strength, 0.0, 1.0))

func tick(delta: float, planar_speed: float, _grounded: bool) -> void:
	if parts.is_empty():
		return
	var move := clampf(planar_speed / REF_SPEED, 0.0, 1.0)

	# walk cadence → a two-step vertical bounce (both feet land per cycle)
	_phase += delta * (STRIDE_BASE + planar_speed * STRIDE_PER_SPEED)
	var bounce := absf(sin(_phase)) * BOB_AMP * move

	# breathing — only really visible when near-idle; quick & shallow when tense
	var breath_rate := 1.6 + tension * 4.0 + maxf(0.0, mood) * 0.8
	_breath += delta * breath_rate
	var idle := 1.0 - move
	var breath := sin(_breath) * BREATH_AMP * idle

	# a reaction hop that springs back toward rest
	_pop = move_toward(_pop, 0.0, delta * POP_DECAY)
	var hop := _pop * POP_HEIGHT

	# posture from mood: stand a touch taller when alert, sink when low
	var settle := mood * 0.06

	# a fine nervous tremble driven by tension (fear neurons)
	_tremor_t += delta * 40.0
	var tremor := 0.0
	if tension > 0.001:
		tremor = (sin(_tremor_t) * 0.5 + sin(_tremor_t * 2.31) * 0.5) * tension * 0.05

	var y_off := bounce + breath + hop + settle
	var lean := move * LEAN_AMP - maxf(0.0, -mood) * 0.12   # lean into a run; droop when low
	var squash_y := 1.0 + _pop * 0.18
	var squash_xz := 1.0 - _pop * 0.10

	for i in range(parts.size()):
		var p: Node3D = parts[i]
		if not is_instance_valid(p):
			continue
		p.position = _base_pos[i] + Vector3(0.0, y_off, 0.0)
		p.rotation = _base_rot[i] + Vector3(lean + tremor, 0.0, tremor * 0.6)
		p.scale = _base_scl[i] * Vector3(squash_xz, squash_y, squash_xz)
