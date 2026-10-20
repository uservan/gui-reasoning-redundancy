# Motivation Experiment: Cross-Step Reasoning Redundancy in GUI Agents

## 1. Goal

Test whether modern GUI agents repeatedly recompute action plans that were already present in earlier reasoning.

The standard loop is:

```text
Observe_t -> Reason_t -> Action_t -> Observe_{t+1} -> Reason_{t+1} -> Action_{t+1}
```

Our hypothesis is that `Reason_t` often already contains several future executable intents, while later reasoning steps repeatedly derive part of the same plan.

This stage is **motivation only**. Do not train a JEV, executor, or replacement policy yet.

## 2. Models

Primary model set:

- EvoCUA-8B
- EvoCUA-32B
- UI-Mate-9B
- UI-Mate-27B

Use the same OSWorld-Verified task IDs across all models.

A model is eligible for the main reasoning-redundancy analysis only if its harness exposes textual planning/reasoning actually produced during inference. Do not reconstruct hidden CoT after the fact.

## 3. Benchmark

Primary benchmark:

- OSWorld-Verified

Keep task IDs, environment initialization, maximum step budget, evaluator version, official/default agent prompt, action parser, and decoding settings fixed as much as possible.

Only logging/instrumentation may be added.

## 4. Pilot

First run the same **30 tasks** for all four models.

Before building a large automatic analysis pipeline, manually inspect roughly **100-200 reasoning steps**.

Questions:

1. Does one reasoning step visibly contain multiple executable future actions?
2. Do later reasoning steps visibly repeat already stated action intents?
3. Is the exposed reasoning structured enough to parse reliably?
4. Is the phenomenon common enough to justify the full study?

If the pilot is overwhelmingly one-step-only, stop before scaling.

## 5. Raw trajectory preservation

Every rollout must be saved in a form that can be directly inspected by a human.

For each task create a self-contained trajectory folder:

```text
trajectories/
  <model>/
    <task_id>/
      meta.json
      trajectory.jsonl
      report.html
      step_000/
        before.png
        after.png
        raw_output.txt
        reasoning.txt
        action.json
      step_001/
        ...
```

### trajectory.jsonl

Every line stores one interaction step:

```json
{
  "task_id": "...",
  "model": "EvoCUA-32B",
  "step": 12,
  "instruction": "...",
  "screenshot_before": "step_012/before.png",
  "raw_model_output": "...",
  "reasoning": "...",
  "raw_action": "...",
  "executed_action": "...",
  "screenshot_after": "step_012/after.png",
  "input_tokens": 0,
  "output_tokens": 0,
  "reasoning_tokens": 0,
  "latency_ms": 0,
  "task_success": false
}
```

Always preserve the raw model output and raw action. Derived annotations must be stored separately.

## 6. Human-readable trajectory report

In addition to raw JSONL, generate **report.html** for every task so the researcher can visually inspect the rollout without writing code.

Each step should show, in order:

1. task instruction,
2. step index,
3. screenshot before action,
4. full raw model output,
5. extracted reasoning,
6. executed action,
7. screenshot after action,
8. token count / latency if available.

The HTML should make sequential reasoning overlap easy to notice. For example, show `Reason_t` and `Reason_{t+1}` next to each other or place them in adjacent expandable cards.

Do not replace raw logs with the HTML; keep both.

## 7. Semantic action normalization

Normalize raw actions into a shared schema:

```text
CLICK(target)
TYPE(text, target)
SCROLL(direction)
PRESS(key)
HOTKEY(keys)
DRAG(source, target)
WAIT
DONE
OTHER(...)
```

For coordinate clicks, use the pre-action screenshot and coordinate to identify the semantic target.

Preserve both the raw and normalized action.

## 8. Parse future action intents from reasoning

For each `Reason_t`, extract only action intents explicitly stated by the model.

Allowed parser input:

- task instruction,
- current reasoning text.

Forbidden parser input:

- future actions,
- future screenshots,
- final task outcome.

Example output:

```json
{
  "current_action": {"type": "CLICK", "target": "Chrome menu"},
  "future_actions": [
    {"type": "CLICK", "target": "Settings"},
    {"type": "CLICK", "target": "Privacy and Security"}
  ]
}
```

Use conservative parsing. Prefer false negatives over invented future plans.

## 9. Core metrics

### Multi-Action Planning Rate (MAPR)

Fraction of reasoning steps containing at least two executable action intents.

### Future Action Coverage@k (FAC@k)

For `Reason_t`, measure how many of the next `k` actually executed actions were already specified.

Report FAC@1 through FAC@5.

### Reasoning Reuse Horizon (RRH)

Longest consecutive prefix of future executed actions already specified in `Reason_t`.

Example:

```text
Reason_t: A B C
Actual:   A B C D
RRH = 3
```

Report mean, median, CDF/histogram, and P(RRH>=2/3/5).

### Re-Reasoning Overlap (RRO)

Measure how much of a later reasoning step's action intent was already present in previous reasoning.

Example:

```text
Reason_t:      A B C D
Reason_{t+1}:    B C D
```

### Reasoning cost

Record reasoning/output tokens, wall-clock latency, total reasoner calls, and total reasoning cost per task.

At this stage call this **potentially reusable reasoning cost**, not saved cost.

## 10. Required controls

Report metrics for:

- all trajectories,
- successful trajectories,
- failed trajectories,
- short / medium / long tasks.

Compare:

- EvoCUA-8B vs EvoCUA-32B,
- UI-Mate-9B vs UI-Mate-27B.

Text similarity may be a secondary diagnostic only. The main analysis must operate on semantic action intents.

## 11. Human validation

Randomly sample at least **200-300 reasoning steps** across models and outcomes.

Human annotators label:

1. action intents explicitly present in reasoning,
2. whether future executed actions were already implied,
3. whether two action descriptions are semantically equivalent.

Report parser/alignment precision, recall, and F1.

## 12. Main figures

1. A real motivating trajectory showing repeated action plans across consecutive reasoning steps.
2. FAC@1...5 for all four models.
3. RRH distribution / CDF.
4. Scaling comparison for 8B->32B and 9B->27B.
5. Optional qualitative gallery linked directly to the saved `report.html` files.

## 13. Go / No-Go

Proceed only if both model families show meaningful multi-action reasoning, RRH is often >1, future-action coverage remains substantial beyond one step, and later reasoning repeatedly recomputes already stated intents.

Stop or reformulate if most reasoning is one-step-only, RRH is ~1, FAC@2/FAC@3 are near zero, or the phenomenon is confined to one model/prompt family.

## 14. What comes later

Only after motivation succeeds do we ask:

> Can one reasoning pass be reused across multiple evolving GUI states instead of recomputing expensive reasoning after every action?

The eventual method could be a lightweight executor, policy, classifier, JEV-style scorer, or something else. The motivation study should remain method-agnostic.
