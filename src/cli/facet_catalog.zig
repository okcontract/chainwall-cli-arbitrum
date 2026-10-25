const std = @import("std");
const c = @import("common.zig");
const abi = @import("abi_codec.zig");
const rpc = @import("rpc.zig");
const ms = @import("miniscript");
pub const zero = "0x0000000000000000000000000000000000000000";

pub fn field(value: c.Value, name: []const u8) !c.Value {
    return c.field(value, name) orelse error.InvalidFacetPlan;
}
pub fn string(value: c.Value, name: []const u8) ![]const u8 {
    return c.string(try field(value, name));
}
pub fn same(left: []const u8, right: []const u8) bool {
    return std.ascii.eqlIgnoreCase(left, right);
}
pub fn load(a: c.A) !c.Value {
    return field(try c.parse(a, @embedFile("artifacts/facets.json")), "entries");
}
pub fn find(a: c.A, entries: c.Value, name: []const u8) !c.Value {
    for (entries.array.items) |entry| if (same(name, try string(entry, "key")) or same(name, try string(entry, "contractName")) or same(name, try c.kebab(a, try string(entry, "key")))) return entry;
    return error.UnknownFacetRelease;
}
pub fn publicEntry(a: c.A, entry: c.Value) !c.Value {
    var fields: std.json.ObjectMap = .empty;
    for ([_][]const u8{ "key", "contractName", "friendlyName", "selectors", "creationCodehash", "runtimeCodehash" }) |name| try fields.put(a, name, try field(entry, name));
    try fields.put(a, "requiresDeploymentProof", .{ .bool = (try field(entry, "immutableReferences")).array.items.len > 0 });
    return .{ .object = fields };
}
pub fn code(remote: *rpc.Rpc, address: []const u8) ![]const u8 {
    return @import("releases.zig").codeAt(remote, address);
}
pub fn codehash(a: c.A, data: []const u8) ![]const u8 {
    return c.hex(a, ms.bytecode.hash(try abi.unhex(a, data)));
}
/// Standard CREATE address derivation. Constructor-created dependencies begin
/// with nonce 1 and cannot be substituted with arbitrary immutable pointers.
fn createdAddress(a: c.A, from: []const u8, nonce: u64) ![]const u8 {
    const address = try abi.unhex(a, from);
    if (address.len != 20) return error.InvalidAddress;
    var encoded: [31]u8 = undefined;
    encoded[1] = 0x94;
    @memcpy(encoded[2..22], address);
    var length: usize = 23;
    if (nonce == 0) encoded[22] = 0x80 else if (nonce < 128) encoded[22] = @intCast(nonce) else {
        const size: usize = (64 - @clz(nonce) + 7) / 8;
        encoded[22] = @as(u8, @intCast(size)) + 0x80;
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, nonce, .big);
        @memcpy(encoded[23..][0..size], bytes[8 - size ..]);
        length += size;
    }
    encoded[0] = 0xc0 + @as(u8, @intCast(length - 1));
    return a.print("0x{x:0>40}", .{@as(u160, @truncate(ms.bytecode.hash(encoded[0..length])))});
}
fn deploymentProof(remote: *rpc.Rpc, entry: c.Value, address: []const u8, hash: []const u8) !c.Value {
    const a = remote.a;
    if (hash.len != 66) return error.InvalidFacetDeploymentProof;
    _ = try abi.unhex(a, hash);
    const tx = try remote.one("eth_getTransactionByHash", try abi.array(a, &.{.{ .string = hash }}));
    const receipt = try remote.one("eth_getTransactionReceipt", try abi.array(a, &.{.{ .string = hash }}));
    if (tx == .null or receipt == .null) return error.TransactionReceiptUnavailable;
    if (!same(hash, try string(tx, "hash")) or !same(hash, try string(receipt, "transactionHash")) or try field(tx, "to") != .null or try field(receipt, "to") != .null or !same(try string(tx, "input"), try string(entry, "creationBytecode")) or try c.number(a, try field(tx, "value")) != 0) return error.InvalidFacetDeploymentProof;
    if (try c.number(a, try field(receipt, "status")) != 1 or !same(address, try string(receipt, "contractAddress")) or !same(address, try createdAddress(a, try string(tx, "from"), try rpc.integer(a, try field(tx, "nonce"))))) return error.InvalidFacetDeploymentProof;
    if (c.field(tx, "chainId")) |chain| if (try c.number(a, chain) != remote.chain) return error.RpcChainMismatch;
    const number = try rpc.integer(a, try field(receipt, "blockNumber"));
    if (number > remote.block.number or number != try rpc.integer(a, try field(tx, "blockNumber")) or !same(try string(tx, "blockHash"), try string(receipt, "blockHash"))) return error.InvalidFacetDeploymentProof;
    const block = try remote.blockAt(try rpc.quantity(a, number));
    if (!same(block.hash, try string(receipt, "blockHash")) or !try remote.canonical(block)) return error.TransactionReorganized;
    return c.parse(a, try c.encode(a, .{ .transactionHash = hash, .block = block, .deployer = try field(tx, "from") }));
}
pub fn verify(remote: *rpc.Rpc, entry: c.Value, address: []const u8, proof_hash: ?[]const u8) !c.Value {
    const a = remote.a;
    try c.address(address);
    const runtime = try code(remote, address);
    const references = try field(entry, "immutableReferences");
    const manifest = try c.parse(a, try c.encode(a, .{ .runtimeBytecode = try field(entry, "deployedBytecode"), .immutableReferences = references }));
    const comparison = try @import("releases.zig").runtime(a, manifest, runtime);
    var issues = std.json.Array.init(a);
    if (try field(comparison, "matches") != .bool or !(try field(comparison, "matches")).bool) try issues.append(.{ .string = "artifact-runtime" });
    var proof: c.Value = .null;
    var dependency: c.Value = .null;
    if (proof_hash) |hash| proof = try deploymentProof(remote, entry, address, hash) else if (references.array.items.len > 0) try issues.append(.{ .string = "canonical-deployment-proof-required" });
    if (references.array.items.len > 0 and (try field(comparison, "matches") == .bool and (try field(comparison, "matches")).bool)) {
        // The generated catalog currently has one constructor-bound facet.
        // New immutable patterns require an explicit dependency review.
        if (!c.eq(u8, try string(entry, "key"), "timelock")) return error.UnsupportedFacetImmutables;
        const expected = try createdAddress(a, address, 1);
        const bytes = try abi.unhex(a, runtime);
        for (references.array.items) |reference| {
            const offset = try rpc.integer(a, try field(reference, "start"));
            if (try c.number(a, try field(reference, "length")) != 32 or offset > bytes.len or bytes.len - offset < 32) return error.InvalidFacetArtifact;
            if (std.mem.readInt(u256, bytes[@intCast(offset)..][0..32], .big) != try c.word(expected)) try issues.append(.{ .string = "constructor-dependency-address" });
        }
        const child = try code(remote, expected);
        if (child.len <= 2) try issues.append(.{ .string = "constructor-dependency-missing" });
        dependency = try c.parse(a, try c.encode(a, .{ .address = expected, .codehash = try codehash(a, child) }));
    }
    return c.parse(a, try c.encode(a, .{ .facet = try field(entry, "key"), .address = address, .compatible = issues.items.len == 0, .runtime = comparison, .deploymentProof = proof, .dependency = dependency, .issues = issues.items, .block = remote.block }));
}
