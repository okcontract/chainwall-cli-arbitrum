const std = @import("std");
const c = @import("common.zig");
const abi = @import("abi_codec.zig");
const storage = @import("store.zig");
const sync = @import("sync.zig");
const vault = @import("vault.zig");

pub const Entry = struct {
    kind: []const u8,
    id: []const u8,
    label: []const u8 = "",
    address: ?[]const u8 = null,
    name: ?[]const u8 = null,
    org: ?[]const u8 = null,
};

/// Stored labels use AES-128-SIV with a
/// vector of authenticated context strings, not the KV AES-GCM envelope.
pub fn key(secret: vault.Secret) [32]u8 {
    var hash = std.crypto.hash.sha3.Keccak256.init(.{});
    hash.update(&secret.encryption_key);
    hash.update("okcontracts:stored-label:siv-key:v1");
    var result: [32]u8 = undefined;
    hash.final(&result);
    return result;
}

fn text(bytes: []const u8) ?[]const u8 {
    const value = std.mem.trim(u8, std.mem.trimEnd(u8, bytes, "\x00"), " \t\r\n");
    if (value.len == 0 or !std.unicode.utf8ValidateSlice(value)) return null;
    // Labels are rendered in a terminal and in a line-oriented completion protocol.
    for (value) |ch| if (ch < 32 or ch == 127) return null;
    return value;
}

pub const scopes = @import("schema.zig").label_scopes;

pub fn validateText(label: []const u8) !void {
    if (text(label) == null or std.mem.indexOfScalar(u8, label, 0) != null) return error.InvalidLabelText;
    for (label) |ch| if (ch < 32 or ch == 127) return error.InvalidLabelText;
}

pub fn validateContext(registry: []const u8, scope: []const u8, entity: ?[]const u8) !void {
    try c.address(registry);
    if (!@import("schema.zig").contains(scopes, scope)) return error.InvalidLabelScope;
    if (c.eq(u8, scope, "user-label") or c.eq(u8, scope, "account-label")) {
        try c.address(entity orelse return error.LabelEntityRequired);
    } else if (entity != null) return error.LabelEntityNotApplicable;
}

fn context(a: c.A, chain: u64, registry: []const u8, scope: []const u8, entity: ?[]const u8) ![5][]const u8 {
    try validateContext(registry, scope, entity);
    var aad: [5][]const u8 = .{
        "okcontracts:stored-label:v1",
        try a.print("chain:{d}", .{chain}),
        try a.print("registry:{s}", .{try std.ascii.allocLowerString(a, registry)}),
        try a.print("scope:{s}", .{scope}),
        "",
    };
    if (entity) |id| aad[4] = try a.print("entity:{s}", .{try std.ascii.allocLowerString(a, id)});
    return aad;
}

pub fn encode(a: c.A, label: []const u8, material: [32]u8, chain: u64, registry: []const u8, scope: []const u8, entity: ?[]const u8) ![]const u8 {
    if (label.len > 16) return error.EncryptedLabelTooLong;
    try validateText(label);
    const aad = try context(a, chain, registry, scope, entity);
    var plaintext: [16]u8 = @splat(0);
    defer std.crypto.secureZero(u8, &plaintext);
    @memcpy(plaintext[0..label.len], label);
    var bytes: [32]u8 = undefined;
    std.crypto.aead.aes_siv.Aes128Siv.encryptWithAdVector(bytes[16..], bytes[0..16], &plaintext, aad[0..if (entity != null) 5 else 4], material);
    return abi.hex(a, &bytes);
}

pub fn decode(a: c.A, value: []const u8, material: ?[32]u8, chain: u64, registry: []const u8, scope: []const u8, entity: ?[]const u8) !?[]const u8 {
    const bytes = abi.unhex(a, value) catch return null;
    if (bytes.len >= 64 and std.mem.readInt(u256, bytes[0..32], .big) == 32) {
        const length = std.mem.readInt(u256, bytes[32..64], .big);
        if (length <= bytes.len - 64) return text(bytes[64..][0..@intCast(length)]);
    }
    if (bytes.len != 32) return null;
    if (text(bytes)) |plain| return plain;
    const siv_key = material orelse return null;
    const aad = try context(a, chain, registry, scope, entity);
    var plaintext: [16]u8 = undefined;
    defer std.crypto.secureZero(u8, &plaintext);
    std.crypto.aead.aes_siv.Aes128Siv.decryptWithAdVector(&plaintext, bytes[16..], bytes[0..16].*, aad[0..if (entity != null) 5 else 4], siv_key) catch return null;
    return if (text(&plaintext)) |plain| try a.dupe(u8, plain) else null;
}

pub fn load(a: c.A, db: storage.Store, chain: u64, registry: []const u8, material: ?[32]u8) ![]Entry {
    return loadKeys(a, db, chain, registry, if (material) |k| &.{k} else &.{});
}

pub fn decodeKeys(a: c.A, value: []const u8, materials: []const [32]u8, chain: u64, registry: []const u8, scope: []const u8, entity: ?[]const u8) !?[]const u8 {
    if (try decode(a, value, null, chain, registry, scope, entity)) |plain| return plain;
    for (materials) |material| if (try decode(a, value, material, chain, registry, scope, entity)) |plain| return plain;
    return null;
}

pub fn loadKeys(a: c.A, db: storage.Store, chain: u64, registry: []const u8, materials: []const [32]u8) ![]Entry {
    const scope = try storage.scopeKey(a, chain, registry);
    var entries: std.ArrayList(Entry) = .empty;
    const metadata = try db.entries(scope, "labels");
    for (sync.datasets) |dataset| {
        const records = try db.entries(scope, dataset.name);
        for (records.values()) |value| {
            const id = c.string(c.field(value, "key") orelse value) catch continue;
            const record = c.field(value, "record") orelse .null;
            var entry: Entry = .{ .kind = dataset.name, .id = id };
            if (c.eq(u8, dataset.name, "contracts") or c.eq(u8, dataset.name, "tokens")) {
                const org = c.string(c.field(record, "org") orelse .null) catch "";
                const name = c.string(c.field(record, "id") orelse .null) catch "";
                if (name.len > 0) entry.label = try a.print("{s}/{s}", .{ org, name });
                entry.name = name;
                entry.org = org;
                entry.address = c.string(c.field(c.field(record, "latest") orelse .null, "addr") orelse .null) catch null;
                if (entry.address == null and c.eq(u8, dataset.name, "tokens")) for (entries.items) |known| {
                    if (c.eq(u8, known.kind, "contracts") and std.ascii.eqlIgnoreCase(known.id, id)) {
                        entry.address = known.address;
                        break;
                    }
                };
            } else if (c.eq(u8, dataset.name, "orgs")) {
                if (record == .array and record.array.items.len > 0) entry.label = c.string(record.array.items[0]) catch "";
            }
            const label_scope: ?[]const u8 = if (c.eq(u8, dataset.name, "groups")) "group-id" else if (c.eq(u8, dataset.name, "interactions")) "interaction-id" else if (c.eq(u8, dataset.name, "policies")) "policy-id" else null;
            if (label_scope) |kind| entry.label = (try decodeKeys(a, id, materials, chain, registry, kind, null)) orelse entry.label;
            const meta_key = try a.print("{s}:{s}", .{ dataset.name, try std.ascii.allocLowerString(a, id) });
            if (metadata.get(meta_key)) |meta| {
                const raw = c.string(meta) catch "";
                const address_label = c.eq(u8, dataset.name, "users") or c.eq(u8, dataset.name, "accounts") or c.eq(u8, dataset.name, "safes");
                const kind = if (c.eq(u8, dataset.name, "users")) "user-label" else if (address_label) "account-label" else "contract-label";
                if (try decodeKeys(a, raw, materials, chain, registry, kind, if (address_label) id else null)) |label| {
                    // Keep organization/name usable even when a contract also
                    // has a display label. Both references select the same ID.
                    if (entry.label.len > 0 and !c.eq(u8, entry.label, label)) try entries.append(a, entry);
                    entry.label = label;
                }
            }
            try entries.append(a, entry);
        }
    }
    const timelocks = try db.entries(scope, "timelocks");
    for (timelocks.keys()) |id| try entries.append(a, .{ .kind = "timelocks", .id = id });
    return entries.toOwnedSlice(a);
}

/// Explicit @labels always resolve to the stored key. In particular an
/// encrypted interaction/group ID must never be re-hashed from its label.
pub fn resolve(entries: []const Entry, kind: ?[]const u8, value: []const u8, address: bool) ![]const u8 {
    if (!std.mem.startsWith(u8, value, "@")) return value;
    var result: ?[]const u8 = null;
    for (entries) |entry| {
        if (kind) |wanted| if (!c.eq(u8, wanted, entry.kind)) continue;
        if (entry.label.len == 0 or !c.eq(u8, entry.label, value[1..])) continue;
        const id = if (address) entry.address orelse if (entry.id.len == 42) entry.id else continue else entry.id;
        if (result) |previous| if (!std.ascii.eqlIgnoreCase(previous, id)) return error.AmbiguousLabelUseId;
        result = id;
    }
    return result orelse error.UnknownLabelUnlockOrSync;
}

/// ABI types cannot identify the collection. Use parameter semantics first,
/// then the method's collection for generic names such as `h` and `id`.
pub fn collection(group: []const u8, method: []const u8, param: []const u8) ?[]const u8 {
    if (c.eq(u8, param, "interactionId") or c.eq(u8, param, "interactionIds")) return "interactions";
    if (c.eq(u8, param, "policyId") or c.eq(u8, param, "policyIds")) return "policies";
    if (c.eq(u8, param, "groupId") or c.eq(u8, param, "groupHash") or c.eq(u8, param, "groupHashes") or c.eq(u8, param, "groupIds")) return "groups";
    if (c.eq(u8, param, "user") or c.eq(u8, param, "member")) return "users";
    if (c.eq(u8, param, "safe")) return "safes";
    if (c.eq(u8, param, "account")) return "accounts";
    if (c.eq(u8, param, "org") or c.eq(u8, param, "orgId")) return "orgs";
    if (c.eq(u8, param, "actionId")) return "timelocks";
    // Contract version labels are a different keyspace from contract hashes.
    if (c.eq(u8, param, "label")) return null;
    if (c.eq(u8, param, "id") or c.eq(u8, param, "h") or c.eq(u8, param, "key")) {
        if (std.mem.indexOf(u8, method, "Group") != null) return "groups";
        if (std.mem.indexOf(u8, method, "Safe") != null) return "safes";
        if (std.mem.startsWith(u8, group, "timelock")) return "timelocks";
        for (sync.datasets) |dataset| if (c.eq(u8, dataset.name, group)) return group;
    }
    return null;
}
