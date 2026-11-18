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
CHECKER_MODEL = os.getenv("PRISM_CHECKER_MODEL", "groq/openai/gpt-oss-20b")

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
        headers={"x-prism-priority": "routine", "x-prism-bypass": "1"},  # input is PHI-masked before /verify runs
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
