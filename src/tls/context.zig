const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c");
const pem = @import("pem.zig");
const config = @import("../config.zig");

pub const BR_SSL_BUFSIZE_BIDI: usize = c.BR_SSL_BUFSIZE_BIDI;

pub const TlsContext = struct {
    chain: pem.CertChain,
    key: pem.PrivateKey,
    alpn_names: [1][*:0]const u8,

    pub fn init(allocator: Allocator, tls_cfg: config.TlsConfig) !TlsContext {
        const cert_path = tls_cfg.cert_path orelse return error.MissingCertPath;
        const key_path = tls_cfg.key_path orelse return error.MissingKeyPath;

        var chain = try pem.loadCertChain(allocator, cert_path);
        errdefer chain.deinit();

        var key = try pem.loadPrivateKey(allocator, key_path);
        errdefer key.deinit();

        return .{
            .chain = chain,
            .key = key,
            .alpn_names = .{"http/1.1"},
        };
    }

    pub fn deinit(self: *TlsContext) void {
        self.chain.deinit();
        self.key.deinit();
    }

    pub fn initServerConnection(self: *const TlsContext, server_ctx: *c.br_ssl_server_context, iobuf: []u8) void {
        c.br_ssl_server_init_full_rsa(
            server_ctx,
            self.chain.certs.ptr,
            self.chain.certs.len,
            &self.key.key,
        );

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
