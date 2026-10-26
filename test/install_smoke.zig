//! Native installation smoke runner. Invoked after `zig build` has installed files.
const std = @import("std");
fn require(io: std.Io, a: std.mem.Allocator, prefix: []const u8, path: []const u8) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, try std.Io.Dir.path.join(a, &.{ prefix, path }), a, .limited(4 * 1024 * 1024));
    if (bytes.len == 0) return error.EmptyInstalledFile;
}
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 4) return error.InvalidArguments;
    const prefix = args[1];
    const cli = std.mem.eql(u8, args[2], "cli");
    const lsp = std.mem.eql(u8, args[3], "lsp");
    for ([_][]const u8{ "share/licenses/chainwall/LICENSE", "share/licenses/chainwall/THIRD_PARTY_NOTICES.md" }) |path| try require(init.io, a, prefix, path);
    if (cli or lsp) {
        for ([_][]const u8{ "README.md", "CLI.md", "MANUAL.md", "manual.md", "LSP.md", "COMPILER.md", "skills/chainwall-operations/SKILL.md", "skills/chainwall-operations/agents/openai.yaml" }) |path| try require(init.io, a, prefix, try a.print("share/doc/chainwall/{s}", .{path}));
        try require(init.io, a, prefix, "share/licenses/chainwall/zqlite.txt");
    }
    if (cli) {
        try require(init.io, a, prefix, "share/zsh/site-functions/_chainwall");
        try require(init.io, a, prefix, "share/fish/vendor_completions.d/chainwall.fish");
    }
    if (lsp) for ([_][]const u8{ "plugin/chainwall.lua", "ftplugin/lambdascript.vim", "syntax/lambdascript.vim" }) |path| try require(init.io, a, prefix, try a.print("share/chainwall/editors/neovim/{s}", .{path}));
    for ([_]struct { name: []const u8, enabled: bool }{ .{ .name = "chainwall", .enabled = cli }, .{ .name = "chainwall-lsp", .enabled = lsp } }) |item| {
        if (!item.enabled) continue;
        const output = try std.process.run(a, init.io, .{ .argv = &.{ try std.Io.Dir.path.join(a, &.{ prefix, "bin", item.name }), "--version" }, .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(10) } } });
        if (output.term != .exited or output.term.exited != 0 or std.mem.indexOf(u8, output.stdout, "0.3.0") == null) return error.VersionSmokeFailed;
    }
    // Compile through stdin using a real file, without depending on a shell.
    const source = try a.print("{s}/smoke-input.ls", .{prefix});
    const out = try std.Io.Dir.cwd().createFile(init.io, source, .{});
    try out.writeStreamingAll(init.io, "$arg0 + 1");
    out.close(init.io);
    defer std.Io.Dir.cwd().deleteFile(init.io, source) catch {};
    const input = try std.Io.Dir.cwd().openFile(init.io, source, .{});
    defer input.close(init.io);
    var child = try std.process.spawn(init.io, .{ .argv = &.{ try std.Io.Dir.path.join(a, &.{ prefix, "bin", "miniscript" }), "compile" }, .stdin = .{ .file = input }, .stdout = .pipe, .stderr = .inherit });
    defer child.kill(init.io);
    var buffer: [4096]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(init.io, &buffer);
    const output = try reader.interface.allocRemaining(a, .limited(65536));
    const term = try child.wait(init.io);
    if (term != .exited or term.exited != 0 or std.mem.indexOf(u8, output, "010023010110ff") == null) return error.CompilerSmokeFailed;
}
