const std = @import("std");
const c = @import("common.zig");
const abi = @import("abi_codec.zig");
const ms = @import("miniscript");
const vault = @import("vault.zig");
const operations = @import("operations.zig");
const rpc = @import("rpc.zig");
const contracts = @import("contracts.zig");
const Client = @import("contract_client.zig").Client;

const Attempt = struct {
    previous: vault.Secret,
    next: vault.Secret,
    nonce: u256,
    value: [145]u8,
    authorization: [65]u8,

    fn deinit(s: *Attempt) void {
        std.crypto.secureZero(u8, std.mem.asBytes(s));
    }
    fn encode(s: Attempt) [307]u8 {
        var bytes: [307]u8 = undefined;
        bytes[0] = 1;
        @memcpy(bytes[1..33], &s.previous.private_key);
        @memcpy(bytes[33..65], &s.next.private_key);
        std.mem.writeInt(u256, bytes[65..97], s.nonce, .big);
        @memcpy(bytes[97..242], &s.value);
        @memcpy(bytes[242..307], &s.authorization);
        return bytes;
    }
    fn decode(bytes: []const u8) !Attempt {
        if (bytes.len != 307 or bytes[0] != 1) return error.InvalidSecretRotation;
        var previous = try vault.Secret.init(bytes[1..33].*);
        defer previous.deinit();
        return .{ .previous = previous, .next = try vault.Secret.init(bytes[33..65].*), .nonce = std.mem.readInt(u256, bytes[65..97], .big), .value = bytes[97..242].*, .authorization = bytes[242..307].* };
    }
    fn metadata(s: Attempt, a: c.A) !c.Value {
        return c.parse(a, try c.encode(a, .{ .previousSigner = try s.previous.address(a), .nextSigner = try s.next.address(a), .nonce = try abi.uint(a, s.nonce), .rotationKey = try s.next.rotationKey(a), .rotationValueHash = try c.hex(a, ms.bytecode.hash(&s.value)) }));
    }
};
const Observation = struct {
    signer: []const u8,
    owner: []const u8,
    nonce: u256,
    entry: ?[]const u8,
    fn phase(s: Observation, a: c.A, attempt: Attempt) ![]const u8 {
        if (equal(s.signer, try attempt.next.address(a)) and s.nonce == attempt.nonce +% 1 and s.entry != null and equal(s.entry.?, try abi.hex(a, &attempt.value))) return "confirmed";
        if (equal(s.signer, try attempt.previous.address(a)) and s.nonce == attempt.nonce and s.entry == null) return "prepared";
        return "conflict";
    }
};
fn equal(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}
fn first(remote: *rpc.Rpc, cat: contracts.Catalog, method: []const u8, args: []const c.Value) !c.Value {
    return (try remote.call(try cat.find("kv", method), args)).array.items[0];
}
fn observe(remote: *rpc.Rpc, cat: contracts.Catalog, key: ?[]const u8) !Observation {
    return .{
        .signer = try c.string(try first(remote, cat, "passwordSigner", &.{})),
        .owner = try c.string(try first(remote, cat, "owner", &.{})),
        .nonce = try c.number(remote.a, try first(remote, cat, "passwordSignerRotationNonce", &.{})),
        .entry = if (key) |k| if ((try first(remote, cat, "exists", &.{.{ .string = k }})).bool) try c.string(try first(remote, cat, "read", &.{.{ .string = k }})) else null else null,
    };
}
pub fn pendingId(a: c.A, scope: []const u8) ![]const u8 {
    return a.print("kv:{s}:rotation.pending.v1", .{scope});
}
pub const Result = struct { value: c.Value, confirmed: bool = false };

pub fn run(client: Client, v: vault.Vault, scope: []const u8, verb: []const u8, secret_file: ?[]const u8, resuming: bool, dry: bool) !Result {
    const cast = client.cast;
    const a = cast.a;
    const rotating = c.eq(u8, verb, "rotate");
    if (rotating and cast.block != null) return error.TransactionRequiresLatestBlock;
    if (resuming and secret_file != null) return error.RotationResumeUsesSavedSecret;
    const id = try pendingId(a, scope);
    const raw = try v.get(id);
    defer if (raw) |bytes| std.crypto.secureZero(u8, bytes);
    var attempt: ?Attempt = if (raw) |bytes| try Attempt.decode(bytes) else null;
    defer if (attempt) |*value| value.deinit();
    var remote = try rpc.Rpc.init(a, cast.io, cast.rpc, cast.chain, cast.instance);
    defer remote.deinit();
    try remote.pin(cast.block, 0);
    var observation = try observe(&remote, client.cat, if (attempt) |value| try value.next.rotationKey(a) else null);
    var head = try v.head(scope);
    defer head.deinit();
    if (c.eq(u8, verb, "rotation-status")) return .{ .value = try c.parse(a, try c.encode(a, .{ .status = if (attempt) |value| try observation.phase(a, value) else "none", .pending = if (attempt) |value| try value.metadata(a) else @as(c.Value, .null), .currentSigner = observation.signer, .localSigner = try head.address(a), .nonce = try abi.uint(a, observation.nonce), .block = remote.block })) };
    if (!rotating) {
        const secrets = try operations.readSecretHistory(a, &remote, client.cat, head);
        defer for (secrets) |*secret| secret.deinit();
        if (!try remote.canonical(remote.block)) return error.ChainReorganizedRetrySync;
        try operations.saveHistory(a, v, scope, secrets);
        var signers = std.json.Array.init(a);
        for (secrets) |secret| try signers.append(.{ .string = try secret.address(a) });
        return .{ .value = try c.parse(a, try c.encode(a, .{ .headSigner = try head.address(a), .currentSigner = observation.signer, .current = equal(try head.address(a), observation.signer), .signers = signers.items, .block = remote.block })) };
    }
    if (resuming and attempt == null) return error.NoPendingRotation;
    if (!resuming and attempt != null) return error.PendingRotationUseResume;
    if (attempt == null) {
        if (!equal(observation.signer, try head.address(a))) return error.WrongKvSigner;
        const history = try operations.readSecretHistory(a, &remote, client.cat, head);
        defer for (history) |*secret| secret.deinit();
        if (history.len == 64) return error.SecretHistoryTooDeep;
        var next_key: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &next_key);
        if (secret_file) |file| {
            const text = try c.read(a, cast.io, file);
            defer std.crypto.secureZero(u8, @constCast(text));
            const bytes = try abi.unhex(a, c.trim(text));
            defer std.crypto.secureZero(u8, bytes);
            if (bytes.len != 32) return error.InvalidKvSecret;
            next_key = bytes[0..32].*;
        } else try cast.io.randomSecure(&next_key);
        var next = try vault.Secret.init(next_key);
        defer next.deinit();
        for (history) |secret| if (c.eq(u8, &secret.signer, &next.signer)) return error.SecretRotationCycle;
        const rotation_key = try next.rotationKey(a);
        if ((try first(&remote, client.cat, "exists", &.{.{ .string = rotation_key }})).bool) return error.RotationKeyAlreadyUsed;
        // Rotation wire format: uint8(1), previous signer, previous private key,
        // encrypted with the next secret's authenticated AES-GCM envelope.
        var plaintext: [96]u8 = @splat(0);
        defer std.crypto.secureZero(u8, &plaintext);
        plaintext[31] = 1;
        @memcpy(plaintext[44..64], &head.signer);
        @memcpy(plaintext[64..96], &head.private_key);
        const encrypted = try next.encrypt(a, cast.io, &plaintext);
        const domain = try c.number(a, try first(&remote, client.cat, "domainSeparatorV4", &.{}));
        const signature = try @import("kv_write.zig").sign(head, domain, &.{ ms.bytecode.hash("RotatePasswordSigner(address expectedCurrentSigner,address newSigner,bytes32 rotationKey,bytes32 rotationValueHash,uint256 nonce)"), try c.word(observation.signer), try c.word(try next.address(a)), try c.word(rotation_key), ms.bytecode.hash(encrypted), observation.nonce });
        attempt = .{ .previous = head, .next = next, .nonce = observation.nonce, .value = encrypted[0..145].*, .authorization = signature };
        if (!try remote.canonical(remote.block)) return error.ChainReorganizedRetrySync;
        var saved = attempt.?.encode();
        defer std.crypto.secureZero(u8, &saved);
        try v.db.begin();
        errdefer v.db.db.rollback();
        if (try v.db.secret(id) != null) return error.PendingRotationUseResume;
        try v.put(id, &saved);
        try v.db.db.commit();
    }
    const plan = attempt.?;
    const phase = try observation.phase(a, plan);
    if (c.eq(u8, phase, "conflict")) return error.StaleKvRotation;
    var receipt: c.Value = .null;
    const values = [_]c.Value{ .{ .string = try plan.previous.address(a) }, .{ .string = try plan.next.address(a) }, .{ .string = try abi.hex(a, &plan.value) }, .{ .string = try abi.hex(a, &plan.authorization) } };
    if (dry) return .{ .value = try c.parse(a, try c.encode(a, .{ .status = phase, .pending = try plan.metadata(a), .transaction = try client.transaction("rotatePasswordSigner", &values, null, true) })) };
    if (c.eq(u8, phase, "prepared")) {
        if (!equal(try cast.signerAddress(), observation.owner)) return error.KvOwnerRequired;
        receipt = client.transaction("rotatePasswordSigner", &values, null, false) catch |err| {
            cast.diagnostic = "Rotation is saved locally. Use chainwall kv rotation-status, then chainwall kv rotate --resume.\n";
            return err;
        };
        try remote.pin(null, 0);
        observation = try observe(&remote, client.cat, try plan.next.rotationKey(a));
    }
    if (!c.eq(u8, try observation.phase(a, plan), "confirmed")) return error.KvRotationNotConfirmed;
    const history = try operations.readSecretHistory(a, &remote, client.cat, plan.next);
    defer for (history) |*secret| secret.deinit();
    if (!try remote.canonical(remote.block)) return error.ChainReorganizedRetrySync;
    try v.db.begin();
    errdefer v.db.db.rollback();
    try v.putHead(scope, plan.next);
    try operations.saveHistory(a, v, scope, history);
    try v.db.db.commit();
    // Keep the recovery record until the caller has saved its profile pointer.
    return .{ .confirmed = true, .value = try c.parse(a, try c.encode(a, .{ .status = "confirmed", .passwordSigner = try plan.next.address(a), .previousSigner = try plan.previous.address(a), .historyDepth = history.len, .nonce = try abi.uint(a, observation.nonce), .block = remote.block, .receipt = receipt })) };
}

test "rotation proof requires the exact entry and nonce, including uint256 wrap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var attempt: Attempt = .{
        .previous = try vault.Secret.init(@as([31]u8, @splat(0)) ++ .{1}),
        .next = try vault.Secret.init(@as([31]u8, @splat(0)) ++ .{2}),
        .nonce = std.math.maxInt(u256),
        .value = @splat(42),
        .authorization = @splat(0),
    };
    defer attempt.deinit();
    var observed: Observation = .{ .signer = try attempt.previous.address(a), .owner = "", .nonce = attempt.nonce, .entry = null };
    try std.testing.expectEqualStrings("prepared", try observed.phase(a, attempt));
    observed.signer = try attempt.next.address(a);
    observed.nonce = 0;
    try std.testing.expectEqualStrings("conflict", try observed.phase(a, attempt));
    observed.entry = try abi.hex(a, &attempt.value);
    try std.testing.expectEqualStrings("confirmed", try observed.phase(a, attempt));
    observed.nonce = 1;
    try std.testing.expectEqualStrings("conflict", try observed.phase(a, attempt));
    observed.nonce = 0;
    observed.entry = "0x00";
    try std.testing.expectEqualStrings("conflict", try observed.phase(a, attempt));
}
