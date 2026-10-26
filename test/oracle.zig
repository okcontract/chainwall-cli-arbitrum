//! Independent, bounded VM model for compiler semantic tests. Opcode values and
//! decoding are intentionally independent of the production decoder and AST.
//! Unsupported instructions fail explicitly; this is not a complete chain VM.
const std = @import("std");
pub const Effect = struct { write: bool, target: u256, selector: u256 };
pub const Result = struct { value: u256, effects: [32]Effect, count: usize };
const Machine = struct {
    code: []const u8,
    pc: usize = 0,
    stack: [256]u256 = undefined,
    height: usize = 0,
    result: Result = .{ .value = 0, .effects = undefined, .count = 0 },
    fn immediate(m: *Machine, n: usize) !u256 {
        if (n > m.code.len - m.pc) return error.TruncatedInstruction;
        var value: u256 = 0;
        for (m.code[m.pc..][0..n]) |byte| value = value * 256 + byte;
        m.pc += n;
        return value;
    }
    fn push(m: *Machine, value: u256) !void {
        if (m.height == m.stack.len) return error.StackOverflow;
        m.stack[m.height] = value;
        m.height += 1;
    }
    fn pop(m: *Machine) !u256 {
        if (m.height == 0) return error.StackUnderflow;
        m.height -= 1;
        return m.stack[m.height];
    }
};
pub fn execute(code: []const u8, args: []const u256) !Result {
    var m: Machine = .{ .code = code };
    var steps: usize = 0;
    while (m.pc < code.len) {
        steps += 1;
        if (steps > 10000) return error.StepLimit;
        const op = code[m.pc];
        m.pc += 1;
        switch (op) {
            0x00, 0xff => break,
            0x01 => try m.push(try m.immediate(1)),
            0x02, 0x04 => try m.push(try m.immediate(32)),
            0x03 => try m.push(try m.immediate(8)),
            0x10...0x16, 0x19, 0x60...0x65 => {
                const right = try m.pop();
                const left = try m.pop();
                try m.push(switch (op) {
                    0x10 => left +% right,
                    0x11 => left -% right,
                    0x12 => left *% right,
                    0x13 => if (right == 0) 0 else left / right,
                    0x14 => left & right,
                    0x15 => left | right,
                    0x16 => left ^ right,
                    0x19 => if (right == 0) 0 else left % right,
                    0x60 => @intFromBool(left == right),
                    0x61 => @intFromBool(left != right),
                    0x62 => @intFromBool(left < right),
                    0x63 => @intFromBool(left > right),
                    0x64 => @intFromBool(left <= right),
                    0x65 => @intFromBool(left >= right),
                    else => unreachable,
                });
            },
            0x17 => try m.push(~try m.pop()),
            0x18 => if (try m.pop() == 0) return error.RequireFailed,
            0x1a => {
                const count: usize = @intCast(try m.immediate(1));
                const mask = try m.immediate(2);
                if (count > m.height) return error.StackUnderflow;
                var numerator: u512 = 1;
                var denominator: u512 = 1;
                for (m.stack[m.height - count .. m.height], 0..) |v, i| {
                    if ((mask >> @intCast(i)) & 1 == 0) numerator = try std.math.mul(u512, numerator, v) else denominator = try std.math.mul(u512, denominator, v);
                }
                if (denominator == 0) return error.DivisionByZero;
                m.height -= count;
                const value = numerator / denominator;
                if (value > std.math.maxInt(u256)) return error.RatioOverflow;
                try m.push(@intCast(value));
            },
            0x20, 0x21 => {
                const count = try m.pop();
                const selector = try m.pop();
                const target = try m.pop();
                if (count > m.height) return error.StackUnderflow;
                m.height -= @intCast(count);
                if (m.result.count == m.result.effects.len) return error.EffectLimit;
                m.result.effects[m.result.count] = .{ .write = op == 0x21, .target = target, .selector = selector };
                m.result.count += 1;
                try m.push(100 + m.result.count);
            },
            // Fixture resolver maps numeric target IDs to the same address.
            0x22 => {},
            0x23 => {
                const index = try m.pop();
                if (index >= args.len) return error.MissingArgument;
                try m.push(args[@intCast(index)]);
            },
            0x30, 0x31 => {
                const distance: usize = @intCast(try m.immediate(2));
                const target = m.pc - 1 + distance;
                if (target >= code.len) return error.InvalidJump;
                if (op == 0x31 or try m.pop() != 0) m.pc = target;
            },
            0x40, 0x44...0x4a => {
                const depth: usize = if (op == 0x40) 1 else op - 0x42;
                if (depth > m.height) return error.StackUnderflow;
                try m.push(m.stack[m.height - depth]);
            },
            0x41 => _ = try m.pop(),
            0x42, 0x52...0x58 => {
                const depth: usize = if (op == 0x42) 1 else op - 0x50;
                if (depth >= m.height) return error.StackUnderflow;
                std.mem.swap(u256, &m.stack[m.height - 1], &m.stack[m.height - 1 - depth]);
            },
            0x4c...0x51 => {
                const depth: usize = op - 0x49;
                if (depth > m.height) return error.StackUnderflow;
                const index = m.height - depth;
                const value = m.stack[index];
                std.mem.copyForwards(u256, m.stack[index .. m.height - 1], m.stack[index + 1 .. m.height]);
                m.stack[m.height - 1] = value;
            },
            else => return error.UnsupportedOracleInstruction,
        }
    }
    if (m.height != 1) return error.InvalidResultStack;
    m.result.value = m.stack[0];
    return m.result;
}

test "oracle rejects unknown instructions rather than silently ignoring them" {
    try std.testing.expectError(error.UnsupportedOracleInstruction, execute(&.{0x05}, &.{}));
    try std.testing.expectError(error.TruncatedInstruction, execute(&.{0x02}, &.{}));
    try std.testing.expectEqual(@as(u256, 3), (try execute(&.{ 1, 1, 1, 2, 0x10, 0xff }, &.{})).value);
}
