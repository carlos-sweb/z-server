# Phase 4 — cache-aside and PUT/DELETE

Commands from `/home/sweb/z-server`. Zig **0.17.0**.

## Commands

```bash
zig version
zig build
zig build test --summary all
zig build run
```

## Curl sequence (HIT → PUT → MISS)

```bash
curl -s -D - -X POST -H 'Content-Type: application/json' \
  -d '{"name":"foo","payload":{"k":1}}' \
  http://127.0.0.1:8080/items

curl -sI http://127.0.0.1:8080/items/1 | grep -i x-cache   # MISS
curl -sI http://127.0.0.1:8080/items/1 | grep -i x-cache   # HIT

curl -s -D - -X PUT -H 'Content-Type: application/json' \
  -d '{"name":"bar","payload":{"k":2}}' \
  http://127.0.0.1:8080/items/1

curl -sI http://127.0.0.1:8080/items/1 | grep -i x-cache   # MISS
curl -sI http://127.0.0.1:8080/items/1 | grep -i x-cache   # HIT

curl -s -D - -X DELETE http://127.0.0.1:8080/items/1       # 204
curl -sI http://127.0.0.1:8080/items/1                     # 404
curl -s -D - -X DELETE http://127.0.0.1:8080/items/1       # 404
```

`GET /items` (list) and `POST /items` do not set `X-Cache`.

Cache key is `item:{id}`, TTL 60 seconds. Invalidation on PUT/DELETE is immediate (`cache.delete`), not TTL-based.

## Byte-identical HIT

GET miss serializes the item **once** with `std.json.Stringify.valueAlloc` into `res.arena`. Those bytes are `res.body` and, if `len <= MAX_VALUE_BYTES`, `cache.set`. A later HIT copies the same bytes from Pogocache into `res.body`.

`res.content_type` is `httpz.ContentType.JSON` (enum is `.JSON`, not `.json`).

## Oversized values

If the serialized item JSON is larger than 64 KiB, it is served from SQLite with `X-Cache: MISS` and is not stored. HTTP `request.max_body_size` remains 64 KiB, so a live POST whose **request body** exceeds 64 KiB is still 413. The cache skip test uses a payload that fits in the POST body in `httpz.testing` (no worker `BodyTooBig`) while the serialized GET JSON exceeds 64 KiB.

## Corrections vs plan

- httpz `ContentType` members are uppercase (`.JSON`). The plan's `.json` would not compile.
- `res.json()` writes into an internal buffer that **takes precedence** over `res.body` (`buffered.len > 0 ? buffer : body`). HIT/MISS therefore set `res.body` and must not call `res.json()`.
- `router.put` and `router.delete` exist at commit 1bb71ff.
- `res.header("X-Cache", ...)` stores the name as given; tests expect `X-Cache`.
- PUT body requires both `name` and `payload` (same parser as POST).
- PUT does **not** `cache.set` after the write, so the next GET is MISS.
- GET `:id` is parsed as `u32` (400 if not).
