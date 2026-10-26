const std = @import("std");
const c = @import("common.zig");
const abi = @import("abi_codec.zig");
const rpc = @import("rpc.zig");
const Store = @import("store.zig").Store;
const Cast = @import("cast.zig").Cast;
const field = @import("commitment_codec.zig").field;
const string = @import("commitment_codec.zig").string;
pub fn same(left: []const u8, right: []const u8) bool {
    return std.ascii.eqlIgnoreCase(left, right);
}
pub fn hash(a: c.A, value: []const u8) ![]const u8 {
    if (value.len != 66 or try c.word(value) == 0) return error.InvalidTransactionHash;
    return std.ascii.allocLowerString(a, value);
}
fn scope(a: c.A, chain: u64) ![]const u8 {
    return a.print("transactions:{d}", .{chain});
}
pub fn list(db: Store, chain: u64) ![]c.Value {
    return (try db.entries(try scope(db.a, chain), "transactions")).values();
}
pub fn saved(db: Store, chain: u64, tx_hash: []const u8) !?c.Value {
    return db.get(try scope(db.a, chain), "transactions", tx_hash);
}
pub fn page(db: Store, chain: u64, start: u64, count: u64) !Store.Page {
    return db.page(try scope(db.a, chain), "transactions", start, count);
}
pub fn save(db: Store, chain: u64, report: c.Value) !void {
    try db.put(try scope(db.a, chain), "transactions", try hash(db.a, try string(report, "hash")), try redact(db.a, report));
}
fn digest(a: c.A, tx: c.Value) !u256 {
    if (c.field(tx, "input")) |value| {
        const bytes = try abi.unhex(a, try c.string(value));
        if (bytes.len > 1024 * 1024) return error.TransactionTooLarge;
        return @import("miniscript").bytecode.hash(bytes);
    }
    return c.number(a, try field(tx, "inputHash"));
}
fn redactTransaction(a: c.A, value: *c.Value) !void {
    if (value.* == .null) return;
    if (c.field(value.*, "input")) |input| {
        try value.object.put(a, "inputHash", .{ .string = try c.hex(a, try digest(a, value.*)) });
        try value.object.put(a, "inputBytes", try abi.uint(a, (try c.string(input)).len / 2 - 1));
        _ = value.object.orderedRemove("input");
    }
}
/// An unmined reveal may still contain a secret salt, especially with private
/// RPC transport. Persist its digest, not plaintext calldata. Explicit live
/// transaction inspection remains available to the user.
pub fn redact(a: c.A, report: c.Value) !c.Value {
    var copy = try c.parse(a, try c.encode(a, report));
    if (c.field(copy, "transaction")) |raw| {
        var tx = raw;
        try redactTransaction(a, &tx);
        try copy.object.put(a, "transaction", tx);
    }
    if (c.field(copy, "replacement")) |raw| if (raw != .null) {
        var replaced = raw;
        if (c.field(replaced, "transaction")) |value| {
            var tx = value;
            try redactTransaction(a, &tx);
            try replaced.object.put(a, "transaction", tx);
            try copy.object.put(a, "replacement", replaced);
        }
    };
    return copy;
}
pub fn submitted(cast: *Cast, tx_hash: []const u8, intent: c.Value) !void {
    const journal = cast.journal orelse return;
    const db = try Store.open(cast.a, cast.io, journal.dir);
    defer db.close();
    try save(db, cast.chain, try c.parse(cast.a, try c.encode(cast.a, .{ .chainId = cast.chain, .hash = try hash(cast.a, tx_hash), .status = "submitted", .intent = intent, .log = journal.path })));
}
fn validateTransaction(a: c.A, tx: c.Value, tx_hash: []const u8, chain: u64) !void {
    if (!same(try string(tx, "hash"), tx_hash)) return error.TransactionHashMismatch;
    try c.address(try string(tx, "from"));
    if (c.field(tx, "chainId")) |id| if (id != .null and try c.number(a, id) != chain) return error.TransactionChainMismatch;
    _ = try rpc.integer(a, try field(tx, "nonce"));
    _ = try c.number(a, try field(tx, "value"));
    _ = try digest(a, tx);
    if (c.field(tx, "to")) |to| if (to != .null) try c.address(try c.string(to));
}
fn canonicalReceipt(remote: *rpc.Rpc, tx: c.Value, receipt: c.Value, tx_hash: []const u8) !u64 {
    const a = remote.a;
    try validateTransaction(a, tx, tx_hash, remote.chain);
    if (!same(try string(receipt, "transactionHash"), tx_hash)) return error.TransactionHashMismatch;
    const number = try rpc.integer(a, try field(receipt, "blockNumber"));
    if (number > remote.block.number) return error.TransactionAheadOfSnapshot;
    const block = try remote.blockAt(try rpc.quantity(a, number));
    if (!same(block.hash, try string(receipt, "blockHash")) or !same(block.hash, try string(tx, "blockHash")) or try rpc.integer(a, try field(tx, "blockNumber")) != number) return error.TransactionReorganized;
    if (try c.number(a, try field(receipt, "status")) > 1) return error.InvalidTransactionReceipt;
    if (c.field(receipt, "from")) |from| if (!same(try c.string(from), try string(tx, "from"))) return error.InvalidTransactionReceipt;
    if (c.field(receipt, "to")) |to| if (!sameTarget(to, c.field(tx, "to") orelse .null)) return error.InvalidTransactionReceipt;
    return remote.block.number - number + 1;
}
fn sameTarget(left: c.Value, right: c.Value) bool {
    if (left == .null or right == .null) return left == .null and right == .null;
    return same(c.string(left) catch return false, c.string(right) catch return false);
}
fn sameAccess(a: c.Value, b: c.Value) !bool {
    const left: []const c.Value = if (a == .null) &.{} else if (a == .array) a.array.items else return error.InvalidAccessList;
    const right: []const c.Value = if (b == .null) &.{} else if (b == .array) b.array.items else return error.InvalidAccessList;
    if (left.len != right.len) return false;
    for (left, right) |l, r| {
        if (!same(try string(l, "address"), try string(r, "address"))) return false;
        const lk = try field(l, "storageKeys");
        const rk = try field(r, "storageKeys");
        if (lk != .array or rk != .array) return error.InvalidAccessList;
        if (lk.array.items.len != rk.array.items.len) return false;
        for (lk.array.items, rk.array.items) |x, y| if (!same(try c.string(x), try c.string(y))) return false;
    }
    return true;
}
fn bindIntent(a: c.A, intent: c.Value, tx: c.Value) !void {
    if (!sameTarget(c.field(intent, "to") orelse .null, c.field(tx, "to") orelse .null) or try c.number(a, try field(intent, "dataHash")) != try digest(a, tx) or try @import("amounts.zig").native(try c.scalar(a, try field(intent, "value"))) != try c.number(a, try field(tx, "value"))) return error.TransactionIntentMismatch;
    if (c.field(intent, "from")) |from| if (from != .null and !same(try c.string(from), try string(tx, "from"))) return error.TransactionIntentMismatch;
    for ([_][]const u8{ "nonce", "gas", "gasPrice", "maxFeePerGas", "maxPriorityFeePerGas" }) |name| if (c.field(intent, name)) |value| {
        if (value != .null and try c.number(a, value) != try c.number(a, try field(tx, name))) return error.TransactionIntentMismatch;
    };
    if (!try sameAccess(c.field(intent, "accessList") orelse .null, c.field(tx, "accessList") orelse .null)) return error.TransactionIntentMismatch;
}
pub fn replacementKind(a: c.A, original: c.Value, next: c.Value) ![]const u8 {
    if (!same(try string(original, "from"), try string(next, "from")) or try c.number(a, try field(original, "nonce")) != try c.number(a, try field(next, "nonce"))) return error.NotATransactionReplacement;
    const to = c.field(next, "to") orelse c.Value.null;
    const simple = try c.number(a, c.field(original, "type") orelse c.Value{ .string = "0" }) <= 2 and try c.number(a, c.field(next, "type") orelse c.Value{ .string = "0" }) <= 2;
    if (simple and sameTarget(to, c.field(original, "to") orelse .null) and try digest(a, next) == try digest(a, original) and try c.number(a, try field(next, "value")) == try c.number(a, try field(original, "value")) and try sameAccess(c.field(original, "accessList") orelse .null, c.field(next, "accessList") orelse .null)) return "repriced";
    if (simple and sameTarget(to, try field(next, "from")) and c.eq(u8, try string(next, "input"), "0x") and try c.number(a, try field(next, "value")) == 0 and try sameAccess(c.field(next, "accessList") orelse .null, .null)) return "cancelled";
    return "replaced";
}
const Search = struct { replacement: c.Value = .null, progress: c.Value = .null };
fn originalFromIntent(a: c.A, tx_hash: []const u8, previous: ?c.Value) !c.Value {
    const record = previous orelse return .null;
    const intent = c.field(record, "intent") orelse return .null;
    const from = c.field(intent, "from") orelse return .null;
    const nonce = c.field(intent, "nonce") orelse return .null;
    if (from == .null or nonce == .null) return .null;
    return c.parse(a, try c.encode(a, .{ .hash = tx_hash, .from = from, .nonce = nonce, .chainId = try field(intent, "chainId"), .to = c.field(intent, "to") orelse .null, .value = try abi.uint(a, try @import("amounts.zig").native(try c.scalar(a, try field(intent, "value")))), .inputHash = try field(intent, "dataHash"), .inputBytes = c.field(intent, "dataBytes") orelse .null, .accessList = c.field(intent, "accessList") orelse .null }));
}
fn replacementReport(remote: *rpc.Rpc, original: c.Value, tx: c.Value, receipt: c.Value, tx_hash: []const u8) !c.Value {
    const confirmations = try canonicalReceipt(remote, tx, receipt, tx_hash);
    if (same(tx_hash, try string(original, "hash"))) return error.NotATransactionReplacement;
    return c.parse(remote.a, try c.encode(remote.a, .{ .kind = try replacementKind(remote.a, original, tx), .hash = tx_hash, .transaction = tx, .receipt = receipt, .confirmations = confirmations }));
}
fn replacement(remote: *rpc.Rpc, original: c.Value, previous: ?c.Value, budget: u64) !Search {
    const a = remote.a;
    // A discovered hash is a durable lookup key, not a terminal cached result.
    // Re-read its receipt against this observation's pinned chain snapshot.
    var restart = false;
    if (previous) |record| if (c.field(record, "replacement")) |known| if (c.field(known, "hash")) |value| {
        const known_hash = try hash(a, try c.string(value));
        const params = try abi.array(a, &.{.{ .string = known_hash }});
        const values = try remote.batch(&.{ .{ .method = "eth_getTransactionByHash", .params = params }, .{ .method = "eth_getTransactionReceipt", .params = params } });
        if (values[0] != .null and values[1] != .null) {
            const report = replacementReport(remote, original, values[0], values[1], known_hash) catch |err| switch (err) {
                error.TransactionReorganized => @as(c.Value, .null),
                else => return err,
            };
            if (report != .null) return .{ .replacement = report };
        }
        // Missing/noncanonical replacements invalidate earlier scan coverage.
        restart = true;
    };
    const from = try string(original, "from");
    const nonce = try c.number(a, try field(original, "nonce"));
    const current = try c.number(a, try remote.one("eth_getTransactionCount", try abi.array(a, &.{ .{ .string = from }, try remote.blockSelector() })));
    if (current <= nonce) return .{};
    var floor = remote.block.number -| (budget -| 1);
    if (previous) |record| if (c.field(record, "intent")) |intent| if (c.field(intent, "submissionBlock")) |submitted_block| {
        floor = @min(remote.block.number, try rpc.integer(a, try field(submitted_block, "number")));
    };
    var next = floor;
    if (!restart) if (previous) |record| if (c.field(record, "replacementSearch")) |progress| if (progress == .object) {
        const anchor = try field(progress, "anchor");
        const old_height = try rpc.integer(a, try field(anchor, "number"));
        if (old_height <= remote.block.number and try remote.canonical(.{ .number = old_height, .hash = try string(anchor, "hash"), .timestamp = 0 })) {
            const old_floor = try rpc.integer(a, try field(progress, "fromBlock"));
            const old_next = try rpc.integer(a, try field(progress, "nextBlock"));
            if (old_floor <= floor and old_next >= old_floor and old_next <= remote.block.number +| 1) {
                floor = old_floor;
                next = old_next;
            }
        }
    };
    var remaining = budget;
    while (remaining > 0 and next <= remote.block.number) {
        const count: usize = @intCast(@min(16, @min(remaining, remote.block.number - next + 1)));
        var requests: [16]rpc.Request = undefined;
        for (requests[0..count], 0..) |*request, i| request.* = .{ .method = "eth_getBlockByNumber", .params = try abi.array(a, &.{ .{ .string = try rpc.quantity(a, next + i) }, .{ .bool = true } }) };
        const blocks = try remote.batch(requests[0..count]);
        for (blocks) |block| {
            const height = next;
            if (try rpc.integer(a, try field(block, "number")) != height) return error.InvalidRpcBlock;
            const transactions = try field(block, "transactions");
            if (transactions != .array or transactions.array.items.len > 100000) return error.InvalidRpcBlock;
            for (transactions.array.items) |tx| {
                if (!same(try string(tx, "from"), from) or try c.number(a, try field(tx, "nonce")) != nonce) continue;
                const tx_hash = try string(tx, "hash");
                try validateTransaction(a, tx, tx_hash, remote.chain);
                if (same(tx_hash, try string(original, "hash"))) return .{};
                const receipt = try remote.one("eth_getTransactionReceipt", try abi.array(a, &.{.{ .string = tx_hash }}));
                if (receipt == .null) return .{};
                if (try rpc.integer(a, try field(receipt, "blockNumber")) != height or !same(try string(block, "hash"), try string(receipt, "blockHash"))) return error.TransactionReorganized;
                return .{ .replacement = try replacementReport(remote, original, tx, receipt, tx_hash) };
            }
            next += 1;
        }
        remaining -= count;
    }
    return .{ .replacement = try c.parse(a, "{\"kind\":\"nonce-used\"}"), .progress = try c.parse(a, try c.encode(a, .{ .fromBlock = floor, .nextBlock = next, .anchor = remote.block, .complete = next > remote.block.number, .blocksScanned = budget - remaining })) };
}
pub fn observe(remote: *rpc.Rpc, tx_hash: []const u8, previous: ?c.Value, confirmations: u64, lookback: u64) !c.Value {
    if (confirmations == 0 or lookback > 1024) return error.InvalidTransactionMonitorOptions;
    const a = remote.a;
    const canonical_hash = try hash(a, tx_hash);
    try remote.pinBlock(null, 0);
    const params = try abi.array(a, &.{.{ .string = canonical_hash }});
    const values = try remote.batch(&.{ .{ .method = "eth_getTransactionByHash", .params = params }, .{ .method = "eth_getTransactionReceipt", .params = params } });
    const live_tx = values[0];
    const cached_tx = if (previous) |record| c.field(record, "transaction") orelse c.Value.null else c.Value.null;
    const tx = if (live_tx != .null) live_tx else if (cached_tx != .null) cached_tx else try originalFromIntent(a, canonical_hash, previous);
    if (tx != .null) try validateTransaction(a, tx, tx_hash, remote.chain);
    if (previous) |record| if (c.field(record, "intent")) |intent| if (live_tx != .null) try bindIntent(a, intent, live_tx);
    var status: []const u8 = if (live_tx == .null) "unknown" else "pending";
    var depth: u64 = 0;
    var replaced: c.Value = .null;
    var search: c.Value = .null;
    if (values[1] != .null) {
        if (live_tx == .null) return error.TransactionDetailsUnavailable;
        depth = try canonicalReceipt(remote, tx, values[1], tx_hash);
        status = if (depth < confirmations) "confirming" else if (try c.number(a, try field(values[1], "status")) == 1) "confirmed" else "reverted";
    } else if (tx != .null) {
        const scanned = try replacement(remote, tx, previous, lookback);
        replaced = scanned.replacement;
        search = scanned.progress;
        if (replaced != .null) {
            status = try string(replaced, "kind");
            if (c.field(replaced, "confirmations")) |n| {
                depth = try rpc.integer(a, n);
                if (depth < confirmations) status = "confirming-replacement";
            }
        }
    }
    if (!try remote.canonical(remote.block)) return error.TransactionReorganized;
    var report = try c.parse(a, try c.encode(a, .{ .chainId = remote.chain, .hash = canonical_hash, .status = status, .transaction = tx, .receipt = values[1], .replacement = replaced, .confirmations = depth, .requiredConfirmations = confirmations, .block = remote.block, .replacementLookback = lookback, .replacementSearch = search }));
    try report.object.put(a, "confirmationBasis", .{ .string = if (remote.chain == 42161) "l2-block-depth" else "chain-block-depth" });
    try report.object.put(a, "finality", try @import("transaction_finality.zig").unchecked(a));
    if (previous) |record| for ([_][]const u8{ "intent", "log" }) |name| if (c.field(record, name)) |value| try report.object.put(a, name, value);
    return report;
}
pub fn terminal(report: c.Value) !bool {
    return @import("schema.zig").contains("confirmed reverted repriced cancelled replaced", try string(report, "status"));
}
fn boundedObserve(remote: *rpc.Rpc, tx_hash: []const u8, previous: ?c.Value, confirmations: u64, lookback: u64, seconds: u64) !c.Value {
    const Result = union(enum) { observation: anyerror!c.Value, timeout: std.Io.Cancelable!void };
    var buffer: [2]Result = undefined;
    var select = std.Io.Select(Result).init(remote.client.io, &buffer);
    defer select.cancelDiscard();
    try select.concurrent(.timeout, std.Io.sleep, .{ remote.client.io, .fromSeconds(@intCast(seconds)), .awake });
    try select.concurrent(.observation, observe, .{ remote, tx_hash, previous, confirmations, lookback });
    return switch (try select.await()) {
        .observation => |value| value,
        .timeout => |done| {
            try done;
            return error.TransactionMonitorTimedOut;
        },
    };
}
pub fn wait(cast: *Cast, db: ?Store, tx_hash: []const u8, timeout: u64, confirmations: u64, lookback: u64, poll: u64) !c.Value {
    if (timeout > 86400 or poll == 0 or poll > 60) return error.InvalidTransactionMonitorOptions;
    const a = cast.a;
    const canonical_hash = try hash(a, tx_hash);
    const started = std.Io.Clock.awake.now(cast.io);
    const previous = if (db) |store| try saved(store, cast.chain, canonical_hash) else null;
    // Polling can last hours. Release each observation's decoded RPC objects
    // instead of accumulating them in the command's lifetime arena.
    var previous_bytes: ?[]const u8 = if (previous) |value| try c.encode(std.heap.page_allocator, value) else null;
    defer if (previous_bytes) |bytes| std.heap.page_allocator.free(bytes);
    var retries: u8 = 0;
    var observed = false;
    while (true) {
        const elapsed_before: u64 = @intCast(@max(0, started.durationTo(std.Io.Clock.awake.now(cast.io)).toSeconds()));
        if (timeout > 0 and elapsed_before >= timeout) {
            if (!observed) return error.TransactionMonitorTimedOut;
            return c.parse(a, previous_bytes.?);
        }
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var remote = try rpc.Rpc.initEndpoint(arena.allocator(), cast.io, cast.rpc, cast.chain);
        defer remote.deinit();
        // A zero polling duration means one observation, not a one-second RPC.
        remote.timeout_seconds = if (timeout == 0) 10 else @intCast(@min(timeout - elapsed_before, 10));
        const record = if (previous_bytes) |bytes| try c.parse(arena.allocator(), bytes) else @as(?c.Value, null);
        const report = boundedObserve(&remote, canonical_hash, record, confirmations, lookback, if (timeout == 0) 30 else @min(30, timeout - elapsed_before)) catch |err| {
            // A block can arrive between pinning and the receipt read. Retry
            // reads only; a persistent inconsistent response remains an error.
            if ((err == error.TransactionAheadOfSnapshot or err == error.TransactionReorganized) and retries < 2) {
                retries += 1;
                continue;
            }
            return err;
        };
        retries = 0;
        observed = true;
        if (db) |store| {
            var local = store;
            local.a = arena.allocator();
            try save(local, cast.chain, report);
        }
        const next_bytes = try c.encode(std.heap.page_allocator, report);
        if (previous_bytes) |bytes| std.heap.page_allocator.free(bytes);
        previous_bytes = next_bytes;
        if (try terminal(report) or timeout == 0) return c.parse(a, next_bytes);
        const elapsed = started.durationTo(std.Io.Clock.awake.now(cast.io)).toSeconds();
        if (elapsed >= timeout) return c.parse(a, next_bytes);
        try std.Io.sleep(cast.io, .fromSeconds(@intCast(@min(poll, timeout - @as(u64, @intCast(@max(elapsed, 0)))))), .awake);
    }
}
pub fn verifiedReceipt(report: c.Value) !c.Value {
    const status = try string(report, "status");
    if (c.eq(u8, status, "cancelled") or c.eq(u8, status, "replaced")) return error.TransactionPayloadReplaced;
    if (!try terminal(report)) return error.TransactionStillPending;
    const value = if (c.eq(u8, status, "repriced")) try field(try field(report, "replacement"), "receipt") else try field(report, "receipt");
    if (value == .null) return error.InvalidTransactionReceipt;
    return value;
}

test "one-shot tracking allows an RPC response taking more than one second" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mock = @import("test_rpc.zig");
    const block = "[{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"number\":\"0x1\",\"hash\":\"0x" ++ "1111111111111111111111111111111111111111111111111111111111111111" ++ "\",\"timestamp\":\"0x1\"}}]";
    var server = try mock.Server.init(std.testing.io, &.{
        .{ .body = "[{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\"0xa4b1\"}]", .delay_ms = 1250 },
        .{ .body = block },
        .{ .body = "[{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":null},{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":null}]" },
        .{ .body = block },
    });
    defer server.deinit();
    var serving = try std.testing.io.concurrent(mock.Server.serve, .{&server});
    defer _ = serving.cancel(std.testing.io) catch {};
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    var cast: Cast = .{ .a = a, .io = std.testing.io, .env = &env, .chain = 42161, .rpc = try server.url(a) };
    const report = try wait(&cast, null, "0x" ++ "2222222222222222222222222222222222222222222222222222222222222222", 0, 1, 0, 1);
    try serving.await(std.testing.io);
    try std.testing.expectEqualStrings("unknown", try string(report, "status"));
    try std.testing.expectEqual(@as(usize, 4), server.requests);
}

test "replacement search resumes batched blocks from durable intent when the original transaction disappears" {
    const mock = @import("test_rpc.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const original_hash = "0x1111111111111111111111111111111111111111111111111111111111111111";
    const replacement_hash = "0x2222222222222222222222222222222222222222222222222222222222222222";
    const block_hash = "0x3333333333333333333333333333333333333333333333333333333333333333";
    const sender = "0x1111111111111111111111111111111111111111";
    const target = "0x2222222222222222222222222222222222222222";
    const head = try c.encode(a, .{.{ .jsonrpc = "2.0", .id = 1, .result = .{ .number = "0x64", .hash = block_hash, .timestamp = "0x1" } }});
    const missing = try c.encode(a, .{ .{ .jsonrpc = "2.0", .id = 1, .result = @as(c.Value, .null) }, .{ .jsonrpc = "2.0", .id = 2, .result = @as(c.Value, .null) } });
    const chain = "[{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\"0xa4b1\"}]";
    const nonce = "[{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\"0x2\"}]";
    const next = .{ .hash = replacement_hash, .from = sender, .to = target, .nonce = "0x1", .value = "0x0", .input = "0x12", .blockNumber = "0x53", .blockHash = block_hash, .chainId = "0xa4b1" };
    const receipt = .{ .transactionHash = replacement_hash, .blockNumber = "0x53", .blockHash = block_hash, .status = "0x1" };
    const initial_replies = [_]mock.Reply{
        .{ .body = chain },                                                                                                                                                                                                                                                                                  .{ .body = head },                                                                                                                        .{ .body = missing }, .{ .body = nonce },
        .{ .body = try c.encode(a, .{ .{ .jsonrpc = "2.0", .id = 1, .result = .{ .number = "0x50", .hash = block_hash, .transactions = [_]c.Value{} } }, .{ .jsonrpc = "2.0", .id = 2, .result = .{ .number = "0x51", .hash = block_hash, .transactions = [_]c.Value{} } } }), .request_contains = "0x50" }, .{ .body = head },                                                                                                                        .{ .body = chain },   .{ .body = head },
        .{ .body = missing },                                                                                                                                                                                                                                                                                .{ .body = nonce },                                                                                                                       .{ .body = head },    .{ .body = try c.encode(a, .{ .{ .jsonrpc = "2.0", .id = 1, .result = .{ .number = "0x52", .hash = block_hash, .transactions = [_]c.Value{} } }, .{ .jsonrpc = "2.0", .id = 2, .result = .{ .number = "0x53", .hash = block_hash, .transactions = .{next} } } }), .request_contains = "0x52" },
        .{ .body = try c.encode(a, .{.{ .jsonrpc = "2.0", .id = 1, .result = receipt }}) },                                                                                                                                                                                                                  .{ .body = try c.encode(a, .{.{ .jsonrpc = "2.0", .id = 1, .result = .{ .number = "0x53", .hash = block_hash, .timestamp = "0x1" } }}) }, .{ .body = head },
    };
    var replies: std.ArrayList(mock.Reply) = .empty;
    try replies.appendSlice(a, &initial_replies);
    const Scenario = enum { unchanged, confirming, confirmed, missing, reorg };
    for (std.enums.values(Scenario)) |scenario| {
        const current_head = if (scenario == .confirmed) try c.encode(a, .{.{ .jsonrpc = "2.0", .id = 1, .result = .{ .number = "0x65", .hash = block_hash, .timestamp = "0x2" } }}) else head;
        try replies.appendSlice(a, &.{ .{ .body = chain }, .{ .body = current_head }, .{ .body = missing } });
        try replies.append(a, .{ .body = if (scenario == .missing) missing else try c.encode(a, .{ .{ .jsonrpc = "2.0", .id = 1, .result = next }, .{ .jsonrpc = "2.0", .id = 2, .result = receipt } }), .request_contains = replacement_hash });
        if (scenario != .missing) try replies.append(a, .{ .body = try c.encode(a, .{.{ .jsonrpc = "2.0", .id = 1, .result = .{ .number = "0x53", .hash = if (scenario == .reorg) original_hash else block_hash, .timestamp = "0x1" } }}) });
        if (scenario == .missing or scenario == .reorg) {
            try replies.append(a, .{ .body = nonce });
            try replies.append(a, .{ .body = try c.encode(a, .{ .{ .jsonrpc = "2.0", .id = 1, .result = .{ .number = "0x50", .hash = block_hash, .transactions = [_]c.Value{} } }, .{ .jsonrpc = "2.0", .id = 2, .result = .{ .number = "0x51", .hash = block_hash, .transactions = [_]c.Value{} } } }), .request_contains = "0x50" });
        }
        try replies.append(a, .{ .body = current_head });
    }
    var server = try mock.Server.init(std.testing.io, replies.items);
    defer server.deinit();
    var serving = try std.testing.io.concurrent(mock.Server.serve, .{&server});
    defer _ = serving.cancel(std.testing.io) catch {};
    var remote = try rpc.Rpc.initEndpoint(a, std.testing.io, try server.url(a), 42161);
    defer remote.deinit();
    remote.timeout_seconds = 1;
    remote.read_attempts = 1;
    const previous = try c.parse(a, try c.encode(a, .{ .intent = .{ .chainId = 42161, .from = sender, .nonce = 1, .to = target, .value = "0", .dataHash = try c.hex(a, @import("miniscript").bytecode.hash(&.{0x12})), .submissionBlock = .{ .number = 80 } } }));
    const reconstructed = try originalFromIntent(a, original_hash, previous);
    try validateTransaction(a, reconstructed, original_hash, 42161);
    const first = try observe(&remote, original_hash, previous, 1, 2);
    try std.testing.expectEqualStrings("nonce-used", try string(first, "status"));
    try std.testing.expectEqual(@as(u64, 82), try rpc.integer(a, try field(try field(first, "replacementSearch"), "nextBlock")));
    const persisted = try c.parse(a, try c.encode(a, first));
    const second = try observe(&remote, original_hash, persisted, 1, 2);
    try std.testing.expectEqualStrings("repriced", try string(second, "status"));
    try std.testing.expectEqualStrings(replacement_hash, try string(try field(second, "replacement"), "hash"));
    var known = try redact(a, second);
    for (std.enums.values(Scenario)) |scenario| {
        // Also prove that invalidated replacements discard stale scan progress.
        if (scenario == .missing or scenario == .reorg) {
            known = try redact(a, second);
            try known.object.put(a, "replacementSearch", try field(first, "replacementSearch"));
        }
        const observed = try observe(&remote, original_hash, known, if (scenario == .unchanged) 1 else 19, 2);
        const expected: []const u8 = switch (scenario) {
            .unchanged, .confirmed => "repriced",
            .confirming => "confirming-replacement",
            .missing, .reorg => "nonce-used",
        };
        try std.testing.expectEqualStrings(expected, try string(observed, "status"));
        if (scenario == .missing or scenario == .reorg) {
            try std.testing.expectEqual(82, try rpc.integer(a, try field(try field(observed, "replacementSearch"), "nextBlock")));
            try std.testing.expect(c.field(try field(observed, "replacement"), "hash") == null);
        } else {
            try std.testing.expectEqualStrings(replacement_hash, try string(try field(observed, "replacement"), "hash"));
            try std.testing.expectEqual(@as(u64, if (scenario == .confirmed) 19 else 18), try rpc.integer(a, try field(observed, "confirmations")));
        }
        known = try redact(a, observed);
    }
    try serving.await(std.testing.io);
    try std.testing.expectEqual(replies.items.len, server.requests);
}
