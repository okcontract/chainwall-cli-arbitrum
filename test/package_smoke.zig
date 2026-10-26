//! Exercise Zig's real package filtering, rather than building the checkout.
const std = @import("std");
fn run(a: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: ?[]const u8, env: ?*const std.process.Environ.Map) ![]const u8 {
    const result = try std.process.run(a, io, .{ .argv = argv, .cwd = if (cwd) |path| .{ .path = path } else .inherit, .environ_map = env, .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(600) } } });
    if (result.term != .exited or result.term.exited != 0) {
        try std.Io.File.stderr().writeStreamingAll(io, result.stderr);
        return error.SourcePackageCommandFailed;
    }
    return result.stdout;
}
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 3) return error.InvalidArguments;
    const zig = args[1];
    const source = try std.Io.Dir.cwd().realPathFileAlloc(io, args[2], a);
    // Fetch copies the directory before filtering manifest paths. Its cache
    // must be outside the source, even when CI caches Zig inside the checkout.
    const temp = try std.Io.Dir.cwd().realPathFileAlloc(io, init.environ_map.get("TMPDIR") orelse "/tmp", a);
    if (std.mem.eql(u8, temp, source) or (std.mem.startsWith(u8, temp, source) and temp[source.len] == '/')) return error.TemporaryDirectoryInsideSource;
    var random: [12]u8 = undefined;
    try io.randomSecure(&random);
    const root = try a.print("{s}/chainwall-package-{s}", .{ temp, std.fmt.bytesToHex(random, .lower) });
    try std.Io.Dir.cwd().createDir(io, root, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const fetch_cache = try a.print("{s}/fetch-cache", .{root});
    var fetch_env = try init.environ_map.clone(a);
    defer fetch_env.deinit();
    try fetch_env.put("ZIG_GLOBAL_CACHE_DIR", fetch_cache);
    const hash = std.mem.trim(u8, try run(a, io, &.{ zig, "fetch", source }, null, &fetch_env), "\r\n ");
    if (hash.len == 0) return error.MissingPackageHash;
    for (hash) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_' and ch != '.') return error.InvalidPackageHash;
    const archive = try std.Io.Dir.cwd().openFile(io, try a.print("{s}/p/{s}.tar.gz", .{ fetch_cache, hash }), .{});
    defer archive.close(io);
    const extracted_path = try a.print("{s}/source", .{root});
    var extracted = try std.Io.Dir.cwd().createDirPathOpen(io, extracted_path, .{});
    defer extracted.close(io);
    var compressed_buffer: [8192]u8 = undefined;
    var compressed = archive.readerStreaming(io, &compressed_buffer);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var gzip = std.compress.flate.Decompress.init(&compressed.interface, .gzip, &window);
    try std.tar.extract(io, extracted, &gzip.reader, .{ .strip_components = 1 });
    for ([_][]const u8{ "plugin/chainwall.lua", "ftplugin/lambdascript.vim", "syntax/lambdascript.vim" }) |path| {
        const bytes = extracted.readFileAlloc(io, try a.print("editors/neovim/{s}", .{path}), a, .limited(65536)) catch return error.MissingPackageEditorAssets;
        if (bytes.len == 0) return error.EmptyPackageEditorAsset;
    }
    // The build can still reuse the caller's compiler and dependency caches.
    _ = try run(a, io, &.{ zig, "build", "smoke", "--cache-dir", try a.print("{s}/.zig-cache", .{source}), "--prefix", try a.print("{s}/installed", .{root}) }, extracted_path, null);
    try std.Io.File.stdout().writeStreamingAll(io, "Fetched source package includes editor assets and passes default installation smoke checks.\n");
}
