// Copyright (C) 2026 OKcontract Pte. Ltd.
const std = @import("std");
const ms = @import("miniscript");
const sql = @import("zqlite");
const c = @import("../cli/common.zig");
const config = @import("../cli/config.zig");
const storage = @import("../cli/store.zig");
const sync = @import("../cli/sync.zig");
const contracts = @import("../cli/contracts.zig");
const rpc = @import("../cli/rpc.zig");
const Explorer = @import("../cli/explorer.zig").Explorer;
const disassembly = @import("../cli/disassembly.zig");
const p = @import("protocol.zig");
const text = @import("text.zig");

pub fn merge(a: c.A, base: c.Value, overlay: c.Value) !c.Value {
    if (overlay != .null and overlay != .object) return error.InvalidLspConfiguration;
    var result: std.json.ObjectMap = if (base == .object) try base.object.clone(a) else .empty;
    if (overlay == .object) for (overlay.object.keys(), overlay.object.values()) |key, v| {
        // LSP options may come from repository-controlled editor settings too.
        // Only startup arguments/environment may select the credential store.
        if (c.eq(u8, key, "configDir")) return error.ConfigDirectoryRequiresStartupOption;
        var known = false;
        for ([_][]const u8{ "profile", "chain", "instance", "rpcUrl", "snapshot", "abis", "settings", "readOnly", "linked" }) |name| if (c.eq(u8, key, name)) {
            known = true;
        };
        if (!known) return error.UnknownLspConfigurationKey;
        try result.put(a, key, v);
    };
    return .{ .object = result };
}
fn option(options: c.Value, name: []const u8) !?[]const u8 {
    const v = p.field(options, name);
    return if (v == .null) null else try p.string(v);
}
fn relative(a: c.A, root: []const u8, value: []const u8) ![]const u8 {
    return std.Io.Dir.path.resolve(a, &.{ root, value });
}
pub fn configDirectory(a: c.A, env: *const std.process.Environ.Map, startup_root: []const u8, flag: ?[]const u8) ![]const u8 {
    // Resolve once, before any workspace folders or client configuration exist.
    // A relative startup path must not select a different store in each folder.
    return relative(a, startup_root, flag orelse env.get("CHAINWALL_CONFIG_DIR") orelse if (env.get("XDG_CONFIG_HOME")) |xdg| try a.print("{s}/chainwall", .{xdg}) else try a.print("{s}/.config/chainwall", .{env.get("HOME") orelse return error.HomeDirectoryMissing}));
}
pub const Selection = struct {
    dir: []const u8,
    profile_name: []const u8,
    profile: config.Profile,
    chain: u64,
    instance: []const u8,
    url: []const u8,
    settings: ms.Settings,
    snapshot: ?[]const u8,
    abis: c.Value,
    root: []const u8,
    analysis_options: @import("../cli/program_analysis.zig").Options = .{},

    pub fn resolve(a: c.A, io: std.Io, env: *const std.process.Environ.Map, dir: []const u8, options: c.Value, root: []const u8) !Selection {
        _ = try merge(a, .null, options);
        const name = (try option(options, "profile")) orelse env.get("CHAINWALL_PROFILE") orelse blk: {
            const active = c.read(a, io, try std.Io.Dir.path.join(a, &.{ dir, "active" })) catch |err| {
                if (err == error.FileNotFound) break :blk "default";
                return err;
            };
            break :blk c.trim(active);
        };
        const profile = try config.load(a, io, dir, name);
        const chain_value = p.field(options, "chain");
        const chain = try config.chainId(if (chain_value != .null) try c.scalar(a, chain_value) else env.get("CHAINWALL_CHAIN") orelse profile.get("chain") orelse "ethereum");
        const instance = (try option(options, "instance")) orelse env.get("CHAINWALL_INSTANCE") orelse profile.forChain("instances.", chain) orelse profile.get("instance") orelse "";
        if (instance.len > 0) try c.address(instance);
        const url = (try option(options, "rpcUrl")) orelse env.get("CHAINWALL_RPC_URL") orelse profile.forChain("rpc.", chain) orelse if (chain == try config.chainId(profile.get("chain") orelse "ethereum")) profile.get("rpc_url") orelse "" else "";
        const raw_settings = p.field(options, "settings");
        // Compiler settings use typed JSON integers, unlike cached onchain
        // records whose arbitrary-size numbers must retain their exact spelling.
        const settings_value = (try std.json.parseFromSlice(c.Value, a, if (raw_settings == .string) try c.read(a, io, try relative(a, root, raw_settings.string)) else try c.encode(a, raw_settings), .{ .allocate = .alloc_always })).value;
        const abis = p.field(options, "abis");
        if (abis != .null and abis != .object) return error.InvalidLspConfiguration;
        for ([_][]const u8{ "readOnly", "linked" }) |name_| {
            const value = p.field(options, name_);
            if (value != .null and value != .bool) return error.InvalidLspConfiguration;
        }
        return .{ .dir = dir, .profile_name = name, .profile = profile, .chain = chain, .instance = try std.ascii.allocLowerString(a, instance), .url = url, .settings = try ms.json.normalize(a, if (settings_value == .null) .{} else try ms.json.settings(c.field(settings_value, "settings") orelse settings_value)), .snapshot = if (try option(options, "snapshot")) |file| try relative(a, root, file) else null, .abis = abis, .root = root, .analysis_options = .{ .read_only = if (p.field(options, "readOnly") == .bool) p.field(options, "readOnly").bool else false, .linked = if (p.field(options, "linked") == .bool) p.field(options, "linked").bool else false } };
    }
    pub fn explorer(s: Selection, a: c.A, io: std.Io, env: *const std.process.Environ.Map) Explorer {
        return .{ .a = a, .io = io, .dir = s.dir, .chain = s.chain, .endpoint = s.profile.get("etherscan_url") orelse "https://api.etherscan.io/v2/api", .api_key = env.get(s.profile.get("etherscan_api_key_env") orelse "ETHERSCAN_API_KEY") orelse s.profile.get("etherscan_api_key") };
    }
};

pub const Entry = struct {
    kind: []const u8,
    hash: []const u8,
    label: []const u8,
    path: ?[]const u8 = null,
    address: ?[]const u8 = null,
    implementation: ?[]const u8 = null,
    record: c.Value = .null,
};
pub const Catalog = struct {
    a: c.A,
    selection: Selection,
    entries: std.ArrayList(Entry) = .empty,
    by_kind: std.StringHashMapUnmanaged(usize) = .empty,
    by_hash: std.StringHashMapUnmanaged(usize) = .empty,
    known: std.json.ObjectMap = .empty,
    abis: std.json.ObjectMap = .empty,
    checkpoints: std.json.ObjectMap = .empty,
    complete_contracts: bool = false,
    complete_tokens: bool = false,
    abi_issues: std.StringArrayHashMapUnmanaged([]const u8) = .empty,

    pub fn load(a: c.A, io: std.Io, selection: Selection) !Catalog {
        var result: Catalog = .{ .a = a, .selection = selection };
        if (selection.instance.len > 0 and selection.snapshot == null) try result.database(io);
        // Snapshot metadata overrides the selected cache explicitly. It is the
        // same format accepted by chainwall compile --snapshot, plus optional
        // named entries for completely offline authoring.
        if (selection.snapshot) |file| {
            const snapshot = try c.parse(a, try c.read(a, io, file));
            if (snapshot != .object) return error.InvalidSnapshot;
            if (c.field(snapshot, "knownKindsByTargetHash")) |known| {
                if (known != .object) return error.InvalidSnapshot;
                result.known = .empty;
                for (known.object.keys(), known.object.values()) |hash, kind| {
                    const name = try p.string(kind);
                    if (!c.eq(u8, name, "contract") and !c.eq(u8, name, "token") and !c.eq(u8, name, "contract+token")) return error.InvalidCatalogKind;
                    const normalized = try c.id(a, hash);
                    if (result.known.contains(normalized)) return error.DuplicateSnapshotTarget;
                    try result.known.put(a, normalized, kind);
                }
                result.complete_contracts = true;
                result.complete_tokens = true;
            }
            // Compiler metadata carries canonical names even without catalog
            // entries, so exported programs can seed offline authoring too.
            if (c.field(snapshot, "registryReferencesByTargetHash")) |refs| {
                var names: disassembly.Metadata = .{ .a = a };
                var input: std.json.ObjectMap = .empty;
                try input.put(a, "registryReferencesByTargetHash", refs);
                try names.merge(.{ .object = input });
                for (names.references.keys(), names.references.values()) |hash, ref| {
                    const path = try p.string(p.field(ref, "path"));
                    try result.add(.{ .kind = try p.string(p.field(ref, "kind")), .hash = hash, .path = path, .label = path });
                }
            }
            if (c.field(snapshot, "entries")) |entries| {
                if (entries != .array) return error.InvalidSnapshot;
                for (entries.array.items) |entry| {
                    const kind = try p.string(p.field(entry, "kind"));
                    const path = try option(entry, "path");
                    const hash = (try option(entry, "hash")) orelse path orelse (try option(entry, "address")) orelse return error.InvalidSnapshot;
                    try result.add(.{ .kind = kind, .hash = hash, .path = path, .label = (try option(entry, "label")) orelse path orelse hash, .address = try option(entry, "address"), .implementation = try option(entry, "implementation"), .record = p.field(entry, "record") });
                }
            }
            if (c.field(snapshot, "abiByTargetHash")) |abis| try result.addAbis(abis);
        }
        for (result.entries.items) |entry| {
            if (result.abis.contains(entry.hash)) continue;
            const address = entry.implementation orelse entry.address orelse continue;
            if (!c.eq(u8, entry.kind, "contract") and !c.eq(u8, entry.kind, "token")) continue;
            var cache: Explorer = .{ .a = a, .io = io, .dir = selection.dir, .chain = selection.chain };
            const cached = cache.cachedAbi(address) catch |err| {
                if (err == error.OutOfMemory) return err;
                try result.abi_issues.put(a, entry.hash, @errorName(err));
                continue;
            };
            if (cached) |abi| try result.abis.put(a, entry.hash, abi);
        }
        if (selection.abis == .object) for (selection.abis.object.keys(), selection.abis.object.values()) |target, file| {
            const input = try c.parse(a, try c.read(a, io, try relative(a, selection.root, try p.string(file))));
            const abi = c.field(input, "abi") orelse input;
            if (abi != .array) return error.InvalidAbi;
            try result.abis.put(a, try c.id(a, target), abi);
        };
        return result;
    }
    fn addAbis(s: *Catalog, abis: c.Value) !void {
        if (abis != .object) return error.InvalidSnapshot;
        for (abis.object.keys(), abis.object.values()) |hash, abi| {
            if (abi != .array) return error.InvalidAbi;
            try s.abis.put(s.a, try c.id(s.a, hash), abi);
        }
    }
    pub fn toSnapshot(s: Catalog) !c.Value {
        var object: std.json.ObjectMap = .empty;
        try object.put(s.a, "knownKindsByTargetHash", .{ .object = s.known });
        try object.put(s.a, "abiByTargetHash", .{ .object = s.abis });
        return .{ .object = object };
    }
    pub fn sourceMetadata(s: Catalog) !disassembly.Metadata {
        var result: disassembly.Metadata = .{ .a = s.a, .known = try s.known.clone(s.a), .abis = try s.abis.clone(s.a) };
        for (s.entries.items) |entry| {
            if (!c.eq(u8, entry.kind, "contract") and !c.eq(u8, entry.kind, "token")) continue;
            const path = entry.path orelse continue;
            result.reference(entry.hash, entry.kind, path) catch |err| {
                if (err == error.OutOfMemory) return err;
                // Records with names outside the surface grammar stay raw.
            };
        }
        return result;
    }
    fn add(s: *Catalog, raw: Entry) !void {
        var entry = raw;
        var known_kind = false;
        for ([_][]const u8{ "contract", "token", "interaction", "user", "safe", "account", "group", "policy", "org" }) |kind| if (c.eq(u8, kind, entry.kind)) {
            known_kind = true;
        };
        if (!known_kind) return error.InvalidCatalogKind;
        const is_address = c.eq(u8, entry.kind, "user") or c.eq(u8, entry.kind, "safe") or c.eq(u8, entry.kind, "account");
        if (is_address) {
            try c.address(entry.hash);
            entry.hash = try std.ascii.allocLowerString(s.a, entry.hash);
            entry.address = entry.hash;
        } else entry.hash = try c.id(s.a, entry.hash);
        if (entry.address) |address| try c.address(address);
        if (entry.implementation) |address| try c.address(address);
        if (entry.path) |path| if (!c.eq(u8, try c.id(s.a, path), entry.hash)) return error.RegistryPathHashMismatch;
        if (c.eq(u8, entry.kind, "contract") or c.eq(u8, entry.kind, "token")) {
            const previous = s.known.get(entry.hash);
            try s.known.put(s.a, entry.hash, .{ .string = if (previous != null and !c.eq(u8, try p.string(previous.?), entry.kind)) "contract+token" else entry.kind });
        }
        const key = try s.a.print("{s}:{s}", .{ entry.kind, entry.hash });
        if (s.by_kind.get(key)) |i| {
            s.entries.items[i] = entry;
            return;
        }
        if (s.entries.items.len >= 10000) return error.CatalogTooLarge;
        try s.by_kind.put(s.a, key, s.entries.items.len);
        if (!s.by_hash.contains(entry.hash)) try s.by_hash.put(s.a, entry.hash, s.entries.items.len);
        try s.entries.append(s.a, entry);
    }
    fn database(s: *Catalog, io: std.Io) !void {
        const file = try s.a.printSentinel("{s}/chainwall.sqlite3", .{s.selection.dir}, 0);
        std.Io.Dir.cwd().access(io, file, .{}) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        // Resolve the directory, as Store.open does (macOS /tmp is a symlink),
        // while still refusing a symlink for the database file itself.
        const real = try std.Io.Dir.cwd().realPathFileAlloc(io, s.selection.dir, s.a);
        const db = try storage.openConnection(try s.a.printSentinel("{s}/chainwall.sqlite3", .{real}, 0), sql.OpenFlags.ReadOnly | sql.OpenFlags.NoFollow | sql.OpenFlags.EXResCode);
        defer db.close();
        try db.busyTimeout(500);
        const store: storage.Store = .{ .a = s.a, .db = db };
        const scope = try storage.scopeKey(s.a, s.selection.chain, s.selection.instance);
        var version = (try db.row("PRAGMA user_version", .{})) orelse return error.InvalidDatabase;
        const schema = version.int(0);
        version.deinit();
        if (schema != 1) return error.UnsupportedDatabaseVersion;
        // One read transaction prevents mixed checkpoints/records during CLI sync.
        try db.execNoArgs("BEGIN");
        defer db.rollback();
        for (sync.datasets) |dataset| {
            const checkpoint = (try store.checkpoint(scope, dataset.name)) orelse continue;
            try s.checkpoints.put(s.a, dataset.name, checkpoint);
            if (c.eq(u8, dataset.name, "contracts")) s.complete_contracts = true;
            if (c.eq(u8, dataset.name, "tokens")) s.complete_tokens = true;
            var rows = try db.rows("SELECT value FROM entries WHERE scope=? AND dataset=? ORDER BY id LIMIT 10001", .{ scope, dataset.name });
            defer rows.deinit();
            while (rows.next()) |row| {
                const v = try c.parse(s.a, row.text(0));
                const kind = if (c.eq(u8, dataset.name, "policies")) "policy" else if (c.eq(u8, dataset.name, "orgs")) "org" else dataset.name[0 .. dataset.name.len - 1];
                const key = if (c.eq(u8, kind, "user")) try p.string(v) else try p.string(p.field(v, "key"));
                const record = p.field(v, "record");
                var entry: Entry = .{ .kind = kind, .hash = key, .label = key, .record = record };
                if (c.eq(u8, kind, "contract") or c.eq(u8, kind, "token")) {
                    const org = try p.string(p.field(record, "org"));
                    const id = try p.string(p.field(record, "id"));
                    entry.path = try s.a.print("{s}/{s}", .{ org, id });
                    entry.label = entry.path.?;
                    if (c.eq(u8, kind, "contract")) {
                        const latest = p.field(record, "latest");
                        const address = try p.string(p.field(latest, "addr"));
                        if (try c.word(address) != 0) entry.address = address;
                        const implementation = try p.string(p.field(latest, "implementation"));
                        if (try c.word(implementation) != 0) entry.implementation = implementation;
                    }
                }
                if (c.eq(u8, kind, "org") and record == .array and record.array.items.len > 0) entry.label = try p.string(record.array.items[0]);
                try s.add(entry);
            }
            if (rows.err) |err| return err;
        }
        // Tokens share their deployment record with contracts of the same hash.
        for (s.entries.items) |*entry| if (c.eq(u8, entry.kind, "token")) {
            if (s.findKind(entry.hash, "contract")) |contract| {
                entry.address = contract.address;
                entry.implementation = contract.implementation;
            }
        };
    }
    pub fn find(s: Catalog, hash: []const u8) ?Entry {
        var buffer: [66]u8 = undefined;
        if (hash.len > buffer.len) return null;
        return s.entries.items[s.by_hash.get(std.ascii.lowerString(&buffer, hash)) orelse return null];
    }
    pub fn findKind(s: Catalog, hash: []const u8, kind: []const u8) ?Entry {
        var lower: [66]u8 = undefined;
        var buffer: [90]u8 = undefined;
        if (hash.len > lower.len) return null;
        const key = std.mem.print(&buffer, "{s}:{s}", .{ kind, std.ascii.lowerString(&lower, hash) }) catch return null;
        return s.entries.items[s.by_kind.get(key) orelse return null];
    }
    pub fn reference(s: Catalog, path: []const u8, token: bool) !?Entry {
        return s.findKind(try c.id(s.a, path), if (token) "token" else "contract");
    }
    pub fn location(s: Catalog, io: std.Io, entry: Entry) !struct { uri: []const u8, range: text.Range } {
        const dir_hash = ms.bytecode.hash(s.selection.root);
        const file = try s.a.print("{s}/lsp/{d}/{s}/{x}/{s}-{s}.json", .{ s.selection.dir, s.selection.chain, if (s.selection.instance.len > 0) s.selection.instance else "offline", dir_hash, entry.kind, entry.hash });
        const body = try c.encode(s.a, entry);
        try c.write(io, file, body, true);
        return .{ .uri = try text.uri(s.a, file), .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 1 } } };
    }
};

/// This is the CLI sync engine, restricted to public Registry data. No signer,
/// vault, passphrase or transaction-sending code is involved in authoring.
pub fn refresh(a: c.A, io: std.Io, env: *const std.process.Environ.Map, selection: Selection) !c.Value {
    var client = try rpc.Rpc.init(a, io, selection.url, selection.chain, selection.instance);
    defer client.deinit();
    try client.pin(null, 0);
    const cat = try contracts.Catalog.load(a);
    const component = (try client.call(try cat.find("registry", "chainwallComponentId"), &.{})).array.items[0];
    if (try c.number(a, component) != ms.bytecode.hash("Chainwall.Registry")) return error.NotAChainwallRegistry;
    const db = try storage.Store.open(a, io, selection.dir);
    defer db.close();
    var staged = try @import("../cli/staging.zig").Stage.open(db, io, selection.dir);
    defer staged.deinit();
    var engine: sync.Engine = .{ .a = a, .db = staged.db, .rpc = &client, .cat = cat, .scope = try storage.scopeKey(a, selection.chain, selection.instance), .explorer = selection.explorer(a, io, env) };
    for (sync.datasets) |dataset| try engine.registry(dataset);
    if (!try client.canonical(client.block)) return error.ChainReorganizedRetrySync;
    try staged.commit();
    return p.json(a, .{ .chainId = selection.chain, .instance = selection.instance, .block = client.block, .rpcRequests = client.requests });
}

test "credential directory uses startup paths and cannot enter LSP options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try std.testing.expectError(error.HomeDirectoryMissing, configDirectory(a, &env, "/startup", null));
    try env.put("HOME", "/home/user");
    try std.testing.expectEqualStrings("/home/user/.config/chainwall", try configDirectory(a, &env, "/startup", null));
    try env.put("XDG_CONFIG_HOME", "xdg");
    try std.testing.expectEqualStrings("/startup/xdg/chainwall", try configDirectory(a, &env, "/startup", null));
    try env.put("CHAINWALL_CONFIG_DIR", "profiles");
    try std.testing.expectEqualStrings("/startup/profiles", try configDirectory(a, &env, "/startup", null));
    try std.testing.expectEqualStrings("/startup/cli", try configDirectory(a, &env, "/startup", "cli"));
    try std.testing.expectEqualStrings("/absolute", try configDirectory(a, &env, "/startup", "/absolute"));
    for ([_][]const u8{ "{\"configDir\":null}", "{\"configDir\":\"profiles\"}", "{\"configDir\":\"/repo/profiles\"}" }) |input|
        try std.testing.expectError(error.ConfigDirectoryRequiresStartupOption, merge(a, .null, try c.parse(a, input)));
}

test "nested LSP compiler settings share strict library validation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    for ([_][]const u8{ "{\"settings\":{\"optimisation\":\"size\"}}", "{\"settings\":{\"settings\":{\"optimisation\":\"size\"}}}" }) |input| {
        try std.testing.expectError(error.InvalidSettings, Selection.resolve(a, std.testing.io, &env, dir, try c.parse(a, input), dir));
    }
}
