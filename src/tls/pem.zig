const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c");
const posix = std.posix;
const linux = std.os.linux;

pub const PemError = error{
    CertFileNotFound,
    KeyFileNotFound,
    InvalidHeader,
    InvalidBase64,
    KeyNotSupported,
    OutOfMemory,
    ReadFailed,
    PathTooLong,
};

pub const CertChain = struct {
    certs: []c.br_x509_certificate,
    allocator: Allocator,

    pub fn deinit(self: *CertChain) void {
        for (self.certs) |cert| {
            if (cert.data != null and cert.data_len > 0) {
                self.allocator.free(cert.data[0..cert.data_len]);
            }
        }
        self.allocator.free(self.certs);
    }
};

pub const PrivateKey = struct {
    key: c.br_rsa_private_key,
    allocator: Allocator,

    pub fn deinit(self: *PrivateKey) void {
        if (self.key.p != null and self.key.plen > 0) self.allocator.free(self.key.p[0..self.key.plen]);
        if (self.key.q != null and self.key.qlen > 0) self.allocator.free(self.key.q[0..self.key.qlen]);
        if (self.key.dp != null and self.key.dplen > 0) self.allocator.free(self.key.dp[0..self.key.dplen]);
        if (self.key.dq != null and self.key.dqlen > 0) self.allocator.free(self.key.dq[0..self.key.dqlen]);
        if (self.key.iq != null and self.key.iqlen > 0) self.allocator.free(self.key.iq[0..self.key.iqlen]);
    }
};

fn readFile(allocator: Allocator, path: []const u8, is_cert: bool) PemError![]u8 {
    var path_buf: [4096:0]u8 = undefined;
    if (path.len >= path_buf.len) return error.PathTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    var statx_buf: linux.Statx = undefined;
    const rc = linux.statx(posix.AT.FDCWD, &path_buf, 0, linux.STATX.BASIC_STATS, &statx_buf);
    if (rc != 0) {
        if (is_cert) return error.CertFileNotFound else return error.KeyFileNotFound;
    }
    const size: usize = @intCast(statx_buf.size);

    const fd = posix.openatZ(posix.AT.FDCWD, &path_buf, .{ .ACCMODE = .RDONLY }, 0) catch {
        if (is_cert) return error.CertFileNotFound else return error.KeyFileNotFound;
    };
    defer _ = linux.close(fd);

    const buf = allocator.alloc(u8, size) catch return error.OutOfMemory;
    errdefer allocator.free(buf);

    var total: usize = 0;
    while (total < size) {
        const n = posix.read(fd, buf[total..]) catch return error.ReadFailed;
        if (n == 0) break;
        total += n;
    }
    return buf[0..total];
}

const CertAccumulator = struct {
    allocator: Allocator,
    current: std.ArrayList(u8) = .empty,
    collecting: bool = false,

    fn appendCallback(ctx: ?*anyopaque, src: ?*const anyopaque, len: usize) callconv(.c) void {
        if (ctx == null or src == null or len == 0) return;
        const self: *CertAccumulator = @ptrCast(@alignCast(ctx.?));
        if (!self.collecting) return;
        const bytes: [*]const u8 = @ptrCast(src.?);
        self.current.appendSlice(self.allocator, bytes[0..len]) catch {};
    }
};

pub fn loadCertChain(allocator: Allocator, path: []const u8) PemError!CertChain {
    const raw_pem = try readFile(allocator, path, true);
    defer allocator.free(raw_pem);

    return parseCertChainFromSlice(allocator, raw_pem);
}

pub fn parseCertChainFromSlice(allocator: Allocator, raw_pem: []const u8) PemError!CertChain {
    var accum = CertAccumulator{
        .allocator = allocator,
        .current = .empty,
        .collecting = false,
    };
    defer accum.current.deinit(allocator);

    var certs_list: std.ArrayList(c.br_x509_certificate) = .empty;
    errdefer {
        for (certs_list.items) |cert| {
            if (cert.data != null and cert.data_len > 0) {
                allocator.free(cert.data[0..cert.data_len]);
            }
        }
        certs_list.deinit(allocator);
    }

    var pc: c.br_pem_decoder_context = undefined;
    c.br_pem_decoder_init(&pc);
    c.br_pem_decoder_setdest(&pc, CertAccumulator.appendCallback, &accum);

    var offset: usize = 0;
    while (offset < raw_pem.len) {
        const chunk_len = raw_pem.len - offset;
        const consumed = c.br_pem_decoder_push(&pc, raw_pem.ptr + offset, chunk_len);
        offset += consumed;

        while (true) {
            const ev = c.br_pem_decoder_event(&pc);
            if (ev == 0) break;
            switch (ev) {
                c.BR_PEM_BEGIN_OBJ => {
                    const name_ptr = c.br_pem_decoder_name(&pc);
                    const name = std.mem.span(name_ptr);
                    if (std.mem.eql(u8, name, "CERTIFICATE") or std.mem.eql(u8, name, "X509 CERTIFICATE")) {
                        accum.collecting = true;
                        accum.current.clearRetainingCapacity();
                    } else {
                        accum.collecting = false;
                    }
                },
                c.BR_PEM_END_OBJ => {
                    if (accum.collecting) {
                        accum.collecting = false;
                        if (accum.current.items.len > 0) {
                            const cert_data = allocator.alloc(u8, accum.current.items.len) catch return error.OutOfMemory;
                            @memcpy(cert_data, accum.current.items);
                            certs_list.append(allocator, .{
                                .data = cert_data.ptr,
                                .data_len = cert_data.len,
                            }) catch return error.OutOfMemory;
                            accum.current.clearRetainingCapacity();
                        }
                    }
                },
                c.BR_PEM_ERROR => {
                    return error.InvalidBase64;
                },
                else => {},
            }
        }
    }

    if (certs_list.items.len == 0) {
        return error.InvalidHeader;
    }

    return CertChain{
        .certs = certs_list.toOwnedSlice(allocator) catch return error.OutOfMemory,
        .allocator = allocator,
    };
}

const KeyAccumulator = struct {
    skey_ctx: *c.br_skey_decoder_context,
    collecting: bool = false,

    fn appendCallback(ctx: ?*anyopaque, src: ?*const anyopaque, len: usize) callconv(.c) void {
        if (ctx == null or src == null or len == 0) return;
        const self: *KeyAccumulator = @ptrCast(@alignCast(ctx.?));
        if (!self.collecting) return;
        c.br_skey_decoder_push(self.skey_ctx, src.?, len);
    }
};

pub fn loadPrivateKey(allocator: Allocator, path: []const u8) PemError!PrivateKey {
    const raw_pem = try readFile(allocator, path, false);
    defer allocator.free(raw_pem);

    return parsePrivateKeyFromSlice(allocator, raw_pem);
}

pub fn parsePrivateKeyFromSlice(allocator: Allocator, raw_pem: []const u8) PemError!PrivateKey {
    var skey_ctx: c.br_skey_decoder_context = undefined;
    c.br_skey_decoder_init(&skey_ctx);

    var accum = KeyAccumulator{
        .skey_ctx = &skey_ctx,
        .collecting = false,
    };

    var pc: c.br_pem_decoder_context = undefined;
    c.br_pem_decoder_init(&pc);
    c.br_pem_decoder_setdest(&pc, KeyAccumulator.appendCallback, &accum);

    var key_found = false;
    var unsupported_key = false;

    var offset: usize = 0;
    while (offset < raw_pem.len) {
        const chunk_len = raw_pem.len - offset;
        const consumed = c.br_pem_decoder_push(&pc, raw_pem.ptr + offset, chunk_len);
        offset += consumed;

        while (true) {
            const ev = c.br_pem_decoder_event(&pc);
            if (ev == 0) break;
            switch (ev) {
                c.BR_PEM_BEGIN_OBJ => {
                    const name_ptr = c.br_pem_decoder_name(&pc);
                    const name = std.mem.span(name_ptr);
                    if (std.mem.eql(u8, name, "RSA PRIVATE KEY") or std.mem.eql(u8, name, "PRIVATE KEY")) {
                        accum.collecting = true;
                        key_found = true;
                    } else if (std.mem.eql(u8, name, "EC PRIVATE KEY")) {
                        accum.collecting = true;
                        unsupported_key = true;
                    } else {
                        accum.collecting = false;
                    }
                },
                c.BR_PEM_END_OBJ => {
                    if (accum.collecting) {
                        accum.collecting = false;
                    }
                },
                c.BR_PEM_ERROR => {
                    return error.InvalidBase64;
                },
                else => {},
            }
        }
    }

    if (!key_found) {
        return error.InvalidHeader;
    }

    if (unsupported_key) {
        return error.KeyNotSupported;
    }

    const err_code = c.br_skey_decoder_last_error(&skey_ctx);
    if (err_code != 0) {
        return error.InvalidBase64;
    }

    const key_type = c.br_skey_decoder_key_type(&skey_ctx);
    if (key_type != c.BR_KEYTYPE_RSA) {
        return error.KeyNotSupported;
    }

    const sk_opt = c.br_skey_decoder_get_rsa(&skey_ctx);
    if (sk_opt == null) {
        return error.KeyNotSupported;
    }
    const sk = sk_opt.*;

    const p_buf = allocator.alloc(u8, sk.plen) catch return error.OutOfMemory;
    errdefer allocator.free(p_buf);
    @memcpy(p_buf, sk.p[0..sk.plen]);

    const q_buf = allocator.alloc(u8, sk.qlen) catch return error.OutOfMemory;
    errdefer allocator.free(q_buf);
    @memcpy(q_buf, sk.q[0..sk.qlen]);

    const dp_buf = allocator.alloc(u8, sk.dplen) catch return error.OutOfMemory;
    errdefer allocator.free(dp_buf);
    @memcpy(dp_buf, sk.dp[0..sk.dplen]);

    const dq_buf = allocator.alloc(u8, sk.dqlen) catch return error.OutOfMemory;
    errdefer allocator.free(dq_buf);
    @memcpy(dq_buf, sk.dq[0..sk.dqlen]);

    const iq_buf = allocator.alloc(u8, sk.iqlen) catch return error.OutOfMemory;
    errdefer allocator.free(iq_buf);
    @memcpy(iq_buf, sk.iq[0..sk.iqlen]);

    return PrivateKey{
        .key = .{
            .n_bitlen = sk.n_bitlen,
            .p = p_buf.ptr,
            .plen = p_buf.len,
            .q = q_buf.ptr,
            .qlen = q_buf.len,
            .dp = dp_buf.ptr,
            .dplen = dp_buf.len,
            .dq = dq_buf.ptr,
            .dqlen = dq_buf.len,
            .iq = iq_buf.ptr,
            .iqlen = iq_buf.len,
        },
        .allocator = allocator,
    };
}
