# Implementation Plan

The first implementation goal is **trajectory collection and human inspection**, not model training.

## Required scripts

### 1. collect_rollouts.py

Run one model on one OSWorld-Verified task set while preserving official/default agent behavior.

For every step save:

- screenshot before action,
- full raw model output,
- extracted reasoning field if the output format exposes one,
- raw and executed action,
- screenshot after action,
- token usage if available,
- latency,
- final task result.

Do not perform semantic analysis inside the collector.

### 2. build_trajectory_report.py

Generate a human-readable `report.html` for every task.

The report should let a researcher scroll through the trajectory and directly see:

```text
Screenshot_t
Reason_t
Action_t
Screenshot_{t+1}
Reason_{t+1}
Action_{t+1}
...
```

Design requirements:

- show screenshots at readable size,
- preserve complete reasoning text,
- show raw model output in expandable sections,
- display action and latency/token metadata,
- make consecutive reasoning steps easy to compare,
- include task success/failure at the top,
- provide next/previous step navigation or a single chronological page.

This report is mandatory for the pilot because the first question is whether redundancy is visually obvious to a human.

### 3. semanticize_actions.py

Convert raw benchmark actions into the shared semantic schema while retaining raw actions.

### 4. extract_future_actions.py

Parse explicit current/future action intents from reasoning.

Important: never expose future screenshots or future actions to this parser.

### 5. align_actions.py

Align parsed action intents with actually executed semantic actions.

### 6. compute_metrics.py

Compute:

- MAPR,
- FAC@1...5,
- RRH,
- RRO,
- token/latency statistics,
- success/failure breakdown,
- task-length breakdown,
- within-family scaling comparisons.

### 7. sample_human_validation.py

Sample 200-300 reasoning steps for manual annotation and parser validation.

## Recommended output layout

```text
data/
  raw/
    <model>/<task_id>/
      meta.json
      trajectory.jsonl
      report.html
      step_000/
      step_001/
      ...
  semantic_actions/
  parsed_reasoning/
  alignments/
  human_validation/
```

Never overwrite raw rollout artifacts with derived annotations.
