# Phase 3 — embedded Pogocache

Commands from `/home/sweb/z-server`. Zig **0.17.0**.

## Commands

```bash
zig version
zig build
zig build test --summary all
zig build run
```

```bash
curl -s http://127.0.0.1:8080/health
```

Expected:

```json
{"ok":true,"version":"0.0.0","db":"ok","cache":"ok"}
```

Items endpoints from Phase 2 are unchanged (cache is not wired into GET/POST `/items` yet).

`ldd zig-out/bin/z-server` must show `libsqlite3.so.0` and must **not** show a pogocache `.so`. Pogocache is compiled into the binary via `addCSourceFile`.

## Vendored files hashes

Tag `1.3.2`, commit `9ca1b8d18be6c1582723e89433bc3c002ba53b04`.

| File | SHA-256 |
|---|---|
| `vendor/pogocache/pogocache.c` | `471de58608733128c39ba6b7c3682990f1f29592fdb372c637c6d4976322cd34` |
| `vendor/pogocache/pogocache.h` | `c0cf911557e4bb4c03d099f85250b4dd18c37b58790f0876706701af100b2dbc` |
| `vendor/pogocache/LICENSE` | `19d11348ac185f11e283ddc934604624b847ff0a4b24d918d9d20dc6a285d22b` |

License: MIT (Polypoint Labs, LLC). Source is unmodified.

## Bindings

One `src/c/bindings.h` includes both `<sqlite3.h>` and `"pogocache.h"`. A single `translate_c` module named `"c"` is enough: `Translator.addIncludePath(vendor/pogocache)` finds the vendored header; sqlite3 still comes from the system library.

`pogocache.c` is compiled with `-std=c11 -D_GNU_SOURCE` into the root module. `_GNU_SOURCE` is required so `<time.h>` exposes `clock_gettime` / `CLOCK_BOOTTIME` (used by unmodified 1.3.2). `linkSystemLibrary("m")` covers `math.h`.

## Cache settings

- `nshards = 512`: covers `clamp(2*nproc, 4, 16)` handler threads without the C default of 4096 shards (header comment 65536 is stale; `DEFSHARDS` in `.c` is 4096).
- `usethreadbatch = false` (TLS batch is not reentrant).
- Application TTL is seconds; wrapper multiplies by `POGOCACHE_SECOND` (nanoseconds) for the C ABI.
- Values larger than 64 KiB return `error.ValueTooLarge` without calling `pogocache_store`.

## Corrections vs plan

- Header comment `nshards` default 65536 vs implementation `DEFSHARDS 4096`. We set 512 explicitly.
- `pogocache_new` returns NULL on OOM; mapped to `error.CacheNoMem`.
- `pogocache_delete` of a missing key returns `POGOCACHE_NOTFOUND`; treated as success (idempotent).
- `error.CacheIo` is in the error set but unused: the embeddable library has no I/O path.
- `Cache.init` takes a Zig allocator for API stability; Pogocache 1.3.2 uses libc `malloc`.
- `http_smoke` / `items_http` TestEnv now construct `Cache` because `App` gained that field. Item HTTP behavior is unchanged.
- `/health` reports `cache` independently of `db` and uses HTTP 503 if either fails.
- Zig 0.17 removed `**` array repeat. The oversized-value test uses `@splat(0)` instead of `[_]u8{0} ** N`.

## Tests

`zig build test --summary all` includes `run test cache_smoke` with:

1. set/get
2. miss
3. TTL (1s then sleep 1100ms)
4. ValueTooLarge
5. four threads on distinct keys
