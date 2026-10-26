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
    log_source: @import("event_logs.zig").Source = .auto,
    last_log_source: []const u8 = "rpc-logs",
    last_log_from: u64 = 0,
    backfill_from: ?u64 = null,
    progress: bool = false,
    processed: usize = 0,
    peak_page_bytes: usize = 0,

    pub fn note(e: *Engine, dataset: []const u8, count: usize) !void {
        e.processed += count;
        if (e.progress) {
            var buffer: [256]u8 = undefined;
            try std.Io.File.stderr().writeStreamingAll(e.rpc.client.io, try std.fmt.bufPrint(&buffer, "Syncing {s}: processed {d} records\n", .{ dataset, count }));
        }
    }

    pub fn collectLogs(e: *Engine, work: @import("sync_queue.zig").Queue, topic: []const u8, from: u64, kind: enum { timelock, kv }) !void {
        const Consumer = struct {
            engine: *Engine,
            queue: @import("sync_queue.zig").Queue,
            kv: bool,
            fn consume(raw: *anyopaque, a: c.A, logs: []const c.Value) !void {
                const self: *@This() = @ptrCast(@alignCast(raw));
                const remote = self.engine.rpc;
                const previous = remote.a;
                remote.a = a;
                defer {
                    if (remote.last_error) |failure| remote.last_error = blk: {
                        const bytes = c.encode(a, failure) catch break :blk null;
                        break :blk c.parse(previous, bytes) catch null;
                    };
                    remote.a = previous;
                }
                try remote.verifyLogs(logs);
                var queue = self.queue;
                queue.db.a = a;
                for (logs) |log| {
                    const topics = c.field(log, "topics").?.array.items;
                    if (topics.len != (if (self.kv) @as(usize, 3) else 2)) return error.InvalidEventTopics;
                    const id = try c.string(topics[1]);
                    if (!self.kv) {
                        try queue.put(id, .null);
                    } else if (!try queue.db.contains(self.engine.scope, "kv", id)) {
                        const signer = try a.print("0x{x:0>40}", .{@as(u160, @truncate(try c.number(a, topics[2])))});
                        try queue.put(id, try c.parse(a, try c.encode(a, .{ .key = id, .signer = signer, .blockNumber = c.field(log, "blockNumber").?, .transactionHash = c.field(log, "transactionHash").?, .logIndex = c.field(log, "logIndex").? })));
                    }
                }
                try self.engine.note("logs", logs.len);
            }
        };
        var consumer: Consumer = .{ .engine = e, .queue = work, .kv = kind == .kv };
        var sink: @import("log_sink.zig").Sink = .{ .context = &consumer, .consume = Consumer.consume };
        defer e.peak_page_bytes = @max(e.peak_page_bytes, sink.peak_bytes);
        e.last_log_source = "rpc-logs";
        e.last_log_from = from;
        if (e.log_source == .explorer or (e.log_source == .auto and e.explorer.api_key != null)) {
            try e.db.db.execNoArgs("SAVEPOINT explorer_scan");
            const complete = if (e.explorer.walk(e.rpc.address, topic, from, e.rpc.block.number, &sink)) true else |err| blk: {
                try e.db.db.execNoArgs("ROLLBACK TO explorer_scan");
                try e.db.db.execNoArgs("RELEASE explorer_scan");
                if (e.log_source == .explorer or err == error.OutOfMemory or err == error.Canceled) return err;
                e.rpc.last_error = null;
                break :blk false;
            };
            if (complete) {
                try e.db.db.execNoArgs("RELEASE explorer_scan");
                e.last_log_source = "etherscan";
                return;
            }
        }
        try @import("event_logs.zig").walkRpc(e.rpc, e.rpc.address, topic, from, e.rpc.block.number, &sink);
    }

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
        const logs = c.eq(u8, strategy, "etherscan") or c.eq(u8, strategy, "rpc-logs");
        const discovery: ?@import("log_coverage.zig").Coverage = if (logs) try @import("log_coverage.zig").advance(e.a, try e.db.checkpoint(e.scope, name), strategy, e.from_block, e.last_log_from, e.rpc.block.number) else null;
        try e.db.saveCheckpoint(e.scope, name, .{ .version = 1, .block = e.rpc.block, .strategy = strategy, .cursor = cursor, .discovery = discovery });
    }
    pub fn logStart(e: *Engine, previous: ?c.Value) !u64 {
        return @import("log_coverage.zig").start(e.a, previous, e.from_block, e.lookback, e.backfill_from, e.rpc.block.number);
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
        const work = try @import("sync_queue.zig").Queue.init(e.db, name);
        // Pending actions may disappear from the current pending index.
        var cursor_buffer: [1024]u8 = undefined;
        var cursor: ?[]const u8 = null;
        while (true) {
            var frame: Frame = undefined;
            frame.init(e);
            defer frame.deinit();
            const chunk = &frame.engine;
            var queue = work;
            queue.db = chunk.db;
            const page = try chunk.db.scan(chunk.scope, name, cursor, 256);
            for (page.entries) |entry| {
                const status = try c.number(chunk.a, c.field(entry.value, "status").?);
                if (status == 1 or status == 2) try queue.put(entry.id, .null);
            }
            const next = page.next orelse break;
            if (next.len > cursor_buffer.len) return error.InvalidCacheKey;
            @memcpy(cursor_buffer[0..next.len], next);
            cursor = cursor_buffer[0..next.len];
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
                if (count - offset > 1_000_000) return error.IndexTooLarge;
                while (offset < count) {
                    var frame: Frame = undefined;
                    frame.init(e);
                    defer frame.deinit();
                    const chunk = &frame.engine;
                    var queue = work;
                    queue.db = chunk.db;
                    const size = @min(@as(u64, 256), count - offset);
                    const values = try abi.namedResult(chunk.a, method.abi, try chunk.rpc.call(method, &.{ try abi.uint(chunk.a, offset), try abi.uint(chunk.a, size) }));
                    if (values.array.items.len != size) return error.ShortIndexPage;
                    for (values.array.items) |summary| {
                        const id = try c.string(c.field(summary, "id").?);
                        try chunk.db.put(chunk.scope, name, id, summary);
                        try queue.remove(id);
                    }
                    try chunk.note(name, @intCast(size));
                    offset += size;
                }
            }
        } else {
            const from = try e.logStart(previous);
            const event = e.cat.event("ActionQueued") orelse return error.InvalidArtifact;
            const topic = try c.hex(e.a, ms.bytecode.hash(try contracts.signature(e.a, event, false)));
            try e.collectLogs(work, topic, from, .timelock);
        }
        const method = try e.cat.find("registry", "getActionSummary");
        while (true) {
            var frame: Frame = undefined;
            frame.init(e);
            defer frame.deinit();
            const chunk = &frame.engine;
            var queue = work;
            queue.db = chunk.db;
            const pending = try queue.page(256);
            if (pending.len == 0) break;
            var calls: [256]rpc.Call = undefined;
            for (pending, 0..) |entry, i| calls[i] = .{ .method = method, .args = try abi.array(chunk.a, &.{.{ .string = entry.id }}) };
            for (try chunk.rpc.calls(calls[0..pending.len]), pending) |value, entry| {
                try chunk.db.put(chunk.scope, name, entry.id, try abi.namedResult(chunk.a, method.abi, value));
                try queue.remove(entry.id);
            }
            try chunk.note(name, pending.len);
        }
        try e.save(name, if (indexed) "pending-and-executed-index" else e.last_log_source, .{ .executedCount = executed_count, .fromBlock = e.from_block });
    }
    pub fn registry(e: *Engine, dataset: Dataset) !void {
        var prev = try e.loadPrevious(dataset.name);
        if (prev) |p| if (c.eq(u8, try c.string(c.field(c.field(p, "block").?, "hash").?), e.rpc.block.hash)) return;
        if (c.eq(u8, dataset.name, "users")) {
            const count = try rpc.integer(e.a, (try e.query("getUserCount", &.{})).array.items[0]);
            const method = try e.cat.find("registry", "getUserAt");
            if (count > 1_000_000) return error.IndexTooLarge;
            try e.db.clear(e.scope, dataset.name);
            var offset: u64 = 0;
            while (offset < count) {
                var frame: Frame = undefined;
                frame.init(e);
                defer frame.deinit();
                const chunk = &frame.engine;
                const n: usize = @intCast(@min(256, count - offset));
                var calls: [256]rpc.Call = undefined;
                for (calls[0..n], 0..) |*call, i| call.* = .{ .method = method, .args = try abi.array(chunk.a, &.{try abi.uint(chunk.a, offset + i)}) };
                for (try chunk.rpc.calls(calls[0..n]), 0..) |value, i| try chunk.db.put(chunk.scope, dataset.name, try c.hex(chunk.a, offset + i), value.array.items[0]);
                try chunk.note(dataset.name, n);
                offset += n;
            }
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
        const work = try @import("sync_queue.zig").Queue.init(e.db, dataset.name);
        const first_page = old_next / 256;
        const page_end = next / 256 + @intFromBool(next % 256 != 0);
        if (page_end - first_page > 1_000_000) return error.IndexTooLarge;
        var page_at = first_page;
        while (next > old_next and page_at < page_end) {
            var frame: Frame = undefined;
            frame.init(e);
            defer frame.deinit();
            const chunk = &frame.engine;
            var queue = work;
            queue.db = chunk.db;
            const n: usize = @intCast(@min(64, page_end - page_at));
            var calls: [64]rpc.Call = undefined;
            for (calls[0..n], 0..) |*call, i| call.* = try chunk.indexCall(dataset, "AlivePage", &.{try abi.uint(chunk.a, page_at + i)});
            for (try chunk.rpc.calls(calls[0..n]), 0..) |value, i| {
                var bits = try c.number(chunk.a, value.array.items[0]);
                while (bits != 0) {
                    const id = try bitId(page_at + i, @intCast(@ctz(bits)));
                    bits &= bits - 1;
                    if (id >= old_next and id < next) try queue.put(try c.hex(chunk.a, id), .null);
                }
            }
            page_at += n;
        }
        if (prev != null) {
            // Include the last observed epoch: its journal remains mutable.
            if (epoch - old_epoch > 1_000_000 or epoch == std.math.maxInt(u64)) return error.IndexTooLarge;
            var total_pages: u64 = 0;
            for (old_epoch..epoch + 1) |ep| {
                var epoch_frame: Frame = undefined;
                epoch_frame.init(e);
                defer epoch_frame.deinit();
                const epoch_chunk = &epoch_frame.engine;
                const n = try rpc.integer(epoch_chunk.a, (try epoch_chunk.rpc.calls(&.{try epoch_chunk.indexCall(dataset, "EpochPageCount", &.{try abi.uint(epoch_chunk.a, ep)})}))[0].array.items[0]);
                if (n > 1_000_000 or total_pages + n > 1_000_000) return error.IndexTooLarge;
                total_pages += n;
                var offset: u64 = 0;
                while (offset < n) {
                    var frame: Frame = undefined;
                    frame.init(epoch_chunk);
                    defer frame.deinit();
                    const chunk = &frame.engine;
                    var queue = work;
                    queue.db = chunk.db;
                    const size: usize = @intCast(@min(64, n - offset));
                    var calls: [64]rpc.Call = undefined;
                    for (calls[0..size], 0..) |*call, i| call.* = try chunk.indexCall(dataset, "EpochPageAt", &.{ try abi.uint(chunk.a, ep), try abi.uint(chunk.a, offset + i) });
                    const pages = try chunk.rpc.calls(calls[0..size]);
                    for (calls[0..size], pages) |*call, page| call.* = try chunk.indexCall(dataset, "Journal", &.{ try abi.uint(chunk.a, ep), page.array.items[0] });
                    for (try chunk.rpc.calls(calls[0..size]), pages) |journal, page| {
                        const number = try rpc.integer(chunk.a, page.array.items[0]);
                        var deletes = try c.number(chunk.a, journal.array.items[1]);
                        while (deletes != 0) {
                            const id = try bitId(number, @intCast(@ctz(deletes)));
                            deletes &= deletes - 1;
                            if (id >= next) continue;
                            const key = try c.hex(chunk.a, id);
                            try queue.remove(key);
                            try chunk.db.remove(chunk.scope, dataset.name, key);
                        }
                        var updates = try c.number(chunk.a, journal.array.items[0]);
                        while (updates != 0) {
                            const id = try bitId(number, @intCast(@ctz(updates)));
                            updates &= updates - 1;
                            const key = try c.hex(chunk.a, id);
                            if (id < next and try chunk.db.contains(chunk.scope, dataset.name, key)) try queue.put(key, .null);
                        }
                    }
                    offset += size;
                }
            }
        }
        while (true) {
            var frame: Frame = undefined;
            frame.init(e);
            defer frame.deinit();
            const chunk = &frame.engine;
            var queue = work;
            queue.db = chunk.db;
            const pending = try queue.page(256);
            if (pending.len == 0) break;
            var ids = std.json.Array.init(chunk.a);
            for (pending) |entry| try ids.append(try abi.uint(chunk.a, try c.word(entry.id)));
            const values = (try chunk.rpc.calls(&.{try chunk.indexCall(dataset, "Values", &.{.{ .array = ids }})}))[0].array.items[0].array.items;
            if (values.len != pending.len) return error.ShortIndexPage;
            var calls: [256]rpc.Call = undefined;
            if (dataset.record) |name| for (values, 0..) |key, i| {
                calls[i] = .{ .method = try chunk.cat.find("registry", name), .args = try abi.array(chunk.a, &.{key}) };
            };
            const records = if (dataset.record != null) try chunk.rpc.calls(calls[0..values.len]) else &.{};
            for (pending, values, 0..) |entry, key, i| {
                const record = if (dataset.record != null) try abi.namedResult(chunk.a, calls[i].method.abi, records[i]) else @as(c.Value, .null);
                try chunk.db.put(chunk.scope, dataset.name, entry.id, try c.parse(chunk.a, try c.encode(chunk.a, .{ .id = try chunk.a.print("{d}", .{try c.word(entry.id)}), .key = key, .record = record })));
                try queue.remove(entry.id);
            }
            try chunk.note(dataset.name, pending.len);
        }
        try e.save(dataset.name, "stable-index", .{ .nextId = try e.a.print("{d}", .{next}), .currentEpoch = try e.a.print("{d}", .{epoch}) });
    }

    /// Metadata has its own update lifecycle, so refresh it even when the
    /// entity's stable index has not changed. Only ciphertext is persisted.
    pub fn labels(e: *Engine) !void {
        const method = try e.cat.find("registry", "getMeta");
        try e.db.clear(e.scope, "labels");
        for ([_][2][]const u8{ .{ "users", "user" }, .{ "accounts", "account" }, .{ "safes", "account" }, .{ "contracts", "contract" } }) |pair| {
            var cursor_buffer: [1024]u8 = undefined;
            var cursor: ?[]const u8 = null;
            while (true) {
                var frame: Frame = undefined;
                frame.init(e);
                defer frame.deinit();
                const chunk = &frame.engine;
                const page = try chunk.db.scan(chunk.scope, pair[0], cursor, 256);
                var calls: [256]rpc.Call = undefined;
                var keys: [256][]const u8 = undefined;
                for (page.entries, 0..) |entry, i| {
                    const id = try c.string(c.field(entry.value, "key") orelse entry.value);
                    keys[i] = try chunk.a.print("{s}:{s}", .{ pair[0], try std.ascii.allocLowerString(chunk.a, id) });
                    calls[i] = .{ .method = method, .args = try abi.array(chunk.a, &.{ .{ .string = pair[1] }, .{ .string = id }, .{ .string = "label" } }) };
                }
                for (keys[0..page.entries.len], try chunk.rpc.calls(calls[0..page.entries.len])) |id, value| try chunk.db.put(chunk.scope, "labels", id, value.array.items[0]);
                try chunk.note("labels", page.entries.len);
                const next = page.next orelse break;
                if (next.len > cursor_buffer.len) return error.InvalidCacheKey;
                @memcpy(cursor_buffer[0..next.len], next);
                cursor = cursor_buffer[0..next.len];
            }
        }
        try e.save("labels", "metadata", .{});
    }
};
/// A frame owns one decoded page. HTTP connection storage has an independent
/// lifetime; only request/results and the cloned engine use this arena.
pub const Frame = struct {
    arena: std.heap.ArenaAllocator,
    parent: *Engine,
    engine: Engine,
    previous_allocator: c.A,
    pub fn init(f: *Frame, parent: *Engine) void {
        f.arena = .init(std.heap.page_allocator);
        f.parent = parent;
        f.engine = parent.*;
        f.engine.a = f.arena.allocator();
        f.engine.db.a = f.engine.a;
        f.engine.explorer.a = f.engine.a;
        f.engine.processed = 0;
        f.engine.peak_page_bytes = 0;
        f.previous_allocator = parent.rpc.a;
        parent.rpc.a = f.engine.a;
        parent.rpc.last_error = null;
    }
    pub fn deinit(f: *Frame) void {
        const remote = f.parent.rpc;
        if (remote.last_error) |failure| remote.last_error = blk: {
            const bytes = c.encode(f.engine.a, failure) catch break :blk null;
            break :blk c.parse(f.previous_allocator, bytes) catch null;
        };
        remote.a = f.previous_allocator;
        f.parent.processed += f.engine.processed;
        f.parent.peak_page_bytes = @max(f.parent.peak_page_bytes, f.arena.queryCapacity() + f.engine.peak_page_bytes);
        f.parent.last_log_source = f.engine.last_log_source;
        f.parent.last_log_from = f.engine.last_log_from;
        f.arena.deinit();
    }
};
fn bitId(page: u64, bit: u8) !u64 {
    return std.math.add(u64, try std.math.mul(u64, page, 256), bit);
}

test "paged user synchronization releases page arenas as the index grows" {
    const mock = @import("test_rpc.zig");
    var peaks: [2]usize = undefined;
    for ([_]usize{ 600, 1200 }, 0..) |count, scenario| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const db = try storage.Store.init(a, ":memory:");
        defer db.close();
        var replies: std.ArrayList(mock.Reply) = .empty;
        try replies.append(a, .{ .body = try c.encode(a, .{.{ .jsonrpc = "2.0", .id = 1, .result = try c.hex(a, count) }}) });
        var offset: usize = 0;
        while (offset < count) {
            const page_end = @min(offset + 256, count);
            while (offset < page_end) {
                const end = @min(offset + 100, page_end);
                var results = std.json.Array.init(a);
                for (offset..end) |i| try results.append(try c.parse(a, try c.encode(a, .{ .jsonrpc = "2.0", .id = i - offset + 1, .result = try c.hex(a, i + 1) })));
                try replies.append(a, .{ .body = try c.encode(a, c.Value{ .array = results }) });
                offset = end;
            }
        }
        var server = try mock.Server.init(std.testing.io, replies.items);
        defer server.deinit();
        var serving = try std.testing.io.concurrent(mock.Server.serve, .{&server});
        defer _ = serving.cancel(std.testing.io) catch {};
        var remote = try rpc.Rpc.initEndpoint(a, std.testing.io, try server.url(a), 42161);
        defer remote.deinit();
        remote.address = "0x1111111111111111111111111111111111111111";
        remote.block = .{ .number = 100, .hash = "0x1111111111111111111111111111111111111111111111111111111111111111", .timestamp = 1 };
        remote.timeout_seconds = 1;
        remote.read_attempts = 1;
        var engine: Engine = .{ .a = a, .db = db, .rpc = &remote, .cat = try contracts.Catalog.load(a), .scope = "test", .full = true, .explorer = .{ .a = a, .io = std.testing.io, .dir = "", .chain = 42161 } };
        try db.begin();
        try engine.registry(datasets[0]);
        try db.db.commit();
        const checkpoint = (try db.checkpoint("test", "users")).?;
        try std.testing.expectEqual(count, try rpc.integer(a, c.field(c.field(checkpoint, "cursor").?, "count").?));
        try std.testing.expectEqual(count, engine.processed);
        try std.testing.expectEqual(count, try c.word(try c.string((try db.get("test", "users", try c.hex(a, count - 1))).?)));
        peaks[scenario] = engine.peak_page_bytes;
        try serving.await(std.testing.io);
        try std.testing.expectEqual(replies.items.len, server.requests);
    }
    try std.testing.expect(peaks[0] > 0 and peaks[1] <= peaks[0] * 2);
}
