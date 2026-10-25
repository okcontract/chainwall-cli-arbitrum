const std = @import("std");
const c = @import("common.zig");
const abi = @import("abi_codec.zig");
const contracts = @import("contracts.zig");
const ms = @import("miniscript");

fn kind(item: c.Value, expected: []const u8) bool {
    return c.eq(u8, c.string(c.field(item, "type") orelse .null) catch "", expected);
}

pub fn validate(a: c.A, catalog: c.Value) !void {
    if (catalog != .array) return error.InvalidAbi;
    for (catalog.array.items) |item| {
        if (!kind(item, "function") and !kind(item, "event")) continue;
        var method = item;
        method.object = try item.object.clone(a);
        if (kind(item, "event")) {
            if (c.field(item, "anonymous")) |flag| if (flag != .bool) return error.InvalidAbi;
            try method.object.put(a, "stateMutability", .{ .string = "view" });
        }
        _ = ms.abi.method(a, method) catch |err| return if (err == error.OutOfMemory) err else error.InvalidAbi;
        for (c.field(item, "inputs").?.array.items) |param| if (c.field(param, "indexed")) |flag| if (flag != .bool) return error.InvalidAbi;
        if (kind(item, "function")) {
            const outputs = c.field(item, "outputs") orelse return error.InvalidAbi;
            try method.object.put(a, "inputs", outputs);
            _ = ms.abi.method(a, method) catch |err| return if (err == error.OutOfMemory) err else error.InvalidAbi;
        }
    }
}

/// Selectors alone are not identities. Preserve collisions and malformed data
/// as undecoded input instead of choosing a plausible ABI arbitrarily.
pub fn call(a: c.A, catalog: c.Value, input: []const u8) !c.Value {
    const bytes = try abi.unhex(a, input);
    if (bytes.len < 4) return .null;
    var found: c.Value = .null;
    var signature: ?[]const u8 = null;
    if (catalog == .array) for (catalog.array.items) |item| {
        if (!kind(item, "function")) continue;
        const candidate = try contracts.signature(a, item, false);
        if (@as(u32, @intCast(ms.bytecode.hash(candidate) >> 224)) != std.mem.readInt(u32, bytes[0..4], .big)) continue;
        if (signature) |previous| {
            if (!c.eq(u8, previous, candidate) or !c.eq(u8, try c.encode(a, c.field(found, "inputs").?), try c.encode(a, c.field(item, "inputs").?))) return error.AmbiguousAbiSelector;
        } else {
            found = item;
            signature = candidate;
        }
    };
    if (found == .null) return .null;
    const params = c.field(found, "inputs").?;
    const values = try abi.decode(a, params, bytes[4..]);
    const encoded = try abi.encode(a, params, values);
    return c.parse(a, try c.encode(a, .{ .name = c.field(found, "name").?, .signature = signature.?, .selector = try abi.hex(a, bytes[0..4]), .abi = found, .args = values, .namedArgs = try abi.named(a, params, values), .canonical = c.eq(u8, encoded, bytes[4..]) }));
}

fn eventValues(a: c.A, item: c.Value, topics: []const c.Value, bytes: []const u8) !c.Value {
    const params = c.field(item, "inputs") orelse return error.InvalidAbi;
    var plain = std.json.Array.init(a);
    var indexed_count: usize = 0;
    for (params.array.items) |param| {
        if ((c.field(param, "indexed") orelse c.Value{ .bool = false }).bool) indexed_count += 1 else try plain.append(param);
    }
    if (topics.len != indexed_count) return error.InvalidEventTopics;
    const values = try abi.decode(a, .{ .array = plain }, bytes);
    if (!c.eq(u8, bytes, try abi.encode(a, .{ .array = plain }, values))) return error.InvalidEventData;
    var ti: usize = 0;
    var vi: usize = 0;
    var args = std.json.Array.init(a);
    for (params.array.items) |param| {
        const indexed = (c.field(param, "indexed") orelse c.Value{ .bool = false }).bool;
        const type_ = try c.string(c.field(param, "type").?);
        const hashed = indexed and (std.mem.indexOfScalar(u8, type_, '[') != null or std.mem.startsWith(u8, type_, "tuple") or c.eq(u8, type_, "bytes") or c.eq(u8, type_, "string"));
        const value = if (indexed) blk: {
            const topic = topics[ti];
            ti += 1;
            const word = try abi.unhex(a, try c.string(topic));
            if (word.len != 32) return error.InvalidEventTopics;
            break :blk if (hashed) topic else (try abi.decode(a, try abi.array(a, &.{param}), word)).array.items[0];
        } else blk: {
            const value = values.array.items[vi];
            vi += 1;
            break :blk value;
        };
        try args.append(try c.parse(a, try c.encode(a, .{ .name = c.field(param, "name") orelse c.Value{ .string = "" }, .type = type_, .indexed = indexed, .hashed = hashed, .value = value })));
    }
    return .{ .array = args };
}

pub fn event(a: c.A, catalog: c.Value, log: c.Value) !c.Value {
    if (catalog != .array) return .null;
    const topics = c.field(log, "topics") orelse return error.InvalidEventTopics;
    if (topics != .array or topics.array.items.len > 4) return error.InvalidEventTopics;
    const bytes = try abi.unhex(a, try c.string(c.field(log, "data") orelse return error.InvalidEventData));
    var found: c.Value = .null;
    for (catalog.array.items) |item| {
        if (!kind(item, "event")) continue;
        const anonymous = (c.field(item, "anonymous") orelse c.Value{ .bool = false }).bool;
        const signature = try contracts.signature(a, item, false);
        if (!anonymous and (topics.array.items.len == 0 or !std.ascii.eqlIgnoreCase(try c.string(topics.array.items[0]), try c.hex(a, ms.bytecode.hash(signature))))) continue;
        const values = eventValues(a, item, topics.array.items[@intFromBool(!anonymous)..], bytes) catch |err| {
            if (err == error.OutOfMemory or !anonymous) return err;
            continue;
        };
        const candidate = try c.parse(a, try c.encode(a, .{ .name = c.field(item, "name").?, .signature = signature, .anonymous = anonymous, .args = values }));
        if (found != .null and !c.eq(u8, try c.encode(a, found), try c.encode(a, candidate))) return error.AmbiguousEventAbi;
        found = candidate;
    }
    return found;
}
