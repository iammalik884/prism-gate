"""Synthetic hospital traffic for PRISM-Gate. All data is invented; no real patients.

Usage:
  python -m simulator.simulate --n 200 --mode prism            # through Bifrost + plugin
  python -m simulator.simulate --n 200 --mode static           # same prompts, plugin bypassed via header
  python -m simulator.simulate --n 200 --outage-at 100 --outage-arm groq/llama-3.3-70b-versatile

Writes one JSON line per request to eval/logs/sim_<mode>.jsonl.
"""
from __future__ import annotations

import argparse
import json
import random
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import httpx

BIFROST = "http://127.0.0.1:8080/v1/chat/completions"
BRAIN = "http://127.0.0.1:8090"
MIX = [("emergency", 0.05), ("clinical", 0.35), ("routine", 0.40), ("batch", 0.20)]
PHI_SHARE = 0.20

FIRST = ["Ahmed", "Ayesha", "Bilal", "Fatima", "Hassan", "Zainab", "Usman", "Maryam"]
LAST = ["Raza", "Khan", "Malik", "Iqbal", "Siddiqui", "Butt", "Chaudhry"]

PROMPTS = {
    "emergency": ["Adult with crushing chest pain and sweating for 20 minutes. Immediate steps?",
                  "Child with suspected anaphylaxis after peanuts. What first?",
                  "Possible overdose of paracetamol 4 hours ago. Urgent actions?"],
    "clinical": ["Usual adult dosage of amoxicillin for community pneumonia?",
                 "Drug interaction between warfarin and ciprofloxacin?",
                 "First-line treatment for newly diagnosed type 2 diabetes?",
                 "Current guideline target blood pressure for adults with diabetes?"],
    "routine": ["Write a short note reminding staff about hand hygiene.",
                "Explain hypertension to a patient in simple words.",
                "Draft a polite email to a medicine supplier about a late delivery."],
    "batch": ["Summarize all these discharge notes into one paragraph each: (note 1) stable, discharged. (note 2) follow-up in 2 weeks.",
              "Batch: convert these 5 lab values to plain language: Hb 11, WBC 9, Plt 250, Na 138, K 4.1."],
}


def make_request(rng: random.Random) -> dict:
    r, acc, pr = rng.random(), 0.0, "routine"
    for name, share in MIX:
        acc += share
        if r <= acc:
            pr = name
            break
    text = rng.choice(PROMPTS[pr])
    phi = rng.random() < PHI_SHARE
    if phi:
        cnic = f"{rng.randint(10000, 99999)}-{rng.randint(1000000, 9999999)}-{rng.randint(1, 9)}"
        text = f"Patient {rng.choice(FIRST)} {rng.choice(LAST)}, CNIC {cnic}, MRN: {rng.randint(10000, 99999)}. " + text
    return {"priority": pr, "has_phi": phi, "text": text}


def send(req: dict, mode: str, default_model: str) -> dict:
    headers = {"x-prism-priority": req["priority"]}
    if mode == "static":
        headers["x-prism-bypass"] = "1"  # documented: baseline runs use Bifrost without the plugin config
    t0 = time.perf_counter()
    try:
        r = httpx.post(BIFROST, headers=headers, timeout=120,
                       json={"model": default_model, "messages": [{"role": "user", "content": req["text"]}]})
        ok = r.status_code == 200
        body = r.json() if ok else {}
        model = body.get("model")
        err = None if ok else r.text[:200]
    except Exception as e:  # network errors count as failures
        ok, model, err = False, None, str(e)[:200]
    return {"priority": req["priority"], "has_phi": req["has_phi"], "ok": ok, "served_model": model,
            "latency_ms": round((time.perf_counter() - t0) * 1000), "error": err, "mode": mode, "ts": time.time()}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=200)
    ap.add_argument("--mode", choices=["prism", "static"], default="prism")
    ap.add_argument("--model", default="groq/llama-3.3-70b-versatile", help="model the app asks for")
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--outage-at", type=int, default=0, help="request index at which to disable an arm")
    ap.add_argument("--outage-arm", default="")
    args = ap.parse_args()

    rng = random.Random(args.seed)
    reqs = [make_request(rng) for _ in range(args.n)]
    out = Path("eval/logs") / f"sim_{args.mode}.jsonl"
    out.parent.mkdir(parents=True, exist_ok=True)

    with out.open("w") as f, ThreadPoolExecutor(args.workers) as pool:
        futures = []
        for i, req in enumerate(reqs):
            if args.outage_at and i == args.outage_at and args.outage_arm:
                httpx.post(f"{BRAIN}/admin/disable", json={"arm": args.outage_arm}, timeout=5)
                print(f"-- outage injected on {args.outage_arm} at request {i}")
            futures.append(pool.submit(send, req, args.mode, args.model))
            time.sleep(0.25)  # stay under free-tier rate limits
        for fut in futures:
            f.write(json.dumps(fut.result()) + "\n")
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
