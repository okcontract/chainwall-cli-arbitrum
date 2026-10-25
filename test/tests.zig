const std = @import("std");
const ms = @import("miniscript");

// Flatten repeated byte patterns without changing the bounded-input fixtures.
fn repeat(comptime pattern: []const u8, comptime count: usize) [pattern.len * count]u8 {
    return std.mem.asBytes(&@as([count][pattern.len]u8, @splat(pattern.*))).*;
}

test "Golden programs compile and round trip in both modes" {
    const a = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, a, @embedFile("fixtures.json"), .{});
    defer parsed.deinit();
    for (parsed.value.array.items) |fixture| {
        const source = try ms.json.string(ms.json.field(fixture, "source").?);
        const settings = try ms.json.settings(ms.json.field(fixture, "settings"));
        const expected = try ms.bytecode.unhex(a, try ms.json.string(ms.json.field(fixture, "bytecode").?));
        defer a.free(expected);
        const bytes = try ms.compile(a, source, settings);
        defer a.free(bytes);
        std.testing.expectEqualSlices(u8, expected, bytes) catch |err| {
            std.debug.print("Fixture: {s}\n", .{try ms.json.string(ms.json.field(fixture, "id").?)});
            return err;
        };
        const assembly = try ms.disasm(a, bytes);
        defer a.free(assembly);
        const assembled = try ms.assemble(a, assembly);
        defer a.free(assembled);
        try std.testing.expectEqualSlices(u8, bytes, assembled);
        const recovered = try ms.decompile(a, bytes, settings);
        defer a.free(recovered);
        const recompiled = try ms.compile(a, recovered, settings);
        defer a.free(recompiled);
        try std.testing.expectEqualSlices(u8, bytes, recompiled);
    }
}

test "invalid source and bytecode fail without leaking" {
    const a = std.testing.allocator;
    const cases = [_]struct { source: []const u8, err: ms.Error }{
        .{ .source = "", .err = error.Syntax },
        .{ .source = "let x = x in x", .err = error.CyclicDefinition },
        .{ .source = "missing", .err = error.UnboundVariable },
        .{ .source = "0.5", .err = error.InvalidConstant },
        .{ .source = "$read(1, 0x100000000)", .err = error.InvalidConstant },
        .{ .source = "$read(1, 1, {let x = 1, x})", .err = error.InvalidArguments },
        .{ .source = "$arg9007199254740992", .err = error.InvalidConstant },
        .{ .source = "$readWords(1, 1, {}, [0])", .err = error.InvalidSettings },
        .{ .source = "IF($arg0, $noOp, 1) + 1", .err = error.InvalidType },
        .{ .source = "let x = 1 and x = 2 in x", .err = error.DuplicateBinding },
    };
    for (cases) |case| try std.testing.expectError(case.err, ms.compile(a, case.source, .{}));
    try std.testing.expectError(error.StackUnderflow, ms.decompile(a, &.{ 0x10, 0xff }, .{}));
    for ([_][]const u8{ &.{0x05}, &.{1}, &.{ 0x30, 0, 0 }, &.{ 0x30, 0, 2, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0xff } }) |bytes|
        try std.testing.expectError(error.InvalidBytecode, ms.bytecode.decode(a, bytes));
    try std.testing.expectError(error.InvalidBytecode, ms.bytecode.unhex(a, "0xzz"));
    try std.testing.expectError(error.InvalidBytecode, ms.assemble(a, "PUSH8 0x01"));
}

fn allocationRoundTrip(a: std.mem.Allocator) !void {
    const bytes = try ms.compile(a, "{let x = $read(10, 1), IF(x > 0, x + x, $arg0)}", .{});
    defer a.free(bytes);
    const source = try ms.decompile(a, bytes, .{});
    defer a.free(source);
    const assembly = try ms.disasm(a, bytes);
    defer a.free(assembly);
    const assembled = try ms.assemble(a, assembly);
    defer a.free(assembled);
    const instructions = try ms.bytecode.decode(a, bytes);
    defer a.free(instructions);
    const encoded = try ms.bytecode.encode(a, instructions);
    defer a.free(encoded);
    try std.testing.expectEqualSlices(u8, bytes, encoded);
}
test "public API handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationRoundTrip, .{});
}

test "recursive instructions reject every truncated immediate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixtures = try std.json.parseFromSlice(std.json.Value, a, @embedFile("fixtures.json"), .{});
    var checked: usize = 0;
    for (fixtures.value.array.items) |fixture| {
        const bytes = try ms.bytecode.unhex(a, try ms.json.string(ms.json.field(fixture, "bytecode").?));
        var pc: usize = 0;
        while (pc < bytes.len) {
            const op: ms.bytecode.Op = @fromBackingInt(@intCast(bytes[pc]));
            const width = try ms.bytecode.immediateLength(op, bytes[pc + 1 ..]);
            if (ms.bytecode.recursive(op)) {
                for (0..width) |length| {
                    if (ms.bytecode.decode(a, bytes[pc..][0 .. length + 1])) |_| return error.TestUnexpectedResult else |_| {}
                }
                const mutated = try a.dupe(u8, bytes[pc..][0 .. width + 1]);
                mutated[3] = 2;
                try std.testing.expectError(error.InvalidDescriptor, ms.bytecode.decode(a, mutated));
                checked += 1;
            }
            pc += 1 + width;
        }
    }
    try std.testing.expect(checked > 100);
}

test "reference extraction and compiler cap include discarded effects" {
    const a = std.testing.allocator;
    const bytes = try ms.compile(a, "{$staticLinked(1), $calli(12, {$arg0}), $read(10, 1)}", .{});
    defer a.free(bytes);
    var refs = try ms.references.scan(a, bytes);
    defer refs.deinit(a);
    try std.testing.expect(refs.complete);
    try std.testing.expectEqualSlices(u256, &.{1}, refs.linked_relations.items);
    try std.testing.expectEqualSlices(u256, &.{12}, refs.calli_ids.items);
    try std.testing.expectEqualSlices(u256, &.{10}, refs.targets.items);
    var source: std.Io.Writer.Allocating = .init(a);
    defer source.deinit();
    try source.writer.writeByte('{');
    for (0..129) |_| try source.writer.writeAll("$staticLinked(1),");
    try source.writer.writeAll("1}");
    try std.testing.expectError(error.ResourceLimit, ms.compile(a, source.written(), .{}));
}

test "compiler bounds operator chains, postfix trees and flat input" {
    const a = std.testing.allocator;
    for ([_][]const u8{
        repeat("1&&", 40000) ++ "1",
        repeat("1+", 15000) ++ "1",
        "1" ++ repeat("[0]", 1000),
        "{" ++ repeat("1,", 9000) ++ "1}",
    }) |source| try std.testing.expectError(error.ResourceLimit, ms.compile(a, source, .{}));
}

test "ABI metadata bounds array dimensions before recursive layout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const value = try std.json.parseFromSlice(std.json.Value, a, "{\"name\":\"f\",\"stateMutability\":\"view\",\"inputs\":[{\"type\":\"uint256" ++ repeat("[]", 20000) ++ "\"}]}", .{});
    try std.testing.expectError(error.InvalidDescriptor, ms.abi.method(a, value.value));
}

test "lowering bounds definition chains and compiler rewrite growth" {
    const a = std.testing.allocator;
    var source: std.Io.Writer.Allocating = .init(a);
    defer source.deinit();
    try source.writer.writeAll("let x0 = 1\n");
    for (1..1000) |i| try source.writer.print("and x{d} = x{d}\n", .{ i, i - 1 });
    try source.writer.writeAll("in x999");
    try std.testing.expectError(error.ResourceLimit, ms.compile(a, source.written(), .{}));
    // Flat source can generate a deep chain of intermediate let bindings.
    try std.testing.expectError(error.ResourceLimit, ms.compile(a, "{" ++ repeat("$read(1, 1),", 1500) ++ "1}", .{}));
    // Decompilation repeatedly substitutes prior expressions into this chain.
    const bytes = try ms.bytecode.unhex(a, "0101" ++ repeat("010110", 2000) ++ "ff");
    defer a.free(bytes);
    try std.testing.expectError(error.ResourceLimit, ms.decompile(a, bytes, .{}));
}
