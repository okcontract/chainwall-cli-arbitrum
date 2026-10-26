// Copyright (C) 2026 OKcontract Pte. Ltd.
const std = @import("std");
const ms = @import("miniscript");
const c = @import("../cli/common.zig");
const p = @import("protocol.zig");
pub const Span = ms.tree.Span;
pub const Position = struct { line: usize, character: usize };
pub const Range = struct { start: Position, end: Position };
pub const Edit = struct { range: Range, newText: []const u8 };
pub const Encoding = enum { utf16, utf8 };
pub const max_source = ms.limits.source_bytes;

pub fn position(source: []const u8, offset_: usize, encoding: Encoding) Position {
    const end_offset = @min(offset_, source.len);
    var result: Position = .{ .line = 0, .character = 0 };
    var i: usize = 0;
    while (i < end_offset) {
        if (source[i] == '\n' or source[i] == '\r') {
            result.line += 1;
            result.character = 0;
            i += if (source[i] == '\r' and i + 1 < source.len and source[i + 1] == '\n') @as(usize, 2) else 1;
        } else {
            const width = std.unicode.utf8ByteSequenceLength(source[i]) catch 1;
            if (i + width > end_offset) break;
            result.character += if (encoding == .utf8) width else if (width == 4) @as(usize, 2) else 1;
            i += width;
        }
    }
    return result;
}
pub fn offset(source: []const u8, input: c.Value, encoding: Encoding) !usize {
    const line = try p.integer(p.field(input, "line"));
    const character = try p.integer(p.field(input, "character"));
    if (line < 0 or character < 0) return error.InvalidParams;
    var i: usize = 0;
    var current: usize = 0;
    while (current < line) : (current += 1) {
        while (i < source.len and source[i] != '\r' and source[i] != '\n') i += 1;
        if (i == source.len) return i;
        i += if (source[i] == '\r' and i + 1 < source.len and source[i + 1] == '\n') @as(usize, 2) else 1;
    }
    var units: usize = 0;
    while (i < source.len and source[i] != '\n' and source[i] != '\r') {
        if (units == character) return i;
        const width = std.unicode.utf8ByteSequenceLength(source[i]) catch return error.InvalidParams;
        units += if (encoding == .utf8) width else if (width == 4) @as(usize, 2) else 1;
        if (units > character) return error.InvalidParams; // Never split a code point/surrogate pair.
        i += width;
    }
    return i; // LSP clamps positions beyond the end of a line.
}
pub fn range(source: []const u8, span: Span, encoding: Encoding) Range {
    return .{ .start = position(source, span.start, encoding), .end = position(source, span.end, encoding) };
}
pub fn changed(a: c.A, source: []const u8, changes: c.Value, encoding: Encoding) ![]const u8 {
    if (changes != .array or source.len > max_source) return error.InvalidParams;
    // Reuse one growing buffer. Request arenas otherwise retain a complete
    // document copy for every edit in a single didChange notification.
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(a);
    try result.appendSlice(a, source);
    for (changes.array.items) |change| {
        const insert = try p.string(p.field(change, "text"));
        if (!std.unicode.utf8ValidateSlice(insert)) return error.InvalidParams;
        const r = p.field(change, "range");
        const start = if (r == .null) 0 else try offset(result.items, p.field(r, "start"), encoding);
        const end = if (r == .null) result.items.len else try offset(result.items, p.field(r, "end"), encoding);
        if (end < start or insert.len > max_source or result.items.len - (end - start) > max_source - insert.len) return error.InvalidParams;
        try result.replaceRange(a, start, end - start, insert);
    }
    return result.toOwnedSlice(a);
}
pub fn identifier(s: []const u8) bool {
    if (s.len == 0 or !(std.ascii.isAlphabetic(s[0]) or s[0] == '_' or s[0] == '$')) return false;
    for (s[1..]) |ch| if (!word(ch)) return false;
    return true;
}
pub const word = ms.syntax.word;
pub const keyword = ms.syntax.keyword;
pub const Token = ms.syntax.Token;
pub const tokens = ms.syntax.tokens;
pub fn at(items: []const Token, pos: usize) ?Token {
    for (items) |item| if (item.span.start <= pos and pos < item.span.end) return item;
    for (items) |item| if (item.span.end == pos) return item;
    return null;
}
pub fn contains(span: Span, pos: usize) bool {
    return span.start <= pos and pos <= span.end;
}

pub fn path(a: c.A, input_uri: []const u8) !?[]const u8 {
    if (!std.mem.startsWith(u8, input_uri, "file://")) return null;
    var raw = input_uri[7..];
    if (std.mem.startsWith(u8, raw, "localhost/")) raw = raw[9..];
    if (raw.len == 0 or raw[0] != '/') return error.InvalidFileUri;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '%') {
            if (i + 2 >= raw.len) return error.InvalidFileUri;
            const ch = std.fmt.parseInt(u8, raw[i + 1 .. i + 3], 16) catch return error.InvalidFileUri;
            if (ch == 0) return error.InvalidFileUri;
            try out.append(a, ch);
            i += 2;
        } else {
            if (raw[i] == '?' or raw[i] == '#' or raw[i] == 0) return error.InvalidFileUri;
            try out.append(a, raw[i]);
        }
    }
    if (!std.unicode.utf8ValidateSlice(out.items)) return error.InvalidFileUri;
    const decoded = if (@import("builtin").target.os.tag == .windows and out.items.len > 2 and out.items[2] == ':') out.items[1..] else out.items;
    return try std.Io.Dir.path.resolve(a, &.{decoded});
}
pub fn uri(a: c.A, file: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try out.writer.writeAll(if (std.mem.startsWith(u8, file, "/")) "file://" else "file:///");
    for (file) |ch| {
        if (std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "/-._~:", ch) != null) try out.writer.writeByte(ch) else if (@import("builtin").target.os.tag == .windows and ch == '\\') try out.writer.writeByte('/') else try out.writer.print("%{X:0>2}", .{ch});
    }
    return out.toOwnedSlice();
}

test "UTF-16 edits preserve astral characters and apply sequentially" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "\"\xf0\x9f\x98\x80\"\r\n$arg0";
    try std.testing.expectEqual(Position{ .line = 0, .character = 3 }, position(source, 5, .utf16));
    try std.testing.expectError(error.InvalidParams, offset(source, try p.json(a, .{ .line = 0, .character = 2 }), .utf16));
    const changes = try c.parse(a, "[{\"range\":{\"start\":{\"line\":1,\"character\":4},\"end\":{\"line\":1,\"character\":5}},\"text\":\"1\"}]");
    try std.testing.expectEqualStrings("\"\xf0\x9f\x98\x80\"\r\n$arg1", try changed(a, source, changes, .utf16));
    try std.testing.expectEqualStrings("/tmp/a b.ls", (try path(a, "file:///tmp/a%20b.ls")).?);
}

test "large edit batches reuse storage and preserve sequential coordinates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try a.alloc(u8, max_source);
    @memset(source, ' ');
    const change = try c.parse(a, "{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":1}},\"text\":\"x\"}");
    var changes = std.json.Array.init(a);
    for (0..1024) |_| try changes.append(change);
    const before = arena.queryCapacity();
    const result = try changed(a, source, .{ .array = changes }, .utf16);
    try std.testing.expectEqual(max_source, result.len);
    try std.testing.expectEqual(@as(u8, 'x'), result[0]);
    try std.testing.expectEqual(@as(u8, ' '), source[0]);
    try std.testing.expect(arena.queryCapacity() - before < 2 * 1024 * 1024);
    const edits = try c.parse(a, "[{\"range\":{\"start\":{\"line\":0,\"character\":1},\"end\":{\"line\":0,\"character\":2}},\"text\":\"xy\"},{\"range\":{\"start\":{\"line\":0,\"character\":2},\"end\":{\"line\":0,\"character\":4}},\"text\":\"\"}]");
    try std.testing.expectEqualStrings("ax", try changed(a, "abc", edits, .utf16));
}

fn allocationEdits(a: c.A, edits: c.Value) !void {
    const result = try changed(a, "abc", edits, .utf16);
    defer a.free(result);
    try std.testing.expectEqualStrings("ax", result);
}
test "edit storage is released on allocation and validation failures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const edits = try c.parse(arena.allocator(), "[{\"text\":\"a longer replacement\"},{\"text\":\"ax\"}]");
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationEdits, .{edits});
    const invalid = try c.parse(arena.allocator(), "[{\"text\":\"valid\"},{\"range\":{\"start\":{\"line\":0,\"character\":4},\"end\":{\"line\":0,\"character\":1}},\"text\":\"\"}]");
    try std.testing.expectError(error.InvalidParams, changed(std.testing.allocator, "abc", invalid, .utf16));
}

test "line positions and edits support CR, LF and CRLF" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "\r", "\n", "\r\n" }) |ending| {
        const source = try a.print("one{s}two{s}", .{ ending, ending });
        const start = 3 + ending.len;
        try std.testing.expectEqual(Position{ .line = 1, .character = 0 }, position(source, start, .utf16));
        try std.testing.expectEqual(start + 1, try offset(source, try p.json(a, .{ .line = 1, .character = 1 }), .utf16));
        try std.testing.expectEqual(Position{ .line = 2, .character = 0 }, position(source, source.len, .utf16));
    }
}
