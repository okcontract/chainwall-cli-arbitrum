const std = @import("std");
const c = @import("common.zig");
const abi = @import("abi_codec.zig");
const contracts = @import("contracts.zig");
const rpc = @import("rpc.zig");
const Cast = @import("cast.zig").Cast;

const Preset = struct {
    feed: []const u8,
    priceFeedDecimals: u8,
    feedMaxAgeSeconds: u64,
    environment: struct {
        sequencerRequired: bool,
        sequencerUptimeFeed: []const u8,
        recoveryGracePeriodSeconds: u64,
    },
};

/// Validate at one canonical block, then build the same three calls as the app.
/// Governance still applies to each inner call; never relax the global age limit.
pub fn arguments(cast: *Cast, cat: contracts.Catalog, dry: bool) !c.Value {
    if (cast.block != null and !dry) return error.TransactionRequiresLatestBlock;
    const a = cast.a;
    const auxiliary = try contracts.Catalog.loadNativePrice(a);
    const presets = c.field(auxiliary.root, "presets").?;
    const raw = c.field(presets, try a.print("{d}", .{cast.chain})) orelse return error.NoChainlinkNativeFeedPreset;
    const preset = (try std.json.parseFromValue(Preset, a, raw, .{ .allocate = .alloc_always })).value;
    var remote = try rpc.Rpc.init(a, cast.io, cast.rpc, cast.chain, cast.instance);
    defer remote.deinit();
    try remote.pin(cast.block, 0);
    const ceiling = try c.number(a, try remote.namedAt(cast.instance, try cat.find("tokens", "getMaxFeedStaleness"), &.{}));
    const decimals = try remote.namedAt(preset.feed, try auxiliary.find("chainlink", "decimals"), &.{});
    if (try c.number(a, decimals) != preset.priceFeedDecimals) return error.NativeFeedDecimalsMismatch;
    const round = try remote.namedAt(preset.feed, try auxiliary.find("chainlink", "latestRoundData"), &.{});
    const answer = try std.fmt.parseInt(i256, try c.scalar(a, c.field(round, "answer").?), 10);
    if (answer <= 0) return error.NativeFeedAnswerNotPositive;
    if (try c.number(a, c.field(round, "answeredInRound").?) < try c.number(a, c.field(round, "roundId").?)) return error.NativeFeedIncompleteRound;
    const updated = try c.number(a, c.field(round, "updatedAt").?);
    if (updated == 0 or updated > remote.block.timestamp) return error.NativeFeedInvalidTimestamp;
    const age = remote.block.timestamp - updated;
    if (age > preset.feedMaxAgeSeconds or (ceiling != 0 and age > ceiling)) return error.NativeFeedStale;
    if (!try remote.canonical(remote.block)) return error.NativeFeedChainChanged;

    const env = preset.environment;
    const environment_args = try abi.array(a, &.{ .{ .bool = env.sequencerRequired }, .{ .string = env.sequencerUptimeFeed }, try abi.uint(a, env.recoveryGracePeriodSeconds) });
    const age_args = try abi.array(a, &.{ .{ .string = preset.feed }, try abi.uint(a, preset.feedMaxAgeSeconds) });
    const feed_args = try abi.array(a, &.{ .{ .string = preset.feed }, try abi.uint(a, preset.priceFeedDecimals) });
    var calls = std.json.Array.init(a);
    for ([_][]const u8{ "setOracleEnvironment", "setFeedMaxAge", "setNativeUsdFeed" }, [_]c.Value{ environment_args, age_args, feed_args }) |name, values| {
        try calls.append(.{ .string = try abi.calldata(a, (try cat.find("tokens", name)).abi, values) });
    }
    return abi.array(a, &.{.{ .array = calls }});
}
