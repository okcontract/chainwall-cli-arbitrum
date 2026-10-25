const std = @import("std");
const t = @import("tree.zig");
const parser = @import("parser.zig");
const json = @import("json.zig");
const Settings = @import("lower.zig").Settings;
const Error = t.Error;
// This bridge serializes parser nodes only. It never lowers, substitutes,
// schedules, or interprets expressions; Lean owns those operations.
const Exporter = struct {
    a: t.Allocator,
    out: std.Io.Writer.Allocating,
    fn write(e: *Exporter, s: []const u8) Error!void {
        e.out.writer.writeAll(s) catch return error.OutOfMemory;
    }
    fn text(e: *Exporter, s: []const u8) Error!void {
        try e.write(std.json.Stringify.valueAlloc(e.a, s, .{}) catch return error.OutOfMemory);
    }
    fn list(e: *Exporter, nodes: []const *t.Node) Error!void {
        try e.write("[");
        for (nodes, 0..) |n, i| {
            if (i > 0) try e.write(", ");
            try e.node(n);
        }
        try e.write("]");
    }
    fn tuple(e: *Exporter, nodes: []const *t.Node) Error!void {
        try e.write("(.tuple [");
        for (nodes, 0..) |n, i| {
            if (i > 0) try e.write(", ");
            if (n.tag == .declaration) {
                try e.write("(.let_ ");
                try e.text(if (n.spelling.len > 0) n.spelling else n.name);
                try e.write(" ");
                try e.node(n.children[0]);
                try e.write(" ");
                try e.tuple(nodes[i + 1 ..]);
                try e.write(")");
                break;
            }
            try e.node(n);
        }
        try e.write("])");
    }
    fn node(e: *Exporter, n: *t.Node) Error!void {
        switch (n.tag) {
            .number => e.out.writer.print("(.number {d} 1 {s})", .{ n.value, if (n.negative) "true" else "false" }) catch return error.OutOfMemory,
            .variable => {
                try e.write("(.variable ");
                try e.text(if (n.spelling.len > 0) n.spelling else n.name);
                try e.write(")");
            },
            .string => {
                try e.write("(.text ");
                try e.text(n.name);
                try e.write(")");
            },
            .application => {
                try e.write("(.apply (.variable ");
                try e.text(if (n.spelling.len > 0) n.spelling else n.name);
                try e.write(") ");
                try e.list(n.children);
                try e.write(")");
            },
            .tuple => try e.tuple(n.children),
            .object => try e.write("(.object [])"),
            .list => {
                try e.write("(.list ");
                try e.list(n.children);
                try e.write(")");
            },
            .index => {
                try e.write("(.field ");
                try e.node(n.children[0]);
                try e.write(" ");
                try e.node(n.children[1]);
                try e.write(")");
            },
            else => return error.Unsupported,
        }
    }
};
pub fn program(a: t.Allocator, source: []const u8, settings: Settings) Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    var f: t.Factory = .{ .a = temp };
    var p: parser.Parser = .{ .f = &f, .source = source };
    const parsed = try p.parse();
    var e: Exporter = .{ .a = temp, .out = .init(temp) };
    try e.write("{ definitions := [");
    for (parsed.bindings, 0..) |binding, i| {
        if (i > 0) try e.write(", ");
        try e.write("(");
        try e.text(if (binding.spelling.len > 0) binding.spelling else binding.name);
        try e.write(", ");
        try e.node(binding.value);
        try e.write(")");
    }
    try e.write("], body := ");
    try e.node(parsed.main);
    try e.write(", argumentContext := .");
    try e.write(@tagName(settings.argumentContext));
    try e.write(", abiFunctions := [");
    if (settings.abiFunctionsByCallKey) |methods| {
        if (methods != .object) return error.InvalidSettings;
        var iterator = methods.object.iterator();
        var i: usize = 0;
        while (iterator.next()) |entry| : (i += 1) {
            if (i > 0) try e.write(", ");
            try e.write("(");
            try e.text(entry.key_ptr.*);
            try e.write(", ");
            const method = entry.value_ptr.*;
            try e.text(try json.string(json.field(method, "stateMutability") orelse return error.InvalidSettings));
            try e.write(", [");
            const inputs = json.field(method, "inputs") orelse return error.InvalidSettings;
            if (inputs != .array) return error.InvalidSettings;
            for (inputs.array.items, 0..) |input, j| {
                if (j > 0) try e.write(", ");
                try e.text(try json.string(json.field(input, "type") orelse return error.InvalidSettings));
            }
            try e.write("])");
        }
    }
    try e.write("] }");
    return a.dupe(u8, e.out.written());
}
