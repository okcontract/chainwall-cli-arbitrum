const std = @import("std");
const t = @import("tree.zig");
pub const Error = t.Error;
pub const Op = enum(u8) {
    STOP = 0x00,
    PUSH1 = 0x01,
    PUSH32 = 0x02,
    PUSH8 = 0x03,
    PUSHDATA32 = 0x04,
    ADD = 0x10,
    SUB = 0x11,
    MUL = 0x12,
    DIV = 0x13,
    AND = 0x14,
    OR = 0x15,
    XOR = 0x16,
    NOT = 0x17,
    REQUIRE = 0x18,
    MOD = 0x19,
    RATIO = 0x1a,
    KECCAK = 0x1b,
    SQRT = 0x1c,
    READ = 0x20,
    WRITE = 0x21,
    RESOLVE = 0x22,
    ARG = 0x23,
    CALLER = 0x24,
    TIME = 0x25,
    WRITEV = 0x26,
    READX = 0x27,
    WRITEX = 0x28,
    WRITEVX = 0x29,
    CALLI = 0x2a,
    PRICEUSD = 0x2b,
    NOFAIL = 0x2c,
    THIS = 0x2d,
    BALANCE = 0x2e,
    STATICLINK = 0x2f,
    JUMPI = 0x30,
    JMP = 0x31,
    SUBJECT = 0x32,
    VALUEUSD = 0x33,
    TRANSFER_NATIVE = 0x34,
    READABI = 0x35,
    WRITEABI = 0x36,
    WRITEVABI = 0x37,
    READWORDS = 0x38,
    DUP1 = 0x40,
    DROP = 0x41,
    SWAP1 = 0x42,
    DUP2 = 0x44,
    DUP3 = 0x45,
    DUP4 = 0x46,
    DUP5 = 0x47,
    DUP6 = 0x48,
    DUP7 = 0x49,
    DUP8 = 0x4a,
    PICK3 = 0x4c,
    PICK4 = 0x4d,
    PICK5 = 0x4e,
    PICK6 = 0x4f,
    PICK7 = 0x50,
    PICK8 = 0x51,
    SWAP2 = 0x52,
    SWAP3 = 0x53,
    SWAP4 = 0x54,
    SWAP5 = 0x55,
    SWAP6 = 0x56,
    SWAP7 = 0x57,
    SWAP8 = 0x58,
    EQ = 0x60,
    NEQ = 0x61,
    LT = 0x62,
    GT = 0x63,
    LTE = 0x64,
    GTE = 0x65,
    RETURN = 0xff,
};
pub fn recursive(op: Op) bool {
    return switch (op) {
        .READABI, .WRITEABI, .WRITEVABI, .READWORDS => true,
        else => false,
    };
}
pub fn width(op: Op) usize {
    return switch (op) {
        .PUSH1, .KECCAK => 1,
        .PUSH8 => 8,
        .PUSH32, .PUSHDATA32, .STATICLINK => 32,
        .JUMPI, .JMP => 2,
        .RATIO => 3,
        .VALUEUSD => 36,
        else => 0,
    };
}
pub fn word(bytes: []const u8) u256 {
    var out: u256 = 0;
    for (bytes) |b| out = (out << 8) | b;
    return out;
}
pub fn put(bytes: []u8, value: u256) void {
    var v = value;
    var i = bytes.len;
    while (i > 0) {
        i -= 1;
        bytes[i] = @truncate(v);
        v >>= 8;
    }
}
pub fn hex(a: t.Allocator, bytes: []const u8) Error![]const u8 {
    const out = try a.alloc(u8, 2 + bytes.len * 2);
    @memcpy(out[0..2], "0x");
    const digits = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[2 + 2 * i] = digits[b >> 4];
        out[3 + 2 * i] = digits[b & 15];
    }
    return out;
}
pub fn unhex(a: t.Allocator, text: []const u8) Error![]u8 {
    const s = if (std.mem.startsWith(u8, text, "0x")) text[2..] else text;
    if (s.len % 2 != 0) return error.InvalidBytecode;
    const out = try a.alloc(u8, s.len / 2);
    errdefer a.free(out);
    _ = std.fmt.hexToBytes(out, s) catch return error.InvalidBytecode;
    return out;
}
pub fn hash(bytes: []const u8) u256 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(bytes, &digest, .{});
    return word(&digest);
}
pub fn dup(depth: usize) Error!Op {
    if (depth == 1) return .DUP1;
    if (depth >= 2 and depth <= 8) return @fromBackingInt(@intCast(0x42 + depth));
    return error.StackCapacity;
}
pub fn dupDepth(op: Op) ?usize {
    const v = @backingInt(op);
    return if (op == .DUP1) 1 else if (v >= 0x44 and v <= 0x4a) v - 0x42 else null;
}
pub fn swapDepth(op: Op) ?usize {
    const v = @backingInt(op);
    return if (op == .SWAP1) 1 else if (v >= 0x52 and v <= 0x58) v - 0x50 else null;
}
pub fn pickDepth(op: Op) ?usize {
    const v = @backingInt(op);
    return if (v >= 0x4c and v <= 0x51) v - 0x49 else null;
}
pub const Instruction = struct { op: Op, immediate: []const u8 = &.{}, target: ?usize = null, label: ?usize = null };
pub const Builder = struct {
    a: t.Allocator,
    items: std.ArrayList(Instruction) = .empty,
    next_label: usize = 0,
    pub fn emit(b: *Builder, op: Op, immediate: []const u8) Error!void {
        try b.items.append(b.a, .{ .op = op, .immediate = try b.a.dupe(u8, immediate) });
    }
    pub fn push(b: *Builder, op: Op) Error!void {
        try b.emit(op, &.{});
    }
    pub fn literal(b: *Builder, value: u256, force: ?Op) Error!void {
        const op = force orelse (if (value <= 255) Op.PUSH1 else if (value <= std.math.maxInt(u64)) Op.PUSH8 else Op.PUSH32);
        var bytes: [32]u8 = undefined;
        const slice = bytes[0..width(op)];
        put(slice, value);
        try b.emit(op, slice);
    }
    pub fn label(b: *Builder) usize {
        const id = b.next_label;
        b.next_label += 1;
        return id;
    }
    pub fn mark(b: *Builder, id: usize) Error!void {
        try b.items.append(b.a, .{ .op = .STOP, .label = id });
    }
    pub fn jump(b: *Builder, op: Op, target: usize) Error!void {
        try b.items.append(b.a, .{ .op = op, .target = target });
    }
};
pub fn immediateLength(op: Op, bytes: []const u8) Error!usize {
    if (!recursive(op)) {
        const len = width(op);
        if (bytes.len < len) return error.InvalidBytecode;
        return len;
    }
    if (bytes.len < 39) return error.InvalidBytecode;
    const len: usize = @intCast(word(bytes[0..2]));
    if (len < 4 or len > 1024 or bytes[2] > 1) return error.InvalidDescriptor;
    var start: usize = 39;
    if (op == .READWORDS) {
        if (bytes.len <= start) return error.InvalidBytecode;
        const count = bytes[start];
        start += 1;
        if (count == 0 or count > 8 or bytes.len < start + 2 * @as(usize, count)) return error.InvalidDescriptor;
        var previous: ?u256 = null;
        for (0..count) |_| {
            const v = word(bytes[start..][0..2]);
            if (previous) |p| {
                if (v <= p) return error.InvalidDescriptor;
            }
            previous = v;
            start += 2;
        }
    }
    if (bytes.len < start + len) return error.InvalidBytecode;
    if (bytes[start] != 1 and bytes[start] != 2) return error.InvalidDescriptor;
    return start + len;
}
pub fn validate(op: Op, imm: []const u8) Error!void {
    if (try immediateLength(op, imm) != imm.len) return error.InvalidBytecode;
    if (op == .RATIO) {
        const count = imm[0];
        const mask = word(imm[1..]);
        if (count < 2 or count > 16 or mask == 0 or mask >= (@as(u256, 1) << @intCast(count)) - 1) return error.InvalidBytecode;
    }
    if (op == .STATICLINK and word(imm) == 0) return error.InvalidBytecode;
    if (op == .VALUEUSD and (word(imm[32..]) == 0 or word(imm[32..]) > 172800)) return error.InvalidBytecode;
}
pub fn encode(a: t.Allocator, items: []const Instruction) Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var labels: std.AutoHashMap(usize, usize) = .init(a);
    defer labels.deinit();
    var length: usize = 0;
    for (items) |item| {
        if (item.label) |id| {
            const entry = try labels.getOrPut(id);
            if (entry.found_existing) return error.InvalidBytecode;
            entry.value_ptr.* = length;
        } else {
            if (item.target != null) {
                if (item.op != .JMP and item.op != .JUMPI) return error.InvalidBytecode;
            } else {
                try validate(item.op, item.immediate);
                if (recursive(item.op)) {
                    const len: usize = @intCast(word(item.immediate[0..2]));
                    _ = try @import("abi.zig").decode(arena.allocator(), item.immediate[item.immediate.len - len ..]);
                }
            }
            length += if (item.target != null) 3 else 1 + item.immediate.len;
        }
    }
    const out = try a.alloc(u8, length);
    var pc: usize = 0;
    errdefer a.free(out);
    for (items) |item| {
        if (item.label != null) continue;
        out[pc] = @backingInt(item.op);
        if (item.target) |id| {
            const target = labels.get(id) orelse return error.InvalidBytecode;
            if (target <= pc + 2 or target >= length or target - pc - 2 > 65535) return error.InvalidBytecode;
            put(out[pc + 1 ..][0..2], target - pc - 2);
            pc += 3;
        } else {
            @memcpy(out[pc + 1 ..][0..item.immediate.len], item.immediate);
            pc += 1 + item.immediate.len;
        }
    }
    return out;
}
/// Caller owns the instruction slice; immediates borrow the input bytes.
pub fn decode(a: t.Allocator, bytes: []const u8) Error![]Instruction {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var items: std.ArrayList(Instruction) = .empty;
    errdefer items.deinit(a);
    var starts: std.AutoHashMap(usize, void) = .init(a);
    defer starts.deinit();
    var targets: std.AutoHashMap(usize, void) = .init(a);
    defer targets.deinit();
    var pc: usize = 0;
    while (pc < bytes.len) {
        const op = std.enums.fromInt(Op, bytes[pc]) orelse return error.InvalidBytecode;
        const len = try immediateLength(op, bytes[pc + 1 ..]);
        const imm = bytes[pc + 1 ..][0..len];
        try validate(op, imm);
        if (recursive(op)) {
            const descriptor_len: usize = @intCast(word(imm[0..2]));
            _ = try @import("abi.zig").decode(arena.allocator(), imm[imm.len - descriptor_len ..]);
        }
        try starts.put(pc, {});
        if (op == .JUMPI or op == .JMP) {
            const target = pc + 2 + @as(usize, @intCast(word(imm)));
            if (target <= pc + 2) return error.InvalidBytecode;
            try targets.put(target, {});
        }
        pc += 1 + len;
    }
    var keys = targets.keyIterator();
    while (keys.next()) |target| if (!starts.contains(target.*)) return error.InvalidBytecode;
    pc = 0;
    while (pc < bytes.len) {
        if (targets.contains(pc)) try items.append(a, .{ .op = .STOP, .label = pc });
        const op: Op = @fromBackingInt(@intCast(bytes[pc]));
        const len = try immediateLength(op, bytes[pc + 1 ..]);
        const imm = bytes[pc + 1 ..][0..len];
        try items.append(a, if (op == .JUMPI or op == .JMP) .{ .op = op, .target = pc + 2 + @as(usize, @intCast(word(imm))) } else .{ .op = op, .immediate = imm });
        pc += 1 + len;
    }
    return items.toOwnedSlice(a);
}

test "lossless widths, malformed jumps, and ratio framing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try unhex(a, "0x030000000000000001ff");
    try std.testing.expectEqualSlices(u8, bytes, try encode(a, try decode(a, bytes)));
    try std.testing.expectError(error.InvalidBytecode, decode(a, &.{ 0x30, 0, 0, 0xff }));
    try std.testing.expectError(error.InvalidBytecode, decode(a, &.{ 0x1a, 2, 0, 3, 0xff }));
}
