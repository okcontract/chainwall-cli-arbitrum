//! Event discovery with bounded RPC ranges and explicit backend selection.
const std = @import("std");
const c = @import("common.zig");
const abi = @import("abi_codec.zig");
const rpc = @import("rpc.zig");
const Explorer = @import("explorer.zig").Explorer;
pub const Sink = @import("log_sink.zig").Sink;
pub const Source = enum { auto, rpc, explorer };
pub const Result = struct { items: []const c.Value, source: []const u8 };

pub fn fetch(remote: *rpc.Rpc, explorer: *Explorer, source: Source, address: []const u8, topic: []const u8, from: u64, to: u64) !Result {
    if (source == .explorer or (source == .auto and explorer.api_key != null)) {
        const items = explorer.logs(address, topic, from, to) catch |err| {
            if (source == .explorer or err == error.OutOfMemory or err == error.Canceled) return err;
            return .{ .items = try rpcLogs(remote, address, topic, from, to), .source = "rpc-logs" };
        };
        return .{ .items = items, .source = "etherscan" };
    }
    return .{ .items = try rpcLogs(remote, address, topic, from, to), .source = "rpc-logs" };
}
pub fn rpcLogs(remote: *rpc.Rpc, address: []const u8, topic: []const u8, from: u64, to: u64) ![]const c.Value {
    const Collector = struct {
        a: c.A,
        values: std.ArrayList(c.Value) = .empty,
        fn consume(raw: *anyopaque, temporary: c.A, values: []const c.Value) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (values.len == 0) return;
            const copied = try c.parse(self.a, try c.encode(temporary, values));
            try self.values.appendSlice(self.a, copied.array.items);
        }
    };
    var collector: Collector = .{ .a = remote.a };
    var sink: Sink = .{ .context = &collector, .consume = Collector.consume };
    try walkRpc(remote, address, topic, from, to, &sink);
    return collector.values.items;
}
pub fn walkRpc(remote: *rpc.Rpc, address: []const u8, topic: []const u8, from: u64, to: u64, sink: *Sink) !void {
    try c.address(address);
    if (topic.len != 66) return error.InvalidEventTopic;
    _ = try c.word(topic);
    if (from > to) return;
    var start = from;
    while (true) {
        const end = start + @min(to - start, 9999);
        try range(remote, address, topic, start, end, sink);
        if (end == to) break;
        start = end + 1;
    }
}
fn query(remote: *rpc.Rpc, address: []const u8, topic: []const u8, from: u64, to: u64) !c.Value {
    const a = remote.a;
    const filter = try c.parse(a, try c.encode(a, .{ .address = address, .topics = .{topic}, .fromBlock = try rpc.quantity(a, from), .toBlock = try rpc.quantity(a, to) }));
    const response = remote.one("eth_getLogs", try abi.array(a, &.{filter})) catch |err| {
        if (err == error.RpcBatchTooLarge or (err == error.RpcRejectedRequest and limitError(a, remote.last_error))) return error.SplitLogRange;
        return err;
    };
    if (response != .array) return error.InvalidRpcLogs;
    if (response.array.items.len >= 10000) return error.SplitLogRange;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (response.array.items) |log| {
        const emitter = try c.string(c.field(log, "address") orelse return error.InvalidRpcLogs);
        const topics = c.field(log, "topics") orelse return error.InvalidRpcLogs;
        const height = try rpc.integer(a, c.field(log, "blockNumber") orelse return error.InvalidRpcLogs);
        const tx = try c.string(c.field(log, "transactionHash") orelse return error.InvalidRpcLogs);
        const hash = try c.string(c.field(log, "blockHash") orelse return error.InvalidRpcLogs);
        const index = try rpc.integer(a, c.field(log, "logIndex") orelse return error.InvalidRpcLogs);
        if (!std.ascii.eqlIgnoreCase(emitter, address) or topics != .array or topics.array.items.len == 0 or !std.ascii.eqlIgnoreCase(try c.string(topics.array.items[0]), topic) or height < from or height > to or tx.len != 66 or hash.len != 66) return error.InvalidRpcLogs;
        _ = try c.word(tx);
        _ = try c.word(hash);
        if (c.field(log, "removed")) |removed| if (removed != .bool or removed.bool) return error.ChainReorganizedRetrySync;
        const identity = try a.print("{s}:{d}", .{ tx, index });
        if (seen.contains(identity)) return error.DuplicateRpcLog;
        try seen.put(a, identity, {});
    }
    return response;
}
fn range(remote: *rpc.Rpc, address: []const u8, topic: []const u8, from: u64, to: u64, sink: *Sink) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const original = remote.a;
    remote.a = arena.allocator();
    defer {
        if (remote.last_error) |failure| remote.last_error = blk: {
            const bytes = c.encode(arena.allocator(), failure) catch break :blk null;
            break :blk c.parse(original, bytes) catch null;
        };
        remote.a = original;
        sink.peak_bytes = @max(sink.peak_bytes, arena.queryCapacity());
    }
    const response = query(remote, address, topic, from, to) catch |err| {
        if (err != error.SplitLogRange) return err;
        if (from == to) return error.RpcSingleBlockLogLimit;
        // Release an oversized page before descending into smaller ranges.
        remote.last_error = null;
        remote.a = original;
        sink.peak_bytes = @max(sink.peak_bytes, arena.queryCapacity());
        _ = arena.reset(.free_all);
        const middle = from + (to - from) / 2;
        try range(remote, address, topic, from, middle, sink);
        try range(remote, address, topic, middle + 1, to, sink);
        return;
    };
    try sink.accept(remote.a, response.array.items);
}
fn limitError(a: c.A, value: ?c.Value) bool {
    const detail = value orelse return false;
    const message = std.ascii.allocLowerString(a, c.string(c.field(detail, "message") orelse .null) catch "") catch return false;
    return std.mem.indexOf(u8, message, "too many results") != null or std.mem.indexOf(u8, message, "range") != null or std.mem.indexOf(u8, message, "response size") != null or std.mem.indexOf(u8, message, "query returned more") != null;
}

test "RPC event discovery splits provider ranges and validates returned logs" {
    const mock = @import("test_rpc.zig");
    const address = "0x1111111111111111111111111111111111111111";
    const hash = "0x1111111111111111111111111111111111111111111111111111111111111111";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const log = .{ .address = address, .topics = .{hash}, .blockNumber = "0x2", .blockHash = hash, .transactionHash = hash, .logIndex = "0x0", .removed = false };
    const replies = [_]mock.Reply{
        .{ .body = "[{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32005,\"message\":\"block range exceeds limit\"}}]", .request_contains = "\"toBlock\": \"0x3\"" },
        .{ .body = "[{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":[]}]", .request_contains = "\"toBlock\": \"0x1\"" },
        .{ .body = try c.encode(a, .{.{ .jsonrpc = "2.0", .id = 1, .result = .{log} }}), .request_contains = "\"fromBlock\": \"0x2\"" },
    };
    var server = try mock.Server.init(std.testing.io, &replies);
    defer server.deinit();
    var serving = try std.testing.io.concurrent(mock.Server.serve, .{&server});
    defer _ = serving.cancel(std.testing.io) catch {};
    var remote = try rpc.Rpc.initEndpoint(a, std.testing.io, try server.url(a), 42161);
    defer remote.deinit();
    remote.timeout_seconds = 1;
    remote.read_attempts = 1;
    var explorer: Explorer = .{ .a = a, .io = std.testing.io, .dir = "", .chain = 42161 };
    const result = try fetch(&remote, &explorer, .auto, address, hash, 0, 3);
    try std.testing.expectEqualStrings("rpc-logs", result.source);
    try std.testing.expectEqual(@as(usize, 1), result.items.len);
    try serving.await(std.testing.io);
    for ([_]bool{ false, true }) |removed| {
        var invalid = try c.parse(a, try c.encode(a, log));
        if (removed) try invalid.object.put(a, "removed", .{ .bool = true }) else try invalid.object.put(a, "blockNumber", .{ .string = "0x4" });
        var bad_server = try mock.Server.init(std.testing.io, &.{.{ .body = try c.encode(a, .{.{ .jsonrpc = "2.0", .id = 1, .result = .{invalid} }}) }});
        defer bad_server.deinit();
        var bad_serving = try std.testing.io.concurrent(mock.Server.serve, .{&bad_server});
        defer _ = bad_serving.cancel(std.testing.io) catch {};
        var bad_remote = try rpc.Rpc.initEndpoint(a, std.testing.io, try bad_server.url(a), 42161);
        defer bad_remote.deinit();
        try std.testing.expectError(if (removed) error.ChainReorganizedRetrySync else error.InvalidRpcLogs, rpcLogs(&bad_remote, address, hash, 0, 3));
        try bad_serving.await(std.testing.io);
    }
}
