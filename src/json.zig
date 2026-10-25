const std = @import("std");
const t = @import("tree.zig");
const Settings = @import("lower.zig").Settings;
pub fn field(v: std.json.Value, key: []const u8) ?std.json.Value {
    return if (v == .object) v.object.get(key) else null;
}
pub fn string(v: std.json.Value) t.Error![]const u8 {
    return if (v == .string) v.string else error.InvalidArguments;
}
pub fn settings(v: ?std.json.Value) t.Error!Settings {
    var out: Settings = .{};
    const value = v orelse return out;
    if (value != .object) return error.InvalidSettings;
    if (field(value, "argumentContext")) |arg| out.argumentContext = std.meta.stringToEnum(@TypeOf(out.argumentContext), try string(arg)) orelse return error.InvalidSettings;
    if (field(value, "optimization")) |arg| out.optimization = std.meta.stringToEnum(@TypeOf(out.optimization), try string(arg)) orelse return error.InvalidSettings;
    if (field(value, "$validity")) |arg| {
        if (arg != .integer or arg.integer < 0) return error.InvalidSettings;
        out.validity = @intCast(arg.integer);
    }
    if (field(value, "$slippage")) |arg| {
        if (arg != .integer) return error.InvalidSettings;
        out.slippage = arg.integer;
    }
    if (field(value, "forceRecursiveAbi")) |arg| {
        if (arg != .bool) return error.InvalidSettings;
        out.forceRecursiveAbi = arg.bool;
    }
    // Compiler artifacts serialize absent optional metadata as JSON null.
    inline for (.{ "abiFunctionsByCallKey", "knownResolvableHashes", "addressArgResolutionsByWriteKey" }) |key| {
        if (field(value, key)) |item| @field(out, key) = if (item == .null) null else item;
    }
    return out;
}

fn callMap(a: t.Allocator, input: std.json.Value, methods: bool) t.Error!std.json.Value {
    if (input != .object) return error.InvalidSettings;
    var result: std.json.ObjectMap = .empty;
    var iterator = input.object.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        if (key.len != 77 or !std.mem.startsWith(u8, key, "0x") or !std.mem.eql(u8, key[66..69], ":0x")) return error.InvalidSettings;
        for (key[2..66]) |c| if (!std.ascii.isHex(c)) return error.InvalidSettings;
        for (key[69..]) |c| if (!std.ascii.isHex(c)) return error.InvalidSettings;
        if (methods) {
            const method = try @import("abi.zig").method(a, entry.value_ptr.*);
            const selector = std.fmt.parseInt(u32, key[69..], 16) catch return error.InvalidSettings;
            if (method.selector != selector) return error.InvalidSettings;
        } else {
            const hints = entry.value_ptr.*;
            if (hints != .array) return error.InvalidSettings;
            for (hints.array.items) |hint| {
                const index = field(hint, "index") orelse return error.InvalidSettings;
                const kind = try string(field(hint, "kind") orelse return error.InvalidSettings);
                if (index != .integer or index.integer < 0 or index.integer > 9007199254740991 or (!t.same(kind, "address") and !t.same(kind, "address[]"))) return error.InvalidSettings;
            }
        }
        try result.put(a, try std.ascii.allocLowerString(a, key), entry.value_ptr.*);
    }
    return .{ .object = result };
}

/// Normalize into a compilation arena; caller-owned JSON is never mutated.
pub fn normalize(a: t.Allocator, input: Settings) t.Error!Settings {
    var out = input;
    if (input.abiFunctionsByCallKey) |methods| out.abiFunctionsByCallKey = try callMap(a, methods, true);
    if (input.addressArgResolutionsByWriteKey) |hints| out.addressArgResolutionsByWriteKey = try callMap(a, hints, false);
    if (input.knownResolvableHashes) |hashes| {
        if (hashes != .array) return error.InvalidSettings;
        for (hashes.array.items) |hash| _ = @import("parser.zig").parseNumber(a, try string(hash)) catch return error.InvalidSettings;
    }
    return out;
}
