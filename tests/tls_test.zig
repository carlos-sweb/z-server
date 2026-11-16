const std = @import("std");
const tls = @import("z_server_tls");
const c = @import("c");
const pem = tls.pem;
const context = tls.context;

test "1. load valid cert chain from file" {
    const a = std.testing.allocator;
    var chain = try pem.loadCertChain(a, "loadtest/tls/server.crt");
    defer chain.deinit();

    try std.testing.expect(chain.certs.len >= 1);
    try std.testing.expect(chain.certs[0].data_len > 0);
    try std.testing.expect(chain.certs[0].data != null);
}

test "2. load valid PKCS#8 private key from file" {
    const a = std.testing.allocator;
    var key = try pem.loadPrivateKey(a, "loadtest/tls/server.key");
    defer key.deinit();

    try std.testing.expectEqual(@as(u32, 2048), key.key.n_bitlen);
    try std.testing.expect(key.key.plen > 0);
    try std.testing.expect(key.key.qlen > 0);
    try std.testing.expect(key.key.p != null);
    try std.testing.expect(key.key.q != null);
}

test "3. load valid PKCS#1 private key from file" {
    const a = std.testing.allocator;
    var key = try pem.loadPrivateKey(a, "loadtest/tls/server_pkcs1.key");
    defer key.deinit();

    try std.testing.expectEqual(@as(u32, 2048), key.key.n_bitlen);
    try std.testing.expect(key.key.plen > 0);
    try std.testing.expect(key.key.qlen > 0);
}

test "4. missing cert file returns CertFileNotFound" {
    const a = std.testing.allocator;
    const res = pem.loadCertChain(a, "/nonexistent/path/server.crt");
    try std.testing.expectError(error.CertFileNotFound, res);
}

test "5. missing key file returns KeyFileNotFound" {
    const a = std.testing.allocator;
    const res = pem.loadPrivateKey(a, "/nonexistent/path/server.key");
    try std.testing.expectError(error.KeyFileNotFound, res);
}

test "6. EC private key returns KeyNotSupported" {
    const a = std.testing.allocator;
    const res = pem.loadPrivateKey(a, "loadtest/tls/ec_test.key");
    try std.testing.expectError(error.KeyNotSupported, res);
}

test "7. corrupted base64 returns InvalidBase64" {
    const a = std.testing.allocator;
    const bad_pem =
        \\-----BEGIN CERTIFICATE-----
        \\!!!not valid base64 chars???
        \\-----END CERTIFICATE-----
    ;
    const res = pem.parseCertChainFromSlice(a, bad_pem);
    try std.testing.expectError(error.InvalidBase64, res);
}

test "8. missing PEM header returns InvalidHeader" {
    const a = std.testing.allocator;
    const plain_text = "Hello, world! This is not a PEM file.";
    const res = pem.parseCertChainFromSlice(a, plain_text);
    try std.testing.expectError(error.InvalidHeader, res);
}

test "9. TlsContext init and initServerConnection" {
    const a = std.testing.allocator;
    var tls_ctx = try context.TlsContext.init(a, .{
        .enabled = true,
        .cert_path = "loadtest/tls/server.crt",
        .key_path = "loadtest/tls/server.key",
    });
    defer tls_ctx.deinit();

    var server_ctx: c.br_ssl_server_context = undefined;
    var iobuf: [context.BR_SSL_BUFSIZE_BIDI]u8 = undefined;

    tls_ctx.initServerConnection(&server_ctx, &iobuf, null);
    const state = c.br_ssl_engine_current_state(&server_ctx.eng);
    // At reset, server engine is waiting for client hello or ready to receive
    try std.testing.expect(state != 0);
}

test "10. TLS hardened security profile and engine configuration" {
    const a = std.testing.allocator;
    var tls_ctx = try context.TlsContext.init(a, .{
        .enabled = true,
        .cert_path = "loadtest/tls/server.crt",
        .key_path = "loadtest/tls/server.key",
    });
    defer tls_ctx.deinit();

    var server_ctx: c.br_ssl_server_context = undefined;
    var iobuf: [context.BR_SSL_BUFSIZE_BIDI]u8 = undefined;
    tls_ctx.initServerConnection(&server_ctx, &iobuf, null);

    // TLS version strictly pinned to 1.2
    try std.testing.expectEqual(@as(u16, c.BR_TLS12), server_ctx.eng.version_min);
    try std.testing.expectEqual(@as(u16, c.BR_TLS12), server_ctx.eng.version_max);

    // Cipher suites: strictly 3 AEAD suites, zero CBC suites
    try std.testing.expectEqual(@as(u8, 3), server_ctx.eng.suites_num);
    const configured_suites = server_ctx.eng.suites_buf[0..server_ctx.eng.suites_num];
    for (configured_suites) |s| {
        // Known CBC/3DES suite values in BearSSL
        const is_cbc = (s == 0xC027 or s == 0xC028 or s == 0xC013 or s == 0xC014 or
            s == 0x003C or s == 0x003D or s == 0x002F or s == 0x0035 or
            s == 0xC012 or s == 0x000A);
        try std.testing.expect(!is_cbc);
    }
    try std.testing.expectEqual(@as(u16, c.BR_TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256), configured_suites[0]);
    try std.testing.expectEqual(@as(u16, c.BR_TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384), configured_suites[1]);
    try std.testing.expectEqual(@as(u16, c.BR_TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256), configured_suites[2]);

    // Renegotiation disabled and server preferences enforced
    try std.testing.expect((server_ctx.eng.flags & c.BR_OPT_NO_RENEGOTIATION) != 0);
    try std.testing.expect((server_ctx.eng.flags & c.BR_OPT_ENFORCE_SERVER_PREFERENCES) != 0);

    // Elliptic curves restricted to X25519 (29) and P-256 (23)
    const expected_curves = (@as(u32, 1) << c.BR_EC_secp256r1) | (@as(u32, 1) << c.BR_EC_curve25519);
    try std.testing.expectEqual(expected_curves, server_ctx.eng.iec.*.supported_curves);

    // Hash table verification: MD5 excluded, SHA-1 and SHA-2 registered
    try std.testing.expectEqual(@as(?*const anyopaque, null), @as(?*const anyopaque, @ptrCast(c.br_multihash_getimpl(&server_ctx.eng.mhash, c.br_md5_ID))));
    try std.testing.expect(c.br_multihash_getimpl(&server_ctx.eng.mhash, c.br_sha1_ID) != null);
    try std.testing.expect(c.br_multihash_getimpl(&server_ctx.eng.mhash, c.br_sha256_ID) != null);
}

test "11. getSecurityProfile exposes audited TLS configuration" {
    const prof = context.getSecurityProfile();
    try std.testing.expectEqual(@as(u16, c.BR_TLS12), prof.version_min);
    try std.testing.expectEqual(@as(u16, c.BR_TLS12), prof.version_max);
    try std.testing.expectEqual(@as(usize, 3), prof.suites.len);
    try std.testing.expectEqualStrings("disabled", prof.renegotiation);
    try std.testing.expectEqualStrings("disabled", prof.rsa_keyx);
}

fn pumpEngines(eng1: *c.br_ssl_engine_context, eng2: *c.br_ssl_engine_context) bool {
    var progress = false;
    var len1: usize = 0;
    const buf1 = c.br_ssl_engine_sendrec_buf(eng1, &len1);
    if (buf1 != null and len1 > 0) {
        var rlen2: usize = 0;
        const rbuf2 = c.br_ssl_engine_recvrec_buf(eng2, &rlen2);
        if (rbuf2 != null and rlen2 > 0) {
            const to_copy = @min(len1, rlen2);
            @memcpy(rbuf2[0..to_copy], buf1[0..to_copy]);
            c.br_ssl_engine_sendrec_ack(eng1, to_copy);
            c.br_ssl_engine_recvrec_ack(eng2, to_copy);
            progress = true;
        }
    }
    var len2: usize = 0;
    const buf2 = c.br_ssl_engine_sendrec_buf(eng2, &len2);
    if (buf2 != null and len2 > 0) {
        var rlen1: usize = 0;
        const rbuf1 = c.br_ssl_engine_recvrec_buf(eng1, &rlen1);
        if (rbuf1 != null and rlen1 > 0) {
            const to_copy = @min(len2, rlen1);
            @memcpy(rbuf1[0..to_copy], buf2[0..to_copy]);
            c.br_ssl_engine_sendrec_ack(eng2, to_copy);
            c.br_ssl_engine_recvrec_ack(eng1, to_copy);
            progress = true;
        }
    }
    return progress;
}

fn driveHandshake(server_eng: *c.br_ssl_engine_context, client_eng: *c.br_ssl_engine_context) !void {
    var loops: usize = 0;
    while (loops < 1000) : (loops += 1) {
        const s_state = c.br_ssl_engine_current_state(server_eng);
        const c_state = c.br_ssl_engine_current_state(client_eng);

        if ((s_state & (c.BR_SSL_SENDAPP | c.BR_SSL_RECVAPP)) != 0 and
            (c_state & (c.BR_SSL_SENDAPP | c.BR_SSL_RECVAPP)) != 0)
        {
            if (server_eng.x509ctx) |x509_ptr| {
                const x509: *const c.br_x509_minimal_context = @ptrCast(@alignCast(x509_ptr));
                if (x509.err != 0 and x509.err != c.BR_ERR_X509_OK) {
                    server_eng.err = x509.err;
                    return error.HandshakeFailed;
                }
            }
            return;
        }

        if ((s_state & c.BR_SSL_CLOSED) != 0 or (c_state & c.BR_SSL_CLOSED) != 0) {
            return error.HandshakeFailed;
        }

        if (!pumpEngines(server_eng, client_eng)) {
            break;
        }
    }
    return error.HandshakeFailed;
}

const ClientOptions = struct {
    client_cert_path: ?[]const u8 = null,
    client_key_path: ?[]const u8 = null,
};

const TestClient = struct {
    chain: ?pem.CertChain = null,
    key: ?pem.PrivateKey = null,
    tas: []c.br_x509_trust_anchor,
    ctx: c.br_ssl_client_context = undefined,
    x509: c.br_x509_minimal_context = undefined,
    iobuf: [context.BR_SSL_BUFSIZE_BIDI]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator, opts: ClientOptions) !TestClient {
        const server_tas = try pem.loadTrustAnchors(allocator, "loadtest/tls/server.crt");

        var client: TestClient = .{
            .tas = server_tas,
        };

        c.br_ssl_client_init_full(&client.ctx, &client.x509, server_tas.ptr, server_tas.len);

        const now = c.time(null);
        if (now > 0) {
            const unow: u64 = @intCast(now);
            const days: u32 = @intCast((unow / 86400) + 719528);
            const seconds: u32 = @intCast(unow % 86400);
            c.br_x509_minimal_set_time(&client.x509, days, seconds);
        }

        if (opts.client_cert_path) |cp| {
            client.chain = try pem.loadCertChain(allocator, cp);
            client.key = try pem.loadPrivateKey(allocator, opts.client_key_path.?);
        }

        return client;
    }

    pub fn start(self: *TestClient) void {
        if (self.chain != null and self.key != null) {
            c.br_ssl_client_set_single_rsa(
                &self.ctx,
                self.chain.?.certs.ptr,
                self.chain.?.certs.len,
                &self.key.?.key,
                c.br_rsa_pkcs1_sign_get_default(),
            );
        }
        c.br_ssl_engine_set_buffer(&self.ctx.eng, &self.iobuf, self.iobuf.len, 1);
        _ = c.br_ssl_client_reset(&self.ctx, "localhost", 0);
    }

    pub fn deinit(self: *TestClient, allocator: std.mem.Allocator) void {
        if (self.chain) |*ch| ch.deinit();
        if (self.key) |*k| k.deinit();
        pem.freeTrustAnchors(allocator, self.tas);
    }
};

test "12. mTLS off: handshake succeeds without client certificate" {
    const a = std.testing.allocator;
    var tls_ctx = try context.TlsContext.init(a, .{
        .enabled = true,
        .cert_path = "loadtest/tls/server.crt",
        .key_path = "loadtest/tls/server.key",
        .client_ca_path = null,
        .require_client_cert = false,
    });
    defer tls_ctx.deinit();

    var server_ctx: c.br_ssl_server_context = undefined;
    var server_x509: c.br_x509_minimal_context = undefined;
    var server_iobuf: [context.BR_SSL_BUFSIZE_BIDI]u8 = undefined;
    tls_ctx.initServerConnection(&server_ctx, &server_iobuf, &server_x509);

    var client = try TestClient.init(a, .{});
    defer client.deinit(a);
    client.start();

    try driveHandshake(&server_ctx.eng, &client.ctx.eng);
    try std.testing.expectEqual(@as(c_int, 0), c.br_ssl_engine_last_error(&server_ctx.eng));
}

test "13. mTLS optional: handshake succeeds without client certificate" {
    const a = std.testing.allocator;
    var tls_ctx = try context.TlsContext.init(a, .{
        .enabled = true,
        .cert_path = "loadtest/tls/server.crt",
        .key_path = "loadtest/tls/server.key",
        .client_ca_path = "loadtest/tls/ca.crt",
        .require_client_cert = false,
    });
    defer tls_ctx.deinit();

    var server_ctx: c.br_ssl_server_context = undefined;
    var server_x509: c.br_x509_minimal_context = undefined;
    var server_iobuf: [context.BR_SSL_BUFSIZE_BIDI]u8 = undefined;
    tls_ctx.initServerConnection(&server_ctx, &server_iobuf, &server_x509);

    var client_cn_buf: [256]u8 = undefined;
    var name_elt = c.br_name_element{
        .oid = &context.OID_COMMON_NAME,
        .buf = &client_cn_buf,
        .len = client_cn_buf.len,
        .status = 0,
    };
    c.br_x509_minimal_set_name_elements(&server_x509, &name_elt, 1);

    var client = try TestClient.init(a, .{});
    defer client.deinit(a);
    client.start();

    try driveHandshake(&server_ctx.eng, &client.ctx.eng);
    try std.testing.expectEqual(@as(c_int, 0), c.br_ssl_engine_last_error(&server_ctx.eng));
    try std.testing.expectEqual(@as(c_int, 0), name_elt.status);
}

test "14. mTLS optional: handshake succeeds with valid client cert and exposes subject CN" {
    const a = std.testing.allocator;
    var tls_ctx = try context.TlsContext.init(a, .{
        .enabled = true,
        .cert_path = "loadtest/tls/server.crt",
        .key_path = "loadtest/tls/server.key",
        .client_ca_path = "loadtest/tls/ca.crt",
        .require_client_cert = false,
    });
    defer tls_ctx.deinit();

    var server_ctx: c.br_ssl_server_context = undefined;
    var server_x509: c.br_x509_minimal_context = undefined;
    var server_iobuf: [context.BR_SSL_BUFSIZE_BIDI]u8 = undefined;
    tls_ctx.initServerConnection(&server_ctx, &server_iobuf, &server_x509);

    var client_cn_buf: [256]u8 = undefined;
    var name_elt = c.br_name_element{
        .oid = &context.OID_COMMON_NAME,
        .buf = &client_cn_buf,
        .len = client_cn_buf.len,
        .status = 0,
    };
    c.br_x509_minimal_set_name_elements(&server_x509, &name_elt, 1);

    var client = try TestClient.init(a, .{
        .client_cert_path = "loadtest/tls/client.crt",
        .client_key_path = "loadtest/tls/client.key",
    });
    defer client.deinit(a);
    client.start();

    try driveHandshake(&server_ctx.eng, &client.ctx.eng);
    try std.testing.expectEqual(@as(c_int, 0), c.br_ssl_engine_last_error(&server_ctx.eng));
    try std.testing.expectEqual(@as(c_int, 1), name_elt.status);
    const cn_len = std.mem.indexOfScalar(u8, &client_cn_buf, 0) orelse client_cn_buf.len;
    try std.testing.expectEqualStrings("test-client", client_cn_buf[0..cn_len]);
}

test "15. mTLS optional: handshake fails with client cert signed by untrusted CA" {
    const a = std.testing.allocator;
    var tls_ctx = try context.TlsContext.init(a, .{
        .enabled = true,
        .cert_path = "loadtest/tls/server.crt",
        .key_path = "loadtest/tls/server.key",
        .client_ca_path = "loadtest/tls/ca.crt",
        .require_client_cert = false,
    });
    defer tls_ctx.deinit();

    var server_ctx: c.br_ssl_server_context = undefined;
    var server_x509: c.br_x509_minimal_context = undefined;
    var server_iobuf: [context.BR_SSL_BUFSIZE_BIDI]u8 = undefined;
    tls_ctx.initServerConnection(&server_ctx, &server_iobuf, &server_x509);

    var client_cn_buf: [256]u8 = undefined;
    var name_elt = c.br_name_element{
        .oid = &context.OID_COMMON_NAME,
        .buf = &client_cn_buf,
        .len = client_cn_buf.len,
        .status = 0,
    };
    c.br_x509_minimal_set_name_elements(&server_x509, &name_elt, 1);

    var client = try TestClient.init(a, .{
        .client_cert_path = "loadtest/tls/other_client.crt",
        .client_key_path = "loadtest/tls/other_client.key",
    });
    defer client.deinit(a);
    client.start();

    const res = driveHandshake(&server_ctx.eng, &client.ctx.eng);
    try std.testing.expectError(error.HandshakeFailed, res);
    const last_err = c.br_ssl_engine_last_error(&server_ctx.eng);
    try std.testing.expect(last_err != 0);
}

test "16. mTLS strict: handshake fails without client cert, succeeds with valid cert" {
    const a = std.testing.allocator;
    var tls_ctx = try context.TlsContext.init(a, .{
        .enabled = true,
        .cert_path = "loadtest/tls/server.crt",
        .key_path = "loadtest/tls/server.key",
        .client_ca_path = "loadtest/tls/ca.crt",
        .require_client_cert = true,
    });
    defer tls_ctx.deinit();

    // 1. Without client cert -> must fail
    {
        var server_ctx: c.br_ssl_server_context = undefined;
        var server_x509: c.br_x509_minimal_context = undefined;
        var server_iobuf: [context.BR_SSL_BUFSIZE_BIDI]u8 = undefined;
        tls_ctx.initServerConnection(&server_ctx, &server_iobuf, &server_x509);

        var client = try TestClient.init(a, .{});
        defer client.deinit(a);
        client.start();

        const res = driveHandshake(&server_ctx.eng, &client.ctx.eng);
        try std.testing.expectError(error.HandshakeFailed, res);
        try std.testing.expect(c.br_ssl_engine_last_error(&server_ctx.eng) != 0);
    }

    // 2. With valid client cert -> must succeed
    {
        var server_ctx: c.br_ssl_server_context = undefined;
        var server_x509: c.br_x509_minimal_context = undefined;
        var server_iobuf: [context.BR_SSL_BUFSIZE_BIDI]u8 = undefined;
        tls_ctx.initServerConnection(&server_ctx, &server_iobuf, &server_x509);

        var client_cn_buf: [256]u8 = undefined;
        var name_elt = c.br_name_element{
            .oid = &context.OID_COMMON_NAME,
            .buf = &client_cn_buf,
            .len = client_cn_buf.len,
            .status = 0,
        };
        c.br_x509_minimal_set_name_elements(&server_x509, &name_elt, 1);

        var client = try TestClient.init(a, .{
            .client_cert_path = "loadtest/tls/client.crt",
            .client_key_path = "loadtest/tls/client.key",
        });
        defer client.deinit(a);
        client.start();

        try driveHandshake(&server_ctx.eng, &client.ctx.eng);
        try std.testing.expectEqual(@as(c_int, 0), c.br_ssl_engine_last_error(&server_ctx.eng));
        try std.testing.expectEqual(@as(c_int, 1), name_elt.status);
        const cn_len = std.mem.indexOfScalar(u8, &client_cn_buf, 0) orelse client_cn_buf.len;
        try std.testing.expectEqualStrings("test-client", client_cn_buf[0..cn_len]);
    }
}
