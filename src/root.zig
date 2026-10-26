//! Allocation contracts are listed in COMPILER.md. High-level compile,
//! decompile, disasm, assemble and leanProgram return independently owned slices.
//! Lower-level syntax/IR/ABI APIs generally require a caller-owned arena.
const std = @import("std");
pub const parser = @import("parser.zig");
pub const syntax = @import("syntax.zig");
pub const tree = @import("tree.zig");
pub const limits = @import("limits.zig");
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
pub const Diagnostic = tree.Diagnostic;
pub const json = @import("json.zig");
pub const leanProgram = @import("lean.zig").program;
pub const decompile = @import("decompile.zig").decompile;
pub const disasm = @import("assembly.zig").disasm;
pub const assemble = @import("assembly.zig").assemble;

fn emit(a: std.mem.Allocator, root: *tree.Node, diagnostic: *Diagnostic) Error![]u8 {
    errdefer diagnostic.locate(root.span);
    var generator: codegen.Generator = .{ .builder = .{ .a = a }, .diagnostic = diagnostic };
    try validate.semanticDetailed(root, diagnostic);
    const items = try generator.run(root);
    const original = try bytecode.encode(a, items);
    const result = try bytecode.encode(a, try optimize.machine(a, items));
    if (!references.same(try references.scan(a, original), try references.scan(a, result))) return error.InvalidBytecode;
    return result;
}

/// The returned bytes belong to the caller. All intermediate allocations are
/// scoped to this compilation and released even on invalid input.
pub fn compile(a: std.mem.Allocator, source: []const u8, settings: Settings) Error![]u8 {
    var diagnostic: Diagnostic = .{};
    return compileDetailed(a, source, settings, &diagnostic);
}

/// Same ownership as compile. On failure, diagnostic contains static strings
/// and source offsets which remain valid after intermediate arenas are freed.
pub fn compileDetailed(a: std.mem.Allocator, source: []const u8, settings: Settings, diagnostic: *Diagnostic) Error![]u8 {
    diagnostic.* = .{};
    return compileInner(a, source, settings, diagnostic) catch |err| {
        diagnostic.record(.{ .end = source.len }, err);
        return err;
    };
}
fn compileInner(a: std.mem.Allocator, source: []const u8, settings: Settings, diagnostic: *Diagnostic) Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    var f: tree.Factory = .{ .a = temp, .diagnostic = diagnostic };
    var p: parser.Parser = .{ .f = &f, .source = source };
    const program = p.parse() catch |err| {
        diagnostic.record(.{ .start = p.token.start, .end = @min(source.len, p.token.start + p.token.text.len) }, err);
        return err;
    };
    diagnostic.phase = .settings;
    const normalized_settings = try json.normalize(temp, settings);
    diagnostic.phase = .lower;
    var l: lower.Lowerer = .{ .f = &f, .settings = normalized_settings };
    const lowered = try l.run(program);
    diagnostic.phase = .validate;
    try validate.semanticDetailed(lowered, diagnostic);
    diagnostic.phase = .normalize;
    var normalizer: normalize.Normalizer = .{ .f = &f };
    const normalized = try normalizer.run(lowered);
    try validate.boundedDepth(normalized, 0);
    const root = try lower.dependencies(&f, try normalize.schedule(&f, normalized, false));
    diagnostic.phase = .generate;
    var best = try emit(temp, root, diagnostic);
    const contract = try references.scan(temp, best);
    if (settings.optimization == .size) {
        diagnostic.phase = .optimize;
        for ([_]struct { max: usize, last: bool }{ .{ .max = 2, .last = true }, .{ .max = 1, .last = false }, .{ .max = 1, .last = true } }) |variant| {
            if (try optimize.constants(&f, root, variant.max, variant.last)) |candidate| {
                const bytes = emit(temp, candidate, diagnostic) catch |err| {
                    if (err == error.StackCapacity) {
                        diagnostic.* = .{ .phase = .optimize };
                        continue;
                    }
                    return err;
                };
                if (!references.same(contract, try references.scan(temp, bytes))) return error.InvalidBytecode;
                if (bytes.len < best.len) best = bytes;
            }
        }
    }
    if ((try references.scan(temp, best)).raw_count > limits.static_references) return error.ResourceLimit;
    const result = try a.dupe(u8, best);
    diagnostic.* = .{};
    return result;
}

test "detailed compilation reports phases, exact spans and related bindings" {
    const a = std.testing.allocator;
    const cases = [_]struct { source: []const u8, err: Error, text: []const u8, phase: @FieldType(Diagnostic, "phase"), related: bool = false }{
        .{ .source = "1 + missing", .err = error.UnboundVariable, .text = "missing", .phase = .lower },
        .{ .source = "let x = 1 and x = 2 in x", .err = error.DuplicateBinding, .text = "x", .phase = .parse, .related = true },
        .{ .source = "let x = x in x", .err = error.CyclicDefinition, .text = "x", .phase = .lower, .related = true },
        .{ .source = "$staticLinked(-2)", .err = error.InvalidConstant, .text = "-2", .phase = .lower },
        .{ .source = "1 + $sqrt()", .err = error.InvalidArguments, .text = "$sqrt()", .phase = .lower },
    };
    for (cases) |case| {
        var diagnostic: Diagnostic = .{};
        try std.testing.expectError(case.err, compileDetailed(a, case.source, .{}, &diagnostic));
        try std.testing.expectEqualStrings(@errorName(case.err), diagnostic.code);
        try std.testing.expectEqualStrings(case.text, case.source[diagnostic.primary.?.start..diagnostic.primary.?.end]);
        try std.testing.expectEqual(case.phase, diagnostic.phase);
        try std.testing.expectEqual(case.related, diagnostic.related != null);
    }
}

test {
    _ = json;
    _ = parser;
    _ = bytecode;
    _ = abi;
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
