const std = @import("std");
const c = @import("common.zig");
const abi = @import("abi_codec.zig");
const ms = @import("miniscript");
const vault = @import("vault.zig");
const operations = @import("operations.zig");
pub const Entries = std.StringArrayHashMapUnmanaged(c.Value);
pub const field = @import("commitment_codec.zig").field;
pub const string = @import("commitment_codec.zig").string;
const pair = "{\"name\":\"entries\",\"type\":\"tuple[]\",\"components\":[{\"name\":\"signer\",\"type\":\"address\"},{\"name\":\"proposalKey\",\"type\":\"bytes32\"}]}";
const manifest_layout = "[{\"name\":\"journalVersion\",\"type\":\"uint8\"},{\"name\":\"kind\",\"type\":\"uint8\"},{\"name\":\"checkpointId\",\"type\":\"bytes32\"},{\"name\":\"signers\",\"type\":\"address[]\"},{\"name\":\"signerCounts\",\"type\":\"uint256[]\"},{\"name\":\"signerLastKeys\",\"type\":\"bytes32[]\"},{\"name\":\"retainedHash\",\"type\":\"bytes32\"},{\"name\":\"retainedCount\",\"type\":\"uint32\"},{\"name\":\"chunkCount\",\"type\":\"uint32\"},{\"name\":\"createdAt\",\"type\":\"uint256\"}]";
const chunk_layout = "[{\"name\":\"journalVersion\",\"type\":\"uint8\"},{\"name\":\"kind\",\"type\":\"uint8\"},{\"name\":\"checkpointId\",\"type\":\"bytes32\"},{\"name\":\"chunkIndex\",\"type\":\"uint32\"}," ++ pair ++ "]";
pub fn same(left: []const u8, right: []const u8) bool {
    return std.ascii.eqlIgnoreCase(left, right);
}
pub fn tagged(key: []const u8, tag: []const u8) bool {
    return key.len == 66 and same(key[2..4], tag);
}
fn encode(a: c.A, layout: []const u8, value: c.Value) ![]const u8 {
    return abi.encode(a, try c.parse(a, layout), value);
}
fn decode(a: c.A, layout: []const u8, bytes: []const u8, kind: u8) !c.Value {
    const params = try c.parse(a, layout);
    const value = try abi.named(a, params, try abi.decode(a, params, bytes));
    if (try c.number(a, try field(value, "journalVersion")) != 3 or try c.number(a, try field(value, "kind")) != kind) return error.UnsupportedJournalVersion;
    return value;
}
pub fn chunkKey(a: c.A, id: []const u8, index: usize) ![]const u8 {
    if (index > std.math.maxInt(u32)) return error.CheckpointTooLarge;
    var bytes: [64]u8 = undefined;
    std.mem.writeInt(u256, bytes[0..32], try c.word(id), .big);
    std.mem.writeInt(u256, bytes[32..64], index, .big);
    const hash = ms.bytecode.hash(&bytes);
    return c.hex(a, (hash & ((@as(u256, 1) << 248) - 1)) | (@as(u256, 0xb2) << 248));
}
fn canonicalEntries(a: c.A, entries: []const c.Value) !c.Value {
    for (entries) |entry| {
        try c.address(try string(entry, "signer"));
        if (!tagged(try string(entry, "proposalKey"), "b0")) return error.InvalidCheckpoint;
        _ = try c.word(try string(entry, "proposalKey"));
    }
    const sorted = try a.dupe(c.Value, entries);
    std.mem.sort(c.Value, sorted, a, struct {
        fn less(allocator: c.A, left: c.Value, right: c.Value) bool {
            for ([_][]const u8{ "signer", "proposalKey" }) |name| {
                const l = c.number(allocator, field(left, name) catch unreachable) catch unreachable;
                const r = c.number(allocator, field(right, name) catch unreachable) catch unreachable;
                if (l != r) return l < r;
            }
            return false;
        }
    }.less);
    // Reject duplicates instead of silently changing a claimed retained count.
    for (sorted, 0..) |entry, i| {
        try c.address(try string(entry, "signer"));
        if (!tagged(try string(entry, "proposalKey"), "b0")) return error.InvalidCheckpoint;
        _ = try c.word(try string(entry, "proposalKey"));
        if (i > 0 and same(try string(entry, "signer"), try string(sorted[i - 1], "signer")) and same(try string(entry, "proposalKey"), try string(sorted[i - 1], "proposalKey"))) return error.InvalidCheckpoint;
    }
    return abi.array(a, sorted);
}
fn retainedHash(a: c.A, entries: c.Value) ![]const u8 {
    return c.hex(a, ms.bytecode.hash(try encode(a, "[" ++ pair ++ "]", try abi.array(a, &.{entries}))));
}
pub fn frontiers(a: c.A, entries: Entries, secrets: []const vault.Secret, counts: c.Value) !c.Value {
    var result = std.json.Array.init(a);
    // Journal epochs are ordered oldest first, while the local secret vault stores
    // the current head first. Insertion indexes include every KV record kind.
    var index = secrets.len;
    while (index > 0) {
        index -= 1;
        const signer = try secrets[index].address(a);
        const count = try @import("rpc.zig").integer(a, c.field(counts, signer) orelse return error.CheckpointRequiresIndexedSync);
        if (count > 1_000_000) return error.CheckpointTooLarge;
        const keys = try a.alloc(?[]const u8, count);
        @memset(keys, null);
        for (entries.keys(), entries.values()) |key, raw| if (same(signer, try string(raw, "signer"))) {
            const offset = try @import("rpc.zig").integer(a, try field(raw, "insertionIndex"));
            if (offset >= count or keys[offset] != null) return error.InvalidKvIndex;
            keys[offset] = key;
        };
        for (keys) |key| if (key == null) return error.IncompleteOperationJournal;
        try result.append(try c.parse(a, try c.encode(a, .{ .signer = signer, .count = count, .lastKey = if (count > 0) keys[count - 1].? else try c.hex(a, 0) })));
    }
    return .{ .array = result };
}
pub fn build(a: c.A, id: []const u8, manifest_key: []const u8, frontier: c.Value, entries: []const c.Value, created: u64, chunk_size: usize) !c.Value {
    if (chunk_size == 0 or chunk_size > 128 or entries.len > 100000 or !tagged(manifest_key, "b1")) return error.InvalidCheckpoint;
    const retained = try canonicalEntries(a, entries);
    var signers = std.json.Array.init(a);
    var counts = std.json.Array.init(a);
    var last_keys = std.json.Array.init(a);
    for (frontier.array.items) |item| {
        try signers.append(try field(item, "signer"));
        try counts.append(try field(item, "count"));
        try last_keys.append(try field(item, "lastKey"));
    }
    var records = std.json.Array.init(a);
    var start: usize = 0;
    while (start < retained.array.items.len) : (start += chunk_size) {
        const index = records.items.len;
        const values = try abi.array(a, &.{ try abi.uint(a, 3), try abi.uint(a, 3), .{ .string = id }, try abi.uint(a, index), try abi.array(a, retained.array.items[start..@min(start + chunk_size, retained.array.items.len)]) });
        try records.append(try c.parse(a, try c.encode(a, .{ .key = try chunkKey(a, id, index), .plaintext = try abi.hex(a, try encode(a, chunk_layout, values)) })));
    }
    const values = try abi.array(a, &.{ try abi.uint(a, 3), try abi.uint(a, 2), .{ .string = id }, .{ .array = signers }, .{ .array = counts }, .{ .array = last_keys }, .{ .string = try retainedHash(a, retained) }, try abi.uint(a, retained.array.items.len), try abi.uint(a, records.items.len), try abi.uint(a, created) });
    const bytes = try encode(a, manifest_layout, values);
    const manifest = try decode(a, manifest_layout, bytes, 2);
    try records.append(try c.parse(a, try c.encode(a, .{ .key = manifest_key, .plaintext = try abi.hex(a, bytes) })));
    return c.parse(a, try c.encode(a, .{ .manifestKey = manifest_key, .checkpointId = id, .manifest = manifest, .records = records.items }));
}
fn plaintext(a: c.A, raw: c.Value, secret: vault.Secret) ![]u8 {
    if (!same(try string(raw, "signer"), try secret.address(a))) return error.InvalidCheckpoint;
    return secret.decrypt(a, try abi.unhex(a, try string(raw, "value")));
}
pub const View = struct { entries: Entries, checkpoint: c.Value = .null, rejected: usize = 0 };
fn candidate(a: c.A, entries: Entries, secrets: []const vault.Secret, frontier: c.Value, key: []const u8, secret: vault.Secret) !View {
    const bytes = try plaintext(a, entries.get(key).?, secret);
    defer std.crypto.secureZero(u8, bytes);
    const manifest = try decode(a, manifest_layout, bytes, 2);
    const signers = (try field(manifest, "signers")).array.items;
    const counts = (try field(manifest, "signerCounts")).array.items;
    const lasts = (try field(manifest, "signerLastKeys")).array.items;
    if (signers.len == 0 or signers.len > frontier.array.items.len or counts.len != signers.len or lasts.len != signers.len) return error.InvalidCheckpoint;
    var covered: std.StringHashMapUnmanaged(u256) = .empty;
    for (signers, counts, lasts, 0..) |signer, count, last, i| {
        const expected = frontier.array.items[i];
        const address = try string(expected, "signer");
        const n = try c.number(a, count);
        if (!same(try c.string(signer), address) or n > try c.number(a, try field(expected, "count"))) return error.InvalidCheckpoint;
        if (n == 0) {
            if (try c.number(a, last) != 0) return error.InvalidCheckpoint;
        } else {
            const anchor = entries.get(try c.string(last)) orelse return error.InvalidCheckpoint;
            if (!same(try string(anchor, "signer"), address) or try c.number(a, try field(anchor, "insertionIndex")) != n - 1) return error.InvalidCheckpoint;
        }
        try covered.put(a, address, n);
    }
    const chunks = try @import("rpc.zig").integer(a, try field(manifest, "chunkCount"));
    const count = try @import("rpc.zig").integer(a, try field(manifest, "retainedCount"));
    if (count > 100000 or chunks > count or (count == 0 and chunks != 0)) return error.CheckpointTooLarge;
    var retained = std.json.Array.init(a);
    const id = try string(manifest, "checkpointId");
    for (0..chunks) |i| {
        const raw = entries.get(try chunkKey(a, id, i)) orelse return error.IncompleteCheckpoint;
        const chunk_bytes = try plaintext(a, raw, secret);
        defer std.crypto.secureZero(u8, chunk_bytes);
        const chunk = try decode(a, chunk_layout, chunk_bytes, 3);
        if (!same(try string(chunk, "checkpointId"), id) or try c.number(a, try field(chunk, "chunkIndex")) != i) return error.InvalidCheckpoint;
        const items = (try field(chunk, "entries")).array.items;
        if (items.len == 0 or items.len > 100000 - retained.items.len) return error.CheckpointTooLarge;
        try retained.appendSlice(items);
    }
    if (retained.items.len != count) return error.InvalidCheckpoint;
    const sorted = try canonicalEntries(a, retained.items);
    if (!same(try retainedHash(a, sorted), try string(manifest, "retainedHash"))) return error.InvalidCheckpoint;
    var selected: Entries = .empty;
    for (sorted.array.items) |entry| {
        const proposal_key = try string(entry, "proposalKey");
        const raw = entries.get(proposal_key) orelse return error.IncompleteCheckpoint;
        const signer = try std.ascii.allocLowerString(a, try string(entry, "signer"));
        const bound = covered.get(signer) orelse return error.InvalidCheckpoint;
        if (!same(try string(raw, "signer"), signer) or try c.number(a, try field(raw, "insertionIndex")) >= bound) return error.InvalidCheckpoint;
        try selected.put(a, proposal_key, raw);
    }
    const decoded = try operations.list(a, selected, secrets, null, null);
    if (decoded.invalid != 0 or decoded.unreadable != 0 or decoded.entries.len != count) return error.InvalidCheckpoint;
    // Proposals written after a covered frontier, including newly rotated
    // signer epochs, are always replayed. Audit storage remains untouched.
    for (entries.keys(), entries.values()) |proposal_key, raw| if (tagged(proposal_key, "b0")) {
        const signer = try std.ascii.allocLowerString(a, try string(raw, "signer"));
        if (try c.number(a, try field(raw, "insertionIndex")) >= (covered.get(signer) orelse 0)) try selected.put(a, proposal_key, raw);
    };
    return .{ .entries = selected, .checkpoint = try c.parse(a, try c.encode(a, .{ .manifestKey = key, .manifest = manifest })) };
}
pub fn consume(a: c.A, entries: Entries, secrets: []const vault.Secret, counts: c.Value) !View {
    const frontier = frontiers(a, entries, secrets, counts) catch |err| {
        if (err == error.OutOfMemory) return err;
        return .{ .entries = entries };
    };
    var rejected: usize = 0;
    for (secrets) |secret| {
        var candidates = std.json.Array.init(a);
        for (entries.keys(), entries.values()) |key, raw| if (tagged(key, "b1") and same(try string(raw, "signer"), try secret.address(a))) try candidates.append(raw);
        std.mem.sort(c.Value, candidates.items, a, struct {
            fn less(allocator: c.A, left: c.Value, right: c.Value) bool {
                return (c.number(allocator, field(left, "insertionIndex") catch unreachable) catch unreachable) > (c.number(allocator, field(right, "insertionIndex") catch unreachable) catch unreachable);
            }
        }.less);
        for (candidates.items) |raw| {
            var view = candidate(a, entries, secrets, frontier, try string(raw, "key"), secret) catch |err| {
                if (err == error.OutOfMemory) return err;
                rejected += 1;
                continue;
            };
            view.rejected = rejected;
            return view;
        }
    }
    return .{ .entries = entries, .rejected = rejected };
}
