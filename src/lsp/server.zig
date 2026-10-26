// Copyright (C) 2026 OKcontract Pte. Ltd.
const std = @import("std");
const ms = @import("miniscript");
const c = @import("../cli/common.zig");
const p = @import("protocol.zig");
const text = @import("text.zig");
const syntax = @import("analysis.zig");
const metadata = @import("metadata.zig");
const features = @import("features.zig");
const programs = @import("../cli/programs.zig");
const disassembly = @import("../cli/disassembly.zig");
const Surface = @import("../cli/surface.zig").Surface;
const Cached = struct { arena: std.heap.ArenaAllocator, context: features.Context, revision: u64 };
const Document = struct { source: []const u8, version: i64, cached: ?*Cached = null, diagnostic: ?*DiagnosticJob = null };
const DiagnosticJob = struct {
    arena: std.heap.ArenaAllocator,
    context: features.Context,
    transport: *p.Transport,
    canceled: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    future: ?std.Io.Future(void) = null,
    fn run(job: *@This()) void {
        defer job.done.store(true, .release);
        std.Io.sleep(job.context.io, .fromMilliseconds(150), .awake) catch return;
        const items = job.context.diagnostics() catch return;
        if (job.canceled.load(.acquire)) return;
        job.transport.notify("textDocument/publishDiagnostics", .{ .uri = job.context.uri, .version = job.context.version, .diagnostics = items }) catch {};
    }
};
const Folder = struct { uri: []const u8, path: []const u8 };

fn nested(input: c.Value, names: []const []const u8) c.Value {
    var v = input;
    for (names) |name| v = p.field(v, name);
    return v;
}
const Job = struct {
    arena: std.heap.ArenaAllocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    transport: *p.Transport,
    id: c.Value,
    command: []const u8,
    options: c.Value,
    root: []const u8,
    config_dir: []const u8,
    hash: ?[]const u8,
    refresh_support: bool,
    done: std.atomic.Value(bool) = .init(false),
    future: ?std.Io.Future(void) = null,

    fn run(job: *Job) void {
        defer job.done.store(true, .release);
        const result = job.execute() catch |err| {
            job.transport.failure(job.id, if (err == error.Canceled) -32800 else -32001, features.message(err)) catch {};
            return;
        };
        job.transport.reply(job.id, result) catch return;
        if (job.refresh_support) job.transport.send(.{ .jsonrpc = "2.0", .id = "chainwall-diagnostic-refresh", .method = "workspace/diagnostic/refresh" }) catch {};
    }
    fn execute(job: *Job) !c.Value {
        const a = job.arena.allocator();
        const selected = try metadata.Selection.resolve(a, job.io, job.env, job.config_dir, job.options, job.root);
        if (c.eq(u8, job.command, "chainwall.refresh")) return metadata.refresh(a, job.io, job.env, selected);
        const catalog = try metadata.Catalog.load(a, job.io, selected);
        const hash = try c.id(a, job.hash orelse return error.AbiTargetRequired);
        const entry = catalog.find(hash) orelse return error.UnknownRegistryReference;
        const address = entry.implementation orelse entry.address orelse return error.ContractAddressUnavailable;
        var explorer = selected.explorer(a, job.io, job.env);
        explorer.refresh = true;
        const abi = try explorer.abi(address);
        return p.json(a, .{ .chainId = selected.chain, .instance = selected.instance, .target = hash, .abi = abi });
    }
};

pub const Server = struct {
    a: c.A,
    io: std.Io,
    env: *const std.process.Environ.Map,
    transport: p.Transport,
    root: []const u8,
    config_dir: []const u8,
    base_options: c.Value,
    initial_options: ?[]const u8 = null,
    configuration_arena: std.heap.ArenaAllocator,
    options: c.Value = .null,
    language: c.Value,
    documents: std.StringArrayHashMapUnmanaged(Document) = .empty,
    folders: std.ArrayList(Folder) = .empty,
    initialized: bool = false,
    shutdown: bool = false,
    exit_code: ?u8 = null,
    encoding: text.Encoding = .utf16,
    snippets: bool = false,
    versioned_edits: bool = false,
    refresh_support: bool = false,
    show_document: bool = false,
    request_sequence: usize = 0,
    job: ?*Job = null,
    metadata_revision: u64 = 0,
    cache_builds: usize = 0,
    refresh_diagnostics: bool = false,

    pub fn init(a: c.A, io: std.Io, env: *const std.process.Environ.Map, root: []const u8, config_dir: []const u8, base_options: c.Value, language: c.Value) Server {
        return .{ .a = a, .io = io, .env = env, .root = root, .config_dir = config_dir, .base_options = base_options, .configuration_arena = .init(a), .language = language, .transport = .{ .io = io } };
    }
    pub fn deinit(s: *Server) void {
        s.finishJob(true);
        for (s.documents.keys(), s.documents.values()) |key, *doc| {
            s.cancelDiagnostics(doc);
            s.releaseCache(doc.cached);
            s.a.free(key);
            s.a.free(doc.source);
        }
        s.documents.deinit(s.a);
        for (s.folders.items) |folder| {
            s.a.free(folder.uri);
            s.a.free(folder.path);
        }
        s.folders.deinit(s.a);
        s.configuration_arena.deinit();
        if (s.initial_options) |options| s.a.free(options);
    }
    fn finishJob(s: *Server, cancel: bool) void {
        const job = s.job orelse return;
        if (!cancel and !job.done.load(.acquire)) return;
        if (job.future) |*future| {
            if (cancel) future.cancel(s.io) else future.await(s.io);
        }
        // Invalidation cancels queued diagnostics even when a refresh fails.
        // Republish the current document versions after every completed job.
        if (!cancel) s.refresh_diagnostics = true;
        job.arena.deinit();
        s.a.destroy(job);
        s.job = null;
        s.invalidate();
    }
    fn releaseCache(s: *Server, cached: ?*Cached) void {
        if (cached) |entry| {
            entry.arena.deinit();
            s.a.destroy(entry);
        }
    }
    fn cancelDiagnostics(s: *Server, doc: *Document) void {
        const job = doc.diagnostic orelse return;
        job.canceled.store(true, .release);
        if (job.future) |*future| future.cancel(s.io);
        job.arena.deinit();
        s.a.destroy(job);
        doc.diagnostic = null;
    }
    fn scheduleDiagnostics(s: *Server, uri: []const u8) !void {
        const doc = s.documents.getPtr(uri) orelse return error.DocumentNotOpen;
        s.cancelDiagnostics(doc);
        const job = try s.a.create(DiagnosticJob);
        errdefer s.a.destroy(job);
        job.arena = .init(std.heap.page_allocator);
        errdefer job.arena.deinit();
        job.context = try s.context(job.arena.allocator(), uri);
        job.transport = &s.transport;
        job.canceled = .init(false);
        job.done = .init(false);
        job.future = try s.io.concurrent(DiagnosticJob.run, .{job});
        doc.diagnostic = job;
    }
    fn invalidate(s: *Server) void {
        s.metadata_revision +%= 1;
        for (s.documents.values()) |*doc| {
            s.cancelDiagnostics(doc);
            s.releaseCache(doc.cached);
            doc.cached = null;
        }
    }
    pub fn run(s: *Server) !u8 {
        var buffer: [8192]u8 = undefined;
        var reader = std.Io.File.stdin().readerStreaming(s.io, &buffer);
        const Event = union(enum) { input: anyerror!?[]const u8, tick: anyerror!void };
        var events: [3]Event = undefined;
        var select = std.Io.Select(Event).init(s.io, &events);
        defer while (select.cancel()) |event| switch (event) {
            .input => |result| if (result catch null) |body| std.heap.page_allocator.free(body),
            .tick => {},
        };
        try select.concurrent(.input, readInput, .{&reader.interface});
        var ticking = false;
        while (s.exit_code == null) {
            const event = try select.await();
            if (event == .tick) {
                try event.tick;
                ticking = false;
            }
            s.finishJob(false);
            if (s.refresh_diagnostics) {
                s.refresh_diagnostics = false;
                try s.publishAll();
            }
            if (event == .input) {
                const body = (try event.input) orelse break;
                defer std.heap.page_allocator.free(body);
                try select.concurrent(.input, readInput, .{&reader.interface});
                var arena = std.heap.ArenaAllocator.init(s.a);
                defer arena.deinit();
                const a = arena.allocator();
                const request = std.json.parseFromSlice(c.Value, a, body, .{ .allocate = .alloc_always }) catch {
                    try s.transport.failure(.null, -32700, "Invalid JSON");
                    continue;
                };
                try s.handle(a, request.value);
            }
            // Only poll while an explicit metadata job is active. The input
            // reader remains pending, so completion wakes an otherwise idle LSP.
            if (s.job != null and !ticking) {
                try select.concurrent(.tick, refreshTick, .{s.io});
                ticking = true;
            }
        }
        return s.exit_code orelse if (s.shutdown) @as(u8, 0) else 1;
    }
    fn handle(s: *Server, a: c.A, request: c.Value) !void {
        if (request != .object or !c.eq(u8, p.string(p.field(request, "jsonrpc")) catch "", "2.0")) return s.transport.failure(.null, -32600, "Invalid JSON-RPC request");
        const id = c.field(request, "id");
        if (id) |v| if (v != .integer and v != .string and v != .null) return s.transport.failure(.null, -32600, "Invalid request ID");
        // Responses to optional server-initiated refresh requests have no method.
        if (p.field(request, "method") == .null and (c.field(request, "result") != null or c.field(request, "error") != null)) return;
        const method = p.string(p.field(request, "method")) catch return s.transport.failure(id orelse .null, -32600, "Missing method");
        const params = p.field(request, "params");
        if (c.eq(u8, method, "exit")) {
            s.exit_code = if (s.shutdown) 0 else 1;
            return;
        }
        if (!s.initialized and !c.eq(u8, method, "initialize")) {
            if (id) |request_id| try s.transport.failure(request_id, -32002, "Server not initialized");
            return;
        }
        if (s.shutdown) {
            if (id) |request_id| try s.transport.failure(request_id, -32600, "Server has shut down");
            return;
        }
        const result = s.dispatch(a, method, params, id) catch |err| {
            if (id) |request_id| try s.transport.failure(request_id, if (err == error.MethodNotFound) -32601 else if (err == error.InvalidParams or err == error.InvalidBindingName or err == error.UnknownLspConfigurationKey or err == error.ConfigDirectoryRequiresStartupOption) -32602 else -32001, features.message(err)) else try s.transport.notify("window/logMessage", .{ .type = 1, .message = features.message(err) });
            return;
        };
        if (id != null and result != null) try s.transport.reply(id.?, result.?);
    }
    fn dispatch(s: *Server, a: c.A, method: []const u8, params: c.Value, id: ?c.Value) !?c.Value {
        if (c.eq(u8, method, "initialize")) {
            if (s.initialized or id == null) return error.InvalidParams;
            const init_options = p.field(params, "initializationOptions");
            const opts = try metadata.merge(a, s.base_options, init_options);
            const folders = p.field(params, "workspaceFolders");
            if (folders != .null and folders != .array) return error.InvalidParams;
            if (folders == .array) {
                for (folders.array.items) |folder| _ = (try text.path(a, try p.string(p.field(folder, "uri")))) orelse return error.InvalidFileUri;
            } else if (p.field(params, "rootUri") == .string) _ = (try text.path(a, p.field(params, "rootUri").string)) orelse return error.InvalidFileUri;
            // Copy JSON strings out of this initialize request's temporary arena.
            _ = s.configuration_arena.reset(.retain_capacity);
            s.options = try c.parse(s.configuration_arena.allocator(), try c.encode(a, opts));
            const initial_options = try s.a.dupe(u8, try c.encode(a, opts));
            if (s.initial_options) |previous| s.a.free(previous);
            s.initial_options = initial_options;
            const encodings = nested(params, &.{ "capabilities", "general", "positionEncodings" });
            if (encodings == .array) for (encodings.array.items) |v| if (c.eq(u8, p.string(v) catch "", "utf-8")) {
                s.encoding = .utf8;
                break;
            };
            s.snippets = p.boolean(nested(params, &.{ "capabilities", "textDocument", "completion", "completionItem", "snippetSupport" }));
            s.versioned_edits = p.boolean(nested(params, &.{ "capabilities", "workspace", "workspaceEdit", "documentChanges" }));
            s.refresh_support = p.boolean(nested(params, &.{ "capabilities", "workspace", "diagnostics", "refreshSupport" }));
            s.show_document = p.boolean(nested(params, &.{ "capabilities", "window", "showDocument", "support" }));
            if (folders == .array) {
                for (folders.array.items) |folder| try s.addFolder(try p.string(p.field(folder, "uri")));
            } else if (p.field(params, "rootUri") == .string) try s.addFolder(p.field(params, "rootUri").string);
            s.initialized = true;
            return try p.json(a, .{ .serverInfo = .{ .name = "chainwall-lsp", .version = "0.3.0" }, .capabilities = .{
                .positionEncoding = if (s.encoding == .utf8) "utf-8" else "utf-16",
                .textDocumentSync = .{ .openClose = true, .change = 2, .save = .{ .includeText = false } },
                .completionProvider = .{ .triggerCharacters = .{ "@", ".", "(", "/", "$" }, .resolveProvider = false },
                .hoverProvider = true,
                .signatureHelpProvider = .{ .triggerCharacters = .{ "(", "," }, .retriggerCharacters = .{")"} },
                .definitionProvider = true,
                .referencesProvider = true,
                .documentHighlightProvider = true,
                .documentSymbolProvider = true,
                .workspaceSymbolProvider = true,
                .renameProvider = .{ .prepareProvider = true },
                .documentFormattingProvider = true,
                .foldingRangeProvider = true,
                .selectionRangeProvider = true,
                .semanticTokensProvider = .{ .legend = .{ .tokenTypes = features.token_types, .tokenModifiers = .{ "declaration", "readonly", "defaultLibrary" } }, .full = true, .range = false },
                .inlayHintProvider = true,
                .codeLensProvider = .{ .resolveProvider = false },
                .codeActionProvider = .{ .codeActionKinds = .{ "quickfix", "source" } },
                .diagnosticProvider = .{ .identifier = "chainwall", .interFileDependencies = false, .workspaceDiagnostics = false },
                .executeCommandProvider = .{ .commands = features.commands },
                .workspace = .{ .workspaceFolders = .{ .supported = true, .changeNotifications = true } },
            } });
        }
        if (c.eq(u8, method, "shutdown")) {
            s.finishJob(true);
            for (s.documents.values()) |*doc| s.cancelDiagnostics(doc);
            s.shutdown = true;
            return @as(c.Value, .null);
        }
        if (c.eq(u8, method, "$/cancelRequest")) {
            if (s.job) |job| if (c.eq(u8, try c.encode(a, job.id), try c.encode(a, p.field(params, "id")))) s.finishJob(true);
            return null;
        }
        if (c.eq(u8, method, "initialized") or c.eq(u8, method, "$/setTrace")) return null;
        if (c.eq(u8, method, "workspace/didChangeConfiguration")) {
            const settings = p.field(params, "settings");
            const overlay = c.field(settings, "chainwall") orelse settings;
            const serialized = try c.encode(a, overlay);
            var next = std.heap.ArenaAllocator.init(s.a);
            errdefer next.deinit();
            const base = try c.parse(next.allocator(), s.initial_options.?);
            const options = try metadata.merge(next.allocator(), base, try c.parse(next.allocator(), serialized));
            s.configuration_arena.deinit();
            s.configuration_arena = next;
            next = .init(s.a); // Ownership moved; a publish failure must not free live options.
            s.options = options;
            s.invalidate();
            try s.publishAll();
            return null;
        }
        if (c.eq(u8, method, "workspace/didChangeWatchedFiles")) {
            s.invalidate();
            try s.publishAll();
            return null;
        }
        if (c.eq(u8, method, "workspace/didChangeWorkspaceFolders")) {
            const event = p.field(params, "event");
            const removed = p.field(event, "removed");
            const added = p.field(event, "added");
            if (removed != .array or added != .array) return error.InvalidParams;
            for (removed.array.items) |folder| s.removeFolder(try p.string(p.field(folder, "uri")));
            for (added.array.items) |folder| try s.addFolder(try p.string(p.field(folder, "uri")));
            s.invalidate();
            try s.publishAll();
            return null;
        }
        if (c.eq(u8, method, "textDocument/didOpen")) {
            const doc = p.field(params, "textDocument");
            const uri = try p.string(p.field(doc, "uri"));
            const source = try p.string(p.field(doc, "text"));
            const version = try p.integer(p.field(doc, "version"));
            if (s.documents.contains(uri) or s.documents.count() >= ms.limits.open_documents or source.len > text.max_source or !std.unicode.utf8ValidateSlice(source)) return error.InvalidParams;
            {
                const key = try s.a.dupe(u8, uri);
                errdefer s.a.free(key);
                const owned = try s.a.dupe(u8, source);
                errdefer s.a.free(owned);
                try s.documents.put(s.a, key, .{ .source = owned, .version = version });
            }
            try s.publish(a, uri);
            return null;
        }
        if (c.eq(u8, method, "textDocument/didChange")) {
            const input = p.field(params, "textDocument");
            const uri = try p.string(p.field(input, "uri"));
            const version = try p.integer(p.field(input, "version"));
            const doc = s.documents.getPtr(uri) orelse return error.InvalidParams;
            if (version <= doc.version) return null;
            const source = try text.changed(a, doc.source, p.field(params, "contentChanges"), s.encoding);
            const owned = try s.a.dupe(u8, source);
            s.cancelDiagnostics(doc);
            s.releaseCache(doc.cached);
            doc.cached = null;
            s.a.free(doc.source);
            doc.source = owned;
            doc.version = version;
            try s.scheduleDiagnostics(uri);
            return null;
        }
        if (c.eq(u8, method, "textDocument/didClose")) {
            const uri = try p.string(nested(params, &.{ "textDocument", "uri" }));
            if (s.documents.fetchOrderedRemove(uri)) |entry| {
                var closed = entry.value;
                s.cancelDiagnostics(&closed);
                s.releaseCache(entry.value.cached);
                s.a.free(entry.key);
                s.a.free(entry.value.source);
            }
            try s.transport.notify("textDocument/publishDiagnostics", .{ .uri = uri, .diagnostics = [_]c.Value{} });
            return null;
        }
        if (c.eq(u8, method, "textDocument/didSave")) {
            try s.publish(a, try p.string(nested(params, &.{ "textDocument", "uri" })));
            return null;
        }
        if (c.eq(u8, method, "workspace/executeCommand")) return s.execute(a, params, id orelse return error.InvalidParams);
        if (c.eq(u8, method, "workspace/symbol")) return try s.workspaceSymbols(a, try p.string(p.field(params, "query")));
        if (id == null) return null; // Unknown notifications never receive responses.
        var supported = false;
        for ([_][]const u8{
            "textDocument/diagnostic",    "textDocument/documentSymbol", "textDocument/semanticTokens/full",
            "textDocument/foldingRange",  "textDocument/selectionRange", "textDocument/inlayHint",
            "textDocument/codeLens",      "textDocument/codeAction",     "textDocument/formatting",
            "textDocument/completion",    "textDocument/hover",          "textDocument/signatureHelp",
            "textDocument/definition",    "textDocument/references",     "textDocument/documentHighlight",
            "textDocument/prepareRename", "textDocument/rename",         "chainwall/compile",
            "chainwall/analyze",
        }) |name| if (c.eq(u8, name, method)) {
            supported = true;
            break;
        };
        if (!supported) return error.MethodNotFound;
        const uri = try p.string(nested(params, &.{ "textDocument", "uri" }));
        var ctx = try s.context(a, uri);
        if (c.eq(u8, method, "textDocument/diagnostic")) {
            const doc = s.documents.getPtr(uri).?;
            const pending = if (doc.diagnostic) |job| !job.done.load(.acquire) else false;
            s.cancelDiagnostics(doc);
            const items = try ctx.diagnostics();
            if (pending) try s.transport.notify("textDocument/publishDiagnostics", .{ .uri = uri, .version = ctx.version, .diagnostics = items });
            return try p.json(a, .{ .kind = "full", .items = items });
        }
        if (c.eq(u8, method, "textDocument/documentSymbol")) return try ctx.symbols();
        if (c.eq(u8, method, "textDocument/semanticTokens/full")) return try ctx.semanticTokens();
        if (c.eq(u8, method, "textDocument/foldingRange")) return try ctx.folding();
        if (c.eq(u8, method, "textDocument/selectionRange")) return try ctx.selections(p.field(params, "positions"));
        if (c.eq(u8, method, "textDocument/inlayHint")) return try ctx.inlays(p.field(params, "range"));
        if (c.eq(u8, method, "textDocument/codeLens")) return try ctx.codeLenses();
        if (c.eq(u8, method, "textDocument/codeAction")) return try ctx.actions(p.field(params, "range"));
        if (c.eq(u8, method, "chainwall/compile")) return try ctx.compile();
        if (c.eq(u8, method, "chainwall/analyze")) return c.field(try ctx.compile(), "analysis").?;
        if (c.eq(u8, method, "textDocument/formatting")) {
            const indent = p.integer(nested(params, &.{ "options", "tabSize" })) catch 2;
            if (indent < 1 or indent > ms.limits.indentation_width) return error.InvalidParams;
            const spaces = nested(params, &.{ "options", "insertSpaces" });
            if (spaces != .null and spaces != .bool) return error.InvalidParams;
            const formatted = ms.syntax.formatWithOptions(a, ctx.source, .{ .tab_size = @intCast(indent), .insert_spaces = spaces == .null or spaces.bool }) catch |err| {
                if (err == error.OutOfMemory) return err;
                return try p.json(a, &[_]c.Value{});
            };
            return try p.json(a, &[_]text.Edit{.{ .range = text.range(ctx.source, .{ .end = ctx.source.len }, s.encoding), .newText = formatted }});
        }
        const pos = try text.offset(ctx.source, p.field(params, "position"), s.encoding);
        if (c.eq(u8, method, "textDocument/completion")) return try ctx.completion(pos);
        if (c.eq(u8, method, "textDocument/hover")) return try ctx.hover(pos);
        if (c.eq(u8, method, "textDocument/signatureHelp")) return try ctx.signature(pos);
        if (c.eq(u8, method, "textDocument/definition")) return try ctx.definition(pos);
        if (c.eq(u8, method, "textDocument/references")) return try ctx.references(pos, p.boolean(nested(params, &.{ "context", "includeDeclaration" })), false);
        if (c.eq(u8, method, "textDocument/documentHighlight")) return try ctx.references(pos, true, true);
        if (c.eq(u8, method, "textDocument/prepareRename")) return try ctx.prepareRename(pos);
        if (c.eq(u8, method, "textDocument/rename")) return try ctx.rename(pos, try p.string(p.field(params, "newName")));
        return error.MethodNotFound;
    }
    fn addFolder(s: *Server, uri: []const u8) !void {
        for (s.folders.items) |folder| if (c.eq(u8, folder.uri, uri)) return;
        const path = (try text.path(s.a, uri)) orelse return error.InvalidFileUri;
        errdefer s.a.free(path);
        const owned_uri = try s.a.dupe(u8, uri);
        errdefer s.a.free(owned_uri);
        try s.folders.append(s.a, .{ .uri = owned_uri, .path = path });
    }
    fn removeFolder(s: *Server, uri: []const u8) void {
        for (s.folders.items, 0..) |folder, i| if (c.eq(u8, folder.uri, uri)) {
            s.a.free(folder.uri);
            s.a.free(folder.path);
            _ = s.folders.orderedRemove(i);
            return;
        };
    }
    fn scope(s: *Server, a: c.A, uri: []const u8) !struct { root: []const u8, options: c.Value } {
        const path = (try text.path(a, uri)) orelse "";
        var root = s.root;
        var longest: usize = 0;
        for (s.folders.items) |folder| if (folder.path.len > longest and std.mem.startsWith(u8, path, folder.path) and (path.len == folder.path.len or folder.path[folder.path.len - 1] == std.Io.Dir.path.sep or path[folder.path.len] == std.Io.Dir.path.sep)) {
            root = folder.path;
            longest = root.len;
        };
        if (path.len == 0 and s.folders.items.len > 0) root = s.folders.items[0].path;
        var options = s.options;
        const file = try std.Io.Dir.path.join(a, &.{ root, "chainwall-lsp.json" });
        if (c.read(a, s.io, file)) |bytes| options = try metadata.merge(a, options, try c.parse(a, bytes)) else |err| if (err != error.FileNotFound) return err;
        return .{ .root = root, .options = options };
    }
    fn context(s: *Server, a: c.A, uri: []const u8) !features.Context {
        const doc = s.documents.getPtr(uri) orelse return error.DocumentNotOpen;
        if (doc.cached) |cached| if (cached.revision != s.metadata_revision or cached.context.version != doc.version) {
            s.releaseCache(doc.cached);
            doc.cached = null;
        };
        if (doc.cached == null) {
            const cached = try s.a.create(Cached);
            errdefer s.a.destroy(cached);
            cached.arena = .init(s.a);
            errdefer cached.arena.deinit();
            cached.context = try s.buildContext(cached.arena.allocator(), try cached.arena.allocator().dupe(u8, uri));
            cached.revision = s.metadata_revision;
            doc.cached = cached;
            s.cache_builds += 1;
        }
        // Cached syntax and catalogs are immutable. Per-request rendering and
        // preprocessing allocate in the request arena, never the cache arena.
        var result = doc.cached.?.context;
        result.a = a;
        result.catalog.a = a;
        result.analysis.a = a;
        if (result.analysis.surface) |*surface_| surface_.a = a;
        return result;
    }
    fn buildContext(s: *Server, a: c.A, uri: []const u8) !features.Context {
        const doc = s.documents.get(uri) orelse return error.DocumentNotOpen;
        var issue: ?anyerror = null;
        const catalog = s.loadCatalog(a, uri) catch |err| blk: {
            if (err == error.OutOfMemory) return err;
            issue = err;
            break :blk metadata.Catalog{ .a = a, .selection = .{ .dir = "", .profile_name = "", .profile = .{}, .chain = 0, .instance = "", .url = "", .settings = .{}, .snapshot = null, .abis = .null, .root = s.root } };
        };
        var analysis = try syntax.Analysis.init(a, doc.source);
        const tokens = text.tokens(a, doc.source) catch |err| blk: {
            if (err == error.OutOfMemory) return err;
            analysis.failure = err;
            analysis.surface = null;
            analysis.error_span = .{};
            break :blk &.{};
        };
        return .{ .a = a, .io = s.io, .uri = uri, .source = doc.source, .version = doc.version, .encoding = s.encoding, .snippets = s.snippets, .catalog = catalog, .language = s.language, .analysis = analysis, .tokens = tokens, .configuration_error = issue, .versioned_edits = s.versioned_edits };
    }
    fn loadCatalog(s: *Server, a: c.A, uri: []const u8) !metadata.Catalog {
        const selected = try s.scope(a, uri);
        return metadata.Catalog.load(a, s.io, try metadata.Selection.resolve(a, s.io, s.env, s.config_dir, selected.options, selected.root));
    }
    fn publish(s: *Server, a: c.A, uri: []const u8) !void {
        if (s.documents.getPtr(uri)) |doc| s.cancelDiagnostics(doc);
        var ctx = try s.context(a, uri);
        try s.transport.notify("textDocument/publishDiagnostics", .{ .uri = uri, .version = ctx.version, .diagnostics = try ctx.diagnostics() });
    }
    fn publishAll(s: *Server) !void {
        for (s.documents.keys()) |uri| {
            var arena = std.heap.ArenaAllocator.init(s.a);
            defer arena.deinit();
            try s.publish(arena.allocator(), uri);
        }
    }
    fn execute(s: *Server, a: c.A, params: c.Value, id: c.Value) !?c.Value {
        const command = try p.string(p.field(params, "command"));
        const args = p.field(params, "arguments");
        if (args != .null and args != .array) return error.InvalidParams;
        if (c.eq(u8, command, "chainwall.templates")) return p.field(s.language, "templates");
        const uri = if (args == .array and args.array.items.len > 0) try p.string(args.array.items[0]) else if (s.documents.count() > 0) s.documents.keys()[0] else try text.uri(a, s.root);
        if (c.eq(u8, command, "chainwall.refresh") or c.eq(u8, command, "chainwall.fetchAbi")) {
            s.finishJob(false);
            if (s.job != null) return error.CatalogRefreshAlreadyRunning;
            const scope_ = try s.scope(a, uri);
            const job = try s.a.create(Job);
            errdefer s.a.destroy(job);
            job.* = .{ .arena = .init(std.heap.page_allocator), .io = s.io, .env = s.env, .transport = &s.transport, .id = .null, .command = "", .options = .null, .root = "", .config_dir = s.config_dir, .hash = null, .refresh_support = s.refresh_support };
            errdefer job.arena.deinit();
            const ja = job.arena.allocator();
            job.id = try c.parse(ja, try c.encode(a, id));
            job.command = try ja.dupe(u8, command);
            job.options = try c.parse(ja, try c.encode(a, scope_.options));
            job.root = try ja.dupe(u8, scope_.root);
            if (args == .array and args.array.items.len > 1) job.hash = try ja.dupe(u8, try p.string(args.array.items[1]));
            job.future = try s.io.concurrent(Job.run, .{job});
            s.job = job;
            return null;
        }
        if (c.eq(u8, command, "chainwall.reload")) {
            s.invalidate();
            try s.publishAll();
            return @as(c.Value, .null);
        }
        if (c.eq(u8, command, "chainwall.status")) {
            const catalog = try s.loadCatalog(a, uri);
            var issues: std.json.ObjectMap = .empty;
            for (catalog.abi_issues.keys(), catalog.abi_issues.values()) |hash, issue| try issues.put(a, hash, .{ .string = issue });
            return try p.json(a, .{ .profile = catalog.selection.profile_name, .chainId = catalog.selection.chain, .instance = catalog.selection.instance, .entries = catalog.entries.items.len, .checkpoints = c.Value{ .object = catalog.checkpoints }, .cache = try @import("../cli/cache_metadata.zig").describe(a, if (catalog.selection.snapshot != null) "snapshot-file" else "sqlite-cache", .null, .null, issues.count() > 0), .cacheByDataset = try @import("../cli/cache_metadata.zig").datasets(a, if (catalog.selection.snapshot != null) "snapshot-file" else "sqlite-cache", .{ .object = catalog.checkpoints }), .abiIssues = c.Value{ .object = issues }, .offlineSnapshot = catalog.selection.snapshot });
        }
        if (c.eq(u8, command, "chainwall.compile") or c.eq(u8, command, "chainwall.showCompiled") or c.eq(u8, command, "chainwall.analyze")) {
            var ctx = try s.context(a, uri);
            const artifact = try ctx.compile();
            if (c.eq(u8, command, "chainwall.compile")) return artifact;
            if (c.eq(u8, command, "chainwall.analyze")) return c.field(artifact, "analysis").?;
            const file = try a.print("{s}/lsp/compiled/{x}.json", .{ ctx.catalog.selection.dir, ms.bytecode.hash(uri) });
            try c.write(s.io, file, try c.encode(a, artifact), true);
            const output_uri = try text.uri(a, file);
            if (s.show_document) {
                s.request_sequence += 1;
                try s.transport.send(.{ .jsonrpc = "2.0", .id = try a.print("chainwall-show-{d}", .{s.request_sequence}), .method = "window/showDocument", .params = .{ .uri = output_uri, .external = false, .takeFocus = true } });
            } else try s.transport.notify("window/showMessage", .{ .type = 3, .message = try a.print("Compiler JSON saved to {s}", .{file}) });
            return try p.json(a, .{ .uri = output_uri });
        }
        if (c.eq(u8, command, "chainwall.decompileInteraction")) {
            if (args != .array or args.array.items.len != 2) return error.InvalidParams;
            const catalog = try s.loadCatalog(a, uri);
            const hash = try c.id(a, try p.string(args.array.items[1]));
            const entry = catalog.findKind(hash, "interaction") orelse return error.UnknownInteraction;
            const bytes = try ms.bytecode.unhex(a, try p.string(p.field(entry.record, "script")));
            const source_metadata = try catalog.sourceMetadata();
            const recovered = try disassembly.decompile(a, bytes, catalog.selection.settings, source_metadata);
            const snapshot = try source_metadata.snapshot();
            var surface_ = try Surface.parse(a, recovered.source);
            const core = try surface_.preprocess(snapshot, catalog.selection.settings);
            var artifact = try programs.artifact(a, uri, recovered.source, core, surface_.settings);
            try programs.attachMetadata(a, &artifact, surface_, snapshot);
            if (!std.ascii.eqlIgnoreCase(try p.string(p.field(artifact, "bytecode")), try p.string(p.field(entry.record, "script")))) return error.StoredInteractionDoesNotRoundTrip;
            return artifact;
        }
        return error.MethodNotFound;
    }
    fn workspaceSymbols(s: *Server, a: c.A, query: []const u8) !c.Value {
        var out = std.json.Array.init(a);
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        for (s.documents.keys()) |uri| {
            const ctx = try s.context(a, uri);
            for (ctx.analysis.symbols.items) |symbol| if (containsIgnoreCase(symbol.spelling, query)) try out.append(try p.json(a, .{ .name = symbol.spelling, .kind = 13, .location = .{ .uri = uri, .range = text.range(ctx.source, symbol.span, s.encoding) } }));
        }
        const count = @max(s.folders.items.len, 1);
        for (0..count) |i| {
            const uri = if (s.folders.items.len > 0) s.folders.items[i].uri else try text.uri(a, s.root);
            const catalog = s.loadCatalog(a, uri) catch |err| {
                if (err == error.OutOfMemory) return err;
                continue;
            };
            for (catalog.entries.items) |entry| {
                if (!containsIgnoreCase(entry.label, query) and !containsIgnoreCase(entry.hash, query)) continue;
                const key = try a.print("{d}:{s}:{s}:{s}", .{ catalog.selection.chain, catalog.selection.instance, entry.kind, entry.hash });
                if (seen.contains(key)) continue;
                try seen.put(a, key, {});
                try out.append(try p.json(a, .{ .name = entry.label, .kind = 14, .containerName = try a.print("{s} | {d} | {s}", .{ entry.kind, catalog.selection.chain, catalog.selection.instance }), .location = try catalog.location(s.io, entry) }));
                if (out.items.len >= 100) return .{ .array = out };
            }
        }
        return .{ .array = out };
    }
};

fn readInput(reader: *std.Io.Reader) anyerror!?[]const u8 {
    return p.read(std.heap.page_allocator, reader);
}
fn refreshTick(io: std.Io) anyerror!void {
    try std.Io.sleep(io, .fromMilliseconds(50), .awake);
}
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    return false;
}

fn allocationInitialize(a: c.A, params: c.Value) !void {
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var server = Server.init(a, std.testing.io, &env, "/", "/", .null, .null);
    defer server.deinit();
    // An earlier initialize can save options and then fail while adding a
    // workspace folder. Retrying must retain the old buffer until replacement.
    server.initial_options = try a.dupe(u8, "{}");
    var request_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer request_arena.deinit();
    _ = try server.dispatch(request_arena.allocator(), "initialize", params, .{ .integer = 1 });
}
test "initialize retry releases each owned buffer on allocation failures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const params = try c.parse(arena.allocator(), "{\"rootUri\":\"file:///tmp\",\"capabilities\":{}}");
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationInitialize, .{params});
}

test "document cache reuses syntax and catalog until version or metadata changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var env: std.process.Environ.Map = .init(a);
    var server = Server.init(a, std.testing.io, &env, dir, dir, .null, .null);
    defer server.deinit();
    server.options = try c.parse(a, "{}");
    const uri = try a.print("file://{s}/cache.ls", .{dir});
    try server.documents.put(a, try a.dupe(u8, uri), .{ .source = try a.dupe(u8, "let x = 1 in x"), .version = 1 });
    var first = try server.context(a, uri);
    const second = try server.context(a, uri);
    try std.testing.expectEqual(first.analysis.nodes.items.ptr, second.analysis.nodes.items.ptr);
    try std.testing.expectEqual(1, server.cache_builds);
    // Preprocessing a returned copy must not mutate the cached Surface maps.
    _ = try first.analysis.surface.?.preprocess(try first.catalog.toSnapshot(), .{});
    try std.testing.expectEqual(0, server.documents.get(uri).?.cached.?.context.analysis.surface.?.accepted.count());
    server.documents.getPtr(uri).?.version = 2;
    _ = try server.context(a, uri);
    try std.testing.expectEqual(2, server.cache_builds);
    server.invalidate();
    _ = try server.context(a, uri);
    try std.testing.expectEqual(3, server.cache_builds);
}
