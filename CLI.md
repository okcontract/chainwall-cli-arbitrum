# Chainwall CLI

For binary users, see the comprehensive [Chainwall CLI user manual](MANUAL.md).
The CLI build installs it at `share/doc/chainwall/manual.md` alongside `bin/chainwall`.

With `--json`, a failed command exits nonzero and writes a compact JSON error
record as the final stderr line. Stdout retains any command report already
produced (for example a failed simulation). Earlier stderr lines may contain
transport progress. The error record has `schemaVersion: 1`, `ok: false`,
`command`, and `error` with `code`, `message`, `field`, `retryable`, `detail`,
and `recovery`. `field` is a JSON pointer for input validation, an option name
when known, or null. Recovery includes the journal path, transaction and
UserOperation hashes, and whether submission was attempted. When submission may
have occurred, `retryable` is false: observe the saved hash before resubmitting.
Unknown simulation reverts preserve `rawData` with `decoded: false`; known
errors include both raw bytes and decoded fields.
This document covers repository setup, implementation details, and development checks.
For the companion `chainwall-lsp` binary and editor setup, see [LSP.md](LSP.md).

`chainwall` manages Registry instances using a system-installed Foundry `cast`.
It compiles individual Lambdascript `.ls` files natively and needs no adjacent
source tree or runtime package downloads.

## JSON input schemas

Command JSON files are structurally validated before RPC, wallet prompts or
submission. Keystores are checked when selected for signing. Errors identify a
JSON Pointer without printing input values. Protocol checks for
signatures, hashes, chain/Registry bindings and live state still apply.

```sh
chainwall schemas list
chainwall schemas show operation-document --out operation.schema.json
chainwall schemas template operation-intent --out intent.json
chainwall schemas validate operation-document intent.json
chainwall operations direct --schema
chainwall registry upsertToken --schema
chainwall operations direct --schema --edit-input signatures-file
```

`--schema` works without an input file or connection. `--edit-input` selects an
auxiliary JSON option. ABI argument and constructor schemas derive from the embedded
artifacts and support named objects and positional arrays. Use decimal strings for
integers above JavaScript's safe integer range. Integer JSON inputs must use plain
decimal notation (for example, `12`); decimal points and exponents such as
`12.0` or `1.20e1` are rejected during input validation.

The binary embeds `src/cli/artifacts/input-schemas.json` and evaluates its bounded
validation vocabulary offline. Input documents cannot supply executable schemas
or remote references.
Templates are editing scaffolds; placeholders may deliberately require completion.

## Interactive JSON input

```sh
chainwall config set editor hx
chainwall operations direct --interactive --dry-run
chainwall operations propose intent.json --interactive --out proposal.json
chainwall registry upsertToken --interactive --dry-run
chainwall operations execute proposal.json --interactive --edit-input signatures-file --via safe
chainwall upgrade deploy accountFactory --interactive --dry-run
```

Omit the JSON file to start from a schema template, or supply an existing file to
edit a copy. Keep other positional arguments, such as policy IDs and transaction
hashes. `--edit-input OPTION` selects an auxiliary input instead of the primary
document. For a repeatable ABI option, supply exactly one `--abi TARGET=FILE`.
`--interactive` edits JSON; `.ls` source stays in the normal source editor workflow.

Editor precedence is `--editor`, `CHAINWALL_EDITOR`, the profile's `editor`, `VISUAL`,
`EDITOR`, then `vi`. Commands accept quoted arguments, for example
`chainwall config set editor 'code --wait'`. The CLI invokes the executable directly,
without shell expansion. GUI editors must wait until editing is finished.

Saving and quitting successfully validates the input and continues the original
command, including normal signing/submission unless `--dry-run` was supplied.
An error exit, empty document or untouched new template cancels execution. Invalid
JSON stops before RPC or signing and prints the retained draft path for correction.

Drafts use a new private directory under `CONFIG_DIR/interactive` (0700) and files
with mode 0600. The directory includes `schema.json` for editor tooling. Existing
input files are preserved. A validated snapshot is used for execution, and ordinary
successful drafts are removed. Failures retain the draft; commands that update their
input with receipt/reconciliation evidence retain `validated.json` even on success.
Editors may maintain their own backups or history; configure those according to the
sensitivity of the inputs you edit.

## Build and configure

Foundry submissions now save the transaction hash before waiting for a receipt.
Use `--wait-timeout SECONDS` (default 120) and `--tx-confirmations N` (default 1).
An interrupted or timed-out command keeps its recovery handle in the private
transaction log and local transaction cache.
Automatic logs and cached transactions keep calldata digests rather than plaintext,
so an unmined private reveal does not expose its salt in local tracking data.
`transactions inspect HASH` remains the explicit workflow for reviewing live calldata.

```sh
chainwall transactions list
chainwall transactions track "$TX_HASH"
chainwall transactions wait "$TX_HASH" --confirmations 3 --timeout 300
chainwall transactions refresh
chainwall transactions speed-up "$TX_HASH" --dry-run
chainwall transactions speed-up "$TX_HASH" --bump 15
chainwall transactions cancel "$TX_HASH"
```

`list` is an offline snapshot for the selected chain. `track`, `refresh [HASH]`
and `wait` recheck canonical RPC state without resubmitting. Replacement searches
scan at most 64 blocks per observation (`--lookback 0..1024`) in batches of 16.\nSaved submission context supplies the starting block, sender and nonce even if\nthe original hash disappeared. Otherwise the first scan covers the recent window.\n`replacementSearch.nextBlock` persists progress; later observations resume after\nchecking the saved anchor is canonical. A reorg restarts the scan. Zero disables\nblock scanning. An unavailable hash without recovery context is `unknown`;
a consumed nonce without a discovered replacement is `nonce-used`. Neither proves
success. Wait returns nonzero unless the original or a matching repriced payload
has a successful, sufficiently confirmed receipt. Recovery does not automatically
resume deployments or finalize saved business workflows; use their reconciliation
commands with the recovered receipt.

Speed-up requires the original EOA signer and preserves nonce, destination, data,
value, access list and fee model. Both dynamic fee caps (or the legacy price) must
increase by at least `--bump` percent, default 15. Current RPC suggestions can make
the increase larger; review `--dry-run` and set explicit fee caps if desired.
Cancellation uses zero value and empty data to the sender, requires a plain EOA,
and only permits its next nonce. The original can still mine first. AuthAccount,
UserOperation, blob and EIP-7702 replacements are excluded; saved UserOperations
remain recoverable through `auth receipt`. Polling is bounded and never changes
RPC endpoints automatically. Reports and logs exclude RPC URLs and wallet keys.

Gas previews are available on prepared write commands:

```sh
chainwall users add "$USER_ADDRESS" --estimate --from administrator
chainwall transactions estimate transaction.json --from administrator
chainwall users add "$USER_ADDRESS" --max-fee 10gwei --priority-fee 1gwei
```

`--estimate` implies `--dry-run`. It estimates the displayed transaction at a
verified canonical block, without signing or broadcasting. Use a dry-run JSON
file or `{chainId,to,data,value}` with `transactions estimate`; omit `to` for
contract creation. `--from` avoids unlocking a wallet just to find its address.
Signed execution requests need their real signatures before RPC estimation.

Reports separate `estimatedTransactionFeeWei` from `maximumTransactionFeeWei`,
and include value, balance and a 20% default gas margin. On Arbitrum, the RPC gas
estimate includes L2 execution and the L1 data posting component; do not add that
component again. `maximumValueAndFeeWei` includes the transferred native value.
Multi-stage workflows estimate the shown
stage; later dependent stages need their prerequisites mined first. Passkey and
UserOperation fee review remains in the existing browser approval flow.

Global `--gas-limit N`, `--max-fee AMOUNT`, and `--priority-fee AMOUNT` control
Foundry submissions. `--gas-price AMOUNT` selects legacy pricing; `--legacy`
lets Foundry choose that model's price. Amounts accept exact wei or gwei. Mixing
legacy and dynamic fees is rejected. Estimates do not set future submission fees;
pass the reviewed limits again when sending.

```sh
zig build -Doptimize=safe
zig-out/bin/chainwall --help
# Put zig-out/bin/chainwall on PATH to use the commands below.
```

Zig 0.17 and Foundry 1.7.1 are tested. The CLI uses
[zqlite](https://github.com/karlseguin/zqlite.zig), pinned by URL and package hash in `build.zig.zon`, with bundled SQLite linked
statically. No SQLite installation is
needed at runtime. `zig build -Dcli=false -Dlsp=false` builds the compiler alone, using only
Zig's standard library.

```sh
cast wallet import deployer --interactive
chainwall accounts
chainwall profile create work
chainwall profile use work
chainwall config set account deployer
chainwall config set chain base
chainwall config set rpc_url "$BASE_RPC_URL"
chainwall login "$REGISTRY_ADDRESS"
chainwall users add "$USER_ADDRESS"
chainwall users list
```

`login` accepts either a Registry address or the SafeFactory instance address
used by the app. For an instance, it follows `INTERACT_CONTRACT()` to Interact,
then `registry()` to the Registry. It verifies the RPC chain ID, deployed code,
and component identities before saving the resolved Registry and signer defaults.
It updates both scalar settings and the selected chain's `[instances]` and
`[rpc]` entries, and saves the instance's Interact address when resolved.
Every network operation verifies chain ID and instance code. `login` does not
deploy an instance.
Transaction signing uses Foundry's account/password handling; the CLI never
exports the Foundry signer's private key. The separate KV secret described below
is handled natively so operation journals can be decrypted.
Use `--password-file PATH` for unattended signing, or `--keystore PATH` for an
encrypted keystore outside Foundry's default directory.

Profiles live in `~/.config/chainwall/NAME.toml`. `profile use NAME` selects the
active profile; `--profile NAME` overrides it for one command. The initial name
is `default`. `profile list`, `config show`, `config get KEY`, and
`config unset KEY` inspect or change profiles. Writes are atomic with mode 0600
on POSIX. Printed profiles redact RPC URLs and API tokens.

Example profile, with example addresses and provider URLs to replace:

```toml
chain = "base"
account = "deployer"
instance = "0x1111111111111111111111111111111111111111"
etherscan_api_key_env = "ETHERSCAN_API_KEY"
# password_file = "/absolute/path/to/password"

[rpc]
base = "https://your-base-rpc.example"
ethereum = "https://your-ethereum-rpc.example"

[instances]
ethereum = "0x2222222222222222222222222222222222222222"
```

The profile schema accepts quoted scalar TOML values, comments, and `[rpc]`,
`[instances]`, and `[interacts]` tables. Numeric chain IDs can also be unquoted integers. Duplicate
keys, unknown settings, unknown tables, and profile path traversal are rejected.
Arrays, dates, inline tables, dotted TOML assignments, and multiline strings are
outside this small profile schema. `config set rpc.base URL` writes a table entry.

Connection precedence is command flag, `CHAINWALL_*` environment value, matching
chain table entry, then profile default. Changing chains does not reuse the
previous chain's `rpc_url`. Named chains and their numeric IDs match the same
table entries. A global `instance` is a fallback when no chain-specific instance
exists. Supported names: ethereum/mainnet, base, arbitrum, optimism, polygon,
bsc, avalanche, gnosis, sepolia, base-sepolia, anvil/localhost. Other chains use a
numeric ID and explicit RPC URL.

Environment overrides: `CHAINWALL_PROFILE`, `CHAINWALL_CHAIN`,
`CHAINWALL_RPC_URL`, `CHAINWALL_INSTANCE`, `CHAINWALL_ACCOUNT`, and
`CHAINWALL_CONFIG_DIR`. Config location also honors `XDG_CONFIG_HOME`, and
`--config-dir` takes precedence. No public RPC endpoint is silently selected.

`config explain [KEY] --json` reports the selected profile and directory, resolved
startup values, the winning option/environment/profile key, and
`shadowedProfileKeys`. Startup and this report use the same resolver. Flags precede
environment values, then chain-specific profile bindings, then generic profile
values and defaults. A generic `rpc_url` applies only to the profile's chain.
Explicit keystore or unlocked mode suppresses a saved account; an account suppresses
a saved keystore. RPC URLs remain redacted. Editor selection includes `VISUAL` and
`EDITOR` after the saved editor. Workflow-specific settings are separately marked
`scope: "stored-workflow-setting"`; they describe stored inputs, not live discovery.
`config set` and `config unset` also return this explanation so a saved update
shadowed by an environment value or chain binding is visible immediately.

## Private contract, token and interaction commitments

```sh
chainwall commitments template contract --out contract.json
# Edit payload.org, payload.id, payload.address and payload.version.
chainwall commitments prepare contract contract.json --out prepared.json
chainwall commitments list
chainwall commitments commit "$COMMIT_HASH"
chainwall commitments status "$COMMIT_HASH"
chainwall commitments reveal "$COMMIT_HASH"
chainwall commitments archive "$COMMIT_HASH"
chainwall commitments archives
```

`prepare` creates a cryptographically random 32-byte salt, calculates the same
protocol commitment, and saves the full draft in the encrypted local vault.
It needs no KV deployment. `--passphrase-file FILE` supports automation; normal
reports contain the commitment hash, context and deadline, never the secret salt
or payload. The input is `{ "payload": {...}, "deadline": 1234567890 }`, with
optional `deadline`, `forwarder`, and bytes32 `hint`. Deadlines are Unix seconds,
default to seven days, and must be within 90 days. Public salt phrases and custom
salts are deliberately unavailable for these private commitments.

The active draft collection holds up to 1,024 entries. `archive HASH` frees a slot
after checking that the commitment is absent or expired and has no pending action.
The complete draft remains encrypted in the local archive. `archives` lists its
summary; `export HASH --out FILE` also works for archived drafts. Import an export
to restore an active draft when needed. Archival sends no blockchain transaction.

Contract payloads contain `org`, `id`, `address`, and `version`, with optional
`implementation` and bytes32 `label`. Versions accept up to 32 UTF-8 bytes or an
explicit bytes32. Address fields accept Foundry account names and `@labels`.
Token payloads contain `org`, `id`, `symbol`, and `decimals`, with optional
`price`, `priceFeedDecimals`, and `flags` (0 or 2 for inactive). The referenced
contract must exist before the token reveal. Use `tokens metadata` to discover
metadata before preparing a token draft.

Interaction payloads contain `bundle: {id, script, flags?, linked?}` and optional
`relatedContracts`. A linked artifact is `{relation, payload}`. Lists are sorted
canonically; duplicates, unsupported flags and protocol size violations are
rejected. `--source-file interaction.ls` compiles the main script natively and
accepts the usual compiler snapshot/ABI options. Otherwise supply bytecode in
`script`. Private sources and linked artifacts stay in the encrypted draft.

Submission verifies Registry identity, chain time, the exact live commitment,
pending actions for its scope, and whether the deadline allows the timelock
delay. With a signer, it simulates before broadcasting. A reveal simulation
discloses the payload and salt to the selected RPC; the reveal transaction makes
them public. `--dry-run` submits nothing and saves no new draft. With `--from` or
an AuthAccount it still simulates; without one it validates context only.

`commitments cancel HASH` cancels a matching commitment. `expire HASH` cleans up
an expired one, including permissionless interaction cancellation. Queued commit
receipts remain `queued`; execute or cancel the reported timelock action before
continuing. The CLI saves an encrypted attempt before broadcast and retains its
receipt before classification. After an interruption, use `status HASH`, then
`reconcile HASH TRANSACTION_HASH` to verify canonical event evidence. An explicit
`--retry` is required to repeat an attempted submission, and pending actions
still block duplicates. No automatic resubmission occurs. Delegated reveals
accept `--actor-signature-file FILE` containing a JSON signature string or an
object with `signature`; the contract checks that authorization during simulation.

Drafts belong to their chain and Registry. For recovery, `export HASH --out FILE`
explicitly writes the complete private draft, including its salt, to a new 0600
file. `import FILE` checks the context and commitment hash before encrypting it
in the destination vault; it does not trust imported submission history.
Reports and exports never overwrite an existing file. Keep the config directory
or a private export until the commitment is closed.

## Facet deployment and selector plans

```sh
chainwall facets catalog
chainwall facets deploy tokens --out token-facet.json
chainwall facets verify tokens "$FACET"
chainwall facets plan tokens --target "$FACET" --out plan.json
chainwall facets apply plan.json --dry-run --from "$ADMIN"
chainwall facets apply plan.json
chainwall facets check plan.json
```

The catalog embeds the same canonical creation bytecode and managed selector
sets as the app. Plans operate on a Registry with its core loupe/cut and timelock
facets installed. `deploy` creates a standalone facet; `plan` handles both fresh
selector installation and upgrades. `--current ADDRESS` selects the old facet
when inference is ambiguous; `--current none` intentionally leaves unrelated
routes alone. Constructor-bound releases require a canonical CREATE transaction
proof, supplied through `--deployment-tx HASH` or a verified local deployment.

Every extra selector on the old facet needs an explicit choice. Supply
`--choices-file choices.json` containing entries such as:

```json
{
  "0x11111111": { "kind": "keep" },
  "0x22222222": { "kind": "remove" },
  "0x33333333": { "kind": "move", "address": "0x1234567890123456789012345678901234567890" }
}
```

Review custom move destinations yourself; the CLI verifies their code is present
and unchanged, but only catalog targets are matched against bundled artifacts.
Unknown choices are rejected. Protected direct and core selectors cannot be
removed. Pending diamond actions block new plans from being applied.

`apply` rechecks the complete routing table, canonical block, destination code
hashes and constructor dependencies, then simulates using the selected signer.
It saves the attempt and receipt in the mode-0600 plan before checking exact
cut events and resulting routes. Only code cuts are supported, with zero init
address and empty init calldata. Plans and deployment reports are created without
overwriting existing files; apply/reconcile update the selected plan in place.

For interruptions, use `facets reconcile plan.json TRANSACTION_HASH`. Queued cuts
remain queued until their timelock action executes; reconcile the execution
receipt afterward. `check` verifies current routes and destination/dependency
code. `--retry` explicitly acknowledges a prior attempt and still requires a
valid unchanged plan. Raw ABI facet methods remain available.

## RPC pools

```sh
chainwall rpc add primary --rpc-url "$PRIVATE_RPC_URL" --privacy private
chainwall rpc add backup --rpc-url "$BACKUP_RPC_URL" --privacy private
chainwall rpc privacy private
chainwall rpc probe
chainwall rpc choose --max-lag 3
chainwall rpc list
chainwall rpc use primary
```

Pools belong to the selected profile and chain. Each contains up to 32 named
endpoints. URLs remain in mode-0600 configuration files; reports show names,
declared privacy, selection, latency, canonical head, and health history. They
retain the last 20 observations plus cumulative success/failure counts, without
provider credentials or raw RPC error messages. Classification is user-declared.

`rpc privacy private` excludes public and unknown endpoints before network use,
including explicit URL overrides and each chain in combined status views.
`rpc privacy all` permits every class. `rpc use NAME` verifies that endpoint;
`rpc choose` selects the fastest healthy candidate within `--max-lag` blocks of
the highest candidate. Both check the chain ID and canonical head before saving
the profile. Selection is explicit; failed transactions are never automatically
resubmitted to another provider. HTTPS is required except for localhost HTTP.

`rpc probe [NAME]` records observations without selecting an endpoint. Its
`--timeout` is a per-request deadline of 1-30 seconds (default 5). `--dry-run`
previews configuration changes but still records probes. `--out FILE` saves a
new report. `rpc remove NAME` also clears a matching saved RPC binding.

## Instance discovery and status

```sh
chainwall instances discover --chains base,ethereum
chainwall instances discover "$REGISTRY_ADDRESS" --chains base,optimism
chainwall status
chainwall status --all-chains --out status.json
```

Discovery checks each configured chain independently and reports installed,
missing, different-contract, or unavailable results without changing the profile.
Without an address, it uses each chain's configured Registry binding, falling
back to the selected address. An explicit address probes that same address on
every requested chain. Discovery defaults to configured chains; `status` defaults
to the selected chain and also accepts `--chains` or `--all-chains`.

Status combines ownership, pause/bootstrap state, security council, terms
acceptance, pending actions, and catalog counts. Reads use one canonical block per
chain. Unavailable facets produce null fields with errors and `complete: false`;
one unavailable chain does not hide the others. RPC credentials are not included
in reports. `--block` is available only for a single selected chain.

## Shell completion and label references

Run these commands in fish after putting `chainwall` on PATH:

```fish
mkdir -p $__fish_config_dir/completions
chainwall completions fish > $__fish_config_dir/completions/chainwall.fish
chainwall sync
chainwall completions watch
# For labels encrypted with the imported app shared secret:
chainwall completions lock
chainwall completions unlock
```

For zsh, generate an autoloadable completion file:

```zsh
mkdir -p ~/.zsh/completions
chainwall completions zsh > ~/.zsh/completions/_chainwall
```

Add `fpath=(~/.zsh/completions $fpath)` to `~/.zshrc` before its `compinit`
call, then restart zsh. If completion is not initialized yet, also add
`autoload -Uz compinit` and `compinit` after the `fpath` line.
The same `sync`, `watch`, `unlock`, `status`, and `lock` commands work in either
shell, and an unlocked session can be shared between them.

The build also installs `share/fish/vendor_completions.d/chainwall.fish` and
`share/zsh/site-functions/_chainwall`.
Both adapters ask the installed binary for commands, ABI methods, applicable
flags, enum values, profiles, paths, and scoped Registry entities. Options use
the same arity/repetition metadata as the parser and descriptions as help.
Tab only reads cached data and the local session socket. It never prompts,
unlocks the vault, starts a sync, or requires Foundry.

`watch` refreshes public records; `unlock` also decrypts labels using the
imported shared secret. Both run an expiring helper: `--ttl 900` and
`--refresh 30` are the defaults, and `--refresh 0` disables background reads.
`unlock --passphrase-file FILE` supports automation. Sessions are scoped to
the config directory, profile, chain, and Registry. Use `completions status`
to inspect refresh success and `completions lock` to stop the helper.

Registry candidates cover users, accounts, Safes, groups, organizations,
contracts, tokens, interactions, policies, and cached timelock IDs. The `labels`
sync dataset refreshes label metadata even when membership is unchanged;
group, interaction, and policy labels are decoded from their stored keys.
Encrypted labels use the protocol's AES-SIV format and authenticated context. Only
ciphertext is saved. Decryption happens in helper memory, and plaintext is
returned to the requesting CLI for display or resolution. Locked or unavailable
sessions fall back to public labels and raw IDs.
Arbitrary non-enumerable mappings and unrecoverable hashed names have no label
to suggest. Contract version labels are distinct from contract names.

Use `@label` in positional, named, or JSON ABI arguments, for example:

```sh
chainwall users contains '@Alice Smith'
chainwall users remove --arg-user '@Alice Smith' --dry-run
chainwall contracts get '@example/vault'
chainwall interactions source '@Swap' --offline
```

Resolution uses the exact stored address or ID, including encrypted IDs;
it never hashes a decrypted label to reconstruct an ID. Ambiguous labels are
omitted from completion and rejected during execution. Raw addresses and IDs
remain accepted. Completion returns at most 200 matching candidates; type a
longer prefix to narrow a large collection.

Address arguments also accept bare Foundry account names. The common resolver covers
user/account/Safe references, `--from`, `--owner`, `--safe`, and ABI `address` fields,
including arrays and tuples in named JSON flags or `--args-file`. Safe creation's
comma-separated `--owners` list resolves names before checking for duplicate owners.
New operation proposals resolve their `safe` input before hashing or saving it.
These lookups use `cast wallet address --account NAME` independently of the selected
transaction signer. Foundry handles password prompts and the configured password file.

## Private recipient address books

```sh
chainwall recipients add @Payments --vault @Treasury --recipient alice --label Alice
chainwall recipients list @Payments --vault @Treasury
chainwall recipients authorize @Payments Alice --vault @Treasury
chainwall recipients resolve @Payments Alice --vault @Treasury --out recipient-args.json
chainwall recipients revoke @Payments Alice --vault @Treasury
chainwall recipients remove @Payments Alice --vault @Treasury
```

These commands use the configured encrypted KV and shared secret. They refresh
the journal before acting, including historical signer epochs. Registry reads
verify the selected tenant, policy and registered account/Safe at a canonical
block. KV storage can live on another configured chain. Recipient addresses accept
Foundry names or `@labels`; the vault accepts account labels and addresses.

Add appends an encrypted address-book entry without authorizing it. It derives
the app's deterministic HMAC mask from the shared secret and full execution
context, then computes the v2 policy/vault-bound commitment. Existing destinations
cannot be added again. Authorize/revoke write only the public commitment to
policy state. Governance may queue either change; wait for execution before
resolving or removing the recipient. A pending policy update blocks book writes
and authorization changes. Remove requires the commitment to be revoked and
appends an encrypted tombstone.

List decrypts names and addresses in memory without printing masks. `--offline`
uses the encrypted cache and reports authorization as unknown. Live lists include
the authorization value and block. Only ciphertext is cached; indexed journals
retain signer insertion order so same-block tombstones replay correctly. Older
caches rebuild this metadata automatically on the next online refresh.

Resolve requires live authorization equal to one and an explicit new `--out`
file (0600). Its JSON contains `args[0]` as the recipient address word and
`args[1]` as the secret mask. Use those arguments when preparing a new operation;
do not edit a proposal that has already been hashed or signed. Standard output
contains only the commitment and file path. `--dry-run` previews writes and checks
resolution without exporting masks. Use a commitment instead of a label when
labels are ambiguous, and `--passphrase-file` for noninteractive vault access.

## Direct interaction execution

`operations direct` executes without a proposal when the actor can satisfy the
policy alone. Use the same JSON input as `operations propose`: `safe` (the
destination OKAccount or Safe), `policyId`, `interactionId`, `deadline` in Unix
seconds, `args` (default `[]`), and `nativeValue` in wei (default `0`). The
deadline must be in the future and nonzero. IDs accept hashes or plaintext names.

```sh
chainwall operations direct input.json --actor "$ACTOR" --dry-run
chainwall operations direct input.json --account operator --out execution.json

# Safe: authorize the actor, collect owner signatures, then execute.
chainwall operations direct-sign-actor input.json --via safe --account actor --out actor.json
chainwall operations direct-sign input.json --via safe --actor-signature-file actor.json --account owner --out owner.json
# Combine owner.json files into a JSON array called owners.json.
chainwall operations direct input.json --via safe --actor-signature-file actor.json --signatures-file owners.json --account relayer
```

Keep the same input, `--via`, `--max-steps` (default `100000`) and optional
`--reveal-file` throughout signing and execution. Actor signatures bind the chain,
Interact address, destination, policy, arguments, execution binding, value cap,
deadline and actor nonce. Safe owner signatures also bind the Safe transaction
and nonce. Saved signatures are refused when context changes. Passkey account
execution uses the existing protocol-call approval and runtime revision checks.

Submission rechecks binding and nonces and simulates the exact signed call.
Dry runs are unsigned previews; they do not prove executability. `--out` reserves
a new mode-0600 report before signing and updates it with the receipt. Transaction
receipts are also journaled. Existing proposals remain under `operations execute`.

Safes with the optional OKModule enabled also support `--via module`:

```sh
chainwall operations direct input.json --via module --account operator
chainwall operations execute proposal.json --via module --account operator --approve
chainwall operations execute proposal.json --via module --auth-profile passkey.json --bundler-url "$BUNDLER_RPC"
```

The CLI discovers the module through the Registry's authorized Safe factories,
checks the Safe's live extension policy, and signs the actor automatically.
It verifies the module's execution event after mining. This route preserves the
Safe owner nonce and requires no owner signature collection. `--reveal-file`
supports private interactions on both direct and proposed paths.

For a separate relayer, run `direct-sign-actor` or `sign-actor` with `--via module`
and pass its file to execution with `--actor-signature-file`. A read-only
`operations simulate` also needs that signed file and the relayer's sender.
Passkey execution can use a selected Foundry signer to pay gas, or a bundler to
authorize and simulate the full UserOperation through the existing approval page.
Bundled calls use the selected passkey actor and cannot take an external actor file.

## Terms documents

```sh
chainwall terms document
chainwall terms document --out initial-terms.md
chainwall terms document --document-file downloaded-terms.md
```

Terms are fetched through `https://ipfs.io/ipfs` by default. Use
`--ipfs-gateway URL` to select another gateway prefix. The command verifies the
exact bytes against the SHA-256 hash recorded onchain, pins the terms record to
a canonical block, and returns the document with its URI and hash. It
rejects redirects, invalid UTF-8, responses larger than 1 MiB, and hash
mismatches. `--out` writes a new file only after verification.

Acceptance is separate. To accept the document just reviewed, pass the returned
published hash explicitly to `terms accept-terms DOCUMENT_HASH`. The command
resolves its canonical URI onchain and verifies the bytes before signing.

## Account funding and Safe inspection

```sh
chainwall accounts fund @treasury --value 0.1ether --dry-run
chainwall safes fund "$SAFE" --value 25000000000000000 --account operator
chainwall safes inspect "$SAFE"
```

Funding checks factory provenance, tenant bindings, and Registry registration
before sending native currency from the selected signer. Bare integers are wei;
`wei`, `gwei`, `ether`, and `eth` suffixes accept exact decimal amounts. Excess
precision is rejected without rounding. Named Foundry accounts and Registry
labels resolve as destinations; `--nonce` retains its usual meaning.

Safe inspection reports version capabilities and uses `null` for unsupported
guard/handler fields. A supported but unset field is the zero address. Legacy
Safe 1.0 module lists and pre-1.4 pagination are handled explicitly. Unknown
releases can be inspected but cannot be imported without compatibility review.

## App configuration JSON

Generate a shared secret before deploying a KV or encrypting labels:

```sh
chainwall config generate-secret --passphrase-file /path/to/vault-password
```

The command generates a cryptographically random key, stores it encrypted in the
local vault, and prints only its public signer address. It refuses to overwrite
an existing secret. Connected KVs use `kv rotate` to retain readable history.
A later `kv create` uses the saved secret unless `--secret-file` is supplied; an
interrupted deployment retains its pending key. Use explicit config export to
back up or transfer the secret.

```sh
chainwall config import app-configuration.json --passphrase-file /path/to/vault-password
chainwall config export app-configuration.json --passphrase-file /path/to/vault-password
```

Both commands use the app's exact version-2 configuration schema, including
Registry/SafeFactory topology, wallet address, locale, RPC override, Etherscan
API key, shared `stackSecret`, and independent KV address/chain. Import is
offline and validates before switching the selected profile. Foundry signer
selection is retained separately from the app wallet address.

Shared secrets are encrypted in the local vault. Import/export prompts for its
passphrase when a secret is present; the file flag supports automation. Export
includes the plaintext secret and API key, like the app, and writes files
atomically with mode 0600. Omit the output path (or use `-`) for JSON on stdout.
`config show --json` remains a redacted view of CLI settings.

Export reflects saved profile settings, preserves imported app-only metadata,
and includes recorded topology from `deploy`. Changing the selected Registry
or chain discards unrelated imported topology. Foundry signing private keys
are not part of the app format. CLI-only settings, including extra RPC tables,
keystore paths, and passwords, are not added to the exported schema.

## Deploy an instance

`deploy` creates a tenant stack through an existing OKFactory, using the same
bootstrap, prepare, and finalize transactions as the app:

```sh
chainwall deploy --factory "$OK_FACTORY_ADDRESS" --owner "$OWNER_ADDRESS" \
  --salt "$BYTES32_SALT" --chain base --out deployment.json
```

The owner and salt are explicit. `--salt` accepts 32-byte hex or a phrase such as
`--salt "treasury autumn 2026"`. Phrases become `keccak256(UTF-8 text)` with case
and whitespace preserved. Hex inputs beginning with `0x` must contain exactly
64 hexadecimal digits; zero is valid. Empty or whitespace-only phrases are rejected.
The same conversion applies to `accounts create`, `safes create`, security council
recovery salts (named, positional, or JSON), and terms governor draft `salt` fields.
These salts are public identifiers, so use distinct labels for distinct deployments
or actions. Commit/reveal salts still require explicit bytes32 values with sufficient
unpredictability to protect hidden inputs. Never use a wallet recovery phrase as a salt.

`--owner` accepts an address or a Foundry
account name, resolved with `cast wallet address --account NAME` before any RPC
or transaction. It does not change the signer selected by `--account`, `--keystore`,
or `--unlocked`. Foundry may prompt for the owner's password even during dry-run;
the configured password file applies to both owner lookup and signing.

Indexing defaults to enabled; use
`--no-indexing` to disable it or `--indexing` to enable it explicitly.
`--auth-accounts` deploys an AuthAccount factory; `--no-auth-accounts` is the
default. These switches cover all four combinations. Numeric `--flags 0|1|2|3`
is also accepted, but cannot be combined with the named switches. These options
apply at bootstrap; resumed stages use the settings recorded onchain.
Without `--factory`, the CLI uses
the profile's `factory` override, then the selected chain's bundled default.
`src/cli/artifacts/factory-addresses.json` includes defaults only for Arbitrum One
(chain ID `42161`), including `kv create`. Other chains require an explicit
factory address. Set an override with `config set factory ADDRESS`.
Signing uses the usual Foundry options.
All transaction commands automatically save a mode-0600 JSON log under
`CONFIG_DIR/logs` (normally `~/.config/chainwall/logs`) and print its path.
Each log includes the profile, command, receipts, and full command result. Receipts
are saved before follow-up checks, so failed or interrupted commands retain the
evidence collected so far. A log's status describes the command, not whether an
onchain action executed. `--json` still prints the original result to stdout, with
the log path on stderr. `--out` keeps its existing command-specific behavior.
Reads and dry runs do not create transaction logs.
On Etherscan-supported chains, each submitted transaction also prints its
chain-specific explorer URL to stderr once its transaction hash is available,
including when later receipt checks fail. URLs are not added to JSON results or
saved logs. Unsupported networks and read-only receipt recovery print no link.
The bundled website list comes from `https://api.etherscan.io/v2/chainlist`;
the checked-in catalog is `src/cli/etherscan-chains.json`. Displaying links
requires no API key or additional network request.

```sh
chainwall logs list
chainwall logs show latest
chainwall logs show 20260922T123456.789Z-default-deploy-0123456789abcdef.json
chainwall logs show latest --json > transaction-log.json
```

The log browser works offline across profiles in the selected config directory.
List prints paths newest first; show accepts a listed filename, full path, or
`latest` (the default). JSON highlighting follows `--color auto|always|never`,
`NO_COLOR`, and terminal support. Saved files and `--json` output contain no colors.

Finalization verifies the factory event against `getInstance`, records the
component addresses, and selects the new Registry/Interact in the profile.

`--stage bootstrap` stops after creating the paused Registry. To resume a
deployment, use its Registry address with `--stage prepare`, then
`--stage finalize`. The same factory must own that deployment key. A repeated
bootstrap fails with the existing Registry address instead of creating another
instance. Successful earlier stages remain onchain if a later transaction fails.

`--dry-run` produces native, offline calldata for the selected stage; with the
default `--stage all`, it previews bootstrap and lists the two dependent stages.
Prepare/finalize previews take `--registry ADDRESS`. No signing or profile changes
occur during previews. `artifacts OKFactory` exports the generated ABI reference.

## Sync and cached lists

```sh
export ETHERSCAN_API_KEY='your-token'
chainwall sync
chainwall users list
chainwall groups list --count 100
chainwall timelocks list
chainwall sync --only users,interactions,timelocks --confirmations 12
chainwall interactions list --offline
```

The database is `chainwall.sqlite3` in the config directory. Profiles share it;
records and checkpoints are isolated by chain ID, contract address, and dataset.
SQLite uses WAL transactions and mode 0600 on POSIX. List results include the
checkpoint block and are snapshots, not a claim about the latest chain state.
Existing entity lists use the cache when present and retain their live RPC
behavior before the first sync. `--offline` requires a cache; `--live` bypasses
it. Timelock history uses `timelocks list`; `timelock pending` is the live pending
queue query. Pagination uses `--start N --count N`, with at most 1,000 rows.

Default sync covers users, groups, policies, orgs, contracts, tokens,
interactions, safes, accounts, and timelocks. It includes operations when
`kv_address` is configured. `--only` takes a comma-separated dataset list.
Registry sync uses stable IDs, alive bitmaps, and epoch journals to fetch newly
allocated live IDs, apply deletions,
then refresh touched records, including the previously observed epoch. Users
have no stable ID journal and are reread in batches. Other entities retain
their keys and primary records, including full interaction bundles.

Registry entity indexes exist independently of `indexingEnabled`. The optional
flag controls the timelock strategy: indexed sync reads pending summaries and
new executed summaries, then refreshes previously seen pending actions that
left the queue. With indexing disabled, RPC `eth_getLogs` or Etherscan V2 `getLogs` discovers queued
action IDs and RPC supplies their current summaries. Indexed discovery retains
cancelled/expired actions it has observed; an action queued and cancelled wholly
between two syncs is not discoverable through those indexes. It is not a complete
event audit. Log discovery finds those actions through queue logs.

RPC calls are batched, decoded natively, and pinned with EIP-1898
`blockHash`/`requireCanonical`. The provider must support JSON RPC batches and
EIP-1898. A sync verifies the old checkpoint, resets after a reorg, and checks the
new block again before committing all selected datasets together. Errors leave
the prior snapshot intact. Sync, recipient refresh, checkpoint preparation and LSP
metadata refresh perform network work against a private disk snapshot. The live
SQLite write transaction only validates the source revision and applies changed
cache/checkpoint/vault rows. A concurrent database update produces
`DatabaseChangedRetrySync`; rerun the read to build from the newer snapshot.
Temporary snapshot storage is proportional to the cache size and is removed when
the operation finishes. Each HTTP request has a 60-second deadline. Etherscan
pagination rejects repeated pages and subdivides full result windows or ranges
that the explorer reports as too large to query;
provider errors never count as empty history. Log block hashes are checked
against the RPC chain before use. Explorer completeness still
depends on the provider's index being current.

`sync --log-source auto|rpc|explorer` selects event discovery. `auto` uses the
configured explorer and falls back to RPC if it is unavailable; without an API
key it uses RPC immediately. `rpc` requires no explorer credentials. RPC scans
use ranges of at most 10,000 blocks and subdivide provider range/result limits.
An overflowing single block fails explicitly. Logs must match the emitter,
topic and requested range; duplicates and removed logs are rejected. Both
backends verify log block hashes before committing. Checkpoint strategy records
the backend actually used. ABI discovery still requires an explorer or supplied ABI.

Explorer scans revisit the last 128 blocks by default to pick up delayed logs.
`--lookback N` adjusts this overlap. Previously cached immutable KV values are
not downloaded again. `--backfill-from N` revisits older logs through the current
snapshot without clearing cached records. It must be at or above `--from-block`.
For example, `sync --only timelocks --log-source rpc --backfill-from 0` closes
historical gaps left by explorer indexing lag when the configured lower bound is zero.
Use `--full` to rebuild instead.
Rate limits retry the same page with bounded backoff before failing the sync.

Sync output includes dataset checkpoints. Their `block` is the current-state
snapshot; log checkpoints also include `discovery` with the requested range,
actual source, verified contiguous `completeFrom`/`completeThrough`, and
`historyComplete` relative to the configured lower bound. Successful explorer
responses never advance verified coverage: their `indexerCompleteThrough` is
null because the API provides no completeness watermark. A recent snapshot
therefore does not imply complete event history. RPC backfills can establish
contiguous coverage; provider errors and reorganizations preserve the prior checkpoint.

`--full` rebuilds selected snapshots. `--from-block N` bounds explorer discovery
and is recorded in the checkpoint; changing it resets the affected snapshot.
The default is block zero. `--block NUMBER|TAG` selects an explicit Registry
snapshot; `--confirmations N` instead syncs N blocks behind the head. Separate KV
chains get their own block and confirmation depth.

## Encrypted operation journals

For indexed journals, `operations checkpoint prepare` refreshes the full journal
and saves an encrypted local draft. It returns an ID for
`operations checkpoint inspect ID` and `operations checkpoint publish ID`.
Publication resumes confirmed writes and writes the manifest last. Use `--retry`
only after reviewing an unconfirmed attempt. No raw history is deleted.

Preparation excludes proposals expired on the selected execution chain at a
canonical block 12 confirmations behind the head (`--confirmations N`). All other
chains and unproven closed records are retained. `--keep-all` retains every
distinct proposal without contacting the execution chain. `--chunk-size 1..128`
controls transaction size. All commands accept `--passphrase-file FILE`.

After publication, run `sync --only operations`. `operations list` defaults to
`--view operational`, which verifies journal checkpoints, retained proposal hashes,
signer frontiers and subsequent writes. Invalid checkpoints fall back to an
older valid checkpoint or full history. `--view audit` reads every raw journal
proposal including duplicates, without adding local imports. Both views support
the usual chain, account, status and pagination filters. Full ciphertext history
is still synchronized and cached so audit and fallback remain available.

Use an existing PasswordGatedKV, with its current app secret in a file containing
one `0x`-prefixed 32-byte private key:

```sh
chainwall config set kv_factory "$KV_FACTORY_ADDRESS"
chainwall config set kv_chain base
chainwall config set kv_rpc_url "$BASE_RPC_URL"
chainwall kv connect "$KV_ADDRESS" --secret-file /path/to/kv-secret
```

Or create an indexed KV through the configured `PasswordGatedKVFactory`, owned
by the Foundry signer selected in this profile:

```sh
chainwall kv create
chainwall config set interact "$INTERACT_ADDRESS"
chainwall sync --only operations
chainwall operations list
chainwall operations list --safe "$SAFE_OR_ACCOUNT" --status active
chainwall operations list --all-chains --offline --json
```

`kv create` uses a standalone shared secret or generates a random one, stores it encrypted before broadcasting,
and saves the deployed KV address after checking the factory event. Its
`--dry-run` preserves an encrypted pending secret and prints only public signer
metadata and calldata. A pending secret survives a failed broadcast/receipt;
keep the database if recovery is needed. `kv connect` verifies the current
password signer before importing the secret. After an app rotation, connect
again with the new head secret, then sync. The CLI follows and validates up to
64 encrypted parent links so older operations remain readable.

Private commands prompt for a passphrase with terminal echo disabled. The first
vault setup confirms it. `--passphrase-file FILE` supplies it for automation;
this is separate from Foundry's `--password-file`. Windows currently requires
file input. The passphrase derives a local key with Argon2id (64 MiB, three
passes), and AES-256-GCM binds each secret to its database context. Keep a backup
of the database and the passphrase: the CLI has no passphrase recovery service.
Public Registry commands do not prompt for this passphrase.

The local database contains the original onchain KV ciphertext, encrypted secret
history, and encrypted status snapshots. Proposal contents are decrypted in
memory after unlocking. Versioned onchain envelopes and version-3 proposal
journals use Keccak-derived keys, rotation payloads, pending identity checks,
and deduplication. Unrelated
KV entries are ignored; unreadable or invalid journals are counted in output.
Indexed KV sync reads new keys per readable signer. Unindexed KV sync uses
RPC or Etherscan `Wrote` logs. Neither path rereads unchanged immutable values.

`kv_chain` defaults to the selected execution chain; `kv_rpc_url` defaults to
its `[rpc]` entry or that chain's selected RPC. Storage and execution chains may
differ. Lists default to the selected execution chain; `--all-chains` displays
all readable proposals. A configured `interact`, or `[interacts]` entry for the
execution chain, must identify a Chainwall Interact bound to the selected
Registry before statuses are saved. Without it, status is `unknown`.

Statuses are `active`, `expired`, `closed`, `mismatch`, and `unknown`, evaluated
at the displayed `statusBlock`. `closed` means the contract's
`isOperationExecuted` predicate returned true. That also covers withdrawn and
missing IDs, so it does not prove execution. Live records are checked against
the proposal's safe, policy and native value; status is not an execution
simulation. Records on other execution chains use their own encrypted status
snapshots when `[instances]` explicitly binds that chain's Registry. Sync with
each chain selected first; missing bindings or snapshots remain `unknown`.
Each entry reports its status block and Registry. No network access is needed
to list a cached journal.

Private operation sharing works without publishing details to the shared KV:

```sh
chainwall operations export proposal.json --out share.json
chainwall operations import share.json --dry-run
chainwall operations import share.json --passphrase-file /path/to/vault-password
chainwall operations list --local --passphrase-file /path/to/vault-password
chainwall operations export-local "$PENDING_ID" --out copy.json
chainwall operations execute copy.json --via account --account operator
```

Exports use the app's version-1 `chainwall.privatePendingOperation` envelope.
New CLI proposals retain their transaction hash; older proposal files require
`--proposal-tx HASH`. Verification checks canonical transaction/receipt evidence,
payload details, creator, open operation state, account, policy, native value, and
current execution binding. This app share format supports direct Interact
proposals with no pinned executor. Relayed outer proposal transactions require a
different proof format and are rejected.

Imports are encrypted in the local vault and deduplicated by pending ID. Lists
include them alongside the KV journal; `--local` reads only selected-chain imports
without RPC or KV setup and reports their live status as unknown. KV operation
sync also refreshes imported records' statuses. Re-export and all execution/signing
commands verify share envelopes again. Exported files use mode 0600 and contain
private operation details; disclose them only to intended recipients. Import
does not submit a transaction, and its `--dry-run` does not save anything.

## Compile and publish interactions

For a token registered as `circle/usdc`, save this as `transfer.ls`:

```text
let token = @token(circle/usdc)
in $require(token.transfer($arg0 :: address, $arg1 :: uint256))
```

```sh
export ETHERSCAN_API_KEY='your-token'
chainwall compile transfer.ls --chain base --out transfer.json
chainwall decompile transfer.json
chainwall disasm transfer.json
chainwall interactions add transfer.ls --chain base --dry-run
chainwall interactions add transfer.ls --chain base --out publication.json
chainwall interactions update transfer.ls --out publication.json
chainwall interactions deactivate transfer
chainwall interactions activate transfer
```

`compile` prints bytecode; `--json` prints the full compiler result. `--out` saves
it with original source, lowered core source, bytecode and Keccak hash, lossless
assembly, recovered source, resolved settings, and static references. These
settings make ABI-sensitive decompilation and recompilation reproducible.
`decompile` accepts compiler JSON, publication JSON, or a hex bytecode file.
It restores Registry names, short aliases, and ABI member calls such as
`token.balanceOf($self)` and `token.transfer(...)`. Compiler JSON includes the
resolved Registry paths and ABIs in `metadata` for offline source recovery.
The same view is available through `disasm --source`; plain `disasm` remains a
lossless opcode listing.

```sh
chainwall disasm transfer.json --source
chainwall interactions source transfer --live
chainwall interactions source transfer --offline
chainwall decompile program.hex --snapshot catalog.json --abi circle/usdc=erc20.json
```

Source recovery uses saved metadata and the selected profile's Registry/ABI
cache. `--live` fetches missing Registry records and verified ABIs.
`interactions source` reads the cached script when available, otherwise fetches
it; `--offline` requires a cached interaction and `--live` reads the current
script. Unavailable or incompatible metadata retains raw IO syntax. Restored
source is recompiled internally to verify byte-for-byte equivalence.
`--no-preprocess` displays core Lambdascript without Registry/ABI rewrites.

Lambdascript output is syntax-highlighted on ANSI terminals. Use
`--color auto|always|never`; automatic coloring respects `NO_COLOR`, `CLICOLOR=0`,
and `TERM=dumb`. Pipes are plain by default, and `--out` files and `--json`
output always remain plain. `interactions source --json` returns
`{id, bytecode, source, restored}`.

Interaction IDs default to the Keccak hash of the filename stem. `--id NAME` or
`--id 0x...` selects another ID. Add rejects existing IDs, and update rejects
missing IDs. Publication reads use one block and include the current bundle hash
in the Registry's compare-and-swap operation. Updates preserve current flags
(including inactivity) and linked entries unless explicitly replaced by
`--flags INTEGER` or `--linked-file FILE`. The linked file is a JSON array of
`{"relation":"0x...","payload":"0x..."}` objects, ordered as the contract
requires. `--out` on publication stores both the compiler result and exact
publication arguments before submission.

Native preprocessing supports `@contract(org/id)`, `@token(org/id)`, lazy global
aliases, scoped strict aliases, member calls, payable `{value: expression}`
options, recursive ABI arguments, and exact `::` type annotations for overloads.
It validates Registry kinds and inserts address resolution where the ABI requires
an address. Payable methods require an explicit value. Imports and module bundles
are not supported; input programs are individual `.ls` files.

Verified ABIs are retrieved through Etherscan V2 `getsourcecode`, following proxy
implementation metadata, using the selected chain ID. The current Registry
implementation address takes precedence when present. Cache entries live under
`abi/CHAIN_ID/ADDRESS.json` in the config directory. ABI contents are stored only
under the final implementation address (or the address of a non-proxy contract)
and do not expire. Proxy entries contain implementation mappings, not merged ABIs;
these mappings expire after 24 hours for online lookups. Offline consumers use the
last known mapping. Use `--refresh-abi` to refresh mappings and ABI contents. Only call targets need an ABI; token arguments
and price references do not trigger ABI downloads. `chainwall abi ADDRESS`
retrieves an ABI directly, with optional `--out FILE`. Explorer behavior follows
the [Etherscan V2 endpoint](https://docs.etherscan.io/api-reference/endpoint/getsourcecode).

For an unverified contract, supply `--abi org/id=abi.json`. This accepts an ABI
array or a compiler artifact containing `abi`. Repeat the flag for multiple
targets. Registry existence is still checked. A core call identified by a literal
target hash uses `--abi 0xTARGET_HASH=abi.json` or `--settings`; automatic Registry
discovery starts from named `@contract` and `@token` references.

Completely offline surface compilation uses `--snapshot metadata.json`:

```json
{
  "knownKindsByTargetHash": { "0xTARGET_HASH": "contract" },
  "abiByTargetHash": { "0xTARGET_HASH": [] }
}
```

Replace the hash and ABI with real metadata; `chainwall id org/id` computes the
hash. Kinds are `contract`, `token`, or `contract+token`. Snapshot key casing is
normalized. Additional `--abi` flags can supply or override snapshot ABIs.
Plain core programs compile offline without metadata. `--no-preprocess` accepts
core syntax with explicit `--settings`. Compiler options include
`--optimization size|baseline` and `--argument-context frame|subject`.

## Registry commands

The complete Registry ABI is embedded in `src/cli/artifacts/registry.json`.
Methods can be called by Solidity name, kebab-case name, or canonical signature.
`chainwall registry --help` lists everything; `<group> --help` narrows the list;
`<group> <method> --help` shows exact ABI names and types.
Built-in commands also have detailed help, for example `chainwall deploy --help`
and `chainwall interactions source --help`. Group help includes local CLI
subcommands alongside Registry methods. `--help --json` on an ABI method returns
its complete ABI entry, including nested tuple components.

Help and version output display the Chainwall name, website, and OKcontract Labs
attribution. Help tables align descriptions automatically and color commands and
options on supported terminals. `--color auto|always|never` controls help,
version, source, and all JSON output, including previews, artifacts, and config
exports to stdout. JSON uses subtle colors without bold text. Automatic mode
respects `NO_COLOR`, `CLICOLOR=0`, `TERM=dumb`, and output redirection. `--json`
output never contains color escapes, and saved files always remain plain.
Help requires no RPC or signer.

Groups include users, groups, accounts, safes, orgs, contracts, tokens,
interactions, policies, capabilities, roles, ownership, metadata, timelock,
terms, auth, sync, sync-query, interaction-sync, token-commits, emergency,
policy-state, diamond, and facets. The `registry` group always exposes the full
union, including governance, upgrades, commit/reveal, and synchronization methods.
An instance must have the corresponding facets installed.

`chainwall tokens set-chainlink-native-feed` applies the bundled Chainlink
native USD preset for the selected chain in one Registry `multicall`. It sets the
oracle environment (including L2 sequencer protection), feed maximum age, and
native USD feed/decimals. The preset and aggregator ABI are included in
`src/cli/artifacts/registry.json`. Chains without a preset fail before RPC or submission.
Both normal execution and `--dry-run` require an RPC to validate the feed's decimals,
positive answer, completed round, timestamp, and age at one canonical block.
The existing global age limit is preserved and enforced during validation.
Submission requires an admin signer and uses the normal receipt logs and timelock
classification. A queued result still needs execution through the timelock commands.

```sh
chainwall tokens set-chainlink-native-feed --dry-run
chainwall tokens set-chainlink-native-feed --account admin
chainwall tokens get-native-usd-feed-config
```

`tokens metadata ADDRESS|ORG/ID|HASH|@LABEL` reads ERC20 symbol and decimals at
one canonical block, including legacy `bytes32` symbols. `tokens configure`
requires an existing Registry contract record and discovers its token metadata;
`--symbol` and `--decimals` provide explicit overrides for nonstandard tokens.
Decimals must be known and at most 36. Existing price feeds are preserved unless
`--price-feed ADDRESS|none` replaces or clears them.

`tokens validate-feed ADDRESS --max-age SECONDS` reviews an arbitrary Chainlink
feed. Without `--max-age`, it uses the Registry's configured heartbeat. Validation
checks decimals, positive price, completed round, timestamp, heartbeat, and the
Registry's global staleness limit. These checks do not establish which asset or
denomination the feed represents; select the intended token/USD feed explicitly.
Configuration with `--feed-max-age` batches the heartbeat and token update in one
multicall. Submissions simulate before signing and distinguish queued updates
from applied updates. `--out` saves a new review file and its eventual receipt.

```sh
chainwall tokens metadata @USDC
chainwall tokens validate-feed "$USD_FEED" --max-age 3600
chainwall tokens configure acme/usdc --price-feed "$USD_FEED" --feed-max-age 3600 --dry-run
chainwall tokens configure acme/usdc --price-feed none --account admin
```

`chainwall terms accept-terms` selects the Registry's initial document, verifies
its exact bytes against the published SHA-256 digest, and submits that digest
using the configured signer, which needs `ADMIN_ROLE`. `--dry-run` verifies the
document and previews the transaction without signing. To select another
published document, use `terms accept-terms DOCUMENT_HASH`, `--document-hash HASH`,
or `--args-file FILE` containing `{ "documentHash": "0x..." }` or `["0x..."]`.
The command resolves the document's canonical URI onchain; unpublished hashes
are rejected. Use `terms get-terms-context` to inspect the initial document and
`terms instance-has-accepted-initial-terms` to check initial acceptance. Later
acceptance can be checked with `terms has-accepted-terms DOCUMENT_HASH`.

```sh
chainwall users contains "$USER_ADDRESS"
chainwall users remove --arg-user "$USER_ADDRESS"
chainwall groups list --start 0 --count 20
chainwall accounts list
chainwall registry upsertToken --args-file token.json --dry-run
chainwall registry upsertToken --args-file token.json
chainwall registry getInteractionBundle --help
chainwall timelock pending
chainwall timelock get "$ACTION_ID"
chainwall timelock approve "$ACTION_ID"
chainwall timelock execute "$ACTION_ID"
```

Positional arguments use cast's notation. Named `--arg-PARAMETER` flags avoid
collisions with global options such as `--account`. `--args-file` accepts either
a positional JSON array or an object keyed by exact ABI parameter names; nested
structs accept arrays or objects. Use JSON for strings with embedded quotes and
other complex arguments. Large integers should be decimal strings. Hash-based
generic methods take bytes32 values; use `chainwall id NAME` to derive them.

Read methods use `eth_call`; writes use `cast send`. `--json` returns structured
call results or transaction receipts. `--dry-run` prints chain ID, destination,
canonical function signature, calldata, and value without signing. Generic
calldata generation works offline; interaction publication previews require RPC
reads to resolve metadata and obtain the current bundle hash. `--value` is
accepted only for payable Registry methods. `--block` pins reads explicitly.
Global `--nonce N` passes an explicit transaction nonce to `cast call` and
`cast send` across Registry commands, interaction publication, deployment, and
KV creation. Decimal and `0x` hexadecimal values are accepted. Omit it for
Foundry's normal nonce selection. Each confirmed send advances the supplied
nonce, so `deploy --nonce N` uses `N`, `N+1`, and `N+2` for its three stages.
Read calls and dry runs do not advance it; dry-run JSON includes `nonce`.

Successful governance transactions report pending action IDs as `queued` rather
than claiming the change executed. Batch execution reports executed, expired,
and skipped IDs, with `partial` or `no-actions-executed` when applicable. The
receipt remains available in JSON output. `--unlocked --from ADDRESS` explicitly
selects an RPC-managed signer, useful for local Anvil testing.

## Search

`search [QUERY]` searches the selected chain and Registry's cached catalogs,
accounts, aliases, token symbols, public record fields, and saved tenant contract
addresses. It does not contact RPC. Results include dataset checkpoints; use
`sync` to refresh them. Exact identifiers and labels rank first, and all words in
a query must match. `--kind` filters collections, while `--start` and `--count`
page the ranked results.

```sh
chainwall search USDC
chainwall search treasury --kind accounts
chainwall search ExecutionEngine --kind system
chainwall search Alice --private
chainwall search Alice --passphrase-file /path/to/vault-password
```

Public searches do not unlock secrets. `--private` or `--passphrase-file` decrypts
labels in memory using the selected profile's key history. Search does not save a
decrypted index; an explicit `--out FILE` writes a new mode-0600 result file.
System addresses describe saved topology and are not live deployment proofs.

## Policy programs

`policies templates` lists the app's interaction and timelock policy templates.
Render a named template to editable source, then compile and publish it:

```sh
chainwall policies templates pause-switch --out pause.ls
chainwall policies program compile pause.ls --out pause.json
chainwall policies program publish @Spending pause.ls --max-steps 100000 --dry-run
chainwall policies program publish @Spending pause.json --account admin --out policy-update.json
chainwall policies program inspect @Spending
chainwall policies program simulate @Spending context.json
chainwall policies program clear @Spending --account admin
```

Allowlist templates require two distinct `--interaction ID|@LABEL` options.
The private destination template pins both live content hashes, so it cannot
silently authorize later replacements under the same interaction IDs. Other
templates cover budgets, a pause switch, and timelock capability-grant delays.
Review their constants and initialize the referenced policy state before use.

Compilation uses the embedded compiler, frame argument context, and bytecode
analysis. Publication accepts `.ls` source or a compiler artifact, rechecks the
installed program version, and simulates the write before signing. Normal
permissions and timelocks apply. `simulate` evaluates the installed program with
rollback. Its context file contains `interactionId`, `interactionArgs`,
`nativeValue`, `operationId`, `payloadHash`, `actor`, and `vault`; integer values
may be decimal strings. A rejected policy returns a nonzero exit status.

## Security council setup

`security-council inspect [GROUP|HASH|@LABEL]` shows the active configuration and
current member eligibility. To configure a council, select a group of 2 to 32
deployed contract accounts and an independent recovery contract outside that
group. The Registry itself cannot fill either role. Recovery addresses accept
Foundry account names and Registry labels.

```sh
chainwall security-council inspect @Council
chainwall security-council configure @Council --threshold 2 --recovery-authority @Recovery --dry-run
chainwall security-council configure @Council --threshold 2 --recovery-authority @Recovery --account admin --out council.json
chainwall security-council reconcile council.json "$TRANSACTION_HASH"
```

Submission requires a new `--out` file, binds the live membership revision,
checks administrator access, rechecks eligibility, and simulates before signing.
The report is saved before broadcast and updated with receipt evidence. A
`queued` outcome includes its action ID and ETA; execution uses the existing
timelock commands. Contract delays and pending-recovery restrictions still apply.
Reconciliation verifies canonical receipt events against the exact reviewed call,
including relayed AuthAccount calls, without submitting another transaction.

## Reference artifacts and checks

```sh
chainwall artifacts RegistryInteractionsFacet > interaction-artifact.json
chainwall artifacts > registry-reference.json
chainwall artifacts storage > storage-reference.json

# From this repository root:
zig build -Doptimize=safe
zig build test
```

Contract artifacts and input schemas are bundled under `src/cli/artifacts/`.
Changes to these files must keep ABIs, deployment bytecode, release manifests,
and expected runtime hashes consistent.

Native RPC reads retry transient connection failures, HTTP 408/429/500/502/503/504,
and explicit provider rate-limit errors up to three total attempts, with 100 ms
and 200 ms delays. Each attempt retains the configured request deadline. Reverted
calls, invalid responses and permanent errors are returned immediately. Oversized
read batches split recursively down to individual requests. Unknown methods and
submission methods are never retried; an ambiguous transport/server failure is
reported as `RpcSubmissionOutcomeUnknown`, which requires checking transaction
state before another submission. `Rpc.requests` counts successful logical reads;
`Rpc.wire_attempts` counts HTTP attempts including retries and splits.

Transaction `confirmations` count canonical blocks including the receipt block.
On Arbitrum, reports label this `confirmationBasis: "l2-block-depth"`.
`status: "confirmed"` means a successful receipt reached the requested depth;
it does not assert parent-chain finality or settlement. Add `--finality` to
`transactions track`, `refresh`, or `wait` to inspect the RPC's `safe` and
`finalized` tags after the observation. Each marker reports `reached`,
`not-reached`, or `unavailable`, with its canonical block or error. Without the
option both are `not-checked`. A replacement's marker applies to its receipt,
identified by `finalityTransactionHash`. `wait` still waits for block depth only.
Settlement is separately `not-checked`; no L1 rollup assertion or withdrawal
verification is performed. See [Arbitrum's finality reference](https://developer.arbitrum.io/how-arbitrum-works/reference/finality-and-reorgs).

Before an EOA broadcast, the CLI resolves the actual wallet address, freezes the
explicit or pending nonce, and records both with the chain ID and canonical
`submissionBlock` in the recovery intent. Foundry receives that exact sender and
nonce. The intent is durable before the subprocess starts; the returned hash is
saved before receipt polling. This supports recovery even if the transaction
later disappears from the RPC mempool. Concurrent use of the same signer can
still compete for the same nonce. ERC-4337 nonces remain bundler-managed and are
separate from EOA transaction nonces.

For standalone terms checking, supply all three inputs:

```sh
chainwall terms document IPFS_URI SHA256_DIGEST --document-file terms.md --offline
```

This requires no RPC endpoint, Registry, wallet, or Foundry. The explicit URI/hash
and local file also select offline verification without `--offline`; the flag
requires all inputs and prevents an accidental online lookup. The result verifies
exact bytes and UTF-8, reports `publicationStatus: "not-checked"`, and does not
establish that the document is published or accepted onchain.

Recover a proposal after an interrupted `operations propose`:

```sh
chainwall operations reconcile prepared.json --proposal-tx 0xTRANSACTION_HASH
```

Use the confirmed transaction hash from the submission journal or explorer.
If the file already contains a mined receipt or `proposalTxHash`, omit the flag.
The command verifies the direct Interact proposal transaction and canonical
receipt, fills `operationId` and `createdAt`, and atomically finalizes the input.
Rerunning is idempotent. `--dry-run` previews recovery; `--out recovered.json`
keeps the input and writes a separate result (an identical result may be reused).
It does not sign or resubmit, and historical recovery still works after an
operation closes. Wrapped/multicall/UserOperation transactions whose top-level
calldata is not `propose` are rejected; recover their underlying proposal context
before using this direct-transaction workflow.

Cached Registry lists, operation lists, recipient views, and transaction history
include a versioned `cache` object. Search, sync reports, and LSP catalog status
use `cacheByDataset` when several checkpoints are involved. Existing output fields
remain available.

| Field | Meaning |
| --- | --- |
| `formatVersion` | Metadata schema version, currently 1. |
| `source` | Origin such as `sqlite-cache`, `local-imports`, `journal-and-local-imports`, `transaction-journal`, or `snapshot-file`. |
| `checkpoint` | Original snapshot checkpoint, or explicit `null`. |
| `freshness` | `as-of-block` or `unknown`, with `asOfBlock`, `headChecked: false`, and unknown `ageSeconds: null`. Reading a cache does not establish current freshness. |
| `statusBlock` | Block used for a separately verified execution/authorization status, or `null`. This may differ from the discovery checkpoint and its chain. |
| `completeness` | Separate `snapshot` and `history` states (`complete`, `partial`, `unknown`), plus nullable verified range and indexer-through fields. |

Completeness describes the configured dataset and available secret history, not
all activity on the chain. Invalid or unreadable journal records make the decoded
snapshot partial. An indexed current-state snapshot does not prove historical
coverage. Explorer-only discovery does not establish complete history. Local
imports have no chain-discovery checkpoint; missing evidence remains unknown.
Raw ABI-array exports retain their ABI format; LSP catalog status exposes their
availability/errors alongside this metadata.
