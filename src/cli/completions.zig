const std = @import("std");
const c = @import("common.zig");
const schema = @import("schema.zig");
const config = @import("config.zig");
const contracts = @import("contracts.zig");
const help = @import("help.zig");
const labels = @import("labels.zig");
const session = @import("completion_session.zig");

pub const fish = @embedFile("chainwall.fish");
pub const zsh = @embedFile("_chainwall");
pub const Context = struct {
    a: c.A,
    io: std.Io,
    env: *const std.process.Environ.Map,
    positional: std.ArrayList([]const u8) = .empty,
    options: std.StringHashMapUnmanaged([]const u8) = .empty,
    pending: ?[]const u8 = null,
    ended: bool = false,
    current: []const u8,
    prefix: []const u8 = "",
    seen: std.StringHashMapUnmanaged(void) = .empty,

    fn add(ctx: *Context, value: []const u8, description: []const u8) !void {
        if (ctx.seen.count() >= 200) return;
        if (!std.ascii.startsWithIgnoreCase(value, ctx.current) or ctx.seen.contains(value)) return;
        for (value) |ch| if (ch < 32 or ch == 127) return;
        try ctx.seen.put(ctx.a, value, {});
        const desc = try ctx.a.dupe(u8, description);
        for (desc) |*ch| if (ch.* < 32 or ch.* == 127) {
            ch.* = ' ';
        };
        try c.print(ctx.io, "{s}{s}\t{s}\n", .{ ctx.prefix, value, desc });
    }
    fn words(ctx: *Context, values: []const u8, description: []const u8) !void {
        var items = std.mem.tokenizeScalar(u8, values, ' ');
        while (items.next()) |item| try ctx.add(item, description);
    }
    pub fn selection(ctx: Context) !session.Selection {
        const dir = ctx.options.get("config-dir") orelse ctx.env.get("CHAINWALL_CONFIG_DIR") orelse if (ctx.env.get("XDG_CONFIG_HOME")) |xdg| try ctx.a.print("{s}/chainwall", .{xdg}) else try ctx.a.print("{s}/.config/chainwall", .{ctx.env.get("HOME") orelse return error.HomeDirectoryMissing});
        const name = ctx.options.get("profile") orelse ctx.env.get("CHAINWALL_PROFILE") orelse c.trim(c.read(ctx.a, ctx.io, try ctx.a.print("{s}/active", .{dir})) catch "default");
        const profile = try config.load(ctx.a, ctx.io, dir, name);
        const chain = try config.chainId(ctx.options.get("chain") orelse ctx.env.get("CHAINWALL_CHAIN") orelse profile.get("chain") orelse "ethereum");
        const registry = ctx.options.get("instance") orelse ctx.env.get("CHAINWALL_INSTANCE") orelse profile.forChain("instances.", chain) orelse profile.get("instance") orelse "";
        return .{ .dir = dir, .profile = name, .chain = chain, .registry = registry };
    }
    fn profiles(ctx: *Context) !void {
        const selected = try ctx.selection();
        var dir = std.Io.Dir.cwd().openDir(ctx.io, selected.dir, .{ .iterate = true }) catch return;
        defer dir.close(ctx.io);
        var iter = dir.iterate();
        while (try iter.next(ctx.io)) |entry| if (std.mem.endsWith(u8, entry.name, ".toml")) {
            const name = entry.name[0 .. entry.name.len - 5];
            if (config.validName(name)) try ctx.add(name, "Profile");
        };
    }
    fn entities(ctx: *Context, kind: ?[]const u8, type_: []const u8) !void {
        const selected = try ctx.selection();
        const entries = session.entries(ctx.a, ctx.io, selected) catch return;
        const wants_address = c.eq(u8, type_, "address");
        for (entries) |entry| {
            if (kind) |wanted| if (!c.eq(u8, wanted, entry.kind)) continue;
            const id = if (wants_address) entry.address orelse if (entry.id.len == 42) entry.id else continue else if (c.eq(u8, type_, "string")) entry.name orelse entry.label else entry.id;
            const desc = try ctx.a.print("{s}: {s} ({s})", .{ entry.kind, entry.label, id });
            if (id.len > 0) try ctx.add(id, desc);
            if (entry.label.len > 0) {
                const ref = try ctx.a.print("@{s}", .{entry.label});
                _ = labels.resolve(entries, kind, ref, wants_address) catch continue;
                try ctx.add(ref, desc);
            }
        }
    }
    fn files(ctx: *Context, directories: bool) !void {
        try c.print(ctx.io, "{s}\t{s}\t{s}\n", .{ if (directories) "__chainwall_directories__" else "__chainwall_files__", ctx.prefix, ctx.current });
    }
    fn optionValue(ctx: *Context, name: []const u8) !void {
        const spec = schema.option(name);
        if (c.eq(u8, name, "abi")) {
            if (std.mem.indexOfScalar(u8, ctx.current, '=')) |at| {
                ctx.prefix = try std.mem.concat(ctx.a, u8, &.{ ctx.prefix, ctx.current[0 .. at + 1] });
                ctx.current = ctx.current[at + 1 ..];
                return ctx.files(false);
            }
            const entries = session.entries(ctx.a, ctx.io, try ctx.selection()) catch return;
            for (entries) |entry| if (schema.contains("contracts tokens", entry.kind) and entry.org != null and entry.name != null) {
                try ctx.add(try ctx.a.print("{s}/{s}=", .{ entry.org.?, entry.name.? }), "Target ABI file");
            };
            return;
        }
        if (c.eq(u8, name, "id")) return ctx.entities("interactions", "bytes32");
        if (c.eq(u8, name, "token-id")) return ctx.entities("tokens", "bytes32");
        if (c.eq(u8, name, "safe")) return ctx.entities("safes", "address");
        if (c.eq(u8, name, "entity")) return ctx.entities(null, "address");
        if (c.eq(u8, name, "owner") or c.eq(u8, name, "from")) return ctx.entities(null, "address");
        if (c.eq(u8, name, "only")) {
            if (std.mem.lastIndexOfScalar(u8, ctx.current, ',')) |at| {
                ctx.prefix = try std.mem.concat(ctx.a, u8, &.{ ctx.prefix, ctx.current[0 .. at + 1] });
                ctx.current = ctx.current[at + 1 ..];
            }
            return ctx.words(schema.datasets ++ " operations", "Sync dataset");
        }
        switch (spec.argument) {
            .choice => try ctx.words(spec.choices, "Value"),
            .chain => try ctx.words(schema.chains, "Chain"),
            .profile => try ctx.profiles(),
            .file => try ctx.files(false),
            .directory => try ctx.files(true),
            else => if (std.mem.startsWith(u8, name, "arg-")) {
                const m = (try ctx.method()) orelse return;
                for (c.field(m.abi, "inputs").?.array.items) |param| {
                    const param_name = try c.string(c.field(param, "name").?);
                    if (c.eq(u8, name[4..], try c.kebab(ctx.a, param_name))) try ctx.parameter(m, param);
                }
            },
        }
    }
    fn method(ctx: Context) !?contracts.Method {
        const p = ctx.positional.items;
        if (p.len < 2) return null;
        const cat = try contracts.Catalog.load(ctx.a);
        return cat.find(p[0], schema.alias(p[0], p[1])) catch null;
    }
    fn parameter(ctx: *Context, m: contracts.Method, param: c.Value) !void {
        const type_ = try c.string(c.field(param, "type").?);
        if (c.eq(u8, type_, "bool")) return ctx.words("true false", "Boolean");
        if (!c.eq(u8, type_, "address") and !c.eq(u8, type_, "bytes32") and !c.eq(u8, type_, "string")) return;
        const kind = labels.collection(m.group, m.name, try c.string(c.field(param, "name").?));
        if (kind == null and !c.eq(u8, type_, "address")) return;
        try ctx.entities(kind, type_);
    }
    fn flags(ctx: *Context, rows: []const help.Row) !void {
        for (rows) |row| {
            var parts = std.mem.tokenizeAny(u8, row[0], " |,");
            while (parts.next()) |part| {
                if (!std.mem.startsWith(u8, part, "--")) continue;
                if (ctx.options.contains(part[2..]) and !schema.option(part[2..]).repeat) continue;
                try ctx.add(part, row[1]);
            }
        }
    }
    fn complete(ctx: *Context) !void {
        if (ctx.pending) |name| return ctx.optionValue(name);
        const p = ctx.positional.items;
        if (!ctx.ended and std.mem.startsWith(u8, ctx.current, "-")) {
            if (std.mem.startsWith(u8, ctx.current, "--")) if (std.mem.indexOfScalar(u8, ctx.current, '=')) |at| {
                const name = ctx.current[2..at];
                ctx.prefix = ctx.current[0 .. at + 1];
                ctx.current = ctx.current[at + 1 ..];
                return ctx.optionValue(name);
            };
            try ctx.flags(&help.global_options);
            if (p.len > 0) if (try help.commandPage(ctx.a, p)) |page| try ctx.flags(page.options);
            if (try ctx.method()) |m| {
                for (c.field(m.abi, "inputs").?.array.items) |param| {
                    const flag = try ctx.a.print("--arg-{s}", .{try c.kebab(ctx.a, try c.string(c.field(param, "name").?))});
                    if (!ctx.options.contains(flag[2..])) try ctx.add(flag, try contracts.parameter(ctx.a, param));
                }
                if (c.eq(u8, try c.string(c.field(m.abi, "stateMutability").?), "payable")) try ctx.add("--value", "Native value in wei");
            }
            return;
        }
        for (schema.commands) |cmd| {
            var words_ = std.mem.tokenizeScalar(u8, cmd.path, ' ');
            var matched = true;
            for (p) |word| if (!c.eq(u8, words_.next() orelse "", word)) {
                matched = false;
                break;
            };
            if (matched) if (words_.next()) |word| try ctx.add(word, cmd.description);
        }
        if (p.len == 0) return ctx.words(schema.groups, "Registry commands");
        if (p.len == 1 and schema.contains(schema.groups, p[0])) {
            if (schema.contains(schema.datasets, p[0])) try ctx.add("list", "List cached records");
            for (schema.aliases) |entry| if (c.eq(u8, entry[0], p[0])) try ctx.add(entry[1], entry[2]);
            const cat = try contracts.Catalog.load(ctx.a);
            var seen: std.StringHashMapUnmanaged(void) = .empty;
            for (cat.methods) |m| {
                if (!contracts.matchesGroup(m, p[0]) or seen.contains(m.signature)) continue;
                try seen.put(ctx.a, m.signature, {});
                // Ambiguous methods require a signature to select an overload.
                const resolved = cat.find(p[0], m.command) catch null;
                try ctx.add(if (resolved != null) m.command else m.signature, m.signature);
                if (resolved != null) try ctx.add(m.name, m.signature);
            }
        }
        if (c.eq(u8, p[0], "profile") and p.len == 2 and c.eq(u8, p[1], "use")) return ctx.profiles();
        if (c.eq(u8, p[0], "logs") and p.len == 2 and c.eq(u8, p[1], "show")) {
            try ctx.add("latest", "Most recent transaction log");
            const selected = try ctx.selection();
            for (try @import("logs.zig").list(ctx.a, ctx.io, selected.dir)) |entry| try ctx.add(entry.name, "Transaction log");
            return;
        }
        if (c.eq(u8, p[0], "upgrade") and p.len == 2) {
            if (c.eq(u8, p[1], "release")) return ctx.files(false);
            if (schema.contains("deploy inspect verify propose", p[1])) {
                const cat = try contracts.Catalog.loadReleases(ctx.a);
                for (c.field(cat.root, "contracts").?.array.items) |item| {
                    const manifest = c.field(item, "manifest").?;
                    try ctx.add(try c.string(c.field(manifest, "key").?), try c.string(c.field(manifest, "label").?));
                }
                return;
            }
            if (schema.contains("status approve execute cancel", p[1])) return ctx.entities("timelocks", "bytes32");
        }
        if (c.eq(u8, p[0], "labels") and p.len >= 2 and schema.contains("set get clear", p[1])) {
            if (p.len == 2) return ctx.words("user account safe contract", "Label kind");
            if (p.len == 3) {
                const kind = if (c.eq(u8, p[2], "user")) "users" else if (c.eq(u8, p[2], "account")) "accounts" else if (c.eq(u8, p[2], "safe")) "safes" else if (c.eq(u8, p[2], "contract")) "contracts" else return;
                return ctx.entities(kind, if (c.eq(u8, p[2], "contract")) "bytes32" else "address");
            }
        }
        if (p.len == 2 and schema.contains("accounts safes", p[0]) and schema.contains("assets activity", p[1])) return ctx.entities(p[0], "address");
        if (c.eq(u8, p[0], "config") and p.len == 2 and schema.contains("get set unset", p[1])) return ctx.words(schema.config_keys, "Profile setting");
        if (c.eq(u8, p[0], "config") and p.len == 3 and c.eq(u8, p[1], "set") and schema.contains("chain kv_chain", p[2])) return ctx.words(schema.chains, "Chain");
        if (p.len == 3 and c.eq(u8, p[0], "terms") and c.eq(u8, p[1], "governor") and schema.contains("queue execute", p[2])) return ctx.files(false);
        const file = (p.len == 1 and schema.contains("compile decompile disasm analyze", p[0])) or (p.len == 2 and ((c.eq(u8, p[0], "interactions") and schema.contains("add update compile", p[1])) or (c.eq(u8, p[0], "config") and schema.contains("import export", p[1])) or (schema.contains("operations policies", p[0]) and c.eq(u8, p[1], "simulate"))));
        if (file) return ctx.files(false);
        if (p.len == 2 and c.eq(u8, p[0], "interactions") and schema.contains("source activate deactivate", p[1])) return ctx.entities("interactions", "bytes32");
        if (p.len == 1 and c.eq(u8, p[0], "abi")) return ctx.entities("contracts", "address");
        if (try ctx.method()) |m| {
            const params = c.field(m.abi, "inputs").?.array.items;
            if (p.len - 2 < params.len) try ctx.parameter(m, params[p.len - 2]);
        }
    }
};

/// Deliberately accepts an unfinished command line. Never execute the command
/// being completed or run the strict parser on an option awaiting its value.
pub fn run(a: c.A, io: std.Io, env: *const std.process.Environ.Map, words: []const []const u8) !void {
    if (words.len == 0) return;
    var ctx: Context = .{ .a = a, .io = io, .env = env, .current = words[words.len - 1] };
    for (words[0 .. words.len - 1]) |word| {
        if (ctx.pending) |name| {
            try ctx.options.put(a, name, word);
            ctx.pending = null;
        } else if (!ctx.ended and c.eq(u8, word, "--")) {
            ctx.ended = true;
        } else if (!ctx.ended and std.mem.startsWith(u8, word, "--")) {
            const equal = std.mem.indexOfScalar(u8, word, '=');
            const name = word[2..(equal orelse word.len)];
            if (equal) |at| try ctx.options.put(a, name, word[at + 1 ..]) else if (schema.option(name).argument == .none) try ctx.options.put(a, name, "") else {
                ctx.pending = name;
            }
        } else if (!ctx.ended and (c.eq(u8, word, "-h") or c.eq(u8, word, "-V"))) {
            continue;
        } else try ctx.positional.append(a, word);
    }
    try ctx.complete();
}
