extends RefCounted
class_name RivalAdaptationModel
# ─────────────────────────────────────────────────────────────────────────────
# RivalAdaptationModel -- "an opponent that's adapted to you, not a fixed AI."
#
# A real, TRAINED linear readout (same ridge-regression technique used for
# memory capacity in project_thought/ssh_chiral_experiment.gd, pointed at a
# different problem) that maps the player's actual aggregate behavior --
# how often their own tribe has blamed them, how often they've fed members,
# how many wars/raids they've personally triggered -- to a single adapted
# AGGRESSION score in 0..1. Rival tribes use this to scale how hard they
# react to the player specifically, instead of every rival treating a
# murder or a greeting identically regardless of the player's history.
#
# The weights are FIT, not hand-picked: a small set of archetypal players
# (a peaceful feeder, a warmonger, a neglectful leader who gets blamed a
# lot, a genuinely balanced player) with a hand-authored target aggression
# each, run through ridge regression once at construction. This is honestly
# a small calibration set, not a full RL policy -- appropriate for what a
# rival tribe's "read" on the player should look like, and it's still a
# real fitted model producing weights nobody chose directly, not an
# if/else ladder.
# ─────────────────────────────────────────────────────────────────────────────

const RIDGE_LAMBDA := 0.1

# [blame_freq, feed_freq, war_freq] (each pre-normalized 0..1), -> target aggression 0..1
const TRAIN_X: Array = [
	[0.0, 0.0, 0.0],   # a total stranger -- rivals start neutral, low aggression
	[0.0, 1.0, 0.0],   # a generous, peaceful feeder -- rivals should stay calm
	[0.0, 0.8, 0.1],   # mostly generous, a little conflict -- still fairly calm
	[1.0, 0.0, 0.0],   # own tribe blames them constantly (neglect) -- rivals wary
	[0.0, 0.0, 1.0],   # a warmonger who's triggered many raids -- rivals hostile
	[1.0, 0.0, 1.0],   # blamed AND a warmonger -- rivals very hostile
	[0.5, 0.5, 0.5],   # a mixed, unpredictable player -- moderately wary
	[0.2, 0.9, 0.0],   # mostly kind with a little blame -- mostly calm
	[0.0, 0.3, 0.8],   # not very generous, frequently at war -- hostile
]
const TRAIN_Y: Array = [0.15, 0.05, 0.10, 0.55, 0.85, 0.95, 0.55, 0.20, 0.80]

var weights: Array = []   # [w_blame, w_feed, w_war, bias]

func _init() -> void:
	weights = _ridge_fit(TRAIN_X, TRAIN_Y)

## The actual, personalized read: how aggressively should a rival treat this
## player right now, given their real aggregate behavior so far.
func predict(blame_freq: float, feed_freq: float, war_freq: float) -> float:
	var x: Array = [clampf(blame_freq, 0.0, 1.0), clampf(feed_freq, 0.0, 1.0), clampf(war_freq, 0.0, 1.0), 1.0]
	var out := 0.0
	for i in range(x.size()):
		out += x[i] * float(weights[i])
	return clampf(out, 0.0, 1.0)

## Ridge regression via normal equations w = (X^T X + lambda I)^-1 X^T y,
## with a bias column appended -- same small-k Gaussian-elimination approach
## as ssh_chiral_experiment.gd's _ridge_fit, k=4 here (3 features + bias).
func _ridge_fit(xs_raw: Array, ys: Array) -> Array:
	var k := 4
	var xs: Array = []
	for row in xs_raw:
		xs.append([row[0], row[1], row[2], 1.0])
	var xtx := []
	for i in range(k):
		var row := []
		for j in range(k):
			row.append(0.0)
		xtx.append(row)
	var xty := []
	for i in range(k):
		xty.append(0.0)
	for t in range(xs.size()):
		var x: Array = xs[t]
		var y: float = ys[t]
		for i in range(k):
			xty[i] += x[i] * y
			for j in range(k):
				xtx[i][j] += x[i] * x[j]
	for i in range(k):
		xtx[i][i] += RIDGE_LAMBDA
	return _gauss_solve(xtx, xty, k)

func _gauss_solve(a: Array, b: Array, k: int) -> Array:
	var m: Array = []
	for i in range(k):
		var row: Array = a[i].duplicate()
		row.append(b[i])
		m.append(row)
	for col in range(k):
		var pivot_row := col
		for r in range(col + 1, k):
			if absf(m[r][col]) > absf(m[pivot_row][col]):
				pivot_row = r
		var tmp = m[col]; m[col] = m[pivot_row]; m[pivot_row] = tmp
		var pivot: float = m[col][col]
		if absf(pivot) < 1e-9:
			continue
		for c in range(col, k + 1):
			m[col][c] /= pivot
		for r in range(k):
			if r == col:
				continue
			var factor: float = m[r][col]
			for c in range(col, k + 1):
				m[r][c] -= factor * m[col][c]
	var w: Array = []
	for i in range(k):
		w.append(m[i][k])
	return w
