const std = @import("std");
const c = @import("common.zig");
const abi = @import("abi_codec.zig");
const contracts = @import("contracts.zig");

pub const Block = struct { number: u64, hash: []const u8, timestamp: u64 };
pub const Request = struct { method: []const u8, params: c.Value };
pub const Call = struct { method: contracts.Method, args: c.Value };
pub const Rpc = struct {
    a: c.A,
    client: std.http.Client,
    url: []const u8,
    chain: u64,
    address: []const u8,
    block: Block = undefined,
    requests: usize = 0,
    last_error: ?c.Value = null,
    reported_chain: ?u64 = null,
    timeout_seconds: u32 = 60,
    read_attempts: u8 = 3,
    retry_delay_ms: u32 = 100,
    wire_attempts: usize = 0,

    pub fn init(a: c.A, io: std.Io, url: []const u8, chain: u64, address: []const u8) !Rpc {
        try c.address(address);
        var r = try initEndpoint(a, io, url, chain);
        r.address = address;
        return r;
    }
    pub fn initEndpoint(a: c.A, io: std.Io, url: []const u8, chain: u64) !Rpc {
        if (url.len == 0) return error.RpcUrlRequired;
        return .{ .a = a, .client = .{ .allocator = std.heap.page_allocator, .io = io }, .url = url, .chain = chain, .address = "" };
    }
    pub fn deinit(r: *Rpc) void {
        r.client.deinit();
    }
    pub fn batch(r: *Rpc, requests: []const Request) ![]const c.Value {
        return r.batchMode(requests, false);
    }
    /// Returns ordered JSON-RPC envelopes, including per-item errors. Only read
    /// methods are allowed; malformed batch framing remains a process error.
    pub fn settled(r: *Rpc, requests: []const Request) ![]const c.Value {
        for (requests) |request| if (!readMethod(request.method)) return error.ReadOnlyBatchRequired;
        return r.batchMode(requests, true);
    }
    fn batchMode(r: *Rpc, requests: []const Request, envelopes: bool) ![]const c.Value {
        r.last_error = null;
        const values = try r.a.alloc(c.Value, requests.len);
        var start: usize = 0;
        while (start < requests.len) {
            const end = @min(start + 100, requests.len);
            try r.chunk(requests[start..end], values[start..end], envelopes);
            start = end;
        }
        return values;
    }
    fn chunk(r: *Rpc, requests: []const Request, values: []c.Value, envelopes: bool) anyerror!void {
        var read_only = true;
        for (requests) |request| if (!readMethod(request.method)) {
            read_only = false;
            break;
        };
        var attempt: u8 = 0;
        while (true) : (attempt += 1) {
            r.exchange(requests, values, envelopes) catch |err| {
                if (read_only and requests.len > 1 and err == error.RpcBatchTooLarge) {
                    const middle = requests.len / 2;
                    try r.chunk(requests[0..middle], values[0..middle], envelopes);
                    try r.chunk(requests[middle..], values[middle..], envelopes);
                    return;
                }
                if (read_only and attempt + 1 < @max(1, @min(r.read_attempts, 5)) and transient(err)) {
                    try std.Io.sleep(r.client.io, .fromMilliseconds(@as(i64, r.retry_delay_ms) * (@as(i64, 1) << @intCast(attempt))), .awake);
                    continue;
                }
                // A transport/server failure cannot prove a broadcast was rejected.
                if (!read_only and (transient(err) or err == error.InvalidRpcBatch)) return error.RpcSubmissionOutcomeUnknown;
                return if (err == error.RpcTransientHttpFailure) error.RpcHttpFailure else if (err == error.RpcRateLimited) error.RpcRejectedRequest else err;
            };
            r.last_error = null;
            r.requests += requests.len;
            return;
        }
    }
    fn exchange(r: *Rpc, requests: []const Request, values: []c.Value, envelopes: bool) !void {
        var scratch = std.heap.ArenaAllocator.init(r.a);
        defer scratch.deinit();
        const a = scratch.allocator();
        var items = std.json.Array.init(a);
        for (requests, 0..) |request, i| try items.append(try c.parse(a, try c.encode(a, .{ .jsonrpc = "2.0", .id = i + 1, .method = request.method, .params = request.params })));
        const buffer = try std.heap.page_allocator.alloc(u8, 32 * 1024 * 1024);
        defer std.heap.page_allocator.free(buffer);
        var body: std.Io.Writer = .fixed(buffer);
        r.wire_attempts += 1;
        const response = try @import("http.zig").fetchWithTimeout(&r.client, .{ .location = .{ .url = r.url }, .method = .POST, .payload = try c.encode(a, c.Value{ .array = items }), .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }}, .response_writer = &body, .redirect_behavior = .unhandled }, r.timeout_seconds);
        const status = @backingInt(response.status);
        if (status == 413) return error.RpcBatchTooLarge;
        if (status == 408 or status == 429 or status == 500 or status == 502 or status == 503 or status == 504) return error.RpcTransientHttpFailure;
        if (response.status != .ok) return error.RpcHttpFailure;
        const decoded = try c.parse(a, body.buffered());
        const responses = if (decoded == .array) decoded.array.items else &.{decoded};
        for (responses) |item| if (c.field(item, "error")) |failure| {
            if (envelopes and (c.field(item, "id") orelse .null) != .null) continue;
            r.last_error = try @import("revert_errors.zig").enrich(r.a, try c.parse(r.a, try c.encode(a, failure)));
            const message = try std.ascii.allocLowerString(a, c.string(c.field(failure, "message") orelse .null) catch "");
            if (std.mem.indexOf(u8, message, "batch") != null and (std.mem.indexOf(u8, message, "limit") != null or std.mem.indexOf(u8, message, "large") != null or std.mem.indexOf(u8, message, "many") != null)) return error.RpcBatchTooLarge;
            if (std.mem.indexOf(u8, message, "rate limit") != null or std.mem.indexOf(u8, message, "too many requests") != null or std.mem.indexOf(u8, message, "temporarily unavailable") != null) return error.RpcRateLimited;
            return error.RpcRejectedRequest;
        };
        // Copy only a successful response into the caller's result allocator.
        try orderMode(a, decoded, values, envelopes);
        for (values) |*value| value.* = try c.parse(r.a, try c.encode(a, value.*));
    }
    pub fn one(r: *Rpc, method: []const u8, params: c.Value) !c.Value {
        return (try r.batch(&.{.{ .method = method, .params = params }}))[0];
    }
    pub fn verifyLogs(r: *Rpc, logs: []const c.Value) !void {
        var blocks: std.AutoArrayHashMapUnmanaged(u64, []const u8) = .empty;
        for (logs) |log| {
            const number = try integer(r.a, c.field(log, "blockNumber") orelse return error.InvalidExplorerResponse);
            const hash = try c.string(c.field(log, "blockHash") orelse return error.InvalidExplorerResponse);
            if (number > r.block.number or hash.len != 66) return error.InvalidExplorerResponse;
            if (blocks.get(number)) |previous| if (!std.ascii.eqlIgnoreCase(previous, hash)) return error.ExplorerBlockMismatch;
            try blocks.put(r.a, number, hash);
        }
        const requests = try r.a.alloc(Request, blocks.count());
        for (requests, blocks.keys()) |*request, number| request.* = .{ .method = "eth_getBlockByNumber", .params = try abi.array(r.a, &.{ .{ .string = try quantity(r.a, number) }, .{ .bool = false } }) };
        for (try r.batch(requests), blocks.values()) |block, expected| {
            const hash = try c.string(c.field(block, "hash") orelse return error.ExplorerBlockMismatch);
            if (!std.ascii.eqlIgnoreCase(hash, expected)) return error.ExplorerBlockMismatch;
        }
    }
    pub fn blockAt(r: *Rpc, selector: []const u8) !Block {
        const value = try r.one("eth_getBlockByNumber", try abi.array(r.a, &.{ .{ .string = selector }, .{ .bool = false } }));
        return .{ .number = try integer(r.a, c.field(value, "number") orelse return error.BlockUnavailable), .hash = try c.string(c.field(value, "hash") orelse return error.BlockUnavailable), .timestamp = try integer(r.a, c.field(value, "timestamp") orelse return error.BlockUnavailable) };
    }
    pub fn pin(r: *Rpc, selector: ?[]const u8, confirmations: u64) !void {
        try r.pinBlock(selector, confirmations);
        const code = try r.one("eth_getCode", try abi.array(r.a, &.{ .{ .string = r.address }, try r.blockSelector() }));
        if ((try c.string(code)).len <= 2) return error.InstanceHasNoCode;
    }
    pub fn pinBlock(r: *Rpc, selector: ?[]const u8, confirmations: u64) !void {
        const chain = try r.one("eth_chainId", try abi.array(r.a, &.{}));
        r.reported_chain = try integer(r.a, chain);
        if (r.reported_chain.? != r.chain) return error.RpcChainMismatch;
        const selected = selector orelse "latest";
        var block = try r.blockAt(if (selected.len > 0 and std.ascii.isDigit(selected[0]) and !std.mem.startsWith(u8, selected, "0x")) try quantity(r.a, try std.fmt.parseInt(u64, selected, 10)) else selected);
        if (confirmations > 0) {
            if (selector != null) return error.ConflictingBlockOptions;
            if (confirmations > block.number) return error.BlockUnavailable;
            block = try r.blockAt(try quantity(r.a, block.number - confirmations));
        }
        r.block = block;
    }
    pub fn canonical(r: *Rpc, block: Block) !bool {
        const now = r.blockAt(try quantity(r.a, block.number)) catch |err| {
            if (err == error.BlockUnavailable) return false;
            return err;
        };
        return std.ascii.eqlIgnoreCase(now.hash, block.hash);
    }
    pub fn blockSelector(r: *Rpc) !c.Value {
        return c.parse(r.a, try c.encode(r.a, .{ .blockHash = r.block.hash, .requireCanonical = true }));
    }
    pub fn calls(r: *Rpc, calls_: []const Call) ![]const c.Value {
        const requests = try r.a.alloc(Request, calls_.len);
        const selector = try r.blockSelector();
        for (calls_, requests) |item, *request| {
            const transaction = try c.parse(r.a, try c.encode(r.a, .{ .to = r.address, .data = try abi.calldata(r.a, item.method.abi, item.args) }));
            request.* = .{ .method = "eth_call", .params = try abi.array(r.a, &.{ transaction, selector }) };
        }
        const raw = try r.batch(requests);
        for (raw, calls_, 0..) |value, item, i| {
            const bytes = try abi.unhex(r.a, try c.string(value));
            const decoded = try abi.decode(r.a, c.field(item.method.abi, "outputs").?, bytes);
            requests[i].params = decoded;
        }
        const result = try r.a.alloc(c.Value, calls_.len);
        for (requests, result) |request, *value| value.* = request.params;
        return result;
    }
    pub fn call(r: *Rpc, method: contracts.Method, args: []const c.Value) !c.Value {
        return (try r.calls(&.{.{ .method = method, .args = try abi.array(r.a, args) }}))[0];
    }
    pub fn namedAt(r: *Rpc, address: []const u8, method: contracts.Method, args: []const c.Value) !c.Value {
        try c.address(address);
        const previous = r.address;
        r.address = address;
        defer r.address = previous;
        return abi.namedResult(r.a, method.abi, try r.call(method, args));
    }
};
pub fn quantity(a: c.A, n: u64) ![]const u8 {
    return a.print("0x{x}", .{n});
}
pub fn integer(a: c.A, value: c.Value) !u64 {
    return std.math.cast(u64, try c.number(a, value)) orelse error.IndexTooLarge;
}
fn orderResponses(a: c.A, decoded: c.Value, values: []c.Value) !void {
    return orderMode(a, decoded, values, false);
}
fn orderMode(a: c.A, decoded: c.Value, values: []c.Value, envelopes: bool) !void {
    if (decoded != .array or decoded.array.items.len != values.len) return error.InvalidRpcBatch;
    const seen = try a.alloc(bool, values.len);
    @memset(seen, false);
    for (decoded.array.items) |item| {
        if (!c.eq(u8, try c.string(c.field(item, "jsonrpc") orelse return error.InvalidRpcBatch), "2.0")) return error.InvalidRpcBatch;
        const id = try integer(a, c.field(item, "id") orelse return error.InvalidRpcBatch);
        if (id == 0 or id > values.len or seen[id - 1]) return error.InvalidRpcBatch;
        const failure = c.field(item, "error");
        const result = c.field(item, "result");
        if ((failure == null) == (result == null)) return error.InvalidRpcBatch;
        if (!envelopes and failure != null) return error.RpcRejectedRequest;
        values[id - 1] = if (envelopes) item else result.?;
        seen[id - 1] = true;
    }
}

test "JSON RPC batch responses reorder by ID and reject duplicates and errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var values: [2]c.Value = undefined;
    try orderResponses(a, try c.parse(a, "[{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":\"b\"},{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\"a\"}]"), &values);
    try std.testing.expectEqualStrings("a", try c.string(values[0]));
    try std.testing.expectError(error.InvalidRpcBatch, orderResponses(a, try c.parse(a, "[{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":0},{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":0}]"), &values));
    try std.testing.expectError(error.RpcRejectedRequest, orderResponses(a, try c.parse(a, "[{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{}}]"), values[0..1]));
}

test "RPC contract failures keep provider payloads alongside decoded details" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mock = @import("test_rpc.zig");
    const failure = .{ .code = -32000, .message = "execution reverted", .data = "0xbed8168a" };
    var server = try mock.Server.init(std.testing.io, &.{.{ .body = try c.encode(a, .{.{ .jsonrpc = "2.0", .id = 1, .@"error" = failure }}) }});
    defer server.deinit();
    var serving = try std.testing.io.concurrent(mock.Server.serve, .{&server});
    defer _ = serving.cancel(std.testing.io) catch {};
    var remote = try Rpc.initEndpoint(a, std.testing.io, try server.url(a), 42161);
    defer remote.deinit();
    try std.testing.expectError(error.RpcRejectedRequest, remote.one("eth_call", try abi.array(a, &.{})));
    const result = remote.last_error.?;
    try std.testing.expectEqualStrings(failure.data, try c.string(c.field(result, "data").?));
    try std.testing.expectEqualStrings(failure.message, try c.string(c.field(result, "message").?));
    try std.testing.expectEqualStrings("InvalidFeedConfiguration", try c.string(c.field(c.field(result, "detail").?, "name").?));
    try serving.await(std.testing.io);
    try std.testing.expectEqual(@as(usize, 1), server.requests);
}

fn readMethod(method: []const u8) bool {
    for ([_][]const u8{ "eth_call", "eth_estimateGas", "eth_chainId", "eth_blockNumber", "eth_gasPrice", "eth_maxPriorityFeePerGas", "eth_getBalance", "eth_getCode", "eth_getStorageAt", "eth_getBlockByNumber", "eth_getBlockByHash", "eth_getTransactionByHash", "eth_getTransactionReceipt", "eth_getTransactionCount", "eth_getLogs", "eth_getUserOperationReceipt", "eth_getUserOperationByHash", "eth_feeHistory" }) |name| if (c.eq(u8, method, name)) return true;
    return false;
}
fn transient(err: anyerror) bool {
    return switch (err) {
        error.RpcTransientHttpFailure, error.RpcRateLimited, error.HttpRequestTimeout, error.ConnectionResetByPeer, error.ConnectionTimedOut, error.ConnectionRefused, error.ConnectionClosed, error.HttpConnectionClosing, error.TemporaryNameServerFailure, error.ReadFailed, error.WriteFailed, error.EndOfStream => true,
        else => false,
    };
}
