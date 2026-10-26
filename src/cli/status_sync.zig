//! Paged journal decryption and individually encrypted status snapshots.
const std = @import("std");
const c = @import("common.zig");
const sync = @import("sync.zig");
const operations = @import("operations.zig");
const Vault = @import("vault.zig").Vault;
const records = @import("sealed_records.zig");
pub fn run(e: *sync.Engine, vault: Vault, chain: u64, registry: []const u8, interact: ?[]const u8) !void {
    const scope = try @import("operation_status.zig").key(e.a, e.scope, chain, registry);
    const imports = try @import("operation_share.zig").key(e.a, chain, registry);
    const secrets = try operations.history(e.a, vault, e.scope);
    defer for (secrets) |*secret| secret.deinit();
    {
        var frame: sync.Frame = undefined;
        frame.init(e);
        defer frame.deinit();
        var v = vault;
        v.a = frame.engine.a;
        v.db = frame.engine.db;
        try @import("operation_share.zig").migrate(v, imports);
    }
    try e.db.clear(scope, "sealed");
    if (interact) |target| {
        for ([_]bool{ false, true }) |local| {
            var cursor_buffer: [128]u8 = undefined;
            var cursor: ?[]const u8 = null;
            while (true) {
                var frame: sync.Frame = undefined;
                frame.init(e);
                defer frame.deinit();
                const chunk = &frame.engine;
                var v = vault;
                v.a = chunk.a;
                v.db = chunk.db;
                const page = if (local) try records.page(v, imports, cursor) else try chunk.db.scan(e.scope, "kv", cursor, 256);
                var listing: operations.Listing = undefined;
                if (local) {
                    var values: std.ArrayList(c.Value) = .empty;
                    for (page.entries) |entry| {
                        if (try records.contains(v, scope, entry.id)) continue;
                        try values.append(chunk.a, try operations.proposal(chunk.a, try operations.encodeProposal(chunk.a, c.field(entry.value, "payload") orelse return error.InvalidOperationPayload)));
                    }
                    listing = .{ .entries = values.items, .invalid = 0, .unreadable = 0 };
                } else {
                    var values: std.StringArrayHashMapUnmanaged(c.Value) = .empty;
                    for (page.entries) |entry| try values.put(chunk.a, entry.id, entry.value);
                    listing = try operations.list(chunk.a, values, secrets, chain, null);
                }
                const statuses = try operations.statuses(chunk.a, chunk.rpc, chunk.cat, target, registry, listing);
                for (statuses.object.keys(), statuses.object.values()) |id, value| try records.put(v, scope, id, value);
                try chunk.note("operation statuses", listing.entries.len);
                const next = page.next orelse break;
                if (next.len > cursor_buffer.len) return error.InvalidCacheKey;
                @memcpy(cursor_buffer[0..next.len], next);
                cursor = cursor_buffer[0..next.len];
            }
        }
    }
    try vault.put(scope, try c.encode(e.a, .{ .formatVersion = 2, .block = e.rpc.block, .interact = interact }));
}
