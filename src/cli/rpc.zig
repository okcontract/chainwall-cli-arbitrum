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
    timeout_seconds: u32 = 60,

    pub fn init(a: c.A, io: std.Io, url: []const u8, chain: u64, address: []const u8) !Rpc {
        try c.address(address);
        var r = try initEndpoint(a, io, url, chain);
        r.address = address;
        return r;
    }
    pub fn initEndpoint(a: c.A, io: std.Io, url: []const u8, chain: u64) !Rpc {
        if (url.len == 0) return error.RpcUrlRequired;
        return .{ .a = a, .client = .{ .allocator = a, .io = io }, .url = url, .chain = chain, .address = "" };
    }
    pub fn deinit(r: *Rpc) void {
        r.client.deinit();
    }
    pub fn batch(r: *Rpc, requests: []const Request) ![]const c.Value {
        r.last_error = null;
        const values = try r.a.alloc(c.Value, requests.len);
        var start: usize = 0;
        while (start < requests.len) {
            const end = @min(start + 100, requests.len);
            var items = std.json.Array.init(r.a);
            for (requests[start..end], 0..) |request, i| try items.append(try c.parse(r.a, try c.encode(r.a, .{ .jsonrpc = "2.0", .id = i + 1, .method = request.method, .params = request.params })));
            const buffer = try std.heap.page_allocator.alloc(u8, 32 * 1024 * 1024);
            defer std.heap.page_allocator.free(buffer);
            var body: std.Io.Writer = .fixed(buffer);
            const response = try @import("http.zig").fetchWithTimeout(&r.client, .{ .location = .{ .url = r.url }, .method = .POST, .payload = try c.encode(r.a, c.Value{ .array = items }), .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }}, .response_writer = &body, .redirect_behavior = .unhandled }, r.timeout_seconds);
            if (response.status != .ok) return error.RpcHttpFailure;
            const decoded = try c.parse(r.a, body.buffered());
            if (decoded == .array) for (decoded.array.items) |item| {
                if (c.field(item, "error")) |failure| {
                    r.last_error = failure;
                    break;
                }
            };
            try orderResponses(r.a, decoded, values[start..end]);
            r.requests += end - start;
            start = end;
        }
        return values;
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
        if (try integer(r.a, chain) != r.chain) return error.RpcChainMismatch;
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
    if (decoded != .array or decoded.array.items.len != values.len) return error.InvalidRpcBatch;
    const seen = try a.alloc(bool, values.len);
    @memset(seen, false);
    for (decoded.array.items) |item| {
        if (!c.eq(u8, try c.string(c.field(item, "jsonrpc") orelse return error.InvalidRpcBatch), "2.0")) return error.InvalidRpcBatch;
        const id = try integer(a, c.field(item, "id") orelse return error.InvalidRpcBatch);
        if (id == 0 or id > values.len or seen[id - 1]) return error.InvalidRpcBatch;
        if (c.field(item, "error") != null) return error.RpcRejectedRequest;
        values[id - 1] = c.field(item, "result") orelse return error.InvalidRpcBatch;
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
