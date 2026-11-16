const std = @import("std");
const version = @import("version");

test "version is 0.9.0" {
    try std.testing.expectEqualStrings("0.9.0", version.version);
}
