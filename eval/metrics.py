"""Compare runs: python -m eval.metrics  -> prints a markdown table for the README.

Reads eval/logs/sim_static.jsonl and eval/logs/sim_prism.jsonl written by the simulator.
"PHI to cloud" counts PHI requests whose answering model was not the local model.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import pandas as pd

LOCAL_PREFIX = ("qwen", "llama3.2", "ollama")


def load(mode: str) -> pd.DataFrame:
    p = Path("eval/logs") / f"sim_{mode}.jsonl"
    if not p.exists():
        return pd.DataFrame()
    return pd.DataFrame([json.loads(l) for l in p.read_text().splitlines() if l.strip()])


def summarize(df: pd.DataFrame) -> dict:
    if df.empty:
        return {}
    phi = df[df.has_phi]
    leaked = phi[~phi.served_model.fillna("").str.lower().str.startswith(LOCAL_PREFIX)]
    emerg = df[(df.priority == "emergency") & df.ok]
    return {
        "requests": len(df),
        "success_%": round(100 * df.ok.mean(), 1),
        "phi_to_cloud": int(len(leaked)),
        "emergency_p95_ms": int(emerg.latency_ms.quantile(0.95)) if len(emerg) else None,
        "all_p50_ms": int(df[df.ok].latency_ms.median()) if df.ok.any() else None,
        "served_by": df.served_model.value_counts().to_dict(),
    }


if __name__ == "__main__":
    rows = {m: summarize(load(m)) for m in ("static", "prism")}
    keys = ["requests", "success_%", "phi_to_cloud", "emergency_p95_ms", "all_p50_ms"]
    print("| Metric | Static | PRISM-Gate |\n| --- | --- | --- |")
    for k in keys:
        print(f"| {k} | {rows['static'].get(k, '-')} | {rows['prism'].get(k, '-')} |")
    for m, r in rows.items():
        print(f"\n{m} served_by: {r.get('served_by', {})}", file=sys.stderr)
