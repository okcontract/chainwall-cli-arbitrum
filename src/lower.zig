const std = @import("std");
const t = @import("tree.zig");
const bc = @import("bytecode.zig");
const abi = @import("abi.zig");
const json = @import("json.zig");
const Node = t.Node;
const Error = t.Error;
pub const Settings = struct {
    argumentContext: enum { frame, subject } = .frame,
    optimization: enum { baseline, size } = .size,
    validity: u64 = 1800,
    slippage: i64 = 5,
    forceRecursiveAbi: bool = false,
    abiFunctionsByCallKey: ?std.json.Value = null,
    knownResolvableHashes: ?std.json.Value = null,
    addressArgResolutionsByWriteKey: ?std.json.Value = null,
};
const Env = struct {
    name: []const u8,
    value: *Node,
    parent: ?*const Env,
    fn get(env: ?*const Env, name: []const u8) ?*Node {
        var e = env;
        while (e) |entry| : (e = entry.parent) {
            if (t.same(entry.name, name)) return entry.value;
        }
        return null;
    }
};
const Definition = struct { binding: t.Binding, internal_name: []const u8 = "", count: usize = 0, visiting: bool = false, runtime: bool = false, lowered: ?*Node = null };
pub const Lowerer = struct {
    f: *t.Factory,
    settings: Settings,
    definitions: []Definition = &.{},
    order: std.ArrayList(usize) = .empty,
    depth: usize = 0,
    fn lookup(l: *Lowerer, name: []const u8) ?usize {
        for (l.definitions, 0..) |d, i| if (t.same(d.binding.name, name)) return i;
        return null;
    }
    fn count(l: *Lowerer, n: *Node, locals: ?*const Env) Error!void {
        errdefer if (l.f.diagnostic) |d| d.locate(n.span);
        if (l.depth >= t.limits.lowering_depth) return error.ResourceLimit;
        l.depth += 1;
        defer l.depth -= 1;
        if (n.tag == .variable and Env.get(locals, n.name) == null) {
            if (l.lookup(n.name)) |i| {
                const d = &l.definitions[i];
                d.count += 1;
                if (d.count > t.limits.dependency_visits) return error.ResourceLimit;
                if (d.visiting) {
                    if (l.f.diagnostic) |diagnostic| {
                        diagnostic.record(n.span, error.CyclicDefinition);
                        diagnostic.related = d.binding.name_span;
                    }
                    return error.CyclicDefinition;
                }
                d.visiting = true;
                try l.count(d.binding.value, null);
                d.visiting = false;
                return;
            }
        }
        if (n.tag == .tuple) {
            var env = locals;
            for (n.children) |c| {
                if (c.tag == .declaration) {
                    try l.count(c.children[0], env);
                    const next = try l.f.a.create(Env);
                    next.* = .{ .name = c.name, .value = c, .parent = env };
                    env = next;
                } else try l.count(c, env);
            }
        } else {
            for (n.children) |c| try l.count(c, locals);
        }
    }
    fn astEffect(l: *Lowerer, n: *Node, depth: usize) Error!bool {
        if (depth > t.limits.resolution_depth) return error.CyclicDefinition;
        if (n.tag == .variable) {
            if (std.mem.startsWith(u8, n.name, "$subject")) return true;
            if (l.lookup(n.name)) |i| return l.astEffect(l.definitions[i].binding.value, depth + 1);
        }
        if (n.tag == .application) {
            for ([_][]const u8{ "$read", "$readwords", "$write", "$floor", "$address", "$require", "$price", "$balance", "$calli", "$staticlinked", "$subjectarg", "$valueusd", "$nativevalueusd", "$transfernative" }) |name| if (t.same(n.name, name)) return true;
        }
        for (n.children) |c| if (try l.astEffect(c, depth + 1)) return true;
        return false;
    }
    fn hasDeclaration(n: *Node) bool {
        if (n.tag == .declaration) return true;
        for (n.children) |c| if (hasDeclaration(c)) return true;
        return false;
    }
    fn definition(l: *Lowerer, i: usize) Error!*Node {
        const d = &l.definitions[i];
        if (d.lowered) |value| return value;
        if (d.visiting) return error.CyclicDefinition;
        d.visiting = true;
        defer d.visiting = false;
        const value = try l.expr(d.binding.value, null, false);
        d.lowered = value;
        if (d.runtime) try l.order.append(l.f.a, i);
        return value;
    }
    fn expand(l: *Lowerer, n: *Node, env: ?*const Env, depth: usize) Error!*Node {
        if (depth > t.limits.resolution_depth) return error.CyclicDefinition;
        if (n.tag == .variable) {
            if (Env.get(env, n.name)) |v| return v;
            if (l.lookup(n.name)) |i| {
                if (l.definitions[i].runtime) return n;
                return l.expand(l.definitions[i].binding.value, null, depth + 1);
            }
        }
        return n;
    }
    fn literal(l: *Lowerer, node: *Node, env: ?*const Env, hashed: bool) Error!u256 {
        errdefer if (l.f.diagnostic) |d| d.locate(node.span);
        const n = try l.expand(node, env, 0);
        if (n.tag == .application and (t.same(n.name, "$address") or t.same(n.name, "$__resolved")) and n.children.len == 1) return l.literal(n.children[0], env, true);
        if (n.tag == .string and hashed) return bc.hash(n.name);
        if ((n.tag != .number and n.tag != .constant) or n.negative) return error.InvalidConstant;
        return n.value;
    }
    fn sequence(l: *Lowerer, nodes: []const *Node, env: ?*const Env) Error!*Node {
        if (l.depth >= t.limits.lowering_depth) return error.ResourceLimit;
        l.depth += 1;
        defer l.depth -= 1;
        if (nodes.len == 0) return l.f.num(0);
        var items: std.ArrayList(*Node) = .empty;
        for (nodes, 0..) |n, i| {
            if (n.tag == .declaration) {
                const value = try l.expr(n.children[0], env, false);
                const name = try l.f.fresh("local");
                // Unit bindings remember completion, never the initializer's
                // effect. Referring to one must not execute REQUIRE again.
                const local = if (value.tag == .constant) value else if (t.resultType(value) == .unit) try l.f.node(.unit, &.{}) else try l.f.named(.local, name, &.{});
                local.result = t.resultType(value);
                const entry: Env = .{ .name = n.name, .value = local, .parent = env };
                const body = if (i + 1 == nodes.len) try l.f.node(.unit, &.{}) else try l.sequence(nodes[i + 1 ..], &entry);
                const result = if (value.tag == .constant and i + 1 < nodes.len) body else if (t.resultType(value) == .unit) try l.f.sequence(&.{ value, body }) else try l.f.named(.let, name, &.{ value, body });
                try items.append(l.f.a, result);
                return l.f.sequence(items.items);
            }
            try items.append(l.f.a, try l.expr(n, env, false));
        }
        return l.f.sequence(items.items);
    }
    pub fn expr(l: *Lowerer, n: *Node, env: ?*const Env, target: bool) Error!*Node {
        const origin = l.f.origin;
        l.f.origin = n.span;
        defer l.f.origin = origin;
        errdefer if (l.f.diagnostic) |d| d.locate(n.span);
        if (l.depth >= t.limits.lowering_depth) return error.ResourceLimit;
        l.depth += 1;
        defer l.depth -= 1;
        switch (n.tag) {
            .constant, .local, .unit => return n,
            .number => return if (n.negative) l.f.node(.sub, &.{ try l.f.num(0), try l.f.num(n.value) }) else l.f.num(n.value),
            .string => {
                const v = @import("parser.zig").parseNumber(l.f.a, n.name) catch return error.InvalidConstant;
                return l.f.num(v);
            },
            .variable => {
                if (Env.get(env, n.name)) |value| return value;
                if (l.lookup(n.name)) |i| {
                    const value = try l.definition(i);
                    if (!l.definitions[i].runtime) return value;
                    const local = try l.f.named(.local, l.definitions[i].internal_name, &.{});
                    local.result = t.resultType(value);
                    return local;
                }
                if (std.mem.startsWith(u8, n.name, "$arg")) {
                    const index = std.fmt.parseInt(u64, n.name[4..], 10) catch return error.UnboundVariable;
                    const offset: u64 = if (l.settings.argumentContext == .subject) 7 else 0;
                    if (index > 9007199254740991 - offset) return error.InvalidConstant;
                    const out = try l.f.node(if (offset == 0) .arg else .subject, &.{});
                    out.value = index + offset;
                    return out;
                }
                const names = [_][]const u8{ "$self", "$this", "$time", "$subjectversion", "$subjectid", "$subjectnativevalue", "$subjectactor", "$subjectvault", "$subjectargcount", "$subjectpolicy" };
                for (names, 0..) |name, i| if (t.same(n.name, name)) {
                    const out = try l.f.node(if (i == 0) .caller else if (i == 1) .this else if (i == 2) .time else .subject, &.{});
                    if (i >= 3) out.value = i - 3;
                    return out;
                };
                return error.UnboundVariable;
            },
            .tuple => return l.sequence(n.children, env),
            .index => {
                const index = try l.literal(n.children[1], env, false);
                if (index > 7) return error.InvalidArguments;
                const out = try l.f.node(.get_word, &.{try l.expr(n.children[0], env, false)});
                out.value = index;
                return out;
            },
            .application => return l.application(n, env, target),
            else => return error.Unsupported,
        }
    }
    fn unary(l: *Lowerer, tag: t.Tag, args: []const *Node, env: ?*const Env) Error!*Node {
        if (args.len != 1) return error.InvalidArguments;
        return l.f.node(tag, &.{try l.expr(args[0], env, false)});
    }
    fn collectRatio(l: *Lowerer, node: *Node, env: ?*const Env, inverted: bool, factors: *std.ArrayList(*Node), mask: *u16) Error!bool {
        const n = try l.expand(node, env, 0);
        if (n.tag == .application and (t.same(n.name, "*") or t.same(n.name, "/"))) {
            const division = t.same(n.name, "/");
            var has = division;
            for (n.children, 0..) |c, i| {
                const child_has = try l.collectRatio(c, env, if (division and i > 0) !inverted else inverted, factors, mask);
                has = has or child_has;
            }
            return has;
        }
        if (factors.items.len >= 17) return error.InvalidArguments;
        if (inverted) {
            if (factors.items.len >= t.limits.ratio_factors) return error.InvalidArguments;
            mask.* |= @as(u16, 1) << @intCast(factors.items.len);
        }
        try factors.append(l.f.a, n);
        return false;
    }
    fn application(l: *Lowerer, n: *Node, env: ?*const Env, target: bool) Error!*Node {
        const name = n.name;
        const args = n.children;
        const unary_names = [_][]const u8{ "$require", "!", "$bitnot", "$sqrt" };
        const unary_tags = [_]t.Tag{ .require, .not, .bitnot, .sqrt };
        for (unary_names, unary_tags) |key, tag| if (t.same(name, key)) return l.unary(tag, args, env);
        if (t.same(name, "$address") or t.same(name, "$__resolved")) {
            if (args.len != 1) return error.InvalidArguments;
            const source = try l.expand(args[0], env, 0);
            const inner = if (source.tag == .string) try l.f.num(bc.hash(source.name)) else try l.expr(source, env, false);
            return if (target) inner else l.f.node(.resolve, &.{inner});
        }
        if (t.same(name, "if")) {
            if (args.len != 3) return error.InvalidArguments;
            const cond = try l.expr(args[0], env, false);
            if (args[1].tag == .variable and t.same(args[1].name, "$noop")) return l.f.node(.noop_then, &.{ cond, try l.expr(args[2], env, false) });
            return l.f.node(.conditional, &.{ cond, try l.expr(args[1], env, false), try l.expr(args[2], env, false) });
        }
        if (t.same(name, "$floor")) {
            if (args.len != 1) return error.InvalidArguments;
            var factors: std.ArrayList(*Node) = .empty;
            var mask: u16 = 0;
            if (!try l.collectRatio(args[0], env, false, &factors, &mask)) return l.expr(args[0], env, false);
            if (factors.items.len > 2 and mask & 1 == 0 and factors.items[0].tag == .number and !factors.items[0].negative and factors.items[0].value == 1 and mask != (@as(u32, 1) << @intCast(factors.items.len)) - 2) {
                _ = factors.orderedRemove(0);
                mask >>= 1;
            }
            if (factors.items.len < 2 or factors.items.len > t.limits.ratio_factors) return error.InvalidArguments;
            for (factors.items) |*c| c.* = try l.expr(c.*, env, false);
            const out = try l.f.node(.ratio, factors.items);
            out.mask = mask;
            return out;
        }
        if (t.same(name, "$keccak")) {
            if (args.len > 255) return error.InvalidArguments;
            const out = try l.f.node(.keccak, args);
            var constants = true;
            for (out.children) |*c| {
                c.* = try l.expr(c.*, env, false);
                constants = constants and c.*.tag == .constant;
            }
            if (constants) {
                const bytes = try l.f.a.alloc(u8, args.len * 32);
                for (out.children, 0..) |c, i| bc.put(bytes[32 * i ..][0..32], c.value);
                return l.f.num(bc.hash(bytes));
            }
            return out;
        }
        if (t.same(name, "$read") or t.same(name, "$write") or t.same(name, "$readwords")) return l.call(n, env);
        if (t.same(name, "$calli")) {
            if (args.len < 1 or args.len > 2) return error.InvalidArguments;
            const id = try l.literal(args[0], env, false);
            const tuple = if (args.len == 2) try l.expand(args[1], env, 0) else try l.f.node(.tuple, &.{});
            if (tuple.tag != .tuple or hasDeclaration(tuple)) return error.InvalidArguments;
            if (tuple.children.len > t.limits.calli_arguments) return error.ResourceLimit;
            var children: std.ArrayList(*Node) = .empty;
            try children.append(l.f.a, try l.f.num(id));
            for (tuple.children) |c| {
                if (c.tag == .tuple or c.tag == .list) return error.InvalidArguments;
                try children.append(l.f.a, try l.expr(c, env, false));
            }
            return l.f.node(.calli, children.items);
        }
        if (t.same(name, "$subjectarg")) {
            if (args.len != 1) return error.InvalidArguments;
            const index = try l.literal(args[0], env, false);
            if (index > 9007199254740984) return error.InvalidConstant;
            const out = try l.f.node(.subject, &.{});
            out.value = index + 7;
            return out;
        }
        if (t.same(name, "$staticlinked")) {
            if (args.len != 1) return error.InvalidArguments;
            const id = try l.literal(args[0], env, true);
            if (id == 0) return error.InvalidConstant;
            const out = try l.f.node(.static_linked, &.{});
            out.value = id;
            return out;
        }
        if (t.same(name, "$valueusd") or t.same(name, "$nativevalueusd")) {
            const native = t.same(name, "$nativevalueusd");
            if (args.len != (if (native) @as(usize, 2) else 3)) return error.InvalidArguments;
            const asset = if (native) 0 else try l.literal(args[0], env, true);
            const age = try l.literal(args[args.len - 1], env, false);
            if (age == 0 or age > 172800) return error.InvalidConstant;
            const out = try l.f.node(.value_usd, &.{try l.expr(args[args.len - 2], env, false)});
            out.value = asset;
            out.name = try l.f.a.print("{d}", .{age});
            return out;
        }
        if (t.same(name, "$price")) {
            if (args.len < 1 or args.len > 3) return error.InvalidArguments;
            return l.f.node(.price, &.{ try l.f.num(try l.literal(args[0], env, true)), if (args.len > 1) try l.expr(args[1], env, false) else try l.f.num(18), if (args.len > 2) try l.expr(args[2], env, false) else try l.f.num(0) });
        }
        if (t.same(name, "$balance")) {
            if (args.len == 1) return l.unary(.balance, args, env);
            if (args.len != 2) return error.InvalidArguments;
            const token = try l.f.num(try l.literal(args[0], env, true));
            const call_node = try l.f.named(.application, "$read", &.{ token, try l.f.num(0x70a08231), try l.f.node(.tuple, args[1..]) });
            return l.call(call_node, env);
        }
        if (t.same(name, "$deadline")) {
            if (args.len != 0) return error.InvalidArguments;
            return l.f.node(.add, &.{ try l.f.node(.time, &.{}), try l.f.num(l.settings.validity) });
        }
        if (t.same(name, "$slip")) {
            if (args.len != 1) return error.InvalidArguments;
            const out = try l.f.node(.ratio, &.{ try l.expr(args[0], env, false), try l.f.num(@intCast(1000 - std.math.clamp(l.settings.slippage, 0, 1000))), try l.f.num(1000) });
            out.mask = 4;
            return out;
        }
        const binary_names = [_][]const u8{ "+", "-", "*", "$idiv", "%", "&&", "||", "==", "!=", "<", ">", "<=", ">=", "$transfernative" };
        const binary_tags = [_]t.Tag{ .add, .sub, .mul, .div, .mod, .logical_and, .logical_or, .eq, .neq, .lt, .gt, .lte, .gte, .transfer_native };
        for (binary_names, binary_tags) |key, tag| if (t.same(name, key)) {
            if (t.same(name, "-") and args.len == 1) return l.f.node(.sub, &.{ try l.f.num(0), try l.expr(args[0], env, false) });
            if (args.len != 2) return error.InvalidArguments;
            return l.f.node(tag, &.{ try l.expr(args[0], env, false), try l.expr(args[1], env, false) });
        };
        return error.Unsupported;
    }
    fn call(l: *Lowerer, n: *Node, env: ?*const Env) Error!*Node {
        const args = n.children;
        const write = t.same(n.name, "$write");
        const read_words = t.same(n.name, "$readwords");
        if (args.len < 2 or args.len > (if (write or read_words) @as(usize, 4) else 3) or (read_words and args.len != 4)) return error.InvalidArguments;
        const raw_target = try l.expand(args[0], env, 0);
        const target = if (l.literal(raw_target, env, false)) |v| try l.f.num(v) else |_| try l.expr(raw_target, env, true);
        const selector = try l.expr(args[1], env, false);
        if (selector.tag == .constant and selector.value > std.math.maxInt(u32)) return error.InvalidConstant;
        const tuple = if (args.len > 2) try l.expand(args[2], env, 0) else try l.f.node(.tuple, &.{});
        const method_value = if (target.tag == .constant and selector.tag == .constant and l.settings.abiFunctionsByCallKey != null) json.field(l.settings.abiFunctionsByCallKey.?, try abi.key(l.f.a, target.value, selector.value)) else null;
        if (method_value) |v| return l.recursiveCall(n, env, target, selector, tuple, try abi.method(l.f.a, v));
        if (l.settings.forceRecursiveAbi or read_words) return error.InvalidSettings;
        if ((tuple.tag != .tuple and !(write and tuple.tag == .object)) or hasDeclaration(tuple)) return error.InvalidArguments;
        if (tuple.children.len > t.limits.raw_arguments) return error.ResourceLimit;
        var children: std.ArrayList(*Node) = .empty;
        try children.appendSlice(l.f.a, &.{ try l.f.node(.target, &.{target}), selector });
        var groups: std.ArrayList(t.Arg) = .empty;
        for (tuple.children, 0..) |arg_, index| {
            const arg = try l.expand(arg_, env, 0);
            const resolution = if (write) try l.addressHint(target, selector, index) else "";
            if (arg.tag == .list) {
                if (arg.children.len > t.limits.raw_array_elements) return error.ResourceLimit;
                try groups.append(l.f.a, .{ .count = arg.children.len, .array = true });
                for (arg.children) |c| {
                    const value = try l.expr(c, env, false);
                    try children.append(l.f.a, if (t.same(resolution, "address[]")) try l.address(value) else value);
                }
            } else {
                if (arg.tag == .tuple) return error.InvalidArguments;
                try groups.append(l.f.a, .{});
                var value = try l.expr(arg, env, false);
                if (t.same(resolution, "address")) value = try l.address(value);
                try children.append(l.f.a, value);
            }
        }
        if (write and args.len == 4) try children.append(l.f.a, try l.expr(args[3], env, false));
        const out = try l.f.node(if (write) .write else .read, children.items);
        out.args = groups.items;
        out.payable = write and args.len == 4;
        return out;
    }
    fn addressHint(l: *Lowerer, target: *Node, selector: *Node, index: usize) Error![]const u8 {
        if (target.tag != .constant or selector.tag != .constant) return "";
        const hints = l.settings.addressArgResolutionsByWriteKey orelse return "";
        const list = json.field(hints, try abi.key(l.f.a, target.value, selector.value)) orelse return "";
        if (list != .array) return error.InvalidSettings;
        for (list.array.items) |hint| {
            const position = json.field(hint, "index") orelse return error.InvalidSettings;
            if (position == .integer and position.integer == index) return json.string(json.field(hint, "kind") orelse return error.InvalidSettings);
        }
        return "";
    }
    fn address(l: *Lowerer, value: *Node) Error!*Node {
        if (value.tag != .constant) return value;
        var resolve = value.value >> 160 != 0;
        if (l.settings.knownResolvableHashes) |hashes| {
            if (hashes != .array) return error.InvalidSettings;
            resolve = false;
            for (hashes.array.items) |hash| {
                const text = try json.string(hash);
                const v = @import("parser.zig").parseNumber(l.f.a, text) catch return error.InvalidSettings;
                if (v == value.value) resolve = true;
            }
        }
        return if (resolve) l.f.node(.resolve, &.{value}) else value;
    }
    const Tape = struct { words: std.ArrayList(*Node) = .empty, validations: std.ArrayList(abi.Validation) = .empty, visits: usize = 0 };
    fn tapeWord(l: *Lowerer, tape: *Tape, word: *Node, validation: abi.Validation) Error!void {
        if (tape.words.items.len >= 384) return error.ResourceLimit;
        try tape.words.append(l.f.a, word);
        try tape.validations.append(l.f.a, validation);
    }
    fn lowerValue(l: *Lowerer, raw: *Node, schema: *abi.Schema, env: ?*const Env, tape: *Tape) Error!void {
        tape.visits += 1;
        if (tape.visits > t.limits.abi_plan_visits) return error.ResourceLimit;
        const node = try l.expand(raw, env, 0);
        switch (schema.kind) {
            .tuple => {
                if ((node.tag != .tuple and node.tag != .object) or node.children.len != schema.children.len or hasDeclaration(node)) return error.InvalidArguments;
                for (node.children, schema.children) |c, child_schema| try l.lowerValue(c, child_schema, env, tape);
            },
            .fixed_array, .dynamic_array => {
                if (node.tag != .list or node.children.len > t.limits.abi_array_elements or (schema.kind == .fixed_array and node.children.len != schema.length)) return error.InvalidArguments;
                if (schema.kind == .dynamic_array) try l.tapeWord(tape, try l.f.num(node.children.len), .{ .tag = 0x80, .exact = @intCast(node.children.len) });
                for (node.children) |c| try l.lowerValue(c, schema.children[0], env, tape);
            },
            .dynamic_bytes => {
                if (node.tag != .string) return error.InvalidArguments;
                const bytes = if (schema.string) node.name else try bc.unhex(l.f.a, node.name);
                if (bytes.len > t.limits.abi_dynamic_bytes or (!schema.string and !std.mem.startsWith(u8, node.name, "0x"))) return error.InvalidArguments;
                try l.tapeWord(tape, try l.f.num(bytes.len), .{ .tag = 0x80, .exact = @intCast(bytes.len) });
                var offset: usize = 0;
                while (offset < bytes.len) : (offset += 32) {
                    const width = @min(32, bytes.len - offset);
                    var word: [32]u8 = @splat(0);
                    @memcpy(word[0..width], bytes[offset..][0..width]);
                    try l.tapeWord(tape, try l.f.num(bc.word(&word)), .{ .tag = if (width == 32) 0 else 0x60 + @as(u8, @intCast(width)) });
                }
            },
            else => {
                if (node.tag == .tuple or node.tag == .list) return error.InvalidArguments;
                var value: *Node = undefined;
                if (schema.kind == .fixed_bytes and node.tag == .string) {
                    if (!std.mem.startsWith(u8, node.name, "0x")) return error.InvalidArguments;
                    const bytes = try bc.unhex(l.f.a, node.name);
                    if (bytes.len != schema.width) return error.InvalidArguments;
                    var word: [32]u8 = @splat(0);
                    @memcpy(word[0..bytes.len], bytes);
                    value = try l.f.num(bc.word(&word));
                } else value = try l.expr(node, env, false);
                if (schema.kind == .address) value = try l.address(value);
                if (node.tag == .number or node.tag == .constant) {
                    const bits: usize = @as(usize, schema.width) * 8;
                    switch (schema.kind) {
                        .uint => if (node.negative or (bits < 256 and node.value >> @intCast(bits) != 0)) {
                            return error.InvalidConstant;
                        },
                        .int => {
                            const bound = @as(u256, 1) << @intCast(bits - 1);
                            if ((node.negative and node.value > bound) or (!node.negative and node.value >= bound)) return error.InvalidConstant;
                        },
                        .boolean => if (node.negative or node.value > 1) {
                            return error.InvalidConstant;
                        },
                        .address => if (node.negative or (value.tag != .resolve and node.value >> 160 != 0)) {
                            return error.InvalidConstant;
                        },
                        .fixed_bytes => if (schema.width != 32 and node.value & ((@as(u256, 1) << @intCast(256 - bits)) - 1) != 0) {
                            return error.InvalidConstant;
                        },
                        else => {},
                    }
                }
                try l.tapeWord(tape, value, abi.scalarValidation(schema));
            },
        }
    }
    fn recursiveCall(l: *Lowerer, n: *Node, env: ?*const Env, target: *Node, selector: *Node, args: *Node, method: abi.Method) Error!*Node {
        const write = t.same(n.name, "$write");
        const read_words = t.same(n.name, "$readwords");
        if (method.selector != selector.value) return error.InvalidSettings;
        if ((write and (method.mutability == .pure or method.mutability == .view)) or (!write and method.mutability != .pure and method.mutability != .view)) return error.InvalidSettings;
        const payable = write and n.children.len == 4;
        if (payable and method.mutability != .payable) return error.InvalidSettings;
        var metadata: t.Abi = .{ .descriptor = method.descriptor, .target = target.value, .selector = method.selector };
        var tape: Tape = .{};
        if (args.tag == .application and t.same(args.name, "$abiargs")) {
            if (args.children.len != 2) return error.InvalidArguments;
            metadata.tape_source = 1;
            for (args.children) |c| try tape.words.append(l.f.a, try l.expr(c, env, false));
        } else {
            try l.lowerValue(args, method.root, env, &tape);
            metadata.descriptor = abi.precompiled(l.f.a, method.descriptor, tape.validations.items) catch |err| blk: {
                if (err != error.ResourceLimit) return err;
                break :blk method.descriptor;
            };
        }
        if (read_words) {
            const indices = try l.expand(n.children[3], env, 0);
            if (indices.tag != .list or indices.children.len == 0 or indices.children.len > 8) return error.InvalidArguments;
            const values = try l.f.a.alloc(u16, indices.children.len);
            for (indices.children, values, 0..) |c, *v, i| {
                const index = try l.literal(c, env, false);
                if (index > 65535 or (i > 0 and index <= values[i - 1])) return error.InvalidArguments;
                v.* = @intCast(index);
            }
            metadata.returns = values;
        }
        var children: std.ArrayList(*Node) = .empty;
        try children.appendSlice(l.f.a, &.{ try l.f.node(.target, &.{target}), selector });
        try children.appendSlice(l.f.a, tape.words.items);
        if (payable) try children.append(l.f.a, try l.expr(n.children[3], env, false));
        const groups = try l.f.a.alloc(t.Arg, tape.words.items.len);
        for (groups) |*group| group.* = .{ .data = metadata.tape_source == 0 };
        const out = try l.f.node(if (write) .write else .read, children.items);
        out.args = groups;
        out.abi = metadata;
        out.payable = payable;
        return out;
    }
    pub fn run(l: *Lowerer, program: t.Program) Error!*Node {
        l.definitions = try l.f.a.alloc(Definition, program.bindings.len);
        for (program.bindings, l.definitions) |binding, *d| d.* = .{ .binding = binding };
        try l.count(program.main, null);
        for (l.definitions) |*d| {
            d.runtime = d.count > 0 and (hasDeclaration(d.binding.value) or (d.count > 1 and try l.astEffect(d.binding.value, 0)));
            // User names never enter the IR binding namespace, where they could
            // otherwise capture generated strict locals or evaluation steps.
            if (d.runtime) d.internal_name = try l.f.fresh("definition");
        }
        // Lowering a demanded definition records dependency order independently
        // of source declaration order and keeps its own lexical environment.
        var root = try l.expr(program.main, null, false);
        var i = l.order.items.len;
        while (i > 0) {
            i -= 1;
            const d = l.definitions[l.order.items[i]];
            root = try @import("memo.zig").materialize(l.f, root, d.internal_name, d.lowered.?);
        }
        return dependencies(l.f, root);
    }
};

pub fn dependencies(f: *t.Factory, n: *Node) Error!*Node {
    const out = try f.clone(n);
    for (out.children) |*c| c.* = try dependencies(f, c.*);
    if ((out.tag != .read and out.tag != .write) or out.abi != null) return out;
    var result = out;
    var bindings: std.ArrayList(t.Binding) = .empty;
    for (out.children[0..2], 0..) |*c, i| if (t.effect(c.*)) {
        const name = try f.fresh("__eval");
        const value = c.*;
        const local = try f.named(.local, name, &.{});
        local.result = t.resultType(value);
        c.* = if (i == 0) try f.node(.target, &.{local}) else local;
        try bindings.append(f.a, .{ .name = name, .value = value });
    };
    var i = bindings.items.len;
    while (i > 0) {
        i -= 1;
        const b = bindings.items[i];
        result = try f.named(.let, b.name, &.{ b.value, result });
    }
    return result;
}
