const std = @import("std");
const ms = @import("miniscript");
pub const A = std.mem.Allocator;
pub const Value = std.json.Value;
pub const eq = std.mem.eql;
pub const field = ms.json.field;
pub const string = ms.json.string;
pub fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

pub fn parse(a: A, source: []const u8) !Value {
    return (try std.json.parseFromSlice(Value, a, source, .{ .allocate = .alloc_always, .parse_numbers = false })).value;
}
pub fn encode(a: A, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, value, .{ .whitespace = .indent_2, .emit_null_optional_fields = false });
}
pub fn scalar(a: A, value: Value) ![]const u8 {
    return switch (value) {
        .string, .number_string => |s| s,
        .integer => |v| a.print("{d}", .{v}),
        .bool => |v| if (v) "true" else "false",
        else => error.ExpectedScalar,
    };
}
pub fn number(a: A, value: Value) !u256 {
    return word(try scalar(a, value));
}
pub fn word(value: []const u8) !u256 {
    if (std.mem.startsWith(u8, value, "0x")) return std.fmt.parseInt(u256, value[2..], 16);
    return std.fmt.parseInt(u256, value, 10);
}
pub fn hex(a: A, value: u256) ![]const u8 {
    return a.print("0x{x:0>64}", .{value});
}
pub fn id(a: A, value: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, value, "0x")) {
        if (value.len != 66 or try word(value) == 0) return error.InvalidId;
        return hex(a, try word(value));
    }
    if (value.len == 0) return error.InvalidId;
    return hex(a, ms.bytecode.hash(value));
}
/// Public deployment/action salts only. Never use phrases for secret commitments.
pub fn salt(a: A, value: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, value, "0x")) {
        if (value.len != 66) return error.InvalidSalt;
        for (value[2..]) |ch| if (!std.ascii.isHex(ch)) return error.InvalidSalt;
        return value;
    }
    if (trim(value).len == 0) return error.InvalidSalt;
    return hex(a, ms.bytecode.hash(value));
}
pub fn address(value: []const u8) !void {
    if (value.len != 42 or !std.mem.startsWith(u8, value, "0x") or try word(value) == 0) return error.InvalidAddress;
}
pub fn read(a: A, io: std.Io, path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(32 * 1024 * 1024));
}
pub fn write(io: std.Io, path: []const u8, bytes: []const u8, replace: bool) !void {
    const permissions: std.Io.File.Permissions = if (@import("builtin").target.os.tag == .windows) .default_file else .fromMode(0o600);
    var file = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .make_path = true, .replace = replace, .permissions = permissions });
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, bytes);
    if (replace) try file.replace(io) else try file.link(io);
}
pub fn print(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &buf);
    try out.interface.print(fmt, args);
    try out.interface.flush();
}
pub fn kebab(a: A, name: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (name, 0..) |ch, i| {
        if (std.ascii.isUpper(ch) and i > 0 and std.ascii.isLower(name[i - 1])) try out.append(a, '-');
        try out.append(a, if (ch == '_') '-' else std.ascii.toLower(ch));
    }
    return out.toOwnedSlice(a);
}
