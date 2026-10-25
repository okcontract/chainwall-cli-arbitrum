const std = @import("std");
const ms = @import("miniscript");
const c = @import("common.zig");
const Schema = ms.abi.Schema;

pub fn unhex(a: c.A, text: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, text, "0x") or text.len % 2 != 0) return error.InvalidHex;
    const bytes = try a.alloc(u8, (text.len - 2) / 2);
    errdefer a.free(bytes);
    _ = try std.fmt.hexToBytes(bytes, text[2..]);
    return bytes;
}
pub const hex = ms.bytecode.hex;
pub fn array(a: c.A, items: []const c.Value) !c.Value {
    var v = std.json.Array.init(a);
    try v.appendSlice(items);
    return .{ .array = v };
}
pub fn uint(a: c.A, v: u256) !c.Value {
    return .{ .string = try a.print("{d}", .{v}) };
}
fn root(a: c.A, params: c.Value) !*Schema {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "name", .{ .string = "codec" });
    try obj.put(a, "stateMutability", .{ .string = "view" });
    try obj.put(a, "inputs", params);
    return (try ms.abi.method(a, .{ .object = obj })).root;
}
fn dynamic(s: *const Schema) bool {
    return switch (s.kind) {
        .dynamic_array, .dynamic_bytes => true,
        .fixed_array => dynamic(s.children[0]),
        .tuple => blk: {
            for (s.children) |child| if (dynamic(child)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}
fn size(s: *const Schema) usize {
    if (dynamic(s)) return 32;
    if (s.kind == .fixed_array) return s.length * size(s.children[0]);
    if (s.kind == .tuple) {
        var n: usize = 0;
        for (s.children) |child| n += size(child);
        return n;
    }
    return 32;
}
fn word(out: *std.Io.Writer, n: u256) !void {
    var buf: [32]u8 = undefined;
    std.mem.writeInt(u256, &buf, n, .big);
    try out.writeAll(&buf);
}
fn sequence(a: c.A, schemas: []const *Schema, repeat: bool, values: []const c.Value) anyerror![]const u8 {
    var head: std.Io.Writer.Allocating = .init(a);
    var tail: std.Io.Writer.Allocating = .init(a);
    var head_size: usize = 0;
    for (values, 0..) |_, i| head_size += size(schemas[if (repeat) 0 else i]);
    for (values, 0..) |v, i| {
        const s = schemas[if (repeat) 0 else i];
        const encoded = try encodeNode(a, s, v);
        if (dynamic(s)) {
            try word(&head.writer, head_size + tail.written().len);
            try tail.writer.writeAll(encoded);
        } else try head.writer.writeAll(encoded);
    }
    try head.writer.writeAll(tail.written());
    return head.toOwnedSlice();
}
fn encodeNode(a: c.A, s: *const Schema, v: c.Value) anyerror![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    switch (s.kind) {
        .tuple, .fixed_array, .dynamic_array => {
            if (v != .array) return error.ExpectedArray;
            const items = v.array.items;
            if ((s.kind == .tuple and items.len != s.children.len) or (s.kind == .fixed_array and items.len != s.length) or items.len > 100_000) return error.WrongArgumentCount;
            if (s.kind == .dynamic_array) try word(&out.writer, items.len);
            try out.writer.writeAll(try sequence(a, s.children, s.kind != .tuple, items));
        },
        .dynamic_bytes => {
            const text = try c.string(v);
            const bytes = if (s.string) text else try unhex(a, text);
            try word(&out.writer, bytes.len);
            try out.writer.writeAll(bytes);
            try out.writer.splatByteAll(0, (32 - bytes.len % 32) % 32);
        },
        .fixed_bytes => {
            const bytes = try unhex(a, try c.string(v));
            if (bytes.len != s.width) return error.InvalidAbiScalar;
            try out.writer.writeAll(bytes);
            try out.writer.splatByteAll(0, 32 - bytes.len);
        },
        .boolean => {
            const n: u256 = if (v == .bool) @intFromBool(v.bool) else if (c.eq(u8, try c.scalar(a, v), "true")) 1 else if (c.eq(u8, try c.scalar(a, v), "false")) 0 else return error.InvalidAbiScalar;
            try word(&out.writer, n);
        },
        .int => {
            const text = try c.scalar(a, v);
            const n = if (std.mem.startsWith(u8, text, "0x")) @as(i256, @bitCast(try c.word(text))) else try std.fmt.parseInt(i256, text, 10);
            const shift: u8 = @intCast(256 - @as(u16, s.width) * 8);
            if ((n << shift) >> shift != n) return error.InvalidAbiScalar;
            try word(&out.writer, @bitCast(n));
        },
        .uint, .address => {
            if (s.kind == .address) {
                const text = try c.scalar(a, v);
                if (text.len != 42 or !std.mem.startsWith(u8, text, "0x")) return error.InvalidAbiScalar;
            }
            const n = try c.number(a, v);
            const bits: u16 = if (s.kind == .address) 160 else @as(u16, s.width) * 8;
            if (bits < 256 and n >> @as(u8, @intCast(bits)) != 0) return error.InvalidAbiScalar;
            try word(&out.writer, n);
        },
    }
    return out.toOwnedSlice();
}
fn tupleValues(a: c.A, params: []const c.Value, value: c.Value) anyerror!c.Value {
    var values = std.json.Array.init(a);
    if (value == .array and value.array.items.len != params.len) return error.WrongArgumentCount;
    for (params, 0..) |p, i| {
        const v = if (value == .array) value.array.items[i] else c.field(value, try c.string(c.field(p, "name").?)) orelse return error.MissingNamedArgument;
        try values.append(try normalize(a, p, v));
    }
    return .{ .array = values };
}
fn normalize(a: c.A, param: c.Value, value: c.Value) anyerror!c.Value {
    const kind = try c.string(c.field(param, "type").?);
    if (std.mem.endsWith(u8, kind, "]")) {
        if (value != .array) return error.ExpectedArray;
        var child = param;
        child.object = try param.object.clone(a);
        try child.object.put(a, "type", .{ .string = kind[0..std.mem.lastIndexOfScalar(u8, kind, '[').?] });
        var result = std.json.Array.init(a);
        for (value.array.items) |v| try result.append(try normalize(a, child, v));
        return .{ .array = result };
    }
    if (c.eq(u8, kind, "tuple")) return tupleValues(a, c.field(param, "components").?.array.items, value);
    return value;
}
pub fn encode(a: c.A, params: c.Value, values: c.Value) ![]const u8 {
    return encodeNode(a, try root(a, params), try tupleValues(a, params.array.items, values));
}
pub fn calldata(a: c.A, method: c.Value, values: c.Value) ![]const u8 {
    const parsed = try ms.abi.method(a, method);
    const args = try encode(a, c.field(method, "inputs").?, values);
    const buf = try a.alloc(u8, args.len + 4);
    std.mem.writeInt(u32, buf[0..4], parsed.selector, .big);
    @memcpy(buf[4..], args);
    return hex(a, buf);
}
fn readWord(bytes: []const u8, offset: usize) !u256 {
    if (offset > bytes.len or bytes.len - offset < 32) return error.InvalidAbiResponse;
    return std.mem.readInt(u256, bytes[offset..][0..32], .big);
}
fn offsetWord(bytes: []const u8, offset: usize) !usize {
    return std.math.cast(usize, try readWord(bytes, offset)) orelse error.InvalidAbiResponse;
}
const DecodeBudget = struct {
    nodes: usize = 1_000_000,
    bytes: usize = 32 * 1024 * 1024,
    fn consume(b: *DecodeBudget, bytes: usize) !void {
        if (bytes > b.bytes) return error.InvalidAbiResponse;
        b.bytes -= bytes;
    }
};
fn decodeSequence(a: c.A, schemas: []const *Schema, repeat: bool, count: usize, bytes: []const u8, budget: *DecodeBudget) anyerror!c.Value {
    if (count > 100_000 or count > budget.nodes) return error.InvalidAbiResponse;
    budget.nodes -= count;
    try budget.consume(count * @sizeOf(c.Value));
    var head: usize = 0;
    for (0..count) |i| head = try std.math.add(usize, head, size(schemas[if (repeat) 0 else i]));
    if (head > bytes.len) return error.InvalidAbiResponse;
    var values = std.json.Array.init(a);
    var at: usize = 0;
    for (0..count) |i| {
        const s = schemas[if (repeat) 0 else i];
        const offset = if (dynamic(s)) try offsetWord(bytes, at) else at;
        if (offset > bytes.len or (dynamic(s) and (offset < head or offset % 32 != 0))) return error.InvalidAbiResponse;
        try values.append(try decodeNode(a, s, bytes[offset..], budget));
        at += size(s);
    }
    return .{ .array = values };
}
fn decodeNode(a: c.A, s: *const Schema, bytes: []const u8, budget: *DecodeBudget) anyerror!c.Value {
    switch (s.kind) {
        .tuple => return decodeSequence(a, s.children, false, s.children.len, bytes, budget),
        .fixed_array => return decodeSequence(a, s.children, true, s.length, bytes, budget),
        .dynamic_array => return decodeSequence(a, s.children, true, try offsetWord(bytes, 0), if (bytes.len >= 32) bytes[32..] else return error.InvalidAbiResponse, budget),
        .dynamic_bytes => {
            const n = try offsetWord(bytes, 0);
            if (bytes.len < 32 or n > bytes.len - 32) return error.InvalidAbiResponse;
            const raw = bytes[32..][0..n];
            if (s.string and !std.unicode.utf8ValidateSlice(raw)) return error.InvalidAbiResponse;
            // Offsets may alias the same tail many times. Charge each decoded
            // copy, including hex expansion, before allocating it.
            const length = if (s.string) n else try std.math.add(usize, 2, try std.math.mul(usize, n, 2));
            try budget.consume(length);
            return .{ .string = if (s.string) try a.dupe(u8, raw) else try hex(a, raw) };
        },
        else => {},
    }
    try budget.consume(80); // Upper bound for a formatted uint256 or scalar hex.
    const n = try readWord(bytes, 0);
    switch (s.kind) {
        .boolean => return if (n <= 1) .{ .bool = n == 1 } else error.InvalidAbiResponse,
        .address => return if (n >> 160 == 0) .{ .string = try hex(a, bytes[12..32]) } else error.InvalidAbiResponse,
        .fixed_bytes => {
            for (bytes[s.width..32]) |b| if (b != 0) return error.InvalidAbiResponse;
            return .{ .string = try hex(a, bytes[0..s.width]) };
        },
        .uint => {
            if (s.width < 32 and n >> @as(u8, @intCast(@as(u16, s.width) * 8)) != 0) return error.InvalidAbiResponse;
            return uint(a, n);
        },
        .int => {
            const signed: i256 = @bitCast(n);
            const shift: u8 = @intCast(256 - @as(u16, s.width) * 8);
            if ((signed << shift) >> shift != signed) return error.InvalidAbiResponse;
            return .{ .string = try a.print("{d}", .{signed}) };
        },
        else => unreachable,
    }
}
pub fn decode(a: c.A, params: c.Value, bytes: []const u8) !c.Value {
    var budget: DecodeBudget = .{};
    return decodeNode(a, try root(a, params), bytes, &budget);
}

/// Add artifact field names for human-facing records, retaining arrays for
/// unnamed outputs. Wire decoding always uses positional tuples.
pub fn named(a: c.A, params: c.Value, value: c.Value) anyerror!c.Value {
    var result: std.json.ObjectMap = .empty;
    var values = std.json.Array.init(a);
    var all_named = true;
    for (params.array.items, value.array.items) |p, v| {
        const name = c.string(c.field(p, "name") orelse .{ .string = "" }) catch "";
        const converted = try namedNode(a, p, v);
        try values.append(converted);
        if (name.len == 0 or result.contains(name)) all_named = false;
        try result.put(a, name, converted);
    }
    return if (all_named) .{ .object = result } else .{ .array = values };
}
fn namedNode(a: c.A, param: c.Value, value: c.Value) anyerror!c.Value {
    const kind = try c.string(c.field(param, "type").?);
    if (std.mem.endsWith(u8, kind, "]")) {
        var child = param;
        child.object = try param.object.clone(a);
        try child.object.put(a, "type", .{ .string = kind[0..std.mem.lastIndexOfScalar(u8, kind, '[').?] });
        var result = std.json.Array.init(a);
        for (value.array.items) |v| try result.append(try namedNode(a, child, v));
        return .{ .array = result };
    }
    if (c.eq(u8, kind, "tuple")) return named(a, c.field(param, "components").?, value);
    return value;
}
pub fn namedResult(a: c.A, method: c.Value, decoded: c.Value) !c.Value {
    const params = c.field(method, "outputs").?;
    if (params.array.items.len == 1) return namedNode(a, params.array.items[0], decoded.array.items[0]);
    return named(a, params, decoded);
}

test "hex decoding releases invalid input buffers without an arena" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidCharacter, unhex(a, "0x12gg"));
    const bytes = try unhex(a, "0x1234");
    defer a.free(bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34 }, bytes);
}

test "ABI dynamic tuple offsets, signed values and invalid response bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const params = try c.parse(a, "[{\"type\":\"tuple[]\",\"components\":[{\"name\":\"x\",\"type\":\"int8\"},{\"name\":\"y\",\"type\":\"string\"}]}]");
    const value = try c.parse(a, "[[[\"-128\",\"hello\"],[\"127\",\"\"]]]");
    const bytes = try encode(a, params, value);
    try std.testing.expectEqualStrings(try c.encode(a, value), try c.encode(a, try decode(a, params, bytes)));
    try std.testing.expectError(error.InvalidAbiResponse, decode(a, params, bytes[0..40]));
    const bad = try a.dupe(u8, bytes);
    @memset(bad[32..64], 255);
    try std.testing.expectError(error.InvalidAbiResponse, decode(a, params, bad));
    const address_param = try c.parse(a, "[{\"type\":\"address\"}]");
    try std.testing.expectError(error.InvalidAbiScalar, encode(a, address_param, try array(a, &.{.{ .string = "0x1" }})));
}

test "ABI shared tails cannot multiply decoded memory beyond the budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const params = try c.parse(a, "[{\"type\":\"bytes[]\"}]");
    const count = 1024;
    const tail_len = 65536;
    const bytes = try a.alloc(u8, 96 + count * 32 + tail_len);
    @memset(bytes, 0);
    std.mem.writeInt(u256, bytes[0..32], 32, .big);
    std.mem.writeInt(u256, bytes[32..64], count, .big);
    for (0..count) |i| std.mem.writeInt(u256, bytes[64 + i * 32 ..][0..32], count * 32, .big);
    std.mem.writeInt(u256, bytes[64 + count * 32 ..][0..32], tail_len, .big);
    try std.testing.expectError(error.InvalidAbiResponse, decode(a, params, bytes));
    try std.testing.expect(arena.queryCapacity() < 48 * 1024 * 1024);
    // Small shared tails remain valid; rejecting aliasing would narrow the ABI.
    std.mem.writeInt(u256, bytes[64 + count * 32 ..][0..32], 1, .big);
    const decoded = try decode(a, params, bytes);
    try std.testing.expectEqual(count, decoded.array.items[0].array.items.len);
}
