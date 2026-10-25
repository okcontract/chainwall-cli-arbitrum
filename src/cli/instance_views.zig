const std = @import("std");
const ms = @import("miniscript");
const c = @import("common.zig");
const abi = @import("abi_codec.zig");
const config = @import("config.zig");
const contracts = @import("contracts.zig");
const rpc = @import("rpc.zig");
const Cast = @import("cast.zig").Cast;
const Args = @import("args.zig").Args;

fn inspect(cast: *Cast, cat: contracts.Catalog, dir: []const u8, profile_name: []const u8, chain: u64, endpoint: []const u8, registry: []const u8, summary: bool) !c.Value {
    const a = cast.a;
    try @import("rpc_pool.zig").validateSelection(a, cast.io, dir, profile_name, chain, endpoint);
    var remote = try rpc.Rpc.init(a, cast.io, endpoint, chain, registry);
    defer remote.deinit();
    try remote.pinBlock(cast.block, 0);
    const code = try c.string(try remote.one("eth_getCode", try abi.array(a, &.{ .{ .string = registry }, try remote.blockSelector() })));
    var status: []const u8 = "not-installed";
    if (code.len > 2) {
        const identity = try remote.namedAt(registry, try cat.find("registry", "chainwallComponentId"), &.{});
        status = if (try c.number(a, identity) == ms.bytecode.hash("Chainwall.Registry")) "installed" else "different-contract";
    }
    var report = try c.parse(a, try c.encode(a, .{ .chainId = chain, .registry = registry, .status = status, .block = remote.block }));
    if (summary and c.eq(u8, status, "installed")) {
        var fields: std.json.ObjectMap = .empty;
        var errors: std.json.ObjectMap = .empty;
        // Older installations may omit facets. Preserve unavailable fields as
        // null with their errors, never as successful empty/false results.
        for ([_][2][]const u8{
            .{ "paused", "paused" }, .{ "owner", "owner" }, .{ "ownerBootstrapFinalized", "bootstrapFinalized" }, .{ "getSecurityCouncilConfiguration", "securityCouncil" }, .{ "getTermsContext", "terms" }, .{ "instanceHasAcceptedInitialTerms", "acceptance" }, .{ "getPendingActionCount", "pendingActions" }, .{ "getUserCount", "users" }, .{ "getAccountCount", "accounts" }, .{ "getSafeCount", "safes" }, .{ "getPolicyCount", "policies" }, .{ "getInteractionCount", "interactions" }, .{ "getTokenCount", "tokens" },
        }) |pair| {
            const value = remote.namedAt(registry, try cat.find("registry", pair[0]), &.{}) catch |err| blk: {
                if (err == error.OutOfMemory) return err;
                try errors.put(a, pair[1], .{ .string = @errorName(err) });
                break :blk c.Value.null;
            };
            try fields.put(a, pair[1], value);
        }
        try report.object.put(a, "summary", .{ .object = fields });
        try report.object.put(a, "errors", .{ .object = errors });
        try report.object.put(a, "complete", .{ .bool = errors.count() == 0 });
    }
    if (!try remote.canonical(remote.block)) return error.ChainReorganizedRetrySync;
    return report;
}

pub fn run(cast: *Cast, cat: contracts.Catalog, profile: config.Profile, dir: []const u8, profile_name: []const u8, args: *Args, p: []const []const u8) !c.Value {
    const a = cast.a;
    const summary = c.eq(u8, p[0], "status");
    if ((summary and p.len != 1) or (!summary and (p.len < 2 or p.len > 3 or !c.eq(u8, p[1], "discover")))) return error.WrongArgumentCount;
    const all = args.flag("all-chains") or !summary;
    const names = args.get("chains");
    const out = args.get("out");
    try args.finish();
    if ((all or names != null) and cast.block != null) return error.CrossChainBlockNotApplicable;
    const explicit_registry = if (p.len == 3) p[2] else null;
    var chains: std.AutoArrayHashMapUnmanaged(u64, void) = .empty;
    if (names) |text| {
        var parts = std.mem.splitScalar(u8, text, ',');
        while (parts.next()) |name| try chains.put(a, try config.chainId(c.trim(name)), {});
    } else {
        try chains.put(a, cast.chain, {});
        if (all) for (profile.values.keys()) |name| {
            if (std.mem.startsWith(u8, name, "rpc.")) try chains.put(a, try config.chainId(name[4..]), {});
            if (std.mem.startsWith(u8, name, "instances.")) try chains.put(a, try config.chainId(name[10..]), {});
        };
    }
    var reports = std.json.Array.init(a);
    var installed: usize = 0;
    var unavailable: usize = 0;
    for (chains.keys()) |chain| {
        const registry = explicit_registry orelse if (chain == cast.chain) cast.instance else profile.forChain("instances.", chain) orelse cast.instance;
        try c.address(registry);
        const endpoint = if (chain == cast.chain) cast.rpc else profile.forChain("rpc.", chain) orelse "";
        const report = inspect(cast, cat, dir, profile_name, chain, endpoint, registry, summary) catch |err| blk: {
            if (err == error.OutOfMemory) return err;
            // Do not expose raw RPC diagnostics, which can contain provider keys.
            break :blk try c.parse(a, try c.encode(a, .{ .chainId = chain, .registry = registry, .status = "unavailable", .errorName = @errorName(err) }));
        };
        const status = try c.string(c.field(report, "status").?);
        if (c.eq(u8, status, "installed")) installed += 1;
        if (c.eq(u8, status, "unavailable")) unavailable += 1;
        try reports.append(report);
    }
    const result = try c.parse(a, try c.encode(a, .{ .chains = reports.items, .installed = installed, .unavailable = unavailable }));
    if (out) |path| try c.write(cast.io, path, try c.encode(a, result), false);
    return result;
}
