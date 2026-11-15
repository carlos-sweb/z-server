# hello-db

Example consumer project demonstrating `z-server` HTTP core combined with the optional `z_server_db` SQLite module.

## Features

- HTTP server provided by `z_server` module.
- SQLite connection pool provided by `z_server_db` module.
- Zero BearSSL or Pogocache dependencies.

## Building

Dynamic (default, ~1.2 MB):
```bash
zig build
./zig-out/bin/hello-db
# -> hello-db listening on 127.0.0.1:9000
```

Static (~1.2 MB, portable):
```bash
zig build -Dtarget=x86_64-linux-musl
./zig-out/bin/hello-db
# -> hello-db listening on 127.0.0.1:9000
```

## Endpoints

- `GET /` -> `{"service":"hello-db"}`
- `GET /db-check` -> `{"db":"connected","query_result":1}`
