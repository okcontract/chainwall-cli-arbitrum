// Copyright (C) 2026 OKcontract Pte. Ltd.
const std = @import("std");
const ms = @import("miniscript");
const c = @import("../cli/common.zig");
const text = @import("text.zig");
const Surface = @import("../cli/surface.zig").Surface;
const Node = ms.tree.Node;
pub const Symbol = struct { name: []const u8, spelling: []const u8, span: text.Span, value: *Node, scope: text.Span };
pub const Use = struct { node: *Node, symbol: ?usize };
const Scope = struct { symbol: usize, parent: ?*const Scope };

pub const Analysis = struct {
    a: c.A,
    source: []const u8,
    surface: ?Surface = null,
    failure: ?anyerror = null,
    error_span: text.Span = .{},
    symbols: std.ArrayList(Symbol) = .empty,
    uses: std.ArrayList(Use) = .empty,
    nodes: std.ArrayList(*Node) = .empty,
    globals: usize = 0,
    depth: usize = 0,

    pub fn init(a: c.A, source: []const u8) !Analysis {
        var result: Analysis = .{ .a = a, .source = source };
        var f: ms.tree.Factory = .{ .a = a };
        var parser: ms.parser.Parser = .{ .f = &f, .source = source, .surface = true };
        const program = parser.parse() catch |err| {
            if (err == error.OutOfMemory) return err;
            result.failure = err;
            result.error_span = .{ .start = parser.token.start, .end = @min(source.len, parser.token.start + parser.token.text.len) };
            return result;
        };
        for (program.bindings) |binding| try result.symbols.append(a, .{ .name = binding.name, .spelling = binding.spelling, .span = binding.name_span, .value = binding.value, .scope = .{ .end = source.len } });
        result.globals = result.symbols.items.len;
        result.indexProgram(program) catch |err| {
            if (err == error.OutOfMemory) return err;
            result.failure = err;
            result.surface = null;
            result.symbols.clearRetainingCapacity();
            result.nodes.clearRetainingCapacity();
            result.uses.clearRetainingCapacity();
            result.globals = 0;
            return result;
        };
        result.surface = Surface.fromProgram(a, program) catch |err| {
            if (err == error.OutOfMemory) return err;
            result.failure = err;
            return result;
        };
        return result;
    }
    fn indexProgram(s: *Analysis, program: ms.tree.Program) !void {
        for (program.bindings) |binding| try s.visit(binding.value, null);
        try s.visit(program.main, null);
    }
    fn lookup(s: *Analysis, name: []const u8, scope_: ?*const Scope) ?usize {
        var scope = scope_;
        while (scope) |entry| : (scope = entry.parent) if (c.eq(u8, name, s.symbols.items[entry.symbol].name)) return entry.symbol;
        for (s.symbols.items[0..s.globals], 0..) |symbol, i| if (c.eq(u8, symbol.name, name)) return i;
        return null;
    }
    fn visit(s: *Analysis, node: *Node, scope_: ?*const Scope) anyerror!void {
        if (s.depth >= 256 or s.nodes.items.len >= 8192) return error.ResourceLimit;
        s.depth += 1;
        defer s.depth -= 1;
        try s.nodes.append(s.a, node);
        if (node.tag == .variable) try s.uses.append(s.a, .{ .node = node, .symbol = s.lookup(node.name, scope_) });
        if (node.tag == .tuple) {
            var scope = scope_;
            for (node.children) |child| {
                if (child.tag == .declaration) {
                    try s.nodes.append(s.a, child);
                    try s.visit(child.children[0], scope);
                    const index = s.symbols.items.len;
                    try s.symbols.append(s.a, .{ .name = child.name, .spelling = child.spelling, .span = child.name_span, .value = child.children[0], .scope = .{ .start = child.span.end, .end = node.span.end } });
                    const next = try s.a.create(Scope);
                    next.* = .{ .symbol = index, .parent = scope };
                    scope = next;
                } else try s.visit(child, scope);
            }
        } else for (node.children) |child| try s.visit(child, scope_);
    }
    pub fn symbolAt(s: Analysis, pos: usize) ?usize {
        for (s.symbols.items, 0..) |symbol, i| if (text.contains(symbol.span, pos)) return i;
        for (s.uses.items) |use| if (use.symbol != null and use.node.name_span.end > use.node.name_span.start and text.contains(use.node.name_span, pos)) return use.symbol;
        return null;
    }
    pub fn reference(s: Analysis, node: *Node) ?*Node {
        return s.resolve(node, 0);
    }
    fn resolve(s: Analysis, node: *Node, depth: usize) ?*Node {
        if (depth > 256) return null;
        if (node.tag == .registry_reference) return node;
        if (node.tag == .variable) for (s.uses.items) |use| {
            if (use.node == node) return if (use.symbol) |i| s.resolve(s.symbols.items[i].value, depth + 1) else null;
        };
        return null;
    }
    pub fn nodeAt(s: Analysis, pos: usize) ?*Node {
        var result: ?*Node = null;
        for (s.nodes.items) |node| if (text.contains(node.span, pos) and (result == null or node.span.end - node.span.start < result.?.span.end - result.?.span.start)) {
            result = node;
        };
        return result;
    }
    pub fn namedAt(s: Analysis, start: usize) ?*Node {
        for (s.nodes.items) |node| if (node.name_span.start == start and (node.tag == .application or node.tag == .member_call)) return node;
        return null;
    }
};

/// Complete only the prefix for interactive lookup. Never compile recovered
/// text or use it for rename/diagnostics; those require the actual document.
pub fn context(a: c.A, source: []const u8, pos: usize) !Analysis {
    var complete = try Analysis.init(a, source);
    if (complete.failure == null) return complete;
    const prefix = source[0..pos];
    const items = try text.tokens(a, prefix);
    var closers: std.ArrayList(u8) = .empty;
    for (items) |item| {
        if (item.kind != .symbol or item.text.len != 1) continue;
        const ch = item.text[0];
        if (std.mem.indexOfScalar(u8, "([{", ch)) |i| try closers.append(a, ")]}"[i]) else if (closers.items.len > 0 and ch == closers.items[closers.items.len - 1]) _ = closers.pop();
    }
    var suffix: std.Io.Writer.Allocating = .init(a);
    const last = if (items.len > 0) items[items.len - 1].text else "";
    if (c.eq(u8, last, ".")) try suffix.writer.writeAll("__lsp__()") else if (items.len > 1 and c.eq(u8, items[items.len - 2].text, ".")) try suffix.writer.writeAll("()") else if (last.len == 0 or std.mem.indexOfScalar(u8, "(,=+-*/", last[0]) != null) try suffix.writer.writeAll("0");
    var i = closers.items.len;
    while (i > 0) {
        i -= 1;
        try suffix.writer.writeByte(closers.items[i]);
    }
    const repaired = try std.mem.concat(a, u8, &.{ prefix, suffix.written() });
    complete = try Analysis.init(a, repaired);
    if (complete.failure != null) complete = try Analysis.init(a, try std.mem.concat(a, u8, &.{ repaired, " in 0" }));
    return complete;
}

pub const Call = struct { name: text.Token, open: usize, argument: usize };
pub fn callAt(items: []const text.Token, pos: usize) ?Call {
    var stack: [256]struct { index: usize, commas: usize } = undefined;
    var len: usize = 0;
    for (items, 0..) |item, i| {
        if (item.span.start >= pos) break;
        if (item.kind != .symbol or item.text.len != 1) continue;
        if (std.mem.indexOfScalar(u8, "([{", item.text[0]) != null) {
            if (len == stack.len) return null;
            stack[len] = .{ .index = i, .commas = 0 };
            len += 1;
        } else if (std.mem.indexOfScalar(u8, ")]}", item.text[0]) != null) {
            if (len > 0) len -= 1;
        } else if (item.text[0] == ',' and len > 0) stack[len - 1].commas += 1;
    }
    while (len > 0) {
        len -= 1;
        const frame = stack[len];
        if (!c.eq(u8, items[frame.index].text, "(") or frame.index == 0) continue;
        var before = frame.index - 1;
        if (c.eq(u8, items[before].text, "}")) {
            var depth: usize = 1;
            while (before > 0) {
                before -= 1;
                if (c.eq(u8, items[before].text, "}")) depth += 1;
                if (c.eq(u8, items[before].text, "{")) {
                    depth -= 1;
                    if (depth == 0) break;
                }
            }
            if (before == 0) continue;
            before -= 1;
        }
        if (items[before].kind == .identifier) return .{ .name = items[before], .open = items[frame.index].span.start, .argument = frame.commas };
    }
    return null;
}

pub fn format(a: c.A, source: []const u8, spaces: usize) ![]const u8 {
    if ((try Analysis.init(a, source)).failure != null) return error.InvalidSource;
    return ms.syntax.format(a, source, spaces);
}

test "scope navigation distinguishes shadowing and recovers incomplete member calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try Analysis.init(a, "let X = @token(circle/usdc) in {let x = @token(weth/weth), x.balanceOf($self)}");
    try std.testing.expect(s.failure == null);
    try std.testing.expectEqual(@as(usize, 2), s.symbols.items.len);
    const call = s.nodes.items[s.nodes.items.len - 3];
    _ = call;
    const partial = "let token = @token(circle/usdc) in token.";
    const recovered = try context(a, partial, partial.len);
    try std.testing.expect(recovered.failure == null);
    const member = recovered.namedAt(partial.len).?;
    try std.testing.expectEqualStrings("circle/usdc", recovered.reference(member.children[0]).?.name);
    const formatted = try format(a, "{$require($arg0>0),$arg0+1}", 2);
    try std.testing.expectEqualStrings(formatted, try format(a, formatted, 2));
    const old = try ms.compile(a, "{$require($arg0>0),$arg0+1}", .{});
    try std.testing.expectEqualSlices(u8, old, try ms.compile(a, formatted, .{}));
}
