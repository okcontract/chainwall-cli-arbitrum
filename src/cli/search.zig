const std = @import("std");
const c = @import("common.zig");
const labels = @import("labels.zig");
const Store = @import("store.zig").Store;
const Profile = @import("config.zig").Profile;
pub const kinds = "users authaccounts groups policies orgs contracts tokens interactions accounts safes timelocks system addresses";

fn appendText(writer: *std.Io.Writer, value: c.Value, depth: u8) anyerror!void {
    if (depth > 16) return;
    switch (value) {
        .string, .number_string => |text| try writer.print("{s}\n", .{text}),
        .integer => |number| try writer.print("{d}\n", .{number}),
        .array => |array| for (array.items) |item| try appendText(writer, item, depth + 1),
        .object => |object| for (object.values()) |item| try appendText(writer, item, depth + 1),
        else => {},
    }
}

const Index = struct {
    a: c.A,
    entries: std.StringArrayHashMapUnmanaged(c.Value) = .empty,

    fn add(index: *Index, kind: []const u8, id: []const u8, label: []const u8, address: ?[]const u8, source: []const u8, record: c.Value) !void {
        const a = index.a;
        const key = try a.print("{s}:{s}", .{ kind, try std.ascii.allocLowerString(a, id) });
        var aliases = std.json.Array.init(a);
        if (index.entries.getPtr(key)) |previous| {
            if (label.len > 0) {
                const list = previous.object.getPtr("aliases").?;
                for (list.array.items) |item| if (c.eq(u8, try c.string(item), label)) return;
                try list.array.append(.{ .string = label });
            }
            return;
        }
        if (label.len > 0) try aliases.append(.{ .string = label });
        try index.entries.put(a, key, try c.parse(a, try c.encode(a, .{ .kind = kind, .id = id, .label = if (label.len > 0) label else id, .aliases = aliases.items, .address = address, .source = source, .record = record })));
    }
    fn system(index: *Index, name: []const u8, raw: ?[]const u8, source: []const u8) !void {
        const address = raw orelse return;
        c.address(address) catch return;
        try index.add(if (c.eq(u8, name, "Owner")) "addresses" else "system", address, name, address, source, .null);
    }
    fn topology(index: *Index, value: c.Value, source: []const u8) !void {
        for ([_][2][]const u8{
            .{ "registry", "Registry" }, .{ "initialOwner", "Owner" }, .{ "miniScript", "MiniScript" }, .{ "interact", "Interact" }, .{ "safeFactory", "SafeFactory" }, .{ "accountFactory", "AccountFactory" }, .{ "authAccountFactory", "AuthAccountFactory" }, .{ "engine", "ExecutionEngine" }, .{ "guard", "SafeGuard" }, .{ "module", "OKModule" }, .{ "safeSingleton", "SafeSingleton" }, .{ "proxyFactory", "SafeProxyFactory" },
        }) |pair| try index.system(pair[1], c.string(c.field(value, pair[0]) orelse .null) catch null, source);
    }
};

pub fn run(a: c.A, db: Store, profile: Profile, chain: u64, registry: []const u8, entries: []const labels.Entry, actor: ?[]const u8, auth_account: ?[]const u8, query: []const u8, kind: ?[]const u8, start: u64, count: u64) !c.Value {
    if (kind) |value| if (!@import("schema.zig").contains(kinds, value)) return error.InvalidSearchKind;
    if (count > 1000) return error.PageTooLarge;
    const scope = try @import("store.zig").scopeKey(a, chain, registry);
    var index: Index = .{ .a = a };
    var checkpoints: std.json.ObjectMap = .empty;
    var records: std.StringArrayHashMapUnmanaged(c.Value) = .empty;
    for (@import("sync.zig").datasets) |dataset| {
        try checkpoints.put(a, dataset.name, (try db.checkpoint(scope, dataset.name)) orelse .null);
        for ((try db.entries(scope, dataset.name)).values()) |entry| {
            const id = c.string(c.field(entry, "key") orelse entry) catch continue;
            try records.put(a, try a.print("{s}:{s}", .{ dataset.name, try std.ascii.allocLowerString(a, id) }), c.field(entry, "record") orelse .null);
        }
    }
    for (entries) |entry| {
        const record = records.get(try a.print("{s}:{s}", .{ entry.kind, try std.ascii.allocLowerString(a, entry.id) })) orelse .null;
        try index.add(entry.kind, entry.id, entry.label, entry.address orelse if (entry.id.len == 42) entry.id else null, "cache", record);
    }
    try index.system("Registry", registry, "profile");
    try index.system("Interact", profile.forChain("interacts.", chain) orelse profile.get("interact"), "profile");
    try index.system("OKFactory", profile.get("factory"), "profile");
    if (actor) |address| try index.add("addresses", address, "Selected wallet", address, "selected", .null);
    if (auth_account) |address| try index.add("authaccounts", address, "Passkey account", address, "selected", .null);
    if ((try db.entries(scope, "deployment")).get("instance")) |value| try index.topology(value, "deployment-cache");
    if (profile.get("configuration_id")) |id| if ((try db.entries("configuration", "snapshots")).get(id)) |snapshot| {
        const instance = c.field(c.field(snapshot, "registry") orelse .null, "address") orelse .null;
        const snapshot_chain = c.number(a, c.field(snapshot, "chainId") orelse .null) catch 0;
        if (snapshot_chain == chain and instance == .string and std.ascii.eqlIgnoreCase(instance.string, registry)) {
            const factory = c.field(snapshot, "safeFactory") orelse .null;
            try index.system("SafeFactory", c.string(c.field(factory, "resolvedAddress") orelse .null) catch null, "configuration");
            try index.topology(c.field(factory, "instance") orelse .null, "configuration");
            try index.topology(c.field(factory, "snapshot") orelse .null, "configuration");
        }
    };
    const needle = try std.ascii.allocLowerString(a, c.trim(query));
    var matched: std.ArrayList(c.Value) = .empty;
    for (index.entries.values()) |entry| {
        if (kind) |wanted| if (!c.eq(u8, wanted, try c.string(c.field(entry, "kind").?))) continue;
        var searchable: std.Io.Writer.Allocating = .init(a);
        for ([_][]const u8{ "kind", "id", "aliases", "address", "record" }) |name| try appendText(&searchable.writer, c.field(entry, name) orelse .null, 0);
        const haystack = try std.ascii.allocLowerString(a, searchable.written());
        var words = std.mem.tokenizeAny(u8, needle, " \t\r\n");
        var matches = true;
        while (words.next()) |word| if (std.mem.indexOf(u8, haystack, word) == null) {
            matches = false;
            break;
        };
        if (!matches) continue;
        var score: u8 = 0;
        for (c.field(entry, "aliases").?.array.items) |alias| {
            const text = try std.ascii.allocLowerString(a, try c.string(alias));
            score = @max(score, if (c.eq(u8, text, needle)) @as(u8, 100) else if (std.mem.startsWith(u8, text, needle)) @as(u8, 80) else @as(u8, 0));
        }
        if (std.ascii.eqlIgnoreCase(try c.string(c.field(entry, "id").?), needle)) score = 110;
        var result = entry;
        try result.object.put(a, "score", .{ .integer = score });
        try matched.append(a, result);
    }
    std.mem.sort(c.Value, matched.items, a, struct {
        fn less(allocator: c.A, left: c.Value, right: c.Value) bool {
            const l = c.number(allocator, c.field(left, "score").?) catch 0;
            const r = c.number(allocator, c.field(right, "score").?) catch 0;
            if (l != r) return l > r;
            const lk = c.string(c.field(left, "kind").?) catch "";
            const rk = c.string(c.field(right, "kind").?) catch "";
            if (!c.eq(u8, lk, rk)) return std.mem.lessThan(u8, lk, rk);
            return std.mem.lessThan(u8, c.string(c.field(left, "id").?) catch "", c.string(c.field(right, "id").?) catch "");
        }
    }.less);
    const offset = @min(start, matched.items.len);
    return c.parse(a, try c.encode(a, .{ .query = query, .chainId = chain, .registry = registry, .total = matched.items.len, .entries = matched.items[offset..@min(offset + count, matched.items.len)], .checkpoints = c.Value{ .object = checkpoints }, .cacheByDataset = try @import("cache_metadata.zig").datasets(a, "sqlite-cache", .{ .object = checkpoints }) }));
}
