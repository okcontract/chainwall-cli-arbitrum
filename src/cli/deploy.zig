const std = @import("std");
const c = @import("common.zig");
const ms = @import("miniscript");
const abi = @import("abi_codec.zig");
const contracts = @import("contracts.zig");
const Cast = @import("cast.zig").Cast;
const Args = @import("args.zig").Args;

pub const Stage = enum { all, bootstrap, prepare, finalize };
pub const Options = struct {
    factory: []const u8,
    stage: Stage,
    owner: ?[]const u8,
    salt: ?[]const u8,
    flags: u8,
    registry: ?[]const u8,

    pub fn parse(a: c.A, args: *Args, factory_default: ?[]const u8) !Options {
        const factory = args.get("factory") orelse factory_default orelse return error.FactoryRequired;
        try c.address(factory);
        const stage = std.meta.stringToEnum(Stage, args.get("stage") orelse "all") orelse return error.InvalidDeploymentStage;
        const owner = args.get("owner");
        var salt = args.get("salt");
        const flags_raw = args.get("flags");
        const indexing = args.flag("indexing");
        const no_indexing = args.flag("no-indexing");
        const auth_accounts = args.flag("auth-accounts");
        const no_auth_accounts = args.flag("no-auth-accounts");
        const switches = indexing or no_indexing or auth_accounts or no_auth_accounts;
        if ((indexing and no_indexing) or (auth_accounts and no_auth_accounts) or (flags_raw != null and switches)) return error.ConflictingDeploymentOptions;
        const flags = if (flags_raw) |raw| try c.word(raw) else @as(u8, if (no_indexing) 0 else 1) | @as(u8, if (auth_accounts) 2 else 0);
        if (flags > 3) return error.UnsupportedDeploymentFlags;
        const registry = args.get("registry");
        if (stage == .all or stage == .bootstrap) {
            try c.address(owner orelse return error.DeploymentOwnerRequired);
            salt = try c.salt(a, salt orelse return error.DeploymentSaltRequired);
            if (registry != null) return error.ConflictingDeploymentOptions;
        } else {
            try c.address(registry orelse return error.DeploymentRegistryRequired);
            if (owner != null or salt != null or flags_raw != null or switches) return error.ConflictingDeploymentOptions;
        }
        return .{ .factory = factory, .stage = stage, .owner = owner, .salt = salt, .flags = @intCast(flags), .registry = registry };
    }
};

fn call(cast: *Cast, cat: contracts.Catalog, name: []const u8, args: []const []const u8) !c.Value {
    return cast.call(try cat.find("factory", name), args);
}

/// Decode only logs emitted by this factory, using the generated event ABI.
pub fn event(a: c.A, cat: contracts.Catalog, receipt: c.Value, factory: []const u8, name: []const u8) !c.Value {
    const definition = cat.event(name) orelse return error.InvalidArtifact;
    const topic = try c.hex(a, ms.bytecode.hash(try contracts.signature(a, definition, false)));
    const inputs = c.field(definition, "inputs").?.array.items;
    var data_params = std.json.Array.init(a);
    var indexed: usize = 1;
    for (inputs) |param| {
        if (c.field(param, "indexed").?.bool) indexed += 1 else try data_params.append(param);
    }
    var found: ?c.Value = null;
    for ((c.field(receipt, "logs") orelse return error.InvalidTransactionReceipt).array.items) |log| {
        if (!std.ascii.eqlIgnoreCase(try c.string(c.field(log, "address").?), factory)) continue;
        const topics = c.field(log, "topics").?.array.items;
        if (topics.len == 0 or !std.ascii.eqlIgnoreCase(try c.string(topics[0]), topic)) continue;
        if (topics.len != indexed or found != null) return error.InvalidDeploymentEvent;
        const decoded_data = try abi.decode(a, .{ .array = data_params }, try abi.unhex(a, try c.string(c.field(log, "data").?)));
        var values = std.json.Array.init(a);
        var t: usize = 1;
        var d: usize = 0;
        for (inputs) |param| {
            if (c.field(param, "indexed").?.bool) {
                const decoded = try abi.decode(a, try abi.array(a, &.{param}), try abi.unhex(a, try c.string(topics[t])));
                try values.append(decoded.array.items[0]);
                t += 1;
            } else {
                try values.append(decoded_data.array.items[d]);
                d += 1;
            }
        }
        found = try abi.named(a, c.field(definition, "inputs").?, .{ .array = values });
    }
    return found orelse error.DeploymentEventMissing;
}

fn data(a: c.A, cat: contracts.Catalog, stage: Stage, opts: Options, registry: ?[]const u8) !struct { method: contracts.Method, bytes: []const u8 } {
    const name = switch (stage) {
        .bootstrap => "deployInstanceStage1Deterministic",
        .prepare => "deployInstanceStage1Finalize",
        .finalize => "deployInstanceStage2",
        .all => unreachable,
    };
    const method = try cat.find("factory", name);
    const values = if (stage == .bootstrap)
        try abi.array(a, &.{ .{ .string = opts.owner.? }, try abi.uint(a, opts.flags), .{ .string = opts.salt.? } })
    else
        try abi.array(a, &.{.{ .string = registry.? }});
    return .{ .method = method, .bytes = try abi.calldata(a, method.abi, values) };
}

pub fn run(cast: *Cast, opts: Options, dry: bool, quiet: bool, out: ?[]const u8) !c.Value {
    const a = cast.a;
    const cat = try contracts.Catalog.loadDeployment(a);
    const first: Stage = if (opts.stage == .all) .bootstrap else opts.stage;
    if (dry) {
        const tx = try data(a, cat, first, opts, opts.registry);
        return c.parse(a, try c.encode(a, .{ .chainId = cast.chain, .to = opts.factory, .stage = @tagName(first), .function = tx.method.signature, .data = tx.bytes, .nonce = cast.nonce, .remainingStages = if (opts.stage == .all) &[_][]const u8{ "prepare", "finalize" } else &[_][]const u8{} }));
    }
    if (out) |path| try c.write(cast.io, path, try c.encode(a, .{ .state = "prepared", .chainId = cast.chain, .deployment = opts }), false);
    cast.instance = opts.factory;
    cast.checked = false;
    if (cast.block != null) return error.DeploymentRequiresLatestBlock;
    // An existing Registry connection must never select the deployment target.
    try cast.check();
    const self = try c.string((try call(cast, cat, "factorySelf", &.{})).array.items[0]);
    if (!std.ascii.eqlIgnoreCase(self, opts.factory)) return error.NotAnOKFactory;
    const termsMethod = try cat.find("factory", "getTerms");
    const factoryTerms = try abi.namedResult(a, termsMethod.abi, try cast.call(termsMethod, &.{}));
    var registry = opts.registry;
    var deployment_key: []const u8 = undefined;
    if (first == .bootstrap) {
        deployment_key = try c.string((try call(cast, cat, "deriveInstanceDeploymentKey", &.{ opts.salt.?, opts.owner.?, try a.print("{d}", .{opts.flags}) })).array.items[0]);
        const existing = try c.string((try call(cast, cat, "getRegistryByDeploymentKey", &.{deployment_key})).array.items[0]);
        if (try c.word(existing) != 0) {
            cast.diagnostic = try a.print("Deployment already started at {s}. Resume with --stage prepare or --stage finalize --registry {s}.\n", .{ existing, existing });
            return error.DeploymentAlreadyStarted;
        }
    } else {
        deployment_key = try c.string((try call(cast, cat, "getInstanceDeploymentKey", &.{registry.?})).array.items[0]);
        if (try c.word(deployment_key) == 0) return error.RegistryNotFromFactory;
    }
    var receipts = std.json.Array.init(a);
    var instance: c.Value = .null;
    for ([_]Stage{ .bootstrap, .prepare, .finalize }) |stage| {
        if (opts.stage != .all and opts.stage != stage) continue;
        const tx = try data(a, cat, stage, opts, registry);
        if (!quiet) try std.Io.File.stderr().writeStreamingAll(cast.io, try a.print("Deploying: {s}\n", .{@tagName(stage)}));
        const receipt = try cast.send(tx.bytes, null);
        try receipts.append(receipt);
        if (out) |path| try c.write(cast.io, path, try c.encode(a, .{ .state = "mined", .chainId = cast.chain, .factory = opts.factory, .stage = @tagName(stage), .registry = registry, .deploymentKey = deployment_key, .receipts = c.Value{ .array = receipts } }), true);
        if (stage == .bootstrap) {
            const committed = try event(a, cat, receipt, opts.factory, "InstanceDeploymentKeyCommitted");
            if (!std.ascii.eqlIgnoreCase(try c.string(c.field(committed, "deploymentKey").?), deployment_key)) return error.DeploymentMismatch;
            registry = try c.string(c.field(committed, "registry").?);
            try c.address(registry.?);
            const registered = try c.string((try call(cast, cat, "getRegistryByDeploymentKey", &.{deployment_key})).array.items[0]);
            if (!std.ascii.eqlIgnoreCase(registered, registry.?)) return error.DeploymentMismatch;
            if (!quiet) try std.Io.File.stderr().writeStreamingAll(cast.io, try a.print("Registry: {s}\nRecovery: chainwall deploy --factory {s} --stage prepare --registry {s}, then --stage finalize.\n", .{ registry.?, opts.factory, registry.? }));
        } else if (stage == .finalize) {
            const deployed = try event(a, cat, receipt, opts.factory, "InstanceDeployed");
            if (!std.ascii.eqlIgnoreCase(try c.string(c.field(deployed, "registry").?), registry.?)) return error.DeploymentMismatch;
            const method = try cat.find("factory", "getInstance");
            instance = try abi.namedResult(a, method.abi, try cast.call(method, &.{registry.?}));
            // Cross-check the persisted snapshot and the receipt, rather than
            // treating a successful transaction as proof of a complete stack.
            for ([_][]const u8{ "index", "initialOwner", "miniScript", "interact", "safeFactory", "accountFactory", "authAccountFactory" }) |key| {
                const emitted = c.field(deployed, if (c.eq(u8, key, "initialOwner")) "instanceOwner" else key).?;
                if (try c.number(a, emitted) != try c.number(a, c.field(instance, key).?)) return error.DeploymentMismatch;
            }
            if (opts.owner) |owner| if (!std.ascii.eqlIgnoreCase(owner, try c.string(c.field(instance, "initialOwner").?))) return error.DeploymentMismatch;
            try instance.object.put(a, "registry", .{ .string = registry.? });
            try instance.object.put(a, "blockNumber", try abi.uint(a, try c.number(a, c.field(receipt, "blockNumber").?)));
        }
    }
    return c.parse(a, try c.encode(a, .{ .chainId = cast.chain, .factory = opts.factory, .terms = factoryTerms, .registry = registry.?, .deploymentKey = deployment_key, .stage = if (opts.stage == .all) "finalize" else @tagName(opts.stage), .instance = instance, .receipts = c.Value{ .array = receipts } }));
}

test "deployment validates explicit owner, salt, stage, and flags before sending" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var args = try Args.parse(a, &.{ "--factory", "0x1111111111111111111111111111111111111111", "--owner", "0x2222222222222222222222222222222222222222", "--salt", "0x0000000000000000000000000000000000000000000000000000000000000000" });
    const opts = try Options.parse(a, &args, null);
    try args.finish();
    try std.testing.expectEqual(Stage.all, opts.stage);
    try std.testing.expectEqual(@as(u8, 1), opts.flags);
    args = try Args.parse(a, &.{ "--stage", "prepare" });
    try std.testing.expectError(error.DeploymentRegistryRequired, Options.parse(a, &args, opts.factory));
    args = try Args.parse(a, &.{ "--flags", "4" });
    try std.testing.expectError(error.UnsupportedDeploymentFlags, Options.parse(a, &args, opts.factory));
}

test "invalid deployment report destination fails before transport" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    const path = try a.print("{s}/report.json", .{dir});
    try c.write(std.testing.io, path, "existing report", false);
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    // Transport would fail with RpcUrlRequired if reached.
    var cast: Cast = .{ .a = a, .io = std.testing.io, .env = &env, .chain = 42161 };
    const opts: Options = .{ .factory = "0x1111111111111111111111111111111111111111", .stage = .prepare, .registry = "0x2222222222222222222222222222222222222222", .owner = null, .salt = null, .flags = 1 };
    try std.testing.expectError(error.PathAlreadyExists, run(&cast, opts, false, true, path));
    try std.testing.expectEqualStrings("existing report", try c.read(a, std.testing.io, path));
    // A regular file cannot serve as an output directory.
    if (run(&cast, opts, false, true, try a.print("{s}/child.json", .{path}))) |_| {
        return error.ExpectedOutputFailure;
    } else |err| {
        try std.testing.expect(err != error.RpcUrlRequired);
    }
}
