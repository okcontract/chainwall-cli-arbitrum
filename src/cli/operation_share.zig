const std = @import("std");
const ms = @import("miniscript");
const c = @import("common.zig");
const abi = @import("abi_codec.zig");
const rpc = @import("rpc.zig");
const operations = @import("operations.zig");
const Client = @import("contract_client.zig").Client;
const Vault = @import("vault.zig").Vault;
pub const share_type = "chainwall.privatePendingOperation";

fn field(value: c.Value, name: []const u8) !c.Value {
    return c.field(value, name) orelse error.InvalidOperationShare;
}
fn same(a: c.A, left: c.Value, right: c.Value) !void {
    if (try c.number(a, left) != try c.number(a, right)) return error.OperationShareMismatch;
}
fn hash(a: c.A, value: c.Value) ![]const u8 {
    const text = try c.string(value);
    if (text.len != 66 or !std.mem.startsWith(u8, text, "0x")) return error.InvalidOperationShare;
    _ = try abi.unhex(a, text);
    return c.hex(a, try c.word(text));
}
pub fn envelope(a: c.A, payload: c.Value, proposal_hash: []const u8) !c.Value {
    // The journal codec supplies canonical uint256 strings and fixed-width hex.
    var normalized = try field(try operations.proposal(a, try operations.encodeProposal(a, payload)), "payload");
    try normalized.object.put(a, "version", .{ .integer = 2 });
    if (try c.number(a, try field(normalized, "operationId")) == 0 or try c.number(a, try field(normalized, "chainId")) == 0) return error.InvalidOperationShare;
    for ([_][]const u8{ "safe", "creator" }) |name| try c.address(try c.string(try field(normalized, name)));
    return c.parse(a, try c.encode(a, .{ .type = share_type, .version = 1, .proposalTxHash = try hash(a, .{ .string = proposal_hash }), .payload = normalized }));
}
pub fn parse(a: c.A, value: c.Value) !c.Value {
    if (!c.eq(u8, try c.string(try field(value, "type")), share_type) or try field(value, "version") == .string or try c.number(a, try field(value, "version")) != 1) return error.UnsupportedOperationShare;
    const payload = try field(value, "payload");
    if (try field(payload, "version") == .string) return error.UnsupportedOperationShare;
    // Shared documents use decimal strings, preventing hex/float/leading-zero
    // ambiguity across the native CLI and browser codecs.
    for ([_][]const u8{ "chainId", "nativeValue", "operationId", "deadline", "createdAt" }) |name| try decimal(a, try field(payload, name));
    const args = try field(payload, "args");
    if (args != .array) return error.InvalidOperationShare;
    for (args.array.items) |arg| try decimal(a, arg);
    for ([_][]const u8{ "interactionId", "policyId", "executionBindingHash", "payloadHash" }) |name| _ = try hash(a, try field(payload, name));
    return envelope(a, payload, try c.string(try field(value, "proposalTxHash")));
}
fn decimal(a: c.A, value: c.Value) !void {
    const text = try c.scalar(a, value);
    if (text.len == 0 or (text.len > 1 and text[0] == '0')) return error.InvalidOperationShare;
    for (text) |ch| if (!std.ascii.isDigit(ch)) return error.InvalidOperationShare;
    _ = try c.word(text);
}
fn read(remote: *rpc.Rpc, client: Client, name: []const u8, values: []const c.Value) !c.Value {
    return remote.namedAt(remote.address, try client.cat.find("interact", name), values);
}

/// A share is private data, not authorization. Prove its complete relationship
/// to a canonical proposal before persisting it or requesting any signature.
pub fn verify(client: Client, value: c.Value) !c.Value {
    const cast = client.cast;
    const a = cast.a;
    const share = try parse(a, value);
    const payload = try field(share, "payload");
    try same(a, try field(payload, "chainId"), try abi.uint(a, cast.chain));
    const proposal_hash = try field(share, "proposalTxHash");
    const id = try field(payload, "operationId");
    var remote = try rpc.Rpc.init(a, cast.io, cast.rpc, cast.chain, cast.instance);
    defer remote.deinit();
    try remote.pin(cast.block, 0);
    try same(a, try read(&remote, client, "chainwallComponentId", &.{}), .{ .string = try c.hex(a, ms.bytecode.hash("Chainwall.Interact")) });
    const method = try client.cat.find("interact", "getPayloadHash");
    var params = (try field(method.abi, "inputs")).array;
    try params.append(try c.parse(a, "{\"type\":\"bytes32\",\"name\":\"executionBindingHash\"}"));
    const values = try abi.array(a, &.{ try field(payload, "interactionId"), try field(payload, "args"), try field(payload, "policyId"), try field(payload, "deadline"), try field(payload, "nativeValue"), try field(payload, "safe"), try field(payload, "executionBindingHash") });
    try same(a, try field(payload, "payloadHash"), .{ .string = try c.hex(a, ms.bytecode.hash(try abi.encode(a, .{ .array = params }, values))) });
    const transaction = try remote.one("eth_getTransactionByHash", try abi.array(a, &.{proposal_hash}));
    if (transaction == .null) return error.ProposalTransactionUnavailable;
    try same(a, try field(transaction, "hash"), proposal_hash);
    try same(a, try field(transaction, "to"), .{ .string = cast.instance });
    try same(a, try field(transaction, "from"), try field(payload, "creator"));
    if (c.field(transaction, "chainId")) |chain| try same(a, chain, try abi.uint(a, cast.chain));
    const expected = try client.data("propose", &.{ try field(payload, "payloadHash"), try field(payload, "policyId"), try field(payload, "deadline"), try field(payload, "nativeValue"), try field(payload, "safe") });
    const input = try c.string(c.field(transaction, "input") orelse try field(transaction, "data"));
    if (!std.ascii.eqlIgnoreCase(input, expected)) return error.OperationShareMismatch;
    const receipt = try remote.one("eth_getTransactionReceipt", try abi.array(a, &.{proposal_hash}));
    if (receipt == .null) return error.TransactionReceiptUnavailable;
    try same(a, try field(receipt, "transactionHash"), proposal_hash);
    if (try c.number(a, try field(receipt, "status")) != 1) return error.ProposalTransactionReverted;
    const block = try rpc.integer(a, try field(receipt, "blockNumber"));
    if (block > remote.block.number) return error.InvalidOperationShare;
    try same(a, try field(transaction, "blockNumber"), try field(receipt, "blockNumber"));
    try same(a, try field(transaction, "blockHash"), try field(receipt, "blockHash"));
    const canonical = try remote.blockAt(try rpc.quantity(a, block));
    if (!std.ascii.eqlIgnoreCase(canonical.hash, try c.string(try field(receipt, "blockHash")))) return error.TransactionReorganized;
    var matches: usize = 0;
    const event_abi = try abi.array(a, &.{client.cat.event("OperationProposed").?});
    for ((try field(receipt, "logs")).array.items) |log| {
        if (!std.ascii.eqlIgnoreCase(cast.instance, try c.string(try field(log, "address")))) continue;
        if ((c.field(log, "removed") orelse c.Value{ .bool = false }).bool) return error.TransactionReorganized;
        try same(a, try field(log, "transactionHash"), proposal_hash);
        try same(a, try field(log, "blockHash"), try field(receipt, "blockHash"));
        try same(a, try field(log, "blockNumber"), try field(receipt, "blockNumber"));
        const event = try @import("transaction_decode.zig").event(a, event_abi, log);
        if (event == .null) continue;
        matches += 1;
        try same(a, try field((try field(event, "args")).array.items[0], "value"), id);
    }
    if (matches != 1) return error.ProposalReceiptUnproven;
    if ((try read(&remote, client, "isOperationExecuted", &.{id})).bool) return error.OperationClosed;
    for ([_][2][]const u8{ .{ "getOperationSafe", "safe" }, .{ "getOperationPolicyId", "policyId" }, .{ "getOperationNativeValue", "nativeValue" } }) |pair| try same(a, try read(&remote, client, pair[0], &.{id}), try field(payload, pair[1]));
    if (try c.number(a, try read(&remote, client, "getOperationExecutor", &.{id})) != 0) return error.ExecutorBoundOperationNotShareable;
    try same(a, try read(&remote, client, "getExecutionBindingHash", &.{ try field(payload, "interactionId"), try field(payload, "policyId") }), try field(payload, "executionBindingHash"));
    if (!try remote.canonical(canonical) or !try remote.canonical(remote.block)) return error.TransactionReorganized;
    return share;
}

pub fn key(a: c.A, chain: u64, registry: []const u8) ![]const u8 {
    return a.print("private-operations:{s}", .{try @import("store.zig").scopeKey(a, chain, registry)});
}
pub fn load(a: c.A, v: Vault, chain: u64, registry: []const u8) !c.Value {
    const scope = try key(a, chain, registry);
    const bytes = (try v.get(scope)) orelse return @import("sealed_records.zig").load(v, scope);
    defer std.crypto.secureZero(u8, bytes);
    const value = try c.parse(a, bytes);
    if (value != .object) return error.InvalidVault;
    return value;
}
/// One-time migration of the legacy encrypted map, inside the caller's write
/// transaction. Subsequent imports and syncs allocate at most one page.
pub fn migrate(v: Vault, scope: []const u8) !void {
    const bytes = (try v.get(scope)) orelse return;
    defer std.crypto.secureZero(u8, bytes);
    const old = try c.parse(v.a, bytes);
    if (old != .object) return error.InvalidVault;
    for (old.object.keys(), old.object.values()) |id, value| try @import("sealed_records.zig").put(v, scope, id, value);
    try v.db.db.exec("DELETE FROM vault WHERE id=?", .{scope});
}
pub fn save(a: c.A, v: Vault, chain: u64, registry: []const u8, share: c.Value) ![]const u8 {
    const record = try operations.proposal(a, try operations.encodeProposal(a, try field(share, "payload")));
    const id = try c.string(try field(record, "pendingId"));
    try v.db.begin();
    errdefer v.db.db.rollback();
    const scope = try key(a, chain, registry);
    try migrate(v, scope);
    try @import("sealed_records.zig").put(v, scope, id, share);
    try v.db.db.commit();
    return id;
}

pub fn merge(a: c.A, listing: operations.Listing, v: Vault, chain: u64, registry: []const u8, safe: ?[]const u8) !operations.Listing {
    const local = try load(a, v, chain, registry);
    var records: std.ArrayList(c.Value) = .empty;
    try records.appendSlice(a, listing.entries);
    for (local.object.keys(), local.object.values()) |id, share| {
        const payload = try field(share, "payload");
        if (safe) |address| if (!std.ascii.eqlIgnoreCase(address, try c.string(try field(payload, "safe")))) continue;
        var exists = false;
        for (records.items) |record| if (c.eq(u8, try c.string(try field(record, "pendingId")), id)) {
            exists = true;
            break;
        };
        if (exists) continue;
        var record = try operations.proposal(a, try operations.encodeProposal(a, payload));
        try record.object.put(a, "source", .{ .string = "local-import" });
        try record.object.put(a, "proposalTxHash", try field(share, "proposalTxHash"));
        try records.append(a, record);
    }
    operations.sort(a, records.items);
    return .{ .entries = records.items, .invalid = listing.invalid, .unreadable = listing.unreadable };
}

test "merged operations are deduplicated and sorted newest first before pagination" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try @import("store.zig").Store.init(a, ":memory:");
    defer db.close();
    const v: Vault = .{ .a = a, .io = std.testing.io, .key = @splat(7), .db = db };
    const address = "0x1111111111111111111111111111111111111111";
    var journal: c.Value = undefined;
    for ([_]u64{ 100, 200, 50 }) |time| {
        const payload = try c.parse(a, try c.encode(a, .{ .version = 2, .safe = address, .creator = address, .chainId = 42161, .interactionId = try c.hex(a, 1), .policyId = try c.hex(a, 2), .executionBindingHash = try c.hex(a, 3), .args = [_]u64{}, .nativeValue = 0, .operationId = time, .payloadHash = try c.hex(a, 4), .deadline = 1000, .createdAt = time }));
        _ = try save(a, v, 42161, address, try c.parse(a, try c.encode(a, .{ .payload = payload, .proposalTxHash = try c.hex(a, time) })));
        if (time == 100) journal = try operations.proposal(a, try operations.encodeProposal(a, payload));
    }
    var journal_entries = [_]c.Value{journal};
    const listing = try merge(a, .{ .entries = &journal_entries, .invalid = 0, .unreadable = 0 }, v, 42161, address, null);
    try std.testing.expectEqual(@as(usize, 3), listing.entries.len);
    for (listing.entries, [_]u256{ 200, 100, 50 }) |record, time| try std.testing.expectEqual(time, try c.number(a, try field(try field(record, "payload"), "createdAt")));
    const local = try merge(a, .{ .entries = &.{}, .invalid = 0, .unreadable = 0 }, v, 42161, address, null);
    for (local.entries, listing.entries) |left, right| try std.testing.expectEqualStrings(try c.string(try field(left, "pendingId")), try c.string(try field(right, "pendingId")));
}
