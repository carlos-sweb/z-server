# hello-all

> **Auth Note**: Auth is enabled: /items/* requires an API key. /health is public. See [docs/auth.md](../../docs/auth.md).

Example consumer project demonstrating the complete `z-server` module ecosystem. It combines the core HTTP server with all five optional modules: SQLite connection pooling, in-process sharded caching, native BearSSL TLS 1.2 termination, JSON file-based configuration, and API key authentication.

## Modules Used

- `z_server`: HTTP core server on `:9000`.
- `z_server_db`: SQLite connection pool (`data/app.db`).
- `z_server_cache`: In-process Pogocache (512 shards, cache-aside).
- `z_server_tls`: Native TLS 1.2 termination on `:9443` proxying to `:9000`.
- `z_server_config`: JSON configuration loader (`config.json`) and environment variable overrides.
- `z_server_auth`: API key authentication with HMAC-SHA256 and constant-time validation.

## Security note

The `cert.pem` and `key.pem` files in this directory are self-signed test certificates generated for localhost. They are intentionally committed so the example runs out-of-the-box.

DO NOT use these certificates in production. Generate your own with:
```bash
openssl req -x509 -newkey rsa:2048 -nodes -days 365 -keyout key.pem -out cert.pem -subj "/CN=localhost"
```

## Building & Running

Compile and run:
```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/hello-all
```

## Testing Endpoints

Test HTTP health check:
```bash
curl -s http://127.0.0.1:9000/health
# -> {"ok":true,"version":"0.5.0","service":"hello-all","db":"ok","cache":"ok"}
```

Test HTTPS health check (TLS 1.2):
```bash
curl -sk https://127.0.0.1:9443/health
# -> {"ok":true,"version":"0.5.0","service":"hello-all","db":"ok","cache":"ok","tls_version":"TLSv1.2"}
```

Test cache-aside item lookup:
```bash
# First request: MISS (fetched from SQLite and cached)
curl -si http://127.0.0.1:9000/items/1 | grep "X-Cache"
# -> X-Cache: MISS

# Second request: HIT (served directly from in-memory cache)
curl -si http://127.0.0.1:9000/items/1 | grep "X-Cache"
# -> X-Cache: HIT
```
