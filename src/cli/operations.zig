const std = @import("std");
const ms = @import("miniscript");
const c = @import("common.zig");
const abi = @import("abi_codec.zig");
const rpc = @import("rpc.zig");
const contracts = @import("contracts.zig");
const sync = @import("sync.zig");
const vault = @import("vault.zig");

const Field = struct { name: []const u8, type: []const u8 };
// Version-3 pending journal wire layout. The identity omits
// creator, executionBindingHash and createdAt.
const payload_fields = [_]Field{
    .{ .name = "version", .type = "uint8" },
    .{ .name = "safe", .type = "address" },
    .{ .name = "creator", .type = "address" },
    .{ .name = "chainId", .type = "uint256" },
    .{ .name = "interactionId", .type = "bytes32" },
    .{ .name = "policyId", .type = "bytes32" },
    .{ .name = "executionBindingHash", .type = "bytes32" },
    .{ .name = "args", .type = "uint256[]" },
    .{ .name = "nativeValue", .type = "uint256" },
    .{ .name = "operationId", .type = "uint256" },
    .{ .name = "payloadHash", .type = "bytes32" },
    .{ .name = "deadline", .type = "uint256" },
    .{ .name = "createdAt", .type = "uint256" },
};
fn layout(a: c.A) !c.Value {
    return c.parse(a, try c.encode(a, .{
        Field{ .name = "journalVersion", .type = "uint8" },
        Field{ .name = "kind", .type = "uint8" },
        Field{ .name = "pendingId", .type = "bytes32" },
        .{ .name = "payload", .type = "tuple", .components = payload_fields },
    }));
}
pub fn encodeProposal(a: c.A, payload: c.Value) ![]const u8 {
    const params = try layout(a);
    var identity_params = std.json.Array.init(a);
    var identity_values = std.json.Array.init(a);
    for ([_]usize{ 1, 3, 4, 5, 7, 8, 9, 10, 11 }) |i| {
        const param = c.field(params.array.items[3], "components").?.array.items[i];
        try identity_params.append(param);
        try identity_values.append(c.field(payload, payload_fields[i].name) orelse return error.InvalidOperationPayload);
    }
    const identity = ms.bytecode.hash(try abi.encode(a, .{ .array = identity_params }, .{ .array = identity_values }));
    const encoded = try abi.encode(a, params, try abi.array(a, &.{ try abi.uint(a, 3), try abi.uint(a, 1), .{ .string = try c.hex(a, identity) }, payload }));
    _ = try proposal(a, encoded);
    return encoded;
}
pub fn proposal(a: c.A, plaintext: []const u8) !c.Value {
    const params = try layout(a);
    const decoded = try abi.decode(a, params, plaintext);
    const values = decoded.array.items;
    if (try c.number(a, values[0]) != 3 or try c.number(a, values[1]) != 1 or try c.number(a, values[3].array.items[0]) != 2) return error.UnsupportedJournalVersion;
    var identity_params = std.json.Array.init(a);
    var identity_values = std.json.Array.init(a);
    const components = c.field(params.array.items[3], "components").?.array.items;
    for ([_]usize{ 1, 3, 4, 5, 7, 8, 9, 10, 11 }) |i| {
        try identity_params.append(components[i]);
        try identity_values.append(values[3].array.items[i]);
    }
    const identity = ms.bytecode.hash(try abi.encode(a, .{ .array = identity_params }, .{ .array = identity_values }));
    if (identity != try c.number(a, values[2])) return error.JournalIdentityMismatch;
    return abi.named(a, params, decoded);
}

pub fn history(a: c.A, v: vault.Vault, scope: []const u8) ![]vault.Secret {
    const raw = (try v.get(try a.print("kv:{s}:history", .{scope}))) orelse return error.RunSyncFirst;
    defer std.crypto.secureZero(u8, raw);
    if (raw.len == 0 or raw.len % 32 != 0 or raw.len > 64 * 32) return error.InvalidVault;
    const secrets = try a.alloc(vault.Secret, raw.len / 32);
    var initialized: usize = 0;
    errdefer for (secrets[0..initialized]) |*secret| secret.deinit();
    for (secrets, 0..) |*secret, i| {
        secret.* = try vault.Secret.init(raw[32 * i ..][0..32].*);
        initialized += 1;
    }
    return secrets;
}
pub fn readSecretHistory(a: c.A, remote: *rpc.Rpc, cat: contracts.Catalog, head: vault.Secret) ![]vault.Secret {
    var secrets: std.ArrayList(vault.Secret) = .empty;
    // Avoid leaving superseded allocations containing historical keys.
    try secrets.ensureTotalCapacity(a, 64);
    errdefer for (secrets.items) |*secret| secret.deinit();
    try secrets.append(a, head);
    const exists = try cat.find("kv", "exists");
    const read = try cat.find("kv", "read");
    while (true) {
        const current = secrets.items[secrets.items.len - 1];
        const key = try current.rotationKey(a);
        if (!(try remote.call(exists, &.{.{ .string = key }})).array.items[0].bool) break;
        const value = (try remote.call(read, &.{.{ .string = key }})).array.items[0];
        const plaintext = try current.decrypt(a, try abi.unhex(a, try c.string(value)));
        defer std.crypto.secureZero(u8, plaintext);
        if (plaintext.len != 96 or ms.bytecode.word(plaintext[0..32]) != 1 or ms.bytecode.word(plaintext[32..64]) >> 160 != 0) return error.InvalidSecretRotation;
        var parent = try vault.Secret.init(plaintext[64..96].*);
        defer parent.deinit();
        if (!c.eq(u8, &parent.signer, plaintext[44..64])) return error.InvalidSecretRotation;
        for (secrets.items) |secret| if (c.eq(u8, &secret.signer, &parent.signer)) return error.SecretRotationCycle;
        if (secrets.items.len == 64) return error.SecretHistoryTooDeep;
        try secrets.append(a, parent);
    }
    return secrets.items;
}
pub fn saveHistory(a: c.A, v: vault.Vault, scope: []const u8, secrets: []const vault.Secret) !void {
    if (secrets.len == 0 or secrets.len > 64) return error.SecretHistoryTooDeep;
    const raw = try a.alloc(u8, secrets.len * 32);
    defer std.crypto.secureZero(u8, raw);
    for (secrets, 0..) |secret, i| @memcpy(raw[32 * i ..][0..32], &secret.private_key);
    try v.put(try a.print("kv:{s}:history", .{scope}), raw);
}

pub fn synchronize(e: *sync.Engine, v: vault.Vault) !void {
    const name = "kv";
    var previous = try e.loadPrevious(name);
    var head = try v.head(e.scope);
    defer head.deinit();
    const secrets = try readSecretHistory(e.a, e.rpc, e.cat, head);
    defer for (secrets) |*secret| secret.deinit();
    try saveHistory(e.a, v, e.scope, secrets);
    const indexed = (try e.rpc.call(try e.cat.find("kv", "indexingEnabled"), &.{})).array.items[0].bool;
    // Recipient tombstones need signer insertion order, including writes in the
    // same block. Upgrade older caches by replaying the immutable index once.
    if (indexed) if (previous) |p| if (c.field(c.field(p, "cursor").?, "orderVersion") == null) {
        previous = null;
    };
    if (previous == null) try e.db.clear(e.scope, name);
    const work = try @import("sync_queue.zig").Queue.init(e.db, name);
    var counts: std.json.ObjectMap = .empty;
    if (indexed) {
        const count_method = try e.cat.find("kv", "keyCountBySigner");
        const page_method = try e.cat.find("kv", "keysBySignerPage");
        var calls: std.ArrayList(rpc.Call) = .empty;
        for (secrets) |secret| try calls.append(e.a, .{ .method = count_method, .args = try abi.array(e.a, &.{.{ .string = try secret.address(e.a) }}) });
        const totals = try e.rpc.calls(calls.items);
        calls.clearRetainingCapacity();

        for (secrets, totals) |secret, total| {
            const signer = try secret.address(e.a);
            const count = try rpc.integer(e.a, total.array.items[0]);
            var offset: u64 = 0;
            if (previous) |p| if (c.field(c.field(c.field(p, "cursor").?, "counts") orelse .null, signer)) |raw| {
                offset = try rpc.integer(e.a, raw);
                if (offset > count) return error.KvIndexRegressedRetryFull;
            };
            if (count - offset > 1_000_000) return error.IndexTooLarge;
            try counts.put(e.a, signer, try abi.uint(e.a, count));
            while (offset < count) {
                var frame: sync.Frame = undefined;
                frame.init(e);
                defer frame.deinit();
                const chunk = &frame.engine;
                var queue = work;
                queue.db = chunk.db;
                const size = @min(@as(u64, 256), count - offset);
                const page = try chunk.rpc.call(page_method, &.{ .{ .string = signer }, try abi.uint(chunk.a, offset), try abi.uint(chunk.a, size) });
                const keys = page.array.items[0].array.items;
                if (keys.len != size) return error.ShortIndexPage;
                for (keys, 0..) |key, index| {
                    const id = try c.string(key);
                    if (try c.word(id) == 0) return error.InvalidKvIndex;
                    if (!try chunk.db.contains(chunk.scope, name, id)) try queue.put(id, try c.parse(chunk.a, try c.encode(chunk.a, .{ .key = id, .signer = signer, .insertionIndex = try abi.uint(chunk.a, offset + index) })));
                }
                offset += size;
            }
        }
    } else {
        const from = try e.logStart(previous);
        const event = e.cat.event("Wrote") orelse return error.InvalidArtifact;
        const topic = try c.hex(e.a, ms.bytecode.hash(try contracts.signature(e.a, event, false)));
        try e.collectLogs(work, topic, from, .kv);
    }
    const method = try e.cat.find("kv", "read");
    while (true) {
        var frame: sync.Frame = undefined;
        frame.init(e);
        defer frame.deinit();
        const chunk = &frame.engine;
        var queue = work;
        queue.db = chunk.db;
        const pending = try queue.page(256);
        if (pending.len == 0) break;
        var calls: [256]rpc.Call = undefined;
        for (pending, 0..) |entry, i| calls[i] = .{ .method = method, .args = try abi.array(chunk.a, &.{.{ .string = entry.id }}) };
        const values = try chunk.rpc.calls(calls[0..pending.len]);
        var infos: []const c.Value = &.{};
        if (indexed) {
            const id_method = try chunk.cat.find("kv", "keyId");
            for (pending, 0..) |entry, i| calls[i] = .{ .method = id_method, .args = try abi.array(chunk.a, &.{.{ .string = entry.id }}) };
            const ids = try chunk.rpc.calls(calls[0..pending.len]);
            const info_method = try chunk.cat.find("kv", "keyInfo");
            for (ids, 0..) |id, i| {
                if (!id.array.items[1].bool) return error.InvalidKvIndex;
                calls[i] = .{ .method = info_method, .args = try abi.array(chunk.a, &.{id.array.items[0]}) };
            }
            infos = try chunk.rpc.calls(calls[0..pending.len]);
        }
        for (pending, values, 0..) |entry, value, i| {
            var record = entry.value;
            try record.object.put(chunk.a, "value", value.array.items[0]);
            if (indexed) {
                const fields = infos[i].array.items;
                if (!fields[1].bool or !std.ascii.eqlIgnoreCase(try c.string(fields[0]), entry.id) or !std.ascii.eqlIgnoreCase(try c.string(fields[3]), try c.string(c.field(record, "signer").?))) return error.InvalidKvIndex;
                try record.object.put(chunk.a, "blockNumber", fields[2]);
            }
            try chunk.db.put(chunk.scope, name, entry.id, record);
            try queue.remove(entry.id);
        }
        try chunk.note(name, pending.len);
    }
    try e.save(name, if (indexed) "signer-key-index" else e.last_log_source, .{ .counts = c.Value{ .object = counts }, .fromBlock = e.from_block, .orderVersion = 1 });
}

pub const Listing = struct { entries: []c.Value, unreadable: usize, invalid: usize };
pub fn list(a: c.A, entries: std.StringArrayHashMapUnmanaged(c.Value), secrets: []const vault.Secret, chain: ?u64, safe: ?[]const u8) !Listing {
    return listView(a, entries, secrets, chain, safe, false);
}
pub fn listView(a: c.A, entries: std.StringArrayHashMapUnmanaged(c.Value), secrets: []const vault.Secret, chain: ?u64, safe: ?[]const u8, audit: bool) !Listing {
    var records: std.ArrayList(c.Value) = .empty;
    var unreadable: usize = 0;
    var invalid: usize = 0;
    for (entries.keys(), entries.values()) |key, raw| {
        if (key.len != 66 or !std.ascii.eqlIgnoreCase(key[2..4], "b0")) continue;
        const envelope = abi.unhex(a, try c.string(c.field(raw, "value").?)) catch {
            invalid += 1;
            continue;
        };
        if (envelope.len < 49) {
            invalid += 1;
            continue;
        }
        const secret = blk: {
            for (secrets) |secret| if (c.eq(u8, &secret.signer, envelope[1..21])) break :blk secret;
            unreadable += 1;
            continue;
        };
        if (c.field(raw, "signer")) |signer| if (!std.ascii.eqlIgnoreCase(try c.string(signer), try secret.address(a))) {
            invalid += 1;
            continue;
        };
        const plaintext = secret.decrypt(a, envelope) catch {
            invalid += 1;
            continue;
        };
        defer std.crypto.secureZero(u8, plaintext);
        var record = proposal(a, plaintext) catch {
            invalid += 1;
            continue;
        };
        const payload = c.field(record, "payload").?;
        if (chain) |id| if (try c.number(a, c.field(payload, "chainId").?) != id) continue;
        if (safe) |address| if (!std.ascii.eqlIgnoreCase(address, try c.string(c.field(payload, "safe").?))) continue;
        try record.object.put(a, "key", .{ .string = key });
        try record.object.put(a, "signer", .{ .string = try secret.address(a) });
        for ([_][]const u8{ "blockNumber", "transactionHash", "logIndex", "insertionIndex" }) |field| if (c.field(raw, field)) |value| try record.object.put(a, field, value);
        try records.append(a, record);
    }
    sort(a, records.items);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var result: std.ArrayList(c.Value) = .empty;
    for (records.items) |record| {
        const id = try c.string(c.field(record, "pendingId").?);
        if (!audit and seen.contains(id)) continue;
        try seen.put(a, id, {});
        try result.append(a, record);
    }
    return .{ .entries = result.items, .unreadable = unreadable, .invalid = invalid };
}

pub fn sort(a: c.A, entries: []c.Value) void {
    std.mem.sort(c.Value, entries, a, struct {
        fn less(allocator: c.A, left: c.Value, right: c.Value) bool {
            for ([_][]const u8{ "createdAt", "blockNumber", "logIndex" }) |field| {
                const l = c.number(allocator, c.field(if (c.eq(u8, field, "createdAt")) c.field(left, "payload").? else left, field) orelse .{ .string = "0" }) catch 0;
                const r = c.number(allocator, c.field(if (c.eq(u8, field, "createdAt")) c.field(right, "payload").? else right, field) orelse .{ .string = "0" }) catch 0;
                if (l != r) return l > r;
            }
            for ([_][]const u8{ "pendingId", "key" }) |name| {
                const l = c.string(c.field(left, name) orelse .null) catch "";
                const r = c.string(c.field(right, name) orelse .null) catch "";
                if (!c.eq(u8, l, r)) return std.mem.lessThan(u8, r, l);
            }
            return false;
        }
    }.less);
}

/// Status is checked only against an explicitly selected, verified Interact
/// belonging to this Registry. Other execution chains remain unverified.
pub fn statuses(a: c.A, client: *rpc.Rpc, cat: contracts.Catalog, interact: []const u8, registry: []const u8, listing: Listing) !c.Value {
    const old_address = client.address;
    defer client.address = old_address;
    client.address = interact;
    const component = (try client.call(try cat.find("interact", "chainwallComponentId"), &.{})).array.items[0];
    if (try c.number(a, component) != ms.bytecode.hash("Chainwall.Interact")) return error.NotAChainwallInteract;
    const bound = (try client.call(try cat.find("interact", "registry"), &.{})).array.items[0];
    if (!std.ascii.eqlIgnoreCase(try c.string(bound), registry)) return error.InteractRegistryMismatch;
    var calls: std.ArrayList(rpc.Call) = .empty;
    const executed = try cat.find("interact", "isOperationExecuted");
    for (listing.entries) |record| {
        const id = c.field(c.field(record, "payload").?, "operationId").?;
        try calls.append(a, .{ .method = executed, .args = try abi.array(a, &.{id}) });
    }
    const closed = try client.calls(calls.items);
    calls.clearRetainingCapacity();
    for (listing.entries, closed) |record, value| {
        if (value.array.items[0].bool) continue;
        const id = c.field(c.field(record, "payload").?, "operationId").?;
        for ([_][]const u8{ "getOperationSafe", "getOperationPolicyId", "getOperationNativeValue" }) |name| try calls.append(a, .{ .method = try cat.find("interact", name), .args = try abi.array(a, &.{id}) });
    }
    const values = try client.calls(calls.items);
    var results: std.json.ObjectMap = .empty;
    var at: usize = 0;
    for (listing.entries, closed) |record, value| {
        const payload = c.field(record, "payload").?;
        // AppEx erases executed/withdrawn records. Its predicate also returns
        // true for unknown IDs, so "closed" is deliberately not proof of execution.
        var status: []const u8 = "closed";
        if (!value.array.items[0].bool) {
            const matches = std.ascii.eqlIgnoreCase(try c.string(values[at].array.items[0]), try c.string(c.field(payload, "safe").?)) and try c.number(a, values[at + 1].array.items[0]) == try c.number(a, c.field(payload, "policyId").?) and try c.number(a, values[at + 2].array.items[0]) == try c.number(a, c.field(payload, "nativeValue").?);
            at += 3;
            status = if (!matches) "mismatch" else if (try c.number(a, c.field(payload, "deadline").?) < client.block.timestamp) "expired" else "active";
        }
        try results.put(a, try c.string(c.field(record, "pendingId").?), .{ .string = status });
    }
    return .{ .object = results };
}
