const std = @import("std");
const ms = @import("miniscript");
const c = @import("common.zig");

pub const Color = enum { auto, always, never };

pub fn enabled(mode: Color, json: bool, terminal: bool, env: *const std.process.Environ.Map) bool {
    if (json or mode == .never) return false;
    if (mode == .always) return true;
    if (!terminal or c.eq(u8, env.get("TERM") orelse "", "dumb") or c.eq(u8, env.get("CLICOLOR") orelse "", "0")) return false;
    if (env.get("NO_COLOR")) |value| if (value.len > 0) return false;
    return true;
}

/// Colors never enter source files or compiler JSON. Token spans preserve the
/// exact source, including whitespace and escape sequences inside strings.
pub fn highlight(a: c.A, source: []const u8) ![]const u8 {
    const tokens = try ms.syntax.tokens(a, source);
    var out: std.Io.Writer.Allocating = .init(a);
    var cursor: usize = 0;
    for (tokens, 0..) |token, i| {
        try out.writer.writeAll(source[cursor..token.span.start]);
        const color: []const u8 = switch (token.kind) {
            .reference => "\x1b[1;34m",
            .string => "\x1b[32m",
            .number => "\x1b[33m",
            .identifier => if (ms.syntax.keyword(token.text)) "\x1b[1;35m" else if (std.mem.startsWith(u8, token.text, "$")) "\x1b[36m" else if (i + 1 < tokens.len and c.eq(u8, tokens[i + 1].text, "(")) "\x1b[1;33m" else "",
            .symbol => "",
        };
        try out.writer.writeAll(color);
        try out.writer.writeAll(token.text);
        if (color.len > 0) try out.writer.writeAll("\x1b[0m");
        cursor = token.span.end;
    }
    try out.writer.writeAll(source[cursor..]);
    return out.toOwnedSlice();
}

/// Render only at the terminal boundary; saved JSON never contains colors.
pub fn printJson(io: std.Io, source: []const u8, colored: bool) !void {
    var buf: [4096]u8 = undefined;
    defer std.crypto.secureZero(u8, &buf);
    var out = std.Io.File.stdout().writerStreaming(io, &buf);
    if (colored) try highlightJson(&out.interface, source) else try out.interface.writeAll(source);
    if (!std.mem.endsWith(u8, source, "\n")) try out.interface.writeByte('\n');
    try out.interface.flush();
}

/// Input is valid serialized JSON. Keep escape sequences and
/// whitespace intact; strings followed by a colon are object keys.
fn highlightJson(out: *std.Io.Writer, source: []const u8) !void {
    var at: usize = 0;
    while (at < source.len) {
        const start = at;
        const color: []const u8 = switch (source[at]) {
            '"' => blk: {
                at += 1;
                while (at < source.len) {
                    const ch = source[at];
                    at += 1;
                    if (ch == '"') break;
                    if (ch == '\\' and at < source.len) at += 1;
                }
                var next = at;
                while (next < source.len and std.ascii.isWhitespace(source[next])) : (next += 1) {}
                break :blk if (next < source.len and source[next] == ':') "\x1b[36m" else "\x1b[32m";
            },
            '-', '0'...'9' => blk: {
                at += 1;
                while (at < source.len and (std.ascii.isDigit(source[at]) or std.mem.indexOfScalar(u8, ".eE+-", source[at]) != null)) : (at += 1) {}
                break :blk "\x1b[33m";
            },
            't', 'f', 'n' => blk: {
                while (at < source.len and std.ascii.isAlphabetic(source[at])) : (at += 1) {}
                break :blk "\x1b[35m";
            },
            else => blk: {
                at += 1;
                break :blk "";
            },
        };
        try out.writeAll(color);
        try out.writeAll(source[start..at]);
        if (color.len > 0) try out.writeAll("\x1b[0m");
    }
}

test "terminal coloring honors redirection, JSON, environment, and explicit overrides" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expect(enabled(.auto, false, true, &env));
    try std.testing.expect(!enabled(.auto, false, false, &env));
    try env.put("NO_COLOR", "1");
    try std.testing.expect(!enabled(.auto, false, true, &env));
    try std.testing.expect(enabled(.always, false, false, &env));
    try std.testing.expect(!enabled(.always, true, true, &env));
    try std.testing.expect(!enabled(.never, false, true, &env));
}
