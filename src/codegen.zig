const std = @import("std");
const t = @import("tree.zig");
const bc = @import("bytecode.zig");
const Node = t.Node;
const Error = t.Error;
const Local = struct { name: []const u8, slot: usize, count: usize };
pub const Generator = struct {
    builder: bc.Builder,
    height: usize = 0,
    locals: std.ArrayList(Local) = .empty,
    fn set(g: *Generator, h: usize) Error!void {
        if (h > 1024) return error.StackCapacity;
        g.height = h;
    }
    fn push(g: *Generator, op: bc.Op) Error!void {
        try g.builder.push(op);
    }
    fn literal(g: *Generator, value: u256, force: ?bc.Op) Error!void {
        try g.builder.literal(value, force);
        try g.set(g.height + 1);
    }
    fn drop(g: *Generator) Error!void {
        if (g.height == 0) return error.StackUnderflow;
        try g.push(.DROP);
        g.height -= 1;
    }
    fn duplicate(g: *Generator, depth: usize) Error!void {
        try g.push(try bc.dup(depth));
        try g.set(g.height + 1);
    }
    fn lookup(g: *Generator, name: []const u8) Error!Local {
        var i = g.locals.items.len;
        while (i > 0) {
            i -= 1;
            const local = g.locals.items[i];
            if (t.same(local.name, name)) return local;
        }
        return error.UnboundVariable;
    }
    fn move(g: *Generator, slots: usize) Error!void {
        if (slots == 0) return;
        if (slots == 1) return g.push(.SWAP1);
        if (slots <= 7) return g.push(@fromBackingInt(@intCast(0x4a + slots)));
        if (slots == 8) {
            try g.push(.PICK8);
            return g.push(.SWAP8);
        }
        return error.StackCapacity;
    }
    fn release(g: *Generator, count: usize, results: usize) Error!void {
        for (0..count) |_| {
            try g.move(results);
            try g.drop();
        }
    }
    fn binary(g: *Generator, op: bc.Op) Error!void {
        if (g.height < 2) return error.StackUnderflow;
        try g.push(op);
        g.height -= 1;
    }
    fn dependency(g: *Generator, n: *Node) Error!void {
        if (n.tag == .constant) try g.literal(n.value, .PUSH32) else try g.emit(n, false, false);
    }
    fn branch(g: *Generator, n: *Node, statement: bool) Error!void {
        const start = g.height;
        try g.emit(n.children[0], false, false);
        if (g.height != start + 1) return error.InvalidType;
        g.height = start;
        const yes = g.builder.label();
        if (n.tag == .noop_then) {
            try g.builder.jump(.JUMPI, yes);
            try g.emit(n.children[1], true, false);
            try g.builder.mark(yes);
            try g.set(start);
            return;
        }
        const end = g.builder.label();
        try g.builder.jump(.JUMPI, yes);
        try g.emit(n.children[2], statement, false);
        const no_height = g.height;
        try g.builder.jump(.JMP, end);
        try g.builder.mark(yes);
        g.height = start;
        try g.emit(n.children[1], statement, false);
        if (no_height != g.height) return error.InvalidType;
        try g.builder.mark(end);
    }
    fn frameSlot(g: *Generator, slots: *usize) Error!void {
        slots.* += 1;
        if (slots.* == 8) {
            try g.move(8);
            slots.* = 0;
        }
    }
    fn call(g: *Generator, n: *Node) Error!void {
        const start = g.height;
        const children = n.children;
        const local_value = n.payable and children[children.len - 1].tag == .local;
        if (n.abi) |abi| {
            if (local_value) try g.emit(children[children.len - 1], false, false);
            var slots: usize = 0;
            var cursor: usize = 2;
            for (n.args) |arg| {
                try g.emit(children[cursor], false, arg.data);
                cursor += 1;
                if (local_value) try g.frameSlot(&slots);
            }
            if (abi.tape_source == 0) {
                try g.literal(n.args.len, null);
                if (local_value) try g.frameSlot(&slots);
            }
            if (local_value) try g.move(slots) else if (n.payable) try g.emit(children[children.len - 1], false, false);
            var immediate: std.ArrayList(u8) = .empty;
            try immediate.resize(g.builder.a, 39 + (if (abi.returns.len == 0) @as(usize, 0) else 1 + 2 * abi.returns.len) + abi.descriptor.len);
            const bytes = immediate.items;
            bc.put(bytes[0..2], abi.descriptor.len);
            bytes[2] = abi.tape_source;
            bc.put(bytes[3..35], abi.target);
            bc.put(bytes[35..39], abi.selector);
            var offset: usize = 39;
            if (abi.returns.len > 0) {
                bytes[offset] = @intCast(abi.returns.len);
                offset += 1;
                for (abi.returns) |index| {
                    bc.put(bytes[offset..][0..2], index);
                    offset += 2;
                }
            }
            @memcpy(bytes[offset..], abi.descriptor);
            const op: bc.Op = if (n.tag == .read) (if (abi.returns.len > 0) .READWORDS else .READABI) else if (n.payable) .WRITEVABI else .WRITEABI;
            try g.builder.emit(op, bytes);
            try g.set(start + (if (abi.returns.len > 0) abi.returns.len else 1));
            return;
        }
        const local_target = children[0].tag == .target and children[0].children[0].tag == .local;
        var kinds: u256 = 0;
        var effects: usize = 0;
        var cursor: usize = 2;
        const starts = try g.builder.a.alloc(usize, n.args.len);
        for (n.args, 0..) |arg, i| {
            starts[i] = cursor;
            if (arg.array) {
                if (i >= 256) return error.InvalidArguments;
                kinds |= @as(u256, 1) << @intCast(i);
            } else if (t.effect(children[cursor])) effects += 1;
            cursor += arg.count;
        }
        const forward = kinds != 0 or effects > 1;
        const moving = local_value or local_target;
        if (local_value) try g.emit(children[children.len - 1], false, false) else if (local_target) try g.emit(children[0].children[0], false, false);
        var slots: usize = 0;
        for (0..n.args.len) |step| {
            const i = if (forward) step else n.args.len - 1 - step;
            const arg = n.args[i];
            for (children[starts[i]..][0..arg.count]) |c| {
                try g.emit(c, false, false);
                if (moving) try g.frameSlot(&slots);
            }
            if (arg.array) {
                try g.literal(arg.count, null);
                if (moving) try g.frameSlot(&slots);
            }
        }
        if (local_target and !local_value) try g.move(slots) else {
            try g.emit(children[0], false, false);
            if (local_value) try g.frameSlot(&slots);
        }
        try g.emit(children[1], false, false);
        if (local_value) try g.frameSlot(&slots);
        try g.literal(n.args.len, null);
        if (local_value) try g.frameSlot(&slots);
        if (forward) {
            try g.literal(kinds, null);
            if (local_value) try g.frameSlot(&slots);
        }
        if (local_value) try g.move(slots) else if (n.payable) try g.emit(children[children.len - 1], false, false);
        try g.push(if (n.tag == .read) (if (forward) bc.Op.READX else .READ) else if (n.payable) (if (forward) bc.Op.WRITEVX else .WRITEV) else if (forward) bc.Op.WRITEX else .WRITE);
        try g.set(start + 1);
    }
    pub fn emit(g: *Generator, n: *Node, statement: bool, data: bool) Error!void {
        const start = g.height;
        const c = n.children;
        switch (n.tag) {
            .unit => {},
            .constant => try g.literal(n.value, if ((data or n.data) and n.value > std.math.maxInt(u64)) bc.Op.PUSHDATA32 else null),
            .arg, .subject => {
                try g.literal(n.value, null);
                try g.push(if (n.tag == .arg) .ARG else .SUBJECT);
            },
            .caller, .this, .time => {
                try g.push(if (n.tag == .caller) .CALLER else if (n.tag == .this) .THIS else .TIME);
                try g.set(start + 1);
            },
            .local => {
                const local = try g.lookup(n.name);
                for (0..local.count) |i| try g.duplicate(g.height - local.slot - i);
            },
            .get_word => {
                const index: usize = @intCast(n.value);
                if (c[0].tag == .local) {
                    const local = try g.lookup(c[0].name);
                    if (index >= local.count) return error.InvalidType;
                    try g.duplicate(g.height - local.slot - index);
                } else {
                    try g.emit(c[0], false, data);
                    if (g.height <= start + index) return error.InvalidType;
                    while (g.height > start + index + 1) try g.drop();
                    try g.release(index, 1);
                }
            },
            .seq => {
                if (c.len == 0) try g.literal(0, null);
                for (c, 0..) |child, i| try g.emit(child, statement or i + 1 < c.len, data);
            },
            .let => {
                try g.emit(c[0], false, data);
                const count = g.height - start;
                try g.locals.append(g.builder.a, .{ .name = n.name, .slot = start, .count = count });
                try g.emit(c[1], statement, data);
                _ = g.locals.pop();
                try g.release(count, g.height - start - count);
            },
            .conditional, .noop_then => try g.branch(n, statement),
            .add, .sub, .mul, .div, .mod, .eq, .neq, .lt, .gt, .lte, .gte => {
                try g.emit(c[0], false, data);
                try g.emit(c[1], false, data);
                const op: bc.Op = switch (n.tag) {
                    .add => .ADD,
                    .sub => .SUB,
                    .mul => .MUL,
                    .div => .DIV,
                    .mod => .MOD,
                    .eq => .EQ,
                    .neq => .NEQ,
                    .lt => .LT,
                    .gt => .GT,
                    .lte => .LTE,
                    .gte => .GTE,
                    else => unreachable,
                };
                try g.binary(op);
            },
            .not, .bitnot, .sqrt, .require, .balance => {
                try g.emit(c[0], false, data);
                if (n.tag == .not) {
                    try g.literal(0, null);
                    try g.binary(.EQ);
                } else {
                    try g.push(switch (n.tag) {
                        .bitnot => .NOT,
                        .sqrt => .SQRT,
                        .require => .REQUIRE,
                        .balance => .BALANCE,
                        else => unreachable,
                    });
                    if (n.tag == .require) {
                        if (g.height == 0) return error.StackUnderflow;
                        g.height -= 1;
                    }
                }
            },
            .target, .resolve => {
                try g.dependency(c[0]);
                if (n.tag == .resolve) try g.push(.RESOLVE);
            },
            .ratio, .keccak => {
                for (c) |child| try g.emit(child, false, data);
                if (n.tag == .ratio) {
                    const imm = [_]u8{ @intCast(c.len), @intCast(n.mask >> 8), @truncate(n.mask) };
                    try g.builder.emit(.RATIO, &imm);
                } else try g.builder.emit(.KECCAK, &.{@intCast(c.len)});
                try g.set(start + 1);
            },
            .read, .write => try g.call(n),
            .calli => {
                for (c[1..]) |child| try g.emit(child, false, data);
                if (c[0].tag != .constant) return error.InvalidArguments;
                try g.literal(c[0].value, .PUSH32);
                try g.literal(c.len - 1, null);
                try g.push(.CALLI);
                try g.set(start + 1);
            },
            .static_linked => {
                var imm: [32]u8 = undefined;
                bc.put(&imm, n.value);
                try g.builder.emit(.STATICLINK, &imm);
                try g.set(start + 1);
            },
            .value_usd => {
                try g.emit(c[0], false, data);
                var imm: [36]u8 = undefined;
                bc.put(imm[0..32], n.value);
                bc.put(imm[32..], std.fmt.parseInt(u32, n.name, 10) catch return error.InvalidConstant);
                try g.builder.emit(.VALUEUSD, &imm);
            },
            .price => {
                try g.dependency(c[0]);
                try g.emit(c[1], false, data);
                try g.emit(c[2], false, data);
                try g.push(.PRICEUSD);
                try g.set(start + 1);
            },
            .transfer_native => {
                try g.emit(c[0], false, data);
                try g.emit(c[1], false, data);
                try g.binary(.TRANSFER_NATIVE);
            },
            else => return error.Unsupported,
        }
        if (statement) {
            while (g.height > start) try g.drop();
        }
    }
    pub fn run(g: *Generator, root: *Node) Error![]bc.Instruction {
        try g.emit(root, false, false);
        if (g.height != 1) return error.InvalidType;
        try g.push(.RETURN);
        return g.builder.items.items;
    }
};
