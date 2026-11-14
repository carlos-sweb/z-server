#!/usr/bin/env bash
# Orchestrate a k6 load test against Bun baseline (native Bun.serve + bun:sqlite).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FREE_GB=$(df --output=avail -BG ~ | tail -1 | tr -d 'G ')
if [ "$FREE_GB" -lt 5 ]; then
  echo "ERROR: less than 5 GB free on ~ ($FREE_GB GB)."
  exit 1
fi

MODE=podman
USERS=10000
DURATION=300s
MAX_VUS=2000
RAMP_UP=60s
BASE_URL="http://127.0.0.1:8080"
MEMORY=512m
CPUS=1
RESULTS_ROOT="$ROOT/loadtest/results"
STAMP="$(date +%Y%m%d-%H%M%S)"
RESULTS="$RESULTS_ROOT/run-$STAMP-bun-load"
IMAGE="docker.io/oven/bun:latest"
CONTAINER_NAME="bun-bench"

usage() {
  cat <<'EOF'
Usage: ./loadtest/run-bun.sh [--mode=podman] [--users=10000] [--duration=300s]
                             [--max-vus=2000] [--ramp-up=60s] [--base-url=http://127.0.0.1:8080]
                             [--memory=512m] [--cpus=1]
EOF
}

for arg in "$@"; do
  case "$arg" in
    --mode=*) MODE="${arg#*=}" ;;
    --users=*) USERS="${arg#*=}" ;;
    --duration=*) DURATION="${arg#*=}" ;;
    --max-vus=*) MAX_VUS="${arg#*=}" ;;
    --ramp-up=*) RAMP_UP="${arg#*=}" ;;
    --base-url=*) BASE_URL="${arg#*=}" ;;
    --memory=*) MEMORY="${arg#*=}" ;;
    --cpus=*) CPUS="${arg#*=}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; usage; exit 2 ;;
  esac
done

if [[ "$MODE" != "podman" ]]; then
  echo "error: --mode must be podman for baseline benchmark parity" >&2
  exit 2
fi

K6_BIN="$(command -v k6 || true)"
if [[ -z "$K6_BIN" && -x "$HOME/.local/bin/k6" ]]; then
  K6_BIN="$HOME/.local/bin/k6"
fi
if [[ -z "$K6_BIN" ]]; then
  echo "error: k6 not found." >&2
  exit 1
fi

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: missing dependency: $1" >&2
    exit 1
  fi
}
need curl
need awk
need jq
need ss
need vmstat
need python3

mkdir -p "$RESULTS"
: > "$RESULTS/server.log"
: > "$RESULTS/run.log"
ln -sfn "$(basename "$RESULTS")" "$RESULTS_ROOT/latest"
echo "==> results dir $RESULTS" | tee "$RESULTS/run.log"

STARTED_SERVER=0
SERVER_PID=""
COMPOSE_UP=0
SAMPLER_PID=""
K6_PID=""

cleanup() {
  local rc=$?
  set +e
  if [[ -n "$SAMPLER_PID" ]] && kill -0 "$SAMPLER_PID" 2>/dev/null; then
    kill "$SAMPLER_PID" 2>/dev/null
    wait "$SAMPLER_PID" 2>/dev/null
  fi
  if [[ -n "$K6_PID" ]] && kill -0 "$K6_PID" 2>/dev/null; then
    kill "$K6_PID" 2>/dev/null
    wait "$K6_PID" 2>/dev/null
  fi
  if [[ "$COMPOSE_UP" -eq 1 ]]; then
    podman stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
    podman rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
  exit "$rc"
}
trap cleanup EXIT INT TERM

if ss -ltn | awk '{print $4}' | grep -qE '(^|:)8080$'; then
  echo "error: port 8080 is taken. Stop whatever is using it first." >&2
  exit 1
fi

echo "==> starting bun-baseline mode=$MODE" | tee -a "$RESULTS/run.log"

# Clean DB before benchmark run
mkdir -p "$ROOT/loadtest/bun-baseline/data"
rm -f "$ROOT/loadtest/bun-baseline/data/app.db"*
chmod 0777 "$ROOT/loadtest/bun-baseline/data" 2>/dev/null || true

podman rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

# Cheap-VPS cgroup: same memory and memory-swap => no swap, OOM killer if exceeded.
# BIND MOUNT to real disk: $ROOT/loadtest/bun-baseline/data -> /app/data (NO tmpfs, NO /tmp)
podman run -d --name "$CONTAINER_NAME" \
  --memory="$MEMORY" --memory-swap="$MEMORY" --cpus="$CPUS" \
  -p 127.0.0.1:8080:8080 \
  -w /app \
  -v "$ROOT/loadtest/bun-baseline:/app:Z" \
  -v "$ROOT/loadtest/bun-baseline/data:/app/data:Z" \
  -e PORT=8080 \
  -e HOST=0.0.0.0 \
  -e DB_PATH=data/app.db \
  -e BUN_WORKERS=16 \
  "$IMAGE" \
  bun run src/server.ts

COMPOSE_UP=1
SERVER_PID="$(podman inspect -f '{{.State.Pid}}' "$CONTAINER_NAME" 2>/dev/null || true)"

ok=0
for i in $(seq 1 50); do
  if curl -fsS --max-time 1 "$BASE_URL/health" >/dev/null 2>&1; then
    ok=1
    break
  fi
  sleep 0.2
done
if [[ "$ok" -ne 1 ]]; then
  echo "error: bun-baseline did not become healthy at $BASE_URL/health" >&2
  podman logs "$CONTAINER_NAME" >&2 || true
  exit 1
fi
echo "==> healthy $(curl -sS "$BASE_URL/health")" | tee -a "$RESULTS/run.log"

{
  echo "k6: $($K6_BIN version | head -1)"
  echo "nproc: $(nproc)"
  echo "mem: $(awk '/MemTotal:/{t=$2} /MemAvailable:/{a=$2} END{print "total_kb=" t " avail_kb=" a}' /proc/meminfo)"
  echo "uname: $(uname -a)"
  echo "mode=$MODE users=$USERS duration=$DURATION max_vus=$MAX_VUS ramp_up=$RAMP_UP"
} > "$RESULTS/meta.txt"

SAMPLER="$ROOT/loadtest/sample.sh"
chmod +x "$SAMPLER"
SAMPLE_DB="$ROOT/loadtest/bun-baseline/data/app.db"
"$SAMPLER" --pid="${SERVER_PID:-0}" --out="$RESULTS/server-samples.csv" --db="$SAMPLE_DB" --interval=5 --health="$BASE_URL/health" >>"$RESULTS/run.log" 2>&1 &
SAMPLER_PID=$!
echo "sampler_pid=$SAMPLER_PID" | tee -a "$RESULTS/run.log"

echo "==> k6 start" | tee -a "$RESULTS/run.log"
set +e
"$K6_BIN" run \
  --out "json=$RESULTS/k6.json" \
  --summary-export "$RESULTS/k6-summary.json" \
  -e "BASE_URL=$BASE_URL" \
  -e "USERS=$USERS" \
  -e "DURATION=$DURATION" \
  -e "RAMP_UP=$RAMP_UP" \
  -e "MAX_VUS=$MAX_VUS" \
  "$ROOT/loadtest/k6/scenarios.js" | tee "$RESULTS/k6-stdout.txt"
K6_RC=${PIPESTATUS[0]}
set -e
echo "k6_exit=$K6_RC" | tee -a "$RESULTS/run.log"

if [[ -n "$SAMPLER_PID" ]]; then
  kill "$SAMPLER_PID" 2>/dev/null || true
  wait "$SAMPLER_PID" 2>/dev/null || true
  SAMPLER_PID=""
fi

if health_final=$(curl -fsS --max-time 2 "$BASE_URL/health" 2>/dev/null); then
  echo "$health_final" > "$RESULTS/health-final.json"
  echo "health_final=$health_final" | tee -a "$RESULTS/run.log"
fi

podman logs "$CONTAINER_NAME" > "$RESULTS/server.log" 2>&1 || true

chmod +x "$ROOT/loadtest/analyze-bun.sh"
"$ROOT/loadtest/analyze-bun.sh" "$RESULTS"
{
  echo "# Bun baseline load test report"
  echo
  echo "Run: $(basename "$RESULTS"). Generated by loadtest/run-bun.sh from analysis.md."
  echo
  cat "$RESULTS/analysis.md"
} > "$RESULTS/REPORT.md"

if [[ "$K6_RC" -eq 0 || "$K6_RC" -eq 99 ]]; then
  echo "==> done (k6_exit=$K6_RC). See $RESULTS/analysis.md" | tee -a "$RESULTS/run.log"
  exit 0
fi
echo "error: k6 exited $K6_RC" | tee -a "$RESULTS/run.log"
exit "$K6_RC"
