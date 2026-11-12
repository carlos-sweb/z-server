#!/usr/bin/env bash
# Sample server process every N seconds. sqlite_busy_count / cache_* stay 0:
# z-server v0.1.1 does not expose those counters (see loadtest/README.md).
set -uo pipefail

PID=0
OUT=""
DB=""
INTERVAL=5
HEALTH="http://127.0.0.1:8080/health"

for arg in "$@"; do
  case "$arg" in
    --pid=*) PID="${arg#*=}" ;;
    --out=*) OUT="${arg#*=}" ;;
    --db=*) DB="${arg#*=}" ;;
    --interval=*) INTERVAL="${arg#*=}" ;;
    --health=*) HEALTH="${arg#*=}" ;;
  esac
done

if [[ -z "$OUT" ]]; then
  echo "sample.sh: --out is required" >&2
  exit 2
fi

CLK=$(getconf CLK_TCK)
echo "timestamp,rss_kb,cpu_pct,threads,fd_count,sqlite_busy_count,io_read_bytes,io_write_bytes,wal_size_bytes,disk_read_kbs,disk_write_kbs" > "$OUT"

prev_ticks=""
prev_t=""
prev_rbytes=""
prev_wbytes=""
dt=""

proc_alive() {
  [[ "$PID" =~ ^[0-9]+$ ]] && [[ "$PID" -gt 0 ]] && [[ -r "/proc/$PID/stat" ]]
}

wal_bytes() {
  local total=0 f sz key
  local -A seen=()
  local dir="."
  [[ -n "$DB" ]] && dir="$(dirname "$DB")"
  shopt -s nullglob
  for f in "$dir"/*.wal "$dir"/*-wal "$dir"/*.db-wal ${DB:+"${DB}-wal"}; do
    [[ -f "$f" ]] || continue
    key=$(stat -c %d:%i "$f" 2>/dev/null || echo "$f")
    [[ -n "${seen[$key]:-}" ]] && continue
    seen[$key]=1
    sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
    total=$((total + sz))
  done
  shopt -u nullglob
  echo "$total"
}

# Wall-clock ticks so 300 s / 5 s yields ≥ 60 rows (sleep 5 after work would drift).
n=0
start_ns=$(date +%s%N)

while true; do
  ts=$(date +%s)
  rss_kb=""
  cpu_pct=""
  threads=""
  fd_count=""
  busy=""
  io_r=""
  io_w=""
  wal=""
  read_kbs=""
  write_kbs=""

  if proc_alive; then
    rss_kb=$(awk '/VmRSS:/{print $2}' "/proc/$PID/status" 2>/dev/null || true)
    threads=$(awk '/Threads:/{print $2}' "/proc/$PID/status" 2>/dev/null || true)
    ticks=$(awk '{print $14+$15}' "/proc/$PID/stat" 2>/dev/null || true)
    now_ns=$(date +%s%N)
    if [[ -n "$prev_ticks" && -n "$prev_t" && -n "$ticks" && "$now_ns" -gt "$prev_t" ]]; then
      dt=$(awk -v n="$now_ns" -v p="$prev_t" 'BEGIN{printf "%.6f", (n-p)/1e9}')
      cpu_pct=$(awk -v t="$ticks" -v pt="$prev_ticks" -v dt="$dt" -v clk="$CLK" \
        'BEGIN{ if (dt>0) printf "%.2f", 100*(t-pt)/clk/dt; else print 0 }')
    fi
    prev_ticks=$ticks
    prev_t=$now_ns
  fi

  # Metrics the process publishes (not host /proc/<container-pid>/io, which is 0400).
  if health_json=$(curl -fsS --max-time 1 "$HEALTH" 2>/dev/null); then
    busy=$(printf '%s' "$health_json" | jq -r '.sqlite_busy_count // empty')
    io_r=$(printf '%s' "$health_json" | jq -r '.io_read_bytes // empty')
    io_w=$(printf '%s' "$health_json" | jq -r '.io_write_bytes // empty')
    fd_count=$(printf '%s' "$health_json" | jq -r '.fd_count // empty')
    if [[ -n "$prev_rbytes" && -n "$prev_wbytes" && -n "$io_r" && -n "$io_w" && -n "$dt" ]]; then
      read_kbs=$(awk -v n="$io_r" -v p="$prev_rbytes" -v dt="$dt" 'BEGIN{ if (dt>0) printf "%.2f", (n-p)/1024/dt; else print 0 }')
      write_kbs=$(awk -v n="$io_w" -v p="$prev_wbytes" -v dt="$dt" 'BEGIN{ if (dt>0) printf "%.2f", (n-p)/1024/dt; else print 0 }')
    fi
    prev_rbytes=$io_r
    prev_wbytes=$io_w
  fi

  wal=$(wal_bytes)

  echo "$ts,${rss_kb},${cpu_pct},${threads},${fd_count},${busy},${io_r},${io_w},${wal},${read_kbs},${write_kbs}" >> "$OUT"

  n=$((n + 1))
  target_ns=$(awk -v s="$start_ns" -v n="$n" -v i="$INTERVAL" 'BEGIN{printf "%.0f", s + n*i*1e9}')
  now_ns=$(date +%s%N)
  delay=$(awk -v t="$target_ns" -v n="$now_ns" 'BEGIN{d=(t-n)/1e9; if (d>0) printf "%.6f", d; else print 0}')
  sleep "$delay"
done
