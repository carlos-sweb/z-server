# Phase 5 — robustness, limits, load

Commands from `/home/sweb/z-server`. Zig **0.17.0**.

```bash
zig build
zig build test --summary all
./bench/run.sh
./bench/valgrind.sh
```

Address-in-use check:

```bash
./zig-out/bin/z-server &
./zig-out/bin/z-server
# stderr: error: address 127.0.0.1:8080 already in use
# exit 2
```

## Limits

| knob | value |
|---|---|
| `request.max_body_size` | 64 KiB |
| `MAX_VALUE_BYTES` | 32 KiB |
| `CACHE_TTL_SECONDS` | 60 |
| pool acquire wait | 5 s (`Condition.waitTimeout`) |
| bind | 127.0.0.1:8080 |

A POST of ~40 KiB is accepted (under 64 KiB) and stored in SQLite, but GET JSON is larger than 32 KiB so it is never cached (`X-Cache: MISS` twice). A ~30 KiB payload is cached.

## Benchmark

Tool: oha 1.16.0 (`bench/oha`, downloaded from GitHub releases). Fedora install: `sudo dnf install oha` or the curl in `bench/README.md`.

See `bench/results.md` (UTC 2026-11-09):

| scenario | n | c | RPS | p50 ms | p95 ms | p99 ms | errors |
|---|---:|---:|---:|---:|---:|---:|---:|
| hit | 1000 | 50 | 129856.9 | 0.292 | 0.618 | 0.941 | 0 |
| miss | 1000 | 50 | 5249.3 | 6.964 | 26.742 | 35.200 | 0 |
| post | 500 | 50 | 62.5 | 301.989 | 3565.037 | 5923.045 | 0 |
| list | 1000 | 50 | 22151.7 | 1.946 | 4.822 | 6.004 | 0 |

p99 HIT (0.941 ms) < p99 MISS (35.200 ms). MISS uses a 40 KiB uncached item. POST p99 is high because 50 concurrent writers serialize on SQLite WAL; retries keep errors at 0.

## Valgrind

`./bench/valgrind.sh` (1000 HIT requests, then SIGINT):

- in use at exit: 0 bytes in 0 blocks
- All heap blocks were freed -- no leaks are possible
- ERROR SUMMARY: 0 errors from 0 contexts
- process exit 0

Log: `bench/valgrind.log`. DWARF2 "Badly formed extended line op" warnings from Zig debug info are noise, not leaks.

## Known noise

- httpz/websocket logs `info(websocket): received shutdown signal` on SIGINT. Silenced with `std_options.log_scope_levels = &.{ .{ .scope = .websocket, .level = .err } }` in `src/main.zig` (same pattern as httpz `examples/08_websocket.zig`). No httpz server API exists to mute it without that.

## Known limitations

- MAX_VALUE_BYTES = 32 KiB, max_body_size = 64 KiB
- no TLS, no auth, no HTTP/2, no Prometheus metrics
- AddressInUse → `std.process.exit(2)` after `std.log.err` (juicy main would otherwise dump a stack and exit 1)
- acquire wait is 5 seconds for a **free connection**, not a per-lease watchdog
- POST under high concurrency is WAL-bound

## Corrections vs plan

- **`waitUncancelableTimeout` does not exist** in 0.17.0 `std.Io.Condition`. The timeout API is `waitTimeout(io, mutex, Timeout)` (`Timeout.Error.Timeout` plus `Canceled`). Used with `{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } }` while the mutex is held via `lockUncancelable`.
- **`std.process.exit(2)`** is required for AddressInUse: returning `error.AddressInUse` from juicy `main` always exits 1 and prints a stack.
- **Websocket mute:** `std.Options.log_scope_levels` for scope `.websocket` at `.err`. httpz has no per-server log filter.
- Valgrind's leak-free run prints `All heap blocks were freed -- no leaks are possible` instead of `definitely lost: 0 bytes`.
- oha 1.16.0 uses `--output-format json`, not `-j`.
