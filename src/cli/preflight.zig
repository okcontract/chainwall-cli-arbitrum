const std = @import("std");
const c = @import("common.zig");
const abi = @import("abi_codec.zig");
const rpc = @import("rpc.zig");
const contracts = @import("contracts.zig");
const Cast = @import("cast.zig").Cast;
const Client = @import("contract_client.zig").Client;
const Args = @import("args.zig").Args;

fn call(remote: *rpc.Rpc, tx: c.Value, from: []const u8) !c.Value {
    const a = remote.a;
    try c.address(from);
    const wire = try c.parse(a, try c.encode(a, .{ .from = from, .to = c.field(tx, "to").?, .data = c.field(tx, "data").?, .value = try a.print("0x{x}", .{try c.number(a, c.field(tx, "value") orelse c.Value{ .string = "0" })}) }));
    const result = remote.one("eth_call", try abi.array(a, &.{ wire, try remote.blockSelector() })) catch |err| {
        if (err != error.RpcRejectedRequest) return err;
        const failure = remote.last_error orelse return err;
        return c.parse(a, try c.encode(a, .{ .ok = false, .transaction = wire, .block = remote.block, .rpcError = failure, .revert = c.field(failure, "detail") orelse .null }));
    };
    return c.parse(a, try c.encode(a, .{ .ok = true, .transaction = wire, .block = remote.block, .result = result }));
}

pub fn operation(client: Client, registry: []const u8, args: *Args, file: []const u8) !c.Value {
    const cast = client.cast;
    const a = cast.a;
    const out = args.get("out");
    var remote = try rpc.Rpc.init(a, cast.io, cast.rpc, cast.chain, cast.instance);
    defer remote.deinit();
    try remote.pin(cast.block, 0);
    const previous = cast.block;
    cast.block = try rpc.quantity(a, remote.block.number);
    defer cast.block = previous;
    try client.boundInteract(registry);
    const from = try cast.callerAddress();
    const prepared = try @import("operation_actions.zig").execute(client, args, file, "execute", true);
    const transaction = c.field(prepared, "transaction") orelse prepared;
    var result = try call(&remote, transaction, from);
    // Safe may return false without reverting its outer call.
    if (c.field(prepared, "safeNonce") != null and c.field(result, "ok").?.bool) {
        const method = try client.cat.find("safe", "execTransaction");
        const decoded = try abi.decode(a, c.field(method.abi, "outputs").?, try abi.unhex(a, try c.string(c.field(result, "result").?)));
        if (decoded != .array or decoded.array.items.len != 1 or decoded.array.items[0] != .bool) return error.InvalidContractResponse;
        try result.object.put(a, "ok", decoded.array.items[0]);
        try result.object.put(a, "safeSuccess", decoded.array.items[0]);
    }
    if (!try remote.canonical(remote.block)) return error.ChainReorganizedRetrySync;
    try result.object.put(a, "prepared", prepared);
    if (out) |path| try c.write(cast.io, path, try c.encode(a, result), true);
    return result;
}

pub fn policy(client: Client, registry: []const u8, args: *Args, file: []const u8) !c.Value {
    const cast = client.cast;
    const a = cast.a;
    const out = args.get("out");
    try args.finish();
    const input = try @import("json_schema.zig").read(a, cast.io, "policy-simulation", file);
    return policyInput(client, registry, input, out);
}

pub fn policyInput(client: Client, registry: []const u8, input: c.Value, out: ?[]const u8) !c.Value {
    const cast = client.cast;
    const a = cast.a;
    const method = try client.cat.find("interact", "simulatePolicyProgram");
    const transaction = try c.parse(a, try c.encode(a, .{ .to = cast.instance, .data = try abi.calldata(a, method.abi, input), .value = "0" }));
    var remote = try rpc.Rpc.init(a, cast.io, cast.rpc, cast.chain, cast.instance);
    defer remote.deinit();
    try remote.pin(cast.block, 0);
    const previous = cast.block;
    cast.block = try rpc.quantity(a, remote.block.number);
    defer cast.block = previous;
    try client.boundInteract(registry);
    // The protocol always reverts, including success, rolling back all effects.
    // Match the app's sender and decode the generated ABI's success sentinel.
    var result = try call(&remote, transaction, cast.instance);
    var accepted = false;
    const reverted = c.field(result, "revert") orelse c.Value.null;
    const name = c.string(c.field(reverted, "name") orelse .null) catch "";
    if (!c.field(result, "ok").?.bool and c.eq(u8, name, "PolicyProgramSimulationResult") and (c.field(reverted, "decoded") orelse c.Value{ .bool = false }).bool) {
        const top = c.field(c.field(reverted, "namedArgs").?, "stackTop").?;
        accepted = try c.number(a, top) != 0;
        try result.object.put(a, "stackTop", top);
        // A sentinel revert is a completed policy simulation, not an RPC fault.
        _ = result.object.orderedRemove("rpcError");
    }
    try result.object.put(a, "ok", .{ .bool = accepted });
    if (!try remote.canonical(remote.block)) return error.ChainReorganizedRetrySync;
    if (out) |path| try c.write(cast.io, path, try c.encode(a, result), true);
    return result;
}
