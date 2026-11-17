#!/usr/bin/env bash
# Unpacks the PRISM-Gate skeleton (generated). Run once from the repo root: bash bootstrap.sh
set -euo pipefail
mkdir -p ".devcontainer"
cat > ".devcontainer/devcontainer.json" <<'PRISM_EOF'
{
  "name": "PRISM-Gate",
  "image": "mcr.microsoft.com/devcontainers/python:3.11-bookworm",
  "hostRequirements": { "cpus": 4, "memory": "16gb" },
  "postCreateCommand": "bash scripts/setup.sh",
  "forwardPorts": [8080, 8090, 8501],
  "portsAttributes": {
    "8080": { "label": "Bifrost" },
    "8090": { "label": "PRISM brain" },
    "8501": { "label": "Dashboard" }
  },
  "secrets": {
    "GROQ_API_KEY": { "description": "Groq API key (free tier)" },
    "GEMINI_API_KEY": { "description": "Google AI Studio key" },
    "TAVILY_API_KEY": { "description": "Tavily API key" }
  },
  "customizations": { "vscode": { "extensions": ["golang.go", "ms-python.python"] } }
}
PRISM_EOF
mkdir -p "."
cat > ".env.example" <<'PRISM_EOF'
# Copy to .env (never commit .env). In Codespaces you can use repository secrets instead.
GROQ_API_KEY=
GEMINI_API_KEY=
TAVILY_API_KEY=
BIFROST_URL=http://127.0.0.1:8080
PRISM_CHECKER_MODEL=groq/llama-3.1-8b-instant
PRISM_LOCAL_ARM=ollama/qwen2.5:1.5b
PRISM_PRESIDIO=1
PRISM_EOF
mkdir -p "."
cat > ".gitignore" <<'PRISM_EOF'
.env
.deps/
build/
.run/
.bifrost/
eval/logs/
__pycache__/
*.pyc
.pytest_cache/
*.so
PRISM_EOF
mkdir -p "."
cat > "CONTRIBUTING.md" <<'PRISM_EOF'
# Contributing

- Plugin code lives in `plugin/` (Go, package `main`). Keep pure logic (priority, admission, config) free of Bifrost imports so it is unit-testable.
- Brain code lives in `brain/` (Python 3.11). Never log raw prompt text; use `phi_guard.mask` if text must be logged.
- Run before a PR: `python -m pytest -q brain/tests` and `bash scripts/build.sh` (runs `go vet` and `go test`).
- Upstream path: the plugin can be proposed to Bifrost under `examples/plugins/prism-gate` with the brain as an optional sidecar.
PRISM_EOF
mkdir -p "."
cat > "README.md" <<'PRISM_EOF'
# PRISM-Gate

**Priority & Risk-aware Intelligent Scheduling for Models** — an open-source [Bifrost](https://github.com/maximhq/bifrost) plugin that lets hospitals use LLMs safely, with a [Tavily](https://tavily.com)-powered check for stale medical facts.

Built for the **Global AI Hackathon 2026 (Geek Room)**:
primary problem **PS-04 Bifrost — "Build a Feature the Open-Source Gateway Is Missing"**, integrated with **PS-06 Tavily — "Build a Stale-Answer Detector for AI Applications"**.

> Status: work in progress during the hackathon (16–21 Nov 2026). Results below are filled from our own runs only.

## The problem

Hospital teams want LLMs, but:

1. **Privacy** — prompts carry patient names, CNIC and MR numbers. These must not reach a cloud model. (PII guardrails are Enterprise-only in Bifrost.)
2. **Priority** — an emergency question waits in the same queue as a nightly batch job. (Bifrost has no request priority.)
3. **Cost and reliability** — static routing sends everything to one model. (Adaptive routing is Enterprise-only.)
4. **Stale answers** — models state old drug prices, approvals and guidelines as current.

## What PRISM-Gate adds

| Part | Where | What it does |
| --- | --- | --- |
| PHI Guard | brain (Python) | Regex for CNIC / MRN / +92 phones / emails / DOB, plus Microsoft Presidio. PHI found → request pinned to a **local Ollama model**, cloud fallbacks removed |
| Priority Gate | plugin (Go) | Emergency / Clinical / Routine / Batch; capacity reserved for Emergency |
| RL Router | brain (Python) | LinUCB contextual bandit picks provider/model per request type; reward from success, latency and cost; circuit breaker on repeated failures |
| Freshness Check | brain (Python) | Extracts claims (LLM via Bifrost) → live sources (Tavily) → verdict (LLM via Bifrost) → freshness score 0–100 |
| Dashboard | Streamlit | Routing log, PHI kept local, learning curve, claim checker |

Bifrost features we **reuse, not rebuild**: providers, fallbacks, routing rules, Ollama support.

### How Bifrost and Tavily each contribute

- **Bifrost** carries every model call: app traffic and the Freshness Check's own LLM calls. PRISM-Gate uses Bifrost's public plugin hooks (`HTTPTransportPreHook`, `PreRequestHook`, `PreLLMHook`, `PostLLMHook`).
- **Tavily** supplies the live web evidence that decides whether a claim is still current.

## Architecture

```
App ──► Bifrost (:8080) ── PRISM-Gate plugin ──► brain (:8090): PHI Guard · RL Router · Freshness
                │                                                     │
                ├──► Ollama (local, PHI only)                         └──► Tavily Search
                └──► Groq / Gemini (cloud arms)
```

Request flow: headers → `PreRequestHook` asks the brain (50 ms budget; if the brain is slow, the original route is kept) → provider/model set → `PreLLMHook` admission → provider call → `PostLLMHook` reports latency/tokens/success as the bandit reward.

## Quick start (GitHub Codespaces, recommended)

1. **Code → Codespaces → New codespace** (4-core / 16 GB). Setup runs automatically (`scripts/setup.sh`): pinned Bifrost source, the Go version Bifrost requires, Python packages, Ollama + `qwen2.5:1.5b`, then builds Bifrost (dynamic) and the plugin.
2. Add keys in `.env` (or as Codespaces secrets): `GROQ_API_KEY`, `GEMINI_API_KEY`, `TAVILY_API_KEY`.
3. Run:

```bash
bash scripts/run_all.sh      # Ollama, brain :8090, Bifrost :8080, dashboard :8501
bash scripts/smoke_test.sh   # PHI request -> local model; normal request -> bandit
```

Any Linux/macOS machine works the same way (`bash scripts/setup.sh`). Native Go plugins do not load on Windows.

### Why the plugin is built inside Bifrost's module

Go plugins only load if every shared package is identical to the host binary's. `scripts/build.sh` therefore compiles the plugin inside Bifrost's `transports` module (same `go.mod`, `go.sum`, Go version and flags) and checks that `bifrost-http` is dynamically linked.

## API

| Header | Values | Effect |
| --- | --- | --- |
| `x-prism-priority` | emergency, clinical, routine, batch | Priority class (keyword rules if absent) |
| `x-prism-department` | any | Logged for per-department reporting |
| `x-prism-bypass` | 1 | Baseline runs: plugin logic off |

Brain: `POST /decide`, `POST /feedback`, `POST /verify`, `GET /stats`, `POST /admin/disable` (simulated health-check failure for the outage demo).

## Evaluation

```bash
python -m simulator.simulate --n 200 --mode static
python -m simulator.simulate --n 200 --mode prism --outage-at 100 --outage-arm groq/llama-3.3-70b-versatile
python -m eval.metrics
```

All traffic is synthetic (invented names and IDs). Metrics: PHI requests answered by a cloud model (target 0), success rate, Emergency p95 latency, learned arm mix, stale-claim precision/recall on a hand-labelled set.

**Results:** _to be filled from our runs._

## Tests

```bash
python -m pytest -q brain/tests
bash scripts/build.sh          # also runs go vet + go test for the plugin
```

## Limits (stated honestly)

- Bandit quality signal = success + latency + cost; it does not grade answer quality yet.
- Costs in `config/arms.json` are relative units unless real prices are filled in.
- Regex PHI rules favour recall; false positives only cost a slower local answer.
- Not a medical device. Decision support for engineers and IT teams only.

## AI tools used

Claude (Anthropic) helped draft code and documentation; all code was reviewed and run by the author. Runtime models: Groq-hosted Llama, Google Gemini, local Qwen via Ollama.

## License

Apache-2.0, same as Bifrost.

Author: Usama Manzoor (MS IT, University of Sargodha) — research on priority-aware, privacy-preserving scheduling for healthcare edge computing.
PRISM_EOF
mkdir -p "brain"
cat > "brain/__init__.py" <<'PRISM_EOF'
PRISM_EOF
mkdir -p "brain"
cat > "brain/app.py" <<'PRISM_EOF'
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

from .phi_guard import PHIGuard
from .router_linucb import LinUCBRouter, features, load_arms, reward

ROOT = Path(__file__).resolve().parent.parent
ARMS_FILE = os.getenv("PRISM_ARMS", str(ROOT / "config" / "arms.json"))
LOG_FILE = Path(os.getenv("PRISM_LOG", str(ROOT / "eval" / "logs" / "decisions.jsonl")))
LOCAL_KEY = os.getenv("PRISM_LOCAL_ARM", "ollama/qwen2.5:1.5b")

app = FastAPI(title="PRISM-Gate brain")
guard = PHIGuard(use_presidio=os.getenv("PRISM_PRESIDIO", "1") == "1")
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
    result = check_answer(body.answer, body.max_claims)
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
PRISM_EOF
mkdir -p "brain/freshness"
cat > "brain/freshness/__init__.py" <<'PRISM_EOF'
from .pipeline import check_answer, freshness_score, label_for  # noqa: F401
PRISM_EOF
mkdir -p "brain/freshness"
cat > "brain/freshness/pipeline.py" <<'PRISM_EOF'
"""Freshness Check (Problem Statement 06): find stale claims in an LLM answer.

Steps
1. Extract atomic claims and tag time-sensitive ones  -> LLM call through Bifrost
2. Search live evidence for each time-sensitive claim  -> Tavily
3. Judge each claim against the evidence               -> LLM call through Bifrost
4. Score freshness 0-100 from verdict, source recency and source trust

Bifrost runs every model call (so routing, fallbacks and PRISM-Gate apply to
the checker itself); Tavily supplies the live sources.
"""
from __future__ import annotations

import json
import os
import re
from dataclasses import asdict, dataclass, field
from datetime import date, datetime
from urllib.parse import urlparse

import httpx

BIFROST_URL = os.getenv("BIFROST_URL", "http://127.0.0.1:8080")
CHECKER_MODEL = os.getenv("PRISM_CHECKER_MODEL", "groq/llama-3.1-8b-instant")

TIME_SENSITIVE = {"price", "approval_status", "guideline", "safety_warning", "organisation", "api_version", "regulation"}

TRUSTED_DOMAINS = (
    "who.int", "fda.gov", "nih.gov", "cdc.gov", "ema.europa.eu", "nice.org.uk",
    "dra.gov.pk", "health.gov.pk", "nhs.uk", "medlineplus.gov", "drugs.com",
)

EXTRACT_PROMPT = """Split the ANSWER into short atomic factual claims.
For each claim give a category from: price, approval_status, guideline, safety_warning,
organisation, api_version, regulation, stable.
Use "stable" for facts that do not change over time (anatomy, definitions).
Return ONLY JSON: {"claims":[{"text":"...","category":"..."}]}

ANSWER:
"""

JUDGE_PROMPT = """You check whether a CLAIM is still true today ({today}) using only the SOURCES.
Reply ONLY JSON: {{"verdict":"supported|contradicted|unclear","correction":"...","why":"..."}}
- supported: sources from recent dates agree with the claim
- contradicted: sources show the claim is outdated or wrong; give the current fact in "correction"
- unclear: sources do not settle it

CLAIM: {claim}

SOURCES:
{sources}
"""


@dataclass
class Evidence:
    title: str
    url: str
    snippet: str
    published: str | None = None


@dataclass
class ClaimResult:
    text: str
    category: str
    time_sensitive: bool
    verdict: str = "not_checked"
    correction: str = ""
    score: int | None = None
    label: str = "stable"
    sources: list[Evidence] = field(default_factory=list)


def _llm(messages: list[dict], timeout: float = 60.0) -> str:
    r = httpx.post(
        f"{BIFROST_URL}/v1/chat/completions",
        json={"model": CHECKER_MODEL, "messages": messages, "temperature": 0},
        headers={"x-prism-priority": "routine"},
        timeout=timeout,
    )
    r.raise_for_status()
    return r.json()["choices"][0]["message"]["content"]


def _json_from(text: str) -> dict:
    m = re.search(r"\{.*\}", text, re.S)
    if not m:
        raise ValueError("model did not return JSON")
    return json.loads(m.group(0))


def extract_claims(answer: str) -> list[ClaimResult]:
    data = _json_from(_llm([{"role": "user", "content": EXTRACT_PROMPT + answer}]))
    out = []
    for c in data.get("claims", []):
        cat = str(c.get("category", "stable")).strip().lower()
        out.append(ClaimResult(text=c.get("text", "").strip(), category=cat, time_sensitive=cat in TIME_SENSITIVE))
    return [c for c in out if c.text]


def search_evidence(claim: str, max_results: int = 5) -> list[Evidence]:
    from tavily import TavilyClient  # imported here so tests run without the SDK

    client = TavilyClient(api_key=os.environ["TAVILY_API_KEY"])
    res = client.search(query=claim, max_results=max_results, search_depth="basic")
    return [
        Evidence(title=r.get("title", ""), url=r.get("url", ""), snippet=(r.get("content") or "")[:600],
                 published=r.get("published_date"))
        for r in res.get("results", [])
    ]


def _age_days(published: str | None, today: date) -> int | None:
    if not published:
        return None
    try:  # ISO style: 2026-11-02 or 2026-11-02T10:00:00
        return (today - date.fromisoformat(published.strip()[:10])).days
    except ValueError:
        pass
    try:  # RFC 2822 style: "Mon, 02 Nov 2026 10:00:00 GMT"
        from email.utils import parsedate_to_datetime
        return (today - parsedate_to_datetime(published).date()).days
    except (TypeError, ValueError):
        return None


def _trusted(url: str) -> bool:
    host = urlparse(url).netloc.lower()
    return any(host == d or host.endswith("." + d) for d in TRUSTED_DOMAINS)


def freshness_score(verdict: str, sources: list[Evidence], today: date | None = None) -> int:
    """0-100. Verdict sets the base; recent and trusted sources move it."""
    today = today or date.today()
    base = {"supported": 80, "unclear": 45, "contradicted": 10}.get(verdict, 45)
    ages = [a for a in (_age_days(s.published, today) for s in sources) if a is not None]
    if ages:
        newest = min(ages)
        if newest <= 180:
            base += 10
        elif newest > 730:
            base -= 10
    if any(_trusted(s.url) for s in sources):
        base += 10 if verdict == "supported" else 0
    return int(max(0, min(100, base)))


def label_for(score: int | None) -> str:
    if score is None:
        return "stable"
    return "current" if score >= 70 else ("check" if score >= 40 else "stale")


def judge(claim: ClaimResult, today: date | None = None) -> ClaimResult:
    today = today or date.today()
    srcs = "\n".join(f"[{i+1}] {s.title} ({s.published or 'date unknown'}) {s.url}\n{s.snippet}"
                     for i, s in enumerate(claim.sources)) or "(no sources found)"
    data = _json_from(_llm([{"role": "user", "content": JUDGE_PROMPT.format(today=today.isoformat(), claim=claim.text, sources=srcs)}]))
    claim.verdict = str(data.get("verdict", "unclear")).lower()
    claim.correction = data.get("correction", "") or ""
    claim.score = freshness_score(claim.verdict, claim.sources, today)
    claim.label = label_for(claim.score)
    return claim


def check_answer(answer: str, max_claims: int = 8) -> dict:
    claims = extract_claims(answer)
    checked = 0
    for c in claims:
        if not c.time_sensitive or checked >= max_claims:
            continue
        c.sources = search_evidence(c.text)
        judge(c)
        checked += 1
    scored = [c.score for c in claims if c.score is not None]
    return {
        "overall_score": round(sum(scored) / len(scored)) if scored else None,
        "checked_claims": checked,
        "claims": [asdict(c) for c in claims],
    }
PRISM_EOF
mkdir -p "brain"
cat > "brain/phi_guard.py" <<'PRISM_EOF'
"""PHI Guard: detects patient data in a prompt.

Two layers:
1. Regex rules that always run (fast, no model): Pakistani CNIC, MR numbers,
   +92 phone numbers, emails, dates of birth.
2. Microsoft Presidio (optional, if installed) for names, locations, dates.

Recall matters more than precision here: a missed identifier means patient
data could reach a cloud model, while a false alarm only costs a slower
local answer.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field

RULES: dict[str, re.Pattern] = {
    "PK_CNIC": re.compile(r"\b\d{5}-\d{7}-\d\b|\b\d{13}\b"),
    "MRN": re.compile(r"\b(?:MRN|MR\s?No\.?|MR#|medical record(?: number)?)\s*[:#-]?\s*[A-Z0-9-]{4,12}\b", re.I),
    "PK_PHONE": re.compile(r"(?:\+92|0092|\b0)3\d{2}[-\s]?\d{7}\b"),
    "EMAIL": re.compile(r"\b[\w.+-]+@[\w-]+\.[\w.-]+\b"),
    "DOB": re.compile(r"\b(?:DOB|D\.O\.B\.?|date of birth)\s*[:-]?\s*\d{1,2}[/-]\d{1,2}[/-]\d{2,4}\b", re.I),
    "NAMED_PATIENT": re.compile(r"\b(?i:patient|pt\.?|mr\.?|mrs\.?|ms\.?)\s+[A-Z][a-z]+(?:\s+[A-Z][a-z]+)?\b"),
}

PRESIDIO_ENTITIES = ["PERSON", "PHONE_NUMBER", "EMAIL_ADDRESS", "DATE_TIME", "LOCATION"]
PRESIDIO_MIN_SCORE = 0.6


@dataclass
class PHIResult:
    phi: bool
    types: list[str] = field(default_factory=list)
    count: int = 0


class PHIGuard:
    def __init__(self, use_presidio: bool = True):
        self._analyzer = None
        if use_presidio:
            try:
                from presidio_analyzer import AnalyzerEngine
                from presidio_analyzer.nlp_engine import NlpEngineProvider

                provider = NlpEngineProvider(nlp_configuration={
                    "nlp_engine_name": "spacy",
                    "models": [{"lang_code": "en", "model_name": "en_core_web_sm"}],
                })
                self._analyzer = AnalyzerEngine(nlp_engine=provider.create_engine())
            except Exception:  # Presidio or the spaCy model missing: regex only
                self._analyzer = None

    @property
    def presidio_enabled(self) -> bool:
        return self._analyzer is not None

    def scan(self, text: str) -> PHIResult:
        if not text:
            return PHIResult(phi=False)
        found: list[str] = []
        for name, pattern in RULES.items():
            found += [name] * len(pattern.findall(text))
        if self._analyzer is not None:
            for r in self._analyzer.analyze(text=text, entities=PRESIDIO_ENTITIES, language="en"):
                # DATE_TIME alone ("today", "2 weeks") is not PHI; count it only with another hit.
                if r.score >= PRESIDIO_MIN_SCORE and r.entity_type != "DATE_TIME":
                    found.append(r.entity_type)
        return PHIResult(phi=bool(found), types=sorted(set(found)), count=len(found))


def mask(text: str) -> str:
    """Replace regex-detected identifiers with tags (used for logs, never raw PHI)."""
    for name, pattern in RULES.items():
        text = pattern.sub(f"<{name}>", text)
    return text
PRISM_EOF
mkdir -p "brain"
cat > "brain/router_linucb.py" <<'PRISM_EOF'
"""RL Router: a LinUCB contextual bandit that picks a (provider, model) arm.

Context features (9): one-hot priority (4), PHI flag, prompt-length bucket (3), bias.
Reward in [0, 1]: 0 on failure; on success 1 minus weighted latency and cost
penalties. The weights depend on priority: Emergency cares most about latency,
Batch most about cost.

Cost uses relative units from config/arms.json (not USD) unless real prices
are filled in there.
"""
from __future__ import annotations

import json
import threading
from dataclasses import dataclass
from pathlib import Path

import numpy as np

PRIORITIES = ["emergency", "clinical", "routine", "batch"]
LATENCY_CAP_MS = 10_000.0

# (latency weight, cost weight) per priority
WEIGHTS = {
    "emergency": (0.7, 0.1),
    "clinical": (0.4, 0.3),
    "routine": (0.3, 0.5),
    "batch": (0.1, 0.8),
}


@dataclass
class Arm:
    provider: str
    model: str
    relative_cost: float  # per 1k tokens, relative units; normalised by the max arm

    @property
    def key(self) -> str:
        return f"{self.provider}/{self.model}"


def load_arms(path: str | Path) -> list[Arm]:
    data = json.loads(Path(path).read_text())
    return [Arm(a["provider"], a["model"], float(a["relative_cost"])) for a in data["arms"]]


def features(priority: str, phi: bool, prompt_chars: int) -> np.ndarray:
    x = np.zeros(9)
    x[PRIORITIES.index(priority) if priority in PRIORITIES else 2] = 1.0
    x[4] = 1.0 if phi else 0.0
    bucket = 0 if prompt_chars < 500 else (1 if prompt_chars < 3000 else 2)
    x[5 + bucket] = 1.0
    x[8] = 1.0
    return x


def reward(success: bool, priority: str, latency_ms: float, cost_norm: float) -> float:
    if not success:
        return 0.0
    w_lat, w_cost = WEIGHTS.get(priority, WEIGHTS["routine"])
    lat = min(latency_ms / LATENCY_CAP_MS, 1.0)
    return float(max(0.0, 1.0 - w_lat * lat - w_cost * min(cost_norm, 1.0)))


class LinUCBRouter:
    def __init__(self, arms: list[Arm], alpha: float = 0.6, dim: int = 9):
        if not arms:
            raise ValueError("at least one arm is required")
        self.arms = arms
        self.alpha = alpha
        self.dim = dim
        self.A = {a.key: np.identity(dim) for a in arms}
        self.b = {a.key: np.zeros(dim) for a in arms}
        self.pulls = {a.key: 0 for a in arms}
        self.total_reward = 0.0
        self.history: list[dict] = []  # for the learning curve
        self.disabled: set[str] = set()
        self._lock = threading.Lock()
        self._max_cost = max(a.relative_cost for a in arms) or 1.0

    def cost_norm(self, arm_key: str, tokens: int) -> float:
        arm = next(a for a in self.arms if a.key == arm_key)
        return (arm.relative_cost / self._max_cost) * min(tokens / 2000.0, 1.0)

    def choose(self, x: np.ndarray) -> tuple[Arm, dict[str, float]]:
        with self._lock:
            scores: dict[str, float] = {}
            for a in self.arms:
                if a.key in self.disabled:
                    continue
                A_inv = np.linalg.inv(self.A[a.key])
                theta = A_inv @ self.b[a.key]
                scores[a.key] = float(theta @ x + self.alpha * np.sqrt(x @ A_inv @ x))
            if not scores:  # everything disabled: fall back to all arms
                scores = {a.key: 0.0 for a in self.arms}
            best = max(scores, key=scores.get)
            return next(a for a in self.arms if a.key == best), scores

    def update(self, arm_key: str, x: np.ndarray, r: float) -> None:
        with self._lock:
            if arm_key not in self.A:
                return
            self.A[arm_key] += np.outer(x, x)
            self.b[arm_key] += r * x
            self.pulls[arm_key] += 1
            self.total_reward += r
            self.history.append({"n": len(self.history) + 1, "arm": arm_key, "reward": r})

    def stats(self) -> dict:
        with self._lock:
            n = len(self.history)
            return {
                "updates": n,
                "mean_reward": (self.total_reward / n) if n else None,
                "pulls": dict(self.pulls),
                "disabled": sorted(self.disabled),
                "recent": self.history[-200:],
            }
PRISM_EOF
mkdir -p "brain/tests"
cat > "brain/tests/__init__.py" <<'PRISM_EOF'
PRISM_EOF
mkdir -p "brain/tests"
cat > "brain/tests/test_brain.py" <<'PRISM_EOF'
from datetime import date

import numpy as np

from brain.freshness.pipeline import Evidence, freshness_score, label_for
from brain.phi_guard import PHIGuard, mask
from brain.router_linucb import Arm, LinUCBRouter, features, reward

guard = PHIGuard(use_presidio=False)


def test_phi_cnic_mrn_phone():
    r = guard.scan("Patient Ahmed Raza, CNIC 35202-1234567-1, MRN: 88231, call 0321-1234567")
    assert r.phi
    assert {"PK_CNIC", "MRN", "PK_PHONE", "NAMED_PATIENT"} <= set(r.types)


def test_no_phi_in_general_question():
    assert not guard.scan("What is the first-line treatment for type 2 diabetes?").phi


def test_mask_hides_identifiers():
    out = mask("CNIC 35202-1234567-1 email a.b@x.com")
    assert "35202" not in out and "a.b@x.com" not in out


def test_reward_shape():
    assert reward(False, "routine", 100, 0.1) == 0.0
    fast = reward(True, "emergency", 500, 0.5)
    slow = reward(True, "emergency", 9000, 0.5)
    assert 0 <= slow < fast <= 1


def test_bandit_learns_better_arm():
    arms = [Arm("p", "good", 1), Arm("p", "bad", 1)]
    r = LinUCBRouter(arms, alpha=0.3)
    x = features("routine", False, 100)
    rng = np.random.default_rng(0)
    for _ in range(300):
        arm, _ = r.choose(x)
        mean = 0.9 if arm.model == "good" else 0.3
        r.update(arm.key, x, float(np.clip(rng.normal(mean, 0.05), 0, 1)))
    assert r.pulls["p/good"] > r.pulls["p/bad"] * 3


def test_disabled_arm_is_skipped():
    r = LinUCBRouter([Arm("a", "x", 1), Arm("b", "y", 1)])
    r.disabled.add("a/x")
    arm, _ = r.choose(features("batch", False, 10))
    assert arm.key == "b/y"


def test_freshness_score_and_labels():
    today = date(2026, 11, 18)
    fresh_trusted = [Evidence("WHO", "https://www.who.int/news/x", "", "2026-10-01")]
    old = [Evidence("blog", "https://example.com/a", "", "2021-01-01")]
    assert freshness_score("supported", fresh_trusted, today) == 100
    assert freshness_score("contradicted", old, today) == 0
    assert label_for(freshness_score("unclear", [], today)) == "check"
    assert label_for(None) == "stable"
PRISM_EOF
mkdir -p "config"
cat > "config/arms.json" <<'PRISM_EOF'
{
  "_note": "relative_cost is in relative units per 1k tokens (local = 0). Replace with real USD prices from each provider's pricing page before reporting costs in USD.",
  "arms": [
    {"provider": "groq",   "model": "llama-3.1-8b-instant",  "relative_cost": 1},
    {"provider": "groq",   "model": "llama-3.3-70b-versatile", "relative_cost": 6},
    {"provider": "gemini", "model": "gemini-2.5-flash",       "relative_cost": 3}
  ]
}
PRISM_EOF
mkdir -p "config/bifrost"
cat > "config/bifrost/config.json" <<'PRISM_EOF'
{
  "$schema": "https://www.getbifrost.ai/schema",
  "config_store": { "enabled": false },
  "providers": {
    "ollama": {
      "keys": [
        { "name": "ollama-local", "value": "", "models": ["*"], "weight": 1.0,
          "ollama_key_config": { "url": "http://127.0.0.1:11434" } }
      ]
    },
    "groq": {
      "keys": [ { "name": "groq-1", "value": "env.GROQ_API_KEY", "models": ["*"], "weight": 1.0 } ]
    },
    "gemini": {
      "keys": [ { "name": "gemini-1", "value": "env.GEMINI_API_KEY", "models": ["*"], "weight": 1.0 } ]
    }
  },
  "plugins": [
    {
      "enabled": true,
      "name": "prism-gate",
      "path": "__PRISM_PLUGIN_PATH__",
      "config": {
        "brain_url": "http://127.0.0.1:8090",
        "brain_timeout_ms": 50,
        "local_provider": "ollama",
        "local_model": "qwen2.5:1.5b",
        "max_concurrent": 8,
        "emergency_reserved": 2,
        "admit_timeout_ms": 20000
      }
    }
  ]
}
PRISM_EOF
mkdir -p "dashboard"
cat > "dashboard/app.py" <<'PRISM_EOF'
"""PRISM-Gate live dashboard: streamlit run dashboard/app.py"""
import httpx
import pandas as pd
import streamlit as st

BRAIN = "http://127.0.0.1:8090"
st.set_page_config(page_title="PRISM-Gate", layout="wide")
st.title("PRISM-Gate: healthcare LLM traffic")

try:
    s = httpx.get(f"{BRAIN}/stats", timeout=3).json()
except Exception as e:
    st.error(f"Brain service not reachable: {e}")
    st.stop()

c = s["counters"]
r = s["router"]
k1, k2, k3, k4 = st.columns(4)
k1.metric("Requests routed", c["requests"])
k2.metric("PHI kept local", c["phi_kept_local"])
k3.metric("Bandit updates", r["updates"])
k4.metric("Mean reward", f"{r['mean_reward']:.3f}" if r["mean_reward"] is not None else "-")

left, right = st.columns(2)
with left:
    st.subheader("Requests by priority")
    st.bar_chart(pd.Series(c["by_priority"], name="requests"))
    st.subheader("Arm pulls (learned routing)")
    st.bar_chart(pd.Series(r["pulls"], name="pulls"))
    if r["disabled"]:
        st.warning("Arms out of rotation: " + ", ".join(r["disabled"]))
with right:
    st.subheader("Learning curve (rolling mean reward)")
    if r["recent"]:
        h = pd.DataFrame(r["recent"])
        st.line_chart(h.set_index("n")["reward"].rolling(20, min_periods=1).mean())
    st.subheader("Latest decisions")
    if s["recent"]:
        d = pd.DataFrame(s["recent"])[["priority", "phi", "provider", "model", "reason", "decide_ms"]]
        st.dataframe(d.iloc[::-1], use_container_width=True, height=300)

st.divider()
st.subheader("Freshness Check (Tavily + Bifrost)")
answer = st.text_area("Paste an AI answer to check", height=140,
                      placeholder="e.g. Drug X costs Rs 500 per pack and is approved by DRAP for children over 2.")
if st.button("Check freshness") and answer.strip():
    with st.spinner("Extracting claims, searching live sources, judging..."):
        res = httpx.post(f"{BRAIN}/verify", json={"answer": answer}, timeout=180)
    if res.status_code != 200:
        st.error(res.text)
    else:
        out = res.json()
        st.metric("Overall freshness score", out["overall_score"] if out["overall_score"] is not None else "-")
        for cl in out["claims"]:
            icon = {"current": "🟢", "check": "🟡", "stale": "🔴"}.get(cl["label"], "⚪")
            with st.expander(f"{icon} {cl['text']}  ({cl['category']}, score {cl['score']})"):
                st.write(f"Verdict: **{cl['verdict']}**")
                if cl["correction"]:
                    st.write(f"Current fact: {cl['correction']}")
                for src in cl["sources"]:
                    st.markdown(f"- [{src['title'] or src['url']}]({src['url']}) {src['published'] or ''}")
PRISM_EOF
mkdir -p "data/synthetic"
cat > "data/synthetic/stale_claims.jsonl" <<'PRISM_EOF'
{"id": 1, "answer": "TEMPLATE: paste an LLM answer that contains a time-sensitive claim here.", "claims": [{"text": "TEMPLATE claim", "label": "stale_or_current", "evidence_url": "", "checked_on": "2026-11-19"}]}
PRISM_EOF
mkdir -p "eval"
cat > "eval/metrics.py" <<'PRISM_EOF'
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
PRISM_EOF
mkdir -p "plugin"
cat > "plugin/brainclient.go" <<'PRISM_EOF'
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"time"
)

// DecideRequest is sent to the brain's POST /decide.
type DecideRequest struct {
	Text         string `json:"text"`
	PriorityHint string `json:"priority_hint"`
	Department   string `json:"department,omitempty"`
	Provider     string `json:"provider"`
	Model        string `json:"model"`
}

// Decision is the brain's answer.
type Decision struct {
	ID       string   `json:"id"`
	PHI      bool     `json:"phi"`
	PHITypes []string `json:"phi_types"`
	Priority string   `json:"priority"`
	Provider string   `json:"provider"`
	Model    string   `json:"model"`
	Reason   string   `json:"reason"`
}

// Feedback is sent to POST /feedback after each attempt (bandit reward).
type Feedback struct {
	DecisionID       string `json:"decision_id"`
	Priority         string `json:"priority"`
	Provider         string `json:"provider"`
	Model            string `json:"model"`
	Success          bool   `json:"success"`
	LatencyMS        int64  `json:"latency_ms"`
	PromptTokens     int    `json:"prompt_tokens"`
	CompletionTokens int    `json:"completion_tokens"`
}

type brainClient struct {
	base string
	fast *http.Client // decisions: strict timeout, gateway must not wait
	slow *http.Client // feedback: async, more patient
}

func newBrainClient(base string, timeout time.Duration) *brainClient {
	if timeout <= 0 {
		timeout = 50 * time.Millisecond
	}
	return &brainClient{
		base: base,
		fast: &http.Client{Timeout: timeout},
		slow: &http.Client{Timeout: 2 * time.Second},
	}
}

func (c *brainClient) Decide(r DecideRequest) (Decision, error) {
	var d Decision
	body, _ := json.Marshal(r)
	resp, err := c.fast.Post(c.base+"/decide", "application/json", bytes.NewReader(body))
	if err != nil {
		return d, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return d, fmt.Errorf("brain /decide status %d", resp.StatusCode)
	}
	err = json.NewDecoder(resp.Body).Decode(&d)
	return d, err
}

func (c *brainClient) Feedback(f Feedback) {
	body, _ := json.Marshal(f)
	resp, err := c.slow.Post(c.base+"/feedback", "application/json", bytes.NewReader(body))
	if err == nil {
		resp.Body.Close()
	}
}
PRISM_EOF
mkdir -p "plugin"
cat > "plugin/config.go" <<'PRISM_EOF'
package main

// Config is read from the plugin's "config" object in Bifrost's config.json.
type Config struct {
	BrainURL          string
	BrainTimeoutMS    int
	LocalProvider     string
	LocalModel        string
	MaxConcurrent     int
	EmergencyReserved int
	AdmitTimeoutMS    int
}

func defaultConfig() Config {
	return Config{
		BrainURL:          "http://127.0.0.1:8090",
		BrainTimeoutMS:    50,
		LocalProvider:     "ollama",
		LocalModel:        "qwen2.5:1.5b",
		MaxConcurrent:     8,
		EmergencyReserved: 2,
		AdmitTimeoutMS:    20000,
	}
}

func (c *Config) apply(m map[string]interface{}) {
	if v, ok := m["brain_url"].(string); ok && v != "" {
		c.BrainURL = v
	}
	if v, ok := m["local_provider"].(string); ok && v != "" {
		c.LocalProvider = v
	}
	if v, ok := m["local_model"].(string); ok && v != "" {
		c.LocalModel = v
	}
	// JSON numbers arrive as float64.
	if v, ok := m["brain_timeout_ms"].(float64); ok && v > 0 {
		c.BrainTimeoutMS = int(v)
	}
	if v, ok := m["max_concurrent"].(float64); ok && v > 0 {
		c.MaxConcurrent = int(v)
	}
	if v, ok := m["emergency_reserved"].(float64); ok && v >= 0 {
		c.EmergencyReserved = int(v)
	}
	if v, ok := m["admit_timeout_ms"].(float64); ok && v > 0 {
		c.AdmitTimeoutMS = int(v)
	}
}
PRISM_EOF
mkdir -p "plugin"
cat > "plugin/main.go" <<'PRISM_EOF'
// PRISM-Gate: a Bifrost native plugin for healthcare LLM traffic.
//
// It keeps prompts that contain patient data (PHI) on a local model, gives
// Emergency requests reserved capacity, and lets a learned router (a LinUCB
// contextual bandit in the Python "brain" service) pick the provider/model.
//
// Hooks used (public extension points of Bifrost):
//   - HTTPTransportPreHook : read x-prism-* headers into the request context
//   - PreRequestHook       : ask the brain for a decision, then set provider/model/fallbacks
//   - PreLLMHook           : priority-aware admission control
//   - PostLLMHook          : release the slot and report the outcome (reward) to the brain
//
// The plugin never blocks on the brain: if the brain is slow or down, the
// request keeps its original provider and Bifrost's own fallbacks.
package main

import (
	"fmt"
	"strings"
	"time"

	"github.com/maximhq/bifrost/core/schemas"
)

// Context keys (namespaced to avoid clashing with Bifrost's own keys).
const (
	ctxPriorityHint = schemas.BifrostContextKey("prism-priority-hint")
	ctxDepartment   = schemas.BifrostContextKey("prism-department")
	ctxDecision     = schemas.BifrostContextKey("prism-decision")
	ctxStart        = schemas.BifrostContextKey("prism-start")
	ctxSlotHeld     = schemas.BifrostContextKey("prism-slot-held")
	ctxBypass       = schemas.BifrostContextKey("prism-bypass")
)

var (
	cfg  = defaultConfig()
	gate *PriorityGate
	bc   *brainClient
)

// Init is called once when Bifrost loads the plugin. config = plugins[].config.
func Init(config any) error {
	if m, ok := config.(map[string]interface{}); ok {
		cfg.apply(m)
	}
	gate = NewPriorityGate(cfg.MaxConcurrent, cfg.EmergencyReserved)
	bc = newBrainClient(cfg.BrainURL, time.Duration(cfg.BrainTimeoutMS)*time.Millisecond)
	fmt.Printf("[prism-gate] loaded: brain=%s local=%s/%s slots=%d reserved=%d\n",
		cfg.BrainURL, cfg.LocalProvider, cfg.LocalModel, cfg.MaxConcurrent, cfg.EmergencyReserved)
	return nil
}

// GetName returns the plugin's system identifier.
func GetName() string { return "prism-gate" }

// Cleanup is called on shutdown.
func Cleanup() error { return nil }

// HTTPTransportPreHook copies PRISM headers into the context. Returning nil
// response means "continue normally".
func HTTPTransportPreHook(ctx *schemas.BifrostContext, req *schemas.HTTPRequest) (*schemas.HTTPResponse, error) {
	if p := req.CaseInsensitiveHeaderLookup("x-prism-priority"); p != "" {
		ctx.SetValue(ctxPriorityHint, strings.ToLower(strings.TrimSpace(p)))
	}
	// Baseline runs for the evaluation: same gateway, plugin logic switched off.
	if req.CaseInsensitiveHeaderLookup("x-prism-bypass") == "1" {
		ctx.SetValue(ctxBypass, true)
	}
	if d := req.CaseInsensitiveHeaderLookup("x-prism-department"); d != "" {
		ctx.SetValue(ctxDepartment, d)
	}
	return nil, nil
}

// HTTPTransportPostHook is unused but declared so all HTTP hooks resolve.
func HTTPTransportPostHook(ctx *schemas.BifrostContext, req *schemas.HTTPRequest, resp *schemas.HTTPResponse) error {
	return nil
}

// PreRequestHook runs once per request (routing phase). Changes to provider,
// model and fallbacks here apply to every attempt.
func PreRequestHook(ctx *schemas.BifrostContext, req *schemas.BifrostRequest) error {
	if req == nil || req.ChatRequest == nil || bypassed(ctx) {
		return nil // only chat completions are routed in this version
	}
	text := lastUserText(req.ChatRequest.Input)
	hint, _ := ctx.Value(ctxPriorityHint).(string)
	dept, _ := ctx.Value(ctxDepartment).(string)
	provider, model, _ := req.GetRequestFields()

	d := Decision{Priority: ClassifyPriority(hint, text), Provider: string(provider), Model: model, Reason: "default"}
	if bd, err := bc.Decide(DecideRequest{Text: text, PriorityHint: d.Priority, Department: dept, Provider: string(provider), Model: model}); err == nil {
		d = bd
	} else {
		ctx.Log(schemas.LogLevelWarn, "prism-gate: brain unavailable, keeping original route: "+err.Error())
	}

	switch {
	case d.PHI:
		// Patient data never leaves: pin to the local model, no cloud fallbacks.
		req.SetProvider(schemas.ModelProvider(cfg.LocalProvider))
		req.SetModel(cfg.LocalModel)
		req.SetFallbacks(nil)
		d.Provider, d.Model = cfg.LocalProvider, cfg.LocalModel
	case d.Provider != "" && d.Model != "":
		req.SetProvider(schemas.ModelProvider(d.Provider))
		req.SetModel(d.Model)
	}
	ctx.SetValue(ctxDecision, d)
	ctx.Log(schemas.LogLevelInfo, fmt.Sprintf("prism-gate: priority=%s phi=%v -> %s/%s (%s)", d.Priority, d.PHI, d.Provider, d.Model, d.Reason))
	return nil
}

// PreLLMHook runs before each provider attempt: priority-aware admission.
func PreLLMHook(ctx *schemas.BifrostContext, req *schemas.BifrostRequest) (*schemas.BifrostRequest, *schemas.LLMPluginShortCircuit, error) {
	if bypassed(ctx) {
		return req, nil, nil
	}
	if held, _ := ctx.Value(ctxSlotHeld).(bool); !held {
		d, _ := ctx.Value(ctxDecision).(Decision)
		if !gate.Acquire(d.Priority, time.Duration(cfg.AdmitTimeoutMS)*time.Millisecond) {
			msg := "prism-gate: capacity reserved for emergency traffic, retry later"
			status := 429
			return req, &schemas.LLMPluginShortCircuit{Error: &schemas.BifrostError{
				StatusCode: &status,
				Error:      &schemas.ErrorField{Message: msg},
			}}, nil
		}
		ctx.SetValue(ctxSlotHeld, true)
	}
	if ctx.Value(ctxStart) == nil {
		ctx.SetValue(ctxStart, time.Now())
	}
	return req, nil, nil
}

// PostLLMHook releases the slot and reports the outcome to the bandit.
func PostLLMHook(ctx *schemas.BifrostContext, resp *schemas.BifrostResponse, bifrostErr *schemas.BifrostError) (*schemas.BifrostResponse, *schemas.BifrostError, error) {
	if held, _ := ctx.Value(ctxSlotHeld).(bool); held {
		gate.Release()
		ctx.SetValue(ctxSlotHeld, false)
	}
	d, ok := ctx.Value(ctxDecision).(Decision)
	if !ok {
		return resp, bifrostErr, nil
	}
	fb := Feedback{DecisionID: d.ID, Priority: d.Priority, Provider: d.Provider, Model: d.Model, Success: bifrostErr == nil}
	if start, ok := ctx.Value(ctxStart).(time.Time); ok {
		fb.LatencyMS = time.Since(start).Milliseconds()
	}
	if resp != nil && resp.ChatResponse != nil && resp.ChatResponse.Usage != nil {
		fb.PromptTokens = resp.ChatResponse.Usage.PromptTokens
		fb.CompletionTokens = resp.ChatResponse.Usage.CompletionTokens
	}
	go bc.Feedback(fb) // never delay the response
	return resp, bifrostErr, nil
}

func bypassed(ctx *schemas.BifrostContext) bool {
	b, _ := ctx.Value(ctxBypass).(bool)
	return b
}

// lastUserText returns the text of the last user message.
func lastUserText(msgs []schemas.ChatMessage) string {
	for i := len(msgs) - 1; i >= 0; i-- {
		m := msgs[i]
		if m.Role != schemas.ChatMessageRoleUser || m.Content == nil {
			continue
		}
		if m.Content.ContentStr != nil {
			return *m.Content.ContentStr
		}
		var b strings.Builder
		for _, blk := range m.Content.ContentBlocks {
			if blk.Text != nil {
				b.WriteString(*blk.Text)
				b.WriteString(" ")
			}
		}
		return strings.TrimSpace(b.String())
	}
	return ""
}
PRISM_EOF
mkdir -p "plugin"
cat > "plugin/priority.go" <<'PRISM_EOF'
package main

import (
	"strings"
	"sync"
	"time"
)

// Priority classes, highest first.
const (
	PriorityEmergency = "emergency"
	PriorityClinical  = "clinical"
	PriorityRoutine   = "routine"
	PriorityBatch     = "batch"
)

var emergencyTerms = []string{
	"chest pain", "cardiac arrest", "stroke", "overdose", "anaphylaxis", "unconscious",
	"not breathing", "severe bleeding", "seizure", "sepsis", "stat ", "code blue", "suicidal",
}

var clinicalTerms = []string{
	"dose", "dosage", "diagnosis", "patient", "symptom", "treatment", "drug interaction",
	"contraindication", "lab result", "prescription", "guideline", "side effect",
}

var batchTerms = []string{"summarize all", "batch", "discharge summaries", "nightly", "bulk"}

// ClassifyPriority uses the header hint when valid, else simple keyword rules.
// The brain may override this with a better classifier.
func ClassifyPriority(hint, text string) string {
	switch hint {
	case PriorityEmergency, PriorityClinical, PriorityRoutine, PriorityBatch:
		return hint
	}
	t := " " + strings.ToLower(text) + " "
	for _, k := range emergencyTerms {
		if strings.Contains(t, k) {
			return PriorityEmergency
		}
	}
	for _, k := range batchTerms {
		if strings.Contains(t, k) {
			return PriorityBatch
		}
	}
	for _, k := range clinicalTerms {
		if strings.Contains(t, k) {
			return PriorityClinical
		}
	}
	return PriorityRoutine
}

// PriorityGate is admission control with capacity reserved for Emergency.
// Emergency may use any free slot; other classes may only use a slot while
// more than `reserved` slots stay free. Batch gives up sooner than others.
type PriorityGate struct {
	mu       sync.Mutex
	cond     *sync.Cond
	max      int
	reserved int
	inUse    int
}

func NewPriorityGate(max, reserved int) *PriorityGate {
	if max < 1 {
		max = 1
	}
	if reserved < 0 || reserved >= max {
		reserved = max / 4
	}
	g := &PriorityGate{max: max, reserved: reserved}
	g.cond = sync.NewCond(&g.mu)
	return g
}

func (g *PriorityGate) canAdmit(priority string) bool {
	free := g.max - g.inUse
	if priority == PriorityEmergency {
		return free > 0
	}
	return free > g.reserved
}

// Acquire waits up to timeout for a slot. Batch waits a quarter of it.
func (g *PriorityGate) Acquire(priority string, timeout time.Duration) bool {
	if priority == PriorityBatch {
		timeout /= 4
	}
	deadline := time.Now().Add(timeout)
	g.mu.Lock()
	defer g.mu.Unlock()
	for !g.canAdmit(priority) {
		remaining := time.Until(deadline)
		if remaining <= 0 {
			return false
		}
		// Wake up periodically to re-check the deadline.
		t := time.AfterFunc(minDur(remaining, 50*time.Millisecond), func() {
			g.mu.Lock()
			g.cond.Broadcast()
			g.mu.Unlock()
		})
		g.cond.Wait()
		t.Stop()
	}
	g.inUse++
	return true
}

// Release frees one slot.
func (g *PriorityGate) Release() {
	g.mu.Lock()
	if g.inUse > 0 {
		g.inUse--
	}
	g.cond.Broadcast()
	g.mu.Unlock()
}

// InUse reports the slots currently taken (for tests and metrics).
func (g *PriorityGate) InUse() int {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.inUse
}

func minDur(a, b time.Duration) time.Duration {
	if a < b {
		return a
	}
	return b
}
PRISM_EOF
mkdir -p "plugin"
cat > "plugin/priority_test.go" <<'PRISM_EOF'
package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestClassifyPriority(t *testing.T) {
	cases := []struct{ hint, text, want string }{
		{"emergency", "anything", PriorityEmergency},
		{"", "Patient with crushing chest pain and sweating", PriorityEmergency},
		{"", "What is the usual dosage of amoxicillin for adults?", PriorityClinical},
		{"", "Summarize all discharge summaries from last night", PriorityBatch},
		{"", "Write a polite email to the vendor", PriorityRoutine},
		{"bogus", "hello", PriorityRoutine},
	}
	for _, c := range cases {
		if got := ClassifyPriority(c.hint, c.text); got != c.want {
			t.Errorf("ClassifyPriority(%q,%q)=%s want %s", c.hint, c.text, got, c.want)
		}
	}
}

func TestGateReservesCapacityForEmergency(t *testing.T) {
	g := NewPriorityGate(3, 1)
	if !g.Acquire(PriorityRoutine, 10*time.Millisecond) || !g.Acquire(PriorityRoutine, 10*time.Millisecond) {
		t.Fatal("routine should get the two unreserved slots")
	}
	if g.Acquire(PriorityRoutine, 20*time.Millisecond) {
		t.Fatal("routine must not take the reserved slot")
	}
	if !g.Acquire(PriorityEmergency, 10*time.Millisecond) {
		t.Fatal("emergency must get the reserved slot")
	}
	if g.InUse() != 3 {
		t.Fatalf("in use = %d, want 3", g.InUse())
	}
}

func TestGateReleaseWakesWaiter(t *testing.T) {
	g := NewPriorityGate(1, 0)
	g.Acquire(PriorityRoutine, time.Millisecond)
	done := make(chan bool)
	go func() { done <- g.Acquire(PriorityClinical, time.Second) }()
	time.Sleep(20 * time.Millisecond)
	g.Release()
	if !<-done {
		t.Fatal("waiter should be admitted after release")
	}
}

func TestBrainTimeoutFallsBack(t *testing.T) {
	slow := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(200 * time.Millisecond)
	}))
	defer slow.Close()
	c := newBrainClient(slow.URL, 30*time.Millisecond)
	start := time.Now()
	if _, err := c.Decide(DecideRequest{Text: "x"}); err == nil {
		t.Fatal("expected timeout error")
	}
	if time.Since(start) > 150*time.Millisecond {
		t.Fatal("decide must not block the gateway")
	}
}
PRISM_EOF
mkdir -p "."
cat > "requirements.txt" <<'PRISM_EOF'
fastapi>=0.110
uvicorn[standard]>=0.29
pydantic>=2.6
numpy>=1.26
httpx>=0.27
tavily-python>=0.5
presidio-analyzer>=2.2
spacy>=3.7
streamlit>=1.35
pandas>=2.2
python-dotenv>=1.0
pytest>=8.0
PRISM_EOF
mkdir -p "scripts"
cat > "scripts/build.sh" <<'PRISM_EOF'
#!/usr/bin/env bash
# Builds a dynamically linked Bifrost and the plugin with the SAME module graph.
# Go plugins only load when every shared package matches exactly, so the plugin
# is compiled inside Bifrost's transports module (same go.mod / go.sum / flags).
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BIFROST_DIR="${BIFROST_DIR:-$REPO/.deps/bifrost}"
export PATH="/usr/local/go/bin:$PATH" CGO_ENABLED=1 GOWORK=off
mkdir -p "$REPO/build"

echo "-- bifrost-http (dynamic)"
cd "$BIFROST_DIR/transports/bifrost-http"
# The web UI is embedded with go:embed; we do not ship it in dev builds.
[ -d ui ] || { mkdir -p ui && echo '<html><body>Bifrost UI not bundled in PRISM-Gate dev build</body></html>' > ui/index.html; }
go build -trimpath -ldflags "-X main.Version=v-prism-dev" -o "$REPO/build/bifrost-http" .
if ldd "$REPO/build/bifrost-http" 2>&1 | grep -q "statically linked"; then
  echo "ERROR: binary is static; plugins cannot load"; exit 1
fi

echo "-- prism-gate plugin"
PLUG_SRC="$BIFROST_DIR/transports/prism_gate_plugin"
rm -rf "$PLUG_SRC" && mkdir -p "$PLUG_SRC"
cp "$REPO"/plugin/*.go "$PLUG_SRC"/
cd "$PLUG_SRC"
go vet .
go test ./...
go build -buildmode=plugin -trimpath -o "$REPO/build/prism-gate.so" .
echo "Built: build/bifrost-http and build/prism-gate.so"
PRISM_EOF
mkdir -p "scripts"
cat > "scripts/run_all.sh" <<'PRISM_EOF'
#!/usr/bin/env bash
# Starts Ollama, the brain (8090), Bifrost with the plugin (8080) and the dashboard (8501).
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"; mkdir -p .run .bifrost
set -a; [ -f .env ] && . ./.env; set +a

pgrep -x ollama >/dev/null || (nohup ollama serve > .run/ollama.log 2>&1 &)

sed "s#__PRISM_PLUGIN_PATH__#$REPO/build/prism-gate.so#" config/bifrost/config.json > .bifrost/config.json

nohup python3 -m uvicorn brain.app:app --host 127.0.0.1 --port 8090 > .run/brain.log 2>&1 &
echo $! > .run/brain.pid
sleep 2
nohup ./build/bifrost-http -app-dir "$REPO/.bifrost" -port 8080 -log-style pretty > .run/bifrost.log 2>&1 &
echo $! > .run/bifrost.pid
nohup python3 -m streamlit run dashboard/app.py --server.port 8501 --server.headless true > .run/dashboard.log 2>&1 &
echo $! > .run/dashboard.pid
sleep 3
echo "brain:     $(curl -s 127.0.0.1:8090/health || echo DOWN)"
echo "bifrost:   http://127.0.0.1:8080   (logs: .run/bifrost.log)"
echo "dashboard: http://127.0.0.1:8501"
grep -m1 "prism-gate\] loaded" .run/bifrost.log || echo "WARNING: plugin load line not found yet, check .run/bifrost.log"
PRISM_EOF
mkdir -p "scripts"
cat > "scripts/setup.sh" <<'PRISM_EOF'
#!/usr/bin/env bash
# One-time setup on Linux (GitHub Codespaces or Ubuntu). Safe to re-run.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BIFROST_DIR="${BIFROST_DIR:-$REPO/.deps/bifrost}"
BIFROST_REF="${BIFROST_REF:-cbea98e6f1140cd4ec319ec6d21a20342a05326b}"   # pinned, tested commit (17 Nov 2026)
LOCAL_MODEL="${PRISM_LOCAL_MODEL:-qwen2.5:1.5b}"

echo "== 1/5 Bifrost source ($BIFROST_REF)"
if [ ! -d "$BIFROST_DIR/.git" ]; then
  mkdir -p "$(dirname "$BIFROST_DIR")"
  git clone --filter=blob:none https://github.com/maximhq/bifrost.git "$BIFROST_DIR"
fi
git -C "$BIFROST_DIR" fetch --quiet origin "$BIFROST_REF" || true
git -C "$BIFROST_DIR" checkout --quiet "$BIFROST_REF"

echo "== 2/5 Go toolchain (the exact version Bifrost requires)"
GO_WANT="$(awk '/^go /{print $2; exit}' "$BIFROST_DIR/transports/go.mod")"
if ! command -v go >/dev/null || [ "$(go env GOVERSION 2>/dev/null)" != "go$GO_WANT" ]; then
  curl -fsSL "https://go.dev/dl/go${GO_WANT}.linux-amd64.tar.gz" -o /tmp/go.tgz
  sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf /tmp/go.tgz && rm /tmp/go.tgz
fi
export PATH="/usr/local/go/bin:$PATH"
grep -q '/usr/local/go/bin' ~/.bashrc 2>/dev/null || echo 'export PATH=/usr/local/go/bin:$PATH' >> ~/.bashrc
go version

echo "== 3/5 Python packages"
python3 -m pip install --quiet --upgrade pip
python3 -m pip install --quiet -r "$REPO/requirements.txt"
python3 -m spacy download en_core_web_sm --quiet || echo "spaCy model download failed: PHI Guard will use regex rules only"

echo "== 4/5 Ollama + local model ($LOCAL_MODEL)"
command -v ollama >/dev/null || curl -fsSL https://ollama.com/install.sh | sh
pgrep -x ollama >/dev/null || (nohup ollama serve > /tmp/ollama.log 2>&1 &) ; sleep 3
ollama pull "$LOCAL_MODEL"

echo "== 5/5 Build Bifrost (dynamic) and the PRISM-Gate plugin"
bash "$REPO/scripts/build.sh"

[ -f "$REPO/.env" ] || cp "$REPO/.env.example" "$REPO/.env"
echo "Setup done. Put your keys in .env (or Codespaces secrets), then run: bash scripts/run_all.sh"
PRISM_EOF
mkdir -p "scripts"
cat > "scripts/smoke_test.sh" <<'PRISM_EOF'
#!/usr/bin/env bash
# Day-1 exit test: requests go through Bifrost + PRISM-Gate.
set -euo pipefail
B=http://127.0.0.1:8080/v1/chat/completions
echo "1) Patient data -> must be answered by the local model"
curl -s $B -H 'Content-Type: application/json' -H 'x-prism-priority: clinical' \
  -d '{"model":"groq/llama-3.1-8b-instant","messages":[{"role":"user","content":"Patient Ahmed Raza, CNIC 35202-1234567-1, has fever 39C. Next step?"}]}' \
  | python3 -c 'import sys,json; r=json.load(sys.stdin); print("model:", r.get("model"), "| error:" , r.get("error"))'
echo "2) General question -> routed by the bandit"
curl -s $B -H 'Content-Type: application/json' -H 'x-prism-priority: routine' \
  -d '{"model":"groq/llama-3.1-8b-instant","messages":[{"role":"user","content":"Explain hypertension in two lines."}]}' \
  | python3 -c 'import sys,json; r=json.load(sys.stdin); print("model:", r.get("model"), "| error:", r.get("error"))'
echo "3) Brain view"; curl -s 127.0.0.1:8090/stats | python3 -c 'import sys,json; print(json.load(sys.stdin)["counters"])'
PRISM_EOF
mkdir -p "scripts"
cat > "scripts/stop_all.sh" <<'PRISM_EOF'
#!/usr/bin/env bash
cd "$(dirname "$0")/.."
for f in .run/*.pid; do [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null; rm -f "$f"; done
echo stopped
PRISM_EOF
mkdir -p "simulator"
cat > "simulator/simulate.py" <<'PRISM_EOF'
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
PRISM_EOF
chmod +x scripts/*.sh
echo "PRISM-Gate files unpacked."
