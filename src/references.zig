const std = @import("std");
const t = @import("tree.zig");
const bc = @import("bytecode.zig");
pub const References = struct {
    targets: std.ArrayList(u256) = .empty,
    calli_ids: std.ArrayList(u256) = .empty,
    linked_relations: std.ArrayList(u256) = .empty,
    price_assets: std.ArrayList(u256) = .empty,
    raw_count: usize = 0,
    complete: bool = true,
    reads_price: bool = false,
    pub fn deinit(r: *References, a: t.Allocator) void {
        r.targets.deinit(a);
        r.calli_ids.deinit(a);
        r.linked_relations.deinit(a);
        r.price_assets.deinit(a);
    }
};
fn add(a: t.Allocator, list: *std.ArrayList(u256), value: u256) t.Error!void {
    for (list.items) |v| if (v == value) return;
    try list.append(a, value);
}
pub fn scan(a: t.Allocator, bytes: []const u8) t.Error!References {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const items = try bc.decode(arena.allocator(), bytes);
    var instructions: std.ArrayList(bc.Instruction) = .empty;
    for (items) |item| if (item.label == null) {
        try instructions.append(arena.allocator(), item);
    };
    const excluded = try arena.allocator().alloc(bool, instructions.items.len);
    @memset(excluded, false);
    var result: References = .{};
    errdefer result.deinit(a);
    for (instructions.items, 0..) |item, i| {
        if (item.op != .CALLI) continue;
        if (i >= 2 and instructions.items[i - 2].op == .PUSH32 and (instructions.items[i - 1].op == .PUSH1 or instructions.items[i - 1].op == .PUSH8 or instructions.items[i - 1].op == .PUSH32)) {
            excluded[i - 2] = true;
            excluded[i - 1] = true;
            result.raw_count += 1;
            try add(a, &result.calli_ids, bc.word(instructions.items[i - 2].immediate));
        } else result.complete = false;
    }
    for (instructions.items, 0..) |item, i| {
        if (item.op == .PUSH32 and !excluded[i]) {
            result.raw_count += 1;
            try add(a, &result.targets, bc.word(item.immediate));
        } else if (item.op == .STATICLINK) {
            result.raw_count += 1;
            try add(a, &result.linked_relations, bc.word(item.immediate));
        } else if (item.op == .VALUEUSD) {
            result.raw_count += 1;
            try add(a, &result.price_assets, bc.word(item.immediate[0..32]));
        } else if (bc.recursive(item.op)) {
            result.raw_count += 1;
            try add(a, &result.targets, bc.word(item.immediate[3..35]));
        }
        if (item.op == .PRICEUSD or item.op == .VALUEUSD) result.reads_price = true;
    }
    return result;
}
fn equal(a: []const u256, b: []const u256) bool {
    if (a.len != b.len) return false;
    for (a) |v| {
        var found = false;
        for (b) |w| if (v == w) {
            found = true;
            break;
        };
        if (!found) return false;
    }
    return true;
}
pub fn same(a: References, b: References) bool {
    return equal(a.targets.items, b.targets.items) and equal(a.calli_ids.items, b.calli_ids.items) and equal(a.linked_relations.items, b.linked_relations.items) and equal(a.price_assets.items, b.price_assets.items) and a.complete == b.complete and a.reads_price == b.reads_price;
}
