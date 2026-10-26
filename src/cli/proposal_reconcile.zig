//! Recover prepared/mined proposal files from canonical transaction evidence.
const std = @import("std");
const c = @import("common.zig");
const ms = @import("miniscript");
const abi = @import("abi_codec.zig");
const rpc = @import("rpc.zig");
const Client = @import("contract_client.zig").Client;
fn field(v: c.Value, name: []const u8) !c.Value {
    return c.field(v, name) orelse error.InvalidOperationPayload;
}
fn same(a: c.A, left: c.Value, right: c.Value) !void {
    if (try c.number(a, left) != try c.number(a, right)) return error.ProposalEvidenceMismatch;
}
pub fn run(client: Client, registry: []const u8, args: *@import("args.zig").Args, file: []const u8, dry: bool) !c.Value {
    const cast = client.cast;
    const a = cast.a;
    const selected_hash = args.get("proposal-tx");
    const out = args.get("out") orelse file;
    try args.finish();
    const bytes = try c.read(a, cast.io, file);
    const input = try c.parse(a, bytes);
    const payload = c.field(input, "payload") orelse input;
    if (payload != .object) return error.InvalidOperationPayload;
    const receipt_hint = c.field(input, "receipt") orelse .null;
    const transaction_hash = selected_hash orelse try c.string(c.field(input, "proposalTxHash") orelse c.field(receipt_hint, "transactionHash") orelse return error.ProposalTransactionHashRequired);
    if (transaction_hash.len != 66) return error.InvalidTransactionHash;
    _ = try c.word(transaction_hash);
    for ([_]?c.Value{ c.field(input, "proposalTxHash"), c.field(receipt_hint, "transactionHash") }) |hint| if (hint) |value| try same(a, value, .{ .string = transaction_hash });
    try same(a, try field(payload, "chainId"), try abi.uint(a, cast.chain));
    var remote = try rpc.Rpc.init(a, cast.io, cast.rpc, cast.chain, cast.instance);
    defer remote.deinit();
    try remote.pin(cast.block, 0);
    const checks = try @import("metadata_batch.zig").read(&remote, &.{
        .{ .address = cast.instance, .method = try client.cat.find("interact", "chainwallComponentId") },
        .{ .address = cast.instance, .method = try client.cat.find("interact", "registry") },
    });
    try same(a, try checks[0].require(), .{ .string = try c.hex(a, ms.bytecode.hash("Chainwall.Interact")) });
    try same(a, try checks[1].require(), .{ .string = registry });
    const transaction = try remote.one("eth_getTransactionByHash", try abi.array(a, &.{.{ .string = transaction_hash }}));
    if (transaction == .null) return error.ProposalTransactionUnavailable;
    const receipt = try remote.one("eth_getTransactionReceipt", try abi.array(a, &.{.{ .string = transaction_hash }}));
    if (receipt == .null) return error.TransactionReceiptUnavailable;
    const height = try rpc.integer(a, try field(receipt, "blockNumber"));
    if (height > remote.block.number) return error.ProposalEvidenceMismatch;
    const block = try remote.blockAt(try rpc.quantity(a, height));
    const record = try recover(client, payload, transaction_hash, transaction, receipt, block);
    if (!try remote.canonical(block) or !try remote.canonical(remote.block)) return error.TransactionReorganized;
    const serialized = try c.encode(a, record);
    if (!dry) {
        if (c.eq(u8, out, file)) {
            if (!c.eq(u8, bytes, try c.read(a, cast.io, file))) return error.ProposalFileChanged;
            if (!c.eq(u8, bytes, serialized)) try c.write(cast.io, out, serialized, true);
        } else if (c.read(a, cast.io, out)) |existing| {
            if (!c.eq(u8, existing, serialized)) return error.PathAlreadyExists;
        } else |err| {
            if (err != error.FileNotFound) return err;
            try c.write(cast.io, out, serialized, false);
        }
    }
    return c.parse(a, try c.encode(a, .{ .proposal = record, .file = if (dry) null else out, .receipt = receipt, .state = "reconciled", .submitted = false }));
}

fn recover(client: Client, original: c.Value, hash: []const u8, transaction: c.Value, receipt: c.Value, block: rpc.Block) !c.Value {
    const a = client.cast.a;
    var payload = original;
    try same(a, try field(transaction, "hash"), .{ .string = hash });
    try same(a, try field(transaction, "to"), .{ .string = client.cast.instance });
    try same(a, try field(transaction, "from"), try field(payload, "creator"));
    try same(a, try field(transaction, "value"), try abi.uint(a, 0));
    if (c.field(transaction, "chainId")) |chain| try same(a, chain, try field(payload, "chainId"));
    const method = try client.cat.find("interact", "getPayloadHash");
    var params = std.json.Array.init(a);
    try params.appendSlice((try field(method.abi, "inputs")).array.items);
    try params.append(try c.parse(a, "{\"type\":\"bytes32\",\"name\":\"executionBindingHash\"}"));
    const values = try abi.array(a, &.{ try field(payload, "interactionId"), try field(payload, "args"), try field(payload, "policyId"), try field(payload, "deadline"), try field(payload, "nativeValue"), try field(payload, "safe"), try field(payload, "executionBindingHash") });
    try same(a, try field(payload, "payloadHash"), .{ .string = try c.hex(a, ms.bytecode.hash(try abi.encode(a, .{ .array = params }, values))) });
    const expected = try client.data("propose", &.{ try field(payload, "payloadHash"), try field(payload, "policyId"), try field(payload, "deadline"), try field(payload, "nativeValue"), try field(payload, "safe") });
    if (!std.ascii.eqlIgnoreCase(expected, try c.string(c.field(transaction, "input") orelse try field(transaction, "data")))) return error.ProposalEvidenceMismatch;
    if (try c.number(a, try field(receipt, "status")) != 1) return error.ProposalTransactionReverted;
    try same(a, try field(receipt, "transactionHash"), .{ .string = hash });
    try same(a, try field(receipt, "blockHash"), .{ .string = block.hash });
    try same(a, try field(receipt, "blockNumber"), try abi.uint(a, block.number));
    try same(a, try field(transaction, "blockHash"), .{ .string = block.hash });
    try same(a, try field(transaction, "blockNumber"), try abi.uint(a, block.number));
    for ((try field(receipt, "logs")).array.items) |log| {
        if (!std.ascii.eqlIgnoreCase(try c.string(try field(log, "address")), client.cast.instance)) continue;
        if ((c.field(log, "removed") orelse c.Value{ .bool = false }).bool) return error.TransactionReorganized;
        try same(a, try field(log, "transactionHash"), .{ .string = hash });
        try same(a, try field(log, "blockHash"), .{ .string = block.hash });
        try same(a, try field(log, "blockNumber"), try abi.uint(a, block.number));
    }
    const event = try @import("deploy.zig").event(a, client.cat, receipt, client.cast.instance, "OperationProposed");
    const id = try field(event, "operationId");
    if (try c.number(a, id) == 0) return error.ProposalEvidenceMismatch;
    if (c.field(payload, "operationId")) |old| if (try c.number(a, old) != 0) try same(a, old, id);
    if (c.field(payload, "createdAt")) |old| if (try c.number(a, old) != 0) try same(a, old, try abi.uint(a, block.timestamp));
    try payload.object.put(a, "operationId", id);
    try payload.object.put(a, "createdAt", try abi.uint(a, block.timestamp));
    var record = try @import("operations.zig").proposal(a, try @import("operations.zig").encodeProposal(a, payload));
    try record.object.put(a, "proposalTxHash", .{ .string = hash });
    return record;
}
