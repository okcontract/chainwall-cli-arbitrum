const std = @import("std");
const c = @import("common.zig");
const abi = @import("abi_codec.zig");
const rpc = @import("rpc.zig");
const amounts = @import("amounts.zig");
const Cast = @import("cast.zig").Cast;
pub const Options = struct {
    gas_limit: ?u64 = null,
    gas_price: ?u256 = null,
    max_fee: ?u256 = null,
    priority_fee: ?u256 = null,
    legacy: bool = false,

    pub fn supplied(o: Options) bool {
        return o.gas_limit != null or o.gas_price != null or o.max_fee != null or o.priority_fee != null or o.legacy;
    }
    pub fn validate(o: Options) !void {
        if (o.gas_limit == 0) return error.InvalidGasLimit;
        if ((o.legacy or o.gas_price != null) and (o.max_fee != null or o.priority_fee != null)) return error.ConflictingFeeOptions;
        if (o.max_fee) |max| if (o.priority_fee) |tip| if (tip > max) return error.PriorityFeeExceedsMaximum;
    }
    pub fn parse(args: *@import("args.zig").Args) !Options {
        const o: Options = .{
            .gas_limit = if (args.get("gas-limit")) |value| std.math.cast(u64, try c.word(value)) orelse return error.InvalidGasLimit else null,
            .gas_price = if (args.get("gas-price")) |value| try amounts.native(value) else null,
            .max_fee = if (args.get("max-fee")) |value| try amounts.native(value) else null,
            .priority_fee = if (args.get("priority-fee")) |value| try amounts.native(value) else null,
            .legacy = args.flag("legacy"),
        };
        try o.validate();
        return o;
    }
    pub fn append(o: Options, a: c.A, args: *std.ArrayList([]const u8)) !void {
        try o.validate();
        if (o.gas_limit) |value| try args.appendSlice(a, &.{ "--gas-limit", try a.print("{d}", .{value}) });
        if (o.gas_price orelse o.max_fee) |value| try args.appendSlice(a, &.{ "--gas-price", try a.print("{d}", .{value}) });
        if (o.priority_fee) |value| try args.appendSlice(a, &.{ "--priority-gas-price", try a.print("{d}", .{value}) });
        if (o.legacy or o.gas_price != null) try args.append(a, "--legacy");
    }
    pub fn overlay(o: Options, a: c.A, tx: *c.Value) !void {
        if (o.gas_limit) |n| try tx.object.put(a, "gas", try quantity(a, n));
        if (o.gas_price) |n| try tx.object.put(a, "gasPrice", try quantity(a, n));
        if (o.max_fee) |n| try tx.object.put(a, "maxFeePerGas", try quantity(a, n));
        if (o.priority_fee) |n| try tx.object.put(a, "maxPriorityFeePerGas", try quantity(a, n));
        if (o.legacy or o.gas_price != null) try tx.object.put(a, "type", try quantity(a, 0));
    }
    fn fromRequest(o: Options, a: c.A, tx: c.Value) !Options {
        var result = o;
        if (o.gas_limit == null) if (c.field(tx, "gas")) |n| {
            result.gas_limit = try rpc.integer(a, n);
        };
        if (o.gas_price == null) if (c.field(tx, "gasPrice")) |n| {
            result.gas_price = try amounts.native(try c.scalar(a, n));
        };
        if (o.max_fee == null) if (c.field(tx, "maxFeePerGas")) |n| {
            result.max_fee = try amounts.native(try c.scalar(a, n));
        };
        if (o.priority_fee == null) if (c.field(tx, "maxPriorityFeePerGas")) |n| {
            result.priority_fee = try amounts.native(try c.scalar(a, n));
        };
        if (c.field(tx, "type")) |n| {
            const kind = try c.number(a, n);
            if (kind > 2) return error.UnsupportedTransactionType;
            if (kind < 2) result.legacy = true;
        }
        try result.validate();
        return result;
    }
};
fn field(value: c.Value, name: []const u8) !c.Value {
    return c.field(value, name) orelse error.InvalidTransactionPreview;
}
fn quantity(a: c.A, n: u256) !c.Value {
    return .{ .string = try a.print("0x{x}", .{n}) };
}
pub fn request(value: c.Value) !c.Value {
    const root = c.field(value, "prepared") orelse value;
    const tx = c.field(root, "transaction") orelse root;
    if (tx != .object or c.field(tx, "data") == null) return error.TransactionPreviewRequired;
    return tx;
}
/// Read only the transaction envelope, never interpret the dry-run report as
/// authorization to sign. Chain and sender bindings remain explicit.
pub fn normalize(cast: *Cast, input: c.Value, from: []const u8) !c.Value {
    const a = cast.a;
    const tx = try request(input);
    if (c.field(input, "chainId")) |chain| if (try c.number(a, chain) != cast.chain) return error.TransactionChainMismatch;
    for ([_][]const u8{ "authorizationList", "blobVersionedHashes", "maxFeePerBlobGas" }) |name| if (c.field(tx, name) != null) return error.UnsupportedTransactionType;
    if (c.field(tx, "chainId")) |chain| if (try c.number(a, chain) != cast.chain) return error.TransactionChainMismatch;
    try c.address(from);
    if (c.field(tx, "from")) |sender| if (sender != .null and !std.ascii.eqlIgnoreCase(try c.string(sender), from)) return error.SignerAddressMismatch;
    const data = try c.string(try field(tx, "data"));
    if ((try abi.unhex(a, data)).len > 1024 * 1024) return error.TransactionTooLarge;
    const value = try amounts.native(try c.scalar(a, c.field(tx, "value") orelse c.Value{ .string = "0" }));
    var result = try c.parse(a, try c.encode(a, .{ .from = from, .data = data, .value = try quantity(a, value) }));
    if (c.field(tx, "to")) |to| {
        if (to != .null) {
            try c.address(try c.string(to));
            try result.object.put(a, "to", to);
        }
    }
    if (c.field(result, "to") == null and data.len == 2) return error.EmptyDeploymentBytecode;
    if (c.field(tx, "accessList")) |list| {
        if (list != .array or list.array.items.len > 1024) return error.InvalidAccessList;
        for (list.array.items) |entry| {
            try c.address(try c.string(try field(entry, "address")));
            const keys = try field(entry, "storageKeys");
            if (keys != .array or keys.array.items.len > 1024) return error.InvalidAccessList;
            for (keys.array.items) |key| if ((try abi.unhex(a, try c.string(key))).len != 32) return error.InvalidAccessList;
        }
        try result.object.put(a, "accessList", list);
    }
    const nonce = if (cast.nonce) |n| try abi.uint(a, n) else c.field(tx, "nonce") orelse c.Value.null;
    if (nonce != .null) try result.object.put(a, "nonce", try quantity(a, try rpc.integer(a, nonce)));
    return result;
}
pub const Prices = struct { legacy: bool, base: u256, maximum: u256, priority: u256, expected: u256 };
pub fn gasLimit(estimated: u64, explicit: ?u64) !u64 {
    const limit = explicit orelse try std.math.add(u64, estimated, try std.math.divCeil(u64, estimated, 5));
    if (limit < estimated) return error.GasLimitBelowEstimate;
    return limit;
}
pub fn prices(remote: *rpc.Rpc, options: Options) !Prices {
    const a = remote.a;
    try options.validate();
    const block = try remote.one("eth_getBlockByNumber", try abi.array(a, &.{ .{ .string = try rpc.quantity(a, remote.block.number) }, .{ .bool = false } }));
    if (!std.ascii.eqlIgnoreCase(try c.string(try field(block, "hash")), remote.block.hash)) return error.ChainReorganizedRetrySync;
    const base_value = c.field(block, "baseFeePerGas") orelse c.Value.null;
    const legacy = options.legacy or options.gas_price != null or base_value == .null;
    if (legacy) {
        if (options.max_fee != null or options.priority_fee != null) return error.ChainDoesNotSupportDynamicFees;
        const price = options.gas_price orelse try c.number(a, try remote.one("eth_gasPrice", try abi.array(a, &.{})));
        return .{ .legacy = true, .base = 0, .maximum = price, .priority = 0, .expected = price };
    }
    const base = try c.number(a, base_value);
    const priority = options.priority_fee orelse blk: {
        const suggested = remote.one("eth_maxPriorityFeePerGas", try abi.array(a, &.{})) catch |err| {
            if (err != error.RpcRejectedRequest) return err;
            const gas_price = try c.number(a, try remote.one("eth_gasPrice", try abi.array(a, &.{})));
            break :blk gas_price -| base;
        };
        break :blk try c.number(a, suggested);
    };
    const maximum = options.max_fee orelse try std.math.add(u256, try std.math.mul(u256, base, 2), priority);
    if (priority > maximum) return error.PriorityFeeExceedsMaximum;
    if (maximum < base) return error.MaxFeeBelowCurrentBaseFee;
    return .{ .legacy = false, .base = base, .maximum = maximum, .priority = priority, .expected = @min(maximum, try std.math.add(u256, base, priority)) };
}
pub fn estimate(cast: *Cast, input: c.Value) !c.Value {
    if (cast.auth != null) return error.EstimateRequiresOuterTransaction;
    const a = cast.a;
    const from = try cast.callerAddress();
    const options = try cast.fees.fromRequest(a, try request(input));
    var tx = try normalize(cast, input, from);
    var remote = try rpc.Rpc.initEndpoint(a, cast.io, cast.rpc, cast.chain);
    defer remote.deinit();
    try remote.pinBlock(cast.block, 0);
    const fees = try prices(&remote, options);
    if (fees.legacy) {
        try tx.object.put(a, "gasPrice", try quantity(a, fees.maximum));
    } else {
        try tx.object.put(a, "maxFeePerGas", try quantity(a, fees.maximum));
        try tx.object.put(a, "maxPriorityFeePerGas", try quantity(a, fees.priority));
    }
    if (options.gas_limit) |limit| try tx.object.put(a, "gas", try quantity(a, limit));
    // Numeric block selectors are broadly supported for estimateGas. Verify
    // the canonical hash on both sides to detect a change at that height.
    const gas = try rpc.integer(a, try remote.one("eth_estimateGas", try abi.array(a, &.{ tx, .{ .string = try rpc.quantity(a, remote.block.number) } })));
    const limit = try gasLimit(gas, options.gas_limit);
    const balance = try c.number(a, try remote.one("eth_getBalance", try abi.array(a, &.{ .{ .string = from }, try remote.blockSelector() })));
    if (!try remote.canonical(remote.block)) return error.ChainReorganizedRetrySync;
    const expected = try std.math.mul(u256, gas, fees.expected);
    const maximum = try std.math.mul(u256, limit, fees.maximum);
    const total = try std.math.add(u256, maximum, try c.number(a, try field(tx, "value")));
    try tx.object.put(a, "gas", try quantity(a, limit));
    return c.parse(a, try c.encode(a, .{ .chainId = cast.chain, .transaction = tx, .block = remote.block, .estimatedGas = gas, .gasLimit = limit, .feeModel = if (fees.legacy) "legacy" else "eip1559", .baseFeePerGas = try abi.uint(a, fees.base), .maxFeePerGas = try abi.uint(a, fees.maximum), .maxPriorityFeePerGas = try abi.uint(a, fees.priority), .estimatedTransactionFeeWei = try abi.uint(a, expected), .maximumTransactionFeeWei = try abi.uint(a, maximum), .maximumValueAndFeeWei = try abi.uint(a, total), .balanceWei = try abi.uint(a, balance), .balanceSufficient = balance >= total, .feeScope = if (cast.chain == 42161) "arbitrum-total-transaction-fee" else "rpc-gas-estimate" }));
}
