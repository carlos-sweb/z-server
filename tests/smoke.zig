const std = @import("std");
const version = @import("version");

test "version is 0.1.1" {
    try std.testing.expectEqualStrings("0.1.1", version.version);
}
