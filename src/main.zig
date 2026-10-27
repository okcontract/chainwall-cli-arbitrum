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
    var object: std.json.ObjectMap = .empty;
    if (json.field(input, "id")) |id| try object.put(a, "id", id);
    const action = if (json.field(input, "action")) |v| json.string(v) catch |err| {
        try object.put(a, "error", .{ .string = @errorName(err) });
        return .{ .object = object };
    } else "compile";
    const settings = json.settings(json.field(input, "settings")) catch |err| {
        try object.put(a, "error", .{ .string = @errorName(err) });
        return .{ .object = object };
    };
    var diagnostic: ms.Diagnostic = .{};
    const output = execute(a, action, input, settings, &diagnostic) catch |err| {
        try object.put(a, "error", .{ .string = @errorName(err) });
        if (diagnostic.code.len > 0) try object.put(a, "diagnostic", (try std.json.parseFromSlice(std.json.Value, a, try std.json.Stringify.valueAlloc(a, diagnostic, .{}), .{})).value);
        return .{ .object = object };
    };
    try object.put(a, if (std.mem.eql(u8, action, "disasm")) "assembly" else if (std.mem.eql(u8, action, "syntax")) "program" else if (std.mem.eql(u8, action, "decompile")) "source" else "bytecode", .{ .string = output });
    return .{ .object = object };
}
fn execute(a: std.mem.Allocator, action: []const u8, input: std.json.Value, settings: ms.Settings, diagnostic: *ms.Diagnostic) ![]const u8 {
    if (std.mem.eql(u8, action, "syntax")) return ms.leanProgram(a, try json.string(json.field(input, "source") orelse return error.InvalidArguments), settings);
    if (std.mem.eql(u8, action, "compile")) {
        const source = try json.string(json.field(input, "source") orelse return error.InvalidArguments);
        return ms.bytecode.hex(a, try ms.compileDetailed(a, source, settings, diagnostic));
    }
    if (std.mem.eql(u8, action, "decompile")) return ms.decompile(a, try ms.bytecode.unhex(a, try json.string(json.field(input, "bytecode") orelse return error.InvalidArguments)), settings);
    if (std.mem.eql(u8, action, "disasm")) {
        const hex = try json.string(json.field(input, "bytecode") orelse return error.InvalidArguments);
        return ms.disasm(a, try ms.bytecode.unhex(a, hex));
    }
    if (std.mem.eql(u8, action, "assemble")) return ms.bytecode.hex(a, try ms.assemble(a, try json.string(json.field(input, "source") orelse return error.InvalidArguments)));
    return error.InvalidArguments;
}
pub fn main(init: std.process.Init) void {
    start(init) catch |err| {
        std.Io.File.stderr().writeStreamingAll(init.io, "miniscript: ") catch {};
        std.Io.File.stderr().writeStreamingAll(init.io, @errorName(err)) catch {};
        std.Io.File.stderr().writeStreamingAll(init.io, "\n" ++ help) catch {};
        std.process.exit(1);
    };
}
fn start(init: std.process.Init) !void {
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
    if (std.mem.eql(u8, action, "--help") or std.mem.eql(u8, action, "-h")) return std.Io.File.stdout().writeStreamingAll(init.io, help);
    if (std.mem.eql(u8, action, "--version") or std.mem.eql(u8, action, "-V")) return std.Io.File.stdout().writeStreamingAll(init.io, "miniscript 0.3.1\n");
    var known = false;
    for ([_][]const u8{ "compile", "decompile", "disasm", "assemble", "json" }) |command| if (std.mem.eql(u8, action, command)) {
        known = true;
    };
    if (!known) return error.UnknownCommand;
    const path = args.next();
    if (args.next() != null) return error.InvalidArguments;
    if (path) |value| if (std.mem.eql(u8, value, "--help") or std.mem.eql(u8, value, "-h")) return std.Io.File.stdout().writeStreamingAll(init.io, help);
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

test "JSON batches preserve neighboring results and IDs for malformed request fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "\"action\":0", "\"source\":0", "\"settings\":0", "\"settings\":{\"optimisation\":\"size\"}" }) |field| {
        const invalid = try std.json.parseFromSlice(std.json.Value, a, try a.print("{{\"id\":2,{s}}}", .{field}), .{});
        const valid = try std.json.parseFromSlice(std.json.Value, a, "{\"id\":1,\"source\":\"1\"}", .{});
        for (0..3) |position| {
            var input = std.json.Array.init(a);
            for (0..3) |i| try input.append(if (i == position) invalid.value else valid.value);
            const result = try request(a, .{ .array = input });
            try std.testing.expectEqual(@as(usize, 3), result.array.items.len);
            for (result.array.items, 0..) |item, i| {
                try std.testing.expectEqual(@as(i64, if (i == position) 2 else 1), json.field(item, "id").?.integer);
                try std.testing.expect(json.field(item, if (i == position) "error" else "bytecode") != null);
            }
        }
    }
}

test "compiler JSON failures include stable source diagnostics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input = (try std.json.parseFromSlice(std.json.Value, a, "{\"id\":7,\"source\":\"1 + missing\"}", .{})).value;
    const result = try request(a, input);
    const diagnostic = json.field(result, "diagnostic").?;
    try std.testing.expectEqualStrings("lower", try json.string(json.field(diagnostic, "phase").?));
    try std.testing.expectEqual(@as(i64, 4), json.field(json.field(diagnostic, "primary").?, "start").?.integer);
    try std.testing.expectEqualStrings("UnboundVariable", try json.string(json.field(diagnostic, "code").?));
}
