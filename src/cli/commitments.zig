const std = @import("std");
const c = @import("common.zig");
const abi = @import("abi_codec.zig");
const ms = @import("miniscript");
const codec = @import("commitment_codec.zig");
const rpc = @import("rpc.zig");
const contracts = @import("contracts.zig");
const Vault = @import("vault.zig").Vault;
const Cast = @import("cast.zig").Cast;
const field = codec.field;
const string = codec.string;
fn same(left: []const u8, right: []const u8) bool {
    return std.ascii.eqlIgnoreCase(left, right);
}
fn vaultKey(a: c.A, chain: u64, registry: []const u8) ![]const u8 {
    return a.print("commitments:{s}", .{try @import("store.zig").scopeKey(a, chain, registry)});
}
pub fn load(v: Vault, chain: u64, registry: []const u8) !c.Value {
    const bytes = (try v.get(try vaultKey(v.a, chain, registry))) orelse return .{ .object = .empty };
    defer std.crypto.secureZero(u8, bytes);
    const drafts = try c.parse(v.a, bytes);
    if (drafts != .object or drafts.object.count() > 1024) return error.InvalidCommitmentDraft;
    return drafts;
}
pub fn save(v: Vault, chain: u64, registry: []const u8, draft: c.Value, replace: bool) !void {
    try codec.validate(v.a, draft, chain, registry);
    try v.db.begin();
    errdefer v.db.db.rollback();
    var drafts = try load(v, chain, registry);
    const id = try string(draft, "commitHash");
    if (!replace and drafts.object.contains(id)) return error.CommitmentDraftAlreadyExists;
    if (!replace and drafts.object.count() == 1024) return error.CommitmentDraftLimit;
    try drafts.object.put(v.a, id, draft);
    const bytes = try c.encode(v.a, drafts);
    defer std.crypto.secureZero(u8, @constCast(bytes));
    try v.put(try vaultKey(v.a, chain, registry), bytes);
    try v.db.db.commit();
}
pub fn prepare(cast: *Cast, kind: []const u8, input: c.Value) !c.Value {
    const a = cast.a;
    try codec.strict(input, "payload deadline forwarder hint");
    const now: u64 = @intCast(std.Io.Clock.real.now(cast.io).toSeconds());
    const deadline = try rpc.integer(a, c.field(input, "deadline") orelse try abi.uint(a, now + 7 * 24 * 60 * 60));
    if (deadline <= now or deadline - now > codec.lifetime) return error.InvalidCommitmentDeadline;
    const value = try codec.payload(a, kind, try field(input, "payload"));
    var salt: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &salt);
    try cast.io.randomSecure(&salt);
    const salt_hex: c.Value = .{ .string = try abi.hex(a, &salt) };
    const draft = try c.parse(a, try c.encode(a, .{ .type = "chainwall.privateCommitment", .version = 1, .chainId = cast.chain, .registry = cast.instance, .kind = kind, .key = try codec.key(a, kind, value), .payload = value, .salt = salt_hex, .commitHash = try codec.commitment(a, kind, value, salt_hex), .deadline = deadline, .forwarder = c.field(input, "forwarder") orelse c.Value{ .string = codec.zero_address }, .hint = c.field(input, "hint") orelse c.Value{ .string = try c.hex(a, 0) }, .createdAt = now }));
    try codec.validate(a, draft, cast.chain, cast.instance);
    return draft;
}
pub fn template(a: c.A, kind: []const u8) !c.Value {
    const payload: c.Value = if (c.eq(u8, kind, "contract"))
        try c.parse(a, "{\"org\":\"example\",\"id\":\"vault\",\"address\":\"REPLACE_WITH_ADDRESS_OR_ACCOUNT\",\"version\":\"1.0.0\"}")
    else if (c.eq(u8, kind, "token"))
        try c.parse(a, "{\"org\":\"example\",\"id\":\"token\",\"symbol\":\"TKN\",\"decimals\":18}")
    else if (c.eq(u8, kind, "interaction"))
        try c.parse(a, "{\"bundle\":{\"id\":\"transfer\",\"script\":\"REPLACE_WITH_COMPILED_BYTECODE\",\"flags\":0,\"linked\":[]},\"relatedContracts\":[]}")
    else
        return error.InvalidCommitmentKind;
    return c.parse(a, try c.encode(a, .{ .payload = payload }));
}
fn read(remote: *rpc.Rpc, cat: contracts.Catalog, name: []const u8, values: []const c.Value) !c.Value {
    return remote.namedAt(remote.address, try cat.find("registry", name), values);
}
fn category(a: c.A, draft: c.Value) !c.Value {
    return .{ .string = try c.hex(a, ms.bytecode.hash(try a.print("timelock.category.{s}", .{try string(draft, "kind")}))) };
}
fn pending(remote: *rpc.Rpc, cat: contracts.Catalog, draft: c.Value) !c.Value {
    const a = remote.a;
    const count = try rpc.integer(a, try read(remote, cat, "getPendingActionCount", &.{}));
    if (count > 10000) return error.TooManyPendingActions;
    const expected_category = try c.number(a, try category(a, draft));
    var result = std.json.Array.init(a);
    var offset: u64 = 0;
    while (offset < count) {
        const size = @min(100, count - offset);
        const page = try read(remote, cat, "getPendingActionSummaries", &.{ try abi.uint(a, offset), try abi.uint(a, size) });
        if (page != .array or page.array.items.len != size) return error.InvalidPendingActionPage;
        for (page.array.items) |action| if (try c.number(a, try field(action, "category")) == expected_category and try c.number(a, try field(action, "scope")) == try c.number(a, try field(draft, "key"))) try result.append(action);
        offset += size;
    }
    return .{ .array = result };
}
fn snapshot(remote: *rpc.Rpc, cat: contracts.Catalog, draft: c.Value) !c.Value {
    if (try c.number(remote.a, try read(remote, cat, "chainwallComponentId", &.{})) != ms.bytecode.hash("Chainwall.Registry")) return error.InvalidRegistry;
    const current = try read(remote, cat, try codec.methodName(try string(draft, "kind"), "status"), &.{try field(draft, "key")});
    const exists = try c.number(remote.a, try field(current, "hash")) != 0;
    const matches = exists and same(try string(current, "hash"), try string(draft, "commitHash")) and
        try c.number(remote.a, try field(current, "deadline")) == try c.number(remote.a, try field(draft, "deadline")) and
        same(try string(current, "forwarder"), try string(draft, "forwarder")) and same(try string(current, "hint"), try string(draft, "hint"));
    return c.parse(remote.a, try c.encode(remote.a, .{ .block = remote.block, .state = if (!exists) "absent" else if (!matches) "mismatch" else if (remote.block.timestamp > try c.number(remote.a, try field(draft, "deadline"))) "expired" else "active", .commitment = current, .pendingActions = try pending(remote, cat, draft) }));
}
fn guard(remote: *rpc.Rpc, cat: contracts.Catalog, draft: c.Value, verb: []const u8, state: c.Value) !void {
    const a = remote.a;
    const deadline = try c.number(a, try field(draft, "deadline"));
    if ((try field(state, "pendingActions")).array.items.len != 0) return error.CommitmentActionPending;
    if (c.eq(u8, try string(state, "state"), "mismatch")) return error.CommitmentChanged;
    if (c.eq(u8, verb, "commit")) {
        if (!c.eq(u8, try string(state, "state"), "absent")) return error.CommitmentAlreadyOnchain;
        if (deadline <= remote.block.timestamp or deadline - remote.block.timestamp > codec.lifetime) return error.InvalidCommitmentDeadline;
        const cat_id = try category(a, draft);
        const configuration = try read(remote, cat, "getCategoryConfig", &.{cat_id});
        const override = try read(remote, cat, "getScopeOverride", &.{ cat_id, try field(draft, "key") });
        const fields = try field(override, "out");
        const delay = try c.number(a, if ((try field(override, "exists")).bool and (try field(fields, "setDelay")).bool) try field(fields, "delay") else try field(configuration, "defaultDelay"));
        if (deadline <= @as(u256, remote.block.timestamp) + delay) return error.CommitmentDeadlineBeforeTimelock;
    } else {
        if (c.eq(u8, try string(state, "state"), "absent")) return error.CommitmentMissing;
        if (c.eq(u8, verb, "reveal") and deadline < remote.block.timestamp) return error.CommitmentExpired;
        if (c.eq(u8, verb, "expire") and deadline >= remote.block.timestamp) return error.CommitmentNotExpired;
    }
}
fn eventField(event: c.Value, name: []const u8) !c.Value {
    for ((try field(event, "args")).array.items) |item| if (c.eq(u8, try string(item, "name"), name)) return field(item, "value");
    return error.InvalidCommitmentEvidence;
}
fn evidence(a: c.A, cat: contracts.Catalog, draft: c.Value, logs: c.Value) !c.Value {
    const attempt = try field(draft, "attempt");
    const verb = try string(attempt, "verb");
    const kind = try string(draft, "kind");
    const suffix = if (c.eq(u8, verb, "commit")) "Created" else if (c.eq(u8, verb, "reveal")) "Revealed" else if (c.eq(u8, verb, "expire") and !c.eq(u8, kind, "interaction")) "Expired" else "Cancelled";
    const name = try a.print("{s}Commit{s}", .{ try codec.methodName(kind, "prefix"), suffix });
    const events = try abi.array(a, &.{ cat.event(name).?, cat.event("ActionQueued").? });
    var result: c.Value = .null;
    var matches: usize = 0;
    for (logs.array.items) |log| {
        if (!same(try string(draft, "registry"), try string(log, "address")) or (c.field(log, "removed") orelse c.Value{ .bool = false }).bool) continue;
        const event = try @import("transaction_decode.zig").event(a, events, log);
        if (event == .null) continue;
        if (c.eq(u8, try string(event, "name"), "ActionQueued")) {
            if (!c.eq(u8, verb, "commit") or !same(try string(attempt, "dataHash"), try c.string(try eventField(event, "payloadHash"))) or !same(try string(attempt, "actor"), try c.string(try eventField(event, "actor")))) continue;
            result = try c.parse(a, try c.encode(a, .{ .status = "queued", .actionId = try eventField(event, "actionId"), .eta = try eventField(event, "eta") }));
        } else {
            if (!same(try string(draft, "key"), try c.string(try eventField(event, if (c.eq(u8, kind, "interaction")) "id" else "key")))) continue;
            if (!same(try string(attempt, "actor"), try c.string(try eventField(event, if (c.eq(u8, verb, "commit")) "committer" else "operator")))) continue;
            if (c.eq(u8, verb, "commit") or c.eq(u8, verb, "reveal")) if (!same(try string(draft, "commitHash"), try c.string(try eventField(event, "commitHash")))) continue;
            if (c.eq(u8, verb, "commit")) {
                if (try c.number(a, try eventField(event, "deadline")) != try c.number(a, try field(draft, "deadline")) or !same(try string(draft, "forwarder"), try c.string(try eventField(event, "forwarder"))) or !same(try string(draft, "hint"), try c.string(try eventField(event, "hint")))) continue;
            }
            result = try c.parse(a, try c.encode(a, .{ .status = if (c.eq(u8, verb, "commit")) "committed" else if (c.eq(u8, verb, "reveal")) "revealed" else if (c.eq(u8, verb, "expire")) "expired" else "cancelled" }));
        }
        matches += 1;
    }
    if (matches != 1) return error.CommitmentOutcomeUnproven;
    return result;
}
pub fn reconcile(remote: *rpc.Rpc, cat: contracts.Catalog, draft: *c.Value, tx_hash: []const u8) !void {
    const a = remote.a;
    _ = try codec.word(a, .{ .string = tx_hash });
    var attempt = try field(draft.*, "attempt");
    const receipt = try remote.one("eth_getTransactionReceipt", try abi.array(a, &.{.{ .string = tx_hash }}));
    if (receipt == .null) return error.TransactionReceiptUnavailable;
    if (!same(tx_hash, try string(receipt, "transactionHash"))) return error.InvalidCommitmentEvidence;
    const number = try rpc.integer(a, try field(receipt, "blockNumber"));
    if (number <= try rpc.integer(a, try field(try field(attempt, "block"), "number")) or number > remote.block.number) return error.InvalidCommitmentEvidence;
    const block = try remote.blockAt(try rpc.quantity(a, number));
    if (!same(block.hash, try string(receipt, "blockHash"))) return error.TransactionReorganized;
    const logs = try field(receipt, "logs");
    if (logs != .array) return error.InvalidCommitmentEvidence;
    for (logs.array.items) |log| if (!same(tx_hash, try string(log, "transactionHash")) or !same(block.hash, try string(log, "blockHash")) or number != try rpc.integer(a, try field(log, "blockNumber"))) return error.InvalidCommitmentEvidence;
    var outcome: c.Value = undefined;
    const status = try c.number(a, try field(receipt, "status"));
    if (status == 0) {
        const tx = try remote.one("eth_getTransactionByHash", try abi.array(a, &.{.{ .string = tx_hash }}));
        if (tx == .null or !same(tx_hash, try string(tx, "hash")) or !same(try string(attempt, "actor"), try string(tx, "from")) or !same(remote.address, try string(tx, "to")) or try c.number(a, try field(tx, "value")) != 0 or !same(try string(attempt, "dataHash"), try c.hex(a, ms.bytecode.hash(try abi.unhex(a, try string(tx, "input")))))) return error.CommitmentOutcomeUnproven;
        outcome = try c.parse(a, "{\"status\":\"reverted\"}");
    } else if (status == 1) outcome = try evidence(a, cat, draft.*, logs) else return error.InvalidCommitmentEvidence;
    if (!try remote.canonical(block) or !try remote.canonical(remote.block)) return error.TransactionReorganized;
    try attempt.object.put(a, "receipt", receipt);
    try attempt.object.put(a, "outcome", outcome);
    try draft.object.put(a, "attempt", attempt);
}
pub const Options = struct { verb: []const u8, out: ?[]const u8, signature: c.Value = .{ .string = "0x" }, retry: bool = false, dry: bool, receipt_hash: ?[]const u8 = null };
pub fn act(cast: *Cast, cat: contracts.Catalog, v: Vault, draft: *c.Value, options: Options) !c.Value {
    const a = cast.a;
    const verb = options.verb;
    if (!@import("schema.zig").contains("status commit reveal cancel expire reconcile", verb)) return error.UnknownCommand;
    if (cast.block != null) return error.TransactionRequiresLatestBlock;
    try codec.validate(a, draft.*, cast.chain, cast.instance);
    if (options.out) |path| try c.write(cast.io, path, "{\"status\":\"commitment-command-in-progress\"}\n", false);
    var remote = try rpc.Rpc.init(a, cast.io, cast.rpc, cast.chain, cast.instance);
    defer remote.deinit();
    try remote.pin(null, 0);
    const state = try snapshot(&remote, cat, draft.*);
    if (c.eq(u8, verb, "reconcile")) {
        if (options.dry) return error.DryRunNotApplicable;
        try reconcile(&remote, cat, draft, options.receipt_hash orelse return error.TransactionHashRequired);
        try save(v, cast.chain, cast.instance, draft.*, true);
    } else if (!c.eq(u8, verb, "status")) {
        try guard(&remote, cat, draft.*, verb, state);
        if (c.field(draft.*, "attempt")) |attempt| {
            const outcome = c.string(c.field(c.field(attempt, "outcome") orelse .null, "status") orelse .null) catch "unknown";
            if (c.eq(u8, verb, "commit") and @import("schema.zig").contains("revealed cancelled expired", outcome)) return error.PrepareNewCommitment;
            if (c.eq(u8, verb, try string(attempt, "verb")) and !options.retry) return error.CommitmentRetryRequiresReview;
            if (c.eq(u8, outcome, "unknown") and !options.retry) return error.CommitmentRetryRequiresReview;
        }
        const method = try cat.find("registry", try codec.methodName(try string(draft.*, "kind"), verb));
        const data = try abi.calldata(a, method.abi, try codec.arguments(a, draft.*, verb, options.signature));
        const sender: ?[]const u8 = if (!options.dry) try cast.signerAddress() else if (cast.auth) |auth| try string(auth.profile, "authAccount") else cast.from;
        // Wallet discovery may prompt. Refresh the entire commitment and pending
        // queue afterwards before revealing any secret to simulation or signing.
        try remote.pin(null, 0);
        const fresh = try snapshot(&remote, cat, draft.*);
        try guard(&remote, cat, draft.*, verb, fresh);
        if (!c.eq(u8, try c.encode(a, try field(state, "commitment")), try c.encode(a, try field(fresh, "commitment")))) return error.CommitmentChanged;
        if (sender) |actor| _ = try remote.one("eth_call", try abi.array(a, &.{ try c.parse(a, try c.encode(a, .{ .from = actor, .to = cast.instance, .data = data, .value = "0x0" })), try remote.blockSelector() }));
        if (!try remote.canonical(remote.block)) return error.ChainReorganizedRetrySync;
        if (!options.dry) {
            var attempt = try c.parse(a, try c.encode(a, .{ .verb = verb, .actor = sender.?, .dataHash = try c.hex(a, ms.bytecode.hash(try abi.unhex(a, data))), .block = remote.block }));
            try draft.object.put(a, "attempt", attempt);
            // Persist the exact intent before an ambiguous network outcome can
            // occur. Retrying is explicit, and a queued action blocks resubmission.
            try save(v, cast.chain, cast.instance, draft.*, true);
            const receipt = try cast.send(data, null);
            try attempt.object.put(a, "receipt", receipt);
            try draft.object.put(a, "attempt", attempt);
            try save(v, cast.chain, cast.instance, draft.*, true);
            try remote.pin(null, 0);
            try reconcile(&remote, cat, draft, try string(receipt, "transactionHash"));
            try save(v, cast.chain, cast.instance, draft.*, true);
        }
    }
    if (!try remote.canonical(remote.block)) return error.ChainReorganizedRetrySync;
    var report = try codec.summary(a, draft.*);
    try report.object.put(a, "live", if (options.dry or c.eq(u8, verb, "status")) state else try snapshot(&remote, cat, draft.*));
    try report.object.put(a, "dryRun", .{ .bool = options.dry });
    if (options.out) |path| try c.write(cast.io, path, try c.encode(a, report), true);
    return report;
}
