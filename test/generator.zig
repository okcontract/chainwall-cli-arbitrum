//! Stable xorshift32 grammar generator. PRNG draws and their order are part of
//! the corpus format; changing either intentionally changes the generated corpus.
const std = @import("std");
pub const Generator = struct {
    a: std.mem.Allocator,
    state: u32,
    next_name: usize = 0,
    fn random(g: *Generator, n: usize) usize {
        g.state ^= g.state << 13;
        g.state ^= g.state >> 17;
        g.state ^= g.state << 5;
        return g.state % n;
    }
    fn pick(g: *Generator, choices: []const []const u8) []const u8 {
        return choices[g.random(choices.len)];
    }
    fn leaf(g: *Generator, names: []const []const u8) ![]const u8 {
        return g.pick(try std.mem.concat(g.a, []const u8, &.{ &.{ "0", "1", "2", "3", "$arg0", "$arg1", "$arg2", "$time" }, names }));
    }
    fn value(g: *Generator, depth: usize, names: []const []const u8) anyerror![]const u8 {
        if (depth == 0) return g.leaf(names);
        switch (g.random(12)) {
            0 => return g.leaf(names),
            1, 2 => {
                const left = try g.value(depth - 1, names);
                const op = g.pick(&.{ "+", "-", "*", "%" });
                const right = try g.value(depth - 1, names);
                return g.a.print("({s} {s} {s})", .{ left, op, right });
            },
            3 => {
                const left = try g.value(depth - 1, names);
                const right = try g.value(depth - 1, names);
                return g.a.print("$idiv({s}, {s})", .{ left, right });
            },
            4 => {
                const predicate = try g.condition(depth - 1, names);
                const yes = try g.value(depth - 1, names);
                const no = try g.value(depth - 1, names);
                return g.a.print("IF({s}, {s}, {s})", .{ predicate, yes, no });
            },
            5 => {
                const name = try g.a.print("x{d}", .{g.next_name});
                g.next_name += 1;
                const init = try g.value(depth - 1, names);
                const body = try g.value(depth - 1, try std.mem.concat(g.a, []const u8, &.{ names, &.{name} }));
                return g.a.print("{{let {s} = {s}, {s} + {s}}}", .{ name, init, body, name });
            },
            6 => {
                const effect = try g.statement(depth - 1, names);
                const result = try g.value(depth - 1, names);
                return g.a.print("{{{s}, {s}}}", .{ effect, result });
            },
            7 => {
                const left = try g.value(depth - 1, names);
                const op = g.pick(&.{ "*", "/" });
                const right = try g.value(depth - 1, names);
                return g.a.print("$floor({s} {s} {s})", .{ left, op, right });
            },
            8 => return g.a.print("$read({s}, 1)", .{g.pick(try std.mem.concat(g.a, []const u8, &.{ &.{ "10", "20" }, names }))}),
            9 => {
                const arg = try g.leaf(names);
                const amount = try g.value(depth - 1, names);
                return g.a.print("$write(50, 1, {{{s}}}, {s})", .{ arg, amount });
            },
            10 => return g.a.print("$sqrt({s})", .{try g.value(depth - 1, names)}),
            else => {
                const x = try g.value(depth - 1, names);
                const y = try g.value(depth - 1, names);
                const z = try g.value(depth - 1, names);
                return g.a.print("$floor({s} / ({s} / {s}))", .{ x, y, z });
            },
        }
    }
    fn statement(g: *Generator, depth: usize, names: []const []const u8) anyerror![]const u8 {
        if (depth == 0) return g.pick(&.{ "$require($arg0 > 0)", "{let discarded = $write(50, 1)}", "{let discarded = $read(20, 1)}", "{let unused = $arg1}" });
        switch (g.random(4)) {
            0 => return g.a.print("{{let discarded = {s}}}", .{try g.value(depth, names)}),
            1 => {
                const predicate = try g.condition(depth - 1, names);
                const yes = if (g.random(3) != 0) try g.statement(depth - 1, names) else "$noOp";
                const no = try g.statement(depth - 1, names);
                return g.a.print("IF({s}, {s}, {s})", .{ predicate, yes, no });
            },
            2 => return g.a.print("$require({s} > 0)", .{try g.value(depth - 1, names)}),
            else => {
                const name = try g.a.print("s{d}", .{g.next_name});
                g.next_name += 1;
                const init = try g.value(depth - 1, names);
                const body = try g.statement(depth - 1, try std.mem.concat(g.a, []const u8, &.{ names, &.{name} }));
                return g.a.print("{{let {s} = {s}, {s}}}", .{ name, init, body });
            },
        }
    }
    fn condition(g: *Generator, depth: usize, names: []const []const u8) anyerror![]const u8 {
        if (depth == 0 or g.random(3) == 0) {
            const left = try g.value(depth, names);
            const op = g.pick(&.{ ">", "==", "!=", "<", "<=", ">=" });
            const right = try g.value(depth, names);
            return g.a.print("({s} {s} {s})", .{ left, op, right });
        }
        const left = try g.condition(depth - 1, names);
        const op = g.pick(&.{ "&&", "||" });
        const right = try g.condition(depth - 1, names);
        return g.a.print("({s} {s} {s})", .{ left, op, right });
    }
    pub fn program(g: *Generator, index: usize) ![]const u8 {
        g.next_name = 0;
        return if (index % 4 == 0) g.a.print("{{{s}, 1}}", .{try g.statement(3, &.{})}) else g.value(2 + @as(usize, @intFromBool(index % 3 == 0)), &.{});
    }
};
