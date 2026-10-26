//! Independent contract reads at one canonical block, with per-item errors.
const std = @import("std");
const c = @import("common.zig");
const rpc = @import("rpc.zig");
const abi = @import("abi_codec.zig");
pub const Read = struct { address: []const u8, method: @import("contracts.zig").Method, args: []const c.Value = &.{} };
pub const Outcome = struct {
    value: c.Value = .null,
    err: ?anyerror = null,
    rpc_error: ?c.Value = null,
    pub fn require(o: Outcome) !c.Value {
        if (o.err) |err| return err;
        return o.value;
    }
    pub fn detail(o: Outcome, a: c.A) !c.Value {
        return c.parse(a, try c.encode(a, .{ .code = @errorName(o.err orelse return .null), .rpcError = o.rpc_error }));
    }
};
pub fn read(remote: *rpc.Rpc, reads: []const Read) ![]Outcome {
    const a = remote.a;
    const requests = try a.alloc(rpc.Request, reads.len);
    const selector = try remote.blockSelector();
    for (reads, requests) |item, *request| {
        try c.address(item.address);
        const tx = try c.parse(a, try c.encode(a, .{ .to = item.address, .data = try abi.calldata(a, item.method.abi, try abi.array(a, item.args)) }));
        request.* = .{ .method = "eth_call", .params = try abi.array(a, &.{ tx, selector }) };
    }
    const envelopes = try remote.settled(requests);
    const results = try a.alloc(Outcome, reads.len);
    for (envelopes, reads, results) |envelope, item, *result| {
        if (c.field(envelope, "error")) |failure| {
            result.* = .{ .err = error.RpcRejectedRequest, .rpc_error = failure };
            continue;
        }
        result.* = .{ .value = decode(a, item, c.field(envelope, "result").?) catch |err| {
            if (err == error.OutOfMemory) return err;
            result.* = .{ .err = err };
            continue;
        } };
    }
    return results;
}
fn decode(a: c.A, item: Read, value: c.Value) !c.Value {
    const decoded = try abi.decode(a, c.field(item.method.abi, "outputs").?, try abi.unhex(a, try c.string(value)));
    return abi.namedResult(a, item.method.abi, decoded);
}
test "metadata batch preserves reordered success and individual revert at pinned block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mock = @import("test_rpc.zig");
    var server = try mock.Server.init(std.testing.io, &.{.{ .body = try c.encode(a, .{ .{ .jsonrpc = "2.0", .id = 2, .@"error" = .{ .code = 3, .message = "execution reverted", .data = "0x1234" } }, .{ .jsonrpc = "2.0", .id = 1, .result = try c.hex(a, @as(u256, 7)) } }), .request_contains = "\"requireCanonical\": true" }});
    defer server.deinit();
    var serving = try std.testing.io.concurrent(mock.Server.serve, .{&server});
    defer _ = serving.cancel(std.testing.io) catch {};
    var remote = try rpc.Rpc.initEndpoint(a, std.testing.io, try server.url(a), 42161);
    defer remote.deinit();
    remote.block = .{ .number = 1, .hash = try c.hex(a, @as(u256, 1)), .timestamp = 1 };
    const cat = try @import("contracts.zig").Catalog.load(a);
    const item: Read = .{ .address = "0x1111111111111111111111111111111111111111", .method = try cat.find("registry", "getUserCount") };
    const values = try read(&remote, &.{ item, item });
    try std.testing.expectEqual(7, try c.number(a, try values[0].require()));
    try std.testing.expectError(error.RpcRejectedRequest, values[1].require());
    try std.testing.expectEqualStrings("0x1234", try c.string(c.field(values[1].rpc_error.?, "data").?));
    try serving.await(std.testing.io);
    try std.testing.expectEqual(1, server.requests);
}
