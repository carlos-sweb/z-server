const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c");
const pem = @import("pem.zig");
const options = @import("options.zig");

pub const BR_SSL_BUFSIZE_BIDI: usize = c.BR_SSL_BUFSIZE_BIDI;

pub const HARDENED_SUITES = [_]u16{
    c.BR_TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
    c.BR_TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,
    c.BR_TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
};

pub const SecurityProfile = struct {
    version_min: u16,
    version_max: u16,
    suites: []const u16,
    supported_curves: u32,
    renegotiation: []const u8,
    rsa_keyx: []const u8,
};

pub fn getSecurityProfile() SecurityProfile {
    return .{
        .version_min = c.BR_TLS12,
        .version_max = c.BR_TLS12,
        .suites = &HARDENED_SUITES,
        .supported_curves = (@as(u32, 1) << c.BR_EC_secp256r1) | (@as(u32, 1) << c.BR_EC_curve25519),
        .renegotiation = "disabled",
        .rsa_keyx = "disabled",
    };
}

pub const TlsContext = struct {
    chain: pem.CertChain,
    key: pem.PrivateKey,
    alpn_names: [1][*:0]const u8,
    ec_impl: c.br_ec_impl,

    pub fn init(allocator: Allocator, tls_cfg: anytype) !TlsContext {
        var chain: pem.CertChain = undefined;
        var key: pem.PrivateKey = undefined;

        const cert_source_opt: ?options.CertSource = if (@hasField(@TypeOf(tls_cfg), "cert"))
            tls_cfg.cert
        else
            null;

        if (cert_source_opt) |cert_source| {
            switch (cert_source) {
                .pem_bytes => |bytes| {
                    chain = try pem.parseCertChainFromSlice(allocator, bytes.cert_pem);
                    errdefer chain.deinit();
                    key = try pem.parsePrivateKeyFromSlice(allocator, bytes.key_pem);
                    errdefer key.deinit();
                },
                .file_paths => |paths| {
                    chain = try pem.loadCertChain(allocator, paths.cert_path);
                    errdefer chain.deinit();
                    key = try pem.loadPrivateKey(allocator, paths.key_path);
                    errdefer key.deinit();
                },
            }
        } else if (@hasField(@TypeOf(tls_cfg), "cert_path") and @hasField(@TypeOf(tls_cfg), "key_path")) {
            const cert_path: ?[]const u8 = tls_cfg.cert_path;
            const key_path: ?[]const u8 = tls_cfg.key_path;
            const cp = cert_path orelse return error.MissingCertPath;
            const kp = key_path orelse return error.MissingKeyPath;
            chain = try pem.loadCertChain(allocator, cp);
            errdefer chain.deinit();
            key = try pem.loadPrivateKey(allocator, kp);
            errdefer key.deinit();
        } else {
            return error.MissingCertConfig;
        }

        // br_ec_all_m31 includes X25519, P-256, P-384 and P-521 by
        // default. We filter supported_curves to X25519 + P-256 only
        // to reduce attack surface (P-384/P-521 not needed for our
        // cert type, and P-521 has had implementation issues in some
        // libraries). This is defense in depth: even if a client
        // offers P-384/P-521, the server will not negotiate them.
        var ec = c.br_ec_all_m31;
        ec.supported_curves = (@as(u32, 1) << c.BR_EC_secp256r1) | (@as(u32, 1) << c.BR_EC_curve25519);

        return .{
            .chain = chain,
            .key = key,
            .alpn_names = .{"http/1.1"},
            .ec_impl = ec,
        };
    }

    pub fn deinit(self: *TlsContext) void {
        self.chain.deinit();
        self.key.deinit();
    }

    pub fn initServerConnection(self: *const TlsContext, server_ctx: *c.br_ssl_server_context, iobuf: []u8) void {
        c.br_ssl_server_zero(server_ctx);

        // 1. Force TLS 1.2 exclusively (disable TLS 1.0 and 1.1 -> BEAST mitigation)
        c.br_ssl_engine_set_versions(&server_ctx.eng, c.BR_TLS12, c.BR_TLS12);

        // 2. Force AEAD suites only (AES-GCM and ChaCha20-Poly1305; eliminate all CBC and 3DES suites)
        c.br_ssl_engine_set_suites(&server_ctx.eng, &HARDENED_SUITES, HARDENED_SUITES.len);

        // 3. Restrict elliptic curves to X25519 and P-256 only (disable legacy/larger curves)
        c.br_ssl_engine_set_ec(&server_ctx.eng, &self.ec_impl);

        // 4. Disable renegotiation and enforce server cipher preferences
        c.br_ssl_engine_add_flags(&server_ctx.eng, c.BR_OPT_NO_RENEGOTIATION | c.BR_OPT_ENFORCE_SERVER_PREFERENCES);

        // 5. Restrict RSA certificate policy to SIGN only (disables RSA key exchange -> ROBOT mitigation)
        c.br_ssl_server_set_single_rsa(
            server_ctx,
            self.chain.certs.ptr,
            self.chain.certs.len,
            &self.key.key,
            c.BR_KEYTYPE_SIGN,
            c.br_rsa_private_get_default(),
            c.br_rsa_pkcs1_sign_get_default(),
        );

        // 6. Hash functions for X.509 chain validation by CLIENTS.
        //    MD5 is excluded (cryptographically broken, no modern chain
        //    uses it). SHA-1 is kept for compatibility with legacy
        //    intermediate CAs; remove it in v0.4.0 if the cert chain
        //    is confirmed SHA-256+.
        c.br_ssl_engine_set_hash(&server_ctx.eng, c.br_sha1_ID, &c.br_sha1_vtable);
        c.br_ssl_engine_set_hash(&server_ctx.eng, c.br_sha224_ID, &c.br_sha224_vtable);
        c.br_ssl_engine_set_hash(&server_ctx.eng, c.br_sha256_ID, &c.br_sha256_vtable);
        c.br_ssl_engine_set_hash(&server_ctx.eng, c.br_sha384_ID, &c.br_sha384_vtable);
        c.br_ssl_engine_set_hash(&server_ctx.eng, c.br_sha512_ID, &c.br_sha512_vtable);

        // 7. Set PRF implementations for TLS 1.2
        c.br_ssl_engine_set_prf_sha256(&server_ctx.eng, &c.br_tls12_sha256_prf);
        c.br_ssl_engine_set_prf_sha384(&server_ctx.eng, &c.br_tls12_sha384_prf);

        // 8. Set AEAD symmetric cipher implementations only (AES-GCM and ChaCha20-Poly1305; no CBC or 3DES)
        c.br_ssl_engine_set_default_aes_gcm(&server_ctx.eng);
        c.br_ssl_engine_set_default_chapol(&server_ctx.eng);

        const names_ptr: [*c][*c]const u8 = @ptrCast(@constCast(&self.alpn_names));
        c.br_ssl_engine_set_protocol_names(
            &server_ctx.eng,
            names_ptr,
            self.alpn_names.len,
        );

        c.br_ssl_engine_set_buffer(&server_ctx.eng, iobuf.ptr, iobuf.len, 1);
        _ = c.br_ssl_server_reset(server_ctx);
    }
};
