const std = @import("std");
const ms = @import("miniscript");
const c = @import("common.zig");
const abi = @import("abi_codec.zig");
const contracts = @import("contracts.zig");
const rpc = @import("rpc.zig");
const storage = @import("store.zig");
const Explorer = @import("explorer.zig").Explorer;

pub const Dataset = struct { name: []const u8, stem: []const u8, record: ?[]const u8 = null };
pub const datasets = [_]Dataset{
    .{ .name = "users", .stem = "User" },
    .{ .name = "groups", .stem = "Group", .record = "getGroupInfo" },
    .{ .name = "policies", .stem = "Policy", .record = "getPolicy" },
    .{ .name = "orgs", .stem = "Org", .record = "getOrgByHash" },
    .{ .name = "contracts", .stem = "Contract", .record = "getContractByHash" },
    .{ .name = "tokens", .stem = "Token", .record = "getTokenByHash" },
    .{ .name = "interactions", .stem = "Interaction", .record = "getInteractionBundle" },
    .{ .name = "safes", .stem = "Safe" },
    .{ .name = "accounts", .stem = "Account" },
};
pub const Engine = struct {
    a: c.A,
    db: storage.Store,
    rpc: *rpc.Rpc,
    cat: contracts.Catalog,
    scope: []const u8,
    full: bool = false,
    from_block: u64 = 0,
    lookback: u64 = 128,
    explorer: Explorer,

    pub fn query(e: *Engine, name: []const u8, args: []const c.Value) !c.Value {
        return e.rpc.call(try e.cat.find("registry", name), args);
    }
    fn indexCall(e: *Engine, dataset: Dataset, suffix: []const u8, args: []const c.Value) !rpc.Call {
        return .{ .method = try e.cat.find("registry", try e.a.print("get{s}Index{s}", .{ dataset.stem, suffix })), .args = try abi.array(e.a, args) };
    }
    pub fn loadPrevious(e: *Engine, name: []const u8) !?c.Value {
        if (e.full) return null;
        const checkpoint = (try e.db.checkpoint(e.scope, name)) orelse return null;
        const cursor = c.field(checkpoint, "cursor") orelse return null;
        if (cursor != .object) return null;
        if (c.field(cursor, "fromBlock")) |from| if (try rpc.integer(e.a, from) != e.from_block) return null;
        for (datasets) |dataset| if (c.eq(u8, name, dataset.name) and !c.eq(u8, name, "users")) {
            _ = rpc.integer(e.a, c.field(cursor, "nextId") orelse return null) catch return null;
            _ = rpc.integer(e.a, c.field(cursor, "currentEpoch") orelse return null) catch return null;
        };
        const block = c.field(checkpoint, "block") orelse return null;
        const height = try rpc.integer(e.a, c.field(block, "number") orelse return null);
        if (height > e.rpc.block.number or try rpc.integer(e.a, c.field(checkpoint, "version") orelse return null) != 1) return null;
        const hash = try c.string(c.field(block, "hash") orelse return null);
        if (hash.len != 66) return null;
        if (!try e.rpc.canonical(.{ .number = height, .hash = hash, .timestamp = 0 })) return null;
        return checkpoint;
    }
    pub fn save(e: *Engine, name: []const u8, strategy: []const u8, cursor: anytype) !void {
        try e.db.saveCheckpoint(e.scope, name, .{ .version = 1, .block = e.rpc.block, .strategy = strategy, .cursor = cursor });
    }
    pub fn logStart(e: *Engine, previous: ?c.Value) !u64 {
        const checkpoint = previous orelse return e.from_block;
        const number = try rpc.integer(e.a, c.field(c.field(checkpoint, "block").?, "number").?);
        // Explorer indexing can lag the RPC head. Revisit a bounded window;
        // immutable KV values already in SQLite are still fetched only once.
        return @max(e.from_block, if (e.lookback == 0) try std.math.add(u64, number, 1) else number -| (e.lookback - 1));
    }
    pub fn timelocks(e: *Engine) !void {
        const name = "timelocks";
        var previous = try e.loadPrevious(name);
        const indexed = (try e.query("indexingEnabled", &.{})).array.items[0].bool;
        const executed_total = if (indexed) try rpc.integer(e.a, (try e.query("getExecutedActionCount", &.{})).array.items[0]) else 0;
        if (indexed) if (previous) |p| if (c.field(c.field(p, "cursor").?, "executedCount")) |count| {
            if (try rpc.integer(e.a, count) > executed_total) previous = null;
        };
        if (previous == null) try e.db.clear(e.scope, name);
        const entries = try e.db.entries(e.scope, name);
        var wanted: std.StringArrayHashMapUnmanaged(void) = .empty;
        // Pending actions may change status even if they disappear from the
        // pending index; retain and refresh all previously observed live IDs.
        for (entries.keys(), entries.values()) |id, value| {
            const status = try c.number(e.a, c.field(value, "status").?);
            if (status == 1 or status == 2) try wanted.put(e.a, id, {});
        }
        var executed_count: u64 = 0;
        if (indexed) {
            for ([_][]const u8{ "Pending", "Executed" }) |kind| {
                const count = if (c.eq(u8, kind, "Executed")) executed_total else try rpc.integer(e.a, (try e.query("getPendingActionCount", &.{})).array.items[0]);
                var offset: u64 = 0;
                if (c.eq(u8, kind, "Executed")) {
                    executed_count = count;
                    if (previous) |p| if (c.field(c.field(p, "cursor").?, "executedCount")) |v| {
                        const old = try rpc.integer(e.a, v);
                        if (old <= count) offset = old;
                    };
                }
                const method = try e.cat.find("registry", try e.a.print("get{s}ActionSummaries", .{kind}));
                var calls: std.ArrayList(rpc.Call) = .empty;
                if (count - offset > 1_000_000) return error.IndexTooLarge;
                while (offset < count) : (offset += @min(@as(u64, 256), count - offset)) try calls.append(e.a, .{ .method = method, .args = try abi.array(e.a, &.{ try abi.uint(e.a, offset), try abi.uint(e.a, @min(@as(u64, 256), count - offset)) }) });
                for (try e.rpc.calls(calls.items), calls.items) |page, call| {
                    const values = try abi.namedResult(e.a, method.abi, page);
                    if (values.array.items.len != try c.number(e.a, call.args.array.items[1])) return error.ShortIndexPage;
                    for (values.array.items) |summary| {
                        const id = try c.string(c.field(summary, "id").?);
                        try e.db.put(e.scope, name, id, summary);
                        _ = wanted.orderedRemove(id);
                    }
                }
            }
        } else {
            const from = try e.logStart(previous);
            const event = e.cat.event("ActionQueued") orelse return error.InvalidArtifact;
            const topic = try c.hex(e.a, ms.bytecode.hash(try contracts.signature(e.a, event, false)));
            const logs = try e.explorer.logs(e.rpc.address, topic, from, e.rpc.block.number);
            try e.rpc.verifyLogs(logs);
            for (logs) |log| {
                const id = try c.string(c.field(log, "topics").?.array.items[1]);
                try wanted.put(e.a, id, {});
            }
        }
        const method = try e.cat.find("registry", "getActionSummary");
        var calls: std.ArrayList(rpc.Call) = .empty;
        for (wanted.keys()) |id| try calls.append(e.a, .{ .method = method, .args = try abi.array(e.a, &.{.{ .string = id }}) });
        for (try e.rpc.calls(calls.items), wanted.keys()) |value, id| try e.db.put(e.scope, name, id, try abi.namedResult(e.a, method.abi, value));
        try e.save(name, if (indexed) "pending-and-executed-index" else "etherscan", .{ .executedCount = executed_count, .fromBlock = e.from_block });
    }
    pub fn registry(e: *Engine, dataset: Dataset) !void {
        var prev = try e.loadPrevious(dataset.name);
        if (prev) |p| if (c.eq(u8, try c.string(c.field(c.field(p, "block").?, "hash").?), e.rpc.block.hash)) return;
        if (c.eq(u8, dataset.name, "users")) {
            const count = try rpc.integer(e.a, (try e.query("getUserCount", &.{})).array.items[0]);
            var calls: std.ArrayList(rpc.Call) = .empty;
            const method = try e.cat.find("registry", "getUserAt");
            if (count > 1_000_000) return error.IndexTooLarge;
            for (0..count) |i| try calls.append(e.a, .{ .method = method, .args = try abi.array(e.a, &.{try abi.uint(e.a, i)}) });
            const values = try e.rpc.calls(calls.items);
            try e.db.clear(e.scope, dataset.name);
            for (values, 0..) |v, i| try e.db.put(e.scope, dataset.name, try c.hex(e.a, i), v.array.items[0]);
            return e.save(dataset.name, "pages", .{ .count = count });
        }
        const state = try e.rpc.calls(&.{ try e.indexCall(dataset, "NextId", &.{}), try e.indexCall(dataset, "CurrentEpoch", &.{}) });
        const next = try rpc.integer(e.a, state[0].array.items[0]);
        const epoch = try rpc.integer(e.a, state[1].array.items[0]);
        var old_next: u64 = 0;
        var old_epoch: u64 = 0;
        if (prev) |p| {
            const cursor = c.field(p, "cursor").?;
            old_next = try rpc.integer(e.a, c.field(cursor, "nextId").?);
            old_epoch = try rpc.integer(e.a, c.field(cursor, "currentEpoch").?);
            if (old_next > next or old_epoch > epoch) prev = null;
        }
        if (prev == null) {
            old_next = 0;
            old_epoch = epoch;
            try e.db.clear(e.scope, dataset.name);
        }
        var entries = try e.db.entries(e.scope, dataset.name);
        var touched: std.AutoHashMapUnmanaged(u64, void) = .empty;
        var calls: std.ArrayList(rpc.Call) = .empty;
        const first_page = old_next / 256;
        const page_end = next / 256 + @intFromBool(next % 256 != 0);
        if (page_end - first_page > 1_000_000) return error.IndexTooLarge;
        if (next > old_next) {
            for (first_page..page_end) |page| try calls.append(e.a, try e.indexCall(dataset, "AlivePage", &.{try abi.uint(e.a, page)}));
            for (try e.rpc.calls(calls.items), first_page..) |v, page| {
                var bits = try c.number(e.a, v.array.items[0]);
                while (bits != 0) {
                    const id = try bitId(page, @intCast(@ctz(bits)));
                    bits &= bits - 1;
                    if (id >= old_next and id < next) try touched.put(e.a, id, {});
                }
            }
        }
        if (prev != null) {
            // The last observed epoch is inclusive: its journal remains mutable.
            calls.clearRetainingCapacity();
            if (epoch - old_epoch > 1_000_000 or epoch == std.math.maxInt(u64)) return error.IndexTooLarge;
            for (old_epoch..epoch + 1) |ep| try calls.append(e.a, try e.indexCall(dataset, "EpochPageCount", &.{try abi.uint(e.a, ep)}));
            const counts = try e.rpc.calls(calls.items);
            calls.clearRetainingCapacity();
            var epochs: std.ArrayList(u64) = .empty;
            for (counts, old_epoch..) |v, ep| {
                const n = try rpc.integer(e.a, v.array.items[0]);
                if (n > 1_000_000 or calls.items.len + n > 1_000_000) return error.IndexTooLarge;
                for (0..n) |i| {
                    try calls.append(e.a, try e.indexCall(dataset, "EpochPageAt", &.{ try abi.uint(e.a, ep), try abi.uint(e.a, i) }));
                    try epochs.append(e.a, ep);
                }
            }
            const pages = try e.rpc.calls(calls.items);
            calls.clearRetainingCapacity();
            for (pages, epochs.items) |page, ep| try calls.append(e.a, try e.indexCall(dataset, "Journal", &.{ try abi.uint(e.a, ep), page.array.items[0] }));
            const journals = try e.rpc.calls(calls.items);
            for (journals, pages) |journal, page_value| {
                const page = try rpc.integer(e.a, page_value.array.items[0]);
                var deletes = try c.number(e.a, journal.array.items[1]);
                while (deletes != 0) {
                    const id = try bitId(page, @intCast(@ctz(deletes)));
                    deletes &= deletes - 1;
                    if (id >= next) continue;
                    const key = try c.hex(e.a, id);
                    _ = entries.orderedRemove(key);
                    _ = touched.remove(id);
                    try e.db.remove(e.scope, dataset.name, key);
                }
                var updates = try c.number(e.a, journal.array.items[0]);
                while (updates != 0) {
                    const id = try bitId(page, @intCast(@ctz(updates)));
                    updates &= updates - 1;
                    if (id < next and entries.contains(try c.hex(e.a, id))) try touched.put(e.a, id, {});
                }
            }
        }
        const ids = try e.a.alloc(u64, touched.count());
        var iterator = touched.keyIterator();
        var at: usize = 0;
        while (iterator.next()) |id| : (at += 1) ids[at] = id.*;
        std.mem.sort(u64, ids, {}, std.sort.asc(u64));
        calls.clearRetainingCapacity();
        at = 0;
        while (at < ids.len) {
            const end = @min(at + 256, ids.len);
            var chunk = std.json.Array.init(e.a);
            for (ids[at..end]) |id| try chunk.append(try abi.uint(e.a, id));
            try calls.append(e.a, try e.indexCall(dataset, "Values", &.{.{ .array = chunk }}));
            at = end;
        }
        var values: std.ArrayList(c.Value) = .empty;
        for (try e.rpc.calls(calls.items), 0..) |page, i| {
            const items = page.array.items[0].array.items;
            if (items.len != @min(@as(usize, 256), ids.len - i * 256)) return error.ShortIndexPage;
            try values.appendSlice(e.a, items);
        }
        calls.clearRetainingCapacity();
        if (dataset.record) |name| for (values.items) |key| try calls.append(e.a, .{ .method = try e.cat.find("registry", name), .args = try abi.array(e.a, &.{key}) });
        const records = try e.rpc.calls(calls.items);
        for (ids, values.items, 0..) |id, key, i| {
            const record = if (dataset.record != null) try abi.namedResult(e.a, calls.items[i].method.abi, records[i]) else @as(c.Value, .null);
            try e.db.put(e.scope, dataset.name, try c.hex(e.a, id), try c.parse(e.a, try c.encode(e.a, .{ .id = try e.a.print("{d}", .{id}), .key = key, .record = record })));
        }
        try e.save(dataset.name, "stable-index", .{ .nextId = try e.a.print("{d}", .{next}), .currentEpoch = try e.a.print("{d}", .{epoch}) });
    }

    /// Metadata has its own update lifecycle, so refresh it even when the
    /// entity's stable index has not changed. Only ciphertext is persisted.
    pub fn labels(e: *Engine) !void {
        var calls: std.ArrayList(rpc.Call) = .empty;
        var keys: std.ArrayList([]const u8) = .empty;
        const method = try e.cat.find("registry", "getMeta");
        for ([_][2][]const u8{ .{ "users", "user" }, .{ "accounts", "account" }, .{ "safes", "account" }, .{ "contracts", "contract" } }) |pair| {
            const entries = try e.db.entries(e.scope, pair[0]);
            for (entries.values()) |entry| {
                const id = try c.string(c.field(entry, "key") orelse entry);
                try keys.append(e.a, try e.a.print("{s}:{s}", .{ pair[0], try std.ascii.allocLowerString(e.a, id) }));
                try calls.append(e.a, .{ .method = method, .args = try abi.array(e.a, &.{ .{ .string = pair[1] }, .{ .string = id }, .{ .string = "label" } }) });
            }
        }
        const values = try e.rpc.calls(calls.items);
        try e.db.clear(e.scope, "labels");
        for (keys.items, values) |id, value| try e.db.put(e.scope, "labels", id, value.array.items[0]);
        try e.save("labels", "metadata", .{});
    }
};
fn bitId(page: u64, bit: u8) !u64 {
    return std.math.add(u64, try std.math.mul(u64, page, 256), bit);
}
