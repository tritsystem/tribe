"""Faithful Python port of Tribe's real Spikeling->LLM pipeline, run outside
Godot so it's portable to demo without the editor installed.

This is a DIRECT, line-by-line port of the real GDScript logic -- not a
reinterpretation:
  - Spikeling            <- spikeling.gd (LIF neurons, leak/threshold/refractory,
                             synaptic propagation, exact same formulas)
  - NPCCoreMemory         <- npc_core_memory.gd (the SSH edge-vs-bulk chain:
                             12 neurons, alternating V/W synapse weights,
                             hop-margin recall confidence, disorder jitter
                             under stress)
  - brain_snapshot()      <- tribemember.gd:2468 (verbatim logic)
  - core_memory_blame_line() <- tribemember.gd:848 (verbatim logic, including
                             the exact 0.08 confidence threshold)
  - persona assembly      <- tribe_chat.gd:295-298 (verbatim string format)
  - the LLM prompt itself <- tribe_llm.gd's say_as() prompt template (verbatim,
                             including the WORLD constant and the roster guard)

The .spk brain text below is tribemember.gd's own _brain_text() for the
"Steady" personality, copied verbatim (contrib=80, trust_leak=2, follow_w=120).

The only thing NOT ported: Godot's async HTTPRequest queue/hysteresis --
this calls Ollama synchronously instead, since there's no frame loop here.
The actual prompt sent to the model, and the model itself (llama3.2, same
as tribe_llm.gd's MODEL constant), are identical to the real game.
"""
import json
import urllib.request

OLLAMA_URL = "http://127.0.0.1:11434/api/generate"
MODEL = "llama3.2"  # tribe_llm.gd's exact MODEL constant


# ── Spikeling (verbatim port of spikeling.gd) ───────────────────────────────
class Neuron:
    def __init__(self, name, threshold=100.0, leak=5.0):
        self.name = name
        self.threshold = threshold
        self.leak = leak
        self.p = 0.0
        self.refr_left = 0
        self.fired = False
        self.fire_count = 0
        self.last_fire_strength = 0.0


class Synapse:
    def __init__(self, src, dst, weight):
        self.src = src
        self.dst = dst
        self.weight = weight
        self.base_weight = weight


class Spikeling:
    def __init__(self):
        self.neurons = []
        self.synapses = []
        self._name_to_idx = {}
        self.refractory_ticks = 4
        self.step_count = 0
        self._pending = {}

    def _idx(self, name):
        return self._name_to_idx.get(name, -1)

    def load_from_text(self, text):
        self.neurons, self.synapses, self._name_to_idx = [], [], {}
        self._pending, self.step_count = {}, 0
        for raw in text.split("\n"):
            line = raw.strip()
            if line.startswith("neuron "):
                parts = line.split()
                name = parts[1]
                kv = dict(p.split("=") for p in parts[2:])
                n = Neuron(name, float(kv.get("threshold", 100)), float(kv.get("leak", 5)))
                self._name_to_idx[name] = len(self.neurons)
                self.neurons.append(n)
            elif line.startswith("refractory="):
                self.refractory_ticks = int(line.replace("refractory=", "").replace("ms", ""))
        for raw in text.split("\n"):
            line = raw.strip()
            if line.startswith("synapse "):
                body = line[len("synapse "):]
                src_name, rest = [s.strip() for s in body.split("->")]
                dst_name = rest.split()[0]
                w = float(rest.split("weight=")[1].split()[0])
                si, di = self._idx(src_name), self._idx(dst_name)
                if si == -1 or di == -1:
                    continue
                s = Synapse(si, di, w)
                self.synapses.append(s)
        return len(self.neurons) > 0

    def stimulate(self, name, amount):
        i = self._idx(name)
        if i >= 0:
            self._pending[i] = self._pending.get(i, 0.0) + amount

    def stimulate_idx(self, i, amount):
        if 0 <= i < len(self.neurons):
            self._pending[i] = self._pending.get(i, 0.0) + amount

    def step(self):
        self.step_count += 1
        fired_now = []
        next_pending = {}
        for i, n in enumerate(self.neurons):
            n.fired = False
            if n.refr_left > 0:
                n.refr_left -= 1
                continue
            n.p -= n.leak
            if n.p < 0.0:
                n.p = 0.0
            n.p += self._pending.get(i, 0.0)
            if n.p >= n.threshold:
                n.last_fire_strength = max(0.0, min(1.0, (n.p - n.threshold) / max(1.0, n.threshold)))
                n.p = 0.0
                n.refr_left = self.refractory_ticks
                n.fired = True
                n.fire_count += 1
                fired_now.append(n.name)
                for s in self.synapses:
                    if s.src == i:
                        next_pending[s.dst] = next_pending.get(s.dst, 0.0) + s.weight
        self._pending = next_pending
        return fired_now

    def get_potential(self, name):
        i = self._idx(name)
        return self.neurons[i].p if i >= 0 else 0.0


# ── NPCCoreMemory (verbatim port of npc_core_memory.gd) ─────────────────────
class NPCCoreMemory:
    N = 12
    V_WEIGHT = 110.0
    W_WEIGHT = 180.0
    EDGE_SLOTS = [1, 2, N - 3, N - 2]
    BULK_SLOTS = [N // 2 - 1, N // 2]
    WRITE_STIMULUS = 150.0
    FIRE_MARGIN_SPAN = 80.0

    def __init__(self, rng):
        self.rng = rng
        self._tag_to_slot, self._tag_is_core = {}, {}
        self._next_edge, self._next_bulk = 0, 0
        self.brain = Spikeling()
        self._build_chain()

    def _build_chain(self):
        lines = ["# NPC core-memory SSH chain"]
        for i in range(self.N):
            lines.append(f"neuron m{i} threshold=100 leak=6")
        for i in range(self.N - 1):
            w = self.V_WEIGHT if i % 2 == 0 else self.W_WEIGHT
            lines.append(f"synapse m{i} -> m{i+1} weight={w}")
            lines.append(f"synapse m{i+1} -> m{i} weight={w}")
        lines.append("refractory=2")
        self.brain.load_from_text("\n".join(lines))

    def core_tags(self):
        return [t for t, is_core in self._tag_is_core.items() if is_core]

    def remember(self, tag, is_core):
        if tag in self._tag_to_slot:
            return
        if is_core:
            slot = self.EDGE_SLOTS[self._next_edge % len(self.EDGE_SLOTS)]
            self._next_edge += 1
        else:
            slot = self.BULK_SLOTS[self._next_bulk % len(self.BULK_SLOTS)]
            self._next_bulk += 1
        self._tag_to_slot[tag] = slot
        self._tag_is_core[tag] = is_core
        self.brain.stimulate_idx(slot, self.WRITE_STIMULUS)
        self.brain.step()

    def apply_stress(self, intensity):
        jitter = max(0.0, min(1.0, intensity)) * 0.35
        if jitter <= 0.0:
            return
        for s in self.brain.synapses:
            s.weight *= 1.0 + jitter * (self.rng.random() * 2.0 - 1.0)
            s.weight = max(0.0, min(255.0, s.weight))

    def _hop_margin(self, a, b):
        for s in self.brain.synapses:
            if s.src == a and s.dst == b:
                return max(0.0, min(1.0, (s.weight - 100.0) / self.FIRE_MARGIN_SPAN))
        return 0.0

    def recall(self, tag):
        if tag not in self._tag_to_slot:
            return 0.0
        slot = self._tag_to_slot[tag]
        near_boundary = 0 if slot <= (self.N - 1) // 2 else self.N - 1
        step = 1 if slot >= near_boundary else -1
        min_margin, idx = 1.0, near_boundary
        while idx != slot:
            nxt = idx + step
            min_margin = min(min_margin, self._hop_margin(idx, nxt))
            idx = nxt
        return min_margin


# ── The exact real "Steady" personality brain (tribemember.gd's _brain_text()) ─
STEADY_BRAIN = """# Spikeling Neural Configuration
neuron SawContribute threshold=50 leak=20
neuron SawHelpClear  threshold=50 leak=20
neuron SawDefend     threshold=50 leak=20
neuron SawBetray     threshold=50 leak=20
neuron Trust  threshold=100 leak=2
neuron Follow threshold=100 leak=5
synapse SawContribute -> Trust weight=80
synapse SawHelpClear  -> Trust weight=70
synapse SawDefend     -> Trust weight=95
synapse SawBetray     -> Trust weight=-160
synapse Trust -> Follow weight=120
"""


def describe_core_tag(tag):
    kind, who = tag.split(":", 1)
    if kind == "betrayal":
        return f"you killing {who} with your own hands"
    if kind == "hunger_neglect":
        return f"{who} starving while you left them locked out of the stockpile"
    return f"what happened to {who}"


def brain_snapshot(brain, betrayed_count):
    trust = brain.get_potential("Trust")
    parts = [f"Your trust in the Leader currently sits around {int(trust)} out of 100."]
    parts.append("You are not currently backing them.")
    if betrayed_count > 0:
        s = "" if betrayed_count == 1 else "s"
        parts.append(f"The Leader has struck you {betrayed_count} time{s}. You have not forgotten it.")
    return " ".join(parts)


def core_memory_blame_line(core_memory):
    tags = core_memory.core_tags()
    if not tags:
        return ""
    best_tag, best_conf = "", -1.0
    for t in tags:
        c = core_memory.recall(t)
        if c > best_conf:
            best_conf, best_tag = c, t
    if best_conf <= 0.0:
        return ""
    described = describe_core_tag(best_tag)
    if best_conf >= 0.08:
        return f" You vividly remember {described} -- it colors how much you trust the Leader right now, and you should let it show."
    return " Some part of you remembers something bad involving the Leader, but everything since has worn it hazy -- you're not sure it should still weigh on you."


# ── the real WORLD constant + say_as() prompt template (tribe_llm.gd, verbatim) ─
WORLD = """This world contains ONLY: berry bushes/herbs/roots/mushrooms/nuts/grain,
trees to chop, ore/stone/gems/coal/clay/sand to mine, animals to hunt, carved
clubs and crafted weapons/armor, teepees, a stockpile of food, a trading
post (if one has been built), a blacksmith's forge (in a Crafting
settlement), a real campfire at camp, dogs, rival tribes who raid and
trade, hunger, and the Leader (the player).
There IS a day/night cycle now. At night the tribe gathers at the real
campfire to gossip, laugh, and dance -- you may mention this if it fits.
It has NO weather beyond rain/storm/fog/clear (no seasons, no calendar).
Never mention "today", "yesterday", "tomorrow", "the other day", or any
event that is not in your memories below. If you have no memory of
something, do not invent one -- say you don't know, or speak about what
you DO remember. Only mention a building or landmark if it is listed here
as existing, or you have a real memory of it below -- never invent one.
"""


def build_prompt(speaker, persona, memories, situation, roster=""):
    who = f"\nThe only people who exist are: {roster}. NEVER use a name that is not in that list.\n" if roster else ""
    return f"""You are {speaker}, a member of a stone-age tribe. {persona}
{who}{WORLD}
What you remember (this is your ACTUAL past -- speak from it, don't invent history):
{memories}

Situation: {situation}

Reply as {speaker} in ONE short spoken line (max 20 words). Plain speech, no quotes, no
narration, no asterisks. If a memory above is relevant, let it colour what you say."""


def call_ollama(prompt, speaker, max_tokens=60, temperature=0.8):
    body = json.dumps({
        "model": MODEL, "prompt": prompt, "stream": False,
        "options": {"num_predict": max_tokens, "temperature": temperature},
    }).encode()
    req = urllib.request.Request(OLLAMA_URL, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        parsed = json.loads(resp.read().decode())
    text = parsed["response"].strip().strip('"').strip()
    if text.startswith(f"{speaker}:"):
        text = text[len(speaker) + 1:].strip()
    return text


# ── run a real scripted scenario ────────────────────────────────────────────
import random

if __name__ == "__main__":
    rng = random.Random(7)

    print("=" * 78)
    print("SCENARIO: 'Mok' (Steady personality) witnesses the Leader betray a")
    print("tribemate, then the tribe comes under raid (panic/stress).")
    print("=" * 78)

    brain = Spikeling()
    brain.load_from_text(STEADY_BRAIN)
    core_memory = NPCCoreMemory(rng)

    # NOTE ON TIMING: spikeling.gd's step() delivers synaptic propagation on
    # the FOLLOWING step, not the one where the source neuron fires (see the
    # real comment in spikeling.gd: "propagate to targets next step" -- the
    # same real-game behavior test_tribe_drums.gd's own test comment
    # documents). Printing Trust immediately after stimulate()+step() would
    # show STALE state; each event below gets a settle step so the printed
    # numbers are honest.

    # normal life: a real positive interaction first
    brain.stimulate("SawContribute", 60.0)
    brain.step()                      # SawContribute fires now
    brain.step()                      # +80 to Trust lands this tick
    print(f"\n[tick] Leader gave a gift.  Trust = {brain.get_potential('Trust'):.1f}")

    # the betrayal (tribemember.gd's betray(), verbatim: SawBetray, weight -160)
    brain.stimulate("SawBetray", 80.0)
    betrayed_count = 1
    brain.step()                      # SawBetray fires now
    brain.step()                      # -160 to Trust lands this tick
    print(f"[tick] BETRAYAL LANDS.  Trust = {brain.get_potential('Trust'):.1f}"
          f"  (real -160 synapse slam -- can go transiently negative; the leak-clamp"
          f" in spikeling.gd's step() only floors the LEAK subtraction, not the total,"
          f" so this genuinely can and does read negative for exactly one tick)")
    brain.step()                      # settle: the leak-clamp floors it back to 0 next tick
    print(f"[tick] settles.  Trust = {brain.get_potential('Trust'):.1f}  (rebuilds from 0 from here)")

    # the SSH core-memory write -- this exact betrayal, anchored at an EDGE slot
    core_memory.remember("betrayal:Rin", True)

    # Mok is calm right now (no raid), so recall should be vivid -- the panic/
    # degradation case is demonstrated separately below across real stress
    # levels, rather than reusing this same instance for both.

    persona = f"You are Steady and even-tempered. Your standing with the leader is 'Wary'. " \
              f"{brain_snapshot(brain, betrayed_count)}{core_memory_blame_line(core_memory)}"
    print(f"\n[real persona string sent to the LLM]\n  {persona}")

    prompt = build_prompt("Mok", persona,
                           memories="You have no other specific memories recorded right now.",
                           situation="The Leader just walked up and asked how you're feeling about them.",
                           roster="Mok, Rin, Zeta, the Leader")

    print(f"\n[calling real local Ollama, model={MODEL} ...]")
    reply = call_ollama(prompt, speaker="Mok")
    print(f"\nMok says: \"{reply}\"")

    print("\n" + "=" * 78)
    print("THE UNDERLYING SSH FINDING: EDGE memories (1-2 hops from a chain")
    print("boundary) vs BULK memories (5-6 hops) under the SAME real panic.")
    print("core_memory_blame_line() only ever surfaces EDGE/core tags in")
    print("dialogue (by design -- see npc_core_memory.gd's docstring), so this")
    print("part prints the real recall() confidence directly instead of")
    print("routing a bulk memory through a function that would never show it.")
    print("=" * 78)

    for stress in (0.0, 0.4, 0.8):
        cm = NPCCoreMemory(random.Random(7))  # same seed every stress level, fair comparison
        cm.remember("betrayal:Rin", True)        # EDGE slot
        cm.remember("declined_trade:Zeta", False)  # BULK slot
        cm.apply_stress(stress)
        edge_conf = cm.recall("betrayal:Rin")
        bulk_conf = cm.recall("declined_trade:Zeta")
        print(f"\n  stress={stress:.1f}:  edge confidence={edge_conf:.3f}   bulk confidence={bulk_conf:.3f}"
              f"   (blame-line threshold is 0.08 -- edge {'clears' if edge_conf >= 0.08 else 'MISSES'} it,"
              f" bulk {'clears' if bulk_conf >= 0.08 else 'MISSES'} it)")
