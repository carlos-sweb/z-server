#!/usr/bin/env bash
# Orchestrate a k6 load test against z-server (host binary or podman-compose).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FREE_GB=$(df --output=avail -BG ~ | tail -1 | tr -d 'G ')
if [ "$FREE_GB" -lt 5 ]; then
  echo "ERROR: less than 5 GB free on ~ ($FREE_GB GB)."
  echo "Run: ./loadtest/build-image.sh --prune-only"
  echo "  or: podman image prune -f && podman volume prune -f"
  exit 1
fi

MODE=host
USERS=10000
DURATION=300s
MAX_VUS=200
RAMP_UP=60s
BASE_URL="http://127.0.0.1:8080"
MEMORY=512m
CPUS=1
RESULTS_ROOT="$ROOT/loadtest/results"
STAMP="$(date +%Y%m%d-%H%M%S)"
RESULTS="$RESULTS_ROOT/run-$STAMP-load"
HANDLER_THREADS=4
SQLITE_POOL=4
SQLITE_SYNCHRONOUS=""
IMAGE="localhost/z-server:0.2.0"

usage() {
  cat <<'EOF'
Usage: ./loadtest/run.sh [--mode=host|podman] [--users=10000] [--duration=300s]
                         [--max-vus=200] [--ramp-up=60s] [--base-url=http://127.0.0.1:8080]
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
    --handler-threads=*) HANDLER_THREADS="${arg#*=}" ;;
    --sqlite-pool=*) SQLITE_POOL="${arg#*=}" ;;
    --sqlite-synchronous=*) SQLITE_SYNCHRONOUS="${arg#*=}" ;;
    --image=*) IMAGE="${arg#*=}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; usage; exit 2 ;;
  esac
done

if [[ "$MODE" != "host" && "$MODE" != "podman" ]]; then
  echo "error: --mode must be host or podman" >&2
  exit 2
fi

K6_BIN="$(command -v k6 || true)"
if [[ -z "$K6_BIN" && -x "$HOME/.local/bin/k6" ]]; then
  K6_BIN="$HOME/.local/bin/k6"
fi
if [[ -z "$K6_BIN" ]]; then
  echo "error: k6 not found. Install:" >&2
  echo "  curl -fsSL -o /tmp/k6.tar.gz https://github.com/grafana/k6/releases/download/v0.54.0/k6-v0.54.0-linux-amd64.tar.gz" >&2
  echo "  tar -C /tmp -xzf /tmp/k6.tar.gz && install -m 0755 /tmp/k6-v0.54.0-linux-amd64/k6 \$HOME/.local/bin/k6" >&2
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

if ! command -v pidstat >/dev/null 2>&1; then
  echo "note: pidstat not installed (sysstat); sampler uses /proc" >&2
fi
if ! command -v iostat >/dev/null 2>&1; then
  echo "note: iostat not installed (sysstat); sampler uses /proc/<pid>/io" >&2
fi

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
  if [[ "$STARTED_SERVER" -eq 1 && -n "$SERVER_PID" ]]; then
    if kill -0 "$SERVER_PID" 2>/dev/null; then
      kill -TERM "$SERVER_PID" 2>/dev/null
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "$SERVER_PID" 2>/dev/null || break
        sleep 0.3
      done
      if kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "warning: server still alive after SIGTERM, sending SIGKILL" | tee -a "$RESULTS/run.log"
        kill -KILL "$SERVER_PID" 2>/dev/null
      fi
      wait "$SERVER_PID" 2>/dev/null
      echo "server_exit:$?" | tee -a "$RESULTS/run.log"
    else
      echo "SERVER_DIED before cleanup (pid $SERVER_PID)" | tee -a "$RESULTS/run.log"
    fi
  fi
  if [[ "$COMPOSE_UP" -eq 1 ]]; then
    podman stop zs-cutre >/dev/null 2>&1 || true
    podman rm zs-cutre >/dev/null 2>&1 || true
  fi
  exit "$rc"
}
trap cleanup EXIT INT TERM

if [[ "$MODE" != "podman" ]] && ss -ltn | awk '{print $4}' | grep -qE '(^|:)8080$'; then
  if curl -fsS --max-time 2 "$BASE_URL/health" >/dev/null 2>&1; then
    echo "error: something already healthy on $BASE_URL — refuse to clobber. Stop it first." >&2
    exit 1
  fi
  echo "error: port 8080 is taken and /health is not ok. Not measuring anything." >&2
  exit 1
fi

echo "==> starting z-server mode=$MODE" | tee -a "$RESULTS/run.log"

if [[ "$MODE" == "host" ]]; then
  if [[ ! -x "$ROOT/zig-out/bin/z-server" ]]; then
    echo "==> zig build -Doptimize=ReleaseSafe" | tee -a "$RESULTS/run.log"
    zig build -Doptimize=ReleaseSafe
  fi
  ( cd "$ROOT" && ./zig-out/bin/z-server >>"$RESULTS/server.log" 2>&1 ) &
  SERVER_PID=$!
  STARTED_SERVER=1
  echo "server_pid=$SERVER_PID" | tee -a "$RESULTS/run.log"
else
  mkdir -p "$ROOT/data-loadtest"
  chmod 0777 "$ROOT/data-loadtest" 2>/dev/null || true
  podman rm -f zs-cutre >/dev/null 2>&1 || true
  # Cheap-VPS cgroup: same memory and memory-swap ⇒ no swap, OOM killer if exceeded.
  PODMAN_ENV=(
    -e Z_SERVER_BIND=0.0.0.0:8080
    -e Z_SERVER_HANDLER_THREADS="$HANDLER_THREADS"
    -e Z_SERVER_SQLITE_POOL="$SQLITE_POOL"
  )
  if [[ -n "$SQLITE_SYNCHRONOUS" ]]; then
    PODMAN_ENV+=(-e "Z_SERVER_SQLITE_SYNCHRONOUS=$SQLITE_SYNCHRONOUS")
  fi
  podman run -d --name zs-cutre \
    --memory="$MEMORY" --memory-swap="$MEMORY" --cpus="$CPUS" \
    -p 127.0.0.1:8080:8080 \
    -v "$ROOT/data-loadtest:/app/data:Z" \
    "${PODMAN_ENV[@]}" \
    "$IMAGE"
  COMPOSE_UP=1
  SERVER_PID="$(podman inspect -f '{{.State.Pid}}' zs-cutre 2>/dev/null || true)"
fi

ok=0
for i in $(seq 1 50); do
  if curl -fsS --max-time 1 "$BASE_URL/health" >/dev/null 2>&1; then
    ok=1
    break
  fi
  if [[ "$STARTED_SERVER" -eq 1 && -n "$SERVER_PID" ]] && ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "error: z-server exited before becoming healthy. log:" >&2
    tail -50 "$RESULTS/server.log" >&2
    exit 1
  fi
  sleep 0.2
done
if [[ "$ok" -ne 1 ]]; then
  echo "error: z-server did not become healthy at $BASE_URL/health" >&2
  tail -50 "$RESULTS/server.log" >&2 || true
  exit 1
fi
echo "==> healthy $(curl -sS "$BASE_URL/health")" | tee -a "$RESULTS/run.log"

{
  echo "k6: $($K6_BIN version | head -1)"
  echo "nproc: $(nproc)"
  echo "mem: $(awk '/MemTotal:/{t=$2} /MemAvailable:/{a=$2} END{printf \"total_kb=%s avail_kb=%s\\n\", t, a}' /proc/meminfo)"
  echo "uname: $(uname -a)"
  echo "mode=$MODE users=$USERS duration=$DURATION max_vus=$MAX_VUS ramp_up=$RAMP_UP"
} > "$RESULTS/meta.txt"

SAMPLER="$ROOT/loadtest/sample.sh"
chmod +x "$SAMPLER"
SAMPLE_DB="$ROOT/data/app.db"
if [[ "$MODE" == "podman" ]]; then SAMPLE_DB="$ROOT/data-loadtest/app.db"; fi
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

if [[ "$STARTED_SERVER" -eq 1 && -n "$SERVER_PID" ]] && ! kill -0 "$SERVER_PID" 2>/dev/null; then
  echo "SERVER_DIED during k6 (pid $SERVER_PID)" | tee -a "$RESULTS/run.log"
fi

if [[ -n "$SAMPLER_PID" ]]; then
  kill "$SAMPLER_PID" 2>/dev/null || true
  wait "$SAMPLER_PID" 2>/dev/null || true
  SAMPLER_PID=""
fi

chmod +x "$ROOT/loadtest/analyze.sh"
"$ROOT/loadtest/analyze.sh" "$RESULTS"
{
  echo "# z-server load test report"
  echo
  echo "Run: $(basename "$RESULTS"). Generated by loadtest/run.sh from analysis.md."
  echo
  cat "$RESULTS/analysis.md"
} > "$RESULTS/REPORT.md"

if [[ "$K6_RC" -eq 0 || "$K6_RC" -eq 99 ]]; then
  # 99 = thresholds failed; the run itself completed.
  echo "==> done (k6_exit=$K6_RC). See $RESULTS/analysis.md" | tee -a "$RESULTS/run.log"
  exit 0
fi
echo "error: k6 exited $K6_RC" | tee -a "$RESULTS/run.log"
exit "$K6_RC"
