//! One additive metadata shape for cached views. An offline cache read never
//! proves current chain-head freshness or explorer indexing completeness.
const std = @import("std");
const c = @import("common.zig");
pub fn describe(a: c.A, source: []const u8, checkpoint: c.Value, status_block: c.Value, incomplete: bool) !c.Value {
    const block = c.field(checkpoint, "block") orelse .null;
    const strategy = c.string(c.field(checkpoint, "strategy") orelse .null) catch "";
    const discovery = c.field(checkpoint, "discovery") orelse .null;
    var snapshot: []const u8 = "unknown";
    var history: []const u8 = "unknown";
    if (@import("schema.zig").contains("pages stable-index signer-key-index pending-and-executed-index", strategy) and block != .null) snapshot = "complete";
    if (c.field(discovery, "historyComplete")) |complete| {
        if (complete == .bool) {
            history = if (complete.bool) "complete" else "partial";
            snapshot = history;
        }
    }
    if (incomplete) snapshot = "partial";
    return c.parse(a, try c.encode(a, .{
        .formatVersion = 1,
        .source = source,
        .checkpoint = checkpoint,
        .freshness = .{ .state = if (block == .null) "unknown" else "as-of-block", .asOfBlock = block, .headChecked = false, .ageSeconds = @as(c.Value, .null) },
        .statusBlock = status_block,
        .completeness = .{ .snapshot = snapshot, .history = history, .verifiedFrom = c.field(discovery, "completeFrom") orelse @as(c.Value, .null), .verifiedThrough = c.field(discovery, "completeThrough") orelse @as(c.Value, .null), .indexerCompleteThrough = c.field(discovery, "indexerCompleteThrough") orelse @as(c.Value, .null) },
    }));
}
pub fn datasets(a: c.A, source: []const u8, checkpoints: c.Value) !c.Value {
    var result: std.json.ObjectMap = .empty;
    if (checkpoints != .object) return .{ .object = result };
    for (checkpoints.object.keys(), checkpoints.object.values()) |name, checkpoint| try result.put(a, name, try describe(a, source, checkpoint, .null, false));
    return .{ .object = result };
}
test "cache metadata separates snapshot completeness, history, status and freshness" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const indexed = try describe(a, "sqlite-cache", try c.parse(a, "{\"block\":{\"number\":20},\"strategy\":\"stable-index\"}"), .null, false);
    try std.testing.expectEqualStrings("complete", try c.string(c.field(c.field(indexed, "completeness").?, "snapshot").?));
    try std.testing.expectEqualStrings("unknown", try c.string(c.field(c.field(indexed, "completeness").?, "history").?));
    try std.testing.expect(!c.field(c.field(indexed, "freshness").?, "headChecked").?.bool);
    const explorer = try describe(a, "sqlite-cache", try c.parse(a, "{\"block\":{\"number\":20},\"strategy\":\"etherscan\",\"discovery\":{\"historyComplete\":false}}"), try c.parse(a, "{\"number\":15}"), false);
    try std.testing.expectEqualStrings("partial", try c.string(c.field(c.field(explorer, "completeness").?, "snapshot").?));
    try std.testing.expectEqual(15, try c.number(a, c.field(c.field(explorer, "statusBlock").?, "number").?));
    const local = try describe(a, "local-imports", .null, .null, false);
    for ([_][]const u8{ "checkpoint", "statusBlock" }) |name| try std.testing.expect(c.field(local, name).? == .null);
    try std.testing.expectEqualStrings("unknown", try c.string(c.field(c.field(local, "completeness").?, "snapshot").?));
    const damaged = try describe(a, "sqlite-cache", c.field(indexed, "checkpoint").?, .null, true);
    try std.testing.expectEqualStrings("partial", try c.string(c.field(c.field(damaged, "completeness").?, "snapshot").?));
    const snapshot = try datasets(a, "snapshot-file", try c.parse(a, "{\"users\":{\"block\":{\"number\":20},\"strategy\":\"pages\"}}"));
    try std.testing.expectEqualStrings("snapshot-file", try c.string(c.field(c.field(snapshot, "users").?, "source").?));
}
