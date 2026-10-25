const std = @import("std");
const ms = @import("miniscript");
const json = ms.json;
const help =
    "Usage: miniscript <compile|decompile|disasm|assemble|json> [file|-]\n" ++
    "compile: Lambdascript source -> bytecode hex\n" ++
    "decompile: bytecode hex -> Lambdascript source\n" ++
    "disasm: bytecode hex -> lossless instruction listing\n" ++
    "assemble: instruction listing -> bytecode hex\n" ++
    "json: request object or array, with action, source/bytecode, settings\n";
fn request(a: std.mem.Allocator, input: std.json.Value) !std.json.Value {
    if (input == .array) {
        var result = std.json.Array.init(a);
        for (input.array.items) |item| try result.append(try request(a, item));
        return .{ .array = result };
    }
    const action = if (json.field(input, "action")) |v| try json.string(v) else "compile";
    var object: std.json.ObjectMap = .empty;
    if (json.field(input, "id")) |id| try object.put(a, "id", id);
    const settings = json.settings(json.field(input, "settings")) catch |err| {
        try object.put(a, "error", .{ .string = @errorName(err) });
        return .{ .object = object };
    };
    const output = execute(a, action, input, settings) catch |err| {
        try object.put(a, "error", .{ .string = @errorName(err) });
        return .{ .object = object };
    };
    try object.put(a, if (std.mem.eql(u8, action, "disasm")) "assembly" else if (std.mem.eql(u8, action, "syntax")) "program" else if (std.mem.eql(u8, action, "decompile")) "source" else "bytecode", .{ .string = output });
    return .{ .object = object };
}
fn execute(a: std.mem.Allocator, action: []const u8, input: std.json.Value, settings: ms.Settings) ![]const u8 {
    if (std.mem.eql(u8, action, "syntax")) return ms.leanProgram(a, try json.string(json.field(input, "source") orelse return error.InvalidArguments), settings);
    if (std.mem.eql(u8, action, "compile")) {
        const source = try json.string(json.field(input, "source") orelse return error.InvalidArguments);
        return ms.bytecode.hex(a, try ms.compile(a, source, settings));
    }
    if (std.mem.eql(u8, action, "decompile")) return ms.decompile(a, try ms.bytecode.unhex(a, try json.string(json.field(input, "bytecode") orelse return error.InvalidArguments)), settings);
    if (std.mem.eql(u8, action, "disasm")) {
        const hex = try json.string(json.field(input, "bytecode") orelse return error.InvalidArguments);
        return ms.disasm(a, try ms.bytecode.unhex(a, hex));
    }
    if (std.mem.eql(u8, action, "assemble")) return ms.bytecode.hex(a, try ms.assemble(a, try json.string(json.field(input, "source") orelse return error.InvalidArguments)));
    return error.InvalidArguments;
}
pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var args = try init.minimal.args.iterateAllocator(a);
    defer args.deinit();
    _ = args.next();
    const action = args.next() orelse {
        try std.Io.File.stdout().writeStreamingAll(init.io, help);
        return;
    };
    if (std.mem.eql(u8, action, "--help")) return std.Io.File.stdout().writeStreamingAll(init.io, help);
    const path = args.next();
    if (args.next() != null) return error.InvalidArguments;
    const input = if (path != null and !std.mem.eql(u8, path.?, "-")) try std.Io.Dir.cwd().readFileAlloc(init.io, path.?, a, .limited(64 * 1024 * 1024)) else blk: {
        var buffer: [4096]u8 = undefined;
        var reader = std.Io.File.stdin().readerStreaming(init.io, &buffer);
        break :blk try reader.interface.allocRemaining(a, .limited(64 * 1024 * 1024));
    };
    const output = if (std.mem.eql(u8, action, "json")) blk: {
        const parsed = try std.json.parseFromSlice(std.json.Value, a, input, .{ .allocate = .alloc_always });
        break :blk try std.json.Stringify.valueAlloc(a, try request(a, parsed.value), .{});
    } else if (std.mem.eql(u8, action, "compile")) try ms.bytecode.hex(a, try ms.compile(a, input, .{})) else if (std.mem.eql(u8, action, "decompile")) try ms.decompile(a, try ms.bytecode.unhex(a, std.mem.trim(u8, input, " \t\r\n")), .{}) else if (std.mem.eql(u8, action, "disasm")) try ms.disasm(a, try ms.bytecode.unhex(a, std.mem.trim(u8, input, " \t\r\n"))) else if (std.mem.eql(u8, action, "assemble")) try ms.bytecode.hex(a, try ms.assemble(a, input)) else return error.InvalidArguments;
    try std.Io.File.stdout().writeStreamingAll(init.io, output);
    try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
}
