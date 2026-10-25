const std = @import("std");
const c = @import("common.zig");
const abi = @import("abi_codec.zig");
const Client = @import("contract_client.zig").Client;
fn required(value: c.Value, name: []const u8) !c.Value {
    return c.field(value, name) orelse error.InvalidSafeTransaction;
}

/// Safe 1.5 indexes txHash; reviewed earlier releases put it in event data.
/// Require one matching success event even when the outer receipt succeeded.
pub fn verifySuccess(a: c.A, cat: @import("contracts.zig").Catalog, receipt: c.Value, address: []const u8, hash: c.Value) !void {
    const definition = cat.event("ExecutionSuccess") orelse return error.InvalidArtifact;
    const topic = try c.hex(a, @import("miniscript").bytecode.hash(try @import("contracts.zig").signature(a, definition, false)));
    var found = false;
    const logs = try required(receipt, "logs");
    if (logs != .array) return error.InvalidTransactionReceipt;
    for (logs.array.items) |log| {
        if (!std.ascii.eqlIgnoreCase(try c.string(try required(log, "address")), address)) continue;
        const topics = try required(log, "topics");
        if (topics != .array or topics.array.items.len == 0) return error.InvalidTransactionReceipt;
        if (!std.ascii.eqlIgnoreCase(try c.string(topics.array.items[0]), topic)) continue;
        const data = try abi.unhex(a, try c.string(try required(log, "data")));
        const actual = if (topics.array.items.len == 1 and data.len == 64)
            std.mem.readInt(u256, data[0..32], .big)
        else if (topics.array.items.len == 2 and data.len == 32)
            try c.number(a, topics.array.items[1])
        else
            return error.InvalidSafeExecutionEvent;
        if (found or actual != try c.number(a, hash)) return error.SafeTransactionMismatch;
        found = true;
    }
    if (!found) return error.SafeExecutionFailed;
}
pub fn typed(a: c.A, primary: []const u8, fields: c.Value, domain: c.Value, message: c.Value) !c.Value {
    var types: c.Value = .{ .object = .empty };
    try types.object.put(a, "EIP712Domain", try c.parse(a, if (c.eq(u8, primary, "SafeTx"))
        "[{\"name\":\"chainId\",\"type\":\"uint256\"},{\"name\":\"verifyingContract\",\"type\":\"address\"}]"
    else
        "[{\"name\":\"name\",\"type\":\"string\"},{\"name\":\"version\",\"type\":\"string\"},{\"name\":\"chainId\",\"type\":\"uint256\"},{\"name\":\"verifyingContract\",\"type\":\"address\"}]"));
    try types.object.put(a, primary, fields);
    return c.parse(a, try c.encode(a, .{ .types = types, .primaryType = primary, .domain = domain, .message = message }));
}
pub fn sign(safe: Client, values: []const c.Value, dry: bool) !c.Value {
    const cast = safe.cast;
    const a = cast.a;
    const nonce = values[9];
    const tx_hash = try safe.first("getTransactionHash", values);
    const method = try safe.cat.find("safe", "getTransactionHash");
    var fields = (try required(method.abi, "inputs")).array;
    // Safe's helper calls this parameter _nonce; EIP-712 calls it nonce.
    fields.items = try a.dupe(c.Value, fields.items);
    fields.items[9].object = try fields.items[9].object.clone(a);
    try fields.items[9].object.put(a, "name", .{ .string = "nonce" });
    const tx_message = try abi.named(a, .{ .array = fields }, try abi.array(a, values));
    const tx_domain = try c.parse(a, try c.encode(a, .{ .chainId = cast.chain, .verifyingContract = cast.instance }));
    const typed_data = try typed(a, "SafeTx", .{ .array = fields }, tx_domain, tx_message);
    return try c.parse(a, try c.encode(a, .{ .signer = try cast.signerAddress(), .signatureType = if (cast.auth != null) "contract" else "eoa", .transactionHash = tx_hash, .safeNonce = nonce, .typedData = typed_data, .signature = if (dry) @as(?[]const u8, null) else try cast.signTypedData(typed_data) }));
}
pub fn pack(a: c.A, signatures: c.Value, tx_hash: c.Value) ![]const u8 {
    if (signatures != .array or signatures.array.items.len == 0) return error.InvalidSafeSignatures;
    var sorted: std.ArrayList(struct { address: u160, signature: []const u8, contract: bool }) = .empty;
    for (signatures.array.items) |entry| {
        if (try c.number(a, try required(entry, "transactionHash")) != try c.number(a, tx_hash)) return error.SafeTransactionMismatch;
        const signer = try c.string(try required(entry, "signer"));
        try c.address(signer);
        const sig = try c.string(try required(entry, "signature"));
        const bytes = try abi.unhex(a, sig);
        const kind = if (c.field(entry, "signatureType")) |v| try c.string(v) else "eoa";
        const contract = c.eq(u8, kind, "contract");
        if (!contract and !c.eq(u8, kind, "eoa")) return error.InvalidSafeSignatures;
        if (if (contract) bytes.len == 0 or bytes.len > 16384 else bytes.len != 65 or (bytes[64] != 27 and bytes[64] != 28)) return error.InvalidSafeSignatures;
        try sorted.append(a, .{ .address = @intCast(try c.word(signer)), .signature = bytes, .contract = contract });
    }
    const Item = @TypeOf(sorted.items[0]);
    std.mem.sort(Item, sorted.items, {}, struct {
        fn less(_: void, l: Item, r: Item) bool {
            return l.address < r.address;
        }
    }.less);
    var fixed: std.ArrayList(u8) = .empty;
    var dynamic: std.ArrayList(u8) = .empty;
    for (sorted.items, 0..) |entry, i| {
        if (i > 0 and sorted.items[i - 1].address == entry.address) return error.DuplicateSafeSigner;
        if (!entry.contract) {
            try fixed.appendSlice(a, entry.signature);
            continue;
        }
        // Safe contract-owner signatures use an address and a dynamic offset
        // in the 65-byte static slot, followed by length-prefixed ERC-1271 data.
        var slot: [65]u8 = @splat(0);
        std.mem.writeInt(u256, slot[0..32], entry.address, .big);
        std.mem.writeInt(u256, slot[32..64], sorted.items.len * 65 + dynamic.items.len, .big);
        try fixed.appendSlice(a, &slot);
        var length: [32]u8 = undefined;
        std.mem.writeInt(u256, &length, entry.signature.len, .big);
        try dynamic.appendSlice(a, &length);
        try dynamic.appendSlice(a, entry.signature);
    }
    try fixed.appendSlice(a, dynamic.items);
    return abi.hex(a, fixed.items);
}

test "Safe receipt success requires the intended hash in either reviewed event layout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cat = try @import("contracts.zig").Catalog.loadAuxiliary(a);
    const topic = try c.hex(a, @import("miniscript").bytecode.hash("ExecutionSuccess(bytes32,uint256)"));
    const address = "0x1111111111111111111111111111111111111111";
    const hash = try c.hex(a, 42);
    for ([_]bool{ false, true }) |indexed| {
        const data = if (indexed) try c.hex(a, 0) else try a.print("{s}{s}", .{ hash, (try c.hex(a, 0))[2..] });
        const topics = if (indexed) try abi.array(a, &.{ .{ .string = topic }, .{ .string = hash } }) else try abi.array(a, &.{.{ .string = topic }});
        const receipt = try c.parse(a, try c.encode(a, .{ .logs = .{.{ .address = address, .topics = topics, .data = data }} }));
        try verifySuccess(a, cat, receipt, address, .{ .string = hash });
        try std.testing.expectError(error.SafeTransactionMismatch, verifySuccess(a, cat, receipt, address, try abi.uint(a, 43)));
    }
    try std.testing.expectError(error.SafeExecutionFailed, verifySuccess(a, cat, try c.parse(a, "{\"logs\":[]}"), address, .{ .string = hash }));
}
