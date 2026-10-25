const std = @import("std");
const c = @import("common.zig");
const abi = @import("abi_codec.zig");
const ms = @import("miniscript");
const rpc = @import("rpc.zig");
const contracts = @import("contracts.zig");
const catalog = @import("facet_catalog.zig");
const planner = @import("facet_plan.zig");
const Cast = @import("cast.zig").Cast;
const Store = @import("store.zig").Store;
const Args = @import("args.zig").Args;
const field = catalog.field;
const string = catalog.string;
const same = catalog.same;

fn read(remote: *rpc.Rpc, cat: contracts.Catalog, name: []const u8, args: []const c.Value) !c.Value {
    return remote.namedAt(remote.address, try cat.find("registry", name), args);
}
fn canonical(remote: *rpc.Rpc) !void {
    if (!try remote.canonical(remote.block)) return error.ChainReorganizedRetrySync;
}
fn deploymentScope(a: c.A, chain: u64) ![]const u8 {
    return a.print("facet-deployments:{d}", .{chain});
}
fn proofHash(db: Store, chain: u64, address: []const u8, explicit: ?[]const u8) !?[]const u8 {
    if (explicit) |hash| return hash;
    const entries = try db.entries(try deploymentScope(db.a, chain), "receipts");
    return if (entries.get(try std.ascii.allocLowerString(db.a, address))) |receipt| try string(receipt, "transactionHash") else null;
}
fn topology(remote: *rpc.Rpc, cat: contracts.Catalog) !planner.Routes {
    if (try c.number(remote.a, try read(remote, cat, "chainwallComponentId", &.{})) != ms.bytecode.hash("Chainwall.Registry")) return error.InvalidRegistry;
    return planner.routes(remote.a, try read(remote, cat, "facets", &.{}));
}
fn pending(remote: *rpc.Rpc, cat: contracts.Catalog) !c.Value {
    const a = remote.a;
    const count = try rpc.integer(a, try read(remote, cat, "getPendingActionCount", &.{}));
    if (count > 10000) return error.TooManyPendingActions;
    var result = std.json.Array.init(a);
    var offset: u64 = 0;
    while (offset < count) {
        const size = @min(100, count - offset);
        const page = try read(remote, cat, "getPendingActionSummaries", &.{ try abi.uint(a, offset), try abi.uint(a, size) });
        if (page != .array or page.array.items.len != size) return error.InvalidPendingActionPage;
        for (page.array.items) |action| if (try c.number(a, try field(action, "category")) == ms.bytecode.hash("timelock.category.diamond")) try result.append(action);
        offset += size;
    }
    return .{ .array = result };
}
fn contains(selectors: c.Value, needle: []const u8) !bool {
    for (selectors.array.items) |item| if (same(try c.string(item), needle)) return true;
    return false;
}
fn currentFacet(a: c.A, routes: planner.Routes, entry: c.Value, target: []const u8, explicit: ?[]const u8) !?[]const u8 {
    if (explicit) |address| {
        if (c.eq(u8, address, "none")) return null;
        try c.address(address);
        return address;
    }
    var candidates: std.StringHashMapUnmanaged(void) = .empty;
    for ((try field(entry, "selectors")).array.items) |value| if (routes.get(try c.string(value))) |address| {
        if (!same(address, target)) try candidates.put(a, address, {});
    };
    if (candidates.count() > 1) return error.AmbiguousCurrentFacet;
    if (candidates.count() == 1) {
        var iterator = candidates.keyIterator();
        return iterator.next().?.*;
    }
    for (routes.values()) |address| if (same(address, target)) return target;
    return null;
}
fn makePlan(remote: *rpc.Rpc, cat: contracts.Catalog, entries: c.Value, db: Store, entry: c.Value, target: []const u8, current: ?[]const u8, choices: c.Value, explicit_proof: ?[]const u8) !c.Value {
    const a = remote.a;
    const before = try topology(remote, cat);
    const selected = try currentFacet(a, before, entry, target, current);
    const proof = try proofHash(db, remote.chain, target, explicit_proof);
    const verified = try catalog.verify(remote, entry, target, proof);
    var plan = try planner.build(a, remote.address, selected, target, try field(entry, "selectors"), before, choices);
    var destination_hashes: std.json.ObjectMap = .empty;
    const cuts = try field(plan, "cuts");
    if (cuts != .null) for (cuts.array.items) |cut| {
        const removing = try c.number(a, try field(cut, "action")) == 2;
        for ([_][]const u8{ "cut", "loupe" }) |key| {
            const core = try catalog.find(a, entries, key);
            for ((try field(cut, "functionSelectors")).array.items) |selector| {
                if (!try contains(try field(core, "selectors"), try c.string(selector))) continue;
                if (removing) return error.CoreFacetSelectorProtected;
                const checked = try catalog.verify(remote, core, try string(cut, "facetAddress"), null);
                if (!(try field(checked, "compatible")).bool) return error.CoreFacetTargetMismatch;
            }
        }
        if (!removing) {
            const address = try string(cut, "facetAddress");
            const code = try catalog.code(remote, address);
            if (code.len <= 2) return error.FacetHasNoCode;
            try destination_hashes.put(a, try std.ascii.allocLowerString(a, address), .{ .string = try catalog.codehash(a, code) });
        }
    };
    const queue = try pending(remote, cat);
    const ready = (try field(plan, "ready")).bool and (try field(verified, "compatible")).bool and queue.array.items.len == 0;
    try plan.object.put(a, "ready", .{ .bool = ready });
    try plan.object.put(a, "type", .{ .string = "chainwall.facetPlan" });
    try plan.object.put(a, "version", .{ .integer = 1 });
    try plan.object.put(a, "chainId", try abi.uint(a, remote.chain));
    try plan.object.put(a, "registry", .{ .string = remote.address });
    try plan.object.put(a, "block", try c.parse(a, try c.encode(a, remote.block)));
    try plan.object.put(a, "selection", try c.parse(a, try c.encode(a, .{ .facet = try field(entry, "key"), .target = target, .current = if (selected) |address| address else "none", .choices = choices, .deploymentTx = if (proof) |hash| c.Value{ .string = hash } else c.Value.null, .creationCodehash = try field(entry, "creationCodehash") })));
    try plan.object.put(a, "before", try planner.exportRoutes(a, before));
    try plan.object.put(a, "verification", verified);
    try plan.object.put(a, "destinationCodehashes", .{ .object = destination_hashes });
    try plan.object.put(a, "pendingActions", queue);
    try plan.object.put(a, "transaction", try transaction(a, cat, remote.address, cuts));
    try canonical(remote);
    return plan;
}
fn transaction(a: c.A, cat: contracts.Catalog, registry: []const u8, cuts: c.Value) !c.Value {
    return if (cuts == .null or cuts.array.items.len == 0) .null else c.parse(a, try c.encode(a, .{ .to = registry, .data = try abi.calldata(a, (try cat.find("registry", "diamondCut")).abi, try abi.array(a, &.{ cuts, .{ .string = catalog.zero }, .{ .string = "0x" } })), .value = "0" }));
}
fn validatePlan(a: c.A, cast: *Cast, cat: contracts.Catalog, entries: c.Value, plan: c.Value) !c.Value {
    if (!c.eq(u8, try string(plan, "type"), "chainwall.facetPlan") or try c.number(a, try field(plan, "version")) != 1 or try c.number(a, try field(plan, "chainId")) != cast.chain or !same(try string(plan, "registry"), cast.instance)) return error.FacetPlanContextMismatch;
    const selection = try field(plan, "selection");
    const entry = try catalog.find(a, entries, try string(selection, "facet"));
    if (!same(try string(selection, "creationCodehash"), try string(entry, "creationCodehash"))) return error.FacetCatalogChanged;
    const current = try string(selection, "current");
    const rebuilt = try planner.build(a, cast.instance, if (c.eq(u8, current, "none")) null else current, try string(selection, "target"), try field(entry, "selectors"), try planner.importRoutes(a, try field(plan, "before")), try field(selection, "choices"));
    for ([_][]const u8{ "cuts", "expectedRoutes" }) |key| if (!c.eq(u8, try c.encode(a, try field(rebuilt, key)), try c.encode(a, try field(plan, key)))) return error.InvalidFacetPlan;
    if (!c.eq(u8, try c.encode(a, try transaction(a, cat, cast.instance, try field(rebuilt, "cuts"))), try c.encode(a, try field(plan, "transaction")))) return error.InvalidFacetPlan;
    return entry;
}
fn revalidate(remote: *rpc.Rpc, cat: contracts.Catalog, entries: c.Value, db: Store, entry: c.Value, plan: c.Value) !c.Value {
    const selection = try field(plan, "selection");
    const proof = try field(selection, "deploymentTx");
    const before_block = try field(plan, "block");
    const canonical_before = try remote.blockAt(try rpc.quantity(remote.a, try rpc.integer(remote.a, try field(before_block, "number"))));
    if (!same(canonical_before.hash, try string(before_block, "hash"))) return error.TransactionReorganized;
    const fresh = try makePlan(remote, cat, entries, db, entry, try string(selection, "target"), try string(selection, "current"), try field(selection, "choices"), if (proof != .null) try c.string(proof) else null);
    if (!(try field(fresh, "ready")).bool) return error.FacetPlanNotReady;
    for ([_][]const u8{ "before", "transaction", "destinationCodehashes", "expectedRoutes" }) |key| if (!c.eq(u8, try c.encode(remote.a, try field(fresh, key)), try c.encode(remote.a, try field(plan, key)))) return error.FacetPlanChanged;
    const dependency = try field(try field(fresh, "verification"), "dependency");
    if (!c.eq(u8, try c.encode(remote.a, dependency), try c.encode(remote.a, try field(try field(plan, "verification"), "dependency")))) return error.FacetPlanChanged;
    return fresh;
}
fn eventField(event: c.Value, name: []const u8) !c.Value {
    for ((try field(event, "args")).array.items) |item| if (c.eq(u8, try string(item, "name"), name)) return field(item, "value");
    return error.InvalidFacetEvidence;
}
fn evidence(a: c.A, cat: contracts.Catalog, plan: c.Value, receipt: c.Value) !c.Value {
    const events = try abi.array(a, &.{ cat.event("DiamondCut").?, cat.event("ActionQueued").? });
    const expected = try string(try field(plan, "transaction"), "data");
    const actor = try string(try field(plan, "attempt"), "actor");
    var matches: usize = 0;
    var result: c.Value = .null;
    for ((try field(receipt, "logs")).array.items) |log| {
        if (!same(try string(plan, "registry"), try string(log, "address")) or (c.field(log, "removed") orelse c.Value{ .bool = false }).bool) continue;
        const event = try @import("transaction_decode.zig").event(a, events, log);
        if (event == .null) continue;
        if (c.eq(u8, try string(event, "name"), "DiamondCut")) {
            const data = try abi.calldata(a, (try cat.find("registry", "diamondCut")).abi, try abi.array(a, &.{ try eventField(event, "_diamondCut"), try eventField(event, "_init"), try eventField(event, "_calldata") }));
            if (!same(data, expected)) continue;
            result = try c.parse(a, "{\"status\":\"applied\"}");
        } else {
            if (!same(actor, try c.string(try eventField(event, "actor"))) or !same(try catalog.codehash(a, expected), try c.string(try eventField(event, "payloadHash")))) continue;
            result = try c.parse(a, try c.encode(a, .{ .status = "queued", .actionId = try eventField(event, "actionId"), .eta = try eventField(event, "eta") }));
        }
        matches += 1;
    }
    if (matches != 1) return error.FacetOutcomeUnproven;
    return result;
}
fn checkRoutes(remote: *rpc.Rpc, cat: contracts.Catalog, plan: c.Value) !c.Value {
    const actual = try topology(remote, cat);
    const expected = try planner.importRoutes(remote.a, try field(plan, "expectedRoutes"));
    var mismatches = std.json.Array.init(remote.a);
    for (expected.keys(), expected.values()) |key, address| {
        const found = actual.get(key) orelse catalog.zero;
        if (!same(address, found)) try mismatches.append(try c.parse(remote.a, try c.encode(remote.a, .{ .selector = key, .expected = address, .actual = found })));
    }
    for (actual.keys(), actual.values()) |key, address| if (!expected.contains(key)) try mismatches.append(try c.parse(remote.a, try c.encode(remote.a, .{ .selector = key, .expected = catalog.zero, .actual = address })));
    var changed_code = std.json.Array.init(remote.a);
    const hashes = try field(plan, "destinationCodehashes");
    if (hashes != .object) return error.InvalidFacetPlan;
    for (hashes.object.keys(), hashes.object.values()) |address, hash| {
        const actual_hash = try catalog.codehash(remote.a, try catalog.code(remote, address));
        if (!same(try c.string(hash), actual_hash)) try changed_code.append(try c.parse(remote.a, try c.encode(remote.a, .{ .address = address, .expected = hash, .actual = actual_hash })));
    }
    const dependency = try field(try field(plan, "verification"), "dependency");
    if (dependency != .null) {
        const address = try string(dependency, "address");
        const actual_hash = try catalog.codehash(remote.a, try catalog.code(remote, address));
        if (!same(try string(dependency, "codehash"), actual_hash)) try changed_code.append(try c.parse(remote.a, try c.encode(remote.a, .{ .address = address, .expected = try field(dependency, "codehash"), .actual = actual_hash })));
    }
    return c.parse(remote.a, try c.encode(remote.a, .{ .matches = mismatches.items.len == 0 and changed_code.items.len == 0, .mismatches = mismatches.items, .changedCode = changed_code.items, .block = remote.block }));
}
fn reconcile(remote: *rpc.Rpc, cat: contracts.Catalog, plan: *c.Value, hash: []const u8) !void {
    const a = remote.a;
    if (hash.len != 66) return error.InvalidFacetEvidence;
    _ = try abi.unhex(a, hash);
    const receipt = try remote.one("eth_getTransactionReceipt", try abi.array(a, &.{.{ .string = hash }}));
    if (receipt == .null) return error.TransactionReceiptUnavailable;
    if (!same(hash, try string(receipt, "transactionHash")) or try c.number(a, try field(receipt, "status")) != 1) return error.FacetOutcomeUnproven;
    const number = try rpc.integer(a, try field(receipt, "blockNumber"));
    if (number <= try rpc.integer(a, try field(try field(try field(plan.*, "attempt"), "block"), "number")) or number > remote.block.number) return error.InvalidFacetEvidence;
    const block = try remote.blockAt(try rpc.quantity(a, number));
    if (!same(block.hash, try string(receipt, "blockHash"))) return error.TransactionReorganized;
    for ((try field(receipt, "logs")).array.items) |log| if (!same(hash, try string(log, "transactionHash")) or !same(block.hash, try string(log, "blockHash")) or number != try rpc.integer(a, try field(log, "blockNumber"))) return error.InvalidFacetEvidence;
    const outcome = try evidence(a, cat, plan.*, receipt);
    if (c.eq(u8, try string(outcome, "status"), "applied")) {
        const head = remote.block;
        remote.block = block;
        defer remote.block = head;
        const verified_routes = try checkRoutes(remote, cat, plan.*);
        if (!(try field(verified_routes, "matches")).bool) return error.FacetRoutesMismatch;
        try plan.object.put(a, "verifiedRoutes", verified_routes);
    }
    try canonical(remote);
    if (!try remote.canonical(block)) return error.TransactionReorganized;
    try plan.object.put(a, "receipt", receipt);
    try plan.object.put(a, "outcome", outcome);
}
pub fn run(cast: *Cast, cat: contracts.Catalog, dir: []const u8, args: *Args, p: []const []const u8, dry: bool) !c.Value {
    const a = cast.a;
    if (p.len < 2) return error.WrongArgumentCount;
    const verb = p[1];
    const entries = try catalog.load(a);
    const out = args.get("out");
    if (c.eq(u8, verb, "catalog")) {
        if (p.len > 3) return error.WrongArgumentCount;
        try args.finish();
        var rows = std.json.Array.init(a);
        for (entries.array.items) |entry| try rows.append(try catalog.publicEntry(a, entry));
        const result = if (p.len == 3) try catalog.publicEntry(a, try catalog.find(a, entries, p[2])) else c.Value{ .array = rows };
        if (out) |file| try c.write(cast.io, file, try c.encode(a, result), false);
        return result;
    }
    const plan_command = c.eq(u8, verb, "plan");
    const target = if (plan_command) args.get("target") orelse return error.FacetTargetRequired else null;
    const current = if (plan_command) args.get("current") else null;
    const choices_file = if (plan_command) args.get("choices-file") else null;
    const proof = if (plan_command or c.eq(u8, verb, "verify")) args.get("deployment-tx") else null;
    const retry = if (c.eq(u8, verb, "apply")) args.flag("retry") else false;
    try args.finish();
    if (cast.block != null) return error.TransactionRequiresLatestBlock;
    if (p.len != @as(usize, if (c.eq(u8, verb, "verify") or c.eq(u8, verb, "reconcile")) 4 else 3)) return error.WrongArgumentCount;
    if (!@import("schema.zig").contains("deploy verify plan apply check reconcile", verb)) return error.UnknownCommand;
    const db = try Store.open(a, cast.io, dir);
    defer db.close();
    var remote = try rpc.Rpc.initEndpoint(a, cast.io, cast.rpc, cast.chain);
    defer remote.deinit();
    remote.address = cast.instance;
    try remote.pinBlock(null, 0);
    if (c.eq(u8, verb, "deploy")) {
        const entry = try catalog.find(a, entries, p[2]);
        const data = try string(entry, "creationBytecode");
        var report = try c.parse(a, try c.encode(a, .{ .facet = try field(entry, "key"), .chainId = cast.chain, .creationCodehash = try field(entry, "creationCodehash"), .transaction = .{ .data = data, .value = "0" }, .block = remote.block }));
        if (!dry and out == null) return error.OutputFileRequired;
        if (out) |file| try c.write(cast.io, file, try c.encode(a, report), false);
        try canonical(&remote);
        if (dry) return report;
        const receipt = try cast.create(data, null);
        try report.object.put(a, "receipt", receipt);
        try c.write(cast.io, out.?, try c.encode(a, report), true);
        const address = try string(receipt, "contractAddress");
        try c.address(address);
        // Cache only a hint. Every reuse proves the canonical transaction again.
        try db.put(try deploymentScope(a, cast.chain), "receipts", try std.ascii.allocLowerString(a, address), receipt);
        try remote.pinBlock(null, 0);
        const verified = try catalog.verify(&remote, entry, address, try string(receipt, "transactionHash"));
        try canonical(&remote);
        try report.object.put(a, "address", .{ .string = address });
        try report.object.put(a, "verification", verified);
        try c.write(cast.io, out.?, try c.encode(a, report), true);
        if (!(try field(verified, "compatible")).bool) return error.IncompatibleFacet;
        return report;
    }
    if (c.eq(u8, verb, "verify")) {
        const result = try catalog.verify(&remote, try catalog.find(a, entries, p[2]), p[3], try proofHash(db, cast.chain, p[3], proof));
        try canonical(&remote);
        if (out) |file| try c.write(cast.io, file, try c.encode(a, result), false);
        return result;
    }
    if (plan_command) {
        const choices = if (choices_file) |file| try @import("json_schema.zig").read(a, cast.io, "facet-choices", file) else c.Value{ .object = .empty };
        const result = try makePlan(&remote, cat, entries, db, try catalog.find(a, entries, p[2]), target.?, current, choices, proof);
        if (out) |file| try c.write(cast.io, file, try c.encode(a, result), false);
        return result;
    }
    if (out != null) return error.FacetPlanUpdatedInPlace;
    const lock = try std.Io.Dir.cwd().createFile(cast.io, try a.print("{s}.lock", .{p[2]}), .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true, .permissions = .fromMode(0o600) });
    defer lock.close(cast.io);
    var plan = try @import("json_schema.zig").read(a, cast.io, "facet-plan", p[2]);
    const entry = try validatePlan(a, cast, cat, entries, plan);
    if (c.eq(u8, verb, "check")) {
        const result = try checkRoutes(&remote, cat, plan);
        try canonical(&remote);
        return result;
    }
    if (c.eq(u8, verb, "reconcile")) {
        if (dry) return error.DryRunNotApplicable;
        try reconcile(&remote, cat, &plan, p[3]);
        try c.write(cast.io, p[2], try c.encode(a, plan), true);
        return plan;
    }
    if (c.field(plan, "attempt") != null and !retry and !dry) return error.FacetRetryRequiresReview;
    _ = try revalidate(&remote, cat, entries, db, entry, plan);
    const actor = if (!dry) try cast.signerAddress() else cast.from;
    try remote.pinBlock(null, 0);
    _ = try revalidate(&remote, cat, entries, db, entry, plan);
    const data = try string(try field(plan, "transaction"), "data");
    if (actor) |from| _ = try remote.one("eth_call", try abi.array(a, &.{ try c.parse(a, try c.encode(a, .{ .from = from, .to = cast.instance, .data = data, .value = "0x0" })), try remote.blockSelector() }));
    try canonical(&remote);
    if (dry) return plan;
    try plan.object.put(a, "attempt", try c.parse(a, try c.encode(a, .{ .actor = actor.?, .block = remote.block })));
    try c.write(cast.io, p[2], try c.encode(a, plan), true);
    const receipt = try cast.send(data, null);
    try plan.object.put(a, "receipt", receipt);
    try c.write(cast.io, p[2], try c.encode(a, plan), true);
    try remote.pinBlock(null, 0);
    try reconcile(&remote, cat, &plan, try string(receipt, "transactionHash"));
    try c.write(cast.io, p[2], try c.encode(a, plan), true);
    return plan;
}
