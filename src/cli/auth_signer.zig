const std = @import("std");
const c = @import("common.zig");
const abi = @import("abi_codec.zig");
const ms = @import("miniscript");
const browser = @import("browser_approval.zig");
const contracts = @import("contracts.zig");
const Cast = @import("cast.zig").Cast;
const Client = @import("contract_client.zig").Client;

pub const Options = struct { profile: c.Value, registry: []const u8, bundler: ?[]const u8 = null, paymaster: ?[]const u8 = null, browser: browser.Options = .{} };
pub fn field(v: c.Value, name: []const u8) !c.Value {
    return c.field(v, name) orelse error.InvalidAuthProfile;
}
pub fn string(v: c.Value, name: []const u8) ![]const u8 {
    return c.string(try field(v, name));
}
fn equal(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

pub fn validate(a: c.A, value: c.Value, chain: u64, registry: []const u8, enrollment: bool) !void {
    if (try c.number(a, try field(value, "chainId")) != chain or !equal(try string(value, "registry"), registry)) return error.AuthProfileTenantMismatch;
    try c.address(registry);
    const origin = try string(value, "origin");
    if (!c.eq(u8, origin, try browser.origin(a, origin))) return error.InvalidApprovalOrigin;
    const uri = try std.Uri.parse(origin);
    const rp_id = try uri.host.?.toRawMaybeAlloc(a);
    if (!c.eq(u8, rp_id, try string(value, "rpId")) or (try field(value, "requireUserVerification")) != .bool or !(try field(value, "requireUserVerification")).bool) return error.InvalidAuthProfile;
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(rp_id, &hash, .{});
    if (!equal(try abi.hex(a, &hash), try string(value, "rpIdHash"))) return error.InvalidAuthProfile;
    const credential = try abi.unhex(a, try string(value, "credentialId"));
    if (credential.len == 0 or credential.len > 4096) return error.InvalidAuthProfile;
    std.crypto.hash.sha2.Sha256.hash(credential, &hash, .{});
    if (!equal(try abi.hex(a, &hash), try string(value, "credHash"))) return error.InvalidAuthProfile;
    const id = try derive(a, "ChainwallWebAuthnAuthIdKey(address registry,bytes32 rpIdHash,bytes32 credHash)", registry, try string(value, "rpIdHash"), try string(value, "credHash"));
    if (!equal(id, try string(value, "idKey"))) return error.InvalidAuthProfile;
    if (enrollment) {
        if (!c.eq(u8, try string(value, "kind"), "chainwall.webauthn-auth-account.enrollment") or try c.number(a, try field(value, "version")) != 1) return error.InvalidAuthEnrollment;
        const salt = try derive(a, "ChainwallWebAuthnAuthAccountSalt(address registry,bytes32 rpIdHash,bytes32 idKey)", registry, try string(value, "rpIdHash"), id);
        if (!equal(salt, try string(value, "accountSalt"))) return error.InvalidAuthEnrollment;
        for ([_][]const u8{ "qx", "qy" }) |key| if ((try abi.unhex(a, try string(value, key))).len != 32) return error.InvalidAuthEnrollment;
        try c.address(try string(value, "authAccountFactory"));
    } else try c.address(try string(value, "authAccount"));
}
fn derive(a: c.A, domain: []const u8, registry: []const u8, rp: []const u8, key: []const u8) ![]const u8 {
    var bytes: [128]u8 = @splat(0);
    std.mem.writeInt(u256, bytes[0..32], ms.bytecode.hash(domain), .big);
    std.mem.writeInt(u256, bytes[32..64], try c.word(registry), .big);
    std.mem.writeInt(u256, bytes[64..96], try c.word(rp), .big);
    std.mem.writeInt(u256, bytes[96..128], try c.word(key), .big);
    return c.hex(a, ms.bytecode.hash(&bytes));
}

pub fn approve(cast: *Cast, action: []const u8, extra: c.Value) !c.Value {
    const opts = cast.auth orelse return error.AuthProfileRequired;
    try validate(cast.a, opts.profile, cast.chain, opts.registry, false);
    var payload = try c.parse(cast.a, try c.encode(cast.a, .{ .version = 1, .action = action, .chainId = cast.chain, .registry = opts.registry, .origin = try string(opts.profile, "origin"), .rpcUrl = cast.rpc, .profile = opts.profile }));
    for (extra.object.keys(), extra.object.values()) |key, value| try payload.object.put(cast.a, key, value);
    return browser.request(cast.a, cast.io, cast.env, try string(opts.profile, "origin"), payload, opts.browser);
}

pub fn sign(cast: *Cast, typed: c.Value) ![]const u8 {
    try cast.check();
    const result = try approve(cast, "sign-typed-data", try c.parse(cast.a, try c.encode(cast.a, .{ .typedData = typed })));
    const signature = try string(result, "signature");
    const bytes = try abi.unhex(cast.a, signature);
    if (bytes.len == 0 or bytes.len > 16384) return error.InvalidSignature;
    // Compute the EIP-712 digest independently of the browser, then ask the
    // selected account to verify its ERC-1271 assertion on the current chain.
    const digest = try typedHash(cast.a, typed);
    if (!equal(digest, try string(result, "hash"))) return error.TypedDataHashMismatch;
    var verifier = cast.*;
    verifier.auth = null;
    verifier.instance = try string(cast.auth.?.profile, "authAccount");
    verifier.checked = false;
    const client: Client = .{ .cast = &verifier, .cat = try contracts.Catalog.loadAuxiliary(cast.a), .group = "auth-account" };
    if (!equal(try c.string(try client.first("isValidSignature", &.{ .{ .string = digest }, .{ .string = signature } })), "0x1626ba7e")) return error.InvalidAuthSignature;
    return signature;
}

/// The CLI signs flat SafeTx and ExecutionActor EIP-712 structures. Reject
/// nested schemas rather than hash an unsupported type with different rules.
pub fn typedHash(a: c.A, typed: c.Value) ![]const u8 {
    const types = try field(typed, "types");
    const domain = try structHash(a, types, "EIP712Domain", try field(typed, "domain"));
    const message = try structHash(a, types, try string(typed, "primaryType"), try field(typed, "message"));
    var bytes: [66]u8 = undefined;
    bytes[0..2].* = .{ 0x19, 0x01 };
    std.mem.writeInt(u256, bytes[2..34], domain, .big);
    std.mem.writeInt(u256, bytes[34..66], message, .big);
    return c.hex(a, ms.bytecode.hash(&bytes));
}
fn structHash(a: c.A, types: c.Value, name: []const u8, values: c.Value) !u256 {
    const fields = try field(types, name);
    if (fields != .array or fields.array.items.len > 64) return error.UnsupportedTypedData;
    var declaration: std.Io.Writer.Allocating = .init(a);
    try declaration.writer.print("{s}(", .{name});
    var encoded: std.ArrayList(u8) = .empty;
    try encoded.appendNTimes(a, 0, 32);
    for (fields.array.items, 0..) |param, i| {
        const kind = try string(param, "type");
        const key = try string(param, "name");
        try declaration.writer.print("{s}{s} {s}", .{ if (i > 0) "," else "", kind, key });
        const value = try field(values, key);
        if (c.eq(u8, kind, "string") or c.eq(u8, kind, "bytes")) {
            const bytes = if (c.eq(u8, kind, "string")) try c.string(value) else try abi.unhex(a, try c.string(value));
            var hash: [32]u8 = undefined;
            std.mem.writeInt(u256, &hash, ms.bytecode.hash(bytes), .big);
            try encoded.appendSlice(a, &hash);
        } else {
            if (std.mem.indexOfScalar(u8, kind, '[') != null or c.field(types, kind) != null or c.eq(u8, kind, "tuple")) return error.UnsupportedTypedData;
            const bytes = try abi.encode(a, try abi.array(a, &.{param}), try abi.array(a, &.{value}));
            if (bytes.len != 32) return error.UnsupportedTypedData;
            try encoded.appendSlice(a, bytes);
        }
    }
    try declaration.writer.writeByte(')');
    std.mem.writeInt(u256, encoded.items[0..32], ms.bytecode.hash(declaration.written()), .big);
    return ms.bytecode.hash(encoded.items);
}

pub fn send(cast: *Cast, data: []const u8, value: ?[]const u8) anyerror!c.Value {
    const opts = cast.auth.?;
    const a = cast.a;
    if (cast.block != null) return error.TransactionRequiresLatestBlock;
    if (try c.word(value orelse "0") != 0) return error.AuthProtocolCallCannotCarryValue;
    const tx = try c.parse(a, try c.encode(a, .{ .to = cast.instance, .data = data, .value = "0" }));
    if (opts.bundler) |url| {
        if (cast.fees.supplied()) return error.BundlerManagesFees;
        if (cast.nonce != null) return error.BundlerManagesNonce;
        if (cast.journal) |journal| try journal.begin();
        var extra = try c.parse(a, try c.encode(a, .{ .tx = tx, .bundlerUrl = url }));
        if (opts.paymaster) |paymaster| {
            try c.address(paymaster);
            try extra.object.put(a, "paymaster", .{ .string = paymaster });
        }
        const result = try approve(cast, "user-operation", extra);
        const hash = try string(result, "userOpHash");
        if ((try abi.unhex(a, hash)).len != 32) return error.InvalidUserOperationHash;
        // Save the recovery handle before terminal output or receipt verification.
        if (cast.journal) |journal| try journal.record(.{ .chainId = cast.chain, .userOpHash = hash, .txHash = c.field(result, "txHash") orelse .null });
        // Link the containing transaction, not the distinct UserOperation hash,
        // before receipt verification can fail. Receipt recovery is read-only.
        if (c.field(result, "txHash")) |tx_hash| try cast.showTransaction(c.string(tx_hash) catch "");
        // Preserve the recovery handle even if receipt polling failed after
        // submission. This command must never silently resubmit an operation.
        try std.Io.File.stderr().writeStreamingAll(cast.io, try a.print("UserOperation: {s}\n", .{hash}));
        const tx_hash = c.field(result, "txHash") orelse return error.UserOperationReceiptUnavailable;
        return verifyReceipt(cast, hash, try c.string(tx_hash));
    }
    var sponsor = cast.*;
    sponsor.auth = null;
    const from = try sponsor.signerAddress();
    const result = try approve(cast, "protocol-call", try c.parse(a, try c.encode(a, .{ .tx = tx, .sponsor = from })));
    const account = try string(opts.profile, "authAccount");
    if (!equal(try string(result, "to"), account) or !equal(try string(result, "from"), from) or try c.number(a, try field(result, "value")) != 0) return error.InvalidApprovedTransaction;
    const approved = try string(result, "data");
    const cat = try contracts.Catalog.loadAuxiliary(a);
    const method = try cat.find("auth-account", "executeProtocolCall");
    const encoded = try abi.unhex(a, approved);
    if (encoded.len < 4 or std.mem.readInt(u32, encoded[0..4], .big) != @as(u32, @intCast(ms.bytecode.hash(method.signature) >> 224))) return error.InvalidApprovedTransaction;
    const args = try abi.decode(a, c.field(method.abi, "inputs").?, encoded[4..]);
    if (!equal(try c.string(args.array.items[0]), cast.instance) or !equal(try c.string(args.array.items[1]), data)) return error.InvalidApprovedTransaction;
    sponsor.instance = account;
    sponsor.checked = false;
    const receipt = try sponsor.send(approved, null);
    cast.nonce = sponsor.nonce;
    return receipt;
}

pub fn verifyReceipt(cast: *Cast, hash: []const u8, tx_hash: []const u8) !c.Value {
    const a = cast.a;
    const account = try string(cast.auth.?.profile, "authAccount");
    var account_cast = cast.*;
    account_cast.instance = account;
    account_cast.checked = false;
    const client: Client = .{ .cast = &account_cast, .cat = try contracts.Catalog.loadAuxiliary(a), .group = "auth-account" };
    const entry_point = try c.string(try client.first("entryPoint", &.{}));
    const receipt = try c.parse(a, try cast.run(&.{ "rpc", "eth_getTransactionReceipt", tx_hash, "--rpc-url", cast.rpc }));
    try cast.recordReceipt(receipt);
    if (try c.number(a, try field(receipt, "status")) != 1 or !equal(try string(receipt, "transactionHash"), tx_hash)) return error.TransactionReverted;
    const logs = try field(receipt, "logs");
    if (logs != .array) return error.InvalidTransactionReceipt;
    // ERC-4337 UserOperationEvent is emitted by EntryPoint, not by its caller.
    const topic = ms.bytecode.hash("UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)");
    for (logs.array.items) |log| {
        if (!equal(try string(log, "address"), entry_point)) continue;
        const topics = try field(log, "topics");
        if (topics != .array or topics.array.items.len != 4 or try c.number(a, topics.array.items[0]) != topic) continue;
        if (!equal(try c.string(topics.array.items[1]), hash) or try c.number(a, topics.array.items[2]) != try c.word(account)) continue;
        const bytes = try abi.unhex(a, try string(log, "data"));
        if (bytes.len != 128) return error.InvalidTransactionReceipt;
        if (std.mem.readInt(u256, bytes[32..64], .big) != 1) return error.UserOperationReverted;
        return receipt;
    }
    return error.UserOperationEventMissing;
}
