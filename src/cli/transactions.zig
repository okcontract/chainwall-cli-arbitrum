const std = @import("std");
const c = @import("common.zig");
const ms = @import("miniscript");
const abi = @import("abi_codec.zig");
const rpc = @import("rpc.zig");
const contracts = @import("contracts.zig");
const decode = @import("transaction_decode.zig");
const storage = @import("store.zig");
const programs = @import("programs.zig");
const Metadata = @import("disassembly.zig").Metadata;
const Cast = @import("cast.zig").Cast;
const Args = @import("args.zig").Args;

const Context = struct {
    cast: *Cast,
    cat: contracts.Catalog,
    explorer: @import("explorer.zig").Explorer,
    abis: std.StringHashMapUnmanaged(c.Value) = .empty,
    records: std.StringArrayHashMapUnmanaged(c.Value) = .empty,
    metadata: Metadata,
    warnings: std.json.Array,
    chain_name: []const u8,

    fn warn(ctx: *Context, message: []const u8) !void {
        for (ctx.warnings.items) |item| if (c.eq(u8, item.string, message)) return;
        try ctx.warnings.append(.{ .string = message });
    }
    fn loadRecords(ctx: *Context) !void {
        if (ctx.cast.instance.len == 0) return;
        const a = ctx.cast.a;
        const path = try a.print("{s}/chainwall.sqlite3", .{ctx.explorer.dir});
        std.Io.Dir.cwd().access(ctx.cast.io, path, .{}) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        const db = try storage.Store.openReadOnly(a, ctx.cast.io, ctx.explorer.dir);
        defer db.close();
        const scope = try storage.scopeKey(a, ctx.cast.chain, ctx.cast.instance);
        try db.db.transaction();
        defer db.db.rollback();
        if (try db.checkpoint(scope, "contracts") != null) ctx.records = try db.entries(scope, "contracts");
    }
    fn contract(ctx: *Context, address: []const u8) !?struct { hash: []const u8, path: ?[]const u8 } {
        const a = ctx.cast.a;
        for (ctx.records.values()) |entry| {
            const record = c.field(entry, "record") orelse continue;
            const latest = c.field(record, "latest") orelse continue;
            const known = c.string(c.field(latest, "addr") orelse continue) catch continue;
            if (!std.ascii.eqlIgnoreCase(address, known)) continue;
            const hash = try c.id(a, try c.string(c.field(entry, "key") orelse continue));
            const path = try a.print("{s}/{s}", .{ c.string(c.field(record, "org") orelse .null) catch "", c.string(c.field(record, "id") orelse .null) catch "" });
            var usable = true;
            ctx.metadata.reference(hash, "contract", path) catch |err| {
                if (err == error.OutOfMemory) return err;
                usable = false;
            };
            try ctx.warn("Registry references use the selected tenant's cached contract catalog. Review their current deployment before publishing.");
            return .{ .hash = hash, .path = if (usable) path else null };
        }
        return null;
    }
    fn abiAt(ctx: *Context, address: []const u8) !c.Value {
        const a = ctx.cast.a;
        const key = try std.ascii.allocLowerString(a, address);
        if (ctx.abis.get(key)) |value| return value;
        const value = if (std.ascii.eqlIgnoreCase(address, ctx.cast.instance)) blk: {
            var all = std.json.Array.init(a);
            for (c.field(ctx.cat.root, "contracts").?.array.items) |item| try all.appendSlice(c.field(c.field(item, "artifact").?, "abi").?.array.items);
            break :blk c.Value{ .array = all };
        } else ctx.explorer.abi(address) catch |err| blk: {
            if (err == error.OutOfMemory) return err;
            try ctx.warn(try a.print("ABI unavailable for {s}: {s}", .{ address, @errorName(err) }));
            break :blk c.Value.null;
        };
        if (value != .null) decode.validate(a, value) catch |err| {
            if (err == error.OutOfMemory) return err;
            try ctx.warn(try a.print("ABI unavailable for {s}: InvalidAbi", .{address}));
            try ctx.abis.put(a, key, .null);
            return .null;
        };
        try ctx.abis.put(a, key, value);
        return value;
    }
};

fn checksum(a: c.A, address: []const u8) ![]const u8 {
    try c.address(address);
    const result = try std.ascii.allocLowerString(a, address);
    const hash = try c.hex(a, ms.bytecode.hash(result[2..]));
    for (result[2..], hash[2..42]) |*ch, digit| if ((std.fmt.charToDigit(digit, 16) catch unreachable) >= 8) {
        ch.* = std.ascii.toUpper(ch.*);
    };
    return result;
}

fn argument(ctx: *Context, param: c.Value, value: c.Value) anyerror![]const u8 {
    const a = ctx.cast.a;
    const type_ = try c.string(c.field(param, "type").?);
    if (std.mem.endsWith(u8, type_, "]")) {
        var child = param;
        child.object = try param.object.clone(a);
        try child.object.put(a, "type", .{ .string = type_[0..std.mem.lastIndexOfScalar(u8, type_, '[').?] });
        var values: std.ArrayList([]const u8) = .empty;
        for (value.array.items) |element| try values.append(a, try argument(ctx, child, element));
        return a.print("[{s}]", .{try std.mem.join(a, ", ", values.items)});
    }
    if (c.eq(u8, type_, "tuple")) {
        var values: std.ArrayList([]const u8) = .empty;
        for (c.field(param, "components").?.array.items, value.array.items) |child, element| try values.append(a, try argument(ctx, child, element));
        return a.print("{{{s}}}", .{try std.mem.join(a, ", ", values.items)});
    }
    if (c.eq(u8, type_, "address")) {
        if (try ctx.contract(try c.string(value))) |known| return a.print("$address({s})", .{known.hash});
    }
    if (c.eq(u8, type_, "string") or std.mem.startsWith(u8, type_, "bytes") or c.eq(u8, type_, "function")) {
        // Lambdascript byte strings use their exact escaped bytes. JSON string
        // escaping is also the parser's string literal syntax.
        return c.encode(a, value);
    }
    return c.scalar(a, value);
}

fn generate(ctx: *Context, tx: c.Value, decoded: c.Value, methods: *std.json.ObjectMap) !c.Value {
    const a = ctx.cast.a;
    const to = c.field(tx, "to") orelse .null;
    if (to == .null) return error.ContractCreationHasNoCallTarget;
    const address = try c.string(to);
    const input = try abi.unhex(a, try c.string(c.field(tx, "input").?));
    if (input.len < 4) return error.TransactionHasNoFunctionSelector;
    const selector = try abi.hex(a, input[0..4]);
    const known = try ctx.contract(address);
    const query = try a.print("@{s}/{s}", .{ ctx.chain_name, try checksum(a, address) });
    const target_hash = if (known) |record| record.hash else try c.hex(a, ms.bytecode.hash(query));
    const target_source = if (known) |record| if (record.path) |path| try a.print("@contract({s})", .{path}) else record.hash else try a.print("$address({s})", .{try c.encode(a, query)});
    if (known == null) try ctx.warn("Direct address targets use the app's @chain/address identifiers. Register or resolve these identifiers before executing the program.");
    var values: std.ArrayList([]const u8) = .empty;
    const value = try c.number(a, c.field(tx, "value") orelse c.Value{ .string = "0x0" });
    var payable = value > 0;
    if (decoded != .null) {
        if (!c.field(decoded, "canonical").?.bool) return error.NonCanonicalTransactionCalldata;
        const method = c.field(decoded, "abi").?;
        const mutability = try c.string(c.field(method, "stateMutability").?);
        if (c.eq(u8, mutability, "view") or c.eq(u8, mutability, "pure")) return error.ReadOnlyTransactionCannotBeReplayedAsWrite;
        payable = c.eq(u8, mutability, "payable");
        if (value > 0 and !payable) return error.NonpayableCallValue;
        const key = try a.print("{s}:{s}", .{ target_hash, selector });
        if (methods.get(key)) |previous| {
            if (!c.eq(u8, try c.encode(a, previous), try c.encode(a, method))) return error.AbiSelectorCollision;
        } else try methods.put(a, key, method);
        for (c.field(method, "inputs").?.array.items, c.field(decoded, "args").?.array.items) |param, v| try values.append(a, try argument(ctx, param, v));
        var target_abi = ctx.metadata.abis.get(target_hash) orelse try abi.array(a, &.{});
        try target_abi.array.append(method);
        try ctx.metadata.abis.put(a, target_hash, target_abi);
    } else {
        if ((input.len - 4) % 32 != 0) return error.CalldataRequiresAbi;
        var at: usize = 4;
        while (at < input.len) : (at += 32) try values.append(a, try abi.hex(a, input[at..][0..32]));
        try ctx.warn("An undecoded call uses exact raw calldata words. Dynamic offsets are fixed; obtain its ABI before changing arguments.");
    }
    const value_source = if (payable) try a.print(", {d}", .{value}) else "";
    return c.parse(a, try c.encode(a, .{ .source = try a.print("$write({s}, {s}, {{{s}}}{s})", .{ target_source, selector, try std.mem.join(a, ", ", values.items), value_source }), .target = .{ .hash = target_hash, .address = address, .registryBacked = known != null, .query = if (known == null) c.Value{ .string = query } else c.Value.null } }));
}

fn inspect(ctx: *Context, remote: *rpc.Rpc, hash: []const u8, methods: *std.json.ObjectMap) !c.Value {
    const a = ctx.cast.a;
    if (hash.len != 66) return error.InvalidTransactionHash;
    const hash_bytes = try abi.unhex(a, hash);
    if (hash_bytes.len != 32) return error.InvalidTransactionHash;
    const params = try abi.array(a, &.{.{ .string = hash }});
    const values = try remote.batch(&.{ .{ .method = "eth_getTransactionByHash", .params = params }, .{ .method = "eth_getTransactionReceipt", .params = params } });
    const tx = values[0];
    const receipt = values[1];
    if (tx == .null) return error.TransactionNotFound;
    if (!std.ascii.eqlIgnoreCase(try c.string(c.field(tx, "hash") orelse return error.InvalidTransactionResponse), hash)) return error.InvalidTransactionResponse;
    var block: ?rpc.Block = null;
    if (receipt != .null) {
        if (!std.ascii.eqlIgnoreCase(try c.string(c.field(receipt, "transactionHash") orelse return error.InvalidTransactionResponse), hash)) return error.InvalidTransactionResponse;
        const number = try rpc.integer(a, c.field(receipt, "blockNumber") orelse return error.InvalidTransactionResponse);
        if (number != try rpc.integer(a, c.field(tx, "blockNumber") orelse return error.InvalidTransactionResponse)) return error.InvalidTransactionResponse;
        block = try remote.blockAt(try rpc.quantity(a, number));
        for ([_]c.Value{ tx, receipt }) |item| if (!std.ascii.eqlIgnoreCase(try c.string(c.field(item, "blockHash") orelse return error.InvalidTransactionResponse), block.?.hash)) return error.TransactionReorganized;
    } else if ((c.field(tx, "blockHash") orelse c.Value.null) != .null) return error.TransactionReceiptUnavailable;
    const to = c.field(tx, "to") orelse c.Value.null;
    var failure: ?[]const u8 = null;
    const decoded = if (to == .string) decode.call(a, try ctx.abiAt(to.string), try c.string(c.field(tx, "input").?)) catch |err| blk: {
        if (err == error.OutOfMemory) return err;
        failure = @errorName(err);
        break :blk c.Value.null;
    } else c.Value.null;
    var logs = std.json.Array.init(a);
    if (c.field(receipt, "logs")) |items| for (items.array.items) |log| {
        if (!std.ascii.eqlIgnoreCase(try c.string(c.field(log, "transactionHash") orelse return error.InvalidTransactionResponse), hash) or !std.ascii.eqlIgnoreCase(try c.string(c.field(log, "blockHash") orelse return error.InvalidTransactionResponse), block.?.hash) or try rpc.integer(a, c.field(log, "blockNumber") orelse return error.InvalidTransactionResponse) != block.?.number or (c.field(log, "removed") orelse c.Value{ .bool = false }).bool) return error.TransactionReorganized;
        var log_failure: ?[]const u8 = null;
        const event = decode.event(a, try ctx.abiAt(try c.string(c.field(log, "address").?)), log) catch |err| blk: {
            if (err == error.OutOfMemory) return err;
            log_failure = @errorName(err);
            break :blk c.Value.null;
        };
        try logs.append(try c.parse(a, try c.encode(a, .{ .raw = log, .decoded = event, .decodeError = log_failure })));
    };
    var source_error: ?[]const u8 = failure;
    const generated = if (failure == null) generate(ctx, tx, decoded, methods) catch |err| blk: {
        if (err == error.OutOfMemory) return err;
        source_error = @errorName(err);
        break :blk c.Value.null;
    } else c.Value.null;
    if (block) |anchor| if (!try remote.canonical(anchor)) return error.TransactionReorganized;
    return c.parse(a, try c.encode(a, .{ .transaction = tx, .receipt = receipt, .block = block, .status = if (receipt == .null) "pending" else if (try c.number(a, c.field(receipt, "status").?) == 1) "success" else "reverted", .call = decoded, .decodeError = failure, .logs = logs.items, .generated = generated, .sourceError = source_error }));
}

fn compile(ctx: *Context, methods: std.json.ObjectMap, sources: []const []const u8) !c.Value {
    const a = ctx.cast.a;
    const source = if (sources.len == 1) sources[0] else try a.print("{{{s}}}", .{try std.mem.join(a, ", ", sources)});
    var surface = try @import("surface.zig").Surface.parse(a, source);
    const snapshot = try ctx.metadata.snapshot();
    const core = try surface.preprocess(snapshot, .{ .abiFunctionsByCallKey = .{ .object = methods } });
    var program = try programs.artifact(a, "transactions", try ms.syntax.format(a, source, 2), core, surface.settings);
    try programs.attachMetadata(a, &program, surface, snapshot);
    return program;
}

pub fn run(cast: *Cast, cat: contracts.Catalog, explorer: @import("explorer.zig").Explorer, chain_name: []const u8, args: *Args, hashes: []const []const u8) !c.Value {
    if (hashes.len == 0 or hashes.len > 100) return error.TransactionHashesRequired;
    if (cast.block != null) return error.TransactionHashSelectsBlock;
    const a = cast.a;
    var ctx: Context = .{ .cast = cast, .cat = cat, .explorer = explorer, .metadata = .{ .a = a }, .warnings = std.json.Array.init(a), .chain_name = chain_name };
    for (args.options) |*option| if (c.eq(u8, option.key, "abi") and !option.used) {
        option.used = true;
        const at = std.mem.indexOfScalar(u8, option.value, '=') orelse return error.AbiRequiresTargetAndFile;
        const address = try std.ascii.allocLowerString(a, option.value[0..at]);
        try c.address(address);
        if (ctx.abis.contains(address)) return error.DuplicateAbiTarget;
        const file = try @import("json_schema.zig").read(a, cast.io, "abi-document", option.value[at + 1 ..]);
        const value = c.field(file, "abi") orelse file;
        try decode.validate(a, value);
        try ctx.abis.put(a, address, value);
    };
    if (args.flag("offline")) {
        ctx.explorer.api_key = null;
        ctx.explorer.refresh = false;
    }
    try args.finish();
    try ctx.loadRecords();
    var remote = try rpc.Rpc.initEndpoint(a, cast.io, cast.rpc, cast.chain);
    defer remote.deinit();
    if (try rpc.integer(a, try remote.one("eth_chainId", try abi.array(a, &.{}))) != cast.chain) return error.RpcChainMismatch;
    var items = std.json.Array.init(a);
    var methods: std.json.ObjectMap = .empty;
    var sources: std.ArrayList([]const u8) = .empty;
    for (hashes) |hash| {
        const result = try inspect(&ctx, &remote, hash, &methods);
        try items.append(result);
        if (c.field(result, "generated").? != .null) try sources.append(a, try c.string(c.field(c.field(result, "generated").?, "source").?));
    }
    var program: c.Value = .null;
    var compile_error: ?[]const u8 = null;
    if (sources.items.len == items.items.len) {
        program = compile(&ctx, methods, sources.items) catch |err| blk: {
            if (err == error.OutOfMemory) return err;
            compile_error = @errorName(err);
            break :blk c.Value.null;
        };
    }
    return c.parse(a, try c.encode(a, .{ .chainId = cast.chain, .transactions = items.items, .program = program, .compileError = compile_error, .warnings = ctx.warnings.items }));
}
