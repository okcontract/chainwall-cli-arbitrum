const std = @import("std");
const c = @import("common.zig");
pub const embedded = @embedFile("artifacts/registry.json");
pub const auxiliary = @embedFile("artifacts/storage.json");
pub const deployment = @embedFile("artifacts/deployment.json");
pub const releases = @embedFile("artifacts/releases.json");

pub const Method = struct {
    group: []const u8,
    contract: []const u8,
    name: []const u8,
    command: []const u8,
    signature: []const u8,
    abi: c.Value,
    pub fn read(m: Method) bool {
        const mutability = c.string(c.field(m.abi, "stateMutability").?) catch return false;
        return c.eq(u8, mutability, "view") or c.eq(u8, mutability, "pure");
    }
};
pub const Catalog = struct {
    root: c.Value,
    methods: []const Method,
    pub fn load(a: c.A) !Catalog {
        return loadSource(a, embedded);
    }
    pub fn loadAuxiliary(a: c.A) !Catalog {
        return loadSource(a, auxiliary);
    }
    pub fn loadDeployment(a: c.A) !Catalog {
        return loadSource(a, deployment);
    }
    pub fn loadNativePrice(a: c.A) !Catalog {
        return loadSource(a, @embedFile("artifacts/native-price.json"));
    }
    pub fn loadSafeInspection(a: c.A) !Catalog {
        return loadSource(a, @embedFile("artifacts/safe-inspection.json"));
    }
    pub fn loadReleases(a: c.A) !Catalog {
        return loadSource(a, releases);
    }
    fn loadSource(a: c.A, source: []const u8) !Catalog {
        const root = try c.parse(a, source);
        var methods: std.ArrayList(Method) = .empty;
        for (c.field(root, "contracts").?.array.items) |contract| {
            const name = try c.string(c.field(contract, "name").?);
            const group = if (c.field(contract, "group")) |value| try c.string(value) else try groupFor(a, name);
            for (c.field(c.field(contract, "artifact").?, "abi").?.array.items) |item| {
                if (!c.eq(u8, try c.string(c.field(item, "type").?), "function")) continue;
                const method_name = try c.string(c.field(item, "name").?);
                try methods.append(a, .{ .group = group, .contract = name, .name = method_name, .command = try c.kebab(a, method_name), .signature = try signature(a, item, false), .abi = item });
            }
        }
        return .{ .root = root, .methods = methods.items };
    }
    pub fn find(cat: Catalog, group: []const u8, name: []const u8) !Method {
        var result: ?Method = null;
        for (cat.methods) |method| {
            if (!matchesGroup(method, group)) continue;
            if (!c.eq(u8, method.name, name) and !c.eq(u8, method.command, name) and !c.eq(u8, method.signature, name)) continue;
            if (result) |previous| if (!c.eq(u8, previous.signature, method.signature)) return error.AmbiguousMethodUseSignature;
            result = method;
        }
        return result orelse error.UnknownRegistryMethod;
    }
    pub fn event(cat: Catalog, name: []const u8) ?c.Value {
        for (c.field(cat.root, "contracts").?.array.items) |contract| {
            for (c.field(c.field(contract, "artifact").?, "abi").?.array.items) |item| {
                if (c.eq(u8, c.string(c.field(item, "type").?) catch "", "event") and c.eq(u8, c.string(c.field(item, "name") orelse continue) catch "", name)) return item;
            }
        }
        return null;
    }
};
pub fn matchesGroup(m: Method, group: []const u8) bool {
    if (c.eq(u8, group, "registry") or c.eq(u8, group, m.group)) return true;
    if (c.eq(u8, group, "groups")) return c.eq(u8, m.group, "users") and std.mem.indexOf(u8, m.name, "Group") != null;
    if (c.eq(u8, group, "safes")) return c.eq(u8, m.group, "accounts") and std.mem.indexOf(u8, m.name, "Safe") != null;
    if (c.eq(u8, group, "roles") or c.eq(u8, group, "ownership")) return c.eq(u8, m.group, "diamond");
    if (c.eq(u8, group, "timelock")) return std.mem.startsWith(u8, m.group, "timelock");
    return false;
}
fn groupFor(a: c.A, name: []const u8) ![]const u8 {
    if (c.eq(u8, name, "OKFactory")) return "factory";
    if (c.eq(u8, name, "PasswordGatedKV")) return "kv";
    if (c.eq(u8, name, "PasswordGatedKVFactory")) return "kv-factory";
    if (c.eq(u8, name, "Interact")) return "interact";
    if (c.eq(u8, name, "SafeFactoryWithCreate2")) return "safe-factory";
    if (c.eq(u8, name, "OKAccount")) return "ok-account";
    if (c.eq(u8, name, "Safe")) return "safe";
    if (c.eq(u8, name, "AccountFactory")) return "account-factory";
    if (c.eq(u8, name, "SafeConfigurator")) return "safe-configurator";
    if (c.eq(u8, name, "WebAuthnAuthAccountFactory")) return "auth-factory";
    if (c.eq(u8, name, "WebAuthnAuthAccount")) return "auth-account";
    if (c.eq(u8, name, "ERC20")) return "erc20";
    if (c.eq(u8, name, "RegistryDiamond")) return "diamond";
    if (c.eq(u8, name, "DiamondCutFacet") or c.eq(u8, name, "DiamondLoupeFacet")) return "facets";
    if (!std.mem.startsWith(u8, name, "Registry") or !std.mem.endsWith(u8, name, "Facet")) return error.InvalidArtifact;
    return c.kebab(a, name[8 .. name.len - 5]);
}
pub fn parameter(a: c.A, item: c.Value) anyerror![]const u8 {
    return parameterForEncoding(a, item, false);
}
fn parameterForEncoding(a: c.A, item: c.Value, strings_as_bytes: bool) anyerror![]const u8 {
    const raw = try c.string(c.field(item, "type") orelse return error.InvalidAbi);
    if (strings_as_bytes and std.mem.startsWith(u8, raw, "string")) return a.print("bytes{s}", .{raw[6..]});
    if (!std.mem.startsWith(u8, raw, "tuple")) return raw;
    var out: std.Io.Writer.Allocating = .init(a);
    try out.writer.writeByte('(');
    const children = c.field(item, "components") orelse return error.InvalidAbi;
    for (children.array.items, 0..) |child, i| {
        if (i > 0) try out.writer.writeByte(',');
        try out.writer.writeAll(try parameterForEncoding(a, child, strings_as_bytes));
    }
    try out.writer.print("){s}", .{raw[5..]});
    return out.toOwnedSlice();
}
pub fn signature(a: c.A, item: c.Value, outputs: bool) ![]const u8 {
    return encodingSignature(a, item, outputs, false);
}
pub fn encodingSignature(a: c.A, item: c.Value, outputs: bool, strings_as_bytes: bool) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try out.writer.print("{s}(", .{try c.string(c.field(item, "name").?)});
    for (c.field(item, "inputs").?.array.items, 0..) |input, i| {
        if (i > 0) try out.writer.writeByte(',');
        try out.writer.writeAll(try parameterForEncoding(a, input, strings_as_bytes));
    }
    try out.writer.writeByte(')');
    if (outputs) {
        try out.writer.writeByte('(');
        for (c.field(item, "outputs").?.array.items, 0..) |output, i| {
            if (i > 0) try out.writer.writeByte(',');
            try out.writer.writeAll(try parameter(a, output));
        }
        try out.writer.writeByte(')');
    }
    return out.toOwnedSlice();
}

/// JSON argument objects follow artifact parameter names; structs may use
/// objects or arrays. Conversion only builds cast's argument notation.
pub fn argument(a: c.A, param: c.Value, value: c.Value) anyerror![]const u8 {
    const kind = try c.string(c.field(param, "type").?);
    if (std.mem.endsWith(u8, kind, "]")) {
        if (value != .array) return error.ExpectedArrayArgument;
        const bracket = std.mem.lastIndexOfScalar(u8, kind, '[').?;
        const length = kind[bracket + 1 .. kind.len - 1];
        if (length.len > 0 and value.array.items.len != try std.fmt.parseInt(usize, length, 10)) return error.WrongArrayLength;
        var child = param;
        child.object = try param.object.clone(a);
        try child.object.put(a, "type", .{ .string = kind[0..bracket] });
        var out: std.Io.Writer.Allocating = .init(a);
        try out.writer.writeByte('[');
        for (value.array.items, 0..) |element, i| {
            if (i > 0) try out.writer.writeByte(',');
            try out.writer.writeAll(try argument(a, child, element));
        }
        try out.writer.writeByte(']');
        return out.toOwnedSlice();
    }
    if (c.eq(u8, kind, "tuple")) {
        const args = try arguments(a, c.field(param, "components").?.array.items, value);
        return a.print("({s})", .{try std.mem.join(a, ",", args)});
    }
    // String and bytes have identical ABI payloads. Hex avoids cast's tuple
    // string parser, which cannot escape every possible quote combination.
    // Cast.calldata restores the original function selector after encoding.
    if (c.eq(u8, kind, "string")) return @import("miniscript").bytecode.hex(a, try c.string(value));
    return c.scalar(a, value);
}
pub fn arguments(a: c.A, params: []const c.Value, value: c.Value) ![]const []const u8 {
    if ((value != .array and value != .object) or (if (value == .array) value.array.items.len else value.object.count()) != params.len) return error.WrongArgumentCount;
    const out = try a.alloc([]const u8, params.len);
    for (params, out, 0..) |param, *dest, i| {
        const raw = if (value == .array) value.array.items[i] else value.object.get(try c.string(c.field(param, "name").?)) orelse return error.MissingNamedArgument;
        dest.* = try argument(a, param, raw);
    }
    return out;
}

test "embedded artifacts provide every tuple signature and named arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cat = try Catalog.load(a);
    try std.testing.expect(cat.methods.len > 300);
    const m = try cat.find("interactions", "upsertInteractionBundle");
    try std.testing.expectEqualStrings("upsertInteractionBundle(bytes32,(bytes32,bytes,uint256,(bytes32,bytes)[]))", m.signature);
    const args = try arguments(a, c.field(m.abi, "inputs").?.array.items, try c.parse(a, "{\"expectedCurrentBundleHash\":\"0x01\",\"bundle\":{\"id\":\"0x02\",\"script\":\"0xff\",\"flags\":\"0\",\"linked\":[]}}"));
    try std.testing.expectEqualStrings("(0x02,0xff,0,[])", args[1]);
}
