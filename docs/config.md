# Configuration Guide

`z-server` supports configuration via JSON file, environment variables, or default fallbacks (100% backward-compatible with v0.2.0).

## Usage

Specify the config file path via CLI flag `--config` (or `-c`) or via the `Z_SERVER_CONFIG` environment variable:

```bash
# Using CLI flag
./zig-out/bin/z-server --config /etc/z-server/config.json
./zig-out/bin/z-server -c ./docs/config.dev.json

# Using environment variable
Z_SERVER_CONFIG=/etc/z-server/config.json ./zig-out/bin/z-server
```

If no configuration file is specified, `z-server` operates with built-in v0.2.0 defaults.

## Configuration Schema

The JSON configuration format has the following top-level structure:

```json
{
  "$schema_version": 1,
  "server": {
    "bind": "0.0.0.0:8080",
    "handler_threads": 16,
    "max_body_size": 65536
  },
  "sqlite": {
    "path": "data/app.db",
    "pool_size": 16,
    "synchronous": "NORMAL",
    "busy_timeout_ms": 5000
  },
  "cache": {
    "nshards": 512,
    "default_ttl_s": 60,
    "max_value_bytes": 32768
  },
  "tls": {
    "enabled": false,
    "bind": "0.0.0.0:8443",
    "cert_path": null,
    "key_path": null,
    "alpn": ["http/1.1"],
    "min_version": "1.2",
    "max_conns": 256
  },
  "logging": {
    "level": "info"
  }
}
```

### Schema Versioning

- `$schema_version` (or `schema_version`): Must be `1`. Any higher version will fail validation with `UnsupportedSchemaVersion`.

### Relative Path Resolution

Relative paths specified for `sqlite.path`, `tls.cert_path`, and `tls.key_path` are automatically resolved relative to the directory containing the configuration file. For example, if `/etc/z-server/config.json` specifies `"cert_path": "certs/server.crt"`, it resolves to `/etc/z-server/certs/server.crt`. Absolute paths remain unchanged.

### Environment Variable Overrides

Environment variables take precedence over settings in the configuration file:

| Setting | Environment Variable | Accepted Values |
| :--- | :--- | :--- |
| `server.bind` | `Z_SERVER_BIND` | `127.0.0.1:PORT` or `0.0.0.0:PORT` |
| `server.handler_threads` | `Z_SERVER_HANDLER_THREADS` | Integer `1..128` |
| `sqlite.pool_size` | `Z_SERVER_SQLITE_POOL` | Integer `1..128` |
| `sqlite.synchronous` | `Z_SERVER_SQLITE_SYNCHRONOUS` | `OFF`, `NORMAL`, `FULL`, `EXTRA` |

> **Security Note:** `Z_SERVER_TLS_CERT_PATH` and `Z_SERVER_TLS_KEY_PATH` are explicitly **prohibited** in environment variables to prevent certificate/key paths leaking through `/proc/$PID/environ`. Attempting to set them will cause immediate exit with `TlsPathsNotAllowedInEnv`.

### Validation Rules

- `schema_version`: Must be `<= 1`.
- `server.handler_threads`: Must be in range `1..128` if provided.
- `sqlite.pool_size`: Must be in range `1..128` if provided.
- `cache.nshards`: Must be in range `1..65535`.
- If `tls.enabled == true`:
  - `tls.cert_path` and `tls.key_path` are required.
  - The certificate file and private key file must exist and be readable.
  - If the private key file has world-readable permissions (`mode & 0o004 != 0`), a security warning is logged.
