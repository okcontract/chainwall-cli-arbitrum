// Copyright (C) 2026 OKcontract Pte. Ltd.
const std = @import("std");
const ms = @import("miniscript");
const c = @import("../cli/common.zig");
const surface = @import("../cli/surface.zig");
const programs = @import("../cli/programs.zig");
const p = @import("protocol.zig");
const text = @import("text.zig");
const syntax = @import("analysis.zig");
const metadata = @import("metadata.zig");
const Node = ms.tree.Node;

pub const token_types = [_][]const u8{ "variable", "function", "keyword", "number", "string", "operator", "type", "namespace" };
pub const commands = [_][]const u8{ "chainwall.compile", "chainwall.showCompiled", "chainwall.analyze", "chainwall.refresh", "chainwall.reload", "chainwall.fetchAbi", "chainwall.decompileInteraction", "chainwall.templates", "chainwall.status" };
pub const Diagnostic = struct { range: text.Range, severity: u8 = 1, code: []const u8, source: []const u8 = "chainwall", message: []const u8 };
const Markup = struct { kind: []const u8 = "markdown", value: []const u8 };
const Completion = struct {
    label: []const u8,
    kind: u8 = 6,
    detail: ?[]const u8 = null,
    documentation: ?Markup = null,
    textEdit: text.Edit,
    insertTextFormat: u8 = 1,
    filterText: ?[]const u8 = null,
    sortText: ?[]const u8 = null,
    additionalTextEdits: ?[]const text.Edit = null,
};

pub const Context = struct {
    a: c.A,
    io: std.Io,
    uri: []const u8,
    source: []const u8,
    version: i64,
    encoding: text.Encoding,
    snippets: bool,
    catalog: metadata.Catalog,
    language: c.Value,
    analysis: syntax.Analysis,
    tokens: []const text.Token,
    configuration_error: ?anyerror = null,
    versioned_edits: bool = false,

    fn r(s: Context, span: text.Span) text.Range {
        return text.range(s.source, span, s.encoding);
    }
    fn builtin(s: Context, name: []const u8) ?c.Value {
        for (p.field(s.language, "stdlib").array.items) |entry| if (std.ascii.eqlIgnoreCase(p.string(p.field(entry, "name")) catch "", name)) return entry;
        return null;
    }
    fn builtinVariable(s: Context, name: []const u8) bool {
        if (std.mem.startsWith(u8, name, "$arg")) {
            _ = std.fmt.parseInt(u64, name[4..], 10) catch return false;
            return true;
        }
        const entry = s.builtin(name) orelse return false;
        return c.eq(u8, p.string(p.field(entry, "kind")) catch "", "variable");
    }
    pub fn compile(s: *Context) !c.Value {
        if (s.configuration_error != null) return error.ConfigurationUnavailable;
        if (s.analysis.failure) |err| return err;
        const parsed = &s.analysis.surface.?;
        const snapshot = try s.catalog.toSnapshot();
        const core = try parsed.preprocess(snapshot, s.catalog.selection.settings);
        var program = try programs.artifact(s.a, s.uri, s.source, core, parsed.settings);
        try programs.attachMetadata(s.a, &program, parsed.*, snapshot);
        const options = s.catalog.selection.analysis_options;
        if (options.read_only or options.linked) try program.object.put(s.a, "analysis", try @import("../cli/program_analysis.zig").analyze(s.a, try ms.bytecode.unhex(s.a, try c.string(c.field(program, "bytecode").?)), options));
        return program;
    }
    fn diagnostic(s: Context, span: text.Span, err: anyerror) Diagnostic {
        return .{ .range = s.r(span), .code = @errorName(err), .message = message(err) };
    }
    pub fn diagnostics(s: *Context) ![]const Diagnostic {
        var result: std.ArrayList(Diagnostic) = .empty;
        if (c.trim(s.source).len == 0) return &.{};
        if (s.analysis.failure) |err| {
            try result.append(s.a, s.diagnostic(s.analysis.error_span, err));
            return result.items;
        }
        if (s.configuration_error) |err| {
            try result.append(s.a, .{ .range = s.r(.{}), .severity = 2, .code = @errorName(err), .message = try s.a.print("Chainwall configuration could not be loaded ({s}). Registry assistance is unavailable until it is corrected.", .{message(err)}) });
        }
        for (s.analysis.uses.items) |use| if (use.symbol == null and use.node.name_span.end > use.node.name_span.start and !s.builtinVariable(use.node.name)) {
            try result.append(s.a, .{ .range = s.r(use.node.name_span), .code = "UnboundVariable", .message = try s.a.print("Unknown variable '{s}'.", .{use.node.spelling}) });
        };
        for (s.analysis.nodes.items) |node| if (node.tag == .registry_reference) {
            const hash = try c.id(s.a, node.name);
            const kind = s.catalog.known.get(hash);
            const wanted = if (node.data) "token" else "contract";
            if (kind == null) {
                const complete = if (node.data) s.catalog.complete_tokens else s.catalog.complete_contracts;
                try result.append(s.a, .{ .range = s.r(node.span), .severity = if (complete) 1 else 2, .code = if (complete) "UnknownRegistryReference" else "CatalogNotSynced", .message = if (complete) try s.a.print("No {s} named '{s}' in the selected catalog.", .{ wanted, node.name }) else "Registry metadata is not synced. Run chainwall.refresh or chainwall sync with this profile." });
            } else if (!c.eq(u8, try p.string(kind.?), wanted) and !c.eq(u8, try p.string(kind.?), "contract+token")) try result.append(s.a, s.diagnostic(node.span, error.RegistryKindMismatch));
        };
        if (result.items.len > 0) return result.items;
        const program = s.compile() catch |err| {
            if (err == error.OutOfMemory) return err;
            const span = s.analysis.surface.?.diagnostic_span orelse s.analysis.surface.?.program.main.span;
            var d = s.diagnostic(span, err);
            if (err == error.MissingAbi) d.severity = 2;
            try result.append(s.a, d);
            return result.items;
        };
        const report = c.field(program, "analysis").?;
        for ([_][]const u8{ "issues", "readOnlyViolations" }) |key| for (c.field(report, key).?.array.items) |issue| {
            // Dynamic operands can be valid at runtime while preventing a full
            // static report. Keep these distinct from compiler errors.
            try result.append(s.a, .{ .range = s.r(s.analysis.surface.?.program.main.span), .severity = if (c.eq(u8, key, "issues") and !s.catalog.selection.analysis_options.linked) 2 else 1, .code = if (c.eq(u8, key, "issues")) "MiniScriptAnalysis" else "ReadOnlyViolation", .message = try c.string(issue) });
        };
        return result.items;
    }
    pub fn completion(s: *Context, pos: usize) !c.Value {
        var out: std.ArrayList(Completion) = .empty;
        const token = text.at(s.tokens, pos);
        if (token) |t| if (t.kind == .string and pos > t.span.start and pos < t.span.end) return p.json(s.a, .{ .isIncomplete = false, .items = out.items });
        if (token) |t| if (t.kind == .reference and text.contains(t.span, pos)) {
            if (std.mem.indexOfScalar(u8, t.text, '(')) |open| {
                const start = t.span.start + open + 1;
                const end = if (std.mem.endsWith(u8, t.text, ")")) t.span.end - 1 else t.span.end;
                if (pos < start or pos > end) return p.json(s.a, .{ .isIncomplete = false, .items = out.items });
                const name = c.trim(t.text[0..open]);
                const kind = if (c.eq(u8, name, "@token")) "token" else if (c.eq(u8, name, "@contract")) "contract" else "";
                for (s.catalog.entries.items) |entry| if (c.eq(u8, entry.kind, kind) and entry.path != null and matches(entry.label, c.trim(s.source[start..pos]))) try out.append(s.a, try s.entryCompletion(entry, .{ .start = start, .end = end }, entry.path.?));
            } else {
                for ([_][]const u8{ "@contract", "@token" }) |kind| if (matches(kind, s.source[t.span.start..pos])) try out.append(s.a, .{ .label = kind, .kind = 14, .textEdit = .{ .range = s.r(t.span), .newText = if (s.snippets) try s.a.print("{s}(${{1:org/id}})", .{kind}) else kind }, .insertTextFormat = if (s.snippets) 2 else 1 });
            }
            return p.json(s.a, .{ .isIncomplete = false, .items = out.items });
        };
        var start = pos;
        while (start > 0 and text.word(s.source[start - 1])) start -= 1;
        var end = pos;
        while (end < s.source.len and text.word(s.source[end])) end += 1;
        const replace: text.Span = .{ .start = start, .end = end };
        const query = s.source[start..pos];
        const analysis = try syntax.context(s.a, s.source, pos);
        var before = start;
        while (before > 0 and std.ascii.isWhitespace(s.source[before - 1])) before -= 1;
        if (before > 0 and s.source[before - 1] == '.') {
            const member = analysis.namedAt(start) orelse return p.json(s.a, .{ .isIncomplete = false, .items = out.items });
            if (member.tag == .member_call) if (analysis.reference(member.children[0])) |ref| {
                const abi = s.catalog.abis.get(try c.id(s.a, ref.name)) orelse return p.json(s.a, .{ .isIncomplete = false, .items = out.items });
                for (abi.array.items) |item| {
                    if (!function(item) or !matches(try p.string(p.field(item, "name")), query)) continue;
                    if (try s.methodCompletion(item, abi, replace, s.analysis.namedAt(start))) |completion_| try out.append(s.a, completion_);
                }
            };
            return p.json(s.a, .{ .isIncomplete = false, .items = out.items });
        }
        const call = syntax.callAt(s.tokens, pos);
        var io_slot = false;
        var interaction_slot = false;
        var token_slot = false;
        if (call) |ctx| {
            const read = std.ascii.eqlIgnoreCase(ctx.name.text, "$read") or std.ascii.eqlIgnoreCase(ctx.name.text, "$readWords");
            const write = std.ascii.eqlIgnoreCase(ctx.name.text, "$write");
            io_slot = (read or write) and ctx.argument < 2;
            interaction_slot = std.ascii.eqlIgnoreCase(ctx.name.text, "$calli") and ctx.argument == 0;
            token_slot = std.ascii.eqlIgnoreCase(ctx.name.text, "$price") and ctx.argument == 0;
            if ((read or write) and ctx.argument == 1) {
                const node = analysis.namedAt(ctx.name.span.start);
                if (node != null and node.?.children.len > 0) {
                    const target = node.?.children[0];
                    const hash = if (analysis.reference(target)) |ref| try c.id(s.a, ref.name) else if (target.tag == .number) try c.hex(s.a, target.value) else null;
                    if (hash) |key| if (s.catalog.abis.get(key)) |abi| for (abi.array.items) |item| {
                        if (!function(item)) continue;
                        const method = ms.abi.method(s.a, item) catch continue;
                        const readonly = method.mutability == .pure or method.mutability == .view;
                        if (read != readonly or !matches(method.signature, query)) continue;
                        try out.append(s.a, .{ .label = method.signature, .kind = 3, .detail = @tagName(method.mutability), .textEdit = .{ .range = s.r(replace), .newText = try s.a.print("0x{x:0>8}", .{method.selector}) } });
                    };
                }
                return p.json(s.a, .{ .isIncomplete = false, .items = out.items });
            }
        }
        if (!io_slot and !interaction_slot and !token_slot) {
            var names: std.StringHashMapUnmanaged(void) = .empty;
            var i = analysis.symbols.items.len;
            while (i > 0) {
                i -= 1;
                const symbol = analysis.symbols.items[i];
                if (!text.contains(symbol.scope, pos) or !matches(symbol.spelling, query) or names.contains(symbol.name)) continue;
                try names.put(s.a, symbol.name, {});
                try out.append(s.a, .{ .label = symbol.spelling, .detail = "local binding", .sortText = try s.a.print("0-{s}", .{symbol.name}), .textEdit = .{ .range = s.r(replace), .newText = symbol.spelling } });
            }
            for (p.field(s.language, "stdlib").array.items) |entry| {
                const name = try p.string(p.field(entry, "name"));
                if (!matches(name, query) or names.contains(try std.ascii.allocLowerString(s.a, name))) continue;
                const is_function = c.eq(u8, try p.string(p.field(entry, "kind")), "function");
                const builtin_signature = try p.string(p.field(entry, "signature"));
                const doc = if (std.mem.startsWith(u8, name, "$arg")) try s.a.print("{s} argument {s}.", .{ if (s.catalog.selection.settings.argumentContext == .subject) "Original interaction" else "Program frame", name[4..] }) else try p.string(p.field(entry, "doc"));
                const after = std.mem.trimStart(u8, s.source[end..], " \t\r\n");
                const insert = if (s.snippets and is_function and !std.mem.startsWith(u8, after, "(")) try builtinSnippet(s.a, name, builtin_signature) else if (s.snippets) try snippetEscape(s.a, name) else name;
                try out.append(s.a, .{ .label = name, .kind = if (is_function) 3 else 6, .detail = builtin_signature, .documentation = .{ .value = doc }, .textEdit = .{ .range = s.r(replace), .newText = insert }, .insertTextFormat = if (s.snippets) 2 else 1 });
            }
            for ([_][]const u8{ "let", "and", "in", "true", "false", "@contract", "@token" }) |name| if (matches(name, query)) try out.append(s.a, .{ .label = name, .kind = 14, .textEdit = .{ .range = s.r(replace), .newText = name } });
            if (c.trim(s.source).len == 0) for (p.field(s.language, "templates").array.items) |template| {
                const label = try p.string(p.field(template, "label"));
                try out.append(s.a, .{ .label = label, .kind = 15, .detail = "Chainwall interaction template", .documentation = .{ .value = try p.string(p.field(template, "description")) }, .textEdit = .{ .range = s.r(replace), .newText = try p.string(p.field(template, "source")) } });
            };
        }
        for (s.catalog.entries.items) |entry| {
            if (io_slot and !c.eq(u8, entry.kind, "contract") and !c.eq(u8, entry.kind, "token")) continue;
            if (interaction_slot and !c.eq(u8, entry.kind, "interaction")) continue;
            if (token_slot and !c.eq(u8, entry.kind, "token")) continue;
            if (!matches(entry.label, query) and !matches(entry.hash, query)) continue;
            const insert = if ((c.eq(u8, entry.kind, "token") or c.eq(u8, entry.kind, "contract")) and entry.path != null) try s.a.print("@{s}({s})", .{ entry.kind, entry.path.? }) else entry.hash;
            try out.append(s.a, try s.entryCompletion(entry, replace, insert));
            if (out.items.len >= 250) break;
        }
        return p.json(s.a, .{ .isIncomplete = out.items.len >= 250, .items = out.items });
    }
    fn entryCompletion(s: Context, entry: metadata.Entry, replace: text.Span, insert: []const u8) !Completion {
        return .{ .label = entry.label, .kind = if (c.eq(u8, entry.kind, "user")) 6 else 21, .detail = try s.a.print("{s} | chain {d} | {s}", .{ entry.kind, s.catalog.selection.chain, entry.hash }), .documentation = .{ .value = try s.entryDoc(entry) }, .filterText = try s.a.print("{s} {s}", .{ entry.label, entry.hash }), .textEdit = .{ .range = s.r(replace), .newText = insert } };
    }
    fn entryAt(s: Context, pos: usize) !?metadata.Entry {
        for (s.analysis.nodes.items) |node| if (node.tag == .registry_reference and text.contains(node.span, pos)) return s.catalog.reference(node.name, node.data);
        const token = text.at(s.tokens, pos) orelse return null;
        return if (token.kind == .number) s.catalog.find(token.text) else null;
    }
    pub fn hover(s: *Context, pos: usize) !c.Value {
        if (s.analysis.symbolAt(pos)) |index| {
            const symbol = s.analysis.symbols.items[index];
            const end = @min(symbol.value.span.end, s.source.len);
            const body = if (end >= symbol.value.span.start) c.trim(s.source[symbol.value.span.start..end]) else "";
            const ref = s.analysis.reference(symbol.value);
            const entry = if (ref) |n| try s.catalog.reference(n.name, n.data) else null;
            return p.json(s.a, .{ .contents = Markup{ .value = try s.a.print("```lambdascript\n{s} = {s}\n```{s}", .{ symbol.spelling, body, if (entry) |e| try s.a.print("\n\n{s}", .{try s.entryDoc(e)}) else "" }) }, .range = s.r((text.at(s.tokens, pos) orelse return .null).span) });
        }
        if (try s.entryAt(pos)) |entry| return p.json(s.a, .{ .contents = Markup{ .value = try s.entryDoc(entry) }, .range = s.r((text.at(s.tokens, pos) orelse return .null).span) });
        for (s.analysis.nodes.items) |node| if (node.tag == .member_call and text.contains(node.name_span, pos)) {
            const ref = s.analysis.reference(node.children[0]) orelse continue;
            const abi = s.catalog.abis.get(try c.id(s.a, ref.name)) orelse continue;
            var out: std.Io.Writer.Allocating = .init(s.a);
            for (abi.array.items) |item| if (function(item) and c.eq(u8, try p.string(p.field(item, "name")), node.spelling)) {
                const method = ms.abi.method(s.a, item) catch continue;
                try out.writer.print("```lambdascript\n{s}\n```\n\nSelector: `0x{x:0>8}`. Target: `{s}`.\n\n", .{ try methodLabel(s.a, item), method.selector, ref.name });
            };
            return p.json(s.a, .{ .contents = Markup{ .value = out.written() }, .range = s.r(node.name_span) });
        };
        const token = text.at(s.tokens, pos) orelse return .null;
        if (s.builtinVariable(token.text) and std.mem.startsWith(u8, token.text, "$arg")) return p.json(s.a, .{ .contents = Markup{ .value = try s.a.print("`{s}`: {s} argument {s}.", .{ token.text, if (s.catalog.selection.settings.argumentContext == .subject) "original interaction" else "program frame", token.text[4..] }) }, .range = s.r(token.span) });
        if (s.builtin(token.text)) |entry| return p.json(s.a, .{ .contents = Markup{ .value = try s.a.print("```lambdascript\n{s}\n```\n\n{s}", .{ try p.string(p.field(entry, "signature")), if (std.mem.startsWith(u8, token.text, "$arg")) try s.a.print("{s} argument {s}.", .{ if (s.catalog.selection.settings.argumentContext == .subject) "Original interaction" else "Program frame", token.text[4..] }) else try p.string(p.field(entry, "doc")) }) }, .range = s.r(token.span) });
        return .null;
    }
    pub fn signature(s: *Context, pos: usize) !c.Value {
        const call = syntax.callAt(s.tokens, pos) orelse return .null;
        const analysis = try syntax.context(s.a, s.source, pos);
        const node = analysis.namedAt(call.name.span.start);
        var signatures = std.json.Array.init(s.a);
        if (node != null and node.?.tag == .member_call) {
            const ref = analysis.reference(node.?.children[0]) orelse return .null;
            const abi = s.catalog.abis.get(try c.id(s.a, ref.name)) orelse return .null;
            for (abi.array.items) |item| if (function(item) and c.eq(u8, try p.string(p.field(item, "name")), call.name.text)) {
                _ = ms.abi.method(s.a, item) catch continue;
                var parameters = std.json.Array.init(s.a);
                for (p.field(item, "inputs").array.items) |param| try parameters.append(try p.json(s.a, .{ .label = try s.a.print("{s} {s}", .{ try surface.annotation(s.a, param), p.string(p.field(param, "name")) catch "" }) }));
                try signatures.append(try p.json(s.a, .{ .label = try methodLabel(s.a, item), .parameters = parameters.items, .activeParameter = @min(call.argument, parameters.items.len -| 1) }));
            };
        } else if (s.builtin(call.name.text)) |entry| {
            const label = try p.string(p.field(entry, "signature"));
            var parameters = std.json.Array.init(s.a);
            if (std.mem.indexOfScalar(u8, label, '(')) |open| if (std.mem.indexOfScalarPos(u8, label, open, ')')) |close| {
                var parts = std.mem.splitSequence(u8, label[open + 1 .. close], ", ");
                while (parts.next()) |part| if (part.len > 0) try parameters.append(try p.json(s.a, .{ .label = part }));
            };
            try signatures.append(try p.json(s.a, .{ .label = label, .documentation = Markup{ .value = try p.string(p.field(entry, "doc")) }, .parameters = parameters.items, .activeParameter = @min(call.argument, parameters.items.len -| 1) }));
        }
        if (signatures.items.len == 0) return .null;
        return p.json(s.a, .{ .signatures = signatures.items, .activeSignature = 0, .activeParameter = p.field(signatures.items[0], "activeParameter") });
    }
    pub fn definition(s: Context, pos: usize) !c.Value {
        if (s.analysis.symbolAt(pos)) |index| return p.json(s.a, .{ .uri = s.uri, .range = s.r(s.analysis.symbols.items[index].span) });
        if (try s.entryAt(pos)) |entry| return p.json(s.a, try s.catalog.location(s.io, entry));
        return .null;
    }
    pub fn references(s: Context, pos: usize, declarations: bool, highlights: bool) !c.Value {
        var result = std.json.Array.init(s.a);
        const index = s.analysis.symbolAt(pos);
        if (index) |i| {
            if (declarations) try result.append(if (highlights) try p.json(s.a, .{ .range = s.r(s.analysis.symbols.items[i].span), .kind = 3 }) else try p.json(s.a, .{ .uri = s.uri, .range = s.r(s.analysis.symbols.items[i].span) }));
            for (s.analysis.uses.items) |use| if (use.symbol == index and use.node.name_span.end > use.node.name_span.start) try result.append(if (highlights) try p.json(s.a, .{ .range = s.r(use.node.name_span), .kind = 2 }) else try p.json(s.a, .{ .uri = s.uri, .range = s.r(use.node.name_span) }));
        } else if (try s.entryAt(pos)) |entry| {
            for (s.analysis.nodes.items) |node| if ((node.tag == .registry_reference and c.eq(u8, try c.id(s.a, node.name), entry.hash)) or (node.tag == .number and node.value == try c.word(entry.hash))) {
                try result.append(if (highlights) try p.json(s.a, .{ .range = s.r(node.span), .kind = 2 }) else try p.json(s.a, .{ .uri = s.uri, .range = s.r(node.span) }));
            };
        }
        return .{ .array = result };
    }
    pub fn prepareRename(s: Context, pos: usize) !c.Value {
        if (s.analysis.failure != null) return .null;
        const index = s.analysis.symbolAt(pos) orelse return .null;
        const token = text.at(s.tokens, pos) orelse return .null;
        return p.json(s.a, .{ .range = s.r(token.span), .placeholder = s.analysis.symbols.items[index].spelling });
    }
    pub fn rename(s: Context, pos: usize, name: []const u8) !c.Value {
        if (s.analysis.failure != null) return error.InvalidSource;
        const index = s.analysis.symbolAt(pos) orelse return error.NotALocalBinding;
        if (!text.identifier(name) or text.keyword(name) or s.builtin(name) != null or std.mem.startsWith(u8, name, "$")) return error.InvalidBindingName;
        // Reject capture, including forward global references. A conservative
        // collision check also avoids changing meaning inside nested scopes.
        for (s.analysis.symbols.items, 0..) |symbol, i| if (i != index and std.ascii.eqlIgnoreCase(symbol.name, name)) return error.RenameWouldCaptureBinding;
        for (s.analysis.uses.items) |use| if (use.symbol == null and std.ascii.eqlIgnoreCase(use.node.name, name)) return error.RenameWouldCaptureBinding;
        var edits: std.ArrayList(text.Edit) = .empty;
        try edits.append(s.a, .{ .range = s.r(s.analysis.symbols.items[index].span), .newText = name });
        for (s.analysis.uses.items) |use| if (use.symbol == index and use.node.name_span.end > use.node.name_span.start) try edits.append(s.a, .{ .range = s.r(use.node.name_span), .newText = name });
        return s.workspaceEdit(edits.items);
    }
    fn workspaceEdit(s: Context, edits: []const text.Edit) !c.Value {
        if (s.versioned_edits) return p.json(s.a, .{ .documentChanges = .{.{ .textDocument = .{ .uri = s.uri, .version = s.version }, .edits = edits }} });
        var changes: std.json.ObjectMap = .empty;
        try changes.put(s.a, s.uri, try p.json(s.a, edits));
        return p.json(s.a, .{ .changes = c.Value{ .object = changes } });
    }
    pub fn symbols(s: Context) !c.Value {
        var result = std.json.Array.init(s.a);
        for (s.analysis.symbols.items) |symbol| try result.append(try p.json(s.a, .{ .name = symbol.spelling, .detail = if (s.analysis.reference(symbol.value)) |ref| ref.name else "local binding", .kind = 13, .range = s.r(.{ .start = symbol.span.start, .end = @max(symbol.span.end, symbol.value.span.end) }), .selectionRange = s.r(symbol.span) }));
        return .{ .array = result };
    }
    pub fn semanticTokens(s: Context) !c.Value {
        var data: std.ArrayList(usize) = .empty;
        var previous: text.Position = .{ .line = 0, .character = 0 };
        for (s.tokens, 0..) |token, i| {
            const r_ = s.r(token.span);
            if (r_.start.line != r_.end.line or r_.end.character <= r_.start.character) continue;
            var kind: usize = switch (token.kind) {
                .number => 3,
                .string => 4,
                .reference => 7,
                .symbol => 5,
                .identifier => if (text.keyword(token.text)) 2 else if (i + 1 < s.tokens.len and (c.eq(u8, s.tokens[i + 1].text, "(") or c.eq(u8, s.tokens[i + 1].text, "{"))) 1 else if (i > 0 and c.eq(u8, s.tokens[i - 1].text, "::")) 6 else 0,
            };
            var modifiers: usize = 0;
            for (s.analysis.symbols.items) |symbol| if (symbol.span.start == token.span.start and symbol.span.end == token.span.end) {
                modifiers = 3;
                kind = 0;
            };
            if (s.builtin(token.text) != null) modifiers |= 4;
            try data.appendSlice(s.a, &.{ r_.start.line - previous.line, if (r_.start.line == previous.line) r_.start.character - previous.character else r_.start.character, r_.end.character - r_.start.character, kind, modifiers });
            previous = r_.start;
        }
        return p.json(s.a, .{ .data = data.items });
    }
    pub fn folding(s: Context) !c.Value {
        var result = std.json.Array.init(s.a);
        var stack: std.ArrayList(text.Token) = .empty;
        for (s.tokens) |token| {
            if (token.kind != .symbol or token.text.len != 1) continue;
            if (std.mem.indexOfScalar(u8, "([{", token.text[0]) != null) try stack.append(s.a, token) else if (std.mem.indexOfScalar(u8, ")]}", token.text[0]) != null and stack.items.len > 0) {
                const open = stack.pop().?;
                const start = text.position(s.source, open.span.start, s.encoding);
                const end = text.position(s.source, token.span.start, s.encoding);
                if (end.line > start.line + 1) try result.append(try p.json(s.a, .{ .startLine = start.line, .endLine = end.line - 1, .kind = "region" }));
            }
        }
        return .{ .array = result };
    }
    pub fn selections(s: Context, positions: c.Value) !c.Value {
        if (positions != .array) return error.InvalidParams;
        var result = std.json.Array.init(s.a);
        for (positions.array.items) |position_| {
            const pos = try text.offset(s.source, position_, s.encoding);
            var spans: std.ArrayList(text.Span) = .empty;
            try spans.append(s.a, .{ .end = s.source.len });
            for (s.analysis.nodes.items) |node| if (text.contains(node.span, pos) and node.span.end <= s.source.len) try spans.append(s.a, node.span);
            if (text.at(s.tokens, pos)) |token| try spans.append(s.a, token.span);
            std.mem.sort(text.Span, spans.items, {}, struct {
                fn less(_: void, lhs: text.Span, rhs: text.Span) bool {
                    return lhs.end - lhs.start > rhs.end - rhs.start;
                }
            }.less);
            var parent: c.Value = .null;
            var previous: ?text.Span = null;
            for (spans.items) |span| {
                if (previous) |prev| if (span.start < prev.start or span.end > prev.end or (span.start == prev.start and span.end == prev.end)) continue;
                parent = try p.json(s.a, .{ .range = s.r(span), .parent = if (parent == .null) @as(?c.Value, null) else parent });
                previous = span;
            }
            try result.append(parent);
        }
        return .{ .array = result };
    }
    pub fn inlays(s: *Context, requested: c.Value) !c.Value {
        var result = std.json.Array.init(s.a);
        if (s.analysis.surface == null) return .{ .array = result };
        _ = s.analysis.surface.?.preprocess(try s.catalog.toSnapshot(), s.catalog.selection.settings) catch |err| blk: {
            if (err == error.OutOfMemory) return err;
            break :blk "";
        };
        const start = try text.offset(s.source, p.field(requested, "start"), s.encoding);
        const end = try text.offset(s.source, p.field(requested, "end"), s.encoding);
        for (s.analysis.nodes.items) |node| if (node.tag == .member_call) {
            const selected = s.analysis.surface.?.selected.get(node) orelse continue;
            const ref = s.analysis.reference(node.children[0]) orelse continue;
            const abi = s.catalog.abis.get(try c.id(s.a, ref.name)) orelse continue;
            for (abi.array.items) |item| {
                if (!function(item)) continue;
                const method = ms.abi.method(s.a, item) catch continue;
                if (method.selector != selected.selector) continue;
                const args = node.children[1 .. node.children.len - @intFromBool(node.payable)];
                for (args, p.field(item, "inputs").array.items) |arg, param| {
                    const name = p.string(p.field(param, "name")) catch continue;
                    if (name.len == 0 or arg.span.start < start or arg.span.start > end or (arg.tag == .variable and std.ascii.eqlIgnoreCase(arg.name, name))) continue;
                    try result.append(try p.json(s.a, .{ .position = text.position(s.source, arg.span.start, s.encoding), .label = try s.a.print("{s}:", .{name}), .kind = 2, .paddingRight = true, .tooltip = Markup{ .value = try surface.annotation(s.a, param) } }));
                }
            }
        };
        return .{ .array = result };
    }
    pub fn codeLenses(s: *Context) !c.Value {
        const artifact = s.compile() catch |err| {
            if (err == error.OutOfMemory) return err;
            return p.json(s.a, &[_]c.Value{});
        };
        const bytes = (try p.string(p.field(artifact, "bytecode"))).len / 2 - 1;
        const count = try c.scalar(s.a, p.field(p.field(artifact, "references"), "rawCount"));
        return p.json(s.a, .{.{ .range = s.r(.{}), .command = .{ .title = try s.a.print("{d} bytes | {s} references | compiler JSON", .{ bytes, count }), .command = "chainwall.showCompiled", .arguments = .{s.uri} } }});
    }
    pub fn actions(s: *Context, requested: c.Value) !c.Value {
        var result = std.json.Array.init(s.a);
        const start = try text.offset(s.source, p.field(requested, "start"), s.encoding);
        const end = try text.offset(s.source, p.field(requested, "end"), s.encoding);
        for (s.analysis.nodes.items) |node| if (node.tag == .registry_reference and node.span.end >= start and node.span.start <= end) {
            const hash = try c.id(s.a, node.name);
            if (!s.catalog.abis.contains(hash)) try result.append(try p.json(s.a, .{ .title = try s.a.print("Fetch ABI for {s}", .{node.name}), .kind = "quickfix", .command = .{ .title = "Fetch target ABI", .command = "chainwall.fetchAbi", .arguments = .{ s.uri, hash } } }));
            const wrong_kind = if (node.data) "contract" else "token";
            if (s.catalog.known.get(hash)) |kind| if (c.eq(u8, try p.string(kind), wrong_kind)) {
                const edit = try s.workspaceEdit(&.{.{ .range = s.r(node.span), .newText = try s.a.print("@{s}({s})", .{ wrong_kind, node.name }) }});
                try result.append(try p.json(s.a, .{ .title = try s.a.print("Use @{s} for {s}", .{ wrong_kind, node.name }), .kind = "quickfix", .edit = edit }));
            };
        };
        try result.append(try p.json(s.a, .{ .title = "Refresh Chainwall catalog", .kind = "source", .command = .{ .title = "Refresh Chainwall catalog", .command = "chainwall.refresh", .arguments = .{s.uri} } }));
        try result.append(try p.json(s.a, .{ .title = "Open compiled Chainwall program JSON", .kind = "source", .command = .{ .title = "Open compiled Chainwall program JSON", .command = "chainwall.showCompiled", .arguments = .{s.uri} } }));
        return .{ .array = result };
    }
    fn entryDoc(s: Context, entry: metadata.Entry) ![]const u8 {
        return s.a.print("**{s}** ({s})\n\nID: `{s}`\n\nChain: {d}\n\nRegistry: `{s}`\n\nAddress: `{s}`\n\nCached Registry metadata.\n\n```json\n{s}\n```", .{ entry.label, entry.kind, entry.hash, s.catalog.selection.chain, s.catalog.selection.instance, entry.address orelse "unavailable", try c.encode(s.a, entry.record) });
    }
    fn methodCompletion(s: Context, item: c.Value, abi: c.Value, replace: text.Span, existing: ?*Node) !?Completion {
        const method = ms.abi.method(s.a, item) catch return null;
        const name = try p.string(p.field(item, "name"));
        if (!text.identifier(name)) return null;
        const inputs = p.field(item, "inputs").array.items;
        var overloaded = false;
        for (abi.array.items) |other| if (function(other) and c.eq(u8, try p.string(p.field(other, "name")), name) and p.field(other, "inputs") == .array and p.field(other, "inputs").array.items.len == inputs.len) {
            const candidate = ms.abi.method(s.a, other) catch continue;
            if (!c.eq(u8, candidate.signature, method.signature)) overloaded = true;
        };
        var edits: std.ArrayList(text.Edit) = .empty;
        const after = std.mem.trimStart(u8, s.source[replace.end..], " \t\r\n");
        const has_arguments = std.mem.startsWith(u8, after, "(") or std.mem.startsWith(u8, after, "{");
        var replacement = replace;
        var fill = !has_arguments;
        var options: ?[]const u8 = null;
        if (has_arguments and existing != null and existing.?.tag == .member_call) {
            const node = existing.?;
            const args = node.children[1 .. node.children.len - @intFromBool(node.payable)];
            if (node.payable and method.mutability != .payable) return null;
            fill = s.snippets and args.len == 0 and (inputs.len > 0 or method.mutability == .payable);
            if (fill) {
                replacement.end = node.span.end;
                if (node.payable) {
                    const open = std.mem.indexOfScalarPos(u8, s.source, node.children[node.children.len - 1].span.end, '(') orelse return null;
                    options = s.source[replace.end..open];
                }
            } else if (args.len != inputs.len) return null;
            if (!fill and overloaded) for (args, inputs) |arg, input| {
                const annotation = try surface.annotation(s.a, input);
                if (arg.type_hint) |hint| {
                    if (!c.eq(u8, hint, annotation)) return null;
                } else if (arg.span.end <= s.source.len and arg.span.end > arg.span.start) try edits.append(s.a, .{ .range = s.r(arg.span), .newText = try s.a.print("({s}) :: {s}", .{ c.trim(s.source[arg.span.start..arg.span.end]), annotation }) });
            };
        }
        var insert: []const u8 = name;
        if (fill and s.snippets) {
            var out: std.Io.Writer.Allocating = .init(s.a);
            try out.writer.writeAll(try snippetEscape(s.a, name));
            var index: usize = 1;
            if (options) |value| {
                try out.writer.writeAll(try snippetEscape(s.a, value));
            } else if (method.mutability == .payable) {
                try out.writer.writeAll("{value: ${1:nativeValue}}");
                index += 1;
            }
            try out.writer.writeByte('(');
            for (inputs, method.root.children, 0..) |input, schema, i| {
                if (i > 0) try out.writer.writeAll(", ");
                const label = p.string(p.field(input, "name")) catch "";
                const raw = if (text.identifier(label)) label else "value";
                try argumentSnippet(s.a, &out.writer, schema, input, raw, &index);
                if (overloaded) try out.writer.print(" :: {s}", .{try snippetEscape(s.a, try surface.annotation(s.a, input))});
            }
            try out.writer.writeAll(")$0");
            insert = try out.toOwnedSlice();
        }
        return .{ .label = method.signature, .kind = 2, .detail = try methodLabel(s.a, item), .documentation = .{ .value = try s.a.print("Selector `0x{x:0>8}`. {s}.{s}", .{ method.selector, @tagName(method.mutability), if (method.mutability == .payable) " Requires an explicit native value." else "" }) }, .filterText = name, .textEdit = .{ .range = s.r(replacement), .newText = insert }, .insertTextFormat = if (s.snippets and fill) 2 else 1, .additionalTextEdits = if (edits.items.len > 0) edits.items else null };
    }
};

fn function(item: c.Value) bool {
    return c.eq(u8, p.string(p.field(item, "type")) catch "", "function");
}
fn argumentSnippet(a: c.A, out: *std.Io.Writer, schema: *const ms.abi.Schema, input: c.Value, label: []const u8, index: *usize) anyerror!void {
    switch (schema.kind) {
        .tuple => {
            try out.writeByte('{');
            for (schema.children, p.field(input, "components").array.items, 0..) |child, component, i| {
                if (i > 0) try out.writeAll(", ");
                const name = p.string(p.field(component, "name")) catch "value";
                try argumentSnippet(a, out, child, component, if (text.identifier(name)) name else "value", index);
            }
            try out.writeAll("\\}");
        },
        // Keep arrays bounded in the completion item. The selected placeholder
        // is editable; fixed array size and recursive shape appear in the type.
        .fixed_array, .dynamic_array => {
            try out.print("[${{{d}:{s}}}]", .{ index.*, try snippetEscape(a, label) });
            index.* += 1;
        },
        else => {
            try out.print("${{{d}:{s}}}", .{ index.*, try snippetEscape(a, label) });
            index.* += 1;
        },
    }
}
fn matches(label: []const u8, query: []const u8) bool {
    if (query.len > label.len) return false;
    for (0..label.len - query.len + 1) |i| if (std.ascii.eqlIgnoreCase(label[i .. i + query.len], query)) return true;
    return false;
}
fn snippetEscape(a: c.A, source: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (source) |ch| {
        if (ch == '$' or ch == '}' or ch == '\\') try out.append(a, '\\');
        try out.append(a, ch);
    }
    return out.toOwnedSlice(a);
}
fn builtinSnippet(a: c.A, name: []const u8, signature: []const u8) ![]const u8 {
    const open = std.mem.indexOfScalar(u8, signature, '(') orelse return snippetEscape(a, name);
    const close = std.mem.indexOfScalarPos(u8, signature, open, ')') orelse return snippetEscape(a, name);
    var out: std.Io.Writer.Allocating = .init(a);
    try out.writer.print("{s}(", .{try snippetEscape(a, name)});
    var parts = std.mem.splitSequence(u8, signature[open + 1 .. close], ", ");
    var index: usize = 1;
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.endsWith(u8, part, "?")) continue;
        if (index > 1) try out.writer.writeAll(", ");
        try out.writer.print("${{{d}:{s}}}", .{ index, try snippetEscape(a, part) });
        index += 1;
    }
    try out.writer.writeAll(")$0");
    return out.toOwnedSlice();
}
fn methodLabel(a: c.A, item: c.Value) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try out.writer.print("{s}(", .{try p.string(p.field(item, "name"))});
    for (p.field(item, "inputs").array.items, 0..) |param, i| {
        if (i > 0) try out.writer.writeAll(", ");
        try out.writer.print("{s} {s}", .{ try surface.annotation(a, param), p.string(p.field(param, "name")) catch "" });
    }
    try out.writer.print(") {s}", .{p.string(p.field(item, "stateMutability")) catch "nonpayable"});
    return out.toOwnedSlice();
}
pub fn message(err: anyerror) []const u8 {
    return switch (err) {
        error.ConfigDirectoryRequiresStartupOption => "Set the profile directory with --config-dir or CHAINWALL_CONFIG_DIR at server startup; remove configDir from LSP and workspace settings.",
        error.Syntax => "Expected a Lambdascript expression or matching delimiter.",
        error.InvalidConstant => "Constant is outside the supported exact integer range.",
        error.UnboundVariable => "Unknown variable or unsupported builtin.",
        error.DuplicateBinding => "A binding with this name already exists in this scope (names are case-insensitive).",
        error.CyclicDefinition => "Bindings form a dependency cycle.",
        error.InvalidType => "This expression's result type does not match its use.",
        error.InvalidArguments => "Arguments do not match this operation's supported form.",
        error.MissingAbi => "ABI unavailable. Fetch the target ABI, configure an ABI file, or supply a compiler snapshot.",
        error.UnknownAbiMethod => "The target ABI has no method with this name.",
        error.AbiArgumentArity => "The argument count does not match a method in the target ABI.",
        error.IncompatibleAbiArgument => "Arguments do not match an ABI overload. Check types and tuple/array shapes.",
        error.AmbiguousAbiOverloadAddTypeAnnotation => "Ambiguous ABI overload. Add exact argument annotations, for example $arg0 :: uint256.",
        error.PayableCallRequiresValue => "This payable method requires {value: nativeAmount} before its arguments.",
        error.NonpayableCallValue => "Native value is only accepted by payable ABI methods.",
        error.RegistryKindMismatch => "This Registry path exists with a different kind. Check @token versus @contract.",
        error.UnknownRegistryReference => "Registry reference is absent from the selected catalog.",
        error.UnsupportedRegistryReferenceContext => "Use Registry references as ABI arguments/receivers, IO targets, price targets, or with $address.",
        error.NonStaticMemberReceiver => "ABI method receivers must resolve to a static @contract or @token reference.",
        error.StackCapacity, error.ResourceLimit, error.SourceTooLarge => "Program exceeds the compiler's resource limits.",
        else => @errorName(err),
    };
}
