const std = @import("std");
pub const parser = @import("parser.zig");
pub const syntax = @import("syntax.zig");
pub const tree = @import("tree.zig");
pub const bytecode = @import("bytecode.zig");
pub const abi = @import("abi.zig");
const lower = @import("lower.zig");
const normalize = @import("normalize.zig");
const codegen = @import("codegen.zig");
const optimize = @import("optimize.zig");
pub const Settings = lower.Settings;
pub const references = @import("references.zig");
const validate = @import("validate.zig");
pub const Error = tree.Error;
pub const json = @import("json.zig");
pub const leanProgram = @import("lean.zig").program;
pub const decompile = @import("decompile.zig").decompile;
pub const disasm = @import("assembly.zig").disasm;
pub const assemble = @import("assembly.zig").assemble;

fn emit(a: std.mem.Allocator, root: *tree.Node) Error![]u8 {
    var generator: codegen.Generator = .{ .builder = .{ .a = a } };
    try validate.semantic(root);
    const items = try generator.run(root);
    const original = try bytecode.encode(a, items);
    const result = try bytecode.encode(a, try optimize.machine(a, items));
    if (!references.same(try references.scan(a, original), try references.scan(a, result))) return error.InvalidBytecode;
    return result;
}

/// The returned bytes belong to the caller. All intermediate allocations are
/// scoped to this compilation and released even on invalid input.
pub fn compile(a: std.mem.Allocator, source: []const u8, settings: Settings) Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    var f: tree.Factory = .{ .a = temp };
    var p: parser.Parser = .{ .f = &f, .source = source };
    const program = try p.parse();
    var l: lower.Lowerer = .{ .f = &f, .settings = try json.normalize(temp, settings) };
    const lowered = try l.run(program);
    try validate.semantic(lowered);
    var normalizer: normalize.Normalizer = .{ .f = &f };
    const normalized = try normalizer.run(lowered);
    try validate.boundedDepth(normalized, 0);
    const root = try lower.dependencies(&f, try normalize.schedule(&f, normalized, false));
    var best = try emit(temp, root);
    const contract = try references.scan(temp, best);
    if (settings.optimization == .size) {
        for ([_]struct { max: usize, last: bool }{ .{ .max = 2, .last = true }, .{ .max = 1, .last = false }, .{ .max = 1, .last = true } }) |variant| {
            if (try optimize.constants(&f, root, variant.max, variant.last)) |candidate| {
                const bytes = emit(temp, candidate) catch |err| {
                    if (err == error.StackCapacity) continue;
                    return err;
                };
                if (!references.same(contract, try references.scan(temp, bytes))) return error.InvalidBytecode;
                if (bytes.len < best.len) best = bytes;
            }
        }
    }
    if ((try references.scan(temp, best)).raw_count > 128) return error.ResourceLimit;
    return a.dupe(u8, best);
}

test {
    _ = parser;
    _ = bytecode;
}
test "standalone compiler exact arithmetic, lazy control, and strict locals" {
    const a = std.testing.allocator;
    const sources = [_][]const u8{ "$arg0 + 1", "$require($arg0 <= 1e18)", "IF($arg0 > 0, $arg1, 3)", "{let x = $read(10, 1), x + x}", "let x = $read(10, 1) in x + x", "$floor($arg0 * $arg1 / $arg2)" };
    for (sources) |source| {
        const bytes = try compile(a, source, .{});
        defer a.free(bytes);
        try std.testing.expect(bytes.len > 0 and bytes[bytes.len - 1] == 0xff);
    }
    const bytes = try compile(a, "$arg0 + 1", .{});
    defer a.free(bytes);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 0x23, 1, 1, 0x10, 0xff }, bytes);
}
