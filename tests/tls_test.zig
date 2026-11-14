const std = @import("std");
const app = @import("app");
const c = @import("c");
const pem = app.tls_pem;
const context = app.tls_context;

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

    tls_ctx.initServerConnection(&server_ctx, &iobuf);
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
    tls_ctx.initServerConnection(&server_ctx, &iobuf);

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
