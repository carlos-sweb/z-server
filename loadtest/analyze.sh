#!/usr/bin/env bash
# Build analysis.md from a run directory (k6-summary.json + server-samples.csv).
# X-Cache HIT/MISS are required checks in k6-summary.json (jq). Missing → exit 1.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -n "${1:-}" ]]; then
  RES="$1"
elif [[ -L "$ROOT/loadtest/results/latest" ]]; then
  RES="$ROOT/loadtest/results/latest"
else
  RES="$ROOT/loadtest/results"
fi
SUM="$RES/k6-summary.json"
CSV="$RES/server-samples.csv"
JSON="$RES/k6.json"
OUT="$RES/analysis.md"

if [[ ! -f "$SUM" ]]; then
  echo "error: missing $SUM — run loadtest/run.sh first" >&2
  exit 1
fi

# k6 --summary-export stores named checks under root_group (object or nested).
check_passes() {
  local name="$1"
  jq -r --arg n "$name" '
    def by_name:
      [ .. | objects | select(.name == $n and has("passes")) | .passes ] | add;
    def by_key:
      [ .. | objects | to_entries[]? | select(.key == $n) | .value | objects | .passes ] | add;
    (by_name // by_key)
  ' "$SUM"
}

HIT_RAW="$(check_passes "X-Cache HIT")"
MISS_RAW="$(check_passes "X-Cache MISS")"

if [[ "$HIT_RAW" == "null" || -z "$HIT_RAW" || "$MISS_RAW" == "null" || -z "$MISS_RAW" ]]; then
  echo "error: k6-summary.json has no X-Cache HIT/MISS checks (looked for check name \"X-Cache HIT\" and \"X-Cache MISS\")." >&2
  echo "       GET /items/:id must record those checks from the X-Cache header. Refusing to report hit_ratio=0." >&2
  exit 1
fi

HIT="$HIT_RAW"
MISS="$MISS_RAW"
if [[ $((HIT + MISS)) -eq 0 ]]; then
  echo "error: X-Cache HIT+MISS = 0 in $SUM (no GET /items/:id with X-Cache). Cannot compute hit_ratio." >&2
  exit 1
fi

echo "X-Cache HIT=$HIT MISS=$MISS hit_ratio=$(awk -v h="$HIT" -v m="$MISS" 'BEGIN{printf "%.4f", h/(h+m)}')"

python3 - "$SUM" "$CSV" "$JSON" "$OUT" "$RES/run.log" "$HIT" "$MISS" <<'PY'
import json, os, sys, math, collections

sum_path, csv_path, json_path, out_path, runlog_path, hit_s, miss_s = sys.argv[1:8]

with open(sum_path) as f:
    summary = json.load(f)

metrics = summary.get("metrics", {})

def mval(name, key, default=None):
    m = metrics.get(name) or {}
    # k6 --summary-export 0.54 is flat ({count, rate} / {med, p(99), ...}).
    # Older/other exporters nest under "values".
    vals = m.get("values") if isinstance(m.get("values"), dict) else m
    return vals.get(key, default)

def trend_row(label, names):
    # names: duration trend, optional count from same trend 'count'
    dur_name = names[0]
    raw = metrics.get(dur_name) or {}
    values = raw.get("values") if isinstance(raw.get("values"), dict) else raw
    n = values.get("count", 0) or 0
    p50 = values.get("med", values.get("p(50)", 0)) or 0
    p95 = values.get("p(95)", 0) or 0
    p99 = values.get("p(99)", 0) or 0
    mx = values.get("max", 0) or 0
    return n, p50, p95, p99, mx

checks = metrics.get("checks") or {}
checks_vals = checks.get("values") or {}
http_reqs = mval("http_reqs", "count", 0) or 0
http_rate = mval("http_reqs", "rate", 0) or 0
fail_rate = mval("http_req_failed", "rate", 0) or 0
fail_count = mval("http_req_failed", "count", 0) or 0
p50 = mval("http_req_duration", "med", 0) or 0
p95 = mval("http_req_duration", "p(95)", 0) or 0
p99 = mval("http_req_duration", "p(99)", 0) or 0
pmax = mval("http_req_duration", "max", 0) or 0
hits = int(hit_s)
misses = int(miss_s)
n503 = mval("status_503", "count", 0) or 0
hit_ratio = hits / (hits + misses)

endpoints = [
    ("GET /health", "dur_health"),
    ("GET /items", "dur_list"),
    ("GET /items/:id", "dur_get"),
    ("POST /items", "dur_post"),
    ("PUT /items/:id", "dur_put"),
    ("DELETE /items/:id", "dur_delete"),
]

# 503s are global (status_503); per-endpoint 503 is not split in custom counters.
ep_lines = []
for label, trend in endpoints:
    n, a, b, c, d = trend_row(label, [trend])
    ep_lines.append((label, n, a, b, c, d))

samples = []
if os.path.isfile(csv_path):
    with open(csv_path) as f:
        header = f.readline()
        for line in f:
            parts = line.strip().split(",")
            if len(parts) < 11:
                continue
            try:
                samples.append({
                    "t": int(parts[0]),
                    "rss_kb": float(parts[1] or 0),
                    "cpu": float(parts[2] or 0),
                    "threads": float(parts[3] or 0),
                    "fd": float(parts[4] or 0),
                    "busy": float(parts[5] or 0) if parts[5] not in ("", "null") else 0,
                    "io_r": float(parts[6] or 0) if parts[6] not in ("", "null") else 0,
                    "io_w": float(parts[7] or 0) if parts[7] not in ("", "null") else 0,
                    "wal": float(parts[8] or 0) if parts[8] not in ("", "null") else 0,
                    "rkb": float(parts[9] or 0) if parts[9] not in ("", "null") else 0,
                    "wkb": float(parts[10] or 0) if parts[10] not in ("", "null") else 0,
                })
            except ValueError:
                continue

# Breakpoint from k6.json (NDJSON Point rows), 10s windows.
breakpoint = None
timeline = []  # minute buckets
if os.path.isfile(json_path) and os.path.getsize(json_path) > 0:
    windows = collections.defaultdict(lambda: {"dur": [], "fail": 0, "n": 0, "s503": 0})
    t0 = None
    with open(json_path, "r", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if obj.get("type") != "Point":
                continue
            data = obj.get("data") or {}
            metric = obj.get("metric")
            t = data.get("time")
            if not t:
                continue
            # RFC3339 → epoch roughly via slicing if python has fromisoformat
            try:
                ts = t.replace("Z", "+00:00")
                # datetime fromisoformat supports +00:00
                from datetime import datetime
                epoch = datetime.fromisoformat(ts).timestamp()
            except Exception:
                continue
            if t0 is None:
                t0 = epoch
            rel = epoch - t0
            w = int(rel // 10)
            tags = data.get("tags") or {}
            val = data.get("value")
            if metric == "http_req_duration" and isinstance(val, (int, float)):
                windows[w]["dur"].append(val)
                windows[w]["n"] += 1
            if metric == "http_req_failed" and val:
                windows[w]["fail"] += 1
            if metric == "status_503" and val:
                windows[w]["s503"] += 1
            st = str(tags.get("status", ""))
            if metric == "http_reqs" and st == "503":
                windows[w]["s503"] += 1

    def percentile(xs, p):
        if not xs:
            return 0
        ys = sorted(xs)
        i = min(len(ys) - 1, max(0, math.ceil(p / 100 * len(ys)) - 1))
        return ys[i]

    for w in sorted(windows):
        rec = windows[w]
        n = rec["n"] or 1
        err = rec["fail"] / n
        p99w = percentile(rec["dur"], 99)
        minute = (w * 10) // 60
        timeline.append((minute, w * 10, n, p99w, err, rec["s503"]))
        if breakpoint is None and (p99w > 1000 or err > 0.10):
            breakpoint = {
                "t_s": w * 10,
                "p99": p99w,
                "error_rate": err,
                "n": rec["n"],
                "s503": rec["s503"],
            }

runlog = ""
if os.path.isfile(runlog_path):
    runlog = open(runlog_path).read()
server_died = "SERVER_DIED" in runlog

lines = []
A = lines.append
A("# z-server load test analysis")
A("")
A("Generated by `loadtest/analyze.sh`. Copy into `report-template.md`.")
A("")
A("## A–H answers")
A("")
A(f"- **A. RPS** average `{http_rate:.1f}` (http_reqs `{http_reqs:.0f}`). Peak is not in the k6 summary; use the per-minute table if k6.json was parsed.")
A(f"- **B. Latency** overall p50 `{p50:.2f}` ms, p95 `{p95:.2f}` ms, p99 `{p99:.2f}` ms, max `{pmax:.2f}` ms.")
A(f"- **C. 503s** `{n503:.0f}` (custom `status_503`). http_req_failed count `{fail_count:.0f}`, rate `{fail_rate:.4f}`.")
A(f"- **D. Cache hit ratio** `{hit_ratio:.3f}` = HIT/(HIT+MISS) from k6 checks `X-Cache HIT` ({hits}) and `X-Cache MISS` ({misses}) in k6-summary.json. Sampler cache columns are 0 (v0.1.1 does not export them).")
if samples:
    busy_peak = max(s["busy"] for s in samples)
    io_w_peak = max(s["io_w"] for s in samples)
    io_r_peak = max(s["io_r"] for s in samples)
    A(f"- **E. SQLite busy_count** peak `{busy_peak:.0f}` (from /health). io_read_bytes peak `{io_r_peak:.0f}`, io_write_bytes peak `{io_w_peak:.0f}`. WAL in the resource table.")
else:
    A("- **E. SQLite** no sampler rows.")
if samples:
    rss = max(s["rss_kb"] for s in samples)
    cpu = max(s["cpu"] for s in samples)
    wal = max(s["wal"] for s in samples)
    A(f"- **F. Resources** peak RSS `{rss/1024:.1f}` MiB, peak CPU `{cpu:.1f}` % of one core, peak WAL `{wal/1024/1024:.2f}` MiB.")
else:
    A("- **F. Resources** no server-samples.csv rows.")
if server_died:
    A("- **G. Collapse** SERVER_DIED (see run.log).")
elif breakpoint:
    A(f"- **G. Breakpoint** first 10s window at t={breakpoint['t_s']}s with p99={breakpoint['p99']:.0f} ms and error_rate={breakpoint['error_rate']:.2%} (503s in window {breakpoint['s503']}).")
else:
    A("- **G. Collapse** no 10s window with p99>1s or error_rate>10% (or k6.json missing).")
A("- **H. v0.2.0** see Recommendations below.")
A("")
A("## Endpoint table")
A("")
A("| endpoint | n | p50 ms | p95 ms | p99 ms | max ms | errors | 503s |")
A("|---|---:|---:|---:|---:|---:|---:|---:|")
for label, n, a, b, c, d in ep_lines:
    A(f"| {label} | {n:.0f} | {a:.2f} | {b:.2f} | {c:.2f} | {d:.2f} | — | — |")
A("")
A("Per-endpoint error/503 splits are not in the custom trends; overall 503s = "
  f"`{n503:.0f}`, http_req_failed rate = `{fail_rate:.4f}`.")
A("")
A("## Resource table")
A("")
A("| t (unix) | rss_mb | cpu_pct | wal_mb | cache_hit_ratio | busy_timeouts |")
A("|---:|---:|---:|---:|---:|---:|")
if not samples:
    A(f"| — | — | — | — | {hit_ratio:.3f} | 0 |")
else:
    step = max(1, len(samples) // 24)
    for i, s in enumerate(samples):
        if i % step != 0 and i != len(samples) - 1:
            continue
        A(
            f"| {s['t']} | {s['rss_kb']/1024:.2f} | {s['cpu']:.1f} | {s['wal']/1024/1024:.3f} | {hit_ratio:.3f} | {s['busy']:.0f} |"
        )
A("")
A("cache_hit_ratio is the **test-wide** k6 ratio (sampler cache columns are always 0). busy_timeouts from sampler are always 0.")
A("")
A("## Breakpoint")
A("")
if breakpoint:
    A(
        f"First 10-second window with p99 > 1s **or** error_rate > 10%: "
        f"**t = {breakpoint['t_s']} s** (p99={breakpoint['p99']:.1f} ms, "
        f"error_rate={breakpoint['error_rate']:.2%}, n={breakpoint['n']}, 503s={breakpoint['s503']})."
    )
else:
    A("No window crossed p99>1s or error_rate>10%. If k6.json is empty, this test is inconclusive.")
A("")
A("## Per-minute (from k6.json, if present)")
A("")
A("| minute | t_s | n | p99 ms | error_rate | 503s |")
A("|---:|---:|---:|---:|---:|---:|")
if timeline:
    by_min = {}
    for minute, t_s, n, p99w, err, s503 in timeline:
        rec = by_min.setdefault(minute, {"n": 0, "dur_p99": [], "fail": 0, "s503": 0})
        rec["n"] += n
        rec["dur_p99"].append(p99w)
        rec["fail"] += err * n
        rec["s503"] += s503
    for minute in sorted(by_min):
        rec = by_min[minute]
        p = max(rec["dur_p99"]) if rec["dur_p99"] else 0
        er = (rec["fail"] / rec["n"]) if rec["n"] else 0
        A(f"| {minute} | {minute*60} | {rec['n']:.0f} | {p:.1f} | {er:.3f} | {rec['s503']:.0f} |")
else:
    A("| — | — | — | — | — | — |")
A("")
A("All latency values are in ms, same unit across the table. k6 `http_req_duration` points are milliseconds; a last-minute row with n=1 can show a sub-millisecond p99 (e.g. 0.2 ms) — that is one leftover request, not a unit mix.")
A("")
A("## Checks")
A("")
passes = checks_vals.get("passes", 0)
fails = checks_vals.get("fails", 0)
A(f"passes={passes} fails={fails} rate={checks_vals.get('rate', 0)}")
A("")
A("## Recommendations for v0.2.0")
A("")
A("- **SQLite pool:** v0.1.1 sizes the pool to `clamp(2*nproc,4,16)`. On 503/`PoolTimeout`, raise the cap (32–64) and measure WAL contention before blaming the pool.")
A("- **Cache TTL:** 60s. If GET :id p99 is fine and hit ratio < 0.5, users are editing (PUT invalidates). If hit ratio is high but list is slow, list is uncached by design.")
A("- **MAX_VALUE_BYTES:** 32 KiB. This test uses tiny TODO payloads (always cached). Do not raise it to hide SQLite cost.")
A("- **BEGIN IMMEDIATE:** consider for POST/PUT/DELETE if write 503s cluster with WAL growth.")
A("- **POST queue:** if POST p99 >> GET p99 and CPU is idle, a single writer thread (or WAL + IMMEDIATE) beats more pool connections.")
A("")

os.makedirs(os.path.dirname(out_path), exist_ok=True)
with open(out_path, "w") as f:
    f.write("\n".join(lines) + "\n")
print(f"wrote {out_path}")
PY
