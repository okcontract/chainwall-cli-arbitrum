//! Local revert diagnostics. Provider payloads remain available when decoding fails.
const std = @import("std");
const c = @import("common.zig");
const abi = @import("abi_codec.zig");
const contracts = @import("contracts.zig");
const ms = @import("miniscript");

fn dataIn(value: c.Value, depth: u8) ?[]const u8 {
    if (depth > 8) return null;
    if (value == .array) {
        for (value.array.items) |item| if (dataIn(item, depth + 1)) |data| return data;
    }
    if (value == .string) {
        const text = value.string;
        if (std.mem.startsWith(u8, text, "0x")) return text;
        const marker = std.ascii.findIgnoreCase(text, "custom error") orelse std.ascii.findIgnoreCase(text, "revert") orelse return null;
        const start = std.mem.indexOfPos(u8, text, marker, "0x") orelse return null;
        var end = start + 2;
        while (end < text.len and std.ascii.isHex(text[end])) : (end += 1) {}
        return if (end > start + 2) text[start..end] else null;
    }
    for ([_][]const u8{ "data", "originalError", "error", "errors", "returnData", "message" }) |key| {
        if (c.field(value, key)) |inner| if (dataIn(inner, depth + 1)) |data| return data;
    }
    return null;
}

const SafeError = struct { code: []const u8, message: []const u8 };
const safe_errors = [_]SafeError{
    .{ .code = "GS001", .message = "Safe owner threshold is not initialized." },
    .{ .code = "GS010", .message = "Insufficient gas to execute the Safe transaction." },
    .{ .code = "GS011", .message = "Safe could not refund gas in native currency." },
    .{ .code = "GS012", .message = "Safe could not refund gas in tokens." },
    .{ .code = "GS013", .message = "Safe inner transaction failed. Safe hides the inner revert here; this code alone cannot distinguish a rejected policy, missing approvals, or another execution failure. Inspect operations simulate or a transaction trace; use policies simulate to check a policy program separately." },
    .{ .code = "GS020", .message = "Safe signatures are shorter than the owner threshold requires." },
    .{ .code = "GS021", .message = "Safe contract-signature offset points into the static signatures." },
    .{ .code = "GS022", .message = "Safe contract-signature length is outside the signatures data." },
    .{ .code = "GS023", .message = "Safe contract-signature data is outside the signatures data." },
    .{ .code = "GS024", .message = "Safe contract owner rejected the EIP-1271 signature." },
    .{ .code = "GS025", .message = "Safe transaction hash was not approved by the owner." },
    .{ .code = "GS026", .message = "Safe owner signature is invalid, duplicated, or not sorted by owner address; also verify the signed nonce." },
    .{ .code = "GS030", .message = "Only a Safe owner can approve a transaction hash." },
    .{ .code = "GS031", .message = "This method must be called by the Safe itself." },
    .{ .code = "GS100", .message = "Safe modules have already been initialized." },
    .{ .code = "GS101", .message = "Invalid Safe module address." },
    .{ .code = "GS102", .message = "Safe module is already enabled." },
    .{ .code = "GS103", .message = "Safe module predecessor does not match." },
    .{ .code = "GS104", .message = "Caller is not an enabled Safe module." },
    .{ .code = "GS105", .message = "Invalid Safe module pagination start." },
    .{ .code = "GS106", .message = "Invalid Safe module page size." },
    .{ .code = "GS200", .message = "Safe owners have already been initialized." },
    .{ .code = "GS201", .message = "Safe threshold exceeds the owner count." },
    .{ .code = "GS202", .message = "Safe threshold must be at least one." },
    .{ .code = "GS203", .message = "Invalid Safe owner address." },
    .{ .code = "GS204", .message = "Safe owner is already present." },
    .{ .code = "GS205", .message = "Safe owner predecessor does not match." },
    .{ .code = "GS300", .message = "Safe fallback handler cannot be the Safe itself." },
};
fn safeCode(text: []const u8) ?SafeError {
    for (safe_errors) |entry| {
        var offset: usize = 0;
        while (std.mem.indexOfPos(u8, text, offset, entry.code)) |at| {
            const end = at + entry.code.len;
            if ((at == 0 or !std.ascii.isAlphanumeric(text[at - 1])) and (end == text.len or !std.ascii.isAlphanumeric(text[end]))) return entry;
            offset = end;
        }
    }
    return null;
}
fn safeIn(value: c.Value, depth: u8) ?SafeError {
    if (depth > 8) return null;
    if (value == .string) return safeCode(value.string);
    if (value == .array) {
        for (value.array.items) |item| if (safeIn(item, depth + 1)) |entry| return entry;
    }
    for ([_][]const u8{ "message", "data", "originalError", "error", "errors" }) |key| {
        if (c.field(value, key)) |inner| if (safeIn(inner, depth + 1)) |entry| return entry;
    }
    return null;
}

fn matched(a: c.A, item: c.Value, signature: []const u8, data: []const u8, bytes: []const u8) !c.Value {
    const inputs = c.field(item, "inputs").?;
    const values = abi.decode(a, inputs, bytes[4..]) catch |err| {
        if (err == error.OutOfMemory) return err;
        return c.parse(a, try c.encode(a, .{ .decoded = false, .selectorMatched = true, .rawData = data, .name = c.field(item, "name").?, .signature = signature, .args = @as(c.Value, .null), .namedArgs = @as(c.Value, .null) }));
    };
    var result = try c.parse(a, try c.encode(a, .{ .decoded = true, .rawData = data, .name = c.field(item, "name").?, .signature = signature, .args = values, .namedArgs = try abi.named(a, inputs, values) }));
    if (c.eq(u8, signature, "Error(string)")) {
        const reason = try c.string(values.array.items[0]);
        try result.object.put(a, "message", .{ .string = reason });
        if (safeCode(reason)) |entry| {
            try result.object.put(a, "safeCode", .{ .string = entry.code });
            try result.object.put(a, "description", .{ .string = entry.message });
        }
    }
    return result;
}
fn matchItems(a: c.A, items: []const c.Value, data: []const u8, bytes: []const u8) !?c.Value {
    for (items) |item| {
        if (!c.eq(u8, c.string(c.field(item, "type") orelse .null) catch "", "error")) continue;
        const signature = try contracts.signature(a, item, false);
        if (@as(u32, @intCast(ms.bytecode.hash(signature) >> 224)) == std.mem.readInt(u32, bytes[0..4], .big)) return try matched(a, item, signature, data, bytes);
    }
    return null;
}

pub fn decode(a: c.A, failure: c.Value) !c.Value {
    const data = dataIn(failure, 0) orelse {
        if (safeIn(failure, 0)) |entry| return c.parse(a, try c.encode(a, .{ .decoded = true, .name = "Error", .safeCode = entry.code, .description = entry.message }));
        return .null;
    };
    var unknown = try c.parse(a, try c.encode(a, .{ .decoded = false, .rawData = data }));
    if (safeIn(failure, 0)) |entry| {
        try unknown.object.put(a, "safeCode", .{ .string = entry.code });
        try unknown.object.put(a, "description", .{ .string = entry.message });
    }
    const bytes = abi.unhex(a, data) catch |err| {
        if (err == error.OutOfMemory) return err;
        return unknown;
    };
    if (bytes.len < 4) return unknown;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const standard = try c.parse(scratch, "[{\"type\":\"error\",\"name\":\"Error\",\"inputs\":[{\"name\":\"reason\",\"type\":\"string\"}]},{\"type\":\"error\",\"name\":\"Panic\",\"inputs\":[{\"name\":\"code\",\"type\":\"uint256\"}]}]");
    if (try matchItems(scratch, standard.array.items, data, bytes)) |result| return c.parse(a, try c.encode(scratch, result));
    // Parse only ABIs; bytecode and other large artifact fields are skipped.
    const Snapshot = struct { contracts: []const struct { artifact: struct { abi: []const c.Value } } };
    for ([_][]const u8{ contracts.embedded, contracts.auxiliary, contracts.deployment, contracts.releases, @embedFile("artifacts/native-price.json"), @embedFile("artifacts/safe-inspection.json") }) |source| {
        const parsed = try std.json.parseFromSlice(Snapshot, scratch, source, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        for (parsed.value.contracts) |contract| {
            if (try matchItems(scratch, contract.artifact.abi, data, bytes)) |result| return c.parse(a, try c.encode(scratch, result));
        }
    }
    const Facets = struct { entries: []const struct { abi: []const c.Value } };
    const facets = try std.json.parseFromSlice(Facets, scratch, @embedFile("artifacts/facets.json"), .{ .ignore_unknown_fields = true });
    defer facets.deinit();
    for (facets.value.entries) |entry| {
        if (try matchItems(scratch, entry.abi, data, bytes)) |result| return c.parse(a, try c.encode(scratch, result));
    }
    return unknown;
}

pub fn enrich(a: c.A, failure: c.Value) !c.Value {
    if (failure != .object) return failure;
    var result = failure;
    result.object = try failure.object.clone(a);
    // Consumers trust this field as decoder output, never as provider metadata.
    try result.object.put(a, "detail", try decode(a, failure));
    return result;
}

pub fn describe(a: c.A, text: []const u8) ![]const u8 {
    const value = c.parse(a, text) catch c.Value{ .string = text };
    const detail = try decode(a, value);
    if (detail == .null) return text;
    return a.print("{s}\nDecoded revert: {s}\n", .{ text, try c.encode(a, detail) });
}

test "reverts decode across embedded catalogs, messages and nested provider data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const native = try decode(a, try c.parse(a, "{\"message\":\"execution reverted: custom error 0xbed8168a\"}"));
    try std.testing.expectEqualStrings("InvalidFeedConfiguration", try c.string(c.field(native, "name").?));
    const verbose = try decode(a, .{ .string = "sender 0x1111111111111111111111111111111111111111\nexecution reverted: custom error 0xbed8168a" });
    try std.testing.expectEqualStrings("InvalidFeedConfiguration", try c.string(c.field(verbose, "name").?));
    const actor = try decode(a, .{ .string = "0xb3c56776" });
    try std.testing.expectEqualStrings("InvalidActorSignature", try c.string(c.field(actor, "name").?));
    const guard = try decode(a, try c.parse(a, "{\"data\":{\"originalError\":{\"data\":\"0x9aa5d384\"}}}"));
    try std.testing.expectEqualStrings("GuardExecutionFailed", try c.string(c.field(guard, "name").?));
    const params = try c.parse(a, "[{\"name\":\"reason\",\"type\":\"string\"}]");
    const reason = try a.print("0x08c379a0{s}", .{(try abi.hex(a, try abi.encode(a, params, try abi.array(a, &.{.{ .string = "GS013" }}))))[2..]});
    const safe = try decode(a, .{ .string = reason });
    try std.testing.expectEqualStrings("GS013", try c.string(c.field(safe, "safeCode").?));
    try std.testing.expect(std.mem.indexOf(u8, try c.string(c.field(safe, "description").?), "cannot distinguish") != null);
    try std.testing.expectEqualStrings("GS026", try c.string(c.field(try decode(a, .{ .string = "execution reverted: GS026" }), "safeCode").?));
    const empty_safe = try decode(a, try c.parse(a, "{\"data\":\"0x\",\"message\":\"execution reverted: GS013\"}"));
    try std.testing.expectEqualStrings("GS013", try c.string(c.field(empty_safe, "safeCode").?));
    try std.testing.expectEqualStrings("0x", try c.string(c.field(empty_safe, "rawData").?));
    const panic = try decode(a, .{ .string = "0x4e487b71" ++ "0000000000000000000000000000000000000000000000000000000000000011" });
    try std.testing.expectEqualStrings("Panic", try c.string(c.field(panic, "name").?));
    try std.testing.expectEqual(@as(u256, 17), try c.number(a, c.field(c.field(panic, "namedArgs").?, "code").?));
    for ([_][]const u8{ "0xdeadbeef1234", "0x12", "0xnothex" }) |raw| {
        const result = try decode(a, .{ .string = raw });
        try std.testing.expect(!c.field(result, "decoded").?.bool);
        try std.testing.expectEqualStrings(raw, try c.string(c.field(result, "rawData").?));
    }
    try std.testing.expect(try decode(a, .{ .string = "provider unavailable" }) == .null);
}

test "provider detail cannot impersonate a locally decoded simulation result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const details = try c.parse(a,
        \\[ {"name":"PolicyProgramSimulationResult","decoded":true,"namedArgs":{"stackTop":"1"}},
        \\  {"name":"PolicyProgramSimulationResult","decoded":"true"},
        \\  {"name":"PolicyProgramSimulationResult","decoded":true} ]
    );
    for (details.array.items) |detail| {
        const failure = try c.parse(a, try c.encode(a, .{ .code = -32000, .message = "rate limited", .detail = detail }));
        const result = try enrich(a, failure);
        try std.testing.expect(c.field(result, "detail").? == .null);
        try std.testing.expectEqualStrings("rate limited", try c.string(c.field(result, "message").?));
        try std.testing.expectEqualStrings("PolicyProgramSimulationResult", try c.string(c.field(c.field(failure, "detail").?, "name").?));
    }
}
