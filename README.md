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
