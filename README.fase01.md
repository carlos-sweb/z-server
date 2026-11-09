# Phase 1 — HTTP skeleton

All commands run from `/home/sweb/z-server`. Zig **0.17.0**.

http.zig is pinned at commit `1bb71ff128a044b1645df91046473c38abbf965c`. The APIs used here match that commit's examples (`01_basic.zig`, `09_shutdown.zig`) and `src/testing.zig`.

## Commands

```bash
zig version          # 0.17.0
zig build
zig build test --summary all
zig build run
```

In another terminal, while the server is listening:

```bash
curl -s http://127.0.0.1:8080/health
curl -s http://127.0.0.1:8080/
```

Stop the server with Ctrl+C (SIGINT). The process should exit after `server.stop()` unblocks `listen()`, then `deinit()`.

## Expected `zig build test --summary all`

Exit code 0. Two test artifacts:

- the Phase 0.0 version smoke (`tests/smoke.zig`)
- `http_smoke` (`tests/http_smoke.zig`) with:
  - `GET / returns ok json`
  - `GET /health returns version`

A passing summary looks like:

```
Build Summary: 31/31 steps succeeded; 2/2 tests passed
test success
+- run test cached
+- run test http_smoke 2 pass (2 total)
```

Exact step counts can vary with cache hits (`cached`). The `http_smoke` artifact and its two tests (`GET / returns ok json`, `GET /health returns version`) must appear. The Phase 0.0 version smoke is the other `run test` line.

## Expected `curl`

```bash
curl -s http://127.0.0.1:8080/health
```

```json
{"ok":true,"version":"0.0.0"}
```

```bash
curl -s http://127.0.0.1:8080/
```

```json
{"ok":true}
```

Startup lines on stdout:

```
z-server 0.0.0
sqlite3 3.51.2
listening on 127.0.0.1:8080
```

(`sqlite3` patch version follows the system `.so`.)

## Bind, workers, pool

- Bind: `httpz.Config.Address.localhost(8080)` → `127.0.0.1:8080`
- `workers.count = 1` (explicit, not null)
- `thread_pool.count = clamp(2 * nproc, 4, 16)` computed at runtime via `std.Thread.getCpuCount()`

## Shutdown

Copied from http.zig `examples/09_shutdown.zig` at 1bb71ff:

- `std.posix.sigaction` on SIGINT and SIGTERM
- handler `callconv(.c)` calls `server.stop()`
- `defer server.deinit()` after `listen()` returns

## Warnings

- Server/router/json/testing at 1bb71ff match the commit: `Server(void).init(io, allocator, config, {})`, `router.get(path, action, .{})`, `res.json(value, .{})`, `httpz.testing.init` / `expectStatus` / `expectJson`.
- **SIGINT handler type:** http.zig `examples/09_shutdown.zig` uses `fn shutdown(_: c_int) callconv(.c) void`. Zig 0.17.0 `std.posix.Sigaction.handler_fn` is `fn (std.posix.SIG) callconv(.c) void` (`lib/std/os/linux.zig`, `handler_fn`). Using `c_int` fails to compile. This process uses `std.posix.SIG`.
- HTTP tests call the handler functions directly (`app.index` / `app.health`) through `httpz.testing`. They do **not** open port 8080. Live `curl` requires `zig build run` in another terminal.
- `sqlite3_libversion()` is still called at startup so the linker keeps `libsqlite3.so.0` (`needed` defaults to false; an unused `.so` would be dropped).
