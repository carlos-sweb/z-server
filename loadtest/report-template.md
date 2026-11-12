# z-server load test report

Fill from `loadtest/results/analysis.md` after `./loadtest/run.sh`. Do not edit the harness to “make numbers look good”.

## Resumen ejecutivo

- (3–5 lines: RPS avg/peak, p99, error/503 rate, whether the process survived 5 min, what ran out first.)
- A:
- B:
- F / G:

## Configuración

| | |
|---|---|
| Hardware | (nproc, RAM, disk — `results/meta.txt`) |
| OS | (`uname -a`) |
| z-server | v0.1.1, Zig 0.17.0, SQLite pool clamp(2*nproc,4,16), Pogocache 512 shards, TTL 60 s |
| Bind | host `127.0.0.1:8080` or compose `0.0.0.0:8080` |
| k6 | v0.54.0 |
| USERS / MAX_VUS / DURATION / RAMP_UP | |
| Same host? | yes / no |
| Mode | host / podman |

## Línea de tiempo

Paste the per-minute table from analysis.md (RPS implied by `n` per 60 s, p99, error_rate).

| minute | t_s | n | p99 ms | error_rate | 503s |
|---:|---:|---:|---:|---:|---:|
| | | | | | |

## Breakdown por endpoint

Paste the endpoint table from analysis.md.

| endpoint | n | p50 ms | p95 ms | p99 ms | max ms | errors | 503s |
|---|---:|---:|---:|---:|---:|---:|---:|
| GET /health | | | | | | | |
| GET /items | | | | | | | |
| GET /items/:id | | | | | | | |
| POST /items | | | | | | | |
| PUT /items/:id | | | | | | | |
| DELETE /items/:id | | | | | | | |

## Breakdown por perfil

k6 tags each scenario `profile=lurker|casual|power|editor`. If tagged duration metrics appear in `k6-summary.json`, paste them here; otherwise note “scenario rates only” from the arrival-rate split in README.

| profile | weight | think μ | arrival/s (capped) | notes |
|---|---:|---:|---:|---|
| lurker | 0.40 | 15 | | |
| casual | 0.35 | 3.5 | | |
| power | 0.20 | 1.0 | | |
| editor | 0.05 | 2.0 | | |

## Estado del server

Paste the resource table (RSS, CPU % of one core, WAL MiB). Cache hit ratio is the k6 `X-Cache` ratio (sampler columns are 0). SQLite busy is 503/`busy`, not a PRAGMA counter.

## Punto de quiebre

From analysis.md “Breakpoint”: first 10 s window with p99 > 1 s or error_rate > 10%. Cause (pool / WAL / CPU / RAM / client saturation / same-host). If none, say so.

## Recomendaciones v0.2.0

Copy the bullet list from analysis.md and keep only what the numbers support:

- SQLite pool size
- Cache TTL
- MAX_VALUE_BYTES
- BEGIN IMMEDIATE
- Writer queue for POST
