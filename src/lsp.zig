// Copyright (C) 2026 OKcontract Pte. Ltd.
const std = @import("std");
const c = @import("cli/common.zig");
const Server = @import("lsp/server.zig").Server;
const metadata = @import("lsp/metadata.zig");
const Args = @import("cli/args.zig").Args;
const help =
    "chainwall-lsp - Lambdascript language server (LSP 3.17 over stdio)\n\n" ++
    "Usage: chainwall-lsp [--stdio] [--profile NAME] [--config-dir DIR]\n" ++
    "                     [--chain CHAIN] [--instance ADDRESS] [--rpc-url URL]\n" ++
    "                     [--snapshot FILE] [--settings FILE] [--abi TARGET=FILE]\n\n" ++
    "Uses Chainwall profiles and cached SQLite data. Network refresh is explicit.\n" ++
    "The config directory is a startup setting (--config-dir or CHAINWALL_CONFIG_DIR).\n" ++
    "Each workspace can provide chainwall-lsp.json. See the installed LSP guide.\n";
pub fn main(init: std.process.Init) void {
    const code = start(init) catch |err| {
        std.Io.File.stderr().writeStreamingAll(init.io, @errorName(err)) catch {};
        std.Io.File.stderr().writeStreamingAll(init.io, "\n") catch {};
        std.process.exit(1);
    };
    if (code != 0) std.process.exit(code);
}
fn start(init: std.process.Init) !u8 {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var iterator = try init.minimal.args.iterateAllocator(a);
    defer iterator.deinit();
    _ = iterator.next();
    var argv: std.ArrayList([]const u8) = .empty;
    var stdio = false;
    while (iterator.next()) |arg| {
        if (c.eq(u8, arg, "--stdio")) {
            if (stdio) return error.DuplicateOption;
            stdio = true;
        } else try argv.append(a, arg);
    }
    var args = try Args.parse(a, argv.items);
    if (args.flag("help")) {
        try std.Io.File.stdout().writeStreamingAll(init.io, help);
        return 0;
    }
    if (args.flag("version")) {
        try std.Io.File.stdout().writeStreamingAll(init.io, "chainwall-lsp 0.3.1\n");
        return 0;
    }
    if (args.positional.len > 0) return error.InvalidArguments;
    var options: std.json.ObjectMap = .empty;
    const config_dir = args.get("config-dir");
    for ([_][]const u8{ "profile", "chain", "instance", "rpc-url", "snapshot", "settings" }, [_][]const u8{ "profile", "chain", "instance", "rpcUrl", "snapshot", "settings" }) |flag, key| if (args.get(flag)) |v| try options.put(a, key, .{ .string = v });
    var abis: std.json.ObjectMap = .empty;
    for (args.options) |*opt| if (c.eq(u8, opt.key, "abi")) {
        opt.used = true;
        const at = std.mem.indexOfScalar(u8, opt.value, '=') orelse return error.AbiRequiresTargetAndFile;
        const key = try c.id(a, opt.value[0..at]);
        if (abis.contains(key)) return error.DuplicateAbiTarget;
        try abis.put(a, key, .{ .string = opt.value[at + 1 ..] });
    };
    if (abis.count() > 0) try options.put(a, "abis", .{ .object = abis });
    try args.finish();
    const language = try c.parse(a, @embedFile("lsp/catalog.json"));
    const root = try std.Io.Dir.cwd().realPathFileAlloc(init.io, ".", a);
    const dir = try metadata.configDirectory(a, init.environ_map, root, config_dir);
    var server = Server.init(init.gpa, init.io, init.environ_map, root, dir, .{ .object = options }, language);
    defer server.deinit();
    return server.run();
}
test {
    _ = @import("lsp/server.zig");
    _ = @import("lsp/protocol.zig");
    _ = @import("lsp/text.zig");
    _ = @import("lsp/analysis.zig");
    _ = @import("lsp/metadata.zig");
    _ = @import("lsp/features.zig");
}
