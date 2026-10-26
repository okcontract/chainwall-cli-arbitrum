# Editing Lambdascript with Chainwall

`chainwall-lsp` brings Chainwall-aware completion, diagnostics, navigation, and
compilation to editors that support the Language Server Protocol. It edits
individual `.ls` files using the same native compiler and JSON artifact format
as `chainwall compile`.

This guide assumes you have the distributed binaries. No Zig installation or system SQLite is needed to run the binaries.
See the [CLI manual](MANUAL.md) for accounts, permissions, transaction submission,
timelocks, and operation journals.

## Start with an instance

A Chainwall Registry names the contracts and tokens your programs use and stores
interactions, users, groups, policies, and registered accounts. A name such as
`@token(circle/usdc)` is resolved in one Registry on one chain. Identical names
can have different deployments on different chains. Selecting the right profile
is part of selecting the meaning of your program.

Place `chainwall` and `chainwall-lsp` on your `PATH`, then check:

```sh
chainwall --version
chainwall-lsp --version
```

Configure a CLI profile, substituting your Registry address and RPC endpoint:

```sh
chainwall profile create work
chainwall profile use work
chainwall config set chain base
chainwall config set rpc_url "$BASE_RPC_URL"
chainwall login "$REGISTRY_ADDRESS"
chainwall sync --only users,groups,policies,orgs,contracts,tokens,interactions,safes,accounts
```

The editor reads the resulting public catalog from
`~/.config/chainwall/chainwall.sqlite3`. A signer is not needed for editing. The
server does not invoke Foundry, unlock accounts, ask for a vault passphrase, or
send transactions. It uses native RPC for its explicit catalog refresh command.
The CLI uses Foundry for its own wallet and transaction operations.

Create a directory for your programs. Put this `chainwall-lsp.json` at its root:

```json
{
  "profile": "work",
  "chain": "base"
}
```

Configure your editor as described below and open `transfer.ls`:

```lambdascript
let token = @token(circle/usdc)
and recipient = $arg0
and amount = $arg1
in $require(token.transfer(recipient, amount))
```

This example requires the selected Registry to contain `circle/usdc`, with a
deployment whose ABI has `transfer(address,uint256)`. `$arg0` and `$arg1` are
execution arguments. Integer token amounts use the token's smallest unit, so
1 USDC is normally written as `1000000` when its configured decimals are 6.

## Connect your editor

The executable speaks LSP 3.17 over stdin/stdout. Configure a language named
`lambdascript`, associate `.ls` files with it, and launch:

```sh
chainwall-lsp --stdio
```

There is no listening TCP port. Starting this command in a terminal without an
LSP client makes it wait for protocol messages. Use `--help` to inspect options.
Editors must send file contents with `textDocument/didOpen`; the server uses the
current editor buffer, including unsaved edits.

### Neovim

The distribution includes a native Neovim package with `.ls` file association,
syntax highlighting, indentation defaults, and automatic LSP attachment. It
requires Neovim 0.11 or later and is tested with
[Neovim 0.11.5](https://github.com/neovim/neovim/releases/tag/v0.11.5).
Install the package from your unpacked release (replace `PREFIX`):

```sh
mkdir -p ~/.config/nvim/pack/chainwall/start
cp -R PREFIX/share/chainwall/editors/neovim ~/.config/nvim/pack/chainwall/start/chainwall
```

For a source checkout, copy `editors/neovim` instead. Put `chainwall-lsp` on your
`PATH`, then restart Neovim. Keep the package and binaries from the same release;
update by replacing that `chainwall` package directory. The `.ls` association
takes precedence over other languages using that extension. To supply startup
options, set this before packages load in `init.lua`:

```lua
vim.g.chainwall_lsp_cmd = { 'chainwall-lsp', '--stdio', '--profile', 'work' }
```

If you prefer to maintain your own configuration, the equivalent native client
setup is:

```lua
vim.filetype.add({ extension = { ls = 'lambdascript' } })
vim.lsp.config('chainwall', {
  cmd = { 'chainwall-lsp', '--stdio' },
  filetypes = { 'lambdascript' },
  root_markers = { 'chainwall-lsp.json', '.git' },
})
vim.lsp.enable('chainwall')
```

Open a `.ls` file below `chainwall-lsp.json`. Use `K` for hover and insert-mode
`Ctrl-X Ctrl-O` for completion. The standard LSP actions provide rename, references,
formatting, and code actions. `:checkhealth vim.lsp` helps diagnose attachment.
See [Neovim's LSP guide](https://neovim.io/doc/user/lsp/) for client configuration.
The package provides syntax highlighting before the server attaches; semantic
tokens refine highlighting once it is running. The native Zig smoke test runs
a real headless editor, checks file association and highlighting, and requests
hover and diagnostics from the actual server:

```sh
zig build test-editor -Dneovim=/path/to/nvim
```

For example, open the code-action menu with:

```vim
:lua vim.lsp.buf.code_action()
```

Choose **Open compiled Chainwall program JSON** to inspect the current buffer's
artifact, or **Refresh Chainwall catalog** to update public Registry metadata.
Enable inlay hints with:

```vim
:lua vim.lsp.inlay_hint.enable(true)
```

### Helix

Add to your Helix `languages.toml`, either in its configuration directory or in
the project's `.helix` directory:

```toml
[language-server.chainwall]
command = "chainwall-lsp"
args = ["--stdio"]
timeout = 120

[[language]]
name = "lambdascript"
scope = "source.lambdascript"
file-types = ["ls"]
roots = ["chainwall-lsp.json", ".git"]
language-servers = ["chainwall"]
indent = { tab-width = 2, unit = "  " }
```

This configures LSP features; it does not install a Tree-sitter grammar. See
[Helix language configuration](https://docs.helix-editor.com/languages.html)
for client options and workspace commands. Catalog refresh can take longer than
ordinary editor requests, which is why this example increases the request timeout.

### Other editors, including VS Code

Use an LSP client capable of registering a custom language and executable. Set
the language ID to `lambdascript`, the file extension to `.ls`, and the transport
to stdio. Supply the workspace folder containing `chainwall-lsp.json`.

VS Code needs a language-client extension to launch a standalone LSP server;
putting the binary on `PATH` alone does not register the language. This release
includes the server, not a VS Code extension. The protocol and commands below
provide the integration surface for custom clients.

## Completion and assistance

| While editing | Assistance |
| --- | --- |
| `@token(cir` | Token paths from the selected Registry |
| `@contract(uni` | Contract paths from the selected Registry |
| `token.` | ABI methods, including through local aliases |
| `token.transfer(` | Signatures, parameter names, and inlay hints |
| `$read(token, ` | Read-only ABI selectors |
| `$write(token, ` | Write and payable ABI selectors |
| `$calli(` | Cached interaction IDs |
| `$price(` | Registered tokens |
| A partial name or hash | Local bindings and matching public Registry entries |
| `$` | Compiler builtins and their documentation |
| An empty file | The app's interaction templates |

The public catalog includes contracts, tokens, interactions, users, groups,
policies, organizations, safes, and accounts. Contract/token paths use Registry
names. Other entries may be identifiable only by their onchain address or hash.
Encrypted app labels and private operation journals are not decrypted by the
server.

ABI completions show canonical signatures and mutability. Snippet-capable
clients receive argument placeholders, tuple shapes, and explicit native-value
options for payable methods. Completing an empty argument list fills it without
duplicating parentheses and preserves existing call options. Completing a call
with arguments preserves the values and filters incompatible arities.

For same-arity overloads, completion adds exact type annotations where needed,
such as `5 :: uint8`. Existing conflicting annotations filter out that overload.
Signature help displays available overloads; compilation remains the authority
on whether the complete call is valid. The server uses the same bounded recursive
ABI support as the compiler, rather than offering every ABI type indiscriminately.

Diagnostics cover parsing, unknown variables, Registry kind/name mismatches,
missing ABIs, overload ambiguity, payable-value requirements, and compiler
errors. An unsynced catalog produces a warning; an absent name in a synced
catalog produces an error. Fixes include switching between `@contract` and
`@token` and fetching an unavailable ABI.

Hover shows binding values, builtin documentation, ABI signatures and selectors,
or public Registry metadata. Go-to-definition navigates to local declarations or
a generated JSON view of a Registry entry. These metadata views are cached
read-only reference material; editing them does not change the Registry.

Local references, highlights, and rename respect case-insensitive binding names
and lexical shadowing. Rename rejects names that could capture another binding.
References are within the current document. Workspace symbol search includes
bindings in open documents and public entries from each configured workspace.

Document symbols, semantic highlighting, selection expansion, folding, and
formatting are also available. Formatting preserves program tokens and uses
spaces, with the client's tab width clamped to 1 through 8. Invalid programs
receive no formatting edits. Parameter hints and compiler JSON code lenses are
optional editor UI features; enable them in your client if desired.

## ABIs and network access

Typing, completion, hover, diagnostics, and compilation read local data. They do
not make network requests. Catalog refresh and ABI retrieval are explicit actions.

Use the same Etherscan token configuration as the CLI:

```sh
chainwall --profile work config set etherscan_api_key_env ETHERSCAN_API_KEY
export ETHERSCAN_API_KEY='your-token'
```

Launch the editor from an environment containing that variable. A GUI editor
started separately may not inherit your shell's environment.

When an ABI is missing, place the cursor on the Registry reference and choose
**Fetch ABI for ...**. The server uses the selected chain and deployment, follows
the CLI's verified proxy ABI retrieval, and updates the shared ABI cache. To
force a refetch of an existing ABI, execute `chainwall.fetchAbi` with its target
hash or `org/id` path.

ABIs already fetched by `chainwall compile` are available in the editor. Their
chain and deployment identity are validated. For offline authoring, their age
does not trigger a refetch. `chainwall.status` reports invalid cache entries.

For unverified contracts or completely local workflows, provide ABI files:

```json
{
  "profile": "work",
  "abis": {
    "circle/usdc": "abi/usdc.json",
    "example/vault": "abi/vault.json"
  }
}
```

Each file can contain an ABI array or an artifact object with an `abi` field.
Keys accept `org/id` paths or 32-byte Registry hashes. Local files override cached
ABIs. A supplied ABI does not establish that a Registry name exists; that comes
from the synced catalog or explicit snapshot.

**Refresh Chainwall catalog** uses the CLI's paged-index sync engine to update
the nine public datasets in one SQLite transaction, with pinned canonical RPC
reads. It excludes timelocks and encrypted operation journals. These public entity
indexes exist independently of the Registry's optional indexing flag. Use the CLI
for timelock history and operation sync.

Only one refresh/fetch task runs at a time. Ordinary editor requests continue
while it runs. Clients can cancel a task through LSP cancellation. A failed or
cancelled catalog transaction retains the previous snapshot. Successful refresh
requests a diagnostic refresh when supported by the client; otherwise save the
buffer or run `chainwall.reload` to republish diagnostics.

## Configuration reference

The server accepts these command-line options:

```text
chainwall-lsp [--stdio] [--profile NAME] [--config-dir DIR]
              [--chain CHAIN] [--instance ADDRESS] [--rpc-url URL]
              [--snapshot FILE] [--settings FILE] [--abi TARGET=FILE]
```

Repeat `--abi` for multiple targets. Use an absolute binary path if your editor
has a different `PATH` from your shell.

Except for `--config-dir`, these settings can be supplied as LSP
`initializationOptions`, as `workspace/didChangeConfiguration` under
`settings.chainwall`, or in `chainwall-lsp.json`:

| JSON key | Value |
| --- | --- |
| `profile` | CLI profile name, such as `work` |
| `chain` | Supported CLI chain name or numeric chain ID |
| `instance` | Chainwall Registry address |
| `rpcUrl` | RPC endpoint used for explicit refresh |
| `snapshot` | Path to an offline compiler snapshot |
| `abis` | Map of target hashes or paths to local ABI files |
| `settings` | Compiler settings object or path to a settings/artifact JSON file |
| `readOnly` | Boolean; report MiniScript writes and native transfers as errors |
| `linked` | Boolean; require one result word on each terminal path |

Explicit option precedence, from lowest to highest, is command-line defaults,
initialization options, current editor settings, then the workspace file. Editor
configuration updates replace the previous editor settings layer. Nested `abis`
and `settings` objects are replaced as a unit, not merged by individual key.

The directory containing profiles, SQLite, and cached ABIs is selected only at
server startup: `--config-dir`, then `CHAINWALL_CONFIG_DIR`, then
`XDG_CONFIG_HOME/chainwall` or `~/.config/chainwall`. A relative directory resolves
from the server's startup working directory and stays the same for every
workspace folder. `configDir` in initialization options, editor settings, or
workspace JSON is rejected with `ConfigDirectoryRequiresStartupOption`. Move
existing `configDir` settings to the server's argument list or environment.

Keep this directory and its profiles under your control. Workspaces may select
a profile by name, but the credential environment-variable binding and explorer
endpoint both come from that profile in the startup-selected directory. Configure
server arguments and environment in trusted editor user settings. The server
cannot distinguish user settings from repository settings once the editor has
used them to launch a process.

Absent explicit options, the server uses the CLI's
`CHAINWALL_PROFILE`, `CHAINWALL_CHAIN`, `CHAINWALL_INSTANCE`, and
`CHAINWALL_RPC_URL` environment overrides, the active profile, and profile
defaults. No public RPC is selected automatically.

Relative snapshot, ABI, and compiler-settings paths resolve from the document's
workspace root. For a multi-root workspace, the longest matching workspace
folder selects its own `chainwall-lsp.json`; the server does not search arbitrary
parent directories.
Documents outside registered folders use the server's initial working directory.
Untitled documents use the first workspace folder when available. Unknown
configuration keys are rejected so misspellings do not silently change context.

For valuation programs that read the original interaction's arguments:

```json
{
  "profile": "work",
  "settings": {
    "argumentContext": "subject",
    "optimization": "size",
    "$validity": 1800,
    "$slippage": 5
  }
}
```

Ordinary interaction programs default to `argumentContext: "frame"`. Give
different program settings their own workspace folder or change the current
editor configuration. The `.ls` file alone does not embed compiler settings.

Profiles, workspace files, snapshots, and ABI files are reread on requests, so
external `chainwall sync` results become available without restarting. Saving,
watcher notifications, or `chainwall.reload` updates displayed diagnostics too.

### Offline snapshots

`snapshot` selects the same metadata format as `chainwall compile --snapshot`
and replaces the SQLite catalog for that workspace. Optional named `entries`
add completion and navigation without requiring a database:

```json
{
  "knownKindsByTargetHash": {
    "example/vault": "contract"
  },
  "abiByTargetHash": {
    "example/vault": []
  },
  "entries": [
    {
      "kind": "contract",
      "path": "example/vault",
      "address": "0x1111111111111111111111111111111111111111",
      "record": { "description": "Offline example" }
    }
  ]
}
```

Replace the empty ABI array with the actual ABI. Known kinds are `contract`,
`token`, or `contract+token`. Entry kinds additionally include `interaction`,
`user`, `safe`, `account`, `group`, `policy`, and `org`. Entries accept `hash`,
`label`, `path`, `address`, `implementation`, and public `record` fields. A supplied
path must hash to its ID. Addresses identify users, safes, and accounts; other
entries use 32-byte IDs. Interaction records use the CLI's `script` field for
stored bytecode. Hash-only snapshots cannot recover human names without entries.

Updating SQLite does not override a selected snapshot. Remove `snapshot` when
you want to resume using live-sync results.

## Compiler artifacts and client commands

The code lens and **Open compiled Chainwall program JSON** action compile the
current buffer and save a generated file below the config directory's
`lsp/compiled` directory. Supporting clients open it with `window/showDocument`;
other clients receive its path in a message. Compilation errors leave the prior
artifact intact. Generated JSON is replaced on the next successful invocation.

The artifact is `chainwall.program.v1`, matching the CLI: preprocessor-level
source, resolved core source, exact bytecode, bytecode hash, assembly, recovered
core source, compiler settings, reference analysis, and Registry/ABI metadata.
`sourceFile` is the buffer URI. Editor input uses the preprocessor-level language
by default, including `@token`/`@contract`, aliases, and ABI member calls.
Inspect this artifact before submitting the saved `.ls` file with the CLI.
Compiling or opening JSON does not publish an interaction.

Custom clients can issue `workspace/executeCommand`. Arguments are an array;
the first argument is normally the document URI:

| Command | Arguments | Result |
| --- | --- | --- |
| `chainwall.compile` | `[uri]` | Exact compiler JSON; no output file |
| `chainwall.analyze` | `[uri]` | MiniScript calls, argument provenance, references, limits, and findings |
| `chainwall.showCompiled` | `[uri]` | `{ "uri": ... }` for saved compiler JSON; opens it when supported |
| `chainwall.refresh` | `[uri]` | Chain, instance, pinned block, RPC request count |
| `chainwall.fetchAbi` | `[uri, target]` | Chain, instance, target hash, ABI |
| `chainwall.reload` | `[]` | Republishes diagnostics for open documents |
| `chainwall.status` | `[uri]` | Profile, chain, instance, entry count, checkpoints, ABI issues, snapshot path |
| `chainwall.templates` | `[]` | App template catalog, including source and companion metadata |
| `chainwall.decompileInteraction` | `[uri, interactionId]` | Compiler artifact with an editable preprocessor-level `source`, reconstructed from cached bytecode |

The custom request `chainwall/compile` also accepts
`{ "textDocument": { "uri": "file:///path/transfer.ls" } }` and returns the
compiler artifact. Compilation requires the document to be open. Catalog commands
can use a URI to select a workspace without opening the file.

`chainwall/analyze` accepts the same document parameter and returns the artifact's
`analysis` field. Every compiled artifact includes this report. Analysis issues
and configured read-only violations also appear in editor diagnostics. Both
options default to false. Analysis is bounded: `complete: false` means the
program could not be fully analyzed; `valid: false` also includes read-only
violations. Static findings do not establish onchain authorization or execution
success. Use CLI operation/policy simulation for explicit RPC preflight.

Decompilation uses the same postprocessor as `chainwall decompile`: cached
Registry names and ABIs restore short aliases, named read/write calls, payable
options, nested arguments, and overload annotations. `source` is the editable
Lambdascript draft; `coreSource` is its lowered form. Semantic highlighting,
completion, formatting, diagnostics, and compilation all accept this draft
directly. Offline snapshots may supply canonical names through
`registryReferencesByTargetHash`, as emitted in compiler JSON's `metadata`.

Decompilation requires a synced interaction or a snapshot interaction entry and
checks that recompilation reproduces the stored bytes exactly. Missing names or
ABIs retain raw IO where possible; unsupported bytecode or insufficient metadata
for an exact round trip produces an error. Metadata reads remain offline; use
`chainwall.refresh` and `chainwall.fetchAbi` explicitly to update them. Recovered
source is returned to the client; the original `.ls` file is never overwritten.

## Scope and troubleshooting

This server edits the onchain-compilable Lambdascript language. It does not run
the app's reactive evaluator, general-purpose imports/closures, live simulation,
gas estimation, or policy authorization checks. Template responses retain
companion valuation metadata, but inserting a template inserts its interaction
source only. Onchain acceptance still depends on current state,
permissions, policies, and execution arguments.

| Symptom | Check |
| --- | --- |
| No editor features | Executable path, `.ls` language association, workspace root, client logs |
| No Registry paths | `chainwall.status`, selected profile/chain/instance, then explicit sync |
| No method completion | Cached deployment and ABI, or configure an `abis` file |
| `MissingAbi` | Fetch ABI action, token environment, verified implementation, or local ABI |
| `RegistryKindMismatch` | Use the offered `@token`/`@contract` fix |
| Stale data | Refresh the catalog; refresh ABI separately after a deployment change |
| `ConfigurationUnavailable` | Correct the reported profile, JSON, settings, or SQLite error |
| `ConfigDirectoryRequiresStartupOption` | Move `configDir` to `--config-dir` or `CHAINWALL_CONFIG_DIR` in trusted server startup settings |
| `ResourceLimit` | Reduce document size/depth or split independent programs into files |
| Compile succeeds, submission fails | Inspect current Registry policies and execute through the CLI |

Supported resource limits are 128 open documents, 256 KiB per document, 2 MiB
per protocol message, 8,192 indexed syntax nodes, 256 syntax/index nesting levels,
and 10,000 public catalog entries per selected instance. General catalog
completion is capped at 250 results; workspace catalog search at 100 results.
Narrow the prefix when a result set is incomplete.

Compiler work also limits intermediate trees and total node allocations; see the
[library limits](COMPILER.md#library). Incremental edit batches reuse document
storage, and RPC ABI decoding budgets 32 MiB for decoded values per response.

UTF-16 positions are the default; clients may negotiate UTF-8. Incremental edits
apply sequentially and atomically, and stale document versions are ignored.
Protocol output is reserved for LSP frames. Errors avoid echoing RPC URLs,
API tokens, or wallet configuration.

The implementation follows the [LSP 3.17 specification](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/).
The toolchain's [test documentation](COMPILER.md#tests) describes the native
compiler tests and checked-in fixtures.

Formatting honors `insertSpaces` and `tabSize` (1–32). Tabs use one tab per
nesting level; spaces use the requested width. The first line ending in a
buffer selects LF, CRLF, or CR for generated whitespace; a buffer without line
breaks uses LF. Mixed structural whitespace is normalized to that style, string
contents are preserved, and output ends with one line ending. Invalid source
produces no formatting edits. UTF-8/UTF-16 positions also recognize CR-only input.
