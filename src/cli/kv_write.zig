const std = @import("std");
const ms = @import("miniscript");
const c = @import("common.zig");
const abi = @import("abi_codec.zig");
const vault = @import("vault.zig");
const Client = @import("contract_client.zig").Client;

pub fn write(client: Client, secret: vault.Secret, key: []const u8, plaintext: []const u8, dry: bool) !c.Value {
    const cast = client.cast;
    const a = cast.a;
    const signer = try secret.address(a);
    const current = try c.string(try client.first("passwordSigner", &.{}));
    if (!std.ascii.eqlIgnoreCase(current, signer)) return error.WrongKvSigner;
    const writer = try cast.signerAddress();
    const nonce = try c.number(a, try client.first("nonces", &.{.{ .string = writer }}));
    const domain = try c.number(a, try client.first("domainSeparatorV4", &.{}));
    const encrypted = try secret.encrypt(a, cast.io, plaintext);
    // Sign Write(key, keccak256(ciphertext), writerNonce, writer).
    const words = [_]u256{ ms.bytecode.hash("Write(bytes32 key,bytes32 valueHash,uint256 nonce,address writer)"), try c.word(key), ms.bytecode.hash(encrypted), nonce, try c.word(writer) };
    const signature = try sign(secret, domain, &words);
    return client.transaction("write", &.{ .{ .string = key }, .{ .string = try abi.hex(a, encrypted) }, .{ .string = try abi.hex(a, &signature) } }, null, dry);
}

pub fn sign(secret: vault.Secret, domain: u256, words: []const u256) ![65]u8 {
    var hash = std.crypto.hash.sha3.Keccak256.init(.{});
    for (words) |word| {
        var bytes: [32]u8 = undefined;
        std.mem.writeInt(u256, &bytes, word, .big);
        hash.update(&bytes);
    }
    var struct_hash: [32]u8 = undefined;
    hash.final(&struct_hash);
    var typed: [66]u8 = undefined;
    typed[0..2].* = .{ 0x19, 0x01 };
    std.mem.writeInt(u256, typed[2..34], domain, .big);
    @memcpy(typed[34..66], &struct_hash);
    var digest: [32]u8 = undefined;
    std.mem.writeInt(u256, &digest, ms.bytecode.hash(&typed), .big);
    return secret.sign(digest);
}
