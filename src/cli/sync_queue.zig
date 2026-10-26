//! Temporary SQLite queues keep pending sync work out of the process arena.
const std = @import("std");
const c = @import("common.zig");
const Store = @import("store.zig").Store;
pub const Queue = struct {
    db: Store,
    name: []const u8,
    pub fn init(db: Store, name: []const u8) !Queue {
        try db.db.execNoArgs("CREATE TEMP TABLE IF NOT EXISTS sync_work (name TEXT,id TEXT,value TEXT,PRIMARY KEY(name,id))");
        try db.db.exec("DELETE FROM sync_work WHERE name=?", .{name});
        return .{ .db = db, .name = name };
    }
    pub fn put(q: Queue, id: []const u8, value: c.Value) !void {
        try q.db.db.exec("INSERT INTO sync_work VALUES (?,?,?) ON CONFLICT(name,id) DO UPDATE SET value=excluded.value", .{ q.name, id, try c.encode(q.db.a, value) });
    }
    pub fn remove(q: Queue, id: []const u8) !void {
        try q.db.db.exec("DELETE FROM sync_work WHERE name=? AND id=?", .{ q.name, id });
    }
    pub fn page(q: Queue, count: u32) ![]const Store.Entry {
        if (count == 0 or count > 256) return error.PageTooLarge;
        var rows = try q.db.db.rows("SELECT id,value FROM sync_work WHERE name=? ORDER BY id LIMIT ?", .{ q.name, @as(i64, count) });
        defer rows.deinit();
        var result: std.ArrayList(Store.Entry) = .empty;
        while (rows.next()) |row| try result.append(q.db.a, .{ .id = try q.db.a.dupe(u8, row.text(0)), .value = try c.parse(q.db.a, row.text(1)) });
        if (rows.err) |err| return err;
        return result.items;
    }
};
