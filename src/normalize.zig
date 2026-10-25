const std = @import("std");
const t = @import("tree.zig");
const Node = t.Node;
const Error = t.Error;
const Env = struct {
    name: []const u8,
    value: *Node,
    parent: ?*const Env,
    fn get(env: ?*const Env, name: []const u8) ?*Node {
        var e = env;
        while (e) |entry| : (e = entry.parent) {
            if (t.same(entry.name, name)) return entry.value;
        }
        return null;
    }
};
const Step = struct { value: *Node, local: ?*Node = null };
const Steps = std.ArrayList(Step);
pub const Normalizer = struct {
    f: *t.Factory,
    next: usize = 0,
    fn finish(n: *Normalizer, steps: Steps, result: *Node) Error!*Node {
        var out = result;
        var i = steps.items.len;
        while (i > 0) {
            i -= 1;
            const step = steps.items[i];
            out = if (step.local) |local| try n.f.named(.let, local.name, &.{ step.value, out }) else try n.f.node(.seq, &.{ step.value, out });
        }
        return out;
    }
    fn region(n: *Normalizer, node: *Node, env: ?*const Env, boolean: bool) Error!*Node {
        var steps: Steps = .empty;
        var result = try n.norm(node, env, &steps);
        if (boolean) {
            if (result.tag == .constant) result = try n.f.num(@intFromBool(result.value != 0)) else if (t.resultType(result) != .boolean) result = try n.f.node(.neq, &.{ result, try n.f.num(0) });
        }
        return n.finish(steps, result);
    }
    fn norm(n: *Normalizer, node: *Node, env: ?*const Env, steps: *Steps) Error!*Node {
        if (node.tag == .local) return Env.get(env, node.name) orelse error.UnboundVariable;
        if (t.atomic(node)) return node;
        if (node.tag == .let) {
            const value = try n.norm(node.children[0], env, steps);
            const entry: Env = .{ .name = node.name, .value = value, .parent = env };
            return n.norm(node.children[1], &entry, steps);
        }
        if (node.tag == .seq) {
            var result = try n.f.num(0);
            for (node.children) |child| result = try n.norm(child, env, steps);
            return result;
        }
        if (node.tag == .target) {
            const value = try n.norm(node.children[0], env, steps);
            return if (value.tag == .target) value else n.f.node(.target, &.{value});
        }
        var operation = try n.f.clone(node);
        if (node.tag == .conditional or node.tag == .noop_then) {
            operation.children[0] = try n.norm(node.children[0], env, steps);
            for (operation.children[1..]) |*child| child.* = try n.region(child.*, env, false);
        } else if (node.tag == .logical_and or node.tag == .logical_or) {
            const cond = try n.norm(node.children[0], env, steps);
            const right = try n.region(node.children[1], env, true);
            operation = try n.f.node(.conditional, &.{ cond, if (node.tag == .logical_and) right else try n.f.num(1), if (node.tag == .logical_and) try n.f.num(0) else right });
        } else {
            for (operation.children) |*child| child.* = try n.norm(child.*, env, steps);
        }
        if (operation.tag == .add or operation.tag == .sub) {
            if (zero(operation.children[1])) return operation.children[0];
            if (operation.tag == .add and zero(operation.children[0])) return operation.children[1];
        }
        if (operation.tag == .mul and (zero(operation.children[0]) or zero(operation.children[1]))) return n.f.num(0);
        if (t.resultType(operation) == .unit or t.resultType(operation) == .mixed) {
            try steps.append(n.f.a, .{ .value = operation });
            return n.f.node(.unit, &.{});
        }
        const name = try n.f.a.print("$__anf{d}", .{n.next});
        n.next += 1;
        const local = try n.f.named(.local, name, &.{});
        local.result = t.resultType(operation);
        try steps.append(n.f.a, .{ .value = operation, .local = local });
        return local;
    }
    pub fn run(n: *Normalizer, root: *Node) Error!*Node {
        var steps: Steps = .empty;
        const value = try n.norm(root, null, &steps);
        return n.finish(steps, if (value.tag == .unit) try n.f.num(1) else value);
    }
};
fn zero(n: *Node) bool {
    return n.tag == .constant and n.value == 0;
}
fn firstDemand(n: *Node, name: []const u8) bool {
    if (n.tag == .local) return t.same(n.name, name);
    const children = switch (n.tag) {
        .conditional, .noop_then, .logical_and, .logical_or => n.children[0..1],
        else => n.children,
    };
    for (children) |child| {
        if (t.uses(child, name) > 0) return firstDemand(child, name);
        if (t.effect(child)) return false;
    }
    return false;
}
fn scheduleSequence(f: *t.Factory, nodes: []const *Node, statement: bool) Error!*Node {
    var flat: std.ArrayList(*Node) = .empty;
    for (nodes) |node| {
        if (node.tag == .seq) try flat.appendSlice(f.a, node.children) else try flat.append(f.a, node);
    }
    var kept: std.ArrayList(*Node) = .empty;
    for (flat.items, 0..) |node, i| {
        if (statement and node.tag == .unit) continue;
        if (i == flat.items.len - 1 or t.effect(node)) try kept.append(f.a, node);
    }
    return if (kept.items.len == 0) f.node(.unit, &.{}) else f.sequence(kept.items);
}
pub fn schedule(f: *t.Factory, node: *Node, statement: bool) Error!*Node {
    if (statement and !t.effect(node)) return f.node(.unit, &.{});
    const out = try f.clone(node);
    for (out.children, 0..) |*child, i| {
        const childStatement = switch (out.tag) {
            .seq => if (i == out.children.len - 1) statement else true,
            .let, .conditional, .noop_then => if (i == 0) false else statement,
            else => false,
        };
        child.* = try schedule(f, child.*, childStatement);
    }
    if (out.tag == .conditional) {
        const cond = out.children[0];
        const yes = out.children[1];
        const no = out.children[2];
        if (yes.tag == .unit and no.tag == .unit) return scheduleSequence(f, &.{ cond, yes }, statement);
        if (yes.tag == .unit) return f.node(.noop_then, &.{ cond, no });
        if (no.tag == .unit) return f.node(.noop_then, &.{ try f.node(.eq, &.{ cond, try f.num(0) }), yes });
    }
    if (out.tag == .seq) return scheduleSequence(f, out.children, statement);
    if (out.tag != .let) return out;
    const value = out.children[0];
    const body = out.children[1];
    const count = t.uses(body, out.name);
    if (count == 0) return if (!t.effect(value)) body else scheduleSequence(f, &.{ value, body }, statement);
    if (t.atomic(value) or (count == 1 and (!t.effect(value) or firstDemand(body, out.name)))) return t.replace(f, body, out.name, value);
    return out;
}
