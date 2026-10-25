const std = @import("std");
const ms = @import("miniscript");
const c = @import("common.zig");
const config = @import("config.zig");
const contracts = @import("contracts.zig");
const Surface = @import("surface.zig").Surface;
const Explorer = @import("explorer.zig").Explorer;
const Cast = @import("cast.zig").Cast;
const Args = @import("args.zig").Args;
const disassembly = @import("disassembly.zig");
const storage = @import("store.zig");
const codec = @import("abi_codec.zig");

pub const Compiler = struct {
    a: c.A,
    io: std.Io,
    cat: contracts.Catalog,
    cast: *Cast,
    explorer: Explorer,

    pub fn loadSettings(a: c.A, io: std.Io, args: *Args) !ms.Settings {
        return loadSettingsWithDefaults(a, io, args, .{});
    }
    pub fn loadSettingsWithDefaults(a: c.A, io: std.Io, args: *Args, defaults: ms.Settings) !ms.Settings {
        var settings = if (args.get("settings")) |path| blk: {
            const parsed = try std.json.parseFromSlice(c.Value, a, try c.read(a, io, path), .{ .allocate = .alloc_always });
            var validator = try @import("json_schema.zig").Validator.init(a);
            try validator.require(io, try validator.schema("settings-document"), parsed.value, "settings-document");
            break :blk try ms.json.settings(c.field(parsed.value, "settings") orelse parsed.value);
        } else defaults;
        if (args.get("optimization")) |value| settings.optimization = std.meta.stringToEnum(@FieldType(ms.Settings, "optimization"), value) orelse return error.InvalidOptimization;
        if (args.get("argument-context")) |value| settings.argumentContext = std.meta.stringToEnum(@FieldType(ms.Settings, "argumentContext"), value) orelse return error.InvalidArgumentContext;
        return settings;
    }
    pub fn compile(compiler: *Compiler, path: []const u8, args: *Args) !c.Value {
        if (!std.mem.endsWith(u8, path, ".ls")) return error.ExpectedLambdascriptFile;
        const source = try c.read(compiler.a, compiler.io, path);
        var surface = try Surface.parse(compiler.a, source);
        var settings = try loadSettings(compiler.a, compiler.io, args);
        const skip = args.flag("no-preprocess");
        var snapshot = if (args.get("snapshot")) |snapshot_path| try @import("json_schema.zig").read(compiler.a, compiler.io, "registry-snapshot", snapshot_path) else @as(c.Value, .null);
        var local_abis: std.StringArrayHashMapUnmanaged(c.Value) = .empty;
        for (args.options) |*option| if (c.eq(u8, option.key, "abi")) {
            option.used = true;
            const at = std.mem.indexOfScalar(u8, option.value, '=') orelse return error.AbiRequiresTargetAndFile;
            const key = try c.id(compiler.a, option.value[0..at]);
            const file = try @import("json_schema.zig").read(compiler.a, compiler.io, "abi-document", option.value[at + 1 ..]);
            const abi = c.field(file, "abi") orelse file;
            if (abi != .array) return error.InvalidAbi;
            if (local_abis.contains(key)) return error.DuplicateAbiTarget;
            try local_abis.put(compiler.a, key, abi);
        };
        // Validate all CLI options before fetching metadata or updating caches.
        try args.finish();
        const core = if (skip) source else blk: {
            if (snapshot == .null) {
                var known: std.json.ObjectMap = .empty;
                var abis: std.json.ObjectMap = .empty;
                const targets = try surface.abiTargets();
                for (surface.references) |ref| {
                    const result = if (c.eq(u8, ref.kind, "token")) try compiler.cast.call(try compiler.cat.find("registry", "isTokenByHash"), &.{ref.hash}) else blk2: {
                        const slash = std.mem.indexOfScalar(u8, ref.path, '/').?;
                        break :blk2 try compiler.cast.call(try compiler.cat.find("registry", "contractExists"), &.{ ref.path[0..slash], ref.path[slash + 1 ..] });
                    };
                    if (result != .array or result.array.items.len != 1 or result.array.items[0] != .bool or !result.array.items[0].bool) return error.UnknownRegistryReference;
                    const previous = known.get(ref.hash);
                    try known.put(compiler.a, ref.hash, .{ .string = if (previous != null and !c.eq(u8, try c.string(previous.?), ref.kind)) "contract+token" else ref.kind });
                    if (local_abis.get(ref.hash)) |abi| {
                        try abis.put(compiler.a, ref.hash, abi);
                    } else if (contains(targets, ref.hash) and !abis.contains(ref.hash)) {
                        const record = try compiler.cast.call(try compiler.cat.find("registry", "getContractByHash"), &.{ref.hash});
                        if (record != .array or record.array.items.len != 1 or record.array.items[0] != .array) return error.InvalidContractRecord;
                        const tuple = record.array.items[0].array.items;
                        if (tuple.len != 5 or tuple[4] != .array) return error.InvalidContractRecord;
                        const deployment = tuple[4].array.items;
                        if (deployment.len != 3) return error.InvalidContractRecord;
                        const addr = try c.string(deployment[0]);
                        const implementation = try c.string(deployment[2]);
                        try abis.put(compiler.a, ref.hash, try compiler.explorer.abi(if (try c.word(implementation) != 0) implementation else addr));
                    }
                }
                for (local_abis.keys(), local_abis.values()) |hash, abi| try abis.put(compiler.a, hash, abi);
                var object: std.json.ObjectMap = .empty;
                try object.put(compiler.a, "knownKindsByTargetHash", .{ .object = known });
                try object.put(compiler.a, "abiByTargetHash", .{ .object = abis });
                snapshot = .{ .object = object };
            } else if (local_abis.count() != 0) {
                if (snapshot != .object) return error.InvalidSnapshot;
                var abis = c.field(snapshot, "abiByTargetHash") orelse c.Value{ .object = .empty };
                if (abis != .object) return error.InvalidSnapshot;
                for (local_abis.keys(), local_abis.values()) |hash, abi| try abis.object.put(compiler.a, hash, abi);
                try snapshot.object.put(compiler.a, "abiByTargetHash", abis);
            }
            break :blk try surface.preprocess(snapshot, settings);
        };
        if (!skip) settings = surface.settings;
        var program = try artifact(compiler.a, path, source, core, settings);
        if (!skip) try attachMetadata(compiler.a, &program, surface, snapshot);
        return program;
    }

    pub fn inspect(compiler: *Compiler, bytes: []const u8, program: c.Value, args: *Args) !disassembly.Result {
        const a = compiler.a;
        const defaults = if (c.field(program, "settings")) |value| try ms.json.settings(value) else ms.Settings{};
        const settings = try loadSettingsWithDefaults(a, compiler.io, args, defaults);
        const raw = args.flag("no-preprocess");
        const offline = args.flag("offline");
        const live = args.flag("live");
        if (live and offline) return error.ConflictingArguments;
        const snapshot_path = args.get("snapshot");
        var overrides: std.StringArrayHashMapUnmanaged(c.Value) = .empty;
        for (args.options) |*option| if (c.eq(u8, option.key, "abi")) {
            option.used = true;
            const at = std.mem.indexOfScalar(u8, option.value, '=') orelse return error.AbiRequiresTargetAndFile;
            const key = try c.id(a, option.value[0..at]);
            const document = try @import("json_schema.zig").read(a, compiler.io, "abi-document", option.value[at + 1 ..]);
            const value = c.field(document, "abi") orelse document;
            if (value != .array) return error.InvalidAbi;
            if (overrides.contains(key)) return error.DuplicateAbiTarget;
            try overrides.put(a, key, value);
        };
        try args.finish();
        if (raw) return .{ .source = try ms.syntax.format(a, try ms.decompile(a, bytes, settings), 2), .restored = false };
        var metadata: disassembly.Metadata = .{ .a = a };
        try compiler.cachedMetadata(&metadata);
        // Compiler JSON and explicit snapshots take precedence over local cache.
        try metadata.merge(c.field(program, "metadata") orelse .null);
        if (snapshot_path) |path| try metadata.merge(try @import("json_schema.zig").read(a, compiler.io, "registry-snapshot", path));
        for (overrides.keys(), overrides.values()) |key, value| try metadata.abis.put(a, key, value);
        if (live) {
            const refs = try ms.references.scan(a, bytes);
            for (refs.targets.items) |word| {
                const hash = try c.hex(a, word);
                if (metadata.abis.contains(hash) and metadata.references.contains(hash) and !compiler.explorer.refresh) continue;
                const method = try compiler.cat.find("registry", "getContractByHash");
                const record = try codec.namedResult(a, method.abi, try compiler.cast.call(method, &.{hash}));
                try compiler.contractMetadata(&metadata, hash, record, true, compiler.explorer.refresh and !overrides.contains(hash));
                if (metadata.references.get(hash)) |ref| {
                    if ((try compiler.cast.call(try compiler.cat.find("registry", "isTokenByHash"), &.{hash})).array.items[0].bool)
                        try metadata.reference(hash, "token", try c.string(c.field(ref, "path").?));
                }
            }
        }
        return disassembly.decompile(a, bytes, settings, metadata);
    }

    fn contractMetadata(compiler: *Compiler, metadata: *disassembly.Metadata, hash: []const u8, record: c.Value, live: bool, refresh: bool) !void {
        const a = compiler.a;
        const org = c.string(c.field(record, "org") orelse return) catch return;
        const id = c.string(c.field(record, "id") orelse return) catch return;
        if (org.len == 0 or id.len == 0) return;
        metadata.reference(hash, "contract", try a.print("{s}/{s}", .{ org, id })) catch |err| {
            if (err == error.OutOfMemory) return err;
            return;
        };
        if (metadata.abis.contains(hash) and !refresh) return;
        const latest = c.field(record, "latest") orelse return;
        const implementation = c.string(c.field(latest, "implementation") orelse .null) catch "0x0";
        const address = if (try c.word(implementation) != 0) implementation else try c.string(c.field(latest, "addr") orelse return);
        if (try c.word(address) == 0) return;
        var client = compiler.explorer;
        if (!live) {
            client.api_key = null;
            client.refresh = false;
        }
        const value = client.abi(address) catch |err| {
            if (err == error.OutOfMemory) return err;
            return;
        };
        try metadata.abis.put(a, hash, value);
    }
    fn cachedMetadata(compiler: *Compiler, metadata: *disassembly.Metadata) !void {
        if (compiler.cast.instance.len == 0) return;
        const a = compiler.a;
        const path = try a.print("{s}/chainwall.sqlite3", .{compiler.explorer.dir});
        std.Io.Dir.cwd().access(compiler.io, path, .{}) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        const db = try storage.Store.open(a, compiler.io, compiler.explorer.dir);
        defer db.close();
        try db.db.transaction();
        defer db.db.rollback();
        const scope = try storage.scopeKey(a, compiler.cast.chain, compiler.cast.instance);
        for ([_][]const u8{ "contracts", "tokens" }) |dataset| {
            if (try db.checkpoint(scope, dataset) == null) continue;
            const entries = try db.entries(scope, dataset);
            for (entries.values()) |entry| {
                const hash = try c.string(c.field(entry, "key") orelse continue);
                const record = c.field(entry, "record") orelse continue;
                if (c.eq(u8, dataset, "contracts")) {
                    try compiler.contractMetadata(metadata, hash, record, false, false);
                } else {
                    const org = c.string(c.field(record, "org") orelse continue) catch continue;
                    const id = c.string(c.field(record, "id") orelse continue) catch continue;
                    metadata.reference(hash, "token", try a.print("{s}/{s}", .{ org, id })) catch |err| {
                        if (err == error.OutOfMemory) return err;
                    };
                }
            }
        }
    }
};

pub fn attachMetadata(a: c.A, program: *c.Value, surface: Surface, snapshot: c.Value) !void {
    var metadata: disassembly.Metadata = .{ .a = a };
    try metadata.merge(snapshot);
    for (surface.references) |ref| try metadata.reference(ref.hash, ref.kind, ref.path);
    try program.object.put(a, "metadata", try metadata.snapshot());
}

/// Shared, exact compiler JSON for CLI publication and editor previews.
pub fn artifact(a: c.A, path: []const u8, source: []const u8, core: []const u8, settings: ms.Settings) !c.Value {
    const bytes = try ms.compile(a, core, settings);
    const recovered = try ms.decompile(a, bytes, settings);
    const refs = try ms.references.scan(a, bytes);
    const target_hashes = try a.alloc([]const u8, refs.targets.items.len);
    for (refs.targets.items, target_hashes) |word, *target| target.* = try c.hex(a, word);
    return c.parse(a, try c.encode(a, .{
        .format = "chainwall.program.v1",
        .sourceFile = path,
        .source = source,
        .coreSource = core,
        .bytecode = try ms.bytecode.hex(a, bytes),
        .bytecodeHash = try c.hex(a, ms.bytecode.hash(bytes)),
        .assembly = try ms.disasm(a, bytes),
        .recoveredSource = recovered,
        .settings = .{ .optimization = @tagName(settings.optimization), .argumentContext = @tagName(settings.argumentContext), .@"$validity" = settings.validity, .@"$slippage" = settings.slippage, .forceRecursiveAbi = settings.forceRecursiveAbi, .abiFunctionsByCallKey = settings.abiFunctionsByCallKey, .knownResolvableHashes = settings.knownResolvableHashes, .addressArgResolutionsByWriteKey = settings.addressArgResolutionsByWriteKey },
        .references = .{ .targets = target_hashes, .complete = refs.complete, .rawCount = refs.raw_count },
        .analysis = try @import("program_analysis.zig").analyze(a, bytes, .{}),
    }));
}

fn contains(values: []const []const u8, value: []const u8) bool {
    for (values) |entry| if (c.eq(u8, entry, value)) return true;
    return false;
}
pub fn explorer(a: c.A, io: std.Io, env: *const std.process.Environ.Map, profile: config.Profile, dir: []const u8, chain: u64, args: *Args) Explorer {
    return .{ .a = a, .io = io, .dir = dir, .chain = chain, .refresh = args.flag("refresh-abi"), .endpoint = args.get("etherscan-url") orelse profile.get("etherscan_url") orelse "https://api.etherscan.io/v2/api", .api_key = env.get(profile.get("etherscan_api_key_env") orelse "ETHERSCAN_API_KEY") orelse profile.get("etherscan_api_key") };
}
