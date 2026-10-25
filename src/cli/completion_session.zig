const std = @import("std");
const c = @import("common.zig");
const storage = @import("store.zig");
const labels = @import("labels.zig");

pub const Selection = struct {
    dir: []const u8,
    profile: []const u8,
    chain: u64,
    registry: []const u8,

    fn endpoint(s: Selection, a: c.A, io: std.Io) ![]const u8 {
        const dir = try std.Io.Dir.cwd().realPathFileAlloc(io, s.dir, a);
        const scope = try storage.scopeKey(a, s.chain, s.registry);
        var hash = std.crypto.hash.sha3.Keccak256.init(.{});
        hash.update(s.profile);
        hash.update(":");
        hash.update(scope);
        var digest: [32]u8 = undefined;
        hash.final(&digest);
        return a.print("{s}/.completions/{s}.endpoint", .{ dir, std.fmt.bytesToHex(digest[0..8].*, .lower) });
    }
};

fn exchange(a: c.A, io: std.Io, path: []const u8, operation: []const u8) ![]u8 {
    const address = try std.Io.net.UnixAddress.init(path);
    const stream = try address.connect(io);
    defer stream.close(io);
    var write_buf: [128]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.print("{s}\n", .{operation});
    try writer.interface.flush();
    var read_buf: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    return reader.interface.allocRemaining(a, .limited(16 * 1024 * 1024));
}

pub fn request(a: c.A, io: std.Io, selected: Selection, operation: []const u8) ![]u8 {
    const path = c.trim(try std.Io.Dir.cwd().readFileAlloc(io, try selected.endpoint(a, io), a, .limited(256)));
    const Result = union(enum) { response: anyerror![]u8, timeout: std.Io.Cancelable!void };
    var buffer: [2]Result = undefined;
    var select = std.Io.Select(Result).init(io, &buffer);
    defer select.cancelDiscard();
    try select.concurrent(.timeout, std.Io.sleep, .{ io, .fromMilliseconds(250), .awake });
    try select.concurrent(.response, exchange, .{ a, io, path, operation });
    return switch (try select.await()) {
        .response => |value| value,
        .timeout => error.CompletionSessionUnavailable,
    };
}

pub fn entries(a: c.A, io: std.Io, selected: Selection) ![]labels.Entry {
    if (request(a, io, selected, "entries")) |raw| {
        defer std.crypto.secureZero(u8, raw);
        return parseEntries(a, raw);
    } else |_| {}
    const db = try storage.Store.openReadOnly(a, io, selected.dir);
    defer db.close();
    try db.db.transaction();
    defer db.db.rollback();
    return labels.load(a, db, selected.chain, selected.registry, null);
}

// Entries and intermediate JSON belong to the caller's arena. Check tags before
// typed conversion: Zig otherwise accepts byte arrays as string slices.
fn parseEntries(a: c.A, raw: []const u8) ![]labels.Entry {
    const response = try c.parse(a, raw);
    if (response != .array) return error.InvalidCompletionResponse;
    for (response.array.items) |entry| {
        if (entry != .object) return error.InvalidCompletionResponse;
        inline for (@typeInfo(labels.Entry).@"struct".field_names, @typeInfo(labels.Entry).@"struct".field_types) |field_name, field_type| {
            if (c.field(entry, field_name)) |value| {
                if (value != .string and !(field_type == ?[]const u8 and value == .null)) return error.InvalidCompletionResponse;
            }
        }
    }
    return std.json.parseFromValueLeaky([]labels.Entry, a, response, .{});
}

const State = struct {
    io: std.Io,
    selected: Selection,
    keys: []const [32]u8,
    ttl: u64,
    refresh_seconds: u64,
    refresh_argv: []const []const u8,
    refresh_state: std.atomic.Value(u8) = .init(0),

    fn refresh(state: *State) void {
        if (state.refresh_seconds == 0) return;
        while (true) {
            var child = std.process.spawn(state.io, .{ .argv = state.refresh_argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch {
                state.refresh_state.store(2, .release);
                std.Io.sleep(state.io, .fromSeconds(@intCast(state.refresh_seconds)), .awake) catch return;
                continue;
            };
            const term = child.wait(state.io) catch {
                child.kill(state.io);
                return;
            };
            state.refresh_state.store(if (term == .exited and term.exited == 0) 1 else 2, .release);
            std.Io.sleep(state.io, .fromSeconds(@intCast(state.refresh_seconds)), .awake) catch return;
        }
    }

    fn respond(state: *State, stream: std.Io.net.Stream) !bool {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var buf: [128]u8 = undefined;
        var reader = stream.reader(state.io, &buf);
        const op = try reader.interface.takeDelimiterExclusive('\n');
        const stopping = c.eq(u8, op, "lock");
        var payload: []const u8 = "{}";
        if (c.eq(u8, op, "entries")) {
            const db = try storage.Store.openReadOnly(a, state.io, state.selected.dir);
            defer db.close();
            try db.db.transaction();
            defer db.db.rollback();
            const items = try labels.loadKeys(a, db, state.selected.chain, state.selected.registry, state.keys);
            defer for (items) |item| if (item.label.len > 0) std.crypto.secureZero(u8, @constCast(item.label));
            payload = try std.json.Stringify.valueAlloc(a, items, .{});
        } else if (c.eq(u8, op, "status")) {
            payload = try c.encode(a, .{
                .status = if (state.keys.len > 0) "unlocked" else "watching",
                .ttl = state.ttl,
                .refreshSeconds = state.refresh_seconds,
                .lastRefresh = switch (state.refresh_state.load(.acquire)) {
                    1 => "ok",
                    2 => "failed",
                    else => if (state.refresh_seconds == 0) "disabled" else "pending",
                },
            });
        } else if (!stopping) return error.InvalidCompletionRequest;
        defer if (payload.len > 2) std.crypto.secureZero(u8, @constCast(payload));
        var out_buf: [4096]u8 = undefined;
        defer std.crypto.secureZero(u8, &out_buf);
        var writer = stream.writer(state.io, &out_buf);
        try writer.interface.writeAll(payload);
        try writer.interface.flush();
        return stopping;
    }

    fn connections(state: *State, server: *std.Io.net.Server) !void {
        while (true) {
            const stream = try server.accept(state.io);
            defer stream.close(state.io);
            const Result = union(enum) { response: anyerror!bool, timeout: std.Io.Cancelable!void };
            var buffer: [2]Result = undefined;
            var select = std.Io.Select(Result).init(state.io, &buffer);
            defer select.cancelDiscard();
            try select.concurrent(.timeout, std.Io.sleep, .{ state.io, .fromSeconds(1), .awake });
            try select.concurrent(.response, respond, .{ state, stream });
            switch (try select.await()) {
                .response => |value| if (value catch false) {
                    return;
                },
                .timeout => {},
            }
        }
    }
};

/// The parent passes derived label keys through an anonymous pipe. Neither
/// passphrases nor key material enter argv, the environment, or a disk cache.
pub fn serve(a: c.A, io: std.Io, selected: Selection, ttl: u64, refresh_seconds: u64, refresh_argv: []const []const u8) !void {
    var keys: [64][32]u8 = undefined;
    defer std.crypto.secureZero(u8, std.mem.sliceAsBytes(&keys));
    var secret_buf: [2049]u8 = undefined;
    defer std.crypto.secureZero(u8, &secret_buf);
    var input = std.Io.File.stdin().readerStreaming(io, &secret_buf);
    const count = try input.interface.takeByte();
    if (count > keys.len) return error.InvalidCompletionRequest;
    try input.interface.readSliceAll(std.mem.sliceAsBytes(keys[0..count]));
    var state: State = .{ .io = io, .selected = selected, .keys = keys[0..count], .ttl = ttl, .refresh_seconds = refresh_seconds, .refresh_argv = refresh_argv };
    std.Io.File.stdin().close(io);

    const private_dir = try a.print("{s}/.completions", .{selected.dir});
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, private_dir, .fromMode(0o700));
    var dir = try std.Io.Dir.cwd().openDir(io, private_dir, .{ .follow_symlinks = false });
    defer dir.close(io);
    try dir.setPermissions(io, .fromMode(0o700));
    const endpoint = try selected.endpoint(a, io);
    const guard = try std.Io.Dir.cwd().createFile(io, try a.print("{s}.lock", .{endpoint}), .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true, .permissions = .fromMode(0o600) });
    defer guard.close(io);
    // A short, private runtime directory avoids sockaddr_un path limits for
    // long config paths. Only its locator is persisted, never keys or labels.
    var random: [16]u8 = undefined;
    try io.randomSecure(&random);
    const runtime_dir = try a.print("/tmp/chainwall-{s}", .{std.fmt.bytesToHex(random, .lower)});
    try std.Io.Dir.cwd().createDir(io, runtime_dir, .fromMode(0o700));
    defer std.Io.Dir.cwd().deleteDir(io, runtime_dir) catch {};
    const path = try a.print("{s}/s", .{runtime_dir});
    const address = try std.Io.net.UnixAddress.init(path);
    var server = try address.listen(io, .{});
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer server.deinit(io);
    try c.write(io, endpoint, path, true);
    defer std.Io.Dir.cwd().deleteFile(io, endpoint) catch {};
    try c.print(io, "ready\n", .{});
    std.Io.File.stdout().close(io);

    var refresh_group: std.Io.Group = .init;
    defer refresh_group.cancel(io);
    try refresh_group.concurrent(io, State.refresh, .{&state});
    const Result = union(enum) { done: anyerror!void, expired: std.Io.Cancelable!void };
    var buffer: [2]Result = undefined;
    var select = std.Io.Select(Result).init(io, &buffer);
    defer select.cancelDiscard();
    try select.concurrent(.expired, std.Io.sleep, .{ io, .fromSeconds(@intCast(ttl)), .awake });
    try select.concurrent(.done, State.connections, .{ &state, &server });
    switch (try select.await()) {
        .done => |done| try done,
        .expired => |done| try done,
    }
}

pub fn launch(a: c.A, io: std.Io, argv: []const []const u8, keys: []const [32]u8) !void {
    if (keys.len > 64) return error.SecretHistoryTooDeep;
    var child = try std.process.spawn(io, .{ .argv = argv, .stdin = .pipe, .stdout = .pipe, .stderr = .ignore });
    errdefer child.kill(io);
    var secret_buf: [2049]u8 = @splat(0);
    defer std.crypto.secureZero(u8, &secret_buf);
    secret_buf[0] = @intCast(keys.len);
    @memcpy(secret_buf[1..][0 .. 32 * keys.len], std.mem.sliceAsBytes(keys));
    try child.stdin.?.writeStreamingAll(io, secret_buf[0 .. 1 + 32 * keys.len]);
    child.stdin.?.close(io);
    child.stdin = null;
    var buf: [128]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(io, &buf);
    const ready = try reader.interface.takeDelimiterExclusive('\n');
    if (!c.eq(u8, ready, "ready")) return error.CompletionSessionUnavailable;
    child.stdout.?.close(io);
    child.stdout = null;
    // The helper owns its lifetime and exits on lock or TTL expiry.
    _ = a;
}

test "completion responses require strings and preserve optional fields and defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var raw = "[{\"kind\":\"users\",\"id\":\"one\"},{\"kind\":\"users\",\"id\":\"two\",\"label\":\"\\u0041\",\"address\":null,\"name\":\"alice\",\"org\":\"team\"}]".*;
    const decoded = try parseEntries(a, &raw);
    @memset(&raw, 0);
    try std.testing.expectEqual(@as(usize, 2), decoded.len);
    try std.testing.expectEqualStrings("one", decoded[0].id);
    try std.testing.expectEqualStrings("", decoded[0].label);
    try std.testing.expectEqualStrings("A", decoded[1].label);
    try std.testing.expect(decoded[1].address == null);
    try std.testing.expectEqualStrings("alice", decoded[1].name.?);
    try std.testing.expectEqualStrings("team", decoded[1].org.?);

    inline for (@typeInfo(labels.Entry).@"struct".field_names, @typeInfo(labels.Entry).@"struct".field_types) |field_name, field_type| {
        for ([_][]const u8{ "[\"65\",66]", "65", "true", "{}" }) |invalid| {
            var response = try c.parse(a, "[{\"kind\":\"users\",\"id\":\"one\"}]");
            try response.array.items[0].object.put(a, field_name, try c.parse(a, invalid));
            try std.testing.expectError(error.InvalidCompletionResponse, parseEntries(a, try c.encode(a, response)));
        }
        var response = try c.parse(a, "[{\"kind\":\"users\",\"id\":\"one\"}]");
        try response.array.items[0].object.put(a, field_name, .null);
        const json = try c.encode(a, response);
        if (field_type == ?[]const u8) {
            _ = try parseEntries(a, json);
        } else try std.testing.expectError(error.InvalidCompletionResponse, parseEntries(a, json));
    }
    for ([_][]const u8{ "{}", "null", "[null]", "[[]]" }) |raw_input| try std.testing.expectError(error.InvalidCompletionResponse, parseEntries(a, raw_input));
    try std.testing.expectEqual(@as(usize, 0), (try parseEntries(a, "[]")).len);
    try std.testing.expectError(error.MissingField, parseEntries(a, "[{\"kind\":\"users\"}]"));
    try std.testing.expectError(error.UnknownField, parseEntries(a, "[{\"kind\":\"users\",\"id\":\"one\",\"extra\":\"value\"}]"));
    try std.testing.expectError(error.DuplicateField, parseEntries(a, "[{\"kind\":\"users\",\"kind\":\"safes\",\"id\":\"one\"}]"));
}
