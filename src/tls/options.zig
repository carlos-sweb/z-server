pub const CertSource = union(enum) {
    file_paths: struct {
        cert_path: []const u8,
        key_path: []const u8,
    },
    pem_bytes: struct {
        cert_pem: []const u8,
        key_pem: []const u8,
    },
};

pub const Options = struct {
    enabled: bool = true,
    bind: []const u8 = "0.0.0.0:8443",
    cert: ?CertSource = null,
    cert_path: ?[]const u8 = null,
    key_path: ?[]const u8 = null,
    alpn: []const []const u8 = &.{"http/1.1"},
    min_version: []const u8 = "1.2",
    max_conns: u32 = 256,
};
