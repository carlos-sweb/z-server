const std = @import("std");
const version = @import("version");

test "version is 0.2.0" {
    try std.testing.expectEqualStrings("0.2.0", version.version);
}
