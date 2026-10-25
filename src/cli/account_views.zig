const std = @import("std");
const c = @import("common.zig");
const abi = @import("abi_codec.zig");
const contracts = @import("contracts.zig");
const rpc = @import("rpc.zig");
const Cast = @import("cast.zig").Cast;
const Args = @import("args.zig").Args;
const config = @import("config.zig");

fn read(remote: *rpc.Rpc, cat: contracts.Catalog, address: []const u8, name: []const u8, values: []const c.Value) !c.Value {
    return remote.namedAt(address, try cat.find("registry", name), values);
}
fn canonical(remote: *rpc.Rpc) !void {
    if (!try remote.canonical(remote.block)) return error.ChainReorganizedRetrySync;
}
fn number(args: *Args, key: []const u8, default: []const u8) !u64 {
    return std.fmt.parseInt(u64, args.get(key) orelse default, 10);
}
fn optionalNumber(a: c.A, value: ?u64) !c.Value {
    return if (value) |n| .{ .number_string = try a.print("{d}", .{n}) } else .null;
}
fn decimals(a: c.A, amount: u256, places: usize) ![]const u8 {
    if (places > 255) return error.InvalidDecimals;
    const digits = try a.print("{d}", .{amount});
    if (places == 0) return digits;
    var out: std.Io.Writer.Allocating = .init(a);
    if (digits.len > places) try out.writer.print("{s}.{s}", .{ digits[0 .. digits.len - places], digits[digits.len - places ..] }) else {
        try out.writer.writeAll("0.");
        try out.writer.splatByteAll('0', places - digits.len);
        try out.writer.writeAll(digits);
    }
    const text = out.written();
    var end = text.len;
    while (end > 0 and text[end - 1] == '0') end -= 1;
    if (text[end - 1] == '.') end -= 1;
    return text[0..end];
}
fn failure(remote: *rpc.Rpc, err: anyerror) !c.Value {
    if (err == error.OutOfMemory) return err;
    return c.parse(remote.a, try c.encode(remote.a, .{ .code = @errorName(err), .rpcError = remote.last_error }));
}
fn price(remote: *rpc.Rpc, cat: contracts.Catalog, registry: []const u8, row: *c.Value, hash: ?c.Value, amount: c.Value, age: u64) !void {
    const a = remote.a;
    const values: []const c.Value = if (hash) |h| &.{ h, amount, try abi.uint(a, age) } else &.{ amount, try abi.uint(a, age) };
    const value = read(remote, cat, registry, if (hash != null) "getTokenUsdValue18Ceil" else "getNativeUsdValue18Ceil", values) catch |err| {
        try row.object.put(a, "priceError", try failure(remote, err));
        return;
    };
    const raw = read(remote, cat, registry, if (hash != null) "getTokenUsdPriceRaw" else "getNativeUsdPriceRaw", if (hash) |h| &.{h} else &.{}) catch |err| {
        try row.object.put(a, "priceError", try failure(remote, err));
        return;
    };
    try row.object.put(a, "usdValue18", value);
    try row.object.put(a, "usdValue", .{ .string = try decimals(a, try c.number(a, value), 18) });
    try row.object.put(a, "price", raw);
    try row.object.put(a, "priceUsd", .{ .string = try decimals(a, try c.number(a, c.field(raw, "answer").?), @intCast(try c.number(a, c.field(raw, "decimals").?))) });
}
fn token(remote: *rpc.Rpc, cat: contracts.Catalog, aux: contracts.Catalog, registry: []const u8, account: []const u8, hash: c.Value, age: u64) !c.Value {
    const a = remote.a;
    var row = try c.parse(a, try c.encode(a, .{ .kind = "erc20", .hash = hash, .balance = @as(c.Value, .null), .usdValue18 = @as(c.Value, .null) }));
    const meta = try read(remote, cat, registry, "getTokenByHash", &.{hash});
    if ((try c.string(c.field(meta, "id").?)).len == 0) return error.TokenMissing;
    try row.object.put(a, "metadata", meta);
    const contract = try read(remote, cat, registry, "getContractByHash", &.{hash});
    const address = try c.string(c.field(c.field(contract, "latest").?, "addr").?);
    if (try c.word(address) == 0) return error.TokenContractMissing;
    try row.object.put(a, "address", .{ .string = address });
    const amount = remote.namedAt(address, try aux.find("erc20", "balanceOf"), &.{.{ .string = account }}) catch |err| {
        try row.object.put(a, "balanceError", try failure(remote, err));
        return row;
    };
    try row.object.put(a, "balance", amount);
    try row.object.put(a, "balanceFormatted", .{ .string = try decimals(a, try c.number(a, amount), @intCast(try c.number(a, c.field(meta, "decimals").?))) });
    try price(remote, cat, registry, &row, hash, amount, age);
    return row;
}

pub fn assets(cast: *Cast, cat: contracts.Catalog, args: *Args, account: []const u8) !c.Value {
    const a = cast.a;
    try c.address(account);
    const start = try number(args, "start", "0");
    const count = try number(args, "count", "20");
    const age = try number(args, "max-age", "3600");
    const out = args.get("out");
    if (count == 0 or count > 100 or age == 0) return error.InvalidAccountViewLimit;
    var explicit = std.StringArrayHashMapUnmanaged(void){};
    while (args.get("token-id")) |id| try explicit.put(a, try c.id(a, id), {});
    if (explicit.count() > 1000) return error.InvalidAccountViewLimit;
    try args.finish();
    const aux = try contracts.Catalog.loadAuxiliary(a);
    var remote = try rpc.Rpc.init(a, cast.io, cast.rpc, cast.chain, cast.instance);
    defer remote.deinit();
    try remote.pin(cast.block, 0);
    var discovery: []const u8 = "explicit";
    var total: u64 = explicit.count();
    var keys = std.json.Array.init(a);
    if (explicit.count() > 0) {
        for (explicit.keys()[@min(start, total)..@min(total, start +| count)]) |id| try keys.append(.{ .string = id });
    } else {
        // Token catalog indexes are always maintained; the Registry flag only
        // controls timelock history, independently of Interact execution history.
        discovery = "registry-index";
        total = try rpc.integer(a, try read(&remote, cat, cast.instance, "getTokenCount", &.{}));
        const wanted = @min(count, total -| start);
        if (wanted > 0) keys = (try read(&remote, cat, cast.instance, "getTokenKeysPage", &.{ try abi.uint(a, start), try abi.uint(a, wanted) })).array;
        if (keys.items.len != wanted) return error.ShortIndexPage;
    }

    var rows = std.json.Array.init(a);
    if (start == 0) {
        const amount = try abi.uint(a, try c.number(a, try remote.one("eth_getBalance", try abi.array(a, &.{ .{ .string = account }, try remote.blockSelector() }))));
        var native = try c.parse(a, try c.encode(a, .{ .kind = "native", .decimals = 18, .balance = amount, .balanceFormatted = try decimals(a, try c.number(a, amount), 18), .usdValue18 = @as(c.Value, .null) }));
        const feed = read(&remote, cat, cast.instance, "getNativeUsdFeedConfig", &.{}) catch |err| blk: {
            try native.object.put(a, "feedError", try failure(&remote, err));
            break :blk c.Value.null;
        };
        try native.object.put(a, "feed", feed);
        try price(&remote, cat, cast.instance, &native, null, amount, age);
        try rows.append(native);
    }
    for (keys.items) |hash| try rows.append(token(&remote, cat, aux, cast.instance, account, hash, age) catch |err| try c.parse(a, try c.encode(a, .{ .kind = "erc20", .hash = hash, .balance = @as(c.Value, .null), .usdValue18 = @as(c.Value, .null), .@"error" = try failure(&remote, err) })));
    var subtotal: u256 = 0;
    var unpriced: usize = 0;
    var addresses: std.StringHashMapUnmanaged(c.Value) = .empty;
    for (rows.items) |*row| {
        // Catalog aliases can point at one ERC20 balance. Keep each record
        // visible, but never count the same holding twice in the subtotal.
        if (c.field(row.*, "address")) |address| {
            const key = try std.ascii.allocLowerString(a, try c.string(address));
            if (addresses.get(key)) |first| {
                try row.object.put(a, "duplicateOf", first);
                continue;
            }
            try addresses.put(a, key, c.field(row.*, "hash").?);
        }
        const value = c.field(row.*, "usdValue18").?;
        if (value == .null) unpriced += 1 else subtotal = try std.math.add(u256, subtotal, try c.number(a, value));
    }
    try canonical(&remote);
    const next: ?u64 = if (start +| keys.items.len < total) start + keys.items.len else null;
    const result = try c.parse(a, try c.encode(a, .{ .chainId = cast.chain, .registry = cast.instance, .account = account, .block = remote.block, .discovery = discovery, .start = start, .tokenCount = total, .nextStart = try optionalNumber(a, next), .maxAge = age, .assets = rows.items, .pricedSubtotalUsd18 = try abi.uint(a, subtotal), .pricedSubtotalUsd = try decimals(a, subtotal, 18), .unpricedAssets = unpriced, .portfolioComplete = c.eq(u8, discovery, "registry-index") and start == 0 and next == null and unpriced == 0 }));
    if (out) |path| try c.write(cast.io, path, try c.encode(a, result), true);
    return result;
}

fn newer(_: void, left: c.Value, right: c.Value) bool {
    const l = c.field(left, "blockNumber").?;
    const r = c.field(right, "blockNumber").?;
    const a = c.word(c.string(l) catch return false) catch return false;
    const b = c.word(c.string(r) catch return false) catch return false;
    if (a != b) return a > b;
    const li = c.field(left, "logIndex") orelse return false;
    const ri = c.field(right, "logIndex") orelse return false;
    return (c.word(c.string(li) catch return false) catch return false) > (c.word(c.string(ri) catch return false) catch return false);
}
fn logs(remote: *rpc.Rpc, interact: []const u8, topics: c.Value, from: u64, to: u64, collected: *std.json.Array, budget: *usize) anyerror!void {
    const a = remote.a;
    if (budget.* == 0) return error.ActivityRpcLimitNarrowRange;
    budget.* -= 1;
    const batch = remote.one("eth_getLogs", try abi.array(a, &.{try c.parse(a, try c.encode(a, .{ .address = interact, .topics = topics, .fromBlock = try rpc.quantity(a, from), .toBlock = try rpc.quantity(a, to) }))})) catch |err| {
        // Provider range limits are handled without silently dropping a window.
        if (err != error.RpcRejectedRequest or from == to) return err;
        if (remote.last_error) |v| if (c.field(v, "code")) |code| if (c.eq(u8, c.scalar(a, code) catch "", "-32601")) return err;
        const middle = from + (to - from) / 2;
        try logs(remote, interact, topics, from, middle, collected, budget);
        return logs(remote, interact, topics, middle + 1, to, collected, budget);
    };
    if (batch != .array) return error.InvalidRpcLogs;
    if (collected.items.len + batch.array.items.len > 50000) return error.ActivityLogLimitNarrowRange;
    for (batch.array.items) |log| {
        const height = try rpc.integer(a, c.field(log, "blockNumber") orelse return error.InvalidRpcLogs);
        if (height < from or height > to) return error.InvalidRpcLogs;
        try collected.append(log);
    }
}

pub fn activity(cast: *Cast, dir: []const u8, profile: config.Profile, args: *Args, account: []const u8) !c.Value {
    const a = cast.a;
    try c.address(account);
    const start = try number(args, "start", "0");
    const count = try number(args, "count", "20");
    const from_arg = args.get("from-block");
    const force_logs = args.flag("logs") or from_arg != null;
    const out = args.get("out");
    if (count == 0 or count > 100) return error.InvalidAccountViewLimit;
    try args.finish();
    const interact = profile.forChain("interacts.", cast.chain) orelse profile.get("interact") orelse try @import("topology.zig").resolve(cast, dir, profile, "interact");
    const aux = try contracts.Catalog.loadAuxiliary(a);
    var remote = try rpc.Rpc.init(a, cast.io, cast.rpc, cast.chain, interact);
    defer remote.deinit();
    try remote.pin(cast.block, 0);
    if (!std.ascii.eqlIgnoreCase(try c.string(try remote.namedAt(interact, try aux.find("interact", "registry"), &.{})), cast.instance)) return error.InteractRegistryMismatch;
    const indexed = (try remote.namedAt(interact, try aux.find("interact", "indexingEnabled"), &.{})).bool;
    const use_logs = force_logs or !indexed;
    var rows = std.json.Array.init(a);
    var from: ?u64 = null;
    if (!use_logs) {
        rows = (try remote.namedAt(interact, try aux.find("interact", "getVaultExecutionRecent"), &.{.{ .string = account }})).array;
        if (rows.items.len > 256) return error.InvalidContractResponse;
        for (rows.items) |row| if (!std.ascii.eqlIgnoreCase(try c.string(c.field(row, "vault") orelse return error.InvalidContractResponse), account)) return error.InvalidContractResponse;
    } else {
        from = if (from_arg) |text| try std.fmt.parseInt(u64, text, 0) else remote.block.number -| 9999;
        if (from.? > remote.block.number or remote.block.number - from.? > 1_000_000) return error.InvalidActivityBlockRange;
        const event = aux.event("VaultInteractionExecuted") orelse return error.InvalidArtifact;
        const topic = try c.hex(a, @import("miniscript").bytecode.hash(try contracts.signature(a, event, false)));
        const account_topic = try c.hex(a, try c.word(account));
        const topics = try abi.array(a, &.{ .{ .string = topic }, .{ .string = account_topic } });
        var raw = std.json.Array.init(a);
        var budget: usize = 1024;
        var offset = from.?;
        while (offset <= remote.block.number) {
            const end = @min(remote.block.number, offset +| 1999);
            try logs(&remote, interact, topics, offset, end, &raw, &budget);
            if (end == remote.block.number) break;
            offset = end + 1;
        }
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        for (raw.items) |log| {
            if (!std.ascii.eqlIgnoreCase(try c.string(c.field(log, "address") orelse return error.InvalidRpcLogs), interact)) return error.InvalidRpcLogs;
            const ts = c.field(log, "topics") orelse return error.InvalidRpcLogs;
            if (ts != .array or ts.array.items.len != 4 or !std.ascii.eqlIgnoreCase(try c.string(ts.array.items[0]), topic) or !std.ascii.eqlIgnoreCase(try c.string(ts.array.items[1]), account_topic)) return error.InvalidRpcLogs;
            if (c.field(log, "removed")) |removed| if (removed != .bool or removed.bool) return error.ChainReorganizedRetrySync;
            const tx = try c.string(c.field(log, "transactionHash") orelse return error.InvalidRpcLogs);
            if ((try abi.unhex(a, tx)).len != 32) return error.InvalidRpcLogs;
            const log_index = try rpc.integer(a, c.field(log, "logIndex") orelse return error.InvalidRpcLogs);
            const identity = try a.print("{s}:{d}", .{ tx, log_index });
            if (seen.contains(identity)) return error.DuplicateActivityLog;
            try seen.put(a, identity, {});
            const decoded = try @import("transaction_decode.zig").event(a, try abi.array(a, &.{event}), log);
            if (decoded == .null) return error.InvalidRpcLogs;
            var row = try c.parse(a, "{}");
            for (c.field(decoded, "args").?.array.items) |entry| try row.object.put(a, try c.string(c.field(entry, "name").?), c.field(entry, "value").?);
            for ([_][]const u8{ "blockNumber", "blockHash", "transactionHash", "logIndex" }) |key| try row.object.put(a, key, c.field(log, key) orelse return error.InvalidRpcLogs);
            try rows.append(row);
        }
        std.mem.sort(c.Value, rows.items, {}, newer);
    }
    const total = rows.items.len;
    const selected = rows.items[@min(start, total)..@min(total, start +| count)];
    if (use_logs) try remote.verifyLogs(selected);
    var blocks: std.AutoHashMapUnmanaged(u64, rpc.Block) = .empty;
    for (selected) |*row| {
        const height = try rpc.integer(a, c.field(row.*, "blockNumber").?);
        if (height > remote.block.number) return error.InvalidContractResponse;
        const block = blocks.get(height) orelse blk: {
            const value = try remote.blockAt(try rpc.quantity(a, height));
            if (value.number != height) return error.InvalidRpcBlock;
            try blocks.put(a, height, value);
            break :blk value;
        };
        try row.object.put(a, "timestamp", try abi.uint(a, block.timestamp));
        try row.object.put(a, "blockHash", .{ .string = block.hash });
        if (!use_logs) try row.object.put(a, "transactionHash", .null);
    }
    try canonical(&remote);
    const next: ?u64 = if (start +| selected.len < total) start + selected.len else null;
    const result = try c.parse(a, try c.encode(a, .{ .chainId = cast.chain, .registry = cast.instance, .interact = interact, .account = account, .block = remote.block, .indexingEnabled = indexed, .coverage = if (use_logs) "block-range" else "recent-index", .fromBlock = try optionalNumber(a, from), .toBlock = remote.block.number, .start = start, .total = total, .nextStart = try optionalNumber(a, next), .records = selected }));
    if (out) |path| try c.write(cast.io, path, try c.encode(a, result), true);
    return result;
}

test "asset decimals preserve exact base units without floating point" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("0", try decimals(a, 0, 18));
    try std.testing.expectEqualStrings("123.45", try decimals(a, 123450000, 6));
    try std.testing.expectEqualStrings("0.000000000000000001", try decimals(a, 1, 18));
    try std.testing.expectEqualStrings("100", try decimals(a, 100, 0));
    try std.testing.expectEqualStrings("115792089237316195423570985008687907853269984665640564039457.584007913129639935", try decimals(a, std.math.maxInt(u256), 18));
}
