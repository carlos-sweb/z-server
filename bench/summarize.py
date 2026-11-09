#!/usr/bin/env python3
import argparse
import datetime
import json
import subprocess
from pathlib import Path


def ns_to_ms(value):
    if value is None:
        return None
    if value > 10:
        return value / 1_000_000.0
    return value * 1000.0


def pick(d, *keys):
    cur = d
    for k in keys:
        if not isinstance(cur, dict) or k not in cur:
            return None
        cur = cur[k]
    return cur


def load_stats(path):
    data = json.loads(Path(path).read_text())
    summary = data.get("summary", data)
    rps = (
        pick(summary, "requestsPerSec")
        or pick(summary, "rps")
        or pick(data, "rps")
    )
    errors = (
        pick(summary, "errorCount")
        or pick(summary, "errors")
        or 0
    )
    status = pick(data, "statusCodeDistribution") or pick(data, "status") or {}
    if isinstance(status, dict):
        bad = sum(v for k, v in status.items() if str(k) not in ("200", "201", "204"))
        errors = max(int(errors or 0), int(bad))
    percentiles = (
        pick(data, "latencyPercentiles")
        or pick(summary, "latencyPercentiles")
        or pick(data, "responseTimePercentiles")
        or {}
    )
    p50 = percentiles.get("p50") or percentiles.get("50.0") or percentiles.get("median")
    p95 = percentiles.get("p95") or percentiles.get("95.0")
    p99 = percentiles.get("p99") or percentiles.get("99.0")
    if p50 is None:
        p50 = pick(summary, "average")
    return {
        "rps": float(rps or 0),
        "p50_ms": ns_to_ms(p50) or 0,
        "p95_ms": ns_to_ms(p95) or 0,
        "p99_ms": ns_to_ms(p99) or 0,
        "errors": int(errors or 0),
        "raw": data,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--oha", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("pairs", nargs="+", help="name path name path ...")
    args = parser.parse_args()
    names = args.pairs[0::2]
    paths = args.pairs[1::2]
    rows = [(n, load_stats(p)) for n, p in zip(names, paths)]
    version = subprocess.check_output([args.oha, "--version"], text=True).strip()
    hit = next((s for n, s in rows if n == "hit"), None)
    miss = next((s for n, s in rows if n == "miss"), None)

    lines = [
        f"# z-server bench results",
        "",
        f"- date: {datetime.datetime.now(datetime.timezone.utc).isoformat()}",
        f"- tool: {version}",
        "",
        "| scenario | n | c | RPS | p50 ms | p95 ms | p99 ms | errors |",
        "|---|---:|---:|---:|---:|---:|---:|---:|",
    ]
    counts = {"hit": "1000", "miss": "1000", "post": "500", "list": "1000"}
    conc = "50"
    for name, s in rows:
        lines.append(
            f"| {name} | {counts.get(name, '?')} | {conc} | {s['rps']:.1f} | "
            f"{s['p50_ms']:.3f} | {s['p95_ms']:.3f} | {s['p99_ms']:.3f} | {s['errors']} |"
        )
    lines.append("")
    if hit and miss:
        cmp = "yes" if hit["p99_ms"] < miss["p99_ms"] else "NO"
        lines.append(
            f"p99 HIT ({hit['p99_ms']:.3f} ms) < p99 MISS ({miss['p99_ms']:.3f} ms): **{cmp}**"
        )
    Path(args.out).write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
