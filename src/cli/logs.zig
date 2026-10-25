const std = @import("std");
const c = @import("common.zig");

/// Shared by Cast copies so multi-stage and sponsored writes keep one log.
/// Reserve before submission and persist receipts before any follow-up checks.
pub const Journal = struct {
    a: c.A,
    io: std.Io,
    dir: []const u8,
    profile: []const u8,
    command: []const u8,
    path: ?[]const u8 = null,
    transactions: std.ArrayList(c.Value) = .empty,
    submissions: std.ArrayList(c.Value) = .empty,
    result: c.Value = .null,
    status: []const u8 = "pending",
    failure: ?[]const u8 = null,

    pub fn begin(j: *Journal) !void {
        if (j.path != null) return;
        const folder = try directory(j.a, j.dir);
        _ = try std.Io.Dir.cwd().createDirPathStatus(j.io, folder, .fromMode(0o700));
        const absolute = try std.Io.Dir.cwd().realPathFileAlloc(j.io, folder, j.a);
        const now = std.Io.Clock.real.now(j.io);
        const seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(now.toSeconds()) };
        const day = seconds.getEpochDay().calculateYearDay();
        const month = day.calculateMonthDay();
        const time = seconds.getDaySeconds();
        var random: [8]u8 = undefined;
        try j.io.randomSecure(&random);
        const path = try j.a.print("{s}/{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}.{d:0>3}Z-{s}-{s}-{s}.json", .{
            absolute,               day.year,                  month.month.numeric(),              month.day_index + 1,
            time.getHoursIntoDay(), time.getMinutesIntoHour(), time.getSecondsIntoMinute(),        @as(u16, @intCast(@mod(now.toMilliseconds(), 1000))),
            j.profile,              j.command,                 std.fmt.bytesToHex(random, .lower),
        });
        try c.write(j.io, path, try j.encode(), false);
        j.path = path;
    }

    pub fn record(j: *Journal, value: anytype) !void {
        try j.transactions.append(j.a, try c.parse(j.a, try c.encode(j.a, value)));
        try j.flush();
    }
    pub fn prepareSubmission(j: *Journal, value: c.Value) !usize {
        try j.begin();
        try j.submissions.append(j.a, value);
        try j.flush();
        return j.submissions.items.len - 1;
    }
    pub fn updateSubmission(j: *Journal, index: usize, value: c.Value) !void {
        j.submissions.items[index] = value;
        try j.flush();
    }

    pub fn finish(j: *Journal, failure: ?anyerror) !void {
        j.status = if (failure != null) "error" else "complete";
        j.failure = if (failure) |err| @errorName(err) else null;
        try j.flush();
    }

    fn encode(j: *Journal) ![]const u8 {
        return c.encode(j.a, .{ .version = 1, .profile = j.profile, .command = j.command, .status = j.status, .transactions = j.transactions.items, .submissions = j.submissions.items, .result = j.result, .errorName = j.failure });
    }

    pub fn flush(j: *Journal) !void {
        if (j.path) |path| try c.write(j.io, path, try j.encode(), true);
    }
};

fn directory(a: c.A, dir: []const u8) ![]const u8 {
    return std.Io.Dir.path.join(a, &.{ dir, "logs" });
}

fn validName(name: []const u8) bool {
    if (!std.mem.endsWith(u8, name, ".json") or name.len <= 5) return false;
    for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_' and ch != '.') return false;
    return !std.mem.startsWith(u8, name, ".");
}

pub const Entry = struct { name: []const u8, path: []const u8 };

pub fn list(a: c.A, io: std.Io, dir: []const u8) ![]Entry {
    const folder = try directory(a, dir);
    var opened = std.Io.Dir.cwd().openDir(io, folder, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return &.{};
        return err;
    };
    defer opened.close(io);
    const absolute = try std.Io.Dir.cwd().realPathFileAlloc(io, folder, a);
    var entries: std.ArrayList(Entry) = .empty;
    var iter = opened.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file or !validName(entry.name)) continue;
        try entries.append(a, .{ .name = try a.dupe(u8, entry.name), .path = try std.Io.Dir.path.join(a, &.{ absolute, entry.name }) });
    }
    std.mem.sort(Entry, entries.items, {}, struct {
        fn less(_: void, left: Entry, right: Entry) bool {
            return std.mem.order(u8, left.name, right.name) == .gt;
        }
    }.less);
    return entries.toOwnedSlice(a);
}

pub fn read(a: c.A, io: std.Io, dir: []const u8, name: []const u8) !c.Value {
    const entries = try list(a, io, dir);
    if (c.eq(u8, name, "latest")) {
        if (entries.len == 0) return error.NoTransactionLogs;
        return @import("json_schema.zig").read(a, io, "transaction-log", entries[0].path);
    }
    for (entries) |entry| {
        if (c.eq(u8, name, entry.name) or c.eq(u8, name, entry.path)) return @import("json_schema.zig").read(a, io, "transaction-log", entry.path);
    }
    return error.TransactionLogNotFound;
}
