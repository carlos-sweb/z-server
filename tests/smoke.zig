const std = @import("std");
const version = @import("version");

test "version is 1.0.0" {
    try std.testing.expectEqualStrings("1.0.0", version.version);
}
