const std = @import("std");
const c = @import("common.zig");
const Cast = @import("cast.zig").Cast;
pub const tested_version = "1.8.6";
fn probe(cast: *Cast) ![]const u8 {
    const version = try cast.run(&.{"--version"});
    const data = try cast.run(&.{ "calldata", "f(uint256)", "1" });
    if (!c.eq(u8, data, "0xb3de648b0000000000000000000000000000000000000000000000000000000000000001")) return error.IncompatibleFoundryCalldata;
    const value = try c.parse(cast.a, try cast.run(&.{ "decode-abi", "f()(uint256)", data[10..], "--json" }));
    if (value != .array or value.array.items.len != 1 or try c.number(cast.a, value.array.items[0]) != 1) return error.IncompatibleFoundryJson;
    const send = try cast.run(&.{ "send", "--help" });
    for ([_][]const u8{ "--async", "--nonce", "--unlocked", "--gas-limit", "--priority-gas-price" }) |flag| if (std.mem.indexOf(u8, send, flag) == null) return error.IncompatibleFoundrySend;
    const wallet = try cast.run(&.{ "wallet", "sign", "--help" });
    for ([_][]const u8{ "--data", "--account", "--keystore", "--password-file" }) |flag| if (std.mem.indexOf(u8, wallet, flag) == null) return error.IncompatibleFoundryWallet;
    return version;
}
pub fn run(cast: *Cast) !c.Value {
    const version = probe(cast) catch |err| return c.parse(cast.a, try c.encode(cast.a, .{ .schemaVersion = 1, .ok = false, .chainwall = "0.3.1", .zig = @import("builtin").zig_version_string, .cast = .{ .ok = false, .code = @errorName(err), .testedVersion = tested_version, .action = "Install Foundry cast 1.8.6 from https://getfoundry.sh/, put it on PATH, then rerun chainwall doctor. These checks use no wallet or RPC." } }));
    return c.parse(cast.a, try c.encode(cast.a, .{ .schemaVersion = 1, .ok = true, .chainwall = "0.3.1", .zig = @import("builtin").zig_version_string, .cast = .{ .ok = true, .version = version, .testedVersion = tested_version, .testedRelease = std.mem.indexOf(u8, version, "Version: " ++ tested_version ++ "-") != null or std.mem.indexOf(u8, version, "Version: " ++ tested_version ++ "\n") != null, .checks = .{ "calldata", "decode-abi-json", "send-options", "wallet-sign-options" } } }));
}
