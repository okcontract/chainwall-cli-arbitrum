//! Loopback HTTP fixtures used only by native Zig regression tests.
const std = @import("std");
const c = @import("common.zig");

pub const Reply = struct { body: []const u8, delay_ms: u64 = 0, status: std.http.Status = .ok, request_contains: ?[]const u8 = null };
pub const Server = struct {
    io: std.Io,
    listener: std.Io.net.Server,
    replies: []const Reply,
    requests: usize = 0,

    pub fn init(io: std.Io, replies: []const Reply) !Server {
        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        return .{ .io = io, .listener = try address.listen(io, .{}), .replies = replies };
    }
    pub fn deinit(s: *Server) void {
        s.listener.deinit(s.io);
    }
    pub fn url(s: *Server, a: c.A) ![]const u8 {
        return a.print("http://127.0.0.1:{d}", .{s.listener.socket.address.getPort()});
    }
    pub fn serve(s: *Server) !void {
        for (s.replies) |reply| {
            const stream = try s.listener.accept(s.io);
            defer stream.close(s.io);
            var read_buffer: [8192]u8 = undefined;
            var write_buffer: [4096]u8 = undefined;
            var reader = stream.reader(s.io, &read_buffer);
            var writer = stream.writer(s.io, &write_buffer);
            var http = std.http.Server.init(&reader.interface, &writer.interface);
            var req = try http.receiveHead();
            var body_buffer: [4096]u8 = undefined;
            const body_reader = try req.readerExpectContinue(&body_buffer);
            if (reply.request_contains) |expected| {
                const content = try body_reader.allocRemaining(std.heap.page_allocator, .limited(65536));
                defer std.heap.page_allocator.free(content);
                if (std.mem.indexOf(u8, content, expected) == null) return error.UnexpectedMockRequest;
            } else _ = try body_reader.discardRemaining();
            s.requests += 1;
            if (reply.delay_ms > 0) try std.Io.sleep(s.io, .fromMilliseconds(@intCast(reply.delay_ms)), .awake);
            try req.respond(reply.body, .{ .keep_alive = false, .status = reply.status });
        }
    }
};
