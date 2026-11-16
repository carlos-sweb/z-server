const std = @import("std");
const version = @import("version");

test "version is 0.8.0" {
    try std.testing.expectEqualStrings("0.8.0", version.version);
}
