const std = @import("std");
const c = @import("common.zig");
pub const Result = struct { value: c.Value, success: bool = true };
/// Foundry 1.8 JSON output can use a versioned envelope. Older bare values and
/// receipts remain supported. Preserve data even on failure for recovery paths.
pub fn unwrap(a: c.A, value: c.Value) !Result {
    const version = c.field(value, "schema_version") orelse return .{ .value = value };
    if (try c.number(a, version) != 1) return error.UnsupportedFoundryJsonVersion;
    const success = c.field(value, "success") orelse return error.InvalidFoundryJson;
    if (success != .bool) return error.InvalidFoundryJson;
    return .{ .value = c.field(value, "data") orelse return error.InvalidFoundryJson, .success = success.bool };
}
test "Foundry JSON compatibility preserves bare values, envelopes and failure data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "[\"1\"]", "{\"schema_version\":1,\"success\":true,\"data\":[\"1\"],\"errors\":[],\"warnings\":[]}" }) |text| {
        const result = try unwrap(a, try c.parse(a, text));
        try std.testing.expect(result.success);
        try std.testing.expectEqualStrings("1", try c.string(result.value.array.items[0]));
    }
    const failed = try unwrap(a, try c.parse(a, "{\"schema_version\":1,\"success\":false,\"data\":\"0x1234\"}"));
    try std.testing.expect(!failed.success);
    try std.testing.expectEqualStrings("0x1234", try c.string(failed.value));
    try std.testing.expectError(error.UnsupportedFoundryJsonVersion, unwrap(a, try c.parse(a, "{\"schema_version\":2}")));
}
