const std = @import("std");
const ms = @import("miniscript");
const c = @import("common.zig");
const abi = @import("abi_codec.zig");
const contracts = @import("contracts.zig");
const rpc = @import("rpc.zig");
const Client = @import("contract_client.zig").Client;
const Args = @import("args.zig").Args;
const safe_tx = @import("safe_transactions.zig");
const auth = @import("auth_signer.zig");
const modules = @import("module_execution.zig");
const zero = "0x0000000000000000000000000000000000000000";

fn field(value: c.Value, name: []const u8) !c.Value {
    return c.field(value, name) orelse error.InvalidDirectExecution;
}
fn same(a: c.A, left: c.Value, right: c.Value) !void {
    if (try c.number(a, left) != try c.number(a, right)) return error.DirectExecutionChanged;
}
fn read(remote: *rpc.Rpc, client: Client, name: []const u8, values: []const c.Value) !c.Value {
    return remote.namedAt(client.cast.instance, try client.cat.find(client.group, name), values);
}

pub fn typed(a: c.A, payload: c.Value, actor: []const u8, forwarder: []const u8, interact: []const u8, chain: u64, nonce: c.Value, binding: c.Value, max_steps: c.Value, is_safe: bool) !c.Value {
    const encoded_args = try abi.encode(a, try c.parse(a, "[{\"type\":\"uint256[]\"}]"), try abi.array(a, &.{try field(payload, "args")}));
    var message = try c.parse(a, try c.encode(a, .{ .actor = actor, .forwarder = forwarder, .policyId = try field(payload, "policyId"), .interactionId = try field(payload, "interactionId"), .argsHash = try c.hex(a, ms.bytecode.hash(encoded_args)), .executionBindingHash = binding, .maxSteps = max_steps, .nativeValue = try field(payload, "nativeValue"), .deadline = try field(payload, "deadline"), .chainId = chain, .nonce = nonce }));
    if (!is_safe) try message.object.put(a, "account", try field(payload, "safe"));
    const primary = if (is_safe) "DirectExecute" else "DirectExecuteFromAccount";
    const fields = try field(try c.parse(a, @embedFile("artifacts/execution-types.json")), primary);
    const domain = try c.parse(a, try c.encode(a, .{ .name = "Interact", .version = "1", .chainId = chain, .verifyingContract = interact }));
    return safe_tx.typed(a, primary, fields, domain, message);
}

pub fn run(client: Client, registry: []const u8, args: *Args, file: []const u8, verb: []const u8, dry: bool) !c.Value {
    const cast = client.cast;
    const a = cast.a;
    const options = try @import("command_options.zig").Operation.parse(args, true);
    const mode = @tagName(cast.route);
    const is_module = cast.route == .module;
    const is_safe = cast.route != .account;
    const actor_option = options.actor;
    const actor_file = options.actor_file;
    const signatures_file = options.signatures_file;
    const reveal_file = options.reveal_file;
    const out = options.out;
    const max_steps = try abi.uint(a, options.max_steps);
    const sign_actor = c.eq(u8, verb, "direct-sign-actor");
    const sign_safe = c.eq(u8, verb, "direct-sign");
    const bundled = is_module and modules.bundled(cast) and !sign_actor;
    try args.finish();
    if (!dry and cast.block != null) return error.TransactionRequiresLatestBlock;
    if ((!is_safe and (sign_safe or signatures_file != null)) or (sign_actor and (actor_file != null or signatures_file != null)) or (sign_safe and signatures_file != null)) return error.InvalidSigningOptions;
    if (is_module and (sign_safe or signatures_file != null)) return error.InvalidSigningOptions;
    if (bundled and actor_file != null) return error.InvalidSigningOptions;
    var payload = try @import("operation_actions.zig").read(client, file);
    if (payload != .object) return error.InvalidDirectExecution;
    if (c.field(payload, "operationId")) |id| if (try c.number(a, id) != 0) return error.DirectExecutionCannotUseProposal;
    if (c.field(payload, "chainId")) |id| try same(a, id, try abi.uint(a, cast.chain));
    const account = try cast.resolveAddress(try c.string(try field(payload, "safe")));
    try c.address(account);
    try payload.object.put(a, "safe", .{ .string = account });
    try payload.object.put(a, "args", c.field(payload, "args") orelse try abi.array(a, &.{}));
    try payload.object.put(a, "nativeValue", c.field(payload, "nativeValue") orelse try abi.uint(a, 0));
    for ([_][]const u8{ "policyId", "interactionId" }) |key| try payload.object.put(a, key, .{ .string = try c.id(a, try c.string(try field(payload, key))) });
    const saved_auth = if (actor_file) |path| try @import("json_schema.zig").read(a, cast.io, "actor-signature", path) else @as(c.Value, .null);
    const selected_actor = actor_option orelse if (saved_auth != .null) try c.string(try field(saved_auth, "actor")) else if (cast.auth != null) try cast.signerAddress() else cast.from orelse try cast.signerAddress();
    const actor = try cast.resolveAddress(selected_actor);
    try c.address(actor);
    if (bundled and !std.ascii.eqlIgnoreCase(actor, try cast.signerAddress())) return error.SignerAddressMismatch;
    const forwarder = if (is_safe) account else if (dry and cast.account == null and cast.keystore == null and cast.auth == null and !cast.unlocked) actor else try cast.signerAddress();
    var remote = try rpc.Rpc.init(a, cast.io, cast.rpc, cast.chain, cast.instance);
    defer remote.deinit();
    try remote.pin(cast.block, 0);
    try same(a, try read(&remote, client, "registry", &.{}), .{ .string = registry });
    const module = if (is_module) try modules.resolve(&remote, client, registry, account) else null;
    const deadline = try c.number(a, try field(payload, "deadline"));
    if (deadline == 0 or deadline <= remote.block.timestamp) return error.DirectExecutionDeadlineRequired;
    if (try c.number(a, max_steps) == 0) return error.InvalidDirectExecution;
    const registry_cat = try contracts.Catalog.load(a);
    if (!(try remote.namedAt(registry, try registry_cat.find("accounts", if (is_safe) "isSafeAllowed" else "isAccountAllowed"), &.{.{ .string = account }})).bool) return error.AccountBindingsMismatch;
    if (!is_safe) {
        try same(a, try remote.namedAt(account, try client.cat.find("ok-account", "REGISTRY"), &.{}), .{ .string = registry });
        try same(a, try remote.namedAt(account, try client.cat.find("ok-account", "INTERACT"), &.{}), .{ .string = cast.instance });
    }
    const binding_values = [_]c.Value{ try field(payload, "interactionId"), try field(payload, "policyId") };
    if (!(try read(&remote, client, "canUserSatisfyPolicy", &.{ binding_values[1], .{ .string = actor } })).bool) return error.DirectPolicyRequiresProposal;
    const binding = try read(&remote, client, "getExecutionBindingHash", &binding_values);
    if (c.field(payload, "executionBindingHash")) |expected| try same(a, binding, expected);
    const actor_nonce = try read(&remote, client, "directExecuteNonce", &.{.{ .string = actor }});
    const typed_data = try typed(a, payload, actor, forwarder, cast.instance, cast.chain, actor_nonce, binding, max_steps, is_safe);
    const digest = try auth.typedHash(a, typed_data);
    var result = try c.parse(a, try c.encode(a, .{ .chainId = cast.chain, .registry = registry, .interact = cast.instance, .via = mode, .payload = payload, .actor = actor, .actorNonce = actor_nonce, .typedData = typed_data, .digest = digest, .block = remote.block }));
    if (out) |path| try c.write(cast.io, path, try c.encode(a, result), false);
    var signature: []const u8 = "0x";
    if (saved_auth != .null) {
        try same(a, .{ .string = try auth.typedHash(a, try field(saved_auth, "typedData")) }, .{ .string = digest });
        signature = try c.string(try field(saved_auth, "signature"));
        const bytes = try abi.unhex(a, signature);
        if (bytes.len == 0 or bytes.len > 16384) return error.InvalidSignature;
    } else if (!dry and (!is_safe or is_module or sign_actor)) {
        if (!std.ascii.eqlIgnoreCase(actor, try cast.signerAddress())) return error.SignerAddressMismatch;
        // AuthAccounts authorize account calls through their protocol-call
        // challenge, which binds the current authorization/runtime revision.
        if (!bundled and (cast.auth == null or is_safe or sign_actor)) signature = try cast.signTypedData(typed_data);
    } else if (is_safe and !sign_actor and !dry) return error.ActorSignatureFileRequired;
    try result.object.put(a, "signature", if (c.eq(u8, signature, "0x")) .null else .{ .string = signature });
    if (sign_actor) {
        if (out) |path| try c.write(cast.io, path, try c.encode(a, result), true);
        return result;
    }
    const name = try a.print("directExecute{s}{s}", .{ if (reveal_file != null) "Private" else "", if (is_safe) "" else "FromAccount" });
    var values = std.json.Array.init(a);
    if (!is_safe) try values.append(.{ .string = account });
    try values.appendSlice(&.{ try field(payload, "policyId"), try field(payload, "interactionId"), try field(payload, "args"), max_steps, try field(payload, "nativeValue"), try field(payload, "deadline"), .{ .string = actor }, .{ .string = signature } });
    if (reveal_file) |path| try values.append(try @import("json_schema.zig").read(a, cast.io, "interaction-reveal", path));
    const data = try client.data(name, values.items);
    var destination = client;
    var safe_cast = cast.*;
    var safe_nonce: ?c.Value = null;
    var safe_hash: ?c.Value = null;
    var transaction = try client.transaction(name, values.items, if (is_safe) try c.scalar(a, try field(payload, "nativeValue")) else null, true);
    if (module) |target| {
        safe_cast.instance = target.address;
        safe_cast.checked = false;
        destination = .{ .cast = &safe_cast, .cat = target.entry.cat, .group = try c.string(c.field(target.entry.item, "group").?) };
        var module_values = std.json.Array.init(a);
        try module_values.appendSlice(&.{ .{ .string = account }, try field(payload, "policyId"), try field(payload, "interactionId"), try field(payload, "args"), max_steps, .{ .string = if (bundled) zero else actor }, .{ .string = signature }, try field(payload, "nativeValue"), try field(payload, "deadline") });
        if (reveal_file) |path| try module_values.append(try @import("json_schema.zig").read(a, cast.io, "interaction-reveal", path));
        transaction = try destination.transaction(if (reveal_file == null) "directExecuteInteraction" else "directExecuteInteractionPrivate", module_values.items, null, true);
        if (bundled) {
            transaction = try modules.userOperation(client, target, try c.string(try field(transaction, "data")), digest);
            safe_cast.instance = try c.string(try field(transaction, "to"));
        }
        try result.object.put(a, "module", .{ .string = target.address });
    } else if (is_safe) {
        safe_cast.instance = account;
        safe_cast.checked = false;
        destination = .{ .cast = &safe_cast, .cat = client.cat, .group = "safe" };
        const version = try remote.namedAt(account, try client.cat.find("safe", "VERSION"), &.{});
        if (!(try @import("account_actions.zig").safeCapabilities(try c.string(version))).importSupported) return error.UnsupportedSafeImportVersion;
        const nonce = try remote.namedAt(account, try client.cat.find("safe", "nonce"), &.{});
        safe_nonce = nonce;
        var tx_values = [_]c.Value{ .{ .string = cast.instance }, try field(payload, "nativeValue"), .{ .string = data }, try abi.uint(a, 0), try abi.uint(a, 0), try abi.uint(a, 0), try abi.uint(a, 0), .{ .string = zero }, .{ .string = zero }, nonce };
        const hash = try remote.namedAt(account, try client.cat.find("safe", "getTransactionHash"), &tx_values);
        safe_hash = hash;
        if (sign_safe) {
            if (actor_file == null) return error.ActorSignatureFileRequired;
            const signed = try safe_tx.sign(destination, &tx_values, dry);
            try same(a, hash, .{ .string = try auth.typedHash(a, try field(signed, "typedData")) });
            if (out) |path| try c.write(cast.io, path, try c.encode(a, signed), true);
            return signed;
        }
        tx_values[9] = .{ .string = if (signatures_file) |path| try safe_tx.pack(a, try @import("json_schema.zig").read(a, cast.io, "safe-signatures", path), hash) else if (dry) "0x" else return error.SafeSignaturesFileRequired };
        transaction = try destination.transaction("execTransaction", &tx_values, null, true);
        try result.object.put(a, "safeNonce", nonce);
        try result.object.put(a, "transactionHash", hash);
    }
    try result.object.put(a, "transaction", transaction);
    if (!try remote.canonical(remote.block)) return error.ChainReorganizedRetrySync;
    if (out) |path| try c.write(cast.io, path, try c.encode(a, result), true);
    if (dry) return result;
    // Revalidate after signing, then simulate the exact signed transaction. A
    // rejected policy, stale signature or Safe ExecutionFailure never broadcasts.
    try remote.pin(null, 0);
    if (deadline <= remote.block.timestamp) return error.DirectExecutionDeadlineRequired;
    try same(a, binding, try read(&remote, client, "getExecutionBindingHash", &binding_values));
    try same(a, actor_nonce, try read(&remote, client, "directExecuteNonce", &.{.{ .string = actor }}));
    if (safe_nonce) |nonce| try same(a, nonce, try remote.namedAt(account, try client.cat.find("safe", "nonce"), &.{}));
    if (module) |target| if (!std.ascii.eqlIgnoreCase(target.address, (try modules.resolve(&remote, client, registry, account)).address)) return error.DirectExecutionChanged;
    const final_data = try c.string(try field(transaction, "data"));
    if (!bundled) {
        const sender = if (is_module) try modules.sender(cast) else try cast.signerAddress();
        const returned = try remote.one("eth_call", try abi.array(a, &.{ try c.parse(a, try c.encode(a, .{ .from = sender, .to = destination.cast.instance, .data = final_data, .value = "0x0" })), try remote.blockSelector() }));
        if (is_safe and !is_module and try c.number(a, returned) != 1) return error.SafeExecutionSimulationFailed;
    }
    if (!try remote.canonical(remote.block)) return error.ChainReorganizedRetrySync;
    const receipt = if (is_module) try modules.send(destination.cast, final_data) else try destination.cast.send(final_data, null);
    cast.nonce = destination.cast.nonce;
    try result.object.put(a, "receipt", receipt);
    if (out) |path| try c.write(cast.io, path, try c.encode(a, result), true);
    if (safe_hash) |hash| {
        try safe_tx.verifySuccess(a, client.cat, receipt, account, hash);
    }
    if (module) |target| try modules.verify(target, a, receipt, account, try field(payload, "interactionId"), null);
    return result;
}
