const std = @import("std");
const c = @import("common.zig");
const Args = @import("args.zig").Args;
const inputs = @import("json_inputs.zig");
const json = @import("json_schema.zig");

/// Editor commands are argv, not shell scripts. Quotes allow paths containing
/// spaces and options such as `code --wait`; expansions are deliberately absent.
pub fn arguments(a: c.A, command: []const u8) ![]const []const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    var token: std.ArrayList(u8) = .empty;
    var quote: u8 = 0;
    var escape = false;
    var started = false;
    for (command) |ch| {
        if (ch == 0 or ch == '\n' or ch == '\r') return error.InvalidEditor;
        if (escape) {
            try token.append(a, ch);
            escape = false;
            started = true;
            continue;
        }
        if (ch == '\\' and quote != '\'') {
            escape = true;
            started = true;
            continue;
        }
        if (quote != 0) {
            if (ch == quote) quote = 0 else try token.append(a, ch);
        } else if (ch == '\'' or ch == '"') {
            quote = ch;
            started = true;
        } else if (ch == ' ' or ch == '\t') {
            if (started) {
                try result.append(a, try token.toOwnedSlice(a));
                started = false;
            }
        } else {
            try token.append(a, ch);
            started = true;
        }
    }
    if (escape or quote != 0) return error.InvalidEditor;
    if (started) try result.append(a, try token.toOwnedSlice(a));
    if (result.items.len == 0 or result.items[0].len == 0) return error.InvalidEditor;
    return result.toOwnedSlice(a);
}

pub const Draft = struct {
    a: c.A,
    io: std.Io,
    directory: []const u8,
    path: []const u8,
    durable: bool,
    pub fn finish(d: Draft, success: bool) void {
        if (success and !d.durable) {
            std.Io.Dir.cwd().deleteTree(d.io, d.directory) catch {
                d.retained();
            };
        } else d.retained();
    }
    fn retained(d: Draft) void {
        const message = d.a.print("Input draft retained: {s}\n", .{d.path}) catch return;
        std.Io.File.stderr().writeStreamingAll(d.io, message) catch {};
    }
};

pub fn edit(v: *json.Validator, io: std.Io, env: *const std.process.Environ.Map, config_dir: []const u8, command: []const u8, args: *Args, selected: inputs.Binding) !Draft {
    const a = v.a;
    const editor_args = try arguments(a, command);
    if (selected.position) |index| if (args.positional.len < index) return error.InteractiveCommandArgumentsRequired;
    if (selected.option) |key| {
        if (c.eq(u8, key, "args-file") and args.positional.len > 2) return error.ConflictingArguments;
        if (c.eq(u8, key, "abi")) {
            var count: usize = 0;
            for (args.options) |item| if (c.eq(u8, item.key, key)) {
                count += 1;
            };
            if (count != 1) return error.InteractiveAbiTargetRequired;
        }
    }
    if (selected.mixed and selected.path != null and std.mem.endsWith(u8, selected.path.?, ".ls")) return error.InteractiveJsonRequired;
    var existing = false;
    const bytes = if (selected.path) |path| blk: {
        const source = c.read(a, io, path) catch |err| {
            if (err != error.FileNotFound) return err;
            break :blk try c.encode(a, try inputs.template(v.*, selected.rule, 0));
        };
        existing = true;
        break :blk source;
    } else try c.encode(a, try inputs.template(v.*, selected.rule, 0));
    defer std.crypto.secureZero(u8, @constCast(bytes));
    const folder = try a.print("{s}/interactive", .{config_dir});
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, folder, .fromMode(0o700));
    var random: [16]u8 = undefined;
    try io.randomSecure(&random);
    const directory = try a.print("{s}/{s}", .{ folder, std.fmt.bytesToHex(random, .lower) });
    try std.Io.Dir.cwd().createDir(io, directory, .fromMode(0o700));
    const absolute = try std.Io.Dir.cwd().realPathFileAlloc(io, directory, a);
    const path = try a.print("{s}/input.json", .{absolute});
    const draft: Draft = .{ .a = a, .io = io, .directory = absolute, .path = path, .durable = selected.durable };
    errdefer draft.finish(false);
    try c.write(io, path, bytes, false);
    try c.write(io, try a.print("{s}/schema.json", .{absolute}), try c.encode(a, try v.document(selected.rule)), false);
    const argv = try std.mem.concat(a, []const u8, &.{ editor_args, &.{path} });
    try std.Io.File.stderr().writeStreamingAll(io, try a.print("Editing {s}. Save and quit to validate and continue; exit the editor with an error to cancel.\n", .{selected.name}));
    var child = std.process.spawn(io, .{ .argv = argv, .environ_map = env, .expand_arg0 = .expand, .stdin = .inherit, .stdout = .inherit, .stderr = .inherit }) catch |err| {
        if (err == error.FileNotFound) return error.EditorNotFound;
        return err;
    };
    defer child.kill(io);
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) return error.EditorCancelled;
    // Editors often replace files atomically. Reopen without following links,
    // require an ordinary file, and restore private permissions after the save.
    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .follow_symlinks = false });
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.nlink != 1) return error.InvalidEditorFile;
    try file.setPermissions(io, .fromMode(0o600));
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const edited = try reader.interface.allocRemaining(a, .limited(32 * 1024 * 1024));
    defer std.crypto.secureZero(u8, edited);
    if (!existing and c.eq(u8, c.trim(bytes), c.trim(edited))) return error.EditorTemplateUnchanged;
    if (c.trim(edited).len == 0) return error.EditorCancelled;
    const value = c.parse(a, edited) catch return error.InvalidJsonInput;
    try v.require(io, selected.rule, value, selected.name);
    // The command consumes the validated snapshot, never an editor-owned file
    // that could still be changed by a background process.
    const snapshot = try a.print("{s}/validated.json", .{absolute});
    try c.write(io, snapshot, try c.encode(a, value), false);
    if (selected.position) |index| {
        const p = try a.alloc([]const u8, if (selected.insert) args.positional.len + 1 else @max(args.positional.len, index + 1));
        if (selected.insert) {
            @memcpy(p[0..index], args.positional[0..index]);
            @memcpy(p[index + 1 ..], args.positional[index..]);
        } else @memcpy(p[0..args.positional.len], args.positional);
        p[index] = snapshot;
        args.positional = p;
    } else {
        const key = selected.option.?;
        for (args.options) |*item| if (c.eq(u8, item.key, key)) {
            item.value = if (c.eq(u8, key, "abi")) try a.print("{s}={s}", .{ item.value[0..std.mem.indexOfScalar(u8, item.value, '=').?], snapshot }) else snapshot;
            return .{ .a = a, .io = io, .directory = absolute, .path = if (selected.durable) snapshot else path, .durable = selected.durable };
        };
        const options = try a.alloc(@import("args.zig").Option, args.options.len + 1);
        @memcpy(options[0..args.options.len], args.options);
        options[args.options.len] = .{ .key = key, .value = snapshot };
        args.options = options;
    }
    return .{ .a = a, .io = io, .directory = absolute, .path = if (selected.durable) snapshot else path, .durable = selected.durable };
}

test "editor argv quoting never invokes a shell" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = try arguments(a, "'/Applications/My Editor' --wait \"a b\" '$(touch injected)' ");
    try std.testing.expectEqual(@as(usize, 4), argv.len);
    try std.testing.expectEqualStrings("/Applications/My Editor", argv[0]);
    try std.testing.expectEqualStrings("a b", argv[2]);
    try std.testing.expectEqualStrings("$(touch injected)", argv[3]);
    try std.testing.expectError(error.InvalidEditor, arguments(a, "'unfinished"));
    try std.testing.expectError(error.InvalidEditor, arguments(a, ""));
}
