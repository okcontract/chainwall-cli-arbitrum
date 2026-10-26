// Copyright (C) 2026 OKcontract Pte. Ltd.
const std = @import("std");
const tree = @import("tree.zig");
const Parser = @import("parser.zig").Parser;
pub const Span = tree.Span;

pub fn word(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '$';
}
pub fn keyword(s: []const u8) bool {
    for ([_][]const u8{ "let", "and", "in", "true", "false" }) |k| if (std.ascii.eqlIgnoreCase(s, k)) return true;
    return false;
}
pub const Token = struct { span: Span, kind: enum { identifier, number, string, reference, symbol }, text: []const u8 };

/// Tolerant tokenization is only for editor context and presentation. The real
/// parser remains authoritative for syntax, scopes, diagnostics and compilation.
/// Token storage uses a's arena; text slices borrow source.
pub fn tokens(a: std.mem.Allocator, source: []const u8) ![]const Token {
    var out: std.ArrayList(Token) = .empty;
    var i: usize = 0;
    while (i < source.len) {
        if (std.ascii.isWhitespace(source[i])) {
            i += 1;
            continue;
        }
        const start = i;
        const ch = source[i];
        i += 1;
        var kind: @FieldType(Token, "kind") = .symbol;
        if (ch == '"') {
            kind = .string;
            while (i < source.len) {
                const next = source[i];
                i += 1;
                if (next == '\\' and i < source.len) i += 1 else if (next == '"') break;
            }
        } else if (ch == '@') {
            kind = .reference;
            while (i < source.len and (word(source[i]) or source[i] == '/')) i += 1;
            var open = i;
            while (open < source.len and std.ascii.isWhitespace(source[open])) open += 1;
            if (open < source.len and source[open] == '(') {
                i = open + 1;
                while (i < source.len and source[i] != ')' and source[i] != '\n' and source[i] != '\r') i += 1;
                if (i < source.len and source[i] == ')') i += 1;
            }
        } else if (std.ascii.isDigit(ch) or (ch == '.' and i < source.len and std.ascii.isDigit(source[i]))) {
            kind = .number;
            while (i < source.len and (word(source[i]) or source[i] == '.' or ((source[i] == '-' or source[i] == '+') and (source[i - 1] == 'e' or source[i - 1] == 'E')))) i += 1;
        } else if (word(ch)) {
            kind = .identifier;
            while (i < source.len and word(source[i])) i += 1;
        } else if (i < source.len and ((source[i] == '=' and std.mem.indexOfScalar(u8, "=!<>", ch) != null) or (source[i] == ch and std.mem.indexOfScalar(u8, "&|:", ch) != null))) i += 1;
        try out.append(a, .{ .span = .{ .start = start, .end = i }, .kind = kind, .text = source[start..i] });
        if (out.items.len > tree.limits.syntax_tokens) return error.ResourceLimit;
    }
    return out.items;
}

fn validate(a: std.mem.Allocator, source: []const u8) !void {
    var f: tree.Factory = .{ .a = a };
    var parser: Parser = .{ .f = &f, .source = source, .surface = true };
    _ = try parser.parse();
}

pub fn format(a: std.mem.Allocator, source: []const u8, spaces: usize) ![]const u8 {
    return formatWithOptions(a, source, .{ .tab_size = spaces });
}
pub const FormatOptions = struct { tab_size: usize = 2, insert_spaces: bool = true };
/// Preserve the first line-ending style; mixed structural whitespace is
/// normalized to that style. String contents are emitted without alteration.
/// Use an arena: validation/tokenization intermediates share its lifetime.
pub fn formatWithOptions(a: std.mem.Allocator, source: []const u8, options: FormatOptions) ![]const u8 {
    if (options.tab_size == 0 or options.tab_size > tree.limits.indentation_width) return error.InvalidIndentWidth;
    const ending: []const u8 = blk: {
        for (source, 0..) |ch, at| {
            if (ch == '\r') break :blk if (at + 1 < source.len and source[at + 1] == '\n') "\r\n" else "\r";
            if (ch == '\n') break :blk "\n";
        }
        break :blk "\n";
    };
    try validate(a, source);
    const items = try tokens(a, source);
    var out: std.ArrayList(u8) = .empty;
    var depth: usize = 0;
    var braces: [tree.limits.syntax_depth]bool = undefined;
    var brace_count: usize = 0;
    var newline = true;
    for (items, 0..) |item, i| {
        const s = item.text;
        const prev = if (i == 0) "" else items[i - 1].text;
        const next = if (i + 1 == items.len) "" else items[i + 1].text;
        const closing = std.mem.eql(u8, s, "}") and brace_count > 0 and braces[brace_count - 1];
        if (closing) {
            depth -= 1;
            newline = true;
        }
        if (std.mem.eql(u8, s, "and") or std.mem.eql(u8, s, "in")) newline = true;
        if (newline) {
            while (out.items.len > 0 and (out.items[out.items.len - 1] == ' ' or out.items[out.items.len - 1] == '\t')) _ = out.pop();
            if (out.items.len > 0 and out.items[out.items.len - 1] != ending[ending.len - 1]) try out.appendSlice(a, ending);
            try out.appendNTimes(a, if (options.insert_spaces) ' ' else '\t', depth * if (options.insert_spaces) options.tab_size else @as(usize, 1));
        } else if (out.items.len > 0 and !std.mem.eql(u8, s, ",") and !std.mem.eql(u8, s, ";") and !std.mem.eql(u8, s, ")") and !std.mem.eql(u8, s, "]") and !std.mem.eql(u8, s, ".") and !std.mem.eql(u8, s, ":") and !std.mem.eql(u8, prev, ".") and !std.mem.eql(u8, prev, "(") and !std.mem.eql(u8, prev, "[") and !(std.mem.eql(u8, s, "(") and (items[i - 1].kind == .identifier or std.mem.eql(u8, prev, "}"))) and !(std.mem.eql(u8, s, "[") and (items[i - 1].kind == .identifier or std.mem.eql(u8, prev, ")")))) try out.append(a, ' ');
        try out.appendSlice(a, s);
        newline = false;
        if (std.mem.eql(u8, s, "{")) {
            const block = !std.mem.eql(u8, next, "}") and !std.mem.eql(u8, next, "value") and !std.mem.eql(u8, prev, "::");
            if (brace_count == braces.len) return error.ResourceLimit;
            braces[brace_count] = block;
            brace_count += 1;
            if (block) {
                depth += 1;
                newline = true;
            }
        } else if (std.mem.eql(u8, s, "}")) {
            if (brace_count > 0) brace_count -= 1;
        } else if (std.mem.eql(u8, s, ",") and brace_count > 0 and braces[brace_count - 1]) {
            newline = true;
        } else if (std.mem.eql(u8, s, ";") and depth == 0) newline = true;
    }
    try out.appendSlice(a, ending);
    try validate(a, out.items);
    return out.toOwnedSlice(a);
}
