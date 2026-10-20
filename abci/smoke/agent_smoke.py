#!/usr/bin/env python3
"""No-VM smoke test of one vLLM endpoint with its official agent (run on a compute node inside a PBS job, never on a login node).

For each bundled example screenshot (UI-Mate's resources/example_single_step: OSWorld step-0 screenshots at 1920x1080 with the
OSWorld task's own instruction) the official agent makes one step. The OpenAI client is wrapped only to record each raw
chat-completion response (content, reasoning_content, usage, latency); prompts, response parsing and decoding settings are the
agents' own. Writes <out>/steps.jsonl (one record per example) and <out>/summary.json.

usage: agent_smoke.py --family evocua|uimate --base-url http://127.0.0.1:8001/v1 --model EvoCUA-S2 --out DIR
"""
import argparse
import json
import os
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EXAMPLES = ROOT / "third_party" / "UI-Mate" / "resources" / "example_single_step"
RECORDS = []


def install_recorder():
    """Wrap openai.OpenAI so every chat.completions.create call is recorded; behaviour is unchanged."""
    import openai

    base = openai.OpenAI

    class RecordingOpenAI(base):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs)
            inner = self.chat.completions.create

            def create(*cargs, **ckwargs):
                t0 = time.time()
                resp = inner(*cargs, **ckwargs)
                dump = resp.model_dump() if hasattr(resp, "model_dump") else json.loads(resp.json())
                RECORDS.append({
                    "latency_s": round(time.time() - t0, 3),
                    "params": {k: v for k, v in ckwargs.items() if k != "messages"},
                    "n_messages": len(ckwargs.get("messages", [])),
                    "response": dump,
                })
                return resp

            self.chat.completions.create = create

    openai.OpenAI = RecordingOpenAI


def make_agent(family, base_url, model):
    if family == "evocua":
        sys.path.insert(0, str(ROOT / "third_party" / "EvoCUA"))
        os.environ["OPENAI_BASE_URL"] = base_url  # EvoCUA's call_llm reads these at call time
        os.environ["OPENAI_API_KEY"] = "EMPTY"
        from mm_agents.evocua.evocua_agent import EvoCUAAgent
        # the official OSWorld command in the EvoCUA README: S2 prompt, temperature 0.01, 4 history turns,
        # relative coordinates, resize factor 32, 50 steps; top_p / max_tokens are the runner's defaults (0.9 / 32768)
        return EvoCUAAgent(model=model, temperature=0.01, top_p=0.9, max_tokens=32768, prompt_style="S2",
                           max_history_turns=4, coordinate_type="relative", resize_factor=32, max_steps=50)
    sys.path.insert(0, str(ROOT / "third_party" / "UI-Mate"))
    from agents.ui_mate_agent import UIMateAgent
    # official defaults: max_tokens 16384, temperature 1.0, top_p 0.95, thinking enabled
    return UIMateAgent(base_url=base_url, model=model)


def message_of(record):
    try:
        return record["response"]["choices"][0]["message"] or {}
    except (KeyError, IndexError, TypeError):
        return {}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--family", choices=["evocua", "uimate"], required=True)
    ap.add_argument("--base-url", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    install_recorder()
    examples = json.loads((EXAMPLES / "examples.json").read_text())["examples"]

    rows = []
    with open(out / "steps.jsonl", "w") as fh:
        for ex in examples:
            agent = make_agent(args.family, args.base_url, args.model)  # a fresh agent per example: no history
            n0, t0, error = len(RECORDS), time.time(), None
            try:
                response, actions = agent.predict(ex["instruction"], {"screenshot": (EXAMPLES / ex["image"]).read_bytes()})
            except Exception as e:  # recorded, not raised: the summary shows which endpoint / example failed
                response, actions, error = None, None, repr(e)
            calls = RECORDS[n0:]
            msg = message_of(calls[-1]) if calls else {}
            content = msg.get("content") or ""
            reasoning = msg.get("reasoning_content") or msg.get("reasoning") or ""
            usage = (calls[-1]["response"].get("usage") or {}) if calls else {}
            row = {
                "example": ex["image"], "app": ex.get("app"), "osworld_task_id": ex.get("osworld_task_id"),
                "instruction": ex["instruction"], "error": error, "n_calls": len(calls),
                "wall_s": round(time.time() - t0, 3), "latency_s": calls[-1]["latency_s"] if calls else None,
                "prompt_tokens": usage.get("prompt_tokens"), "completion_tokens": usage.get("completion_tokens"),
                "finish_reason": (calls[-1]["response"]["choices"][0].get("finish_reason") if calls else None),
                "content_has_think_end": "</think>" in content,
                "think_chars": len(content.split("</think>")[0]) if "</think>" in content else 0,
                "reasoning_content_chars": len(reasoning),
                "actions": actions, "agent_response": response,
                "raw_calls": calls,
            }
            fh.write(json.dumps(row, ensure_ascii=False) + "\n")
            fh.flush()
            rows.append(row)
            print(f"[{args.family} {args.model}] {ex['image']}: error={error} think_chars={row['think_chars']} "
                  f"reasoning_content_chars={row['reasoning_content_chars']} completion_tokens={row['completion_tokens']} "
                  f"latency_s={row['latency_s']} actions={str(actions)[:160]}", flush=True)

    ok = [r for r in rows if r["error"] is None and r["actions"]]
    summary = {
        "family": args.family, "model": args.model, "base_url": args.base_url, "examples": len(rows),
        "no_error_with_actions": len(ok),
        "visible_reasoning": sum(1 for r in rows if r["think_chars"] > 0),
        "reasoning_moved_to_reasoning_content": sum(1 for r in rows if r["reasoning_content_chars"] > 0),
        "mean_latency_s": round(sum(r["latency_s"] for r in ok) / len(ok), 2) if ok else None,
        "mean_completion_tokens": round(sum(r["completion_tokens"] or 0 for r in ok) / len(ok), 1) if ok else None,
        "errors": [r["error"] for r in rows if r["error"]],
    }
    (out / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2))
    print(json.dumps(summary, ensure_ascii=False), flush=True)
    return 0 if len(ok) == len(rows) else 1


if __name__ == "__main__":
    sys.exit(main())
