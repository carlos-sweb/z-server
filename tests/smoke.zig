const std = @import("std");
const version = @import("version");

test "version is 0.4.0" {
    try std.testing.expectEqualStrings("0.4.0", version.version);
}
