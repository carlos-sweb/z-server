const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c");
const context = @import("context.zig");
const options = @import("options.zig");

pub const TlsServer = struct {
    allocator: Allocator,
    tls_ctx: context.TlsContext,
    listen_fd: c_int,
    http_port: u16,
    max_conns: u32,
    active_conns: std.atomic.Value(u32),
    running: std.atomic.Value(bool),
    accept_thread: ?std.Thread,

    pub fn init(allocator: Allocator, tls_cfg: anytype, http_port: u16) !*TlsServer {
        var tls_ctx = try context.TlsContext.init(allocator, tls_cfg);
        errdefer tls_ctx.deinit();

        const colon = std.mem.lastIndexOfScalar(u8, tls_cfg.bind, ':') orelse return error.InvalidBind;
        const host_slice = tls_cfg.bind[0..colon];
        const port_slice = tls_cfg.bind[colon + 1 ..];
        const port = std.fmt.parseInt(u16, port_slice, 10) catch return error.InvalidBind;

        var host_buf: [64]u8 = undefined;
        if (host_slice.len >= host_buf.len) return error.InvalidBind;
        @memcpy(host_buf[0..host_slice.len], host_slice);
        host_buf[host_slice.len] = 0;

        const listen_fd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
        if (listen_fd < 0) return error.SocketCreationFailed;
        errdefer _ = c.close(listen_fd);

        const one: c_int = 1;
        _ = c.setsockopt(listen_fd, c.SOL_SOCKET, c.SO_REUSEADDR, &one, @sizeOf(c_int));
        _ = c.setsockopt(listen_fd, c.SOL_SOCKET, c.SO_REUSEPORT, &one, @sizeOf(c_int));

        var addr = std.mem.zeroes(c.struct_sockaddr_in);
        addr.sin_family = c.AF_INET;
        addr.sin_port = std.mem.nativeToBig(u16, port);
        if (c.inet_pton(c.AF_INET, &host_buf, &addr.sin_addr) <= 0) {
            return error.InvalidBind;
        }

        if (c.bind(listen_fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_in)) != 0) {
            return error.BindFailed;
        }

        if (c.listen(listen_fd, 256) != 0) {
            return error.ListenFailed;
        }

        const self = try allocator.create(TlsServer);
        self.* = .{
            .allocator = allocator,
            .tls_ctx = tls_ctx,
            .listen_fd = listen_fd,
            .http_port = http_port,
            .max_conns = if (@hasField(@TypeOf(tls_cfg), "max_conns")) tls_cfg.max_conns else 256,
            .active_conns = std.atomic.Value(u32).init(0),
            .running = std.atomic.Value(bool).init(false),
            .accept_thread = null,
        };

        return self;
    }

    pub fn start(self: *TlsServer) !void {
        self.running.store(true, .release);
        self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
    }

    pub fn stop(self: *TlsServer) void {
        self.running.store(false, .release);
        if (self.listen_fd >= 0) {
            _ = c.shutdown(self.listen_fd, c.SHUT_RDWR);
            _ = c.close(self.listen_fd);
            self.listen_fd = -1;
        }
        if (self.accept_thread) |th| {
            th.join();
            self.accept_thread = null;
        }
        while (self.active_conns.load(.acquire) > 0) {
            _ = c.usleep(1000); // 1 ms
        }
    }

    pub fn deinit(self: *TlsServer) void {
        self.stop();
        self.tls_ctx.deinit();
        self.allocator.destroy(self);
    }
};

fn acceptLoop(self: *TlsServer) void {
    while (self.running.load(.acquire)) {
        var client_addr: c.struct_sockaddr_in = undefined;
        var addr_len: c.socklen_t = @sizeOf(c.struct_sockaddr_in);

        const client_fd = c.accept(self.listen_fd, @ptrCast(&client_addr), &addr_len);
        if (client_fd < 0) {
            if (!self.running.load(.acquire)) break;
            continue;
        }

        const cur = self.active_conns.fetchAdd(1, .monotonic);
        if (cur >= self.max_conns) {
            _ = self.active_conns.fetchSub(1, .monotonic);
            _ = c.close(client_fd);
            continue;
        }

        const thread = std.Thread.spawn(.{}, handleConnectionThread, .{ self, client_fd }) catch {
            _ = self.active_conns.fetchSub(1, .monotonic);
            _ = c.close(client_fd);
            continue;
        };
        thread.detach();
    }
}

fn handleConnectionThread(self: *TlsServer, client_fd: c_int) void {
    defer {
        _ = self.active_conns.fetchSub(1, .monotonic);
        _ = c.close(client_fd);
    }

    var tv = c.struct_timeval{ .tv_sec = 15, .tv_usec = 0 };
    _ = c.setsockopt(client_fd, c.SOL_SOCKET, c.SO_RCVTIMEO, &tv, @sizeOf(c.struct_timeval));
    _ = c.setsockopt(client_fd, c.SOL_SOCKET, c.SO_SNDTIMEO, &tv, @sizeOf(c.struct_timeval));

    var server_ctx: c.br_ssl_server_context = undefined;
    var x509_ctx: c.br_x509_minimal_context = undefined;
    var iobuf: [context.BR_SSL_BUFSIZE_BIDI]u8 = undefined;
    self.tls_ctx.initServerConnection(&server_ctx, &iobuf, &x509_ctx);

    var client_cn_buf: [256]u8 = undefined;
    var name_elt = c.br_name_element{
        .oid = &context.OID_COMMON_NAME,
        .buf = &client_cn_buf,
        .len = client_cn_buf.len,
        .status = 0,
    };
    if (self.tls_ctx.trust_anchors != null) {
        c.br_x509_minimal_set_name_elements(&x509_ctx, &name_elt, 1);
    }

    var ioc: c.br_sslio_context = undefined;
    var client_fd_copy: c_int = client_fd;
    c.br_sslio_init(&ioc, &server_ctx.eng, lowRead, &client_fd_copy, lowWrite, &client_fd_copy);

    // Connect to backend plaintext HTTP server
    const backend_fd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
    if (backend_fd < 0) return;
    defer _ = c.close(backend_fd);

    _ = c.setsockopt(backend_fd, c.SOL_SOCKET, c.SO_RCVTIMEO, &tv, @sizeOf(c.struct_timeval));
    _ = c.setsockopt(backend_fd, c.SOL_SOCKET, c.SO_SNDTIMEO, &tv, @sizeOf(c.struct_timeval));

    var backend_addr = std.mem.zeroes(c.struct_sockaddr_in);
    backend_addr.sin_family = c.AF_INET;
    backend_addr.sin_port = std.mem.nativeToBig(u16, self.http_port);
    backend_addr.sin_addr.s_addr = std.mem.nativeToBig(u32, 0x7f000001); // 127.0.0.1

    if (c.connect(backend_fd, @ptrCast(&backend_addr), @sizeOf(c.struct_sockaddr_in)) != 0) {
        return;
    }

    while (self.running.load(.acquire)) {
        // 1. Read request from TLS client
        var req_buf: [65536]u8 = undefined;
        var req_len: usize = 0;
        var header_end: ?usize = null;

        while (req_len < req_buf.len) {
            const n = c.br_sslio_read(&ioc, req_buf[req_len..].ptr, req_buf.len - req_len);
            if (n <= 0) {
                const err = c.br_ssl_engine_last_error(&server_ctx.eng);
                if (err != 0) {
                    std.log.warn("TLS handshake/read error: {d}", .{err});
                }
                return;
            }
            req_len += @intCast(n);

            if (std.mem.indexOf(u8, req_buf[0..req_len], "\r\n\r\n")) |idx| {
                header_end = idx + 4;
                break;
            }
        }

        const h_end = header_end orelse return;
        const headers = req_buf[0..h_end];
        const body_len = parseContentLength(headers);
        const body_read_so_far = req_len - h_end;

        if (x509_ctx.err != 0 and x509_ctx.err != c.BR_ERR_X509_OK) {
            std.log.warn("Rejecting client cert with x509 error: {d}", .{x509_ctx.err});
            const resp = "HTTP/1.1 401 Unauthorized\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: 42\r\n\r\n{\"error\":\"invalid_client_certificate\"}\r\n";
            _ = c.br_sslio_write_all(&ioc, resp.ptr, resp.len);
            _ = c.br_sslio_close(&ioc);
            return;
        }

        if (!writeAll(backend_fd, req_buf[0 .. h_end - 2])) return;
        if (x509_ctx.err == c.BR_ERR_X509_OK and name_elt.status == 1) {
            const cn_len = std.mem.indexOfScalar(u8, &client_cn_buf, 0) orelse client_cn_buf.len;
            const client_cn = client_cn_buf[0..cn_len];
            if (client_cn.len > 0) {
                if (!writeAll(backend_fd, "X-Client-Cert-Subject: ")) return;
                if (!writeAll(backend_fd, client_cn)) return;
                if (!writeAll(backend_fd, "\r\n")) return;
            }
        }
        if (!writeAll(backend_fd, "X-Forwarded-Proto: https\r\n\r\n")) return;
        if (body_read_so_far > 0) {
            if (!writeAll(backend_fd, req_buf[h_end..req_len])) return;
        }

        var remaining = if (body_len > body_read_so_far) body_len - body_read_so_far else 0;
        while (remaining > 0) {
            const to_read = @min(remaining, req_buf.len);
            const n = c.br_sslio_read(&ioc, &req_buf, to_read);
            if (n <= 0) return;
            const un: usize = @intCast(n);
            if (!writeAll(backend_fd, req_buf[0..un])) return;
            remaining -= un;
        }

        // 2. Read response from backend
        var resp_buf: [65536]u8 = undefined;
        var resp_len: usize = 0;
        var resp_header_end: ?usize = null;

        while (resp_len < resp_buf.len) {
            const n = c.read(backend_fd, resp_buf[resp_len..].ptr, resp_buf.len - resp_len);
            if (n <= 0) return;
            resp_len += @intCast(n);

            if (std.mem.indexOf(u8, resp_buf[0..resp_len], "\r\n\r\n")) |idx| {
                resp_header_end = idx + 4;
                break;
            }
        }

        const rh_end = resp_header_end orelse return;
        const resp_headers = resp_buf[0..rh_end];
        const resp_body_len = parseContentLength(resp_headers);
        const is_chunked = isTransferChunked(resp_headers);
        const resp_body_read_so_far = resp_len - rh_end;

        if (c.br_sslio_write_all(&ioc, &resp_buf, resp_len) != 0) return;

        if (is_chunked) {
            var chunked_done = std.mem.indexOf(u8, resp_buf[rh_end..resp_len], "0\r\n\r\n") != null;
            while (!chunked_done) {
                const n = c.read(backend_fd, &resp_buf, resp_buf.len);
                if (n <= 0) break;
                const un: usize = @intCast(n);
                if (c.br_sslio_write_all(&ioc, &resp_buf, un) != 0) return;
                if (std.mem.indexOf(u8, resp_buf[0..un], "0\r\n\r\n") != null) {
                    chunked_done = true;
                }
            }
        } else {
            var resp_remaining = if (resp_body_len > resp_body_read_so_far) resp_body_len - resp_body_read_so_far else 0;
            while (resp_remaining > 0) {
                const to_read = @min(resp_remaining, resp_buf.len);
                const n = c.read(backend_fd, &resp_buf, to_read);
                if (n <= 0) return;
                const un: usize = @intCast(n);
                if (c.br_sslio_write_all(&ioc, &resp_buf, un) != 0) return;
                resp_remaining -= un;
            }
        }

        if (c.br_sslio_flush(&ioc) != 0) return;

        const req_close = isConnectionClose(headers);
        const resp_close = isConnectionClose(resp_headers);
        if (req_close or resp_close) return;
    }

    _ = c.br_sslio_close(&ioc);
}

fn lowRead(ctx: ?*anyopaque, data: [*c]u8, len: usize) callconv(.c) c_int {
    const fd_ptr: *const c_int = @ptrCast(@alignCast(ctx.?));
    const fd = fd_ptr.*;
    const rc = c.read(fd, data, len);
    if (rc <= 0) return -1;
    return @intCast(rc);
}

fn lowWrite(ctx: ?*anyopaque, data: [*c]const u8, len: usize) callconv(.c) c_int {
    const fd_ptr: *const c_int = @ptrCast(@alignCast(ctx.?));
    const fd = fd_ptr.*;
    const rc = c.write(fd, data, len);
    if (rc <= 0) return -1;
    return @intCast(rc);
}

fn writeAll(fd: c_int, data: []const u8) bool {
    var sent: usize = 0;
    while (sent < data.len) {
        const n = c.write(fd, data.ptr + sent, data.len - sent);
        if (n <= 0) return false;
        sent += @intCast(n);
    }
    return true;
}

fn parseContentLength(headers: []const u8) usize {
    var it = std.mem.splitSequence(u8, headers, "\r\n");
    while (it.next()) |line| {
        if (line.len < 16) continue;
        const prefix = line[0..15];
        if (std.ascii.eqlIgnoreCase(prefix, "content-length:")) {
            const val_str = std.mem.trim(u8, line[15..], " \t");
            return std.fmt.parseInt(usize, val_str, 10) catch 0;
        }
    }
    return 0;
}

fn isTransferChunked(headers: []const u8) bool {
    var it = std.mem.splitSequence(u8, headers, "\r\n");
    while (it.next()) |line| {
        if (line.len < 18) continue;
        const prefix = line[0..18];
        if (std.ascii.eqlIgnoreCase(prefix, "transfer-encoding:")) {
            return std.mem.indexOf(u8, line, "chunked") != null;
        }
    }
    return false;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn isConnectionClose(headers: []const u8) bool {
    var it = std.mem.splitSequence(u8, headers, "\r\n");
    while (it.next()) |line| {
        if (line.len < 11) continue;
        const prefix = line[0..11];
        if (std.ascii.eqlIgnoreCase(prefix, "connection:")) {
            return indexOfIgnoreCase(line[11..], "close") != null;
        }
    }
    return false;
}
