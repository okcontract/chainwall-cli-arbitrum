const std = @import("std");
const c = @import("common.zig");
const abi = @import("abi_codec.zig");
const catalog = @import("facet_catalog.zig");
const field = catalog.field;
const string = catalog.string;
const same = catalog.same;
pub const Routes = std.StringArrayHashMapUnmanaged([]const u8);

fn selector(a: c.A, value: []const u8) ![]const u8 {
    if ((try abi.unhex(a, value)).len != 4) return error.InvalidFacetSelector;
    return std.ascii.allocLowerString(a, value);
}
fn less(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}
pub fn routes(a: c.A, facets: c.Value) !Routes {
    if (facets != .array or facets.array.items.len > 256) return error.InvalidFacetTopology;
    var result: Routes = .empty;
    for (facets.array.items) |facet| {
        const address = try string(facet, "facetAddress");
        try c.address(address);
        const selectors = try field(facet, "functionSelectors");
        if (selectors != .array or selectors.array.items.len > 10000) return error.InvalidFacetTopology;
        for (selectors.array.items) |value| {
            const key = try selector(a, try c.string(value));
            if (result.contains(key)) return error.DuplicateFacetRoute;
            try result.put(a, key, try std.ascii.allocLowerString(a, address));
        }
    }
    if (result.count() > 10000) return error.InvalidFacetTopology;
    return result;
}
pub fn exportRoutes(a: c.A, value: Routes) !c.Value {
    const keys = try a.dupe([]const u8, value.keys());
    std.mem.sort([]const u8, keys, {}, less);
    var rows = std.json.Array.init(a);
    for (keys) |key| try rows.append(try c.parse(a, try c.encode(a, .{ .selector = key, .facetAddress = value.get(key).? })));
    return .{ .array = rows };
}
pub fn importRoutes(a: c.A, value: c.Value) !Routes {
    if (value != .array or value.array.items.len > 10000) return error.InvalidFacetTopology;
    var result: Routes = .empty;
    for (value.array.items) |item| {
        const key = try selector(a, try string(item, "selector"));
        const address = try string(item, "facetAddress");
        try c.address(address);
        if (result.contains(key)) return error.DuplicateFacetRoute;
        try result.put(a, key, try std.ascii.allocLowerString(a, address));
    }
    return result;
}
fn cut(a: c.A, cuts: *std.json.Array, address: []const u8, action: u8, selectors: []const c.Value) !void {
    if (selectors.len > 0) try cuts.append(try c.parse(a, try c.encode(a, .{ .facetAddress = address, .action = action, .functionSelectors = selectors })));
}
/// Unknown extra selectors require an explicit decision. They are never
/// implicitly removed just because the bundled catalog does not mention them.
pub fn build(a: c.A, registry: []const u8, current: ?[]const u8, target: []const u8, desired: c.Value, before: Routes, choices: c.Value) !c.Value {
    try c.address(target);
    if (same(target, registry) or (current != null and same(current.?, registry))) return error.DirectFacetRoutesProtected;
    if (current) |address| try c.address(address);
    if (choices != .object or desired != .array) return error.InvalidFacetChoices;
    var wanted: std.StringHashMapUnmanaged(void) = .empty;
    var adds = std.json.Array.init(a);
    var replaces = std.json.Array.init(a);
    var removes = std.json.Array.init(a);
    var extras = std.json.Array.init(a);
    var missing = std.json.Array.init(a);
    var changes = std.json.Array.init(a);
    var decisions: std.StringHashMapUnmanaged(c.Value) = .empty;
    for (choices.object.keys(), choices.object.values()) |raw, choice| {
        const key = try selector(a, raw);
        if (decisions.contains(key)) return error.InvalidFacetChoices;
        try decisions.put(a, key, choice);
    }
    var after = try before.clone(a);
    for (desired.array.items) |raw| {
        const key = try selector(a, try c.string(raw));
        if (wanted.contains(key)) return error.DuplicateFacetSelector;
        try wanted.put(a, key, {});
        if (before.get(key)) |address| {
            if (same(address, registry)) return error.DirectFacetRoutesProtected;
            if (!same(address, target)) try replaces.append(.{ .string = key });
        } else try adds.append(.{ .string = key });
        try after.put(a, key, target);
    }
    const ordered = try a.dupe([]const u8, before.keys());
    std.mem.sort([]const u8, ordered, {}, less);
    for (ordered) |key| {
        const address = before.get(key).?;
        if (current == null or !same(address, current.?) or wanted.contains(key)) continue;
        try extras.append(.{ .string = key });
        const choice = decisions.get(key) orelse {
            try missing.append(.{ .string = key });
            continue;
        };
        _ = decisions.remove(key);
        if (choice != .object) return error.InvalidFacetChoices;
        const kind = try string(choice, "kind");
        if (c.eq(u8, kind, "keep")) {
            if (choice.object.count() != 1) return error.InvalidFacetChoices;
        } else if (c.eq(u8, kind, "remove")) {
            if (choice.object.count() != 1) return error.InvalidFacetChoices;
            _ = after.orderedRemove(key);
            try removes.append(.{ .string = key });
        } else if (c.eq(u8, kind, "move")) {
            if (choice.object.count() != 2) return error.InvalidFacetChoices;
            const destination = try string(choice, "address");
            try c.address(destination);
            if (same(destination, registry)) return error.DirectFacetRoutesProtected;
            if (!same(destination, address)) {
                try cut(a, &changes, destination, 1, &.{.{ .string = key }});
                try after.put(a, key, destination);
            }
        } else return error.InvalidFacetChoices;
    }
    if (decisions.count() != 0) return error.UnusedFacetSelectorChoice;
    var cuts = std.json.Array.init(a);
    try cut(a, &cuts, target, 1, replaces.items);
    try cut(a, &cuts, target, 0, adds.items);
    try cut(a, &cuts, catalog.zero, 2, removes.items);
    try cuts.appendSlice(changes.items);
    return c.parse(a, try c.encode(a, .{ .extras = extras.items, .unresolved = missing.items, .cuts = if (missing.items.len == 0) c.Value{ .array = cuts } else c.Value.null, .expectedRoutes = try exportRoutes(a, after), .ready = missing.items.len == 0 and cuts.items.len > 0 }));
}
