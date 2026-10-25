const std = @import("std");
const c = @import("common.zig");
const abi = @import("abi_codec.zig");
const ms = @import("miniscript");
pub const zero_address = "0x0000000000000000000000000000000000000000";
pub const lifetime = 90 * 24 * 60 * 60;

pub fn field(value: c.Value, name: []const u8) !c.Value {
    return c.field(value, name) orelse error.InvalidCommitmentDraft;
}
pub fn string(value: c.Value, name: []const u8) ![]const u8 {
    return c.string(try field(value, name));
}
pub fn strict(value: c.Value, fields: []const u8) !void {
    if (value != .object) return error.InvalidCommitmentDraft;
    for (value.object.keys()) |name| if (!@import("schema.zig").contains(fields, name)) return error.UnknownCommitmentField;
}
pub fn word(a: c.A, value: c.Value) !c.Value {
    const text = try c.string(value);
    if (text.len != 66 or !std.mem.startsWith(u8, text, "0x")) return error.InvalidCommitmentWord;
    return .{ .string = try c.hex(a, try c.word(text)) };
}
fn hash(a: c.A, bytes: []const u8) !c.Value {
    return .{ .string = try c.hex(a, ms.bytecode.hash(bytes)) };
}
pub fn hashFields(a: c.A, types: []const u8, values: []const c.Value) !c.Value {
    var params = std.json.Array.init(a);
    var names = std.mem.tokenizeScalar(u8, types, ' ');
    while (names.next()) |name| try params.append(try c.parse(a, try c.encode(a, .{ .type = name })));
    return hash(a, try abi.encode(a, .{ .array = params }, try abi.array(a, values)));
}
fn address(a: c.A, value: c.Value) !c.Value {
    const text = try c.string(value);
    if (text.len != 42 or !std.mem.startsWith(u8, text, "0x") or try c.word(text) > std.math.maxInt(u160)) return error.InvalidAddress;
    return .{ .string = try std.ascii.allocLowerString(a, text) };
}
fn identifier(value: []const u8) !void {
    try @import("labels.zig").validateText(value);
    for (value) |ch| if (std.ascii.isUpper(ch) or ch == '/') return error.InvalidCommitmentIdentifier;
}
fn less(_: void, left: c.Value, right: c.Value) bool {
    return std.mem.order(u8, left.string, right.string) == .lt;
}
fn linkedLess(_: void, left: c.Value, right: c.Value) bool {
    return less({}, c.field(left, "relation").?, c.field(right, "relation").?);
}

/// Normalize before hashing. Sorting never changes an interaction's semantics;
/// duplicate relations or related contracts remain errors, never silent drops.
pub fn payload(a: c.A, kind: []const u8, input: c.Value) !c.Value {
    if (c.eq(u8, kind, "interaction")) {
        try strict(input, "bundle relatedContracts");
        const bundle = try field(input, "bundle");
        try strict(bundle, "id script flags linked");
        const id = try c.id(a, try string(bundle, "id"));
        const script = try abi.unhex(a, try string(bundle, "script"));
        if (script.len == 0 or script.len > 8192) return error.InvalidInteractionScriptLength;
        const flags = try c.number(a, c.field(bundle, "flags") orelse c.Value{ .integer = 0 });
        if (flags & ~@as(u256, 6) != 0) return error.InvalidInteractionFlags;
        const linked = c.field(bundle, "linked") orelse try abi.array(a, &.{});
        if (linked != .array or linked.array.items.len > 16) return error.InvalidLinkedArtifacts;
        var size = script.len;
        for (linked.array.items) |*item| {
            try strict(item.*, "relation payload");
            const relation = try word(a, try field(item.*, "relation"));
            if (try c.number(a, relation) == 0) return error.InvalidLinkedArtifacts;
            const bytes = try abi.unhex(a, try string(item.*, "payload"));
            size += bytes.len;
            if (bytes.len == 0 or bytes.len > 8192 or size > 16384) return error.InvalidLinkedArtifacts;
            item.* = try c.parse(a, try c.encode(a, .{ .relation = relation, .payload = try abi.hex(a, bytes) }));
        }
        std.mem.sort(c.Value, linked.array.items, {}, linkedLess);
        for (linked.array.items, 0..) |item, i| if (i > 0 and c.eq(u8, try string(item, "relation"), try string(linked.array.items[i - 1], "relation"))) return error.DuplicateLinkedRelation;
        const related = c.field(input, "relatedContracts") orelse try abi.array(a, &.{});
        if (related != .array or related.array.items.len > 128) return error.InvalidRelatedContracts;
        for (related.array.items) |*item| {
            item.* = try word(a, item.*);
            if (try c.number(a, item.*) == 0) return error.InvalidRelatedContracts;
        }
        std.mem.sort(c.Value, related.array.items, {}, less);
        for (related.array.items, 0..) |item, i| if (i > 0 and c.eq(u8, item.string, related.array.items[i - 1].string)) return error.DuplicateRelatedContract;
        return c.parse(a, try c.encode(a, .{ .bundle = .{ .id = id, .script = try abi.hex(a, script), .flags = try abi.uint(a, flags), .linked = linked }, .relatedContracts = related }));
    }
    if (!@import("schema.zig").contains("contract token", kind)) return error.InvalidCommitmentKind;
    const org = try string(input, "org");
    const id = try string(input, "id");
    try identifier(org);
    try identifier(id);
    if (c.eq(u8, kind, "contract")) {
        try strict(input, "org id address version implementation label");
        const addr = try address(a, try field(input, "address"));
        try c.address(addr.string);
        const version = try string(input, "version");
        var version_word: [32]u8 = @splat(0);
        const version_hex = if (std.mem.startsWith(u8, version, "0x")) (try word(a, .{ .string = version })).string else blk: {
            try @import("labels.zig").validateText(version);
            if (version.len > 32) return error.ContractVersionTooLong;
            @memcpy(version_word[0..version.len], version);
            break :blk try abi.hex(a, &version_word);
        };
        return c.parse(a, try c.encode(a, .{ .org = org, .id = id, .address = addr, .version = version_hex, .implementation = try address(a, c.field(input, "implementation") orelse c.Value{ .string = zero_address }), .label = try word(a, c.field(input, "label") orelse c.Value{ .string = try c.hex(a, 0) }) }));
    }
    try strict(input, "org id symbol decimals price priceFeedDecimals flags");
    const symbol = try string(input, "symbol");
    try @import("labels.zig").validateText(symbol);
    const decimals = try c.number(a, try field(input, "decimals"));
    const feed_decimals = try c.number(a, c.field(input, "priceFeedDecimals") orelse c.Value{ .integer = 0 });
    const price = try address(a, c.field(input, "price") orelse c.Value{ .string = zero_address });
    const flags = try c.number(a, c.field(input, "flags") orelse c.Value{ .integer = 0 });
    if (decimals > 36 or feed_decimals > 36 or (try c.number(a, price) == 0 and feed_decimals != 0)) return error.InvalidTokenDecimals;
    if (flags & ~@as(u256, 2) != 0) return error.InvalidTokenFlags;
    return c.parse(a, try c.encode(a, .{ .org = org, .id = id, .symbol = symbol, .decimals = try abi.uint(a, decimals), .price = price, .priceFeedDecimals = try abi.uint(a, feed_decimals), .flags = try abi.uint(a, flags) }));
}
pub fn key(a: c.A, kind: []const u8, value: c.Value) !c.Value {
    if (c.eq(u8, kind, "interaction")) return field(try field(value, "bundle"), "id");
    return hash(a, try a.print("{s}/{s}", .{ try string(value, "org"), try string(value, "id") }));
}
pub fn commitment(a: c.A, kind: []const u8, value: c.Value, salt: c.Value) !c.Value {
    const id = try key(a, kind, value);
    var payload_hash: c.Value = undefined;
    var domain: []const u8 = undefined;
    if (c.eq(u8, kind, "interaction")) {
        const bundle = try field(value, "bundle");
        var linked = std.json.Array.init(a);
        for ((try field(bundle, "linked")).array.items) |item| try linked.append(try hashFields(a, "bytes32 bytes32 bytes32", &.{ try hash(a, "LinkedArtifactHash(bytes32 relation,bytes32 payloadHash)"), try field(item, "relation"), try hash(a, try abi.unhex(a, try string(item, "payload"))) }));
        const flags = try c.number(a, try field(bundle, "flags"));
        const content = try hashFields(a, "bytes32 bytes32 bytes32 uint256 bytes32", &.{ try hash(a, "InteractionContent(bytes32 id,bytes32 scriptHash,uint256 flags,bytes32 linkedArtifactsHash)"), id, try hash(a, try abi.unhex(a, try string(bundle, "script"))), try abi.uint(a, flags & ~@as(u256, 2)), try hashFields(a, "bytes32[]", &.{.{ .array = linked }}) });
        const bundle_hash = try hashFields(a, "bytes32 bytes32 bool", &.{ try hash(a, "InteractionBundle(bytes32 contentHash,bool active)"), content, .{ .bool = flags & 2 == 0 } });
        return hashFields(a, "bytes32 bytes32 bytes32 bytes32 uint256", &.{ try hash(a, "InteractionBundleCommit(bytes32 bundleHash,bytes32 relatedContractsHash,bytes32 salt,uint256 schema)"), bundle_hash, try hashFields(a, "bytes32[]", &.{try field(value, "relatedContracts")}), try word(a, salt), try abi.uint(a, 1) });
    } else if (c.eq(u8, kind, "contract")) {
        domain = "ContractCommit(bytes32 key,bytes32 payloadHash,bytes32 salt,uint256 schema)";
        payload_hash = try hashFields(a, "bytes32 address bytes32 address bytes32", &.{ id, try field(value, "address"), try field(value, "version"), try field(value, "implementation"), try field(value, "label") });
    } else if (c.eq(u8, kind, "token")) {
        domain = "TokenCommit(bytes32 key,bytes32 payloadHash,bytes32 salt,uint256 schema)";
        payload_hash = try hashFields(a, "bytes32 string uint8 address uint8 uint256", &.{ id, try field(value, "symbol"), try field(value, "decimals"), try field(value, "price"), try field(value, "priceFeedDecimals"), try field(value, "flags") });
    } else return error.InvalidCommitmentKind;
    return hashFields(a, "bytes32 bytes32 bytes32 bytes32 uint256", &.{ try hash(a, domain), id, payload_hash, try word(a, salt), try abi.uint(a, 1) });
}
pub fn methodName(kind: []const u8, verb: []const u8) ![]const u8 {
    const names = [_][7][]const u8{
        .{ "contract", "commitContractPrivate", "revealContractCommit", "cancelContractCommit", "expireContractCommit", "getContractCommitByKey", "Contract" },
        .{ "token", "commitTokenPrivate", "revealTokenCommit", "cancelTokenCommit", "expireTokenCommit", "getTokenCommitByKey", "Token" },
        .{ "interaction", "commitInteractionPrivate", "revealInteractionCommit", "cancelInteractionCommit", "cancelInteractionCommit", "getInteractionCommit", "Interaction" },
    };
    const index: usize = if (c.eq(u8, verb, "commit")) 1 else if (c.eq(u8, verb, "reveal")) 2 else if (c.eq(u8, verb, "cancel")) 3 else if (c.eq(u8, verb, "expire")) 4 else if (c.eq(u8, verb, "status")) 5 else if (c.eq(u8, verb, "prefix")) 6 else return error.UnknownCommand;
    for (names) |row| if (c.eq(u8, kind, row[0])) return row[index];
    return error.InvalidCommitmentKind;
}
pub fn arguments(a: c.A, draft: c.Value, verb: []const u8, signature: c.Value) !c.Value {
    const value = try field(draft, "payload");
    const kind = try string(draft, "kind");
    const interaction = c.eq(u8, kind, "interaction");
    var args = std.json.Array.init(a);
    if (c.eq(u8, verb, "reveal")) {
        if (interaction) try args.appendSlice(&.{ try field(value, "bundle"), try field(value, "relatedContracts") }) else if (c.eq(u8, kind, "token")) {
            try args.appendSlice(&.{ try c.parse(a, try c.encode(a, .{ .org = try field(value, "org"), .id = try field(value, "id"), .symbol = try field(value, "symbol"), .decimals = try field(value, "decimals"), .price = try field(value, "price"), .priceFeedDecimals = try field(value, "priceFeedDecimals") })), try field(value, "flags") });
        } else try args.appendSlice(&.{ try field(value, "org"), try field(value, "id"), try c.parse(a, try c.encode(a, .{ .addr = try field(value, "address"), .version = try field(value, "version"), .implementation = try field(value, "implementation") })), try field(value, "label") });
        try args.appendSlice(&.{ try field(draft, "salt"), signature });
    } else {
        if (interaction) try args.append(try field(draft, "key")) else try args.appendSlice(&.{ try field(value, "org"), try field(value, "id") });
        if (c.eq(u8, verb, "commit")) try args.appendSlice(&.{ try field(draft, "commitHash"), try field(draft, "deadline"), try field(draft, "forwarder"), try field(draft, "hint") });
    }
    return .{ .array = args };
}
pub fn validate(a: c.A, draft: c.Value, chain: u64, registry: []const u8) !void {
    if (!c.eq(u8, try string(draft, "type"), "chainwall.privateCommitment") or try c.number(a, try field(draft, "version")) != 1) return error.InvalidCommitmentDraft;
    if (try c.number(a, try field(draft, "chainId")) != chain or !std.ascii.eqlIgnoreCase(try string(draft, "registry"), registry)) return error.CommitmentContextMismatch;
    const kind = try string(draft, "kind");
    const normalized = try payload(a, kind, try field(draft, "payload"));
    if (try c.number(a, try commitment(a, kind, normalized, try field(draft, "salt"))) != try c.number(a, try field(draft, "commitHash")) or try c.number(a, try key(a, kind, normalized)) != try c.number(a, try field(draft, "key"))) return error.CommitmentHashMismatch;
    if (try c.number(a, try field(draft, "deadline")) == 0 or try c.number(a, try field(draft, "deadline")) > std.math.maxInt(u64)) return error.InvalidCommitmentDeadline;
    _ = try @import("rpc.zig").integer(a, try field(draft, "createdAt"));
    _ = try address(a, try field(draft, "forwarder"));
    _ = try word(a, try field(draft, "hint"));
}
pub fn summary(a: c.A, draft: c.Value) !c.Value {
    var fields: std.json.ObjectMap = .empty;
    for ([_][]const u8{ "type", "version", "chainId", "registry", "kind", "key", "commitHash", "deadline", "forwarder", "hint", "createdAt" }) |name| try fields.put(a, name, try field(draft, name));
    const attempt = c.field(draft, "attempt") orelse c.Value.null;
    if (attempt != .null) try fields.put(a, "lastAttempt", try c.parse(a, try c.encode(a, .{ .verb = try field(attempt, "verb"), .actor = try field(attempt, "actor"), .outcome = c.field(attempt, "outcome") orelse c.Value.null, .transactionHash = c.field(c.field(attempt, "receipt") orelse .null, "transactionHash") orelse c.Value.null })));
    return .{ .object = fields };
}
