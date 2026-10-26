//! Log coverage is separate from the block used for current-state reads.
const std = @import("std");
const c = @import("common.zig");
const rpc = @import("rpc.zig");
pub const Coverage = struct {
    source: []const u8,
    requestedFrom: u64,
    requestedThrough: u64,
    rangeComplete: bool,
    completeFrom: ?u64,
    completeThrough: ?u64,
    historyComplete: bool,
    // Explorer getLogs provides no watermark proving indexing completeness.
    indexerCompleteThrough: c.Value = .null,
};
pub fn start(a: c.A, previous: ?c.Value, minimum: u64, lookback: u64, backfill: ?u64, head: u64) !u64 {
    if (minimum > head) return error.InvalidLogRange;
    if (backfill) |from| if (from < minimum or from > head) return error.InvalidBackfillRange;
    var first = minimum;
    if (previous) |checkpoint| {
        const number = try rpc.integer(a, c.field(c.field(checkpoint, "block").?, "number").?);
        first = @max(minimum, if (lookback == 0) number +| 1 else number -| (lookback - 1));
    }
    return if (backfill) |from| @min(first, from) else first;
}
pub fn advance(a: c.A, previous: ?c.Value, source: []const u8, minimum: u64, from: u64, to: u64) !Coverage {
    const complete = c.eq(u8, source, "rpc-logs");
    var lower: ?u64 = null;
    var upper: ?u64 = null;
    if (previous) |checkpoint| if (c.field(checkpoint, "discovery")) |old| {
        if (c.field(old, "completeFrom")) |value| if (value != .null) {
            const old_lower = try rpc.integer(a, value);
            if (c.field(old, "completeThrough")) |end| if (end != .null) {
                const old_upper = try rpc.integer(a, end);
                if (old_lower >= minimum and old_lower <= old_upper and old_upper <= to) {
                    lower = old_lower;
                    upper = old_upper;
                }
            };
        };
    };
    if (complete and from <= to) {
        if (lower != null and from <= upper.? +| 1) {
            lower = @min(lower.?, from);
        } else lower = from;
        upper = to;
    }
    return .{ .source = source, .requestedFrom = from, .requestedThrough = to, .rangeComplete = complete, .completeFrom = lower, .completeThrough = upper, .historyComplete = lower != null and lower.? == minimum and upper.? == to };
}

test "explorer progress never claims completeness and explicit backfill closes old gaps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old = try c.parse(a, "{\"block\":{\"number\":500}}");
    try std.testing.expectEqual(@as(u64, 373), try start(a, old, 10, 128, null, 600));
    try std.testing.expectEqual(@as(u64, 10), try start(a, old, 10, 128, 10, 600));
    try std.testing.expectError(error.InvalidBackfillRange, start(a, old, 10, 128, 9, 600));
    const lagged = try advance(a, old, "etherscan", 10, 373, 600);
    try std.testing.expect(!lagged.historyComplete and lagged.completeThrough == null);
    const partial = try advance(a, old, "rpc-logs", 10, 373, 600);
    try std.testing.expect(partial.rangeComplete and !partial.historyComplete);
    const checkpoint = try c.parse(a, try c.encode(a, .{ .block = .{ .number = 600 }, .discovery = partial }));
    const filled = try advance(a, checkpoint, "rpc-logs", 10, 10, 700);
    try std.testing.expect(filled.historyComplete);
    const verified = try c.parse(a, try c.encode(a, .{ .discovery = filled }));
    const next = try advance(a, verified, "rpc-logs", 10, 701, 800);
    try std.testing.expect(next.historyComplete);
    const uncertain = try advance(a, verified, "etherscan", 10, 600, 800);
    try std.testing.expectEqual(@as(?u64, 700), uncertain.completeThrough);
    try std.testing.expect(!uncertain.historyComplete);
}
