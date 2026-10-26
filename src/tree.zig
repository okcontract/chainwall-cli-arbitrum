const std = @import("std");
pub const Allocator = std.mem.Allocator;
pub const Error = error{ OutOfMemory, Syntax, Unsupported, InvalidConstant, InvalidArguments, UnboundVariable, DuplicateBinding, CyclicDefinition, ConditionalMemo, InvalidType, StackCapacity, StackUnderflow, InvalidBytecode, InvalidDescriptor, InvalidSettings, ResourceLimit };

// Authoring bounds shared with bytecode reconstruction, independent of any
// larger frame a particular deployed VM might accept.
pub const limits = @import("limits.zig");

// Children are stored in source evaluation order. Call metadata describes the
// argument groups without introducing non-expression nodes into IR traversal.
pub const Tag = enum {
    number,
    string,
    variable,
    application,
    tuple,
    object,
    list,
    declaration,
    index,
    registry_reference,
    member_call,
    unit,
    constant,
    arg,
    local,
    let,
    add,
    sub,
    mul,
    div,
    mod,
    logical_and,
    logical_or,
    eq,
    neq,
    lt,
    gt,
    lte,
    gte,
    ratio,
    keccak,
    not,
    bitnot,
    sqrt,
    require,
    conditional,
    noop_then,
    seq,
    caller,
    this,
    time,
    balance,
    transfer_native,
    static_linked,
    subject,
    value_usd,
    resolve,
    target,
    price,
    read,
    write,
    calli,
    get_word,
};
pub const Arg = struct { count: usize = 1, array: bool = false, data: bool = false };
pub const Abi = struct { descriptor: []const u8, target: u256, selector: u32, tape_source: u8 = 0, returns: []const u16 = &.{} };
pub const Type = enum { word, boolean, unit, mixed, words1, words2, words3, words4, words5, words6, words7, words8 };
/// Byte offsets into the original UTF-8 source. Generated IR has empty spans;
/// source positions never participate in lowering or bytecode generation.
pub const Span = struct { start: usize = 0, end: usize = 0 };
/// Diagnostics borrow no arena memory. Spans are half-open UTF-8 byte offsets
/// in the source passed to compileDetailed; strings have static lifetime.
pub const Diagnostic = struct {
    phase: enum { parse, settings, lower, validate, normalize, generate, optimize } = .parse,
    code: []const u8 = "",
    message: []const u8 = "",
    primary: ?Span = null,
    related: ?Span = null,
    pub fn locate(d: *Diagnostic, span: Span) void {
        if (d.primary == null) d.primary = span;
    }
    pub fn record(d: *Diagnostic, span: Span, err: anyerror) void {
        if (d.code.len != 0) return;
        d.code = @errorName(err);
        d.locate(span);
        d.message = switch (err) {
            error.Syntax => "Expected a valid expression, binding, or closing delimiter here.",
            error.InvalidConstant => "This value must be an exact integer within the required unsigned range.",
            error.UnboundVariable => "This name has no visible binding.",
            error.DuplicateBinding => "This binding repeats a name already declared in the same scope.",
            error.CyclicDefinition => "This definition depends on itself through a binding cycle.",
            error.InvalidArguments => "Arguments do not match the function's required count or shape.",
            error.InvalidType => "This expression's result type is not valid in this position.",
            error.InvalidSettings => "A compiler setting is unknown, malformed, or inconsistent with ABI metadata.",
            error.InvalidDescriptor => "ABI metadata cannot be represented by this compiler.",
            error.StackCapacity => "This expression needs more accessible stack slots than the VM supports.",
            error.ResourceLimit => "The program exceeds a compiler resource limit.",
            else => @errorName(err),
        };
    }
};
pub const Node = struct {
    tag: Tag,
    children: []*Node = &.{},
    name: []const u8 = "",
    // Retain parser spelling for syntax export; lookup uses the normalized name.
    spelling: []const u8 = "",
    span: Span = .{},
    name_span: Span = .{},
    // Surface overload selection uses exact ABI annotations, not runtime casts.
    type_hint: ?[]const u8 = null,
    value: u256 = 0,
    negative: bool = false,
    data: bool = false,
    mask: u16 = 0,
    args: []const Arg = &.{},
    payable: bool = false,
    abi: ?Abi = null,
    result: Type = .word,
};
pub const Binding = struct { name: []const u8, value: *Node, spelling: []const u8 = "", name_span: Span = .{} };
pub const Program = struct { bindings: []const Binding, main: *Node };
/// Arena-oriented graph allocation. Nodes and copied child slices belong to a;
/// named() borrows the name and child nodes. clone() is shallow: names, metadata,
/// and descendants retain their original lifetimes. There is no recursive free.
pub const Factory = struct {
    a: Allocator,
    origin: Span = .{},
    diagnostic: ?*Diagnostic = null,
    next: usize = 0,
    created: usize = 0,
    fn allocate(f: *Factory) Error!*Node {
        // Rewriting may expand a small input quadratically. Limit total work,
        // including discarded intermediate trees, within one operation.
        if (f.created >= limits.factory_nodes) return error.ResourceLimit;
        f.created += 1;
        return f.a.create(Node);
    }
    pub fn node(f: *Factory, tag: Tag, children: []const *Node) Error!*Node {
        const n = try f.allocate();
        n.* = .{ .tag = tag, .children = try f.a.dupe(*Node, children), .span = f.origin };
        return n;
    }
    pub fn num(f: *Factory, value: u256) Error!*Node {
        const n = try f.node(.constant, &.{});
        n.value = value;
        return n;
    }
    pub fn named(f: *Factory, tag: Tag, name: []const u8, children: []const *Node) Error!*Node {
        const n = try f.node(tag, children);
        n.name = name;
        return n;
    }
    pub fn clone(f: *Factory, n: *const Node) Error!*Node {
        const copy = try f.allocate();
        copy.* = n.*;
        copy.children = try f.a.dupe(*Node, n.children);
        return copy;
    }
    pub fn fresh(f: *Factory, prefix: []const u8) Error![]const u8 {
        const name = try f.a.print("${s}{d}", .{ prefix, f.next });
        f.next += 1;
        return name;
    }
    pub fn sequence(f: *Factory, items: []const *Node) Error!*Node {
        return if (items.len == 1) items[0] else f.node(.seq, items);
    }
};
pub fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
pub fn atomic(n: *const Node) bool {
    return switch (n.tag) {
        .constant, .arg, .local, .caller, .this, .time, .unit => true,
        else => false,
    };
}
pub fn effect(n: *const Node) bool {
    switch (n.tag) {
        .read, .write, .require, .ratio, .resolve, .balance, .price, .calli, .static_linked, .subject, .value_usd, .transfer_native => return true,
        else => {},
    }
    for (n.children) |c| if (effect(c)) return true;
    return false;
}
pub fn uses(n: *const Node, name: []const u8) usize {
    if (n.tag == .local) return @intFromBool(same(n.name, name));
    var count: usize = 0;
    for (n.children) |c| count += uses(c, name);
    return count;
}
pub fn replace(f: *Factory, n: *Node, name: []const u8, value: *Node) Error!*Node {
    if (n.tag == .local and same(n.name, name)) return value;
    const out = try f.clone(n);
    for (out.children) |*c| c.* = try replace(f, c.*, name, value);
    return out;
}
pub fn wordCount(t: Type) usize {
    return switch (t) {
        .unit => 0,
        .words1, .words2, .words3, .words4, .words5, .words6, .words7, .words8 => @backingInt(t) - @backingInt(Type.words1) + 1,
        else => 1,
    };
}
pub fn resultType(n: *const Node) Type {
    return switch (n.tag) {
        .unit, .require => .unit,
        .constant => if (n.value <= 1) .boolean else .word,
        .local => n.result,
        .let => resultType(n.children[1]),
        .seq => if (n.children.len == 0) .boolean else resultType(n.children[n.children.len - 1]),
        .conditional => blk: {
            const a = resultType(n.children[1]);
            const b = resultType(n.children[2]);
            break :blk if (a == b) a else if (wordCount(a) == 1 and wordCount(b) == 1 and a != .mixed and b != .mixed and @backingInt(a) < 4 and @backingInt(b) < 4) .word else .mixed;
        },
        .noop_then => if (resultType(n.children[1]) == .unit) .unit else .mixed,
        .eq, .neq, .lt, .gt, .lte, .gte, .logical_and, .logical_or, .not => .boolean,
        .target => resultType(n.children[0]),
        .read => if (n.abi) |abi| if (abi.returns.len > 0) @fromBackingInt(@intCast(@backingInt(Type.words1) + abi.returns.len - 1)) else .word else .word,
        else => .word,
    };
}
