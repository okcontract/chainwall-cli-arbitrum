const std = @import("std");
const c = @import("common.zig");
const abi = @import("abi_codec.zig");
const ms = @import("miniscript");
const rpc = @import("rpc.zig");
const journal = @import("recipient_journal.zig");
const contracts = @import("contracts.zig");
const Secret = @import("vault.zig").Secret;
const Cast = @import("cast.zig").Cast;
const field = journal.field;

pub const Options = struct { verb: []const u8, reference: ?[]const u8, recipient: ?[]const u8, label: ?[]const u8, out: ?[]const u8, offline: bool, dry: bool };
fn parameters(a: c.A, context: journal.Context, commitment: c.Value) ![4]c.Value {
    return .{ .{ .string = context.policyId }, .{ .string = try c.hex(a, journal.namespace) }, .{ .string = try c.hex(a, try c.word(context.vault)) }, commitment };
}
fn authorization(remote: *rpc.Rpc, cat: contracts.Catalog, context: journal.Context, commitment: c.Value) !c.Value {
    return remote.namedAt(context.registryAddress, try cat.find("policy-state", "getPolicyUint"), &try parameters(remote.a, context, commitment));
}
fn noPending(remote: *rpc.Rpc, cat: contracts.Catalog, context: journal.Context) !void {
    const count = try rpc.integer(remote.a, try remote.namedAt(context.registryAddress, try cat.find("timelock", "getPendingActionCount"), &.{}));
    if (count > 10000) return error.TooManyPendingActions;
    var offset: u64 = 0;
    while (offset < count) {
        const size = @min(100, count - offset);
        const page = try remote.namedAt(context.registryAddress, try cat.find("timelock", "getPendingActionSummaries"), &.{ try abi.uint(remote.a, offset), try abi.uint(remote.a, size) });
        if (page != .array or page.array.items.len != size) return error.InvalidPendingActionPage;
        for (page.array.items) |action| if (try c.number(remote.a, try field(action, "category")) == ms.bytecode.hash("timelock.category.policy") and try c.number(remote.a, try field(action, "scope")) == try c.word(context.policyId)) return error.RecipientPolicyUpdatePending;
        offset += size;
    }
}
pub fn run(cast: *Cast, kv_cast: *Cast, secret: Secret, context: journal.Context, listing: journal.Listing, checkpoint: c.Value, options: Options) !c.Value {
    const a = cast.a;
    const list = c.eq(u8, options.verb, "list");
    const add = c.eq(u8, options.verb, "add");
    const remove = c.eq(u8, options.verb, "remove");
    const resolve = c.eq(u8, options.verb, "resolve");
    if (options.offline) {
        if (!list) return error.OfflineRecipientListOnly;
        var entries = std.json.Array.init(a);
        for (listing.entries) |entry| try entries.append(try journal.publicEntry(a, entry));
        const report = try c.parse(a, try c.encode(a, .{ .context = context, .entries = entries.items, .checkpoint = checkpoint, .invalid = listing.invalid, .unreadable = listing.unreadable, .authorization = "unknown", .cache = try @import("cache_metadata.zig").describe(a, "sqlite-cache", checkpoint, .null, listing.invalid > 0 or listing.unreadable > 0) }));
        if (options.out) |path| try c.write(cast.io, path, try c.encode(a, report), false);
        return report;
    }
    if (cast.block != null) return error.RecipientActionsRequireLatestBlock;
    if (resolve and options.out == null) return error.OutputFileRequired;
    const cat = try contracts.Catalog.load(a);
    var remote = try rpc.Rpc.init(a, cast.io, cast.rpc, cast.chain, cast.instance);
    defer remote.deinit();
    try remote.pin(null, 0);
    const checks = try @import("metadata_batch.zig").read(&remote, &.{
        .{ .address = cast.instance, .method = try cat.find("registry", "chainwallComponentId") },
        .{ .address = cast.instance, .method = try cat.find("policies", "getPolicy"), .args = &.{.{ .string = context.policyId }} },
        .{ .address = cast.instance, .method = try cat.find("accounts", "isAccountAllowed"), .args = &.{.{ .string = context.vault }} },
        .{ .address = cast.instance, .method = try cat.find("safes", "isSafeAllowed"), .args = &.{.{ .string = context.vault }} },
    });
    if (try c.number(a, try checks[0].require()) != ms.bytecode.hash("Chainwall.Registry")) return error.InvalidRegistry;
    _ = try checks[1].require();
    if (!(try checks[2].require()).bool and !(try checks[3].require()).bool) return error.UnregisteredRecipientVault;
    if (list) {
        var entries = std.json.Array.init(a);
        const batch = @import("metadata_batch.zig");
        const reads = try a.alloc(batch.Read, listing.entries.len);
        for (listing.entries, reads) |entry, *item| item.* = .{ .address = context.registryAddress, .method = try cat.find("policy-state", "getPolicyUint"), .args = try a.dupe(c.Value, &try parameters(a, context, try field(entry, "commitment"))) };
        for (listing.entries, try batch.read(&remote, reads)) |entry, result| {
            var row = try journal.publicEntry(a, entry);
            try row.object.put(a, "authorization", result.value);
            if (result.err != null) try row.object.put(a, "authorizationError", try result.detail(a));
            try entries.append(row);
        }
        if (!try remote.canonical(remote.block)) return error.ChainReorganizedRetrySync;
        const report = try c.parse(a, try c.encode(a, .{ .context = context, .entries = entries.items, .checkpoint = checkpoint, .authorizationBlock = remote.block, .invalid = listing.invalid, .unreadable = listing.unreadable, .cache = try @import("cache_metadata.zig").describe(a, "sqlite-cache", checkpoint, try c.parse(a, try c.encode(a, remote.block)), listing.invalid > 0 or listing.unreadable > 0) }));
        if (options.out) |path| try c.write(cast.io, path, try c.encode(a, report), false);
        return report;
    }
    const selected = if (add) c.Value.null else try journal.select(listing, options.reference orelse return error.RecipientRequired);
    if (resolve) {
        const state = try authorization(&remote, cat, context, try field(selected, "commitment"));
        if (!(try field(state, "found")).bool or try c.number(a, try field(state, "value")) != 1) return error.RecipientNotAuthorized;
        if (!try remote.canonical(remote.block)) return error.ChainReorganizedRetrySync;
        if (!options.dry) {
            const args = try abi.array(a, &.{ try abi.uint(a, try c.number(a, try field(selected, "recipient"))), try abi.uint(a, try c.number(a, try field(selected, "mask"))) });
            try c.write(cast.io, options.out.?, try c.encode(a, .{ .context = context, .commitment = try field(selected, "commitment"), .args = args, .authorizationBlock = remote.block }), false);
        }
        return c.parse(a, try c.encode(a, .{ .file = if (options.dry) null else options.out, .commitment = try field(selected, "commitment"), .authorized = true, .argumentCount = 2 }));
    }
    try noPending(&remote, cat, context);
    if (add or remove) {
        if (listing.invalid > 0 or listing.unreadable > 0) return error.IncompleteRecipientJournal;
        if (add) for (listing.entries) |entry| {
            if (std.ascii.eqlIgnoreCase(try c.string(try field(entry, "recipient")), options.recipient orelse return error.RecipientRequired)) return error.RecipientAlreadyInAddressBook;
        };
        if (remove) {
            const state = try authorization(&remote, cat, context, try field(selected, "commitment"));
            if ((try field(state, "found")).bool and try c.number(a, try field(state, "value")) != 0) return error.RevokeRecipientBeforeRemoval;
        }
        const record = try journal.create(a, cast.io, secret, context, if (add) options.recipient else null, options.label orelse "", if (remove) try c.string(try field(selected, "commitment")) else null);
        const plaintext = try journal.encode(a, record);
        defer std.crypto.secureZero(u8, @constCast(plaintext));
        if (!try remote.canonical(remote.block)) return error.ChainReorganizedRetrySync;
        const kv: @import("contract_client.zig").Client = .{ .cast = kv_cast, .cat = try contracts.Catalog.loadAuxiliary(a), .group = "kv" };
        var report = try c.parse(a, try c.encode(a, .{ .key = try field(record, "recordKey"), .commitment = try field(record, "commitment"), .kind = if (remove) "tombstone" else "upsert", .transaction = c.Value.null }));
        if (options.out) |path| try c.write(cast.io, path, try c.encode(a, report), false);
        const receipt = try @import("kv_write.zig").write(kv, secret, try c.string(try field(record, "recordKey")), plaintext, options.dry);
        try report.object.put(a, "transaction", receipt);
        if (options.out) |path| try c.write(cast.io, path, try c.encode(a, report), true);
        return report;
    }
    const allow = c.eq(u8, options.verb, "authorize");
    const method = try cat.find("policy-state", "setPolicyUint");
    const values = (try parameters(a, context, try field(selected, "commitment"))) ++ .{try abi.uint(a, if (allow) 1 else 0)};
    const data = try abi.calldata(a, method.abi, try abi.array(a, &values));
    var report = try c.parse(a, try c.encode(a, .{ .commitment = try field(selected, "commitment"), .allowed = allow, .transaction = .{ .chainId = cast.chain, .to = cast.instance, .data = data, .value = "0" } }));
    if (!try remote.canonical(remote.block)) return error.ChainReorganizedRetrySync;
    if (options.out) |path| try c.write(cast.io, path, try c.encode(a, report), false);
    if (!options.dry) {
        const sender = try cast.signerAddress();
        _ = try remote.one("eth_call", try abi.array(a, &.{ try c.parse(a, try c.encode(a, .{ .from = sender, .to = cast.instance, .data = data })), try remote.blockSelector() }));
        if (!try remote.canonical(remote.block)) return error.ChainReorganizedRetrySync;
        const receipt = try cast.send(data, null);
        try report.object.put(a, "receipt", receipt);
        if (options.out) |path| try c.write(cast.io, path, try c.encode(a, report), true);
        try report.object.put(a, "outcome", try c.parse(a, try c.encode(a, try @import("receipts.zig").classify(a, cat, receipt, cast.instance, method, &.{}))));
        if (options.out) |path| try c.write(cast.io, path, try c.encode(a, report), true);
    }
    return report;
}
