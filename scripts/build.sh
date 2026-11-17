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
