const std = @import("std");
const t = @import("tree.zig");
const Node = t.Node;
const Error = t.Error;
const Token = struct { text: []const u8, start: usize, kind: enum { identifier, number, string, symbol, eof } };
pub const Parser = struct {
    f: *t.Factory,
    source: []const u8,
    pos: usize = 0,
    token: Token = .{ .text = "", .start = 0, .kind = .eof },
    depth: usize = 0,
    tokens: usize = 0,
    surface: bool = false,

    fn advance(p: *Parser) Error!void {
        p.tokens += 1;
        if (p.tokens > 32768) return error.ResourceLimit;
        while (p.pos < p.source.len and std.ascii.isWhitespace(p.source[p.pos])) p.pos += 1;
        const start = p.pos;
        if (start == p.source.len) {
            p.token = .{ .text = "", .start = start, .kind = .eof };
            return;
        }
        const c = p.source[p.pos];
        p.pos += 1;
        var kind: @TypeOf(p.token.kind) = .symbol;
        errdefer p.token = .{ .text = p.source[start..p.pos], .start = start, .kind = kind };
        if (std.ascii.isAlphabetic(c) or c == '$' or c == '_' or (p.surface and c == '@')) {
            kind = .identifier;
            while (p.pos < p.source.len and (std.ascii.isAlphanumeric(p.source[p.pos]) or p.source[p.pos] == '_' or p.source[p.pos] == '$')) p.pos += 1;
        } else if (std.ascii.isDigit(c) or (c == '.' and p.pos < p.source.len and std.ascii.isDigit(p.source[p.pos]))) {
            kind = .number;
            if (c == '0' and p.pos < p.source.len and (p.source[p.pos] == 'x' or p.source[p.pos] == 'X')) {
                p.pos += 1;
                while (p.pos < p.source.len and (std.ascii.isHex(p.source[p.pos]) or p.source[p.pos] == '_')) p.pos += 1;
            } else {
                while (p.pos < p.source.len and (std.ascii.isDigit(p.source[p.pos]) or p.source[p.pos] == '_' or p.source[p.pos] == '.')) p.pos += 1;
                if (p.pos < p.source.len and (p.source[p.pos] == 'e' or p.source[p.pos] == 'E')) {
                    p.pos += 1;
                    if (p.pos < p.source.len and (p.source[p.pos] == '+' or p.source[p.pos] == '-')) p.pos += 1;
                    while (p.pos < p.source.len and std.ascii.isDigit(p.source[p.pos])) p.pos += 1;
                }
            }
        } else if (c == '"') {
            kind = .string;
            while (p.pos < p.source.len and p.source[p.pos] != '"') {
                if (p.source[p.pos] == '\\') p.pos += 1;
                if (p.pos >= p.source.len) return error.Syntax;
                p.pos += 1;
            }
            if (p.pos == p.source.len) return error.Syntax;
            p.pos += 1;
        } else if (p.pos < p.source.len) {
            const next = p.source[p.pos];
            if ((next == '=' and (c == '=' or c == '!' or c == '<' or c == '>')) or (c == '&' and next == '&') or (c == '|' and next == '|') or (c == ':' and next == ':')) p.pos += 1;
        }
        p.token = .{ .text = p.source[start..p.pos], .start = start, .kind = kind };
    }
    fn is(p: *Parser, s: []const u8) bool {
        return t.same(p.token.text, s);
    }
    fn take(p: *Parser, s: []const u8) Error!bool {
        if (!p.is(s)) return false;
        try p.advance();
        return true;
    }
    fn expect(p: *Parser, s: []const u8) Error!void {
        if (!try p.take(s)) return error.Syntax;
    }
    fn name(p: *Parser) Error![]const u8 {
        if (p.token.kind != .identifier) return error.Syntax;
        const s = try std.ascii.allocLowerString(p.f.a, p.token.text);
        try p.advance();
        return s;
    }
    fn call(p: *Parser, name_: []const u8, children: []const *Node) Error!*Node {
        return p.f.named(.application, name_, children);
    }
    fn sourceEnd(p: *Parser) usize {
        var end = p.token.start;
        while (end > 0 and std.ascii.isWhitespace(p.source[end - 1])) end -= 1;
        return end;
    }
    fn primary(p: *Parser) Error!*Node {
        const start = p.token.start;
        if (try p.take("-")) {
            const n = try p.expression(7);
            if (n.tag == .number and !n.negative) {
                const out = try p.f.clone(n);
                out.negative = true;
                out.span.start = start;
                return out;
            }
            const out = try p.call("-", &.{n});
            out.span = .{ .start = start, .end = n.span.end };
            out.name_span = .{ .start = start, .end = start + 1 };
            return out;
        }
        if (try p.take("!")) {
            const child = try p.expression(7);
            const out = try p.call("!", &.{child});
            out.span = .{ .start = start, .end = child.span.end };
            out.name_span = .{ .start = start, .end = start + 1 };
            return out;
        }
        var n: *Node = undefined;
        if (p.token.kind == .number) {
            const value = try parseNumber(p.f.a, p.token.text);
            n = try p.f.node(.number, &.{});
            n.value = value;
            try p.advance();
        } else if (p.token.kind == .string) {
            const parsed = std.json.parseFromSlice([]const u8, p.f.a, p.token.text, .{ .allocate = .alloc_always }) catch return error.Syntax;
            n = try p.f.named(.string, parsed.value, &.{});
            try p.advance();
        } else if (p.token.kind == .identifier) {
            const spelling = p.token.text;
            const name_span: t.Span = .{ .start = p.token.start, .end = p.pos };
            const s = try p.name();
            if (p.surface and (t.same(spelling, "@contract") or t.same(spelling, "@token"))) {
                if (!p.is("(")) return error.Syntax;
                const close = std.mem.indexOfScalarPos(u8, p.source, p.pos, ')') orelse return error.Syntax;
                const path = std.mem.trim(u8, p.source[p.pos..close], " \t\r\n");
                const slash = std.mem.indexOfScalar(u8, path, '/') orelse return error.InvalidArguments;
                if (slash == 0 or slash + 1 == path.len or std.mem.indexOfScalarPos(u8, path, slash + 1, '/') != null) return error.InvalidArguments;
                for (path) |ch| if (std.ascii.isWhitespace(ch) or std.ascii.isUpper(ch) or ch == '(') return error.InvalidArguments;
                n = try p.f.named(.registry_reference, path, &.{});
                n.data = t.same(spelling, "@token");
                p.pos = close;
                try p.advance();
                try p.expect(")");
            } else if (t.same(s, "true") or t.same(s, "false")) {
                n = try p.f.node(.number, &.{});
                n.value = @intFromBool(t.same(s, "true"));
                n.spelling = spelling;
            } else {
                n = try p.f.named(.variable, s, &.{});
                n.spelling = spelling;
            }
            n.name_span = name_span;
        } else if (try p.take("(")) {
            n = try p.expression(0);
            try p.expect(")");
        } else if (p.is("{") or p.is("[")) {
            const list = p.is("[");
            try p.advance();
            const close: []const u8 = if (list) "]" else "}";
            var elements: std.ArrayList(*Node) = .empty;
            while (!p.is(close)) {
                const item = if (!list and try p.take("let")) blk: {
                    const spelling = p.token.text;
                    const name_span: t.Span = .{ .start = p.token.start, .end = p.pos };
                    const s = try p.name();
                    try p.expect("=");
                    const binding = try p.f.named(.declaration, s, &.{try p.expression(0)});
                    binding.spelling = spelling;
                    binding.name_span = name_span;
                    binding.span = .{ .start = name_span.start, .end = p.sourceEnd() };
                    break :blk binding;
                } else try p.expression(0);
                try elements.append(p.f.a, item);
                if (!try p.take(",")) break;
            }
            try p.expect(close);
            n = try p.f.node(if (list) .list else if (elements.items.len == 0) .object else .tuple, elements.items);
        } else return error.Syntax;
        n.span = .{ .start = start, .end = p.sourceEnd() };
        while (true) {
            if (p.surface and try p.take(".")) {
                const spelling = p.token.text;
                const name_span: t.Span = .{ .start = p.token.start, .end = p.pos };
                const method_name = try p.name();
                var args: std.ArrayList(*Node) = .empty;
                try args.append(p.f.a, n);
                var value: ?*Node = null;
                if (try p.take("{")) {
                    if (!t.same(p.token.text, "value")) return error.InvalidArguments;
                    try p.advance();
                    try p.expect(":");
                    value = try p.expression(0);
                    try p.expect("}");
                }
                try p.expect("(");
                while (!p.is(")")) {
                    try args.append(p.f.a, try p.expression(0));
                    if (!try p.take(",")) break;
                }
                try p.expect(")");
                if (value) |v| try args.append(p.f.a, v);
                n = try p.f.named(.member_call, method_name, args.items);
                n.spelling = spelling;
                n.payable = value != null;
                n.name_span = name_span;
            } else if (try p.take("(")) {
                if (n.tag != .variable) return error.Unsupported;
                var args: std.ArrayList(*Node) = .empty;
                while (!p.is(")")) {
                    try args.append(p.f.a, try p.expression(0));
                    if (!try p.take(",")) break;
                }
                try p.expect(")");
                const spelling = n.spelling;
                const name_span = n.name_span;
                n = try p.call(n.name, args.items);
                n.spelling = spelling;
                n.name_span = name_span;
            } else if (try p.take("[")) {
                n = try p.f.node(.index, &.{ n, try p.expression(0) });
                try p.expect("]");
            } else if (try p.take("::")) {
                if (p.surface) {
                    const hint = try p.typeHint();
                    if (!t.same(hint, "number")) n.type_hint = if (n.type_hint) |previous| if (t.same(previous, hint)) hint else "" else hint;
                    n.span = .{ .start = start, .end = p.sourceEnd() };
                    continue;
                }
                // Type ascriptions do not alter scalar code generation.
                _ = try p.name();
                if (try p.take("[")) {
                    while (!p.is("]") and p.token.kind != .eof) try p.advance();
                    try p.expect("]");
                }
            } else break;
            n.span = .{ .start = start, .end = p.sourceEnd() };
        }
        return n;
    }
    fn typeHint(p: *Parser) Error![]const u8 {
        p.depth += 1;
        defer p.depth -= 1;
        if (p.depth > 256) return error.ResourceLimit;
        if (try p.take("[")) {
            const child = try p.typeHint();
            const length = if (try p.take(";")) blk: {
                if (p.token.kind != .number) return error.Syntax;
                const v = try parseNumber(p.f.a, p.token.text);
                try p.advance();
                break :blk try p.f.a.print("; {d}", .{v});
            } else "";
            try p.expect("]");
            return p.f.a.print("[{s}{s}]", .{ child, length });
        }
        if (try p.take("{")) {
            var children: std.ArrayList([]const u8) = .empty;
            while (!p.is("}")) {
                try children.append(p.f.a, try p.typeHint());
                if (!try p.take(",")) break;
            }
            try p.expect("}");
            return p.f.a.print("{{{s}}}", .{try std.mem.join(p.f.a, ", ", children.items)});
        }
        const raw = try p.name();
        if (t.same(raw, "number") and try p.take("[")) {
            // Numeric refinements do not select an ABI width or emit VM casts.
            while (!p.is("]") and p.token.kind != .eof) try p.advance();
            try p.expect("]");
        }
        return if (t.same(raw, "uint")) "uint256" else if (t.same(raw, "int")) "int256" else raw;
    }
    fn precedence(s: []const u8) u8 {
        if (t.same(s, "||")) return 1;
        if (t.same(s, "&&")) return 2;
        for ([_][]const u8{ "==", "!=", "<", ">", "<=", ">=" }) |op| if (t.same(s, op)) return 3;
        if (t.same(s, "+") or t.same(s, "-")) return 4;
        if (t.same(s, "*") or t.same(s, "/") or t.same(s, "%")) return 5;
        return 0;
    }
    fn expression(p: *Parser, min: u8) Error!*Node {
        // Boolean operators recurse directly through expression, without
        // keeping primary on the stack. Count every recursive expression.
        p.depth += 1;
        defer p.depth -= 1;
        if (p.depth > 256) return error.ResourceLimit;
        var left = try p.primary();
        while (true) {
            const prec = precedence(p.token.text);
            if (prec == 0 or prec < min) break;
            const op = p.token.text;
            const span_start = left.span.start;
            const name_span: t.Span = .{ .start = p.token.start, .end = p.pos };
            try p.advance();
            const right = try p.expression(prec + @intFromBool(prec != 1 and prec != 2));
            left = try p.call(op, &.{ left, right });
            left.span = .{ .start = span_start, .end = right.span.end };
            left.name_span = name_span;
        }
        return left;
    }
    fn checkTree(node: *Node, depth: usize, remaining: *usize) Error!void {
        if (depth > 256 or remaining.* == 0) return error.ResourceLimit;
        remaining.* -= 1;
        for (node.children) |child| try checkTree(child, depth + 1, remaining);
    }
    pub fn parse(p: *Parser) Error!t.Program {
        try p.advance();
        var bindings: std.ArrayList(t.Binding) = .empty;
        var mains: std.ArrayList(*Node) = .empty;
        while (p.token.kind != .eof) {
            const component = try p.take("let");
            var look = p.*;
            const definition = p.token.kind == .identifier and blk: {
                try look.advance();
                break :blk look.is("=");
            };
            if (component or definition) {
                while (true) {
                    const spelling = p.token.text;
                    const name_span: t.Span = .{ .start = p.token.start, .end = p.pos };
                    const s = try p.name();
                    try p.expect("=");
                    const value = try p.expression(0);
                    for (bindings.items) |b| if (t.same(b.name, s)) return error.DuplicateBinding;
                    try bindings.append(p.f.a, .{ .name = s, .value = value, .spelling = spelling, .name_span = name_span });
                    if (!component or !try p.take("and")) break;
                }
                if (component) {
                    try p.expect("in");
                    try mains.append(p.f.a, try p.expression(0));
                }
            } else try mains.append(p.f.a, try p.expression(0));
            _ = try p.take(";");
        }
        if (mains.items.len == 0) {
            if (bindings.items.len == 0) return error.Syntax;
            const binding = bindings.items[bindings.items.len - 1];
            const result = try p.f.named(.variable, binding.name, &.{});
            result.spelling = binding.spelling;
            try mains.append(p.f.a, result);
        }
        const main = if (mains.items.len == 1) mains.items[0] else try p.f.node(.tuple, mains.items);
        if (mains.items.len > 1) main.span = .{ .start = mains.items[0].span.start, .end = mains.items[mains.items.len - 1].span.end };
        // Iterative parsing can still construct deep left-associated or postfix
        // trees. Bound them before lowering and other recursive traversals.
        var remaining: usize = 8192;
        for (bindings.items) |binding| try checkTree(binding.value, 1, &remaining);
        try checkTree(main, 1, &remaining);
        return .{ .bindings = bindings.items, .main = main };
    }
};

pub fn parseNumber(a: t.Allocator, text: []const u8) Error!u256 {
    var clean: std.ArrayList(u8) = .empty;
    for (text) |c| if (c != '_') {
        try clean.append(a, c);
    };
    const s = clean.items;
    if (std.mem.startsWith(u8, s, "0x") or std.mem.startsWith(u8, s, "0X")) return std.fmt.parseInt(u256, s[2..], 16) catch error.InvalidConstant;
    const e = std.mem.indexOfAny(u8, s, "eE") orelse s.len;
    const exponent: i32 = if (e < s.len) std.fmt.parseInt(i32, s[e + 1 ..], 10) catch return error.InvalidConstant else 0;
    var value: u256 = 0;
    var fractional: i32 = 0;
    var dot = false;
    for (s[0..e]) |c| {
        if (c == '.') {
            if (dot) return error.InvalidConstant;
            dot = true;
            continue;
        }
        if (!std.ascii.isDigit(c)) return error.InvalidConstant;
        const mul = @mulWithOverflow(value, 10);
        const add = @addWithOverflow(mul[0], c - '0');
        if (mul[1] != 0 or add[1] != 0) return error.InvalidConstant;
        value = add[0];
        if (dot) fractional += 1;
    }
    const scale: i64 = @as(i64, exponent) - fractional;
    if (scale > 77 or scale < -1000) return error.InvalidConstant;
    var i: i64 = 0;
    while (i < @abs(scale)) : (i += 1) {
        if (scale < 0) {
            if (value % 10 != 0) return error.InvalidConstant;
            value /= 10;
        } else {
            const mul = @mulWithOverflow(value, 10);
            if (mul[1] != 0) return error.InvalidConstant;
            value = mul[0];
        }
    }
    return value;
}

test "exact decimal and scientific words" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(u256, 1_500_000_000_000_000_000), try parseNumber(arena.allocator(), "1.5e18"));
    try std.testing.expectError(error.InvalidConstant, parseNumber(arena.allocator(), "0.1"));
}
