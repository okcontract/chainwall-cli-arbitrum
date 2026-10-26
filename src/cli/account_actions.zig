const std = @import("std");
const ms = @import("miniscript");
const c = @import("common.zig");
const abi = @import("abi_codec.zig");
const contracts = @import("contracts.zig");
const Client = @import("contract_client.zig").Client;
const Args = @import("args.zig").Args;
const safe_tx = @import("safe_transactions.zig");
const zero = "0x0000000000000000000000000000000000000000";
const sentinel = "0x0000000000000000000000000000000000000001";

fn field(value: c.Value, name: []const u8) !c.Value {
    return c.field(value, name) orelse error.InvalidAccountConfiguration;
}
fn equal(a: c.A, left: c.Value, right: c.Value) !bool {
    return try c.number(a, left) == try c.number(a, right);
}
pub fn bind(factory: Client, registry: []const u8, is_safe: bool) ![]const u8 {
    const a = factory.cast.a;
    const id = if (is_safe) "Chainwall.SafeFactory" else "Chainwall.AccountFactory";
    if (try c.number(a, try factory.first("chainwallComponentId", &.{})) != ms.bytecode.hash(id)) return error.WrongFactoryComponent;
    const interact = try c.string(try factory.first(if (is_safe) "INTERACT_CONTRACT" else "interact", &.{}));
    var cast = factory.cast.*;
    cast.instance = interact;
    cast.checked = false;
    const client: Client = .{ .cast = &cast, .cat = factory.cat, .group = "interact" };
    try client.boundInteract(registry);
    return interact;
}
fn registered(factory: Client, registry: []const u8, address: []const u8, is_safe: bool) !bool {
    var cast = factory.cast.*;
    cast.instance = registry;
    cast.checked = false;
    const client: Client = .{ .cast = &cast, .cat = try contracts.Catalog.load(cast.a), .group = "accounts" };
    return (try client.first(if (is_safe) "isSafeAllowed" else "isAccountAllowed", &.{.{ .string = address }})).bool;
}
fn addressAt(safe: Client, slot: u256) !c.Value {
    const a = safe.cast.a;
    // Raw RPC storage reads also work with legacy Safes lacking getStorageAt.
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(a, &.{ "storage", safe.cast.instance, try c.hex(a, slot), "--rpc-url", safe.cast.rpc });
    if (safe.cast.block) |block| try args.appendSlice(a, &.{ "--block", block });
    const value = try abi.unhex(a, try safe.cast.run(args.items));
    if (value.len != 32) return error.InvalidSafeStorage;
    return .{ .string = try abi.hex(a, value[12..]) };
}

/// Unreviewed releases can be inspected, but
/// cannot enter the signing/import workflow based only on their VERSION string.
pub fn safeCapabilities(version: []const u8) !struct { verified: bool, importSupported: bool, moduleEnumeration: []const u8, fallbackHandler: bool, transactionGuard: bool, moduleGuard: bool } {
    const parsed = std.SemanticVersion.parse(c.trim(version)) catch return error.InvalidSafeVersion;
    var verified = false;
    for ([_][]const u8{ "1.0.0", "1.1.1", "1.2.0", "1.3.0", "1.4.1", "1.5.0" }) |known| {
        if (c.eq(u8, c.trim(version), known)) verified = true;
    }
    const v1 = parsed.major == 1;
    return .{ .verified = verified, .importSupported = verified and parsed.minor >= 3, .moduleEnumeration = if (v1 and parsed.minor == 0) "legacy" else "paginated", .fallbackHandler = v1 and parsed.minor >= 1, .transactionGuard = v1 and parsed.minor >= 3, .moduleGuard = v1 and parsed.minor >= 5 };
}

fn appendModules(a: c.A, modules: *std.json.Array, seen: *std.AutoHashMapUnmanaged(u256, void), page: c.Value) !void {
    if (page != .array or page.array.items.len > 256) return error.InvalidSafeModules;
    for (page.array.items) |entry| {
        try c.address(try c.string(entry));
        const id = try c.number(a, entry);
        if (id <= 1 or seen.contains(id)) return error.InvalidSafeModules;
        try seen.put(a, id, {});
        try modules.append(entry);
    }
}
pub fn inspect(factory: Client, registry: []const u8, address: []const u8, is_safe: bool) !c.Value {
    return inspectWithModuleCompleteness(factory, registry, address, is_safe, true);
}

fn inspectWithModuleCompleteness(factory: Client, registry: []const u8, address: []const u8, is_safe: bool, require_complete_modules: bool) !c.Value {
    const a = factory.cast.a;
    try c.address(address);
    const interact = try bind(factory, registry, is_safe);
    const managed = (try factory.first(if (is_safe) "isSafe" else "isAccount", &.{.{ .string = address }})).bool;
    const allowed = try registered(factory, registry, address, is_safe);
    var cast = factory.cast.*;
    cast.instance = address;
    cast.checked = false;
    const client: Client = .{ .cast = &cast, .cat = factory.cat, .group = if (is_safe) "safe" else "ok-account" };
    if (!is_safe) {
        const account_registry = try client.first("REGISTRY", &.{});
        const account_interact = try client.first("INTERACT", &.{});
        const engine = try client.first("ENGINE", &.{});
        const registry_matches = try equal(a, account_registry, .{ .string = registry });
        const interact_matches = try equal(a, account_interact, .{ .string = interact });
        const engine_code = try cast.code(try c.string(engine));
        const factory_engine = try c.string(try factory.first("engine", &.{}));
        const factory_code = try cast.code(factory_engine);
        const engine_matches = engine_code.len > 2 and std.ascii.eqlIgnoreCase(engine_code, factory_code);
        return c.parse(a, try c.encode(a, .{ .address = address, .kind = "account", .factoryManaged = managed, .registered = allowed, .registry = account_registry, .interact = account_interact, .engine = engine, .registryMatches = registry_matches, .interactMatches = interact_matches, .engineMatches = engine_matches, .valid = managed and registry_matches and interact_matches and engine_matches }));
    }
    const owners = try client.first("getOwners", &.{});
    const threshold = try client.first("getThreshold", &.{});
    const nonce = try client.first("nonce", &.{});
    const version = try client.first("VERSION", &.{});
    const capabilities = try safeCapabilities(try c.string(version));
    const singleton = try addressAt(client, 0);
    const guard = if (capabilities.transactionGuard) try addressAt(client, ms.bytecode.hash("guard_manager.guard.address")) else .null;
    const fallback = if (capabilities.fallbackHandler) try addressAt(client, ms.bytecode.hash("fallback_manager.handler.address")) else .null;
    const module_guard = if (capabilities.moduleGuard) try addressAt(client, ms.bytecode.hash("module_manager.module_guard.address")) else .null;
    const guard_expected = try factory.first("GUARD_CONTRACT", &.{});
    const execution_module = try factory.first("executionModule", &.{});
    const module = try factory.first("MODULE_CONTRACT", &.{});
    const code = try abi.unhex(a, try cast.code(address));
    const authentic = ms.bytecode.hash(code) == try c.number(a, try factory.first("SAFE_PROXY_RUNTIME_CODEHASH", &.{})) and (try factory.first("isSafeSingletonApproved", &.{singleton})).bool;
    var modules = std.json.Array.init(a);
    var cursor: c.Value = .{ .string = sentinel };
    var seen: std.AutoHashMapUnmanaged(u256, void) = .empty;
    var modules_complete = true;
    if (c.eq(u8, capabilities.moduleEnumeration, "legacy")) {
        const legacy: Client = .{ .cast = &cast, .cat = try contracts.Catalog.loadSafeInspection(a), .group = "safe" };
        try appendModules(a, &modules, &seen, try legacy.first("getModules", &.{}));
    } else for (0..16) |_| {
        const page = (try client.call("getModulesPaginated", &.{ cursor, try abi.uint(a, 16) })).array.items;
        if (page.len != 2 or page[0] != .array or page[0].array.items.len > 16) return error.InvalidSafeModules;
        try appendModules(a, &modules, &seen, page[0]);
        try c.address(try c.string(page[1]));
        if (try c.number(a, page[1]) == 1) break;
        if (page[0].array.items.len == 0 or try equal(a, cursor, page[1])) return error.InvalidSafeModules;
        // Before 1.4, next names the first unreturned item. Both versions use
        // exclusive start cursors, so continuing from our last item is safe.
        cursor = page[0].array.items[page[0].array.items.len - 1];
    } else {
        // Permissive imports do not need the rest of the list. Never mistake this
        // bounded inspection for a complete list when constructing an allowlist.
        modules_complete = false;
        if (require_complete_modules) return error.SafeModulePaginationLimit;
    }
    if (managed) _ = try factory.call("validateManagedSafe", &.{.{ .string = address }});
    return c.parse(a, try c.encode(a, .{ .address = address, .kind = "safe", .factoryManaged = managed, .registered = allowed, .authentic = authentic, .owners = owners, .threshold = threshold, .nonce = nonce, .version = version, .capabilities = capabilities, .singleton = singleton, .guard = guard, .fallbackHandler = fallback, .moduleGuard = module_guard, .modules = c.Value{ .array = modules }, .modulesComplete = modules_complete, .expectedGuard = guard_expected, .executionModule = execution_module, .optionalModule = module, .valid = managed and authentic and capabilities.importSupported }));
}

pub fn fund(factory: Client, registry: []const u8, address: []const u8, args: *Args, is_safe: bool, dry: bool) !c.Value {
    const a = factory.cast.a;
    const amount = try @import("amounts.zig").native(args.get("value") orelse return error.FundingValueRequired);
    if (amount == 0) return error.FundingValueRequired;
    try args.finish();
    if (!dry and factory.cast.block != null) return error.TransactionRequiresLatestBlock;
    const inspected = try inspect(factory, registry, address, is_safe);
    if (!(try field(inspected, "valid")).bool or !(try field(inspected, "registered")).bool) return error.AccountBindingsMismatch;
    var cast = factory.cast.*;
    defer factory.cast.nonce = cast.nonce;
    cast.instance = address;
    cast.checked = false;
    const value = try a.print("{d}", .{amount});
    const transaction = try c.parse(a, try c.encode(a, .{ .chainId = cast.chain, .to = address, .data = "0x", .value = value, .nonce = cast.nonce }));
    if (dry) return c.parse(a, try c.encode(a, .{ .inspection = inspected, .transaction = transaction }));
    const receipt = try cast.send("0x", value);
    return c.parse(a, try c.encode(a, .{ .address = address, .value = value, .receipt = receipt }));
}
fn ownersValue(cast: *@import("cast.zig").Cast, text: []const u8) !c.Value {
    const a = cast.a;
    var values = std.json.Array.init(a);
    var entries = std.mem.splitScalar(u8, text, ',');
    var seen: std.AutoHashMapUnmanaged(u256, void) = .empty;
    while (entries.next()) |raw| {
        const owner = try cast.resolveAddress(c.trim(raw));
        try c.address(owner);
        const id = try c.word(owner);
        if (id <= 1 or seen.contains(id)) return error.InvalidSafeOwners;
        try seen.put(a, id, {});
        try values.append(.{ .string = owner });
    }
    return .{ .array = values };
}
pub fn create(factory: Client, registry: []const u8, args: *Args, is_safe: bool, dry: bool) !c.Value {
    const a = factory.cast.a;
    const nonce_salt: c.Value = .{ .string = try c.salt(a, args.get("salt") orelse return error.AccountSaltRequired) };
    var values = std.json.Array.init(a);
    try values.append(nonce_salt);
    var funding: ?[]const u8 = null;
    if (is_safe) {
        const owners = try ownersValue(factory.cast, args.get("owners") orelse return error.SafeOwnersRequired);
        const threshold = try c.word(args.get("threshold") orelse "1");
        if (threshold == 0 or threshold > owners.array.items.len) return error.InvalidSafeThreshold;
        const module = args.flag("module");
        const no_module = args.flag("no-module");
        if (module and no_module) return error.ConflictingModuleOptions;
        const install_module = module or (!no_module and owners.array.items.len == 1 and threshold == 1);
        if (install_module and (owners.array.items.len != 1 or threshold != 1)) return error.ModuleRequiresSingleOwner;
        try values.appendSlice(&.{ owners, try abi.uint(a, threshold), .{ .string = zero }, .{ .bool = true }, .{ .bool = install_module } });
        funding = args.get("value");
    }
    try args.finish();
    _ = try bind(factory, registry, is_safe);
    const predicted = try factory.first(if (is_safe) "computeSafeAddress" else "computeAccountAddress", values.items);
    const tx = try factory.transaction(if (is_safe) "newSafe" else "newAccount", values.items, funding, dry);
    if (dry) return c.parse(a, try c.encode(a, .{ .address = predicted, .transaction = tx }));
    const inspected = try inspect(factory, registry, try c.string(predicted), is_safe);
    if (!(try field(inspected, "valid")).bool) return error.CreatedAccountMismatch;
    return c.parse(a, try c.encode(a, .{ .address = predicted, .inspection = inspected, .receipt = tx }));
}
pub fn importAccount(factory: Client, registry: []const u8, address: []const u8, dry: bool) !c.Value {
    const inspected = try inspect(factory, registry, address, false);
    if (!(try field(inspected, "valid")).bool) return error.AccountBindingsMismatch;
    if ((try field(inspected, "registered")).bool) return error.AccountAlreadyRegistered;
    var cast = factory.cast.*;
    defer factory.cast.nonce = cast.nonce;
    cast.instance = registry;
    cast.checked = false;
    const client: Client = .{ .cast = &cast, .cat = try contracts.Catalog.load(cast.a), .group = "accounts" };
    const method = try client.cat.find("accounts", "addAccount");
    const receipt = try client.transaction("addAccount", &.{.{ .string = address }}, null, dry);
    if (dry) return receipt;
    const outcome = try @import("receipts.zig").classify(cast.a, client.cat, receipt, registry, method, &.{address});
    return c.parse(cast.a, try c.encode(cast.a, .{ .receipt = receipt, .outcome = outcome }));
}
// Keep aligned with SafeFactory.IMPORT_OPTION_SKIP_MODULE_CHECK. Never sign unknown options.
const import_option_skip_module_check: u256 = 1 << 0;

fn supportedImportOptions(factory: Client) !?u256 {
    const cast = factory.cast;
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(cast.a, &.{ "call", cast.instance, "--data", try factory.data("SUPPORTED_IMPORT_OPTIONS", &.{}), "--rpc-url", cast.rpc });
    if (cast.block) |block| try argv.appendSlice(cast.a, &.{ "--block", block });
    const result = cast.run(argv.items) catch |err| {
        const diagnostic = cast.diagnostic orelse return err;
        if (err == error.CastFailed and (std.mem.indexOf(u8, diagnostic, "execution reverted") != null or std.mem.indexOf(u8, diagnostic, "function selector was not recognized") != null)) {
            cast.diagnostic = null;
            return null;
        }
        return err;
    };
    if (c.eq(u8, result, "0x")) return null;
    if (result.len != 66) return error.InvalidSafeImportOptions;
    return try c.word(result);
}

pub fn importSafe(factory: Client, registry: []const u8, address: []const u8, args: *Args, signing: bool, dry: bool) !c.Value {
    const a = factory.cast.a;
    const preserve = args.flag("preserve-extensions");
    const check_modules = !args.flag("no-module-check");
    const module = args.flag("module");
    const no_module = args.flag("no-module");
    const signatures_file = args.get("signatures-file");
    const out = args.get("out");
    try args.finish();
    if ((module and no_module) or (preserve and (module or no_module)) or (signing and signatures_file != null)) return error.ConflictingImportOptions;
    const inspected = try inspectWithModuleCompleteness(factory, registry, address, true, check_modules);
    if (!(try field(try field(inspected, "capabilities"), "importSupported")).bool) return error.UnsupportedSafeImportVersion;
    if (!(try field(inspected, "authentic")).bool) return error.UnauthenticSafe;
    if ((try field(inspected, "registered")).bool) return error.AccountAlreadyRegistered;
    const guard = try field(inspected, "guard");
    const expected_guard = try field(inspected, "expectedGuard");
    if (try c.number(a, guard) != 0 and !try equal(a, guard, expected_guard)) return error.SafeHasDifferentGuard;
    const module_guard = try field(inspected, "moduleGuard");
    if (module_guard != .null and try c.number(a, module_guard) != 0) return error.SafeHasModuleGuard;
    const execution_module = try field(inspected, "executionModule");
    const optional_module = try field(inspected, "optionalModule");
    var cast = factory.cast.*;
    cast.instance = address;
    cast.checked = false;
    const safe: Client = .{ .cast = &cast, .cat = factory.cat, .group = "safe" };
    // OKModule may be beyond the inspected prefix. Its actual installation state
    // determines both the signed enableModule argument and the owner constraint.
    const enabled = (try safe.first("isModuleEnabled", &.{optional_module})).bool;
    var extras = std.json.Array.init(a);
    for ((try field(inspected, "modules")).array.items) |entry| {
        if (!try equal(a, entry, optional_module) and !try equal(a, entry, execution_module)) try extras.append(entry);
    }
    const fallback = try field(inspected, "fallbackHandler");
    if (!preserve and ((check_modules and extras.items.len > 0) or try c.number(a, fallback) != 0)) return error.SafeExtensionsRequireExplicitPreservation;
    const single = (try field(inspected, "owners")).array.items.len == 1 and try c.number(a, try field(inspected, "threshold")) == 1;
    const install_module = !preserve and (module or (!no_module and single));
    const supported_options = if (preserve or check_modules) null else try supportedImportOptions(factory);
    const options: u256 = if (check_modules) 0 else import_option_skip_module_check;
    if (!preserve) {
        if (supported_options) |supported| {
            if (options & ~supported != 0) return error.UnsupportedSafeImportOptions;
        } else if (!check_modules) return error.SafeFactoryUpgradeRequired;
    }
    const with_options = supported_options != null;
    if ((install_module or enabled) and !single) return error.ModuleRequiresSingleOwner;
    var configurator_cast = factory.cast.*;
    configurator_cast.instance = try c.string(try factory.first("CONFIGURATOR", &.{}));
    configurator_cast.checked = false;
    const configurator: Client = .{ .cast = &configurator_cast, .cat = factory.cat, .group = "safe-configurator" };
    var config_values = std.json.Array.init(a);
    try config_values.appendSlice(&.{ expected_guard, .{ .bool = true }, execution_module, optional_module, .{ .bool = install_module and !enabled } });
    var import_values = std.json.Array.init(a);
    try import_values.appendSlice(&.{ .{ .string = address }, .{ .bool = true } });
    if (preserve) {
        const fallbacks = try abi.array(a, if (try c.number(a, fallback) == 0) &.{} else &.{fallback});
        const extension_values = [_]c.Value{ try abi.uint(a, if (!check_modules) 1 else if (extras.items.len == 0) 0 else 2), if (check_modules) .{ .array = extras } else try abi.array(a, &.{}), try abi.uint(a, if (fallbacks.array.items.len == 0) 0 else 2), fallbacks };
        try config_values.appendSlice(&extension_values);
        try import_values.appendSlice(&extension_values);
    } else {
        try import_values.append(.{ .bool = install_module });
        if (with_options) {
            try import_values.append(try abi.uint(a, options));
            try config_values.appendSlice(&.{ try abi.uint(a, if (check_modules) 0 else 1), try abi.array(a, &.{}), try abi.uint(a, 0), try abi.array(a, &.{}) });
        }
    }
    const data = try configurator.data(if (preserve or with_options) "configureWithExtensionPolicy" else "configure", config_values.items);
    const configurator_address = configurator_cast.instance;
    const tx_values = [_]c.Value{ .{ .string = configurator_address }, try abi.uint(a, 0), .{ .string = data }, try abi.uint(a, 1), try abi.uint(a, 0), try abi.uint(a, 0), try abi.uint(a, 0), .{ .string = zero }, .{ .string = zero }, try field(inspected, "nonce") };
    if (out) |path| try c.write(cast.io, path, try c.encode(a, .{ .state = "prepared", .inspection = inspected, .transaction = tx_values }), false);
    if (signing) {
        const result = try safe_tx.sign(safe, &tx_values, dry);
        if (out) |path| try c.write(cast.io, path, try c.encode(a, result), true);
        return result;
    }
    const hash = try safe.first("getTransactionHash", &tx_values);
    const signatures = if (signatures_file) |path| try safe_tx.pack(a, try @import("json_schema.zig").read(a, cast.io, "safe-signatures", path), hash) else if (dry) "0x" else return error.SafeSignaturesFileRequired;
    try import_values.appendSlice(tx_values[4..9]);
    try import_values.append(.{ .string = signatures });
    const receipt = try factory.transaction(if (preserve) "importSafeWithExtensionPolicy" else if (with_options) "importSafeWithOptions" else "importSafe", import_values.items, null, dry);
    const submitted = try c.parse(a, try c.encode(a, .{ .transaction = receipt, .transactionHash = hash, .inspection = inspected }));
    if (out) |path| try c.write(cast.io, path, try c.encode(a, submitted), true);
    if (dry) return submitted;
    const verified = try inspectWithModuleCompleteness(factory, registry, address, true, check_modules);
    if (!(try field(verified, "valid")).bool) return error.ImportedSafeMismatch;
    const result = try c.parse(a, try c.encode(a, .{ .receipt = receipt, .inspection = verified }));
    if (out) |path| try c.write(cast.io, path, try c.encode(a, result), true);
    return result;
}
