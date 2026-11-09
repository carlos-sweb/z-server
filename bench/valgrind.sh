#!/usr/bin/env bash
# Run 1000 HIT requests against z-server under valgrind.
# From the repository root: ./bench/valgrind.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OHA="${OHA:-$ROOT/bench/oha}"
if [[ ! -x "$OHA" ]] && command -v oha >/dev/null 2>&1; then
    OHA="$(command -v oha)"
fi
if [[ ! -x "$OHA" ]]; then
    echo "oha not found" >&2
    exit 1
fi

zig build

LOG="$ROOT/bench/valgrind.log"
rm -f "$LOG"

valgrind --leak-check=full --show-leak-kinds=definite,indirect \
    --error-exitcode=99 --log-file="$LOG" \
    ./zig-out/bin/z-server >"$ROOT/bench/valgrind-server.out" 2>&1 &
VG_PID=$!

cleanup() {
    kill -INT "$VG_PID" 2>/dev/null || true
    wait "$VG_PID" 2>/dev/null || true
}
trap cleanup EXIT

ready=0
for _ in $(seq 1 300); do
    if curl -sf -o /dev/null http://127.0.0.1:8080/health 2>/dev/null; then
        ready=1
        break
    fi
    sleep 0.2
done
if [[ "$ready" != 1 ]]; then
    echo "server did not start under valgrind" >&2
    tail -n 20 "$ROOT/bench/valgrind-server.out" >&2 || true
    exit 1
fi

ID="$(curl -sS -X POST -H 'Content-Type: application/json' \
    -d '{"name":"vg","payload":{"k":1}}' http://127.0.0.1:8080/items \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
curl -sS "http://127.0.0.1:8080/items/$ID" >/dev/null

"$OHA" --no-tui --output-format quiet -n 1000 -c 20 "http://127.0.0.1:8080/items/$ID" >/dev/null

kill -INT "$VG_PID"
set +e
wait "$VG_PID"
VG_EXIT=$?
set -e
trap - EXIT

echo "valgrind process exit: $VG_EXIT"
echo "log: $LOG"
if ! grep -q "Invalid " "$LOG" && grep -q "ERROR SUMMARY: 0 errors" "$LOG"; then
    if grep -q "All heap blocks were freed -- no leaks are possible" "$LOG" \
        || { grep -q "definitely lost: 0 bytes" "$LOG" && grep -q "indirectly lost: 0 bytes" "$LOG"; }; then
        echo "valgrind: 0 definite/indirect leaks, 0 invalid access, ERROR SUMMARY 0"
        exit 0
    fi
fi
echo "valgrind: check $LOG" >&2
tail -n 40 "$LOG" >&2
exit 1
