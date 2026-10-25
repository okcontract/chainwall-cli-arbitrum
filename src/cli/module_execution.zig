const std = @import("std");
const c = @import("common.zig");
const abi = @import("abi_codec.zig");
const ms = @import("miniscript");
const contracts = @import("contracts.zig");
const releases = @import("releases.zig");
const rpc = @import("rpc.zig");
const Client = @import("contract_client.zig").Client;
const Cast = @import("cast.zig").Cast;

pub const Target = struct { address: []const u8, entry: releases.Entry };

pub fn bundled(cast: *Cast) bool {
    return if (cast.auth) |opts| opts.bundler != null else false;
}

/// The browser replaces the zero revision/runtime at its canonical signing
/// snapshot and adds the protocol's transient ERC-1271 actor trailer. Keeping this
/// unsigned envelope identical to the app also preserves its UserOp simulation.
pub fn userOperation(client: Client, target: Target, data: []const u8, digest: []const u8) !c.Value {
    const cast = client.cast;
    const profile = cast.auth.?.profile;
    var account_cast = cast.*;
    account_cast.instance = try c.string(c.field(profile, "authAccount").?);
    const account: Client = .{ .cast = &account_cast, .cat = client.cat, .group = "auth-account" };
    return account.transaction("executeUserOpSafeModuleCall", &.{ c.field(profile, "credHash").?, .{ .string = try c.hex(cast.a, 0) }, try abi.uint(cast.a, 0), .{ .string = target.address }, .{ .string = digest }, .{ .string = data } }, null, true);
}

/// A separately verified ERC-1271 actor signature can be relayed by the selected
/// Foundry signer. Module calls cannot use executeProtocolCall's narrower scope.
pub fn sender(cast: *Cast) ![]const u8 {
    var relay = cast.*;
    relay.auth = null;
    return relay.signerAddress();
}

pub fn send(cast: *Cast, data: []const u8) !c.Value {
    if (bundled(cast)) return cast.send(data, null);
    var relay = cast.*;
    relay.auth = null;
    const receipt = try relay.send(data, null);
    cast.nonce = relay.nonce;
    return receipt;
}

/// Discover only factories explicitly authorized by this Registry. Cached
/// topology and arbitrary modules exposing plausible getters are not authority.
pub fn resolve(remote: *rpc.Rpc, client: Client, registry: []const u8, safe: []const u8) !Target {
    const a = remote.a;
    const cat = try contracts.Catalog.load(a);
    const catalog = try contracts.Catalog.loadReleases(a);
    const factory = try releases.find(a, catalog, "safeFactory");
    const module = try releases.find(a, catalog, "okModule");
    if (!(try remote.namedAt(registry, try cat.find("accounts", "isSafeAllowed"), &.{.{ .string = safe }})).bool) return error.AccountBindingsMismatch;
    const actors = try remote.namedAt(registry, try cat.find("capabilities", "getCapabilityActors"), &.{.{ .string = try c.hex(a, ms.bytecode.hash("cap.registry.account.write")) }});
    if (actors != .array or actors.array.items.len > 256) return error.InvalidFactoryBindings;
    var selected: ?[]const u8 = null;
    for (actors.array.items) |actor| {
        const address = try c.string(actor);
        // System capabilities can preauthorize future factory deployments.
        if ((try releases.codeAt(remote, address)).len <= 2) continue;
        const component = remote.namedAt(address, try factory.method("chainwallComponentId"), &.{}) catch |err| switch (err) {
            error.RpcRejectedRequest => continue,
            else => return err,
        };
        if (try c.number(a, component) != ms.bytecode.hash("Chainwall.SafeFactory")) continue;
        if (!(try remote.namedAt(address, try factory.method("isSafe"), &.{.{ .string = safe }})).bool) continue;
        if (!releases.same(try remote.namedAt(address, try factory.method("INTERACT_CONTRACT"), &.{}), .{ .string = client.cast.instance })) return error.AccountBindingsMismatch;
        _ = try remote.namedAt(address, try factory.method("validateManagedSafe"), &.{.{ .string = safe }});
        var candidate = try remote.namedAt(address, try factory.method("MODULE_CONTRACT"), &.{});
        if ((try remote.namedAt(address, try factory.method("INDEXING_ENABLED"), &.{})).bool) {
            const index = try remote.namedAt(address, try factory.method("safeDeploymentId"), &.{.{ .string = safe }});
            if (c.field(index, "exists").?.bool) {
                const record = try remote.namedAt(address, try factory.method("safeDeploymentAt"), &.{c.field(index, "id").?});
                const value = c.field(record, "record").?;
                if (!c.field(record, "isAlive").?.bool or !releases.same(c.field(value, "safe").?, .{ .string = safe })) return error.AccountBindingsMismatch;
                if (try c.number(a, c.field(value, "module").?) != 0) candidate = c.field(value, "module").?;
            }
        }
        const target = try c.string(candidate);
        try c.address(target);
        if (!(try remote.namedAt(safe, try client.cat.find("safe", "isModuleEnabled"), &.{candidate})).bool) return error.SafeModuleDisabled;
        if (try c.number(a, try remote.namedAt(target, try module.method("chainwallComponentId"), &.{})) != ms.bytecode.hash("Chainwall.OKModule") or !releases.same(try remote.namedAt(target, try module.method("INTERACTION"), &.{}), .{ .string = client.cast.instance })) return error.AccountBindingsMismatch;
        _ = try remote.namedAt(target, try module.method("validateSafeExtensions"), &.{.{ .string = safe }});
        if (selected) |previous| if (!std.ascii.eqlIgnoreCase(previous, target)) return error.AmbiguousSafeModule;
        selected = target;
    }
    return .{ .address = selected orelse return error.SafeModuleUnavailable, .entry = module };
}

pub fn trailer(a: c.A, data: []const u8, actor: []const u8, signature: []const u8) ![]const u8 {
    try c.address(actor);
    const bytes = try abi.unhex(a, signature);
    if (bytes.len == 0 or bytes.len > 16384) return error.InvalidSignature;
    return a.print("{s}{s}{s}{x:0>8}{x:0>64}", .{ data, signature[2..], actor[2..], @as(u32, @intCast(bytes.len)), ms.bytecode.hash("ChainwallSignedActorTrailerV2") });
}

pub fn verify(target: Target, a: c.A, receipt: c.Value, safe: []const u8, interaction: c.Value, operation: ?c.Value) !void {
    const event = try @import("deploy.zig").event(a, target.entry.cat, receipt, target.address, if (operation == null) "ModuleDirectExecuted" else "ModuleInteractionExecuted");
    if (!releases.same(c.field(event, "safe").?, .{ .string = safe }) or !releases.same(c.field(event, "interactionId").?, interaction)) return error.OperationMismatch;
    if (operation) |id| if (try c.number(a, c.field(event, "operationId").?) != try c.number(a, id)) return error.OperationMismatch;
}
