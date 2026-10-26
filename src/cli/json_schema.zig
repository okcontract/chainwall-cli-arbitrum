const std = @import("std");
const c = @import("common.zig");

pub const embedded = @embedFile("input-schemas");
pub const Failure = struct { path: []const u8, message: []const u8 };

/// Evaluates the vocabulary used by our bundled 2020-12 schemas. Schemas are
/// trusted build inputs, never fetched from an input document or the network.
pub const Validator = struct {
    a: c.A,
    root: c.Value,
    failure: ?Failure = null,
    quiet: bool = false,
    remaining: usize = 200000,

    pub fn init(a: c.A) !Validator {
        return .{ .a = a, .root = try c.parse(a, embedded) };
    }
    pub fn schema(v: Validator, name: []const u8) !c.Value {
        return c.field(c.field(v.root, "$defs").?, name) orelse error.UnknownInputSchema;
    }
    fn fail(v: *Validator, path: []const u8, message: []const u8) bool {
        v.failure = .{ .path = path, .message = message };
        return false;
    }
    fn child(v: Validator, path: []const u8, key: []const u8) ![]const u8 {
        const slash = try std.mem.replaceOwned(u8, v.a, key, "~", "~0");
        return v.a.print("{s}/{s}", .{ path, try std.mem.replaceOwned(u8, v.a, slash, "/", "~1") });
    }
    pub fn check(v: *Validator, rule: c.Value, value: c.Value) !bool {
        v.failure = null;
        v.remaining = 200000;
        return v.visit(rule, value, "", 0);
    }
    fn visit(v: *Validator, rule: c.Value, value: c.Value, path: []const u8, depth: usize) anyerror!bool {
        if (depth > 128 or v.remaining == 0) return error.JsonSchemaLimit;
        v.remaining -= 1;
        if (rule == .bool) return rule.bool or v.fail(path, "value is not allowed");
        if (rule != .object) return error.InvalidInputSchema;
        for (rule.object.keys()) |key| if (!@import("schema.zig").contains("$schema $id $defs $ref title description default examples type const enum anyOf oneOf allOf required properties additionalProperties propertyNames prefixItems items minItems maxItems minLength maxLength pattern minimum maximum", key)) return error.UnsupportedSchemaKeyword;
        if (c.field(rule, "$ref")) |reference| {
            const key = try c.string(reference);
            if (!std.mem.startsWith(u8, key, "#/$defs/")) return error.UnsupportedSchemaReference;
            if (!try v.visit(try v.schema(key[8..]), value, path, depth + 1)) return false;
        }
        for ([_][]const u8{ "anyOf", "oneOf", "allOf" }) |key| if (c.field(rule, key)) |branches| {
            var matches: usize = 0;
            var best: ?Failure = null;
            for (branches.array.items) |branch| {
                if (try v.visit(branch, value, path, depth + 1)) {
                    matches += 1;
                } else if (v.failure) |failure| {
                    if (best == null or failure.path.len > best.?.path.len) best = failure;
                }
            }
            if (matches == 0 or (c.eq(u8, key, "oneOf") and matches != 1) or (c.eq(u8, key, "allOf") and matches != branches.array.items.len)) {
                v.failure = best orelse Failure{ .path = path, .message = "does not match the expected document shape" };
                return false;
            }
            v.failure = null;
        };
        if (c.field(rule, "type")) |kind| if (!matchesType(try c.string(kind), value)) return v.fail(path, try v.a.print("expected {s}", .{try c.string(kind)}));
        if (c.field(rule, "const")) |expected| if (!try equal(v.a, value, expected)) return v.fail(path, "incorrect constant or document version");
        if (c.field(rule, "enum")) |choices| {
            var found = false;
            for (choices.array.items) |expected| if (try equal(v.a, value, expected)) {
                found = true;
                break;
            };
            if (!found) return v.fail(path, "not an allowed value");
        }
        if (value == .object) {
            if (c.field(rule, "required")) |required| for (required.array.items) |key| {
                const name = try c.string(key);
                if (!value.object.contains(name)) return v.fail(try v.child(path, name), "required field is missing");
            };
            const props = c.field(rule, "properties") orelse c.Value{ .object = .empty };
            for (value.object.keys(), value.object.values()) |key, item| {
                const at = try v.child(path, key);
                if (c.field(rule, "propertyNames")) |names| if (!try v.visit(names, .{ .string = key }, at, depth + 1)) return false;
                if (c.field(props, key)) |property| {
                    if (!try v.visit(property, item, at, depth + 1)) return false;
                } else if (c.field(rule, "additionalProperties")) |extra| {
                    if (extra == .bool and !extra.bool) return v.fail(at, "unknown field");
                    if (!try v.visit(extra, item, at, depth + 1)) return false;
                }
            }
        } else if (value == .array) {
            if (!try v.size(rule, "minItems", "maxItems", value.array.items.len, path)) return false;
            const prefix = c.field(rule, "prefixItems");
            for (value.array.items, 0..) |item, i| {
                const selected = if (prefix != null and i < prefix.?.array.items.len) prefix.?.array.items[i] else c.field(rule, "items") orelse c.Value{ .bool = true };
                if (!try v.visit(selected, item, try v.child(path, try v.a.print("{d}", .{i})), depth + 1)) return false;
            }
        } else if (value == .string) {
            const length = std.unicode.utf8CountCodepoints(value.string) catch return v.fail(path, "invalid UTF-8");
            if (!try v.size(rule, "minLength", "maxLength", length, path)) return false;
            if (c.field(rule, "pattern")) |pattern| if (!try matchesPattern(try c.string(pattern), value.string)) return v.fail(path, "invalid string format");
        } else if (numeric(value)) {
            const n = try number(value);
            if (!std.math.isFinite(n)) return v.fail(path, "number must be finite");
            if (c.field(rule, "minimum")) |min| if (n < try number(min)) return v.fail(path, "number is below minimum");
            if (c.field(rule, "maximum")) |max| if (n > try number(max)) return v.fail(path, "number exceeds maximum; use a decimal string for large integers");
        }
        return true;
    }
    fn size(v: *Validator, rule: c.Value, min: []const u8, max: []const u8, length: usize, path: []const u8) !bool {
        if (c.field(rule, min)) |n| if (length < try c.number(v.a, n)) return v.fail(path, "too few items or characters");
        if (c.field(rule, max)) |n| if (length > try c.number(v.a, n)) return v.fail(path, "too many items or characters");
        return true;
    }
    pub fn document(v: Validator, rule: c.Value) !c.Value {
        var result = rule;
        if (result != .object) return error.InvalidInputSchema;
        result.object = try result.object.clone(v.a);
        try result.object.put(v.a, "$schema", c.field(v.root, "$schema").?);
        try result.object.put(v.a, "$defs", c.field(v.root, "$defs").?);
        return result;
    }
    pub fn require(v: *Validator, io: std.Io, rule: c.Value, value: c.Value, label: []const u8) !void {
        if (try v.check(rule, value)) {
            v.failure = null;
            return;
        }
        const failure = v.failure.?;
        // Never include input values: files can contain salts or credentials.
        if (!v.quiet) try std.Io.File.stderr().writeStreamingAll(io, try v.a.print("Invalid JSON input ({s}) at {s}: {s}\n", .{ label, if (failure.path.len == 0) "/" else failure.path, failure.message }));
        return error.JsonInputValidationFailed;
    }
};
fn numeric(value: c.Value) bool {
    return value == .integer or value == .float or value == .number_string;
}
fn number(value: c.Value) !f64 {
    return switch (value) {
        .integer => |n| @floatFromInt(n),
        .float => |n| n,
        .number_string => |s| std.fmt.parseFloat(f64, s),
        else => error.InvalidInputSchema,
    };
}
fn matchesType(kind: []const u8, value: c.Value) bool {
    if (c.eq(u8, kind, "integer")) {
        return switch (value) {
            .integer => true,
            .number_string => |text| integerText(text),
            else => false,
        };
    }
    if (c.eq(u8, kind, "number")) return numeric(value);
    if (c.eq(u8, kind, "boolean")) return value == .bool;
    return c.eq(u8, kind, @tagName(value));
}
/// ABI integer inputs use plain decimal notation, matching the encoder.
/// Reject decimal points and exponents before any command can change state.
fn integerText(source: []const u8) bool {
    const digits = if (std.mem.startsWith(u8, source, "-")) source[1..] else source;
    if (digits.len == 0) return false;
    for (digits) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}
fn equal(a: c.A, left: c.Value, right: c.Value) !bool {
    if (numeric(left) and numeric(right)) return matchesType("integer", left) == matchesType("integer", right) and try number(left) == try number(right);
    return c.eq(u8, try c.encode(a, left), try c.encode(a, right));
}
fn matchesPattern(pattern: []const u8, input: []const u8) !bool {
    // Deliberately bounded patterns. A new schema pattern must add native tests
    // here; unsupported patterns fail closed instead of silently skipping them.
    if (c.eq(u8, pattern, "^[0-9]+([.][0-9]+)?(wei|gwei|eth|ether)$")) {
        for ([_][]const u8{ "ether", "eth", "gwei", "wei" }) |unit| {
            if (!std.mem.endsWith(u8, input, unit)) continue;
            const digits = input[0 .. input.len - unit.len];
            if (digits.len == 0 or !std.ascii.isDigit(digits[0]) or !std.ascii.isDigit(digits[digits.len - 1])) return false;
            var point = false;
            for (digits) |ch| {
                if (ch == '.' and !point) {
                    point = true;
                    continue;
                }
                if (!std.ascii.isDigit(ch)) return false;
            }
            return true;
        }
        return false;
    }
    if (c.eq(u8, pattern, "^0x[0-9a-fA-F]*$")) {
        if (!std.mem.startsWith(u8, input, "0x")) return false;
        for (input[2..]) |ch| if (!std.ascii.isHex(ch)) return false;
        return true;
    }
    const negative = c.eq(u8, pattern, "^-[0-9]+$");
    if (!negative and !c.eq(u8, pattern, "^[0-9]+$")) return error.UnsupportedSchemaPattern;
    if (input.len == 0 or (negative and (input.len == 1 or input[0] != '-'))) return false;
    for (input[@intFromBool(negative)..]) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

pub fn read(a: c.A, io: std.Io, name: []const u8, path: []const u8) !c.Value {
    var validator = try Validator.init(a);
    return readRule(&validator, io, try validator.schema(name), name, path);
}
pub fn readRule(validator: *Validator, io: std.Io, rule: c.Value, name: []const u8, path: []const u8) !c.Value {
    const a = validator.a;
    const bytes = try c.read(a, io, path);
    defer std.crypto.secureZero(u8, @constCast(bytes));
    const value = c.parse(a, bytes) catch return error.InvalidJsonInput;
    try validator.require(io, rule, value, name);
    return value;
}

pub fn abiArguments(a: c.A, params: c.Value, references: bool) anyerror!c.Value {
    var properties: std.json.ObjectMap = .empty;
    var required = std.json.Array.init(a);
    var prefix = std.json.Array.init(a);
    var named = true;
    for (params.array.items) |param| {
        const name = try c.string(c.field(param, "name") orelse c.Value{ .string = "" });
        const rule = try abiParameter(a, param, references);
        if (name.len == 0 or properties.contains(name)) named = false;
        try properties.put(a, name, rule);
        try required.append(.{ .string = name });
        try prefix.append(rule);
    }
    const positional = try c.parse(a, try c.encode(a, .{ .type = "array", .prefixItems = c.Value{ .array = prefix }, .minItems = params.array.items.len, .maxItems = params.array.items.len, .items = false }));
    if (!named) return positional;
    return c.parse(a, try c.encode(a, .{ .anyOf = .{ .{ .type = "object", .properties = c.Value{ .object = properties }, .required = c.Value{ .array = required }, .additionalProperties = false }, positional } }));
}
pub fn abiParameter(a: c.A, param: c.Value, references: bool) anyerror!c.Value {
    const kind = try c.string(c.field(param, "type").?);
    if (std.mem.endsWith(u8, kind, "]")) {
        const at = std.mem.lastIndexOfScalar(u8, kind, '[') orelse return error.InvalidAbi;
        var base = param;
        base.object = try param.object.clone(a);
        try base.object.put(a, "type", .{ .string = kind[0..at] });
        var result = try c.parse(a, try c.encode(a, .{ .type = "array", .items = try abiParameter(a, base, references) }));
        if (at + 1 < kind.len - 1) {
            const size = try std.fmt.parseInt(i64, kind[at + 1 .. kind.len - 1], 10);
            try result.object.put(a, "minItems", .{ .integer = size });
            try result.object.put(a, "maxItems", .{ .integer = size });
        }
        return result;
    }
    if (c.eq(u8, kind, "tuple")) return abiArguments(a, c.field(param, "components").?, references);
    if (c.eq(u8, kind, "string")) return c.parse(a, "{\"type\":\"string\"}");
    if (references and (c.eq(u8, kind, "address") or c.eq(u8, kind, "bytes32"))) return c.parse(a, "{\"type\":\"string\",\"minLength\":1}");
    if (c.eq(u8, kind, "bool")) return c.parse(a, "{\"anyOf\":[{\"type\":\"boolean\"},{\"enum\":[\"true\",\"false\"]}]}");
    if (std.mem.startsWith(u8, kind, "uint") or std.mem.startsWith(u8, kind, "int")) {
        const unsigned = try c.parse(a, "{\"anyOf\":[{\"type\":\"integer\",\"minimum\":0,\"maximum\":9007199254740991},{\"type\":\"string\",\"pattern\":\"^[0-9]+$\"},{\"type\":\"string\",\"pattern\":\"^0x[0-9a-fA-F]*$\",\"minLength\":3,\"maxLength\":66}]}");
        if (kind[0] == 'u') return unsigned;
        return c.parse(a, try c.encode(a, .{ .anyOf = .{ unsigned, try c.parse(a, "{\"type\":\"integer\",\"minimum\":-9007199254740991,\"maximum\":-1}"), try c.parse(a, "{\"type\":\"string\",\"pattern\":\"^-[0-9]+$\"}") } }));
    }
    const size: ?usize = if (c.eq(u8, kind, "address")) 20 else if (c.eq(u8, kind, "function")) 24 else if (std.mem.startsWith(u8, kind, "bytes") and kind.len > 5) try std.fmt.parseInt(usize, kind[5..], 10) else if (c.eq(u8, kind, "bytes")) null else return error.InvalidAbi;
    var result = try c.parse(a, "{\"type\":\"string\",\"pattern\":\"^0x[0-9a-fA-F]*$\",\"minLength\":2}");
    if (size) |n| {
        try result.object.put(a, "minLength", .{ .integer = @intCast(2 + n * 2) });
        try result.object.put(a, "maxLength", .{ .integer = @intCast(2 + n * 2) });
    }
    return result;
}

test "schemas reject nested typos, unsafe JSON integers, and malformed signatures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var v = try Validator.init(a);
    try std.testing.expect(!try v.check(try v.schema("operation-intent"), try c.parse(a, "{\"safe\":\"alice\"}")));
    try std.testing.expectEqualStrings("/interactionId", v.failure.?.path);
    const params = try c.parse(a, "[{\"name\":\"amount\",\"type\":\"uint256\"}]");
    const rule = try abiArguments(a, params, true);
    try std.testing.expect(try v.check(rule, try c.parse(a, "{\"amount\":12}")));
    try std.testing.expect(try v.check(rule, try c.parse(a, "{\"amount\":\"9007199254740993\"}")));
    try std.testing.expect(!try v.check(rule, try c.parse(a, "{\"amount\":9007199254740993}")));
    try std.testing.expect(!try v.check(rule, try c.parse(a, "{\"amount\":1.000000000000000000001}")));
    try std.testing.expect(!try v.check(rule, try c.parse(a, "{\"amount\":1e-9999}")));
    try std.testing.expect(!try v.check(rule, try c.parse(a, "{\"amount\":1.20e1}")));
    try std.testing.expect(!try v.check(rule, try c.parse(a, "{\"amount\":0.0e-9999}")));
    try std.testing.expect(!try equal(a, try c.parse(a, "1.000000000000000000001"), .{ .integer = 1 }));
    try std.testing.expect(!try v.check(rule, try c.parse(a, "{\"amount\":\"1\",\"amout\":\"2\"}")));
    try std.testing.expect(!try v.check(try v.schema("safe-signatures"), try c.parse(a, "[]")));
    try std.testing.expect(try v.check(try v.schema("facet-choices"), try c.parse(a, "{\"0x12345678\":{\"kind\":\"remove\"}}")));
    try std.testing.expect(!try v.check(try v.schema("facet-choices"), try c.parse(a, "{\"secret\":{\"kind\":\"remove\"}}")));
}
