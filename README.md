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
