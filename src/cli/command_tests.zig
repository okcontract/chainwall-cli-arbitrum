//! Black-box command tests: real executable, isolated configuration, Zig-only fixtures.
const std = @import("std");
const c = @import("common.zig");
const abi = @import("abi_codec.zig");
const contracts = @import("contracts.zig");
const mock = @import("test_rpc.zig");
const binaries = @import("executables");
const registry = "0x1111111111111111111111111111111111111111";
const interact = "0x2222222222222222222222222222222222222222";
const safe = "0x3333333333333333333333333333333333333333";
const factory = "0x4444444444444444444444444444444444444444";
const module_address = "0x5555555555555555555555555555555555555555";
const actor = "0x6666666666666666666666666666666666666666";
const hash = "0x0000000000000000000000000000000000000000000000000000000000000001";
const block = "{\"number\":\"0x64\",\"timestamp\":\"0x64\",\"hash\":\"" ++ hash ++ "\"}";

const CastMode = enum { current, legacy, mined };

fn run(a: c.A, dir: []const u8, url: []const u8, args: []const []const u8) !std.process.RunResult {
    return runWithCast(a, dir, url, args, .current);
}
fn runWithCast(a: c.A, dir: []const u8, url: []const u8, args: []const []const u8, mode: CastMode) !std.process.RunResult {
    return runWithFormat(a, dir, url, args, mode, true);
}
fn runWithFormat(a: c.A, dir: []const u8, url: []const u8, args: []const []const u8, mode: CastMode, json: bool) !std.process.RunResult {
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("PATH", std.fs.path.dirname(binaries.cast).?);
    try env.put("CLICOLOR_FORCE", "1");
    try env.put("FORCE_COLOR", "1");
    if (mode == .legacy) try env.put("CHAINWALL_TEST_LEGACY_CAST", "1");
    if (mode == .mined) try env.put("CHAINWALL_TEST_MINED_SEND", "1");
    return std.process.run(a, std.testing.io, .{
        .argv = try std.mem.concat(a, []const u8, &.{ &.{ binaries.cli, "--config-dir", dir, "--chain", "arbitrum", "--instance", registry, "--rpc-url", url }, if (json) &.{"--json"} else &.{}, args }),
        .environ_map = &env,
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(30) } },
    });
}
fn success(output: std.process.RunResult) !void {
    if (output.term != .exited or output.term.exited != 0) std.debug.print("CLI failed: {s}\n{s}\n", .{ output.stdout, output.stderr });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, output.term);
}
fn reply(a: c.A, value: c.Value) !mock.Reply {
    return .{ .body = try c.encode(a, .{.{ .jsonrpc = "2.0", .id = 1, .result = value }}) };
}
fn contractReply(a: c.A, cat: contracts.Catalog, group: []const u8, name: []const u8, values: []const c.Value) !mock.Reply {
    const method = try cat.find(group, name);
    return reply(a, .{ .string = try abi.hex(a, try abi.encode(a, c.field(method.abi, "outputs").?, try abi.array(a, values))) });
}

test "doctor fails when cast send does not support raw calldata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    const result = try runWithCast(a, dir, "http://127.0.0.1:1", &.{"doctor"}, .legacy);
    try std.testing.expect(result.term == .exited and result.term.exited != 0);
    const report = try c.parse(a, result.stdout);
    try std.testing.expect(!c.field(report, "ok").?.bool);
    const cast = c.field(report, "cast").?;
    try std.testing.expectEqualStrings("IncompatibleFoundrySend", try c.string(c.field(cast, "code").?));
    try std.testing.expect(std.mem.indexOf(u8, try c.string(c.field(cast, "action").?), "foundryup --install 1.8.6") != null);
}

test "RPC chain mismatch reaches human and JSON command errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]bool{ false, true }) |json| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
        var server = try mock.Server.init(std.testing.io, &.{try reply(a, .{ .string = "0x1" })});
        defer server.deinit();
        var serving = try std.testing.io.concurrent(mock.Server.serve, .{&server});
        defer _ = serving.cancel(std.testing.io) catch {};
        const url = try a.print("{s}/secret-key", .{try server.url(a)});
        try success(try run(a, dir, url, &.{ "rpc", "add", "wrong-chain" }));
        const result = try runWithFormat(a, dir, url, &.{ "rpc", "use", "wrong-chain" }, .current, json);
        try std.testing.expect(result.term == .exited and result.term.exited != 0);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, result.stderr, "wrong-chain: RpcChainMismatch (endpoint reports 1, profile expects 42161)"));
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "secret-key") == null);
        if (json) {
            const failure = c.field(try c.parse(a, result.stderr), "error").?;
            try std.testing.expectEqualStrings("NoHealthyRpcEndpoint", try c.string(c.field(failure, "code").?));
        }
        try serving.await(std.testing.io);
        try std.testing.expectEqual(@as(usize, 1), server.requests);
    }
}

test "captured contract errors are decoded and redacted in human and JSON output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    for ([_]bool{ false, true }) |json| {
        const result = try runWithFormat(a, dir, "https://provider.example/secret-key/fixture-revert", &.{ "registry", "paused" }, .current, json);
        try std.testing.expect(result.term == .exited and result.term.exited != 0);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, result.stderr, "Decoded revert:"));
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "InvalidFeedConfiguration") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "0xbed8168a") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "secret-key") == null);
        if (json) {
            const failure = c.field(try c.parse(a, result.stderr), "error").?;
            try std.testing.expectEqualStrings("CastFailed", try c.string(c.field(failure, "code").?));
        }
    }
}

test "real CLI preserves account, Safe and module routes and envelopes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    try c.write(std.testing.io, try a.print("{s}/default.toml", .{dir}), "interact = '" ++ interact ++ "'\n", false);
    const file = try a.print("{s}/operation.json", .{dir});
    try c.write(std.testing.io, file, try c.encode(a, .{ .version = 2, .chainId = 42161, .operationId = 1, .interactionId = hash, .policyId = hash, .safe = safe, .nativeValue = 0, .deadline = 1000, .args = .{}, .executionBindingHash = hash, .payloadHash = hash, .creator = actor, .createdAt = 1 }), false);
    const local = "http://127.0.0.1:1";
    const account = try run(a, dir, local, &.{ "operations", "execute", file, "--via", "account", "--dry-run" });
    try success(account);
    const envelope = try c.parse(a, account.stdout);
    try std.testing.expectEqualStrings(interact, try c.string(c.field(envelope, "to").?));
    const auxiliary = try contracts.Catalog.loadAuxiliary(a);
    const method = try auxiliary.find("interact", "executeFromAccount");
    const expected = try abi.calldata(a, method.abi, try abi.array(a, &.{ try abi.uint(a, 1), .{ .string = hash }, try abi.array(a, &.{}), try abi.uint(a, 100000) }));
    try std.testing.expectEqualStrings(expected, try c.string(c.field(envelope, "data").?));

    const signing = try run(a, dir, local, &.{ "operations", "sign-actor", file, "--via", "safe", "--from", actor, "--dry-run" });
    try success(signing);
    var auth = try c.parse(a, signing.stdout);
    try auth.object.put(a, "signature", .{ .string = "0x12" });
    const signature = try a.print("{s}/actor.json", .{dir});
    try c.write(std.testing.io, signature, try c.encode(a, auth), false);
    const safe_output = try run(a, dir, local, &.{ "operations", "execute", file, "--via", "safe", "--actor-signature-file", signature, "--dry-run" });
    try success(safe_output);
    const safe_tx = c.field(try c.parse(a, safe_output.stdout), "transaction").?;
    try std.testing.expectEqualStrings(safe, try c.string(c.field(safe_tx, "to").?));
    try std.testing.expect(std.mem.startsWith(u8, try c.string(c.field(safe_tx, "data").?), "0x6a761202"));

    const cat = try contracts.Catalog.load(a);
    const releases = try contracts.Catalog.loadReleases(a);
    const ms = @import("miniscript");
    const replies = [_]mock.Reply{
        try reply(a, .{ .string = "0xa4b1" }),                                                                                                                     try reply(a, try c.parse(a, block)),                                                                                                                 try reply(a, .{ .string = "0x6000" }),
        try contractReply(a, cat, "accounts", "isSafeAllowed", &.{.{ .bool = true }}),                                                                             try contractReply(a, cat, "capabilities", "getCapabilityActors", &.{try abi.array(a, &.{.{ .string = factory }})}),                                  try reply(a, .{ .string = "0x6000" }),
        try contractReply(a, releases, "release-safeFactory", "chainwallComponentId", &.{.{ .string = try c.hex(a, ms.bytecode.hash("Chainwall.SafeFactory")) }}), try contractReply(a, releases, "release-safeFactory", "isSafe", &.{.{ .bool = true }}),                                                              try contractReply(a, releases, "release-safeFactory", "INTERACT_CONTRACT", &.{.{ .string = interact }}),
        try contractReply(a, releases, "release-safeFactory", "validateManagedSafe", &.{}),                                                                        try contractReply(a, releases, "release-safeFactory", "MODULE_CONTRACT", &.{.{ .string = module_address }}),                                         try contractReply(a, releases, "release-safeFactory", "INDEXING_ENABLED", &.{.{ .bool = false }}),
        try contractReply(a, auxiliary, "safe", "isModuleEnabled", &.{.{ .bool = true }}),                                                                         try contractReply(a, releases, "release-okModule", "chainwallComponentId", &.{.{ .string = try c.hex(a, ms.bytecode.hash("Chainwall.OKModule")) }}), try contractReply(a, releases, "release-okModule", "INTERACTION", &.{.{ .string = interact }}),
        try contractReply(a, releases, "release-okModule", "validateSafeExtensions", &.{}),                                                                        try reply(a, try c.parse(a, block)),                                                                                                                 try reply(a, try c.parse(a, block)),
    };
    var server = try mock.Server.init(std.testing.io, &replies);
    defer server.deinit();
    var serving = try std.testing.io.concurrent(mock.Server.serve, .{&server});
    defer _ = serving.cancel(std.testing.io) catch {};
    const module_output = try run(a, dir, try server.url(a), &.{ "operations", "execute", file, "--via", "module", "--from", actor, "--dry-run" });
    try success(module_output);
    const result = try c.parse(a, module_output.stdout);
    try std.testing.expectEqualStrings("module", try c.string(c.field(result, "via").?));
    const transaction = c.field(result, "transaction").?;
    try std.testing.expectEqualStrings(module_address, try c.string(c.field(transaction, "to").?));
    const module_method = try releases.find("release-okModule", "executeInteraction");
    try std.testing.expectEqualStrings(module_method.signature, try c.string(c.field(transaction, "function").?));
    try serving.await(std.testing.io);
    try std.testing.expectEqual(replies.len, server.requests);
}

test "real CLI rejects inapplicable flags before changing configuration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    const doctor = try run(a, dir, "http://127.0.0.1:1", &.{"doctor"});
    try success(doctor);
    try std.testing.expect(c.field(try c.parse(a, doctor.stdout), "ok").?.bool);
    const source = try a.print("{s}/source.ls", .{dir});
    const settings = try a.print("{s}/settings.json", .{dir});
    try c.write(std.testing.io, source, "1", false);
    try c.write(std.testing.io, settings, "{\"optimizationTypo\":\"size\"}", false);
    const invalid_settings = try run(a, dir, "http://127.0.0.1:1", &.{ "compile", source, "--settings", settings });
    try std.testing.expect(invalid_settings.term == .exited and invalid_settings.term.exited != 0);
    const input_error = c.field(try c.parse(a, invalid_settings.stderr), "error").?;
    try std.testing.expectEqualStrings("/optimizationTypo", try c.string(c.field(input_error, "field").?));
    try std.testing.expectEqualStrings("JsonInputValidationFailed", try c.string(c.field(input_error, "code").?));
    const failed = try run(a, dir, "http://127.0.0.1:1", &.{ "config", "set", "editor", "review-editor", "--estimate" });
    try std.testing.expect(failed.term == .exited and failed.term.exited != 0);
    const error_record = try c.parse(a, failed.stderr);
    try std.testing.expectEqual(@as(u256, 1), try c.number(a, c.field(error_record, "schemaVersion").?));
    try std.testing.expect(!c.field(error_record, "ok").?.bool);
    const path = try a.print("{s}/default.toml", .{dir});
    try std.testing.expectError(error.FileNotFound, c.read(a, std.testing.io, path));
    try success(try run(a, dir, "http://127.0.0.1:1", &.{ "config", "set", "editor", "review-editor" }));
    try std.testing.expect(std.mem.indexOf(u8, try c.read(a, std.testing.io, path), "review-editor") != null);
}

test "config updates explain when a command option shadows the saved value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    const changed = try run(a, dir, "http://127.0.0.1:1", &.{ "config", "set", "instance", interact });
    try success(changed);
    const explanation = try run(a, dir, "http://127.0.0.1:1", &.{ "config", "explain", "instance" });
    try success(explanation);
    const entry = c.field(try c.parse(a, explanation.stdout), "settings").?.array.items[0];
    try std.testing.expectEqualStrings(registry, try c.string(c.field(entry, "value").?));
    try std.testing.expectEqualStrings("instance", try c.string(c.field(entry, "source").?));
    try std.testing.expectEqualStrings("instance", try c.string(c.field(entry, "shadowedProfileKeys").?.array.items[0]));
    const saved = try @import("config.zig").load(a, std.testing.io, dir, "default");
    try std.testing.expectEqualStrings(interact, saved.get("instance").?);
}

test "a stopped broadcast retains the actual signer nonce and block in its recovery journal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    const replies = [_]mock.Reply{
        try reply(a, .{ .string = "0xa4b1" }), try reply(a, try c.parse(a, block)),
        try reply(a, .{ .string = "0x5" }),    try reply(a, try c.parse(a, block)),
    };
    var server = try mock.Server.init(std.testing.io, &replies);
    defer server.deinit();
    var serving = try std.testing.io.concurrent(mock.Server.serve, .{&server});
    defer _ = serving.cancel(std.testing.io) catch {};
    const output = try run(a, dir, try server.url(a), &.{ "registry", "pause", "--account", "fixture" });
    try std.testing.expect(output.term == .exited and output.term.exited != 0);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "FixtureBroadcastStopped") != null);
    const journals = try @import("logs.zig").list(a, std.testing.io, dir);
    try std.testing.expectEqual(@as(usize, 1), journals.len);
    const journal = try c.parse(a, try c.read(a, std.testing.io, journals[0].path));
    const intent = c.field(c.field(journal, "submissions").?.array.items[0], "transaction").?;
    try std.testing.expectEqualStrings(actor, try c.string(c.field(intent, "from").?));
    try std.testing.expectEqual(@as(u256, 5), try c.number(a, c.field(intent, "nonce").?));
    try std.testing.expectEqual(@as(u256, 42161), try c.number(a, c.field(intent, "chainId").?));
    try std.testing.expectEqualStrings(hash, try c.string(c.field(c.field(intent, "submissionBlock").?, "hash").?));
    try serving.await(std.testing.io);
}

test "explicit terms document verification works offline and rejects changed bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    const file = try a.print("{s}/terms.txt", .{dir});
    const output = try a.print("{s}/verified.txt", .{dir});
    const document = "Example terms\r\n";
    try c.write(std.testing.io, file, document, false);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(document, &digest, .{});
    const expected = try abi.hex(a, &digest);
    const uri = "ipfs://QmYwAPJzv5CZsnAzt8auVZRnGgWNxT5P8M28DQ4NhM5wq6/terms.txt";
    const checked = try run(a, dir, "not-an-rpc-url", &.{ "terms", "document", uri, expected, "--document-file", file, "--offline", "--out", output });
    try success(checked);
    const report = try c.parse(a, checked.stdout);
    try std.testing.expectEqualStrings("not-checked", try c.string(c.field(report, "publicationStatus").?));
    try std.testing.expect(c.field(report, "block") == null);
    try std.testing.expectEqualStrings(document, try c.read(a, std.testing.io, output));
    const automatic = try run(a, dir, "not-an-rpc-url", &.{ "terms", "document", uri, expected, "--document-file", file });
    try success(automatic);
    try c.write(std.testing.io, file, "Example terms\n", true);
    const mismatch = try run(a, dir, "not-an-rpc-url", &.{ "terms", "document", uri, expected, "--document-file", file });
    try std.testing.expect(mismatch.term == .exited and mismatch.term.exited != 0);
    try std.testing.expect(std.mem.indexOf(u8, mismatch.stderr, "TermsDocumentHashMismatch") != null);
    const missing = try run(a, dir, "not-an-rpc-url", &.{ "terms", "document", "--offline" });
    try std.testing.expect(std.mem.indexOf(u8, missing.stderr, "OfflineTermsInputsRequired") != null);
}

test "proposal reconciliation recovers prepared files idempotently and rejects unrelated evidence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    try c.write(std.testing.io, try a.print("{s}/default.toml", .{dir}), "interact = '" ++ interact ++ "'\n", false);
    const cat = try contracts.Catalog.loadAuxiliary(a);
    const method = try cat.find("interact", "getPayloadHash");
    var params = std.json.Array.init(a);
    try params.appendSlice(c.field(method.abi, "inputs").?.array.items);
    try params.append(try c.parse(a, "{\"type\":\"bytes32\"}"));
    const payload_hash = try c.hex(a, @import("miniscript").bytecode.hash(try abi.encode(a, .{ .array = params }, try abi.array(a, &.{ .{ .string = hash }, try abi.array(a, &.{}), .{ .string = hash }, try abi.uint(a, 1000), try abi.uint(a, 0), .{ .string = safe }, .{ .string = hash } }))));
    const payload = try c.parse(a, try c.encode(a, .{ .version = 2, .chainId = 42161, .operationId = 0, .interactionId = hash, .policyId = hash, .safe = safe, .nativeValue = 0, .deadline = 1000, .args = [_]c.Value{}, .executionBindingHash = hash, .payloadHash = payload_hash, .creator = actor, .createdAt = 0 }));
    const file = try a.print("{s}/prepared.json", .{dir});
    try c.write(std.testing.io, file, try c.encode(a, .{ .payload = payload, .state = "prepared" }), false);
    const calldata = try abi.calldata(a, (try cat.find("interact", "propose")).abi, try abi.array(a, &.{ .{ .string = payload_hash }, .{ .string = hash }, try abi.uint(a, 1000), try abi.uint(a, 0), .{ .string = safe } }));
    const topic = try c.hex(a, @import("miniscript").bytecode.hash("OperationProposed(uint256)"));
    var saved: ?[]const u8 = null;
    for (0..4) |scenario| {
        const tx = try c.parse(a, try c.encode(a, .{ .hash = hash, .to = interact, .from = actor, .value = "0x0", .chainId = "0xa4b1", .blockHash = hash, .blockNumber = "0x64", .input = if (scenario == 2) "0x1234" else calldata }));
        const receipt = try c.parse(a, try c.encode(a, .{ .transactionHash = hash, .status = if (scenario == 3) "0x0" else "0x1", .blockHash = hash, .blockNumber = "0x64", .logs = .{.{ .address = interact, .topics = .{ topic, try c.hex(a, @as(u256, 7)) }, .data = "0x", .transactionHash = hash, .blockHash = hash, .blockNumber = "0x64" }} }));
        const replies = [_]mock.Reply{
            try reply(a, .{ .string = "0xa4b1" }),
            try reply(a, try c.parse(a, block)),
            try reply(a, .{ .string = "0x6000" }),
            .{ .body = try c.encode(a, .{ .{ .jsonrpc = "2.0", .id = 1, .result = try c.hex(a, @import("miniscript").bytecode.hash("Chainwall.Interact")) }, .{ .jsonrpc = "2.0", .id = 2, .result = try c.hex(a, try c.word(registry)) } }) },
            try reply(a, tx),
            try reply(a, receipt),
            try reply(a, try c.parse(a, block)),
            try reply(a, try c.parse(a, block)),
            try reply(a, try c.parse(a, block)),
        };
        var server = try mock.Server.init(std.testing.io, replies[0..(if (scenario < 2) @as(usize, 9) else 7)]);
        defer server.deinit();
        var serving = try std.testing.io.concurrent(mock.Server.serve, .{&server});
        defer _ = serving.cancel(std.testing.io) catch {};
        const output = try run(a, dir, try server.url(a), if (scenario == 0) &.{ "operations", "reconcile", file, "--proposal-tx", hash } else &.{ "operations", "reconcile", file });
        if (scenario < 2) {
            try success(output);
            const record = try c.parse(a, try c.read(a, std.testing.io, file));
            try std.testing.expectEqual(7, try c.number(a, c.field(c.field(record, "payload").?, "operationId").?));
            try std.testing.expectEqual(100, try c.number(a, c.field(c.field(record, "payload").?, "createdAt").?));
            try std.testing.expect(!c.field(try c.parse(a, output.stdout), "submitted").?.bool);
            if (saved) |previous| try std.testing.expectEqualStrings(previous, try c.read(a, std.testing.io, file));
            saved = try c.read(a, std.testing.io, file);
        } else {
            try std.testing.expect(output.term == .exited and output.term.exited != 0);
            try std.testing.expectEqualStrings(saved.?, try c.read(a, std.testing.io, file));
        }
        try serving.await(std.testing.io);
    }
}

test "submitted transaction links appear once per hash including repriced replacements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input = "0xb3de648b0000000000000000000000000000000000000000000000000000000000000001";
    const replacement_hash = "0x0000000000000000000000000000000000000000000000000000000000000002";
    for ([_]bool{ false, true }) |repriced| {
        const receipt_hash = if (repriced) replacement_hash else hash;
        const transaction = try c.parse(a, try c.encode(a, .{ .hash = receipt_hash, .from = actor, .to = registry, .nonce = "0x5", .value = "0x0", .input = input, .chainId = "0xa4b1", .blockHash = hash, .blockNumber = "0x64" }));
        const receipt = try c.parse(a, try c.encode(a, .{ .transactionHash = receipt_hash, .status = "0x1", .from = actor, .to = registry, .blockHash = hash, .blockNumber = "0x64", .logs = .{} }));
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
        var replies: std.ArrayList(mock.Reply) = .empty;
        try replies.appendSlice(a, &.{
            try reply(a, .{ .string = "0xa4b1" }),                                                                                                                                                                       try reply(a, try c.parse(a, block)),
            try reply(a, .{ .string = "0x5" }),                                                                                                                                                                          try reply(a, try c.parse(a, block)),
            try reply(a, .{ .string = "0xa4b1" }),                                                                                                                                                                       try reply(a, try c.parse(a, block)),
            .{ .body = try c.encode(a, .{ .{ .jsonrpc = "2.0", .id = 1, .result = if (repriced) c.Value.null else transaction }, .{ .jsonrpc = "2.0", .id = 2, .result = if (repriced) c.Value.null else receipt } }) },
        });
        if (repriced) {
            const full_block = try c.parse(a, try c.encode(a, .{ .number = "0x64", .timestamp = "0x64", .hash = hash, .transactions = .{transaction} }));
            try replies.appendSlice(a, &.{ try reply(a, .{ .string = "0x6" }), try reply(a, full_block), try reply(a, receipt) });
        }
        try replies.appendSlice(a, &.{ try reply(a, try c.parse(a, block)), try reply(a, try c.parse(a, block)) });
        var server = try mock.Server.init(std.testing.io, replies.items);
        defer server.deinit();
        var serving = try std.testing.io.concurrent(mock.Server.serve, .{&server});
        defer _ = serving.cancel(std.testing.io) catch {};
        const result = try runWithCast(a, dir, try server.url(a), &.{ "registry", "pause", "--account", "fixture" }, .mined);
        try success(result);
        const report = try c.parse(a, result.stdout);
        try std.testing.expectEqualStrings("confirmed", try c.string(c.field(report, "status").?));
        try std.testing.expectEqualStrings(receipt_hash, try c.string(c.field(c.field(report, "receipt").?, "transactionHash").?));
        const expected: usize = if (repriced) 2 else 1;
        try std.testing.expectEqual(expected, std.mem.count(u8, result.stderr, "Transaction:"));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, result.stderr, "Submitted:"));
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "https://arbiscan.io/tx/" ++ hash) != null);
        if (repriced) try std.testing.expect(std.mem.indexOf(u8, result.stderr, "https://arbiscan.io/tx/" ++ replacement_hash) != null);
        try serving.await(std.testing.io);
        try std.testing.expectEqual(replies.items.len, server.requests);
    }
}
