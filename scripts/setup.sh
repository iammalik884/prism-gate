#!/usr/bin/env bash
# One-time setup on Linux (GitHub Codespaces or Ubuntu). Safe to re-run.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BIFROST_DIR="${BIFROST_DIR:-$REPO/.deps/bifrost}"
BIFROST_REF="${BIFROST_REF:-transports/v2.5.1}"   # official release (10 Nov 2026)
LOCAL_MODEL="${PRISM_LOCAL_MODEL:-qwen2.5:1.5b}"

echo "== 1/5 Bifrost source ($BIFROST_REF)"
if [ ! -d "$BIFROST_DIR/.git" ]; then
  mkdir -p "$(dirname "$BIFROST_DIR")"
  git clone --filter=blob:none https://github.com/maximhq/bifrost.git "$BIFROST_DIR"
fi
git -C "$BIFROST_DIR" fetch --quiet origin tag "$BIFROST_REF" || git -C "$BIFROST_DIR" fetch --quiet origin "$BIFROST_REF" || true
git -C "$BIFROST_DIR" checkout --quiet --force "$BIFROST_REF"

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
