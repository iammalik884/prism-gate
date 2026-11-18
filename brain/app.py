"""PRISM-Gate brain service (FastAPI).

POST /decide    called by the Bifrost plugin before routing (must answer < 50 ms)
POST /feedback  called by the plugin after each attempt (bandit reward)
POST /verify    Freshness Check for an answer (PS-06)
GET  /stats     numbers for the dashboard
GET  /health

Run: uvicorn brain.app:app --port 8090
"""
from __future__ import annotations

import json
import os
import time
import uuid
from collections import deque
from pathlib import Path

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

from .phi_guard import PHIGuard, mask
from .router_linucb import LinUCBRouter, features, load_arms, reward

ROOT = Path(__file__).resolve().parent.parent
ARMS_FILE = os.getenv("PRISM_ARMS", str(ROOT / "config" / "arms.json"))
LOG_FILE = Path(os.getenv("PRISM_LOG", str(ROOT / "eval" / "logs" / "decisions.jsonl")))
LOCAL_KEY = os.getenv("PRISM_LOCAL_ARM", "ollama/qwen2.5:1.5b")

app = FastAPI(title="PRISM-Gate brain")
guard = PHIGuard(use_presidio=os.getenv("PRISM_PRESIDIO", "1") == "1")
guard.scan("warm up for Ahmed Raza in Lahore")  # load the NLP model now, not on the first request
router = LinUCBRouter(load_arms(ARMS_FILE))
pending: dict[str, dict] = {}            # decision id -> context for the reward update
recent = deque(maxlen=500)               # recent decisions for the dashboard
counters = {"requests": 0, "phi_kept_local": 0, "by_priority": {}}
fail_streak: dict[str, int] = {}         # circuit breaker: consecutive failures per arm
disabled_until: dict[str, float] = {}
BREAKER_FAILS, BREAKER_SECONDS = 3, 60
LOG_FILE.parent.mkdir(parents=True, exist_ok=True)


class DecideIn(BaseModel):
    text: str = ""
    priority_hint: str = "routine"
    department: str | None = None
    provider: str = ""
    model: str = ""


class FeedbackIn(BaseModel):
    decision_id: str = ""
    priority: str = "routine"
    provider: str = ""
    model: str = ""
    success: bool = True
    latency_ms: int = 0
    prompt_tokens: int = 0
    completion_tokens: int = 0


class VerifyIn(BaseModel):
    answer: str
    max_claims: int = 8


def _log(event: dict) -> None:
    with LOG_FILE.open("a") as f:
        f.write(json.dumps(event) + "\n")


@app.get("/health")
def health():
    return {"ok": True, "presidio": guard.presidio_enabled, "arms": [a.key for a in router.arms]}


@app.post("/decide")
def decide(body: DecideIn):
    t0 = time.perf_counter()
    did = uuid.uuid4().hex[:12]
    phi = guard.scan(body.text)
    priority = body.priority_hint or "routine"
    counters["requests"] += 1
    counters["by_priority"][priority] = counters["by_priority"].get(priority, 0) + 1

    if phi.phi:
        provider, model = LOCAL_KEY.split("/", 1)
        reason = "phi->local"
        counters["phi_kept_local"] += 1
        scores = {}
    else:
        x = features(priority, False, len(body.text))
        arm, scores = router.choose(x)
        provider, model, reason = arm.provider, arm.model, "linucb"
        pending[did] = {"x": x.tolist(), "arm": arm.key, "t": time.time()}

    # re-enable arms whose breaker cooled down
    for k, until in list(disabled_until.items()):
        if time.time() >= until:
            router.disabled.discard(k)
            disabled_until.pop(k, None)

    out = {"id": did, "phi": phi.phi, "phi_types": phi.types, "priority": priority,
           "provider": provider, "model": model, "reason": reason}
    ms = (time.perf_counter() - t0) * 1000
    event = {**out, "ts": time.time(), "decide_ms": round(ms, 2), "department": body.department,
             "scores": {k: round(v, 4) for k, v in scores.items()}}
    recent.append(event)
    _log({"type": "decision", **event})  # no prompt text is logged
    return out


@app.post("/feedback")
def feedback(body: FeedbackIn):
    ctx = pending.pop(body.decision_id, None)
    _log({"type": "feedback", "ts": time.time(), **body.model_dump()})
    if ctx is None:  # PHI/local decisions are not learned from
        return {"learned": False}
    import numpy as np

    arm_key = f"{body.provider}/{body.model}"
    if arm_key != ctx["arm"]:  # Bifrost fell back to another arm: credit the arm that ran
        arm_key = arm_key if arm_key in router.A else ctx["arm"]
    if body.success:
        fail_streak[arm_key] = 0
    else:
        fail_streak[arm_key] = fail_streak.get(arm_key, 0) + 1
        if fail_streak[arm_key] >= BREAKER_FAILS:  # stop sending traffic for a while
            router.disabled.add(arm_key)
            disabled_until[arm_key] = time.time() + BREAKER_SECONDS
    tokens = body.prompt_tokens + body.completion_tokens
    r = reward(body.success, body.priority, body.latency_ms, router.cost_norm(arm_key, tokens))
    router.update(arm_key, np.array(ctx["x"]), r)
    return {"learned": True, "reward": r}


@app.post("/verify")
def verify(body: VerifyIn):
    from .freshness import check_answer

    if not os.getenv("TAVILY_API_KEY"):
        raise HTTPException(500, "TAVILY_API_KEY is not set")
    # The answer goes to Tavily and to cloud checkers: mask identifiers first.
    result = check_answer(mask(body.answer), body.max_claims)
    _log({"type": "verify", "ts": time.time(), "overall": result["overall_score"], "checked": result["checked_claims"]})
    return result


class ArmIn(BaseModel):
    arm: str
    seconds: int = 120


@app.post("/admin/disable")
def admin_disable(body: ArmIn):
    """Simulated health-check failure for the outage demo (documented in the README)."""
    router.disabled.add(body.arm)
    disabled_until[body.arm] = time.time() + body.seconds
    _log({"type": "admin_disable", "ts": time.time(), "arm": body.arm})
    return {"disabled": sorted(router.disabled)}


@app.get("/stats")
def stats():
    return {"counters": counters, "router": router.stats(), "recent": list(recent)[-100:]}
