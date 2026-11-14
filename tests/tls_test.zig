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
