const std = @import("std");
const bc = @import("bytecode.zig");
const Error = bc.Error;

/// Lossless text codec. Returned allocations belong to the caller.
pub fn disasm(a: std.mem.Allocator, bytes: []const u8) Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    _ = try bc.decode(temp, bytes);
    var out: std.Io.Writer.Allocating = .init(temp);
    var pc: usize = 0;
    while (pc < bytes.len) {
        const op: bc.Op = @fromBackingInt(@intCast(bytes[pc]));
        const len = try bc.immediateLength(op, bytes[pc + 1 ..]);
        out.writer.print("{s}", .{@tagName(op)}) catch return error.OutOfMemory;
        if (len > 0) out.writer.print(" {s}", .{try bc.hex(temp, bytes[pc + 1 ..][0..len])}) catch return error.OutOfMemory;
        out.writer.writeByte('\n') catch return error.OutOfMemory;
        pc += 1 + len;
    }
    return a.dupe(u8, out.written());
}

pub fn assemble(a: std.mem.Allocator, source: []const u8) Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    var tokens = std.mem.tokenizeAny(u8, source, " \t\r\n");
    var out: std.ArrayList(u8) = .empty;
    while (tokens.next()) |name| {
        const op = std.meta.stringToEnum(bc.Op, name) orelse return error.InvalidBytecode;
        try out.append(temp, @backingInt(op));
        if (bc.width(op) > 0 or bc.recursive(op)) {
            const immediate = try bc.unhex(temp, tokens.next() orelse return error.InvalidBytecode);
            try bc.validate(op, immediate);
            try out.appendSlice(temp, immediate);
        }
    }
    _ = try bc.decode(temp, out.items);
    return a.dupe(u8, out.items);
}
