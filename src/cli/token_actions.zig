const std = @import("std");
const ms = @import("miniscript");
const c = @import("common.zig");
const abi = @import("abi_codec.zig");
const contracts = @import("contracts.zig");
const rpc = @import("rpc.zig");
const Cast = @import("cast.zig").Cast;
const Args = @import("args.zig").Args;
const zero = "0x0000000000000000000000000000000000000000";

fn field(value: c.Value, name: []const u8) !c.Value {
    return c.field(value, name) orelse error.InvalidTokenMetadata;
}
fn precision(a: c.A, value: c.Value) !c.Value {
    const number = try c.number(a, value);
    if (number > 36) return error.TokenDecimalsTooHigh;
    return abi.uint(a, number);
}
fn symbol(a: c.A, remote: *rpc.Rpc, cat: contracts.Catalog, address: []const u8) ![]const u8 {
    const method = try cat.find("erc20", "symbol");
    const data = try abi.calldata(a, method.abi, try abi.array(a, &.{}));
    const encoded = try remote.one("eth_call", try abi.array(a, &.{ try c.parse(a, try c.encode(a, .{ .to = address, .data = data })), try remote.blockSelector() }));
    const bytes = try abi.unhex(a, try c.string(encoded));
    // Legacy ERC20s return bytes32 under the same symbol() selector.
    if (bytes.len == 32) return std.mem.trimEnd(u8, bytes, &.{0});
    return c.string((try abi.decode(a, c.field(method.abi, "outputs").?, bytes)).array.items[0]);
}

pub fn validateFeed(remote: *rpc.Rpc, cat: contracts.Catalog, registry: []const u8, address: []const u8, maximum_age: ?u64) !c.Value {
    const a = remote.a;
    try c.address(address);
    if (try c.word(address) == 0) return error.PriceFeedRequired;
    const feed_cat = try contracts.Catalog.loadNativePrice(a);
    const age_limit = maximum_age orelse try rpc.integer(a, try remote.namedAt(registry, try cat.find("tokens", "getFeedMaxAge"), &.{.{ .string = address }}));
    if (age_limit == 0) return error.PriceFeedHeartbeatRequired;
    const ceiling = try c.number(a, try remote.namedAt(registry, try cat.find("tokens", "getMaxFeedStaleness"), &.{}));
    const decimals = try precision(a, try remote.namedAt(address, try feed_cat.find("chainlink", "decimals"), &.{}));
    const round = try remote.namedAt(address, try feed_cat.find("chainlink", "latestRoundData"), &.{});
    if (try std.fmt.parseInt(i256, try c.scalar(a, try field(round, "answer")), 10) <= 0) return error.PriceFeedAnswerInvalid;
    if (try c.number(a, try field(round, "answeredInRound")) < try c.number(a, try field(round, "roundId"))) return error.PriceFeedRoundIncomplete;
    const updated = try c.number(a, try field(round, "updatedAt"));
    if (updated == 0 or updated > remote.block.timestamp) return error.PriceFeedTimestampInvalid;
    const age = remote.block.timestamp - updated;
    if (age > age_limit or (ceiling != 0 and age > ceiling)) return error.PriceFeedStale;
    return c.parse(a, try c.encode(a, .{ .address = address, .decimals = decimals, .round = round, .age = try abi.uint(a, age), .maxAge = age_limit, .globalMaxAge = try abi.uint(a, ceiling) }));
}

pub fn run(cast: *Cast, cat: contracts.Catalog, args: *Args, reference: []const u8, verb: []const u8, dry: bool) !c.Value {
    const a = cast.a;
    const configure = c.eq(u8, verb, "configure");
    const validate = c.eq(u8, verb, "validate-feed");
    const out = args.get("out");
    const symbol_override = if (configure) args.get("symbol") else null;
    const decimals_override = if (configure) args.get("decimals") else null;
    const feed_override = if (configure) args.get("price-feed") else null;
    const max_age_text = if (configure) args.get("feed-max-age") else if (validate) args.get("max-age") else null;
    const max_age = if (max_age_text) |text| try std.fmt.parseInt(u64, text, 10) else null;
    if (max_age == 0) return error.PriceFeedHeartbeatRequired;
    try args.finish();
    if (configure and !dry and cast.block != null) return error.TransactionRequiresLatestBlock;
    const by_address = !configure and !validate and reference.len == 42 and std.mem.startsWith(u8, reference, "0x");
    var remote = try rpc.Rpc.init(a, cast.io, cast.rpc, cast.chain, if (by_address) reference else cast.instance);
    defer remote.deinit();
    try remote.pin(cast.block, 0);
    if (validate) {
        const feed = try validateFeed(&remote, cat, cast.instance, reference, max_age);
        if (!try remote.canonical(remote.block)) return error.ChainReorganizedRetrySync;
        const report = try c.parse(a, try c.encode(a, .{ .chainId = cast.chain, .block = remote.block, .feed = feed }));
        if (out) |path| try c.write(cast.io, path, try c.encode(a, report), false);
        return report;
    }
    var record: c.Value = .null;
    var key: []const u8 = "";
    const address = if (by_address) reference else blk: {
        key = try c.id(a, reference);
        record = try remote.namedAt(cast.instance, try cat.find("contracts", "getContractByHash"), &.{.{ .string = key }});
        if (try c.number(a, try field(record, "latestVersion")) == 0) return error.TokenContractMissing;
        const org = try c.string(try field(record, "org"));
        const id = try c.string(try field(record, "id"));
        if (org.len == 0 or id.len == 0 or ms.bytecode.hash(try a.print("{s}/{s}", .{ org, id })) != try c.word(key)) return error.InvalidTokenMetadata;
        break :blk try c.string(try field(try field(record, "latest"), "addr"));
    };
    try c.address(address);
    if ((try c.string(try remote.one("eth_getCode", try abi.array(a, &.{ .{ .string = address }, try remote.blockSelector() })))).len <= 2) return error.TokenContractMissing;
    const auxiliary = try contracts.Catalog.loadAuxiliary(a);
    const text = symbol_override orelse try symbol(a, &remote, auxiliary, address);
    if (c.trim(text).len == 0 or text.len > 64 or !std.unicode.utf8ValidateSlice(text) or std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidTokenSymbol;
    const decimals = try precision(a, if (decimals_override) |value| .{ .string = value } else try remote.namedAt(address, try auxiliary.find("erc20", "decimals"), &.{}));
    var report = try c.parse(a, try c.encode(a, .{ .chainId = cast.chain, .address = address, .block = remote.block, .symbol = text, .decimals = decimals, .symbolSource = if (symbol_override != null) "override" else "onchain", .decimalsSource = if (decimals_override != null) "override" else "onchain" }));
    if (configure) {
        const previous = try remote.namedAt(cast.instance, try cat.find("tokens", "getTokenByHash"), &.{.{ .string = key }});
        const price = if (feed_override) |value| if (c.eq(u8, value, "none")) zero else try cast.resolveAddress(value) else try c.string(try field(previous, "price"));
        if (!c.eq(u8, price, zero)) try c.address(price);
        const has_feed = try c.word(price) != 0;
        if (!has_feed and max_age != null) return error.PriceFeedRequired;
        const feed = if (has_feed) try validateFeed(&remote, cat, cast.instance, price, max_age) else @as(c.Value, .null);
        const token = try c.parse(a, try c.encode(a, .{ .org = try field(record, "org"), .id = try field(record, "id"), .symbol = text, .decimals = decimals, .price = price, .priceFeedDecimals = if (has_feed) try field(feed, "decimals") else try abi.uint(a, 0) }));
        var calls = std.json.Array.init(a);
        if (max_age) |age| try calls.append(.{ .string = try abi.calldata(a, (try cat.find("tokens", "setFeedMaxAge")).abi, try abi.array(a, &.{ .{ .string = price }, try abi.uint(a, age) })) });
        const upsert = try cat.find("tokens", "upsertToken");
        const token_args = try abi.array(a, &.{token});
        try calls.append(.{ .string = try abi.calldata(a, upsert.abi, token_args) });
        const method = if (max_age != null) try cat.find("registry", "multicall") else upsert;
        const values = if (max_age != null) try abi.array(a, &.{.{ .array = calls }}) else token_args;
        const data = try abi.calldata(a, method.abi, values);
        try report.object.put(a, "token", token);
        try report.object.put(a, "previousToken", previous);
        try report.object.put(a, "feed", feed);
        try report.object.put(a, "transaction", try c.parse(a, try c.encode(a, .{ .chainId = cast.chain, .to = cast.instance, .data = data, .value = "0", .nonce = cast.nonce })));
        if (!try remote.canonical(remote.block)) return error.ChainReorganizedRetrySync;
        if (out) |path| try c.write(cast.io, path, try c.encode(a, report), false);
        if (!dry) {
            const sender = try cast.signerAddress();
            _ = try remote.one("eth_call", try abi.array(a, &.{ try c.parse(a, try c.encode(a, .{ .from = sender, .to = cast.instance, .data = data })), try remote.blockSelector() }));
            if (!try remote.canonical(remote.block)) return error.ChainReorganizedRetrySync;
            const receipt = try cast.send(data, null);
            try report.object.put(a, "receipt", receipt);
            if (out) |path| try c.write(cast.io, path, try c.encode(a, report), true);
            const outcome = try @import("receipts.zig").classify(a, cat, receipt, cast.instance, method, &.{});
            try report.object.put(a, "outcome", try c.parse(a, try c.encode(a, outcome)));
            if (out) |path| try c.write(cast.io, path, try c.encode(a, report), true);
        }
    } else {
        if (!try remote.canonical(remote.block)) return error.ChainReorganizedRetrySync;
        if (out) |path| try c.write(cast.io, path, try c.encode(a, report), false);
    }
    return report;
}
