# hello-cache

Example consumer project demonstrating `z-server` HTTP core combined with the optional `z_server_cache` in-memory Pogocache module.

## Features

- HTTP server provided by `z_server` module.
- High-performance in-memory cache provided by `z_server_cache` module (Pogocache).
- Zero SQLite or BearSSL dependencies.

## Building

Dynamic (default, ~500 KB):
```bash
zig build
./zig-out/bin/hello-cache
# -> hello-cache listening on 127.0.0.1:9000
```

ReleaseFast (~500 KB):
```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/hello-cache
```

## Endpoints

- `GET /` -> `{"service":"hello-cache"}`
- `GET /counter` -> `{"counter":1}`, `{"counter":2}`, ... (increments and caches for 60s)
