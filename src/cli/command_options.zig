//! Options shared by startup and execution handlers are consumed exactly once.
const std = @import("std");
const c = @import("common.zig");
const Args = @import("args.zig").Args;
const schema = @import("schema.zig");
pub const Route = schema.Route;
pub const Execution = struct {
    route: Route = .account,
    auth_profile: ?[]const u8 = null,
    bundler: ?[]const u8 = null,
    paymaster: ?[]const u8 = null,

    pub fn parse(args: *Args) !Execution {
        const raw_route = args.get("via");
        const result: Execution = .{
            .route = if (raw_route) |raw| std.meta.stringToEnum(Route, raw) orelse return error.InvalidExecutionMode else .account,
            .auth_profile = args.get("auth-profile"),
            .bundler = args.get("bundler-url"),
            .paymaster = args.get("paymaster"),
        };
        if (raw_route != null and !schema.acceptsRoute(args.positional)) return error.ExecutionRouteNotApplicable;
        if (result.auth_profile != null or result.bundler != null or result.paymaster != null) {
            if (args.positional.len == 0 or schema.contains("config profile doctor schemas logs id artifacts completions search", args.positional[0])) return error.ExecutionOptionsNotApplicable;
        }
        if (result.paymaster) |address| {
            try c.address(address);
            if (result.bundler == null) return error.PaymasterRequiresBundler;
            if (result.auth_profile == null) return error.PaymasterRequiresAuthProfile;
            if (result.route != .account) return error.PaymasterRequiresAccountMode;
        }
        return result;
    }
};

pub const Operation = struct {
    max_steps: u256,
    actor: ?[]const u8,
    actor_file: ?[]const u8,
    signatures_file: ?[]const u8,
    reveal_file: ?[]const u8,
    out: ?[]const u8,
    approve: bool,
    pub fn parse(args: *Args, direct: bool) !Operation {
        const result: Operation = .{
            .max_steps = try c.word(args.get("max-steps") orelse "100000"),
            .actor = if (direct) args.get("actor") else null,
            .actor_file = args.get("actor-signature-file"),
            .signatures_file = args.get("signatures-file"),
            .reveal_file = args.get("reveal-file"),
            .out = args.get("out"),
            .approve = if (direct) false else args.flag("approve"),
        };
        try args.finish();
        return result;
    }
};

test "typed routes preserve sponsorship and reject invalid applicability before dispatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    inline for (std.meta.tags(Route)) |route| {
        var args = try Args.parse(a, &.{ "operations", "execute", "operation.json", "--via", @tagName(route), "--auth-profile", "actor.json" });
        const options = try Execution.parse(&args);
        try std.testing.expectEqual(route, options.route);
        try std.testing.expectEqualStrings("actor.json", options.auth_profile.?);
        try args.finish();
    }
    var sponsored = try Args.parse(a, &.{ "operations", "execute", "operation.json", "--auth-profile", "actor.json", "--bundler-url", "https://bundler.invalid", "--paymaster", "0x1111111111111111111111111111111111111111" });
    const retained = try Execution.parse(&sponsored);
    try std.testing.expectEqualStrings("actor.json", retained.auth_profile.?);
    try std.testing.expectEqualStrings("https://bundler.invalid", retained.bundler.?);
    try sponsored.finish();
    for ([_][]const u8{ "safe", "module" }) |route| {
        var args = try Args.parse(a, &.{ "operations", "execute", "file", "--via", route, "--auth-profile", "actor.json", "--bundler-url", "url", "--paymaster", "0x1111111111111111111111111111111111111111" });
        try std.testing.expectError(error.PaymasterRequiresAccountMode, Execution.parse(&args));
    }
    var invalid = try Args.parse(a, &.{ "operations", "execute", "file", "--via", "invalid" });
    try std.testing.expectError(error.InvalidExecutionMode, Execution.parse(&invalid));
    var local = try Args.parse(a, &.{ "config", "set", "editor", "hx", "--via", "safe" });
    try std.testing.expectError(error.ExecutionRouteNotApplicable, Execution.parse(&local));
    var missing = try Args.parse(a, &.{ "operations", "execute", "file", "--bundler-url", "url", "--paymaster", "0x1111111111111111111111111111111111111111" });
    try std.testing.expectError(error.PaymasterRequiresAuthProfile, Execution.parse(&missing));
}
