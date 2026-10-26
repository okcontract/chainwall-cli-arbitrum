const std = @import("std");
const ms = @import("miniscript");
const oracle = @import("oracle.zig");

fn check(source: []const u8, args: []const u256, expected: u256, effects: []const oracle.Effect) !void {
    for ([_]ms.Settings{ .{ .optimization = .baseline }, .{ .optimization = .size } }) |settings| {
        const bytes = try ms.compile(std.testing.allocator, source, settings);
        defer std.testing.allocator.free(bytes);
        const result = try oracle.execute(bytes, args);
        try std.testing.expectEqual(expected, result.value);
        try std.testing.expectEqual(effects.len, result.count);
        for (effects, result.effects[0..result.count]) |want, actual| try std.testing.expectEqualDeep(want, actual);
    }
}
test "independent semantics cover overflow, negative factors, rounding and effects" {
    const max = std.math.maxInt(u256);
    try check("$arg0 + $arg1", &.{ max, 1 }, 0, &.{});
    try check("$arg0 * $arg1", &.{ max, 2 }, max - 1, &.{});
    try check("$arg0 - $arg1", &.{ 0, 1 }, max, &.{});
    try check("$floor(-1 * $arg0 / $arg1)", &.{ 2, 2 }, max, &.{});
    try check("$floor($arg0 * $arg1 / $arg2)", &.{ max, 2, 2 }, max, &.{});
    try check("$floor($arg0 * $arg1 / $arg2)", &.{ 7, 3, 4 }, 5, &.{});
    try check("$floor($arg0 * $arg1 / -1)", &.{ 2, 3 }, 0, &.{});
    try check("let x = $read(10, 1) in x + x", &.{}, 202, &.{.{ .write = false, .target = 10, .selector = 1 }});
    for ([_]u256{ 0, 1 }) |condition| {
        try check("{$write(10, 1), IF($arg0, $write(10, 2), $write(10, 3))}", &.{condition}, 102, &.{ .{ .write = true, .target = 10, .selector = 1 }, .{ .write = true, .target = 10, .selector = if (condition == 0) 3 else 2 } });
        try check("IF($arg0, 7, 9)", &.{condition}, if (condition == 0) 9 else 7, &.{});
    }
}

test "seeded expression corpus agrees with independent mathematical expectations" {
    // Fixed LCG, independent of std.Random implementation/version. Each case is
    // evaluated directly here and independently by the bytecode machine.
    var seed: u64 = 0x434841494e57414c;
    for (0..2000) |i| {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        const x: u256 = seed;
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        const y: u256 = seed;
        const z: u256 = (i % 97) + 1;
        const source, const expected = switch (i % 4) {
            0 => .{ "($arg0 + $arg1) * $arg2", (x +% y) *% z },
            1 => .{ "($arg0 - $arg1) * $arg2", (x -% y) *% z },
            2 => .{ "$floor($arg0 * $arg1 / $arg2)", x * y / z },
            else => .{ "IF($arg0 > $arg1, $arg0 - $arg1, $arg1 - $arg0)", if (x > y) x - y else y - x },
        };
        try check(source, &.{ x, y, z }, expected, &.{});
    }
}
