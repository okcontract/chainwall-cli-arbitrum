const std = @import("std");
const c = @import("common.zig");
const codec = @import("abi_codec.zig");
const ms = @import("miniscript");
const bc = ms.bytecode;
const Op = bc.Op;

pub const Options = struct { read_only: bool = false, linked: bool = false };
const Symbol = struct {
    kind: enum { @"const", arg, resolved, caller, this, time, computed, unknown } = .unknown,
    word: u256 = 0,
    description: []const u8 = "unknown",
    sources: []const u64 = &.{},
    fn constant(value: u256) Symbol {
        return .{ .kind = .@"const", .word = value };
    }
    fn number(s: Symbol) ?u256 {
        return if (s.kind == .@"const") s.word else null;
    }
    fn describe(s: Symbol, a: c.A) ![]const u8 {
        return switch (s.kind) {
            .@"const" => c.hex(a, s.word),
            .arg => a.print("arg[{d}]", .{s.word}),
            .resolved => a.print("resolve({s})", .{try c.hex(a, s.word)}),
            .caller => "CALLER",
            .this => "THIS",
            .time => "TIME",
            else => s.description,
        };
    }
    fn json(s: Symbol, a: c.A) !c.Value {
        return switch (s.kind) {
            .@"const" => c.parse(a, try c.encode(a, .{ .kind = "const", .hex = try c.hex(a, s.word), .args = s.sources })),
            .arg => c.parse(a, try c.encode(a, .{ .kind = "arg", .index = s.word })),
            .resolved => c.parse(a, try c.encode(a, .{ .kind = "resolved", .hash = try c.hex(a, s.word), .args = s.sources })),
            .caller, .this, .time => c.parse(a, try c.encode(a, .{ .kind = @tagName(s.kind), .args = s.sources })),
            else => c.parse(a, try c.encode(a, .{ .kind = @tagName(s.kind), .description = s.description, .args = s.sources })),
        };
    }
};
const Runtime = struct { byteLength: usize, localStaticReferenceCount: usize = 0, calliCount: usize = 0, externalCallCount: usize = 0, noFailCount: usize = 0, staticLinkCount: usize = 0, priceReadCount: usize = 0 };
const State = struct { pc: usize, stack: []const Symbol };
const Reference = struct { hash: []const u8, kind: []const u8, via: std.StringArrayHashMapUnmanaged(void) = .empty };
const Analyzer = struct {
    a: c.A,
    options: Options,
    stack: std.ArrayList(Symbol) = .empty,
    states: std.ArrayList(State) = .empty,
    seen: std.AutoHashMapUnmanaged(u256, void) = .empty,
    issues: std.StringArrayHashMapUnmanaged(void) = .empty,
    readonly: std.StringArrayHashMapUnmanaged(void) = .empty,
    warnings: std.StringArrayHashMapUnmanaged(void) = .empty,
    contracts: std.StringArrayHashMapUnmanaged(Reference) = .empty,
    arguments: std.AutoArrayHashMapUnmanaged(u64, u3) = .empty,
    subjects: std.AutoArrayHashMapUnmanaged(u64, void) = .empty,
    calls: std.ArrayList(c.Value) = .empty,
    terminals: std.ArrayList(c.Value) = .empty,
    halted: bool = false,
    steps: usize = 0,

    fn issue(s: *Analyzer, message: []const u8) !void {
        try s.issues.put(s.a, message, {});
    }
    fn fail(s: *Analyzer, message: []const u8) !void {
        try s.issue(message);
        s.halted = true;
    }
    fn push(s: *Analyzer, value: Symbol) !void {
        if (s.stack.items.len >= ms.limits.stack_words) return s.fail("Analysis stack limit exceeded.");
        try s.stack.append(s.a, value);
    }
    fn pop(s: *Analyzer) !Symbol {
        return s.stack.pop() orelse blk: {
            try s.fail("Stack underflow encountered during analysis.");
            break :blk Symbol{ .description = "stack underflow" };
        };
    }
    fn usage(s: *Analyzer, value: Symbol, flag: u3) !void {
        for (value.sources) |index| try s.arguments.put(s.a, index, (s.arguments.get(index) orelse 0) | flag);
    }
    fn unionSources(s: *Analyzer, values: []const Symbol) ![]const u64 {
        var set: std.AutoArrayHashMapUnmanaged(u64, void) = .empty;
        for (values) |value| for (value.sources) |index| {
            try set.put(s.a, index, {});
        };
        const keys = try s.a.dupe(u64, set.keys());
        std.mem.sort(u64, keys, {}, std.sort.asc(u64));
        return keys;
    }
    fn reference(s: *Analyzer, kind: []const u8, hash: u256, via: []const u8) !void {
        const hex = try c.hex(s.a, hash);
        const key = try s.a.print("{s}:{s}", .{ hex, kind });
        const entry = try s.contracts.getOrPut(s.a, key);
        if (!entry.found_existing) entry.value_ptr.* = .{ .kind = kind, .hash = hex };
        try entry.value_ptr.via.put(s.a, via, {});
    }
    fn write(s: *Analyzer, pc: usize, op: Op) !void {
        if (s.options.read_only) try s.readonly.put(s.a, try s.a.print("{s} at pc {d}", .{ @tagName(op), pc }), {});
    }
    fn terminal(s: *Analyzer, kind: []const u8, pc: usize) !void {
        const top = if (s.stack.items.len > 0) s.stack.items[s.stack.items.len - 1] else null;
        if (top) |value| try s.usage(value, 4);
        try s.terminals.append(s.a, try c.parse(s.a, try c.encode(s.a, .{ .kind = kind, .pc = pc, .stackDepth = s.stack.items.len, .result = if (top) |value| try value.json(s.a) else c.Value.null })));
        if (s.options.linked and s.stack.items.len != 1) try s.issue(try s.a.print("Linked MiniScript {s} at pc {d} leaves {d} stack words; expected exactly one.", .{ kind, pc, s.stack.items.len }));
    }
    fn enqueue(s: *Analyzer, pc: usize) !void {
        // Full symbolic state identity retains argument provenance below the
        // visible stack top. Bounds limit both branch explosion and editor work.
        const state = try c.encode(s.a, .{ .pc = pc, .stack = s.stack.items });
        const hash = bc.hash(state);
        if (s.seen.contains(hash)) return;
        if (s.seen.count() >= ms.limits.analysis_states) return s.issue("Analysis state limit exceeded.");
        try s.seen.put(s.a, hash, {});
        try s.states.append(s.a, .{ .pc = pc, .stack = try s.a.dupe(Symbol, s.stack.items) });
    }
    fn computed(s: *Analyzer, description: []const u8, values: []const Symbol) !void {
        const bounded = if (description.len <= ms.limits.analysis_description_bytes) description else try std.mem.concat(s.a, u8, &.{ description[0 .. ms.limits.analysis_description_bytes - 3], "..." });
        try s.push(.{ .kind = .computed, .description = bounded, .sources = try s.unionSources(values) });
    }
    fn binary(s: *Analyzer, op: Op) !void {
        const right = try s.pop();
        const left = try s.pop();
        const sources = try s.unionSources(&.{ left, right });
        const name: []const u8 = switch (op) {
            .ADD => "+",
            .SUB => "-",
            .MUL => "*",
            .DIV => "/",
            .MOD => "%",
            .AND => "&",
            .OR => "|",
            .XOR => "^",
            .EQ => "==",
            .NEQ => "!=",
            .LT => "<",
            .GT => ">",
            .LTE => "<=",
            .GTE => ">=",
            else => unreachable,
        };
        if (left.number()) |x| if (right.number()) |y| {
            const value: u256 = switch (op) {
                .ADD => x +% y,
                .SUB => x -% y,
                .MUL => x *% y,
                .DIV => if (y == 0) 0 else x / y,
                .MOD => if (y == 0) 0 else x % y,
                .AND => x & y,
                .OR => x | y,
                .XOR => x ^ y,
                .EQ => @intFromBool(x == y),
                .NEQ => @intFromBool(x != y),
                .LT => @intFromBool(x < y),
                .GT => @intFromBool(x > y),
                .LTE => @intFromBool(x <= y),
                .GTE => @intFromBool(x >= y),
                else => unreachable,
            };
            return s.push(.{ .kind = .@"const", .word = value, .sources = sources });
        };
        try s.computed(try s.a.print("({s} {s} {s})", .{ try left.describe(s.a), name, try right.describe(s.a) }), &.{ left, right });
    }
    fn scalar(s: *Analyzer, value: Symbol) !c.Value {
        return c.parse(s.a, try c.encode(s.a, .{ .kind = "scalar", .value = try value.json(s.a) }));
    }
    fn call(s: *Analyzer, op: Op) !void {
        const paid = op == .WRITEV or op == .WRITEVX;
        const extended = op == .READX or op == .WRITEX or op == .WRITEVX;
        const value = if (paid) try s.pop() else null;
        if (value) |v| try s.usage(v, 1);
        const kinds = if (extended) try s.pop() else null;
        const count = (try s.pop()).number() orelse return s.fail("Unable to determine number of call arguments.");
        const selector = try s.pop();
        const target = try s.pop();
        if (count > ms.limits.analysis_frame_words) return s.fail("Unable to determine number of call arguments.");
        const mask = if (kinds) |k| k.number() orelse return s.fail("Unable to determine argument kind bitmask.") else 0;
        const args = try s.a.alloc(c.Value, @intCast(count));
        for (0..args.len) |step| {
            const index = if (extended) args.len - 1 - step else step;
            if (index < ms.limits.argument_mask_bits and (mask >> @as(u8, @intCast(index))) & 1 == 1) {
                const length = try s.pop();
                const n = length.number() orelse return s.fail("Dynamic array length encountered; analysis cannot continue.");
                if (n > ms.limits.analysis_frame_words) return s.fail("Array length out of supported bounds.");
                const elements = try s.a.alloc(c.Value, @intCast(n));
                for (0..elements.len) |j| {
                    const v = try s.pop();
                    try s.usage(v, 2);
                    elements[elements.len - 1 - j] = try v.json(s.a);
                }
                try s.usage(length, 2);
                args[index] = try c.parse(s.a, try c.encode(s.a, .{ .kind = "array", .length = try length.json(s.a), .elements = elements }));
            } else {
                const v = try s.pop();
                try s.usage(v, 2);
                args[index] = try s.scalar(v);
            }
        }
        if (target.number()) |hash| try s.reference("target", hash, @tagName(op)) else try s.issue("Dynamic target hash encountered.");
        try s.calls.append(s.a, try c.parse(s.a, try c.encode(s.a, .{ .opcode = @tagName(op), .hash = if (target.number()) |v| try c.hex(s.a, v) else null, .selector = if (selector.number()) |v| try s.a.print("0x{x:0>8}", .{@as(u32, @truncate(v))}) else null, .argKinds = if (kinds) |k| if (k.number()) |n| try c.hex(s.a, n) else null else null, .callValue = if (value) |v| try v.json(s.a) else @as(?c.Value, null), .args = args })));
        try s.push(.{ .description = if (op == .READ or op == .READX) "read result" else "write result" });
    }
    fn recursiveCall(s: *Analyzer, op: Op, immediate: []const u8) !void {
        const value = if (op == .WRITEVABI) try s.pop() else null;
        if (value) |v| try s.usage(v, 1);
        const length = try s.pop();
        var args = std.json.Array.init(s.a);
        if (immediate[2] == 0) {
            const count = length.number() orelse return s.fail("Unable to determine recursive ABI tape length.");
            if (count > 384) return s.fail("Unable to determine recursive ABI tape length.");
            const words = try s.a.alloc(c.Value, @intCast(count));
            for (0..words.len) |i| {
                const v = try s.pop();
                try s.usage(v, 2);
                words[words.len - 1 - i] = try s.scalar(v);
            }
            try args.appendSlice(words);
        } else {
            const start = try s.pop();
            try s.usage(start, 2);
            try s.usage(length, 2);
            try args.append(try s.scalar(start));
            try args.append(try s.scalar(length));
        }
        const size: usize = @intCast(bc.word(immediate[0..2]));
        const descriptor = immediate[immediate.len - size ..];
        const decoded = try ms.abi.decode(s.a, descriptor);
        const stats = schemaStats(decoded.root);
        const target = bc.word(immediate[3..35]);
        try s.reference("target", target, @tagName(op));
        const indices = if (op == .READWORDS) try s.a.alloc(u16, immediate[39]) else null;
        if (indices) |items| for (items, 0..) |*v, i| {
            v.* = @intCast(bc.word(immediate[40 + i * 2 ..][0..2]));
        };
        try s.calls.append(s.a, try c.parse(s.a, try c.encode(s.a, .{ .opcode = @tagName(op), .hash = try c.hex(s.a, target), .selector = try codec.hex(s.a, immediate[35..39]), .callValue = if (value) |v| try v.json(s.a) else @as(?c.Value, null), .args = args.items, .recursiveAbi = .{ .returnWordIndices = indices, .descriptor = try codec.hex(s.a, descriptor), .descriptorHash = try c.hex(s.a, bc.hash(descriptor)), .encoding = if (descriptor[0] == 2) "compiler-planned" else "runtime-shaped", .tapeSource = if (immediate[2] == 0) "evaluated" else "args-slice", .nodeCount = stats.nodes, .depth = stats.depth } })));
        if (indices) |items| {
            for (items) |index| try s.push(.{ .description = try s.a.print("read result word {d}", .{index}) });
        } else try s.push(.{ .description = if (op == .READABI) "read result" else "write result" });
    }
    fn run(s: *Analyzer, bytes: []const u8) !void {
        try s.enqueue(0);
        while (s.states.pop()) |state| {
            s.stack.clearRetainingCapacity();
            try s.stack.appendSlice(s.a, state.stack);
            s.halted = false;
            var pc = state.pc;
            var terminated = false;
            while (pc < bytes.len and !s.halted) {
                s.steps += 1;
                if (s.steps > ms.limits.analysis_steps) return s.issue("Analysis instruction limit exceeded.");
                const op: Op = @fromBackingInt(@intCast(bytes[pc]));
                const width = try bc.immediateLength(op, bytes[pc + 1 ..]);
                const immediate = bytes[pc + 1 ..][0..width];
                const next = pc + 1 + width;
                if (bc.dupDepth(op)) |depth| {
                    if (s.stack.items.len < depth) try s.fail("DUP attempted with insufficient stack.") else try s.push(s.stack.items[s.stack.items.len - depth]);
                } else if (bc.swapDepth(op)) |depth| {
                    if (s.stack.items.len <= depth) try s.fail("SWAP attempted with insufficient stack.") else std.mem.swap(Symbol, &s.stack.items[s.stack.items.len - 1], &s.stack.items[s.stack.items.len - 1 - depth]);
                } else if (bc.pickDepth(op)) |depth| {
                    if (s.stack.items.len < depth) try s.fail("PICK attempted with insufficient stack.") else {
                        const v = s.stack.orderedRemove(s.stack.items.len - depth);
                        try s.push(v);
                    }
                } else switch (op) {
                    .STOP, .RETURN => {
                        try s.terminal(@tagName(op), pc);
                        terminated = true;
                        break;
                    },
                    .PUSH1, .PUSH8, .PUSH32, .PUSHDATA32 => try s.push(Symbol.constant(bc.word(immediate))),
                    .DROP, .REQUIRE => try s.usage(try s.pop(), 4),
                    .ADD, .SUB, .MUL, .DIV, .MOD, .AND, .OR, .XOR, .EQ, .NEQ, .LT, .GT, .LTE, .GTE => try s.binary(op),
                    .SQRT, .NOT => {
                        const v = try s.pop();
                        if (v.number()) |n| try s.push(.{ .kind = .@"const", .word = if (op == .NOT) ~n else sqrt(n), .sources = v.sources }) else try s.computed(try s.a.print("{s}{s}{s}", .{ if (op == .NOT) "~" else "sqrt(", try v.describe(s.a), if (op == .NOT) "" else ")" }), &.{v});
                    },
                    .RATIO, .KECCAK => {
                        const count = immediate[0];
                        const values = try s.a.alloc(Symbol, count);
                        var constant = true;
                        for (0..count) |i| {
                            values[count - 1 - i] = try s.pop();
                            if (values[count - 1 - i].number() == null) constant = false;
                        }
                        if (op == .RATIO) {
                            const mask = bc.word(immediate[1..]);
                            var numerator: u4096 = 1;
                            var denominator: u4096 = 1;
                            for (values, 0..) |v, i| if (v.number()) |n| {
                                if ((mask >> @intCast(i)) & 1 == 1) {
                                    if (n == 0) {
                                        try s.fail("RATIO has a zero denominator or a result larger than uint256.");
                                        break;
                                    }
                                    denominator *= n;
                                } else numerator *= n;
                            };
                            if (!s.halted and constant) {
                                const result = numerator / denominator;
                                if (result > std.math.maxInt(u256)) try s.fail("RATIO has a zero denominator or a result larger than uint256.") else try s.push(.{ .kind = .@"const", .word = @intCast(result), .sources = try s.unionSources(values) });
                            }
                            if (!s.halted and !constant) try s.computed("RATIO", values);
                        } else if (constant) {
                            const data = try s.a.alloc(u8, count * @as(usize, 32));
                            for (values, 0..) |v, i| bc.put(data[i * 32 ..][0..32], v.word);
                            try s.push(.{ .kind = .@"const", .word = bc.hash(data), .sources = try s.unionSources(values) });
                        } else try s.computed("KECCAK", values);
                    },
                    .CALLER => try s.push(.{ .kind = .caller }),
                    .THIS => try s.push(.{ .kind = .this }),
                    .TIME => try s.push(.{ .kind = .time }),
                    .BALANCE => {
                        const v = try s.pop();
                        try s.usage(v, 4);
                        try s.computed(try s.a.print("BALANCE({s})", .{try v.describe(s.a)}), &.{v});
                    },
                    .TRANSFER_NATIVE => {
                        try s.write(pc, op);
                        const value = try s.pop();
                        const recipient = try s.pop();
                        try s.usage(value, 1);
                        try s.usage(recipient, 2);
                        try s.calls.append(s.a, try c.parse(s.a, try c.encode(s.a, .{ .opcode = "TRANSFER_NATIVE", .callValue = try value.json(s.a), .args = .{try s.scalar(recipient)} })));
                        try s.push(.{ .description = "native transfer result" });
                    },
                    .RESOLVE => {
                        const v = try s.pop();
                        if (v.number()) |hash| {
                            try s.reference("resolve", hash, "RESOLVE");
                            try s.push(.{ .kind = .resolved, .word = hash, .sources = v.sources });
                        } else {
                            try s.issue(try s.a.print("Dynamic RESOLVE hash at pc {d}.", .{pc}));
                            try s.push(.{ .description = "resolved address", .sources = v.sources });
                        }
                    },
                    .ARG => {
                        const v = try s.pop();
                        if (v.number()) |index| {
                            if (index > 9007199254740991) try s.fail("ARG index exceeds the analysis range.") else try s.push(.{ .kind = .arg, .word = index, .sources = try s.a.dupe(u64, &.{@intCast(index)}) });
                        } else {
                            try s.issue(try s.a.print("Dynamic ARG index at pc {d}.", .{pc}));
                            try s.push(.{ .description = "arg", .sources = v.sources });
                        }
                    },
                    .READ, .WRITE, .WRITEV, .READX, .WRITEX, .WRITEVX => {
                        if (op != .READ and op != .READX) try s.write(pc, op);
                        try s.call(op);
                    },
                    .READABI, .WRITEABI, .WRITEVABI, .READWORDS => {
                        if (op != .READABI and op != .READWORDS) try s.write(pc, op);
                        try s.recursiveCall(op, immediate);
                    },
                    .NOFAIL => {},
                    .PRICEUSD => {
                        const age = try s.pop();
                        const decimals = try s.pop();
                        const hash = try s.pop();
                        try s.usage(age, 4);
                        try s.usage(decimals, 4);
                        if (hash.number()) |n| try s.reference("target", n, "PRICEUSD");
                        try s.computed("PRICEUSD", &.{ hash, decimals, age });
                    },
                    .STATICLINK => try s.push(.{ .description = try s.a.print("STATICLINK({s})", .{try c.hex(s.a, bc.word(immediate))}) }),
                    .SUBJECT => {
                        const v = try s.pop();
                        const n = v.number();
                        if (n != null and n.? <= 9007199254740991) try s.subjects.put(s.a, @intCast(n.?), {}) else try s.issue(try s.a.print("Dynamic or invalid SUBJECT selector at pc {d}.", .{pc}));
                        try s.push(.{ .description = try s.a.print("SUBJECT({s})", .{if (n) |v_| try s.a.print("{d}", .{v_}) else "?"}), .sources = v.sources });
                    },
                    .VALUEUSD => {
                        const v = try s.pop();
                        try s.usage(v, 4);
                        try s.push(.{ .description = try s.a.print("VALUEUSD({s},{d})", .{ try c.hex(s.a, bc.word(immediate[0..32])), bc.word(immediate[32..]) }), .sources = v.sources });
                    },
                    .CALLI => {
                        const count_value = try s.pop();
                        const id = try s.pop();
                        const n = count_value.number() orelse {
                            try s.fail("CALLI has non-constant or invalid arg count.");
                            break;
                        };
                        if (n > ms.limits.analysis_frame_words) {
                            try s.fail("CALLI has non-constant or invalid arg count.");
                            break;
                        }
                        var values: std.ArrayList(Symbol) = .empty;
                        try values.appendSlice(s.a, &.{ id, count_value });
                        for (0..@intCast(n)) |_| {
                            const v = try s.pop();
                            try s.usage(v, 2);
                            try values.append(s.a, v);
                        }
                        try s.usage(id, 4);
                        if (id.number() == null) try s.issue(try s.a.print("Dynamic CALLI interaction id at pc {d}.", .{pc}));
                        try s.push(.{ .description = "calli result", .sources = try s.unionSources(values.items) });
                    },
                    .JMP, .JUMPI => {
                        if (op == .JUMPI) try s.usage(try s.pop(), 4);
                        try s.enqueue(pc + 2 + @as(usize, @intCast(bc.word(immediate))));
                        if (op == .JMP) {
                            terminated = true;
                            break;
                        }
                    },
                    else => unreachable,
                }
                pc = next;
            }
            if (!terminated and !s.halted) try s.terminal("EOF", pc);
        }
    }
};
fn sqrt(n: u256) u256 {
    if (n < 2) return n;
    var x: u256 = @as(u256, 1) << @as(u8, @intCast((256 - @clz(n) + 1) / 2));
    while (true) {
        const next = (x + n / x) / 2;
        if (next >= x) return x;
        x = next;
    }
}
fn schemaStats(root: *const ms.abi.Schema) struct { nodes: usize, depth: usize } {
    var result: @TypeOf(schemaStats(root)) = .{ .nodes = 1, .depth = 1 };
    for (root.children) |child| {
        const stats = schemaStats(child);
        result.nodes += stats.nodes;
        result.depth = @max(result.depth, 1 + stats.depth);
    }
    return result;
}
fn hashes(a: c.A, values: []const u256) ![]const []const u8 {
    const out = try a.alloc([]const u8, values.len);
    for (values, out) |n, *text| text.* = try c.hex(a, n);
    return out;
}
fn stringLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Bounded, conservative CFG analysis. A clean report describes local bytecode;
/// it is not permission, execution, or downstream gas simulation.
pub fn analyze(a: c.A, bytes: []const u8, options: Options) !c.Value {
    var s: Analyzer = .{ .a = a, .options = options };
    var runtime: Runtime = .{ .byteLength = bytes.len };
    var refs: ms.references.References = .{};
    if (ms.references.scan(a, bytes)) |found| {
        refs = found;
        runtime.localStaticReferenceCount = refs.raw_count;
        var pc: usize = 0;
        while (pc < bytes.len) {
            const op: Op = @fromBackingInt(@intCast(bytes[pc]));
            if (op == .CALLI) runtime.calliCount += 1;
            if (op == .NOFAIL) runtime.noFailCount += 1;
            if (op == .STATICLINK) runtime.staticLinkCount += 1;
            if (op == .PRICEUSD or op == .VALUEUSD) runtime.priceReadCount += 1;
            if (bc.recursive(op) or op == .READ or op == .READX or op == .WRITE or op == .WRITEV or op == .WRITEX or op == .WRITEVX or op == .TRANSFER_NATIVE) runtime.externalCallCount += 1;
            pc += 1 + try bc.immediateLength(op, bytes[pc + 1 ..]);
        }
        try s.run(bytes);
    } else |err| {
        if (err == error.OutOfMemory) return err;
        try s.issue(try a.print("Structural validation failed: {s}.", .{@errorName(err)}));
    }
    if (options.linked and s.terminals.items.len == 0) try s.issue("Linked MiniScript has no reachable successful terminal path.");
    if (runtime.localStaticReferenceCount >= 96) try s.warnings.put(a, try a.print("Local static references: {d}/128; nested CALLI dependencies share the runtime limit.", .{runtime.localStaticReferenceCount}), {});
    if (runtime.localStaticReferenceCount > ms.limits.static_references) try s.issue("Static reference runtime limit exceeded.");
    if (!refs.complete) try s.issue("Static reference discovery is incomplete.");
    if (runtime.calliCount > 0) try s.warnings.put(a, "CALLI children share the static-reference and maxSteps budgets; their code is not included in this local analysis.", {});
    if (runtime.staticLinkCount > 0) try s.warnings.put(a, "Linked programs require separate analysis and current runtime authorization.", {});
    if (runtime.externalCallCount > 0) try s.warnings.put(a, "External-call scratch space is capped at 16384 bytes; maxSteps counts VM opcodes rather than downstream work.", {});
    if (runtime.noFailCount > 0) try s.warnings.put(a, "NOFAIL suppresses only low-level WRITE transport failures; other VM and malformed-return failures still revert.", {});
    for (s.calls.items) |call_| {
        const opcode = try c.string(c.field(call_, "opcode").?);
        if (c.eq(u8, opcode, "TRANSFER_NATIVE")) try s.warnings.put(a, "TRANSFER_NATIVE calls a raw recipient with empty calldata and full gas. Require its result when failure must reject execution.", {});
        const selector = c.string(c.field(call_, "selector") orelse .null) catch "";
        if (!std.mem.startsWith(u8, opcode, "READ") and c.eq(u8, selector, "0x095ea7b3")) try s.warnings.put(a, "ERC20 allowances are not revoked automatically and may remain after execution.", {});
    }
    var contract_values = std.json.Array.init(a);
    const keys = try a.dupe([]const u8, s.contracts.keys());
    std.mem.sort([]const u8, keys, {}, stringLess);
    for (keys) |key| {
        const ref = s.contracts.get(key).?;
        const via = try a.dupe([]const u8, ref.via.keys());
        std.mem.sort([]const u8, via, {}, stringLess);
        try contract_values.append(try c.parse(a, try c.encode(a, .{ .hash = ref.hash, .kind = ref.kind, .via = via })));
    }
    var args = std.json.Array.init(a);
    const indices = try a.dupe(u64, s.arguments.keys());
    std.mem.sort(u64, indices, {}, std.sort.asc(u64));
    for (indices) |index| {
        const flags = s.arguments.get(index).?;
        var kinds = std.json.Array.init(a);
        for ([_][]const u8{ "call-arg", "call-value", "other" }, [_]u3{ 2, 1, 4 }) |name, flag| if (flags & flag != 0) {
            try kinds.append(.{ .string = name });
        };
        try args.append(try c.parse(a, try c.encode(a, .{ .index = index, .kinds = kinds.items })));
    }
    const subjects = try a.dupe(u64, s.subjects.keys());
    std.mem.sort(u64, subjects, {}, std.sort.asc(u64));
    return c.parse(a, try c.encode(a, .{ .script = try codec.hex(a, bytes), .contracts = contract_values.items, .calls = s.calls.items, .arguments = args.items, .issues = s.issues.keys(), .calliIds = try hashes(a, refs.calli_ids.items), .linkedRelations = try hashes(a, refs.linked_relations.items), .priceAssets = try hashes(a, refs.price_assets.items), .subjectSelectors = subjects, .readOnlyViolations = s.readonly.keys(), .terminals = s.terminals.items, .runtime = runtime, .runtimeWarnings = s.warnings.keys(), .complete = s.issues.count() == 0, .valid = s.issues.count() == 0 and s.readonly.count() == 0 }));
}
