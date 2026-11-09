# Phase 2 — SQLite pool and items API

Commands from `/home/sweb/z-server`. Zig **0.17.0**.

## Commands

```bash
zig version
zig build
zig build test --summary all
zig build run
```

In another terminal:

```bash
curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"name":"foo","payload":{"k":1}}' \
  http://127.0.0.1:8080/items

curl -s http://127.0.0.1:8080/items
curl -s http://127.0.0.1:8080/items/1
curl -s http://127.0.0.1:8080/items/9999
curl -s -X POST -d 'not json' http://127.0.0.1:8080/items
curl -s http://127.0.0.1:8080/health
```

After a live run:

```bash
sqlite3 data/app.db ".tables"
sqlite3 data/app.db "PRAGMA user_version;"
```

Expected: table `items`, user_version `1`.

POST `/items` returns `201` with `{"id":N}` where `N` is `sqlite3_last_insert_rowid` on that connection (first insert on a new file is `1`).

## JSON decisions

- **Parse POST:** `httpz.Request.jsonValue()` → `std.json.parseFromSliceLeaky` on `req.arena`. Then read `name` (string) and `payload` (must be a JSON object). No extra parser.
- **Store payload:** `std.json.Stringify.valueAlloc` writes the object to TEXT.
- **Serialize responses:** `res.json(...)` (httpz helper over `std.json.fmt`). GET-by-id parses stored payload back to `std.json.Value` so the client receives an object, not a string.

## Body size / 413

`request.max_body_size = 64 KiB`. httpz maps `error.BodyTooBig` to **413** in the worker before any handler runs (`src/worker.zig` `requestError`). Handlers do not duplicate that check.

## Corrections vs plan

- **`std.Thread.Mutex` does not exist in 0.17.0.** The pool uses `std.Io.Mutex` + `std.Io.Condition` with `lockUncancelable` / `waitUncancelable` / `signal`, which take `std.Io`.
- **`std.fs.cwd()` is gone.** Create `data/` with `std.Io.Dir.cwd().createDirPath(io, "data")`. Delete test files with `std.Io.Dir.deleteFileAbsolute`.
- **`std.time.nanoTimestamp` is gone.** Tests pick unique `/tmp/z-server-test-*.db` names with `std.testing.io.random`.
- **`App` lives in `src/main.zig`.** `src/handlers/items.zig` imports it via `@import("../main.zig").App`.
- **httpz.testing does not run the router.** GET `/items/:id` tests call `ht.param("id", ...)`.
- **`std.Thread.Mutex.Condition`:** N/A; see Io condition above.
- **SIGINT handler** stays `fn shutdown(_: std.posix.SIG) callconv(.c) void`. Server type is now `httpz.Server(*App)`.
- Shutdown after `listen()` returns: `app.db.deinit()` then `defer server.deinit()`.

## Tests

`zig build test --summary all` should show:

```
Build Summary: 35/35 steps succeeded; 2/2 tests passed
+- run test
+- run test http_smoke
+- run test db_smoke 2 pass
+- run test items_http
```

`http_smoke` covers `/` and `/health` (now with `"db":"ok"`). `items_http` has 5 tests. `db_smoke` has insert/select/delete plus two threads acquiring distinct `sqlite3*` pointers. Cached runs still count as pass.
