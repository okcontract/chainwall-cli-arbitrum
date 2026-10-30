const std = @import("std");
const c = @import("common.zig");
const schema = @import("schema.zig");
pub const Option = struct { key: []const u8, value: []const u8, used: bool = false };
pub const Args = struct {
    positional: []const []const u8,
    options: []Option,
    rejected: ?[]const u8 = null,
    pub fn parse(a: c.A, argv: []const []const u8) !Args {
        var positional: std.ArrayList([]const u8) = .empty;
        var options: std.ArrayList(Option) = .empty;
        var end = false;
        var i: usize = 0;
        while (i < argv.len) : (i += 1) {
            const arg = argv[i];
            if (!end and c.eq(u8, arg, "--")) {
                end = true;
                continue;
            }
            if (!end and (c.eq(u8, arg, "-h") or c.eq(u8, arg, "-V"))) {
                try options.append(a, .{ .key = if (arg[1] == 'h') "help" else "version", .value = "" });
            } else if (!end and std.mem.startsWith(u8, arg, "--")) {
                const equal = std.mem.indexOfScalar(u8, arg, '=');
                const key = arg[2..(equal orelse arg.len)];
                const spec = schema.option(key);
                const boolean = spec.argument == .none;
                const value = if (equal) |at| arg[at + 1 ..] else if (boolean) "" else blk: {
                    i += 1;
                    if (i >= argv.len or std.mem.startsWith(u8, argv[i], "--")) return error.OptionValueRequired;
                    break :blk argv[i];
                };
                if (boolean and value.len != 0) return error.FlagTakesNoValue;
                for (options.items) |option| if (c.eq(u8, option.key, key) and !spec.repeat) return error.DuplicateOption;
                try options.append(a, .{ .key = key, .value = value });
            } else try positional.append(a, arg);
        }
        return .{ .positional = positional.items, .options = options.items };
    }
    pub fn get(args: *Args, key: []const u8) ?[]const u8 {
        for (args.options) |*option| if (!option.used and c.eq(u8, option.key, key)) {
            option.used = true;
            return option.value;
        };
        return null;
    }
    pub fn flag(args: *Args, key: []const u8) bool {
        return args.get(key) != null;
    }
    pub fn reject(args: *Args, key: []const u8) error{UnknownOption} {
        args.rejected = key;
        return error.UnknownOption;
    }
    pub fn finish(args: *Args) !void {
        for (args.options) |option| if (!option.used) return args.reject(option.key);
    }
};

test "options work before and after commands without shell interpretation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var args = try Args.parse(arena.allocator(), &.{ "--profile", "work", "users", "add", "--chain=base", "$(not-a-shell)", "--dry-run" });
    try std.testing.expectEqualStrings("work", args.get("profile").?);
    try std.testing.expectEqualStrings("base", args.get("chain").?);
    try std.testing.expect(args.flag("dry-run"));
    try std.testing.expectEqualStrings("$(not-a-shell)", args.positional[2]);
    try args.finish();
}

test "unused options retain the rejected name for command diagnostics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var args = try Args.parse(arena.allocator(), &.{ "safes", "create", "--salt", "treasury", "--out", "safe.json" });
    _ = args.get("salt");
    try std.testing.expectError(error.UnknownOption, args.finish());
    try std.testing.expectEqualStrings("out", args.rejected.?);
}
