# hello-config

Example consumer project demonstrating `z-server` HTTP core combined with file-based JSON configuration and environment overrides via the optional `z_server_config` module.

## Features

- HTTP server provided by `z_server` module.
- JSON configuration loader with schema validation via `z_server_config`.
- Environment variable overrides support (`Z_SERVER_BIND`, etc.).
- Zero C code or vendor C dependencies in configuration loading.
- Zero SQLite, Pogocache, or BearSSL dependencies.

## Building & Running

Compile and run:
```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/hello-config
```

## Testing Endpoints

Test root endpoint:
```bash
curl -s http://127.0.0.1:9000/
# -> {"service":"hello-config"}
```

Test configuration inspection endpoint:
```bash
curl -s http://127.0.0.1:9000/config
# -> {"bind":"127.0.0.1:9000","handler_threads":4,"max_body_size":65536,"logging_level":"info"}
```

Test environment variable override:
```bash
Z_SERVER_BIND=127.0.0.1:9001 ./zig-out/bin/hello-config
# hello-config listening on 127.0.0.1:9001
curl -s http://127.0.0.1:9001/config
# -> {"bind":"127.0.0.1:9001",...}
```
