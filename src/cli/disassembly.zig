const std = @import("std");
const ms = @import("miniscript");
const c = @import("common.zig");
const surface = @import("surface.zig");
const Node = ms.tree.Node;

pub const Metadata = struct {
    a: c.A,
    references: std.json.ObjectMap = .empty,
    known: std.json.ObjectMap = .empty,
    abis: std.json.ObjectMap = .empty,
    partial_abis: std.StringHashMapUnmanaged(void) = .empty,

    pub fn reference(m: *Metadata, raw_hash: []const u8, kind: []const u8, path: []const u8) !void {
        if (!c.eq(u8, kind, "token") and !c.eq(u8, kind, "contract")) return error.InvalidRegistryReference;
        const slash = std.mem.indexOfScalar(u8, path, '/') orelse return error.InvalidRegistryReference;
        if (slash == 0 or slash + 1 == path.len or std.mem.indexOfScalarPos(u8, path, slash + 1, '/') != null) return error.InvalidRegistryReference;
        for (path) |ch| if (ch <= 32 or ch >= 127 or std.ascii.isUpper(ch) or std.mem.indexOfScalar(u8, "(){}[]\"'\\", ch) != null) return error.InvalidRegistryReference;
        const hash = try c.id(m.a, raw_hash);
        if (!c.eq(u8, hash, try c.hex(m.a, ms.bytecode.hash(path)))) return error.RegistryPathHashMismatch;
        const previous = m.known.get(hash);
        try m.known.put(m.a, hash, .{ .string = if (previous != null and !c.eq(u8, try c.string(previous.?), kind)) "contract+token" else kind });
        // As in the app, prefer token syntax for records of both kinds.
        if (m.references.get(hash)) |ref| if (c.eq(u8, try c.string(c.field(ref, "kind").?), "token")) return;
        try m.references.put(m.a, hash, try c.parse(m.a, try c.encode(m.a, .{ .kind = kind, .path = path })));
    }
    pub fn merge(m: *Metadata, input: c.Value) !void {
        if (input == .null) return;
        if (input != .object) return error.InvalidSnapshot;
        if (c.field(input, "knownKindsByTargetHash")) |known| {
            if (known != .object) return error.InvalidSnapshot;
            for (known.object.keys(), known.object.values()) |hash, kind| {
                const name = try c.string(kind);
                if (!c.eq(u8, name, "token") and !c.eq(u8, name, "contract") and !c.eq(u8, name, "contract+token")) return error.InvalidRegistryReference;
                try m.known.put(m.a, try c.id(m.a, hash), kind);
            }
        }
        if (c.field(input, "registryReferencesByTargetHash")) |refs| {
            if (refs != .object) return error.InvalidSnapshot;
            for (refs.object.keys(), refs.object.values()) |hash, ref| {
                if (ref == .null) continue;
                try m.reference(hash, try c.string(c.field(ref, "kind") orelse return error.InvalidRegistryReference), try c.string(c.field(ref, "path") orelse return error.InvalidRegistryReference));
            }
        }
        // Accept the named offline catalog already used by chainwall-lsp.
        if (c.field(input, "entries")) |entries| {
            if (entries != .array) return error.InvalidSnapshot;
            for (entries.array.items) |entry| {
                const kind = c.string(c.field(entry, "kind") orelse continue) catch continue;
                if (!c.eq(u8, kind, "token") and !c.eq(u8, kind, "contract")) continue;
                const path = try c.string(c.field(entry, "path") orelse continue);
                const hash = if (c.field(entry, "hash")) |value| try c.string(value) else try c.id(m.a, path);
                try m.reference(hash, kind, path);
            }
        }
        if (c.field(input, "abiByTargetHash")) |abis| {
            if (abis != .object) return error.InvalidSnapshot;
            for (abis.object.keys(), abis.object.values()) |hash, value| {
                if (value != .array) return error.InvalidAbi;
                try m.abis.put(m.a, try c.id(m.a, hash), value);
            }
        }
    }
    pub fn snapshot(m: Metadata) !c.Value {
        var object: std.json.ObjectMap = .empty;
        try object.put(m.a, "knownKindsByTargetHash", .{ .object = m.known });
        try object.put(m.a, "abiByTargetHash", .{ .object = m.abis });
        try object.put(m.a, "registryReferencesByTargetHash", .{ .object = m.references });
        return .{ .object = object };
    }
    pub fn settings(m: Metadata, defaults: ms.Settings) !ms.Settings {
        var loader = try surface.Surface.parse(m.a, "$noOp");
        _ = try loader.preprocess(try m.snapshot(), defaults);
        return loader.settings;
    }
    fn addSettings(m: *Metadata, defaults: ms.Settings) !void {
        const methods = defaults.abiFunctionsByCallKey orelse return;
        if (methods != .object) return error.InvalidSettings;
        for (methods.object.keys(), methods.object.values()) |key, method| {
            const colon = std.mem.indexOfScalar(u8, key, ':') orelse return error.InvalidSettings;
            const hash = try c.id(m.a, key[0..colon]);
            if (m.abis.contains(hash) and !m.partial_abis.contains(hash)) continue;
            var items = m.abis.get(hash) orelse c.Value{ .array = std.json.Array.init(m.a) };
            try items.array.append(method);
            try m.abis.put(m.a, hash, items);
            try m.partial_abis.put(m.a, hash, {});
        }
    }
};

const Renderer = struct {
    a: c.A,
    source: []const u8,
    metadata: Metadata,
    settings: ms.Settings,

    fn reference(r: Renderer, n: *Node) !?[]const u8 {
        if (n.tag != .number or n.negative) return null;
        const ref = r.metadata.references.get(try c.hex(r.a, n.value)) orelse return null;
        return try r.a.print("@{s}({s})", .{ try c.string(c.field(ref, "kind").?), try c.string(c.field(ref, "path").?) });
    }
    fn value(r: Renderer, n: *Node, schema: *ms.abi.Schema) anyerror![]const u8 {
        if (schema.kind == .address) {
            const candidate = if (n.tag == .application and c.eq(u8, n.name, "$address") and n.children.len == 1) n.children[0] else n;
            if (try r.reference(candidate)) |name| return name;
        } else if (schema.kind == .fixed_bytes and schema.width == 32) {
            if (try r.reference(n)) |name| return name;
        }
        if ((schema.kind == .tuple and n.tag == .tuple and n.children.len == schema.children.len) or ((schema.kind == .fixed_array or schema.kind == .dynamic_array) and n.tag == .list)) {
            var children: std.ArrayList([]const u8) = .empty;
            for (n.children, 0..) |child, i| try children.append(r.a, try r.value(child, schema.children[if (schema.kind == .tuple) i else 0]));
            return r.a.print("{s}{s}{s}", .{ if (n.tag == .tuple) "{" else "[", try std.mem.join(r.a, ", ", children.items), if (n.tag == .tuple) "}" else "]" });
        }
        return r.render(n);
    }
    fn ioCall(r: Renderer, n: *Node) anyerror!?[]const u8 {
        if (n.children.len < 2 or n.children[0].tag != .number or n.children[1].tag != .number) return null;
        const target = (try r.reference(n.children[0])) orelse return null;
        const methods = r.settings.abiFunctionsByCallKey orelse return null;
        const item = c.field(methods, try ms.abi.key(r.a, n.children[0].value, n.children[1].value)) orelse return null;
        const method = try ms.abi.method(r.a, item);
        const read = c.eq(u8, n.name, "$read");
        if (read != (method.mutability == .view or method.mutability == .pure)) return null;
        const payable = method.mutability == .payable;
        const tuple = if (n.children.len >= 3) n.children[2] else null;
        const args: []const *Node = if (tuple) |node| if (node.tag == .tuple or node.tag == .object) node.children else return null else &.{};
        if (args.len != method.root.children.len or n.children.len != 2 + @as(usize, @intFromBool(tuple != null)) + @as(usize, @intFromBool(payable))) return null;
        const name = try c.string(c.field(item, "name").?);
        if (name.len == 0 or (!std.ascii.isAlphabetic(name[0]) and name[0] != '_')) return null;
        for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_') return null;
        const inputs = c.field(item, "inputs").?.array.items;
        var overloads: usize = 0;
        if (r.metadata.abis.get(try c.hex(r.a, n.children[0].value))) |full| {
            for (full.array.items) |candidate| if (c.eq(u8, c.string(c.field(candidate, "type") orelse .null) catch "", "function") and c.eq(u8, c.string(c.field(candidate, "name") orelse .null) catch "", name)) {
                overloads += 1;
            };
        }
        if (r.metadata.partial_abis.contains(try c.hex(r.a, n.children[0].value))) overloads = 0;
        var rendered: std.ArrayList([]const u8) = .empty;
        for (args, method.root.children, inputs) |arg, schema, param| {
            const text = try r.value(arg, schema);
            try rendered.append(r.a, if (overloads != 1) try r.a.print("({s}) :: {s}", .{ text, try surface.annotation(r.a, param) }) else text);
        }
        const payment = if (payable) try r.a.print("{{value: {s}}}", .{try r.render(n.children[n.children.len - 1])}) else "";
        return try r.a.print("{s}.{s}{s}({s})", .{ target, name, payment, try std.mem.join(r.a, ", ", rendered.items) });
    }
    fn render(r: Renderer, n: *Node) anyerror![]const u8 {
        if (n.tag == .application and (c.eq(u8, n.name, "$read") or c.eq(u8, n.name, "$write"))) {
            if (try r.ioCall(n)) |text| return text;
        }
        var out: std.Io.Writer.Allocating = .init(r.a);
        var cursor = n.span.start;
        for (n.children, 0..) |child, i| {
            // Source spans retain operators, parentheses, locals and ABI tapes.
            // Rewrite only proven IO/reference positions, never arbitrary words.
            if (child.span.start < cursor or child.span.end > n.span.end) return error.InvalidSourceSpan;
            try out.writer.writeAll(r.source[cursor..child.span.start]);
            const reference_slot = i == 0 and n.tag == .application and (c.eq(u8, n.name, "$address") or c.eq(u8, n.name, "$read") or c.eq(u8, n.name, "$readwords") or c.eq(u8, n.name, "$write") or c.eq(u8, n.name, "$price") or c.eq(u8, n.name, "$valueusd"));
            const ref = if (reference_slot) try r.reference(child) else null;
            try out.writer.writeAll(ref orelse try r.render(child));
            cursor = child.span.end;
        }
        try out.writer.writeAll(r.source[cursor..n.span.end]);
        return out.toOwnedSlice();
    }
};

pub const Result = struct { source: []const u8, restored: bool };

fn identifier(a: c.A, path: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var upper = false;
    for (path) |ch| {
        if (!std.ascii.isAlphanumeric(ch)) {
            upper = out.items.len > 0;
            continue;
        }
        if (out.items.len == 0 and std.ascii.isDigit(ch)) try out.appendSlice(a, "ref");
        try out.append(a, if (upper) std.ascii.toUpper(ch) else std.ascii.toLower(ch));
        upper = false;
    }
    return if (out.items.len == 0) "reference" else out.toOwnedSlice(a);
}
fn reserved(name: []const u8) bool {
    for ([_][]const u8{ "and", "else", "false", "if", "in", "let", "then", "true" }) |word| if (std.ascii.eqlIgnoreCase(name, word)) return true;
    for ([_][]const u8{ "address", "const", "contract", "shared" }) |prefix| {
        if (std.mem.startsWith(u8, name, prefix) and name.len > prefix.len) {
            _ = std.fmt.parseInt(u64, name[prefix.len..], 10) catch continue;
            return true;
        }
    }
    return false;
}

/// Give method targets and repeated Registry
/// references readable aliases, avoiding keywords and existing local bindings.
fn aliases(a: c.A, source: []const u8) ![]const u8 {
    const tokens = try ms.syntax.tokens(a, source);
    const Candidate = struct { count: usize = 0, target: bool = false, name: ?[]const u8 = null };
    var candidates: std.StringArrayHashMapUnmanaged(Candidate) = .empty;
    var used: std.StringHashMapUnmanaged(void) = .empty;
    for (tokens, 0..) |token, i| {
        if (token.kind == .identifier) try used.put(a, try std.ascii.allocLowerString(a, token.text), {});
        if (token.kind != .reference) continue;
        const entry = try candidates.getOrPut(a, token.text);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        entry.value_ptr.count += 1;
        const io_target = i >= 2 and c.eq(u8, tokens[i - 1].text, "(") and (std.ascii.eqlIgnoreCase(tokens[i - 2].text, "$read") or std.ascii.eqlIgnoreCase(tokens[i - 2].text, "$write") or std.ascii.eqlIgnoreCase(tokens[i - 2].text, "$readWords"));
        if (io_target or (i + 1 < tokens.len and c.eq(u8, tokens[i + 1].text, "."))) entry.value_ptr.target = true;
    }
    var out: std.Io.Writer.Allocating = .init(a);
    var count: usize = 0;
    for (candidates.keys(), candidates.values()) |reference, *candidate| {
        if (candidate.count < 2 and !candidate.target) continue;
        const start = (std.mem.indexOfScalar(u8, reference, '(') orelse continue) + 1;
        const path = reference[start .. reference.len - 1];
        const slash = std.mem.indexOfScalar(u8, path, '/') orelse continue;
        const short = try identifier(a, path[slash + 1 ..]);
        const full = try identifier(a, path);
        var name = short;
        if (reserved(name) or used.contains(try std.ascii.allocLowerString(a, name))) name = full;
        var suffix: usize = 2;
        while (reserved(name) or used.contains(try std.ascii.allocLowerString(a, name))) : (suffix += 1) name = try a.print("{s}{d}", .{ full, suffix });
        try used.put(a, try std.ascii.allocLowerString(a, name), {});
        candidate.name = name;
        try out.writer.print("{s} {s} = {s}\n", .{ if (count == 0) "let" else "and", name, reference });
        count += 1;
    }
    if (count == 0) return source;
    var cursor: usize = 0;
    if (tokens.len > 0 and c.eq(u8, tokens[0].text, "let")) {
        try out.writer.writeAll("and");
        cursor = tokens[0].span.end;
    } else try out.writer.writeAll("in ");
    for (tokens) |token| {
        if (token.kind != .reference) continue;
        const name = candidates.get(token.text).?.name orelse continue;
        try out.writer.writeAll(source[cursor..token.span.start]);
        try out.writer.writeAll(name);
        cursor = token.span.end;
    }
    try out.writer.writeAll(source[cursor..]);
    return out.toOwnedSlice();
}

pub fn decompile(a: c.A, bytes: []const u8, defaults: ms.Settings, input_metadata: Metadata) !Result {
    var metadata = input_metadata;
    try metadata.addSettings(defaults);
    const settings = try metadata.settings(defaults);
    const core = try ms.decompile(a, bytes, settings);
    if (metadata.references.count() == 0) return .{ .source = try ms.syntax.format(a, core, 2), .restored = false };
    var parsed = try surface.Surface.parse(a, core);
    const renderer: Renderer = .{ .a = a, .source = core, .metadata = metadata, .settings = settings };
    var out: std.Io.Writer.Allocating = .init(a);
    for (parsed.program.bindings, 0..) |binding, i| try out.writer.print("{s} {s} = {s}\n", .{ if (i == 0) "let" else "and", binding.spelling, try renderer.render(binding.value) });
    if (parsed.program.bindings.len > 0) try out.writer.writeAll("in ");
    try out.writer.writeAll(try renderer.render(parsed.program.main));
    const source = try ms.syntax.format(a, try aliases(a, out.written()), 2);
    // Presentation must not alter bytecode semantics or introduce ambiguous
    // overloads. Reuse the authoring preprocessor to certify the exact bytes.
    parsed = try surface.Surface.parse(a, source);
    const rebuilt_core = parsed.preprocess(try metadata.snapshot(), settings) catch |err| {
        if (err == error.OutOfMemory) return err;
        return .{ .source = try ms.syntax.format(a, core, 2), .restored = false };
    };
    const rebuilt = ms.compile(a, rebuilt_core, parsed.settings) catch |err| {
        if (err == error.OutOfMemory) return err;
        return .{ .source = try ms.syntax.format(a, core, 2), .restored = false };
    };
    if (!c.eq(u8, bytes, rebuilt)) return .{ .source = try ms.syntax.format(a, core, 2), .restored = false };
    return .{ .source = source, .restored = true };
}
