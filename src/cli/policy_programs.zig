const std = @import("std");
const ms = @import("miniscript");
const c = @import("common.zig");
const abi = @import("abi_codec.zig");
const contracts = @import("contracts.zig");
const rpc = @import("rpc.zig");
const programs = @import("programs.zig");
const Cast = @import("cast.zig").Cast;
const Args = @import("args.zig").Args;

fn field(value: c.Value, name: []const u8) !c.Value {
    return c.field(value, name) orelse error.InvalidPolicyProgram;
}
pub fn templates(cast: *Cast, cat: contracts.Catalog, args: *Args, p: []const []const u8) !c.Value {
    const a = cast.a;
    const out = args.get("out");
    var interactions: std.ArrayList([]const u8) = .empty;
    for (args.options) |*option| if (!option.used and c.eq(u8, option.key, "interaction")) {
        option.used = true;
        try interactions.append(a, try c.id(a, option.value));
    };
    try args.finish();
    const catalog = try c.parse(a, @embedFile("artifacts/policy-templates.json"));
    if (p.len == 2) {
        if (out != null or interactions.items.len != 0) return error.WrongArgumentCount;
        var list = std.json.Array.init(a);
        for (catalog.array.items) |template| try list.append(try c.parse(a, try c.encode(a, .{ .id = try field(template, "id"), .label = try field(template, "label"), .description = try field(template, "description"), .context = try field(template, "context") })));
        return .{ .array = list };
    }
    if (p.len != 3) return error.WrongArgumentCount;
    var template: c.Value = .null;
    for (catalog.array.items) |item| if (c.eq(u8, p[2], try c.string(try field(item, "id")))) {
        template = item;
        break;
    };
    if (template == .null) return error.UnknownPolicyTemplate;
    var source = try c.string(try field(template, "source"));
    const needs_ids = std.mem.indexOf(u8, source, "__INTERACTION_") != null;
    if ((needs_ids and interactions.items.len != 2) or (!needs_ids and interactions.items.len != 0)) return error.PolicyTemplateRequiresTwoInteractions;
    if (needs_ids and c.eq(u8, interactions.items[0], interactions.items[1])) return error.DuplicatePolicyTemplateInteraction;
    if (std.mem.indexOf(u8, source, "__REGISTRY__") != null) {
        try c.address(cast.instance);
        source = try std.mem.replaceOwned(u8, a, source, "__REGISTRY__", try c.hex(a, try c.word(cast.instance)));
    }
    if (needs_ids) for ([_][]const u8{ "__INTERACTION_A__", "__INTERACTION_B__" }, interactions.items) |marker, id| {
        source = try std.mem.replaceOwned(u8, a, source, marker, id);
    };
    if (std.mem.indexOf(u8, source, "__CONTENT_") != null) {
        var remote = try rpc.Rpc.init(a, cast.io, cast.rpc, cast.chain, cast.instance);
        defer remote.deinit();
        try remote.pin(cast.block, 0);
        for ([_][]const u8{ "__CONTENT_A__", "__CONTENT_B__" }, interactions.items) |marker, id| {
            const hash = try remote.namedAt(cast.instance, try cat.find("registry", "getInteractionContentHash"), &.{.{ .string = id }});
            const text = try c.string(hash);
            if (try c.word(text) == 0) return error.PolicyTemplateInteractionMissing;
            source = try std.mem.replaceOwned(u8, a, source, marker, text);
        }
        if (!try remote.canonical(remote.block)) return error.ChainReorganizedRetrySync;
        try template.object.put(a, "block", try c.parse(a, try c.encode(a, remote.block)));
    }
    try template.object.put(a, "source", .{ .string = source });
    if (out) |path| try c.write(cast.io, path, source, false);
    return template;
}

pub fn run(compiler: *programs.Compiler, args: *Args, p: []const []const u8, policy_id: []const u8, dry: bool) !c.Value {
    const cast = compiler.cast;
    const a = cast.a;
    const verb = p[2];
    const compile = c.eq(u8, verb, "compile");
    const publish = c.eq(u8, verb, "publish");
    const clear = c.eq(u8, verb, "clear");
    if (!compile and !publish and !clear and !c.eq(u8, verb, "inspect")) return error.UnknownPolicyProgramCommand;
    if (p.len != (if (publish) @as(usize, 5) else 4)) return error.WrongArgumentCount;
    const out = args.get("out");
    const max_steps: u32 = if (publish) try std.fmt.parseInt(u32, args.get("max-steps") orelse "100000", 10) else 0;
    if (publish and max_steps == 0) return error.InvalidMaxSteps;
    var program: c.Value = .null;
    if (compile or publish) {
        const path = p[if (publish) @as(usize, 4) else 3];
        program = if (std.mem.endsWith(u8, path, ".ls")) try compiler.compile(path, args) else blk: {
            try args.finish();
            break :blk try @import("json_schema.zig").read(a, cast.io, "policy-program", path);
        };
        if (!c.eq(u8, try c.string(try field(try field(program, "settings"), "argumentContext")), "frame")) return error.PolicyProgramRequiresFrameContext;
        const bytecode = try abi.unhex(a, try c.string(try field(program, "bytecode")));
        if (bytecode.len == 0) return error.EmptyPolicyProgram;
        const analysis = try @import("program_analysis.zig").analyze(a, bytecode, .{});
        if (!(try field(analysis, "valid")).bool) return error.MiniScriptAnalysisFailed;
        try program.object.put(a, "analysis", analysis);
        try program.object.put(a, "bytecodeHash", .{ .string = try c.hex(a, ms.bytecode.hash(bytecode)) });
    } else try args.finish();
    if (compile) {
        if (out) |path| try c.write(cast.io, path, try c.encode(a, program), false);
        return program;
    }
    if (!dry and (publish or clear) and cast.block != null) return error.TransactionRequiresLatestBlock;
    var remote = try rpc.Rpc.init(a, cast.io, cast.rpc, cast.chain, cast.instance);
    defer remote.deinit();
    try remote.pin(cast.block, 0);
    const method = try compiler.cat.find("registry", "getPolicy");
    const previous = try remote.namedAt(cast.instance, method, &.{.{ .string = policy_id }});
    var report = try c.parse(a, try c.encode(a, .{ .chainId = cast.chain, .registry = cast.instance, .policyId = policy_id, .block = remote.block, .policy = previous }));
    if (!publish and !clear) {
        if (!try remote.canonical(remote.block)) return error.ChainReorganizedRetrySync;
        if (out) |path| try c.write(cast.io, path, try c.encode(a, report), false);
        return report;
    }
    const write = try compiler.cat.find("registry", if (publish) "setPolicyProgram" else "clearPolicyProgram");
    const values = if (publish) try abi.array(a, &.{ .{ .string = policy_id }, try field(program, "bytecode"), try abi.uint(a, max_steps) }) else try abi.array(a, &.{.{ .string = policy_id }});
    const data = try abi.calldata(a, write.abi, values);
    try report.object.put(a, "program", program);
    try report.object.put(a, "transaction", try c.parse(a, try c.encode(a, .{ .to = cast.instance, .data = data, .value = "0", .nonce = cast.nonce })));
    if (!try remote.canonical(remote.block)) return error.ChainReorganizedRetrySync;
    if (out) |path| try c.write(cast.io, path, try c.encode(a, report), false);
    if (dry) return report;
    const actor = try cast.signerAddress();
    try remote.pin(null, 0);
    const current = try remote.namedAt(cast.instance, method, &.{.{ .string = policy_id }});
    if (try c.number(a, try field(previous, "version")) != try c.number(a, try field(current, "version"))) return error.PolicyProgramChanged;
    _ = try remote.one("eth_call", try abi.array(a, &.{ try c.parse(a, try c.encode(a, .{ .from = actor, .to = cast.instance, .data = data })), try remote.blockSelector() }));
    if (!try remote.canonical(remote.block)) return error.ChainReorganizedRetrySync;
    const receipt = try cast.send(data, null);
    try report.object.put(a, "receipt", receipt);
    if (out) |path| try c.write(cast.io, path, try c.encode(a, report), true);
    try report.object.put(a, "outcome", try c.parse(a, try c.encode(a, try @import("receipts.zig").classify(a, compiler.cat, receipt, cast.instance, write, &.{}))));
    if (out) |path| try c.write(cast.io, path, try c.encode(a, report), true);
    return report;
}
