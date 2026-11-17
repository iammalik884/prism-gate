# Contributing

- Plugin code lives in `plugin/` (Go, package `main`). Keep pure logic (priority, admission, config) free of Bifrost imports so it is unit-testable.
- Brain code lives in `brain/` (Python 3.11). Never log raw prompt text; use `phi_guard.mask` if text must be logged.
- Run before a PR: `python -m pytest -q brain/tests` and `bash scripts/build.sh` (runs `go vet` and `go test`).
- Upstream path: the plugin can be proposed to Bifrost under `examples/plugins/prism-gate` with the brain as an optional sidecar.
