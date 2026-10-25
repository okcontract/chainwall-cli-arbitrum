const std = @import("std");
const c = @import("common.zig");
const contracts = @import("contracts.zig");
const sync = @import("sync.zig");

pub const Row = [2][]const u8;
const commands = [_]Row{
    .{ "schemas list|show|template|validate", "Inspect shared JSON input schemas" },
    .{ "facets catalog|deploy|plan|apply|check", "Deploy canonical facets and review selector transitions" },
    .{ "commitments prepare|commit|reveal|status", "Manage encrypted private contract, token and interaction drafts" },
    .{ "login <address>", "Connect a Registry or SafeFactory instance" },
    .{ "deploy", "Deploy a Chainwall instance through OKFactory" },
    .{ "tokens set-chainlink-native-feed", "Configure the chain's Chainlink native USD preset" },
    .{ "security-council inspect|configure|reconcile", "Review and configure the tenant security council" },
    .{ "logs list|show [NAME|latest]", "Browse saved transaction results and receipts" },
    .{ "upgrade deploy|inspect|verify|propose", "Verify and adopt embedded releases" },
    .{ "transactions inspect|source HASH...", "Decode transactions and generate Lambdascript" },
    .{ "transactions list|track|refresh|wait", "Recover and monitor canonical transaction state" },
    .{ "transactions speed-up|cancel HASH", "Replace a pending EOA transaction at the same nonce" },
    .{ "transactions estimate FILE", "Preview execution gas and fee caps without signing" },
    .{ "analyze FILE", "Inspect MiniScript calls, arguments and runtime limits" },
    .{ "terms document|accept-terms", "Verify and accept published licensing documents" },
    .{ "policies simulate FILE", "Simulate a policy in its operation context" },
    .{ "recipients list|add|remove|authorize|revoke|resolve", "Manage encrypted policy recipient address books" },
    .{ "profile list|create|use", "Manage TOML profiles" },
    .{ "rpc add|list|probe|use|choose|privacy", "Manage endpoint pools, health history and privacy filters" },
    .{ "config show|get|set|unset", "Configure the selected profile" },
    .{ "config import|export FILE", "Exchange app-format JSON, including secrets" },
    .{ "accounts", "List Foundry keystore accounts" },
    .{ "accounts create|import|inspect", "Deploy and verify managed OKAccounts" },
    .{ "accounts assets|activity ADDRESS", "Read balances, valuations, and execution history" },
    .{ "safes create|import|inspect", "Deploy, import, and inspect guarded Safes" },
    .{ "safes assets|activity ADDRESS", "Read Safe balances, valuations, and execution history" },
    .{ "auth enroll|create|register|inspect", "Enroll and manage passkey AuthAccounts" },
    .{ "users add|remove|contains", "Manage allowed users" },
    .{ "users list", "List users (--start 0 --count 50)" },
    .{ "sync", "Sync Registry data into SQLite" },
    .{ "search [QUERY]", "Search cached catalogs, accounts, and tenant contracts" },
    .{ "instances discover [ADDRESS]", "Discover Registry deployments on configured chains" },
    .{ "status [--all-chains]", "Inspect tenant governance, terms, and catalog status" },
    .{ "timelocks list", "List cached timelock actions" },
    .{ "kv create|connect|rotate|history", "Manage encrypted storage and its secret history" },
    .{ "labels encode|decode|set|get|clear", "Create encrypted IDs and manage Registry labels" },
    .{ "operations list", "Unlock and list cached operation proposals" },
    .{ "operations propose|publish|simulate|execute FILE", "Create, share, simulate, and execute operations" },
    .{ "operations approve|withdraw|status ID", "Manage live operations" },
    .{ "interactions add <file.ls>", "Compile and publish a new interaction" },
    .{ "interactions update <file.ls>", "Update a complete interaction bundle" },
    .{ "interactions compile <file.ls>", "Compile without publishing" },
    .{ "interactions source <id>", "Display an interaction as Lambdascript" },
    .{ "interactions activate|deactivate <id>", "Change interaction availability" },
    .{ "compile <file.ls>", "Compile source (--out program.json)" },
    .{ "decompile|disasm <hex-file>", "Inspect MiniScript bytecode" },
    .{ "abi <address>", "Fetch/cache a verified contract ABI" },
    .{ "registry <method> [args...]", "Any method in the embedded Registry ABI" },
    .{ "registry <method> --help", "Show exact parameter types and names" },
    .{ "artifacts [contract]", "Export the embedded compiler JSON" },
    .{ "id <name>", "Derive a bytes32 identifier" },
    .{ "completions fish|zsh", "Print shell integration" },
    .{ "completions unlock|watch|lock|status", "Manage live completion sessions" },
};
pub const global_options = [_]Row{
    .{ "--interactive", "Edit a JSON template or input copy, validate, then continue" },
    .{ "--editor COMMAND", "Override the preferred editor for this invocation" },
    .{ "--schema", "Print the command's JSON input schema without executing" },
    .{ "--edit-input OPTION", "Select an auxiliary JSON input, such as signatures-file" },
    .{ "--profile NAME", "Select ~/.config/chainwall/NAME.toml" },
    .{ "--chain NAME|ID", "Select chain; RPC chain ID is verified" },
    .{ "--rpc-url URL --instance ADDR", "Override the profile connection" },
    .{ "--account NAME", "Foundry keystore account (cast wallet)" },
    .{ "--keystore PATH", "Use a keystore outside Foundry's default folder" },
    .{ "--password-file PATH", "Let cast unlock the account noninteractively" },
    .{ "--auth-profile FILE", "Approve transactions with a domain-bound passkey" },
    .{ "--bundler-url URL", "Send passkey UserOperations through an ERC-4337 bundler" },
    .{ "--paymaster ADDRESS", "Use the customer's OKAccountPaymaster with the bundler" },
    .{ "--approval-url URL", "Standalone approval page at the configured passkey origin" },
    .{ "--app-url URL", "Approval app path within the configured passkey origin" },
    .{ "--no-browser", "Print the approval URL without launching a browser" },
    .{ "--approval-timeout SECONDS", "Browser approval timeout (default: 300)" },
    .{ "--json", "Machine-readable output" },
    .{ "--color auto|always|never", "Color help, source, and JSON (default: auto)" },
    .{ "--dry-run", "Print transaction calldata without signing" },
    .{ "--estimate", "Prepare calldata and estimate execution gas without signing" },
    .{ "--gas-limit N", "Set a transaction gas limit" },
    .{ "--max-fee AMOUNT --priority-fee AMOUNT", "Set EIP-1559 fee caps in wei or gwei" },
    .{ "--gas-price AMOUNT --legacy", "Use legacy gas pricing (gas-price implies legacy)" },
    .{ "--wait-timeout SECONDS", "Receipt wait after submission (default: 120)" },
    .{ "--tx-confirmations N", "Required submission confirmations (default: 1)" },
    .{ "--args-file FILE", "Named or positional JSON ABI arguments" },
    .{ "--from ADDRESS|ACCOUNT", "Caller address or Foundry account name" },
    .{ "--unlocked", "Use --from as an RPC-managed signer (local testing)" },
    .{ "--nonce N", "Pass a starting nonce to cast call/send" },
    .{ "--block NUMBER|TAG", "Pin Registry reads to a block" },
    .{ "--config-dir PATH", "Override profile/cache location" },
    .{ "--help, -h", "Show help for the selected command or method" },
    .{ "--version, -V", "Show the CLI version" },
};
const compiler_options = [_]Row{
    .{ "--snapshot FILE", "Use offline Registry and ABI metadata" },
    .{ "--abi org/id=FILE", "Supply a target ABI; repeat for multiple targets" },
    .{ "--settings FILE", "Load compiler settings or a compiler JSON artifact" },
    .{ "--optimization size|baseline", "Select compiler optimization" },
    .{ "--argument-context frame|subject", "Select argument interpretation" },
    .{ "--no-preprocess", "Compile core Lambdascript directly" },
    .{ "--refresh-abi", "Refresh verified ABI metadata" },
    .{ "--etherscan-url URL", "Override the explorer API endpoint" },
};
const source_options = [_]Row{
    .{ "--snapshot FILE", "Supply offline Registry names and ABIs" },
    .{ "--abi org/id=FILE", "Supply a target ABI; repeat for multiple targets" },
    .{ "--settings FILE", "Override saved compiler/decompiler settings" },
    .{ "--optimization size|baseline", "Select reconstruction optimization" },
    .{ "--argument-context frame|subject", "Select argument interpretation" },
    .{ "--live", "Fetch missing Registry records and verified ABIs" },
    .{ "--offline", "Use saved metadata and local cache only" },
    .{ "--refresh-abi", "Refresh verified ABIs with --live" },
    .{ "--etherscan-url URL", "Override the explorer API endpoint" },
    .{ "--no-preprocess", "Display core source without Registry/ABI rewrites" },
    .{ "--out FILE", "Save plain source without terminal colors" },
};
const page_options = [_]Row{
    .{ "--start N", "Start at offset N (default: 0)" },
    .{ "--count N", "Maximum number of entries (default: 50)" },
    .{ "--offline", "Require cached data without RPC access" },
    .{ "--live", "Read current Registry data instead of the cache" },
};

pub const Page = struct {
    usage: []const []const u8,
    options: []const Row = &.{},
    notes: []const u8 = "",
};

/// Widths are measured before styling, so ANSI escapes never affect padding.
pub const Renderer = struct {
    a: c.A,
    out: std.Io.Writer.Allocating,
    color: bool,

    pub fn init(a: c.A, color: bool) Renderer {
        return .{ .a = a, .out = .init(a), .color = color };
    }
    fn styled(r: *Renderer, value: []const u8, style: []const u8) !void {
        if (r.color) try r.out.writer.writeAll(style);
        try r.out.writer.writeAll(value);
        if (r.color) try r.out.writer.writeAll("\x1b[0m");
    }
    fn label(r: *Renderer, value: []const u8) !void {
        try r.styled(value, "\x1b[1;36m");
    }
    fn brand(r: *Renderer, version_text: ?[]const u8) !void {
        try r.label("Chainwall");
        if (version_text) |value| try r.out.writer.print(" {s}", .{value});
        try r.out.writer.writeByte('\n');
        try r.styled("https://chainwall.org", "\x1b[4;36m");
        try r.out.writer.writeByte('\n');
        try r.styled("by OKcontract Labs", "\x1b[2m");
        try r.out.writer.writeByte('\n');
    }
    pub fn version(r: *Renderer) !void {
        try r.brand("0.3.0 (Zig 0.17)");
    }
    fn width(rows: []const Row) usize {
        var result: usize = 0;
        for (rows) |row| result = @max(result, row[0].len);
        return result;
    }
    pub fn table(r: *Renderer, rows: []const Row, min_width: usize) !void {
        const column = @max(min_width, width(rows)) + 2;
        for (rows) |row| {
            try r.out.writer.writeAll("  ");
            try r.label(row[0]);
            try r.out.writer.splatByteAll(' ', column - row[0].len);
            try r.out.writer.print("{s}\n", .{row[1]});
        }
    }
    fn page(r: *Renderer, value: Page) !void {
        try r.brand(null);
        try r.out.writer.writeByte('\n');
        for (value.usage, 0..) |usage, i| {
            try r.out.writer.writeAll(if (i == 0) "Usage: " else "       ");
            try r.label(usage);
            try r.out.writer.writeByte('\n');
        }
        if (value.options.len > 0) {
            try r.out.writer.writeAll("\nOptions:\n");
            try r.table(value.options, 0);
        }
        if (value.notes.len > 0) try r.out.writer.print("\n{s}\n", .{value.notes});
        try r.out.writer.writeAll("\nUse chainwall --help for global options.\n");
    }
    pub fn print(r: *Renderer, io: std.Io) !void {
        try c.print(io, "{s}", .{r.out.written()});
    }
    pub fn top(r: *Renderer) !void {
        try r.brand(null);
        try r.out.writer.writeByte('\n');
        try r.out.writer.writeAll("Usage: ");
        try r.label("chainwall <command> [options]");
        try r.out.writer.writeAll("\n\n");
        const column = @max(width(&commands), width(&global_options));
        try r.table(&commands, column);
        try r.out.writer.writeAll("\nGroups: users, groups, safes, orgs, contracts, tokens, interactions,\npolicies, capabilities, roles, ownership, metadata, timelock, terms,\nauth, sync, sync-query, interaction-sync, token-commits, emergency,\npolicy-state, diamond, facets. Use <group> --help to list all methods.\n\nGlobal options:\n");
        try r.table(&global_options, column);
        try r.out.writer.writeAll("\nExamples:\n");
        for ([_][]const u8{
            "chainwall login 0x... --chain base --rpc-url https://... --account deployer",
            "chainwall users add 0x...",
            "chainwall interactions add swap.ls --chain base",
            "chainwall timelock approve 0x...",
            "chainwall timelock execute 0x...",
            "chainwall deploy --help",
            "chainwall registry upsertToken --help --json",
        }) |example| {
            try r.out.writer.writeAll("  ");
            try r.label(example);
            try r.out.writer.writeByte('\n');
        }
    }
    pub fn group(r: *Renderer, cat: contracts.Catalog, name: []const u8) !void {
        var rows: std.ArrayList(Row) = .empty;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        for (cat.methods) |entry| {
            if (!contracts.matchesGroup(entry, name) or seen.contains(entry.signature)) continue;
            try seen.put(r.a, entry.signature, {});
            try rows.append(r.a, .{ entry.command, try r.a.print("{s}  {s}", .{ if (entry.read()) "read " else "write", entry.signature }) });
        }
        if (rows.items.len == 0) return error.UnknownCommand;
        try r.brand(null);
        try r.out.writer.writeByte('\n');
        try r.out.writer.writeAll("Usage: ");
        try r.label(try r.a.print("chainwall {s} <command> [options]", .{name}));
        try r.out.writer.writeAll("\n\n");
        var shortcuts: std.ArrayList(Row) = .empty;
        for (commands) |row| {
            const first = row[0][0..(std.mem.indexOfScalar(u8, row[0], ' ') orelse row[0].len)];
            if (c.eq(u8, first, name) and !c.eq(u8, name, "registry")) try shortcuts.append(r.a, row);
        }
        if (shortcuts.items.len > 0) {
            try r.out.writer.writeAll("Commands:\n");
            try r.table(shortcuts.items, 0);
            try r.out.writer.writeByte('\n');
        }
        try r.out.writer.writeAll("Registry methods:\n");
        try r.table(rows.items, 0);
        try r.out.writer.print("\nUse chainwall {s} <command> --help for parameters and options.\n", .{name});
    }
    pub fn method(r: *Renderer, method_: contracts.Method) !void {
        try r.brand(null);
        try r.out.writer.writeByte('\n');
        try r.label(try contracts.signature(r.a, method_.abi, true));
        try r.out.writer.print("\n{s}\n", .{try c.string(c.field(method_.abi, "stateMutability").?)});
        if (c.eq(u8, method_.group, "terms") and c.eq(u8, method_.name, "acceptTerms")) {
            try r.out.writer.writeAll("\nUsage: chainwall terms accept-terms [DOCUMENT_HASH]\n\nWith no arguments, reads the initial document from the selected Registry.\nAn explicit hash resolves its canonical document from the licensing list.\nThe signer needs ADMIN_ROLE. --dry-run verifies the document without submitting.\nDocument bytes must match SHA-256. Use --ipfs-gateway URL or --document-file FILE.\n");
        }
        var rows: std.ArrayList(Row) = .empty;
        for (c.field(method_.abi, "inputs").?.array.items) |input| {
            try rows.append(r.a, .{ try r.a.print("--arg-{s}", .{try c.kebab(r.a, try c.string(c.field(input, "name").?))}), try contracts.parameter(r.a, input) });
        }
        if (rows.items.len > 0) {
            try r.out.writer.writeAll("\nParameters:\n");
            try r.table(rows.items, 0);
        }
        try r.out.writer.writeAll("\nUse positional arguments, named flags, or --args-file with JSON objects/arrays.\nUse --help --json for the complete ABI, including nested tuple components.\nUse chainwall --help for global options.\n");
    }

    pub fn command(r: *Renderer, p: []const []const u8) !bool {
        const value = (try commandPage(r.a, p)) orelse return false;
        try r.page(value);
        return true;
    }
};

pub fn commandPage(a: c.A, p: []const []const u8) !?Page {
    const name = p[0];
    const verb = if (p.len > 1) p[1] else "";
    const value: Page = if (c.eq(u8, name, "schemas")) .{
        .usage = &.{ "chainwall schemas [list]", "chainwall schemas show NAME [--out FILE]", "chainwall schemas template NAME [--out FILE]", "chainwall schemas validate NAME FILE" },
        .options = &.{.{ "--out FILE", "Save a new schema or template" }},
        .notes = "Schemas are embedded for offline validation.\nUse any JSON-input command with --schema to inspect its selected input, including\nABI-derived named/positional arguments. --edit-input OPTION selects an auxiliary\nfile such as signatures-file. Templates contain placeholders to complete.\nSet a preferred editor with config set editor hx; --interactive edits a private\ncopy and continues only after a successful editor exit and JSON validation.",
    } else if (c.eq(u8, name, "completions")) .{
        .usage = &.{ "chainwall completions fish|zsh", "chainwall completions unlock|watch [options]", "chainwall completions lock|status" },
        .options = &.{ .{ "--ttl SECONDS", "Session lifetime (default: 900, maximum: 86400)" }, .{ "--refresh SECONDS", "Background sync interval (default: 30; 0 disables)" }, .{ "--passphrase-file FILE", "Unlock private labels noninteractively" } },
        .notes = "Save fish output to $__fish_config_dir/completions/chainwall.fish.\nSave zsh output as _chainwall in a directory on fpath before running compinit.\nUnlock decrypts private labels in memory; watch refreshes public records only.\nSessions belong to the selected profile, chain, and Registry. Tab never prompts.\nUse @label for entity arguments; duplicate labels require a raw address or ID.",
    } else if (c.eq(u8, name, "status") or c.eq(u8, name, "instances")) .{
        .usage = &.{ "chainwall instances discover [ADDRESS] [--chains base,ethereum]", "chainwall status [--all-chains | --chains base,ethereum]" },
        .options = &.{ .{ "--chains NAMES|IDS", "Comma-separated selection using saved RPC endpoints" }, .{ "--all-chains", "Inspect all profile RPC/Registry chains (discovery default)" }, .{ "--out FILE", "Save a new report without changing profile bindings" } },
        .notes = "Checks RPC chain ID, code, Registry component identity, and block canonicality.\nEach chain reports installed, not-installed, different-contract, or unavailable.\nUses explicit per-chain instance bindings, otherwise probes the selected address.\nStatus reads pause/bootstrap/council, terms, pending actions and catalog\ncounts at each chain's own block. Missing facets report null plus errors.\nUnavailable RPCs do not hide other chains, and provider credentials are omitted.\nResults do not change the selected profile or prove canonical release bytecode.",
    } else if (c.eq(u8, name, "search")) .{
        .usage = &.{"chainwall search [QUERY] [--kind KIND] [--private]"},
        .options = &.{ .{ "--kind KIND", "Filter users, groups, policies, orgs, contracts, tokens, interactions, accounts, safes, authaccounts, timelocks, system, addresses" }, .{ "--private", "Unlock encrypted labels in memory for this search" }, .{ "--passphrase-file FILE", "Unlock private labels noninteractively; implies --private" }, .{ "--start N --count N", "Select a ranked result page (defaults: 0 and 50)" }, .{ "--out FILE", "Save a new result file (0600)" } },
        .notes = "Searches the selected chain/Registry cache without RPC, and reports dataset\ncheckpoints. Run sync first to refresh catalogs. Matches labels, paths, symbols,\naddresses, IDs, and public record fields; query words must all match. Exact IDs\nand labels rank first. Alias rows are deduplicated by kind and ID. Default search\nuses public labels; private labels are decrypted only with an explicit unlock.\nSystem addresses come from saved topology and are not live deployment proofs.",
    } else if (c.eq(u8, name, "operations") and c.eq(u8, verb, "checkpoint")) .{
        .usage = &.{ "chainwall operations checkpoint prepare [--keep-all] [--confirmations N]", "chainwall operations checkpoint inspect ID", "chainwall operations checkpoint publish ID [--retry]" },
        .options = &.{ .{ "--passphrase-file FILE", "Unlock encrypted journal and checkpoint drafts" }, .{ "--confirmations N", "Execution-chain depth for expiry proof (default: 12)" }, .{ "--keep-all", "Retain every distinct proposal without execution-chain RPC" }, .{ "--chunk-size N", "Retained proposals per transaction, 1..128 (default: 128)" }, .{ "--retry", "Explicitly retry an unconfirmed write attempt" }, .{ "--dry-run", "Validate publication context without signing or sending" } },
        .notes = "Prepare syncs the complete indexed KV journal, saves an encrypted local draft,\nand returns its ID. It excludes only proposals past their deadline at the\nconfirmed block on the selected execution chain. Other chains and unproven\nclosed operations are retained. No Safe/status/list filters apply.\nPublish verifies the chain, current secret epoch and saved canonical blocks,\nresumes already confirmed writes, and writes the manifest after all chunks.\nA crash or unconfirmed attempt requires --retry; raw history is never deleted.\nRun sync --only operations after publishing. List defaults to --view operational;\n--view audit shows every raw proposal, including duplicates and compacted entries.\nInvalid or incomplete checkpoints fall back to an older valid checkpoint or raw history.",
    } else if (c.eq(u8, name, "operations") and @import("schema.zig").contains("import export export-local", verb)) .{
        .usage = &.{ "chainwall operations import SHARE.json [--out SHARE_COPY.json]", "chainwall operations export PROPOSAL.json --out SHARE.json [--proposal-tx HASH]", "chainwall operations export-local PENDING_ID --out SHARE.json" },
        .options = &.{ .{ "--proposal-tx HASH", "Original proposal transaction hash for older CLI proposal files" }, .{ "--out FILE", "New plaintext private share file with owner-only permissions" }, .{ "--passphrase-file FILE", "Unlock encrypted local imports" }, .{ "--dry-run", "Import verification only; do not store or export data" } },
        .notes = "Shares match the app's version-1 private operation envelope. Verification checks\nproposal calldata, canonical receipt evidence, payload hash, open operation state,\naccount, policy, value, and execution binding. Executor-bound operations and\nrelayed outer proposals are not supported by this share format. Imports are\nencrypted in the local vault, without requiring a shared KV. Use operations list\n--local to view them. Existing execute/publish/sign commands reverify share files.\nExported files contain private operation details; send them only to recipients\nyou intend to disclose those details to. Imports never submit a transaction.",
    } else if (c.eq(u8, name, "policies") and c.eq(u8, verb, "templates")) .{
        .usage = &.{ "chainwall policies templates", "chainwall policies templates NAME [--interaction ID --interaction ID] [--out FILE.ls]" },
        .options = &.{ .{ "--interaction ID|@LABEL", "Two distinct reviewed IDs for allowlist templates" }, .{ "--out FILE.ls", "Save new editable Lambdascript source" } },
        .notes = "Bundled templates cover budget, pause, recipient, and timelock\nprograms. Private destination templates pin both live interaction content hashes.\nRegistry-dependent templates require --instance or a selected profile. Review and\nedit budget constants and initialize referenced policy state before publication.\nSource is printed directly unless --json requests the complete template record.",
    } else if (c.eq(u8, name, "policies") and c.eq(u8, verb, "program")) .{
        .usage = &.{ "chainwall policies program compile FILE.ls [--out FILE.json]", "chainwall policies program publish POLICY FILE.ls|FILE.json [--max-steps N]", "chainwall policies program inspect|clear POLICY", "chainwall policies program simulate POLICY CONTEXT.json" },
        .options = &.{ .{ "--max-steps N", "Positive execution bound (publish default: 100000)" }, .{ "--out FILE", "Save compilation or a new review/receipt report" }, .{ "--dry-run", "Review current program and preview publication without signing" } },
        .notes = "Uses the embedded compiler with frame argument context and static analysis.\nPublication rechecks program version and simulates the write; contract governance\nstill applies. Simulation evaluates the installed program with rollback, not a\nlocal draft. CONTEXT.json contains interactionId, interactionArgs, nativeValue,\noperationId, payloadHash, actor, and vault. Existing compiler options are supported\nfor .ls inputs; templates and compiled artifacts use the same publication flow.",
    } else if (c.eq(u8, name, "security-council")) .{
        .usage = &.{ "chainwall security-council inspect [GROUP|HASH|@LABEL]", "chainwall security-council configure GROUP --threshold N --recovery-authority ADDRESS|ACCOUNT --out FILE", "chainwall security-council reconcile FILE TRANSACTION_HASH" },
        .options = &.{ .{ "--threshold N", "Required approvals, between 2 and the group size (maximum 32)" }, .{ "--recovery-authority ADDRESS|ACCOUNT", "Independent deployed contract outside the council group" }, .{ "--out FILE", "New durable review/receipt file; required for submission" }, .{ "--dry-run", "Review live membership and preview without signing" } },
        .notes = "Members must be deployed contracts and cannot be the Registry. Configuration\nbinds the reviewed membership revision, checks administrator access, and simulates\nbefore signing. Contract delays and recovery restrictions remain enforced.\nA queued result includes its action ID and ETA; use timelock commands to execute it.\nReconcile proves the exact inner call from canonical receipt events, including\nrelayed AuthAccount submissions. It updates the saved file without resubmitting.",
    } else if (c.eq(u8, name, "tokens") and @import("schema.zig").contains("metadata configure validate-feed", verb)) .{
        .usage = &.{ "chainwall tokens metadata ADDRESS|ORG/ID|HASH|@LABEL", "chainwall tokens configure ORG/ID|HASH|@LABEL [options]", "chainwall tokens validate-feed ADDRESS [--max-age SECONDS]" },
        .options = &.{ .{ "--symbol TEXT --decimals N", "Explicit configure overrides; otherwise read ERC20 metadata" }, .{ "--price-feed ADDRESS|none", "Choose or clear a feed; omission preserves its current value" }, .{ "--feed-max-age SECONDS", "Set a positive feed heartbeat in the same multicall as the upsert" }, .{ "--max-age SECONDS", "Validation-only heartbeat override" }, .{ "--out FILE", "Save a new report and update it with receipt/timelock evidence" }, .{ "--dry-run", "Resolve metadata, validate the feed and preview without signing" } },
        .notes = "Configure uses the selected contract's latest registered address. Symbol supports\nstandard string and legacy bytes32 returns; decimals must be 0..36 and are never guessed.\nFeed validation checks a positive completed round, timestamp, reviewed heartbeat and\nthe Registry global age limit at one canonical block. A heartbeat requires price-admin\npermission. Submission simulates the complete call; normal timelocks still apply.\nInspect outcome.queuedActions when governance queues a change. A healthy response does\nnot establish that an arbitrary supplied feed quotes the intended token in USD.",
    } else if (c.eq(u8, name, "tokens") and c.eq(u8, verb, "set-chainlink-native-feed")) .{
        .usage = &.{"chainwall tokens set-chainlink-native-feed [options]"},
        .options = &.{.{ "--dry-run", "Validate via RPC and preview the multicall without signing" }},
        .notes = "Uses the bundled preset for the selected chain. Validates feed decimals,\nround completeness, positive price, timestamp, and age at one canonical block.\nOne multicall sets the oracle environment, feed maximum age, and native USD feed.\nPreserves the Registry global age limit. ADMIN_ROLE and an RPC are required to\nsubmit; contract timelocks may queue the three changes. Unsupported chains fail\nwithout submitting. Transaction logs and Foundry signer options work as usual.",
    } else if (c.eq(u8, name, "logs")) .{
        .usage = &.{ "chainwall logs list", "chainwall logs show [NAME|PATH|latest]" },
        .notes = "Transaction commands save results and receipts in CONFIG_DIR/logs (default:\n~/.config/chainwall/logs), including receipts obtained before a later failure.\nList prints paths newest first. Show defaults to the latest log and works offline.\nJSON is highlighted on supported terminals; --color never disables highlighting.\n--json keeps machine-readable output. Logs span all profiles in this config directory.",
    } else if (c.eq(u8, name, "deploy")) .{
        .usage = &.{ "chainwall deploy --owner ADDRESS|ACCOUNT --salt BYTES32|PHRASE [options]", "chainwall deploy --stage prepare|finalize --registry ADDRESS [options]" },
        .options = &.{
            .{ "--factory ADDRESS", "Override the profile or bundled Arbitrum factory default" },
            .{ "--owner ADDRESS|ACCOUNT", "Owner address or Foundry account name (required at bootstrap)" },
            .{ "--salt BYTES32|PHRASE", "32-byte hex or phrase hashed with Keccak-256 (required at bootstrap)" },
            .{ "--indexing | --no-indexing", "Enable or disable indexing (default: enabled)" },
            .{ "--auth-accounts | --no-auth-accounts", "Enable or disable AuthAccounts (default: disabled)" },
            .{ "--flags 0|1|2|3", "Numeric alternative; cannot be mixed with feature switches" },
            .{ "--stage all|bootstrap|prepare|finalize", "Select deployment stage (default: all)" },
            .{ "--registry ADDRESS", "Resume a bootstrapped instance" },
            .{ "--out FILE", "Save an additional copy of deployment results" },
            .{ "--dry-run", "Preview the selected stage without RPC or signing" },
            .{ "--nonce N", "Starting nonce; advances after each confirmed stage" },
        },
        .notes = "Creates an instance through an existing OKFactory. Finalization saves the new connection.\nResults and receipts are saved in CONFIG_DIR/logs; prints the log path by default.\nUse --json to also print the result JSON, or logs show to inspect a saved log.\nOwner names resolve through cast wallet address; --account still selects the signer.\nFoundry may prompt for the owner's password, including during dry-run.\nDry-run with --stage all previews bootstrap and lists the remaining stages.",
    } else if (c.eq(u8, name, "facets")) .{
        .usage = &.{ "chainwall facets catalog [NAME]", "chainwall facets deploy NAME --out deployment.json", "chainwall facets verify NAME ADDRESS [--deployment-tx HASH]", "chainwall facets plan NAME --target ADDRESS [--current ADDRESS|none] --out plan.json", "chainwall facets apply plan.json [--dry-run]", "chainwall facets check plan.json", "chainwall facets reconcile plan.json TRANSACTION_HASH" },
        .options = &.{ .{ "--choices-file FILE", "Extra selectors mapped to {kind: keep|remove} or {kind: move, address: ADDRESS}" }, .{ "--current ADDRESS|none", "Current facet; inferred only when unambiguous" }, .{ "--deployment-tx HASH", "Canonical CREATE proof for facets with constructor dependencies" }, .{ "--out FILE", "New deployment report or reviewable selector plan" }, .{ "--retry", "Explicitly retry a reviewed attempt; live checks still apply" }, .{ "--dry-run", "Preview deployment or validate/simulate a saved plan without sending" } },
        .notes = "Catalog bytecode and selector sets are embedded in the CLI.\nDeploy retains the receipt before runtime verification. Constructor-bound facets\nrequire their canonical creation transaction; local deployments cache this hint.\nPlan requires an explicit keep/remove/move choice for every extra selector.\nProtected direct and core routes cannot be removed. Apply rechecks all routes\nand destination code, simulates with the selected signer, then submits a code-only cut.\nApply/reconcile update the supplied plan in place. Receipt success is insufficient:\nmatching events and canonical resulting routes prove applied outcomes.\nQueued cuts must execute through the timelock. Raw ABI facet methods remain available.",
    } else if (c.eq(u8, name, "commitments")) .{
        .usage = &.{ "chainwall commitments template contract|token|interaction [--out FILE]", "chainwall commitments prepare contract|token|interaction FILE", "chainwall commitments list", "chainwall commitments status|commit|reveal|cancel|expire HASH", "chainwall commitments reconcile HASH TRANSACTION_HASH", "chainwall commitments export HASH --out FILE", "chainwall commitments import FILE" },
        .options = &.{ .{ "--passphrase-file FILE", "Unlock encrypted local drafts; no KV deployment needed" }, .{ "--source-file FILE", "Compile a .ls main program while preparing an interaction" }, .{ "--actor-signature-file FILE", "Optional committer signature for a delegated reveal" }, .{ "--out FILE", "New 0600 report or explicitly requested private export" }, .{ "--retry", "Explicitly retry a reviewed attempt after checking live state" }, .{ "--dry-run", "Preview without saving a new draft or submitting a transaction" } },
        .notes = "Prepare takes {payload, deadline?, forwarder?, hint?}; template provides payload fields.\nDeadline is Unix seconds, defaults to seven days, and cannot exceed 90 days.\nSalts are generated securely and kept encrypted with the complete payload.\nNo salt phrase is accepted. List/status/normal reports never print salt or payload.\nCommit checks chain time, current commitment, pending actions and timelock delay.\nReveal checks the exact commitment and simulates before submission. Simulation\nsends the reveal to your selected RPC; a successful reveal makes it public.\nDrafts are scoped to chain and Registry. Keep a recovery export before moving\nconfigurations: export intentionally writes the secret salt and payload to FILE.\nQueued outcomes remain queued until their timelock action executes.\nReconcile verifies receipt events, actor, payload binding and canonical block.",
    } else if (c.eq(u8, name, "rpc")) .{
        .usage = &.{ "chainwall rpc add NAME --rpc-url URL [--privacy private|public|unknown]", "chainwall rpc list", "chainwall rpc probe [NAME]", "chainwall rpc use NAME", "chainwall rpc choose [--max-lag N]", "chainwall rpc privacy all|private", "chainwall rpc remove NAME" },
        .options = &.{ .{ "--chain CHAIN", "Pool scope, together with the selected profile" }, .{ "--privacy CLASS", "User-declared provider privacy; defaults to unknown" }, .{ "--timeout SECONDS", "Per-request probe deadline, 1-30 seconds (default: 5)" }, .{ "--max-lag BLOCKS", "Maximum lag from the highest healthy candidate (default: 3)" }, .{ "--out FILE", "Save a new report without endpoint URLs or credentials" }, .{ "--dry-run", "Preview configuration changes; probes still record health" } },
        .notes = "Pools are local, profile- and chain-scoped, with up to 32 named endpoints.\nURLs stay in a 0600 file; reports retain 20 health observations and cumulative\nsuccess/failure counts without RPC credentials or raw provider errors.\nUse/choose verify chain ID and canonical head before updating the profile.\nPrivate-only filtering excludes public and unknown endpoints before probing.\nPrivacy classes are your declarations, not claims verified by the CLI.\nSelection is explicit; failed transactions are never retried on another provider.",
    } else if (c.eq(u8, name, "recipients")) .{
        .usage = &.{ "chainwall recipients list POLICY --vault ACCOUNT", "chainwall recipients add POLICY --vault ACCOUNT --recipient ADDRESS|ACCOUNT --label NAME", "chainwall recipients authorize|revoke|remove POLICY LABEL|COMMITMENT --vault ACCOUNT", "chainwall recipients resolve POLICY LABEL|COMMITMENT --vault ACCOUNT --out FILE" },
        .options = &.{ .{ "--vault ADDRESS|ACCOUNT|@LABEL", "Tenant OKAccount or Safe receiving policy enforcement" }, .{ "--recipient ADDRESS|ACCOUNT|@LABEL", "Destination for an encrypted address-book entry" }, .{ "--label NAME", "Private label, required when adding an entry" }, .{ "--passphrase-file FILE", "Unlock the shared secret noninteractively" }, .{ "--offline", "List cached encrypted records without live authorization checks" }, .{ "--out FILE", "New report file; required for secret execution arguments" }, .{ "--dry-run", "Preview without broadcasting or exporting masks" } },
        .notes = "Uses the app's v2 policy/vault-bound commitments and encrypted KV journal.\nOnline commands refresh the journal; list never prints secret masks. Add changes\nthe address book only. Authorize and revoke update onchain policy state, possibly\nthrough a timelock. Remove requires revocation and no pending policy update.\nResolve checks live authorization and writes args[0]=recipient, args[1]=mask to\na new 0600 file. Use those arguments when preparing an operation.\nLabels may be ambiguous; a commitment selects an exact entry. Offline listings\nreport authorization as unknown. Shared secret rotation history is supported.",
    } else if (c.eq(u8, name, "auth") and c.eq(u8, verb, "recover")) .{
        .usage = &.{"chainwall auth recover --out passkey.json [--label NAME]"},
        .options = &.{ .{ "--auth-factory ADDRESS", "Override the saved AuthAccount factory candidate" }, .{ "--auth-account ADDRESS", "Select an account when a credential has multiple matches" }, .{ "--credential-file FILE", "Read existing public credential metadata instead of opening the browser" }, .{ "--out FILE", "New public signing profile (0600); required" }, .{ "--label NAME", "Display label for the recovered profile" }, .{ "--dry-run", "Check factory policy without requesting the passkey or writing a profile" } },
        .notes = "Select an existing resident passkey at the factory's configured origin.\nRecovery verifies credential-derived hashes, active onchain credentials, factory\ninstallation, and tenant/RP/origin bindings at a fresh canonical block.\nAmbiguous credentials require --auth-account; factories above 10000 accounts\nrequire it to bound discovery. Recovery creates no credential or transaction.\nExisting files are refused; interrupted requests leave a marker, not a profile.",
    } else if (c.eq(u8, name, "auth") and @import("schema.zig").contains("enroll create register inspect receipt", verb)) .{
        .usage = &.{ "chainwall auth enroll --out ENROLLMENT.json [--label NAME]", "chainwall auth create ENROLLMENT.json --out AUTH_PROFILE.json", "chainwall auth register|inspect AUTH_PROFILE.json", "chainwall auth receipt USER_OP_HASH --auth-profile FILE --bundler-url URL" },
        .options = &.{ .{ "--auth-factory ADDRESS", "Override the saved factory topology for enrollment" }, .{ "--scopes-file FILE", "Initial direct execution scopes as an ABI JSON array" }, .{ "--out FILE", "Write app-format enrollment or a public passkey profile (0600)" }, .{ "--label NAME", "Passkey display name" }, .{ "--dry-run", "Preview enrollment or account transactions without approval" } },
        .notes = "Enrollment opens a browser at the factory's configured WebAuthn origin.\n--approval-url selects an externally hosted approval page.\n--app-url selects an app with the CLI approval route.\nBoth retain the configured origin. Native macOS passkeys are deferred.\nCreate pins the factory implementation and writes a recoverable profile before broadcast.\nRegister resumes factory authorization, user allowlisting, and credential linking; queued\ntimelock actions must execute before rerunning register. Inspect checks live credential state.\nUse --auth-profile with transaction/signature commands. Foundry pays gas unless --bundler-url\nselects ERC-4337. Add --paymaster for a customer OKAccountPaymaster; omitting it keeps\nthe configured ZeroDev sponsorship flow. Bundlers manage their own nonce; --nonce is rejected.\nReceipt recovers a submitted UserOperation without repeating its signature or transaction.",
    } else if (c.eq(u8, name, "terms") and c.eq(u8, verb, "document")) .{
        .usage = &.{"chainwall terms document [IPFS_URI DOCUMENT_HASH] [options]"},
        .options = &.{ .{ "--ipfs-gateway URL", "Gateway path prefix (default: https://ipfs.io/ipfs)" }, .{ "--document-file FILE", "Verify a local copy instead of fetching IPFS" }, .{ "--out FILE", "Save verified document bytes to a new file" } },
        .notes = "Defaults to the initial terms; one hash selects a canonical published update.\nAn explicit IPFS URI and hash may be reviewed without making it official. Exact\ndocument bytes are checked before display or saving; size is limited to 1 MiB,\nUTF-8 is required, and redirects are refused. Acceptance is separate and accepts\nonly the initial document or a published DOCUMENT_HASH.",
    } else if (c.eq(u8, name, "analyze")) .{
        .usage = &.{"chainwall analyze FILE.ls|program.json|bytecode.hex [options]"},
        .options = &(compiler_options ++ [_]Row{ .{ "--read-only", "Report write and native-transfer violations" }, .{ "--linked", "Require exactly one stack result on every terminal path" }, .{ "--out FILE", "Save the JSON analysis report" } }),
        .notes = "Source input uses the preprocessor by default. Reports calls, argument provenance,\nreferences, terminal stacks, runtime counters and warnings. Analysis is bounded;\nincomplete analysis and violations return a nonzero exit status. Compiler JSON\nincludes the same default report. Analysis does not execute or authorize a program.",
    } else if (c.eq(u8, name, "policies") and c.eq(u8, verb, "simulate")) .{
        .usage = &.{"chainwall policies simulate INPUT.json [--out REPORT.json]"},
        .notes = "Input uses the generated Interact simulatePolicyProgram ABI: policyId and input\nwith interactionId, interactionArgs, nativeValue, operationId, payloadHash, actor\nand vault. Uses a pinned eth_call, with Interact as sender, and decodes the\nprotocol's rollback sentinel. Zero results and reverts return nonzero. No signing.",
    } else if (c.eq(u8, name, "transactions") and @import("schema.zig").contains("list track refresh wait speed-up cancel", verb)) .{
        .usage = &.{ "chainwall transactions list [--start N --count N]", "chainwall transactions track HASH", "chainwall transactions refresh [HASH]", "chainwall transactions wait HASH [--timeout SECONDS --confirmations N]", "chainwall transactions speed-up|cancel HASH [--dry-run]" },
        .options = &.{ .{ "--lookback N", "Replacement search depth, 0..1024 blocks (default: 64)" }, .{ "--confirmations N", "Required confirmations for track/refresh/wait (default: 1)" }, .{ "--timeout SECONDS", "Wait duration, 0..86400 (default: 120; zero checks once)" }, .{ "--poll-interval SECONDS", "Wait polling interval, 1..60 (default: 2)" }, .{ "--start N --count N", "Page cached list or bulk refresh; count at most 100" }, .{ "--bump PERCENT", "Minimum fee increase for speed-up/cancel (default: 15)" }, .{ "--out FILE", "Reserve a new private report file" } },
        .notes = "Foundry submissions save their hash before receipt polling. List is an offline\nchain-scoped cache. Track/refresh/wait verify RPC identity and canonical receipts.\nWait exits nonzero for pending, unknown, reverted, cancelled or replaced payloads.\nA consumed nonce without a replacement inside --lookback is nonce-used, never\nproof of success. Refresh is read-only onchain and never resubmits.\nSpeed-up requires the original sender and pending nonce, preserving destination,\ncalldata, value and access list. Fees rise by at least --bump; explicit caps must\nsatisfy that minimum. Legacy and EIP-1559 fees retain their original model.\nCancel sends zero value and empty data to the sender, who must have no code and\nbe cancelling its next nonce. It competes with the original until one is mined.\nPasskey/UserOperation replacement, blobs and EIP-7702 transactions are excluded.\nUse auth receipt for saved UserOperation handles. Recovered receipts do not\nautomatically resume a multi-stage deployment or finalize an application workflow.",
    } else if (c.eq(u8, name, "transactions") and c.eq(u8, verb, "estimate")) .{
        .usage = &.{ "chainwall transactions estimate FILE --from ADDRESS|ACCOUNT [--out REPORT.json]", "chainwall <write command> --estimate --from ADDRESS|ACCOUNT" },
        .options = &.{ .{ "--gas-limit N", "Use this gas limit instead of estimate plus 20 percent" }, .{ "--max-fee AMOUNT --priority-fee AMOUNT", "EIP-1559 caps in exact wei or gwei" }, .{ "--gas-price AMOUNT --legacy", "Legacy fee model (gas-price implies legacy)" }, .{ "--block NUMBER|TAG", "Estimate at a chosen canonical block" }, .{ "--out FILE", "Save a new estimate report" } },
        .notes = "FILE accepts a dry-run report or {chainId,to,data,value,from?,nonce?}; omit to\nfor creation. Nested transaction envelopes and saved estimate reports work.\n--estimate implies --dry-run and cannot broadcast. Supply --from to avoid\nunlocking a wallet just to learn its address. Unsupported preview shapes fail.\nReports estimated execution fee, maximum execution fee, value, balance,\ncanonical block and exact transaction fields. The default gas margin is 20%;\ndefault EIP-1559 maximum is twice base fee plus the RPC priority suggestion.\nL1 data fees on rollups and other chain-specific charges are not included.\nMulti-stage deployment estimates only the displayed stage; estimate later stages\nafter prerequisites are mined. Required signatures must already be present.\nPasskey/UserOperation fee review stays in its browser approval flow.",
    } else if (c.eq(u8, name, "transactions")) .{
        .usage = &.{ "chainwall transactions inspect HASH [HASH ...]", "chainwall transactions source HASH [HASH ...] [--out calls.ls]", "chainwall transactions estimate FILE --from ACCOUNT", "chainwall transactions list | track HASH | refresh [HASH] | wait HASH", "chainwall transactions speed-up|cancel HASH [--dry-run]" },
        .options = &.{ .{ "--abi ADDRESS=FILE", "Use a local ABI or compiler artifact for this target/emitter (repeatable)" }, .{ "--offline", "Use local/cached ABIs; transaction and receipt reads still use RPC" }, .{ "--refresh-abi", "Refresh explorer ABIs, including proxy implementation ABIs" }, .{ "--program-out FILE", "Save complete compiler JSON with ABI settings and registry metadata" }, .{ "--out FILE", "Save inspection JSON or plain Lambdascript source" } },
        .notes = "No signer or selected Registry is required. Chain ID and mined transaction/receipt\nblock hashes are verified. Pending, successful, and reverted states remain distinct.\nIndexed dynamic event values remain hashes. Unknown or malformed calls/logs retain\ntheir raw data and decoding errors. Multiple hashes generate writes in the given order;\nsource generation never silently omits a call. Use --program-out to retain ABI settings\nfor recursive tuples, arrays, bytes, and strings. Catalog references use the selected\ntenant's cached contracts; direct targets use app-format @chain/address identifiers.\nInspect generated references before publishing. No transaction is signed or replayed.",
    } else if (c.eq(u8, name, "upgrade")) .{
        .usage = &.{ "chainwall upgrade releases", "chainwall upgrade deploy RELEASE [--constructor-file FILE]", "chainwall upgrade inspect RELEASE [--target ADDRESS]", "chainwall upgrade verify RELEASE ADDRESS", "chainwall upgrade propose RELEASE IMPLEMENTATION [--target ADDRESS]", "chainwall upgrade release ACTION.json", "chainwall upgrade status|approve|execute|cancel ACTION_ID" },
        .options = &.{ .{ "--constructor-file FILE", "Named or positional constructor arguments as JSON" }, .{ "--target ADDRESS", "Override the tenant component; required for individual accounts" }, .{ "--data-file FILE", "Hex migration calldata (Registry upgrades require empty data)" }, .{ "--out FILE", "Reserve a new recovery file before broadcasting (0600)" }, .{ "--dry-run", "Verify and preview a transaction without signing" } },
        .notes = "Release names accept camelCase or kebab-case. Deployment uses embedded bytecode.\nVerification compares immutable-masked runtime, component, protocol, UUPS, and delegated\nrelease dependencies. Proposals verify the target Registry and raw implementation slot.\nRelease JSON accepts the kinds listed by schemas show upgrade-action. Governance may execute\nimmediately or queue an action; inspect its status before approval or execution.\nSuccessful transitions invalidate prior runtime authorizations. Terminal payloads may be\npruned onchain; keep --out reports to retain the candidate and verification evidence.\nArtifact matching does not establish arbitrary migration or storage-layout safety.\nUse artifacts releases to inspect the complete manifests and storage fingerprints.",
    } else if (c.eq(u8, name, "profile")) .{
        .usage = &.{ "chainwall profile list", "chainwall profile create NAME", "chainwall profile use NAME" },
        .notes = "Use --profile NAME to select a profile for one command.",
    } else if (c.eq(u8, name, "config")) .{
        .usage = &.{ "chainwall config show|get KEY|set KEY VALUE|unset KEY", "chainwall config import FILE [--passphrase-file FILE]", "chainwall config export [FILE|-] [--passphrase-file FILE]", "chainwall config generate-secret [--passphrase-file FILE]" },
        .options = &.{ .{ "--passphrase-file FILE", "Unlock the locally encrypted shared secret" }, .{ "--out FILE", "Alternative export destination" } },
        .notes = "Import/export uses the app's version-2 JSON, including the KV shared secret and API key.\nExport files use mode 0600; omit FILE for stdout.\nGenerate-secret stores a random shared secret encrypted locally and prints only its signer.\nIt refuses to replace an existing secret; connected KVs must use kv rotate.\nA later kv create uses this saved secret unless --secret-file is supplied.\nKeys: chain, rpc_url, instance, account, keystore, password_file, etherscan_api_key,\netherscan_api_key_env, etherscan_url, factory, kv_factory, kv_address, kv_chain,\nkv_rpc_url, interact, editor, rpc.CHAIN, instances.CHAIN, interacts.CHAIN",
    } else if (c.eq(u8, name, "kv")) .{
        .usage = &.{ "chainwall kv create [--passphrase-file FILE]", "chainwall kv connect ADDRESS --secret-file FILE [--passphrase-file FILE]", "chainwall kv rotate [--secret-file FILE] [--dry-run]", "chainwall kv rotate --resume", "chainwall kv rotation-status|history" },
        .options = &.{ .{ "--passphrase-file FILE", "Unlock local secret storage" }, .{ "--secret-file FILE", "Read a 32-byte secret as 0x hex; rotation otherwise generates one" }, .{ "--resume", "Use the encrypted saved rotation without generating another secret" }, .{ "--dry-run", "Save a rotation plan and preview calldata; --resume submits it" } },
        .notes = "Uses the bundled Arbitrum factory unless kv_factory is configured.\nNew instances enable indexing. Secrets and pending rotations stay encrypted in SQLite.\nRotation requires the KV owner and the current secret. The old key is encrypted by\nthe new key in the Chainwall key-history format. The local head changes only after matching signer,\nnonce and history-entry evidence. Resume recovers a mined rotation without resending.\nHistory verifies and caches up to 64 secrets, without printing keys. Unlock completions\nagain after rotation to use the refreshed label keys. Export config to share the new head.",
    } else if (@import("schema.zig").contains("accounts safes", name) and c.eq(u8, verb, "fund")) .{
        .usage = &.{"chainwall accounts|safes fund ADDRESS|ACCOUNT|@LABEL --value AMOUNT [--dry-run]"},
        .options = &.{ .{ "--value AMOUNT", "Positive wei integer or exact unit amount, e.g. 0.1ether or 10gwei" }, .{ "--account-factory | --safe-factory ADDRESS", "Override the tenant factory used to verify the destination" }, .{ "--dry-run", "Verify the destination and preview the transfer without signing" } },
        .notes = "Requires a registered, factory-managed account with verified tenant bindings.\nTransfers native currency from the selected signer using empty calldata.\nAmounts never use floating point or round excess decimal precision.\nThe receipt is saved to the transaction journal before reporting success.",
    } else if (@import("schema.zig").contains("accounts safes", name) and @import("schema.zig").contains("assets activity", verb)) .{
        .usage = &.{ "chainwall accounts|safes assets ADDRESS [options]", "chainwall accounts|safes activity ADDRESS [options]" },
        .options = &.{ .{ "--start N --count N", "Page offset and size (default 0/20; maximum count 100)" }, .{ "--token-id PATH|HASH", "Select token IDs for assets; repeatable, accepts @labels" }, .{ "--max-age SECONDS", "Valuation freshness bound (default 3600; must be positive)" }, .{ "--logs", "Read activity from RPC logs instead of the recent index" }, .{ "--from-block N", "Activity log lower bound (default: last 10000 blocks)" }, .{ "--block NUMBER|TAG", "Pin balances, prices and history upper bound" }, .{ "--out FILE", "Save the report as JSON" } },
        .notes = "Reads require no signer. Assets discover the live Registry token catalog; metadata, balances and prices\nare read at one block, independently of optional execution history indexing.\nNative balance appears on the first page. Unknown balances/prices remain null\nwith errors. USD18 valuations use the Registry's conservative exact-ceiling path\nand enforce oracle freshness/sequencer rules. Subtotals cover priced rows only.\nActivity uses the capped recent execution index by default; --logs provides\ntransaction hashes and a stated block range, including without indexing.\nUse narrow ranges for providers with strict log limits. These are Chainwall\nexecution records, not a complete history of every account transaction.",
    } else if (c.eq(u8, name, "accounts") and (c.eq(u8, verb, "create") or c.eq(u8, verb, "import") or c.eq(u8, verb, "inspect"))) .{
        .usage = &.{ "chainwall accounts create --salt BYTES32|PHRASE [options]", "chainwall accounts import|inspect ADDRESS [options]" },
        .options = &.{ .{ "--account-factory ADDRESS", "Override saved deployment/app topology" }, .{ "--salt BYTES32|PHRASE", "32-byte hex or phrase hashed with Keccak-256" }, .{ "--dry-run", "Predict address and preview the transaction" } },
        .notes = "Verifies the factory's Interact and Registry bindings. Creation registers the account.\nImport re-registers an existing account from this tenant's factory; unrelated accounts are rejected.\nInspect reports provenance, registration, Registry/Interact links, and engine runtime compatibility.",
    } else if (c.eq(u8, name, "safes") and (c.eq(u8, verb, "create") or c.eq(u8, verb, "import") or c.eq(u8, verb, "sign-import") or c.eq(u8, verb, "inspect"))) .{
        .usage = &.{ "chainwall safes create --salt BYTES32|PHRASE --owners ADDRESS|ACCOUNT,... [options]", "chainwall safes inspect ADDRESS [options]", "chainwall safes sign-import ADDRESS --out SIGNATURE.json [options]", "chainwall safes import ADDRESS --signatures-file SIGNATURES.json [options]" },
        .options = &.{ .{ "--safe-factory ADDRESS", "Override saved deployment/app topology" }, .{ "--salt BYTES32|PHRASE", "32-byte hex or phrase hashed with Keccak-256" }, .{ "--owners ADDRESS|ACCOUNT,...", "Unique owner addresses or Foundry account names" }, .{ "--threshold N", "Required owner signatures (default: 1)" }, .{ "--module | --no-module", "Optional OKModule; default enabled for a single owner" }, .{ "--value WEI", "Fund a new Safe during creation" }, .{ "--preserve-extensions", "Import with explicit allowlists of existing modules/fallback" }, .{ "--no-module-check", "Import trusting all current and future modules; use on sign-import too" }, .{ "--signatures-file FILE", "JSON array of sign-import results" }, .{ "--out FILE", "Write an import signature or result" }, .{ "--dry-run", "Preview or predict without signing or broadcasting" } },
        .notes = "Managed Safes always install the Chainwall guard and execution gateway.\nOptional OKModule requires exactly one owner and threshold 1.\nImport: each owner runs sign-import; combine outputs into an array, then run import.\nUse identical module/preservation flags when signing and importing. Signatures bind the live Safe nonce.\nPreservation never enables a new OKModule. Inspect checks proxy/singleton authenticity and version-aware module lists.\nUnsupported storage fields are null; supported but unset fields are zero addresses.\nUnreviewed versions can be inspected but cannot be imported.",
    } else if (c.eq(u8, name, "operations") and @import("schema.zig").contains("direct direct-sign-actor direct-sign", verb)) .{
        .usage = &.{ "chainwall operations direct INPUT.json [--via account|safe|module] [--dry-run]", "chainwall operations direct-sign-actor INPUT.json --via safe --out ACTOR.json", "chainwall operations direct-sign INPUT.json --via safe --actor-signature-file ACTOR.json --out OWNER.json" },
        .options = &.{ .{ "--via account|safe|module", "Execution route (default: account)" }, .{ "--actor ADDRESS|ACCOUNT", "Logical actor; defaults to the actor file or selected signer" }, .{ "--max-steps N", "Execution step bound (default: 100000)" }, .{ "--actor-signature-file FILE", "Saved authorization bound to the current actor nonce and execution context" }, .{ "--signatures-file FILE", "JSON array of direct-sign results for Safe owners" }, .{ "--reveal-file FILE", "Private interaction reveal tuple" }, .{ "--out FILE", "Reserve a new private report before signing and retain the receipt" }, .{ "--dry-run", "Read context and build an unsigned preview without signing or broadcasting" } },
        .notes = "Input: safe (destination account), policyId, interactionId, deadline (future Unix seconds),\nargs (default []), nativeValue (default 0). IDs also accept plaintext names.\nThe actor must satisfy the policy alone; the contracts enforce all permissions.\nAccount mode signs and executes directly. Passkeys use their protocol-call approval.\nSafe mode: direct-sign-actor, direct-sign by each owner, then direct with both files.\nModule mode discovers the enabled tenant OKModule and signs the actor automatically.\nUse --actor-signature-file for relaying; Safe owner signatures are not required.\nPasskeys use an EOA sponsor or --bundler-url for the full UserOperation flow.\nAdd --paymaster for a customer OKAccountPaymaster in account mode.\nKeep input, --via, --max-steps and --reveal-file identical across signing steps.\nSignatures bind chain, Interact, account, policy, inputs, runtime binding, deadline and nonce.\nSubmission revalidates context and simulates the signed transaction.\nUnsigned dry-run previews do not prove executability. Existing proposals use operations execute.",
    } else if (c.eq(u8, name, "operations")) .{
        .usage = &.{ "chainwall operations list [options]", "chainwall operations propose INPUT.json --out PROPOSAL.json", "chainwall operations publish PROPOSAL.json [--passphrase-file FILE]", "chainwall operations approve|withdraw|status ID", "chainwall operations simulate|execute PROPOSAL.json [--via account|safe|module]", "chainwall operations sign-actor|sign PROPOSAL.json --via safe --out FILE" },
        .options = &.{ .{ "--out FILE", "Save a proposal, signature, or execution result" }, .{ "--via account|safe|module", "Execution path (default: account)" }, .{ "--max-steps N", "Execution step limit (default: 100000)" }, .{ "--approve", "Approve and execute together" }, .{ "--actor-signature-file FILE", "Safe actor authorization from sign-actor" }, .{ "--signatures-file FILE", "JSON array of Safe owner signatures from sign" }, .{ "--reveal-file FILE", "Private interaction reveal as an ABI tuple object" }, .{ "--passphrase-file FILE", "Unlock local operation storage" }, .{ "--safe ADDRESS", "Filter the cached list by account" }, .{ "--all-chains", "List operations on all execution chains" }, .{ "--view operational|audit", "Use verified checkpoints or show every raw proposal" }, .{ "--local", "List encrypted local imports without RPC or KV setup" }, .{ "--status active|expired|closed|mismatch|unknown", "Filter the cached list" }, .{ "--start N --count N", "Select a list page (defaults: 0 and 50)" } },
        .notes = "Input: safe, interactionId, policyId, deadline, args (default []), nativeValue (default 0).\nPropose reserves a mode-0600 output file before sending. Publish is a separate retryable KV write.\nExecution consumes v2 payloads, v3 journals, or freshly verified private share envelopes.\nSafe flow: sign-actor, sign by each owner, then execute with a JSON signature array.\nModule flow: --via module signs the actor and executes through the enabled tenant OKModule.\nSaved actor signatures also work; simulate requires a signed actor file and a relayer.\nPasskeys support EOA sponsorship and --bundler-url. Add --paymaster for customer-funded account mode.\nUse identical --approve, --max-steps and --reveal-file options throughout signing and execution.\nConfigure interact or [interacts]. Run sync before list. --dry-run never broadcasts.",
    } else if (c.eq(u8, name, "sync") and p.len == 1) .{
        .usage = &.{"chainwall sync [options]"},
        .options = &.{ .{ "--only DATASETS", "Comma-separated Registry datasets, timelocks, or operations" }, .{ "--full", "Rebuild selected snapshots" }, .{ "--from-block N", "Start explorer discovery at this block" }, .{ "--lookback N", "Reorg lookback (default: 128)" }, .{ "--confirmations N", "Required block confirmations (default: 0)" }, .{ "--passphrase-file FILE", "Unlock encrypted operation storage" } },
        .notes = "Datasets: users, groups, policies, orgs, contracts, tokens, interactions, safes, accounts, labels, timelocks, operations.",
    } else if (c.eq(u8, name, "login")) .{
        .usage = &.{"chainwall login ADDRESS [--chain NAME|ID] [--rpc-url URL] [--account NAME]"},
        .notes = "Accepts a Registry address or the SafeFactory instance address used by the app.\nInstances resolve through INTERACT_CONTRACT, then Interact.registry().\nVerifies chain, deployed code, and component identities before saving.\nSaves the resolved Registry in instance and [instances], and updates [rpc].\nAn instance login also saves its Interact address for operation status checks.",
    } else if (c.eq(u8, name, "abi")) .{
        .usage = &.{"chainwall abi ADDRESS [options]"},
        .options = &.{ .{ "--refresh-abi", "Refresh verified ABI metadata" }, .{ "--etherscan-url URL", "Override the explorer API endpoint" }, .{ "--out FILE", "Save the ABI as JSON" } },
    } else if (c.eq(u8, name, "compile") or (c.eq(u8, name, "interactions") and c.eq(u8, verb, "compile"))) .{
        .usage = try oneUsage(a, try a.print("chainwall {s}compile FILE.ls [options]", .{if (c.eq(u8, name, "interactions")) "interactions " else ""})),
        .options = &(compiler_options ++ [_]Row{ .{ "--out FILE", "Save the full compiler JSON" }, .{ "--json", "Print compiler JSON instead of bytecode" } }),
        .notes = "Compiles preprocessor-level Lambdascript without publishing.",
    } else if (c.eq(u8, name, "interactions") and (c.eq(u8, verb, "add") or c.eq(u8, verb, "update"))) .{
        .usage = try oneUsage(a, try a.print("chainwall interactions {s} FILE.ls [options]", .{verb})),
        .options = &([_]Row{ .{ "--id NAME|BYTES32", "Override the filename-based interaction ID" }, .{ "--flags INTEGER", "Set interaction flags" }, .{ "--linked-file FILE", "Load linked entries from JSON" }, .{ "--out FILE", "Save the publication bundle before submission" }, .{ "--dry-run", "Preview publication calldata without signing" } } ++ compiler_options),
        .notes = "Add requires a new ID; update requires an existing ID. Updates preserve flags\nand linked entries unless explicitly supplied. Metadata preparation uses RPC.",
    } else if (c.eq(u8, name, "interactions") and (c.eq(u8, verb, "activate") or c.eq(u8, verb, "deactivate"))) .{
        .usage = try oneUsage(a, try a.print("chainwall interactions {s} NAME|BYTES32 [--dry-run]", .{verb})),
    } else if (c.eq(u8, name, "interactions") and c.eq(u8, verb, "source")) .{
        .usage = &.{"chainwall interactions source NAME|ID [options]"},
        .options = &source_options,
        .notes = "Uses the cached interaction when available. --offline requires a cached script;\n--live reads the current script. JSON output includes id, bytecode, source, and restored.",
    } else if (c.eq(u8, name, "decompile") or c.eq(u8, name, "disasm")) .{
        .usage = try oneUsage(a, try a.print("chainwall {s} program.json|bytecode.hex [options]", .{name})),
        .options = if (c.eq(u8, name, "disasm")) &([_]Row{.{ "--source", "Display readable Lambdascript instead of opcodes" }} ++ source_options) else &source_options,
        .notes = "Decompile and disasm --source restore Registry names and ABI member calls.\nSource options use saved compiler metadata or the selected Registry/ABI cache.\nFor plain disasm, use --settings and --out; metadata options require --source.",
    } else if (c.eq(u8, name, "artifacts")) .{
        .usage = &.{"chainwall artifacts [CONTRACT_NAME|storage|deployment]"},
        .notes = "Export the embedded contract compiler JSON reference.",
    } else if (c.eq(u8, name, "labels")) .{
        .usage = &.{ "chainwall labels encode TEXT --scope SCOPE [--entity ADDRESS]", "chainwall labels decode HEX --scope SCOPE [--entity ADDRESS]", "chainwall labels set KIND ID TEXT [--plain]", "chainwall labels get KIND ID [--raw]", "chainwall labels clear KIND ID" },
        .options = &.{ .{ "--scope SCOPE", "group-id, interaction-id, policy-id, contract-label, user-label, account-label" }, .{ "--entity ADDRESS", "Required only for user-label and account-label" }, .{ "--passphrase-file FILE", "Unlock the selected secret and its cached history" }, .{ "--plain", "Store public ABI string metadata instead of an encrypted label" }, .{ "--raw", "Read onchain hex without unlocking or decoding" }, .{ "--dry-run", "Preview set/clear calldata without broadcasting" } },
        .notes = "Kinds: user, account, safe (account metadata), contract (bytes32 catalog ID).\nSet encrypts by default. Labels allow up to 16 UTF-8 bytes when encrypted.\nAES-SIV matches the app and binds chain, Registry, scope and address context.\nEncode/decode work offline. Get/set/clear use live Registry metadata and governance.\nDecode reads cached ancestor keys; kv history refreshes that cache. Sync labels\nafter confirmed writes to refresh completions. @labels select existing entities.",
    } else if (c.eq(u8, name, "id")) .{
        .usage = &.{ "chainwall id NAME|BYTES32", "chainwall id LABEL --encrypt --scope SCOPE [--passphrase-file FILE]" },
        .options = &.{ .{ "--encrypt", "Create a deterministic app-compatible encrypted ID" }, .{ "--scope SCOPE", "group-id, interaction-id, policy-id, or contract-label" }, .{ "--passphrase-file FILE", "Unlock the selected shared secret" } },
        .notes = "Default: Keccak-256 identifier or validation of an existing bytes32.\nEncrypted IDs allow 16 UTF-8 bytes. Their chain, Registry and scope must match\nthe app. Always prints a bytes32 suitable for a shell variable. Preserve IDs\nafter secret rotation: use stored IDs or @labels instead of encoding them again.",
    } else blk: {
        var cached = c.eq(u8, name, "timelocks");
        for (sync.datasets) |dataset| if (c.eq(u8, name, dataset.name) and c.eq(u8, verb, "list")) {
            cached = true;
        };
        if (!cached) return null;
        break :blk Page{
            .usage = try oneUsage(a, try a.print("chainwall {s} list [options]", .{name})),
            .options = if (c.eq(u8, name, "timelocks")) page_options[0..3] else &page_options,
            .notes = if (c.eq(u8, name, "timelocks")) "Run chainwall sync --only timelocks to refresh history.\nUse chainwall timelock pending for the live pending queue." else "Cached results include their last sync block. Run chainwall sync to refresh.",
        };
    };
    return value;
}

fn oneUsage(a: c.A, value: []const u8) ![]const []const u8 {
    return a.dupe([]const u8, &.{value});
}
