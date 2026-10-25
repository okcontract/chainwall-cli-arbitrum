const std = @import("std");
const ms = @import("miniscript");
const c = @import("common.zig");
const abi = @import("abi_codec.zig");
const contracts = @import("contracts.zig");
const rpc = @import("rpc.zig");
const Cast = @import("cast.zig").Cast;
const Args = @import("args.zig").Args;

fn field(value: c.Value, name: []const u8) !c.Value {
    return c.field(value, name) orelse error.InvalidCouncilReport;
}
fn same(left: []const u8, right: []const u8) bool {
    return std.ascii.eqlIgnoreCase(left, right);
}
fn read(remote: *rpc.Rpc, cat: contracts.Catalog, name: []const u8, values: []const c.Value) !c.Value {
    return remote.namedAt(remote.address, try cat.find("registry", name), values);
}
fn hasCode(remote: *rpc.Rpc, address: []const u8) !bool {
    return (try c.string(try remote.one("eth_getCode", try abi.array(remote.a, &.{ .{ .string = address }, try remote.blockSelector() })))).len > 2;
}
fn members(remote: *rpc.Rpc, cat: contracts.Catalog, group: []const u8) !c.Value {
    const a = remote.a;
    const revision = try read(remote, cat, "getGroupMembershipRevision", &.{.{ .string = group }});
    const addresses = try read(remote, cat, "getGroupMembers", &.{.{ .string = group }});
    var items = std.json.Array.init(a);
    var eligible: usize = 0;
    for (addresses.array.items) |value| {
        const address = try c.string(value);
        const live = !same(address, remote.address) and try c.word(address) != 0 and try hasCode(remote, address);
        if (live) eligible += 1;
        try items.append(try c.parse(a, try c.encode(a, .{ .address = address, .eligible = live })));
    }
    return c.parse(a, try c.encode(a, .{ .groupHash = group, .membershipRevision = revision, .members = items.items, .eligibleMembers = eligible }));
}
fn review(remote: *rpc.Rpc, cat: contracts.Catalog, group: []const u8, threshold: u32, recovery: []const u8) !c.Value {
    const value = try members(remote, cat, group);
    const items = (try field(value, "members")).array.items;
    if (threshold < 2 or threshold > 32 or threshold > items.len or items.len > 32) return error.CouncilThresholdInvalid;
    if (try c.number(remote.a, try field(value, "eligibleMembers")) != items.len) return error.CouncilMemberMustBeContract;
    if (same(recovery, remote.address) or !try hasCode(remote, recovery)) return error.CouncilRecoveryMustBeIndependentContract;
    for (items) |item| if (same(recovery, try c.string(try field(item, "address")))) return error.CouncilRecoveryMustBeIndependentContract;
    return value;
}
fn eventField(event: c.Value, name: []const u8) !c.Value {
    for ((try field(event, "args")).array.items) |item| if (c.eq(u8, try c.string(try field(item, "name")), name)) return field(item, "value");
    return error.InvalidCouncilEvidence;
}

/// Match the exact inner protocol call, including AuthAccount/EntryPoint relays.
fn evidence(a: c.A, cat: contracts.Catalog, registry: []const u8, actor: c.Value, data: []const u8, logs: c.Value) !c.Value {
    const events = try abi.array(a, &.{ cat.event("SecurityCouncilConfigured").?, cat.event("ActionQueued").? });
    var queued: c.Value = .null;
    var matches: usize = 0;
    const payload_hash = try c.hex(a, ms.bytecode.hash(try abi.unhex(a, data)));
    for (logs.array.items) |log| {
        if (!same(registry, try c.string(try field(log, "address"))) or (c.field(log, "removed") orelse c.Value{ .bool = false }).bool) continue;
        const event = try @import("transaction_decode.zig").event(a, events, log);
        if (event == .null) continue;
        const name = try c.string(try field(event, "name"));
        if (c.eq(u8, name, "SecurityCouncilConfigured")) {
            const emitted = try abi.calldata(a, (try cat.find("registry", "configureSecurityCouncil")).abi, try abi.array(a, &.{ try eventField(event, "groupHash"), try eventField(event, "threshold"), try eventField(event, "membershipRevision"), try eventField(event, "recoveryAuthority") }));
            if (same(emitted, data)) return c.parse(a, "{\"status\":\"configured\"}");
        } else if (actor != .null and same(payload_hash, try c.string(try eventField(event, "payloadHash"))) and same(try c.string(actor), try c.string(try eventField(event, "actor")))) {
            matches += 1;
            queued = try c.parse(a, try c.encode(a, .{ .status = "queued", .actionId = try eventField(event, "actionId"), .eta = try eventField(event, "eta") }));
        }
    }
    if (matches == 1) return queued;
    return error.CouncilOutcomeUnproven;
}

fn reconcile(remote: *rpc.Rpc, cat: contracts.Catalog, report: c.Value, hash: []const u8) !c.Value {
    const a = remote.a;
    if (hash.len != 66) return error.InvalidCouncilEvidence;
    _ = try abi.unhex(a, hash);
    const receipt = try remote.one("eth_getTransactionReceipt", try abi.array(a, &.{.{ .string = hash }}));
    if (receipt == .null) return error.TransactionReceiptUnavailable;
    if (!same(hash, try c.string(try field(receipt, "transactionHash")))) return error.InvalidCouncilEvidence;
    const block = try rpc.integer(a, try field(receipt, "blockNumber"));
    if (block <= try rpc.integer(a, try field(try field(report, "block"), "number")) or block > remote.block.number) return error.InvalidCouncilEvidence;
    const canonical = try remote.blockAt(try rpc.quantity(a, block));
    if (!same(canonical.hash, try c.string(try field(receipt, "blockHash")))) return error.TransactionReorganized;
    var outcome: c.Value = undefined;
    if (try c.number(a, try field(receipt, "status")) == 0) {
        const known = c.field(report, "receipt") orelse return error.CouncilOutcomeUnproven;
        if (!same(hash, try c.string(try field(known, "transactionHash")))) return error.CouncilOutcomeUnproven;
        outcome = try c.parse(a, "{\"status\":\"reverted\"}");
    } else {
        if (try c.number(a, try field(receipt, "status")) != 1) return error.InvalidCouncilEvidence;
        const logs = try field(receipt, "logs");
        for (logs.array.items) |log| {
            if (!same(hash, try c.string(try field(log, "transactionHash"))) or !same(canonical.hash, try c.string(try field(log, "blockHash"))) or try rpc.integer(a, try field(log, "blockNumber")) != block) return error.InvalidCouncilEvidence;
        }
        outcome = try evidence(a, cat, remote.address, try field(report, "actor"), try c.string(try field(try field(report, "transaction"), "data")), logs);
    }
    if (!try remote.canonical(canonical)) return error.TransactionReorganized;
    return c.parse(a, try c.encode(a, .{ .receipt = receipt, .outcome = outcome }));
}

pub fn run(cast: *Cast, cat: contracts.Catalog, args: *Args, p: []const []const u8, dry: bool) !c.Value {
    const a = cast.a;
    if (p.len < 2) return error.WrongArgumentCount;
    const verb = p[1];
    const out = args.get("out");
    const configure = c.eq(u8, verb, "configure");
    const threshold = if (configure) try std.fmt.parseInt(u32, args.get("threshold") orelse return error.CouncilThresholdRequired, 10) else 0;
    const recovery = if (configure) args.get("recovery-authority") orelse return error.CouncilRecoveryRequired else "";
    try args.finish();
    if (configure and !dry and out == null) return error.CouncilReportRequired;
    if (configure and cast.block != null and !dry) return error.TransactionRequiresLatestBlock;
    var remote = try rpc.Rpc.init(a, cast.io, cast.rpc, cast.chain, cast.instance);
    defer remote.deinit();
    try remote.pin(cast.block, 0);
    if (c.eq(u8, verb, "reconcile")) {
        if (p.len != 4 or dry or out != null or cast.block != null) return error.WrongArgumentCount;
        var report = try @import("json_schema.zig").read(a, cast.io, "council-report", p[2]);
        if (!c.eq(u8, try c.string(try field(report, "type")), "chainwall.securityCouncil") or try c.number(a, try field(report, "chainId")) != cast.chain or !same(cast.instance, try c.string(try field(report, "registry")))) return error.CouncilReportContextMismatch;
        const tx = try field(report, "transaction");
        if (!same(cast.instance, try c.string(try field(tx, "to"))) or try c.number(a, try field(tx, "value")) != 0) return error.InvalidCouncilReport;
        const call = try @import("transaction_decode.zig").call(a, try abi.array(a, &.{(try cat.find("registry", "configureSecurityCouncil")).abi}), try c.string(try field(tx, "data")));
        if (call == .null or !(try field(call, "canonical")).bool) return error.InvalidCouncilReport;
        const result = try reconcile(&remote, cat, report, p[3]);
        try report.object.put(a, "receipt", try field(result, "receipt"));
        try report.object.put(a, "outcome", try field(result, "outcome"));
        try c.write(cast.io, p[2], try c.encode(a, report), true);
        return report;
    }
    if (!configure and !c.eq(u8, verb, "inspect")) return error.UnknownCouncilCommand;
    if ((configure and p.len != 3) or (!configure and p.len != 2 and p.len != 3)) return error.WrongArgumentCount;
    const configuration = try read(&remote, cat, "getSecurityCouncilConfiguration", &.{});
    const group = if (p.len == 3) try c.id(a, p[2]) else try c.string(try field(configuration, "groupHash"));
    var report = try c.parse(a, try c.encode(a, .{ .type = "chainwall.securityCouncil", .chainId = cast.chain, .registry = cast.instance, .block = remote.block, .configuration = configuration }));
    if (!configure) {
        try report.object.put(a, "membership", if (try c.word(group) == 0) .null else try members(&remote, cat, group));
        if (!try remote.canonical(remote.block)) return error.ChainReorganizedRetrySync;
        if (out) |path| try c.write(cast.io, path, try c.encode(a, report), false);
        return report;
    }
    try c.address(recovery);
    const membership = try review(&remote, cat, group, threshold, recovery);
    const method = try cat.find("registry", "configureSecurityCouncil");
    const data = try abi.calldata(a, method.abi, try abi.array(a, &.{ .{ .string = group }, try abi.uint(a, threshold), try field(membership, "membershipRevision"), .{ .string = recovery } }));
    const actor: c.Value = if (!dry) .{ .string = try cast.signerAddress() } else if (cast.auth) |auth| try field(auth.profile, "authAccount") else if (cast.from) |from| .{ .string = from } else .null;
    if (actor != .null and !(try read(&remote, cat, "hasRole", &.{ .{ .string = try c.hex(a, ms.bytecode.hash("ADMIN_ROLE")) }, actor })).bool) return error.CouncilAdminRequired;
    try report.object.put(a, "membership", membership);
    try report.object.put(a, "actor", actor);
    try report.object.put(a, "transaction", try c.parse(a, try c.encode(a, .{ .to = cast.instance, .data = data, .value = "0", .nonce = cast.nonce })));
    if (!try remote.canonical(remote.block)) return error.ChainReorganizedRetrySync;
    if (out) |path| try c.write(cast.io, path, try c.encode(a, report), false);
    if (dry) return report;
    // Recheck membership and code after wallet discovery. The revision is also
    // bound in calldata, so a later change cannot silently appoint other seats.
    try remote.pin(null, 0);
    const latest = try review(&remote, cat, group, threshold, recovery);
    if (!c.eq(u8, try c.encode(a, membership), try c.encode(a, latest))) return error.CouncilMembershipChanged;
    _ = try remote.one("eth_call", try abi.array(a, &.{ try c.parse(a, try c.encode(a, .{ .from = actor, .to = cast.instance, .data = data })), try remote.blockSelector() }));
    if (!try remote.canonical(remote.block)) return error.ChainReorganizedRetrySync;
    const receipt = try cast.send(data, null);
    try report.object.put(a, "receipt", receipt);
    try c.write(cast.io, out.?, try c.encode(a, report), true);
    try remote.pin(null, 0);
    const result = try reconcile(&remote, cat, report, try c.string(try field(receipt, "transactionHash")));
    try report.object.put(a, "receipt", try field(result, "receipt"));
    try report.object.put(a, "outcome", try field(result, "outcome"));
    try c.write(cast.io, out.?, try c.encode(a, report), true);
    return report;
}
