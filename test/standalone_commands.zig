const std = @import("std");
test "standalone command validation and help never wait for stdin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const cases = [_]struct { args: []const []const u8, code: u8, expected: []const u8 }{
        .{ .args = &.{"unknown-command"}, .code = 1, .expected = "UnknownCommand" },
        .{ .args = &.{ "unknown-command", "/does/not/exist" }, .code = 1, .expected = "UnknownCommand" },
        .{ .args = &.{ "compile", "one", "two" }, .code = 1, .expected = "InvalidArguments" },
        .{ .args = &.{"--help"}, .code = 0, .expected = "Usage:" },
        .{ .args = &.{"-h"}, .code = 0, .expected = "Usage:" },
        .{ .args = &.{ "compile", "--help" }, .code = 0, .expected = "Usage:" },
        .{ .args = &.{"--version"}, .code = 0, .expected = "miniscript 0.3.1" },
        .{ .args = &.{"-V"}, .code = 0, .expected = "miniscript 0.3.1" },
    };
    for (cases) |case| {
        var child = try std.process.spawn(io, .{
            .argv = try std.mem.concat(a, []const u8, &.{ &.{@import("executables").miniscript}, case.args }),
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        });
        defer child.kill(io);
        // Keep stdin open and empty. Reading it would hang until this deadline.
        var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
        var reader: std.Io.File.MultiReader = undefined;
        reader.init(a, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
        defer reader.deinit();
        while (reader.fill(4096, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(3) } })) |_| {} else |err| if (err != error.EndOfStream) return err;
        try reader.checkAnyError();
        try std.testing.expectEqual(std.process.Child.Term{ .exited = case.code }, try child.wait(io));
        const output = reader.reader(if (case.code == 0) 0 else 1).buffered();
        try std.testing.expect(std.mem.indexOf(u8, output, case.expected) != null);
        if (case.code != 0) try std.testing.expect(std.mem.indexOf(u8, output, "Usage:") != null);
    }
}
