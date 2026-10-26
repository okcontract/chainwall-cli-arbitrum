const std = @import("std");
const sql = @import("zqlite");
const c = @import("common.zig");

/// The pinned zqlite open path drops SQLite's error handle. Close it here:
/// SQLite can allocate a connection even when sqlite3_open_v2 fails.
pub fn openConnection(path: [:0]const u8, flags: c_int) !sql.Conn {
    var db: ?*sql.c.sqlite3 = null;
    const rc = sql.c.sqlite3_open_v2(path, &db, flags, null);
    if (rc != sql.c.SQLITE_OK) {
        if (db) |handle| _ = sql.c.sqlite3_close_v2(handle);
        return if ((rc & 0xff) == sql.c.SQLITE_NOMEM) error.OutOfMemory else error.DatabaseOpenFailed;
    }
    return .{ .conn = db.? };
}

pub const Store = struct {
    a: c.A,
    db: sql.Conn,

    /// Completion must neither create a profile/cache nor wait behind a writer.
    pub fn openReadOnly(a: c.A, io: std.Io, dir: []const u8) !Store {
        const real = try std.Io.Dir.cwd().realPathFileAlloc(io, dir, a);
        const path = try a.printSentinel("{s}/chainwall.sqlite3", .{real}, 0);
        const db = try openConnection(path, sql.OpenFlags.ReadOnly | sql.OpenFlags.NoFollow | sql.OpenFlags.EXResCode);
        errdefer db.close();
        try db.busyTimeout(30);
        return .{ .a = a, .db = db };
    }

    pub fn open(a: c.A, io: std.Io, dir: []const u8) !Store {
        try std.Io.Dir.cwd().createDirPath(io, dir);
        const real = try std.Io.Dir.cwd().realPathFileAlloc(io, dir, a);
        const path = try a.printSentinel("{s}/chainwall.sqlite3", .{real}, 0);
        return init(a, path);
    }
    pub fn init(a: c.A, path: [:0]const u8) !Store {
        const db = try openConnection(path, sql.OpenFlags.Create | sql.OpenFlags.ReadWrite | sql.OpenFlags.NoFollow | sql.OpenFlags.EXResCode);
        errdefer db.close();
        try db.busyTimeout(5000);
        try db.execNoArgs("PRAGMA foreign_keys=ON");
        if (try db.row("PRAGMA user_version", .{})) |row| {
            defer row.deinit();
            if (row.int(0) > 1) return error.DatabaseVersionTooNew;
            // Opening a cached list must not take a write lock while a sync
            // transaction is in flight. Schema writes belong only to migration.
            if (row.int(0) == 1) return .{ .a = a, .db = db };
        }
        try db.execNoArgs(
            \\PRAGMA journal_mode=WAL;
            \\PRAGMA foreign_keys=ON;
            \\CREATE TABLE IF NOT EXISTS checkpoints (
            \\ scope TEXT NOT NULL, dataset TEXT NOT NULL, value TEXT NOT NULL,
            \\ PRIMARY KEY(scope, dataset));
            \\CREATE TABLE IF NOT EXISTS entries (
            \\ scope TEXT NOT NULL, dataset TEXT NOT NULL, id TEXT NOT NULL, value TEXT NOT NULL,
            \\ PRIMARY KEY(scope, dataset, id));
            \\CREATE TABLE IF NOT EXISTS vault (
            \\ id TEXT PRIMARY KEY NOT NULL, value BLOB NOT NULL);
            \\PRAGMA user_version=1;
        );
        return .{ .a = a, .db = db };
    }
    pub fn close(s: Store) void {
        s.db.close();
    }
    pub fn begin(s: Store) !void {
        // Serialize sync writers before loading cursors; WAL readers stay usable.
        try s.db.execNoArgs("BEGIN IMMEDIATE");
    }
    pub fn checkpoint(s: Store, scope: []const u8, dataset: []const u8) !?c.Value {
        var row = (try s.db.row("SELECT value FROM checkpoints WHERE scope=? AND dataset=?", .{ scope, dataset })) orelse return null;
        defer row.deinit();
        return try c.parse(s.a, row.text(0));
    }
    pub fn saveCheckpoint(s: Store, scope: []const u8, dataset: []const u8, value: anytype) !void {
        try s.db.exec("INSERT INTO checkpoints VALUES (?,?,?) ON CONFLICT(scope,dataset) DO UPDATE SET value=excluded.value", .{ scope, dataset, try c.encode(s.a, value) });
    }
    pub fn clear(s: Store, scope: []const u8, dataset: []const u8) !void {
        try s.db.exec("DELETE FROM entries WHERE scope=? AND dataset=?", .{ scope, dataset });
        try s.db.exec("DELETE FROM checkpoints WHERE scope=? AND dataset=?", .{ scope, dataset });
    }
    pub fn put(s: Store, scope: []const u8, dataset: []const u8, id: []const u8, value: c.Value) !void {
        try s.db.exec("INSERT INTO entries VALUES (?,?,?,?) ON CONFLICT(scope,dataset,id) DO UPDATE SET value=excluded.value", .{ scope, dataset, id, try c.encode(s.a, value) });
    }
    pub fn remove(s: Store, scope: []const u8, dataset: []const u8, id: []const u8) !void {
        try s.db.exec("DELETE FROM entries WHERE scope=? AND dataset=? AND id=?", .{ scope, dataset, id });
    }
    /// Returns a caller-allocator-owned decoded record, without loading its peers.
    pub fn get(s: Store, scope: []const u8, dataset: []const u8, id: []const u8) !?c.Value {
        var row = (try s.db.row("SELECT value FROM entries WHERE scope=? AND dataset=? AND id=?", .{ scope, dataset, id })) orelse return null;
        defer row.deinit();
        return try c.parse(s.a, row.text(0));
    }
    pub fn contains(s: Store, scope: []const u8, dataset: []const u8, id: []const u8) !bool {
        var row = (try s.db.row("SELECT 1 FROM entries WHERE scope=? AND dataset=? AND id=?", .{ scope, dataset, id })) orelse return false;
        defer row.deinit();
        return true;
    }
    pub const Entry = struct { id: []const u8, value: c.Value };
    pub const Scan = struct { entries: []const Entry, next: ?[]const u8 };
    /// Keyset traversal. Cursors are exclusive IDs; callers retain their scope.
    pub fn scan(s: Store, scope: []const u8, dataset: []const u8, after: ?[]const u8, count: u32) !Scan {
        if (count == 0 or count > 1000) return error.PageTooLarge;
        var rows = if (after) |cursor| try s.db.rows("SELECT id,value FROM entries WHERE scope=? AND dataset=? AND id>? ORDER BY id LIMIT ?", .{ scope, dataset, cursor, @as(i64, count) + 1 }) else try s.db.rows("SELECT id,value FROM entries WHERE scope=? AND dataset=? ORDER BY id LIMIT ?", .{ scope, dataset, @as(i64, count) + 1 });
        defer rows.deinit();
        var entries_: std.ArrayList(Entry) = .empty;
        while (rows.next()) |row| {
            if (entries_.items.len == count) return .{ .entries = entries_.items, .next = entries_.items[entries_.items.len - 1].id };
            try entries_.append(s.a, .{ .id = try s.a.dupe(u8, row.text(0)), .value = try c.parse(s.a, row.text(1)) });
        }
        if (rows.err) |err| return err;
        return .{ .entries = entries_.items, .next = null };
    }
    pub fn entries(s: Store, scope: []const u8, dataset: []const u8) !std.StringArrayHashMapUnmanaged(c.Value) {
        var rows = try s.db.rows("SELECT id,value FROM entries WHERE scope=? AND dataset=? ORDER BY id", .{ scope, dataset });
        defer rows.deinit();
        var result: std.StringArrayHashMapUnmanaged(c.Value) = .empty;
        while (rows.next()) |row| try result.put(s.a, try s.a.dupe(u8, row.text(0)), try c.parse(s.a, row.text(1)));
        if (rows.err) |err| return err;
        return result;
    }
    pub const Page = struct { total: i64, values: []const c.Value };
    pub fn page(s: Store, scope: []const u8, dataset: []const u8, start: u64, count: u64) !Page {
        var total = (try s.db.row("SELECT count(*) FROM entries WHERE scope=? AND dataset=?", .{ scope, dataset })).?;
        defer total.deinit();
        var rows = try s.db.rows("SELECT value FROM entries WHERE scope=? AND dataset=? ORDER BY id LIMIT ? OFFSET ?", .{ scope, dataset, @as(i64, @intCast(@min(count, std.math.maxInt(i64)))), @as(i64, @intCast(@min(start, std.math.maxInt(i64)))) });
        defer rows.deinit();
        var values: std.ArrayList(c.Value) = .empty;
        while (rows.next()) |row| try values.append(s.a, try c.parse(s.a, row.text(0)));
        if (rows.err) |err| return err;
        return .{ .total = total.int(0), .values = values.items };
    }
    pub fn secret(s: Store, id: []const u8) !?[]u8 {
        var row = (try s.db.row("SELECT value FROM vault WHERE id=?", .{id})) orelse return null;
        defer row.deinit();
        return try s.a.dupe(u8, row.blob(0));
    }
    pub fn putSecret(s: Store, id: []const u8, value: []const u8) !void {
        try s.db.exec("INSERT INTO vault VALUES (?,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value", .{ id, sql.blob(value) });
    }
};
pub fn scopeKey(a: c.A, chain: u64, address: []const u8) ![]const u8 {
    try c.address(address);
    return a.print("{d}:{s}", .{ chain, try std.ascii.allocLowerString(a, address) });
}

test "SQLite checkpoints and entries roll back together and isolate scopes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const s = try Store.init(arena.allocator(), ":memory:");
    defer s.close();
    try s.begin();
    try s.put("one", "users", "1", .{ .string = "alice" });
    try s.saveCheckpoint("one", "users", .{ .block = 1 });
    s.db.rollback();
    try std.testing.expect((try s.checkpoint("one", "users")) == null);
    try std.testing.expectEqual(@as(usize, 0), (try s.entries("one", "users")).count());
    try s.begin();
    try s.put("one", "users", "1", .{ .string = "alice" });
    try s.saveCheckpoint("one", "users", .{ .block = 1 });
    try s.db.commit();
    try std.testing.expect((try s.checkpoint("one", "users")) != null);
    try std.testing.expectEqual(@as(usize, 0), (try s.entries("two", "users")).count());
}

test "failed SQLite opens release native allocations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(dir);
    const path = try a.printSentinel("{s}/missing/database.sqlite3", .{dir}, 0);
    defer a.free(path);
    const flags = sql.OpenFlags.ReadOnly | sql.OpenFlags.NoFollow | sql.OpenFlags.EXResCode;
    try std.testing.expectError(error.DatabaseOpenFailed, openConnection(path, flags));
    const before = sql.c.sqlite3_memory_used();
    for (0..1000) |_| try std.testing.expectError(error.DatabaseOpenFailed, openConnection(path, flags));
    try std.testing.expectEqual(before, sql.c.sqlite3_memory_used());
}

test "point queries isolate scopes and keyset pages survive deletion before the cursor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try Store.init(a, ":memory:");
    defer db.close();
    for (0..31) |i| try db.put("one", "journal", try a.print("{d:0>3}", .{i}), .{ .string = "entry" });
    try db.put("two", "journal", "001", .{ .string = "other" });
    try std.testing.expectEqualStrings("entry", try c.string((try db.get("one", "journal", "001")).?));
    try std.testing.expectEqualStrings("other", try c.string((try db.get("two", "journal", "001")).?));
    try std.testing.expect((try db.get("one", "missing", "001")) == null);
    const first = try db.scan("one", "journal", null, 10);
    try std.testing.expectEqualStrings("009", first.next.?);
    try db.remove("one", "journal", "000");
    const second = try db.scan("one", "journal", first.next, 10);
    try std.testing.expectEqualStrings("010", second.entries[0].id);
    const last = try db.scan("one", "journal", second.next, 100);
    try std.testing.expectEqual(@as(usize, 11), last.entries.len);
    try std.testing.expect(last.next == null);
    try std.testing.expectError(error.PageTooLarge, db.scan("one", "journal", null, 1001));
}
