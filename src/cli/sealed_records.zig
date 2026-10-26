//! Individually authenticated records, with opaque keys, for paged private data.
const std = @import("std");
const c = @import("common.zig");
const Vault = @import("vault.zig").Vault;
const Store = @import("store.zig").Store;
const abi = @import("abi_codec.zig");
fn recordKey(a: c.A, id: []const u8) ![]const u8 {
    return c.hex(a, @import("miniscript").bytecode.hash(id));
}
pub fn contains(v: Vault, scope: []const u8, id: []const u8) !bool {
    return v.db.contains(scope, "sealed", try recordKey(v.a, id));
}
pub fn put(v: Vault, scope: []const u8, id: []const u8, value: c.Value) !void {
    const index = try recordKey(v.a, id);
    const context = try v.a.print("{s}:{s}", .{ scope, index });
    const bytes = try c.encode(v.a, .{ .id = id, .value = value });
    defer std.crypto.secureZero(u8, @constCast(bytes));
    try v.db.put(scope, "sealed", index, .{ .string = try abi.hex(v.a, try v.seal(context, bytes)) });
}
pub fn page(v: Vault, scope: []const u8, after: ?[]const u8) !Store.Scan {
    const result = try v.db.scan(scope, "sealed", after, 256);
    const entries = try v.a.alloc(Store.Entry, result.entries.len);
    for (result.entries, entries) |entry, *out| {
        const context = try v.a.print("{s}:{s}", .{ scope, entry.id });
        const bytes = try v.openBytes(context, try abi.unhex(v.a, try c.string(entry.value)));
        defer std.crypto.secureZero(u8, bytes);
        const record = try c.parse(v.a, bytes);
        const id = try c.string(c.field(record, "id") orelse return error.InvalidVault);
        if (!c.eq(u8, entry.id, try recordKey(v.a, id))) return error.InvalidVault;
        out.* = .{ .id = id, .value = c.field(record, "value") orelse return error.InvalidVault };
    }
    return .{ .entries = entries, .next = result.next };
}
pub fn load(v: Vault, scope: []const u8) !c.Value {
    var result: std.json.ObjectMap = .empty;
    var cursor: ?[]const u8 = null;
    while (true) {
        const batch = try page(v, scope, cursor);
        for (batch.entries) |entry| try result.put(v.a, entry.id, entry.value);
        cursor = batch.next orelse break;
    }
    return .{ .object = result };
}
test "sealed record pages roundtrip without exposing identifiers or values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try Store.init(a, ":memory:");
    defer db.close();
    const v: Vault = .{ .a = a, .io = std.testing.io, .db = db, .key = @splat(7) };
    for (0..300) |i| try put(v, "private", try a.print("secret-{d}", .{i}), .{ .string = "private-value" });
    const first = try page(v, "private", null);
    try std.testing.expectEqual(256, first.entries.len);
    try std.testing.expectEqual(44, (try page(v, "private", first.next)).entries.len);
    try std.testing.expectEqual(300, (try load(v, "private")).object.count());
    const raw = try db.scan("private", "sealed", null, 1);
    try std.testing.expect(std.mem.indexOf(u8, try c.encode(a, raw.entries), "secret-") == null);
}
