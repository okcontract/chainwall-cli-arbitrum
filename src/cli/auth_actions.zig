const std = @import("std");
const c = @import("common.zig");
const abi = @import("abi_codec.zig");
const auth = @import("auth_signer.zig");
const browser = @import("browser_approval.zig");
const contracts = @import("contracts.zig");
const Cast = @import("cast.zig").Cast;
const Client = @import("contract_client.zig").Client;
const Args = @import("args.zig").Args;
const field = auth.field;
const string = auth.string;
fn same(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn factoryPolicy(client: Client, registry: []const u8) !c.Value {
    if (try c.number(client.cast.a, try client.first("chainwallComponentId", &.{})) != @import("miniscript").bytecode.hash("Chainwall.WebAuthnAuthAccountFactory")) return error.InvalidAuthFactory;
    if (!same(try c.string(try client.first("REGISTRY", &.{})), registry)) return error.AuthFactoryRegistryMismatch;
    if (!(try client.first("REQUIRE_USER_VERIFICATION", &.{})).bool) return error.InvalidAuthFactoryPolicy;
    return c.parse(client.cast.a, try c.encode(client.cast.a, .{ .origin = try client.first("origin", &.{}), .rpIdHash = try client.first("RP_ID_HASH", &.{}), .safeFactory = try client.first("SAFE_FACTORY", &.{}) }));
}
pub fn enroll(client: Client, registry: []const u8, args: *Args, options: browser.Options, dry: bool) !c.Value {
    const cast = client.cast;
    const a = cast.a;
    const out = args.get("out") orelse return error.OutputFileRequired;
    const label = args.get("label") orelse "Chainwall passkey";
    try args.finish();
    const policy = try factoryPolicy(client, registry);
    const origin = try string(policy, "origin");
    const payload = try c.parse(a, try c.encode(a, .{ .version = 1, .action = "enroll", .chainId = cast.chain, .registry = registry, .authAccountFactory = cast.instance, .origin = origin, .rpcUrl = cast.rpc, .label = label }));
    if (dry) return payload;
    // Reserve before creating a passkey, so an existing file cannot cause loss
    // of the returned enrollment. Interrupted requests leave an explicit marker.
    try c.write(cast.io, out, "{\"status\":\"awaiting-enrollment\"}\n", false);
    const enrollment = try browser.request(a, cast.io, cast.env, origin, payload, options);
    try auth.validate(a, enrollment, cast.chain, registry, true);
    if (!same(try string(enrollment, "authAccountFactory"), cast.instance) or !same(try string(enrollment, "rpIdHash"), try string(policy, "rpIdHash")) or !c.eq(u8, try string(enrollment, "origin"), origin)) return error.AuthFactoryPolicyMismatch;
    try c.write(cast.io, out, try c.encode(a, enrollment), true);
    return enrollment;
}

pub fn create(client: Client, registry: []const u8, file: []const u8, args: *Args, dry: bool) !c.Value {
    const cast = client.cast;
    const a = cast.a;
    const out = args.get("out") orelse return error.OutputFileRequired;
    const scopes_file = args.get("scopes-file");
    try args.finish();
    const enrollment = try @import("json_schema.zig").read(a, cast.io, "auth-enrollment", file);
    try auth.validate(a, enrollment, cast.chain, registry, true);
    const policy = try factoryPolicy(client, registry);
    if (!same(try string(enrollment, "authAccountFactory"), cast.instance) or !same(try string(enrollment, "rpIdHash"), try string(policy, "rpIdHash")) or !c.eq(u8, try string(enrollment, "origin"), try string(policy, "origin"))) return error.AuthFactoryPolicyMismatch;
    const scopes = if (scopes_file) |path| try @import("json_schema.zig").read(a, cast.io, "auth-scopes", path) else try abi.array(a, &.{});
    const base = [_]c.Value{ try field(enrollment, "accountSalt"), try field(enrollment, "credHash"), try field(enrollment, "qx"), try field(enrollment, "qy") };
    const predicted = try client.first("computeAuthAccountAddress", &(base ++ .{scopes}));
    const impl = try client.first("IMPLEMENTATION", &.{});
    const codehash = try client.first("CHAINWALL_AUTH_ACCOUNT_IMPLEMENTATION_CODEHASH", &.{});
    const values = base ++ .{ impl, codehash, scopes };
    var profile: c.Value = .{ .object = .empty };
    for ([_][]const u8{ "chainId", "registry", "rpId", "rpIdHash", "origin", "idKey", "credHash", "credentialId", "label", "requireUserVerification", "createdAt" }) |key| try profile.object.put(a, key, try field(enrollment, key));
    try profile.object.put(a, "authAccount", predicted);
    const id = try a.print("{d}:{s}:{s}:{s}", .{ cast.chain, registry, try string(enrollment, "rpIdHash"), try string(enrollment, "idKey") });
    try profile.object.put(a, "id", .{ .string = try std.ascii.allocLowerString(a, id) });
    if (dry) return c.parse(a, try c.encode(a, .{ .profile = profile, .transaction = try client.transaction("newAuthAccount", &values, null, true) }));
    const encoded = try c.encode(a, profile);
    c.write(cast.io, out, encoded, false) catch |err| {
        if (err != error.PathAlreadyExists) return err;
        if (!c.eq(u8, c.trim(try c.read(a, cast.io, out)), encoded)) return error.AuthProfileOutputExists;
    };
    const receipt = try client.transaction("newAuthAccount", &values, null, false);
    if (!(try client.first("isAuthAccount", &.{predicted})).bool) return error.AuthAccountDeploymentMismatch;
    return c.parse(a, try c.encode(a, .{ .profile = profile, .receipt = receipt }));
}

pub fn inspect(cast: *Cast, profile: c.Value, registry: []const u8) !c.Value {
    const a = cast.a;
    try auth.validate(a, profile, cast.chain, registry, false);
    var read = cast.*;
    read.instance = try string(profile, "authAccount");
    read.checked = false;
    const cat = try contracts.Catalog.loadAuxiliary(a);
    var client: Client = .{ .cast = &read, .cat = cat, .group = "auth-account" };
    if (!same(try c.string(try client.first("registry", &.{})), registry) or !same(try c.string(try client.first("rpIdHash", &.{})), try string(profile, "rpIdHash")) or !c.eq(u8, try c.string(try client.first("origin", &.{})), try string(profile, "origin"))) return error.AuthAccountPolicyMismatch;
    const credential = try abi.namedResult(a, (try cat.find("auth-account", "getCredential")).abi, try client.call("getCredential", &.{try field(profile, "credHash")}));
    if (!(try field(credential, "active")).bool or !(try field(credential, "exists")).bool) return error.AuthCredentialInactive;
    const factory = try c.string(try client.first("factory", &.{}));
    read.instance = factory;
    read.checked = false;
    client.group = "auth-factory";
    _ = try factoryPolicy(client, registry);
    if (!(try client.first("isAuthAccount", &.{try field(profile, "authAccount")})).bool) return error.InvalidAuthAccount;
    read.instance = registry;
    read.checked = false;
    client.cat = try contracts.Catalog.load(a);
    client.group = "registry";
    const link = try client.call("getAuthCredentialLink", &.{try field(profile, "idKey")});
    return c.parse(a, try c.encode(a, .{ .profile = profile, .factory = factory, .credential = credential, .factoryAllowed = try client.first("isAuthAccountFactoryAllowed", &.{.{ .string = factory }}), .registered = try client.first("isUser", &.{try field(profile, "authAccount")}), .link = link }));
}

/// Each Registry step may queue under governance. Stop at a queued receipt;
/// rerunning register after execution resumes from verified live state.
pub fn register(cast: *Cast, profile: c.Value, dry: bool) !c.Value {
    const a = cast.a;
    const registry = cast.instance;
    const state = try inspect(cast, profile, registry);
    const client: Client = .{ .cast = cast, .cat = try contracts.Catalog.load(a), .group = "registry" };
    var results = std.json.Array.init(a);
    const steps = [_]struct { name: []const u8, values: []const c.Value, needed: bool }{
        .{ .name = "setAuthAccountFactory", .values = &.{ try field(state, "factory"), .{ .bool = true } }, .needed = !(try field(state, "factoryAllowed")).bool },
        .{ .name = "addUser", .values = &.{try field(profile, "authAccount")}, .needed = !(try field(state, "registered")).bool },
        .{ .name = "linkAuthCredential", .values = &.{ try field(profile, "idKey"), try field(profile, "authAccount"), try field(profile, "credHash") }, .needed = !(try field(state, "link")).array.items[2].bool },
    };
    const link = (try field(state, "link")).array.items;
    if ((try c.number(a, link[0]) != 0 and !same(try c.string(link[0]), try string(profile, "authAccount"))) or (try c.number(a, link[1]) != 0 and !same(try c.string(link[1]), try string(profile, "credHash")))) return error.AuthCredentialLinkConflict;
    for (steps) |step| if (step.needed) {
        const receipt = try client.transaction(step.name, step.values, null, dry);
        const outcome = if (dry) null else try @import("receipts.zig").classify(a, client.cat, receipt, registry, try client.cat.find("registry", step.name), &.{});
        try results.append(try c.parse(a, try c.encode(a, .{ .step = step.name, .receipt = receipt, .outcome = outcome })));
        if (outcome) |o| if (o.queuedActions.len > 0) break;
    };
    return c.parse(a, try c.encode(a, .{ .steps = results.items, .state = if (dry) state else try inspect(cast, profile, registry) }));
}
