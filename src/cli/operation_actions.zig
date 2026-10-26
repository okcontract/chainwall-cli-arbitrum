const std = @import("std");
const c = @import("common.zig");
const abi = @import("abi_codec.zig");
const operations = @import("operations.zig");
const Client = @import("contract_client.zig").Client;
const safe_tx = @import("safe_transactions.zig");
const Args = @import("args.zig").Args;
const rpc = @import("rpc.zig");
const modules = @import("module_execution.zig");
const zero = "0x0000000000000000000000000000000000000000";

fn required(value: c.Value, name: []const u8) !c.Value {
    return c.field(value, name) orelse error.InvalidOperationPayload;
}
pub fn read(client: Client, file: []const u8) !c.Value {
    const value = try @import("json_schema.zig").read(client.cast.a, client.cast.io, "operation-document", file);
    if (c.field(value, "type") != null) return required(try @import("operation_share.zig").verify(client, value), "payload");
    return c.field(value, "payload") orelse value;
}
fn put(a: c.A, obj: *c.Value, key: []const u8, value: c.Value) !void {
    if (obj.* != .object) return error.InvalidOperationPayload;
    try obj.object.put(a, key, value);
}
fn same(a: c.A, left: c.Value, right: c.Value) !void {
    if (try c.number(a, left) != try c.number(a, right)) return error.OperationMismatch;
}
pub fn validate(client: Client, payload: c.Value) !void {
    const a = client.cast.a;
    try same(a, try required(payload, "version"), try abi.uint(a, 2));
    try same(a, try required(payload, "chainId"), try abi.uint(a, client.cast.chain));
    const id = try required(payload, "operationId");
    if (try c.number(a, id) == 0 or (try client.first("isOperationExecuted", &.{id})).bool) return error.OperationClosed;
    for ([_][2][]const u8{ .{ "getOperationSafe", "safe" }, .{ "getOperationPolicyId", "policyId" }, .{ "getOperationNativeValue", "nativeValue" } }) |entry| {
        try same(a, try client.first(entry[0], &.{id}), try required(payload, entry[1]));
    }
    const binding = try client.first("getExecutionBindingHash", &.{ try required(payload, "interactionId"), try required(payload, "policyId") });
    try same(a, binding, try required(payload, "executionBindingHash"));
    try same(a, try hash(client, payload), try required(payload, "payloadHash"));
    _ = try operations.encodeProposal(a, payload);
}
fn hash(client: Client, payload: c.Value) !c.Value {
    return client.first("getPayloadHash", &.{ try required(payload, "interactionId"), try required(payload, "args"), try required(payload, "policyId"), try required(payload, "deadline"), try required(payload, "nativeValue"), try required(payload, "safe") });
}
pub fn propose(client: Client, args: *Args, file: []const u8, dry: bool) !c.Value {
    const cast = client.cast;
    const a = cast.a;
    const out = args.get("out");
    try args.finish();
    if (!dry and out == null) return error.ProposalOutputFileRequired;
    var payload = try read(client, file);
    if (c.field(payload, "operationId")) |id| if (try c.number(a, id) != 0) return error.OperationAlreadyProposed;
    if (c.field(payload, "chainId")) |chain| try same(a, chain, try abi.uint(a, cast.chain));
    const safe = try cast.resolveAddress(try c.string(try required(payload, "safe")));
    try c.address(safe);
    try put(a, &payload, "safe", .{ .string = safe });
    try put(a, &payload, "version", try abi.uint(a, 2));
    try put(a, &payload, "chainId", try abi.uint(a, cast.chain));
    try put(a, &payload, "nativeValue", c.field(payload, "nativeValue") orelse try abi.uint(a, 0));
    try put(a, &payload, "args", c.field(payload, "args") orelse try abi.array(a, &.{}));
    const binding = try client.first("getExecutionBindingHash", &.{ try required(payload, "interactionId"), try required(payload, "policyId") });
    try put(a, &payload, "executionBindingHash", binding);
    try put(a, &payload, "payloadHash", try hash(client, payload));
    const values = [_]c.Value{ try required(payload, "payloadHash"), try required(payload, "policyId"), try required(payload, "deadline"), try required(payload, "nativeValue"), try required(payload, "safe") };
    if (dry) return c.parse(a, try c.encode(a, .{ .payload = payload, .transaction = try client.transaction("propose", &values, null, true) }));
    if (cast.block != null) return error.TransactionRequiresLatestBlock;
    try put(a, &payload, "creator", .{ .string = try cast.signerAddress() });
    try put(a, &payload, "operationId", try abi.uint(a, 0));
    try put(a, &payload, "createdAt", try abi.uint(a, 0));
    // Reserve a private recovery file before any broadcast. Never overwrite a
    // previous proposal; after mining it contains the app-compatible payload.
    try c.write(cast.io, out.?, try c.encode(a, .{ .payload = payload, .state = "prepared" }), false);
    const receipt = try client.transaction("propose", &values, null, false);
    try c.write(cast.io, out.?, try c.encode(a, .{ .payload = payload, .state = "mined", .receipt = receipt }), true);
    const event = try @import("deploy.zig").event(a, client.cat, receipt, cast.instance, "OperationProposed");
    try put(a, &payload, "operationId", try required(event, "operationId"));
    try c.write(cast.io, out.?, try c.encode(a, .{ .payload = payload, .state = "mined", .receipt = receipt }), true);
    const block = try c.parse(a, try cast.run(&.{ "block", try c.scalar(a, try required(receipt, "blockNumber")), "--rpc-url", cast.rpc, "--json" }));
    try put(a, &payload, "createdAt", try abi.uint(a, try c.number(a, try required(block, "timestamp"))));
    const record = try operations.proposal(a, try operations.encodeProposal(a, payload));
    var saved = record;
    try saved.object.put(a, "proposalTxHash", try required(receipt, "transactionHash"));
    try c.write(cast.io, out.?, try c.encode(a, saved), true);
    return c.parse(a, try c.encode(a, .{ .proposal = record, .file = out.?, .receipt = receipt }));
}
pub fn status(client: Client, id: c.Value) !c.Value {
    const closed = (try client.first("isOperationExecuted", &.{id})).bool;
    if (closed) return c.parse(client.cast.a, try c.encode(client.cast.a, .{ .operationId = id, .closed = true }));
    return c.parse(client.cast.a, try c.encode(client.cast.a, .{ .operationId = id, .closed = false, .safe = try client.first("getOperationSafe", &.{id}), .policyId = try client.first("getOperationPolicyId", &.{id}), .nativeValue = try client.first("getOperationNativeValue", &.{id}), .executor = try client.first("getOperationExecutor", &.{id}), .approved = try client.first("isOperationApproved", &.{id}) }));
}

pub fn execute(client: Client, args: *Args, file: []const u8, verb: []const u8, dry: bool) !c.Value {
    const cast = client.cast;
    const a = cast.a;
    const options = try @import("command_options.zig").Operation.parse(args, false);
    const mode = @tagName(cast.route);
    const is_module = cast.route == .module;
    const is_safe = cast.route != .account;
    const bundled = is_module and modules.bundled(cast) and !c.eq(u8, verb, "sign-actor");
    const approve = options.approve;
    const max_steps = try abi.uint(a, options.max_steps);
    const actor_file = options.actor_file;
    const signatures_file = options.signatures_file;
    const reveal_file = options.reveal_file;
    const out = options.out;
    if (!dry and cast.block != null) return error.TransactionRequiresLatestBlock;
    if (is_module and (signatures_file != null or c.eq(u8, verb, "sign"))) return error.InvalidSigningOptions;
    if (bundled and actor_file != null) return error.InvalidSigningOptions;
    const payload = try read(client, file);
    try validate(client, payload);
    const account = try c.string(try required(payload, "safe"));
    var remote = try rpc.Rpc.init(a, cast.io, cast.rpc, cast.chain, cast.instance);
    defer remote.deinit();
    const registry = if (is_module) try c.string(try client.first("registry", &.{})) else "";
    const module = if (is_module) blk: {
        try remote.pin(cast.block, 0);
        break :blk try modules.resolve(&remote, client, registry, account);
    } else null;
    const method_name = try a.print("{s}{s}{s}", .{ if (approve) "approveAndExecute" else "execute", if (reveal_file != null) "Private" else "", if (is_safe) "" else "FromAccount" });
    var values = std.json.Array.init(a);
    try values.appendSlice(&.{ try required(payload, "operationId"), try required(payload, "interactionId"), try required(payload, "args"), max_steps });
    if (reveal_file) |path| try values.append(try @import("json_schema.zig").read(a, cast.io, "interaction-reveal", path));
    var data = try client.data(method_name, values.items);
    const sign_actor = c.eq(u8, verb, "sign-actor");
    if (module) |target| {
        if (!try remote.canonical(remote.block)) return error.ChainReorganizedRetrySync;
        _ = target;
    }
    if (out) |path| try c.write(cast.io, path, try c.encode(a, .{ .state = "prepared", .via = mode, .payload = payload, .data = data }), false);
    if (sign_actor) {
        if (!is_safe or actor_file != null or signatures_file != null) return error.InvalidActorSigningOptions;
        const actor = if (dry) try cast.callerAddress() else try cast.signerAddress();
        const typed_data = try actorTyped(client, account, actor, data[0..10], try required(payload, "operationId"));
        const result = try c.parse(a, try c.encode(a, .{ .actor = actor, .typedData = typed_data, .signature = if (dry) @as(?[]const u8, null) else try cast.signTypedData(typed_data) }));
        if (out) |path| try c.write(cast.io, path, try c.encode(a, result), true);
        return result;
    }
    if (!is_safe) {
        if (actor_file != null or signatures_file != null or c.eq(u8, verb, "sign")) return error.SafeExecutionRequired;
        const result = try client.transaction(method_name, values.items, null, dry);
        if (out) |path| try c.write(cast.io, path, try c.encode(a, result), true);
        return result;
    }
    const auth = if (actor_file) |path| try @import("json_schema.zig").read(a, cast.io, "actor-signature", path) else if (is_module) blk: {
        const actor = if (dry) try cast.callerAddress() else try cast.signerAddress();
        const typed_data = try actorTyped(client, account, actor, data[0..10], try required(payload, "operationId"));
        break :blk try c.parse(a, try c.encode(a, .{ .actor = actor, .typedData = typed_data, .signature = if (dry or bundled) "0x" else try cast.signTypedData(typed_data) }));
    } else return error.ActorSignatureFileRequired;
    const actor = try c.string(try required(auth, "actor"));
    try c.address(actor);
    const auth_typed = try required(auth, "typedData");
    const signing = @import("auth_signer.zig");
    const expected = try actorTyped(client, account, actor, data[0..10], try required(payload, "operationId"));
    try same(a, .{ .string = try signing.typedHash(a, expected) }, .{ .string = try signing.typedHash(a, auth_typed) });
    const signature = try c.string(try required(auth, "signature"));
    if (module) |target| {
        var module_cast = cast.*;
        module_cast.instance = target.address;
        module_cast.checked = false;
        const destination: Client = .{ .cast = &module_cast, .cat = target.entry.cat, .group = try c.string(c.field(target.entry.item, "group").?) };
        var module_values = std.json.Array.init(a);
        try module_values.appendSlice(&.{ .{ .string = account }, try required(payload, "operationId"), try required(payload, "interactionId"), try required(payload, "args"), max_steps, try required(payload, "nativeValue") });
        if (reveal_file != null) try module_values.append(values.items[values.items.len - 1]);
        const name = try a.print("{s}Interaction{s}", .{ if (approve) "approveAndExecute" else "execute", if (reveal_file != null) "Private" else "" });
        var transaction = try destination.transaction(name, module_values.items, null, true);
        const unsigned = (dry and actor_file == null) or bundled;
        const final_data = if (unsigned) try c.string(try required(transaction, "data")) else try modules.trailer(a, try c.string(try required(transaction, "data")), actor, signature);
        try transaction.object.put(a, "data", .{ .string = final_data });
        if (bundled) {
            transaction = try modules.userOperation(client, target, final_data, try signing.typedHash(a, expected));
            module_cast.instance = try c.string(try required(transaction, "to"));
        }
        var result = try c.parse(a, try c.encode(a, .{ .via = mode, .module = target.address, .transaction = transaction, .actor = actor, .typedData = auth_typed, .signed = !unsigned }));
        if (!try remote.canonical(remote.block)) return error.ChainReorganizedRetrySync;
        if (out) |path| try c.write(cast.io, path, try c.encode(a, result), true);
        if (dry) return result;
        try remote.pin(null, 0);
        if (!std.ascii.eqlIgnoreCase(target.address, (try modules.resolve(&remote, client, registry, account)).address)) return error.AccountBindingsMismatch;
        if (!bundled) {
            const sender = try modules.sender(cast);
            _ = try remote.one("eth_call", try abi.array(a, &.{ try c.parse(a, try c.encode(a, .{ .from = sender, .to = target.address, .data = final_data, .value = "0x0" })), try remote.blockSelector() }));
        }
        if (!try remote.canonical(remote.block)) return error.ChainReorganizedRetrySync;
        const receipt = try modules.send(&module_cast, try c.string(try required(transaction, "data")));
        cast.nonce = module_cast.nonce;
        try result.object.put(a, "receipt", receipt);
        if (out) |path| try c.write(cast.io, path, try c.encode(a, result), true);
        try modules.verify(target, a, receipt, account, try required(payload, "interactionId"), try required(payload, "operationId"));
        return result;
    }
    data = try modules.trailer(a, data, actor, signature);
    const interact = cast.instance;
    const checked = cast.checked;
    cast.instance = account;
    cast.checked = false;
    defer {
        cast.instance = interact;
        cast.checked = checked;
    }
    const safe: Client = .{ .cast = cast, .cat = client.cat, .group = "safe" };
    const nonce = try safe.first("nonce", &.{});
    const tx_values = [_]c.Value{ .{ .string = interact }, try required(payload, "nativeValue"), .{ .string = data }, try abi.uint(a, 0), try abi.uint(a, 0), try abi.uint(a, 0), try abi.uint(a, 0), .{ .string = zero }, .{ .string = zero }, nonce };
    const tx_hash = try safe.first("getTransactionHash", &tx_values);
    if (c.eq(u8, verb, "sign")) {
        if (signatures_file != null) return error.InvalidSigningOptions;
        const result = try safe_tx.sign(safe, &tx_values, dry);
        if (out) |path| try c.write(cast.io, path, try c.encode(a, result), true);
        return result;
    }
    const packed_signatures = if (signatures_file) |path|
        try safe_tx.pack(a, try @import("json_schema.zig").read(a, cast.io, "safe-signatures", path), tx_hash)
    else if (dry) "0x" else return error.SafeSignaturesFileRequired;
    var send_values = tx_values;
    send_values[9] = .{ .string = packed_signatures };
    const result = try safe.transaction("execTransaction", &send_values, null, dry);
    const output = try c.parse(a, try c.encode(a, .{ .transaction = result, .transactionHash = tx_hash, .safeNonce = nonce }));
    if (out) |path| try c.write(cast.io, path, try c.encode(a, output), true);
    if (!dry) {
        // Safe can return a successful outer receipt with ExecutionFailure.
        try safe_tx.verifySuccess(a, client.cat, result, account, tx_hash);
    }
    return output;
}

fn actorTyped(client: Client, account: []const u8, actor: []const u8, selector: []const u8, operation: c.Value) !c.Value {
    const a = client.cast.a;
    const fields = try c.parse(a, "[{\"name\":\"actor\",\"type\":\"address\"},{\"name\":\"forwarder\",\"type\":\"address\"},{\"name\":\"selector\",\"type\":\"bytes4\"},{\"name\":\"operationId\",\"type\":\"uint256\"},{\"name\":\"chainId\",\"type\":\"uint256\"}]");
    const domain = try c.parse(a, try c.encode(a, .{ .name = "Interact", .version = "1", .chainId = client.cast.chain, .verifyingContract = client.cast.instance }));
    const message = try c.parse(a, try c.encode(a, .{ .actor = actor, .forwarder = account, .selector = selector, .operationId = operation, .chainId = client.cast.chain }));
    return safe_tx.typed(a, "ExecutionActor", fields, domain, message);
}
