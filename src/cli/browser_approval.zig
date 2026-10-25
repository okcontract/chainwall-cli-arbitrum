const std = @import("std");
const c = @import("common.zig");
const abi = @import("abi_codec.zig");

pub const Options = struct {
    app_url: ?[]const u8 = null,
    page_url: ?[]const u8 = null,
    open_browser: bool = true,
    timeout_seconds: u32 = 300,
};

pub fn approvalUrl(a: c.A, expected_origin: []const u8, options: Options, port: u16, token: []const u8) ![]const u8 {
    if (options.page_url != null and options.app_url != null) return error.ConflictingApprovalUrls;
    const url = options.page_url orelse options.app_url orelse expected_origin;
    const uri = try std.Uri.parse(url);
    if (uri.fragment != null or uri.query != null or !c.eq(u8, try origin(a, url), expected_origin)) return error.AppOriginMismatch;
    // A standalone HTML document is an exact URL. The legacy app option is a
    // router base path and retains its existing trailing-slash behavior.
    const base = if (options.page_url != null) url else try a.print("{s}/", .{std.mem.trimEnd(u8, url, "/")});
    return a.print("{s}#/cli?port={d}&token={s}", .{ base, port, token });
}

pub fn origin(a: c.A, url: []const u8) ![]const u8 {
    const uri = try std.Uri.parse(url);
    if (uri.user != null or uri.password != null) return error.InvalidApprovalUrl;
    const host = try (uri.host orelse return error.InvalidApprovalUrl).toRawMaybeAlloc(a);
    if (!c.eq(u8, uri.scheme, "https") and !(c.eq(u8, uri.scheme, "http") and (c.eq(u8, host, "localhost") or c.eq(u8, host, "127.0.0.1")))) return error.InsecureApprovalOrigin;
    if (uri.port) |port| return a.print("{s}://{s}:{d}", .{ uri.scheme, host, port });
    return a.print("{s}://{s}", .{ uri.scheme, host });
}

/// A single capability-authenticated, origin-restricted loopback exchange.
/// Credentials stay in the configured WebAuthn origin; nothing is served publicly.
pub fn request(a: c.A, io: std.Io, env: *const std.process.Environ.Map, expected_origin: []const u8, payload: c.Value, options: Options) !c.Value {
    if (options.timeout_seconds == 0 or options.timeout_seconds > 3600) return error.InvalidApprovalTimeout;
    if (!c.eq(u8, try origin(a, expected_origin), expected_origin)) return error.InvalidApprovalOrigin;
    var token: [32]u8 = undefined;
    try io.randomSecure(&token);
    const secret = try abi.hex(a, &token);
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    const host = try a.print("127.0.0.1:{d}", .{server.socket.address.getPort()});
    const url = try approvalUrl(a, expected_origin, options, server.socket.address.getPort(), secret[2..]);
    try std.Io.File.stderr().writeStreamingAll(io, try a.print("Approve in Chainwall:\n{s}\n", .{url}));
    if (options.open_browser) {
        const program = if (@import("builtin").target.os.tag == .macos) "open" else if (@import("builtin").target.os.tag == .windows) "explorer.exe" else "xdg-open";
        _ = std.process.run(a, io, .{ .argv = &.{ program, url }, .environ_map = env, .expand_arg0 = .expand, .stdout_limit = .limited(4096), .stderr_limit = .limited(4096), .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } } }) catch null;
    }
    var session: Session = .{ .a = a, .io = io, .server = &server, .origin = expected_origin, .host = host, .authorization = try a.print("Bearer {s}", .{secret[2..]}), .payload = try c.encode(a, payload) };
    const Result = union(enum) { response: anyerror!c.Value, timeout: std.Io.Cancelable!void };
    var buffer: [2]Result = undefined;
    var select = std.Io.Select(Result).init(io, &buffer);
    defer select.cancelDiscard();
    try select.concurrent(.timeout, std.Io.sleep, .{ io, .fromSeconds(options.timeout_seconds), .awake });
    try select.concurrent(.response, Session.serve, .{&session});
    return switch (try select.await()) {
        .response => |value| value,
        .timeout => error.BrowserApprovalTimedOut,
    };
}

const Session = struct {
    a: c.A,
    io: std.Io,
    server: *std.Io.net.Server,
    origin: []const u8,
    host: []const u8,
    authorization: []const u8,
    payload: []const u8,

    fn serve(s: *Session) !c.Value {
        // Bound both total lifetime and request count. Each connection closes
        // after one response, including malformed and unauthenticated requests.
        for (0..128) |_| {
            const stream = try s.server.accept(s.io);
            defer stream.close(s.io);
            var read_buffer: [8192]u8 = undefined;
            var write_buffer: [4096]u8 = undefined;
            var reader = stream.reader(s.io, &read_buffer);
            var writer = stream.writer(s.io, &write_buffer);
            var http = std.http.Server.init(&reader.interface, &writer.interface);
            var req = http.receiveHead() catch continue;
            const origin_header = uniqueHeader(&req, "origin") orelse "";
            const host_header = uniqueHeader(&req, "host") orelse "";
            if (!c.eq(u8, origin_header, s.origin) or !c.eq(u8, host_header, s.host) or !c.eq(u8, req.head.target, "/approval")) {
                try req.respond("{}", .{ .status = .forbidden, .keep_alive = false });
                continue;
            }
            const headers = [_]std.http.Header{
                .{ .name = "Access-Control-Allow-Origin", .value = s.origin },
                .{ .name = "Vary", .value = "Origin" },
                .{ .name = "Access-Control-Allow-Methods", .value = "GET, POST, OPTIONS" },
                .{ .name = "Access-Control-Allow-Headers", .value = "Authorization, Content-Type" },
                .{ .name = "Access-Control-Allow-Private-Network", .value = "true" },
                .{ .name = "Content-Type", .value = "application/json" },
                .{ .name = "Cache-Control", .value = "no-store" },
            };
            if (req.head.method == .OPTIONS) {
                try req.respond("", .{ .status = .no_content, .keep_alive = false, .extra_headers = &headers });
                continue;
            }
            if (!c.eq(u8, uniqueHeader(&req, "authorization") orelse "", s.authorization)) {
                try req.respond("{}", .{ .status = .forbidden, .keep_alive = false, .extra_headers = &headers });
                continue;
            }
            if (req.head.method == .GET) {
                try req.respond(s.payload, .{ .keep_alive = false, .extra_headers = &headers });
                continue;
            }
            if (req.head.method != .POST or !c.eq(u8, req.head.content_type orelse "", "application/json") or (req.head.content_length orelse std.math.maxInt(u64)) > 2 * 1024 * 1024) {
                try req.respond("{}", .{ .status = .bad_request, .keep_alive = false, .extra_headers = &headers });
                continue;
            }
            var body_buffer: [4096]u8 = undefined;
            const body_reader = try req.readerExpectContinue(&body_buffer);
            const body = try body_reader.allocRemaining(s.a, .limited(2 * 1024 * 1024));
            const result = c.parse(s.a, body) catch {
                try req.respond("{}", .{ .status = .bad_request, .keep_alive = false, .extra_headers = &headers });
                continue;
            };
            if (c.field(result, "result") == null and c.field(result, "error") == null) {
                try req.respond("{}", .{ .status = .bad_request, .keep_alive = false, .extra_headers = &headers });
                continue;
            }
            try req.respond("{\"received\":true}", .{ .keep_alive = false, .extra_headers = &headers });
            if (c.field(result, "error")) |_| return error.BrowserApprovalRejected;
            return c.field(result, "result").?;
        }
        return error.BrowserApprovalRequestLimit;
    }
};

fn uniqueHeader(request_: *const std.http.Server.Request, name: []const u8) ?[]const u8 {
    var iterator = request_.iterateHeaders();
    var found: ?[]const u8 = null;
    while (iterator.next()) |header| if (std.ascii.eqlIgnoreCase(header.name, name)) {
        if (found != null) return null;
        found = header.value;
    };
    return found;
}

test "standalone approval URLs preserve the document and enforce the passkey origin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const expected = "https://chainwall.example";
    try std.testing.expectEqualStrings("https://chainwall.example/approval.html#/cli?port=1234&token=abc", try approvalUrl(a, expected, .{ .page_url = "https://chainwall.example/approval.html" }, 1234, "abc"));
    try std.testing.expectEqualStrings("https://chainwall.example/app/#/cli?port=1234&token=abc", try approvalUrl(a, expected, .{ .app_url = "https://chainwall.example/app/" }, 1234, "abc"));
    try std.testing.expectEqualStrings("https://chainwall.example/#/cli?port=1234&token=abc", try approvalUrl(a, expected, .{}, 1234, "abc"));
    for ([_][]const u8{ "https://evil.example/approval.html", "https://chainwall.example:8443/page", "https://chainwall.example/page?query=1", "https://chainwall.example/page#fragment" }) |url|
        try std.testing.expectError(error.AppOriginMismatch, approvalUrl(a, expected, .{ .page_url = url }, 1234, "abc"));
    try std.testing.expectError(error.InvalidApprovalUrl, approvalUrl(a, expected, .{ .page_url = "https://user@chainwall.example/page" }, 1234, "abc"));
    try std.testing.expectError(error.InsecureApprovalOrigin, approvalUrl(a, expected, .{ .page_url = "http://chainwall.example/page" }, 1234, "abc"));
    try std.testing.expectError(error.ConflictingApprovalUrls, approvalUrl(a, expected, .{ .page_url = expected, .app_url = expected }, 1234, "abc"));
}
