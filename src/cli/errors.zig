const std = @import("std");
const c = @import("common.zig");
pub const Context = struct {
    json: bool = false,
    command: []const u8 = "chainwall",
    field: ?[]const u8 = null,
    detail: ?[]const u8 = null,
    log: ?[]const u8 = null,
    transaction_hashes: []const []const u8 = &.{},
    user_operation_hashes: []const []const u8 = &.{},
    submission_attempted: bool = false,

    pub fn recovery(ctx: *Context, a: c.A, journal: @import("logs.zig").Journal) !void {
        ctx.log = journal.path;
        ctx.submission_attempted = journal.submissions.items.len > 0 or journal.transactions.items.len > 0;
        var hashes: std.ArrayList([]const u8) = .empty;
        var user_ops: std.ArrayList([]const u8) = .empty;
        for (journal.submissions.items) |submission| {
            try collect(a, submission, &hashes, &user_ops, 0);
        }
        for (journal.transactions.items) |transaction| try collect(a, transaction, &hashes, &user_ops, 0);
        ctx.transaction_hashes = hashes.items;
        ctx.user_operation_hashes = user_ops.items;
    }
    pub fn encode(ctx: Context, a: c.A, err: anyerror, message: []const u8) ![]const u8 {
        // A retry of a command that may have broadcast is never recommended.
        const retry = !ctx.submission_attempted and retryable(err);
        return std.json.Stringify.valueAlloc(a, .{
            .schemaVersion = 1,
            .ok = false,
            .command = ctx.command,
            .@"error" = .{
                .code = @errorName(err),
                .message = message,
                .field = if (ctx.field orelse fieldFor(err)) |field| c.Value{ .string = field } else c.Value.null,
                .retryable = retry,
                .recovery = .{ .log = ctx.log, .transactionHashes = ctx.transaction_hashes, .userOperationHashes = ctx.user_operation_hashes, .submissionAttempted = ctx.submission_attempted },
                .detail = ctx.detail,
            },
        }, .{});
    }
};
fn collect(a: c.A, value: c.Value, hashes: *std.ArrayList([]const u8), user_ops: *std.ArrayList([]const u8), depth: usize) !void {
    if (depth > 8 or value != .object) return;
    for (value.object.keys(), value.object.values()) |key, item| {
        if (item == .string and (c.eq(u8, key, "hash") or c.eq(u8, key, "transactionHash") or c.eq(u8, key, "userOpHash") or c.eq(u8, key, "userOperationHash"))) {
            if (item.string.len != 66 or !std.mem.startsWith(u8, item.string, "0x")) continue;
            const list = if (std.mem.startsWith(u8, key, "user")) user_ops else hashes;
            var duplicate = false;
            for (list.items) |prior| if (std.ascii.eqlIgnoreCase(prior, item.string)) {
                duplicate = true;
            };
            if (!duplicate) try list.append(a, item.string);
        } else if (c.eq(u8, key, "receipt") or c.eq(u8, key, "replacement") or c.eq(u8, key, "observation")) try collect(a, item, hashes, user_ops, depth + 1);
    }
}
fn retryable(err: anyerror) bool {
    return switch (err) {
        error.HttpRequestTimeout, error.ConnectionRefused, error.ConnectionResetByPeer, error.TemporaryNameServerFailure, error.RpcHttpFailure, error.ChainReorganizedRetrySync, error.DatabaseChangedRetrySync, error.TransactionReorganized, error.ProfileChangedRetry => true,
        else => false,
    };
}
fn fieldFor(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.InvalidExecutionMode, error.ExecutionRouteNotApplicable, error.PaymasterRequiresAccountMode => "--via",
        error.PaymasterRequiresAuthProfile => "--auth-profile",
        error.PaymasterRequiresBundler => "--bundler-url",
        error.InvalidNonce, error.BundlerManagesNonce => "--nonce",
        error.InvalidGasLimit => "--gas-limit",
        error.EstimateNotApplicable => "--estimate",
        error.AddressArgumentRequired => "ADDRESS",
        else => null,
    };
}

test "structured errors retain recovery handles and never suggest retrying a broadcast" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var journal: @import("logs.zig").Journal = .{ .a = a, .io = std.testing.io, .dir = "", .profile = "test", .command = "operations-execute", .path = "recovery.json" };
    const hash = "0x1111111111111111111111111111111111111111111111111111111111111111";
    try journal.submissions.append(a, try c.parse(a, try c.encode(a, .{ .hash = hash, .state = "submitted" })));
    var ctx: Context = .{ .command = "operations execute" };
    try ctx.recovery(a, journal);
    const record = try c.parse(a, try ctx.encode(a, error.HttpRequestTimeout, "Observation timed out."));
    const failure = c.field(record, "error").?;
    try std.testing.expect(!c.field(failure, "retryable").?.bool);
    try std.testing.expectEqualStrings(hash, try c.string(c.field(c.field(failure, "recovery").?, "transactionHashes").?.array.items[0]));
    ctx.submission_attempted = false;
    try std.testing.expect(c.field(c.field(try c.parse(a, try ctx.encode(a, error.HttpRequestTimeout, "Read timed out.")), "error").?, "retryable").?.bool);
}
