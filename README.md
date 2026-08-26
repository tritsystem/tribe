# Tribe

A Godot 4.6 survival/RTS sim where every NPC — tribe members, animals, dogs,
and rival AI tribes — is driven by a small, custom **spiking neural network**
("Spikeling") instead of a behavior tree or state machine.

You play an FPS character who walks up to tribe members and feeds them
(`E`) to build trust. As trust rises, members are promoted through ranks
(Stranger → Acquaintance → Friend → Loyal → Devoted), which gates whether
they'll accept risky orders (gather / hunt / scout / defend). Build enough
backers and you become tribe leader, who can issue rally orders and lead the
tribe through an inter-tribe war that converges to one winner — or razes
your own camp if you lose it.

## Spikeling — the brain

`spikeling.gd` is a real leaky integrate-and-fire (LIF) spiking neural
network, not a metaphor: each neuron has a membrane potential that leaks
toward zero every tick, accumulates weighted input from synapses and
external stimuli, fires when it crosses a threshold, and then sits in a
refractory period before it can fire again. Synapses strengthen via
Hebbian learning (`learn()`) when source and target both fire, bounded so
weights relax back toward their innate strength instead of saturating —
this keeps individual personalities (e.g. Wary vs Trusting) distinct over a
long session instead of washing out.

Every agent type loads its own small brain from a `.spk` text config and
steps it every tick:

```
neuron PlayerNorth threshold=100 leak=5
neuron SwarmNorth  threshold=100 leak=5
synapse PlayerNorth -> SwarmNorth weight=60
refractory=4
```

Wired into: `npc.gd`, `tribemember.gd`, `animal.gd`, `dog.gd`,
`world_tribe.gd` (one brain per AI tribe, not per individual member — cheap
enough to run many tribes at once).

## Tribe DSL

Tribe archetype personalities (Raiders, Traders, Mystics, Warriors, etc.)
are *not* hardcoded — `tribe_dsl.gd` parses plain-text `.tribe` files in
`tribes/` (traits, speech lines, material) at runtime, so a new archetype
is just a new text file, no GDScript or recompiling needed. Parsed results
are cached per archetype name (`tribe_registry.gd`) so many tribe instances
share one parse.

## Other systems

- **BodyAnim** (`body_anim.gd`) — cheap procedural aliveness (walk-bob,
  idle breath, lean, reaction pops) driven by `tension`/`mood` channels
  fed from the Spikeling brain (e.g. prey trembles from its `SeeThreat`
  neuron firing).
- **Inter-tribe war** — AI tribes muster physical marching war parties
  that attack rival totems; the last tribe standing besieges the player's
  base or the player can raze it first.
- **Dogs** — feed (`H`) to tame, then `J` to call to heel or leave them
  guarding the base.
- **Scale presets** — Skirmish / Standard / Epic, chosen at the start
  menu or via `godot -- --scale=epic` to skip straight to a size.

## Setup

Requires [Godot 4.6](https://godotengine.org/download) with the .NET-free
("Standard") build (project uses GDScript only) and Jolt Physics, which
ships with 4.6 by default.

```bash
git clone <this-repo-url>
cd tribe
godot4 .          # or open project.godot from the Godot editor
```

Run from the editor (F5), or headless-check it parses cleanly:

```bash
godot4 --headless --check-only .
```

To build a standalone executable, use the Godot editor's **Project →
Export** with the included `export_presets.cfg` (Windows Desktop preset
configured), or:

```bash
godot4 --headless --export-release "Windows Desktop" tribe.exe
```

## Handoff context (2026-08-26 session — read this first if picking up work)

This session did three real, verified pieces of work, in this order. Full
reasoning/verification for each lives in the linked source; this section
is a map, not a duplicate.

**1. Removed the turtle-island system** (commits `496d212`, pushed).
Player-island/turtle-island/troll mechanics (bundled into an earlier
"Accumulated tribe development" commit alongside unrelated asset/NPC
fixes, which were kept) are fully stripped: `world_tribe.gd` back to
`extends Node3D`, `Tribemanager.gd`'s `MAP_EXTENT` scaling reverted
3x→1x, the ~140-line turtle-encounter UI gone, swim-recovery/home-weld
machinery gone from `npc.gd`/`animal.gd`/`dog.gd`/`FPSPlayer.gd`.
`water_crossing.gd` was deliberately KEPT — it's the general, unrelated
archipelago boat-crossing system, not turtle-specific. Verified via
fresh headless boot, zero script/parse errors.

**2. Added DirectVoice** (commit `31159cf`, pushed) — a second,
deterministic, LLM-free NPC dialogue path alongside the existing
Ollama-based `say_as()`. See `direct_voice.gd` (new) and
`tribe_llm.gd`'s `say_as_direct()`. Built in response to a public
technical critique (an LLM isn't genuinely "the SNN's voice") that
checked out as correct. Verified in real Godot: real Trust-potential
values tracked correctly through a betrayal scenario, personality
divergence confirmed real (Steady/Trusting/Wary produced different
Trust trajectories from their own `trust_leak` params), 12/12 checks
passed both before and after the turtle-island removal. Currently
switchable via `tribe_chat.gd`'s `USE_DIRECT_VOICE_FOR_LIVE_TEST` const
(`true` right now — routes one live chat call site to DirectVoice for
in-game testing; flip to `false` to go back to the normal Ollama path
for that call site, no other call sites affected).

Full side-by-side code + a data-flow diagram of both voice paths:
[`portfolio_demo/SNN_ARCHITECTURE.md`](portfolio_demo/SNN_ARCHITECTURE.md)
(commit `e37f5f6`, pushed).

**3. Scoped (not started) a neuron-type expansion.** The main Spikeling
engine (`Documents/Spikeling/core/`) already has Izhikevich, AdEx, and
Resonator neuron types — none are ported into this project's
`spikeling.gd`, which only has LIF. Full scope, priority order, and
explicit out-of-scope calls (no backprop-trainable SNNs, no Brian2-style
biological realism — neither has an identified gameplay payoff here):
`Documents/Spikeling/vault/Projects/tribe-neuron-type-expansion.md`.
**Recommended next step**: port the Resonator neuron type and test
whether it can unify with or replace the existing TribeDrums Kuramoto
emergent-sync mechanic (a real, already-hardware-validated neuron type
solving an adjacent problem to an existing, separate Tribe system) —
this is the one candidate with a genuine existing hook, not a
speculative one. Do not build AdEx's betrayal-adaptation idea or
Izhikevich speculatively without a real before/after comparison first,
per this project's own verification discipline throughout this README.

## Status / known caveats

- `player.tscn` and `tribemember.tscn` are stale/orphaned — their root
  nodes don't match what their scripts expect (`@onready` children like
  `$Camera3D` are missing), and neither is referenced by `main.tscn`
  (which builds the Player/TribeMember nodes inline instead). Harmless
  leftovers, not live bugs.
- `player.gd` is an empty no-op stub; the real FPS controller is
  `FPSPlayer.gd`.
- No automated tests yet — verification has been manual + headless
  `--check-only`/`--quit-after` runs during development.

## License

MIT — see [LICENSE](LICENSE).
