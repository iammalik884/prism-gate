# PRISM-Gate

**Priority & Risk-aware Intelligent Scheduling for Models** — an open-source [Bifrost](https://github.com/maximhq/bifrost) plugin that lets hospitals use LLMs safely, with a [Tavily](https://tavily.com)-powered check for stale medical facts.

Built for the **Global AI Hackathon 2026 (Geek Room)**:
primary problem **PS-04 Bifrost — "Build a Feature the Open-Source Gateway Is Missing"**, integrated with **PS-06 Tavily — "Build a Stale-Answer Detector for AI Applications"**.

> Status: submitted 19 Nov 2026. Results below come from our own runs only.

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

Request flow: headers → `PreRequestHook` asks the brain (150 ms budget; if the brain is slow, local PHI rules in the plugin still keep patient data local) → provider/model set → `PreLLMHook` admission → provider call → `PostLLMHook` reports latency/tokens/success as the bandit reward.

## Quick start (GitHub Codespaces, recommended)

1. **Code → Codespaces → New codespace** (4-core / 16 GB), then `bash scripts/setup.sh`: Bifrost release v2.5.1 source, the Go version Bifrost requires, Python packages, Ollama + `qwen2.5:1.5b`, then builds Bifrost (dynamic) and the plugin.
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
python -m simulator.simulate --n 200 --mode prism --outage-at 100 --outage-arm groq/openai/gpt-oss-20b
python -m eval.metrics
```

All traffic is synthetic (invented names and IDs). Metrics: PHI requests answered by a cloud model (target 0), success rate, Emergency p95 latency, learned arm mix, stale-claim precision/recall on a hand-labelled set.

### Results (18 Nov 2026, 200 synthetic requests per mode)

Free tiers, 4 parallel workers, one arm disabled at request 100 (outage test). Raw output: `eval/results.md`.

| Metric | Static (all to `groq/openai/gpt-oss-120b`) | PRISM-Gate |
| --- | --- | --- |
| Successful answers | 17 / 200 (8.5%) | 181 / 200 (90.5%) |
| PHI requests sent to a cloud model | 46 / 46 | **0 / 46** |
| PHI requests caught (recall) | n/a | 46 / 46 |
| False alarms (sent local, no real PHI) | n/a | 18 of 64 local |
| Emergency without PHI, median latency | 1.8 s (1 succeeded) | 2.2 s (7 succeeded) |
| Emergency with PHI, latency | 6.0 s (cloud) | 32 s (local CPU model) |

How to read it honestly:

- 183 static failures were HTTP 429 rate limits on one free-tier model. PRISM-Gate succeeds mainly because the bandit spreads load across arms. A baseline at a matched, lower request rate is still to be run.
- Privacy is the strongest result: no synthetic patient data reached a cloud model. The cost is 18 false alarms (precision 72%), mostly Presidio tagging drug names as people.
- Emergency requests that carry PHI are slow on a CPU-only local model (32 s). A GPU or a faster local model removes this trade-off.

### Freshness Check example

Input: *"Ranitidine (Zantac) is approved by the FDA and widely sold over the counter in the US. Paracetamol is used to reduce fever."*

| Claim | Verdict | Score | Label |
| --- | --- | --- | --- |
| Zantac is widely sold over the counter in the US | contradicted | 10 | stale |
| Zantac is approved by the FDA | supported (cited source to be read by a human) | 90 | current |
| Paracetamol is used to reduce fever | not time-sensitive | - | stable |

6.7 s end to end: two LLM calls through Bifrost plus one Tavily search per time-sensitive claim.

### What testing caught (and we fixed)

- **Fail-open gap:** in the first test the brain answered in 58 ms against a 50 ms budget, so a prompt with a CNIC kept its cloud route. The Go plugin now runs local CNIC / MRN / phone / DOB rules on every request (fail-closed), and the brain budget is 150 ms.
- **False positives in the checker:** Presidio tagged a drug name as a person and pushed the checker's own LLM calls to the slow local model. Checker input is now PHI-masked and its internal calls bypass rerouting.
- **Build reproducibility:** the plugin is compiled inside Bifrost's own `transports` module, pinned to release `transports/v2.5.1`.

## Pitch deck

[docs/PRISM-Gate.pptx](docs/PRISM-Gate.pptx) (generated by `python docs/make_deck.py`).

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

Claude (Anthropic) helped draft code and documentation; all code was reviewed and run by the author. Runtime models: GPT-OSS 20B/120B on Groq, Gemini Flash, local Qwen 2.5 1.5B via Ollama.

## License

Apache-2.0, same as Bifrost.

Author: Usama Manzoor (MS IT, University of Sargodha) — research on priority-aware, privacy-preserving scheduling for healthcare edge computing.
