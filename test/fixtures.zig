//! Deterministic corpus maintenance tool. A candidate is never automatically blessed.
const std = @import("std");
const ms = @import("miniscript");
const Generator = @import("generator.zig").Generator;
const Value = std.json.Value;
fn read(a: std.mem.Allocator, io: std.Io, path: []const u8) !Value {
    return (try std.json.parseFromSlice(Value, a, try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4 * 1024 * 1024)), .{})).value;
}
fn write(a: std.mem.Allocator, io: std.Io, path: []const u8, value: Value) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, try std.json.Stringify.valueAlloc(a, value, .{ .whitespace = .indent_2 }));
    try file.writeStreamingAll(io, "\n");
}
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const command = if (args.len > 1) args[1] else "check";
    if (std.mem.eql(u8, command, "extract")) {
        if (args.len != 4) return error.ExpectedSourceAndDestination;
        const source = try read(a, init.io, args[2]);
        for (source.array.items) |*item| _ = item.object.orderedRemove("bytecode");
        return write(a, init.io, args[3], source);
    }
    if (!std.mem.eql(u8, command, "check") and !std.mem.eql(u8, command, "generate")) return error.UnknownCommand;
    if (args.len > 3 or (std.mem.eql(u8, command, "generate") and args.len != 3)) return error.ExpectedOutputPath;
    const corpus = try read(a, init.io, "test/corpus.json");
    const expected = try read(a, init.io, "test/fixtures.json");
    if (corpus.array.items.len != expected.array.items.len) return error.CorpusCountMismatch;
    var generator: Generator = .{ .a = a, .state = 0x12345678 };
    var generated: [128][]const u8 = undefined;
    for (&generated, 0..) |*source, index| source.* = try generator.program(index);
    for (corpus.array.items, expected.array.items) |*item, golden| {
        const id = try ms.json.string(ms.json.field(item.*, "id").?);
        const source = try ms.json.string(ms.json.field(item.*, "source").?);
        if (std.mem.startsWith(u8, id, "generated/305419896/")) {
            var parts = std.mem.splitScalar(u8, id, '/');
            _ = parts.next();
            _ = parts.next();
            const index = try std.fmt.parseInt(usize, parts.next().?, 10);
            if (index >= generated.len or !std.mem.eql(u8, source, generated[index])) return error.GeneratorSourceMismatch;
        }
        const bytes = try ms.compile(a, source, try ms.json.settings(ms.json.field(item.*, "settings")));
        const hex = try ms.bytecode.hex(a, bytes);
        try item.object.put(a, "bytecode", .{ .string = hex });
        if (std.mem.eql(u8, command, "check")) {
            if (!std.mem.eql(u8, try std.json.Stringify.valueAlloc(a, item.*, .{}), try std.json.Stringify.valueAlloc(a, golden, .{}))) {
                try std.Io.File.stderr().writeStreamingAll(init.io, try a.print("Fixture differs: {s}\n", .{id}));
                return error.FixtureMismatch;
            }
        }
    }
    if (std.mem.eql(u8, command, "generate")) try write(a, init.io, args[2], corpus);
    try std.Io.File.stdout().writeStreamingAll(init.io, try a.print("Checked {d} fixtures; generator seed 0x12345678, 128 programs, two optimization modes.\n", .{corpus.array.items.len}));
}
