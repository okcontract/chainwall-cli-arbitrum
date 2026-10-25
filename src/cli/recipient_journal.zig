const std = @import("std");
const c = @import("common.zig");
const abi = @import("abi_codec.zig");
const ms = @import("miniscript");
const Secret = @import("vault.zig").Secret;

pub const namespace = blk: {
    @setEvalBranchQuota(10000);
    break :blk ms.bytecode.hash("chainwall.destination.allow.v2");
};
pub const Context = struct { storageChainId: u64, kvAddress: []const u8, executionChainId: u64, registryAddress: []const u8, policyId: []const u8, vault: []const u8 };
const Field = struct { name: []const u8, type: []const u8 };
const fields = [_]Field{
    .{ .name = "version", .type = "uint8" }, .{ .name = "kind", .type = "uint8" }, .{ .name = "recordKey", .type = "bytes32" }, .{ .name = "storageChainId", .type = "uint256" }, .{ .name = "kvAddress", .type = "address" }, .{ .name = "secretSigner", .type = "address" }, .{ .name = "executionChainId", .type = "uint256" }, .{ .name = "registryAddress", .type = "address" }, .{ .name = "policyId", .type = "bytes32" }, .{ .name = "vault", .type = "address" }, .{ .name = "namespace", .type = "bytes32" }, .{ .name = "commitment", .type = "bytes32" }, .{ .name = "recipient", .type = "address" }, .{ .name = "mask", .type = "bytes32" }, .{ .name = "label", .type = "string" }, .{ .name = "createdAt", .type = "uint256" },
};
pub fn field(value: c.Value, name: []const u8) !c.Value {
    return c.field(value, name) orelse error.InvalidRecipientRecord;
}
fn equal(a: c.A, left: c.Value, right: c.Value) !bool {
    return try c.number(a, left) == try c.number(a, right);
}
pub fn contextValue(a: c.A, context: Context) !c.Value {
    if (context.storageChainId == 0 or context.executionChainId == 0 or try c.word(context.policyId) == 0) return error.InvalidRecipientContext;
    for ([_][]const u8{ context.kvAddress, context.registryAddress, context.vault }) |address| try c.address(address);
    return c.parse(a, try c.encode(a, context));
}
pub fn commitment(a: c.A, policy: []const u8, account: []const u8, recipient: []const u8, mask: []const u8) ![]const u8 {
    var bytes: [192]u8 = undefined;
    for ([_]u256{ ms.bytecode.hash("RecipientCommitV2(bytes32 policyId,address vault,address recipient,bytes32 mask,uint256 schema)"), try c.word(policy), try c.word(account), try c.word(recipient), try c.word(mask), 2 }, 0..) |word, i| std.mem.writeInt(u256, bytes[i * 32 ..][0..32], word, .big);
    return c.hex(a, ms.bytecode.hash(&bytes));
}
pub fn create(a: c.A, io: std.Io, secret: Secret, context: Context, recipient: ?[]const u8, label: []const u8, removing: ?[]const u8) !c.Value {
    var record = try contextValue(a, context);
    var random: [32]u8 = undefined;
    try io.randomSecure(&random);
    random[0] = 0xb3;
    try record.object.put(a, "recordKey", .{ .string = try abi.hex(a, &random) });
    try record.object.put(a, "secretSigner", .{ .string = try secret.address(a) });
    try record.object.put(a, "version", try abi.uint(a, 1));
    try record.object.put(a, "kind", try abi.uint(a, if (removing == null) 1 else 2));
    try record.object.put(a, "namespace", .{ .string = try c.hex(a, namespace) });
    try record.object.put(a, "createdAt", try abi.uint(a, @intCast(std.Io.Clock.real.now(io).toSeconds())));
    var mask: [32]u8 = @splat(0);
    defer std.crypto.secureZero(u8, &mask);
    if (removing == null) {
        try c.address(recipient orelse return error.RecipientRequired);
        if (c.trim(label).len == 0 or label.len > 1024 or !std.unicode.utf8ValidateSlice(label)) return error.InvalidRecipientLabel;
        const params = try c.parse(a, try c.encode(a, .{ Field{ .name = "domain", .type = "string" }, fields[6], fields[7], fields[8], fields[9], fields[12] }));
        const message = try abi.encode(a, params, try abi.array(a, &.{ .{ .string = "chainwall.destination.mask.v2" }, try abi.uint(a, context.executionChainId), .{ .string = context.registryAddress }, .{ .string = context.policyId }, .{ .string = context.vault }, .{ .string = recipient.? } }));
        std.crypto.auth.hmac.sha2.HmacSha256.create(&mask, message, &secret.encryption_key);
    }
    try record.object.put(a, "recipient", .{ .string = recipient orelse "0x0000000000000000000000000000000000000000" });
    try record.object.put(a, "mask", .{ .string = try abi.hex(a, &mask) });
    try record.object.put(a, "label", .{ .string = if (removing == null) c.trim(label) else "" });
    try record.object.put(a, "commitment", .{ .string = removing orelse try commitment(a, context.policyId, context.vault, recipient.?, try abi.hex(a, &mask)) });
    return record;
}
pub fn encode(a: c.A, record: c.Value) ![]const u8 {
    return abi.encode(a, try c.parse(a, try c.encode(a, fields)), record);
}
pub fn decode(a: c.A, bytes: []const u8, context: Context, key: []const u8, signer: []const u8) !?c.Value {
    const params = try c.parse(a, try c.encode(a, fields));
    const decoded = try abi.decode(a, params, bytes);
    if (!c.eq(u8, bytes, try abi.encode(a, params, decoded))) return error.InvalidRecipientRecord;
    const record = try abi.named(a, params, decoded);
    if (try c.number(a, try field(record, "version")) != 1 or try c.number(a, try field(record, "namespace")) != namespace) return error.InvalidRecipientRecord;
    const kind = try c.number(a, try field(record, "kind"));
    if (kind != 1 and kind != 2) return error.InvalidRecipientRecord;
    if (!try equal(a, try field(record, "recordKey"), .{ .string = key }) or !try equal(a, try field(record, "secretSigner"), .{ .string = signer })) return error.InvalidRecipientRecord;
    const wanted = try contextValue(a, context);
    for (wanted.object.keys(), wanted.object.values()) |name, value| if (!try equal(a, try field(record, name), value)) return null;
    if (kind == 2) {
        if (try c.number(a, try field(record, "recipient")) != 0 or try c.number(a, try field(record, "mask")) != 0 or (try c.string(try field(record, "label"))).len != 0) return error.InvalidRecipientRecord;
    } else {
        const recipient = try c.string(try field(record, "recipient"));
        try c.address(recipient);
        if (c.trim(try c.string(try field(record, "label"))).len == 0) return error.InvalidRecipientRecord;
        const expected = try commitment(a, context.policyId, context.vault, recipient, try c.string(try field(record, "mask")));
        if (!try equal(a, try field(record, "commitment"), .{ .string = expected })) return error.InvalidRecipientRecord;
    }
    return record;
}
pub const Listing = struct { entries: []c.Value, invalid: usize, unreadable: usize };
pub fn list(a: c.A, raw: std.StringArrayHashMapUnmanaged(c.Value), secrets: []const Secret, context: Context) !Listing {
    const Ordered = struct { value: c.Value, signer: usize, major: u64, minor: u64 };
    var ordered: std.ArrayList(Ordered) = .empty;
    var invalid: usize = 0;
    var unreadable: usize = 0;
    for (raw.keys(), raw.values()) |key, entry| {
        if (key.len != 66 or !std.ascii.eqlIgnoreCase(key[2..4], "b3")) continue;
        const envelope = abi.unhex(a, try c.string(try field(entry, "value"))) catch {
            invalid += 1;
            continue;
        };
        if (envelope.len < 49) {
            invalid += 1;
            continue;
        }
        var found = false;
        for (secrets, 0..) |secret, index| {
            if (!c.eq(u8, envelope[1..21], &secret.signer)) continue;
            found = true;
            const plaintext = secret.decrypt(a, envelope) catch {
                invalid += 1;
                break;
            };
            defer std.crypto.secureZero(u8, plaintext);
            const record = decode(a, plaintext, context, key, try secret.address(a)) catch {
                invalid += 1;
                break;
            };
            const value = record orelse break;
            const position = c.field(entry, "insertionIndex");
            const major = try @import("rpc.zig").integer(a, position orelse c.field(entry, "blockNumber") orelse return error.RunSyncFirst);
            const minor = if (position != null) 0 else try @import("rpc.zig").integer(a, c.field(entry, "logIndex") orelse return error.RunSyncFirst);
            try ordered.append(a, .{ .value = value, .signer = index, .major = major, .minor = minor });
            break;
        }
        if (!found) unreadable += 1;
    }
    std.mem.sort(Ordered, ordered.items, {}, struct {
        fn less(_: void, left: Ordered, right: Ordered) bool {
            // Secret history is newest-first; replay older epochs first.
            if (left.signer != right.signer) return left.signer > right.signer;
            if (left.major != right.major) return left.major < right.major;
            return left.minor < right.minor;
        }
    }.less);
    for (ordered.items, 0..) |item, i| if (i > 0) {
        const previous = ordered.items[i - 1];
        if (previous.signer == item.signer and previous.major == item.major and previous.minor == item.minor) return error.InvalidRecipientJournalOrder;
    };
    var live: std.StringArrayHashMapUnmanaged(c.Value) = .empty;
    var by_address: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (ordered.items) |item| {
        const key = try c.string(try field(item.value, "commitment"));
        if (try c.number(a, try field(item.value, "kind")) == 2) {
            _ = live.orderedRemove(key);
        } else {
            const recipient = try c.string(try field(item.value, "recipient"));
            if (by_address.get(recipient)) |previous| if (!c.eq(u8, previous, key)) {
                _ = live.orderedRemove(previous);
            };
            try by_address.put(a, recipient, key);
            try live.put(a, key, item.value);
        }
    }
    return .{ .entries = live.values(), .invalid = invalid, .unreadable = unreadable };
}
pub fn select(listing: Listing, reference: []const u8) !c.Value {
    if (listing.invalid > 0 or listing.unreadable > 0) return error.IncompleteRecipientJournal;
    var found: ?c.Value = null;
    for (listing.entries) |entry| {
        if (!std.ascii.eqlIgnoreCase(reference, try c.string(try field(entry, "commitment"))) and !c.eq(u8, reference, try c.string(try field(entry, "label")))) continue;
        if (found != null) return error.AmbiguousRecipientUseCommitment;
        found = entry;
    }
    return found orelse error.RecipientNotFoundRunSync;
}
pub fn publicEntry(a: c.A, entry: c.Value) !c.Value {
    var value: c.Value = .{ .object = .empty };
    for ([_][]const u8{ "recordKey", "commitment", "recipient", "label", "createdAt" }) |name| try value.object.put(a, name, try field(entry, name));
    return value;
}

test "recipient replay follows rotation epochs and rejects authenticated corrupt records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var private_key: [32]u8 = @splat(0);
    private_key[31] = 1;
    var old = try Secret.init(private_key);
    defer old.deinit();
    private_key[31] = 2;
    var head = try Secret.init(private_key);
    defer head.deinit();
    const address = "0x0000000000000000000000000000000000000001";
    const context: Context = .{ .storageChainId = 1, .kvAddress = address, .executionChainId = 1, .registryAddress = address, .policyId = try c.hex(a, 1), .vault = address };
    const first = try create(a, io, old, context, address, "Old", null);
    var latest = try create(a, io, head, context, address, "New", null);
    try std.testing.expect(!try equal(a, try field(first, "commitment"), try field(latest, "commitment")));
    const tombstone = try create(a, io, head, context, null, "", try c.string(try field(first, "commitment")));
    var raw: std.StringArrayHashMapUnmanaged(c.Value) = .empty;
    const add = struct {
        fn run(allocator: c.A, target: *std.StringArrayHashMapUnmanaged(c.Value), secret: Secret, record: c.Value, position: usize) !void {
            const encrypted = try secret.encrypt(allocator, std.testing.io, try encode(allocator, record));
            try target.put(allocator, try c.string(try field(record, "recordKey")), try c.parse(allocator, try c.encode(allocator, .{ .value = try abi.hex(allocator, encrypted), .insertionIndex = position })));
        }
    }.run;
    // Arrival order and signer positions deliberately disagree with epoch order.
    try add(a, &raw, head, tombstone, 1);
    try add(a, &raw, head, latest, 0);
    try add(a, &raw, old, first, 100);
    const listed = try list(a, raw, &.{ head, old }, context);
    try std.testing.expectEqual(@as(usize, 1), listed.entries.len);
    try std.testing.expectEqualStrings("New", try c.string(try field(listed.entries[0], "label")));
    var foreign = context;
    foreign.executionChainId = 2;
    try std.testing.expectEqual(@as(usize, 0), (try list(a, raw, &.{ head, old }, foreign)).entries.len);
    try latest.object.put(a, "commitment", .{ .string = try c.hex(a, 999) });
    try add(a, &raw, head, latest, 0);
    const corrupt = try list(a, raw, &.{ head, old }, context);
    try std.testing.expectEqual(@as(usize, 1), corrupt.invalid);
    try std.testing.expectError(error.IncompleteRecipientJournal, select(corrupt, "New"));
}
