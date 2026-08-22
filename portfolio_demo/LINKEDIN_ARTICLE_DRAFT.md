# A spiking neural network is the brain. A local LLM is just its voice.

Most game NPCs "remember" things through a flag: `has_grudge = true`. Mine don't.

I built Tribe, a Godot NPC trust/loyalty simulation where every member's brain is
a real spiking neural network — leaky integrate-and-fire neurons, membrane
potential, synaptic weights, the whole mechanism — not a behavior tree wearing a
neuroscience name. A local LLM sits on top of it, but it never invents a
personality. It reads live numbers off the actual network and turns them into
sentences.

## Personality is literally a different brain

Each NPC personality — Steady, Wary, Trusting, Brave, Greedy — is a different
set of neuron leak rates and synapse weights, not a different dialogue script.
A "Trusting" member has a stronger contribute→trust synapse and a
slower-leaking Trust neuron than a "Wary" one. Two NPCs with the same social
rank sound different because their underlying Trust neurons genuinely hold
different values.

## The memory system has a real physics finding underneath it

This is the part I'm most proud of. A prior simulation study I ran — an SSH
(Su-Schrieffer-Heeger) topological chain protects information at its *edges*
against disorder far better than in its *bulk* — is wired into an actual
gameplay feature, not just cited in a paper. Each NPC gets a small SSH-style
chain as its "core memory." A witnessed betrayal is written to an edge slot.
A routine slight goes to a bulk slot. Real panic jitters the chain's synapse
weights — the same disorder mechanism the original physics experiment
measured. The result: a panicked NPC mid-raid still reliably recalls "the
leader let my friend die," while petty grudges wash out under the exact same
stress.

## The LLM only ever reads. It never writes.

A local Ollama model (llama3.2) generates each NPC's dialogue — but the
dependency runs one way. It's handed a real numeric snapshot of the SNN
(the Trust neuron's membrane potential, the memory chain's recall
confidence) turned into plain sentences, and told to speak from it. It never
touches the network itself.

Here's a real, unedited run — a betrayal event, the SNN updating, and the
actual local LLM call:

```
[real persona string sent to the LLM]
You are Steady and even-tempered. Your standing with the leader is 'Wary'.
Your trust in the Leader currently sits around 0 out of 100. You are not
currently backing them. The Leader has struck you 1 time. You have not
forgotten it. You vividly remember you killing Rin with your own hands --
it colors how much you trust the Leader right now, and you should let it show.

Mok says: "I'm still sore from when you hurt me."
```

That line was never written by me. It came out of a local model reading real
numbers off a real spiking network.

## Verifying it surfaced two genuine quirks — I kept both

Building the write-up, I ported the exact GDScript logic to Python so I could
run and verify it directly. That caught a real one-tick synaptic propagation
delay I'd initially mis-traced (a fired neuron's effect lands *next* tick, not
this one — same as any real spiking system), and a genuinely interesting
detail already living in the shipped code: Trust can transiently swing
negative for exactly one tick after a betrayal, before the leak-clamp settles
it back toward zero. Both are real, both are documented, and both stayed in
the final write-up instead of getting smoothed over.

---

Full technical write-up (real code, a real diagram, and the complete verified
run): link in comments.

#gamedev #neuromorphiccomputing #spikingneuralnetworks #godot #machinelearning
