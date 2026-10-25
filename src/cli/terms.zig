const std = @import("std");
const c = @import("common.zig");
const abi = @import("abi_codec.zig");
const contracts = @import("contracts.zig");
const rpc = @import("rpc.zig");
const Cast = @import("cast.zig").Cast;
const Args = @import("args.zig").Args;
const Client = @import("contract_client.zig").Client;

fn varint(bytes: []const u8, offset: *usize) !u64 {
    var value: u64 = 0;
    var shift: u6 = 0;
    while (offset.* < bytes.len) {
        const byte = bytes[offset.*];
        offset.* += 1;
        value |= @as(u64, byte & 127) << shift;
        if (byte & 128 == 0) return value;
        if (shift > 49) return error.UnsupportedTermsUri;
        shift += 7;
    }
    return error.UnsupportedTermsUri;
}
fn validateCid(cid: []const u8) !void {
    if (cid.len < 32 or cid.len > 128) return error.UnsupportedTermsUri;
    var bytes: [128]u8 = @splat(0);
    var length: usize = 0;
    const v0 = std.mem.startsWith(u8, cid, "Qm");
    if (v0 or cid[0] == 'z') {
        const alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
        const text = if (v0) cid else cid[1..];
        for (text) |char| {
            var carry: u16 = @intCast(std.mem.indexOfScalar(u8, alphabet, char) orelse return error.UnsupportedTermsUri);
            var i = bytes.len;
            while (i > 0) {
                i -= 1;
                carry += @as(u16, bytes[i]) * 58;
                bytes[i] = @truncate(carry);
                carry >>= 8;
            }
            if (carry != 0) return error.UnsupportedTermsUri;
        }
        var first: usize = 0;
        while (first < bytes.len and bytes[first] == 0) : (first += 1) {}
        length = bytes.len - first;
        std.mem.copyForwards(u8, &bytes, bytes[first..]);
    } else if (cid[0] == 'b') {
        var buffer: u16 = 0;
        var bits: u4 = 0;
        for (cid[1..]) |char| {
            const digit = std.mem.indexOfScalar(u8, "abcdefghijklmnopqrstuvwxyz234567", char) orelse return error.UnsupportedTermsUri;
            buffer = (buffer << 5) | @as(u16, @intCast(digit));
            bits += 5;
            if (bits >= 8) {
                bits -= 8;
                bytes[length] = @truncate(buffer >> bits);
                length += 1;
                buffer &= (@as(u16, 1) << bits) - 1;
            }
        }
        if (bits >= 5 or buffer != 0) return error.UnsupportedTermsUri;
    } else return error.UnsupportedTermsUri;
    var offset: usize = 0;
    const decoded = bytes[0..length];
    if (!v0 and (try varint(decoded, &offset) != 1 or try varint(decoded, &offset) == 0)) return error.UnsupportedTermsUri;
    const code = try varint(decoded, &offset);
    const size = try varint(decoded, &offset);
    if (size == 0 or offset + size != length or (v0 and (code != 18 or size != 32))) return error.UnsupportedTermsUri;
}
fn documentUrl(a: c.A, uri: []const u8, gateway: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, uri, "ipfs://") or uri.len > 4096) return error.UnsupportedTermsUri;
    const path = uri[7..];
    var parts = std.mem.splitScalar(u8, path, '/');
    try validateCid(parts.next() orelse return error.UnsupportedTermsUri);
    while (parts.next()) |part| {
        if (part.len == 0 or c.eq(u8, part, ".") or c.eq(u8, part, "..")) return error.UnsupportedTermsUri;
        for (part) |ch| if (!std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, "-._~", ch) == null) return error.UnsupportedTermsUri;
    }
    const parsed = std.Uri.parse(gateway) catch return error.InvalidIpfsGateway;
    if ((!c.eq(u8, parsed.scheme, "https") and !c.eq(u8, parsed.scheme, "http")) or parsed.host == null or parsed.user != null or parsed.password != null or parsed.query != null or parsed.fragment != null) return error.InvalidIpfsGateway;
    return a.print("{s}/{s}", .{ std.mem.trimEnd(u8, gateway, "/"), path });
}
fn verifiedDocument(cast: *Cast, terms: c.Value, gateway: []const u8, file: ?[]const u8) ![]const u8 {
    const a = cast.a;
    const url = try documentUrl(a, try c.string(c.field(terms, "ipfsUri") orelse return error.InvalidContractResponse), gateway);
    const expected = try abi.unhex(a, try c.string(c.field(terms, "documentHash") orelse return error.InvalidContractResponse));
    if (expected.len != 32 or std.mem.allEqual(u8, expected, 0)) return error.InvalidTermsDocumentHash;
    const document = if (file) |path| try std.Io.Dir.cwd().readFileAlloc(cast.io, path, a, .limited(1024 * 1024)) else blk: {
        var client: std.http.Client = .{ .allocator = a, .io = cast.io };
        defer client.deinit();
        const buffer = try a.alloc(u8, 1024 * 1024);
        var body: std.Io.Writer = .fixed(buffer);
        // A gateway is transport only. Never follow redirects to another host.
        const response = try @import("http.zig").fetch(&client, .{ .location = .{ .url = url }, .response_writer = &body, .redirect_behavior = .unhandled });
        if (response.status != .ok) return error.TermsDocumentHttpFailure;
        break :blk body.buffered();
    };
    // Hash exact bytes before decoding or normalizing whitespace and line endings.
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(document, &digest, .{});
    if (!std.crypto.timing_safe.eql([32]u8, digest, expected[0..32].*)) return error.TermsDocumentHashMismatch;
    if (!std.unicode.utf8ValidateSlice(document)) return error.TermsDocumentNotUtf8;
    return document;
}
fn resolve(remote: *rpc.Rpc, cat: contracts.Catalog, p: []const []const u8) !c.Value {
    if (p.len == 3) return remote.namedAt(remote.address, try cat.find("terms", "getTermsDocument"), &.{.{ .string = p[2] }});
    if (p.len == 4) return c.parse(remote.a, try c.encode(remote.a, .{ .ipfsUri = p[2], .documentHash = p[3] }));
    if (p.len != 2) return error.WrongArgumentCount;
    const context = try remote.namedAt(remote.address, try cat.find("terms", "getTermsContext"), &.{});
    if (c.field(context, "factory")) |factory| if (c.eq(u8, try c.string(factory), "0x0000000000000000000000000000000000000000")) return error.NoInitialTerms;
    return c.field(context, "initialTerms") orelse return error.NoInitialTerms;
}
pub fn inspect(cast: *Cast, cat: contracts.Catalog, args: *Args, p: []const []const u8) !c.Value {
    const gateway = args.get("ipfs-gateway") orelse "https://ipfs.io/ipfs";
    const file = args.get("document-file");
    const out = args.get("out");
    try args.finish();
    var remote = try rpc.Rpc.init(cast.a, cast.io, cast.rpc, cast.chain, cast.instance);
    defer remote.deinit();
    try remote.pin(cast.block, 0);
    const terms = try resolve(&remote, cat, p);
    const document = try verifiedDocument(cast, terms, gateway, file);
    if (!try remote.canonical(remote.block)) return error.ChainReorganizedRetrySync;
    if (out) |path| try c.write(cast.io, path, document, false);
    return c.parse(cast.a, try c.encode(cast.a, .{ .chainId = cast.chain, .registry = cast.instance, .block = remote.block, .terms = terms, .hashAlgorithm = "sha256", .verified = true, .document = document, .file = out }));
}
fn acceptanceInput(a: c.A, io: std.Io, args: *Args, p: []const []const u8) !?c.Value {
    const file = args.get("args-file");
    const hash = args.get("document-hash") orelse args.get("arg-document-hash");
    if (file) |path| {
        if (p.len != 2 or hash != null) return error.ConflictingArguments;
        const value = try c.parse(a, try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024)));
        if (value == .array) {
            if (value.array.items.len != 1) return error.WrongArgumentCount;
            return value.array.items[0];
        }
        if (c.field(value, "ipfsUri") != null) return error.ConflictingArguments;
        return c.field(value, "documentHash") orelse return error.MissingNamedArgument;
    }
    if (hash) |digest| {
        if (p.len != 2) return error.ConflictingArguments;
        return .{ .string = digest };
    }
    if (p.len == 2) return null;
    if (p.len != 3) return error.WrongArgumentCount;
    return .{ .string = p[2] };
}
pub fn accept(cast: *Cast, cat: contracts.Catalog, args: *Args, p: []const []const u8, dry: bool) !c.Value {
    if (cast.block != null and !dry) return error.TransactionRequiresLatestBlock;
    const gateway = args.get("ipfs-gateway") orelse "https://ipfs.io/ipfs";
    const file = args.get("document-file");
    const explicit = try acceptanceInput(cast.a, cast.io, args, p);
    try args.finish();
    var remote = try rpc.Rpc.init(cast.a, cast.io, cast.rpc, cast.chain, cast.instance);
    defer remote.deinit();
    try remote.pin(cast.block, 0);
    const terms = if (explicit) |hash|
        try remote.namedAt(remote.address, try cat.find("terms", "getTermsDocument"), &.{hash})
    else
        try resolve(&remote, cat, p);
    if (explicit) |hash| {
        if (!std.ascii.eqlIgnoreCase(try c.string(hash), try c.string(c.field(terms, "documentHash") orelse return error.InvalidContractResponse))) return error.TermsDocumentHashMismatch;
    }
    _ = try verifiedDocument(cast, terms, gateway, file);
    if (!try remote.canonical(remote.block)) return error.ChainReorganizedRetrySync;
    const client: Client = .{ .cast = cast, .cat = cat, .group = "terms" };
    const result = try client.transaction("acceptTerms", &.{c.field(terms, "documentHash").?}, null, dry);
    return if (dry) result else c.parse(cast.a, try c.encode(cast.a, .{ .status = "confirmed", .receipt = result }));
}

test "IPFS terms URLs validate CIDs and cannot escape the selected gateway" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cid = "bafkreih4un7p7vvitpqypsp7vz6jrgdzqejhzevkpe624wqap2lsulf2ga";
    try std.testing.expectEqualStrings("https://example.test/ipfs/" ++ cid ++ "/terms.md", try documentUrl(a, "ipfs://" ++ cid ++ "/terms.md", "https://example.test/ipfs/"));
    for ([_][]const u8{ "file:///etc/passwd", "https://ipfs.io/ipfs/" ++ cid, "ipns://name", "ipfs://", "ipfs://bafinvalid", "ipfs://" ++ cid ++ "/../secret", "ipfs://" ++ cid ++ "/%2e%2e/secret", "ipfs://" ++ cid ++ "?redirect=1" }) |uri| {
        try std.testing.expectError(error.UnsupportedTermsUri, documentUrl(a, uri, "https://example.test/ipfs"));
    }
    try std.testing.expectError(error.InvalidIpfsGateway, documentUrl(a, "ipfs://" ++ cid, "https://user:password@example.test/ipfs"));
}
