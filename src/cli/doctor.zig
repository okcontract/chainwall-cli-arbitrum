const std = @import("std");
const c = @import("common.zig");
const Cast = @import("cast.zig").Cast;
pub const tested_version = "1.8.6";
fn hasOption(help: []const u8, option: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, help, " \t\r\n,=[]");
    while (words.next()) |word| if (c.eq(u8, word, option)) return true;
    return false;
}
fn probe(cast: *Cast) ![]const u8 {
    const version = try cast.run(&.{"--version"});
    const data = try cast.run(&.{ "calldata", "f(uint256)", "1" });
    if (!c.eq(u8, data, "0xb3de648b0000000000000000000000000000000000000000000000000000000000000001")) return error.IncompatibleFoundryCalldata;
    const value = try c.parse(cast.a, try cast.run(&.{ "decode-abi", "f()(uint256)", data[10..], "--json" }));
    if (value != .array or value.array.items.len != 1 or try c.number(cast.a, value.array.items[0]) != 1) return error.IncompatibleFoundryJson;
    const send = try cast.run(&.{ "send", "--help" });
    for ([_][]const u8{ "--data", "--async", "--nonce", "--unlocked", "--gas-limit", "--priority-gas-price" }) |flag| if (!hasOption(send, flag)) return error.IncompatibleFoundrySend;
    const wallet = try cast.run(&.{ "wallet", "sign", "--help" });
    for ([_][]const u8{ "--data", "--account", "--keystore", "--password-file" }) |flag| if (!hasOption(wallet, flag)) return error.IncompatibleFoundryWallet;
    return version;
}
pub fn run(cast: *Cast) !c.Value {
    // Machine-readable help probes must not inherit forced terminal colors.
    var env = try cast.env.clone(cast.a);
    defer env.deinit();
    try env.put("NO_COLOR", "1");
    _ = env.orderedRemove("CLICOLOR_FORCE");
    _ = env.orderedRemove("FORCE_COLOR");
    var checking = cast.*;
    checking.env = &env;
    defer cast.diagnostic = checking.diagnostic;
    const version = probe(&checking) catch |err| return c.parse(cast.a, try c.encode(cast.a, .{ .schemaVersion = 1, .ok = false, .chainwall = "0.3.1", .zig = @import("builtin").zig_version_string, .cast = .{ .ok = false, .code = @errorName(err), .testedVersion = tested_version, .action = "Run foundryup --install 1.8.6, put cast on PATH, then rerun chainwall doctor. These checks use no wallet or RPC." } }));
    return c.parse(cast.a, try c.encode(cast.a, .{ .schemaVersion = 1, .ok = true, .chainwall = "0.3.1", .zig = @import("builtin").zig_version_string, .cast = .{ .ok = true, .version = version, .testedVersion = tested_version, .testedRelease = std.mem.indexOf(u8, version, "Version: " ++ tested_version ++ "-") != null or std.mem.indexOf(u8, version, "Version: " ++ tested_version ++ "\n") != null, .checks = .{ "calldata", "decode-abi-json", "send-options", "wallet-sign-options" } } }));
}

test "Foundry option checks require a complete option name" {
    try std.testing.expect(hasOption("  --data <DATA>\n  --async", "--data"));
    try std.testing.expect(!hasOption("  --data-file <FILE>\n  --async", "--data"));
    try std.testing.expect(!hasOption("  --async --nonce", "--data"));
}
