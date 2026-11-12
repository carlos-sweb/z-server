//! /proc/self I/O and fd count for /health. The loadtest sampler must not
//! silently write 0 when host /proc/<container-pid>/io is unreadable.

const std = @import("std");

pub const IoBytes = struct {
    read_bytes: u64 = 0,
    write_bytes: u64 = 0,
};

pub fn ioBytes() IoBytes {
    var buf: [1024]u8 = undefined;
    const text = readProc("/proc/self/io", &buf) orelse return .{};
    return .{
        .read_bytes = parseField(text, "read_bytes:"),
        .write_bytes = parseField(text, "write_bytes:"),
    };
}

/// Count open descriptors of this process (fcntl GETFD). Avoids listing
/// /proc/<pid>/fd from another user namespace.
pub fn fdCount() u32 {
    var n: u32 = 0;
    var i: c_int = 0;
    while (i < 1024) : (i += 1) {
        if (std.c.fcntl(i, std.c.F.GETFD) >= 0) n += 1;
    }
    return n;
}

fn readProc(path: []const u8, buf: []u8) ?[]const u8 {
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer _ = std.posix.system.close(fd);
    const n = std.posix.read(fd, buf) catch return null;
    return buf[0..n];
}

fn parseField(text: []const u8, key: []const u8) u64 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, key)) continue;
        const rest = std.mem.trim(u8, line[key.len..], " \t\r");
        return std.fmt.parseInt(u64, rest, 10) catch 0;
    }
    return 0;
}
