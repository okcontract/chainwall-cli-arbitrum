const std = @import("std");
const t = @import("tree.zig");
const Node = t.Node;
const Error = t.Error;
fn paths(n: *Node, name: []const u8, minimum: bool) usize {
    if (n.tag == .local) return @intFromBool(t.same(n.name, name));
    if (n.tag == .let) return paths(n.children[0], name, minimum) + (if (t.same(n.name, name)) @as(usize, 0) else paths(n.children[1], name, minimum));
    if (n.tag == .conditional) {
        const a = paths(n.children[1], name, minimum);
        const b = paths(n.children[2], name, minimum);
        return paths(n.children[0], name, minimum) + (if (minimum) @min(a, b) else @max(a, b));
    }
    if (n.tag == .noop_then or (minimum and (n.tag == .logical_and or n.tag == .logical_or))) return paths(n.children[0], name, minimum) + (if (minimum) @as(usize, 0) else paths(n.children[1], name, minimum));
    var count: usize = 0;
    for (n.children) |c| count += paths(c, name, minimum);
    return count;
}
fn hasLocal(n: *Node) bool {
    if (n.tag == .local or n.tag == .let) return true;
    for (n.children) |c| if (hasLocal(c)) return true;
    return false;
}
const Step = struct { value: *Node, name: ?[]const u8 = null };
fn first(f: *t.Factory, n: *Node, name: []const u8, value: *Node, steps: *std.ArrayList(Step)) Error!*Node {
    if (n.tag == .local and t.same(n.name, name)) {
        try steps.append(f.a, .{ .value = value, .name = if (t.resultType(value) == .unit) null else name });
        return if (t.resultType(value) == .unit) f.node(.unit, &.{}) else n;
    }
    if (n.tag == .seq) {
        var i: usize = 0;
        while (i < n.children.len and paths(n.children[i], name, false) == 0) : (i += 1) try steps.append(f.a, .{ .value = n.children[i] });
        if (i == n.children.len) return error.UnboundVariable;
        const children = try f.a.dupe(*Node, n.children[i..]);
        children[0] = try first(f, children[0], name, value, steps);
        return f.sequence(children);
    }
    if (n.tag == .let and paths(n.children[0], name, false) == 0) {
        try steps.append(f.a, .{ .value = n.children[0], .name = n.name });
        return first(f, n.children[1], name, value, steps);
    }
    if ((n.tag == .conditional or n.tag == .noop_then or n.tag == .logical_and or n.tag == .logical_or) and paths(n.children[0], name, false) == 0) return error.ConditionalMemo;
    const out = try f.clone(n);
    for (out.children) |*c| {
        if (paths(c.*, name, false) > 0) {
            c.* = try first(f, c.*, name, value, steps);
            return out;
        }
        if (!t.effect(c.*) and !hasLocal(c.*)) continue;
        const temporary = try f.fresh("__eval");
        const local = try f.named(.local, temporary, &.{});
        local.result = t.resultType(c.*);
        try steps.append(f.a, .{ .value = c.*, .name = temporary });
        c.* = local;
    }
    return error.UnboundVariable;
}
fn atFirst(f: *t.Factory, n: *Node, name: []const u8, value: *Node) Error!*Node {
    var steps: std.ArrayList(Step) = .empty;
    var result = try first(f, n, name, value, &steps);
    if (t.resultType(value) == .unit) result = try t.replace(f, result, name, try f.node(.unit, &.{}));
    var i = steps.items.len;
    while (i > 0) {
        i -= 1;
        const step = steps.items[i];
        result = if (step.name) |key| try f.named(.let, key, &.{ step.value, result }) else try f.sequence(&.{ step.value, result });
    }
    return result;
}
pub fn materialize(f: *t.Factory, n: *Node, name: []const u8, value: *Node) Error!*Node {
    const count = paths(n, name, false);
    if (count == 0) return n;
    if (count == 1) return t.replace(f, n, name, value);
    if (n.tag == .let and t.same(n.name, name)) return n;
    if (n.tag == .seq) {
        var first_: usize = n.children.len;
        var last: usize = 0;
        var bearing: usize = 0;
        for (n.children, 0..) |c, i| if (paths(c, name, false) > 0) {
            first_ = @min(first_, i);
            last = i;
            bearing += 1;
        };
        const out = try f.clone(n);
        if (bearing == 1) {
            out.children[first_] = try materialize(f, out.children[first_], name, value);
            return out;
        }
        if (paths(n, name, true) == 0) return error.ConditionalMemo;
        var children: std.ArrayList(*Node) = .empty;
        try children.appendSlice(f.a, n.children[0..first_]);
        try children.append(f.a, try atFirst(f, try f.sequence(n.children[first_ .. last + 1]), name, value));
        try children.appendSlice(f.a, n.children[last + 1 ..]);
        return f.sequence(children.items);
    }
    if ((n.tag == .conditional or n.tag == .noop_then) and paths(n.children[0], name, false) == 0) {
        const out = try f.clone(n);
        for (out.children[1..]) |*c| c.* = try materialize(f, c.*, name, value);
        return out;
    }
    if (paths(n, name, true) == 0) {
        const out = try f.clone(n);
        var bearing: usize = 0;
        for (out.children) |*c| if (paths(c.*, name, false) > 0) {
            bearing += 1;
            c.* = try materialize(f, c.*, name, value);
        };
        if (bearing != 1) return error.ConditionalMemo;
        return out;
    }
    return atFirst(f, n, name, value);
}
