//! Reproducible native SQLite query benchmark; creates no persistent database.
const std = @import("std");
const c = @import("common.zig");
const Store = @import("store.zig").Store;
pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    var db = try Store.init(arena.allocator(), ":memory:");
    defer db.close();
    var payload: [512]u8 = @splat('x');
    var filled: usize = 0;
    for ([_]usize{ 100, 10000, 100000 }) |size| {
        try db.begin();
        while (filled < size) : (filled += 1) {
            try db.put("benchmark", "journal", try db.a.print("{d:0>8}", .{filled}), .{ .string = &payload });
            _ = arena.reset(.retain_capacity);
        }
        try db.db.commit();
        const id = try init.arena.allocator().print("{d:0>8}", .{size / 2});
        inline for (.{ "point", "keyset", "offset" }) |kind| {
            _ = arena.reset(.free_all);
            var peak: usize = 0;
            const started = std.Io.Clock.awake.now(init.io);
            for (0..100) |_| {
                if (comptime std.mem.eql(u8, kind, "point")) {
                    const record = (try db.get("benchmark", "journal", id)) orelse return error.MissingBenchmarkRecord;
                    if ((try c.string(record)).len != payload.len) return error.InvalidBenchmarkRecord;
                } else if (comptime std.mem.eql(u8, kind, "keyset")) {
                    if ((try db.scan("benchmark", "journal", id, 20)).entries.len != 20) return error.InvalidBenchmarkPage;
                } else {
                    if ((try db.page("benchmark", "journal", size / 2, 20)).values.len != 20) return error.InvalidBenchmarkPage;
                }
                peak = @max(peak, arena.queryCapacity());
                _ = arena.reset(.retain_capacity);
            }
            const ns = started.durationTo(std.Io.Clock.awake.now(init.io)).toNanoseconds();
            try c.print(init.io, "rows={d} query={s} mean_ns={d} arena_bytes={d}\n", .{ size, kind, @divTrunc(ns, 100), peak });
        }
    }
}
