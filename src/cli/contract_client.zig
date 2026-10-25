const std = @import("std");
const c = @import("common.zig");
const abi = @import("abi_codec.zig");
const contracts = @import("contracts.zig");
const Cast = @import("cast.zig").Cast;

/// A scoped contract target, preserving the selected signer and nonce sequence.
pub const Client = struct {
    cast: *Cast,
    cat: contracts.Catalog,
    group: []const u8,

    pub fn call(self: Client, name: []const u8, values: []const c.Value) !c.Value {
        const method = try self.cat.find(self.group, name);
        const saved = self.cast.json_values;
        defer self.cast.json_values = saved;
        self.cast.json_values = try abi.array(self.cast.a, values);
        const args = try self.cast.a.alloc([]const u8, values.len);
        @memset(args, "");
        return self.cast.call(method, args);
    }
    pub fn first(self: Client, name: []const u8, values: []const c.Value) !c.Value {
        const result = try self.call(name, values);
        if (result != .array or result.array.items.len == 0) return error.InvalidContractResponse;
        return result.array.items[0];
    }
    pub fn data(self: Client, name: []const u8, values: []const c.Value) ![]const u8 {
        return abi.calldata(self.cast.a, (try self.cat.find(self.group, name)).abi, try abi.array(self.cast.a, values));
    }
    pub fn transaction(self: Client, name: []const u8, values: []const c.Value, value: ?[]const u8, dry: bool) !c.Value {
        const bytes = try self.data(name, values);
        if (dry) {
            var tx = try c.parse(self.cast.a, try c.encode(self.cast.a, .{ .chainId = self.cast.chain, .to = self.cast.instance, .function = (try self.cat.find(self.group, name)).signature, .data = bytes, .value = value orelse "0", .nonce = self.cast.nonce }));
            try self.cast.fees.overlay(self.cast.a, &tx);
            return tx;
        }
        if (self.cast.block != null) return error.TransactionRequiresLatestBlock;
        return self.cast.send(bytes, value);
    }
    pub fn boundInteract(self: Client, registry: []const u8) !void {
        if (!std.ascii.eqlIgnoreCase(try c.string(try self.first("registry", &.{})), registry)) return error.InteractRegistryMismatch;
    }
};
