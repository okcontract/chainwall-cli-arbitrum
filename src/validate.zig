const t = @import("tree.zig");
const Scope = struct { name: []const u8, result: t.Type, parent: ?*const Scope };
pub fn boundedDepth(node: *const t.Node, level: usize) t.Error!void {
    if (level > t.limits.ir_depth) return error.ResourceLimit;
    for (node.children) |child| try boundedDepth(child, level + 1);
}
fn tuple(result: t.Type) bool {
    return @backingInt(result) >= @backingInt(t.Type.words1);
}
fn visit(node: *t.Node, statement: bool, scope: ?*const Scope, depth: usize, diagnostic: ?*t.Diagnostic) t.Error!t.Type {
    errdefer if (diagnostic) |d| d.locate(node.span);
    if (depth > t.limits.ir_depth) return error.ResourceLimit;
    if (node.tag == .local) {
        var current = scope;
        while (current) |entry| : (current = entry.parent) {
            if (t.same(entry.name, node.name)) {
                node.result = entry.result;
                return entry.result;
            }
        }
        return error.UnboundVariable;
    }
    if (node.tag == .let) {
        const value = try visit(node.children[0], false, scope, depth + 1, diagnostic);
        const entry: Scope = .{ .name = node.name, .result = value, .parent = scope };
        return visit(node.children[1], statement, &entry, depth + 1, diagnostic);
    }
    if (node.tag == .seq) {
        var result: t.Type = .boolean;
        for (node.children, 0..) |child, i| result = try visit(child, statement or i + 1 < node.children.len, scope, depth + 1, diagnostic);
        return result;
    }
    for (node.children, 0..) |child, i| {
        const branch = (node.tag == .conditional or node.tag == .noop_then) and i > 0;
        const result = try visit(child, if (branch) statement else false, scope, depth + 1, diagnostic);
        if (node.tag == .get_word) {
            if (!tuple(result) or node.value >= t.wordCount(result)) return error.InvalidType;
        } else if (!branch and tuple(result)) return error.InvalidType;
    }
    const result = t.resultType(node);
    if (!statement and (result == .unit or result == .mixed)) return error.InvalidType;
    if (node.tag == .conditional and result == .mixed and (tuple(t.resultType(node.children[1])) or tuple(t.resultType(node.children[2])))) return error.InvalidType;
    return result;
}
pub fn semantic(root: *t.Node) t.Error!void {
    return semanticDetailed(root, null);
}
pub fn semanticDetailed(root: *t.Node, diagnostic: ?*t.Diagnostic) t.Error!void {
    // resultType itself follows let/sequence bodies recursively.
    try boundedDepth(root, 0);
    const result = try visit(root, t.resultType(root) == .unit or t.resultType(root) == .mixed, null, 0, diagnostic);
    if (tuple(result)) return error.InvalidType;
}
