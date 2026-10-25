const std = @import("std");
const c = @import("common.zig");
const abi = @import("abi_codec.zig");
const rpc = @import("rpc.zig");
const releases = @import("releases.zig");
const contracts = @import("contracts.zig");
const config = @import("config.zig");
const Cast = @import("cast.zig").Cast;
const Args = @import("args.zig").Args;
const Client = @import("contract_client.zig").Client;

fn connection(cast: *Cast, address: []const u8) !rpc.Rpc {
    return rpc.Rpc.init(cast.a, cast.io, cast.rpc, cast.chain, address);
}

fn canonical(remote: *rpc.Rpc) !void {
    if (!try remote.canonical(remote.block)) return error.ChainReorganizedRetrySync;
}

fn target(cast: *Cast, dir: []const u8, profile: config.Profile, entry: releases.Entry, explicit: ?[]const u8) ![]const u8 {
    if (explicit) |address| {
        try c.address(address);
        return address;
    }
    if (c.eq(u8, entry.key, "registry")) return cast.instance;
    if (c.eq(u8, entry.key, "okAccount") or c.eq(u8, entry.key, "authAccount")) return error.UpgradeTargetRequired;
    if (c.eq(u8, entry.key, "interact")) if (profile.forChain("interacts.", cast.chain) orelse profile.get("interact")) |address| return address;
    if (c.eq(u8, entry.key, "okGuard") or c.eq(u8, entry.key, "okModule")) {
        const factory = try @import("topology.zig").resolve(cast, dir, profile, "safeFactory");
        var remote = try connection(cast, factory);
        defer remote.deinit();
        try remote.pin(cast.block, 0);
        const address = try c.string(try releases.read(&remote, try releases.find(cast.a, entry.cat, "safeFactory"), factory, if (c.eq(u8, entry.key, "okGuard")) "GUARD_CONTRACT" else "MODULE_CONTRACT", &.{}));
        try canonical(&remote);
        return address;
    }
    return @import("topology.zig").resolve(cast, dir, profile, entry.key);
}

fn inspect(remote: *rpc.Rpc, entry: releases.Entry, address: []const u8) !c.Value {
    const a = remote.a;
    // The stable AuthAccount dispatcher implements these shared selectors;
    // its delegated implementation deliberately does not expose UUPS methods.
    const common = try releases.find(a, entry.cat, "registry");
    const component = try releases.read(remote, entry, address, "chainwallComponentId", &.{});
    if (!releases.same(component, c.field(entry.manifest, "componentId").?)) return error.UpgradeComponentMismatch;
    const implementation = try releases.read(remote, common, address, "chainwallImplementation", &.{});
    const reported_hash = try releases.read(remote, common, address, "chainwallImplementationCodehash", &.{});
    const slot = try remote.one("eth_getStorageAt", try abi.array(a, &.{ .{ .string = address }, c.field(entry.cat.root, "implementationSlot").?, try remote.blockSelector() }));
    if (try c.number(a, implementation) != try c.number(a, slot)) return error.UpgradeImplementationSlotMismatch;
    const candidate = try releases.verify(remote, entry, try c.string(implementation));
    const codehash = c.field(c.field(candidate, "runtime").?, "actualCodehash").?;
    if (!releases.same(codehash, reported_hash)) return error.UpgradeImplementationCodehashMismatch;
    const bindings = try releases.read(remote, entry, address, "chainwallSecurityBindingsHash", &.{});
    return c.parse(a, try c.encode(a, .{ .release = entry.key, .target = address, .implementation = implementation, .codehash = codehash, .securityBindingsHash = bindings, .verification = candidate, .block = remote.block }));
}

const Transition = struct {
    kind: []const u8,
    release: []const u8,
    target_field: []const u8 = "target",
    candidate_field: []const u8 = "newImplementation",
    current_reader: ?[]const u8 = null,
    host: ?[]const u8 = null,
};
const transitions = [_]Transition{
    .{ .kind = "replaceEngine", .release = "miniScriptEngine", .candidate_field = "newEngine", .current_reader = "chainwallEngine" },
    .{ .kind = "setAccountImplementation", .release = "okAccount", .target_field = "accountFactory", .current_reader = "chainwallAccountImplementation", .host = "accountFactory" },
    .{ .kind = "setAuthAccountImplementation", .release = "authAccount", .target_field = "authAccountFactory", .current_reader = "chainwallAuthAccountImplementation", .host = "authAccountFactory" },
    .{ .kind = "setSafeProxyFactory", .release = "safeProxyFactory", .target_field = "safeFactory", .candidate_field = "newProxyFactory", .current_reader = "PROXY_FACTORY", .host = "safeFactory" },
    .{ .kind = "setSafeSingleton", .release = "safeSingleton", .target_field = "safeFactory", .candidate_field = "newSingleton", .current_reader = "SAFE_SINGLETON", .host = "safeFactory" },
    .{ .kind = "replaceSafeSingletonMigrator", .release = "safeSingletonMigrator", .target_field = "safeFactory", .candidate_field = "newMigrator", .current_reader = "SAFE_SINGLETON_MIGRATOR", .host = "safeFactory" },
    .{ .kind = "replaceSafeConfigurator", .release = "safeConfigurator", .target_field = "safeFactory", .candidate_field = "newConfigurator", .current_reader = "CONFIGURATOR", .host = "safeFactory" },
    .{ .kind = "migrateSafeSingleton", .release = "safeSingleton", .target_field = "safeFactory", .candidate_field = "newSingleton", .current_reader = "", .host = "safeFactory" },
};

fn componentAction(a: c.A, entry: releases.Entry) ![]const u8 {
    if (!c.eq(u8, try c.string(c.field(entry.manifest, "role").?), "component-implementation")) return error.ReleaseRequiresExplicitAction;
    const kind = try std.mem.concat(a, u8, &.{ "upgrade", entry.key });
    kind[7] = std.ascii.toUpper(kind[7]);
    return kind;
}

fn transition(a: c.A, cat: contracts.Catalog, kind: []const u8) !Transition {
    for (transitions) |item| if (c.eq(u8, item.kind, kind)) return item;
    for (c.field(cat.root, "contracts").?.array.items) |item| {
        const manifest = c.field(item, "manifest").?;
        if (!c.eq(u8, try c.string(c.field(manifest, "role").?), "component-implementation")) continue;
        const key = try c.string(c.field(manifest, "key").?);
        const entry = try releases.find(a, cat, key);
        if (c.eq(u8, kind, try componentAction(a, entry))) return .{ .kind = kind, .release = key };
    }
    return error.UnknownUpgradeAction;
}

fn required(action: c.Value, key: []const u8) !c.Value {
    return c.field(action, key) orelse error.InvalidUpgradeAction;
}

fn actionValues(a: c.A, registry: contracts.Catalog, change: Transition, action: c.Value) ![]const c.Value {
    const method = try registry.find("registry", change.kind);
    const inputs = c.field(method.abi, "inputs").?.array.items;
    const values = try a.alloc(c.Value, inputs.len);
    for (inputs, values) |param, *value| {
        const name = try c.string(c.field(param, "name").?);
        const key = if (c.eq(u8, name, "factory")) change.target_field else name;
        value.* = c.field(action, key) orelse if (c.eq(u8, key, "data")) c.Value{ .string = "0x" } else return error.InvalidUpgradeAction;
        const kind = try c.string(c.field(param, "type").?);
        if (c.eq(u8, kind, "address")) try c.address(try c.string(value.*));
        if (c.eq(u8, kind, "bytes")) {
            const bytes = try abi.unhex(a, try c.string(value.*));
            if (c.eq(u8, change.kind, "upgradeRegistry") and bytes.len != 0) return error.RegistryUpgradeDataMustBeEmpty;
        }
    }
    return values;
}

fn hostEntry(remote: *rpc.Rpc, cat: contracts.Catalog, address: []const u8) !releases.Entry {
    const id = try releases.read(remote, try releases.find(remote.a, cat, "registry"), address, "chainwallComponentId", &.{});
    for (c.field(cat.root, "contracts").?.array.items) |item| {
        const manifest = c.field(item, "manifest").?;
        if (releases.same(id, c.field(manifest, "componentId").?)) return releases.find(remote.a, cat, try c.string(c.field(manifest, "key").?));
    }
    return error.UpgradeComponentMismatch;
}

fn tenant(remote: *rpc.Rpc, entry: releases.Entry, address: []const u8, registry: []const u8) !void {
    if (c.eq(u8, entry.key, "registry")) {
        if (!std.ascii.eqlIgnoreCase(address, registry)) return error.UpgradeRegistryMismatch;
        return;
    }
    const through_interact: ?[]const u8 = if (c.eq(u8, entry.key, "accountFactory")) "interact" else if (c.eq(u8, entry.key, "safeFactory")) "INTERACT_CONTRACT" else if (c.eq(u8, entry.key, "okGuard") or c.eq(u8, entry.key, "okModule")) "INTERACTION" else null;
    const bound = if (through_interact) |name| blk: {
        const interact = try c.string(try releases.read(remote, entry, address, name, &.{}));
        break :blk try releases.read(remote, try releases.find(remote.a, entry.cat, "interact"), interact, "registry", &.{});
    } else try releases.read(remote, entry, address, if (@import("schema.zig").contains("miniScript interact authAccount", entry.key)) "registry" else "REGISTRY", &.{});
    if (!std.ascii.eqlIgnoreCase(try c.string(bound), registry)) return error.UpgradeRegistryMismatch;
}

fn currentPointer(remote: *rpc.Rpc, entry: releases.Entry, address: []const u8, change: Transition, action: c.Value) !c.Value {
    if (c.eq(u8, change.kind, "migrateSafeSingleton")) {
        const safe = try c.string(try required(action, "safe"));
        try c.address(safe);
        const slot = try remote.one("eth_getStorageAt", try abi.array(remote.a, &.{ .{ .string = safe }, .{ .string = "0x0" }, try remote.blockSelector() }));
        const value = try c.number(remote.a, slot);
        if (value == 0 or value > std.math.maxInt(u160)) return error.InvalidSafeSingleton;
        return .{ .string = try remote.a.print("0x{x:0>40}", .{value}) };
    }
    return releases.read(remote, if (change.current_reader == null) try releases.find(remote.a, entry.cat, "registry") else entry, address, change.current_reader orelse "chainwallImplementation", &.{});
}

fn status(client: Client, id: c.Value) !c.Value {
    const a = client.cast.a;
    const hash = try client.first("getActionUpgradeCodeHash", &.{id});
    const method = try client.cat.find("registry", "getAction");
    const view = try abi.namedResult(a, method.abi, try client.call("getAction", &.{id}));
    const available = try c.number(a, hash) != 0;
    if (!available and try c.number(a, c.field(view, "status").?) < 4) return error.NotAnUpgradeAction;
    // Terminal actions discard their payload. Preserve that distinction instead
    // of inventing a candidate hash or rejecting a successfully executed action.
    return c.parse(a, try c.encode(a, .{ .id = id, .candidateCodehash = if (available) hash else c.Value.null, .action = view, .semantics = try client.call("getActionSemantics", &.{id}) }));
}

fn simulation(cast: *Cast, remote: *rpc.Rpc, transaction: c.Value) !c.Value {
    const a = cast.a;
    if (cast.from == null and cast.account == null and cast.keystore == null and cast.auth == null) return .null;
    const from = try cast.signerAddress();
    const tx = try c.parse(a, try c.encode(a, .{ .from = from, .to = cast.instance, .data = c.field(transaction, "data").?, .value = "0x0" }));
    const result = remote.one("eth_call", try abi.array(a, &.{ tx, try remote.blockSelector() })) catch |err| {
        if (err != error.RpcRejectedRequest) return err;
        const failure = remote.last_error orelse return err;
        return c.parse(a, try c.encode(a, .{ .ok = false, .from = from, .rpcError = failure }));
    };
    return c.parse(a, try c.encode(a, .{ .ok = true, .from = from, .result = result }));
}

fn simulatedOk(result: c.Value) c.Value {
    return if (result == .null) .null else c.field(result, "ok").?;
}

fn govern(cast: *Cast, cat: contracts.Catalog, registry: contracts.Catalog, action: c.Value, out: ?[]const u8, dry: bool) !c.Value {
    const a = cast.a;
    const change = try transition(a, cat, try c.string(try required(action, "kind")));
    const values = try actionValues(a, registry, change, action);
    const address = if (c.eq(u8, change.kind, "upgradeRegistry")) cast.instance else try c.string(try required(action, change.target_field));
    const candidate = try c.string(try required(action, change.candidate_field));
    const entry = try releases.find(a, cat, change.release);
    var remote = try connection(cast, cast.instance);
    defer remote.deinit();
    try remote.pin(cast.block, 0);
    const host = if (change.current_reader == null) entry else try hostEntry(&remote, cat, address);
    if (change.host) |key| if (!c.eq(u8, key, host.key)) return error.UpgradeComponentMismatch;
    if (c.eq(u8, change.kind, "replaceEngine") and !@import("schema.zig").contains("miniScript accountFactory okAccount", host.key)) return error.UpgradeComponentMismatch;
    try tenant(&remote, host, address, cast.instance);
    const before = try inspect(&remote, host, address);
    const previous = try currentPointer(&remote, host, address, change, action);
    if (std.ascii.eqlIgnoreCase(try c.string(previous), candidate)) return error.UpgradeAlreadyCurrent;
    const verified = try releases.verify(&remote, entry, candidate);
    const client: Client = .{ .cast = cast, .cat = registry, .group = "registry" };
    var plan = try c.parse(a, try c.encode(a, .{ .state = "prepared", .action = action, .target = address, .previous = previous, .before = before, .compatible = c.field(verified, "compatible").?, .verification = verified, .transaction = try client.transaction(change.kind, values, null, true) }));
    const simulated = if (c.field(verified, "compatible").?.bool) try simulation(cast, &remote, c.field(plan, "transaction").?) else c.Value.null;
    try plan.object.put(a, "simulation", simulated);
    try plan.object.put(a, "ready", simulatedOk(simulated));
    try canonical(&remote);
    if (out) |file| try c.write(cast.io, file, try c.encode(a, plan), false);
    if (!c.field(verified, "compatible").?.bool or dry or (simulated != .null and !c.field(simulated, "ok").?.bool)) return plan;
    const receipt = try client.transaction(change.kind, values, null, false);
    try std.Io.File.stderr().writeStreamingAll(cast.io, try a.print("Upgrade transaction: {s}\n", .{try c.string(c.field(receipt, "transactionHash") orelse return error.InvalidTransactionReceipt)}));
    try plan.object.put(a, "receipt", receipt);
    try plan.object.put(a, "state", .{ .string = "mined" });
    if (out) |file| try c.write(cast.io, file, try c.encode(a, plan), true);
    const outcome = try @import("receipts.zig").classify(a, registry, receipt, cast.instance, try registry.find("registry", change.kind), &.{});
    try plan.object.put(a, "outcome", try c.parse(a, try c.encode(a, outcome)));
    if (outcome.queuedActions.len > 0) {
        var actions = std.json.Array.init(a);
        for (outcome.queuedActions) |id| {
            const view = try status(client, .{ .string = id });
            if (!releases.same(c.field(view, "candidateCodehash").?, c.field(c.field(verified, "runtime").?, "actualCodehash").?)) return error.QueuedUpgradeCodehashMismatch;
            try actions.append(view);
        }
        try plan.object.put(a, "actions", .{ .array = actions });
    } else {
        try remote.pin(null, 0);
        const installed = try currentPointer(&remote, host, address, change, action);
        if (!std.ascii.eqlIgnoreCase(try c.string(installed), candidate)) return error.UpgradePostconditionFailed;
        const after = try inspect(&remote, host, address);
        if (change.current_reader == null and !releases.same(c.field(before, "securityBindingsHash").?, c.field(after, "securityBindingsHash").?)) return error.UpgradeBindingsChanged;
        try canonical(&remote);
        try plan.object.put(a, "after", after);
    }
    try plan.object.put(a, "state", .{ .string = outcome.status });
    if (out) |file| try c.write(cast.io, file, try c.encode(a, plan), true);
    return plan;
}

pub fn run(cast: *Cast, registry: contracts.Catalog, profile: config.Profile, dir: []const u8, args: *Args, p: []const []const u8, dry: bool) !c.Value {
    if (p.len < 2) return error.CommandRequired;
    const a = cast.a;
    const cat = try contracts.Catalog.loadReleases(a);
    if (c.eq(u8, p[1], "releases")) {
        if (p.len != 2) return error.WrongArgumentCount;
        try args.finish();
        var values = std.json.Array.init(a);
        for (c.field(cat.root, "contracts").?.array.items) |item| {
            const manifest = c.field(item, "manifest").?;
            const entry = try releases.find(a, cat, try c.string(c.field(manifest, "key").?));
            try values.append(try c.parse(a, try c.encode(a, .{ .release = entry.key, .label = c.field(manifest, "label").?, .role = c.field(manifest, "role").?, .componentId = c.field(manifest, "componentId").?, .protocolVersion = c.field(manifest, "protocolVersion").?, .constructor = try releases.constructor(entry, a) })));
        }
        return .{ .array = values };
    }
    if (p.len < 3) return error.ReleaseRequired;
    const out = args.get("out");
    if (@import("schema.zig").contains("status approve execute cancel", p[1])) {
        if (p.len != 3) return error.WrongArgumentCount;
        try args.finish();
        const id: c.Value = .{ .string = try c.id(a, p[2]) };
        const client: Client = .{ .cast = cast, .cat = registry, .group = "registry" };
        const before = try status(client, id);
        if (c.eq(u8, p[1], "status")) return before;
        if (try c.number(a, c.field(c.field(before, "action").?, "status").?) >= 4) return error.UpgradeActionAlreadyTerminal;
        const method = if (c.eq(u8, p[1], "approve")) "approveAction" else if (c.eq(u8, p[1], "execute")) "executeAction" else "cancelAction";
        var remote = try connection(cast, cast.instance);
        defer remote.deinit();
        try remote.pin(cast.block, 0);
        const transaction = try client.transaction(method, &.{id}, null, true);
        const simulated = try simulation(cast, &remote, transaction);
        const prepared = try c.parse(a, try c.encode(a, .{ .before = before, .transaction = transaction, .simulation = simulated, .ready = simulatedOk(simulated) }));
        try canonical(&remote);
        if (out) |file| try c.write(cast.io, file, try c.encode(a, prepared), false);
        if (dry or (simulated != .null and !c.field(simulated, "ok").?.bool)) return prepared;
        const receipt = try client.transaction(method, &.{id}, null, dry);
        if (out) |file| try c.write(cast.io, file, try c.encode(a, .{ .receipt = receipt }), true);
        const result = try c.parse(a, try c.encode(a, .{ .before = before, .transaction = receipt, .after = if (dry) before else try status(client, id) }));
        if (out) |file| try c.write(cast.io, file, try c.encode(a, result), true);
        return result;
    }
    if (c.eq(u8, p[1], "release")) {
        if (p.len != 3) return error.WrongArgumentCount;
        try args.finish();
        return govern(cast, cat, registry, try @import("json_schema.zig").read(a, cast.io, "upgrade-action", p[2]), out, dry);
    }
    const entry = try releases.find(a, cat, p[2]);
    if (c.eq(u8, p[1], "propose")) {
        if (p.len != 4) return error.WrongArgumentCount;
        const explicit = args.get("target");
        const data_file = args.get("data-file");
        try args.finish();
        const address = try target(cast, dir, profile, entry, explicit);
        if (c.eq(u8, entry.key, "registry") and !std.ascii.eqlIgnoreCase(address, cast.instance)) return error.UpgradeRegistryMismatch;
        const action = try c.parse(a, try c.encode(a, .{ .kind = try componentAction(a, entry), .target = address, .newImplementation = p[3], .data = if (data_file) |file| c.trim(try c.read(a, cast.io, file)) else "0x" }));
        return govern(cast, cat, registry, action, out, dry);
    }
    if (c.eq(u8, p[1], "deploy")) {
        if (p.len != 3) return error.WrongArgumentCount;
        const constructor_file = args.get("constructor-file");
        try args.finish();
        var validator = try @import("json_schema.zig").Validator.init(a);
        const constructor_schema = try @import("json_schema.zig").abiArguments(a, try releases.constructor(entry, a), false);
        const data = try releases.deploymentData(entry, a, if (constructor_file) |file| try @import("json_schema.zig").readRule(&validator, cast.io, constructor_schema, "constructor-arguments", file) else null);
        const preview = try c.parse(a, try c.encode(a, .{ .release = entry.key, .chainId = cast.chain, .data = data, .nonce = cast.nonce, .state = "prepared" }));
        if (out) |file| try c.write(cast.io, file, try c.encode(a, preview), false);
        if (dry) return preview;
        const receipt = try cast.create(data, null);
        const address = try c.string(c.field(receipt, "contractAddress") orelse return error.InvalidTransactionReceipt);
        try c.address(address);
        try std.Io.File.stderr().writeStreamingAll(cast.io, try a.print("Release deployed: {s}\n", .{address}));
        // Preserve the receipt before further RPC reads, so verification can be
        // retried without deploying an unnecessary second implementation.
        if (out) |file| try c.write(cast.io, file, try c.encode(a, .{ .release = entry.key, .address = address, .state = "mined", .receipt = receipt }), true);
        var remote = try connection(cast, address);
        defer remote.deinit();
        try remote.pin(cast.block, 0);
        const verified = try releases.verify(&remote, entry, address);
        try canonical(&remote);
        const result = try c.parse(a, try c.encode(a, .{ .release = entry.key, .address = address, .compatible = c.field(verified, "compatible").?, .verification = verified, .receipt = receipt }));
        if (out) |file| try c.write(cast.io, file, try c.encode(a, result), true);
        return result;
    }
    if (c.eq(u8, p[1], "verify") or c.eq(u8, p[1], "inspect")) {
        const verifying = c.eq(u8, p[1], "verify");
        const explicit = if (!verifying) args.get("target") else null;
        try args.finish();
        if (p.len != (if (verifying) @as(usize, 4) else 3)) return error.WrongArgumentCount;
        const address = if (verifying) p[3] else try target(cast, dir, profile, entry, explicit);
        var remote = try connection(cast, address);
        defer remote.deinit();
        try remote.pin(cast.block, 0);
        const result = if (verifying) try releases.verify(&remote, entry, address) else try inspect(&remote, entry, address);
        try canonical(&remote);
        if (out) |file| try c.write(cast.io, file, try c.encode(a, result), false);
        return result;
    }
    return error.UnknownCommand;
}

test "all upgrade and release action shapes match reference encodings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cat = try contracts.Catalog.loadReleases(a);
    const registry = try contracts.Catalog.load(a);
    const fixtures = try c.parse(a, @embedFile("artifacts/upgrade-fixtures.json"));
    try std.testing.expectEqual(@as(usize, 18), fixtures.array.items.len);
    for (fixtures.array.items) |fixture| {
        const action = c.field(fixture, "action").?;
        const change = try transition(a, cat, try c.string(c.field(action, "kind").?));
        const values = try actionValues(a, registry, change, action);
        const encoded = try abi.calldata(a, (try registry.find("registry", change.kind)).abi, try abi.array(a, values));
        try std.testing.expectEqualStrings(try c.string(c.field(fixture, "data").?), encoded);
    }
}
