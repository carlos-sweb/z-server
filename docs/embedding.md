# Embedding z-server as a Library

`z-server` is designed as a modular Zig toolkit. Instead of forcing consumers into an all-or-nothing framework, `z-server` provides five standalone modules that can be imported independently or combined together.

## Available Modules

| Module | Size Impact | C Dependencies | Purpose |
|---|---|---|---|
| `z_server` | ~332 KB | None (Pure Zig) | High-performance HTTP 1.1 core (routing, server, request/response) |
| `z_server_db` | +~1.2 MB | `sqlite3.c` | SQLite threadsafe connection pool with WAL and automatic migrations |
| `z_server_cache` | +~30 KB | `pogocache.c` | Ultra-fast in-memory sharded cache (cache-aside pattern) |
| `z_server_tls` | +~130 KB | `vendor/bearssl/*.c` | Hardened TLS 1.2 terminator with zero runtime dependencies |
| `z_server_config` | +~85 KB | None (Pure Zig) | JSON configuration loader, schema validation, and env overrides |

---

## 1. Adding z-server to build.zig.zon

In your downstream project's `build.zig.zon`:

```zig
.{
    .name = .my_app,
    .version = "0.1.0",
    .minimum_zig_version = "0.17.0",
    .dependencies = .{
        .z_server = .{
            // Via git URL:
            .url = "https://github.com/carlos-sweb/z-server/archive/refs/heads/main.tar.gz",
            // Or local path:
            // .path = "../path/to/z-server",
        },
    },
    .paths = .{""},
}
```

---

## 2. Configuring build.zig

Import only the modules your application requires:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization") orelse .fast;

    const z_server_dep = b.dependency("z_server", .{
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = b.option(bool, "strip", "Strip debug symbols") orelse true,
    });

    // Import core HTTP:
    exe_mod.addImport("z_server", z_server_dep.module("z_server"));

    // Optional modules (import as needed):
    // exe_mod.addImport("z_server_db", z_server_dep.module("z_server_db"));
    // exe_mod.addImport("z_server_cache", z_server_dep.module("z_server_cache"));
    // exe_mod.addImport("z_server_tls", z_server_dep.module("z_server_tls"));
    // exe_mod.addImport("z_server_config", z_server_dep.module("z_server_config"));

    const exe = b.addExecutable(.{
        .name = "my-app",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);
}
```

---

## 3. Reference Implementations

Explore the standalone examples in `examples/` for complete, working projects:

### 1. `examples/hello-world` (Pure HTTP Core)
- **Binary Size:** ~332 KB.
- **Dependencies:** `z_server`.
- **Description:** Barebones HTTP service responding to `GET /`. Zero C dependencies.

### 2. `examples/hello-db` (HTTP + SQLite)
- **Binary Size:** ~1.5 MB.
- **Dependencies:** `z_server`, `z_server_db`.
- **Description:** Exposes SQLite database connections via a threadsafe connection pool (`z_server_db.Pool`).

### 3. `examples/hello-cache` (HTTP + Cache)
- **Binary Size:** ~360 KB.
- **Dependencies:** `z_server`, `z_server_cache`.
- **Description:** Demonstrates an in-memory counter using Pogocache with 512 shards.

### 4. `examples/hello-tls` (HTTP + TLS 1.2 Terminator)
- **Binary Size:** ~463 KB.
- **Dependencies:** `z_server`, `z_server_tls`.
- **Description:** Listens on HTTP `:9000` and proxies HTTPS `:9443` through native BearSSL TLS 1.2. Demonstrates `@embedFile` for zero-filesystem certificate deployment.

### 5. `examples/hello-config` (HTTP + JSON Config)
- **Binary Size:** ~417 KB.
- **Dependencies:** `z_server`, `z_server_config`.
- **Description:** Loads `config.json` with schema validation and applies environment variable overrides (e.g., `Z_SERVER_BIND`). Pure Zig without any C bindings.

### 6. `examples/hello-all` (Full Stack Integration)
- **Binary Size:** ~1.7–2.1 MB.
- **Dependencies:** `z_server`, `z_server_db`, `z_server_cache`, `z_server_tls`, `z_server_config`.
- **Description:** Production-ready composition combining all five modules. Implements cache-aside (`GET /items/:id`), health checks, TLS termination, and config loading.

---

## 4. Key Design Patterns

### Explicit I/O and Process Initialization
In accordance with Zig 0.17 conventions, `init.io` is passed explicitly from `main(init: std.process.Init)`:
```zig
pub fn main(init: std.process.Init) !void {
    var server = try z_server.Server.init(init.gpa, init.io, .{
        .bind = "127.0.0.1:9000",
        .routes = &.{ ... },
    });
    defer server.deinit();
    try server.serve();
}
```

### Handler State Sharing via ServerT
When handlers require application state (such as a database pool or cache), instantiate `z_server.ServerT`:
```zig
const App = struct {
    db: z_server_db.Pool,
    cache: z_server_cache.Cache,
};

var app = App{ .db = pool, .cache = cache };
var server = try z_server.ServerT(*App).init(init.gpa, init.io, .{
    .bind = "127.0.0.1:9000",
    .handler_ctx = &app,
    .routes = &.{
        .{ .method = .GET, .path = "/items/:id", .handler = handleGetItem },
    },
});
```

### Response Arena Allocation
Dynamic responses can be allocated directly in `res.arena`, which is automatically freed when the request completes:
```zig
fn handleGetItem(app: *App, req: *z_server.Request, res: *z_server.Response) !void {
    const json_str = try std.fmt.allocPrint(res.arena, "{{\"item\":\"demo\"}}", .{});
    res.content_type = .JSON;
    res.body = json_str;
}
```
