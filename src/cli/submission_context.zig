const std = @import("std");
const c = @import("common.zig");
const rpc = @import("rpc.zig");
const abi = @import("abi_codec.zig");
pub const Context = struct { chainId: u64, sender: []const u8, nonce: u64, block: rpc.Block };

/// Resolve before broadcast, then pass this exact nonce and sender to Foundry.
pub fn resolve(remote: *rpc.Rpc, sender: []const u8, requested: ?u64) !Context {
    try c.address(sender);
    try remote.pinBlock(null, 0);
    const nonce = requested orelse try rpc.integer(remote.a, try remote.one("eth_getTransactionCount", try abi.array(remote.a, &.{ .{ .string = sender }, .{ .string = "pending" } })));
    if (nonce == std.math.maxInt(u64)) return error.InvalidNonce;
    if (!try remote.canonical(remote.block)) return error.TransactionReorganized;
    return .{ .chainId = remote.chain, .sender = sender, .nonce = nonce, .block = remote.block };
}

test "submission context binds a resolved pending nonce or explicit replacement nonce" {
    const mock = @import("test_rpc.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const head = "[{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"number\":\"0x64\",\"hash\":\"0x1111111111111111111111111111111111111111111111111111111111111111\",\"timestamp\":\"0x1\"}}]";
    for ([_]?u64{ null, 7 }) |requested| {
        const replies = [_]mock.Reply{
            .{ .body = "[{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\"0xa4b1\"}]" },                               .{ .body = head },
            .{ .body = if (requested == null) "[{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\"0x8\"}]" else head }, .{ .body = head },
        };
        var server = try mock.Server.init(std.testing.io, replies[0..(if (requested == null) @as(usize, 4) else 3)]);
        defer server.deinit();
        var serving = try std.testing.io.concurrent(mock.Server.serve, .{&server});
        defer _ = serving.cancel(std.testing.io) catch {};
        var remote = try rpc.Rpc.initEndpoint(a, std.testing.io, try server.url(a), 42161);
        defer remote.deinit();
        remote.timeout_seconds = 1;
        const sender = "0x1111111111111111111111111111111111111111";
        const result = try resolve(&remote, sender, requested);
        try std.testing.expectEqualStrings(sender, result.sender);
        try std.testing.expectEqual(requested orelse 8, result.nonce);
        try std.testing.expectEqual(@as(u64, 100), result.block.number);
        try std.testing.expectEqual(@as(u64, 42161), result.chainId);
        try serving.await(std.testing.io);
    }
}
