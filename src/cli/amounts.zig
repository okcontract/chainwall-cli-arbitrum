const std = @import("std");
const c = @import("common.zig");

/// Parse exact base units without floating point or rounding excess precision.
pub fn decimal(text: []const u8, decimals: u8) !u256 {
    if (text.len == 0 or decimals > 77) return error.InvalidAmount;
    var value: u256 = 0;
    var fraction: ?u8 = null;
    var digits: usize = 0;
    for (text) |ch| {
        if (ch == '.' and fraction == null and digits > 0) {
            fraction = 0;
            continue;
        }
        if (!std.ascii.isDigit(ch)) return error.InvalidAmount;
        value = std.math.add(u256, std.math.mul(u256, value, 10) catch return error.InvalidAmount, ch - '0') catch return error.InvalidAmount;
        digits += 1;
        if (fraction) |n| {
            if (n >= decimals) return error.InvalidAmount;
            fraction = n + 1;
        }
    }
    if (digits == 0 or fraction == 0) return error.InvalidAmount;
    for (fraction orelse 0..decimals) |_| value = std.math.mul(u256, value, 10) catch return error.InvalidAmount;
    return value;
}

pub fn native(text: []const u8) !u256 {
    for ([_]struct { suffix: []const u8, decimals: u8 }{
        .{ .suffix = "ether", .decimals = 18 }, .{ .suffix = "eth", .decimals = 18 },
        .{ .suffix = "gwei", .decimals = 9 },   .{ .suffix = "wei", .decimals = 0 },
    }) |unit| {
        if (std.mem.endsWith(u8, text, unit.suffix)) return decimal(text[0 .. text.len - unit.suffix.len], unit.decimals);
    }
    return c.word(text) catch error.InvalidAmount;
}

test "native amounts preserve exact units and reject rounding, signs and overflow" {
    try std.testing.expectEqual(@as(u256, 100000000000000001), try native("0.100000000000000001ether"));
    try std.testing.expectEqual(@as(u256, 1200000000), try native("1.2gwei"));
    try std.testing.expectEqual(@as(u256, 42), try native("42"));
    try std.testing.expectEqual(@as(u256, 42), try native("42wei"));
    try std.testing.expectEqual(@as(u256, 42), try native("0x2a"));
    for ([_][]const u8{ "", "-1ether", "+1eth", "1e18", "0.1", ".1ether", "1.ether", "1.1wei", "0.0000000001gwei", "1..2ether", "1 ether", "999999999999999999999999999999999999999999999999999999999999999999999999999999ether" }) |text| {
        try std.testing.expectError(error.InvalidAmount, native(text));
    }
}
