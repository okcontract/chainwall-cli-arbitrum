//! Zig assertions against a real headless editor and language server.
const std = @import("std");
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 4) return error.InvalidArguments;
    var random: [12]u8 = undefined;
    try io.randomSecure(&random);
    const dir = try a.print(".zig-cache/editor-{s}", .{std.fmt.bytesToHex(random, .lower)});
    try std.Io.Dir.cwd().createDirPath(io, dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, dir, a);
    try write(io, a, root, "chainwall-lsp.json", "{}");
    try write(io, a, root, "example.ls", "let amount = 1 in amount\n");
    try write(io, a, root, "exercise.lua",
        \\vim.opt.runtimepath:prepend(vim.env.CHAINWALL_EDITOR_ROOT)
        \\vim.g.chainwall_lsp_cmd = { vim.env.CHAINWALL_EDITOR_BINARY, '--stdio', '--config-dir', vim.env.CHAINWALL_EDITOR_DIR }
        \\vim.cmd('filetype plugin on')
        \\vim.cmd('syntax on')
        \\vim.cmd('runtime plugin/chainwall.lua')
        \\vim.cmd('edit ' .. vim.fn.fnameescape(vim.env.CHAINWALL_EDITOR_DIR .. '/example.ls'))
        \\local attached = vim.wait(5000, function()
        \\  local c = vim.lsp.get_clients({bufnr=0, name='chainwall'})[1]
        \\  return c ~= nil and c.initialized
        \\end, 20)
        \\local client = vim.lsp.get_clients({bufnr=0, name='chainwall'})[1]
        \\local result = {attached=attached, filetype=vim.bo.filetype, syntax=vim.fn.synIDattr(vim.fn.synID(1,1,1), 'name'), version=vim.version()}
        \\if client then
        \\  local params = {textDocument={uri=vim.uri_from_bufnr(0)}, position={line=0,character=5}}
        \\  result.hover = client:request_sync('textDocument/hover', params, 5000, 0)
        \\  result.diagnostics = client:request_sync('textDocument/diagnostic', {textDocument=params.textDocument}, 5000, 0)
        \\  client:stop()
        \\end
        \\vim.fn.writefile({vim.json.encode(result)}, vim.env.CHAINWALL_EDITOR_DIR .. '/result.json')
        \\vim.cmd('qa!')
    );
    var env = std.process.Environ.Map.init(a);
    try env.put("HOME", root);
    try env.put("XDG_CONFIG_HOME", root);
    try env.put("XDG_DATA_HOME", root);
    try env.put("XDG_STATE_HOME", root);
    try env.put("XDG_CACHE_HOME", root);
    try env.put("CHAINWALL_EDITOR_ROOT", try std.Io.Dir.cwd().realPathFileAlloc(io, args[3], a));
    try env.put("CHAINWALL_EDITOR_BINARY", try std.Io.Dir.cwd().realPathFileAlloc(io, args[2], a));
    try env.put("CHAINWALL_EDITOR_DIR", root);
    const result = try std.process.run(a, io, .{ .argv = &.{ args[1], "--headless", "--noplugin", "-u", "NONE", "-i", "NONE", "-l", try a.print("{s}/exercise.lua", .{root}) }, .environ_map = &env, .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(20) } } });
    if (result.term != .exited or result.term.exited != 0) {
        try std.Io.File.stderr().writeStreamingAll(io, result.stderr);
        return error.EditorFailed;
    }
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, try a.print("{s}/result.json", .{root}), a, .limited(65536));
    const report = (try std.json.parseFromSlice(std.json.Value, a, bytes, .{})).value.object;
    if (!report.get("attached").?.bool) return error.LspDidNotAttach;
    if (!std.mem.eql(u8, report.get("filetype").?.string, "lambdascript")) return error.WrongFileAssociation;
    if (!std.mem.eql(u8, report.get("syntax").?.string, "chainwallKeyword")) return error.SyntaxHighlightMissing;
    if (report.get("hover").?.object.get("result").? == .null) return error.HoverFailed;
    if (report.get("diagnostics").?.object.get("result").?.object.get("items").?.array.items.len != 0) return error.UnexpectedDiagnostics;
    try std.Io.File.stdout().writeStreamingAll(io, "Neovim attachment, syntax, hover and diagnostics passed.\n");
}
fn write(io: std.Io, a: std.mem.Allocator, dir: []const u8, name: []const u8, bytes: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, try a.print("{s}/{s}", .{ dir, name }), .{});
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}
