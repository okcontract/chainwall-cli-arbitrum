const std = @import("std");
const t = @import("tree.zig");
const bc = @import("bytecode.zig");
const Node = t.Node;
const Error = t.Error;
const Stack = struct {
    values: [16]?u256 = @splat(null),
    len: usize = 0,
    fn push(s: *Stack, value: ?u256) void {
        if (s.len == 16) {
            std.mem.copyForwards(?u256, s.values[0..15], s.values[1..16]);
            s.len -= 1;
        }
        s.values[s.len] = value;
        s.len += 1;
    }
    fn pop(s: *Stack, amount: usize) void {
        s.len -= @min(amount, s.len);
    }
    fn top(s: *Stack) ?u256 {
        return if (s.len == 0) null else s.values[s.len - 1];
    }
    fn count(s: *Stack) ?usize {
        const value = s.top() orelse return null;
        return std.math.cast(usize, value);
    }
    fn external(s: *Stack, op: bc.Op) void {
        const value = op == .WRITEV or op == .WRITEVX;
        const kinds = op == .READX or op == .WRITEX or op == .WRITEVX;
        if (value) s.pop(1);
        const mask = if (kinds) s.top() else @as(?u256, 0);
        if (kinds) s.pop(1);
        const count_ = s.count();
        if (mask == null or count_ == null or count_.? > 1024) {
            s.len = 0;
            s.push(null);
            return;
        }
        s.pop(3);
        var i = count_.?;
        while (i > 0) {
            i -= 1;
            if (i < 256 and (mask.? >> @intCast(i)) & 1 != 0) {
                const len = s.count();
                if (len == null) {
                    s.len = 0;
                    break;
                }
                s.pop(1);
                s.pop(len.?);
            } else s.pop(1);
        }
        s.push(null);
    }
};
fn isPush(op: bc.Op) bool {
    return op == .PUSH1 or op == .PUSH8 or op == .PUSH32;
}
pub fn machine(a: t.Allocator, items: []const bc.Instruction) Error![]bc.Instruction {
    for (items) |item| if (item.label == null and bc.recursive(item.op)) return a.dupe(bc.Instruction, items);
    var declared: std.AutoHashMap(u256, void) = .init(a);
    defer declared.deinit();
    const out = try a.dupe(bc.Instruction, items);
    var stack: Stack = .{};
    for (items, 0..) |item, index| {
        if (item.label != null or item.target != null) {
            stack.len = 0;
            continue;
        }
        const op = item.op;
        if (isPush(op)) {
            const value = bc.word(item.immediate);
            var prev: ?bc.Op = null;
            var next: ?bc.Op = null;
            var after: ?bc.Op = null;
            var i = index;
            while (i > 0) {
                i -= 1;
                if (items[i].label == null) {
                    prev = items[i].op;
                    break;
                }
            }
            i = index + 1;
            while (i < items.len) : (i += 1) {
                if (items[i].label != null) continue;
                if (next == null) next = items[i].op else {
                    after = items[i].op;
                    break;
                }
            }
            const calli = (next != null and isPush(next.?) and after == .CALLI) or (prev != null and isPush(prev.?) and next == .CALLI);
            const first = op == .PUSH32 and !declared.contains(value);
            var depth: ?usize = null;
            if (!calli and !first) for (1..@min(stack.len, 8) + 1) |d| {
                if (stack.values[stack.len - d] != null and stack.values[stack.len - d].? == value) {
                    depth = d;
                    break;
                }
            };
            if (depth) |d| {
                out[index].op = try bc.dup(d);
                out[index].immediate = &.{};
            } else if (op == .PUSH32) try declared.put(value, {});
            stack.push(value);
            continue;
        }
        if (bc.dupDepth(op)) |depth| {
            const v = if (stack.len >= depth) stack.values[stack.len - depth] else null;
            stack.push(v);
            continue;
        }
        if (bc.swapDepth(op)) |depth| {
            if (stack.len > depth) std.mem.swap(?u256, &stack.values[stack.len - 1], &stack.values[stack.len - 1 - depth]) else stack.len = 0;
            continue;
        }
        if (bc.pickDepth(op)) |depth| {
            if (stack.len >= depth) {
                const from = stack.len - depth;
                const v = stack.values[from];
                std.mem.copyForwards(?u256, stack.values[from .. stack.len - 1], stack.values[from + 1 .. stack.len]);
                stack.values[stack.len - 1] = v;
            } else stack.len = 0;
            continue;
        }
        switch (op) {
            .RATIO, .KECCAK => {
                stack.pop(item.immediate[0]);
                stack.push(null);
            },
            .STATICLINK, .CALLER, .THIS, .TIME => stack.push(null),
            .VALUEUSD, .ARG, .SUBJECT, .RESOLVE, .SQRT, .NOT, .BALANCE => {
                stack.pop(1);
                stack.push(null);
            },
            .ADD, .SUB, .MUL, .DIV, .MOD, .AND, .OR, .XOR, .EQ, .NEQ, .LT, .GT, .LTE, .GTE, .TRANSFER_NATIVE => {
                stack.pop(2);
                stack.push(null);
            },
            .REQUIRE, .DROP => stack.pop(1),
            .READ, .WRITE, .WRITEV, .READX, .WRITEX, .WRITEVX => stack.external(op),
            .CALLI => {
                if (stack.count()) |count| {
                    stack.pop(2);
                    stack.pop(count);
                } else stack.len = 0;
                stack.push(null);
            },
            .PRICEUSD => {
                stack.pop(3);
                stack.push(null);
            },
            .NOFAIL, .RETURN, .STOP => {},
            else => stack.len = 0,
        }
    }
    return out;
}
const Candidate = struct { value: u256, count: usize, first: usize, last: usize, name: []const u8 = "" };
const Placement = struct {
    f: *t.Factory,
    candidates: std.ArrayList(Candidate) = .empty,
    occurrence: usize = 0,
    fn skipped(n: *Node, i: usize) bool {
        if (n.tag == .calli and i == 0) return true;
        if (n.tag == .read or n.tag == .write) {
            if (i < 2 and n.abi != null) return true;
            var cursor: usize = 2;
            for (n.args) |arg| {
                if (i >= cursor and i < cursor + arg.count and arg.data) return true;
                cursor += arg.count;
            }
        }
        return false;
    }
    fn collect(p: *Placement, n: *Node) Error!void {
        if (n.tag == .constant and !n.data and n.value > std.math.maxInt(u64)) {
            var found = false;
            for (p.candidates.items) |*c| if (c.value == n.value) {
                c.count += 1;
                c.last = p.occurrence;
                found = true;
                break;
            };
            if (!found) try p.candidates.append(p.f.a, .{ .value = n.value, .count = 1, .first = p.occurrence, .last = p.occurrence });
            p.occurrence += 1;
        }
        for (n.children, 0..) |c, i| if (!skipped(n, i)) {
            try p.collect(c);
        };
    }
    fn replace(p: *Placement, n: *Node, chosen: []const Candidate) Error!*Node {
        if (n.tag == .constant and !n.data) for (chosen) |c| {
            if (n.value == c.value) return p.f.named(.local, c.name, &.{});
        };
        const out = try p.f.clone(n);
        for (out.children, 0..) |*c, i| if (!skipped(n, i)) {
            c.* = try p.replace(c.*, chosen);
        };
        return out;
    }
};
pub fn constants(f: *t.Factory, root: *Node, maximum: usize, last: bool) Error!?*Node {
    var p: Placement = .{ .f = f };
    try p.collect(root);
    var selected: std.ArrayList(Candidate) = .empty;
    for (p.candidates.items) |c| if (c.count > 1) {
        try selected.append(f.a, c);
    };
    if (selected.items.len == 0) return null;
    std.mem.sort(Candidate, selected.items, last, struct {
        fn less(last_: bool, a: Candidate, b: Candidate) bool {
            return if (last_) a.last > b.last else a.first < b.first;
        }
    }.less);
    selected.shrinkRetainingCapacity(@min(maximum, selected.items.len));
    for (selected.items, 0..) |*c, i| c.name = try f.a.print("$__const{d}", .{i});
    var out = try p.replace(root, selected.items);
    var i = selected.items.len;
    while (i > 0) {
        i -= 1;
        const c = selected.items[i];
        out = try f.named(.let, c.name, &.{ try f.num(c.value), out });
    }
    return out;
}
