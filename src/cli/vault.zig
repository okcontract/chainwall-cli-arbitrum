const std = @import("std");
const c = @import("common.zig");
const abi = @import("abi_codec.zig");
const Store = @import("store.zig").Store;
const Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
const keccak = std.crypto.hash.sha3.Keccak256;
const Curve = std.crypto.ecc.Secp256k1;

pub const Secret = struct {
    private_key: [32]u8,
    signer: [20]u8,
    encryption_key: [32]u8,

    pub fn init(private_key: [32]u8) !Secret {
        // Ethereum private keys are canonical nonzero secp256k1 scalars.
        try Curve.scalar.rejectNonCanonical(private_key, .big);
        const public_key = (try Curve.basePoint.mul(private_key, .big)).toUncompressedSec1();
        var digest: [32]u8 = undefined;
        keccak.hash(public_key[1..], &digest, .{});
        var result: Secret = .{ .private_key = private_key, .signer = digest[12..].*, .encryption_key = undefined };
        keccak.hash(&private_key, &result.encryption_key, .{});
        return result;
    }
    pub fn deinit(secret: *Secret) void {
        std.crypto.secureZero(u8, std.mem.asBytes(secret));
    }
    pub fn address(secret: Secret, a: c.A) ![]const u8 {
        return abi.hex(a, &secret.signer);
    }
    pub fn decrypt(secret: Secret, a: c.A, envelope: []const u8) ![]u8 {
        // Decode the versioned onchain KV envelope.
        if (envelope.len < 49 or envelope[0] != 1) return error.InvalidKvEnvelope;
        if (!c.eq(u8, envelope[1..21], &secret.signer)) return error.WrongKvSigner;
        const plaintext = try a.alloc(u8, envelope.len - 49);
        errdefer {
            std.crypto.secureZero(u8, plaintext);
            a.free(plaintext);
        }
        try Gcm.decrypt(plaintext, envelope[33 .. envelope.len - 16], envelope[envelope.len - 16 ..][0..16].*, "", envelope[21..33].*, secret.encryption_key);
        return plaintext;
    }
    pub fn encrypt(secret: Secret, a: c.A, io: std.Io, plaintext: []const u8) ![]u8 {
        const envelope = try a.alloc(u8, plaintext.len + 49);
        errdefer a.free(envelope);
        envelope[0] = 1;
        @memcpy(envelope[1..21], &secret.signer);
        try io.randomSecure(envelope[21..33]);
        Gcm.encrypt(envelope[33..][0..plaintext.len], envelope[33 + plaintext.len ..][0..16], plaintext, "", envelope[21..33].*, secret.encryption_key);
        return envelope;
    }
    /// Sign only the shared KV authorization key. User wallets stay in Foundry.
    pub fn sign(secret: Secret, digest: [32]u8) ![65]u8 {
        const Scheme = std.crypto.sign.ecdsa.EcdsaSecp256k1Sha256;
        var pair = try Scheme.KeyPair.fromSecretKey(try Scheme.SecretKey.fromBytes(secret.private_key));
        defer std.crypto.secureZero(u8, std.mem.asBytes(&pair));
        var signature = try pair.signPrehashed(digest, null);
        const order = Curve.scalar.field_order;
        const raw_s = std.mem.readInt(u256, &signature.s, .big);
        if (raw_s > order / 2) std.mem.writeInt(u256, &signature.s, order - raw_s, .big);
        // Recover the nonce point from public quantities to obtain Ethereum's
        // recovery parity without exposing the deterministic signing nonce.
        const Scalar = Curve.scalar.Scalar;
        var reduced: [32]u8 = undefined;
        std.mem.writeInt(u256, &reduced, std.mem.readInt(u256, &digest, .big) % order, .big);
        const inverse = (try Scalar.fromBytes(signature.s, .big)).invert();
        const digest_scalar = (try Scalar.fromBytes(reduced, .big)).mul(inverse);
        const signature_scalar = (try Scalar.fromBytes(signature.r, .big)).mul(inverse);
        const public_key = try Curve.basePoint.mul(secret.private_key, .big);
        const point = (try Curve.mulDoubleBasePublic(Curve.basePoint, digest_scalar.toBytes(.big), public_key, signature_scalar.toBytes(.big), .big)).toUncompressedSec1();
        if (!c.eq(u8, point[1..33], &signature.r)) return error.UnsupportedRecoveryId;
        return signature.toBytes() ++ [_]u8{27 + (point[64] & 1)};
    }
    pub fn rotationKey(secret: Secret, a: c.A) ![]const u8 {
        var hash = keccak.init(.{});
        hash.update("__kv_secret__");
        hash.update(&secret.signer);
        var digest: [32]u8 = undefined;
        hash.final(&digest);
        return abi.hex(a, &digest);
    }
};

pub const Vault = struct {
    a: c.A,
    io: std.Io,
    key: [32]u8,
    db: Store,

    pub fn unlock(a: c.A, io: std.Io, db: Store, password: []const u8, create: bool) !Vault {
        if (password.len == 0) return error.EmptyPassphrase;
        var key: [32]u8 = undefined;
        errdefer std.crypto.secureZero(u8, &key);
        const saved = try db.secret("master.v1");
        if (saved == null and !create) return error.VaultNotInitialized;
        var salt: [16]u8 = undefined;
        if (saved) |bytes| {
            if (bytes.len != 16 + 12 + 32 + 16) return error.InvalidVault;
            salt = bytes[0..16].*;
        } else try io.randomSecure(&salt);
        // Fixed versioned parameters prevent a corrupt DB from requesting
        // unbounded KDF work. 64 MiB, three passes, one Argon2id lane.
        try std.crypto.pwhash.argon2.kdf(a, &key, password, &salt, .{ .t = 3, .m = 65536, .p = 1 }, .argon2id, io);
        var vault: Vault = .{ .a = a, .io = io, .key = key, .db = db };
        if (saved) |bytes| {
            const verification = vault.openBytes("chainwall.vault.master.v1", bytes[16..]) catch return error.WrongPassphraseOrCorruptVault;
            defer std.crypto.secureZero(u8, verification);
            if (!c.eq(u8, verification, &@as([32]u8, @splat(0)))) return error.InvalidVault;
        } else {
            const encrypted = try vault.seal("chainwall.vault.master.v1", &@as([32]u8, @splat(0)));
            try db.putSecret("master.v1", try std.mem.concat(a, u8, &.{ &salt, encrypted }));
        }
        return vault;
    }
    pub fn deinit(v: *Vault) void {
        std.crypto.secureZero(u8, &v.key);
    }
    pub fn seal(v: Vault, context: []const u8, bytes: []const u8) ![]u8 {
        const envelope = try v.a.alloc(u8, 12 + bytes.len + 16);
        errdefer v.a.free(envelope);
        try v.io.randomSecure(envelope[0..12]);
        Gcm.encrypt(envelope[12..][0..bytes.len], envelope[12 + bytes.len ..][0..16], bytes, context, envelope[0..12].*, v.key);
        return envelope;
    }
    pub fn openBytes(v: Vault, context: []const u8, envelope: []const u8) ![]u8 {
        if (envelope.len < 28) return error.InvalidVault;
        const bytes = try v.a.alloc(u8, envelope.len - 28);
        errdefer {
            std.crypto.secureZero(u8, bytes);
            v.a.free(bytes);
        }
        try Gcm.decrypt(bytes, envelope[12 .. envelope.len - 16], envelope[envelope.len - 16 ..][0..16].*, context, envelope[0..12].*, v.key);
        return bytes;
    }
    pub fn put(v: Vault, id: []const u8, bytes: []const u8) !void {
        try v.db.putSecret(id, try v.seal(id, bytes));
    }
    pub fn get(v: Vault, id: []const u8) !?[]u8 {
        return try v.openBytes(id, (try v.db.secret(id)) orelse return null);
    }
    pub fn putHead(v: Vault, scope: []const u8, secret: Secret) !void {
        const id = try v.a.print("kv:{s}:head", .{scope});
        try v.put(id, &secret.private_key);
    }
    pub fn head(v: Vault, scope: []const u8) !Secret {
        const id = try v.a.print("kv:{s}:head", .{scope});
        const raw = (try v.get(id)) orelse return error.KvSecretRequired;
        defer std.crypto.secureZero(u8, raw);
        if (raw.len != 32) return error.InvalidVault;
        return Secret.init(raw[0..32].*);
    }
};

/// Passphrases are never command line values. File input supports automation;
/// interactive input disables terminal echo and restores it on every exit.
pub fn readPassword(a: c.A, io: std.Io, file: ?[]const u8, confirm: bool) ![]u8 {
    if (file) |path| {
        const raw = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4096));
        defer std.crypto.secureZero(u8, raw);
        return a.dupe(u8, std.mem.trimEnd(u8, raw, "\r\n"));
    }
    const first = try prompt(a, io, "Chainwall passphrase: ");
    errdefer std.crypto.secureZero(u8, first);
    if (confirm) {
        const second = try prompt(a, io, "Confirm passphrase: ");
        defer std.crypto.secureZero(u8, second);
        if (!c.eq(u8, first, second)) return error.PassphrasesDoNotMatch;
    }
    return first;
}
fn prompt(a: c.A, io: std.Io, label: []const u8) ![]u8 {
    if (@import("builtin").target.os.tag == .windows) return error.PassphraseFileRequired;
    const stdin = std.Io.File.stdin();
    var term = std.posix.tcgetattr(stdin.handle) catch return error.PassphraseFileRequired;
    const saved = term;
    term.lflag.ECHO = false;
    try std.posix.tcsetattr(stdin.handle, .FLUSH, term);
    defer std.posix.tcsetattr(stdin.handle, .FLUSH, saved) catch {};
    try std.Io.File.stderr().writeStreamingAll(io, label);
    defer std.Io.File.stderr().writeStreamingAll(io, "\n") catch {};
    var buffer: [4096]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);
    var reader = stdin.readerStreaming(io, &buffer);
    const text = try reader.interface.takeDelimiterExclusive('\n');
    return a.dupe(u8, std.mem.trimEnd(u8, text, "\r"));
}

test "vault buffers are released on entropy and authentication failures without an arena" {
    const a = std.testing.allocator;
    var private_key: [32]u8 = @splat(0);
    private_key[31] = 1;
    var secret = try Secret.init(private_key);
    defer secret.deinit();
    try std.testing.expectError(error.EntropyUnavailable, secret.encrypt(a, .failing, "secret"));
    const envelope = try secret.encrypt(a, std.testing.io, "secret");
    defer a.free(envelope);
    const plaintext = try secret.decrypt(a, envelope);
    defer {
        std.crypto.secureZero(u8, plaintext);
        a.free(plaintext);
    }
    try std.testing.expectEqualStrings("secret", plaintext);
    envelope[envelope.len - 1] ^= 1;
    try std.testing.expectError(error.AuthenticationFailed, secret.decrypt(a, envelope));

    // These helpers do not access storage, so no database fixture is needed.
    var v: Vault = .{ .a = a, .io = .failing, .key = @splat(7), .db = undefined };
    defer v.deinit();
    try std.testing.expectError(error.EntropyUnavailable, v.seal("context", "secret"));
    v.io = std.testing.io;
    const sealed = try v.seal("context", "secret");
    defer a.free(sealed);
    const opened = try v.openBytes("context", sealed);
    defer {
        std.crypto.secureZero(u8, opened);
        a.free(opened);
    }
    try std.testing.expectEqualStrings("secret", opened);
    try std.testing.expectError(error.AuthenticationFailed, v.openBytes("wrong context", sealed));
    sealed[sealed.len - 1] ^= 1;
    try std.testing.expectError(error.AuthenticationFailed, v.openBytes("context", sealed));
}

test "Ethereum secret derivation and authenticated local vault contexts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var private_key: [32]u8 = @splat(0);
    private_key[31] = 1;
    var secret = try Secret.init(private_key);
    defer secret.deinit();
    try std.testing.expectEqualStrings("0x7e5f4552091a69125d5dfcb7b8c2659029395bdf", try secret.address(a));
    try std.testing.expectError(error.IdentityElement, Secret.init(@splat(0)));
    const db = try Store.init(a, ":memory:");
    defer db.close();
    var v: Vault = .{ .a = a, .io = std.testing.io, .key = @splat(7), .db = db };
    defer v.deinit();
    try v.put("one", &private_key);
    const encrypted = (try db.secret("one")).?;
    try std.testing.expect(!c.eq(u8, encrypted, &private_key));
    try std.testing.expectError(error.AuthenticationFailed, v.openBytes("two", encrypted));
    try std.testing.expectEqualSlices(u8, &private_key, (try v.get("one")).?);
    encrypted[12] ^= 1;
    try std.testing.expectError(error.AuthenticationFailed, v.openBytes("one", encrypted));
}
