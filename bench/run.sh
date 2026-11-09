#!/usr/bin/env bash
# Load test z-server with oha. Run from the repository root:
#   ./bench/run.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OHA="${OHA:-}"
if [[ -z "$OHA" ]]; then
    if [[ -x "$ROOT/bench/oha" ]]; then
        OHA="$ROOT/bench/oha"
    elif command -v oha >/dev/null 2>&1; then
        OHA="$(command -v oha)"
    else
        echo "oha not found. Fedora: sudo dnf install oha" >&2
        echo "or: curl -fsSL -o bench/oha https://github.com/hatoo/oha/releases/download/v1.16.0/oha-linux-amd64 && chmod +x bench/oha" >&2
        exit 1
    fi
fi

BASE="http://127.0.0.1:8080"
OUT_DIR="$ROOT/bench"
mkdir -p "$OUT_DIR"

zig build

./zig-out/bin/z-server >"$OUT_DIR/server.log" 2>&1 &
SERVER_PID=$!
cleanup() {
    kill -INT "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
}
trap cleanup EXIT

ready=0
for _ in $(seq 1 100); do
    if curl -sf -o /dev/null "$BASE/health" 2>/dev/null; then
        ready=1
        break
    fi
    sleep 0.1
done
if [[ "$ready" != 1 ]]; then
    echo "server failed to start" >&2
    cat "$OUT_DIR/server.log" >&2 || true
    exit 1
fi

SMALL_JSON='{"name":"bench","payload":{"k":1}}'
SMALL_ID="$(curl -sS -X POST -H 'Content-Type: application/json' -d "$SMALL_JSON" "$BASE/items" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
curl -sS "$BASE/items/$SMALL_ID" >/dev/null
curl -sS "$BASE/items/$SMALL_ID" >/dev/null

BIG_PAYLOAD="$(python3 -c 'print("{\"name\":\"big\",\"payload\":{\"data\":\"" + "x"*40000 + "\"}}")')"
BIG_ID="$(curl -sS -X POST -H 'Content-Type: application/json' -d "$BIG_PAYLOAD" "$BASE/items" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"

run_oha() {
    local name="$1"
    shift
    echo "=== $name ==="
    "$OHA" --no-tui --output-format json "$@" >"$OUT_DIR/${name}.json"
}

run_oha hit -n 1000 -c 50 "$BASE/items/$SMALL_ID"
run_oha miss -n 1000 -c 50 "$BASE/items/$BIG_ID"
run_oha post -n 500 -c 50 -m POST -H 'Content-Type: application/json' -d "$SMALL_JSON" "$BASE/items"
run_oha list -n 1000 -c 50 "$BASE/items"

python3 "$ROOT/bench/summarize.py" \
    --oha "$OHA" \
    --out "$OUT_DIR/results.md" \
    hit "$OUT_DIR/hit.json" \
    miss "$OUT_DIR/miss.json" \
    post "$OUT_DIR/post.json" \
    list "$OUT_DIR/list.json"

echo "wrote $OUT_DIR/results.md"
