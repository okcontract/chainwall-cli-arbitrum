const std = @import("std");
const t = @import("tree.zig");
const bc = @import("bytecode.zig");
const json = @import("json.zig");
const Error = t.Error;
pub const Kind = enum(u8) { uint = 0, int = 1, address = 2, boolean = 3, fixed_bytes = 4, tuple = 0x10, fixed_array = 0x11, dynamic_array = 0x12, dynamic_bytes = 0x13 };
pub const Schema = struct { kind: Kind, width: u8 = 32, length: u16 = 0, children: []*Schema = &.{}, string: bool = false };
pub const Method = struct { root: *Schema, descriptor: []const u8, selector: u32, mutability: enum { pure, view, nonpayable, payable }, signature: []const u8 };
pub const Validation = struct { tag: u8, exact: u16 = 0 };
pub fn scalarValidation(schema: *const Schema) Validation {
    return .{ .tag = switch (schema.kind) {
        .address => 1,
        .boolean => 2,
        .uint => if (schema.width == 32) 0 else 0x20 + schema.width,
        .int => if (schema.width == 32) 0 else 0x40 + schema.width,
        .fixed_bytes => if (schema.width == 32) 0 else 0x60 + schema.width,
        else => unreachable,
    } };
}
pub fn key(a: t.Allocator, target: u256, selector: u256) Error![]const u8 {
    return a.print("0x{x:0>64}:0x{x:0>8}", .{ target, selector });
}
fn create(a: t.Allocator, kind: Kind) Error!*Schema {
    const node = try a.create(Schema);
    node.* = .{ .kind = kind };
    return node;
}
fn parameter(a: t.Allocator, input: std.json.Value, depth: usize, count: *usize) Error!*Schema {
    const raw = try json.string(json.field(input, "type") orelse return error.InvalidDescriptor);
    const start = std.mem.indexOfScalar(u8, raw, '[') orelse raw.len;
    const dimensions = std.mem.count(u8, raw[start..], "[");
    if (dimensions > t.limits.abi_schema_depth or depth + dimensions > t.limits.abi_schema_depth or count.* >= t.limits.abi_schema_nodes or dimensions >= t.limits.abi_schema_nodes - count.*) return error.InvalidDescriptor;
    count.* += 1 + dimensions;
    const base = raw[0..start];
    var node: *Schema = undefined;
    if (t.same(base, "tuple")) {
        node = try create(a, .tuple);
        const components = json.field(input, "components") orelse return error.InvalidDescriptor;
        if (components != .array or components.array.items.len > 64) return error.InvalidDescriptor;
        node.children = try a.alloc(*Schema, components.array.items.len);
        for (components.array.items, node.children) |c, *child| child.* = try parameter(a, c, depth + dimensions + 1, count);
    } else if (std.mem.startsWith(u8, base, "uint") or std.mem.startsWith(u8, base, "int")) {
        const unsigned = base[0] == 'u';
        const digits = base[if (unsigned) @as(usize, 4) else 3..];
        const bits = if (digits.len == 0) 256 else std.fmt.parseInt(u16, digits, 10) catch return error.InvalidDescriptor;
        if (bits == 0 or bits > 256 or bits % 8 != 0) return error.InvalidDescriptor;
        node = try create(a, if (unsigned) .uint else .int);
        node.width = @intCast(bits / 8);
    } else if (t.same(base, "address")) node = try create(a, .address) else if (t.same(base, "bool")) node = try create(a, .boolean) else if (t.same(base, "bytes") or t.same(base, "string")) {
        node = try create(a, .dynamic_bytes);
        node.string = t.same(base, "string");
    } else if (t.same(base, "function") or std.mem.startsWith(u8, base, "bytes")) {
        const width = if (t.same(base, "function")) 24 else std.fmt.parseInt(u8, base[5..], 10) catch return error.InvalidDescriptor;
        if (width < 1 or width > 32) return error.InvalidDescriptor;
        node = try create(a, .fixed_bytes);
        node.width = width;
    } else return error.InvalidDescriptor;
    var pos = start;
    while (pos < raw.len) {
        if (raw[pos] != '[') return error.InvalidDescriptor;
        const end = std.mem.indexOfScalarPos(u8, raw, pos, ']') orelse return error.InvalidDescriptor;
        const wrapper = try create(a, if (end == pos + 1) .dynamic_array else .fixed_array);
        if (wrapper.kind == .fixed_array) {
            wrapper.length = std.fmt.parseInt(u16, raw[pos + 1 .. end], 10) catch return error.InvalidDescriptor;
            if (wrapper.length == 0 or wrapper.length > t.limits.abi_array_elements) return error.InvalidDescriptor;
        }
        wrapper.children = try a.dupe(*Schema, &.{node});
        node = wrapper;
        pos = end + 1;
    }
    return node;
}
fn canonical(a: t.Allocator, input: std.json.Value) Error![]const u8 {
    const raw = try json.string(json.field(input, "type") orelse return error.InvalidDescriptor);
    if (!std.mem.startsWith(u8, raw, "tuple")) {
        const end = std.mem.indexOfScalar(u8, raw, '[') orelse raw.len;
        const base = raw[0..end];
        if (t.same(base, "uint") or t.same(base, "int")) return a.print("{s}256{s}", .{ base, raw[end..] });
        return raw;
    }
    const components = json.field(input, "components") orelse return error.InvalidDescriptor;
    if (components != .array) return error.InvalidDescriptor;
    var out: std.Io.Writer.Allocating = .init(a);
    out.writer.writeByte('(') catch return error.OutOfMemory;
    for (components.array.items, 0..) |c, i| {
        if (i != 0) out.writer.writeByte(',') catch return error.OutOfMemory;
        out.writer.writeAll(try canonical(a, c)) catch return error.OutOfMemory;
    }
    out.writer.print("){s}", .{raw[5..]}) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}
/// Arena-oriented schema graph, signature and descriptor. Partial allocations
/// on failure also belong to a. The input JSON is borrowed during this call.
pub fn method(a: t.Allocator, value: std.json.Value) Error!Method {
    const name = try json.string(json.field(value, "name") orelse return error.InvalidDescriptor);
    if (name.len == 0) return error.InvalidDescriptor;
    const inputs = json.field(value, "inputs") orelse return error.InvalidDescriptor;
    if (inputs != .array or inputs.array.items.len > 64) return error.InvalidDescriptor;
    const root = try create(a, .tuple);
    var count: usize = 1;
    root.children = try a.alloc(*Schema, inputs.array.items.len);
    var signature: std.Io.Writer.Allocating = .init(a);
    signature.writer.print("{s}(", .{name}) catch return error.OutOfMemory;
    for (inputs.array.items, root.children, 0..) |param, *child, i| {
        child.* = try parameter(a, param, 2, &count);
        if (i > 0) signature.writer.writeByte(',') catch return error.OutOfMemory;
        signature.writer.writeAll(try canonical(a, param)) catch return error.OutOfMemory;
    }
    signature.writer.writeByte(')') catch return error.OutOfMemory;
    const text = try signature.toOwnedSlice();
    const mutability = std.meta.stringToEnum(@FieldType(Method, "mutability"), try json.string(json.field(value, "stateMutability") orelse return error.InvalidDescriptor)) orelse return error.InvalidDescriptor;
    const descriptor = try encodeSchema(a, root);
    return .{ .root = root, .descriptor = descriptor, .selector = @intCast(bc.hash(text) >> 224), .mutability = mutability, .signature = text };
}
fn encodeNode(a: t.Allocator, node: *Schema, bytes: *std.ArrayList(u8), depth: usize, count: *usize) Error!void {
    count.* += 1;
    if (depth > t.limits.abi_schema_depth or count.* > t.limits.abi_schema_nodes) return error.InvalidDescriptor;
    const start = bytes.items.len;
    try bytes.appendSlice(a, &.{ @backingInt(node.kind), 0, 0 });
    switch (node.kind) {
        .uint, .int, .fixed_bytes => try bytes.append(a, node.width),
        .fixed_array => {
            var length: [2]u8 = undefined;
            bc.put(&length, node.length);
            try bytes.appendSlice(a, &length);
        },
        else => {},
    }
    for (node.children) |c| try encodeNode(a, c, bytes, depth + 1, count);
    bc.put(bytes.items[start + 1 ..][0..2], bytes.items.len - start - 3);
}
pub fn encodeSchema(a: t.Allocator, root: *Schema) Error![]const u8 {
    _ = try layout(root);
    var bytes: std.ArrayList(u8) = .empty;
    try bytes.append(a, 1);
    var count: usize = 0;
    try encodeNode(a, root, &bytes, 1, &count);
    if (bytes.items.len > t.limits.abi_descriptor_bytes) return error.InvalidDescriptor;
    return bytes.toOwnedSlice(a);
}
fn decodeNode(a: t.Allocator, bytes: []const u8, cursor: *usize, depth: usize, count: *usize) Error!*Schema {
    count.* += 1;
    if (depth > t.limits.abi_schema_depth or count.* > t.limits.abi_schema_nodes or cursor.* + 3 > bytes.len) return error.InvalidDescriptor;
    const kind = std.enums.fromInt(Kind, bytes[cursor.*]) orelse return error.InvalidDescriptor;
    const len: usize = @intCast(bc.word(bytes[cursor.* + 1 ..][0..2]));
    cursor.* += 3;
    const end = cursor.* + len;
    if (end > bytes.len) return error.InvalidDescriptor;
    const node = try create(a, kind);
    switch (kind) {
        .uint, .int, .fixed_bytes => {
            if (len != 1) return error.InvalidDescriptor;
            node.width = bytes[cursor.*];
            if (node.width == 0 or node.width > 32) return error.InvalidDescriptor;
            cursor.* += 1;
        },
        .address, .boolean, .dynamic_bytes => if (len != 0) return error.InvalidDescriptor,
        .tuple => {
            var children: std.ArrayList(*Schema) = .empty;
            while (cursor.* < end) {
                if (children.items.len >= 64) return error.InvalidDescriptor;
                try children.append(a, try decodeNode(a, bytes[0..end], cursor, depth + 1, count));
            }
            node.children = children.items;
        },
        .dynamic_array, .fixed_array => {
            if (kind == .fixed_array) {
                if (len < 2) return error.InvalidDescriptor;
                node.length = @intCast(bc.word(bytes[cursor.*..][0..2]));
                if (node.length == 0 or node.length > t.limits.abi_array_elements) return error.InvalidDescriptor;
                cursor.* += 2;
            }
            node.children = try a.dupe(*Schema, &.{try decodeNode(a, bytes[0..end], cursor, depth + 1, count)});
        },
    }
    if (cursor.* != end) return error.InvalidDescriptor;
    return node;
}
pub fn decodeSchema(a: t.Allocator, bytes: []const u8) Error!*Schema {
    if (bytes.len < 4 or bytes.len > t.limits.abi_descriptor_bytes or bytes[0] != 1) return error.InvalidDescriptor;
    var cursor: usize = 1;
    var count: usize = 0;
    const root = try decodeNode(a, bytes, &cursor, 1, &count);
    if (root.kind != .tuple or cursor != bytes.len) return error.InvalidDescriptor;
    _ = try layout(root);
    return root;
}
fn layout(n: *Schema) Error!struct { dynamic: bool, size: usize } {
    var dynamic = n.kind == .dynamic_array or n.kind == .dynamic_bytes;
    var size: usize = if (n.children.len == 0 and n.kind != .tuple) 32 else 0;
    for (n.children) |c| {
        const child = try layout(c);
        dynamic = dynamic or child.dynamic;
        if (!child.dynamic) size += child.size;
    }
    if (n.kind == .fixed_array) size *= n.length;
    if (size > t.limits.abi_call_bytes - 4) return error.InvalidDescriptor;
    return .{ .dynamic = dynamic, .size = if (dynamic) 0 else size };
}
const Plan = struct { dynamic: bool, words: []const u16 };
const Planner = struct {
    a: t.Allocator,
    validations: []const Validation,
    cursor: usize = 0,
    visits: usize = 0,
    fn consume(p: *Planner, v: Validation) Error!u16 {
        if (p.cursor >= p.validations.len) return error.InvalidDescriptor;
        const actual = p.validations[p.cursor];
        if (v.tag != actual.tag or (v.tag == 0x80 and v.exact != actual.exact)) return error.InvalidDescriptor;
        const i: u16 = @intCast(p.cursor);
        p.cursor += 1;
        return i;
    }
    fn sequence(p: *Planner, items: []const Plan) Error![]const u16 {
        var head: std.ArrayList(u16) = .empty;
        var tail: std.ArrayList(u16) = .empty;
        var size: usize = 0;
        for (items) |item| size += if (item.dynamic) 1 else item.words.len;
        var offset = size * 32;
        for (items) |item| {
            if (item.dynamic) {
                if (offset > 32767) return error.InvalidDescriptor;
                try head.append(p.a, 0x8000 | @as(u16, @intCast(offset)));
                try tail.appendSlice(p.a, item.words);
                offset += item.words.len * 32;
            } else try head.appendSlice(p.a, item.words);
        }
        try head.appendSlice(p.a, tail.items);
        return head.toOwnedSlice(p.a);
    }
    fn node(p: *Planner, n: *Schema) Error!Plan {
        p.visits += 1;
        if (p.visits > t.limits.abi_plan_visits) return error.InvalidDescriptor;
        switch (n.kind) {
            .uint, .int, .address, .boolean, .fixed_bytes => return .{ .dynamic = false, .words = try p.a.dupe(u16, &.{try p.consume(scalarValidation(n))}) },
            .dynamic_bytes => {
                if (p.cursor >= p.validations.len or p.validations[p.cursor].tag != 0x80) return error.InvalidDescriptor;
                const length = p.validations[p.cursor];
                if (length.exact > t.limits.abi_dynamic_bytes) return error.InvalidDescriptor;
                var words: std.ArrayList(u16) = .empty;
                try words.append(p.a, try p.consume(length));
                const count = (@as(usize, length.exact) + 31) / 32;
                for (0..count) |i| {
                    const remainder = length.exact & 31;
                    try words.append(p.a, try p.consume(.{ .tag = if (i + 1 == count and remainder != 0) 0x60 + @as(u8, @intCast(remainder)) else 0 }));
                }
                return .{ .dynamic = true, .words = words.items };
            },
            .tuple, .fixed_array, .dynamic_array => {
                var length: usize = if (n.kind == .tuple) n.children.len else n.length;
                var length_word: ?u16 = null;
                if (n.kind == .dynamic_array) {
                    if (p.cursor >= p.validations.len or p.validations[p.cursor].tag != 0x80) return error.InvalidDescriptor;
                    const v = p.validations[p.cursor];
                    length = v.exact;
                    if (length > t.limits.abi_array_elements) return error.InvalidDescriptor;
                    length_word = try p.consume(v);
                }
                var items: std.ArrayList(Plan) = .empty;
                var dynamic = n.kind == .dynamic_array;
                for (0..length) |i| {
                    const item = try p.node(n.children[if (n.kind == .tuple) i else 0]);
                    dynamic = dynamic or item.dynamic;
                    try items.append(p.a, item);
                }
                const words = try p.sequence(items.items);
                if (length_word) |v| {
                    const out = try p.a.alloc(u16, words.len + 1);
                    out[0] = v;
                    @memcpy(out[1..], words);
                    return .{ .dynamic = dynamic, .words = out };
                }
                return .{ .dynamic = dynamic, .words = words };
            },
        }
    }
};
pub fn precompiled(a: t.Allocator, schema: []const u8, validations: []const Validation) Error![]const u8 {
    const root = try decodeSchema(a, schema);
    var planner: Planner = .{ .a = a, .validations = validations };
    const plan = try planner.node(root);
    if (planner.cursor != validations.len or 4 + plan.words.len * 32 > t.limits.abi_call_bytes) return error.InvalidDescriptor;
    // Version-1 fallback still requires a valid expanded calldata layout.
    if (validations.len > t.limits.abi_tape_words) return error.ResourceLimit;
    var length: usize = 0;
    for (validations) |v| length += if (v.tag == 0x80) @as(usize, 3) else 1;
    const size = 9 + schema.len + length + plan.words.len * 2;
    if (size > t.limits.abi_descriptor_bytes) return error.ResourceLimit;
    const bytes = try a.alloc(u8, size);
    bytes[0] = 2;
    bc.put(bytes[1..3], schema.len);
    bc.put(bytes[3..5], validations.len);
    bc.put(bytes[5..7], plan.words.len);
    bc.put(bytes[7..9], length);
    @memcpy(bytes[9..][0..schema.len], schema);
    var cursor = 9 + schema.len;
    for (validations) |v| {
        bytes[cursor] = v.tag;
        cursor += 1;
        if (v.tag == 0x80) {
            bc.put(bytes[cursor..][0..2], v.exact);
            cursor += 2;
        }
    }
    for (plan.words) |v| {
        bc.put(bytes[cursor..][0..2], v);
        cursor += 2;
    }
    return bytes;
}
pub const Descriptor = struct { root: *Schema, schema: []const u8, validations: []const Validation = &.{} };
/// root and validations use a's arena; schema borrows bytes. Retain both the
/// input bytes and arena. No independent Descriptor.deinit is provided.
pub fn decode(a: t.Allocator, bytes: []const u8) Error!Descriptor {
    if (bytes.len < 4 or bytes.len > t.limits.abi_descriptor_bytes) return error.InvalidDescriptor;
    if (bytes[0] == 1) return .{ .root = try decodeSchema(a, bytes), .schema = bytes };
    if (bytes[0] != 2 or bytes.len < 9) return error.InvalidDescriptor;
    const schema_len: usize = @intCast(bc.word(bytes[1..3]));
    const tape: usize = @intCast(bc.word(bytes[3..5]));
    const output: usize = @intCast(bc.word(bytes[5..7]));
    const vlen: usize = @intCast(bc.word(bytes[7..9]));
    if (schema_len < 4 or tape > t.limits.abi_tape_words or 9 + schema_len + vlen + output * 2 != bytes.len) return error.InvalidDescriptor;
    const schema = bytes[9..][0..schema_len];
    const root = try decodeSchema(a, schema);
    var validations: std.ArrayList(Validation) = .empty;
    var pos = 9 + schema_len;
    const end = pos + vlen;
    for (0..tape) |_| {
        if (pos >= end) return error.InvalidDescriptor;
        const tag = bytes[pos];
        pos += 1;
        if (tag > 2 and !(tag > 0x20 and tag < 0x40) and !(tag > 0x40 and tag < 0x60) and !(tag > 0x60 and tag <= 0x80)) return error.InvalidDescriptor;
        var v: Validation = .{ .tag = tag };
        if (tag == 0x80) {
            if (pos + 2 > end) return error.InvalidDescriptor;
            v.exact = @intCast(bc.word(bytes[pos..][0..2]));
            pos += 2;
        }
        try validations.append(a, v);
    }
    if (pos != end) return error.InvalidDescriptor;
    const expected = try precompiled(a, schema, validations.items);
    if (!std.mem.eql(u8, expected, bytes)) return error.InvalidDescriptor;
    return .{ .root = root, .schema = schema, .validations = validations.items };
}

test "ABI integer aliases canonicalize selectors recursively" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { inputs: []const u8, signature: []const u8 }{
        .{ .inputs = "[{\"type\":\"uint\"}]", .signature = "f(uint256)" },
        .{ .inputs = "[{\"type\":\"int[]\"}]", .signature = "f(int256[])" },
        .{ .inputs = "[{\"type\":\"tuple[]\",\"components\":[{\"type\":\"uint[2]\"},{\"type\":\"int\"}]}]", .signature = "f((uint256[2],int256)[])" },
    };
    for (cases) |case| {
        const source = try a.print("{{\"name\":\"f\",\"stateMutability\":\"view\",\"inputs\":{s}}}", .{case.inputs});
        const value = try std.json.parseFromSlice(std.json.Value, a, source, .{});
        const result = try method(a, value.value);
        try std.testing.expectEqualStrings(case.signature, result.signature);
        try std.testing.expectEqual(@as(u32, @intCast(bc.hash(case.signature) >> 224)), result.selector);
    }
}
