const std = @import("std");
const t = @import("tree.zig");
const bc = @import("bytecode.zig");
const abi = @import("abi.zig");
const json = @import("json.zig");
const Settings = @import("lower.zig").Settings;
const Error = t.Error;
const Node = t.Node;
const Step = struct { value: *Node, local: ?*Node = null, discard: bool = false, retained: bool = false };
const Region = struct { stack: std.ArrayList(*Node) = .empty, steps: std.ArrayList(Step) = .empty };
pub const Decoder = struct {
    f: *t.Factory,
    bytes: []const u8,
    settings: Settings,
    fn pop(_: *Decoder, region: *Region) Error!*Node {
        return region.stack.pop() orelse error.StackUnderflow;
    }
    fn literal(_: *Decoder, node: *Node, limit: u256) Error!usize {
        if (node.tag != .constant or node.value > limit) return error.InvalidBytecode;
        return @intCast(node.value);
    }
    fn push(d: *Decoder, region: *Region, node: *Node) Error!void {
        if (region.stack.items.len >= t.limits.stack_words) return error.StackCapacity;
        if (t.atomic(node)) return region.stack.append(d.f.a, node);
        const local = try d.f.named(.local, try d.f.fresh("shared"), &.{});
        local.result = t.resultType(node);
        try region.steps.append(d.f.a, .{ .value = node, .local = local });
        try region.stack.append(d.f.a, local);
    }
    fn statement(d: *Decoder, region: *Region, node: *Node) Error!void {
        try region.steps.append(d.f.a, .{ .value = node });
    }
    fn consumedNodes(set: *std.AutoHashMap(*Node, void), node: *Node) Error!void {
        try set.put(node, {});
        for (node.children) |child| try consumedNodes(set, child);
    }
    fn firstDemand(node: *Node, name: []const u8) bool {
        if (node.tag == .local) return t.same(node.name, name);
        const children = if (node.tag == .conditional or node.tag == .noop_then) node.children[0..1] else node.children;
        for (children) |child| {
            if (t.uses(child, name) > 0) return firstDemand(child, name);
            if (t.effect(child)) return false;
        }
        return false;
    }
    fn finish(d: *Decoder, region: *Region, incoming: []const *Node) Error!*Node {
        if (region.stack.items.len < incoming.len or region.stack.items.len > incoming.len + 8) return error.InvalidBytecode;
        for (incoming, region.stack.items[0..incoming.len]) |before, after| if (before != after) return error.InvalidBytecode;
        var consumed = std.AutoHashMap(*Node, void).init(d.f.a);
        for (region.steps.items) |step| if (!step.discard) {
            for (step.value.children) |child| try consumedNodes(&consumed, child);
        };
        var result: ?*Node = if (region.stack.items.len == incoming.len) null else region.stack.items[incoming.len];
        if (region.stack.items.len > incoming.len + 1) {
            const first_word = result.?;
            if (first_word.tag != .get_word) return error.InvalidBytecode;
            for (region.stack.items[incoming.len..], 0..) |word, i| if (word.tag != .get_word or word.value != i or word.children[0] != first_word.children[0]) return error.InvalidBytecode;
            result = first_word.children[0];
        }
        var i = region.steps.items.len;
        while (i > 0) {
            i -= 1;
            const step = region.steps.items[i];
            if (step.discard) {
                if (result == null and (step.retained or !consumed.contains(step.value))) result = step.value;
                continue;
            }
            if (step.local) |local| {
                const count = if (result) |body| t.uses(body, local.name) else 0;
                if (count == 0) {
                    if (t.effect(step.value)) result = if (result) |body| try d.f.node(.seq, &.{ step.value, body }) else step.value;
                } else if (count == 1 and (!t.effect(step.value) or firstDemand(result.?, local.name))) result = try t.replace(d.f, result.?, local.name, step.value) else result = try d.f.named(.let, local.name, &.{ step.value, result.? });
            } else result = if (result) |body| try d.f.node(.seq, &.{ step.value, body }) else step.value;
        }
        return result orelse d.f.node(.unit, &.{});
    }
    fn rawCall(d: *Decoder, region: *Region, op: bc.Op) Error!*Node {
        const payable = op == .WRITEV or op == .WRITEVX;
        const forward = op == .READX or op == .WRITEX or op == .WRITEVX;
        const value = if (payable) try d.pop(region) else null;
        const mask_node = if (forward) try d.pop(region) else null;
        const mask = if (mask_node) |n| blk: {
            if (n.tag != .constant) return error.InvalidBytecode;
            break :blk n.value;
        } else 0;
        const count = try d.literal(try d.pop(region), t.limits.raw_arguments);
        const selector = try d.pop(region);
        const target = try d.pop(region);
        const arguments = try d.f.a.alloc([]*Node, count);
        const groups = try d.f.a.alloc(t.Arg, count);
        for (0..count) |step| {
            const i = if (forward) count - 1 - step else step;
            const array = (mask >> @intCast(i)) & 1 != 0;
            const length = if (array) try d.literal(try d.pop(region), t.limits.raw_array_elements) else 1;
            groups[i] = .{ .count = length, .array = array };
            arguments[i] = try d.f.a.alloc(*Node, length);
            var j = length;
            while (j > 0) {
                j -= 1;
                arguments[i][j] = try d.pop(region);
            }
        }
        var children: std.ArrayList(*Node) = .empty;
        try children.appendSlice(d.f.a, &.{ try d.f.node(.target, &.{target}), selector });
        for (arguments) |arg| try children.appendSlice(d.f.a, arg);
        if (value) |v| try children.append(d.f.a, v);
        const node = try d.f.node(if (op == .READ or op == .READX) .read else .write, children.items);
        node.args = groups;
        node.payable = payable;
        return node;
    }
    fn recursiveCall(d: *Decoder, region: *Region, op: bc.Op, imm: []const u8) Error!*Node {
        const descriptor_len: usize = @intCast(bc.word(imm[0..2]));
        const target = bc.word(imm[3..35]);
        const selector: u32 = @intCast(bc.word(imm[35..39]));
        var offset: usize = 39;
        var returns: []u16 = &.{};
        if (op == .READWORDS) {
            returns = try d.f.a.alloc(u16, imm[offset]);
            offset += 1;
            for (returns) |*index| {
                index.* = @intCast(bc.word(imm[offset..][0..2]));
                offset += 2;
            }
        }
        const descriptor = imm[offset..][0..descriptor_len];
        _ = try abi.decode(d.f.a, descriptor);
        const value = if (op == .WRITEVABI) try d.pop(region) else null;
        var tape: []*Node = undefined;
        if (imm[2] == 1) {
            tape = try d.f.a.alloc(*Node, 2);
            tape[1] = try d.pop(region);
            tape[0] = try d.pop(region);
        } else {
            const length = try d.literal(try d.pop(region), 384);
            tape = try d.f.a.alloc(*Node, length);
            var i = length;
            while (i > 0) {
                i -= 1;
                tape[i] = try d.pop(region);
            }
        }
        var children: std.ArrayList(*Node) = .empty;
        try children.appendSlice(d.f.a, &.{ try d.f.node(.target, &.{try d.f.num(target)}), try d.f.num(selector) });
        try children.appendSlice(d.f.a, tape);
        if (value) |v| try children.append(d.f.a, v);
        const node = try d.f.node(if (op == .READABI or op == .READWORDS) .read else .write, children.items);
        const groups = try d.f.a.alloc(t.Arg, tape.len);
        for (groups) |*group| group.* = .{ .data = imm[2] == 0 };
        node.args = groups;
        node.payable = value != null;
        node.abi = .{ .target = target, .selector = selector, .descriptor = descriptor, .tape_source = imm[2], .returns = returns };
        return node;
    }
    fn segment(d: *Decoder, start: usize, end: usize, incoming: []const *Node, depth: usize) Error!Region {
        if (depth > t.limits.syntax_depth) return error.ResourceLimit;
        var region: Region = .{};
        try region.stack.appendSlice(d.f.a, incoming);
        var pc = start;
        while (pc < end) {
            const op: bc.Op = @fromBackingInt(@intCast(d.bytes[pc]));
            const len = try bc.immediateLength(op, d.bytes[pc + 1 ..]);
            if (pc + 1 + len > end) return error.InvalidBytecode;
            const imm = d.bytes[pc + 1 ..][0..len];
            const next = pc + 1 + len;
            if (bc.dupDepth(op)) |dep| {
                if (region.stack.items.len < dep) return error.StackUnderflow;
                try region.stack.append(d.f.a, region.stack.items[region.stack.items.len - dep]);
                pc = next;
                continue;
            }
            if (bc.swapDepth(op)) |dep| {
                const size = region.stack.items.len;
                if (size <= dep) return error.StackUnderflow;
                std.mem.swap(*Node, &region.stack.items[size - 1], &region.stack.items[size - 1 - dep]);
                pc = next;
                continue;
            }
            if (bc.pickDepth(op)) |dep| {
                if (region.stack.items.len < dep) return error.StackUnderflow;
                const v = region.stack.orderedRemove(region.stack.items.len - dep);
                try region.stack.append(d.f.a, v);
                pc = next;
                continue;
            }
            switch (op) {
                .PUSH1, .PUSH8, .PUSH32, .PUSHDATA32 => try d.push(&region, try d.f.num(bc.word(imm))),
                .DROP => {
                    const dropped = try d.pop(&region);
                    var retained = false;
                    for (region.stack.items) |item| if (item == dropped) {
                        retained = true;
                        break;
                    };
                    try region.steps.append(d.f.a, .{ .value = dropped, .discard = true, .retained = retained });
                },
                .ARG, .SUBJECT => {
                    const index = try d.literal(try d.pop(&region), 9007199254740991);
                    const node = try d.f.node(if (op == .ARG) .arg else .subject, &.{});
                    node.value = index;
                    try d.push(&region, node);
                },
                .CALLER, .THIS, .TIME => try d.push(&region, try d.f.node(if (op == .CALLER) .caller else if (op == .THIS) .this else .time, &.{})),
                .ADD, .SUB, .MUL, .DIV, .MOD, .EQ, .NEQ, .LT, .GT, .LTE, .GTE, .TRANSFER_NATIVE => {
                    const right = try d.pop(&region);
                    const left = try d.pop(&region);
                    const tag: t.Tag = switch (op) {
                        .ADD => .add,
                        .SUB => .sub,
                        .MUL => .mul,
                        .DIV => .div,
                        .MOD => .mod,
                        .EQ => .eq,
                        .NEQ => .neq,
                        .LT => .lt,
                        .GT => .gt,
                        .LTE => .lte,
                        .GTE => .gte,
                        .TRANSFER_NATIVE => .transfer_native,
                        else => unreachable,
                    };
                    try d.push(&region, try d.f.node(tag, &.{ left, right }));
                },
                .NOT, .SQRT, .RESOLVE, .BALANCE => {
                    const tag: t.Tag = switch (op) {
                        .NOT => .bitnot,
                        .SQRT => .sqrt,
                        .RESOLVE => .resolve,
                        .BALANCE => .balance,
                        else => unreachable,
                    };
                    try d.push(&region, try d.f.node(tag, &.{try d.pop(&region)}));
                },
                .REQUIRE => try d.statement(&region, try d.f.node(.require, &.{try d.pop(&region)})),
                .RATIO, .KECCAK => {
                    const children = try d.f.a.alloc(*Node, imm[0]);
                    var i = children.len;
                    while (i > 0) {
                        i -= 1;
                        children[i] = try d.pop(&region);
                    }
                    const node = try d.f.node(if (op == .RATIO) .ratio else .keccak, children);
                    if (op == .RATIO) node.mask = @intCast(bc.word(imm[1..]));
                    try d.push(&region, node);
                },
                .STATICLINK => {
                    const node = try d.f.node(.static_linked, &.{});
                    node.value = bc.word(imm);
                    try d.push(&region, node);
                },
                .VALUEUSD => {
                    const node = try d.f.node(.value_usd, &.{try d.pop(&region)});
                    node.value = bc.word(imm[0..32]);
                    node.name = try d.f.a.print("{d}", .{bc.word(imm[32..])});
                    try d.push(&region, node);
                },
                .PRICEUSD => {
                    const age = try d.pop(&region);
                    const decimals = try d.pop(&region);
                    const token = try d.pop(&region);
                    try d.push(&region, try d.f.node(.price, &.{ token, decimals, age }));
                },
                .READ, .READX, .WRITE, .WRITEV, .WRITEX, .WRITEVX => try d.push(&region, try d.rawCall(&region, op)),
                .READABI, .WRITEABI, .WRITEVABI, .READWORDS => {
                    const node = try d.recursiveCall(&region, op, imm);
                    try d.push(&region, node);
                    if (op == .READWORDS) {
                        const local = try d.pop(&region);
                        for (0..node.abi.?.returns.len) |i| {
                            const word = try d.f.node(.get_word, &.{local});
                            word.value = i;
                            try region.stack.append(d.f.a, word);
                        }
                    }
                },
                .CALLI => {
                    const count = try d.literal(try d.pop(&region), t.limits.calli_arguments);
                    const id = try d.pop(&region);
                    const children = try d.f.a.alloc(*Node, count + 1);
                    children[0] = id;
                    var i = count;
                    while (i > 0) {
                        children[i] = try d.pop(&region);
                        i -= 1;
                    }
                    try d.push(&region, try d.f.node(.calli, children));
                },
                .JUMPI => {
                    const condition = try d.pop(&region);
                    const base = try d.f.a.dupe(*Node, region.stack.items);
                    const yes_start = pc + 2 + @as(usize, @intCast(bc.word(imm)));
                    if (yes_start > end or yes_start < next) return error.InvalidBytecode;
                    // A full IF has an unconditional jump immediately before its
                    // then label. Nested branch jumps are inside that interval.
                    var cursor = next;
                    var last: ?usize = null;
                    while (cursor < yes_start) {
                        last = cursor;
                        const inner: bc.Op = @fromBackingInt(@intCast(d.bytes[cursor]));
                        cursor += 1 + try bc.immediateLength(inner, d.bytes[cursor + 1 ..]);
                    }
                    if (cursor != yes_start) return error.InvalidBytecode;
                    if (last != null and d.bytes[last.?] == @backingInt(bc.Op.JMP)) {
                        const jump = last.?;
                        const branch_end = jump + 2 + @as(usize, @intCast(bc.word(d.bytes[jump + 1 ..][0..2])));
                        if (branch_end < yes_start or branch_end > end) return error.InvalidBytecode;
                        var no = try d.segment(next, jump, base, depth + 1);
                        var yes = try d.segment(yes_start, branch_end, base, depth + 1);
                        const node = try d.f.node(.conditional, &.{ condition, try d.finish(&yes, base), try d.finish(&no, base) });
                        if (yes.stack.items.len != no.stack.items.len) return error.InvalidBytecode;
                        if (yes.stack.items.len > base.len) {
                            try d.push(&region, node);
                            const count = yes.stack.items.len - base.len;
                            if (count > 1) {
                                const local = try d.pop(&region);
                                for (0..count) |i| {
                                    const word = try d.f.node(.get_word, &.{local});
                                    word.value = i;
                                    try region.stack.append(d.f.a, word);
                                }
                            }
                        } else try d.statement(&region, node);
                        pc = branch_end;
                        continue;
                    } else {
                        var no = try d.segment(next, yes_start, base, depth + 1);
                        const body = try d.finish(&no, base);
                        if (no.stack.items.len != base.len) return error.InvalidBytecode;
                        try d.statement(&region, try d.f.node(.noop_then, &.{ condition, body }));
                        pc = yes_start;
                        continue;
                    }
                },
                .STOP, .RETURN => {
                    if (next != end) return error.Unsupported;
                },
                else => return error.Unsupported,
            }
            pc = next;
        }
        return region;
    }
    pub fn run(d: *Decoder) Error!*Node {
        _ = try bc.decode(d.f.a, d.bytes);
        if (d.bytes.len == 0 or (d.bytes[d.bytes.len - 1] != 0xff and d.bytes[d.bytes.len - 1] != 0)) return error.InvalidBytecode;
        var region = try d.segment(0, d.bytes.len, &.{}, 0);
        if (region.stack.items.len != 1) return error.InvalidBytecode;
        return d.finish(&region, &.{});
    }
};
pub const Printer = struct {
    f: *t.Factory,
    settings: Settings,
    out: std.Io.Writer.Allocating,
    fn write(p: *Printer, text: []const u8) Error!void {
        p.out.writer.writeAll(text) catch return error.OutOfMemory;
    }
    fn number(p: *Printer, value: u256) Error!void {
        if (value > std.math.maxInt(u64)) p.out.writer.print("0x{x:0>64}", .{value}) catch return error.OutOfMemory else p.out.writer.print("{d}", .{value}) catch return error.OutOfMemory;
    }
    fn list(p: *Printer, nodes: []const *Node, open: []const u8, close: []const u8) Error!void {
        try p.write(open);
        for (nodes, 0..) |n, i| {
            if (i > 0) try p.write(", ");
            try p.node(n);
        }
        try p.write(close);
    }
    fn call(p: *Printer, name: []const u8, nodes: []const *Node) Error!void {
        try p.write(name);
        try p.list(nodes, "(", ")");
    }
    fn dataValue(p: *Printer, schema: *abi.Schema, tape: []const *Node, cursor: *usize) Error!void {
        switch (schema.kind) {
            .tuple, .fixed_array, .dynamic_array => {
                var length: usize = if (schema.kind == .tuple) schema.children.len else schema.length;
                if (schema.kind == .dynamic_array) {
                    if (cursor.* >= tape.len or tape[cursor.*].tag != .constant or tape[cursor.*].value > t.limits.abi_array_elements) return error.Unsupported;
                    length = @intCast(tape[cursor.*].value);
                    cursor.* += 1;
                }
                try p.write(if (schema.kind == .tuple) "{" else "[");
                for (0..length) |i| {
                    if (i > 0) try p.write(", ");
                    try p.dataValue(schema.children[if (schema.kind == .tuple) i else 0], tape, cursor);
                }
                try p.write(if (schema.kind == .tuple) "}" else "]");
            },
            .dynamic_bytes => {
                if (cursor.* >= tape.len or tape[cursor.*].tag != .constant or tape[cursor.*].value > t.limits.abi_dynamic_bytes) return error.Unsupported;
                const length: usize = @intCast(tape[cursor.*].value);
                cursor.* += 1;
                const words = (length + 31) / 32;
                const bytes = try p.f.a.alloc(u8, words * 32);
                for (0..words) |i| {
                    if (cursor.* >= tape.len or tape[cursor.*].tag != .constant) return error.Unsupported;
                    bc.put(bytes[i * 32 ..][0..32], tape[cursor.*].value);
                    cursor.* += 1;
                }
                const text = if (schema.string) bytes[0..length] else try bc.hex(p.f.a, bytes[0..length]);
                try p.write(std.json.Stringify.valueAlloc(p.f.a, text, .{}) catch return error.OutOfMemory);
            },
            else => {
                if (cursor.* >= tape.len) return error.InvalidBytecode;
                const value = tape[cursor.*];
                cursor.* += 1;
                if (schema.kind == .fixed_bytes and value.tag == .constant) {
                    var word: [32]u8 = undefined;
                    bc.put(&word, value.value);
                    try p.write("\"");
                    try p.write(try bc.hex(p.f.a, word[0..schema.width]));
                    try p.write("\"");
                } else try p.node(value);
            },
        }
    }
    fn ioCall(p: *Printer, n: *Node) Error!void {
        const recursive = n.abi;
        const read_words = recursive != null and recursive.?.returns.len > 0;
        try p.write(if (n.tag == .write) "$write(" else if (read_words) "$readWords(" else "$read(");
        try p.node(n.children[0]);
        try p.write(", ");
        try p.node(n.children[1]);
        if (recursive == null and n.args.len == 0 and !n.payable) return p.write(")");
        try p.write(", ");
        if (recursive) |meta| {
            if (meta.tape_source == 1) try p.call("$abiArgs", n.children[2..4]) else {
                const descriptor = try abi.decode(p.f.a, meta.descriptor);
                var root = descriptor.root;
                if (p.settings.abiFunctionsByCallKey) |methods| {
                    if (json.field(methods, try abi.key(p.f.a, meta.target, meta.selector))) |method_json| {
                        const method = try abi.method(p.f.a, method_json);
                        if (!std.mem.eql(u8, method.descriptor, descriptor.schema)) return error.InvalidSettings;
                        root = method.root;
                    }
                }
                var cursor: usize = 0;
                try p.dataValue(root, n.children[2..][0..n.args.len], &cursor);
                if (cursor != n.args.len) return error.InvalidBytecode;
            }
            if (read_words) {
                try p.write(", [");
                for (meta.returns, 0..) |index, i| {
                    if (i > 0) try p.write(", ");
                    try p.number(index);
                }
                try p.write("]");
            }
        } else {
            try p.write("{");
            var cursor: usize = 2;
            for (n.args, 0..) |arg, i| {
                if (i > 0) try p.write(", ");
                if (arg.array) try p.list(n.children[cursor..][0..arg.count], "[", "]") else try p.node(n.children[cursor]);
                cursor += arg.count;
            }
            try p.write("}");
        }
        if (n.payable) {
            try p.write(", ");
            try p.node(n.children[n.children.len - 1]);
        }
        try p.write(")");
    }
    pub fn node(p: *Printer, n: *Node) Error!void {
        const c = n.children;
        switch (n.tag) {
            .constant => if (n.name.len > 0) try p.write(n.name) else try p.number(n.value),
            .local => try p.write(n.name),
            .arg => {
                try p.write("$arg");
                try p.number(n.value);
            },
            .subject => {
                const names = [_][]const u8{ "$subjectVersion", "$subjectId", "$subjectNativeValue", "$subjectActor", "$subjectVault", "$subjectArgCount", "$subjectPolicy" };
                if (n.value < 7) try p.write(names[@intCast(n.value)]) else if (p.settings.argumentContext == .subject) {
                    try p.write("$arg");
                    try p.number(n.value - 7);
                } else {
                    try p.write("$subjectArg(");
                    try p.number(n.value - 7);
                    try p.write(")");
                }
            },
            .unit => try p.write("{let unused = 0}"),
            .caller => try p.write("$self"),
            .this => try p.write("$this"),
            .time => try p.write("$time"),
            .let => {
                try p.write("{let ");
                try p.write(n.name);
                try p.write(" = ");
                try p.node(c[0]);
                try p.write(", ");
                try p.node(c[1]);
                try p.write("}");
            },
            .seq => try p.list(c, "{", "}"),
            .conditional => {
                try p.write("IF(");
                try p.node(c[0]);
                for (c[1..]) |branch| {
                    try p.write(", ");
                    try p.node(branch);
                }
                try p.write(")");
            },
            .noop_then => {
                try p.write("IF(");
                try p.node(c[0]);
                try p.write(", $noOp, ");
                try p.node(c[1]);
                try p.write(")");
            },
            .get_word => {
                try p.write("(");
                try p.node(c[0]);
                try p.write(")[");
                try p.number(n.value);
                try p.write("]");
            },
            .target => try p.node(c[0]),
            .add, .sub, .mul, .mod, .eq, .neq, .lt, .gt, .lte, .gte => {
                const op = switch (n.tag) {
                    .add => " + ",
                    .sub => " - ",
                    .mul => " * ",
                    .mod => " % ",
                    .eq => " == ",
                    .neq => " != ",
                    .lt => " < ",
                    .gt => " > ",
                    .lte => " <= ",
                    .gte => " >= ",
                    else => unreachable,
                };
                try p.write("(");
                try p.node(c[0]);
                try p.write(op);
                try p.node(c[1]);
                try p.write(")");
            },
            .div => try p.call("$idiv", c),
            .sqrt => try p.call("$sqrt", c),
            .bitnot => try p.call("$bitnot", c),
            .require => try p.call("$require", c),
            .balance => try p.call("$balance", c),
            .resolve => try p.call("$address", c),
            .price => try p.call("$price", c),
            .transfer_native => try p.call("$transferNative", c),
            .keccak => try p.call("$keccak", c),
            .ratio => {
                try p.write("$floor(");
                if (n.mask & 1 != 0) try p.write("1");
                for (c, 0..) |factor, i| {
                    const denominator = n.mask & (@as(u16, 1) << @intCast(i)) != 0;
                    if (i > 0 or denominator) try p.write(if (denominator) " / " else " * ");
                    // A ratio factor is already one wrapping word. A sequence
                    // prevents the source parser flattening its multiplication.
                    try p.write("{");
                    try p.node(factor);
                    try p.write("}");
                }
                try p.write(")");
            },
            .read, .write => try p.ioCall(n),
            .calli => {
                try p.write("$calli(");
                try p.node(c[0]);
                if (c.len == 1) return p.write(")");
                try p.write(", ");
                try p.list(c[1..], "{", "}");
                try p.write(")");
            },
            .static_linked => {
                try p.write("$staticLinked(");
                try p.number(n.value);
                try p.write(")");
            },
            .value_usd => {
                try p.write("$valueUsd(");
                try p.number(n.value);
                try p.write(", ");
                try p.node(c[0]);
                try p.write(", ");
                try p.write(n.name);
                try p.write(")");
            },
            else => return error.Unsupported,
        }
    }
};

// VM words erase Boolean literals, and statement branches may discard a
// value. Restore source types without changing the branch or stack encoding.
const SourceTypes = struct {
    f: *t.Factory,
    booleans: std.StringHashMap(void),
    fn isUnit(n: *Node) bool {
        return switch (n.tag) {
            .unit, .require => true,
            .let => isUnit(n.children[1]),
            .seq => n.children.len == 0 or isUnit(n.children[n.children.len - 1]),
            .conditional => isUnit(n.children[1]) or isUnit(n.children[2]),
            .noop_then => isUnit(n.children[1]),
            else => false,
        };
    }
    fn hasValue(n: *Node) bool {
        if (isUnit(n)) return false;
        return switch (n.tag) {
            .noop_then => false,
            .conditional => hasValue(n.children[1]) and hasValue(n.children[2]),
            .let => hasValue(n.children[1]),
            .seq => n.children.len > 0 and hasValue(n.children[n.children.len - 1]),
            else => true,
        };
    }
    fn statement(s: *SourceTypes, n: *Node) Error!*Node {
        if (isUnit(n)) return n;
        if (!hasValue(n)) switch (n.tag) {
            .conditional, .noop_then => {
                for (n.children[1..]) |*branch| branch.* = try s.statement(branch.*);
                return n;
            },
            .let, .seq => {
                const last = &n.children[n.children.len - 1];
                last.* = try s.statement(last.*);
                return n;
            },
            else => {},
        };
        return s.f.named(.let, try s.f.fresh("unused"), &.{ n, try s.f.node(.unit, &.{}) });
    }
    fn boolean(s: *SourceTypes, n: *Node) bool {
        return switch (n.tag) {
            .constant => n.name.len > 0,
            .local => s.booleans.contains(n.name),
            .eq, .neq, .lt, .gt, .lte, .gte => true,
            .let => s.boolean(n.children[1]),
            .seq => n.children.len > 0 and s.boolean(n.children[n.children.len - 1]),
            .conditional => s.boolean(n.children[1]) and s.boolean(n.children[2]),
            else => false,
        };
    }
    fn literal(s: *SourceTypes, n: *Node) Error!*Node {
        if (n.tag != .constant or n.value > 1) return n;
        const copy = try s.f.clone(n);
        copy.name = if (n.value == 0) "false" else "true";
        return copy;
    }
    fn visit(s: *SourceTypes, n: *Node) Error!void {
        if (n.tag == .let) {
            try s.visit(n.children[0]);
            if (s.boolean(n.children[0])) try s.booleans.put(n.name, {});
            return s.visit(n.children[1]);
        }
        for (n.children) |child| try s.visit(child);
        if (n.tag == .require or n.tag == .conditional or n.tag == .noop_then) n.children[0] = try s.literal(n.children[0]);
        if (n.tag == .conditional) {
            const yes = n.children[1];
            const no = n.children[2];
            if (isUnit(yes) or isUnit(no)) {
                n.children[1] = try s.statement(yes);
                n.children[2] = try s.statement(no);
            } else {
                if (s.boolean(no)) n.children[1] = try s.literal(yes);
                if (s.boolean(yes)) n.children[2] = try s.literal(no);
            }
        } else if (n.tag == .eq or n.tag == .neq) {
            const left = s.boolean(n.children[0]);
            const right = s.boolean(n.children[1]);
            if (right) n.children[0] = try s.literal(n.children[0]);
            if (left) n.children[1] = try s.literal(n.children[1]);
        }
    }
};
pub fn decompile(a: t.Allocator, bytes: []const u8, settings: Settings) Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var f: t.Factory = .{ .a = arena.allocator() };
    const normalized_settings = try json.normalize(f.a, settings);
    var decoder: Decoder = .{ .f = &f, .bytes = bytes, .settings = normalized_settings };
    const root = try decoder.run();
    try @import("validate.zig").boundedDepth(root, 0);
    var source_types: SourceTypes = .{ .f = &f, .booleans = .init(f.a) };
    try source_types.visit(root);
    var printer: Printer = .{ .f = &f, .settings = normalized_settings, .out = .init(f.a) };
    try printer.node(root);
    return a.dupe(u8, printer.out.written());
}
