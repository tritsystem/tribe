# Tribe's SNN: before and after the neuron-type expansion

Tribe's brains (`spikeling.gd`) started as a single-neuron-model system.
This document is the real before/after: what changed, the actual formula
behind each addition, what each one is genuinely good and bad for, and
which ones actually do something in the shipped game today versus which
are real, tested, unused capacity.

Every number below is measured, not estimated — from real headless test
runs against the real reference implementations, cited by test file and
commit where relevant.

## Before: one neuron model

Every brain in Tribe — Trust, Follow, SawContribute, SawBetray, all of
it — ran on **leaky integrate-and-fire (LIF)**: a membrane potential
that leaks toward zero every tick, accumulates weighted synaptic input,
fires when it crosses a threshold, then sits refractory before it can
fire again.

LIF answers exactly one question: **how much stimulus, total.** It has
no way to represent *how* that stimulus arrived — a burst of five hits
in one second and the same five hits spread across a minute look
identical to a LIF neuron, because it only ever tracks a running sum.
That's the real limitation the whole expansion below addresses.

## After: four neuron models, each answering a different question

| Neuron | Real computation | What it can represent that LIF can't | Status in Tribe today |
|---|---|---|---|
| **LIF** | `p' = -leak·p`, fires + resets to 0 at threshold | — (the baseline) | Live everywhere, unchanged |
| **Izhikevich** | `v' = 0.04v² + 5v + 140 - u + I`, `u' = a(bv-u)`, resets `v←c, u←u+d` | **Pattern over time** — a recovery variable that carries across spikes, so a burst and a spread-out sequence of the same total stimulus produce different internal state | Live: `BurstTrauma` |
| **AdEx** | `v' = (-g_L(v-E_L) + g_LΔ_T e^{(v-V_T)/Δ_T} - w + I)/C`, `w' = (a(v-E_L)-w)/τ_w`, resets `v←v_reset, w←w+b` | **Repetition / fatigue** — an adaptation current that suppresses response to repeated stimulation, then recovers | Live: `BetrayalFatigue` |
| **Resonator** | `accel = -ω²x - 2ζωv + coupling·drive` (driven damped oscillator), fires on energy-envelope threshold crossing, **no reset** | **Frequency** — which *rate* a signal is happening at, not just how much of it there is | Ported, characterized, real capability confirmed — not wired into gameplay (see below) |

## What each one is actually good and bad for

### LIF — cheap, predictable, magnitude-only

**Good for:** exactly what it's already doing — Trust, Follow, and
every other "has enough of X happened" signal in the game. One state
variable, one reset rule, fully calibrated and battle-tested. If a
mechanic only cares about total accumulated stimulus, LIF is the
correct and cheapest choice; nothing below should replace it for that.

**Bad for:** anything where the *shape* of the stimulus matters. It
cannot distinguish an ambush from a war of attrition, a first offense
from a tenth, or a familiar signal from an unfamiliar one — all it has
is a running total.

### Izhikevich — pattern detection, shipped in `BurstTrauma`

**Good for:** telling a burst apart from the same total spread out.
Tribe's trauma mechanic (`_trauma_hit_count`) used to shift a member's
personality to `"Wary"` after exactly 3 hits, with zero timing
awareness — 3 hits in one second and 3 hits over an hour triggered the
identical shift. `BurstTrauma` fixes that: its recovery variable `u`
stays measurably elevated (13.29) when hits land ~1s apart, but decays
back near baseline (-11.57) when they're 3s+ apart — so a real ambush
now reaches the Wary shift after 2 hits instead of 3, while a slow fight
still needs all 3. Verified in `test_burst_trauma.gd` (9/9), commit
`0d0a2ad`.

**Bad for:** it's real added complexity for a distinction that most
mechanics don't care about — most of Tribe's existing signals only ever
needed magnitude, and porting Izhikevich onto them would be
over-engineering. It also needed real retuning to be useful at all: the
biologically-realistic default recovery time constant (`a=0.02`, ~50ms)
fully decays within about a second of real gameplay time — useless for
detecting a burst across a multi-second window. Retuned to `a=0.001`
(~1000ms) before it did anything meaningful.

### AdEx — repetition fatigue, shipped in `BetrayalFatigue`

**Good for:** making repeated punishment feel different from a first
offense, without hand-coding a discount table. `SawBetray` used to hit
Trust with an identical -160 synapse every single time, forever.
`BetrayalFatigue` adds an adaptation neuron alongside it: a second
betrayal from the same source 3 seconds later lands **~23% softer**
(160.00 → 123.72 Trust drop), a third betrayal 60+ seconds later has
fully **recovered** to full strength (159.96), and a *different*
member's first betrayal is completely **unaffected** by someone else's
accumulated fatigue (160.00). All three predictions were stated before
the code was written and held on the real measured numbers — not just
the direction. Verified in `test_betrayal_fatigue.gd` (4/4), commit
`54ecc52`.

**Bad for:** same retuning cost as Izhikevich (`τ_w` retuned from a
30-100ms biological default to 5000ms — otherwise it's fully decayed
before a player could plausibly land a second betrayal). Also: building
it forced a close look at the old punishment path, which surfaced a
real, unrelated, more serious bug — `learn()`'s weight clamp was
silently flooring every negative-weight synapse to 0, meaning **every
betrayal after the very first one, ever, in the shipped game, had
already been landing at zero strength.** That's not a limitation of
AdEx — it's the kind of pre-existing bug that only gets found when
someone finally has a reason to test the old mechanic carefully.

### Resonator — frequency detection, real but currently unused

**Good for:** telling apart *what rate* something is happening at, not
just whether it's happening. This is a fundamentally different kind of
question than the other three — none of them can distinguish signal
content by frequency, only by magnitude or repetition pattern.
Independently validated at **99.2% detection accuracy vs ~65%** for a
naive amplitude threshold (telling a target frequency apart from
distractor tones + noise), and separately confirmed on real microphone
hardware (structured noise nulled at readout). This session measured
its real resonance curve for the first time in Tribe specifically: peak
lands exactly on the tuned frequency, `Q = 1/(2·damping) ≈ 2.99`
measured against a theoretical 3.33.

**Bad for:** it structurally *cannot* fire repeatedly under sustained
drive — there's no reset on its own dynamics, so once it crosses
threshold it fires once and goes quiet, unlike LIF/Izhikevich/AdEx
where firing *is* a state-changing reset. That ruled out its most
obvious use case: it cannot replace or extend TribeDrums' Kuramoto
phase-lock sync, because there's no periodic pulse train to lock a
phase to. A variant that adds a real reset/refractory mechanism *can*
re-fire periodically (237 fires vs 1 under 60s of sustained drive) —
but that costs real, measured frequency-selectivity in return (Q drops
from ~2.99 to ~0.8–1.1 depending on how it's measured). You don't get
both properties for free from the same neuron.

A second candidate use — recognizing your own camp's drum rhythm
against an unfamiliar one — was investigated properly and found not
viable *in this game specifically*, not because Resonator can't do it:
the signal genuinely has a stable, personality-dependent tempo (real
autocorrelation 0.51–0.78 vs 0.07 for noise), but Tribe has no second,
live, camp-tagged audio source anywhere in the codebase for a detector
to ever be tested against. The capability is real and correct; there's
currently nothing in the game world that needs it.

## The honest summary

Four real neuron types now exist, each ported from a verified reference
and independently fidelity-tested against it. Two of them
(Izhikevich, AdEx) have a real, pre-registered, measured gameplay
payoff. The third (Resonator) is a genuine, validated capability — with
one candidate use structurally ruled out and a second correctly
declined for lack of a live use case, not lack of trying. Nothing here
was wired into the game speculatively; every hook was pre-registered
with a falsifiable prediction before any gameplay code was written, and
every result — including the two that didn't pan out — is reported as
plainly as the ones that did.

Full technical history (private, not published): the author's own
project notes for this work, kept in a separate local vault outside
this repo.
