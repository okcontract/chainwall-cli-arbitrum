const std = @import("std");
const c = @import("common.zig");
const contracts = @import("contracts.zig");

pub const Cast = struct {
    a: c.A,
    io: std.Io,
    env: *const std.process.Environ.Map,
    executable: []const u8 = "cast",
    rpc: []const u8 = "",
    chain: u64 = 0,
    instance: []const u8 = "",
    account: ?[]const u8 = null,
    keystore: ?[]const u8 = null,
    password_file: ?[]const u8 = null,
    from: ?[]const u8 = null,
    unlocked: bool = false,
    checked: bool = false,
    block: ?[]const u8 = null,
    nonce: ?u64 = null,
    diagnostic: ?[]const u8 = null,
    json_arguments: bool = false,
    json_values: ?c.Value = null,
    auth: ?@import("auth_signer.zig").Options = null,
    journal: ?*@import("logs.zig").Journal = null,
    fees: @import("transaction_fees.zig").Options = .{},
    no_broadcast: bool = false,
    wait_timeout: u64 = 120,
    tx_confirmations: u64 = 1,
    access_list: ?c.Value = null,

    pub fn parseNonce(raw: ?[]const u8) !?u64 {
        const value = c.word(raw orelse return null) catch return error.InvalidNonce;
        if (value >= std.math.maxInt(u64)) return error.InvalidNonce;
        return @intCast(value);
    }

    pub fn run(s: *Cast, args: []const []const u8) ![]const u8 {
        const argv = try s.a.alloc([]const u8, args.len + 1);
        argv[0] = s.executable;
        @memcpy(argv[1..], args);
        const output = std.process.run(s.a, s.io, .{ .argv = argv, .environ_map = s.env, .expand_arg0 = .expand, .stdout_limit = .limited(32 * 1024 * 1024), .stderr_limit = .limited(1024 * 1024), .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(60) } } }) catch |err| {
            if (err == error.FileNotFound) return error.FoundryCastNotInstalled;
            return err;
        };
        if (output.term != .exited or output.term.exited != 0) {
            s.diagnostic = try s.redact(output.stderr);
            return error.CastFailed;
        }
        return c.trim(output.stdout);
    }
    fn redact(s: *Cast, text: []const u8) ![]const u8 {
        // RPC URLs can carry provider credentials. Never copy them into errors.
        var redacted = text;
        for ([_][]const u8{ s.rpc, if (s.auth) |auth| auth.bundler orelse "" else "" }) |url| {
            if (url.len == 0) continue;
            var out: std.Io.Writer.Allocating = .init(s.a);
            var parts = std.mem.splitSequence(u8, redacted, url);
            var i: usize = 0;
            while (parts.next()) |part| : (i += 1) {
                if (i > 0) try out.writer.writeAll("<rpc-url>");
                try out.writer.writeAll(part);
            }
            redacted = try out.toOwnedSlice();
        }
        return redacted;
    }
    pub fn check(s: *Cast) !void {
        if (s.checked) return;
        if (s.rpc.len == 0) return error.RpcUrlRequired;
        const chain = try c.word(try s.run(&.{ "chain-id", "--rpc-url", s.rpc }));
        if (chain != s.chain) return error.RpcChainMismatch;
        try c.address(s.instance);
        if ((try s.code(s.instance)).len <= 2) return error.InstanceHasNoCode;
        s.checked = true;
    }
    pub fn code(s: *Cast, address: []const u8) ![]const u8 {
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(s.a, &.{ "code", address, "--rpc-url", s.rpc });
        if (s.block) |block| try args.appendSlice(s.a, &.{ "--block", block });
        return s.run(args.items);
    }
    pub fn resolveAddress(s: *Cast, value: []const u8) ![]const u8 {
        // Literal validation stays with the caller: some ABI fields allow zero.
        // @labels belong to the Registry resolver, never the Foundry keystore.
        if (value.len == 0 or std.mem.startsWith(u8, value, "0x") or std.mem.startsWith(u8, value, "@")) return value;
        // Looking up an address must not inherit or replace the selected signer.
        var wallet_account: Cast = .{ .a = s.a, .io = s.io, .env = s.env, .executable = s.executable, .account = value, .password_file = s.password_file };
        return wallet_account.signerAddress();
    }
    pub fn signerAddress(s: *Cast) ![]const u8 {
        if (s.auth) |auth| {
            try @import("auth_signer.zig").validate(s.a, auth.profile, s.chain, auth.registry, false);
            return @import("auth_signer.zig").string(auth.profile, "authAccount");
        }
        if (s.unlocked) {
            if (s.account != null or s.keystore != null) return error.ConflictingSigners;
            const address = s.from orelse return error.UnlockedRequiresFrom;
            try c.address(address);
            return address;
        }
        const address = try s.wallet(&.{"address"});
        try c.address(address);
        if (s.from) |from| if (!std.ascii.eqlIgnoreCase(from, address)) return error.SignerAddressMismatch;
        return address;
    }
    pub fn signTypedData(s: *Cast, typed: c.Value) ![]const u8 {
        if (s.auth != null) return @import("auth_signer.zig").sign(s, typed);
        const signer = try s.signerAddress();
        const data = try c.encode(s.a, typed);
        const signature = if (s.unlocked)
            try c.string(try c.parse(s.a, try s.run(&.{ "rpc", "eth_signTypedData_v4", signer, data, "--rpc-url", s.rpc })))
        else
            try s.wallet(&.{ "sign", "--data", data });
        if ((try @import("abi_codec.zig").unhex(s.a, signature)).len != 65) return error.InvalidSignature;
        return signature;
    }
    fn wallet(s: *Cast, args: []const []const u8) ![]const u8 {
        if (s.account == null and s.keystore == null) return error.SignerRequired;
        if (s.account != null and s.keystore != null) return error.ConflictingSigners;
        if (s.keystore) |path| _ = try @import("json_schema.zig").read(s.a, s.io, "keystore", path);
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(s.a, &.{ s.executable, "wallet" });
        try argv.appendSlice(s.a, args);
        if (s.account) |account| try argv.appendSlice(s.a, &.{ "--account", account });
        if (s.keystore) |path| try argv.appendSlice(s.a, &.{ "--keystore", path });
        if (s.password_file) |path| try argv.appendSlice(s.a, &.{ "--password-file", path });
        var env = try s.env.clone(s.a);
        defer env.deinit();
        for ([_][]const u8{ "ETH_PRIVATE_KEY", "ETH_KEYSTORE", "ETH_KEYSTORE_ACCOUNT", "ETH_FROM", "ETH_MNEMONIC", "TEMPO_ACCESS_KEY", "TEMPO_ROOT_ACCOUNT" }) |key| _ = env.orderedRemove(key);
        var child = try std.process.spawn(s.io, .{ .argv = argv.items, .environ_map = &env, .expand_arg0 = .expand, .stdin = .inherit, .stderr = .inherit, .stdout = .pipe });
        defer child.kill(s.io);
        var buffer: [4096]u8 = undefined;
        var reader = child.stdout.?.readerStreaming(s.io, &buffer);
        const output = try reader.interface.allocRemaining(s.a, .limited(1024 * 1024));
        const term = try child.wait(s.io);
        if (term != .exited or term.exited != 0) return error.WalletFailed;
        return c.trim(output);
    }
    pub fn calldata(s: *Cast, method: contracts.Method, args: []const []const u8) ![]const u8 {
        if (args.len != c.field(method.abi, "inputs").?.array.items.len) return error.WrongArgumentCount;
        if (s.json_values) |values| return @import("abi_codec.zig").calldata(s.a, method.abi, values);
        const sig = try contracts.encodingSignature(s.a, method.abi, false, s.json_arguments);
        const data = try s.run(try std.mem.concat(s.a, []const u8, &.{ &.{ "calldata", sig }, args }));
        if (!s.json_arguments) return data;
        if (data.len < 10) return error.InvalidCalldata;
        return s.a.print("0x{x:0>8}{s}", .{ @as(u32, @intCast(@import("miniscript").bytecode.hash(method.signature) >> 224)), data[10..] });
    }
    pub fn call(s: *Cast, method: contracts.Method, args: []const []const u8) !c.Value {
        try s.check();
        const sig = try contracts.signature(s.a, method.abi, true);
        const data = try s.calldata(method, args);
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(s.a, &.{ "call", s.instance, "--data", data, "--rpc-url", s.rpc });
        if (if (s.auth != null) try s.signerAddress() else s.from) |from| try argv.appendSlice(s.a, &.{ "--from", from });
        if (s.block) |block| try argv.appendSlice(s.a, &.{ "--block", block });
        if (s.nonce) |nonce| try argv.appendSlice(s.a, &.{ "--nonce", try s.a.print("{d}", .{nonce}) });
        const response = try s.run(argv.items);
        if (c.field(method.abi, "outputs").?.array.items.len == 0) return .{ .array = std.json.Array.init(s.a) };
        return c.parse(s.a, try s.run(&.{ "decode-abi", sig, response, "--json" }));
    }
    pub fn send(s: *Cast, data: []const u8, value: ?[]const u8) !c.Value {
        if (s.no_broadcast) return error.PreviewCannotBroadcast;
        if (s.nonce == std.math.maxInt(u64)) return error.InvalidNonce;
        try s.check();
        if (s.auth != null) return @import("auth_signer.zig").send(s, data, value);
        return s.submit(data, value, false);
    }
    pub fn create(s: *Cast, data: []const u8, value: ?[]const u8) !c.Value {
        if (s.no_broadcast) return error.PreviewCannotBroadcast;
        if (s.block != null) return error.TransactionRequiresLatestBlock;
        if (s.auth != null) return error.DeploymentRequiresFoundrySigner;
        if (s.rpc.len == 0) return error.RpcUrlRequired;
        if (try c.word(try s.run(&.{ "chain-id", "--rpc-url", s.rpc })) != s.chain) return error.RpcChainMismatch;
        return s.submit(data, value, true);
    }
    /// Save receipt evidence before checking success or writing terminal output.
    /// Read-only receipt recovery has no active journal and must not create one.
    pub fn recordReceipt(s: *Cast, receipt: c.Value) !void {
        if (s.journal) |journal| if (journal.path != null) try journal.record(.{ .chainId = s.chain, .receipt = receipt });
    }
    pub fn showTransaction(s: *Cast, hash: []const u8) !void {
        const url = try @import("explorer.zig").transactionUrl(s.a, s.chain, hash) orelse return;
        // Keep stdout usable with --json; links are presentation, not log data.
        try std.Io.File.stderr().writeStreamingAll(s.io, try s.a.print("Transaction: {s}\n", .{url}));
    }
    fn submit(s: *Cast, data: []const u8, value: ?[]const u8, creating: bool) !c.Value {
        if (s.nonce == std.math.maxInt(u64)) return error.InvalidNonce;
        if (s.account == null and s.keystore == null and !s.unlocked) return error.SignerRequired;
        if (s.unlocked and s.from == null) return error.UnlockedRequiresFrom;
        if ((s.unlocked and (s.account != null or s.keystore != null)) or (s.account != null and s.keystore != null)) return error.ConflictingSigners;
        if (s.keystore) |path| _ = try @import("json_schema.zig").read(s.a, s.io, "keystore", path);
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(s.a, &.{ s.executable, "send" });
        if (!creating) try argv.appendSlice(s.a, &.{ s.instance, "--data", data });
        try argv.appendSlice(s.a, &.{ "--rpc-url", s.rpc, "--chain", try s.a.print("{d}", .{s.chain}), "--json", "--async" });
        if (s.account) |account| try argv.appendSlice(s.a, &.{ "--account", account });
        if (s.keystore) |path| try argv.appendSlice(s.a, &.{ "--keystore", path });
        if (s.password_file) |path| try argv.appendSlice(s.a, &.{ "--password-file", path });
        if (s.from) |from| try argv.appendSlice(s.a, &.{ "--from", from });
        if (s.unlocked) try argv.append(s.a, "--unlocked");
        if (value) |amount| try argv.appendSlice(s.a, &.{ "--value", amount });
        if (s.nonce) |nonce| try argv.appendSlice(s.a, &.{ "--nonce", try s.a.print("{d}", .{nonce}) });
        // --create is a cast subcommand: send options must precede it.
        try s.fees.append(s.a, &argv);
        if (s.access_list) |list| try argv.appendSlice(s.a, &.{ "--access-list", try c.encode(s.a, list) });
        if (creating) try argv.appendSlice(s.a, &.{ "--create", data });
        // A Foundry environment default must not override the signer selected
        // in this profile. Password environment support remains with Foundry.
        var signing_env = try s.env.clone(s.a);
        defer signing_env.deinit();
        for ([_][]const u8{ "ETH_PRIVATE_KEY", "ETH_KEYSTORE", "ETH_KEYSTORE_ACCOUNT", "ETH_FROM", "ETH_MNEMONIC", "TEMPO_ACCESS_KEY", "TEMPO_ROOT_ACCOUNT" }) |key| _ = signing_env.orderedRemove(key);
        const calldata_bytes = try @import("abi_codec.zig").unhex(s.a, data);
        var intent = try c.parse(s.a, try c.encode(s.a, .{ .chainId = s.chain, .to = if (creating) null else s.instance, .dataHash = try c.hex(s.a, @import("miniscript").bytecode.hash(calldata_bytes)), .dataBytes = calldata_bytes.len, .value = value orelse "0", .from = s.from, .nonce = s.nonce }));
        try s.fees.overlay(s.a, &intent);
        if (s.access_list) |list| try intent.object.put(s.a, "accessList", list);
        var submission = try c.parse(s.a, try c.encode(s.a, .{ .state = "broadcast-attempt", .transaction = intent }));
        const submission_index = if (s.journal) |journal| try journal.prepareSubmission(submission) else @as(?usize, null);
        // Foundry owns password prompts and key material. Inherit stdin/stderr
        // instead of capturing or retrieving a private key in this process.
        var child = try std.process.spawn(s.io, .{ .argv = argv.items, .environ_map = &signing_env, .expand_arg0 = .expand, .stdin = .inherit, .stderr = .inherit, .stdout = .pipe });
        defer child.kill(s.io);
        var buffer: [4096]u8 = undefined;
        var reader = child.stdout.?.readerStreaming(s.io, &buffer);
        const output = try reader.interface.allocRemaining(s.a, .limited(32 * 1024 * 1024));
        const term = try child.wait(s.io);
        const failed = term != .exited or term.exited != 0;
        const trimmed = c.trim(output);
        const parsed: c.Value = if (trimmed.len == 66 and std.mem.startsWith(u8, trimmed, "0x")) .{ .string = trimmed } else c.parse(s.a, output) catch |err| {
            if (failed) return error.TransactionFailed;
            return err;
        };
        const receipt = if (parsed == .string) blk: {
            const watch = @import("transaction_watch.zig");
            const tx_hash = try watch.hash(s.a, parsed.string);
            try submission.object.put(s.a, "state", .{ .string = "submitted" });
            try submission.object.put(s.a, "hash", .{ .string = tx_hash });
            if (s.journal) |journal| try journal.updateSubmission(submission_index.?, submission);
            // Persist the recovery handle before making another RPC request.
            try watch.submitted(s, tx_hash, intent);
            try s.showTransaction(tx_hash);
            try std.Io.File.stderr().writeStreamingAll(s.io, try s.a.print("Submitted: {s}\n", .{tx_hash}));
            s.diagnostic = try s.a.print("Recover with chainwall transactions wait {s} --chain {d}.\n", .{ tx_hash, s.chain });
            if (failed) return error.TransactionSubmissionUncertain;
            const db: ?@import("store.zig").Store = if (s.journal) |journal| try @import("store.zig").Store.open(s.a, s.io, journal.dir) else null;
            defer if (db) |store| store.close();
            const report = try watch.wait(s, db, tx_hash, s.wait_timeout, s.tx_confirmations, 64, 2);
            try submission.object.put(s.a, "observation", try watch.redact(s.a, report));
            if (s.journal) |journal| try journal.updateSubmission(submission_index.?, submission);
            break :blk try watch.verifiedReceipt(report);
        } else parsed;
        // A failed cast process can still return a mined transaction receipt.
        try submission.object.put(s.a, "state", .{ .string = "receipt-returned" });
        try submission.object.put(s.a, "receipt", receipt);
        if (s.journal) |journal| try journal.updateSubmission(submission_index.?, submission);
        try s.recordReceipt(receipt);
        if (c.field(receipt, "transactionHash")) |hash| try s.showTransaction(c.string(hash) catch "");
        if (failed) return error.TransactionFailed;
        const status = c.field(receipt, "status") orelse return error.InvalidTransactionReceipt;
        if (try c.number(s.a, status) != 1) return error.TransactionReverted;
        s.diagnostic = null;
        // Multi-stage commands reuse this signer and advance only after receipt
        // confirmation. Calls and offline previews never consume a nonce.
        if (s.nonce) |nonce| s.nonce = nonce + 1;
        return receipt;
    }
};
