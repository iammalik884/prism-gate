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
