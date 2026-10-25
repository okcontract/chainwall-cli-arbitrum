const std = @import("std");
const c = @import("common.zig");
const abi = @import("abi_codec.zig");
const ms = @import("miniscript");
const contracts = @import("contracts.zig");
const rpc = @import("rpc.zig");

pub const Entry = struct {
    cat: contracts.Catalog,
    item: c.Value,
    manifest: c.Value,
    key: []const u8,

    pub fn method(e: Entry, name: []const u8) !contracts.Method {
        return e.cat.find(try c.string(c.field(e.item, "group").?), name);
    }
};

pub fn find(a: c.A, cat: contracts.Catalog, key: []const u8) !Entry {
    for (c.field(cat.root, "contracts").?.array.items) |item| {
        const manifest = c.field(item, "manifest").?;
        const name = try c.string(c.field(manifest, "key").?);
        if (c.eq(u8, key, name) or c.eq(u8, key, try c.kebab(a, name))) return .{ .cat = cat, .item = item, .manifest = manifest, .key = name };
    }
    return error.UnknownRelease;
}

pub fn constructor(e: Entry, a: c.A) !c.Value {
    for (c.field(c.field(e.item, "artifact").?, "abi").?.array.items) |item| {
        if (c.eq(u8, try c.string(c.field(item, "type").?), "constructor")) return c.field(item, "inputs").?;
    }
    return abi.array(a, &.{});
}

pub fn deploymentData(e: Entry, a: c.A, arguments: ?c.Value) ![]const u8 {
    const bytecode = try c.string(c.field(e.manifest, "creationBytecode").?);
    if (bytecode.len <= 2) return error.ReleaseHasNoCreationCode;
    if (arguments == null) if (c.field(e.item, "defaultDeploymentData")) |data| return c.string(data);
    const params = try constructor(e, a);
    if (params.array.items.len > 0 and arguments == null) return error.ConstructorArgumentsRequired;
    const encoded = try abi.encode(a, params, arguments orelse try abi.array(a, &.{}));
    const suffix = try abi.hex(a, encoded);
    return std.mem.concat(a, u8, &.{ bytecode, suffix[2..] });
}

/// Compare runtime bytecode while masking only solc's declared
/// immutable ranges, preserving all executable bytes and metadata otherwise.
pub fn runtime(a: c.A, manifest: c.Value, code: []const u8) !c.Value {
    const template = try abi.unhex(a, try c.string(c.field(manifest, "runtimeBytecode").?));
    const actual = try abi.unhex(a, code);
    const actual_hash: c.Value = if (actual.len > 0) .{ .string = try c.hex(a, ms.bytecode.hash(actual)) } else .null;
    var issue: ?[]const u8 = null;
    var masked_hash: c.Value = .null;
    var matches: c.Value = .null;
    if (actual.len == 0 or template.len == 0) {
        issue = "missing-runtime";
    } else if (actual.len != template.len) {
        issue = "length";
        matches = .{ .bool = false };
    } else {
        for (c.field(manifest, "immutableReferences").?.array.items) |reference| {
            const start = try rpc.integer(a, c.field(reference, "start").?);
            const length = try rpc.integer(a, c.field(reference, "length").?);
            if (start > actual.len or length > actual.len - start) return error.InvalidReleaseManifest;
            @memset(actual[@intCast(start)..][0..@intCast(length)], 0);
            @memset(template[@intCast(start)..][0..@intCast(length)], 0);
        }
        matches = .{ .bool = c.eq(u8, actual, template) };
        masked_hash = .{ .string = try c.hex(a, ms.bytecode.hash(actual)) };
        if (!matches.bool) issue = "bytecode";
    }
    return c.parse(a, try c.encode(a, .{ .matches = matches, .actualCodehash = actual_hash, .maskedCodehash = masked_hash, .issue = if (issue) |text| c.Value{ .string = text } else c.Value.null }));
}

pub fn codeAt(remote: *rpc.Rpc, address: []const u8) ![]const u8 {
    return c.string(try remote.one("eth_getCode", try abi.array(remote.a, &.{ .{ .string = address }, try remote.blockSelector() })));
}

pub fn read(remote: *rpc.Rpc, entry: Entry, address: []const u8, name: []const u8, args: []const c.Value) !c.Value {
    const saved = remote.address;
    remote.address = address;
    defer remote.address = saved;
    const result = try remote.call(try entry.method(name), args);
    if (result != .array or result.array.items.len != 1) return error.InvalidContractResponse;
    return result.array.items[0];
}

fn optionalRead(remote: *rpc.Rpc, entry: Entry, address: []const u8, name: []const u8) !c.Value {
    return read(remote, entry, address, name, &.{}) catch |err| switch (err) {
        error.RpcRejectedRequest => .null,
        else => return err,
    };
}

pub fn same(left: c.Value, right: c.Value) bool {
    if (left == .null or right == .null) return left == .null and right == .null;
    return std.ascii.eqlIgnoreCase(c.string(left) catch return false, c.string(right) catch return false);
}

pub fn verify(remote: *rpc.Rpc, entry: Entry, address: []const u8) !c.Value {
    const a = remote.a;
    try c.address(address);
    const code = try codeAt(remote, address);
    const comparison = try runtime(a, entry.manifest, code);
    var issues = std.json.Array.init(a);
    if (c.field(comparison, "matches").? != .bool or !c.field(comparison, "matches").?.bool) try issues.append(.{ .string = "artifact-runtime" });
    var component: c.Value = .null;
    var protocol: c.Value = .null;
    var bindings: c.Value = .null;
    var uups: c.Value = .null;
    const expected_component = c.field(entry.manifest, "componentId").?;
    const expected_protocol = c.field(entry.manifest, "protocolVersion").?;
    if (code.len > 2 and expected_component != .null) {
        component = try optionalRead(remote, entry, address, "chainwallComponentId");
        if (!same(component, expected_component)) try issues.append(.{ .string = "component" });
    }
    if (code.len > 2 and expected_protocol != .null) {
        protocol = try optionalRead(remote, entry, address, "chainwallUpgradeProtocolVersion");
        if (protocol == .null or try c.number(a, protocol) != try c.number(a, expected_protocol)) try issues.append(.{ .string = "protocol" });
        // A standalone stable dispatcher locks its factory slot to itself.
        // Its binding view is meaningful only on initialized account clones.
        if (c.eq(u8, try c.string(c.field(entry.manifest, "role").?), "component-implementation")) {
            bindings = try optionalRead(remote, entry, address, "chainwallSecurityBindingsHash");
            if (bindings == .null) try issues.append(.{ .string = "security-bindings" });
        }
    }
    if (code.len > 2 and c.field(entry.manifest, "requiresUups").?.bool) {
        uups = try optionalRead(remote, entry, address, "proxiableUUID");
        if (!same(uups, c.field(entry.cat.root, "implementationSlot").?)) try issues.append(.{ .string = "uups" });
    }
    var dependencies = std.json.Array.init(a);
    // Parent release comparisons mask immutable pointers. Validate each
    // constructor-created delegatecall dependency by its exact accepted hash.
    const dependency: ?[2][]const u8 = if (c.eq(u8, entry.key, "interact")) .{ "OPS_MODULE", "interactOpsModule" } else if (c.eq(u8, entry.key, "registry")) .{ "PAUSE_MODULE", "registryPauseModule" } else null;
    if (dependency) |pair| if (code.len > 2) {
        const pointer = try optionalRead(remote, entry, address, pair[0]);
        var codehash: c.Value = .null;
        var accepted = false;
        if (pointer != .null and try c.number(a, pointer) != 0) {
            const child_code = try abi.unhex(a, try codeAt(remote, try c.string(pointer)));
            if (child_code.len > 0) codehash = .{ .string = try c.hex(a, ms.bytecode.hash(child_code)) };
            for (c.field(c.field(entry.cat.root, "acceptedCodehashes").?, pair[1]).?.array.items) |expected| if (same(codehash, expected)) {
                accepted = true;
                break;
            };
        }
        if (!accepted) try issues.append(.{ .string = "release-dependency-runtime" });
        try dependencies.append(try c.parse(a, try c.encode(a, .{ .key = pair[1], .address = pointer, .codehash = codehash, .accepted = accepted })));
    };
    return c.parse(a, try c.encode(a, .{ .release = entry.key, .address = address, .compatible = issues.items.len == 0, .runtime = comparison, .componentId = component, .protocolVersion = protocol, .securityBindingsHash = bindings, .proxiableUuid = uups, .releaseDependencies = dependencies.items, .issues = issues.items, .block = remote.block }));
}
