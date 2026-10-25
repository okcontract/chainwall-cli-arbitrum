const std = @import("std");
const c = @import("common.zig");
const Args = @import("args.zig").Args;
const contracts = @import("contracts.zig");
const cli = @import("schema.zig");
const json = @import("json_schema.zig");

pub const Binding = struct {
    name: []const u8,
    rule: c.Value,
    position: ?usize = null,
    option: ?[]const u8 = null,
    path: ?[]const u8 = null,
    /// Some compiler inputs also accept plain source or hex files.
    mixed: bool = false,
    /// These commands update the input with transaction/reconciliation evidence.
    durable: bool = false,
    insert: bool = false,
};
pub fn peek(args: Args, key: []const u8) ?[]const u8 {
    for (args.options) |item| if (c.eq(u8, key, item.key)) return item.value;
    return null;
}
fn at(p: []const []const u8, i: usize) []const u8 {
    return if (i < p.len) p[i] else "";
}
fn is(p: []const []const u8, group: []const u8, verbs: []const u8) bool {
    return c.eq(u8, at(p, 0), group) and cli.contains(verbs, at(p, 1));
}
fn positional(v: json.Validator, p: []const []const u8, index: usize, name: []const u8, mixed: bool, durable: bool) !Binding {
    return .{ .name = name, .rule = try v.schema(name), .position = index, .path = if (p.len > index) p[index] else null, .mixed = mixed, .durable = durable };
}
pub fn primary(v: json.Validator, args: Args, cat: contracts.Catalog) !?Binding {
    const p = args.positional;
    if (is(p, "schemas", "validate") and p.len >= 3) return try positional(v, p, 3, p[2], false, false);
    if (is(p, "operations", "direct direct-sign direct-sign-actor propose")) return try positional(v, p, 2, "operation-document", false, false);
    if (is(p, "operations", "execute simulate publish sign sign-actor export")) return try positional(v, p, 2, "operation-proposal", false, false);
    if (is(p, "operations", "import")) return try positional(v, p, 2, "operation-share", false, false);
    if (is(p, "commitments", "prepare") and cli.contains("contract token interaction", at(p, 2))) return try positional(v, p, 3, try v.a.print("commitment-{s}{s}", .{ p[2], if (c.eq(u8, p[2], "interaction") and peek(args, "source-file") != null) "-source" else "" }), false, false);
    if (is(p, "commitments", "import")) return try positional(v, p, 2, "commitment-export", false, false);
    if (is(p, "policies", "simulate")) return try positional(v, p, 2, "policy-simulation", false, false);
    if (is(p, "policies", "program")) {
        if (c.eq(u8, at(p, 2), "simulate")) return try positional(v, p, 4, "policy-context", false, false);
        if (c.eq(u8, at(p, 2), "compile")) return try positional(v, p, 3, "policy-program", true, false);
        if (c.eq(u8, at(p, 2), "publish")) return try positional(v, p, 4, "policy-program", true, false);
    }
    if (is(p, "facets", "apply check reconcile")) return try positional(v, p, 2, "facet-plan", false, !c.eq(u8, p[1], "check"));
    if (is(p, "security-council", "reconcile")) return try positional(v, p, 2, "council-report", false, true);
    if (is(p, "upgrade", "release")) return try positional(v, p, 2, "upgrade-action", false, false);
    if (is(p, "auth", "create register inspect")) return try positional(v, p, 2, if (c.eq(u8, p[1], "create")) "auth-enrollment" else "auth-profile", false, false);
    if (is(p, "config", "import")) return try positional(v, p, 2, "configuration", false, false);
    if (is(p, "transactions", "estimate")) return try positional(v, p, 2, "transaction-document", false, false);
    if (cli.contains("analyze decompile disasm", at(p, 0))) return try positional(v, p, 1, "program-document", true, false);
    // Only ABI-dispatched commands use args-file. Custom commands with the same
    // names have already been selected above.
    if (p.len >= 2) {
        const method = cat.find(p[0], cli.alias(p[0], p[1])) catch return null;
        return .{ .name = method.signature, .rule = try json.abiArguments(v.a, c.field(method.abi, "inputs").?, true), .option = "args-file", .path = peek(args, "args-file") };
    }
    return null;
}
pub fn option(v: json.Validator, args: Args, cat: contracts.Catalog, key: []const u8) !?Binding {
    const p = args.positional;
    if (c.eq(u8, key, "args-file")) {
        const binding = (try primary(v, args, cat)) orelse return null;
        return if (binding.option != null and c.eq(u8, binding.option.?, "args-file")) binding else null;
    }
    if (c.eq(u8, key, "constructor-file")) {
        if (!is(p, "upgrade", "deploy") or p.len < 3) return error.ConstructorReleaseRequired;
        const releases = @import("releases.zig");
        const entry = try releases.find(v.a, try contracts.Catalog.loadReleases(v.a), p[2]);
        var params = c.Value{ .array = std.json.Array.init(v.a) };
        for (c.field(c.field(entry.item, "artifact").?, "abi").?.array.items) |item| if (c.eq(u8, try c.string(c.field(item, "type").?), "constructor")) {
            params = c.field(item, "inputs").?;
            break;
        };
        return .{ .name = "constructor-arguments", .rule = try json.abiArguments(v.a, params, false), .option = key, .path = peek(args, key) };
    }
    const special: ?[]const u8 = if (c.eq(u8, key, "actor-signature-file")) (if (is(p, "commitments", "reveal")) "committer-signature" else "actor-signature") else null;
    const name = special orelse blk: {
        for ([_][2][]const u8{
            .{ "signatures-file", "safe-signatures" },
            .{ "reveal-file", "interaction-reveal" },
            .{ "linked-file", "linked-artifacts" },
            .{ "choices-file", "facet-choices" },
            .{ "scopes-file", "auth-scopes" },
            .{ "credential-file", "auth-credential" },
            .{ "auth-profile", "auth-profile" },
            .{ "keystore", "keystore" },
            .{ "settings", "settings-document" },
            .{ "snapshot", "registry-snapshot" },
            .{ "abi", "abi-document" },
        }) |entry| if (c.eq(u8, key, entry[0])) break :blk entry[1];
        return null;
    };
    var path = peek(args, key);
    if (path != null and c.eq(u8, key, "abi")) {
        const equals = std.mem.indexOfScalar(u8, path.?, '=') orelse return error.AbiRequiresTargetAndFile;
        path = path.?[equals + 1 ..];
    }
    return .{ .name = name, .rule = try v.schema(name), .option = key, .path = path };
}
pub fn selected(v: json.Validator, args: Args, cat: contracts.Catalog, selector: ?[]const u8) !Binding {
    if (selector) |key| return (try option(v, args, cat, std.mem.trimStart(u8, key, "-"))) orelse error.UnknownJsonInput;
    if (try primary(v, args, cat)) |binding| {
        if (args.positional.len == 3 and (is(args.positional, "facets", "reconcile") or is(args.positional, "security-council", "reconcile"))) {
            var result = binding;
            result.path = null;
            result.insert = true;
            return result;
        }
        return binding;
    }
    const p = args.positional;
    const key: []const u8 = if (is(p, "facets", "plan")) "choices-file" else if (is(p, "safes", "import")) "signatures-file" else if (is(p, "upgrade", "deploy")) "constructor-file" else if (is(p, "auth", "recover")) "credential-file" else if (is(p, "commitments", "reveal")) "actor-signature-file" else if (is(p, "interactions", "add update")) "linked-file" else return error.NoJsonInput;
    return (try option(v, args, cat, key)).?;
}
pub fn validateFile(v: *json.Validator, io: std.Io, binding: Binding) !void {
    const path = binding.path orelse return;
    if (binding.mixed and std.mem.endsWith(u8, path, ".ls")) return;
    const bytes = try c.read(v.a, io, path);
    defer std.crypto.secureZero(u8, @constCast(bytes));
    const trimmed = c.trim(bytes);
    if (binding.mixed and c.eq(u8, binding.name, "program-document") and !std.mem.startsWith(u8, trimmed, "{")) return;
    const value = c.parse(v.a, bytes) catch {
        try std.Io.File.stderr().writeStreamingAll(io, try v.a.print("Invalid JSON syntax ({s}); input values omitted.\n", .{binding.name}));
        return error.InvalidJsonInput;
    };
    try v.require(io, binding.rule, value, binding.name);
}
/// Validate explicit inputs before RPC, credential prompts, vault writes or signing.
pub fn preflight(v: *json.Validator, io: std.Io, args: Args, cat: contracts.Catalog) !void {
    if (try primary(v.*, args, cat)) |binding| try validateFile(v, io, binding);
    for (args.options) |item| {
        // A dry run or a read may carry an unused signer configuration. The
        // keystore is validated when cast actually selects it for signing.
        if (c.eq(u8, item.key, "keystore")) continue;
        var single = args;
        single.options = @constCast((&item)[0..1]);
        if (try option(v.*, single, cat, item.key)) |binding| try validateFile(v, io, binding);
    }
}
pub fn template(v: json.Validator, rule: c.Value, depth: usize) anyerror!c.Value {
    if (depth > 64) return error.JsonSchemaLimit;
    if (rule == .bool) return .null;
    if (c.field(rule, "default")) |value| return value;
    if (c.field(rule, "const")) |value| return value;
    if (c.field(rule, "$ref")) |value| return template(v, try v.schema((try c.string(value))[8..]), depth + 1);
    for ([_][]const u8{ "anyOf", "oneOf", "enum" }) |key| if (c.field(rule, key)) |values| return if (c.eq(u8, key, "enum")) values.array.items[0] else template(v, values.array.items[0], depth + 1);
    const kind = c.string(c.field(rule, "type") orelse .null) catch "object";
    if (c.eq(u8, kind, "object")) {
        var value: c.Value = .{ .object = .empty };
        if (c.field(rule, "required")) |required| for (required.array.items) |key| {
            const name = try c.string(key);
            const prop = c.field(c.field(rule, "properties") orelse .null, name) orelse continue;
            try value.object.put(v.a, name, try template(v, prop, depth + 1));
        };
        return value;
    }
    if (c.eq(u8, kind, "array")) {
        var values = std.json.Array.init(v.a);
        if (c.field(rule, "prefixItems")) |prefix| {
            for (prefix.array.items) |item| try values.append(try template(v, item, depth + 1));
        } else if (c.field(rule, "minItems")) |min| {
            const count = try c.number(v.a, min);
            if (count > 128) return error.JsonSchemaLimit;
            for (0..@intCast(count)) |_| try values.append(try template(v, c.field(rule, "items") orelse c.Value{ .bool = true }, depth + 1));
        }
        return .{ .array = values };
    }
    if (c.eq(u8, kind, "boolean")) return .{ .bool = false };
    if (c.eq(u8, kind, "integer") or c.eq(u8, kind, "number")) return c.field(rule, "minimum") orelse c.Value{ .integer = 0 };
    if (c.eq(u8, kind, "null")) return .null;
    return .{ .string = "" };
}

test "JSON binding inventory covers primary and optional inputs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try json.Validator.init(a);
    const cat = try contracts.Catalog.load(a);
    const args = try Args.parse(a, &.{ "operations", "direct" });
    const binding = try selected(v, args, cat, null);
    try std.testing.expectEqualStrings("operation-document", binding.name);
    try std.testing.expectEqual(@as(?usize, 2), binding.position);
    try std.testing.expect(binding.path == null);
    const generic = try selected(v, try Args.parse(a, &.{ "registry", "upsertToken" }), cat, null);
    try std.testing.expectEqualStrings("args-file", generic.option.?);
    _ = try template(v, generic.rule, 0);
}
