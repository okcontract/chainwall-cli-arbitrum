const std = @import("std");
const ms = @import("miniscript");
const c = @import("common.zig");
const Node = ms.tree.Node;
const Schema = ms.abi.Schema;
const contracts = @import("contracts.zig");

pub const Reference = struct { path: []const u8, hash: []const u8, kind: []const u8 };
const Local = struct { name: []const u8, value: *Node, parent: ?*const Local, initializer_scope: ?*const Local };
pub const Surface = struct {
    a: c.A,
    program: ms.tree.Program,
    references: []const Reference,
    snapshot: c.Value = .null,
    selected: std.AutoHashMapUnmanaged(*Node, ms.abi.Method) = .empty,
    accepted: std.AutoHashMapUnmanaged(*Node, void) = .empty,
    settings: ms.Settings = .{},
    diagnostic_span: ?ms.tree.Span = null,

    pub fn parse(a: c.A, source: []const u8) !Surface {
        if (source.len > 256 * 1024) return error.SourceTooLarge;
        var f: ms.tree.Factory = .{ .a = a };
        var parser: ms.parser.Parser = .{ .f = &f, .source = source, .surface = true };
        const program = try parser.parse();
        return fromProgram(a, program);
    }
    pub fn fromProgram(a: c.A, program: ms.tree.Program) !Surface {
        var refs: std.ArrayList(Reference) = .empty;
        for (program.bindings) |binding| {
            if (std.mem.startsWith(u8, binding.name, "@")) return error.ReservedRegistryName;
            try collect(a, binding.value, &refs);
        }
        try collect(a, program.main, &refs);
        return .{ .a = a, .program = program, .references = refs.items };
    }
    fn collect(a: c.A, n: *Node, refs: *std.ArrayList(Reference)) anyerror!void {
        if (n.tag == .registry_reference) {
            const kind = if (n.data) "token" else "contract";
            for (refs.items) |ref| if (c.eq(u8, ref.path, n.name) and c.eq(u8, ref.kind, kind)) return;
            try refs.append(a, .{ .path = n.name, .hash = try c.hex(a, ms.bytecode.hash(n.name)), .kind = kind });
        }
        for (n.children) |child| try collect(a, child, refs);
    }
    fn reference(s: *Surface, node: *Node, locals: ?*const Local, depth: usize) anyerror!?*Node {
        if (depth > 256) return error.CyclicDefinition;
        if (node.tag == .registry_reference) return node;
        if (node.tag != .variable) return null;
        var local = locals;
        while (local) |entry| : (local = entry.parent) if (c.eq(u8, entry.name, node.name)) return s.reference(entry.value, entry.initializer_scope, depth + 1);
        for (s.program.bindings) |binding| if (c.eq(u8, binding.name, node.name)) return s.reference(binding.value, null, depth + 1);
        return null;
    }
    /// Only receivers and raw IO targets need an ABI. Token references used as
    /// arguments or in price lookups must not require explorer verification.
    pub fn abiTargets(s: *Surface) ![]const []const u8 {
        var targets: std.StringArrayHashMapUnmanaged(void) = .empty;
        for (s.program.bindings) |binding| try s.collectTargets(binding.value, null, &targets);
        try s.collectTargets(s.program.main, null, &targets);
        return targets.keys();
    }
    fn collectTargets(s: *Surface, n: *Node, locals: ?*const Local, targets: *std.StringArrayHashMapUnmanaged(void)) anyerror!void {
        if (n.tag == .tuple) {
            var scope = locals;
            for (n.children) |child| {
                if (child.tag == .declaration) {
                    try s.collectTargets(child.children[0], scope, targets);
                    const next = try s.a.create(Local);
                    next.* = .{ .name = child.name, .value = child.children[0], .parent = scope, .initializer_scope = scope };
                    scope = next;
                } else try s.collectTargets(child, scope, targets);
            }
            return;
        }
        if (n.children.len > 0 and (n.tag == .member_call or (n.tag == .application and (c.eq(u8, n.name, "$read") or c.eq(u8, n.name, "$readwords") or c.eq(u8, n.name, "$write"))))) {
            if (try s.reference(n.children[0], locals, 0)) |ref| try targets.put(s.a, try c.hex(s.a, ms.bytecode.hash(ref.name)), {});
        }
        for (n.children) |child| try s.collectTargets(child, locals, targets);
    }
    fn accept(s: *Surface, n: *Node, locals: ?*const Local, token_only: bool) !void {
        if (try s.reference(n, locals, 0)) |ref| {
            if (token_only and !ref.data) return error.ExpectedTokenReference;
            try s.accepted.put(s.a, n, {});
        }
    }
    fn rawValue(s: *Surface, n: *Node, locals: ?*const Local) anyerror!void {
        if (try s.reference(n, locals, 0) != null) return s.accept(n, locals, false);
        if (n.tag == .tuple or n.tag == .list) for (n.children) |child| try s.rawValue(child, locals);
    }
    fn matches(s: *Surface, n: *Node, schema: *Schema, param: c.Value, locals: ?*const Local) anyerror!bool {
        if (n.type_hint) |hint| if (!c.eq(u8, hint, try annotation(s.a, param))) return false;
        if (try s.reference(n, locals, 0) != null) return schema.kind == .address or (schema.kind == .fixed_bytes and schema.width == 32);
        if (schema.kind == .tuple) {
            if (n.tag != .tuple or n.children.len != schema.children.len) return false;
            const params = c.field(param, "components").?.array.items;
            for (n.children, schema.children, params) |child, child_schema, child_param| if (!try s.matches(child, child_schema, child_param, locals)) return false;
            return true;
        }
        if (schema.kind == .fixed_array or schema.kind == .dynamic_array) {
            if (n.tag != .list or (schema.kind == .fixed_array and n.children.len != schema.length)) return false;
            const child_param = try element(s.a, param);
            for (n.children) |child| if (!try s.matches(child, schema.children[0], child_param, locals)) return false;
            return true;
        }
        if (n.tag == .list or n.tag == .tuple) return false;
        if (n.tag == .number and (std.ascii.eqlIgnoreCase(n.spelling, "true") or std.ascii.eqlIgnoreCase(n.spelling, "false"))) return schema.kind == .boolean;
        if (n.tag == .string) return schema.kind == .dynamic_bytes or schema.kind == .fixed_bytes;
        return true;
    }
    fn acceptAbi(s: *Surface, n: *Node, schema: *Schema, locals: ?*const Local) anyerror!void {
        if (try s.reference(n, locals, 0) != null) return s.accept(n, locals, false);
        if (schema.kind == .tuple) {
            for (n.children, schema.children) |child, child_schema| try s.acceptAbi(child, child_schema, locals);
        } else if (schema.kind == .dynamic_array or schema.kind == .fixed_array) {
            for (n.children) |child| try s.acceptAbi(child, schema.children[0], locals);
        }
    }
    fn visit(s: *Surface, n: *Node, locals: ?*const Local, validate: bool) anyerror!void {
        s.visitInner(n, locals, validate) catch |err| {
            if (s.diagnostic_span == null) s.diagnostic_span = if (n.name_span.end > n.name_span.start) n.name_span else n.span;
            return err;
        };
    }
    fn visitInner(s: *Surface, n: *Node, locals: ?*const Local, validate: bool) anyerror!void {
        if (n.tag == .tuple) {
            var scope = locals;
            var names: std.StringHashMapUnmanaged(void) = .empty;
            for (n.children) |child| {
                if (child.tag == .declaration) {
                    if (names.contains(child.name)) return error.DuplicateBinding;
                    try names.put(s.a, child.name, {});
                    if (std.mem.startsWith(u8, child.name, "@")) return error.ReservedRegistryName;
                    try s.accept(child.children[0], scope, false);
                    try s.visit(child.children[0], scope, validate);
                    const next = try s.a.create(Local);
                    next.* = .{ .name = child.name, .value = child.children[0], .parent = scope, .initializer_scope = scope };
                    scope = next;
                } else try s.visit(child, scope, validate);
            }
            return;
        }
        if (validate) {
            if ((try s.reference(n, locals, 0)) != null and !s.accepted.contains(n)) return error.UnsupportedRegistryReferenceContext;
        } else if (n.tag == .member_call) {
            const target = try s.reference(n.children[0], locals, 0) orelse return error.NonStaticMemberReceiver;
            const hash = try c.hex(s.a, ms.bytecode.hash(target.name));
            const abi = c.field(c.field(s.snapshot, "abiByTargetHash") orelse return error.MissingAbi, hash) orelse return error.MissingAbi;
            if (abi != .array) return error.InvalidAbi;
            const args = n.children[1 .. n.children.len - @intFromBool(n.payable)];
            var selected: ?ms.abi.Method = null;
            var named = false;
            var arity = false;
            for (abi.array.items) |item| {
                if (!c.eq(u8, c.string(c.field(item, "type") orelse continue) catch "", "function")) continue;
                if (!c.eq(u8, c.string(c.field(item, "name") orelse continue) catch "", n.spelling)) continue;
                named = true;
                const inputs = c.field(item, "inputs") orelse continue;
                if (inputs != .array or inputs.array.items.len != args.len) continue;
                arity = true;
                const method = ms.abi.method(s.a, item) catch continue;
                var compatible = true;
                for (args, method.root.children, inputs.array.items) |arg, schema, param| if (!try s.matches(arg, schema, param, locals)) {
                    compatible = false;
                    break;
                };
                if (!compatible) continue;
                if (selected) |previous| {
                    if (!c.eq(u8, previous.signature, method.signature)) return error.AmbiguousAbiOverloadAddTypeAnnotation;
                }
                selected = method;
            }
            const method = selected orelse return if (!named) error.UnknownAbiMethod else if (!arity) error.AbiArgumentArity else error.IncompatibleAbiArgument;
            if (n.payable and method.mutability != .payable) return error.NonpayableCallValue;
            if (!n.payable and method.mutability == .payable) return error.PayableCallRequiresValue;
            try s.selected.put(s.a, n, method);
            try s.accept(n.children[0], locals, false);
            for (args, method.root.children) |arg, schema| try s.acceptAbi(arg, schema, locals);
        } else if (n.tag == .application and n.children.len > 0) {
            if (c.eq(u8, n.name, "$price") or c.eq(u8, n.name, "$valueusd")) try s.accept(n.children[0], locals, true);
            if (c.eq(u8, n.name, "$address")) try s.accept(n.children[0], locals, false);
            if (c.eq(u8, n.name, "$read") or c.eq(u8, n.name, "$readwords") or c.eq(u8, n.name, "$write")) {
                try s.accept(n.children[0], locals, false);
                if (n.children.len > 2) try s.rawValue(n.children[2], locals);
            }
        }
        for (n.children) |child| try s.visit(child, locals, validate);
    }
    pub fn preprocess(s: *Surface, snapshot: c.Value, settings: ms.Settings) ![]const u8 {
        s.snapshot = snapshot;
        if (snapshot == .object) {
            s.snapshot.object = try snapshot.object.clone(s.a);
            for ([_][]const u8{ "knownKindsByTargetHash", "abiByTargetHash" }) |name| {
                if (c.field(snapshot, name)) |table| {
                    if (table != .object) return error.InvalidSnapshot;
                    var normalized: std.json.ObjectMap = .empty;
                    for (table.object.keys(), table.object.values()) |key, value| {
                        const hash = try c.id(s.a, key);
                        if (normalized.contains(hash)) return error.DuplicateSnapshotTarget;
                        try normalized.put(s.a, hash, value);
                    }
                    try s.snapshot.object.put(s.a, name, .{ .object = normalized });
                }
            }
        }
        s.settings = settings;
        const known = c.field(s.snapshot, "knownKindsByTargetHash") orelse .null;
        for (s.references) |ref| {
            const kind = c.string(c.field(known, ref.hash) orelse return error.UnknownRegistryReference) catch return error.UnknownRegistryReference;
            if (!c.eq(u8, kind, ref.kind) and !c.eq(u8, kind, "contract+token")) return error.RegistryKindMismatch;
        }
        // Include exact target-qualified methods for both surface and raw calls.
        // Unused ABI entries do not affect code generation.
        var methods: std.json.ObjectMap = if (settings.abiFunctionsByCallKey) |v| try v.object.clone(s.a) else .empty;
        var hashes = std.json.Array.init(s.a);
        if (settings.knownResolvableHashes) |v| try hashes.appendSlice(v.array.items);
        if (c.field(s.snapshot, "abiByTargetHash")) |abis| {
            if (abis != .object) return error.InvalidAbi;
            for (abis.object.keys(), abis.object.values()) |hash, abi| {
                const target = try c.word(hash);
                if (abi != .array) return error.InvalidAbi;
                try hashes.append(.{ .string = hash });
                for (abi.array.items) |item| {
                    if (!c.eq(u8, c.string(c.field(item, "type") orelse continue) catch "", "function")) continue;
                    const method = ms.abi.method(s.a, item) catch continue;
                    const key = try ms.abi.key(s.a, target, method.selector);
                    if (methods.get(key)) |previous| {
                        if (!c.eq(u8, try contracts.signature(s.a, previous, true), try contracts.signature(s.a, item, true)) or
                            !c.eq(u8, try c.string(c.field(previous, "stateMutability").?), try c.string(c.field(item, "stateMutability").?))) return error.AbiSelectorCollision;
                    } else try methods.put(s.a, key, item);
                }
            }
        }
        if (known == .object) for (known.object.keys()) |hash| try hashes.append(.{ .string = hash });
        s.settings.abiFunctionsByCallKey = .{ .object = methods };
        s.settings.knownResolvableHashes = .{ .array = hashes };
        for ([_]bool{ false, true }) |validate| {
            for (s.program.bindings) |binding| {
                try s.accept(binding.value, null, false);
                try s.visit(binding.value, null, validate);
            }
            try s.visit(s.program.main, null, validate);
        }
        var out: std.Io.Writer.Allocating = .init(s.a);
        for (s.program.bindings, 0..) |binding, i| try out.writer.print("{s} {s} = {s}\n", .{ if (i == 0) "let" else "and", binding.spelling, try s.render(binding.value, null, null) });
        if (s.program.bindings.len > 0) try out.writer.writeAll("in ");
        try out.writer.writeAll(try s.render(s.program.main, null, null));
        if (out.written().len > 512 * 1024) return error.GeneratedSourceTooLarge;
        return out.toOwnedSlice();
    }
    fn render(s: *Surface, n: *Node, locals: ?*const Local, schema: ?*Schema) anyerror![]const u8 {
        if (schema) |expected| if (try s.reference(n, locals, 0) != null and expected.kind == .address) return s.a.print("$address({s})", .{try s.render(n, locals, null)});
        switch (n.tag) {
            .number => {
                if (std.ascii.eqlIgnoreCase(n.spelling, "true") or std.ascii.eqlIgnoreCase(n.spelling, "false")) return if (n.value == 0) "false" else "true";
                return s.a.print("{s}{d}", .{ if (n.negative) "-" else "", n.value });
            },
            .variable => return if (n.spelling.len > 0) n.spelling else n.name,
            .registry_reference => return c.hex(s.a, ms.bytecode.hash(n.name)),
            .string => return std.json.Stringify.valueAlloc(s.a, n.name, .{}),
            .object => return "{}",
            .index => return s.a.print("({s})[{s}]", .{ try s.render(n.children[0], locals, null), try s.render(n.children[1], locals, null) }),
            .application => {
                if (n.name.len > 0 and !std.ascii.isAlphabetic(n.name[0]) and n.name[0] != '$') {
                    if (n.children.len == 1) return s.a.print("({s}({s}))", .{ n.name, try s.render(n.children[0], locals, null) });
                    return s.a.print("({s} {s} {s})", .{ try s.render(n.children[0], locals, null), n.name, try s.render(n.children[1], locals, null) });
                }
                var args: std.ArrayList([]const u8) = .empty;
                for (n.children) |child| try args.append(s.a, try s.render(child, locals, null));
                return s.a.print("{s}({s})", .{ if (n.spelling.len > 0) n.spelling else n.name, try std.mem.join(s.a, ", ", args.items) });
            },
            .member_call => {
                const method = s.selected.get(n) orelse return error.MissingAbiSelection;
                const args = n.children[1 .. n.children.len - @intFromBool(n.payable)];
                var rendered: std.ArrayList([]const u8) = .empty;
                for (args, method.root.children) |arg, expected| try rendered.append(s.a, try s.render(arg, locals, expected));
                const tuple = if (args.len > 0 or n.payable) try s.a.print(", {{{s}}}", .{try std.mem.join(s.a, ", ", rendered.items)}) else "";
                const value = if (n.payable) try s.a.print(", {s}", .{try s.render(n.children[n.children.len - 1], locals, null)}) else "";
                return s.a.print("${s}({s}, 0x{x:0>8}{s}{s})", .{ if (method.mutability == .view or method.mutability == .pure) "read" else "write", try s.render(n.children[0], locals, null), method.selector, tuple, value });
            },
            .tuple, .list => {
                var scope = locals;
                var items: std.ArrayList([]const u8) = .empty;
                for (n.children, 0..) |child, i| {
                    if (child.tag == .declaration) {
                        try items.append(s.a, try s.a.print("let {s} = {s}", .{ child.spelling, try s.render(child.children[0], scope, null) }));
                        const next = try s.a.create(Local);
                        next.* = .{ .name = child.name, .value = child.children[0], .parent = scope, .initializer_scope = scope };
                        scope = next;
                    } else try items.append(s.a, try s.render(child, scope, if (schema) |expected| if (expected.kind == .tuple) expected.children[i] else if (expected.kind == .fixed_array or expected.kind == .dynamic_array) expected.children[0] else null else null));
                }
                return s.a.print("{s}{s}{s}", .{ if (n.tag == .list) "[" else "{", try std.mem.join(s.a, ", ", items.items), if (n.tag == .list) "]" else "}" });
            },
            else => return error.UnsupportedSurfaceSyntax,
        }
    }
};
fn element(a: c.A, param: c.Value) !c.Value {
    var value = param;
    value.object = try param.object.clone(a);
    const kind = try c.string(c.field(param, "type").?);
    const bracket = std.mem.lastIndexOfScalar(u8, kind, '[') orelse return error.InvalidAbi;
    try value.object.put(a, "type", .{ .string = kind[0..bracket] });
    return value;
}
pub fn annotation(a: c.A, param: c.Value) anyerror![]const u8 {
    const kind = try c.string(c.field(param, "type").?);
    if (std.mem.endsWith(u8, kind, "]")) {
        const bracket = std.mem.lastIndexOfScalar(u8, kind, '[').?;
        const size = kind[bracket + 1 .. kind.len - 1];
        return a.print("[{s}{s}]", .{ try annotation(a, try element(a, param)), if (size.len > 0) try a.print("; {s}", .{size}) else "" });
    }
    if (c.eq(u8, kind, "tuple")) {
        var children: std.ArrayList([]const u8) = .empty;
        for (c.field(param, "components").?.array.items) |child| try children.append(a, try annotation(a, child));
        return a.print("{{{s}}}", .{try std.mem.join(a, ", ", children.items)});
    }
    return if (c.eq(u8, kind, "uint")) "uint256" else if (c.eq(u8, kind, "int")) "int256" else kind;
}

test "surface aliases, exact overload selection and registry address coercion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const hash = try c.hex(a, ms.bytecode.hash("test/token"));
    const snapshot = try c.parse(a, try a.print("{{\"knownKindsByTargetHash\":{{\"{s}\":\"token\"}},\"abiByTargetHash\":{{\"{s}\":[{{\"type\":\"function\",\"name\":\"transfer\",\"stateMutability\":\"nonpayable\",\"inputs\":[{{\"type\":\"address\"}},{{\"type\":\"uint256\"}}],\"outputs\":[]}}]}}}}", .{ hash, hash }));
    var source = try Surface.parse(a, "let token = @token(test/token)\nin token.transfer(token, $arg0)");
    const core = try source.preprocess(snapshot, .{});
    try std.testing.expect(std.mem.indexOf(u8, core, "$address(token)") != null);
    _ = try ms.compile(a, core, source.settings);
    var invalid = try Surface.parse(a, "@token(test/token) + 1");
    try std.testing.expectError(error.UnsupportedRegistryReferenceContext, invalid.preprocess(snapshot, .{}));

    var scoped = try Surface.parse(a, "{let vault = @contract(example/vault), vault.transfer(@token(example/unverified), 1)}");
    const targets = try scoped.abiTargets();
    try std.testing.expectEqual(@as(usize, 1), targets.len);
    try std.testing.expectEqualStrings(try c.hex(a, ms.bytecode.hash("example/vault")), targets[0]);
    _ = try Surface.parse(a, "@contract(example/vault).f(1 :: number[0, 255])");
}
