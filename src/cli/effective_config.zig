//! Shared startup resolution and redacted explanations of effective settings.
const std = @import("std");
const c = @import("common.zig");
const config = @import("config.zig");
const Args = @import("args.zig").Args;
const peek = @import("json_inputs.zig").peek;

pub const Entry = struct {
    key: []const u8,
    value: ?[]const u8,
    source: []const u8,
    profileKey: ?[]const u8 = null,
};
const Candidate = struct { value: ?[]const u8, source: []const u8, profile_key: ?[]const u8 = null };
fn choose(key: []const u8, candidates: []const Candidate) Entry {
    for (candidates) |candidate| if (candidate.value) |value| return .{ .key = key, .value = value, .source = candidate.source, .profileKey = candidate.profile_key };
    return .{ .key = key, .value = null, .source = "unset" };
}
fn flag(args: Args, name: []const u8) Candidate {
    return .{ .value = peek(args, name), .source = name };
}
fn environment(env: *const std.process.Environ.Map, name: []const u8) Candidate {
    return .{ .value = env.get(name), .source = name };
}
fn profile(p: config.Profile, name: []const u8) Candidate {
    return .{ .value = p.get(name), .source = "profile", .profile_key = name };
}
fn scoped(p: config.Profile, prefix: []const u8, chain: u64) Candidate {
    for (p.values.keys(), p.values.values()) |key, value| {
        if (std.mem.startsWith(u8, key, prefix) and (config.chainId(key[prefix.len..]) catch continue) == chain) return .{ .value = value, .source = "profile", .profile_key = key };
    }
    return .{ .value = null, .source = "unset" };
}
pub fn resolve(args: Args, env: *const std.process.Environ.Map, p: config.Profile) ![8]Entry {
    const chain = choose("chain", &.{ flag(args, "chain"), environment(env, "CHAINWALL_CHAIN"), profile(p, "chain"), .{ .value = "ethereum", .source = "default" } });
    const id = try config.chainId(chain.value.?);
    const same_chain = id == try config.chainId(p.get("chain") orelse "ethereum");
    const unlocked = peek(args, "unlocked") != null;
    const account = choose("account", &.{ flag(args, "account"), if (unlocked or peek(args, "keystore") != null) .{ .value = null, .source = "unset" } else environment(env, "CHAINWALL_ACCOUNT"), if (unlocked or peek(args, "keystore") != null) .{ .value = null, .source = "unset" } else profile(p, "account") });
    return .{
        chain,
        choose("rpc_url", &.{ flag(args, "rpc-url"), environment(env, "CHAINWALL_RPC_URL"), scoped(p, "rpc.", id), if (same_chain) profile(p, "rpc_url") else .{ .value = null, .source = "different-profile-chain" } }),
        choose("instance", &.{ flag(args, "instance"), environment(env, "CHAINWALL_INSTANCE"), scoped(p, "instances.", id), profile(p, "instance") }),
        account,
        choose("keystore", &.{ flag(args, "keystore"), if (unlocked or account.value != null) .{ .value = null, .source = "unset" } else profile(p, "keystore") }),
        choose("password_file", &.{ flag(args, "password-file"), profile(p, "password_file") }),
        choose("editor", &.{ flag(args, "editor"), environment(env, "CHAINWALL_EDITOR"), profile(p, "editor"), environment(env, "VISUAL"), environment(env, "EDITOR"), .{ .value = "vi", .source = "default" } }),
        choose("interact", &.{ scoped(p, "interacts.", id), profile(p, "interact") }),
    };
}
pub fn get(entries: []const Entry, key: []const u8) ?[]const u8 {
    for (entries) |entry| if (c.eq(u8, entry.key, key)) return entry.value;
    return null;
}
pub fn report(a: c.A, args: Args, env: *const std.process.Environ.Map, p: config.Profile, selected: ?[]const u8) !c.Value {
    var values = std.json.Array.init(a);
    const entries = try resolve(args, env, p);
    var found = selected == null;
    for (entries) |entry| {
        if (selected) |key| if (!c.eq(u8, key, entry.key)) continue;
        found = true;
        var shadowed = std.json.Array.init(a);
        const prefix: ?[]const u8 = if (c.eq(u8, entry.key, "rpc_url")) "rpc." else if (c.eq(u8, entry.key, "instance")) "instances." else if (c.eq(u8, entry.key, "interact")) "interacts." else null;
        for (p.values.keys()) |key| {
            const relevant = c.eq(u8, key, entry.key) or if (prefix) |pre| std.mem.startsWith(u8, key, pre) and (config.chainId(key[pre.len..]) catch 0) == try config.chainId(entries[0].value.?) else false;
            if (relevant and (entry.profileKey == null or !c.eq(u8, key, entry.profileKey.?))) try shadowed.append(.{ .string = key });
        }
        const redacted = c.eq(u8, entry.key, "rpc_url");
        try values.append(try c.parse(a, try c.encode(a, .{ .key = entry.key, .value = if (entry.value) |v| c.Value{ .string = if (redacted) "<configured>" else v } else c.Value.null, .source = entry.source, .profileKey = entry.profileKey, .shadowedProfileKeys = shadowed.items })));
    }
    // Keep workflow-specific stored settings distinct from startup resolution.
    for (p.values.keys(), p.values.values()) |key, value| {
        var common = false;
        for (entries) |entry| if (c.eq(u8, key, entry.key)) {
            common = true;
            break;
        };
        if (common) continue;
        if (selected) |s| if (!c.eq(u8, key, s)) continue;
        found = true;
        const secret = c.eq(u8, key, "etherscan_api_key") or c.eq(u8, key, "kv_rpc_url") or std.mem.startsWith(u8, key, "rpc.");
        try values.append(try c.parse(a, try c.encode(a, .{ .key = key, .value = if (secret) "<configured>" else value, .source = "profile", .profileKey = key, .scope = "stored-workflow-setting" })));
    }
    if (!found) return error.ConfigKeyNotSet;
    return .{ .array = values };
}

test "effective resolution reports chain and environment shadowing without exposing RPC credentials" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    try env.put("CHAINWALL_RPC_URL", "https://secret.example/key");
    const args = try Args.parse(a, &.{ "config", "explain", "--chain", "arbitrum" });
    const p = try config.Profile.parse(a, "chain='arbitrum'\nrpc_url='generic'\n[rpc]\narbitrum='scoped'\n");
    const entries = try resolve(args, &env, p);
    try std.testing.expectEqualStrings("https://secret.example/key", get(&entries, "rpc_url").?);
    const result = try report(a, args, &env, p, "rpc_url");
    const item = result.array.items[0];
    try std.testing.expectEqualStrings("CHAINWALL_RPC_URL", try c.string(c.field(item, "source").?));
    try std.testing.expectEqual(@as(usize, 2), c.field(item, "shadowedProfileKeys").?.array.items.len);
    try std.testing.expect(std.mem.indexOf(u8, try c.encode(a, result), "secret.example") == null);
    env = std.process.Environ.Map.init(a);
    try std.testing.expectEqualStrings("scoped", get(&(try resolve(args, &env, p)), "rpc_url").?);
    const other = try Args.parse(a, &.{ "config", "explain", "--chain", "base" });
    try std.testing.expect(get(&(try resolve(other, &env, p)), "rpc_url") == null);
}
