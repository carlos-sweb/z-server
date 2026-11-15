# Hello World Example

Minimal standalone project demonstrating consumption of `z-server` as an embedded Zig library (`@import("z_server")`) for HTTP services without SQLite, BearSSL, or Pogocache dependencies.

## Project Structure

```
examples/hello-world/
├── build.zig
├── build.zig.zon
├── src/
│   └── main.zig
└── README.md
```

## Building

Dynamic (default, ~332 KB):
```bash
zig build
./zig-out/bin/hello-world
# → hello-world listening on 127.0.0.1:9000
```

Static (~1.1 MB, portable, no glibc dependency):
```bash
zig build -Dtarget=x86_64-linux-musl
./zig-out/bin/hello-world
# → hello-world listening on 127.0.0.1:9000
```

Either works. The main `z-server` binary is always built static by default; this example follows the standard Zig convention of respecting the host target unless overridden.

## Test Endpoint

Once running, send a request to the root endpoint:
```bash
curl -s http://127.0.0.1:9000/
# → {"message":"hello world"}
```
