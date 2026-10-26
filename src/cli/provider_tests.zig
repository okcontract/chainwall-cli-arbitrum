const std = @import("std");
const c = @import("common.zig");
const rpc = @import("rpc.zig");
const abi = @import("abi_codec.zig");
const mock = @import("test_rpc.zig");
const watch = @import("transaction_watch.zig");
const tx_hash = "0x1111111111111111111111111111111111111111111111111111111111111111";
const block_hash = "0x2222222222222222222222222222222222222222222222222222222222222222";
const next_hash = "0x3333333333333333333333333333333333333333333333333333333333333333";
const sender = "0x1111111111111111111111111111111111111111";
const target = "0x2222222222222222222222222222222222222222";
fn reply(a: c.A, value: anytype) !mock.Reply {
    return .{ .body = try c.encode(a, .{.{ .jsonrpc = "2.0", .id = 1, .result = value }}) };
}

test "HTTP RPC fixtures cover order, partial responses, rate limits and chain disagreement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { response: mock.Reply, err: ?anyerror }{
        .{ .response = .{ .body = "[{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":\"second\"},{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\"first\"}]" }, .err = null },
        .{ .response = try reply(a, "first"), .err = error.InvalidRpcBatch },
        .{ .response = .{ .body = "[{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":null},{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":null}]" }, .err = error.InvalidRpcBatch },
        .{ .response = .{ .body = "[{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":null},{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":{\"code\":-32005,\"message\":\"rate limited\"}}]" }, .err = error.RpcRejectedRequest },
        .{ .response = .{ .body = "rate limited", .status = .too_many_requests }, .err = error.RpcHttpFailure },
    };
    for (cases) |case| {
        var server = try mock.Server.init(std.testing.io, &.{case.response});
        defer server.deinit();
        var serving = try std.testing.io.concurrent(mock.Server.serve, .{&server});
        defer _ = serving.cancel(std.testing.io) catch {};
        var remote = try rpc.Rpc.initEndpoint(a, std.testing.io, try server.url(a), 42161);
        defer remote.deinit();
        remote.read_attempts = 1;
        const request: rpc.Request = .{ .method = "eth_blockNumber", .params = try abi.array(a, &.{}) };
        if (case.err) |err| {
            try std.testing.expectError(err, remote.batch(&.{ request, request }));
        } else {
            const values = try remote.batch(&.{ request, request });
            try std.testing.expectEqualStrings("first", try c.string(values[0]));
            try std.testing.expectEqualStrings("second", try c.string(values[1]));
        }
        try serving.await(std.testing.io);
    }
    var server = try mock.Server.init(std.testing.io, &.{try reply(a, "0x1")});
    defer server.deinit();
    var serving = try std.testing.io.concurrent(mock.Server.serve, .{&server});
    defer _ = serving.cancel(std.testing.io) catch {};
    var remote = try rpc.Rpc.initEndpoint(a, std.testing.io, try server.url(a), 42161);
    defer remote.deinit();
    try std.testing.expectError(error.RpcChainMismatch, remote.pinBlock(null, 0));
    try serving.await(std.testing.io);
}

test "transaction transport fixtures cover pending, failed receipts, replacements and reorganizations" {
    const Scenario = enum { pending, confirmed, reverted, confirming, reorg, receipt_mismatch, repriced, cancelled, replaced };
    inline for (std.meta.tags(Scenario)) |scenario| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const replacement = scenario == .repriced or scenario == .cancelled or scenario == .replaced;
        const pending = scenario == .pending or replacement;
        const tx = .{ .hash = tx_hash, .from = sender, .to = target, .nonce = "0x1", .value = "0x0", .input = "0x12", .blockNumber = "0x64", .blockHash = block_hash, .chainId = "0xa4b1" };
        const receipt = .{ .transactionHash = if (scenario == .receipt_mismatch) next_hash else tx_hash, .blockNumber = "0x64", .blockHash = block_hash, .status = if (scenario == .reverted) "0x0" else "0x1" };
        const head = .{ .number = "0x64", .timestamp = "0x64", .hash = block_hash };
        var replies: std.ArrayList(mock.Reply) = .empty;
        try replies.appendSlice(a, &.{ try reply(a, "0xa4b1"), try reply(a, head) });
        try replies.append(a, .{ .body = try c.encode(a, .{
            .{ .jsonrpc = "2.0", .id = 2, .result = if (pending) c.Value.null else try c.parse(a, try c.encode(a, receipt)) },
            .{ .jsonrpc = "2.0", .id = 1, .result = tx },
        }) });
        if (pending) {
            try replies.append(a, try reply(a, if (replacement) "0x2" else "0x1"));
            if (replacement) {
                const next = .{ .hash = next_hash, .from = sender, .to = if (scenario == .cancelled) sender else target, .nonce = "0x1", .value = "0x0", .input = if (scenario == .cancelled) "0x" else if (scenario == .repriced) "0x12" else "0x34", .blockNumber = "0x64", .blockHash = block_hash, .chainId = "0xa4b1" };
                try replies.append(a, try reply(a, .{ .number = "0x64", .hash = block_hash, .transactions = .{next} }));
                try replies.append(a, try reply(a, .{ .transactionHash = next_hash, .blockNumber = "0x64", .blockHash = block_hash, .status = "0x1" }));
                try replies.append(a, try reply(a, head));
            }
        } else if (scenario != .receipt_mismatch) try replies.append(a, try reply(a, .{ .number = "0x64", .timestamp = "0x64", .hash = if (scenario == .reorg) next_hash else block_hash }));
        if (scenario != .reorg and scenario != .receipt_mismatch) try replies.append(a, try reply(a, head));
        var server = try mock.Server.init(std.testing.io, replies.items);
        defer server.deinit();
        var serving = try std.testing.io.concurrent(mock.Server.serve, .{&server});
        defer _ = serving.cancel(std.testing.io) catch {};
        var remote = try rpc.Rpc.initEndpoint(a, std.testing.io, try server.url(a), 42161);
        defer remote.deinit();
        if (scenario == .reorg or scenario == .receipt_mismatch) {
            try std.testing.expectError(if (scenario == .reorg) error.TransactionReorganized else error.TransactionHashMismatch, watch.observe(&remote, tx_hash, null, 1, 1));
        } else {
            const result = watch.observe(&remote, tx_hash, null, if (scenario == .confirming) 2 else 1, 1) catch |err| {
                std.debug.print("Scenario {s}: {s}\n", .{ @tagName(scenario), @errorName(err) });
                return err;
            };
            try std.testing.expectEqualStrings(@tagName(scenario), try c.string(c.field(result, "status").?));
            if (replacement) try std.testing.expectEqualStrings(next_hash, try c.string(c.field(c.field(result, "replacement").?, "hash").?));
            if (scenario == .cancelled or scenario == .replaced) try std.testing.expectError(error.TransactionPayloadReplaced, watch.verifiedReceipt(result));
        }
        try serving.await(std.testing.io);
        try std.testing.expectEqual(replies.items.len, server.requests);
    }
}

test "read retries are bounded, batches split, and submissions are never retried" {
    const Scenario = enum { recover, exhausted, split, broadcast, rejected, rate_recover };
    inline for (std.meta.tags(Scenario)) |scenario| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const limited: mock.Reply = .{ .body = "busy", .status = .too_many_requests };
        const rate: mock.Reply = .{ .body = "[{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32005,\"message\":\"rate limited\"}}]" };
        const rejection: mock.Reply = .{ .body = "[{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":3,\"message\":\"execution reverted\",\"data\":\"0x1234\"}}]" };
        var replies: std.ArrayList(mock.Reply) = .empty;
        switch (scenario) {
            .recover => try replies.appendSlice(a, &.{ limited, try reply(a, "0xa4b1") }),
            .rate_recover => try replies.appendSlice(a, &.{ rate, try reply(a, "0xa4b1") }),
            .exhausted => try replies.appendSlice(a, &.{ limited, limited, limited }),
            .split => try replies.appendSlice(a, &.{ .{ .body = "batch too large", .status = @fromBackingInt(@intCast(413)) }, try reply(a, "first"), try reply(a, "second") }),
            .broadcast => try replies.append(a, .{ .body = "upstream timeout", .status = .gateway_timeout }),
            .rejected => try replies.append(a, rejection),
        }
        var server = try mock.Server.init(std.testing.io, replies.items);
        defer server.deinit();
        var serving = try std.testing.io.concurrent(mock.Server.serve, .{&server});
        defer _ = serving.cancel(std.testing.io) catch {};
        var remote = try rpc.Rpc.initEndpoint(a, std.testing.io, try server.url(a), 42161);
        defer remote.deinit();
        remote.retry_delay_ms = 0;
        const empty = try abi.array(a, &.{});
        switch (scenario) {
            .recover, .rate_recover => {
                try std.testing.expectEqualStrings("0xa4b1", try c.string(try remote.one("eth_chainId", empty)));
                try std.testing.expect(remote.last_error == null);
            },
            .exhausted => try std.testing.expectError(error.RpcHttpFailure, remote.one("eth_chainId", empty)),
            .split => {
                const request: rpc.Request = .{ .method = "eth_blockNumber", .params = empty };
                const result = try remote.batch(&.{ request, request });
                try std.testing.expectEqualStrings("first", try c.string(result[0]));
                try std.testing.expectEqualStrings("second", try c.string(result[1]));
            },
            .broadcast => try std.testing.expectError(error.RpcSubmissionOutcomeUnknown, remote.one("eth_sendRawTransaction", empty)),
            .rejected => {
                try std.testing.expectError(error.RpcRejectedRequest, remote.one("eth_call", empty));
                try std.testing.expectEqualStrings("0x1234", try c.string(c.field(remote.last_error.?, "data").?));
            },
        }
        try serving.await(std.testing.io);
        try std.testing.expectEqual(replies.items.len, remote.wire_attempts);
    }
}
