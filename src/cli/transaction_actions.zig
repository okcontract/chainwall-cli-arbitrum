const std = @import("std");
const c = @import("common.zig");
const abi = @import("abi_codec.zig");
const rpc = @import("rpc.zig");
const watch = @import("transaction_watch.zig");
const fees = @import("transaction_fees.zig");
const Store = @import("store.zig").Store;
const Cast = @import("cast.zig").Cast;
const Args = @import("args.zig").Args;
const field = @import("commitment_codec.zig").field;
const string = @import("commitment_codec.zig").string;
fn bumped(value: u256, percent: u64) !u256 {
    return @max(try std.math.add(u256, value, 1), try std.math.divCeil(u256, try std.math.mul(u256, value, 100 + percent), 100));
}
fn replace(cast: *Cast, db: Store, tx_hash: []const u8, cancel: bool, bump: u64, out: ?[]const u8, dry: bool) !c.Value {
    if (cast.auth != null) return error.ReplacementRequiresFoundrySigner;
    if (cast.block != null) return error.TransactionRequiresLatestBlock;
    if (bump == 0 or bump > 1000) return error.InvalidReplacementBump;
    const a = cast.a;
    // Resolve the signer before observing pending state, so password prompts
    // cannot make an already-mined request appear safe to replace.
    const actor = if (dry) cast.from orelse try cast.signerAddress() else try cast.signerAddress();
    var remote = try rpc.Rpc.initEndpoint(a, cast.io, cast.rpc, cast.chain);
    defer remote.deinit();
    const original = try watch.observe(&remote, tx_hash, try watch.saved(db, cast.chain, tx_hash), 1, 0);
    try watch.save(db, cast.chain, original);
    if (!c.eq(u8, try string(original, "status"), "pending")) return error.TransactionNotPending;
    const tx = try field(original, "transaction");
    if (!watch.same(actor, try string(tx, "from"))) return error.SignerAddressMismatch;
    if ((c.field(tx, "blockHash") orelse c.Value.null) != .null) return error.TransactionNotPending;
    const kind = try c.number(a, c.field(tx, "type") orelse c.Value{ .string = "0" });
    if (kind > 2 or c.field(tx, "authorizationList") != null or c.field(tx, "blobVersionedHashes") != null) return error.UnsupportedTransactionType;
    const nonce = try rpc.integer(a, try field(tx, "nonce"));
    if (cast.nonce) |explicit| if (explicit != nonce) return error.ReplacementNonceMismatch;
    var sending = cast.*;
    sending.from = actor;
    sending.nonce = nonce;
    sending.block = null;
    const old_limit = try rpc.integer(a, try field(tx, "gas"));
    sending.fees.gas_limit = cast.fees.gas_limit orelse if (cancel) 21000 else old_limit;
    if (sending.fees.gas_limit.? < (if (cancel) @as(u64, 21000) else old_limit)) return error.ReplacementGasLimitTooLow;
    if (kind == 2) {
        if (cast.fees.legacy or cast.fees.gas_price != null) return error.ReplacementFeeModelMismatch;
        const minimum_max = try bumped(try c.number(a, try field(tx, "maxFeePerGas")), bump);
        const minimum_tip = try bumped(try c.number(a, try field(tx, "maxPriorityFeePerGas")), bump);
        const suggested = try fees.prices(&remote, .{});
        if (suggested.legacy) return error.ReplacementFeeModelMismatch;
        sending.fees.max_fee = cast.fees.max_fee orelse @max(minimum_max, suggested.maximum);
        sending.fees.priority_fee = cast.fees.priority_fee orelse @max(minimum_tip, suggested.priority);
        if (sending.fees.max_fee.? < minimum_max or sending.fees.priority_fee.? < minimum_tip) return error.ReplacementFeeBumpTooSmall;
    } else {
        if (cast.fees.max_fee != null or cast.fees.priority_fee != null) return error.ReplacementFeeModelMismatch;
        const minimum = try bumped(try c.number(a, try field(tx, "gasPrice")), bump);
        const suggested = try fees.prices(&remote, .{ .legacy = true });
        sending.fees.gas_price = cast.fees.gas_price orelse @max(minimum, suggested.maximum);
        sending.fees.legacy = true;
        if (sending.fees.gas_price.? < minimum) return error.ReplacementFeeBumpTooSmall;
    }
    try sending.fees.validate();
    const to = if (cancel) c.Value{ .string = actor } else c.field(tx, "to") orelse c.Value.null;
    const data = if (cancel) "0x" else try string(tx, "input");
    const value = if (cancel) try abi.uint(a, 0) else try field(tx, "value");
    if (cancel) {
        const next_nonce = try rpc.integer(a, try remote.one("eth_getTransactionCount", try abi.array(a, &.{ .{ .string = actor }, try remote.blockSelector() })));
        if (next_nonce != nonce) return error.CancellationRequiresNextNonce;
        // An EIP-7702 delegated sender can execute code on a self-transfer.
        // Cancellation is only an empty transfer to a currently plain EOA.
        const code = try remote.one("eth_getCode", try abi.array(a, &.{ .{ .string = actor }, try remote.blockSelector() }));
        if (!c.eq(u8, try c.string(code), "0x")) return error.CancellationRequiresPlainEOA;
    } else sending.access_list = c.field(tx, "accessList");
    if (sending.access_list) |list| if (list == .null) {
        sending.access_list = null;
    };
    var request = try c.parse(a, try c.encode(a, .{ .chainId = cast.chain, .from = actor, .to = to, .data = data, .value = value, .nonce = nonce }));
    if (sending.access_list) |list| try request.object.put(a, "accessList", list);
    request = try fees.normalize(&sending, request, actor);
    try sending.fees.overlay(a, &request);
    // eth_call checks the exact replacement payload without broadcasting. A
    // cancellation or reprice still competes with the original until mined.
    _ = try remote.one("eth_call", try abi.array(a, &.{ request, try remote.blockSelector() }));
    if (!try remote.canonical(remote.block)) return error.TransactionReorganized;
    var report = try c.parse(a, try c.encode(a, .{ .chainId = cast.chain, .originalHash = tx_hash, .action = if (cancel) "cancel" else "speed-up", .transaction = request, .block = remote.block, .bumpPercent = bump }));
    if (out) |file| try c.write(cast.io, file, try c.encode(a, report), false);
    if (dry) return report;
    // Check again immediately before handing the same nonce to Foundry.
    const final_state = try watch.observe(&remote, tx_hash, original, 1, 0);
    if (!c.eq(u8, try string(final_state, "status"), "pending")) return error.TransactionNotPending;
    if (cancel) {
        const code = try remote.one("eth_getCode", try abi.array(a, &.{ .{ .string = actor }, try remote.blockSelector() }));
        if (!c.eq(u8, try c.string(code), "0x")) return error.CancellationRequiresPlainEOA;
    }
    const receipt = if (to == .null) try sending.create(data, try c.scalar(a, value)) else blk: {
        sending.instance = try c.string(to);
        // The RPC above verified chain identity and the exact request. An EOA
        // recipient intentionally has no bytecode (including cancellation).
        sending.checked = true;
        break :blk try sending.send(data, try c.scalar(a, value));
    };
    try report.object.put(a, "receipt", receipt);
    if (out) |file| try c.write(cast.io, file, try c.encode(a, report), true);
    return report;
}
pub fn run(cast: *Cast, dir: []const u8, args: *Args, p: []const []const u8, dry: bool) !c.Value {
    const a = cast.a;
    const verb = p[1];
    const replacing = @import("schema.zig").contains("speed-up cancel", verb);
    const listing = c.eq(u8, verb, "list");
    const refresh_all = c.eq(u8, verb, "refresh") and p.len == 2;
    if (p.len != @as(usize, if (listing or refresh_all) 2 else 3)) return error.WrongArgumentCount;
    const out = args.get("out");
    const start = if (listing or refresh_all) try rpc.integer(a, .{ .string = args.get("start") orelse "0" }) else 0;
    const count = if (listing or refresh_all) try rpc.integer(a, .{ .string = args.get("count") orelse "100" }) else 100;
    const confirmations = if (!listing and !replacing) if (args.get("confirmations")) |n| try rpc.integer(a, .{ .string = n }) else cast.tx_confirmations else cast.tx_confirmations;
    const lookback = if (!listing and !replacing) try rpc.integer(a, .{ .string = args.get("lookback") orelse "64" }) else 64;
    const waiting = c.eq(u8, verb, "wait");
    const timeout = if (waiting) try rpc.integer(a, .{ .string = args.get("timeout") orelse "120" }) else 0;
    const poll = if (waiting) try rpc.integer(a, .{ .string = args.get("poll-interval") orelse "2" }) else 2;
    const bump = if (replacing) try rpc.integer(a, .{ .string = args.get("bump") orelse "15" }) else 15;
    try args.finish();
    if (count > 100 or confirmations == 0 or lookback > 1024 or timeout > 86400 or poll == 0 or poll > 60) return error.InvalidTransactionMonitorOptions;
    if (!replacing and dry) return error.DryRunNotApplicable;
    const db = try Store.open(a, cast.io, dir);
    defer db.close();
    if (replacing) return replace(cast, db, try watch.hash(a, p[2]), c.eq(u8, verb, "cancel"), bump, out, dry);
    const entries = try watch.list(db, cast.chain);
    var rows = std.json.Array.init(a);
    if (listing or refresh_all) {
        const offset = @min(start, entries.len);
        for (entries[offset..@min(offset + count, entries.len)]) |entry| {
            const report = if (listing) entry else watch.wait(cast, db, try string(entry, "hash"), 0, confirmations, lookback, poll) catch |err| {
                if (err == error.OutOfMemory) return err;
                try rows.append(try c.parse(a, try c.encode(a, .{ .hash = try field(entry, "hash"), .errorName = @errorName(err) })));
                continue;
            };
            try rows.append(report);
        }
    }
    const report = if (listing or refresh_all) try c.parse(a, try c.encode(a, .{ .chainId = cast.chain, .total = entries.len, .entries = rows.items })) else try watch.wait(cast, db, try watch.hash(a, p[2]), if (c.eq(u8, verb, "wait")) timeout else 0, confirmations, lookback, poll);
    if (out) |file| try c.write(cast.io, file, try c.encode(a, report), false);
    return report;
}
