//! Deliberately small, strict Foundry process fixture. Never submits a transaction.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(a);
    if (argv.len < 2) return error.MissingCommand;
    const command = argv[1];
    if (std.mem.eql(u8, command, "call") and std.mem.endsWith(u8, option(argv, "--rpc-url") orelse "", "/fixture-revert")) {
        try std.Io.File.stderr().writeStreamingAll(init.io, try std.fmt.allocPrint(a, "execution reverted: custom error 0xbed8168a at {s}\n", .{option(argv, "--rpc-url").?}));
        return error.FixtureReadReverted;
    }
    if (std.mem.eql(u8, command, "send") and argv.len == 3 and std.mem.eql(u8, argv[2], "--help")) {
        if (init.environ_map.get("NO_COLOR") == null or init.environ_map.get("CLICOLOR_FORCE") != null or init.environ_map.get("FORCE_COLOR") != null) return error.FixtureHelpRequiresNoColor;
        const legacy = init.environ_map.get("CHAINWALL_TEST_LEGACY_CAST") != null;
        try std.Io.File.stdout().writeStreamingAll(init.io, if (legacy) "--async --nonce --unlocked --gas-limit --priority-gas-price --data-file" else "--data --async --nonce --unlocked --gas-limit --priority-gas-price");
        return;
    }
    if (std.mem.eql(u8, command, "send") and !(argv.len == 3 and std.mem.eql(u8, argv[2], "--help"))) {
        const from = option(argv, "--from") orelse return error.FixtureEnvelopeMismatch;
        const nonce = option(argv, "--nonce") orelse return error.FixtureEnvelopeMismatch;
        if (!std.mem.eql(u8, from, "0x6666666666666666666666666666666666666666") or !std.mem.eql(u8, nonce, "5")) return error.FixtureEnvelopeMismatch;
        return error.FixtureBroadcastStopped;
    }
    const output =
        if (std.mem.eql(u8, command, "--version")) "cast Version: 1.8.6-test\n" else if (std.mem.eql(u8, command, "calldata")) "0xb3de648b0000000000000000000000000000000000000000000000000000000000000001" else if (std.mem.eql(u8, command, "wallet") and argv.len == 4 and std.mem.eql(u8, argv[3], "--help")) "--data --account --keystore --password-file" else if (std.mem.eql(u8, command, "wallet") and argv.len >= 3 and std.mem.eql(u8, argv[2], "address")) "0x6666666666666666666666666666666666666666" else if (std.mem.eql(u8, command, "chain-id")) "42161" else if (std.mem.eql(u8, command, "code")) "0x6000" else if (std.mem.eql(u8, command, "call")) "0x00" else if (std.mem.eql(u8, command, "decode-abi")) blk: {
            const signature = argv[2];
            const name = signature[0 .. std.mem.indexOfScalar(u8, signature, '(') orelse return error.InvalidSignature];
            const fixtures = .{
                .{ "f", "{\"schema_version\":1,\"success\":true,\"data\":[\"1\"],\"errors\":[],\"warnings\":[]}" },
                .{ "registry", "[\"0x1111111111111111111111111111111111111111\"]" },
                .{ "getOperationSafe", "[\"0x3333333333333333333333333333333333333333\"]" },
                .{ "getOperationPolicyId", "[\"0x" ++ "00000000000000000000000000000000000000000000000000000000000000" ++ "01\"]" },
                .{ "getExecutionBindingHash", "[\"0x" ++ "00000000000000000000000000000000000000000000000000000000000000" ++ "01\"]" },
                .{ "getPayloadHash", "[\"0x" ++ "00000000000000000000000000000000000000000000000000000000000000" ++ "01\"]" },
                .{ "getTransactionHash", "[\"0x" ++ "00000000000000000000000000000000000000000000000000000000000000" ++ "01\"]" },
                .{ "isOperationExecuted", "[false]" },
                .{ "getOperationNativeValue", "[\"0\"]" },
                .{ "nonce", "[\"0\"]" },
            };
            inline for (fixtures) |fixture| if (std.mem.eql(u8, name, fixture[0])) break :blk fixture[1];
            return error.UnexpectedContractRead;
        } else return error.UnexpectedCastCommand;
    try std.Io.File.stdout().writeStreamingAll(init.io, output);
}

fn option(argv: []const []const u8, name: []const u8) ?[]const u8 {
    for (argv, 0..) |arg, i| if (std.mem.eql(u8, arg, name) and i + 1 < argv.len) return argv[i + 1];
    return null;
}
