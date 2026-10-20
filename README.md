# GUI Reasoning Redundancy

This repository studies **cross-step reasoning redundancy in GUI agents**.

Modern GUI agents often run a loop like:

```text
Observe_t -> Reason_t -> Action_t -> Observe_{t+1} -> Reason_{t+1} -> Action_{t+1}
```

Our hypothesis is that a single reasoning pass often already contains multiple future action intents, but after executing only one action the agent reasons again and recomputes part of the same plan.

The first stage is **motivation only**. We do **not** train a JEV, executor, or any replacement policy yet.

## Core research question

> Do strong GUI agents repeatedly recompute action plans that were already present in previous reasoning?

If the answer is yes, the later research direction is to reuse one reasoning pass across multiple evolving GUI states and return to the expensive reasoner only when the cached reasoning is no longer reliable.

## Initial model set

We use two model families and two sizes per family:

- EvoCUA-8B
- EvoCUA-32B
- UI-Mate-9B
- UI-Mate-27B

This allows both **cross-family analysis** and **within-family scaling analysis**.

## Primary benchmark

- **OSWorld-Verified**

Use the same task IDs, environment initialization, step budget, and official/default agent settings for all models whenever possible.

## Motivation metrics

1. Multi-Action Planning Rate
2. Future Action Coverage@k
3. Reasoning Reuse Horizon
4. Re-Reasoning Overlap
5. Reasoning token / latency cost

See [MOTIVATION.md](./MOTIVATION.md) for the full experimental protocol.

## Go / No-Go principle

If most reasoning only determines the immediate next action and reuse horizon is approximately 1, stop the project.

If multiple strong model families consistently show that one reasoning pass specifies several future actions and later reasoning recomputes those same intents, proceed to the method stage.

## Repository structure

```text
.
├── README.md
├── MOTIVATION.md
├── configs/
│   ├── models.yaml
│   └── tasks.json
├── scripts/
│   └── README.md
├── analysis/
│   └── README.md
└── results/
    └── README.md
```

## Current status

Planning / motivation stage only. No experimental result should be reported until trajectories have been collected and analyzed.
