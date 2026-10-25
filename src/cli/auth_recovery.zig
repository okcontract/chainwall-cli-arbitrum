const std = @import("std");
const c = @import("common.zig");
const abi = @import("abi_codec.zig");
const ms = @import("miniscript");
const auth = @import("auth_signer.zig");
const rpc = @import("rpc.zig");
const browser = @import("browser_approval.zig");
const contracts = @import("contracts.zig");
const Cast = @import("cast.zig").Cast;
const Args = @import("args.zig").Args;
const field = auth.field;
const string = auth.string;
fn same(left: []const u8, right: []const u8) bool {
    return std.ascii.eqlIgnoreCase(left, right);
}
fn policy(remote: *rpc.Rpc, cat: contracts.Catalog, factory: []const u8) !c.Value {
    if (try c.number(remote.a, try remote.namedAt(factory, try cat.find("auth-factory", "chainwallComponentId"), &.{})) != ms.bytecode.hash("Chainwall.WebAuthnAuthAccountFactory")) return error.InvalidAuthFactory;
    if (!same(try c.string(try remote.namedAt(factory, try cat.find("auth-factory", "REGISTRY"), &.{})), remote.address)) return error.AuthFactoryRegistryMismatch;
    if (!(try remote.namedAt(factory, try cat.find("auth-factory", "REQUIRE_USER_VERIFICATION"), &.{})).bool) return error.InvalidAuthFactoryPolicy;
    return c.parse(remote.a, try c.encode(remote.a, .{ .origin = try remote.namedAt(factory, try cat.find("auth-factory", "origin"), &.{}), .rpIdHash = try remote.namedAt(factory, try cat.find("auth-factory", "RP_ID_HASH"), &.{}) }));
}
fn matches(remote: *rpc.Rpc, cat: contracts.Catalog, factory: []const u8, account: []const u8, discovered: c.Value) !bool {
    const credential = try remote.namedAt(account, try cat.find("auth-account", "getCredential"), &.{try field(discovered, "credHash")});
    if (!(try field(credential, "exists")).bool or !(try field(credential, "active")).bool or !same(try string(credential, "credHash"), try string(discovered, "credHash"))) return false;
    if (!(try remote.namedAt(factory, try cat.find("auth-factory", "isAuthAccount"), &.{.{ .string = account }})).bool) return error.InvalidAuthAccount;
    for ([_][2][]const u8{ .{ "factory", factory }, .{ "registry", remote.address }, .{ "rpIdHash", try string(discovered, "rpIdHash") } }) |pair| {
        if (!same(try c.string(try remote.namedAt(account, try cat.find("auth-account", pair[0]), &.{})), pair[1])) return error.AuthAccountPolicyMismatch;
    }
    if (!c.eq(u8, try c.string(try remote.namedAt(account, try cat.find("auth-account", "origin"), &.{})), try string(discovered, "origin"))) return error.AuthAccountPolicyMismatch;
    return true;
}
pub fn recover(cast: *Cast, factory: []const u8, args: *Args, options: browser.Options, dry: bool) !c.Value {
    const a = cast.a;
    const out = args.get("out") orelse return error.OutputFileRequired;
    const label = args.get("label") orelse "Passkey";
    const credential_file = args.get("credential-file");
    const selected_account = args.get("auth-account");
    try args.finish();
    try c.address(factory);
    if (selected_account) |account| try c.address(account);
    if (label.len > 256 or !std.unicode.utf8ValidateSlice(label)) return error.InvalidPasskeyLabel;
    if (cast.block != null) return error.RecoveryRequiresLatestBlock;
    var remote = try rpc.Rpc.init(a, cast.io, cast.rpc, cast.chain, cast.instance);
    defer remote.deinit();
    try remote.pin(null, 0);
    const cat = try contracts.Catalog.loadAuxiliary(a);
    const configured = try policy(&remote, cat, factory);
    const origin = try string(configured, "origin");
    if (!c.eq(u8, origin, try browser.origin(a, origin))) return error.InvalidApprovalOrigin;
    if (!try remote.canonical(remote.block)) return error.ChainReorganizedRetrySync;
    if (dry) return c.parse(a, try c.encode(a, .{ .action = "recover", .chainId = cast.chain, .registry = cast.instance, .authAccountFactory = factory, .origin = origin, .label = label, .authAccount = selected_account }));
    // Refuse existing profiles before prompting. Interrupted discovery leaves a
    // marker, never a partially trusted signing profile.
    try c.write(cast.io, out, "{\"status\":\"awaiting-passkey-recovery\"}\n", false);
    const discovered = if (credential_file) |file| try @import("json_schema.zig").read(a, cast.io, "auth-credential", file) else try browser.request(a, cast.io, cast.env, origin, try c.parse(a, try c.encode(a, .{ .version = 1, .action = "recover", .chainId = cast.chain, .registry = cast.instance, .authAccountFactory = factory, .origin = origin, .rpcUrl = cast.rpc, .label = label })), options);
    // Validate all credential-derived identities before using them in a query.
    // The temporary account field only satisfies the public profile shape.
    var checked = discovered;
    if (checked != .object) return error.InvalidAuthProfile;
    try checked.object.put(a, "authAccount", .{ .string = factory });
    try auth.validate(a, checked, cast.chain, cast.instance, false);
    if (!c.eq(u8, try string(discovered, "origin"), origin) or !same(try string(discovered, "rpIdHash"), try string(configured, "rpIdHash"))) return error.AuthFactoryPolicyMismatch;
    if (c.field(discovered, "authAccountFactory")) |value| if (!same(try c.string(value), factory)) return error.AuthFactoryPolicyMismatch;
    // Browser interaction may take minutes. Recover against a fresh coherent
    // snapshot, and reject a policy change during that interaction.
    try remote.pin(null, 0);
    if (!c.eq(u8, try c.encode(a, configured), try c.encode(a, try policy(&remote, cat, factory)))) return error.AuthFactoryPolicyMismatch;
    var found: ?[]const u8 = null;
    if (selected_account) |account| {
        if (!try matches(&remote, cat, factory, account, discovered)) return error.AuthCredentialNotFound;
        found = account;
    } else {
        const count = try rpc.integer(a, try remote.namedAt(factory, try cat.find("auth-factory", "getAuthAccountCount"), &.{}));
        if (count > 10000) return error.LargeFactoryRequiresAuthAccount;
        var offset: u64 = 0;
        while (offset < count) {
            const size = @min(64, count - offset);
            const page = try remote.namedAt(factory, try cat.find("auth-factory", "getAuthAccountPage"), &.{ try abi.uint(a, offset), try abi.uint(a, size) });
            if (page != .array or page.array.items.len != size) return error.InvalidAuthAccountPage;
            for (page.array.items) |value| {
                const account = try c.string(value);
                if (!try matches(&remote, cat, factory, account, discovered)) continue;
                if (found != null) return error.AmbiguousCredentialUseAuthAccount;
                found = account;
            }
            offset += size;
        }
    }
    const account = found orelse return error.AuthCredentialNotFound;
    var profile: c.Value = .{ .object = .empty };
    for ([_][]const u8{ "chainId", "registry", "rpId", "rpIdHash", "origin", "idKey", "credHash", "credentialId", "requireUserVerification" }) |key| try profile.object.put(a, key, try field(discovered, key));
    try profile.object.put(a, "authAccount", .{ .string = account });
    try profile.object.put(a, "label", .{ .string = label });
    try profile.object.put(a, "createdAt", .{ .integer = @intCast(std.Io.Clock.real.now(cast.io).toMilliseconds()) });
    const id = try a.print("{d}:{s}:{s}:{s}", .{ cast.chain, cast.instance, try string(discovered, "rpIdHash"), try string(discovered, "idKey") });
    try profile.object.put(a, "id", .{ .string = try std.ascii.allocLowerString(a, id) });
    try auth.validate(a, profile, cast.chain, cast.instance, false);
    if (!try remote.canonical(remote.block)) return error.ChainReorganizedRetrySync;
    try c.write(cast.io, out, try c.encode(a, profile), true);
    return profile;
}
