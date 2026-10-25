const std = @import("std");
const c = @import("common.zig");
const abi = @import("abi_codec.zig");
const rpc = @import("rpc.zig");
const contracts = @import("contracts.zig");
const codec = @import("journal_checkpoint.zig");
const field = codec.field;
const string = codec.string;
const Vault = @import("vault.zig").Vault;
const Cast = @import("cast.zig").Cast;
const Client = @import("contract_client.zig").Client;
fn key(a: c.A, scope: []const u8, id: []const u8) ![]const u8 {
    _ = try c.word(id);
    if (id.len != 66) return error.InvalidCheckpoint;
    return a.print("operation-checkpoint:{s}:{s}", .{ scope, try std.ascii.allocLowerString(a, id) });
}
pub fn save(v: Vault, scope: []const u8, draft: c.Value) !void {
    const bytes = try c.encode(v.a, draft);
    defer std.crypto.secureZero(u8, @constCast(bytes));
    try v.put(try key(v.a, scope, try string(draft, "checkpointId")), bytes);
}
pub fn load(v: Vault, scope: []const u8, id: []const u8) !c.Value {
    const bytes = (try v.get(try key(v.a, scope, id))) orelse return error.CheckpointDraftNotFound;
    defer std.crypto.secureZero(u8, bytes);
    return c.parse(v.a, bytes);
}
pub fn summary(a: c.A, draft: c.Value) !c.Value {
    const manifest = try field(draft, "manifest");
    return c.parse(a, try c.encode(a, .{ .checkpointId = try field(draft, "checkpointId"), .manifestKey = try field(draft, "manifestKey"), .storageChainId = try field(draft, "storageChainId"), .kvAddress = try field(draft, "kvAddress"), .signer = try field(draft, "signer"), .retainedCount = try field(manifest, "retainedCount"), .chunkCount = try field(manifest, "chunkCount"), .excludedExpired = try field(draft, "excludedExpired"), .kvBlock = try field(draft, "kvBlock"), .expiryProof = try field(draft, "expiryProof"), .published = c.field(draft, "published") orelse c.Value{ .bool = false }, .attempt = c.field(draft, "attempt") orelse c.Value.null }));
}
pub fn prepare(cast: *Cast, remote: *rpc.Rpc, v: Vault, scope: []const u8, secrets: []const @import("vault.zig").Secret, entries: codec.Entries, counts: c.Value, confirmations: u64, chunk_size: usize, keep_all: bool) !c.Value {
    const a = cast.a;
    const listing = try @import("operations.zig").list(a, entries, secrets, null, null);
    if (listing.invalid != 0 or listing.unreadable != 0) return error.IncompleteOperationJournal;
    const frontier = try codec.frontiers(a, entries, secrets, counts);
    var chain_rpc = try rpc.Rpc.initEndpoint(a, cast.io, if (keep_all) remote.url else cast.rpc, cast.chain);
    defer chain_rpc.deinit();
    var proof: c.Value = .null;
    if (!keep_all) {
        try chain_rpc.pinBlock(null, confirmations);
        proof = try c.parse(a, try c.encode(a, .{ .chainId = cast.chain, .block = chain_rpc.block, .confirmations = confirmations }));
    }
    var retained = std.json.Array.init(a);
    var excluded: usize = 0;
    for (listing.entries) |entry| {
        const payload = try field(entry, "payload");
        if (!keep_all and try c.number(a, try field(payload, "chainId")) == cast.chain and try c.number(a, try field(payload, "deadline")) < chain_rpc.block.timestamp) {
            excluded += 1;
            continue;
        }
        try retained.append(try c.parse(a, try c.encode(a, .{ .signer = try field(entry, "signer"), .proposalKey = try field(entry, "key") })));
    }
    var random: [64]u8 = undefined;
    try cast.io.randomSecure(&random);
    random[32] = 0xb1;
    var draft = try codec.build(a, try abi.hex(a, random[0..32]), try abi.hex(a, random[32..64]), frontier, retained.items, remote.block.timestamp, chunk_size);
    for ([_]struct { []const u8, c.Value }{
        .{ "storageChainId", try abi.uint(a, remote.chain) },
        .{ "kvAddress", .{ .string = remote.address } },
        .{ "signer", .{ .string = try secrets[0].address(a) } },
        .{ "kvBlock", try c.parse(a, try c.encode(a, remote.block)) },
        .{ "excludedExpired", try abi.uint(a, excluded) },
        .{ "expiryProof", proof },
    }) |entry| try draft.object.put(a, entry[0], entry[1]);
    // Immutable random keys should not collide, but never overwrite a record.
    const cat = try contracts.Catalog.loadAuxiliary(a);
    for ((try field(draft, "records")).array.items) |record| if ((try remote.call(try cat.find("kv", "exists"), &.{try field(record, "key")})).array.items[0].bool) return error.CheckpointKeyCollision;
    if (!try remote.canonical(remote.block) or (!keep_all and !try chain_rpc.canonical(chain_rpc.block))) return error.ChainReorganizedRetrySync;
    try save(v, scope, draft);
    return summary(a, draft);
}
fn canonical(remote: *rpc.Rpc, value: c.Value) !void {
    if (!try remote.canonical(.{ .number = try rpc.integer(remote.a, try field(value, "number")), .hash = try string(value, "hash"), .timestamp = try rpc.integer(remote.a, try field(value, "timestamp")) })) return error.ChainReorganizedPrepareCheckpointAgain;
}
fn guard(remote: *rpc.Rpc, cat: contracts.Catalog, draft: c.Value, secret: @import("vault.zig").Secret) !void {
    try remote.pin(null, 0);
    const current = (try remote.call(try cat.find("kv", "passwordSigner"), &.{})).array.items[0];
    if (!codec.same(try c.string(current), try secret.address(remote.a)) or !codec.same(try string(draft, "signer"), try secret.address(remote.a))) return error.WrongKvSigner;
    if (!(try remote.call(try cat.find("kv", "indexingEnabled"), &.{})).array.items[0].bool) return error.CheckpointRequiresIndexedSync;
    try canonical(remote, try field(draft, "kvBlock"));
}
fn exists(remote: *rpc.Rpc, cat: contracts.Catalog, record: c.Value, secret: @import("vault.zig").Secret) !bool {
    const args = [_]c.Value{try field(record, "key")};
    if (!(try remote.call(try cat.find("kv", "exists"), &args)).array.items[0].bool) return false;
    const raw = (try remote.call(try cat.find("kv", "read"), &args)).array.items[0];
    const bytes = try secret.decrypt(remote.a, try abi.unhex(remote.a, try c.string(raw)));
    defer std.crypto.secureZero(u8, bytes);
    if (!c.eq(u8, bytes, try abi.unhex(remote.a, try string(record, "plaintext")))) return error.CheckpointKeyCollision;
    return true;
}
pub fn publish(cast: *Cast, kv_cast: *Cast, v: Vault, scope: []const u8, draft: *c.Value, retry: bool, dry: bool) !c.Value {
    if (cast.block != null) return error.TransactionRequiresLatestBlock;
    const a = cast.a;
    if (try c.number(a, try field(draft.*, "storageChainId")) != kv_cast.chain or !codec.same(try string(draft.*, "kvAddress"), kv_cast.instance)) return error.CheckpointContextMismatch;
    var secret = try v.head(scope);
    defer secret.deinit();
    const cat = try contracts.Catalog.loadAuxiliary(a);
    var remote = try rpc.Rpc.init(a, cast.io, kv_cast.rpc, kv_cast.chain, kv_cast.instance);
    defer remote.deinit();
    const proof = try field(draft.*, "expiryProof");
    var chain_rpc = try rpc.Rpc.initEndpoint(a, cast.io, if (proof == .null) kv_cast.rpc else cast.rpc, cast.chain);
    defer chain_rpc.deinit();
    if (proof != .null) {
        if (try c.number(a, try field(proof, "chainId")) != cast.chain) return error.CheckpointExecutionChainRequired;
        try chain_rpc.pinBlock(null, 0);
        try canonical(&chain_rpc, try field(proof, "block"));
    }
    try guard(&remote, cat, draft.*, secret);
    if (dry) return summary(a, draft.*);
    // Unlock the transaction signer before the final chain and epoch checks.
    _ = try kv_cast.signerAddress();
    const client: Client = .{ .cast = kv_cast, .cat = cat, .group = "kv" };
    const records = (try field(draft.*, "records")).array.items;
    for (records, 0..) |record, index| {
        try guard(&remote, cat, draft.*, secret);
        if (proof != .null) try canonical(&chain_rpc, try field(proof, "block"));
        if (try exists(&remote, cat, record, secret)) continue;
        if (c.field(draft.*, "attempt")) |attempt| if (codec.same(try string(attempt, "key"), try string(record, "key")) and !retry) return error.CheckpointAttemptUncertainUseRetry;
        // Chunks must be readable together at one canonical block before the
        // final manifest makes them visible to journal consumers.
        if (index + 1 == records.len) for (records[0..index]) |chunk| if (!try exists(&remote, cat, chunk, secret)) return error.IncompleteCheckpoint;
        if (!try remote.canonical(remote.block)) return error.ChainReorganizedRetrySync;
        var attempt = try c.parse(a, try c.encode(a, .{ .key = try field(record, "key"), .index = index, .block = remote.block }));
        try draft.object.put(a, "attempt", attempt);
        try save(v, scope, draft.*);
        const bytes = try abi.unhex(a, try string(record, "plaintext"));
        defer std.crypto.secureZero(u8, bytes);
        const receipt = try @import("kv_write.zig").write(client, secret, try string(record, "key"), bytes, false);
        try attempt.object.put(a, "receipt", receipt);
        try draft.object.put(a, "attempt", attempt);
        try save(v, scope, draft.*);
        try guard(&remote, cat, draft.*, secret);
        if (!try exists(&remote, cat, record, secret)) return error.CheckpointWriteNotConfirmed;
    }
    try guard(&remote, cat, draft.*, secret);
    for (records) |record| if (!try exists(&remote, cat, record, secret)) return error.IncompleteCheckpoint;
    if (proof != .null) try canonical(&chain_rpc, try field(proof, "block"));
    if (!try remote.canonical(remote.block)) return error.ChainReorganizedRetrySync;
    try draft.object.put(a, "published", .{ .bool = true });
    try draft.object.put(a, "publishedBlock", try c.parse(a, try c.encode(a, remote.block)));
    try save(v, scope, draft.*);
    return summary(a, draft.*);
}
