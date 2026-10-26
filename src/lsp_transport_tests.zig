const std = @import("std");
const c = @import("cli/common.zig");
const protocol = @import("lsp/protocol.zig");
const binary = @import("executables").lsp;

fn message(a: c.A, out: *std.Io.Writer, value: anytype) !void {
    const body = try c.encode(a, value);
    try out.print("Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
}
fn exchange(a: c.A, dir: []const u8, input: []const u8, expected_exit: u8) ![]const c.Value {
    return exchangeIdle(a, dir, input, null, expected_exit);
}
fn exchangeIdle(a: c.A, dir: []const u8, input: []const u8, delayed: ?[]const u8, expected_exit: u8) ![]const c.Value {
    const io = std.testing.io;
    const input_path = try a.print("{s}/input.lsp", .{dir});
    try c.write(io, input_path, input, true);
    const file = try std.Io.Dir.cwd().openFile(io, input_path, .{});
    defer file.close(io);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const executable = try std.Io.Dir.cwd().realPathFileAlloc(io, binary, a);
    var child = try std.process.spawn(io, .{ .argv = &.{ executable, "--stdio", "--config-dir", dir }, .environ_map = &env, .cwd = .{ .path = dir }, .stdin = if (delayed != null) .pipe else .{ .file = file }, .stdout = .pipe, .stderr = .pipe });
    defer child.kill(io);
    if (delayed) |tail| {
        try child.stdin.?.writeStreamingAll(io, input);
        try std.Io.sleep(io, .fromMilliseconds(1500), .awake);
        try child.stdin.?.writeStreamingAll(io, tail);
        child.stdin.?.close(io);
        child.stdin = null;
    }
    var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var reader: std.Io.File.MultiReader = undefined;
    reader.init(a, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer reader.deinit();
    while (reader.fill(4096, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(10) } })) |_| {
        if (reader.reader(0).buffered().len > 4 * 1024 * 1024) return error.ExcessiveOutput;
    } else |err| if (err != error.EndOfStream) return err;
    try reader.checkAnyError();
    const term = try child.wait(io);
    if (term != .exited or term.exited != expected_exit) std.debug.print("LSP stderr: {s}\n", .{reader.reader(1).buffered()});
    try std.testing.expectEqual(std.process.Child.Term{ .exited = expected_exit }, term);
    var frames = std.Io.Reader.fixed(reader.reader(0).buffered());
    var messages: std.ArrayList(c.Value) = .empty;
    while (try protocol.read(a, &frames)) |body| try messages.append(a, try c.parse(a, body));
    return messages.items;
}
fn response(messages: []const c.Value, id: u64) !c.Value {
    var found: ?c.Value = null;
    for (messages) |value| if (c.field(value, "id")) |got| {
        if ((c.number(std.testing.allocator, got) catch continue) == id) {
            try std.testing.expect(found == null);
            found = value;
        }
    };
    return found orelse error.MissingResponse;
}
test "LSP executable handles capabilities, editing requests, diagnostics and cancellation frames" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    const uri = try a.print("file://{s}/example.ls", .{dir});
    const doc = .{ .uri = uri };
    var input: std.Io.Writer.Allocating = .init(a);
    try message(a, &input.writer, .{ .jsonrpc = "2.0", .id = 0, .method = "textDocument/hover", .params = .{} });
    try message(a, &input.writer, .{ .jsonrpc = "2.0", .id = 1, .method = "initialize", .params = .{ .capabilities = .{ .textDocument = .{ .completion = .{ .completionItem = .{ .snippetSupport = true } } } } } });
    try message(a, &input.writer, .{ .jsonrpc = "2.0", .method = "initialized", .params = .{} });
    const source = "let amount = 1 in $balance(amount, 2)";
    try message(a, &input.writer, .{ .jsonrpc = "2.0", .method = "textDocument/didOpen", .params = .{ .textDocument = .{ .uri = uri, .languageId = "lambdascript", .version = 1, .text = source } } });
    try message(a, &input.writer, .{ .jsonrpc = "2.0", .id = 2, .method = "textDocument/completion", .params = .{ .textDocument = doc, .position = .{ .line = 0, .character = 18 } } });
    try message(a, &input.writer, .{ .jsonrpc = "2.0", .id = 3, .method = "textDocument/signatureHelp", .params = .{ .textDocument = doc, .position = .{ .line = 0, .character = source.len - 1 } } });
    try message(a, &input.writer, .{ .jsonrpc = "2.0", .id = 4, .method = "textDocument/rename", .params = .{ .textDocument = doc, .position = .{ .line = 0, .character = 5 }, .newName = "quantity" } });
    try message(a, &input.writer, .{ .jsonrpc = "2.0", .method = "$/cancelRequest", .params = .{ .id = 4 } });
    try message(a, &input.writer, .{ .jsonrpc = "2.0", .method = "textDocument/didChange", .params = .{ .textDocument = .{ .uri = uri, .version = 2 }, .contentChanges = .{.{ .text = "let =" }} } });
    try message(a, &input.writer, .{ .jsonrpc = "2.0", .id = 5, .method = "textDocument/diagnostic", .params = .{ .textDocument = doc } });
    try message(a, &input.writer, .{ .jsonrpc = "2.0", .id = 6, .method = "shutdown", .params = .{} });
    try message(a, &input.writer, .{ .jsonrpc = "2.0", .method = "exit", .params = .{} });
    const messages = try exchange(a, dir, input.written(), 0);
    try std.testing.expectEqualStrings("-32002", try c.scalar(a, c.field(c.field(try response(messages, 0), "error").?, "code").?));
    const capabilities = c.field(c.field(try response(messages, 1), "result").?, "capabilities").?;
    try std.testing.expect(c.field(capabilities, "signatureHelpProvider") != null);
    try std.testing.expect(c.field(capabilities, "diagnosticProvider") != null);
    const completion = c.field(try response(messages, 2), "result").?;
    try std.testing.expect(c.field(completion, "items").?.array.items.len > 0);
    const signature = c.field(try response(messages, 3), "result").?;
    try std.testing.expectEqual(@as(u256, 1), try c.number(a, c.field(signature, "activeParameter").?));
    const edits = c.field(c.field(c.field(try response(messages, 4), "result").?, "changes").?, uri).?.array.items;
    try std.testing.expectEqual(@as(usize, 2), edits.len);
    for (edits) |edit| try std.testing.expectEqualStrings("quantity", try c.string(c.field(edit, "newText").?));
    const diagnostic = c.field(try response(messages, 5), "result").?;
    try std.testing.expect(c.field(diagnostic, "items").?.array.items.len > 0);
    var published: usize = 0;
    for (messages) |value| if (c.field(value, "method")) |method| {
        if (c.eq(u8, try c.string(method), "textDocument/publishDiagnostics")) published += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), published);
    try std.testing.expect(c.field(try response(messages, 6), "result").? == .null);
    // Seven requests and two notifications: cancel/initialized/exit receive no replies.
    try std.testing.expectEqual(@as(usize, 9), messages.len);
}

test "LSP exits unsuccessfully without shutdown and rejects truncated framing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    _ = try exchange(a, dir, "Content-Length: 20\r\n\r\n{}", 1);
    var input: std.Io.Writer.Allocating = .init(a);
    try message(a, &input.writer, .{ .jsonrpc = "2.0", .method = "exit" });
    _ = try exchange(a, dir, input.written(), 1);
}

test "edit bursts publish only the latest debounced diagnostics while stdin is idle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    const uri = try a.print("file://{s}/burst.ls", .{dir});
    var input: std.Io.Writer.Allocating = .init(a);
    try message(a, &input.writer, .{ .jsonrpc = "2.0", .id = 1, .method = "initialize", .params = .{ .capabilities = .{} } });
    try message(a, &input.writer, .{ .jsonrpc = "2.0", .method = "textDocument/didOpen", .params = .{ .textDocument = .{ .uri = uri, .version = 1, .text = "1" } } });
    for (2..5) |version| try message(a, &input.writer, .{ .jsonrpc = "2.0", .method = "textDocument/didChange", .params = .{ .textDocument = .{ .uri = uri, .version = version }, .contentChanges = .{.{ .text = if (version == 4) "2" else "let =" }} } });
    var tail: std.Io.Writer.Allocating = .init(a);
    try message(a, &tail.writer, .{ .jsonrpc = "2.0", .id = 2, .method = "shutdown" });
    try message(a, &tail.writer, .{ .jsonrpc = "2.0", .method = "exit" });
    const output = try exchangeIdle(a, dir, input.written(), tail.written(), 0);
    var published: usize = 0;
    for (output) |item| if (c.field(item, "method")) |method| {
        if (!c.eq(u8, try c.string(method), "textDocument/publishDiagnostics")) continue;
        const params = c.field(item, "params").?;
        const version = try c.number(a, c.field(params, "version").?);
        try std.testing.expect(version == 1 or version == 4);
        try std.testing.expectEqual(0, c.field(params, "diagnostics").?.array.items.len);
        published += 1;
    };
    try std.testing.expectEqual(2, published);
}

test "failed metadata refresh preserves debounced diagnostics for an idle push-only client" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    const uri = try a.print("file://{s}/failed-refresh.ls", .{dir});
    var input: std.Io.Writer.Allocating = .init(a);
    try message(a, &input.writer, .{ .jsonrpc = "2.0", .id = 1, .method = "initialize", .params = .{ .capabilities = .{} } });
    try message(a, &input.writer, .{ .jsonrpc = "2.0", .method = "textDocument/didOpen", .params = .{ .textDocument = .{ .uri = uri, .version = 1, .text = "1" } } });
    try message(a, &input.writer, .{ .jsonrpc = "2.0", .method = "textDocument/didChange", .params = .{ .textDocument = .{ .uri = uri, .version = 2 }, .contentChanges = .{.{ .text = "unknown_name" }} } });
    // No instance is configured, so refresh fails while diagnostics are queued.
    try message(a, &input.writer, .{ .jsonrpc = "2.0", .id = 2, .method = "workspace/executeCommand", .params = .{ .command = "chainwall.refresh", .arguments = .{uri} } });
    var tail: std.Io.Writer.Allocating = .init(a);
    try message(a, &tail.writer, .{ .jsonrpc = "2.0", .id = 3, .method = "shutdown" });
    try message(a, &tail.writer, .{ .jsonrpc = "2.0", .method = "exit" });
    const output = try exchangeIdle(a, dir, input.written(), tail.written(), 0);
    try std.testing.expectEqualStrings("-32001", try c.scalar(a, c.field(c.field(try response(output, 2), "error").?, "code").?));
    var published_latest = false;
    for (output) |item| if (c.field(item, "method")) |method| {
        if (!c.eq(u8, try c.string(method), "textDocument/publishDiagnostics")) continue;
        const params = c.field(item, "params").?;
        if (try c.number(a, c.field(params, "version").?) != 2) continue;
        for (c.field(params, "diagnostics").?.array.items) |diagnostic| {
            if (c.eq(u8, try c.string(c.field(diagnostic, "code").?), "UnboundVariable")) published_latest = true;
        }
    };
    try std.testing.expect(published_latest);
}

test "metadata refresh republishes push diagnostics without further editor input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mock = @import("cli/test_rpc.zig");
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash("Chainwall.Registry", &digest, .{});
    const identity = try a.print("0x{s}", .{std.fmt.bytesToHex(digest, .lower)});
    const zero = "0x0000000000000000000000000000000000000000000000000000000000000000";
    const block = "[{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"number\":\"0x1\",\"hash\":\"0x1111111111111111111111111111111111111111111111111111111111111111\",\"timestamp\":\"0x1\"}}]";
    var replies: std.ArrayList(mock.Reply) = .empty;
    try replies.append(a, .{ .body = "[{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\"0xa4b1\"}]" });
    try replies.append(a, .{ .body = block });
    try replies.append(a, .{ .body = "[{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\"0x6000\"}]" });
    try replies.append(a, .{ .body = try c.encode(a, .{.{ .jsonrpc = "2.0", .id = 1, .result = identity }}) });
    try replies.append(a, .{ .body = try c.encode(a, .{.{ .jsonrpc = "2.0", .id = 1, .result = zero }}) });
    for (0..8) |_| try replies.append(a, .{ .body = try c.encode(a, .{ .{ .jsonrpc = "2.0", .id = 1, .result = zero }, .{ .jsonrpc = "2.0", .id = 2, .result = zero } }) });
    try replies.append(a, .{ .body = block });
    for ([_]bool{ false, true }) |refresh_support| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
        var server = try mock.Server.init(std.testing.io, replies.items);
        defer server.deinit();
        var serving = try std.testing.io.concurrent(mock.Server.serve, .{&server});
        defer _ = serving.cancel(std.testing.io) catch {};
        const uri = try a.print("file://{s}/metadata.ls", .{dir});
        var input: std.Io.Writer.Allocating = .init(a);
        try message(a, &input.writer, .{ .jsonrpc = "2.0", .id = 1, .method = "initialize", .params = .{ .initializationOptions = .{ .chain = 42161, .instance = "0x1111111111111111111111111111111111111111", .rpcUrl = try server.url(a) }, .capabilities = .{ .workspace = .{ .diagnostics = .{ .refreshSupport = refresh_support } } } } });
        try message(a, &input.writer, .{ .jsonrpc = "2.0", .method = "textDocument/didOpen", .params = .{ .textDocument = .{ .uri = uri, .version = 1, .text = "@contract(example/missing)" } } });
        try message(a, &input.writer, .{ .jsonrpc = "2.0", .id = 2, .method = "workspace/executeCommand", .params = .{ .command = "chainwall.refresh", .arguments = .{uri} } });
        var tail: std.Io.Writer.Allocating = .init(a);
        try message(a, &tail.writer, .{ .jsonrpc = "2.0", .id = 3, .method = "textDocument/diagnostic", .params = .{ .textDocument = .{ .uri = uri } } });
        try message(a, &tail.writer, .{ .jsonrpc = "2.0", .id = 5, .method = "workspace/executeCommand", .params = .{ .command = "chainwall.status", .arguments = .{uri} } });
        try message(a, &tail.writer, .{ .jsonrpc = "2.0", .id = 4, .method = "shutdown" });
        try message(a, &tail.writer, .{ .jsonrpc = "2.0", .method = "exit" });
        const output = try exchangeIdle(a, dir, input.written(), tail.written(), 0);
        try std.testing.expect(c.field(try response(output, 2), "result") != null);
        var codes: std.ArrayList([]const u8) = .empty;
        for (output) |item| if (c.field(item, "method")) |method| {
            if (c.eq(u8, try c.string(method), "textDocument/publishDiagnostics")) {
                const diagnostics = c.field(c.field(item, "params").?, "diagnostics").?.array.items;
                try codes.append(a, try c.string(c.field(diagnostics[0], "code").?));
            }
        };
        try std.testing.expectEqual(2, codes.items.len);
        try std.testing.expectEqualStrings("CatalogNotSynced", codes.items[0]);
        try std.testing.expectEqualStrings("UnknownRegistryReference", codes.items[1]);
        const pulled = c.field(c.field(try response(output, 3), "result").?, "items").?.array.items;
        try std.testing.expectEqualStrings(codes.items[1], try c.string(c.field(pulled[0], "code").?));
        const status = c.field(try response(output, 5), "result").?;
        const users = c.field(c.field(status, "cacheByDataset").?, "users").?;
        try std.testing.expectEqualStrings("sqlite-cache", try c.string(c.field(users, "source").?));
        try std.testing.expectEqualStrings("complete", try c.string(c.field(c.field(users, "completeness").?, "snapshot").?));
        try std.testing.expect(!c.field(c.field(users, "freshness").?, "headChecked").?.bool);
        try std.testing.expect(c.field(users, "statusBlock").? == .null);
        try serving.await(std.testing.io);
    }
}

test "formatting protocol honors tabs and CR-only document ranges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    const uri = try a.print("file://{s}/format.ls", .{dir});
    var input: std.Io.Writer.Allocating = .init(a);
    try message(a, &input.writer, .{ .jsonrpc = "2.0", .id = 1, .method = "initialize", .params = .{ .capabilities = .{} } });
    try message(a, &input.writer, .{ .jsonrpc = "2.0", .method = "textDocument/didOpen", .params = .{ .textDocument = .{ .uri = uri, .version = 1, .text = "{\rlet x=1,x}" } } });
    try message(a, &input.writer, .{ .jsonrpc = "2.0", .id = 2, .method = "textDocument/formatting", .params = .{ .textDocument = .{ .uri = uri }, .options = .{ .tabSize = 4, .insertSpaces = false } } });
    try message(a, &input.writer, .{ .jsonrpc = "2.0", .id = 3, .method = "shutdown" });
    try message(a, &input.writer, .{ .jsonrpc = "2.0", .method = "exit" });
    const output = try exchange(a, dir, input.written(), 0);
    const edit = c.field(try response(output, 2), "result").?.array.items[0];
    try std.testing.expectEqualStrings("{\r\tlet x = 1,\r\tx\r}\r", try c.string(c.field(edit, "newText").?));
    const end = c.field(c.field(edit, "range").?, "end").?;
    try std.testing.expectEqual(1, try c.number(a, c.field(end, "line").?));
    try std.testing.expectEqual(10, try c.number(a, c.field(end, "character").?));
}
