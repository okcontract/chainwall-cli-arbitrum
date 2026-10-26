//! Network work uses a private disk snapshot. Only changed rows enter the short
//! live write transaction, after checking that its source revision still matches.
const std = @import("std");
const sql = @import("zqlite");
const c = @import("common.zig");
const Store = @import("store.zig").Store;
pub const Stage = struct {
    source: Store,
    db: Store,
    io: std.Io,
    path: []const u8,
    revision: i64,
    finished: bool = false,

    pub fn open(source: Store, io: std.Io, dir: []const u8) !Stage {
        const revision = try version(source);
        var random: [12]u8 = undefined;
        try io.randomSecure(&random);
        const path = try source.a.print("{s}/.sync-{s}.sqlite3", .{ dir, std.fmt.bytesToHex(random, .lower) });
        try c.write(io, path, "", false);
        errdefer std.Io.Dir.cwd().deleteFile(io, path) catch {};
        const db = try Store.init(source.a, try source.a.dupeSentinel(u8, path, 0));
        errdefer db.close();
        const backup = sql.c.sqlite3_backup_init(db.db.conn, "main", source.db.conn, "main") orelse return error.DatabaseSnapshotFailed;
        const copied = sql.c.sqlite3_backup_step(backup, -1);
        const closed = sql.c.sqlite3_backup_finish(backup);
        if (copied != sql.c.SQLITE_DONE or closed != sql.c.SQLITE_OK) return error.DatabaseSnapshotFailed;
        try db.db.execNoArgs("PRAGMA temp_store=FILE");
        try db.db.execNoArgs("PRAGMA cache_size=-2048");
        // These small change journals live only in the disposable database.
        inline for (.{
            .{ "entries", "scope,dataset,id", "scope TEXT,dataset TEXT,id TEXT" },
            .{ "checkpoints", "scope,dataset", "scope TEXT,dataset TEXT" },
            .{ "vault", "id", "id TEXT" },
        }) |table| {
            try db.db.execNoArgs("CREATE TABLE changed_" ++ table[0] ++ "(" ++ table[2] ++ ", PRIMARY KEY(" ++ table[1] ++ "))");
            inline for (.{ "INSERT", "UPDATE", "DELETE" }) |operation| {
                const prefix = if (comptime c.eq(u8, operation, "DELETE")) "OLD." else "NEW.";
                const keys = comptime prefixed(table[1], prefix);
                // SELECT avoids inheriting the outer UPSERT's conflict policy.
                try db.db.execNoArgs("CREATE TRIGGER track_" ++ table[0] ++ "_" ++ operation ++ " AFTER " ++ operation ++ " ON " ++ table[0] ++ " BEGIN INSERT INTO changed_" ++ table[0] ++ " SELECT " ++ keys ++ " WHERE NOT EXISTS (SELECT 1 FROM changed_" ++ table[0] ++ " WHERE (" ++ table[1] ++ ")=(" ++ keys ++ ")); END");
            }
        }
        try db.begin();
        return .{ .source = source, .db = db, .io = io, .path = path, .revision = revision };
    }
    pub fn deinit(s: *Stage) void {
        s.db.db.rollback();
        s.db.close();
        for ([_][]const u8{ "", "-wal", "-shm" }) |suffix| {
            const path = s.source.a.print("{s}{s}", .{ s.path, suffix }) catch continue;
            std.Io.Dir.cwd().deleteFile(s.io, path) catch {};
        }
    }
    pub fn commit(s: *Stage) !void {
        if (s.finished) return error.StageAlreadyFinished;
        try s.db.db.commit();
        s.finished = true;
        try s.source.db.exec("ATTACH DATABASE ? AS sync_stage", .{s.path});
        defer s.source.db.execNoArgs("DETACH DATABASE sync_stage") catch {};
        try s.source.begin();
        errdefer s.source.db.rollback();
        if (try version(s.source) != s.revision) return error.DatabaseChangedRetrySync;
        inline for (.{ .{ "entries", "scope,dataset,id" }, .{ "checkpoints", "scope,dataset" }, .{ "vault", "id" } }) |table| {
            try s.source.db.execNoArgs("DELETE FROM main." ++ table[0] ++ " WHERE (" ++ table[1] ++ ") IN (SELECT " ++ table[1] ++ " FROM sync_stage.changed_" ++ table[0] ++ ")");
            try s.source.db.execNoArgs("INSERT INTO main." ++ table[0] ++ " SELECT records.* FROM sync_stage." ++ table[0] ++ " AS records JOIN sync_stage.changed_" ++ table[0] ++ " USING (" ++ table[1] ++ ")");
        }
        try s.source.db.commit();
    }
};
fn version(db: Store) !i64 {
    var row = (try db.db.row("PRAGMA data_version", .{})) orelse return error.DatabaseSnapshotFailed;
    defer row.deinit();
    return row.int(0);
}
fn prefixed(comptime keys: []const u8, comptime prefix: []const u8) []const u8 {
    comptime var result: []const u8 = prefix;
    inline for (keys) |ch| result = result ++ if (ch == ',') "," ++ prefix else &[_]u8{ch};
    return result;
}

test "staged network work allows concurrent writers and refuses stale publication" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    const path = try a.printSentinel("{s}/live.sqlite3", .{dir}, 0);
    const live = try Store.init(a, path);
    defer live.close();
    const other = try Store.init(a, path);
    defer other.close();
    try other.db.busyTimeout(0);
    try live.put("scope", "data", "old", .{ .string = "before" });
    {
        var stage = try Stage.open(live, std.testing.io, dir);
        defer stage.deinit();
        try stage.db.put("scope", "data", "new", .{ .string = "staged" });
        // This write would fail immediately if live BEGIN IMMEDIATE were held.
        try other.begin();
        try other.put("scope", "data", "old", .{ .string = "concurrent" });
        try other.db.commit();
        try std.testing.expectError(error.DatabaseChangedRetrySync, stage.commit());
        try std.testing.expect((try live.get("scope", "data", "new")) == null);
        try std.testing.expectEqualStrings("concurrent", try c.string((try live.get("scope", "data", "old")).?));
    }
    {
        var stage = try Stage.open(live, std.testing.io, dir);
        defer stage.deinit();
        try stage.db.remove("scope", "data", "old");
        try stage.db.put("scope", "data", "new", .{ .string = "intermediate" });
        try stage.db.put("scope", "data", "new", .{ .string = "published" });
        try stage.db.saveCheckpoint("scope", "data", .{ .block = 100 });
        try stage.db.putSecret("encrypted", "ciphertext");
        try stage.commit();
        try std.testing.expect((try live.get("scope", "data", "old")) == null);
        try std.testing.expectEqualStrings("published", try c.string((try live.get("scope", "data", "new")).?));
        try std.testing.expect((try live.checkpoint("scope", "data")) != null);
        try std.testing.expectEqualStrings("ciphertext", (try live.secret("encrypted")).?);
    }
    // A later page failure abandons every staged row and its new checkpoint.
    {
        var stage = try Stage.open(live, std.testing.io, dir);
        defer stage.deinit();
        for (0..600) |i| try stage.db.put("scope", "data", try a.print("page-{d}", .{i}), .{ .integer = 1 });
        try stage.db.saveCheckpoint("scope", "data", .{ .block = 200 });
    }
    try std.testing.expect(!try live.contains("scope", "data", "page-0"));
    try std.testing.expectEqual(100, try c.number(a, c.field((try live.checkpoint("scope", "data")).?, "block").?));
}
