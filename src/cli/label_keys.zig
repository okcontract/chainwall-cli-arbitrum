const std = @import("std");
const c = @import("common.zig");
const vault = @import("vault.zig");
const labels = @import("labels.zig");
const config = @import("config.zig");
const configuration = @import("configuration.zig");
const storage = @import("store.zig");
const operations = @import("operations.zig");

pub const Keyring = struct {
    values: [64][32]u8 = undefined,
    len: usize = 0,

    pub fn deinit(s: *Keyring) void {
        std.crypto.secureZero(u8, std.mem.asBytes(s));
    }
    pub fn keys(s: *const Keyring) []const [32]u8 {
        return s.values[0..s.len];
    }
};

/// The selected profile's secret and its ancestors, never a newer secret
/// learned by another profile sharing this local vault and KV address.
pub fn load(a: c.A, v: vault.Vault, profile: config.Profile, kv_chain: u64) !Keyring {
    const ref = (try configuration.secretReference(a, profile)) orelse return error.KvSecretRequired;
    const raw = (try v.get(ref)) orelse return error.KvSecretRequired;
    defer std.crypto.secureZero(u8, raw);
    if (raw.len != 32) return error.InvalidVault;
    var secret = try vault.Secret.init(raw[0..32].*);
    defer secret.deinit();
    var result: Keyring = .{};
    errdefer result.deinit();
    result.values[0] = labels.key(secret);
    result.len = 1;
    if (profile.get("kv_address")) |address| {
        const scope = try storage.scopeKey(a, kv_chain, address);
        const history: []vault.Secret = operations.history(a, v, scope) catch |err| switch (err) {
            error.RunSyncFirst => &.{},
            else => return err,
        };
        defer for (history) |*item| item.deinit();
        var found_head = false;
        for (history) |item| {
            if (found_head) {
                if (result.len == result.values.len) return error.SecretHistoryTooDeep;
                result.values[result.len] = labels.key(item);
                result.len += 1;
            }
            if (c.eq(u8, &item.signer, &secret.signer)) found_head = true;
        }
    }
    return result;
}
