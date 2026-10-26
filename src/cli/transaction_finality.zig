const std = @import("std");
const c = @import("common.zig");
const rpc = @import("rpc.zig");

pub fn unchecked(a: c.A) !c.Value {
    return c.parse(a, "{\"basis\":\"rpc-block-tags\",\"safe\":{\"status\":\"not-checked\"},\"finalized\":{\"status\":\"not-checked\"},\"settlement\":{\"status\":\"not-checked\"}}");
}
fn marker(remote: *rpc.Rpc, tag: []const u8, height: ?u64) !c.Value {
    const block = try remote.blockAt(tag);
    if (!try remote.canonical(block)) return error.FinalityMarkerReorganized;
    return c.parse(remote.a, try c.encode(remote.a, .{ .status = if (height != null and height.? <= block.number) "reached" else "not-reached", .block = block }));
}
pub fn check(remote: *rpc.Rpc, receipt: c.Value) !c.Value {
    const a = remote.a;
    try remote.pinBlock(null, 0);
    const block: ?rpc.Block = if (receipt == .null) null else .{
        .number = try rpc.integer(a, c.field(receipt, "blockNumber") orelse return error.InvalidTransactionReceipt),
        .hash = try c.string(c.field(receipt, "blockHash") orelse return error.InvalidTransactionReceipt),
        .timestamp = 0,
    };
    if (block) |mined| if (!try remote.canonical(mined)) return error.TransactionReorganized;
    var result = try unchecked(a);
    for ([_][]const u8{ "safe", "finalized" }) |tag| {
        const value = marker(remote, tag, if (block) |mined| mined.number else null) catch |err| blk: {
            if (err == error.OutOfMemory or err == error.Canceled) return err;
            break :blk try c.parse(a, try c.encode(a, .{ .status = "unavailable", .errorName = @errorName(err) }));
        };
        try result.object.put(a, tag, value);
    }
    if (block) |mined| if (!try remote.canonical(mined)) return error.TransactionReorganized;
    try result.object.put(a, "observedHead", try c.parse(a, try c.encode(a, remote.block)));
    return result;
}

test "safe and finalized markers are independent of depth and unsupported tags stay unknown" {
    const mock = @import("test_rpc.zig");
    const hash = "0x1111111111111111111111111111111111111111111111111111111111111111";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const head = try c.encode(a, .{.{ .jsonrpc = "2.0", .id = 1, .result = .{ .number = "0x64", .hash = hash, .timestamp = "0x1" } }});
    const behind = try c.encode(a, .{.{ .jsonrpc = "2.0", .id = 1, .result = .{ .number = "0x63", .hash = hash, .timestamp = "0x1" } }});
    const receipt = try c.parse(a, try c.encode(a, .{ .blockNumber = "0x64", .blockHash = hash }));
    for ([_]bool{ false, true }) |unsupported| {
        const replies = [_]mock.Reply{
            .{ .body = "[{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\"0xa4b1\"}]" },
            .{ .body = head },
            .{ .body = head },
            .{ .body = head, .request_contains = "safe" },
            .{ .body = head },
            .{ .body = if (unsupported) "[{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32602,\"message\":\"unsupported tag\"}}]" else behind, .request_contains = "finalized" },
            .{ .body = if (unsupported) head else behind },
            .{ .body = head },
        };
        var server = try mock.Server.init(std.testing.io, replies[0..(if (unsupported) @as(usize, 7) else 8)]);
        defer server.deinit();
        var serving = try std.testing.io.concurrent(mock.Server.serve, .{&server});
        defer _ = serving.cancel(std.testing.io) catch {};
        var remote = try rpc.Rpc.initEndpoint(a, std.testing.io, try server.url(a), 42161);
        defer remote.deinit();
        remote.timeout_seconds = 1;
        remote.read_attempts = 1;
        const report = try check(&remote, receipt);
        try std.testing.expectEqualStrings("reached", try c.string(c.field(c.field(report, "safe").?, "status").?));
        try std.testing.expectEqualStrings(if (unsupported) "unavailable" else "not-reached", try c.string(c.field(c.field(report, "finalized").?, "status").?));
        try std.testing.expectEqualStrings("not-checked", try c.string(c.field(c.field(report, "settlement").?, "status").?));
        try serving.await(std.testing.io);
    }
}
