const std = @import("std");
const c = @import("common.zig");

pub fn address(a: c.A, kind: enum { okFactory, passwordGatedKVFactory }, chain: u64) !?[]const u8 {
    const shared = try c.parse(a, @embedFile("factory-addresses"));
    const entries = c.field(shared, @tagName(kind)).?;
    const value = c.field(entries, try a.print("{d}", .{chain})) orelse return null;
    const result = try c.string(value);
    try c.address(result);
    return result;
}
