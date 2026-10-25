const std = @import("std");
const c = @import("common.zig");
const storage = @import("store.zig");
const config = @import("config.zig");
const contracts = @import("contracts.zig");
const factories = @import("factories.zig");
const abi = @import("abi_codec.zig");
const Cast = @import("cast.zig").Cast;
const Client = @import("contract_client.zig").Client;

/// Cached topology supplies candidate addresses only. Callers authenticate the
/// live component and its tenant bindings before sending any transaction.
pub fn resolve(cast: *Cast, dir: []const u8, profile: config.Profile, key: []const u8) ![]const u8 {
    const a = cast.a;
    const db = try storage.Store.open(a, cast.io, dir);
    defer db.close();
    const scope = try storage.scopeKey(a, cast.chain, cast.instance);
    if ((try db.entries(scope, "deployment")).get("instance")) |instance| if (c.field(instance, key)) |value| return c.string(value);
    if (profile.get("configuration_id")) |id| if ((try db.entries("configuration", "snapshots")).get(id)) |snapshot| {
        const chain = c.field(snapshot, "chainId") orelse .null;
        const registry = c.field(c.field(snapshot, "registry") orelse .null, "address") orelse .null;
        if (chain != .null and registry != .null and try c.number(a, chain) == cast.chain and std.ascii.eqlIgnoreCase(try c.string(registry), cast.instance)) {
            const safe_factory = c.field(snapshot, "safeFactory") orelse .null;
            if (c.field(c.field(safe_factory, "instance") orelse .null, key)) |value| if (value != .null) return c.string(value);
            if (c.field(c.field(safe_factory, "snapshot") orelse .null, key)) |value| if (value != .null) return c.string(value);
            if (c.eq(u8, key, "safeFactory")) if (c.field(safe_factory, "resolvedAddress")) |value| if (value != .null) return c.string(value);
        }
    };
    const registry = cast.instance;
    const checked = cast.checked;
    cast.instance = profile.get("factory") orelse try factories.address(a, .okFactory, cast.chain) orelse return error.FactoryAddressRequired;
    cast.checked = false;
    defer {
        cast.instance = registry;
        cast.checked = checked;
    }
    const factory: Client = .{ .cast = cast, .cat = try contracts.Catalog.loadDeployment(a), .group = "factory" };
    const method = try factory.cat.find("factory", "getInstance");
    const instance = try abi.namedResult(a, method.abi, try factory.call("getInstance", &.{.{ .string = registry }}));
    if (!std.ascii.eqlIgnoreCase(try c.string(c.field(instance, "registry") orelse return error.InvalidDeployment), registry)) return error.FactoryRegistryMismatch;
    return c.string(c.field(instance, key) orelse return error.FactoryAddressRequired);
}
