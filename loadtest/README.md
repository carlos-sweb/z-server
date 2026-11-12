# z-server load test

Realistic CRUD load against **z-server v0.1.1** using [k6](https://k6.io) 0.54.0.

## App: personal TODO list

Each simulated user owns a private list of tasks stored as `/items` rows:

| TODO field | HTTP mapping |
|---|---|
| title | `name` |
| done, priority, tags, due_date, notes | `payload` (JSON object) |

Why this domain: it uses every existing verb without changing the server. `GET /items` is the inbox (last 100 rows globally — the API has no per-user filter). `GET /items/:id` is the cache-aside path (`X-Cache: HIT\|MISS`). `POST` creates a task, `PUT` toggles `done` / retitles, `DELETE` removes it (and the client recreates so the DB does not drain). Payloads stay well under 32 KiB so they **are** cached.

The server does not know this is a TODO app.

## 10,000 users vs MAX_VUS

- **USERS=10000** unique identities, partitioned across VUs (each identity keeps its own item IDs).
- **MAX_VUS=200** (default, ceiling in the brief was 500) is **concurrent k6 VUs**, i.e. how many user-loops run at once. That is what stresses the 16-connection SQLite pool.
- Identities are **not** 10,000 concurrent TCP clients. That would be 10,000 VUs.

### Little's Law (do not ignore)

`RPS_objetivo × think_time_promedio = VUs_activos`

Think times were shortened in v0.2.0 so k6 can reach **0 dropped iterations**. Arrival is capped at `vuShare / (think.mean + 1s)`. The **502 RPS** from the 1-vCPU cutre run is a ceiling of **(server + k6 client + think)**, not of the server alone.

`MAX_VUS=200` is still Fase 1 smoke. The official re-test is 2000 VUs / 5 min with `Z_SERVER_HANDLER_THREADS=4` and `Z_SERVER_SQLITE_POOL=4`.

## Profiles

| profile | users | think (s) | mix |
|---|---:|---|---|
| Lurker 40% | 4000 | μ=0.8 s | 80% list, 15% get, 5% health |
| Casual 35% | 3500 | μ=0.3 s | 50% list, 30% get, 15% post, 4% put, 1% del |
| Power 20% | 2000 | μ=0.12 s | 30% list, 30% get, 25% post, 12% put, 3% del |
| Editor 5% | 500 | μ=0.2 s | 20% list, 20% get, 10% post, 30% put, 20% del |

Expected request mix (weighted): ~60% GET, ~18% POST, ~15% PUT, ~7% DELETE.

Each identity POSTs 1–3 tasks on first use, never exceeds 50 items (PUT/DELETE instead), DELETE recreates until the last 5% of the scenario (then one delete is left as cleanup).

## How to run

k6 v0.54.0 is expected on `PATH` or `~/.local/bin/k6`:

```bash
curl -fsSL -o /tmp/k6.tar.gz \
  https://github.com/grafana/k6/releases/download/v0.54.0/k6-v0.54.0-linux-amd64.tar.gz
tar -C /tmp -xzf /tmp/k6.tar.gz
install -m 0755 /tmp/k6-v0.54.0-linux-amd64/k6 "$HOME/.local/bin/k6"
k6 version
```

## Execution in 3 phases

Always in this order. Each run writes a **new** directory `loadtest/results/run-YYYYMMDD-HHMMSS/` (never overwrites a previous run). `loadtest/results/latest` is a symlink to the last one.

### Fase 1 — Smoke (mandatory, always first)

```bash
./loadtest/run.sh --mode=host --users=1000 --duration=60s --max-vus=200
```

Goal: pipeline end-to-end (server starts, k6 runs, sampler writes CSV, `analyze.sh` writes `analysis.md`).

Expected: ~26 RPS, ~1,500 requests.

**Abort:** if `http_req_failed` > 5%, **do not** continue to Fase 2.

### Fase 2 — Realistic load (the official test)

```bash
./loadtest/run.sh --mode=host --users=10000 --duration=300s --max-vus=2500
```

Expected: ~330–500 RPS, ~100,000–150,000 requests.

Goal: p50/p95/p99 under realistic concurrency; name the first saturated resource.

### Fase 3 — Stress (optional, only if Fase 2 did not collapse)

```bash
./loadtest/run.sh --mode=host --users=10000 --duration=300s --max-vus=8000
```

Expected: ~1,000+ RPS, ~300,000 requests.

Goal: real breakpoint. If k6 saturates first (client CPU, or k6 **dropped iterations**), the report must say **the client was the limit**, not the server. Do not dress that up as a server measurement.

Podman (compose publishes 8080, `userns_mode: keep-id`):

```bash
./loadtest/run.sh --mode=podman --users=1000 --duration=60s
```

If something is already healthy on `:8080`, `run.sh` **exits 1** and does not clobber it.

## Outputs

Each execution: `loadtest/results/run-YYYYMMDD-HHMMSS/`.

| file | what |
|---|---|
| `k6-summary.json` | `--summary-export` (p50/p95/p99, reqs, failed, **checks `X-Cache HIT` / `X-Cache MISS`**) |
| `k6.json` | NDJSON metric points (large) |
| `server-samples.csv` | 5 s `/proc` samples |
| `analysis.md` | endpoint table, resource table, hit_ratio, breakpoint |
| `loadtest/report-template.md` | fill from analysis.md |

`run.sh` treats k6 exit **99** (failed thresholds) as success of the *run* so a saturated server still produces analysis. `analyze.sh` **fails** if those X-Cache checks are missing (it will not report `hit_ratio=0`).

## Sampler (`/proc`, every 5 s)

Reads, for the server PID:

| source | fields |
|---|---|
| `/proc/PID/status` | VmRSS, Threads |
| `/proc/PID/stat` | utime, stime → `cpu_pct` |
| `/proc/PID/io` | read_bytes, write_bytes → kB/s |
| `/proc/PID/fd/` | open fd count |
| `data/*.wal` / `data/*-wal` | WAL size bytes |

Ticks are aligned to wall clock so **300 s / 5 s ≥ 60 CSV rows** (a plain `sleep 5` after work would drift under 60).

### Metrics v0.1.1 does not export

- **cache_hits / cache_misses** in the CSV are always **0**. Hit ratio is computed **after** the run from `k6-summary.json` checks `X-Cache HIT` and `X-Cache MISS` on `GET /items/:id`: `hit_ratio = HIT / (HIT + MISS)`. If those checks are absent, `analyze.sh` exits 1.
- **sqlite_busy_count** in the CSV is always **0**. HTTP **503** in k6 is the proxy. v0.1.1 does not distinguish `PoolTimeout` vs `PoolClosed` vs SQLITE_BUSY without new instrumentation.

`pidstat` / `iostat` are optional (Fedora `sysstat`). The sampler does not need them.

## k6 as a possible bottleneck

VUs &gt; 5000 can saturate the **client** before the server. Signals: k6 process CPU pinned, warnings about **dropped iterations**. Fase 3 in that case is “client-limited”, not a server measurement. Say so in the report.

## Same-host caveat

Client (k6) and server share this machine. CPU/RAM/IO numbers are a **worst case** for that box: k6 VUs compete with z-server. Do not treat RPS as a networked production rating.

## Thresholds (documented, non-aborting)

- GET p99 < 100 ms (`dur_list`, `dur_get`, `dur_health`)
- POST/PUT/DELETE p99 < 500 ms
- `http_req_failed` < 5%
- checks > 95% (503 is an allowed status in checks; it **does** count as `http_req_failed`)

If the 1000-user / 60 s smoke exceeds 5% errors, that is a result (pool of 16, WAL, same-host), not a harness bug. Read `analysis.md`.

## Scaling knobs

```text
--users=10000     unique identities
--duration=300s   total scenario time (ramp + hold)
--ramp-up=60s     arrival-rate ramp
--max-vus=200     concurrent VUs (200 smoke / 2500 load / 8000 stress)
--mode=host|podman
--base-url=http://127.0.0.1:8080
--memory=512m     podman cgroup memory (and memory-swap; no swap)
--cpus=1          podman cgroup CPUs
```

`--mode=podman` runs `localhost/z-server:0.2.0` as `zs-cutre` with `--memory=512m --memory-swap=512m --cpus=1` (cheap-VPS profile: 1 vCPU, 512 MiB, no swap). Data dir: `./data-loadtest` (host bind mount; never `podman volume rm` it).

Rebuild images with `./loadtest/build-image.sh` (build + `podman image prune -f --filter dangling=true`). Do not leave previous `:0.2.0` layers as `<none>:<none>`.

Ephemeral smokes (`zs-test-*`, `zs-smoke-*`) must use `podman run --rm`. Prefer `--tmpfs /app/data` or a named volume `zs-test-data-<n>` that `podman volume rm` deletes in the same step. If a test needs more than 5 GB of fixture data, document it and use a named Podman volume instead of `/tmp`.

`run.sh` exits 1 if `df ~` has less than 5 GB free.

## Disk hygiene

Manual cleanup (does **not** delete `./data-loadtest` or tagged `localhost/z-server:0.1.1` / `:0.2.0`):

```bash
podman image prune -f
podman volume prune -f
podman ps -a --filter status=exited --format '{{.Names}}' \
  | grep '^zs-' | xargs -r podman rm -f
```

Do **not** run `podman system prune -af --volumes` as a habit: it would remove unused named volumes. `data-loadtest` is a bind mount, but tagged baseline images can still be marked unused if no container references them.

- Smoke `--tmpfs /app/data` requires `mode=1777` (container user uid 1000 cannot write the default root-owned tmpfs; `uid=` is not accepted by this Podman).
- `./loadtest/build-image.sh --prune-only` runs `podman image prune -f --filter dangling=true` (and `podman volume prune -f`) without a rebuild.

## Change log

- **podman resource caps:** `--mode=podman` no longer uses compose. It `podman run`s `zs-cutre` with `--memory` / `--memory-swap` (same value ⇒ no swap, OOM killer) and `--cpus`. Defaults: `512m` / `1`.
