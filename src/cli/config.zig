const std = @import("std");
const c = @import("common.zig");

/// Profiles use scalar TOML keys and the [rpc] and [instances] string tables.
/// Parsing is strict so misspelled settings never silently select another signer.
pub const Profile = struct {
    values: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    original: std.StringArrayHashMapUnmanaged([]const u8) = .empty,

    pub fn get(p: Profile, key: []const u8) ?[]const u8 {
        return p.values.get(key);
    }
    pub fn set(p: *Profile, a: c.A, key: []const u8, value: []const u8) !void {
        if (!validKey(key)) return error.UnknownConfigKey;
        if (value.len == 0) return error.EmptyConfigValue;
        if (c.eq(u8, key, "editor")) _ = try @import("editor.zig").arguments(a, value);
        if (c.eq(u8, key, "chain") or c.eq(u8, key, "kv_chain")) _ = try chainId(value);
        if (std.mem.startsWith(u8, key, "rpc.")) _ = try chainId(key[4..]);
        if (std.mem.startsWith(u8, key, "instances.")) _ = try chainId(key[10..]);
        if (std.mem.startsWith(u8, key, "interacts.")) _ = try chainId(key[10..]);
        if (c.eq(u8, key, "instance") or std.mem.startsWith(u8, key, "instances.")) try c.address(value);
        if (c.eq(u8, key, "factory") or c.eq(u8, key, "kv_factory") or c.eq(u8, key, "kv_address") or c.eq(u8, key, "interact") or std.mem.startsWith(u8, key, "interacts.")) try c.address(value);
        try p.values.put(a, key, value);
    }
    pub fn parse(a: c.A, source: []const u8) !Profile {
        var profile: Profile = .{};
        var section: []const u8 = "";
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |raw| {
            const line = c.trim(withoutComment(raw));
            if (line.len == 0) continue;
            if (line[0] == '[') {
                if (line.len < 3 or line[line.len - 1] != ']') return error.InvalidToml;
                section = c.trim(line[1 .. line.len - 1]);
                if (!c.eq(u8, section, "rpc") and !c.eq(u8, section, "instances") and !c.eq(u8, section, "interacts")) return error.UnknownConfigTable;
                if (seen.contains(section)) return error.DuplicateConfigKey;
                try seen.put(a, section, {});
                continue;
            }
            const equal = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidToml;
            const raw_key = c.trim(line[0..equal]);
            const key = try text(a, raw_key, true);
            const full = if (section.len == 0) key else try a.print("{s}.{s}", .{ section, key });
            if (profile.values.contains(full)) return error.DuplicateConfigKey;
            try profile.set(a, full, try text(a, c.trim(line[equal + 1 ..]), false));
        }
        return profile;
    }
    pub fn forChain(p: Profile, prefix: []const u8, chain: u64) ?[]const u8 {
        for (p.values.keys(), p.values.values()) |key, value| {
            if (std.mem.startsWith(u8, key, prefix) and (chainId(key[prefix.len..]) catch continue) == chain) return value;
        }
        return null;
    }
    /// A null value removes this chain's binding, including named aliases.
    pub fn setForChain(p: *Profile, a: c.A, prefix: []const u8, chain: u64, value: ?[]const u8) !void {
        // Remove aliases too: an older rpc.base must not shadow rpc.8453.
        var i: usize = 0;
        while (i < p.values.count()) {
            const key = p.values.keys()[i];
            if (std.mem.startsWith(u8, key, prefix) and (chainId(key[prefix.len..]) catch 0) == chain) {
                _ = p.values.orderedRemove(key);
            } else i += 1;
        }
        if (value) |v| try p.set(a, try a.print("{s}{d}", .{ prefix, chain }), v);
    }
    pub fn format(p: Profile, a: c.A, redact: bool) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(a);
        for ([_][]const u8{ "", "rpc", "instances", "interacts" }) |section| {
            if (section.len > 0) try out.writer.print("\n[{s}]\n", .{section});
            for (p.values.keys(), p.values.values()) |key, raw| {
                const dot = std.mem.indexOfScalar(u8, key, '.');
                if (section.len == 0 and dot != null) continue;
                if (section.len > 0 and (dot == null or !c.eq(u8, key[0..dot.?], section))) continue;
                const name = if (dot) |i| key[i + 1 ..] else key;
                const secret = c.eq(u8, key, "etherscan_api_key") or c.eq(u8, key, "rpc_url") or c.eq(u8, key, "kv_rpc_url") or std.mem.startsWith(u8, key, "rpc.");
                const value = if (redact and secret) "<configured>" else raw;
                try out.writer.print("{s} = {s}\n", .{ try std.json.Stringify.valueAlloc(a, name, .{}), try std.json.Stringify.valueAlloc(a, value, .{}) });
            }
        }
        return out.toOwnedSlice();
    }
};
fn validKey(key: []const u8) bool {
    if (c.eq(u8, key, "editor")) return true;
    if (c.eq(u8, key, "configuration_id") or c.eq(u8, key, "stack_secret_ref")) return true;
    for ([_][]const u8{ "chain", "rpc_url", "instance", "account", "keystore", "password_file", "etherscan_api_key", "etherscan_api_key_env", "etherscan_url", "factory", "kv_factory", "kv_address", "kv_chain", "kv_rpc_url", "interact" }) |known| if (c.eq(u8, key, known)) return true;
    for ([_][]const u8{ "rpc.", "instances.", "interacts." }) |prefix| if (std.mem.startsWith(u8, key, prefix)) return validName(key[prefix.len..]);
    return false;
}
pub fn validName(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    for (value) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return false;
    return true;
}
fn withoutComment(line: []const u8) []const u8 {
    var quote: u8 = 0;
    var escaped = false;
    for (line, 0..) |ch, i| {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (quote == '"' and ch == '\\') {
            escaped = true;
            continue;
        }
        if (ch == quote) quote = 0 else if (quote == 0 and (ch == '"' or ch == '\'')) quote = ch else if (quote == 0 and ch == '#') return line[0..i];
    }
    return line;
}
fn text(a: c.A, value: []const u8, bare: bool) ![]const u8 {
    if (value.len == 0) return error.InvalidToml;
    if (value[0] == '"') return c.string(try c.parse(a, value));
    if (value[0] == '\'') {
        if (value.len < 2 or value[value.len - 1] != '\'') return error.InvalidToml;
        // Literal strings end at the first closing quote; adjacent strings or
        // trailing tokens cannot be swallowed into the configured value.
        if (std.mem.indexOfScalar(u8, value[1 .. value.len - 1], '\'') != null) return error.InvalidToml;
        return value[1 .. value.len - 1];
    }
    if (bare and validName(value)) return value;
    // Numeric chain IDs are accepted in either quoted or TOML integer form.
    if (!bare) {
        _ = std.fmt.parseInt(u64, value, 10) catch return error.InvalidToml;
        return value;
    }
    return error.InvalidToml;
}
pub fn file(a: c.A, dir: []const u8, name: []const u8) ![]const u8 {
    if (!validName(name)) return error.InvalidProfileName;
    return a.print("{s}/{s}.toml", .{ dir, name });
}
pub fn load(a: c.A, io: std.Io, dir: []const u8, name: []const u8) !Profile {
    const source = c.read(a, io, try file(a, dir, name)) catch |err| {
        if (err == error.FileNotFound) return .{};
        return err;
    };
    var profile = try Profile.parse(a, source);
    profile.original = try profile.values.clone(a);
    return profile;
}
pub fn loadForCommand(a: c.A, io: std.Io, dir: []const u8, name: []const u8, command: []const []const u8) !Profile {
    // Recovery commands must work even when the current profile is malformed.
    if (command.len > 0 and c.eq(u8, command[0], "profile")) return .{};
    return load(a, io, dir, name);
}
pub fn activate(a: c.A, io: std.Io, dir: []const u8, name: []const u8) !void {
    const source = try c.read(a, io, try file(a, dir, name));
    _ = try Profile.parse(a, source);
    try c.write(io, try a.print("{s}/active", .{dir}), name, true);
}
pub fn save(p: Profile, a: c.A, io: std.Io, dir: []const u8, name: []const u8, replace: bool) !void {
    const path = try file(a, dir, name);
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const lock = try std.Io.Dir.cwd().createFile(io, try a.print("{s}.lock", .{path}), .{ .truncate = false, .lock = .exclusive, .permissions = .fromMode(0o600) });
    defer lock.close(io);
    if (!replace) return c.write(io, path, try p.format(a, false), false);
    // Reload while holding a stable lock file. Atomic replacement alone does
    // not protect changes based on an earlier profile snapshot.
    var current = try load(a, io, dir, name);
    for (p.original.keys()) |key| {
        if (!sameValue(p.original.get(key), p.get(key))) try applyDelta(&current, a, key, p.original.get(key), p.get(key));
    }
    for (p.values.keys()) |key| {
        if (!p.original.contains(key)) try applyDelta(&current, a, key, null, p.get(key));
    }
    try c.write(io, path, try current.format(a, false), true);
}
fn sameValue(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return c.eq(u8, left.?, right.?);
}
fn applyDelta(current: *Profile, a: c.A, key: []const u8, before: ?[]const u8, after: ?[]const u8) !void {
    const latest = current.get(key);
    if (!sameValue(latest, before) and !sameValue(latest, after)) return error.ProfileChangedRetry;
    if (after) |value| try current.set(a, key, value) else _ = current.values.orderedRemove(key);
}
/// Configuration interchange uses exact JSON integers across all supported tools.
pub const max_chain_id: u64 = 9007199254740991;
pub fn chainId(value: []const u8) !u64 {
    const names = [_][]const u8{ "ethereum", "mainnet", "base", "arbitrum", "optimism", "polygon", "bsc", "avalanche", "gnosis", "sepolia", "base-sepolia", "anvil", "localhost" };
    const ids = [_]u64{ 1, 1, 8453, 42161, 10, 137, 56, 43114, 100, 11155111, 84532, 31337, 31337 };
    for (names, ids) |name, number| if (c.eq(u8, value, name)) return number;
    const number = std.fmt.parseInt(u64, value, 10) catch return error.UnknownChainUseNumericId;
    if (number == 0 or number > max_chain_id) return error.InvalidChainId;
    return number;
}

test "profiles preserve quoted TOML, reject typos and traversal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try Profile.parse(a, "chain = 'base'\naccount = \"cold#1\" # comment\n[rpc]\nbase = 'https://example.org/a#b'\n");
    try std.testing.expectEqualStrings("cold#1", p.get("account").?);
    const restored = try Profile.parse(a, try p.format(a, false));
    try std.testing.expectEqualStrings(p.get("rpc.base").?, restored.get("rpc.base").?);
    try std.testing.expectError(error.UnknownConfigKey, Profile.parse(a, "acount='wrong'"));
    for ([_][]const u8{ "account = 'treasury' 'extra'", "account='treasury'junk'", "'account' 'extra'='treasury'", "account='unterminated" }) |source| try std.testing.expectError(error.InvalidToml, Profile.parse(a, source));
    try std.testing.expectEqualStrings("cold#1", (try Profile.parse(a, "account='cold#1' # comment")).get("account").?);
    try std.testing.expectEqualStrings("owner's wallet", (try Profile.parse(a, "account=\"owner's wallet\"")).get("account").?);
    try std.testing.expectError(error.DuplicateConfigKey, Profile.parse(a, "chain='base'\nchain='mainnet'"));
    try std.testing.expectError(error.InvalidProfileName, file(a, "/tmp", "../escape"));
    try std.testing.expectEqual(@as(u64, 8453), try chainId("base"));
    try std.testing.expectEqualStrings(p.get("rpc.base").?, p.forChain("rpc.", 8453).?);
    try std.testing.expect(p.forChain("rpc.", 1) == null);
}

test "chain bindings replace and remove aliases without touching other chains" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var p = try Profile.parse(a, "[rpc]\nbase='old'\n8453='duplicate'\nethereum='keep'\n");
    try p.setForChain(a, "rpc.", 8453, "new");
    try std.testing.expect(p.get("rpc.base") == null);
    try std.testing.expectEqualStrings("new", p.forChain("rpc.", 8453).?);
    try p.setForChain(a, "rpc.", 8453, null);
    try std.testing.expect(p.forChain("rpc.", 8453) == null);
    try std.testing.expectEqualStrings("keep", p.forChain("rpc.", 1).?);
}

test "profile activation validates the target and management recovers from invalid profiles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    try c.write(std.testing.io, try file(a, dir, "good"), "chain='arbitrum'", false);
    try c.write(std.testing.io, try file(a, dir, "bad"), "invalid TOML", false);
    const active = try a.print("{s}/active", .{dir});
    try activate(a, std.testing.io, dir, "good");
    try std.testing.expectError(error.InvalidToml, activate(a, std.testing.io, dir, "bad"));
    try std.testing.expectEqualStrings("good", try c.read(a, std.testing.io, active));
    try c.write(std.testing.io, active, "bad", true);
    _ = try loadForCommand(a, std.testing.io, dir, "bad", &.{ "profile", "list" });
    _ = try loadForCommand(a, std.testing.io, dir, "bad", &.{ "profile", "use", "good" });
    try activate(a, std.testing.io, dir, "good");
    try std.testing.expectEqualStrings("good", try c.read(a, std.testing.io, active));
    try std.testing.expectError(error.InvalidToml, loadForCommand(a, std.testing.io, dir, "bad", &.{ "config", "show" }));
}

test "stale profile saves preserve independent updates and reject conflicting changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    try save(try Profile.parse(a, "chain='arbitrum'\naccount='original'"), a, std.testing.io, dir, "work", false);
    var first = try load(a, std.testing.io, dir, "work");
    var second = try load(a, std.testing.io, dir, "work");
    try first.set(a, "account", "alice");
    try second.set(a, "editor", "vi");
    try save(first, a, std.testing.io, dir, "work", true);
    try save(second, a, std.testing.io, dir, "work", true);
    const merged = try load(a, std.testing.io, dir, "work");
    try std.testing.expectEqualStrings("alice", merged.get("account").?);
    try std.testing.expectEqualStrings("vi", merged.get("editor").?);
    try second.set(a, "account", "bob");
    try std.testing.expectError(error.ProfileChangedRetry, save(second, a, std.testing.io, dir, "work", true));
    try std.testing.expectEqualStrings("alice", (try load(a, std.testing.io, dir, "work")).get("account").?);
    var removal = try load(a, std.testing.io, dir, "work");
    var addition = try load(a, std.testing.io, dir, "work");
    _ = removal.values.orderedRemove("editor");
    try addition.set(a, "rpc_url", "https://example.org");
    try save(addition, a, std.testing.io, dir, "work", true);
    try save(removal, a, std.testing.io, dir, "work", true);
    const final = try load(a, std.testing.io, dir, "work");
    try std.testing.expect(final.get("editor") == null);
    try std.testing.expectEqualStrings("https://example.org", final.get("rpc_url").?);
}
