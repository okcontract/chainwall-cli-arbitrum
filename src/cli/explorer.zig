const std = @import("std");
const c = @import("common.zig");

/// Public website links use Etherscan's bundled chain list, independently of
/// authenticated API endpoints. Unsupported chains never inherit Ethereum's URL.
pub fn transactionUrl(a: c.A, chain: u64, hash: []const u8) !?[]const u8 {
    if (hash.len != 66 or !std.mem.startsWith(u8, hash, "0x")) return null;
    for (hash[2..]) |ch| if (!std.ascii.isHex(ch)) return null;
    const catalog = try c.parse(a, @embedFile("etherscan-chains.json"));
    const site = c.field(c.field(catalog, "chains").?, try a.print("{d}", .{chain})) orelse return null;
    return try a.print("{s}/tx/{s}", .{ try c.string(site), hash });
}

pub const Explorer = struct {
    a: c.A,
    io: std.Io,
    dir: []const u8,
    chain: u64,
    api_key: ?[]const u8 = null,
    endpoint: []const u8 = "https://api.etherscan.io/v2/api",
    refresh: bool = false,

    fn request(e: *Explorer, client: *std.http.Client, url: []const u8) !c.Value {
        var attempt: u6 = 0;
        while (true) : (attempt += 1) {
            const buffer = try std.heap.page_allocator.alloc(u8, 32 * 1024 * 1024);
            defer std.heap.page_allocator.free(buffer);
            var body: std.Io.Writer = .fixed(buffer);
            const response = try @import("http.zig").fetch(client, .{ .location = .{ .url = url }, .response_writer = &body, .redirect_behavior = .unhandled });
            const limited = @backingInt(response.status) == 429;
            if (response.status != .ok and !limited) return error.EtherscanHttpFailure;
            const data = if (limited) @as(c.Value, .null) else try c.parse(e.a, body.buffered());
            const reason = try std.ascii.allocLowerString(e.a, c.string(c.field(data, "result") orelse .null) catch "");
            if (limited or std.mem.indexOf(u8, reason, "rate limit") != null or std.mem.indexOf(u8, reason, "too many requests") != null) {
                if (attempt == 4) return error.EtherscanRejectedRequest;
                try std.Io.sleep(e.io, .fromSeconds(@as(i64, 1) << attempt), .awake);
                continue;
            }
            return data;
        }
    }

    /// Discover logs over a closed block range. Pages are never checkpoints:
    /// callers persist only after the complete range and its RPC anchor agree.
    pub fn logs(e: *Explorer, address: []const u8, topic: []const u8, from: u64, to: u64) ![]const c.Value {
        if (from > to) return &.{};
        try c.address(address);
        const key = e.api_key orelse return error.EtherscanTokenRequiredForLogs;
        var client: std.http.Client = .{ .allocator = e.a, .io = e.io };
        defer client.deinit();
        var result: std.ArrayList(c.Value) = .empty;
        try e.logRange(&client, key, address, topic, from, to, &result);
        return result.items;
    }
    fn logRange(e: *Explorer, client: *std.http.Client, key: []const u8, address: []const u8, topic: []const u8, from: u64, to: u64, result: *std.ArrayList(c.Value)) anyerror!void {
        const start = result.items.len;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        for (1..11) |page| {
            const url = try e.a.print("{s}{s}chainid={d}&module=logs&action=getLogs&address={s}&topic0={s}&fromBlock={d}&toBlock={d}&page={d}&offset=1000&apikey={s}", .{ e.endpoint, if (std.mem.indexOfScalar(u8, e.endpoint, '?') == null) "?" else "&", e.chain, address, topic, from, to, page, try escape(e.a, key) });
            const data = try e.request(client, url);
            const status = try c.string(c.field(data, "status") orelse return error.InvalidExplorerResponse);
            const items = c.field(data, "result") orelse return error.InvalidExplorerResponse;
            if (!c.eq(u8, status, "1")) {
                const message = c.string(c.field(data, "message") orelse .null) catch "";
                if (c.eq(u8, status, "0") and c.eq(u8, message, "No records found") and items == .array and items.array.items.len == 0) return;
                const reason = c.string(items) catch "";
                if (std.mem.indexOf(u8, reason, "Query Timeout") != null or std.mem.indexOf(u8, reason, "Result window is too large") != null) {
                    result.shrinkRetainingCapacity(start);
                    return e.splitLogs(client, key, address, topic, from, to, result);
                }
                return error.EtherscanRejectedRequest;
            }
            if (items != .array or items.array.items.len > 1000) return error.InvalidExplorerResponse;
            for (items.array.items) |item| {
                const emitter = try c.string(c.field(item, "address") orelse return error.InvalidExplorerResponse);
                const topics = c.field(item, "topics") orelse return error.InvalidExplorerResponse;
                const height = try c.number(e.a, c.field(item, "blockNumber") orelse return error.InvalidExplorerResponse);
                if (!std.ascii.eqlIgnoreCase(emitter, address) or topics != .array or topics.array.items.len < 2 or !std.ascii.eqlIgnoreCase(try c.string(topics.array.items[0]), topic) or height < from or height > to) return error.InvalidExplorerResponse;
                const tx = try c.string(c.field(item, "transactionHash") orelse return error.InvalidExplorerResponse);
                if (tx.len != 66) return error.InvalidExplorerResponse;
                const index = try c.number(e.a, c.field(item, "logIndex") orelse return error.InvalidExplorerResponse);
                const identity = try e.a.print("{s}:{d}", .{ tx, index });
                if (seen.contains(identity)) return error.ExplorerPaginationDidNotAdvance;
                try seen.put(e.a, identity, {});
                try result.append(e.a, item);
            }
            if (items.array.items.len < 1000) return;
        }
        // Explorer plans may cap a query at 10,000 results. Subdivide before
        // reaching that cap rather than silently accepting truncated history.
        result.shrinkRetainingCapacity(start);
        return e.splitLogs(client, key, address, topic, from, to, result);
    }
    fn splitLogs(e: *Explorer, client: *std.http.Client, key: []const u8, address: []const u8, topic: []const u8, from: u64, to: u64, result: *std.ArrayList(c.Value)) anyerror!void {
        if (from == to) return error.ExplorerSingleBlockLogLimit;
        const mid = from + (to - from) / 2;
        try e.logRange(client, key, address, topic, from, mid, result);
        try e.logRange(client, key, address, topic, mid + 1, to, result);
    }

    fn abiPath(e: *Explorer, address: []const u8) ![]const u8 {
        return e.a.print("{s}/abi/{d}/{s}.json", .{ e.dir, e.chain, address });
    }

    /// Cache-only lookup for offline CLI/LSP consumers. Proxy mappings may be
    /// stale, but their old merged ABI payloads must never be used.
    pub fn cachedAbi(e: *Explorer, address: []const u8) !?c.Value {
        return e.resolveAbi(address, false);
    }

    pub fn abi(e: *Explorer, address: []const u8) !c.Value {
        return (try e.resolveAbi(address, true)) orelse error.EtherscanTokenRequiredOrSupplyAbi;
    }

    const AbiCacheEntry = struct {
        address: []const u8,
        implementation: []const u8,
        abi: ?c.Value = null,
    };

    fn saveAbis(e: *Explorer, entries: []const AbiCacheEntry, now: i64) !void {
        // Write the implementation before publishing mappings that depend on it.
        var index = entries.len;
        while (index > 0) {
            index -= 1;
            const entry = entries[index];
            try c.write(e.io, try e.abiPath(entry.address), try c.encode(e.a, .{
                .address = entry.address,
                .chainId = e.chain,
                .fetchedAt = now,
                .implementation = entry.implementation,
                .abi = entry.abi,
            }), true);
        }
    }

    fn resolveAbi(e: *Explorer, address: []const u8, network: bool) !?c.Value {
        try c.address(address);
        var current = try std.ascii.allocLowerString(e.a, address);
        const now = std.Io.Clock.real.now(e.io).toSeconds();
        var visited: std.StringHashMapUnmanaged(void) = .empty;
        var pending: std.ArrayList(AbiCacheEntry) = .empty;
        var client: std.http.Client = .{ .allocator = e.a, .io = e.io };
        defer client.deinit();
        for (0..8) |_| {
            if (visited.contains(current)) return error.ProxyImplementationCycle;
            try visited.put(e.a, current, {});
            if (!network or !e.refresh) {
                if (c.read(e.a, e.io, try e.abiPath(current))) |bytes| {
                    const cached = try c.parse(e.a, bytes);
                    if (try c.number(e.a, c.field(cached, "chainId") orelse return error.InvalidAbiCache) != e.chain or !std.ascii.eqlIgnoreCase(try c.string(c.field(cached, "address") orelse return error.InvalidAbiCache), current)) return error.InvalidAbiCache;
                    const implementation = if (c.field(cached, "implementation")) |value| try c.string(value) else current;
                    try c.address(implementation);
                    if (!std.ascii.eqlIgnoreCase(implementation, current)) {
                        const saved = try c.number(e.a, c.field(cached, "fetchedAt") orelse return error.InvalidAbiCache);
                        // ABI contents persist; only upgradeable mappings expire.
                        // Offline consumers deliberately use the last known mapping.
                        if (!network or e.api_key == null or (now >= 0 and saved <= @as(u256, @intCast(now)) and @as(u256, @intCast(now)) - saved < 86400)) {
                            current = try std.ascii.allocLowerString(e.a, implementation);
                            continue;
                        }
                    } else {
                        const value = c.field(cached, "abi") orelse return error.InvalidAbiCache;
                        if (value != .array) return error.InvalidAbiCache;
                        try e.saveAbis(pending.items, now);
                        return value;
                    }
                } else |err| if (err != error.FileNotFound) return err;
            }
            if (!network) return null;
            const key = e.api_key orelse return error.EtherscanTokenRequiredOrSupplyAbi;
            const url = try e.a.print("{s}{s}chainid={d}&module=contract&action=getsourcecode&address={s}&apikey={s}", .{ e.endpoint, if (std.mem.indexOfScalar(u8, e.endpoint, '?') == null) "?" else "&", e.chain, current, try escape(e.a, key) });
            // Do not forward an API token across redirects. Error messages only
            // identify the operation, never the URL or token.
            const data = try e.request(&client, url);
            if (!c.eq(u8, c.string(c.field(data, "status") orelse return error.InvalidExplorerResponse) catch "", "1")) return error.EtherscanRejectedRequest;
            const result = c.field(data, "result") orelse return error.InvalidExplorerResponse;
            if (result != .array or result.array.items.len != 1) return error.InvalidExplorerResponse;
            const contract = result.array.items[0];
            const implementation = if (c.field(contract, "Implementation")) |value| try c.string(value) else "";
            if (implementation.len != 0 and !(implementation.len == 42 and try c.word(implementation) == 0)) {
                try c.address(implementation);
                const next = try std.ascii.allocLowerString(e.a, implementation);
                try pending.append(e.a, .{ .address = current, .implementation = next });
                current = next;
                continue;
            }
            const raw = try c.string(c.field(contract, "ABI") orelse return error.ContractNotVerified);
            const value = c.parse(e.a, raw) catch return error.ContractNotVerified;
            if (value != .array) return error.InvalidAbi;
            try pending.append(e.a, .{ .address = current, .implementation = current, .abi = value });
            try e.saveAbis(pending.items, now);
            return value;
        }
        return error.TooManyProxyImplementations;
    }
};
fn escape(a: c.A, value: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "-._~", byte) != null) try out.writer.writeByte(byte) else try out.writer.print("%{X:0>2}", .{byte});
    }
    return out.toOwnedSlice();
}

test "transaction links use the matching Etherscan website or no link" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const hash = "0x" ++ std.mem.asBytes(&@as([32][2]u8, @splat("12".*))).*;
    try std.testing.expectEqualStrings("https://etherscan.io/tx/" ++ hash, (try transactionUrl(a, 1, hash)).?);
    try std.testing.expectEqualStrings("https://basescan.org/tx/" ++ hash, (try transactionUrl(a, 8453, hash)).?);
    try std.testing.expectEqualStrings("https://sepolia.basescan.org/tx/" ++ hash, (try transactionUrl(a, 84532, hash)).?);
    try std.testing.expectEqualStrings("https://snowscan.xyz/tx/" ++ hash, (try transactionUrl(a, 43114, hash)).?);
    try std.testing.expect(try transactionUrl(a, 31337, hash) == null);
    try std.testing.expect(try transactionUrl(a, 999999999, hash) == null);
    try std.testing.expect(try transactionUrl(a, 1, "0x123") == null);
    try std.testing.expect(try transactionUrl(a, 1, "0x" ++ @as([64]u8, @splat('z'))) == null);
}
