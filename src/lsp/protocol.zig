// Copyright (C) 2026 OKcontract Pte. Ltd.
const std = @import("std");
const c = @import("../cli/common.zig");

pub const Transport = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,

    /// One lock covers the header and body, including background command replies.
    pub fn send(t: *Transport, value: anytype) !void {
        const bytes = try std.json.Stringify.valueAlloc(std.heap.page_allocator, value, .{});
        defer std.heap.page_allocator.free(bytes);
        try t.mutex.lock(t.io);
        defer t.mutex.unlock(t.io);
        var buffer: [4096]u8 = undefined;
        var out = std.Io.File.stdout().writerStreaming(t.io, &buffer);
        try out.interface.print("Content-Length: {d}\r\n\r\n{s}", .{ bytes.len, bytes });
        try out.interface.flush();
    }
    pub fn reply(t: *Transport, id: c.Value, value: anytype) !void {
        try t.send(.{ .jsonrpc = "2.0", .id = id, .result = value });
    }
    pub fn failure(t: *Transport, id: c.Value, code: i32, message: []const u8) !void {
        try t.send(.{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = code, .message = message } });
    }
    pub fn notify(t: *Transport, method: []const u8, params: anytype) !void {
        try t.send(.{ .jsonrpc = "2.0", .method = method, .params = params });
    }
};

pub fn read(a: c.A, reader: *std.Io.Reader) !?[]const u8 {
    var length: ?usize = null;
    var size: usize = 0;
    while (true) {
        const raw = reader.takeDelimiterInclusive('\n') catch |err| {
            if (err == error.EndOfStream and size == 0) return null;
            return err;
        };
        size += raw.len;
        if (size > 8192 or !std.mem.endsWith(u8, raw, "\r\n")) return error.InvalidFrame;
        const line = raw[0 .. raw.len - 2];
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidFrame;
        if (std.ascii.eqlIgnoreCase(line[0..colon], "Content-Length")) {
            if (length != null) return error.InvalidFrame;
            length = std.fmt.parseInt(usize, c.trim(line[colon + 1 ..]), 10) catch return error.InvalidFrame;
        }
    }
    const n = length orelse return error.InvalidFrame;
    if (n == 0 or n > 2 * 1024 * 1024) return error.FrameTooLarge;
    const body = try a.alloc(u8, n);
    errdefer a.free(body);
    try reader.readSliceAll(body);
    return body;
}

pub fn field(value: c.Value, name: []const u8) c.Value {
    return c.field(value, name) orelse .null;
}
pub fn string(value: c.Value) ![]const u8 {
    return c.string(value) catch error.InvalidParams;
}
pub fn integer(value: c.Value) !i64 {
    return switch (value) {
        .integer => |n| n,
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch error.InvalidParams,
        else => error.InvalidParams,
    };
}
pub fn boolean(value: c.Value) bool {
    return value == .bool and value.bool;
}
pub fn json(a: c.A, input: anytype) !c.Value {
    return c.parse(a, try c.encode(a, input));
}

test "framing preserves concatenated messages and rejects ambiguous lengths" {
    var reader = std.Io.Reader.fixed("Content-Length: 2\r\n\r\n{}Content-Length: 4\r\n\r\nnull");
    const a = std.testing.allocator;
    const first = (try read(a, &reader)).?;
    defer a.free(first);
    const second = (try read(a, &reader)).?;
    defer a.free(second);
    try std.testing.expectEqualStrings("{}", first);
    try std.testing.expectEqualStrings("null", second);
    try std.testing.expectEqual(@as(?[]const u8, null), try read(a, &reader));
    reader = .fixed("Content-Length: 2\r\nContent-Length: 3\r\n\r\n{}");
    try std.testing.expectError(error.InvalidFrame, read(a, &reader));
    reader = .fixed("Content-Length: 10\r\n\r\n{}");
    try std.testing.expectError(error.EndOfStream, read(a, &reader));
}
