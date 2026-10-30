const std = @import("std");
const c = @import("common.zig");
const config = @import("config.zig");
const rpc = @import("rpc.zig");
const Store = @import("store.zig").Store;
const Cast = @import("cast.zig").Cast;
const Args = @import("args.zig").Args;

fn field(value: c.Value, key: []const u8) !c.Value {
    return c.field(value, key) orelse error.InvalidRpcPool;
}
fn string(value: c.Value, key: []const u8) ![]const u8 {
    return c.string(try field(value, key));
}
fn path(a: c.A, dir: []const u8, profile: []const u8, chain: u64) ![]const u8 {
    if (!config.validName(profile)) return error.InvalidProfileName;
    return a.print("{s}/rpc-pools/{s}-{d}.json", .{ dir, profile, chain });
}
fn validPrivacy(value: []const u8) bool {
    return @import("schema.zig").contains("private public unknown", value);
}
fn validateUrl(a: c.A, value: []const u8) !void {
    if (value.len == 0 or value.len > 8192) return error.InvalidRpcUrl;
    const uri = std.Uri.parse(value) catch return error.InvalidRpcUrl;
    const host = try (uri.host orelse return error.InvalidRpcUrl).toRawMaybeAlloc(a);
    if (host.len == 0 or uri.user != null or uri.password != null or uri.fragment != null) return error.InvalidRpcUrl;
    if (!c.eq(u8, uri.scheme, "https") and !(c.eq(u8, uri.scheme, "http") and @import("schema.zig").contains("localhost 127.0.0.1 [::1] ::1", host))) return error.RpcPoolRequiresSecureUrl;
}
fn load(a: c.A, io: std.Io, dir: []const u8, profile: []const u8, chain: u64) !c.Value {
    const raw = c.read(a, io, try path(a, dir, profile, chain)) catch |err| {
        if (err == error.FileNotFound) return c.parse(a, "{\"version\":1,\"privacy\":\"all\",\"endpoints\":[]}");
        return err;
    };
    const state = try c.parse(a, raw);
    if (try c.number(a, try field(state, "version")) != 1 or !@import("schema.zig").contains("all private", try string(state, "privacy"))) return error.InvalidRpcPool;
    const entries = try field(state, "endpoints");
    if (entries != .array or entries.array.items.len > 32) return error.InvalidRpcPool;
    var names: std.StringHashMapUnmanaged(void) = .empty;
    for (entries.array.items) |entry| {
        const name = try string(entry, "name");
        if (!config.validName(name) or names.contains(name) or !validPrivacy(try string(entry, "privacy"))) return error.InvalidRpcPool;
        try names.put(a, name, {});
        try validateUrl(a, try string(entry, "url"));
    }
    return state;
}
fn eligible(state: c.Value, endpoint: c.Value) !bool {
    return c.eq(u8, try string(state, "privacy"), "all") or c.eq(u8, try string(endpoint, "privacy"), "private");
}
/// A private-only pool is an opt-in profile policy. Explicit URLs still have to
/// belong to an endpoint the user classified as private on this chain.
pub fn validateSelection(a: c.A, io: std.Io, dir: []const u8, profile: []const u8, chain: u64, url: []const u8) !void {
    if (url.len == 0) return;
    const state = try load(a, io, dir, profile, chain);
    if (c.eq(u8, try string(state, "privacy"), "all")) return;
    for ((try field(state, "endpoints")).array.items) |entry| if (c.eq(u8, url, try string(entry, "url")) and try eligible(state, entry)) return;
    return error.RpcPrivacyFilterExcluded;
}
fn probe(cast: *Cast, url: []const u8, timeout: u32, reported_chain: *?u64) !rpc.Block {
    var remote = try rpc.Rpc.initEndpoint(cast.a, cast.io, url, cast.chain);
    defer remote.deinit();
    defer reported_chain.* = remote.reported_chain;
    remote.timeout_seconds = timeout;
    try remote.pinBlock(null, 0);
    if (remote.block.hash.len != 66 or try c.word(remote.block.hash) == 0) return error.InvalidRpcBlock;
    if (!try remote.canonical(remote.block)) return error.ChainReorganizedRetrySync;
    return remote.block;
}
fn observation(cast: *Cast, endpoint: c.Value, timeout: u32) !c.Value {
    const began = std.Io.Clock.awake.now(cast.io);
    var failure: ?[]const u8 = null;
    var reported_chain: ?u64 = null;
    const block: ?rpc.Block = probe(cast, try string(endpoint, "url"), timeout, &reported_chain) catch |err| blk: {
        if (err == error.OutOfMemory) return err;
        failure = @errorName(err);
        break :blk @as(?rpc.Block, null);
    };
    const elapsed = began.durationTo(std.Io.Clock.awake.now(cast.io)).toMilliseconds();
    return c.parse(cast.a, try c.encode(cast.a, .{ .checkedAt = std.Io.Clock.real.now(cast.io).toSeconds(), .latencyMs = elapsed, .status = if (failure == null) "healthy" else "unavailable", .@"error" = failure, .expectedChainId = cast.chain, .reportedChainId = reported_chain, .block = block }));
}
fn withinLag(a: c.A, health: c.Value, reference: u64, maximum: u64) !bool {
    if (!c.eq(u8, try string(health, "status"), "healthy")) return false;
    const height = try rpc.integer(a, try field(try field(health, "block"), "number"));
    return reference -| height <= maximum;
}
fn refreshLagging(cast: *Cast, candidate: *c.Value, reference: u64, maximum: u64, timeout: u32) !bool {
    if (try withinLag(cast.a, try field(candidate.*, "health"), reference, maximum)) return false;
    const fresh = try observation(cast, try field(candidate.*, "endpoint"), timeout);
    try candidate.object.put(cast.a, "health", fresh);
    return true;
}
fn saveHealth(db: Store, scope: []const u8, name: []const u8, current: c.Value) !void {
    try db.begin();
    errdefer db.db.rollback();
    const previous = (try db.entries(scope, "rpc-health")).get(name);
    var history = std.json.Array.init(db.a);
    var failures: u64 = 0;
    var successes: u64 = 0;
    var consecutive: u64 = 0;
    if (previous) |value| {
        const old = (try field(value, "history")).array.items;
        for (old[old.len -| 19..]) |item| try history.append(item);
        failures = try rpc.integer(db.a, try field(value, "failures"));
        successes = try rpc.integer(db.a, try field(value, "successes"));
        consecutive = try rpc.integer(db.a, try field(value, "consecutiveFailures"));
    }
    try history.append(current);
    const healthy = c.eq(u8, try string(current, "status"), "healthy");
    try db.put(scope, "rpc-health", name, try c.parse(db.a, try c.encode(db.a, .{ .latest = current, .history = history.items, .failures = failures + @intFromBool(!healthy), .successes = successes + @intFromBool(healthy), .consecutiveFailures = if (healthy) 0 else consecutive + 1 })));
    try db.db.commit();
}
pub fn run(cast: *Cast, dir: []const u8, profile_name: []const u8, args: *Args, p: []const []const u8, dry: bool) !c.Value {
    const a = cast.a;
    if (p.len < 2 or !@import("schema.zig").contains("add remove list probe use choose privacy", p[1])) return error.UnknownCommand;
    const verb = p[1];
    const add = c.eq(u8, verb, "add");
    const remove = c.eq(u8, verb, "remove");
    const selecting = c.eq(u8, verb, "choose") or c.eq(u8, verb, "use");
    const privacy = c.eq(u8, verb, "privacy");
    const probing = selecting or c.eq(u8, verb, "probe");
    if (p.len > 3 or ((add or remove or privacy or c.eq(u8, verb, "use")) and p.len != 3) or ((c.eq(u8, verb, "list") or c.eq(u8, verb, "choose")) and p.len != 2)) return error.WrongArgumentCount;
    if (p.len == 3 and !config.validName(p[2])) return error.InvalidRpcEndpointName;
    const classification = if (add) args.get("privacy") orelse "unknown" else "";
    if (add and !validPrivacy(classification)) return error.InvalidRpcPrivacy;
    const timeout = if (probing) try std.fmt.parseInt(u32, args.get("timeout") orelse "5", 10) else 5;
    if (timeout == 0 or timeout > 30) return error.InvalidRpcProbeTimeout;
    const max_lag = if (c.eq(u8, verb, "choose")) try std.fmt.parseInt(u64, args.get("max-lag") orelse "3", 10) else 0;
    const out = args.get("out");
    try args.finish();
    if (cast.block != null) return error.RpcProbeRequiresLatestBlock;
    if (out) |output| try c.write(cast.io, output, "{\"status\":\"rpc-command-in-progress\"}\n", false);
    const file = try path(a, dir, profile_name, cast.chain);
    try std.Io.Dir.cwd().createDirPath(cast.io, std.Io.Dir.path.dirname(file).?);
    const lock = try std.Io.Dir.cwd().createFile(cast.io, try a.print("{s}.lock", .{file}), .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true, .permissions = .fromMode(0o600) });
    defer lock.close(cast.io);
    var state = try load(a, cast.io, dir, profile_name, cast.chain);
    const entries = state.object.getPtr("endpoints").?;
    var profile = try config.load(a, cast.io, dir, profile_name);
    const scope = try a.print("rpc:{s}:{d}", .{ profile_name, cast.chain });
    const db = try Store.open(a, cast.io, dir);
    defer db.close();
    var selected_name: ?[]const u8 = null;
    var state_changed = false;
    var profile_changed = false;
    if (add) {
        try validateUrl(a, cast.rpc);
        if (entries.array.items.len == 32) return error.RpcPoolFull;
        for (entries.array.items) |entry| if (c.eq(u8, p[2], try string(entry, "name")) or c.eq(u8, cast.rpc, try string(entry, "url"))) return error.RpcEndpointAlreadyExists;
        try entries.array.append(try c.parse(a, try c.encode(a, .{ .name = p[2], .url = cast.rpc, .privacy = classification })));
        state_changed = true;
    } else if (remove) {
        var found = false;
        for (entries.array.items, 0..) |entry, index| {
            if (!c.eq(u8, p[2], try string(entry, "name"))) continue;
            const url = try string(entry, "url");
            if (profile.forChain("rpc.", cast.chain)) |current| if (c.eq(u8, url, current)) {
                try profile.setForChain(a, "rpc.", cast.chain, null);
                profile_changed = true;
            };
            if (cast.chain == try config.chainId(profile.get("chain") orelse "ethereum") and c.eq(u8, profile.get("rpc_url") orelse "", url)) {
                _ = profile.values.orderedRemove("rpc_url");
                profile_changed = true;
            }
            _ = entries.array.orderedRemove(index);
            found = true;
            break;
        }
        if (!found) return error.RpcEndpointNotFound;
        state_changed = true;
        if (!dry) try db.remove(scope, "rpc-health", p[2]);
    } else if (privacy) {
        if (!@import("schema.zig").contains("all private", p[2])) return error.InvalidRpcPrivacy;
        state.object.getPtr("privacy").?.* = .{ .string = p[2] };
        state_changed = true;
    }
    if (probing) {
        var candidates = std.json.Array.init(a);
        var failures: std.Io.Writer.Allocating = .init(a);
        var highest: u64 = 0;
        var found = false;
        for (entries.array.items) |endpoint| {
            const name = try string(endpoint, "name");
            if (p.len == 3 and !c.eq(u8, p[2], name)) continue;
            found = true;
            if (!try eligible(state, endpoint)) {
                if (p.len == 3) return error.RpcPrivacyFilterExcluded;
                continue;
            }
            const result = try observation(cast, endpoint, timeout);
            try saveHealth(db, scope, name, result);
            if (c.eq(u8, try string(result, "status"), "healthy")) {
                highest = @max(highest, try rpc.integer(a, try field(try field(result, "block"), "number")));
                try candidates.append(try c.parse(a, try c.encode(a, .{ .endpoint = endpoint, .health = result })));
            } else {
                try failures.writer.print("{s}: {s}", .{ name, try string(result, "error") });
                if (c.eq(u8, try string(result, "error"), "RpcChainMismatch")) try failures.writer.print(" (endpoint reports {d}, profile expects {d})", .{ try c.number(a, try field(result, "reportedChainId")), cast.chain });
                try failures.writer.writeByte('\n');
            }
        }
        if (p.len == 3 and !found) return error.RpcEndpointNotFound;
        if (selecting) {
            var best: ?c.Value = null;
            for (candidates.items) |*candidate| {
                // The first sample may predate blocks produced during later probes.
                // Recheck apparent lag against a fixed reference; refreshing must
                // not move that reference and make another candidate stale again.
                if (try refreshLagging(cast, candidate, highest, max_lag, timeout)) {
                    try saveHealth(db, scope, try string(try field(candidate.*, "endpoint"), "name"), try field(candidate.*, "health"));
                }
                const health = try field(candidate.*, "health");
                if (!try withinLag(a, health, highest, max_lag)) continue;
                if (best == null or try c.number(a, try field(health, "latencyMs")) < try c.number(a, try field(try field(best.?, "health"), "latencyMs"))) best = candidate.*;
            }
            const endpoint = try field(best orelse {
                cast.diagnostic = try failures.toOwnedSlice();
                return error.NoHealthyRpcEndpoint;
            }, "endpoint");
            selected_name = try string(endpoint, "name");
            try profile.setForChain(a, "rpc.", cast.chain, try string(endpoint, "url"));
            profile_changed = true;
        }
    }
    if (!dry) {
        if (state_changed) try c.write(cast.io, file, try c.encode(a, state), true);
        if (profile_changed) try config.save(profile, a, cast.io, dir, profile_name, true);
    }
    const health = try db.entries(scope, "rpc-health");
    const active = profile.forChain("rpc.", cast.chain) orelse if (cast.chain == try config.chainId(profile.get("chain") orelse "ethereum")) profile.get("rpc_url") orelse "" else "";
    var rows = std.json.Array.init(a);
    for (entries.array.items) |endpoint| {
        const name = try string(endpoint, "name");
        try rows.append(try c.parse(a, try c.encode(a, .{ .name = name, .privacy = try string(endpoint, "privacy"), .eligible = try eligible(state, endpoint), .selected = c.eq(u8, active, try string(endpoint, "url")), .health = health.get(name) orelse .null })));
    }
    const report = try c.parse(a, try c.encode(a, .{ .chainId = cast.chain, .profile = profile_name, .privacy = try string(state, "privacy"), .endpoints = rows.items, .selected = selected_name, .dryRun = dry }));
    if (out) |output| try c.write(cast.io, output, try c.encode(a, report), true);
    return report;
}

test "earlier RPC samples are refreshed before rejecting apparent lag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mock = @import("test_rpc.zig");
    const block = "[{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"number\":\"0x78\",\"hash\":\"0x1111111111111111111111111111111111111111111111111111111111111111\",\"timestamp\":\"0x1\"}}]";
    var server = try mock.Server.init(std.testing.io, &.{
        .{ .body = "[{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\"0xa4b1\"}]" },
        .{ .body = block },
        .{ .body = block },
    });
    defer server.deinit();
    var serving = try std.testing.io.concurrent(mock.Server.serve, .{&server});
    defer _ = serving.cancel(std.testing.io) catch {};
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    var cast: Cast = .{ .a = a, .io = std.testing.io, .env = &env, .chain = 42161 };
    var candidate = try c.parse(a, try c.encode(a, .{ .endpoint = .{ .url = try server.url(a) }, .health = .{ .status = "healthy", .block = .{ .number = 100 } } }));
    try std.testing.expect(try refreshLagging(&cast, &candidate, 110, 3, 5));
    try serving.await(std.testing.io);
    try std.testing.expect(try withinLag(a, try field(candidate, "health"), 110, 3));
    const later = try c.parse(a, "{\"status\":\"healthy\",\"block\":{\"number\":110}}");
    try std.testing.expect(try withinLag(a, later, 110, 3));
    try std.testing.expect(!try withinLag(a, later, 120, 3));
}

test "RPC selection reports endpoint chain disagreement without exposing its URL" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    const mock = @import("test_rpc.zig");
    var server = try mock.Server.init(std.testing.io, &.{.{ .body = "[{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\"0xa4b1\"}]" }});
    defer server.deinit();
    var serving = try std.testing.io.concurrent(mock.Server.serve, .{&server});
    defer _ = serving.cancel(std.testing.io) catch {};
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    const url = try a.print("{s}/secret-key", .{try server.url(a)});
    var cast: Cast = .{ .a = a, .io = std.testing.io, .env = &env, .chain = 1, .rpc = url };
    var add_args = try Args.parse(a, &.{});
    _ = try run(&cast, dir, "default", &add_args, &.{ "rpc", "add", "arb1" }, false);
    var use_args = try Args.parse(a, &.{});
    try std.testing.expectError(error.NoHealthyRpcEndpoint, run(&cast, dir, "default", &use_args, &.{ "rpc", "use", "arb1" }, false));
    try std.testing.expect(std.mem.indexOf(u8, cast.diagnostic.?, "arb1: RpcChainMismatch (endpoint reports 42161, profile expects 1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, cast.diagnostic.?, "secret-key") == null);
    try std.testing.expect((try config.load(a, std.testing.io, dir, "default")).forChain("rpc.", 1) == null);
    try serving.await(std.testing.io);
}
