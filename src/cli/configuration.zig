const std = @import("std");
const c = @import("common.zig");
const config = @import("config.zig");
const storage = @import("store.zig");
const vault = @import("vault.zig");
const abi = @import("abi_codec.zig");
const display = @import("display.zig");

fn field(value: c.Value, key: []const u8) !c.Value {
    return c.field(value, key) orelse error.InvalidConfigurationSnapshot;
}
fn record(value: c.Value, key: []const u8) !c.Value {
    const child = try field(value, key);
    if (child != .object) return error.InvalidConfigurationSnapshot;
    return child;
}
fn strings(value: c.Value, keys: []const []const u8) !void {
    for (keys) |key| {
        const child = try field(value, key);
        if (child != .string and child != .null) return error.InvalidConfigurationSnapshot;
    }
}
fn optionalStrings(value: c.Value, keys: []const []const u8) !void {
    for (keys) |key| if (c.field(value, key)) |child| {
        if (child != .string and child != .null) return error.InvalidConfigurationSnapshot;
    };
}
fn nullableNumber(a: c.A, value: c.Value) !void {
    if (value == .null) return;
    if (value != .integer and value != .float and value != .number_string) return error.InvalidConfigurationSnapshot;
    const number = if (value == .float) value.float else std.fmt.parseFloat(f64, try c.scalar(a, value)) catch return error.InvalidConfigurationSnapshot;
    if (!std.math.isFinite(number)) return error.InvalidConfigurationSnapshot;
}
fn chain(a: c.A, value: c.Value) !?u64 {
    if (value == .null) return null;
    try nullableNumber(a, value);
    const n = c.number(a, value) catch return error.InvalidConfigurationChain;
    if (n == 0 or n > 9007199254740991) return error.InvalidConfigurationChain;
    return @intCast(n);
}

/// Version-2 configuration interchange schema.
/// Validate the entire document before opening a vault or replacing a profile.
pub fn validate(a: c.A, value: c.Value) !void {
    const version = try field(value, "version");
    if ((version != .integer and version != .number_string) or try c.number(a, version) != 2) return error.InvalidConfigurationVersion;
    if (try field(value, "generatedAt") != .string or try field(value, "locale") != .string) return error.InvalidConfigurationSnapshot;
    try strings(value, &.{ "account", "etherscanApiKey" });
    _ = try chain(a, try field(value, "chainId"));
    try strings(try record(value, "registry"), &.{"address"});
    try strings(try record(value, "rpc"), &.{"override"});
    const secrets = try record(value, "secrets");
    try strings(secrets, &.{ "stackSecret", "kvAddress" });
    const kv_chain = try chain(a, try field(secrets, "kvChainId"));
    if (try field(secrets, "kvAddress") != .null and kv_chain == null) return error.InvalidConfigurationChain;
    const factory = try record(value, "safeFactory");
    try strings(factory, &.{ "resolvedAddress", "manualOverride" });
    const snapshot = try field(factory, "snapshot");
    if (snapshot != .null) {
        if (snapshot != .object) return error.InvalidConfigurationSnapshot;
        try strings(snapshot, &.{ "miniScript", "interact", "guard", "module", "proxyFactory", "safeSingleton" });
        try optionalStrings(snapshot, &.{ "engine", "accountFactory" });
    }
    const instance = try field(factory, "instance");
    if (instance != .null) {
        if (instance != .object) return error.InvalidConfigurationSnapshot;
        try strings(instance, &.{ "registry", "miniScript", "interact", "safeFactory", "accountFactory", "index", "blockNumber" });
        try optionalStrings(instance, &.{ "initialOwner", "authAccountFactory" });
        try nullableNumber(a, try field(instance, "flags"));
        try nullableNumber(a, try field(instance, "logIndex"));
    }
}

fn optional(value: c.Value) !?[]const u8 {
    return if (value == .null) null else try c.string(value);
}
fn set(p: *config.Profile, a: c.A, key: []const u8, value: c.Value) !void {
    if (try optional(value)) |raw| {
        const text = c.trim(raw);
        if (text.len > 0) return p.set(a, key, text);
    }
    _ = p.values.orderedRemove(key);
}

pub fn secretReference(a: c.A, p: config.Profile) !?[]const u8 {
    if (p.get("stack_secret_ref")) |ref| return if (c.eq(u8, ref, "none")) null else ref;
    // Existing profiles predate explicit secret references.
    const address = p.get("kv_address") orelse return null;
    const chain_id = try config.chainId(p.get("kv_chain") orelse p.get("chain") orelse "ethereum");
    return try headReference(a, chain_id, address);
}
pub fn headReference(a: c.A, chain_id: u64, address: []const u8) ![]const u8 {
    return a.print("kv:{s}:head", .{try storage.scopeKey(a, chain_id, address)});
}

fn unlock(a: c.A, io: std.Io, db: storage.Store, password_file: ?[]const u8, create: bool) !vault.Vault {
    const password = try vault.readPassword(a, io, password_file, create and (try db.secret("master.v1")) == null);
    defer std.crypto.secureZero(u8, password);
    return vault.Vault.unlock(a, io, db, password, create);
}

pub fn generateSecret(a: c.A, io: std.Io, dir: []const u8, name: []const u8, password_file: ?[]const u8) !struct { profile: config.Profile, signer: []const u8 } {
    if (!config.validName(name)) return error.InvalidProfileName;
    const db = try storage.Store.open(a, io, dir);
    defer db.close();
    // Serialize generation through the profile switch, then reload its pointer.
    const lock = try std.Io.Dir.cwd().createFile(io, try a.print("{s}/.config-secret-{s}.lock", .{ dir, name }), .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true, .permissions = .fromMode(0o600) });
    defer lock.close(io);
    var next = try config.load(a, io, dir, name);
    if (next.get("kv_address") != null) return error.KvSecretGenerationRequiresRotation;
    if (try secretReference(a, next) != null) return error.SharedSecretAlreadyConfigured;
    try db.begin();
    errdefer db.db.rollback();
    var v = try unlock(a, io, db, password_file, true);
    defer v.deinit();
    var bytes: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &bytes);
    try io.randomSecure(&bytes);
    var secret = try vault.Secret.init(bytes);
    defer secret.deinit();
    var id: [16]u8 = undefined;
    try io.randomSecure(&id);
    const ref = try a.print("configuration:{s}:stackSecret", .{try abi.hex(a, &id)});
    try v.put(ref, &secret.private_key);
    try next.set(a, "stack_secret_ref", ref);
    // Commit encrypted material before the atomic profile switch. An interrupted
    // profile write cannot destroy a previously configured secret.
    try db.db.commit();
    try config.save(next, a, io, dir, name, true);
    return .{ .profile = next, .signer = try secret.address(a) };
}

pub fn importFile(a: c.A, io: std.Io, dir: []const u8, name: []const u8, previous: config.Profile, path: []const u8, password_file: ?[]const u8) !config.Profile {
    const raw = try c.read(a, io, path);
    defer std.crypto.secureZero(u8, @constCast(raw));
    var snapshot = try c.parse(a, raw);
    var validator = try @import("json_schema.zig").Validator.init(a);
    try validator.require(io, try validator.schema("configuration"), snapshot, "configuration");
    const secret_text = c.field(c.field(snapshot, "secrets") orelse .null, "stackSecret");
    defer if (secret_text) |text| if (text == .string) std.crypto.secureZero(u8, @constCast(text.string));
    try validate(a, snapshot);
    var secret: ?vault.Secret = null;
    defer if (secret) |*value| value.deinit();
    if (try optional(secret_text.?)) |text| {
        const bytes = try abi.unhex(a, c.trim(text));
        defer std.crypto.secureZero(u8, bytes);
        if (bytes.len != 32) return error.InvalidKvSecret;
        secret = try vault.Secret.init(bytes[0..32].*);
    }
    var next = previous;
    next.values = try previous.values.clone(a);
    const chain_id = try chain(a, try field(snapshot, "chainId"));
    const secrets = try record(snapshot, "secrets");
    const kv_chain = try chain(a, try field(secrets, "kvChainId"));
    const registry = try field(try record(snapshot, "registry"), "address");
    const url = try field(try record(snapshot, "rpc"), "override");
    const instance = try field(try record(snapshot, "safeFactory"), "instance");
    const interact = c.field(instance, "interact") orelse .null;
    for ([_]struct { key: []const u8, value: c.Value }{
        .{ .key = "instance", .value = registry },                          .{ .key = "rpc_url", .value = url },
        .{ .key = "interact", .value = interact },                          .{ .key = "etherscan_api_key", .value = try field(snapshot, "etherscanApiKey") },
        .{ .key = "kv_address", .value = try field(secrets, "kvAddress") },
    }) |entry| try set(&next, a, entry.key, entry.value);
    if (chain_id) |id| try next.set(a, "chain", try a.print("{d}", .{id})) else _ = next.values.orderedRemove("chain");
    if (kv_chain) |id| try next.set(a, "kv_chain", try a.print("{d}", .{id})) else _ = next.values.orderedRemove("kv_chain");
    // Imported credentials and destinations replace this profile's app state.
    // Foundry signer selection remains independent of the app's wallet address.
    _ = next.values.orderedRemove("etherscan_api_key_env");
    _ = next.values.orderedRemove("factory");
    _ = next.values.orderedRemove("kv_factory");
    _ = next.values.orderedRemove("kv_rpc_url");
    for ([_][]const u8{ "rpc.", "instances.", "interacts." }) |prefix| {
        var i: usize = 0;
        while (i < next.values.count()) {
            const key = next.values.keys()[i];
            if (std.mem.startsWith(u8, key, prefix) and (chain_id == null or (config.chainId(key[prefix.len..]) catch 0) == chain_id.?)) {
                _ = next.values.orderedRemove(key);
            } else i += 1;
        }
    }
    var random: [16]u8 = undefined;
    try io.randomSecure(&random);
    const id = try abi.hex(a, &random);
    try next.set(a, "configuration_id", id);
    const ref = try a.print("configuration:{s}:stackSecret", .{id});
    try next.set(a, "stack_secret_ref", if (secret != null) ref else "none");
    var public_secrets = secrets;
    try public_secrets.object.put(a, "stackSecret", .null);
    try snapshot.object.put(a, "secrets", public_secrets);
    // Credentials stay in their existing profile fields, never in public cache rows.
    try snapshot.object.put(a, "etherscanApiKey", .null);
    var public_rpc = try record(snapshot, "rpc");
    try public_rpc.object.put(a, "override", .null);
    try snapshot.object.put(a, "rpc", public_rpc);
    const db = try storage.Store.open(a, io, dir);
    defer db.close();
    try db.begin();
    errdefer db.db.rollback();
    if (secret) |value| {
        var v = try unlock(a, io, db, password_file, true);
        defer v.deinit();
        try v.put(ref, &value.private_key);
        if (next.get("kv_address")) |address| try v.putHead(try storage.scopeKey(a, kv_chain.?, address), value);
    }
    try db.put("configuration", "snapshots", id, snapshot);
    try db.db.commit();
    // A new immutable snapshot is committed before the atomic profile switch.
    // Failed profile writes leave the prior configuration pointer intact.
    try config.save(next, a, io, dir, name, true);
    return next;
}

fn stringOrNull(value: ?[]const u8) c.Value {
    return if (value) |text| .{ .string = text } else .null;
}
fn date(a: c.A, io: std.Io) ![]const u8 {
    const seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(std.Io.Clock.real.now(io).toSeconds()) };
    const day = seconds.getEpochDay().calculateYearDay();
    const month = day.calculateMonthDay();
    const time = seconds.getDaySeconds();
    return a.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.000Z", .{ day.year, month.month.numeric(), month.day_index + 1, time.getHoursIntoDay(), time.getMinutesIntoHour(), time.getSecondsIntoMinute() });
}

pub fn exportFile(a: c.A, io: std.Io, env: *const std.process.Environ.Map, dir: []const u8, p: config.Profile, path: ?[]const u8, password_file: ?[]const u8, colored: bool) !void {
    const db = try storage.Store.open(a, io, dir);
    defer db.close();
    var snapshot = if (p.get("configuration_id")) |id| (try db.entries("configuration", "snapshots")).get(id) orelse return error.ConfigurationSnapshotMissing else try c.parse(a,
        \\{"version":2,"generatedAt":"","chainId":null,"account":null,"locale":"en-US","registry":{"address":null},"safeFactory":{"resolvedAddress":null,"manualOverride":null,"snapshot":null,"instance":null},"rpc":{"override":null},"secrets":{"stackSecret":null,"kvAddress":null,"kvChainId":null},"etherscanApiKey":null}
    );
    const chain_id = if (p.get("chain")) |value| try config.chainId(value) else null;
    const address = if (chain_id) |id| p.forChain("instances.", id) orelse p.get("instance") else p.get("instance");
    const old_chain = try chain(a, try field(snapshot, "chainId"));
    const old_address = try optional(try field(try record(snapshot, "registry"), "address"));
    if (old_chain != chain_id or !std.ascii.eqlIgnoreCase(old_address orelse "", address orelse "")) {
        try snapshot.object.put(a, "safeFactory", try c.parse(a, "{\"resolvedAddress\":null,\"manualOverride\":null,\"snapshot\":null,\"instance\":null}"));
    }
    if (chain_id) |id| if (address) |registry| if (try field(try record(snapshot, "safeFactory"), "instance") == .null) {
        if ((try db.entries(try storage.scopeKey(a, id, registry), "deployment")).get("instance")) |deployed| {
            var instance = deployed;
            try instance.object.put(a, "index", try abi.uint(a, try c.number(a, try field(deployed, "index"))));
            try instance.object.put(a, "flags", .{ .integer = @intCast(try c.number(a, try field(deployed, "flags"))) });
            try instance.object.put(a, "logIndex", .null);
            try snapshot.object.put(a, "safeFactory", try c.parse(a, try c.encode(a, .{ .resolvedAddress = try field(instance, "safeFactory"), .manualOverride = @as(c.Value, .null), .snapshot = @as(c.Value, .null), .instance = instance })));
        }
    };
    try snapshot.object.put(a, "generatedAt", .{ .string = try date(a, io) });
    try snapshot.object.put(a, "chainId", if (chain_id) |id| .{ .integer = @intCast(id) } else .null);
    try snapshot.object.put(a, "registry", try c.parse(a, try c.encode(a, .{ .address = stringOrNull(address) })));
    const url = if (chain_id) |id| p.forChain("rpc.", id) orelse p.get("rpc_url") else p.get("rpc_url");
    try snapshot.object.put(a, "rpc", try c.parse(a, try c.encode(a, .{ .override = stringOrNull(url) })));
    const key = p.get("etherscan_api_key") orelse env.get(p.get("etherscan_api_key_env") orelse "ETHERSCAN_API_KEY");
    try snapshot.object.put(a, "etherscanApiKey", stringOrNull(key));
    var secrets = try record(snapshot, "secrets");
    try secrets.object.put(a, "kvAddress", stringOrNull(p.get("kv_address")));
    const kv_chain = if (p.get("kv_chain")) |value| try config.chainId(value) else if (p.get("kv_address") != null) chain_id orelse 1 else null;
    try secrets.object.put(a, "kvChainId", if (kv_chain) |id| .{ .integer = @intCast(id) } else .null);
    var secret_hex: ?[]const u8 = null;
    defer if (secret_hex) |text| std.crypto.secureZero(u8, @constCast(text));
    if (try secretReference(a, p)) |ref| {
        var v = try unlock(a, io, db, password_file, false);
        defer v.deinit();
        const bytes = (try v.get(ref)) orelse return error.KvSecretRequired;
        defer std.crypto.secureZero(u8, bytes);
        if (bytes.len != 32) return error.InvalidKvSecret;
        secret_hex = try abi.hex(a, bytes);
    }
    try secrets.object.put(a, "stackSecret", stringOrNull(secret_hex));
    try snapshot.object.put(a, "secrets", secrets);
    try validate(a, snapshot);
    const encoded = try c.encode(a, snapshot);
    defer std.crypto.secureZero(u8, @constCast(encoded));
    if (path) |file| {
        if (!c.eq(u8, file, "-")) return c.write(io, file, encoded, true);
    }
    try display.printJson(io, encoded, colored);
}
