const std = @import("std");
const c = @import("common.zig");
const config = @import("config.zig");
const Store = @import("store.zig").Store;
const Vault = @import("vault.zig").Vault;

pub fn key(a: c.A, scope: []const u8, chain: u64, registry: []const u8) ![]const u8 {
    return a.print("operations:{s}:{s}", .{ scope, try @import("store.zig").scopeKey(a, chain, registry) });
}

/// An operation's chain ID does not identify its tenant. Other-chain status is
/// usable only through an explicit profile Registry binding and its own cache.
pub fn load(a: c.A, v: Vault, scope: []const u8, profile: config.Profile, selected_chain: u64, selected_registry: []const u8, chain: u64) !c.Value {
    const registry = if (chain == selected_chain) selected_registry else profile.forChain("instances.", chain) orelse return .null;
    const context = try key(a, scope, chain, registry);
    const bytes = (try v.get(context)) orelse return .null;
    defer std.crypto.secureZero(u8, bytes);
    var snapshot = try c.parse(a, bytes);
    if (snapshot != .object) return error.InvalidVault;
    if (c.field(snapshot, "formatVersion")) |version| {
        if (try c.number(a, version) != 2) return error.InvalidVault;
        try snapshot.object.put(a, "values", try @import("sealed_records.zig").load(v, context));
    }
    try snapshot.object.put(a, "registry", .{ .string = registry });
    return snapshot;
}

test "cross-chain operation snapshots require explicit tenant and KV context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try Store.init(a, ":memory:");
    defer db.close();
    var v: Vault = .{ .a = a, .io = std.testing.io, .key = @splat(7), .db = db };
    defer v.deinit();
    const registry = "0x0000000000000000000000000000000000000001";
    const other = "0x0000000000000000000000000000000000000002";
    try v.put(try key(a, "kv-a", 8453, registry), "{\"block\":{\"number\":123},\"values\":{\"id\":\"active\"}}");
    var profile: config.Profile = .{};
    try std.testing.expectEqual(c.Value.null, try load(a, v, "kv-a", profile, 1, other, 8453));
    try profile.set(a, "instances.base", registry);
    const snapshot = try load(a, v, "kv-a", profile, 1, other, 8453);
    try std.testing.expectEqualStrings("active", try c.string(c.field(c.field(snapshot, "values").?, "id").?));
    try std.testing.expectEqualStrings(registry, try c.string(c.field(snapshot, "registry").?));
    try std.testing.expectEqual(c.Value.null, try load(a, v, "kv-b", profile, 1, other, 8453));
    try profile.set(a, "instances.base", other);
    try std.testing.expectEqual(c.Value.null, try load(a, v, "kv-a", profile, 1, other, 8453));
    // The selected chain uses the explicit command target, never a stale profile.
    try std.testing.expect((try load(a, v, "kv-a", profile, 8453, registry, 8453)) != .null);
    const context = try key(a, "kv-a", 8453, registry);
    try v.put(context, "{\"formatVersion\":2,\"block\":{\"number\":124}}");
    try @import("sealed_records.zig").put(v, context, "new-id", .{ .string = "closed" });
    const paged = try load(a, v, "kv-a", profile, 8453, registry, 8453);
    try std.testing.expectEqualStrings("closed", try c.string(c.field(c.field(paged, "values").?, "new-id").?));
    try std.testing.expect(c.field(c.field(paged, "values").?, "id") == null);
}
