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
