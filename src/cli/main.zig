const std = @import("std");
const ms = @import("miniscript");
const c = @import("common.zig");
const config = @import("config.zig");
const contracts = @import("contracts.zig");
const Cast = @import("cast.zig").Cast;
const Args = @import("args.zig").Args;
const programs = @import("programs.zig");
const receipts = @import("receipts.zig");
const storage = @import("store.zig");
const rpc = @import("rpc.zig");
const sync = @import("sync.zig");
const vault = @import("vault.zig");
const operations = @import("operations.zig");
const abi = @import("abi_codec.zig");
const deploy = @import("deploy.zig");
const factories = @import("factories.zig");
const configuration = @import("configuration.zig");
const display = @import("display.zig");
const logs = @import("logs.zig");
const labels = @import("labels.zig");
const completions = @import("completions.zig");
const completion_session = @import("completion_session.zig");
const json_schema = @import("json_schema.zig");
const json_inputs = @import("json_inputs.zig");

const help = @import("help.zig");

fn requirePaymasterAccountMode(paymaster: ?[]const u8, via: ?[]const u8) !void {
    if (paymaster != null and via != null and !c.eq(u8, via.?, "account")) {
        return error.PaymasterRequiresAccountMode;
    }
}

const App = struct {
    a: c.A,
    io: std.Io,
    env: *const std.process.Environ.Map,
    args: Args,
    dir: []const u8,
    profile_name: []const u8,
    profile: config.Profile,
    cat: contracts.Catalog,
    cast: Cast,
    json: bool,
    color: display.Color = .auto,
    dry: bool,
    estimate: bool = false,
    chain: []const u8,
    reference_entries: ?[]labels.Entry = null,
    auth_browser: @import("browser_approval.zig").Options = .{},
    bundler_url: ?[]const u8 = null,
    paymaster: ?[]const u8 = null,

    fn selection(app: *App) completion_session.Selection {
        return .{ .dir = app.dir, .profile = app.profile_name, .chain = app.cast.chain, .registry = app.cast.instance };
    }
    fn references(app: *App) ![]labels.Entry {
        if (app.reference_entries == null) app.reference_entries = completion_session.entries(app.a, app.io, app.selection()) catch return error.UnknownLabelUnlockOrSync;
        return app.reference_entries.?;
    }
    fn reference(app: *App, kind: ?[]const u8, value: []const u8, address: bool) ![]const u8 {
        if (!std.mem.startsWith(u8, value, "@")) return if (address) app.cast.resolveAddress(value) else value;
        return labels.resolve(try app.references(), kind, value, address);
    }
    fn searchCommand(app: *App, p: []const []const u8) !void {
        if (p.len > 2) return error.WrongArgumentCount;
        const password_file = app.args.get("passphrase-file");
        const private = app.args.flag("private") or password_file != null;
        const kind = app.args.get("kind");
        const out = app.args.get("out");
        const offset = try rpc.integer(app.a, .{ .string = app.args.get("start") orelse "0" });
        const count = try rpc.integer(app.a, .{ .string = app.args.get("count") orelse "50" });
        try app.args.finish();
        const db = try storage.Store.openReadOnly(app.a, app.io, app.dir);
        defer db.close();
        try db.db.transaction();
        defer db.db.rollback();
        var v: ?vault.Vault = if (private) try app.unlockVault(db, password_file, false) else null;
        defer if (v) |*value| value.deinit();
        var keys: @import("label_keys.zig").Keyring = if (v) |value| try @import("label_keys.zig").load(app.a, value, app.profile, try app.kvChain()) else .{};
        defer keys.deinit();
        const entries = try labels.loadKeys(app.a, db, app.cast.chain, app.cast.instance, keys.keys());
        const report = try @import("search.zig").run(app.a, db, app.profile, app.cast.chain, app.cast.instance, entries, app.cast.from, if (app.cast.auth) |auth| try c.string(c.field(auth.profile, "authAccount").?) else null, if (p.len == 2) p[1] else "", kind, offset, count);
        if (out) |path| try c.write(app.io, path, try c.encode(app.a, report), false);
        return app.output(report);
    }
    fn completionCommand(app: *App, p: []const []const u8) !void {
        if (p.len != 2) return error.UnknownCommand;
        if (c.eq(u8, p[1], "fish") or c.eq(u8, p[1], "zsh")) {
            try app.args.finish();
            return c.print(app.io, "{s}", .{if (c.eq(u8, p[1], "fish")) completions.fish else completions.zsh});
        }
        if (c.eq(u8, p[1], "status") or c.eq(u8, p[1], "lock")) {
            try app.args.finish();
            const response = completion_session.request(app.a, app.io, app.selection(), p[1]) catch |err| {
                if (err == error.FileNotFound) return app.output(.{ .status = "locked" });
                return err;
            };
            if (c.eq(u8, p[1], "lock")) return app.output(.{ .status = "locked" });
            return app.printJson(response);
        }
        if (!c.eq(u8, p[1], "unlock") and !c.eq(u8, p[1], "watch")) return error.UnknownCommand;
        const ttl = try std.fmt.parseInt(u64, app.args.get("ttl") orelse "900", 10);
        const refresh = try std.fmt.parseInt(u64, app.args.get("refresh") orelse "30", 10);
        const password_file = app.args.get("passphrase-file");
        try app.args.finish();
        if (ttl == 0 or ttl > 86400 or refresh > 86400) return error.InvalidCompletionDuration;
        try c.address(app.cast.instance);
        if (completion_session.request(app.a, app.io, app.selection(), "status")) |_| return error.CompletionSessionAlreadyRunning else |_| {}
        var keyring: @import("label_keys.zig").Keyring = .{};
        defer keyring.deinit();
        if (c.eq(u8, p[1], "unlock")) {
            const db = try storage.Store.openReadOnly(app.a, app.io, app.dir);
            defer db.close();
            var v = try app.unlockVault(db, password_file, false);
            defer v.deinit();
            keyring = try @import("label_keys.zig").load(app.a, v, app.profile, try app.kvChain());
        }
        _ = try std.Io.Dir.cwd().createDirPathStatus(app.io, app.dir, .fromMode(0o700));
        const argv = try app.sessionArgs("__completion-session");
        const args = try std.mem.concat(app.a, []const u8, &.{ argv, &.{ "--ttl", try app.a.print("{d}", .{ttl}), "--refresh", try app.a.print("{d}", .{refresh}) } });
        try completion_session.launch(app.a, app.io, args, keyring.keys());
        try app.output(.{ .status = if (keyring.len > 0) "unlocked" else "watching", .expiresIn = ttl, .refreshSeconds = refresh });
    }
    fn sessionArgs(app: *App, command: []const u8) ![]const []const u8 {
        // Resolve relative config paths before the helper outlives this shell.
        const dir = try std.Io.Dir.cwd().realPathFileAlloc(app.io, app.dir, app.a);
        return app.a.dupe([]const u8, &.{ try std.process.executablePathAlloc(app.io, app.a), command, "--config-dir", dir, "--profile", app.profile_name, "--chain", try app.a.print("{d}", .{app.cast.chain}), "--instance", app.cast.instance, "--rpc-url", app.cast.rpc, "--json" });
    }

    fn labelText(app: *App, value: []const u8, scope: []const u8, entity: ?[]const u8, encode: bool, password_file: ?[]const u8) ![]const u8 {
        try labels.validateContext(app.cast.instance, scope, entity);
        if (!encode) if (try labels.decode(app.a, value, null, app.cast.chain, app.cast.instance, scope, entity)) |plain| return plain;
        const db = try storage.Store.openReadOnly(app.a, app.io, app.dir);
        defer db.close();
        var v = try app.unlockVault(db, password_file, false);
        defer v.deinit();
        var keyring = try @import("label_keys.zig").load(app.a, v, app.profile, try app.kvChain());
        defer keyring.deinit();
        if (encode) return labels.encode(app.a, value, keyring.values[0], app.cast.chain, app.cast.instance, scope, entity);
        return (try labels.decodeKeys(app.a, value, keyring.keys(), app.cast.chain, app.cast.instance, scope, entity)) orelse error.UnreadableLabel;
    }

    fn labelsCommand(app: *App, p: []const []const u8) !void {
        if (p.len < 2) return error.CommandRequired;
        const password_file = app.args.get("passphrase-file");
        if (c.eq(u8, p[1], "encode") or c.eq(u8, p[1], "decode")) {
            if (p.len != 3) return error.WrongArgumentCount;
            const scope = app.args.get("scope") orelse return error.LabelScopeRequired;
            const entity = if (app.args.get("entity")) |raw| try app.reference(null, raw, true) else null;
            try app.args.finish();
            const value = try app.labelText(p[2], scope, entity, c.eq(u8, p[1], "encode"), password_file);
            defer if (c.eq(u8, p[1], "decode")) std.crypto.secureZero(u8, @constCast(value));
            if (app.json) return app.output(.{ .value = value, .scope = scope, .entity = entity, .chainId = app.cast.chain, .registry = app.cast.instance });
            return c.print(app.io, "{s}\n", .{value});
        }
        if (!@import("schema.zig").contains("set get clear", p[1])) return error.UnknownCommand;
        const writing = c.eq(u8, p[1], "set");
        if (p.len != (if (writing) @as(usize, 5) else 4)) return error.WrongArgumentCount;
        const plain = if (writing) app.args.flag("plain") else false;
        const raw = if (c.eq(u8, p[1], "get")) app.args.flag("raw") else false;
        try app.args.finish();
        const namespace = if (c.eq(u8, p[2], "safe")) "account" else p[2];
        if (!@import("schema.zig").contains("user account contract", namespace)) return error.InvalidLabelKind;
        const is_contract = c.eq(u8, namespace, "contract");
        const collection = if (is_contract) "contracts" else if (c.eq(u8, p[2], "safe")) "safes" else if (c.eq(u8, namespace, "user")) "users" else "accounts";
        const id = try std.ascii.allocLowerString(app.a, try app.reference(collection, p[3], !is_contract));
        if (is_contract) {
            if (id.len != 66 or !std.mem.startsWith(u8, id, "0x")) return error.InvalidId;
            _ = try c.id(app.a, id);
        } else try c.address(id);
        const scope = try app.a.print("{s}-label", .{namespace});
        const entity: ?[]const u8 = if (is_contract) null else id;
        const client: @import("contract_client.zig").Client = .{ .cast = &app.cast, .cat = app.cat, .group = "metadata" };
        const args = [_]c.Value{ .{ .string = namespace }, .{ .string = id }, .{ .string = "label" } };
        if (c.eq(u8, p[1], "clear")) return app.output(try client.transaction("deleteMeta", &args, null, app.dry));
        if (writing) {
            try labels.validateText(p[4]);
            const value = if (plain) try abi.hex(app.a, try abi.encode(app.a, try c.parse(app.a, "[{\"type\":\"string\"}]"), try abi.array(app.a, &.{.{ .string = p[4] }}))) else try app.labelText(p[4], scope, entity, true, password_file);
            return app.output(try client.transaction("setMeta", &(args ++ [_]c.Value{.{ .string = value }}), null, app.dry));
        }
        const value = try c.string(try client.first("getMeta", &args));
        const label = if (raw or c.eq(u8, value, "0x")) null else try app.labelText(value, scope, entity, false, password_file);
        defer if (label) |text| std.crypto.secureZero(u8, @constCast(text));
        return app.output(.{ .kind = namespace, .id = id, .value = value, .label = if (label) |text| c.Value{ .string = text } else c.Value.null });
    }

    fn output(app: *App, value: anytype) !void {
        var prepared = try c.parse(app.a, try c.encode(app.a, value));
        if (app.dry and app.cast.fees.supplied()) {
            if (@import("transaction_fees.zig").request(prepared)) |raw| {
                var tx = raw;
                try app.cast.fees.overlay(app.a, &tx);
                if (c.field(prepared, "transaction") != null) try prepared.object.put(app.a, "transaction", tx) else prepared = tx;
            } else |_| {}
        }
        const encoded = if (app.estimate) try c.encode(app.a, .{ .prepared = prepared, .estimate = try @import("transaction_fees.zig").estimate(&app.cast, prepared) }) else try c.encode(app.a, prepared);
        if (app.cast.journal) |journal| if (journal.path != null) {
            journal.result = try c.parse(app.a, encoded);
            try journal.flush();
            if (!app.json) return;
        };
        try app.printJson(encoded);
    }
    fn printJson(app: *App, encoded: []const u8) !void {
        try display.printJson(app.io, encoded, try app.colorEnabled());
    }
    fn logsCommand(app: *App, p: []const []const u8) !void {
        try app.args.finish();
        if (p.len == 1 or (p.len == 2 and c.eq(u8, p[1], "list"))) {
            const entries = try logs.list(app.a, app.io, app.dir);
            if (app.json) return app.output(entries);
            if (entries.len == 0) return c.print(app.io, "No transaction logs.\n", .{});
            for (entries) |entry| try c.print(app.io, "{s}\n", .{entry.path});
            return;
        }
        if ((p.len == 2 or p.len == 3) and c.eq(u8, p[1], "show")) {
            return app.output(try logs.read(app.a, app.io, app.dir, if (p.len == 3) p[2] else "latest"));
        }
        return error.UnknownCommand;
    }
    fn save(app: *App) !void {
        try config.save(app.profile, app.a, app.io, app.dir, app.profile_name, true);
    }
    fn deployCommand(app: *App) !void {
        if (app.args.positional.len != 1) return error.UnexpectedArgument;
        const out = app.args.get("out");
        const opts = try deploy.Options.parse(app.a, &app.args, app.profile.get("factory") orelse try factories.address(app.a, .okFactory, app.cast.chain));
        try app.args.finish();
        const deployment = try deploy.run(&app.cast, opts, app.dry, app.json);
        if (out) |path| try c.write(app.io, path, try c.encode(app.a, deployment), true);
        const instance = c.field(deployment, "instance") orelse .null;
        if (instance != .null) {
            const registry = try c.string(c.field(deployment, "registry").?);
            const interact = try c.string(c.field(instance, "interact").?);
            // Retain the complete topology for app-format configuration export.
            const db = try storage.Store.open(app.a, app.io, app.dir);
            defer db.close();
            try db.put(try storage.scopeKey(app.a, app.cast.chain, registry), "deployment", "instance", instance);
            try app.profile.set(app.a, "factory", opts.factory);
            try app.profile.set(app.a, "chain", app.chain);
            try app.profile.set(app.a, "instance", registry);
            try app.profile.set(app.a, "interact", interact);
            try app.profile.set(app.a, "rpc_url", app.cast.rpc);
            try app.profile.setForChain(app.a, "instances.", app.cast.chain, registry);
            try app.profile.setForChain(app.a, "interacts.", app.cast.chain, interact);
            try app.profile.setForChain(app.a, "rpc.", app.cast.chain, app.cast.rpc);
            if (app.cast.account) |account| {
                try app.profile.set(app.a, "account", account);
                _ = app.profile.values.orderedRemove("keystore");
            }
            if (app.cast.keystore) |path| {
                try app.profile.set(app.a, "keystore", path);
                _ = app.profile.values.orderedRemove("account");
            }
            if (app.cast.password_file) |path| try app.profile.set(app.a, "password_file", path);
            try app.save();
        }
        try app.output(deployment);
    }
    fn query(app: *App, name: []const u8, values: []const []const u8) !c.Value {
        return app.cast.call(try app.cat.find("registry", name), values);
    }
    fn loginCommand(app: *App, p: []const []const u8) !void {
        if (p.len != 2) return error.InstanceAddressRequired;
        try app.args.finish();
        app.cast.instance = p[1];
        app.cast.checked = false;
        var component = try c.number(app.a, (try app.query("chainwallComponentId", &.{})).array.items[0]);
        var interact: ?[]const u8 = null;
        if (component == ms.bytecode.hash("Chainwall.SafeFactory")) {
            // Match the app: a tenant instance is its SafeFactory, which points
            // to Interact, which in turn owns the Registry connection.
            const auxiliary = try contracts.Catalog.loadAuxiliary(app.a);
            interact = try c.string((try app.cast.call(try auxiliary.find("safe-factory", "INTERACT_CONTRACT"), &.{})).array.items[0]);
            app.cast.instance = interact.?;
            app.cast.checked = false;
            if (try c.number(app.a, (try app.query("chainwallComponentId", &.{})).array.items[0]) != ms.bytecode.hash("Chainwall.Interact")) return error.NotAChainwallInteract;
            app.cast.instance = try c.string((try app.cast.call(try auxiliary.find("interact", "registry"), &.{})).array.items[0]);
            app.cast.checked = false;
            component = try c.number(app.a, (try app.query("chainwallComponentId", &.{})).array.items[0]);
        } else if (component != ms.bytecode.hash("Chainwall.Registry")) return error.NotAChainwallRegistryOrInstance;
        if (component != ms.bytecode.hash("Chainwall.Registry")) return error.NotAChainwallRegistry;

        const registry = app.cast.instance;
        const same_chain = app.cast.chain == try config.chainId(app.profile.get("chain") orelse "ethereum");
        const previous = app.profile.forChain("instances.", app.cast.chain) orelse if (same_chain) app.profile.get("instance") orelse "" else "";
        // Retain a known Interact only when reconnecting to the same Registry.
        // Switching Registries must not carry another tenant's execution target.
        if (interact == null and std.ascii.eqlIgnoreCase(previous, registry)) interact = app.profile.forChain("interacts.", app.cast.chain) orelse if (same_chain) app.profile.get("interact") else null;
        if (interact) |target| try app.profile.set(app.a, "interact", target) else _ = app.profile.values.orderedRemove("interact");
        try app.profile.setForChain(app.a, "interacts.", app.cast.chain, interact);
        try app.profile.set(app.a, "instance", registry);
        try app.profile.set(app.a, "chain", app.chain);
        try app.profile.set(app.a, "rpc_url", app.cast.rpc);
        // Imported profiles can have per-chain entries that shadow scalars.
        try app.profile.setForChain(app.a, "instances.", app.cast.chain, registry);
        try app.profile.setForChain(app.a, "rpc.", app.cast.chain, app.cast.rpc);
        if (app.cast.account) |account| {
            try app.profile.set(app.a, "account", account);
            _ = app.profile.values.orderedRemove("keystore");
        }
        if (app.cast.keystore) |path| {
            try app.profile.set(app.a, "keystore", path);
            _ = app.profile.values.orderedRemove("account");
        }
        if (app.cast.password_file) |path| try app.profile.set(app.a, "password_file", path);
        try app.save();
        return app.output(.{ .profile = app.profile_name, .instance = registry, .inputAddress = p[1], .interact = interact, .chainId = app.cast.chain, .account = app.cast.account });
    }
    fn syncCommand(app: *App) !void {
        const full = app.args.flag("full");
        const only = app.args.get("only");
        const from = try rpc.integer(app.a, .{ .string = app.args.get("from-block") orelse "0" });
        const lookback = try rpc.integer(app.a, .{ .string = app.args.get("lookback") orelse "128" });
        const confirmations = try rpc.integer(app.a, .{ .string = app.args.get("confirmations") orelse "0" });
        const passphrase_file = app.args.get("passphrase-file");
        const explorer = programs.explorer(app.a, app.io, app.env, app.profile, app.dir, app.cast.chain, &app.args);
        try app.args.finish();
        if (app.dry) return error.SyncDoesNotSendTransactions;
        if (only) |names| {
            var parts = std.mem.splitScalar(u8, names, ',');
            while (parts.next()) |name| {
                var known = c.eq(u8, name, "timelocks") or c.eq(u8, name, "operations") or c.eq(u8, name, "labels");
                for (sync.datasets) |dataset| if (c.eq(u8, name, dataset.name)) {
                    known = true;
                };
                if (!known) return error.UnknownSyncDataset;
            }
        }
        var client = try rpc.Rpc.init(app.a, app.io, app.cast.rpc, app.cast.chain, app.cast.instance);
        defer client.deinit();
        const block = if (app.cast.block) |raw| if (std.fmt.parseInt(u64, raw, 10)) |n| try rpc.quantity(app.a, n) else |_| raw else null;
        try client.pin(block, confirmations);
        const component = (try client.call(try app.cat.find("registry", "chainwallComponentId"), &.{})).array.items[0];
        if (try c.number(app.a, component) != ms.bytecode.hash("Chainwall.Registry")) return error.NotAChainwallRegistry;
        const db = try storage.Store.open(app.a, app.io, app.dir);
        defer db.close();
        const with_operations = selected(only, "operations") and (only != null or app.profile.get("kv_address") != null);
        var unlocked: ?vault.Vault = if (with_operations) try app.unlockVault(db, passphrase_file, false) else null;
        defer if (unlocked) |*v| v.deinit();
        try db.begin();
        errdefer db.db.rollback();
        const scope = try storage.scopeKey(app.a, app.cast.chain, app.cast.instance);
        var engine: sync.Engine = .{ .a = app.a, .db = db, .rpc = &client, .cat = app.cat, .scope = scope, .full = full, .from_block = from, .lookback = lookback, .explorer = explorer };
        var completed: std.ArrayList([]const u8) = .empty;
        for (sync.datasets) |dataset| {
            if (!selected(only, dataset.name)) continue;
            try app.syncProgress(dataset.name);
            engine.registry(dataset) catch |err| return app.syncFailure(dataset.name, err);
            try completed.append(app.a, dataset.name);
        }
        if (selected(only, "labels")) {
            try app.syncProgress("labels");
            engine.labels() catch |err| return app.syncFailure("labels", err);
            try completed.append(app.a, "labels");
        }
        if (selected(only, "timelocks")) {
            try app.syncProgress("timelocks");
            engine.timelocks() catch |err| return app.syncFailure("timelocks", err);
            try completed.append(app.a, "timelocks");
        }
        if (unlocked) |v| {
            try app.syncProgress("operations");
            app.syncOperations(db, v, &client, engine, confirmations) catch |err| return app.syncFailure("operations", err);
            try completed.append(app.a, "operations");
        }
        if (!try client.canonical(client.block)) return error.ChainReorganizedRetrySync;
        try db.db.commit();
        try app.output(.{ .chainId = app.cast.chain, .instance = app.cast.instance, .block = client.block, .datasets = completed.items, .rpcRequests = client.requests });
    }
    fn syncProgress(app: *App, dataset: []const u8) !void {
        if (!app.json) try std.Io.File.stderr().writeStreamingAll(app.io, try app.a.print("Syncing {s}...\n", .{dataset}));
    }
    fn syncFailure(app: *App, dataset: []const u8, err: anyerror) anyerror {
        app.cast.diagnostic = app.a.print("Sync failed for {s}; the previous snapshot is unchanged.\n", .{dataset}) catch null;
        return err;
    }
    fn unlockVault(app: *App, db: storage.Store, path: ?[]const u8, create: bool) !vault.Vault {
        const password = try vault.readPassword(app.a, app.io, path, create and (try db.secret("master.v1")) == null);
        defer std.crypto.secureZero(u8, password);
        if (create) try db.begin();
        errdefer if (create) db.db.rollback();
        var value = try vault.Vault.unlock(app.a, app.io, db, password, create);
        errdefer value.deinit();
        if (create) try db.db.commit();
        return value;
    }
    fn kvChain(app: *App) !u64 {
        return if (app.profile.get("kv_chain")) |chain| try config.chainId(chain) else app.cast.chain;
    }
    fn kvRpc(app: *App) ![]const u8 {
        const chain = try app.kvChain();
        const url = app.profile.get("kv_rpc_url") orelse app.profile.forChain("rpc.", chain) orelse if (chain == app.cast.chain) app.cast.rpc else return error.KvRpcUrlRequired;
        try @import("rpc_pool.zig").validateSelection(app.a, app.io, app.dir, app.profile_name, chain, url);
        return url;
    }
    fn syncOperations(app: *App, db: storage.Store, v: vault.Vault, registry_client: *rpc.Rpc, base: sync.Engine, confirmations: u64) !void {
        const address = app.profile.get("kv_address") orelse return error.KvAddressRequired;
        const chain = try app.kvChain();
        var remote = try rpc.Rpc.init(app.a, app.io, try app.kvRpc(), chain, address);
        defer remote.deinit();
        // Same-chain Registry and KV reads share one block, including --block.
        try remote.pin(if (chain == registry_client.chain) try rpc.quantity(app.a, registry_client.block.number) else null, if (chain == registry_client.chain) 0 else confirmations);
        const scope = try storage.scopeKey(app.a, chain, address);
        const auxiliary = try contracts.Catalog.loadAuxiliary(app.a);
        var engine = base;
        engine.scope = scope;
        engine.rpc = &remote;
        engine.cat = auxiliary;
        engine.explorer.chain = chain;
        try operations.synchronize(&engine, v);
        const secrets = try operations.history(app.a, v, scope);
        defer for (secrets) |*secret| secret.deinit();
        const listing = try @import("operation_share.zig").merge(app.a, try operations.list(app.a, try db.entries(scope, "kv"), secrets, app.cast.chain, null), v, app.cast.chain, app.cast.instance, null);
        const interact = app.profile.forChain("interacts.", app.cast.chain) orelse app.profile.get("interact");
        const statuses = if (interact) |target| try operations.statuses(app.a, registry_client, auxiliary, target, app.cast.instance, listing) else c.Value{ .object = .empty };
        const key = try app.statusKey(scope);
        const bytes = try c.encode(app.a, .{ .block = registry_client.block, .interact = interact, .values = statuses });
        defer std.crypto.secureZero(u8, @constCast(bytes));
        try v.put(key, bytes);
        if (!try remote.canonical(remote.block)) return error.ChainReorganizedRetrySync;
    }
    fn statusKey(app: *App, scope: []const u8) ![]const u8 {
        return @import("operation_status.zig").key(app.a, scope, app.cast.chain, app.cast.instance);
    }
    fn operationsList(app: *App) !void {
        const view_name = app.args.get("view") orelse "operational";
        if (!@import("schema.zig").contains("operational audit", view_name)) return error.InvalidOperationView;
        const audit = c.eq(u8, view_name, "audit");
        const passphrase_file = app.args.get("passphrase-file");
        const local_only = app.args.flag("local") or app.profile.get("kv_address") == null;
        const all_chains = app.args.flag("all-chains");
        _ = app.args.flag("offline");
        const safe = app.args.get("safe");
        if (safe) |address| try c.address(address);
        const filter = app.args.get("status");
        if (filter) |status| if (!selected("active,expired,closed,mismatch,unknown", status)) return error.InvalidOperationStatus;
        const start_at = try rpc.integer(app.a, .{ .string = app.args.get("start") orelse "0" });
        const count = try rpc.integer(app.a, .{ .string = app.args.get("count") orelse "50" });
        if (count > 1000) return error.PageTooLarge;
        try app.args.finish();
        if (local_only) {
            if (all_chains) return error.LocalOperationChainRequired;
            const db = try storage.Store.open(app.a, app.io, app.dir);
            defer db.close();
            var v = try app.unlockVault(db, passphrase_file, false);
            defer v.deinit();
            const listing = try @import("operation_share.zig").merge(app.a, .{ .entries = &.{}, .unreadable = 0, .invalid = 0 }, v, app.cast.chain, app.cast.instance, safe);
            var rows: std.ArrayList(c.Value) = .empty;
            for (listing.entries) |record| {
                if (filter) |wanted| if (!c.eq(u8, wanted, "unknown")) continue;
                var item = record;
                try item.object.put(app.a, "status", .{ .string = "unknown" });
                try rows.append(app.a, item);
            }
            const start_index = @min(start_at, rows.items.len);
            return app.output(.{ .total = rows.items.len, .entries = rows.items[start_index..@min(start_index + count, rows.items.len)], .source = "local-imports", .statusBlock = @as(?u64, null) });
        }
        const address = app.profile.get("kv_address") orelse return error.KvAddressRequired;
        const scope = try storage.scopeKey(app.a, try app.kvChain(), address);
        const db = try storage.Store.open(app.a, app.io, app.dir);
        defer db.close();
        try db.db.transaction();
        defer db.db.rollback();
        const checkpoint = (try db.checkpoint(scope, "kv")) orelse return error.RunSyncFirst;
        var v = try app.unlockVault(db, passphrase_file, false);
        defer v.deinit();
        const secrets = try operations.history(app.a, v, scope);
        defer for (secrets) |*secret| secret.deinit();
        const raw_entries = try db.entries(scope, "kv");
        const checkpoint_view: @import("journal_checkpoint.zig").View = if (audit) .{ .entries = raw_entries } else try @import("journal_checkpoint.zig").consume(app.a, raw_entries, secrets, c.field(c.field(checkpoint, "cursor") orelse .null, "counts") orelse .null);
        const journal_listing = try operations.listView(app.a, checkpoint_view.entries, secrets, if (all_chains) null else app.cast.chain, safe, audit);
        const listing = if (audit) journal_listing else try @import("operation_share.zig").merge(app.a, journal_listing, v, app.cast.chain, app.cast.instance, safe);
        var snapshots: std.AutoArrayHashMapUnmanaged(u64, c.Value) = .empty;
        const statuses = try @import("operation_status.zig").load(app.a, v, scope, app.profile, app.cast.chain, app.cast.instance, app.cast.chain);
        try snapshots.put(app.a, app.cast.chain, statuses);
        var rows: std.ArrayList(c.Value) = .empty;
        for (listing.entries) |record| {
            var item = record;
            const chain = try rpc.integer(app.a, c.field(c.field(record, "payload").?, "chainId").?);
            if (!snapshots.contains(chain)) try snapshots.put(app.a, chain, try @import("operation_status.zig").load(app.a, v, scope, app.profile, app.cast.chain, app.cast.instance, chain));
            const snapshot = snapshots.get(chain).?;
            const status = c.field(c.field(snapshot, "values") orelse .null, try c.string(c.field(record, "pendingId").?)) orelse c.Value{ .string = "unknown" };
            if (filter) |wanted| if (!c.eq(u8, wanted, try c.string(status))) continue;
            try item.object.put(app.a, "status", status);
            try item.object.put(app.a, "statusBlock", c.field(snapshot, "block") orelse .null);
            try item.object.put(app.a, "statusRegistry", c.field(snapshot, "registry") orelse .null);
            try rows.append(app.a, item);
        }
        const start_index = @min(start_at, rows.items.len);
        try app.output(.{ .total = rows.items.len, .entries = rows.items[start_index..@min(start_index + count, rows.items.len)], .view = view_name, .journalCheckpoint = checkpoint_view.checkpoint, .rejectedCheckpoints = checkpoint_view.rejected, .checkpoint = checkpoint, .statusBlock = c.field(statuses, "block"), .unreadable = listing.unreadable, .invalid = listing.invalid });
    }
    fn checkpointCommand(app: *App, p: []const []const u8) !void {
        if (p.len < 3 or !@import("schema.zig").contains("prepare inspect publish", p[2])) return error.UnknownCommand;
        const preparing = c.eq(u8, p[2], "prepare");
        if (p.len != @as(usize, if (preparing) 3 else 4)) return error.WrongArgumentCount;
        const actions = @import("checkpoint_actions.zig");
        const passphrase_file = app.args.get("passphrase-file");
        const retry = app.args.flag("retry");
        const keep_all = app.args.flag("keep-all");
        const confirmations = try rpc.integer(app.a, .{ .string = app.args.get("confirmations") orelse "12" });
        const chunk_size = try rpc.integer(app.a, .{ .string = app.args.get("chunk-size") orelse "128" });
        if (chunk_size == 0 or chunk_size > 128) return error.InvalidCheckpointChunkSize;
        if (retry and !c.eq(u8, p[2], "publish")) return error.WrongArgumentCount;
        if ((!preparing and (keep_all or confirmations != 12 or chunk_size != 128)) or (preparing and retry)) return error.WrongArgumentCount;
        if (preparing and app.dry) return error.CheckpointPrepareDoesNotBroadcast;
        try app.args.finish();
        const address = app.profile.get("kv_address") orelse return error.KvAddressRequired;
        const chain = try app.kvChain();
        const scope = try storage.scopeKey(app.a, chain, address);
        const db = try storage.Store.open(app.a, app.io, app.dir);
        defer db.close();
        var v = try app.unlockVault(db, passphrase_file, false);
        defer v.deinit();
        if (c.eq(u8, p[2], "inspect")) return app.output(try actions.summary(app.a, try actions.load(v, scope, p[3])));
        var kv_cast = app.cast;
        kv_cast.chain = chain;
        kv_cast.instance = address;
        kv_cast.checked = false;
        kv_cast.rpc = try app.kvRpc();
        if (!preparing) {
            const id = try c.id(app.a, p[3]);
            const lock = try std.Io.Dir.cwd().createFile(app.io, try app.a.print("{s}/checkpoint-{s}.lock", .{ app.dir, id }), .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true, .permissions = .fromMode(0o600) });
            defer lock.close(app.io);
            var draft = try actions.load(v, scope, id);
            return app.output(try actions.publish(&app.cast, &kv_cast, v, scope, &draft, retry, app.dry));
        }
        if (app.cast.block != null) return error.TransactionRequiresLatestBlock;
        var head = try v.head(scope);
        defer head.deinit();
        var remote = try rpc.Rpc.init(app.a, app.io, kv_cast.rpc, chain, address);
        defer remote.deinit();
        try remote.pin(null, 0);
        const auxiliary = try contracts.Catalog.loadAuxiliary(app.a);
        if (!std.ascii.eqlIgnoreCase(try c.string((try remote.call(try auxiliary.find("kv", "passwordSigner"), &.{})).array.items[0]), try head.address(app.a))) return error.WrongKvSigner;
        if (!(try remote.call(try auxiliary.find("kv", "indexingEnabled"), &.{})).array.items[0].bool) return error.CheckpointRequiresIndexedSync;
        var engine: sync.Engine = .{ .a = app.a, .db = db, .rpc = &remote, .cat = auxiliary, .scope = scope, .explorer = .{ .a = app.a, .io = app.io, .dir = app.dir, .chain = chain } };
        try db.begin();
        errdefer db.db.rollback();
        try operations.synchronize(&engine, v);
        const secrets = try operations.history(app.a, v, scope);
        defer for (secrets) |*secret| secret.deinit();
        const report = try actions.prepare(&app.cast, &remote, v, scope, secrets, try db.entries(scope, "kv"), c.field(c.field((try db.checkpoint(scope, "kv")).?, "cursor").?, "counts").?, confirmations, chunk_size, keep_all);
        try db.db.commit();
        return app.output(report);
    }
    fn operationsCommand(app: *App, p: []const []const u8) !void {
        if (p.len >= 2 and c.eq(u8, p[1], "checkpoint")) return app.checkpointCommand(p);
        if (p.len == 2 and c.eq(u8, p[1], "list")) return app.operationsList();
        if (p.len != 3) return error.OperationIdOrFileRequired;
        const actions = @import("operation_actions.zig");
        const Client = @import("contract_client.zig").Client;
        const registry = app.cast.instance;
        app.cast.instance = app.profile.forChain("interacts.", app.cast.chain) orelse app.profile.get("interact") orelse return error.InteractAddressRequired;
        app.cast.checked = false;
        const client: Client = .{ .cast = &app.cast, .cat = try contracts.Catalog.loadAuxiliary(app.a), .group = "interact" };
        try client.boundInteract(registry);
        if (@import("schema.zig").contains("import export export-local", p[1])) {
            const shares = @import("operation_share.zig");
            const out = app.args.get("out");
            const proposal_hash = app.args.get("proposal-tx");
            const passphrase_file = app.args.get("passphrase-file");
            try app.args.finish();
            const importing = c.eq(u8, p[1], "import");
            const local = c.eq(u8, p[1], "export-local");
            if (!importing and out == null) return error.OperationShareOutputRequired;
            if (proposal_hash != null and (importing or local)) return error.WrongArgumentCount;
            if (app.dry and !importing) return error.DryRunNotApplicable;
            const input = if (local) blk: {
                const db = try storage.Store.open(app.a, app.io, app.dir);
                defer db.close();
                var v = try app.unlockVault(db, passphrase_file, false);
                defer v.deinit();
                const values = try shares.load(app.a, v, app.cast.chain, registry);
                break :blk c.field(values, try c.id(app.a, p[2])) orelse return error.LocalOperationNotFound;
            } else try json_schema.read(app.a, app.io, if (importing) "operation-share" else "operation-proposal", p[2]);
            const share = try shares.verify(client, if (importing or local or c.field(input, "type") != null) input else try shares.envelope(app.a, c.field(input, "payload") orelse input, proposal_hash orelse try c.string(c.field(input, "proposalTxHash") orelse return error.ProposalTransactionHashRequired)));
            const record = try operations.proposal(app.a, try operations.encodeProposal(app.a, c.field(share, "payload").?));
            const id = try c.string(c.field(record, "pendingId").?);
            if (!app.dry) {
                if (out) |path| try c.write(app.io, path, try c.encode(app.a, share), false);
                if (importing) {
                    const db = try storage.Store.open(app.a, app.io, app.dir);
                    defer db.close();
                    var v = try app.unlockVault(db, passphrase_file, true);
                    defer v.deinit();
                    _ = try shares.save(app.a, v, app.cast.chain, registry, share);
                }
            }
            return app.output(.{ .pendingId = id, .proposalTxHash = c.field(share, "proposalTxHash").?, .verified = true, .imported = importing and !app.dry, .file = if (app.dry) null else out });
        }
        if (@import("schema.zig").contains("direct direct-sign-actor direct-sign", p[1])) return app.output(try @import("direct_execution.zig").run(client, registry, &app.args, p[2], p[1], app.dry));
        if (c.eq(u8, p[1], "simulate")) {
            const report = try @import("preflight.zig").operation(client, registry, &app.args, p[2]);
            try app.output(report);
            if (!c.field(report, "ok").?.bool) return error.OperationSimulationFailed;
            return;
        }
        if (c.eq(u8, p[1], "propose")) return app.output(try actions.propose(client, &app.args, p[2], app.dry));
        if (c.eq(u8, p[1], "execute") or c.eq(u8, p[1], "sign") or c.eq(u8, p[1], "sign-actor")) return app.output(try actions.execute(client, &app.args, p[2], p[1], app.dry));
        if (c.eq(u8, p[1], "publish")) {
            const passphrase_file = app.args.get("passphrase-file");
            try app.args.finish();
            const payload = try actions.read(client, p[2]);
            try actions.validate(client, payload);
            const plaintext = try operations.encodeProposal(app.a, payload);
            defer std.crypto.secureZero(u8, @constCast(plaintext));
            const chain = try app.kvChain();
            const address = app.profile.get("kv_address") orelse return error.KvAddressRequired;
            const scope = try storage.scopeKey(app.a, chain, address);
            const db = try storage.Store.open(app.a, app.io, app.dir);
            defer db.close();
            var v = try app.unlockVault(db, passphrase_file, false);
            defer v.deinit();
            var secret = try v.head(scope);
            defer secret.deinit();
            app.cast.rpc = try app.kvRpc();
            app.cast.chain = chain;
            app.cast.instance = address;
            app.cast.checked = false;
            const kv: Client = .{ .cast = &app.cast, .cat = client.cat, .group = "kv" };
            var key: [32]u8 = undefined;
            try app.io.randomSecure(&key);
            key[0] = 0xb0;
            const key_hex = try abi.hex(app.a, &key);
            const receipt = try @import("kv_write.zig").write(kv, secret, key_hex, plaintext, app.dry);
            return app.output(.{ .key = key_hex, .pendingId = c.field(try operations.proposal(app.a, plaintext), "pendingId").?, .transaction = receipt });
        }
        try app.args.finish();
        const id = try abi.uint(app.a, try c.word(p[2]));
        if (c.eq(u8, p[1], "status")) return app.output(try actions.status(client, id));
        const method = if (c.eq(u8, p[1], "approve")) "approveOperation" else if (c.eq(u8, p[1], "withdraw")) "withdrawOperation" else return error.UnknownCommand;
        return app.output(try client.transaction(method, &.{id}, null, app.dry));
    }
    fn commitmentsCommand(app: *App, p: []const []const u8) !void {
        const workflow = @import("commitments.zig");
        const codec = @import("commitment_codec.zig");
        if (p.len < 2) return error.WrongArgumentCount;
        const verb = p[1];
        const out = app.args.get("out");
        if (c.eq(u8, verb, "template")) {
            if (p.len != 3) return error.WrongArgumentCount;
            try app.args.finish();
            const report = try workflow.template(app.a, p[2]);
            if (out) |path| try c.write(app.io, path, try c.encode(app.a, report), false);
            return app.output(report);
        }
        if (!@import("schema.zig").contains("prepare import export list status commit reveal cancel expire reconcile", verb)) return error.UnknownCommand;
        const prepare = c.eq(u8, verb, "prepare");
        const importing = c.eq(u8, verb, "import");
        const list = c.eq(u8, verb, "list");
        const reconcile = c.eq(u8, verb, "reconcile");
        const exporting = c.eq(u8, verb, "export");
        if (p.len != @as(usize, if (prepare or reconcile) 4 else if (list) 2 else 3)) return error.WrongArgumentCount;
        if ((importing or exporting or reconcile) and app.dry) return error.DryRunNotApplicable;
        const password_file = app.args.get("passphrase-file");
        const retry = if (@import("schema.zig").contains("commit reveal cancel expire", verb)) app.args.flag("retry") else false;
        const signature_path = if (c.eq(u8, verb, "reveal")) app.args.get("actor-signature-file") else null;
        const source_file = if (prepare and c.eq(u8, p[2], "interaction")) app.args.get("source-file") else null;
        if (exporting and out == null) return error.OutputFileRequired;
        var input: c.Value = .null;
        if (prepare or importing) {
            input = try json_schema.read(app.a, app.io, if (prepare) try app.a.print("commitment-{s}{s}", .{ p[2], if (source_file != null) "-source" else "" }) else "commitment-export", if (prepare) p[3] else p[2]);
        }
        if (prepare) {
            try codec.strict(input, "payload deadline forwarder hint");
            const payload = try codec.field(input, "payload");
            if (payload != .object) return error.InvalidCommitmentDraft;
            if (c.eq(u8, p[2], "contract") or c.eq(u8, p[2], "token")) {
                for ([_][]const u8{ "address", "implementation", "price" }) |name| {
                    if (payload.object.getPtr(name)) |value| value.* = .{ .string = try app.reference(null, try c.string(value.*), true) };
                }
            } else if (c.eq(u8, p[2], "interaction")) {
                const bundle = try codec.field(payload, "bundle");
                if (bundle != .object) return error.InvalidCommitmentDraft;
                if (bundle.object.getPtr("id")) |value| value.* = .{ .string = try app.reference("interactions", try c.string(value.*), false) };
            }
            if (input.object.getPtr("forwarder")) |value| value.* = .{ .string = try app.reference(null, try c.string(value.*), true) };
            if (source_file) |file| {
                try @import("rpc_pool.zig").validateSelection(app.a, app.io, app.dir, app.profile_name, app.cast.chain, app.cast.rpc);
                var tool = app.compiler();
                const compiled = try tool.compile(file, &app.args);
                var bundle = try codec.field(payload, "bundle");
                try bundle.object.put(app.a, "script", try codec.field(compiled, "bytecode"));
                input.object.getPtr("payload").?.object.getPtr("bundle").?.* = bundle;
            }
        }
        try app.args.finish();
        try c.address(app.cast.instance);
        const db = try storage.Store.open(app.a, app.io, app.dir);
        defer db.close();
        const lock_path = try app.a.print("{s}/commitments-{s}.lock", .{ app.dir, try storage.scopeKey(app.a, app.cast.chain, app.cast.instance) });
        const lock = try std.Io.Dir.cwd().createFile(app.io, lock_path, .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true, .permissions = .fromMode(0o600) });
        defer lock.close(app.io);
        var v = try app.unlockVault(db, password_file, prepare or importing);
        defer v.deinit();
        if (prepare or importing) {
            var draft = if (prepare) try workflow.prepare(&app.cast, p[2], input) else input;
            try codec.validate(app.a, draft, app.cast.chain, app.cast.instance);
            // Imported history is untrusted. Live state and fresh receipt proofs
            // determine outcomes; local metadata never authorizes publication.
            if (importing) {
                _ = draft.object.orderedRemove("attempt");
                try draft.object.put(app.a, "payload", try codec.payload(app.a, try codec.string(draft, "kind"), try codec.field(draft, "payload")));
                try draft.object.put(app.a, "commitHash", try codec.word(app.a, try codec.field(draft, "commitHash")));
            }
            const report = try codec.summary(app.a, draft);
            if (out) |path| try c.write(app.io, path, try c.encode(app.a, report), false);
            if (!app.dry) try workflow.save(v, app.cast.chain, app.cast.instance, draft, false);
            return app.output(report);
        }
        const drafts = try workflow.load(v, app.cast.chain, app.cast.instance);
        if (list) {
            var rows = std.json.Array.init(app.a);
            for (drafts.object.values()) |draft| {
                try codec.validate(app.a, draft, app.cast.chain, app.cast.instance);
                try rows.append(try codec.summary(app.a, draft));
            }
            if (out) |path| try c.write(app.io, path, try c.encode(app.a, rows.items), false);
            return app.output(rows.items);
        }
        var draft = drafts.object.get(try c.string(try codec.word(app.a, .{ .string = p[2] }))) orelse return error.CommitmentDraftNotFound;
        try codec.validate(app.a, draft, app.cast.chain, app.cast.instance);
        if (exporting) {
            try c.write(app.io, out.?, try c.encode(app.a, draft), false);
            return app.output(.{ .file = out.?, .commitHash = try codec.field(draft, "commitHash"), .containsSecret = true });
        }
        const signature: c.Value = if (signature_path) |file| blk: {
            const parsed = try json_schema.read(app.a, app.io, "committer-signature", file);
            const value = c.field(parsed, "signature") orelse parsed;
            const bytes = try abi.unhex(app.a, try c.string(value));
            if (bytes.len == 0 or bytes.len > 16384) return error.InvalidSignature;
            break :blk value;
        } else .{ .string = "0x" };
        return app.output(try workflow.act(&app.cast, app.cat, v, &draft, .{ .verb = verb, .out = out, .signature = signature, .retry = retry, .dry = app.dry, .receipt_hash = if (reconcile) p[3] else null }));
    }
    fn recipientsCommand(app: *App, p: []const []const u8) !void {
        if (p.len < 3 or !@import("schema.zig").contains("list add remove authorize revoke resolve", p[1])) return error.UnknownCommand;
        const add = c.eq(u8, p[1], "add");
        const list = c.eq(u8, p[1], "list");
        if (p.len != @as(usize, if (add or list) 3 else 4)) return error.WrongArgumentCount;
        const passphrase_file = app.args.get("passphrase-file");
        const out = app.args.get("out");
        const offline = app.args.flag("offline");
        if (offline and !list) return error.OfflineRecipientListOnly;
        const label = if (add) app.args.get("label") orelse return error.RecipientLabelRequired else null;
        const recipient = if (add) try app.reference(null, app.args.get("recipient") orelse return error.RecipientRequired, true) else null;
        const account = try app.reference(null, app.args.get("vault") orelse return error.RecipientVaultRequired, true);
        const policy = try c.id(app.a, try app.reference("policies", p[2], false));
        const chain = try app.kvChain();
        const address = app.profile.get("kv_address") orelse return error.KvAddressRequired;
        const scope = try storage.scopeKey(app.a, chain, address);
        const explorer = programs.explorer(app.a, app.io, app.env, app.profile, app.dir, chain, &app.args);
        try app.args.finish();
        const db = try storage.Store.open(app.a, app.io, app.dir);
        defer db.close();
        var v = try app.unlockVault(db, passphrase_file, false);
        defer v.deinit();
        var head = try v.head(scope);
        defer head.deinit();
        var kv_cast = app.cast;
        kv_cast.chain = chain;
        kv_cast.instance = address;
        kv_cast.checked = false;
        kv_cast.rpc = if (offline) "" else try app.kvRpc();
        if (!offline) {
            var remote = try rpc.Rpc.init(app.a, app.io, kv_cast.rpc, chain, address);
            defer remote.deinit();
            try remote.pin(null, 0);
            var engine: sync.Engine = .{ .a = app.a, .db = db, .rpc = &remote, .cat = try contracts.Catalog.loadAuxiliary(app.a), .scope = scope, .explorer = explorer };
            const current_signer = (try remote.call(try engine.cat.find("kv", "passwordSigner"), &.{})).array.items[0];
            if (!std.ascii.eqlIgnoreCase(try c.string(current_signer), try head.address(app.a))) return error.WrongKvSigner;
            try db.begin();
            errdefer db.db.rollback();
            try operations.synchronize(&engine, v);
            if (!try remote.canonical(remote.block)) return error.ChainReorganizedRetrySync;
            try db.db.commit();
        }
        const context: @import("recipient_journal.zig").Context = .{ .storageChainId = chain, .kvAddress = address, .executionChainId = app.cast.chain, .registryAddress = app.cast.instance, .policyId = policy, .vault = account };
        const secrets = try operations.history(app.a, v, scope);
        defer for (secrets) |*secret| secret.deinit();
        const listing = try @import("recipient_journal.zig").list(app.a, try db.entries(scope, "kv"), secrets, context);
        return app.output(try @import("recipient_actions.zig").run(&app.cast, &kv_cast, head, context, listing, (try db.checkpoint(scope, "kv")) orelse return error.RunSyncFirst, .{ .verb = p[1], .reference = if (p.len == 4) p[3] else null, .recipient = recipient, .label = label, .out = out, .offline = offline, .dry = app.dry }));
    }
    fn authCommand(app: *App, p: []const []const u8) !void {
        const auth = @import("auth_signer.zig");
        const actions = @import("auth_actions.zig");
        if (c.eq(u8, p[1], "recover")) {
            if (p.len != 2) return error.WrongArgumentCount;
            const factory = app.args.get("auth-factory") orelse try @import("topology.zig").resolve(&app.cast, app.dir, app.profile, "authAccountFactory");
            return app.output(try @import("auth_recovery.zig").recover(&app.cast, factory, &app.args, app.auth_browser, app.dry));
        }
        if (c.eq(u8, p[1], "receipt")) {
            if (p.len != 3 or app.cast.auth == null) return error.AuthProfileRequired;
            const url = app.bundler_url orelse return error.BundlerUrlRequired;
            try app.args.finish();
            const hash = try c.id(app.a, p[2]);
            const response = try c.parse(app.a, try app.cast.run(&.{ "rpc", "eth_getUserOperationReceipt", hash, "--rpc-url", url }));
            if (response == .null) return app.output(.{ .status = "pending", .userOpHash = hash });
            return app.output(try auth.verifyReceipt(&app.cast, hash, try auth.string(try auth.field(response, "receipt"), "transactionHash")));
        }
        if (c.eq(u8, p[1], "register") or c.eq(u8, p[1], "inspect")) {
            if (p.len != 3) return error.WrongArgumentCount;
            try app.args.finish();
            const profile = try json_schema.read(app.a, app.io, "auth-profile", p[2]);
            return app.output(if (c.eq(u8, p[1], "register")) try actions.register(&app.cast, profile, app.dry) else try actions.inspect(&app.cast, profile, app.cast.instance));
        }
        const enroll = c.eq(u8, p[1], "enroll");
        if (p.len != @as(usize, if (enroll) 2 else 3)) return error.WrongArgumentCount;
        const registry = app.cast.instance;
        const factory = app.args.get("auth-factory") orelse if (enroll) try @import("topology.zig").resolve(&app.cast, app.dir, app.profile, "authAccountFactory") else try auth.string(try json_schema.read(app.a, app.io, "auth-enrollment", p[2]), "authAccountFactory");
        try c.address(factory);
        app.cast.instance = factory;
        app.cast.checked = false;
        const client: @import("contract_client.zig").Client = .{ .cast = &app.cast, .cat = try contracts.Catalog.loadAuxiliary(app.a), .group = "auth-factory" };
        return app.output(if (enroll) try actions.enroll(client, registry, &app.args, app.auth_browser, app.dry) else try actions.create(client, registry, p[2], &app.args, app.dry));
    }
    fn accountCommand(app: *App, p: []const []const u8) !void {
        const actions = @import("account_actions.zig");
        const is_safe = c.eq(u8, p[0], "safes");
        const creating = c.eq(u8, p[1], "create");
        if (p.len != @as(usize, if (creating) 2 else 3)) return error.WrongArgumentCount;
        const address = if (creating) "" else try app.reference(if (is_safe) "safes" else "accounts", p[2], true);
        const registry = app.cast.instance;
        const target = app.args.get(if (is_safe) "safe-factory" else "account-factory") orelse try @import("topology.zig").resolve(&app.cast, app.dir, app.profile, if (is_safe) "safeFactory" else "accountFactory");
        try c.address(target);
        app.cast.instance = target;
        app.cast.checked = false;
        const client: @import("contract_client.zig").Client = .{ .cast = &app.cast, .cat = try contracts.Catalog.loadAuxiliary(app.a), .group = if (is_safe) "safe-factory" else "account-factory" };
        if (creating) return app.output(try actions.create(client, registry, &app.args, is_safe, app.dry));
        if (c.eq(u8, p[1], "fund")) return app.output(try actions.fund(client, registry, address, &app.args, is_safe, app.dry));
        if (c.eq(u8, p[1], "inspect")) {
            try app.args.finish();
            return app.output(try actions.inspect(client, registry, address, is_safe));
        }
        if (is_safe) return app.output(try actions.importSafe(client, registry, address, &app.args, c.eq(u8, p[1], "sign-import"), app.dry));
        try app.args.finish();
        return app.output(try actions.importAccount(client, registry, address, app.dry));
    }
    fn kvCommand(app: *App, p: []const []const u8) !void {
        if (p.len < 2) return error.CommandRequired;
        if (@import("schema.zig").contains("rotate rotation-status history", p[1])) {
            if (p.len != 2) return error.WrongArgumentCount;
            const passphrase_file = app.args.get("passphrase-file");
            const secret_file = if (c.eq(u8, p[1], "rotate")) app.args.get("secret-file") else null;
            const resuming = if (c.eq(u8, p[1], "rotate")) app.args.flag("resume") else false;
            try app.args.finish();
            const completion_selection = app.selection();
            const chain = try app.kvChain();
            const address = app.profile.get("kv_address") orelse return error.KvAddressRequired;
            const scope = try storage.scopeKey(app.a, chain, address);
            const db = try storage.Store.open(app.a, app.io, app.dir);
            defer db.close();
            // Serialize rotation through the final profile save and recovery
            // cleanup, including other profiles targeting this same KV.
            const guard = if (c.eq(u8, p[1], "rotate")) try std.Io.Dir.cwd().createFile(app.io, try app.a.print("{s}/.kv-rotation-{x:0>64}.lock", .{ app.dir, ms.bytecode.hash(scope) }), .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true, .permissions = .fromMode(0o600) }) else null;
            defer if (guard) |file| file.close(app.io);
            var v = try app.unlockVault(db, passphrase_file, false);
            defer v.deinit();
            app.cast.rpc = try app.kvRpc();
            app.cast.chain = chain;
            app.cast.instance = address;
            app.cast.checked = false;
            const client: @import("contract_client.zig").Client = .{ .cast = &app.cast, .cat = try contracts.Catalog.loadAuxiliary(app.a), .group = "kv" };
            const rotation = @import("kv_rotation.zig");
            const outcome = try rotation.run(client, v, scope, p[1], secret_file, resuming, app.dry);
            if (outcome.confirmed) {
                try app.profile.set(app.a, "stack_secret_ref", try configuration.headReference(app.a, chain, address));
                try app.save();
                try db.db.exec("DELETE FROM vault WHERE id=?", .{try rotation.pendingId(app.a, scope)});
                _ = completion_session.request(app.a, app.io, completion_selection, "lock") catch null;
            }
            return app.output(outcome.value);
        }
        const create = c.eq(u8, p[1], "create");
        if ((!create and (!c.eq(u8, p[1], "connect") or p.len != 3)) or (create and p.len != 2)) return error.UnknownCommand;
        const passphrase_file = app.args.get("passphrase-file");
        const secret_file = app.args.get("secret-file");
        if (!create and secret_file == null) return error.KvSecretFileRequired;
        try app.args.finish();
        const chain = try app.kvChain();
        const target = if (create) app.profile.get("kv_factory") orelse try factories.address(app.a, .passwordGatedKVFactory, chain) orelse return error.KvFactoryRequired else p[2];
        try c.address(target);
        const db = try storage.Store.open(app.a, app.io, app.dir);
        defer db.close();
        var v = try app.unlockVault(db, passphrase_file, true);
        defer v.deinit();
        const pending = try app.a.print("kv-create:{s}:{s}", .{ app.profile_name, try storage.scopeKey(app.a, chain, target) });
        var secret = blk: {
            if (secret_file) |file| {
                const raw = try c.read(app.a, app.io, file);
                defer std.crypto.secureZero(u8, @constCast(raw));
                const bytes = try abi.unhex(app.a, c.trim(raw));
                defer std.crypto.secureZero(u8, bytes);
                if (bytes.len != 32) return error.InvalidKvSecret;
                break :blk try vault.Secret.init(bytes[0..32].*);
            }
            if (try v.get(pending)) |bytes| {
                defer std.crypto.secureZero(u8, bytes);
                if (bytes.len != 32) return error.InvalidVault;
                break :blk try vault.Secret.init(bytes[0..32].*);
            }
            // Standalone setup/import can precede KV deployment. Preserve that
            // shared secret, while an interrupted deployment keeps its own key.
            if (app.profile.get("kv_address") == null) if (try configuration.secretReference(app.a, app.profile)) |ref| {
                const bytes = (try v.get(ref)) orelse return error.KvSecretRequired;
                defer std.crypto.secureZero(u8, bytes);
                if (bytes.len != 32) return error.InvalidVault;
                break :blk try vault.Secret.init(bytes[0..32].*);
            };
            var bytes: [32]u8 = undefined;
            defer std.crypto.secureZero(u8, &bytes);
            try app.io.randomSecure(&bytes);
            break :blk try vault.Secret.init(bytes);
        };
        defer secret.deinit();
        const signer = try secret.address(app.a);
        const auxiliary = try contracts.Catalog.loadAuxiliary(app.a);
        var address = target;
        if (create) {
            // Keep the encrypted key before broadcast so an interrupted receipt
            // or profile write can be recovered without losing the new KV.
            try v.put(pending, &secret.private_key);
            const method = try auxiliary.find("kv-factory", "createWithIndexing");
            const data = try abi.calldata(app.a, method.abi, try abi.array(app.a, &.{.{ .string = signer }}));
            if (app.dry) return app.output(.{ .chainId = chain, .to = target, .function = method.signature, .data = data, .nonce = app.cast.nonce, .passwordSigner = signer });
            var cast = app.cast;
            cast.rpc = try app.kvRpc();
            cast.chain = chain;
            cast.instance = target;
            cast.checked = false;
            const receipt = try cast.send(data, null);
            const event = auxiliary.event("KVDeployed").?;
            const topic = try c.hex(app.a, ms.bytecode.hash(try contracts.signature(app.a, event, false)));
            var params = std.json.Array.init(app.a);
            for (c.field(event, "inputs").?.array.items) |param| if (!c.field(param, "indexed").?.bool) try params.append(param);
            var found = false;
            for (c.field(receipt, "logs").?.array.items) |log| {
                if (!std.ascii.eqlIgnoreCase(try c.string(c.field(log, "address").?), target)) continue;
                const topics = c.field(log, "topics").?.array.items;
                if (topics.len == 0 or !std.ascii.eqlIgnoreCase(try c.string(topics[0]), topic)) continue;
                const values = try abi.decode(app.a, .{ .array = params }, try abi.unhex(app.a, try c.string(c.field(log, "data").?)));
                if (!std.ascii.eqlIgnoreCase(try c.string(values.array.items[1]), signer)) continue;
                address = try c.string(values.array.items[0]);
                found = true;
            }
            if (!found) return error.KvDeploymentEventMissing;
        } else {
            if (app.dry) return error.DryRunNotApplicable;
            var remote = try rpc.Rpc.init(app.a, app.io, try app.kvRpc(), chain, address);
            defer remote.deinit();
            try remote.pin(null, 0);
            const expected = (try remote.call(try auxiliary.find("kv", "passwordSigner"), &.{})).array.items[0];
            if (!std.ascii.eqlIgnoreCase(try c.string(expected), signer)) return error.WrongKvSigner;
        }
        try v.putHead(try storage.scopeKey(app.a, chain, address), secret);
        try app.profile.set(app.a, "kv_address", address);
        try app.profile.set(app.a, "kv_chain", try app.a.print("{d}", .{chain}));
        try app.profile.set(app.a, "stack_secret_ref", try configuration.headReference(app.a, chain, address));
        try app.save();
        if (create) try db.db.exec("DELETE FROM vault WHERE id=?", .{pending});
        try app.output(.{ .kvAddress = address, .chainId = chain, .passwordSigner = signer });
    }
    fn cachedList(app: *App, name: []const u8, required: bool) !bool {
        if (app.args.flag("live")) return if (required) error.LiveTimelockRequiresPending else false;
        const offline = app.args.flag("offline");
        const db = try storage.Store.open(app.a, app.io, app.dir);
        defer db.close();
        try db.db.transaction();
        defer db.db.rollback();
        const scope = try storage.scopeKey(app.a, app.cast.chain, app.cast.instance);
        const checkpoint = (try db.checkpoint(scope, name)) orelse {
            if (offline or required) return error.RunSyncFirst;
            return false;
        };
        const start_at = try rpc.integer(app.a, .{ .string = app.args.get("start") orelse "0" });
        const count = try rpc.integer(app.a, .{ .string = app.args.get("count") orelse "50" });
        if (count > 1000) return error.PageTooLarge;
        try app.args.finish();
        const page = try db.page(scope, name, start_at, count);
        if (c.eq(u8, name, "users")) try app.output(.{ .total = page.total, .users = page.values, .checkpoint = checkpoint }) else try app.output(.{ .total = page.total, .entries = page.values, .checkpoint = checkpoint });
        return true;
    }
    fn result(app: *App, value: c.Value) !void {
        if (app.json) return app.output(value);
        if (value == .array and value.array.items.len == 1) {
            const first = value.array.items[0];
            if (first != .array and first != .object) return c.print(app.io, "{s}\n", .{try c.scalar(app.a, first)});
        }
        try app.output(value);
    }
    fn transaction(app: *App, method: contracts.Method, args: []const []const u8) !void {
        const value = app.args.get("value");
        if (value != null and !c.eq(u8, try c.string(c.field(method.abi, "stateMutability").?), "payable")) return error.NonpayableMethod;
        try app.args.finish();
        const data = try app.cast.calldata(method, args);
        try c.address(app.cast.instance);
        if (app.dry) return app.output(.{ .chainId = app.cast.chain, .to = app.cast.instance, .function = method.signature, .data = data, .value = value orelse "0", .nonce = app.cast.nonce });
        const receipt = try app.cast.send(data, value);
        const outcome = try receipts.classify(app.a, app.cat, receipt, app.cast.instance, method, args);
        if (!app.json) {
            try c.print(app.io, "{s}: {s}\n", .{ outcome.status, try c.string(c.field(receipt, "transactionHash").?) });
            for (outcome.queuedActions) |action| try c.print(app.io, "Action {s}\n  chainwall timelock get {s}\n", .{ action, action });
        }
        try app.output(.{ .status = outcome.status, .queuedActions = outcome.queuedActions, .executedActions = outcome.executedActions, .expiredActions = outcome.expiredActions, .skippedActions = outcome.skippedActions, .receipt = receipt });
    }
    fn profileCommand(app: *App, p: []const []const u8) !void {
        if (p.len < 2) return error.CommandRequired;
        if (c.eq(u8, p[1], "list")) {
            if (p.len != 2) return error.UnexpectedArgument;
            try app.args.finish();
            var names: std.ArrayList([]const u8) = .empty;
            var dir = std.Io.Dir.cwd().openDir(app.io, app.dir, .{ .iterate = true }) catch |err| {
                if (err == error.FileNotFound) return app.output(.{ .active = app.profile_name, .profiles = names.items });
                return err;
            };
            defer dir.close(app.io);
            var iterator = dir.iterate();
            while (try iterator.next(app.io)) |entry| if (std.mem.endsWith(u8, entry.name, ".toml")) try names.append(app.a, try app.a.dupe(u8, entry.name[0 .. entry.name.len - 5]));
            std.mem.sort([]const u8, names.items, {}, struct {
                fn less(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.lessThan(u8, a, b);
                }
            }.less);
            return app.output(.{ .active = app.profile_name, .profiles = names.items });
        }
        if (p.len != 3 or !config.validName(p[2])) return error.InvalidProfileName;
        try app.args.finish();
        if (c.eq(u8, p[1], "create")) {
            try config.save(.{}, app.a, app.io, app.dir, p[2], false);
        } else if (c.eq(u8, p[1], "use")) {
            _ = try c.read(app.a, app.io, try config.file(app.a, app.dir, p[2]));
            try c.write(app.io, try app.a.print("{s}/active", .{app.dir}), p[2], true);
        } else return error.UnknownCommand;
        try app.output(.{ .profile = p[2] });
    }
    fn configCommand(app: *App, p: []const []const u8) !void {
        if (p.len < 2) return error.CommandRequired;
        if (c.eq(u8, p[1], "generate-secret")) {
            const password_file = app.args.get("passphrase-file");
            try app.args.finish();
            if (p.len != 2) return error.UnexpectedArgument;
            if (app.dry) return error.DryRunNotApplicable;
            const generated = try configuration.generateSecret(app.a, app.io, app.dir, app.profile_name, password_file);
            app.profile = generated.profile;
            return app.output(.{ .profile = app.profile_name, .passwordSigner = generated.signer, .generated = true });
        }
        if (c.eq(u8, p[1], "import") or c.eq(u8, p[1], "export")) {
            const password_file = app.args.get("passphrase-file");
            const out = app.args.get("out");
            try app.args.finish();
            if (app.dry) return error.DryRunNotApplicable;
            if (c.eq(u8, p[1], "import")) {
                if (p.len != 3 or out != null) return error.ConfigurationFileRequired;
                app.profile = try configuration.importFile(app.a, app.io, app.dir, app.profile_name, app.profile, p[2], password_file);
                return app.output(.{ .profile = app.profile_name, .imported = p[2] });
            }
            if (p.len > 3 or (p.len == 3 and out != null)) return error.UnexpectedArgument;
            return configuration.exportFile(app.a, app.io, app.env, app.dir, app.profile, if (p.len == 3) p[2] else out, password_file, try app.colorEnabled());
        }
        try app.args.finish();
        if (c.eq(u8, p[1], "show")) {
            if (p.len != 2) return error.UnexpectedArgument;
            if (app.json) {
                const redacted = try config.Profile.parse(app.a, try app.profile.format(app.a, true));
                var object: std.json.ObjectMap = .empty;
                for (redacted.values.keys(), redacted.values.values()) |key, value| try object.put(app.a, key, .{ .string = value });
                return app.output(c.Value{ .object = object });
            }
            return c.print(app.io, "{s}", .{try app.profile.format(app.a, true)});
        }
        if (p.len < 3) return error.ConfigKeyRequired;
        if (c.eq(u8, p[1], "set")) {
            if (p.len != 4) return error.ConfigValueRequired;
            try app.profile.set(app.a, p[2], p[3]);
            if (c.eq(u8, p[2], "account")) _ = app.profile.values.orderedRemove("keystore");
            if (c.eq(u8, p[2], "keystore")) _ = app.profile.values.orderedRemove("account");
            try app.save();
        } else if (c.eq(u8, p[1], "unset")) {
            if (p.len != 3) return error.UnexpectedArgument;
            _ = app.profile.values.orderedRemove(p[2]);
            try app.save();
        } else if (c.eq(u8, p[1], "get")) {
            if (p.len != 3) return error.UnexpectedArgument;
            const value = app.profile.get(p[2]) orelse return error.ConfigKeyNotSet;
            const secret = c.eq(u8, p[2], "etherscan_api_key") or c.eq(u8, p[2], "rpc_url") or c.eq(u8, p[2], "kv_rpc_url") or std.mem.startsWith(u8, p[2], "rpc.");
            return app.output(.{ .key = p[2], .value = if (secret) "<configured>" else value });
        } else return error.UnknownCommand;
        try app.output(.{ .profile = app.profile_name, .updated = p[2] });
    }
    fn colorEnabled(app: *App) !bool {
        return display.enabled(app.color, app.json, try std.Io.File.stdout().supportsAnsiEscapeCodes(app.io), app.env);
    }
    fn methodHelp(app: *App, method: contracts.Method) !void {
        if (app.json) return app.output(method.abi);
        var renderer = help.Renderer.init(app.a, try app.colorEnabled());
        try renderer.method(method);
        try renderer.print(app.io);
    }
    fn generic(app: *App, p: []const []const u8, wants_help: bool) !void {
        if (p.len == 1) {
            try app.args.finish();
            var renderer = help.Renderer.init(app.a, try app.colorEnabled());
            try renderer.group(app.cat, p[0]);
            try renderer.print(app.io);
            return;
        }
        const name = alias(p[0], p[1]);
        const method = try app.cat.find(p[0], name);
        if (wants_help) return app.methodHelp(method);
        if (c.eq(u8, method.group, "terms") and c.eq(u8, method.name, "acceptTerms")) return app.output(try @import("terms.zig").accept(&app.cast, app.cat, &app.args, p, app.dry));
        const params = c.field(method.abi, "inputs").?.array.items;
        var values: []const []const u8 = p[2..];
        if (app.args.get("args-file")) |path| {
            if (values.len != 0) return error.ConflictingArguments;
            var validator = try json_schema.Validator.init(app.a);
            const rule = try json_schema.abiArguments(app.a, c.field(method.abi, "inputs").?, true);
            const json_values = try app.resolveArguments(method, params, try json_schema.readRule(&validator, app.io, rule, method.signature, path));
            values = try contracts.arguments(app.a, params, json_values);
            app.cast.json_values = json_values;
            app.cast.json_arguments = true;
        } else if (values.len == 0 and params.len > 0) {
            var named: std.json.ObjectMap = .empty;
            for (params) |param| {
                const key = try c.string(c.field(param, "name").?);
                const flag_key = try c.kebab(app.a, key);
                const raw = app.args.get(try app.a.print("arg-{s}", .{flag_key})) orelse app.args.get(flag_key) orelse if (c.eq(u8, p[1], "list") or c.eq(u8, p[1], "pending")) (if (c.eq(u8, key, "start")) "0" else if (c.eq(u8, key, "count")) "50" else return error.MissingNamedArgument) else return error.MissingNamedArgument;
                const kind = try c.string(c.field(param, "type").?);
                const value: c.Value = if (c.eq(u8, kind, "string") or (!std.mem.startsWith(u8, kind, "tuple") and !std.mem.endsWith(u8, kind, "]"))) .{ .string = raw } else try c.parse(app.a, raw);
                if (value != .string) {
                    var validator = try json_schema.Validator.init(app.a);
                    try validator.require(app.io, try json_schema.abiParameter(app.a, param, true), value, key);
                }
                try named.put(app.a, key, try app.resolveArgument(method, param, value));
            }
            values = try contracts.arguments(app.a, params, .{ .object = named });
            app.cast.json_values = .{ .object = named };
            app.cast.json_arguments = true;
        }
        if (values.len != params.len) return error.WrongArgumentCount;
        if (!app.cast.json_arguments) {
            const resolved = try app.a.dupe([]const u8, values);
            for (params, resolved) |param, *value| value.* = try c.scalar(app.a, try app.resolveArgument(method, param, .{ .string = value.* }));
            values = resolved;
        }
        if (method.read() and !app.dry) {
            try app.args.finish();
            return app.result(try app.cast.call(method, values));
        }
        try app.transaction(method, values);
    }
    fn compiler(app: *App) programs.Compiler {
        return .{ .a = app.a, .io = app.io, .cat = app.cat, .cast = &app.cast, .explorer = programs.explorer(app.a, app.io, app.env, app.profile, app.dir, app.cast.chain, &app.args) };
    }
    fn resolveArguments(app: *App, method: contracts.Method, params: []const c.Value, value: c.Value) anyerror!c.Value {
        var resolved = value;
        if (value == .array) {
            if (value.array.items.len != params.len) return error.WrongArgumentCount;
            for (params, resolved.array.items) |param, *item| item.* = try app.resolveArgument(method, param, item.*);
        } else if (value == .object) {
            for (params) |param| {
                const name = try c.string(c.field(param, "name").?);
                if (resolved.object.getPtr(name)) |item| item.* = try app.resolveArgument(method, param, item.*);
            }
        }
        return resolved;
    }
    fn resolveArgument(app: *App, method: contracts.Method, param: c.Value, value: c.Value) anyerror!c.Value {
        const type_ = try c.string(c.field(param, "type").?);
        if (std.mem.endsWith(u8, type_, "]") and value == .array) {
            var child = param;
            child.object = try param.object.clone(app.a);
            try child.object.put(app.a, "type", .{ .string = type_[0..std.mem.lastIndexOfScalar(u8, type_, '[').?] });
            for (value.array.items) |*item| item.* = try app.resolveArgument(method, child, item.*);
            return value;
        }
        if (c.eq(u8, type_, "tuple")) return app.resolveArguments(method, c.field(param, "components").?.array.items, value);
        if (value != .string) return value;
        // These action salts are public replay identifiers. Commit/reveal salts
        // must remain explicit bytes32 values to preserve their secrecy.
        if (c.eq(u8, type_, "bytes32") and c.eq(u8, try c.string(c.field(param, "name").?), "salt") and
            @import("schema.zig").contains("hashSecurityCouncilRecovery scheduleSecurityCouncilRecovery executeSecurityCouncilRecovery", method.name))
            return .{ .string = try c.salt(app.a, value.string) };
        const kind = labels.collection(method.group, method.name, try c.string(c.field(param, "name").?));
        if (c.eq(u8, type_, "address")) return .{ .string = try app.reference(kind, value.string, true) };
        if (!std.mem.startsWith(u8, value.string, "@")) return value;
        if ((!c.eq(u8, type_, "bytes32") and !c.eq(u8, type_, "string")) or kind == null) return value;
        if (c.eq(u8, type_, "string") and kind != null and c.eq(u8, kind.?, "orgs")) {
            _ = try app.reference(kind, value.string, false);
            return .{ .string = value.string[1..] };
        }
        if (c.eq(u8, type_, "string") and kind != null and (c.eq(u8, kind.?, "contracts") or c.eq(u8, kind.?, "tokens"))) {
            const id = try app.reference(kind, value.string, false);
            for (try app.references()) |entry| if (c.eq(u8, entry.kind, kind.?) and c.eq(u8, entry.id, id)) return .{ .string = entry.name orelse return error.UnknownLabelUnlockOrSync };
        }
        return .{ .string = try app.reference(kind, value.string, false) };
    }
    fn compileCommand(app: *App, path: []const u8) !void {
        const out = app.args.get("out");
        var tool = app.compiler();
        const program = try tool.compile(path, &app.args);
        if (out) |output_path| try c.write(app.io, output_path, try c.encode(app.a, program), true);
        if (app.json) return app.output(program);
        try c.print(app.io, "{s}\n", .{try c.string(c.field(program, "bytecode").?)});
    }
    fn sourceOutput(app: *App, source: []const u8, out: ?[]const u8) !void {
        if (out) |path| try c.write(app.io, path, source, true);
        const colored = try app.colorEnabled();
        try c.print(app.io, "{s}", .{if (colored) try display.highlight(app.a, source) else source});
        if (!std.mem.endsWith(u8, source, "\n")) try c.print(app.io, "\n", .{});
    }
    fn interactionSource(app: *App, name: []const u8) !void {
        const id = try c.id(app.a, try app.reference("interactions", name, false));
        const out = app.args.get("out");
        var tool = app.compiler();
        var offline = false;
        var live = false;
        // Validate before any RPC or cache access; inspect consumes these options.
        for (app.args.options) |option| if (!option.used) {
            if (!selected("settings,no-preprocess,offline,live,snapshot,abi,optimization,argument-context", option.key)) return error.UnknownOption;
            if (c.eq(u8, option.key, "offline")) offline = true;
            if (c.eq(u8, option.key, "live")) live = true;
        };
        if (live and offline) return error.ConflictingArguments;
        var bytecode: ?[]const u8 = null;
        if (!live) {
            const db = try storage.Store.open(app.a, app.io, app.dir);
            defer db.close();
            const scope = try storage.scopeKey(app.a, app.cast.chain, app.cast.instance);
            if (try db.checkpoint(scope, "interactions") != null) {
                const entries = try db.entries(scope, "interactions");
                for (entries.values()) |entry| if (std.ascii.eqlIgnoreCase(c.string(c.field(entry, "key") orelse .null) catch "", id)) {
                    bytecode = try c.string(c.field(c.field(entry, "record") orelse .null, "script") orelse return error.InvalidInteractionRecord);
                    break;
                };
            }
        }
        if (bytecode == null) {
            if (offline) return error.InteractionNotCached;
            bytecode = try c.string((try app.query("getInteractionScript", &.{id})).array.items[0]);
        }
        if (bytecode.?.len <= 2) return error.InteractionMissing;
        const source = try tool.inspect(try ms.bytecode.unhex(app.a, bytecode.?), .null, &app.args);
        if (app.json) {
            if (out) |path| try c.write(app.io, path, source.source, true);
            return app.output(.{ .id = id, .bytecode = bytecode.?, .source = source.source, .restored = source.restored });
        }
        try app.sourceOutput(source.source, out);
    }
    fn publish(app: *App, path: []const u8, update: bool) !void {
        const stem = std.Io.Dir.path.stem(path);
        const id = try c.id(app.a, try app.reference("interactions", app.args.get("id") orelse stem, false));
        const flags = app.args.get("flags");
        const linked_path = app.args.get("linked-file");
        const out = app.args.get("out");
        var tool = app.compiler();
        // All reads contributing to an update use one block. The subsequent
        // publication binds that snapshot with the Registry's compare-and-swap.
        try app.cast.check();
        const requested_block = app.cast.block;
        defer app.cast.block = requested_block;
        if (app.cast.block == null) app.cast.block = try app.cast.run(&.{ "block-number", "--rpc-url", app.cast.rpc });
        const program = try tool.compile(path, &app.args);
        const prior_script = try c.string((try app.query("getInteractionScript", &.{id})).array.items[0]);
        const exists = prior_script.len > 2;
        if (exists and !update) return error.InteractionExistsUseUpdate;
        if (!exists and update) return error.InteractionMissingUseAdd;
        const expected = (try app.query("getInteractionBundleHash", &.{id})).array.items[0];
        var current_flags: c.Value = .{ .string = "0" };
        var linked: c.Value = .{ .array = std.json.Array.init(app.a) };
        if (update) {
            const previous = (try app.query("getInteractionBundle", &.{id})).array.items[0].array.items;
            current_flags = previous[2];
            linked = previous[3];
        }
        if (linked_path) |file| linked = try json_schema.read(app.a, app.io, "linked-artifacts", file);
        const desired = try c.parse(app.a, try c.encode(app.a, .{ .expectedCurrentBundleHash = expected, .bundle = .{ .id = id, .script = c.field(program, "bytecode").?, .flags = if (flags) |value| c.Value{ .string = value } else current_flags, .linked = linked } }));
        const method = try app.cat.find("interactions", "upsertInteractionBundle");
        const values = try contracts.arguments(app.a, c.field(method.abi, "inputs").?.array.items, desired);
        app.cast.json_arguments = true;
        if (out) |file| try c.write(app.io, file, try c.encode(app.a, .{ .program = program, .publication = desired, .block = app.cast.block, .chainId = app.cast.chain, .instance = app.cast.instance }), true);
        if (!app.json and !app.dry) try c.print(app.io, "Interaction {s}\n", .{id});
        // The generated compare-and-swap already binds the read snapshot.
        // Restore the caller's block selection before dispatching the signer.
        app.cast.block = requested_block;
        try app.transaction(method, values);
    }
    fn run(app: *App) !void {
        const p = app.args.positional;
        const wants_help = app.args.flag("help");
        if (app.args.flag("version")) {
            var renderer = help.Renderer.init(app.a, try app.colorEnabled());
            try renderer.version();
            return renderer.print(app.io);
        }
        if (p.len == 0) {
            try app.args.finish();
            var renderer = help.Renderer.init(app.a, try app.colorEnabled());
            try renderer.top();
            return renderer.print(app.io);
        }
        if (wants_help) {
            var renderer = help.Renderer.init(app.a, try app.colorEnabled());
            if (try renderer.command(p)) return renderer.print(app.io);
            return app.generic(p, true);
        }
        const local_command = @import("schema.zig").contains("rpc config profile logs search id artifacts completions __completion-session status instances", p[0]) or
            (c.eq(u8, p[0], "accounts") and p.len == 1) or
            (p.len > 1 and c.eq(u8, p[0], "operations") and c.eq(u8, p[1], "list")) or
            (p.len > 1 and c.eq(u8, p[0], "transactions") and c.eq(u8, p[1], "list")) or
            (p.len > 2 and c.eq(u8, p[0], "operations") and c.eq(u8, p[1], "checkpoint") and c.eq(u8, p[2], "inspect")) or
            (p.len > 1 and c.eq(u8, p[0], "commitments") and @import("schema.zig").contains("template prepare import export list", p[1])) or
            (p.len > 1 and c.eq(u8, p[0], "facets") and c.eq(u8, p[1], "catalog"));
        const offline_recipient_list = blk: {
            if (p.len > 1 and c.eq(u8, p[0], "recipients") and c.eq(u8, p[1], "list")) for (app.args.options) |option| {
                if (c.eq(u8, option.key, "offline")) break :blk true;
            };
            break :blk false;
        };
        if (!local_command and !offline_recipient_list) try @import("rpc_pool.zig").validateSelection(app.a, app.io, app.dir, app.profile_name, app.cast.chain, app.cast.rpc);
        if (c.eq(u8, p[0], "completions")) return app.completionCommand(p);
        if (c.eq(u8, p[0], "__completion-session")) {
            const ttl = try std.fmt.parseInt(u64, app.args.get("ttl") orelse "900", 10);
            const refresh = try std.fmt.parseInt(u64, app.args.get("refresh") orelse "30", 10);
            try app.args.finish();
            if (ttl == 0 or ttl > 86400 or refresh > 86400) return error.InvalidCompletionDuration;
            const args = try std.mem.concat(app.a, []const u8, &.{ try app.sessionArgs("sync"), &.{ "--only", "users,groups,policies,orgs,contracts,tokens,interactions,safes,accounts,labels,timelocks" } });
            return completion_session.serve(app.a, app.io, app.selection(), ttl, refresh, args);
        }
        if (app.cast.from) |from| app.cast.from = try app.reference(null, from, true);
        for (app.args.options) |*option| if (!option.used and (c.eq(u8, option.key, "owner") or c.eq(u8, option.key, "safe"))) {
            option.value = try app.reference(if (c.eq(u8, option.key, "safe")) "safes" else null, option.value, true);
        };
        if (c.eq(u8, p[0], "labels")) return app.labelsCommand(p);
        if (c.eq(u8, p[0], "commitments")) return app.commitmentsCommand(p);
        if (c.eq(u8, p[0], "search")) return app.searchCommand(p);
        if (c.eq(u8, p[0], "status") or c.eq(u8, p[0], "instances")) {
            return app.output(try @import("instance_views.zig").run(&app.cast, app.cat, app.profile, app.dir, app.profile_name, &app.args, p));
        }
        if (c.eq(u8, p[0], "security-council")) {
            const council_args = try app.a.dupe([]const u8, p);
            if (p.len == 3 and @import("schema.zig").contains("configure inspect", p[1])) council_args[2] = try app.reference("groups", p[2], false);
            for (app.args.options) |*option| if (!option.used and c.eq(u8, option.key, "recovery-authority")) {
                option.value = try app.reference(null, option.value, true);
            };
            return app.output(try @import("security_council.zig").run(&app.cast, app.cat, &app.args, council_args, app.dry));
        }
        if (p.len >= 2 and c.eq(u8, p[0], "tokens") and c.eq(u8, p[1], "set-chainlink-native-feed")) {
            if (p.len != 2) return error.WrongArgumentCount;
            try app.args.finish();
            const values = try @import("native_price.zig").arguments(&app.cast, app.cat, app.dry);
            const method = try app.cat.find("registry", "multicall");
            app.cast.json_values = values;
            return app.transaction(method, try contracts.arguments(app.a, c.field(method.abi, "inputs").?.array.items, values));
        }
        if (p.len >= 2 and c.eq(u8, p[0], "tokens") and @import("schema.zig").contains("metadata configure validate-feed", p[1])) {
            if (p.len != 3) return error.IdentifierRequired;
            const address = c.eq(u8, p[1], "validate-feed") or (c.eq(u8, p[1], "metadata") and p[2].len == 42 and std.mem.startsWith(u8, p[2], "0x"));
            const resolved = try app.reference("contracts", p[2], address);
            return app.output(try @import("token_actions.zig").run(&app.cast, app.cat, &app.args, resolved, p[1], app.dry));
        }
        if (p.len >= 2 and (c.eq(u8, p[0], "accounts") or c.eq(u8, p[0], "safes")) and @import("schema.zig").contains("assets activity", p[1])) {
            if (p.len != 3) return error.AccountAddressRequired;
            const address = try app.reference(p[0], p[2], true);
            if (c.eq(u8, p[1], "assets")) {
                for (app.args.options) |*option| if (!option.used and c.eq(u8, option.key, "token-id")) {
                    option.value = try app.reference("tokens", option.value, false);
                };
                return app.output(try @import("account_views.zig").assets(&app.cast, app.cat, &app.args, address));
            }
            return app.output(try @import("account_views.zig").activity(&app.cast, app.dir, app.profile, &app.args, address));
        }
        if (p.len >= 2 and c.eq(u8, p[0], "terms") and c.eq(u8, p[1], "accept-terms")) return app.output(try @import("terms.zig").accept(&app.cast, app.cat, &app.args, p, app.dry));
        if (p.len >= 2 and c.eq(u8, p[0], "policies") and c.eq(u8, p[1], "templates")) {
            for (app.args.options) |*option| if (!option.used and c.eq(u8, option.key, "interaction")) {
                option.value = try app.reference("interactions", option.value, false);
            };
            const report = try @import("policy_programs.zig").templates(&app.cast, app.cat, &app.args, p);
            if (p.len == 3 and !app.json) return c.print(app.io, "{s}\n", .{try c.string(c.field(report, "source").?)});
            return app.output(report);
        }
        if (p.len >= 3 and c.eq(u8, p[0], "policies") and c.eq(u8, p[1], "program")) {
            if (p.len < 4) return error.WrongArgumentCount;
            const id = if (c.eq(u8, p[2], "compile")) "" else try c.id(app.a, try app.reference("policies", p[3], false));
            if (c.eq(u8, p[2], "simulate")) {
                if (p.len != 5) return error.WrongArgumentCount;
                const out = app.args.get("out");
                try app.args.finish();
                const context = try json_schema.read(app.a, app.io, "policy-context", p[4]);
                const registry = app.cast.instance;
                app.cast.instance = app.profile.forChain("interacts.", app.cast.chain) orelse app.profile.get("interact") orelse try @import("topology.zig").resolve(&app.cast, app.dir, app.profile, "interact");
                app.cast.checked = false;
                const client: @import("contract_client.zig").Client = .{ .cast = &app.cast, .cat = try contracts.Catalog.loadAuxiliary(app.a), .group = "interact" };
                const method = try client.cat.find("interact", "simulatePolicyProgram");
                const input = try app.resolveArguments(method, c.field(method.abi, "inputs").?.array.items, try c.parse(app.a, try c.encode(app.a, .{ .policyId = id, .input = context })));
                const report = try @import("preflight.zig").policyInput(client, registry, input, out);
                try app.output(report);
                if (!c.field(report, "ok").?.bool) return error.PolicySimulationFailed;
                return;
            }
            var tool = app.compiler();
            return app.output(try @import("policy_programs.zig").run(&tool, &app.args, p, id, app.dry));
        }
        if (p.len >= 2 and c.eq(u8, p[0], "policies") and c.eq(u8, p[1], "simulate")) {
            if (p.len != 3) return error.PolicySimulationFileRequired;
            const registry = app.cast.instance;
            app.cast.instance = app.profile.forChain("interacts.", app.cast.chain) orelse app.profile.get("interact") orelse try @import("topology.zig").resolve(&app.cast, app.dir, app.profile, "interact");
            app.cast.checked = false;
            const client: @import("contract_client.zig").Client = .{ .cast = &app.cast, .cat = try contracts.Catalog.loadAuxiliary(app.a), .group = "interact" };
            const report = try @import("preflight.zig").policy(client, registry, &app.args, p[2]);
            try app.output(report);
            if (!c.field(report, "ok").?.bool) return error.PolicySimulationFailed;
            return;
        }
        if (c.eq(u8, p[0], "analyze")) {
            if (p.len != 2) return error.SourceFileRequired;
            const options: @import("program_analysis.zig").Options = .{ .read_only = app.args.flag("read-only"), .linked = app.args.flag("linked") };
            const out = app.args.get("out");
            const raw = if (std.mem.endsWith(u8, p[1], ".ls")) blk: {
                var tool = app.compiler();
                const program = try tool.compile(p[1], &app.args);
                break :blk try c.string(c.field(program, "bytecode").?);
            } else blk: {
                try app.args.finish();
                const input = c.trim(try c.read(app.a, app.io, p[1]));
                if (!std.mem.startsWith(u8, input, "{")) break :blk input;
                const value = try c.parse(app.a, input);
                break :blk try c.string(c.field(c.field(value, "program") orelse value, "bytecode") orelse return error.MissingBytecode);
            };
            const report = try @import("program_analysis.zig").analyze(app.a, try ms.bytecode.unhex(app.a, raw), options);
            if (out) |file| try c.write(app.io, file, try c.encode(app.a, report), true);
            try app.output(report);
            if (!c.field(report, "valid").?.bool) return error.MiniScriptAnalysisFailed;
            return;
        }
        if (c.eq(u8, p[0], "transactions")) {
            if (p.len > 1 and @import("schema.zig").contains("list track refresh wait speed-up cancel", p[1])) {
                const report = try @import("transaction_actions.zig").run(&app.cast, app.dir, &app.args, p, app.dry);
                try app.output(report);
                if (c.eq(u8, p[1], "wait")) {
                    const receipt = try @import("transaction_watch.zig").verifiedReceipt(report);
                    if (try c.number(app.a, c.field(receipt, "status").?) != 1) return error.TransactionReverted;
                }
                return;
            }
            if (p.len == 3 and c.eq(u8, p[1], "estimate")) {
                const out = app.args.get("out");
                try app.args.finish();
                const report = try @import("transaction_fees.zig").estimate(&app.cast, try json_schema.read(app.a, app.io, "transaction-document", p[2]));
                app.estimate = false;
                if (out) |file| try c.write(app.io, file, try c.encode(app.a, report), false);
                return app.output(report);
            }
            if (p.len < 3 or !@import("schema.zig").contains("inspect source", p[1])) return error.TransactionHashesRequired;
            const out = app.args.get("out");
            const program_out = app.args.get("program-out");
            const explorer = programs.explorer(app.a, app.io, app.env, app.profile, app.dir, app.cast.chain, &app.args);
            const report = try @import("transactions.zig").run(&app.cast, app.cat, explorer, app.chain, &app.args, p[2..]);
            const program = c.field(report, "program").?;
            if (program_out) |file| {
                if (program == .null) {
                    try app.output(report);
                    return error.TransactionSourceUnavailable;
                }
                try c.write(app.io, file, try c.encode(app.a, program), false);
            }
            if (c.eq(u8, p[1], "source")) {
                if (program == .null) {
                    try app.output(report);
                    return error.TransactionSourceUnavailable;
                }
                const source = try c.string(c.field(program, "source").?);
                if (app.json) {
                    if (out) |file| try c.write(app.io, file, source, true);
                    return app.output(report);
                }
                for (c.field(report, "warnings").?.array.items) |warning| try std.Io.File.stderr().writeStreamingAll(app.io, try app.a.print("chainwall: {s}\n", .{try c.string(warning)}));
                return app.sourceOutput(source, out);
            }
            if (out) |file| try c.write(app.io, file, try c.encode(app.a, report), true);
            return app.output(report);
        }
        if (p.len > 1 and c.eq(u8, p[0], "facets") and @import("schema.zig").contains("catalog deploy verify plan apply check reconcile", p[1])) {
            const facet_args = try app.a.dupe([]const u8, p);
            if (p.len == 4 and c.eq(u8, p[1], "verify")) facet_args[3] = try app.reference(null, p[3], true);
            for (app.args.options) |*option| if (!option.used and @import("schema.zig").contains("target current", option.key) and !c.eq(u8, option.value, "none")) {
                option.value = try app.reference(null, option.value, true);
            };
            return app.output(try @import("facet_actions.zig").run(&app.cast, app.cat, app.dir, &app.args, facet_args, app.dry));
        }
        if (c.eq(u8, p[0], "upgrade")) {
            const outcome = try @import("upgrade_actions.zig").run(&app.cast, app.cat, app.profile, app.dir, &app.args, p, app.dry);
            try app.output(outcome);
            if (c.field(outcome, "compatible")) |value| if (!value.bool) return error.IncompatibleUpgradeCandidate;
            if (!app.dry) if (c.field(outcome, "ready")) |value| if (value == .bool and !value.bool) return error.UpgradeSimulationFailed;
            return;
        }
        if (c.eq(u8, p[0], "kv")) {
            return app.kvCommand(p);
        }
        if (p.len >= 2 and c.eq(u8, p[0], "terms") and c.eq(u8, p[1], "document")) return app.output(try @import("terms.zig").inspect(&app.cast, app.cat, &app.args, p));
        if (c.eq(u8, p[0], "operations")) {
            return app.operationsCommand(p);
        }
        if (c.eq(u8, p[0], "recipients")) return app.recipientsCommand(p);
        if (p.len >= 2 and c.eq(u8, p[0], "auth") and @import("schema.zig").contains("enroll recover create register inspect receipt", p[1])) return app.authCommand(p);
        if (p.len >= 2 and (c.eq(u8, p[0], "accounts") or c.eq(u8, p[0], "safes")) and (@import("schema.zig").contains("create import inspect fund", p[1]) or (c.eq(u8, p[0], "safes") and c.eq(u8, p[1], "sign-import")))) return app.accountCommand(p);
        if (c.eq(u8, p[0], "sync") and p.len == 1) {
            return app.syncCommand();
        }
        if (p.len == 2 and c.eq(u8, p[1], "list")) {
            var cached = c.eq(u8, p[0], "timelocks");
            for (sync.datasets) |dataset| if (c.eq(u8, p[0], dataset.name)) {
                cached = true;
            };
            if (cached) {
                if (try app.cachedList(p[0], c.eq(u8, p[0], "timelocks"))) return;
            }
        }
        if (c.eq(u8, p[0], "profile")) return app.profileCommand(p);
        if (c.eq(u8, p[0], "rpc")) return app.output(try @import("rpc_pool.zig").run(&app.cast, app.dir, app.profile_name, &app.args, p, app.dry));
        if (c.eq(u8, p[0], "logs")) return app.logsCommand(p);
        if (c.eq(u8, p[0], "deploy")) return app.deployCommand();
        if (c.eq(u8, p[0], "config")) return app.configCommand(p);
        if (c.eq(u8, p[0], "compile")) {
            if (p.len != 2) return error.SourceFileRequired;
            return app.compileCommand(p[1]);
        }
        if (c.eq(u8, p[0], "abi")) {
            if (p.len != 2) return error.ContractAddressRequired;
            const out = app.args.get("out");
            var explorer = programs.explorer(app.a, app.io, app.env, app.profile, app.dir, app.cast.chain, &app.args);
            try app.args.finish();
            const abi_value = try explorer.abi(try app.reference("contracts", p[1], true));
            if (out) |file| try c.write(app.io, file, try c.encode(app.a, abi_value), true);
            return app.output(abi_value);
        }
        if (c.eq(u8, p[0], "decompile") or c.eq(u8, p[0], "disasm")) {
            if (p.len != 2) return error.BytecodeFileRequired;
            const input = c.trim(try c.read(app.a, app.io, p[1]));
            const document = if (std.mem.startsWith(u8, input, "{")) (try std.json.parseFromSlice(c.Value, app.a, input, .{ .allocate = .alloc_always })).value else @as(c.Value, .null);
            const program = c.field(document, "program") orelse document;
            const source = app.args.flag("source");
            const out = app.args.get("out");
            const raw = if (program != .null) try c.string(c.field(program, "bytecode") orelse return error.MissingBytecode) else input;
            const bytes = try ms.bytecode.unhex(app.a, raw);
            if (source or c.eq(u8, p[0], "decompile")) {
                var tool = app.compiler();
                const recovered = try tool.inspect(bytes, program, &app.args);
                return app.sourceOutput(recovered.source, out);
            }
            var explicit_settings = false;
            for (app.args.options) |option| if (c.eq(u8, option.key, "settings")) {
                explicit_settings = true;
            };
            const defaults = if (!explicit_settings) c.field(program, "settings") else null;
            _ = try programs.Compiler.loadSettingsWithDefaults(app.a, app.io, &app.args, if (defaults) |value| try ms.json.settings(value) else .{});
            try app.args.finish();
            const rendered = try ms.disasm(app.a, bytes);
            if (out) |path| try c.write(app.io, path, rendered, true);
            return c.print(app.io, "{s}\n", .{rendered});
        }
        if (c.eq(u8, p[0], "interactions") and p.len > 1) {
            if (c.eq(u8, p[1], "source")) {
                if (p.len != 3) return error.IdentifierRequired;
                return app.interactionSource(p[2]);
            }
            if (c.eq(u8, p[1], "compile") or c.eq(u8, p[1], "add") or c.eq(u8, p[1], "update")) {
                if (p.len != 3) return error.SourceFileRequired;
                if (c.eq(u8, p[1], "compile")) return app.compileCommand(p[2]);
                return app.publish(p[2], c.eq(u8, p[1], "update"));
            }
            if (c.eq(u8, p[1], "activate") or c.eq(u8, p[1], "deactivate")) {
                if (p.len != 3) return error.IdentifierRequired;
                try app.args.finish();
                const id = try c.id(app.a, try app.reference("interactions", p[2], false));
                const expected = try c.string((try app.query("getInteractionBundleHash", &.{id})).array.items[0]);
                return app.transaction(try app.cat.find("interactions", "setInteractionActive"), &.{ expected, id, if (c.eq(u8, p[1], "activate")) "true" else "false" });
            }
        }
        if (c.eq(u8, p[0], "id")) {
            if (p.len != 2) return error.IdentifierRequired;
            if (app.args.flag("encrypt")) {
                const scope = app.args.get("scope") orelse return error.LabelScopeRequired;
                const password_file = app.args.get("passphrase-file");
                try app.args.finish();
                return c.print(app.io, "{s}\n", .{try app.labelText(p[1], scope, null, true, password_file)});
            }
            try app.args.finish();
            return c.print(app.io, "{s}\n", .{try c.id(app.a, p[1])});
        }
        if (c.eq(u8, p[0], "accounts") and p.len == 1) {
            try app.args.finish();
            return c.print(app.io, "{s}\n", .{try app.cast.run(&.{ "wallet", "list" })});
        }
        if (c.eq(u8, p[0], "login")) return app.loginCommand(p);
        if (c.eq(u8, p[0], "artifacts")) {
            try app.args.finish();
            if (p.len == 1) return app.printJson(contracts.embedded);
            if (p.len != 2) return error.UnexpectedArgument;
            if (c.eq(u8, p[1], "storage")) return app.printJson(contracts.auxiliary);
            if (c.eq(u8, p[1], "deployment")) return app.printJson(contracts.deployment);
            if (c.eq(u8, p[1], "releases")) return app.printJson(contracts.releases);
            for (c.field(app.cat.root, "contracts").?.array.items) |contract| if (c.eq(u8, try c.string(c.field(contract, "name").?), p[1])) return app.output(c.field(contract, "artifact").?);
            const auxiliary = try contracts.Catalog.loadAuxiliary(app.a);
            for (c.field(auxiliary.root, "contracts").?.array.items) |contract| if (c.eq(u8, try c.string(c.field(contract, "name").?), p[1])) return app.output(c.field(contract, "artifact").?);
            const deployment = try contracts.Catalog.loadDeployment(app.a);
            for (c.field(deployment.root, "contracts").?.array.items) |contract| if (c.eq(u8, try c.string(c.field(contract, "name").?), p[1])) return app.output(c.field(contract, "artifact").?);
            return error.UnknownContract;
        }
        if (c.eq(u8, p[0], "users") and p.len >= 2 and c.eq(u8, p[1], "list")) {
            if (p.len != 2) return error.UnexpectedArgument;
            const offset = try c.word(app.args.get("start") orelse "0");
            const count = try c.word(app.args.get("count") orelse "50");
            if (count > 1000) return error.PageTooLarge;
            try app.args.finish();
            const total = try c.number(app.a, (try app.query("getUserCount", &.{})).array.items[0]);
            var users: std.ArrayList(c.Value) = .empty;
            var i = offset;
            while (i < total and users.items.len < count) : (i += 1) try users.append(app.a, (try app.query("getUserAt", &.{try app.a.print("{d}", .{i})})).array.items[0]);
            return app.output(.{ .total = try app.a.print("{d}", .{total}), .users = users.items });
        }
        try app.generic(p, wants_help);
    }
};

const alias = @import("schema.zig").alias;

fn selected(only: ?[]const u8, name: []const u8) bool {
    var parts = std.mem.splitScalar(u8, only orelse return true, ',');
    while (parts.next()) |part| if (c.eq(u8, part, name)) return true;
    return false;
}

pub fn main(init: std.process.Init) void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    start(init, arena.allocator()) catch |err| {
        var buffer: [1024]u8 = undefined;
        var stderr = std.Io.File.stderr().writerStreaming(init.io, &buffer);
        stderr.interface.print("chainwall: {s}\n", .{errorMessage(err) orelse @errorName(err)}) catch {};
        stderr.interface.writeAll("Use chainwall --help or chainwall <group> <method> --help.\n") catch {};
        stderr.interface.flush() catch {};
        std.process.exit(1);
    };
}
fn errorMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.InvalidSalt => "Use a nonempty salt phrase or 0x followed by exactly 64 hexadecimal digits.",
        error.NoChainlinkNativeFeedPreset => "No reviewed Chainlink native USD preset for this chain. Use the explicit token oracle setters for manual configuration.",
        error.NativeFeedDecimalsMismatch => "The Chainlink feed decimals do not match the reviewed preset.",
        error.NativeFeedAnswerNotPositive => "The Chainlink feed answer must be positive.",
        error.NativeFeedIncompleteRound => "The Chainlink feed round is incomplete.",
        error.NativeFeedInvalidTimestamp => "The Chainlink feed timestamp is zero or in the future.",
        error.NativeFeedStale => "The Chainlink feed exceeds its preset maximum age or the Registry age limit.",
        error.NativeFeedChainChanged => "The chain changed during feed validation. Retry tokens set-chainlink-native-feed; no transaction was submitted.",
        error.NoInitialTerms => "The selected Registry has no initialized initial document.",
        error.TermsDocumentHashMismatch => "The document SHA-256 does not match the onchain terms hash. No document was saved.",
        error.UnsupportedTermsUri => "Terms must use an IPFS URI. Use --document-file FILE to verify a downloaded document against the onchain hash.",
        error.TermsDocumentHttpFailure => "The IPFS gateway did not return a document. Select another --ipfs-gateway URL or use --document-file FILE.",
        error.NoTransactionLogs => "No saved transaction logs. Logs are created when a command submits a transaction.",
        error.TransactionLogNotFound => "Log not found. Use chainwall logs list, then logs show NAME or logs show latest.",
        error.InvalidAccountViewLimit => "Use --count between 1 and 100 and a positive --max-age for account views.",
        error.InvalidActivityBlockRange, error.ActivityRpcLimitNarrowRange, error.ActivityLogLimitNarrowRange => "Narrow the activity range with --from-block and --block, then retry. No partial scan was returned.",
        error.MiniScriptAnalysisFailed => "MiniScript analysis found issues or read-only violations. Inspect the report before publication.",
        error.OperationSimulationFailed, error.PolicySimulationFailed => "Simulation did not pass. Inspect the pinned block, decoded revert, and RPC error in the report.",
        error.TransactionSourceUnavailable => "Some transactions cannot be represented as Lambdascript. Inspect sourceError and compileError in the report; no calls were omitted.",
        error.TransactionHashesRequired => "Use transactions inspect|source HASH [HASH ...], with at most 100 transaction hashes.",
        error.UpgradeSimulationFailed => "Upgrade simulation failed. Inspect simulation.rpcError in the report before retrying.",
        error.IncompatibleUpgradeCandidate => "The candidate failed embedded release verification. Inspect verification.issues in the report.",
        error.UpgradeTargetRequired => "Use --target ADDRESS for the individual OKAccount or AuthAccount proxy.",
        error.ConstructorArgumentsRequired => "Use upgrade releases to inspect the constructor, then supply --constructor-file FILE with JSON arguments.",
        error.BrowserApprovalTimedOut => "Browser approval expired. Run the command again and approve at the printed URL.",
        error.BrowserApprovalRejected => "The browser approval was rejected.",
        error.AppOriginMismatch => "--approval-url and --app-url must use the passkey's configured WebAuthn origin, without a query or fragment.",
        error.ConflictingApprovalUrls => "Use either --approval-url for a standalone page or --app-url for the app.",
        error.BundlerManagesNonce => "--nonce applies to a Foundry gas payer. Remove it when using --bundler-url.",
        error.PaymasterRequiresBundler => "--paymaster requires --bundler-url.",
        error.PaymasterRequiresAuthProfile => "--paymaster requires --auth-profile.",
        error.PaymasterRequiresAccountMode => "--paymaster supports only --via account.",
        error.UserOperationReceiptUnavailable => "A UserOperation was submitted or attempted. Recover its status with chainwall auth receipt HASH --auth-profile FILE --bundler-url URL before resubmitting.",
        error.LabelScopeRequired, error.InvalidLabelScope => "Choose --scope group-id, interaction-id, policy-id, contract-label, user-label, or account-label.",
        error.LabelEntityRequired => "User/account labels require --entity ADDRESS to match the app's authenticated context.",
        error.LabelEntityNotApplicable => "This label scope does not use an entity address.",
        error.InvalidLabelKind => "Choose label kind user, account, safe, or contract.",
        error.EncryptedLabelTooLong => "Encrypted labels allow at most 16 UTF-8 bytes, matching the app.",
        error.InvalidLabelText => "Use a nonempty UTF-8 label without NUL or terminal control characters.",
        error.UnreadableLabel => "Cannot decode this label with the selected secret/history and context. Verify chain, Registry, scope and entity; kv history refreshes cached ancestors.",
        error.PendingRotationUseResume => "A rotation is already saved. Inspect chainwall kv rotation-status, then use chainwall kv rotate --resume.",
        error.NoPendingRotation => "No saved rotation exists. Use chainwall kv rotate to prepare a new rotation.",
        error.StaleKvRotation => "Onchain rotation state differs from the saved attempt. The local secret was not changed; inspect chainwall kv rotation-status.",
        error.KvRotationNotConfirmed => "Rotation proof is incomplete. The recovery record is retained; inspect chainwall kv rotation-status and resume.",
        error.KvOwnerRequired => "The selected transaction signer must own this KV. The saved rotation can be resumed with its owner account.",
        error.RunSyncFirst => "No cached snapshot for this instance. Run chainwall sync first.",
        error.LiveTimelockRequiresPending => "Use chainwall timelock pending for the live pending queue, or chainwall sync --only timelocks to refresh history.",
        error.PassphraseFileRequired => "An interactive terminal is required for hidden input. Use --passphrase-file FILE for automation.",
        error.WrongPassphraseOrCorruptVault => "The passphrase is incorrect or the vault failed authentication.",
        error.SharedSecretAlreadyConfigured => "This profile already has a shared secret. Export it with config export, or use a new profile for a separate secret.",
        error.FundingValueRequired => "Supply a positive --value in wei, or an exact amount such as --value 0.1ether.",
        error.PriceFeedHeartbeatRequired => "Set a positive --feed-max-age for token configuration, or --max-age for feed validation. Otherwise a reviewed onchain heartbeat is required.",
        error.PriceFeedRequired => "A nonzero price feed is required when configuring a heartbeat.",
        error.PriceFeedStale => "The feed sample exceeds its reviewed heartbeat or the Registry's global maximum age. No transaction was submitted.",
        error.InvalidTokenSymbol => "The token symbol is unavailable or invalid. tokens configure accepts an explicit --symbol.",
        error.TokenContractMissing => "Register a deployed contract under this org/id before configuring its token metadata.",
        error.DirectExecutionDeadlineRequired => "Direct execution requires a nonzero future deadline in the input JSON (Unix seconds).",
        error.DirectPolicyRequiresProposal => "This actor cannot satisfy the policy alone. Use operations propose to collect the required approvals.",
        error.DirectExecutionChanged => "Direct execution context or nonce changed. Rebuild the input and collect fresh signatures; no transaction was submitted.",
        error.DirectExecutionCannotUseProposal => "This payload already has an operation ID. Use operations execute for an existing proposal.",
        error.SafeExecutionSimulationFailed => "The Safe returned ExecutionFailure during simulation. No transaction was submitted.",
        error.SafeModuleDisabled => "The Safe's optional OKModule is disabled. Inspect it with safes inspect ADDRESS, or use --via safe to collect owner signatures.",
        error.SafeModuleUnavailable => "No authorized tenant Safe factory provides an OKModule for this Safe. Inspect its registration and factory bindings.",
        error.AmbiguousSafeModule => "Authorized Safe factories disagree on this Safe's module. Resolve the factory configuration before signing.",
        error.InvalidAmount => "Use an exact unsigned amount; native units accept wei, gwei, ether or eth suffixes without spaces.",
        error.UnsupportedSafeImportVersion => "This Safe version is not reviewed for import. Inspection remains available; upgrade it through a supported Safe workflow first.",
        error.KvSecretGenerationRequiresRotation => "This profile is connected to a KV. Use kv rotate to change its secret without losing access to history.",
        error.KvSecretRequired => "Connect this KV with chainwall kv connect ADDRESS --secret-file FILE.",
        error.KvAddressRequired => "Configure operation storage with chainwall kv create or chainwall kv connect ADDRESS --secret-file FILE.",
        error.KvFactoryRequired => "Set kv_factory to a PasswordGatedKVFactory address before chainwall kv create.",
        error.KvRpcUrlRequired => "Set kv_rpc_url or rpc.CHAIN for the configured KV chain.",
        error.EtherscanTokenRequiredForLogs => "This contract has indexing disabled. Set ETHERSCAN_API_KEY or etherscan_api_key_env to sync its logs.",
        error.ChainReorganizedRetrySync => "The chain changed during sync. No checkpoint was advanced; retry chainwall sync.",
        error.ExplorerBlockMismatch => "Explorer logs disagree with the RPC's canonical chain. Retry when the explorer has caught up.",
        error.RpcRejectedRequest => "The RPC rejected a read. Check installed facets and support for EIP-1898 block selectors; the snapshot was not advanced.",
        error.InvalidRpcBatch => "The RPC returned an incomplete or invalid batch response. The snapshot was not advanced.",
        error.RpcUrlRequired => "Set rpc_url in this profile or pass --rpc-url for the selected chain.",
        error.RpcChainMismatch => "The RPC chain ID differs from --chain or the profile's chain.",
        error.RpcPrivacyFilterExcluded => "This endpoint is excluded by the profile's private-only pool. Inspect rpc list, then select an eligible endpoint with rpc use NAME.",
        error.NoHealthyRpcEndpoint => "No eligible endpoint passed chain and canonical-head checks. Inspect rpc list for recent health observations.",
        error.InvalidCommitmentDeadline => "Use a future Unix-seconds deadline no more than 90 days away. Drafts default to seven days; submission checks chain time again.",
        error.CommitmentDeadlineBeforeTimelock => "The reveal deadline does not leave time for the current timelock delay. Prepare a new draft with a later deadline.",
        error.CommitmentRetryRequiresReview => "A submission was already attempted. Inspect commitments status and reconcile its transaction hash before an explicit --retry.",
        error.CommitmentActionPending => "A timelock action already targets this commitment. Inspect commitments status, then execute or cancel that action before continuing.",
        error.CommitmentDraftNotFound => "No saved draft with this hash for the selected chain and Registry. Use commitments list or import an exported draft.",
        error.PrepareNewCommitment => "This draft has already been closed. Prepare a new draft to generate a fresh secret salt.",
        error.AmbiguousCurrentFacet => "Desired selectors belong to several facets. Choose the one being upgraded with --current ADDRESS, or --current none for an explicit installation.",
        error.FacetPlanNotReady => "The plan has unresolved selectors, an unverified target, no changes, or pending diamond actions. Inspect the plan and regenerate it before applying.",
        error.FacetPlanChanged, error.FacetCatalogChanged => "Routing or facet code changed since this plan was reviewed. Generate a new plan and review its selector choices.",
        error.FacetRetryRequiresReview => "A facet submission was already attempted. Reconcile its receipt before retrying explicitly with --retry.",
        error.CheckpointRequiresIndexedSync => "Checkpoint preparation requires an indexed KV and complete signer-key history. Raw journal listing remains available without indexing.",
        error.IncompleteOperationJournal => "The journal contains invalid, unreadable, or missing proposal records. Resolve them before preparing a checkpoint; no records were discarded.",
        error.CheckpointAttemptUncertainUseRetry => "Inspect operations checkpoint inspect ID and the transaction log. Repeat publish ID --retry only after reviewing the unconfirmed write.",
        error.ChainReorganizedPrepareCheckpointAgain => "A block used by this checkpoint is no longer canonical. Prepare a new checkpoint from current history.",
        error.CheckpointPrepareDoesNotBroadcast => "Checkpoint preparation only reads RPC and saves an encrypted local draft. Omit --dry-run; publish ID --dry-run validates publication without broadcasting.",
        error.CheckpointDraftNotFound => "No checkpoint draft with this ID is saved for the configured KV. Use the ID returned by operations checkpoint prepare.",
        error.InvalidCheckpointChunkSize => "Use --chunk-size between 1 and 128 retained proposals per transaction.",
        error.TransactionPreviewRequired => "This result has no prepared transaction envelope. Use a write command with --estimate or transactions estimate FILE with {to,data,value,chainId} (to omitted for deployment).",
        error.EstimateRequiresOuterTransaction => "Passkey calls need their approved outer transaction or UserOperation envelope. Review its gas in the existing browser approval flow; an inner protocol call is not an EOA fee estimate.",
        error.ConflictingFeeOptions => "Choose legacy --gas-price/--legacy or EIP-1559 --max-fee/--priority-fee, without mixing them.",
        error.PriorityFeeExceedsMaximum => "The priority fee exceeds the maximum fee. Set --priority-fee at or below --max-fee.",
        error.MaxFeeBelowCurrentBaseFee => "The fee cap is below the selected block's base fee. Increase --max-fee or estimate again at a newer block.",
        error.GasLimitBelowEstimate => "The configured gas limit is below the RPC estimate. Review the request and increase --gas-limit.",
        error.ChainDoesNotSupportDynamicFees => "This chain's selected block has no base fee. Use --gas-price or --legacy for its fee model.",
        error.BundlerManagesFees => "UserOperation gas and fees are managed in the bundler approval flow. Omit EOA transaction fee options.",
        error.TransactionStillPending => "No successful confirmation was established before the wait ended. Inspect transactions track HASH or resume transactions wait HASH; no transaction was resubmitted.",
        error.TransactionMonitorTimedOut => "The RPC observation exceeded the bounded wait. The submitted hash remains in the transaction log; resume transactions wait HASH.",
        error.TransactionPayloadReplaced => "The original nonce was consumed by a cancellation or different payload. The original operation is not confirmed.",
        error.TransactionSubmissionUncertain => "Foundry returned a transaction hash and then failed. The hash is saved; inspect it before considering another submission.",
        error.TransactionIntentMismatch => "The RPC transaction does not match the saved submission intent. No success was reported; inspect the transaction and RPC endpoint.",
        error.TransactionNotPending => "The original transaction is no longer verifiably pending. Refresh its status before replacing it.",
        error.ReplacementFeeBumpTooSmall => "Both EIP-1559 caps (or the legacy gas price) must satisfy the requested percentage increase. Raise the caps or use the suggested values.",
        error.ReplacementFeeModelMismatch => "Keep the original transaction's fee model when replacing it: legacy gas price or EIP-1559 maximum and priority fees.",
        error.ReplacementNonceMismatch => "A replacement must use the original sender's nonce. Omit --nonce or supply that exact nonce.",
        error.CancellationRequiresPlainEOA => "Cancellation requires a sender with no deployed code. A self-transfer to a delegated or contract account could execute code.",
        error.CancellationRequiresNextNonce => "Cancel the sender's next pending nonce first. Future nonce gaps cannot be cancelled with the empty self-transfer workflow.",
        error.ReplacementRequiresFoundrySigner => "Use the original EOA signer for speed-up or cancellation. AuthAccount/UserOperation replacement is managed by its wallet or bundler.",
        error.InvalidTransactionMonitorOptions => "Use positive confirmations, a timeout of 0..86400 seconds, polling of 1..60 seconds, lookback of 0..1024 blocks, and pages of at most 100 transactions.",
        error.FacetPlanUpdatedInPlace => "Apply and reconcile update the provided plan file; check prints a fresh report. Omit --out.",
        error.SignerRequired => "Select a Foundry signer with --account NAME or config set account NAME.",
        error.ConflictingSigners => "Choose one signer: --account, --keystore, or --unlocked with --from.",
        error.FoundryCastNotInstalled => "Foundry cast is required on PATH.",
        error.EtherscanTokenRequiredOrSupplyAbi => "Set ETHERSCAN_API_KEY or etherscan_api_key_env, or supply --abi org/id=file.json.",
        error.EtherscanRejectedRequest => "Etherscan rejected the request. Check the token, chain support, and rate limit.",
        error.ContractNotVerified => "The explorer has no verified ABI. Supply --abi org/id=file.json.",
        error.InvalidAbiCache => "The ABI cache is invalid. Retry with --refresh-abi.",
        error.UnknownRegistryReference => "An @contract or @token reference is missing from the selected Registry or snapshot.",
        error.MissingAbi => "A call target has no ABI. Supply --abi org/id=file.json or configure Etherscan.",
        error.AmbiguousAbiOverloadAddTypeAnnotation => "Multiple ABI overloads match. Annotate the argument, for example $arg0 :: uint256.",
        error.InteractionExistsUseUpdate => "This interaction already exists. Use interactions update or select another --id.",
        error.InteractionMissingUseAdd => "This interaction does not exist. Use interactions add.",
        error.ExpectedLambdascriptFile => "Lambdascript source must be an individual .ls file.",
        error.UnknownOption => "Unknown or inapplicable option. Check the command's --help.",
        error.NotAChainwallRegistryOrInstance => "Address is neither a Chainwall Registry nor a SafeFactory instance.",
        error.NotAChainwallRegistry => "Address is not a Chainwall Registry.",
        error.NotAChainwallInteract => "Instance does not point to a Chainwall Interact contract.",
        error.UnknownLabelUnlockOrSync => "Unknown @label. Run chainwall sync; for private labels use chainwall completions unlock. Raw IDs always work.",
        error.AmbiguousLabelUseId => "This @label matches multiple records. Use the exact address or ID.",
        error.CompletionSessionAlreadyRunning => "A completion session is already running. Use chainwall completions lock before starting another.",
        error.InvalidCompletionDuration => "--ttl must be 1..86400 seconds; --refresh must be 0..86400 (0 disables refresh).",
        error.CompletionSessionUnavailable => "The completion session did not respond. Retry status or lock; its lifetime is still bounded by --ttl.",
        error.UnknownConfigKey => "Unknown profile setting. Use chainwall config --help for supported keys.",
        error.JsonInputValidationFailed => "Correct the reported field, then retry. Use --schema or schemas show NAME to inspect the expected JSON.",
        error.InvalidJsonInput => "Input must be valid JSON. Correct the file and retry.",
        error.NoJsonInput, error.UnknownJsonInput => "This command has no selected JSON input. Use --edit-input OPTION for an auxiliary JSON file.",
        error.EditorNotFound => "Editor executable not found. Set config set editor hx, --editor COMMAND, VISUAL or EDITOR.",
        error.InvalidEditor => "Use an editor executable with optional quoted arguments, for example hx or 'code --wait'. Shell expansion is not supported.",
        error.EditorCancelled => "Editor canceled. The command was not executed.",
        error.EditorTemplateUnchanged => "The new template was not edited. Fill in the input before continuing.",
        error.EditorRequiresInteractive, error.EditInputRequiresInteractive => "Use --interactive with editor options, or --schema with --edit-input.",
        error.InteractiveJsonRequired => "--interactive edits JSON inputs. Edit Lambdascript source directly in your editor.",
        error.InteractiveCommandArgumentsRequired => "Supply the command's non-file arguments before using --interactive.",
        error.InteractiveAbiTargetRequired => "To edit a local ABI, supply exactly one --abi TARGET=FILE with --edit-input abi.",
        error.InvalidEditorFile => "The editor must save an ordinary file without symbolic or hard links.",
        error.InvalidToml => "Invalid profile TOML. Use quoted scalar values and [rpc] or [instances] tables.",
        error.WrongArgumentCount, error.MissingNamedArgument => "Arguments do not match the ABI. Use this method's --help for names and types.",
        else => null,
    };
}
fn start(init: std.process.Init, a: c.A) !void {
    var iterator = try init.minimal.args.iterateAllocator(a);
    defer iterator.deinit();
    _ = iterator.next();
    var argv: std.ArrayList([]const u8) = .empty;
    while (iterator.next()) |arg| try argv.append(a, arg);
    if (argv.items.len > 0 and c.eq(u8, argv.items[0], "__complete")) {
        const offset: usize = if (argv.items.len > 1 and c.eq(u8, argv.items[1], "--")) 2 else 1;
        completions.run(a, init.io, init.environ_map, argv.items[offset..]) catch {};
        return;
    }
    var args = try Args.parse(a, argv.items);
    const env = init.environ_map;
    const dir = args.get("config-dir") orelse env.get("CHAINWALL_CONFIG_DIR") orelse if (env.get("XDG_CONFIG_HOME")) |xdg| try a.print("{s}/chainwall", .{xdg}) else try a.print("{s}/.config/chainwall", .{env.get("HOME") orelse return error.HomeDirectoryMissing});
    const profile_name = args.get("profile") orelse env.get("CHAINWALL_PROFILE") orelse blk: {
        const active = c.read(a, init.io, try a.print("{s}/active", .{dir})) catch |err| {
            if (err == error.FileNotFound) break :blk "default";
            return err;
        };
        break :blk c.trim(active);
    };
    const profile = try config.load(a, init.io, dir, profile_name);
    const interactive = args.flag("interactive");
    const editor_override = args.get("editor");
    const edit_input = args.get("edit-input");
    if (!interactive and editor_override != null) return error.EditorRequiresInteractive;
    if (!interactive and edit_input != null and json_inputs.peek(args, "schema") == null) return error.EditInputRequiresInteractive;
    var draft: ?@import("editor.zig").Draft = null;
    var command_succeeded = false;
    defer if (draft) |value| value.finish(command_succeeded);
    if (interactive and json_inputs.peek(args, "help") == null and json_inputs.peek(args, "version") == null) {
        if (json_inputs.peek(args, "schema") != null) return error.ConflictingArguments;
        var validator = try json_schema.Validator.init(a);
        const binding = try json_inputs.selected(validator, args, try contracts.Catalog.load(a), edit_input);
        const preferred = editor_override orelse env.get("CHAINWALL_EDITOR") orelse profile.get("editor") orelse env.get("VISUAL") orelse env.get("EDITOR") orelse "vi";
        draft = try @import("editor.zig").edit(&validator, init.io, env, dir, preferred, &args, binding);
    }
    const chain = args.get("chain") orelse env.get("CHAINWALL_CHAIN") orelse profile.get("chain") orelse "ethereum";
    const selected_chain = try config.chainId(chain);
    const rpc_url = args.get("rpc-url") orelse env.get("CHAINWALL_RPC_URL") orelse profile.forChain("rpc.", selected_chain) orelse if (selected_chain == try config.chainId(profile.get("chain") orelse "ethereum")) profile.get("rpc_url") orelse "" else "";
    const instance = args.get("instance") orelse env.get("CHAINWALL_INSTANCE") orelse profile.forChain("instances.", selected_chain) orelse profile.get("instance") orelse "";
    const unlocked = args.flag("unlocked");
    const explicit_account = args.get("account");
    const explicit_keystore = args.get("keystore");
    const account = explicit_account orelse if (unlocked or explicit_keystore != null) null else env.get("CHAINWALL_ACCOUNT") orelse profile.get("account");
    const keystore = explicit_keystore orelse if (unlocked or account != null) null else profile.get("keystore");
    const color = std.meta.stringToEnum(display.Color, args.get("color") orelse "auto") orelse return error.InvalidColorMode;
    var app: App = .{ .a = a, .io = init.io, .env = env, .dir = dir, .profile_name = profile_name, .profile = profile, .cat = try contracts.Catalog.load(a), .cast = .{ .a = a, .io = init.io, .env = env, .rpc = rpc_url, .chain = try config.chainId(chain), .instance = instance, .account = account, .keystore = keystore, .password_file = args.get("password-file") orelse profile.get("password_file"), .from = args.get("from"), .block = args.get("block"), .unlocked = unlocked }, .chain = chain, .json = args.flag("json"), .dry = args.flag("dry-run"), .args = undefined };
    app.color = color;
    if (args.get("schema") != null) {
        const validator = try json_schema.Validator.init(a);
        const binding = try json_inputs.selected(validator, args, app.cat, edit_input);
        return app.output(try validator.document(binding.rule));
    }
    var input_validator = try json_schema.Validator.init(a);
    if (args.positional.len > 0 and c.eq(u8, args.positional[0], "schemas")) {
        const p = args.positional;
        const out = args.get("out");
        if (args.flag("help")) return c.print(init.io, "Usage: chainwall schemas [list|show NAME|template NAME|validate NAME FILE] [--out FILE]\n", .{});
        try args.finish();
        const result = if (p.len == 1 or (p.len == 2 and c.eq(u8, p[1], "list"))) blk: {
            var names = std.json.Array.init(a);
            for (c.field(input_validator.root, "$defs").?.object.keys()) |name| try names.append(.{ .string = name });
            break :blk c.Value{ .array = names };
        } else if (p.len == 3 and c.eq(u8, p[1], "show")) try input_validator.document(try input_validator.schema(p[2])) else if (p.len == 3 and c.eq(u8, p[1], "template")) try json_inputs.template(input_validator, try input_validator.schema(p[2]), 0) else if (p.len == 4 and c.eq(u8, p[1], "validate")) blk: {
            try json_inputs.validateFile(&input_validator, init.io, .{ .name = p[2], .rule = try input_validator.schema(p[2]), .path = p[3] });
            break :blk try c.parse(a, "{\"valid\":true}");
        } else return error.WrongArgumentCount;
        if (out) |path| try c.write(init.io, path, try c.encode(a, result), false);
        command_succeeded = true;
        return app.output(result);
    }
    if (json_inputs.peek(args, "help") == null and json_inputs.peek(args, "version") == null) try json_inputs.preflight(&input_validator, init.io, args, app.cat);
    app.estimate = args.flag("estimate");
    app.dry = app.dry or app.estimate;
    app.cast.no_broadcast = app.dry;
    app.cast.fees = try @import("transaction_fees.zig").Options.parse(&args);
    app.cast.wait_timeout = try rpc.integer(a, .{ .string = args.get("wait-timeout") orelse "120" });
    app.cast.tx_confirmations = try rpc.integer(a, .{ .string = args.get("tx-confirmations") orelse "1" });
    if (app.cast.wait_timeout > 86400 or app.cast.tx_confirmations == 0) return error.InvalidTransactionMonitorOptions;
    app.cast.nonce = try Cast.parseNonce(args.get("nonce"));
    app.auth_browser = .{ .app_url = args.get("app-url"), .page_url = args.get("approval-url"), .open_browser = !args.flag("no-browser"), .timeout_seconds = try std.fmt.parseInt(u32, args.get("approval-timeout") orelse "300", 10) };
    app.bundler_url = args.get("bundler-url");
    app.paymaster = args.get("paymaster");
    if (app.paymaster != null and app.bundler_url == null) return error.PaymasterRequiresBundler;
    if (app.paymaster) |paymaster| {
        try c.address(paymaster);
        if (args.get("auth-profile") == null) return error.PaymasterRequiresAuthProfile;
    }
    try requirePaymasterAccountMode(app.paymaster, args.get("via"));
    if (args.get("auth-profile")) |path| {
        const auth_profile = try json_schema.read(a, init.io, "auth-profile", path);
        try @import("auth_signer.zig").validate(a, auth_profile, selected_chain, instance, false);
        app.cast.auth = .{ .profile = auth_profile, .registry = instance, .bundler = app.bundler_url, .paymaster = app.paymaster, .browser = app.auth_browser };
        if (app.bundler_url != null and app.cast.nonce != null) return error.BundlerManagesNonce;
    }
    app.args = args;
    // Log command names only, never wallet options, RPC URLs, or input arguments.
    const p = args.positional;
    const command = if (p.len > 0 and config.validName(p[0])) p[0] else "transaction";
    const label = if (p.len > 1 and config.validName(p[1])) try a.print("{s}-{s}", .{ command, p[1] }) else command;
    var journal: logs.Journal = .{ .a = a, .io = init.io, .dir = dir, .profile = profile_name, .command = label };
    app.cast.journal = &journal;
    app.run() catch |err| {
        journal.finish(err) catch |log_err| {
            try std.Io.File.stderr().writeStreamingAll(init.io, try a.print("Could not update transaction log: {s}\n", .{@errorName(log_err)}));
        };
        if (journal.path) |path| try std.Io.File.stderr().writeStreamingAll(init.io, try a.print("Log: {s}\n", .{path}));
        if (app.cast.diagnostic) |diagnostic| try std.Io.File.stderr().writeStreamingAll(init.io, diagnostic);
        return err;
    };
    try journal.finish(null);
    if (journal.path) |path| try (if (app.json) std.Io.File.stderr() else std.Io.File.stdout()).writeStreamingAll(init.io, try a.print("Log: {s}\n", .{path}));
    command_succeeded = true;
}

test {
    _ = @import("json_inputs.zig");
    _ = @import("json_schema.zig");
    _ = @import("recipient_journal.zig");
    _ = @import("operation_status.zig");
    _ = @import("completion_session.zig");
    _ = @import("account_views.zig");
    _ = @import("transaction_decode.zig");
    _ = @import("upgrade_actions.zig");
    _ = @import("browser_approval.zig");
    _ = @import("abi_codec.zig");
    _ = @import("store.zig");
    _ = @import("rpc.zig");
    _ = @import("vault.zig");
    _ = @import("kv_rotation.zig");
    _ = @import("config.zig");
    _ = @import("args.zig");
    _ = @import("contracts.zig");
    _ = @import("surface.zig");
    _ = @import("deploy.zig");
    _ = @import("configuration.zig");
    _ = @import("display.zig");
    _ = @import("labels.zig");
}

test "customer paymaster accepts only account execution mode" {
    try requirePaymasterAccountMode(null, "module");
    try requirePaymasterAccountMode("0x1111111111111111111111111111111111111111", null);
    try requirePaymasterAccountMode("0x1111111111111111111111111111111111111111", "account");
    try std.testing.expectError(
        error.PaymasterRequiresAccountMode,
        requirePaymasterAccountMode("0x1111111111111111111111111111111111111111", "safe"),
    );
    try std.testing.expectError(
        error.PaymasterRequiresAccountMode,
        requirePaymasterAccountMode("0x1111111111111111111111111111111111111111", "module"),
    );
}
