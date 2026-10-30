---
title: "Chainwall CLI user manual"
author: "© OKcontract Labs, All rights reserved."
hotnotes:
  logo: note:C8B1F59F-F7D7-4657-8097-BC12AD841564
  footer: "Page **%p** of %n ✧ *Confidential until public release*"
  style: preview-avenir-notes
  pdf:
    paper: a4
    pageNumbers: true
    baseFontSize: 11
    bibliographySize: 85%
    newPageBeforeSections: false
    columns: 1
    logoHeight: 26
---
# Chainwall CLI user manual

For completion, diagnostics, and native compilation while editing `.ls` files, see the
companion [Lambdascript editor guide](LSP.md) for `chainwall-lsp`.

For `chainwall` 0.3.1. This manual is for people using a distributed binary.
The examples use installed commands and ordinary files.

Chainwall manages who may perform onchain actions, which contracts and tokens those
actions may use, and which approvals or delays they require.
The `chainwall` command connects to an existing Chainwall Registry, manages its
configuration, compiles interaction programs, and keeps a local view of Registry data
and encrypted operation proposals.

## Contents

1. [How Chainwall fits together](#1-how-chainwall-fits-together)
2. [Install and check the tools](#2-install-and-check-the-tools)
3. [Connect to your first instance](#3-connect-to-your-first-instance)
4. [Profiles and configuration](#4-profiles-and-configuration)
5. [Signers, passwords, and transactions](#5-signers-passwords-and-transactions)
6. [Find commands and supply arguments](#6-find-commands-and-supply-arguments)
7. [Users, groups, and policies](#7-users-groups-and-policies)
8. [Accounts, Safes, and administrative authority](#8-accounts-safes-and-administrative-authority)
9. [Organizations, contracts, and tokens](#9-organizations-contracts-and-tokens)
10. [Write Lambdascript files](#10-write-lambdascript-files)
11. [ABIs and offline compilation](#11-abis-and-offline-compilation)
12. [Publish and maintain interactions](#12-publish-and-maintain-interactions)
13. [Inspect and reproduce bytecode](#13-inspect-and-reproduce-bytecode)
14. [Sync and browse local data](#14-sync-and-browse-local-data)
15. [Manage queued Registry actions](#15-manage-queued-registry-actions)
16. [Connect encrypted operation storage](#16-connect-encrypted-operation-storage)
17. [Read operation proposals](#17-read-operation-proposals)
18. [Use several chains](#18-use-several-chains)
19. [Automation and JSON output](#19-automation-and-json-output)
20. [Backups, upgrades, and recovery](#20-backups-upgrades-and-recovery)
21. [Troubleshooting](#21-troubleshooting)
22. [Command and option reference](#22-command-and-option-reference)
23. [Glossary](#23-glossary)

## 1. How Chainwall fits together

A **Registry instance** is the onchain address containing a particular Chainwall
configuration. Its users, policies, contract catalog, and interactions belong to that
instance on that chain.
Two instances on Base are separate; the same address on Base and Ethereum also refers to
separate chain state.

The main concepts are:

| Concept | What it represents |
| --- | --- |
| User | An address registered as a participant. Administrative powers are assigned through roles and capabilities. |
| Group | A set of registered users, such as treasury approvers. |
| Policy | Required approvals from groups, with an optional program that imposes additional conditions. |
| Capability | A particular administrative power assigned through Registry groups, or to designated system actors. |
| Organization | A namespace and membership record for catalog entries. |
| Contract | A named deployment, with versions and optional implementation metadata. |
| Token | Token metadata associated with a contract entry, including decimals and price-feed information. |
| Interaction | A registered MiniScript program describing an allowed interaction with onchain contracts. |
| Account or Safe | A managed address registered with the instance. |
| Timelock action | A queued change to Registry governance or configuration. |
| Operation proposal | A proposed execution of an interaction, associated with an account or Safe, arguments, and policy. |

**Lambdascript** is the source language used to write interactions.
The compiler turns a `.ls` file into **MiniScript bytecode**, which Chainwall’s onchain
execution engine interprets.
Registering that bytecode publishes a program; execution is a separate operation subject
to the deployment’s authorization and policy rules.

**Interact** is the execution component used for operation state and approvals.
It is a different contract from the Registry.
The CLI can check operation proposal status against an explicitly configured Interact
belonging to the selected Registry.

The app can also publish encrypted operation journals to a **PasswordGatedKV** contract.
This storage contract can be on another chain.
Its encrypted records let clients recover proposal details.
The CLI imports the shared secret into a local encrypted vault, syncs the ciphertext,
and decrypts proposals when you list them.

The CLI creates, publishes, approves, withdraws, and executes interaction operations.
`operations approve` approves an Interact operation; `timelock approve` approves a
Registry governance action.

## 2. Install and check the tools

Obtain the Chainwall binary for your operating system and CPU architecture from your
distributor. Follow the release’s integrity-verification instructions, if provided, and
extract the archive.

On macOS or Linux, an installation in your own account can look like this, run from the
directory containing the extracted `chainwall` binary:

```sh
mkdir -p "$HOME/.local/bin"
install -m 755 chainwall "$HOME/.local/bin/chainwall"
export PATH="$HOME/.local/bin:$PATH"
chainwall --version
chainwall --help
```

Add the PATH setting to your shell startup file to keep it for new terminals.
On Windows, put `chainwall.exe` in a directory on PATH. The shell examples in this
manual use POSIX shell syntax; PowerShell variable assignments and quoting need the
equivalent PowerShell syntax.
An explicit configuration directory is useful on Windows:

```powershell
$env:CHAINWALL_CONFIG_DIR = "$env:USERPROFILE\.config\chainwall"
chainwall --version
```

Install Foundry so that `cast` is on the same process’s PATH. Foundry provides prebuilt
tools and an installer; use its
[official installation guide](https://getfoundry.sh/getting-started/installation?embedable=true).
The CLI has been tested with Foundry 1.7.1. Confirm the installed command:

```sh
cast --version
```

Chainwall uses `cast` for Foundry account handling, signing, and general contract calls.

Some distributions may include a second executable, `miniscript`. It provides the
low-level compiler and assembler described in
[section 13](#13-inspect-and-reproduce-bytecode).
Ordinary Chainwall workflows use the `chainwall` binary.

Before connecting, obtain these details from your instance administrator:

- The chain and its RPC URL.
- The Registry address on that chain.
- The signing address authorized for the work you intend to do, if you will send
  transactions.
- For encrypted operations: the KV chain, KV address, current shared secret, and
  Interact address for each execution chain.

An Etherscan API token is needed when fetching verified ABIs and when selecting explorer event
history from contracts whose optional indexing is disabled.

## 3. Connect to your first instance

The examples use shell variables such as `REGISTRY_ADDRESS` and `BASE_RPC_URL`. Set them
to your administrator’s actual values before running a command that uses them.
Replace abbreviated placeholders such as `0x...` with complete addresses.
All addresses in sample JSON and TOML below are examples to replace.

Create a profile for a Base instance:

```sh
chainwall profile create treasury-base
chainwall profile use treasury-base
chainwall config set chain base
chainwall config set rpc_url "$BASE_RPC_URL"
chainwall login "$REGISTRY_ADDRESS"
chainwall config show
```

`profile create` makes an empty profile.
`profile use` selects it for subsequent commands.
`login` accepts either a Registry address or the SafeFactory instance address shown in
the app. For example, you can use the instance directly:

```sh
chainwall login "$INSTANCE_ADDRESS" --chain base --rpc-url "$BASE_RPC_URL"
```

For an instance, login follows `INTERACT_CONTRACT()` to its Interact contract, then
`registry()` to its Registry.
It checks the RPC’s chain ID, deployed code, and component identities before saving.
The profile’s `instance` setting and selected `[instances]` entry always contain the
resolved Registry address.
The selected `[rpc]` entry is updated too.
Instance login also saves the linked Interact address in `interact` and `[interacts]`
for operation status checks.
Logging into a different Registry directly clears the old Interact binding.
Direct `--instance` overrides on other commands expect a Registry address.

Login saves the connection to your existing Registry. Connect and inspect public data
first, then configure an authorized signer when you are ready to submit transactions.

Start by syncing just users and interactions:

```sh
chainwall sync --only users,interactions
chainwall users list
chainwall interactions list --count 100
```

These lists describe the block recorded in their checkpoint.
Run `sync` again when you need a fresh snapshot.
A direct read bypasses the entity cache:

```sh
chainwall users count
chainwall users contains "$USER_ADDRESS"
chainwall users list --live
```

To enable signing with an existing Foundry account:

```sh
chainwall accounts
chainwall config set account treasury-signer
```

If you need to import a signing key, do that through Foundry’s interactive keystore
workflow:

```sh
cast wallet import treasury-signer --interactive
```

Choose the account name that actually exists on your machine.
The signing address needs the appropriate Registry authority and enough of the chain’s
native currency to pay transaction fees.

Review a first change before submitting it:

```sh
chainwall users add "$USER_ADDRESS" --dry-run
```

This prints the intended destination and calldata.
When you intend to submit that change, run it without `--dry-run`:

```sh
chainwall users add "$USER_ADDRESS" --json
```

Read the returned `status`. If it is `queued`, finish the timelock workflow in
[section 15](#15-manage-queued-registry-actions) before expecting the user to appear.
After the change executes, refresh and inspect:

```sh
chainwall sync --only users
chainwall users list --offline
```

### Deploy a new instance

Create a tenant through the network’s existing OKFactory:

```sh
chainwall deploy --factory "$OK_FACTORY_ADDRESS" --owner "$OWNER_ADDRESS" \
  --salt "$BYTES32_SALT" --out deployment.json
```

Supply a salt and the intended owner explicitly. `--owner` accepts
an address or a local Foundry account name:

```sh
chainwall deploy --factory "$OK_FACTORY_ADDRESS" --owner treasury \
  --account deployer --salt "treasury autumn 2026" --out deployment.json
```

The owner name is resolved with `cast wallet address --account treasury`.
`--account deployer` independently selects the transaction signer.
Foundry may prompt for the owner's keystore password, including during `--dry-run`.
The selected `--password-file` or profile `password_file` applies to both owner
lookup and signing. If their passwords differ, omit that setting to use prompts,
or supply the owner's address directly.

Salts accept 32-byte hex or a memorable public phrase. A phrase becomes
`keccak256(UTF-8 text)`; capitalization and every space matter. Hex inputs starting
with `0x` must have exactly 64 hexadecimal digits and are used unchanged, including
the all-zero salt. Empty or whitespace-only phrases are rejected.

Deployment salts do not need to be secret or random. Use a distinct label for each
deployment: the same factory, owner, flags and salt identify the same instance.
Someone may submit the same configuration first, but changing the owner changes
the deployment key. A phrase is a public label, never a wallet recovery phrase.
Commit/reveal salts are different: they still require explicit bytes32 values with
enough unpredictability to protect hidden inputs.

The command sends the app's three transactions: bootstrap, prepare, and finalize.
Indexing is on by default (`--indexing`); `--no-indexing` disables it.
AuthAccounts are off by default (`--no-auth-accounts`); `--auth-accounts` enables them.
Numeric `--flags 0|1|2|3` remains available as an alternative to the named switches.
Conflicting switches or mixing switches with `--flags` is rejected.
It uses the selected chain, RPC, and Foundry signer.
A completed deployment saves its component addresses and selects the new Registry in the
current profile.
The complete result and receipts are saved under `~/.config/chainwall/logs`;
the command prints the log path. Use `chainwall logs show latest` to inspect it,
or `--json` to also print the original deployment JSON for scripts.

To stop after bootstrap, add `--stage bootstrap`. If interrupted after a successful
stage, use the printed Registry address to continue:

```sh
chainwall deploy --factory "$OK_FACTORY_ADDRESS" --stage prepare --registry "$REGISTRY_ADDRESS"
chainwall deploy --factory "$OK_FACTORY_ADDRESS" --stage finalize --registry "$REGISTRY_ADDRESS"
```

Use only the remaining stages.
Reusing an already committed salt/owner/flags returns the existing Registry address.
`--dry-run` produces a local calldata preview; the default full flow previews
bootstrap and lists the dependent stages.
Preview prepare/finalize separately once the Registry address is known.
`--factory` overrides `config set factory ADDRESS`, which overrides the bundled address
for the selected chain.
`src/cli/artifacts/factory-addresses.json` supplies defaults only for Arbitrum One
(chain ID `42161`), including `kv create`. Other chains require an explicit factory
address.

After deployment, accept the initial terms as described in
[Inspect and accept terms](#inspect-and-accept-terms), then configure native USD
valuation with an authorized administrator:

```sh
chainwall tokens set-chainlink-native-feed --dry-run
chainwall tokens set-chainlink-native-feed --account admin
chainwall tokens get-native-usd-feed-config
```

The preset checks the Arbitrum feed and sequencer configuration before building
the governance calls. Verify the applied configuration before relying on native
asset valuations; a zero feed returns `NativePriceFeedNotConfigured` in
`accounts assets` or `safes assets` with these recovery commands.

## 4. Profiles and configuration

### Exchange configuration with the app

```sh
chainwall config import app-configuration.json
chainwall config export app-configuration.json
```

The JSON format is the app’s version-2 configuration snapshot, including instance
topology, account address, locale, RPC override, Etherscan key, and the shared secret
plus its KV address and chain.
Import validates offline before selecting the new settings.
It preserves the separately configured Foundry signer; the app’s account field is a
wallet address, not a keystore name or signing private key.

The shared secret is encrypted in the CLI vault.
These commands prompt for the vault passphrase when needed; use `--passphrase-file FILE`
in automation. Exported JSON contains the plaintext shared secret and API key, as in the
app. Files are written atomically with mode 0600. Without an output path, export writes
JSON to stdout. `config show --json` still redacts credentials.

Exports use saved profile settings, retain app-only metadata, and include component
addresses recorded by `deploy`. They do not include CLI-only keystore/password settings
or additional per-chain RPC tables.

### Files and active profile

By default, configuration is stored under `~/.config/chainwall`:

```text
chainwall/
  active
  treasury-base.toml
  treasury-ethereum.toml
  chainwall.sqlite3
  abi/
```

`active` records the selected profile name.
The SQLite database stores synced records and encrypted vault data.
`abi/` contains downloaded ABI cache files.
SQLite may also create `chainwall.sqlite3-wal` and `chainwall.sqlite3-shm`.

The configuration directory is selected in this order:

1. `--config-dir PATH`
2. `CHAINWALL_CONFIG_DIR`
3. `$XDG_CONFIG_HOME/chainwall`
4. `$HOME/.config/chainwall`

The profile is selected by `--profile NAME`, then `CHAINWALL_PROFILE`, then the `active`
file, then the name `default`. Profile names contain 1 to 64 ASCII letters, digits,
hyphens, or underscores.
The implicit `default` profile can start empty.

```sh
chainwall profile list
chainwall profile create treasury-ethereum
chainwall profile use treasury-base
chainwall --profile treasury-ethereum config set chain ethereum
chainwall --profile treasury-ethereum config set rpc_url "$ETHEREUM_RPC_URL"
chainwall --profile treasury-ethereum login "$ETHEREUM_REGISTRY_ADDRESS"
```

The `--profile` override applies to that command; later commands use the active profile.
Profiles in the same directory share one database and local vault.
Use a separate `--config-dir` when you need independent local stores or passphrases.

### Inspect and change settings

```sh
chainwall config show
chainwall config show --json
chainwall config get chain
chainwall config set account treasury-signer
chainwall config unset password_file
```

`config show` displays stored profile values, not a fully expanded view of environment
and command-line overrides.
RPC URLs and the Etherscan token are redacted in printed configuration, including
`config get`. The saved TOML still contains their actual values.
Profile files are written atomically with mode 0600 on POSIX systems.

Supported scalar settings:

| Key | Meaning |
| --- | --- |
| `chain` | Default execution chain name or numeric ID. Defaults to `ethereum`. |
| `rpc_url` | RPC for the profile’s default execution chain. |
| `instance` | Default Registry address. |
| `account` | Foundry keystore account name. |
| `keystore` | Path to an encrypted keystore outside Foundry’s default directory. |
| `password_file` | Path to the Foundry account password file. |
| `etherscan_api_key_env` | Name of the environment variable containing the API token. Defaults to `ETHERSCAN_API_KEY`. |
| `etherscan_api_key` | API token stored directly in the profile, used if the selected environment variable is absent. |
| `etherscan_url` | Etherscan V2-compatible API endpoint. |
| `kv_factory` | PasswordGatedKVFactory address used by `kv create`. |
| `kv_address` | PasswordGatedKV address used for operation journals. |
| `kv_chain` | Storage chain; defaults to the selected execution chain. |
| `kv_rpc_url` | Explicit RPC for the storage chain. |
| `interact` | Interact address bound to the selected Registry, for operation status checks. |

Setting `account` removes a stored `keystore`, and setting `keystore` removes a stored
`account`.

### TOML example

This profile uses Base by default and also has Ethereum connection settings:

```toml
chain = "base"
account = "treasury-signer"
instance = "0x1111111111111111111111111111111111111111"
etherscan_api_key_env = "ETHERSCAN_API_KEY"

[rpc]
base = "https://your-base-rpc.example"
ethereum = "https://your-ethereum-rpc.example"

[instances]
base = "0x1111111111111111111111111111111111111111"
ethereum = "0x2222222222222222222222222222222222222222"

[interacts]
base = "0x3333333333333333333333333333333333333333"
ethereum = "0x4444444444444444444444444444444444444444"
```

The supported TOML schema is deliberately small: quoted scalar values, comments, numeric
chain IDs, and the `[rpc]`, `[instances]`, and `[interacts]` tables.
Use TOML tables for chain-specific assignments.
Arrays, multiline strings, dates, and inline tables are unsupported.
Unknown settings and duplicate keys are errors.

The CLI writes table entries using dotted *configuration key arguments*:

```sh
chainwall config set rpc.base "$BASE_RPC_URL"
chainwall config set instances.base "$REGISTRY_ADDRESS"
chainwall config set interacts.base "$INTERACT_ADDRESS"
```

### Selection precedence

| Value | Highest priority first |
| --- | --- |
| Execution chain | `--chain`, `CHAINWALL_CHAIN`, profile `chain`, `ethereum` |
| RPC | `--rpc-url`, `CHAINWALL_RPC_URL`, matching `[rpc]` entry, eligible `rpc_url` |
| Registry | `--instance`, `CHAINWALL_INSTANCE`, matching `[instances]` entry, `instance` |
| Foundry account | `--account`, `CHAINWALL_ACCOUNT`, `account`, subject to explicit signer selection |
| Keystore path | `--keystore`, otherwise `keystore` when no account or unlocked signer is selected |
| Foundry password file | `--password-file`, `password_file` |
| Explorer endpoint | `--etherscan-url`, `etherscan_url`, `https://api.etherscan.io/v2/api` |
| Interact | Matching `[interacts]` entry, then `interact` |

The scalar `rpc_url` is eligible only on the profile’s default chain.
Changing chains therefore requires an appropriate table entry or explicit RPC override.
The scalar `instance` remains a fallback on other chains, so configure chain-specific
Registry addresses when they differ.

A matching table entry takes priority over its scalar fallback.
`login` updates both the scalar defaults and selected chain’s entries; other chains are
preserved. One profile per instance and chain is often the easiest arrangement.

Supported chain names:

| Names | Chain ID |
| --- | ---: |
| `ethereum`, `mainnet` | 1 |
| `base` | 8453 |
| `arbitrum` | 42161 |
| `optimism` | 10 |
| `polygon` | 137 |
| `bsc` | 56 |
| `avalanche` | 43114 |
| `gnosis` | 100 |
| `sepolia` | 11155111 |
| `base-sepolia` | 84532 |
| `anvil`, `localhost` | 31337 |

Other chains use a numeric chain ID from 1 through 9,007,199,254,740,991, matching
the exact JSON integer range used by configuration export. Configure an RPC URL for each chain,
and check Etherscan coverage and your API plan before using explorer commands.

## 5. Signers, passwords, and transactions

### Passkeys and sponsored transactions

Enroll in a browser at the AuthAccount factory’s configured origin:

```sh
chainwall auth enroll --label "My passkey" --out enrollment.json
chainwall auth create enrollment.json --out passkey.json --account administrator
chainwall auth register passkey.json --account administrator
chainwall auth inspect passkey.json
```

Enrollment uses the app’s existing enrollment JSON. The resulting `passkey.json` uses
the public fields of the app's `AuthSessionProfile`.
Both files are written with mode 0600. Create saves the predicted account’s profile
before broadcasting.
If interrupted, rerun with the same enrollment, scopes, and output file to resume the
idempotent factory deployment.
Use `--scopes-file FILE` for initial direct-execution scopes.
Registration verifies the deployed account, authorizes its factory, adds the user, and
links the credential.
If governance queues a step, execute its timelock action and rerun registration to
continue.

Recover a public signing profile for an existing resident passkey:

```sh
chainwall auth recover --label "My passkey" --out recovered-passkey.json
chainwall auth inspect recovered-passkey.json
```

Recovery opens the same origin-bound approval page and selects an existing
credential. It creates no credential or transaction. The CLI independently checks
credential-derived hashes, active onchain credential state, factory installation,
and Registry/RP/origin bindings against a fresh canonical block before saving the
profile. Registration and policy permissions remain separate.

Use `--auth-factory ADDRESS` when topology discovery is unavailable, or
`--auth-account ADDRESS` to choose among multiple matching accounts. Factories
above 10000 accounts require an explicit account to bound the search.
`--credential-file FILE` accepts existing public credential metadata, including an
enrollment or profile, for recovery without a browser. It receives the same checks.
`--dry-run` checks the factory without prompting or writing. Output files use mode
0600 and cannot overwrite existing files; interrupted requests leave an explicit
marker rather than a usable profile.

Use `--auth-profile` on transaction and operation-signing commands.
Each action opens an approval page that displays the request before prompting for a
passkey:

```sh
# The passkey is the actor; the Foundry account pays gas.
chainwall users add "$USER_ADDRESS" --auth-profile passkey.json --account gas-payer

# A ZeroDev-compatible bundler/paymaster sponsors the UserOperation.
chainwall users add "$USER_ADDRESS" --auth-profile passkey.json --bundler-url "$BUNDLER_URL"

# Recover a submitted operation after an interrupted receipt wait.
chainwall auth receipt "$USER_OP_HASH" --auth-profile passkey.json --bundler-url "$BUNDLER_URL"
```

Browser approval works on macOS, Linux, and Windows through an externally hosted
Chainwall app or compatible approval page. The page must use the **exact origin**
configured in the instance's AuthAccountFactory. The RPC and bundler must allow
browser requests from that origin.

`--approval-url` selects a compatible hosted approval page. WebAuthn and the
contracts bind each passkey to the configured RP ID and origin. Local HTTP is
supported only for a factory configured for that localhost origin.

Omit `--approval-url` to use the app’s CLI approval route.
`--app-url` selects an app base path within the configured origin.
Choose one of these options and use a path within the configured origin, with an
empty query and fragment. `--no-browser` prints the approval link; run the browser
on the CLI's machine because the session uses loopback.
Click **Load CLI request**, review it, then approve or reject.
Retry a failed result delivery using the existing signed result.

`--approval-timeout SECONDS` defaults to 300. The browser may request local network
permission when loading the request.
Sessions require both the exact app origin and a random single-session capability, and
expire automatically.

Passkeys support zero-value protocol calls and ERC-1271 signatures, including Safe owner
and execution-actor signatures.
For these signatures, select the passkey owner with `--auth-profile`, then combine the
signature outputs as usual.
Raw Safe execution still uses its submitting gas payer.
Use the app’s supported protocol targets and selectors; arbitrary external calls are
rejected by the AuthAccount.
A Foundry sponsor’s `--nonce` is forwarded normally; sponsored UserOperations reject
`--nonce` because the bundler uses the account’s EntryPoint nonce.
The CLI verifies sponsored success against the EntryPoint event on its configured RPC. A
reported UserOperation hash lets you recover its status with `auth receipt`.

### Keep the different credentials distinct

| Credential | Purpose | How the CLI receives it |
| --- | --- | --- |
| Foundry signing key | Signs transactions from your onchain address. | Foundry account name or encrypted keystore path. |
| Foundry keystore password | Unlocks that signing key in `cast`. | Foundry prompt or `--password-file FILE`. |
| KV shared secret | Decrypts the app’s encrypted journal records. | Imported with `--secret-file FILE`, then kept encrypted in SQLite. |
| Local vault passphrase | Unlocks locally stored KV secrets and private status snapshots. | Hidden terminal prompt or `--passphrase-file FILE`. |
| Etherscan API token | Authorizes explorer API requests. | Environment variable or profile setting. |

The vault passphrase unlocks local secrets. The KV secret decrypts journal data, while
your transaction signer supplies the authority checked by Registry roles, capabilities,
and operation policies.

### Choose a signer

```sh
chainwall users add "$USER_ADDRESS" --account treasury-signer --dry-run
chainwall users add "$USER_ADDRESS" --keystore /absolute/path/to/keystore.json --dry-run
```

Select one signer mode.
An explicit `--keystore` overrides an inherited account; an explicit `--account`
overrides an inherited keystore.
Supplying conflicting explicit modes is an error.

For unattended signing, provision a restricted password file and pass its path:

```sh
chainwall users add "$USER_ADDRESS" \
  --account treasury-signer \
  --password-file /absolute/path/to/foundry-password \
  --json
```

The CLI uses `cast` to unlock the Foundry signer and sign transactions. Use the signer
options listed by `chainwall --help`.

`--from ADDRESS` supplies a caller address for calls. Select a signer separately for
transactions. For an explicitly configured RPC-managed account, such as a local test
node, select `--unlocked --from ADDRESS`.

Wallet address arguments also accept local Foundry account names. This includes
`--from`, deployment `--owner`, Safe creation `--owners`, user/account/Safe arguments,
and ABI `address` fields in positional arguments, named flags, and JSON argument files.
JSON address arrays and nested tuples are resolved recursively. Existing `@labels`
continue to use the Registry label lookup.

```sh
chainwall users add treasury --account administrator --dry-run
chainwall accounts add --arg-account treasury --dry-run
chainwall ownership transfer treasury --dry-run
chainwall safes create --salt "$BYTES32_SALT" --owners alice,bob --threshold 2
chainwall users contains treasury --from administrator
```

Names resolve through `cast wallet address --account NAME`; they do not select the
transaction signer. Foundry may prompt for each referenced account's password,
including in previews. The selected password file also applies to these lookups.
For complex positional arrays or tuples, use named JSON flags or `--args-file`.
New operation proposal files also accept a name in `safe`; the saved proposal records
the resolved address. Signed artifacts continue to contain literal addresses.

Use an explicit `--from` for caller-sensitive reads.

Use global `--nonce N` to supply the nonce to `cast call` and `cast send`. It applies to
every transaction-producing CLI command, including Registry writes, interaction
publication, deployment, and KV creation.
Decimal and `0x` hexadecimal forms are accepted.
Without it, Foundry selects the nonce.
For a multi-stage deployment, it is the starting nonce: each confirmed send advances it
by one. Calls and dry-run previews leave it available for the next transaction.
On a later resume command, supply the current nonce or omit the option.

### Understand what a command does

Every Foundry submission reserves a private log containing its intended request,
then saves the broadcast hash before waiting for a receipt. A crash, RPC error or
timeout does not cause an automatic resend. The default receipt wait is 120 seconds
with one confirmation; change these with `--wait-timeout` and `--tx-confirmations`.
Zero wait time checks once and leaves a pending transaction recoverable.
Automatic intent logs and cached transaction envelopes contain calldata hashes,
not plaintext reveal data. This protects unpublished salts on private RPC routes.
Use `transactions inspect HASH` to explicitly inspect live transaction calldata.

```sh
chainwall transactions list
chainwall transactions track "$TX_HASH"
chainwall transactions wait "$TX_HASH" --timeout 300 --confirmations 3
chainwall transactions refresh
chainwall transactions speed-up "$TX_HASH" --dry-run
chainwall transactions speed-up "$TX_HASH" --bump 15
chainwall transactions cancel "$TX_HASH"
```

Speed-ups and cancellations estimate the replacement payload on the selected
chain and add a 20% gas margin. Explicit `--gas-limit` values must cover the
estimate; speed-ups also retain at least the original gas limit.


The list is a local snapshot for the selected chain. `track HASH` adds or updates
an observation. `refresh [HASH]` refreshes one hash or a page of tracked entries;
`--start` and `--count` select pages of at most 100. `wait` polls for canonical
receipts, defaults to 120 seconds, and accepts `--poll-interval 1..60` (default 2).
`--timeout 0` checks once. These commands never resubmit transactions. `--out FILE`
reserves a new report file with private permissions.

`confirmed` means a successful canonical receipt reached the requested block
depth. On Arbitrum these are L2 blocks, as `confirmationBasis` states. Add
`--finality` to track, refresh or wait for separate RPC `safe` and `finalized`
observations. Unsupported tags remain `unavailable`; omitted checks remain
`not-checked`. This option reports markers after depth tracking and does not
change the wait condition. Settlement remains `not-checked`: neither block
depth nor these RPC markers prove rollup assertion or withdrawal settlement.

A consumed nonce triggers a search starting at the saved submission block, or
the last 64 blocks when submission context is unavailable. `--lookback 0..1024`
bounds blocks examined per observation; zero disables scanning. Blocks are fetched
in batches of 16. Persisted `replacementSearch` progress resumes on the next
observation after validating its canonical anchor, and resets after a reorg. Matching sender,
nonce, destination, calldata, value and access list establish `repriced`.
An empty self-transfer is `cancelled`; other payloads are `replaced`. A consumed
nonce without a discovered replacement is `nonce-used`, not proof of execution.
Unknown hashes remain `unknown`. Wait exits nonzero for pending, unknown,
reverted, cancelled or changed-payload outcomes. Receipt recovery does not resume
deployment stages or finalize application drafts; use the applicable reconcile
command with the recovered transaction hash.

Speed-up requires the original EOA signer and a verifiably pending transaction.
It preserves the nonce, payload, value, access list and fee model. Both EIP-1559
fee caps, or the legacy price, increase by at least `--bump` percent (default 15).
RPC suggestions can produce a higher increase. Inspect `--dry-run` and provide
explicit `--max-fee`/`--priority-fee` or `--gas-price` limits when needed. Limits
below the requested increase are rejected. Cancellation sends an empty, zero-value
self-transfer at the same nonce, requiring a sender with no code and its next
pending nonce. Either the original or replacement can win until mined.

AuthAccount/UserOperation, blob and EIP-7702 replacement require the corresponding
wallet or bundler workflow. `auth receipt` still recovers saved UserOperation
handles. No wallet private key or RPC URL is stored in transaction tracking data.

Preview gas and fees for the prepared transaction before submitting:

```sh
chainwall users add "$USER_ADDRESS" --estimate --from administrator
chainwall transactions estimate transaction.json --from administrator --out fees.json
chainwall users add "$USER_ADDRESS" --gas-limit 150000 --max-fee 10gwei --priority-fee 1gwei
```

`--estimate` implies `--dry-run`. It never broadcasts and does not sign a new
transaction. Use `--from ADDRESS|ACCOUNT` to select the simulated sender; without
it, the configured wallet may need unlocking just to obtain its address.
`transactions estimate FILE` accepts a dry-run JSON report, a saved estimate, or
`{chainId,to,data,value,from?,nonce?}`. Omit `to` for contract creation. It rejects
mismatched chains and senders and preserves supplied access lists.

Use `--estimate` with commands that prepare a transaction. Local configuration,
profile-management, and list commands reject it before changing state.

The report gives the canonical block, estimated gas, gas limit, fee model,
estimated transaction fee, maximum transaction fee, native value and sender balance.
The default gas limit adds 20% to the estimate. EIP-1559 defaults use twice the
block base fee plus the RPC priority suggestion. `--gas-limit N`, `--max-fee`,
and `--priority-fee` override those values. `--gas-price` selects legacy pricing;
`--legacy` selects that model with an RPC-suggested price. Fee amounts accept
exact wei or gwei, without floating-point rounding. The same options apply to
Foundry submissions; pass reviewed limits again when sending.

On Arbitrum, `estimatedTransactionFeeWei` includes both L2 execution and L1 data
posting, as included by `eth_estimateGas`. Do not add the L1 component again.
`maximumTransactionFeeWei` applies the chosen gas limit and maximum gas price;
`maximumValueAndFeeWei` also includes transferred native value. Estimates vary
with chain state and are not a guarantee of the final fee. On other chains, the
scope is the gas estimate supplied by that chain's RPC. Multi-stage deployments estimate the displayed
stage; later stages require their prerequisites mined first. Requests that require
actor or Safe signatures need those signatures present to pass estimation.
Passkey and UserOperation fee review remains in the browser approval flow, where
the actual outer transaction is known. A reverted estimate never broadcasts.

| Command kind | Effect |
| --- | --- |
| Read method | Makes an RPC call and returns its result. |
| Cached list | Reads the local database at its recorded checkpoint. |
| `sync` | Fetches chain data and commits a local snapshot. |
| `compile`, `decompile`, `disasm` | Produces or inspects a program. Named references can require metadata reads during compilation. |
| Registry write | Signs and broadcasts a transaction through `cast`. |
| Registry write with `--dry-run` | Previews destination, chain ID, canonical function signature, calldata, and value. |

`--dry-run` previews calldata. Use the relevant simulation command to check
authorization, policy requirements, and execution against current chain state.
Generic Registry previews can be generated offline.
Interaction publication previews need chain reads to resolve references and capture the
current bundle. `kv create --dry-run` also stores a pending secret locally; see
[section 16](#16-connect-encrypted-operation-storage).

Review the command before signing: a normal write can broadcast as soon as signing
succeeds.
`--value` attaches native currency to a payable Registry method; decimal wei is an
unambiguous representation.
Nonpayable methods reject it.

The CLI reports these transaction outcomes:

| `status` | Interpretation |
| --- | --- |
| `confirmed` | The transaction succeeded. Read the relevant state and receipt for its effect. |
| `queued` | It queued one or more governance actions; the intended change still needs the applicable approval/delay/execution workflow. |
| `partial` | A batch executed some actions while others expired or were skipped. |
| `no-actions-executed` | A batch transaction succeeded without executing any requested action. |

JSON receipts include `queuedActions`, `executedActions`, `expiredActions`,
`skippedActions`, and the original `receipt`. A successful process exit is not enough to
establish that a queued or batched change took effect.

## 6. Find commands and supply arguments

### The binary is its own contract reference

```sh
chainwall --help
chainwall deploy --help
chainwall interactions source --help
chainwall users --help
chainwall registry --help
chainwall registry upsertToken --help
chainwall registry upsertToken --help --json
```

Command help is available locally and describes usage and options.
Group help lists local CLI subcommands and Registry methods, whether they read or write,
and their canonical signatures.
Method help shows exact parameter names and types.
JSON method help returns the function’s ABI entry, including nested tuple components.

Use `--color always` to force colors or `--color never` to disable them.
The default `auto` mode respects `NO_COLOR`, `CLICOLOR=0`, `TERM=dumb`, and output
redirection.

Every method in the embedded Registry ABI is available through `registry`. Convenient
groups and aliases cover common tasks.
For example, these select the same function:

```sh
chainwall users contains "$USER_ADDRESS"
chainwall registry isUser "$USER_ADDRESS"
chainwall registry is-user "$USER_ADDRESS"
chainwall registry 'isUser(address)' "$USER_ADDRESS"
```

Canonical signatures are particularly useful for overloads.
Quote signatures to preserve their parentheses in the shell.
The Registry must have the corresponding functionality installed; a method’s presence in
the binary does not prove that it is available or authorized on your instance.

### Shell completion and private labels

Put `chainwall` on PATH, then follow the setup for your shell.

For fish, run these commands at a fish prompt:

```fish
mkdir -p "$__fish_config_dir/completions"
chainwall completions fish > "$__fish_config_dir/completions/chainwall.fish"
source "$__fish_config_dir/completions/chainwall.fish"
```

The `source` command activates completion immediately.
Future fish sessions load the saved file automatically.

For zsh, run these commands at a zsh prompt:

```zsh
mkdir -p ~/.zsh/completions
chainwall completions zsh > ~/.zsh/completions/_chainwall
```

Add the following to `~/.zshrc`. If completion is already initialized there, add only
the `fpath` line before the existing `compinit` call or shell framework initialization:

```zsh
fpath=(~/.zsh/completions $fpath)
autoload -Uz compinit
compinit
```

Start a new zsh session to activate completion.
In either shell, type `chainwall dep` and press Tab; it should complete to
`chainwall deploy`.

The build also installs `share/fish/vendor_completions.d/chainwall.fish` and
`share/zsh/site-functions/_chainwall` under its installation prefix.

To populate Registry suggestions, select a configured profile and sync it from either
shell:

```sh
chainwall sync
```

Tab completes commands, method arguments, options, files, and cached Registry entities
for the selected profile, chain, and instance.
Start background refresh with `chainwall completions watch`. To include labels encrypted
with the app’s shared secret, use `chainwall completions unlock` instead.
Unlock asks for the local vault passphrase once; `--passphrase-file FILE` supports
automation. Import the app configuration first if its shared secret is not configured.
Sessions are scoped to the config directory, profile, chain, and Registry; fish and zsh
can share the same session.

```sh
chainwall completions unlock --ttl 900 --refresh 30
chainwall completions status
chainwall users contains '@Alice Smith'
chainwall contracts get '@example/vault'
chainwall interactions source '@Swap' --offline
chainwall completions lock
```

The defaults are a 15-minute session and a refresh every 30 seconds.
Use `--refresh 0` to keep the session offline.
Tab reads the local completion cache and active completion session.
Decrypted labels and the derived label key remain in the helper’s memory; locking or
expiry stops it. A locked session still completes public labels and raw IDs.
Stop an existing session before switching between `watch` and `unlock`.

`@label` references work in supported entity arguments, including named ABI flags and
JSON argument files.
They resolve to the stored address or ID. Duplicate labels require a raw ID. For a label
containing spaces, quote the reference; both shells handle escaping when inserting a
completion. The `labels` sync dataset updates metadata for cached entities.
A normal `sync` includes it.
Unrecoverable hashed names and non-enumerable Registry mappings cannot supply labels.
Contract names use `@organization/name`; contract version labels are separate keys.

### Addresses, names, and IDs

An address is `0x` plus 40 hexadecimal digits.
A `bytes32` identifier is `0x` plus 64 hexadecimal digits.
Different commands intentionally accept different kinds of identifier:

| Input | Typical use |
| --- | --- |
| Address | Users, accounts, Safes, deployed contracts. |
| String | Organization ID or separate contract organization/name arguments. |
| `bytes32` | Groups, policies, interactions, capabilities, roles, timelock action IDs. |
| Unsigned integer | Stable list IDs, block numbers, thresholds, amounts, Interact operation IDs. |

Compute a name-based identifier with:

```sh
chainwall id treasury
chainwall id circle/usdc
```

`id` computes Keccak-256 of the name’s UTF-8 bytes.
It also accepts an existing nonzero `bytes32` and normalizes it.
The hash depends on the exact spelling and case of the name.

Generic methods expecting `bytes32` require the actual hash:

```sh
GROUP_ID=$(chainwall id treasury)
chainwall groups members "$GROUP_ID"
```

Use `chainwall id` explicitly when you need the hash of a plain name.
Interaction `add`, `update`, `activate`, and `deactivate` have the name-to-ID
convenience described later.
App-created entities can have opaque IDs derived through the app’s private label scheme.
Hashing their displayed label with `chainwall id` will not necessarily reproduce them.
Use the actual ID from the Registry or app.

Create an encrypted ID in the app’s format with the selected shared secret:

```sh
GROUP_ID=$(chainwall id Treasury --encrypt --scope group-id)
chainwall groups add "$GROUP_ID"
INTERACTION_ID=$(chainwall id Swap --encrypt --scope interaction-id)
chainwall interactions add swap.ls --id "$INTERACTION_ID"
chainwall labels decode "$GROUP_ID" --scope group-id
```

`--scope` is required and binds the ciphertext to its purpose.
ID scopes are `group-id`, `interaction-id`, `policy-id`, and `contract-label` (contract
version labels). The selected chain and Registry must match the app.
Encryption is deterministic for that context and shared secret and allows at most 16
UTF-8 bytes. Multibyte characters consume more than one byte.
Preserve existing IDs after rotation: encoding the same name with a new key produces a
different ID. Use the stored ID or an unlocked `@label` to select an existing entity.

### Read and write display labels

```sh
chainwall labels set user "$USER_ADDRESS" "Alice"
chainwall labels set account "$ACCOUNT_ADDRESS" "Treasury"
chainwall labels get user "$USER_ADDRESS"
chainwall labels get user "$USER_ADDRESS" --raw
chainwall labels set user "$USER_ADDRESS" "Public name" --plain
chainwall labels clear user "$USER_ADDRESS"
chainwall sync --only labels
```

`set` encrypts by default using the selected profile’s shared secret.
`--plain` stores a public ABI string.
Kinds are `user`, `account`, `safe` (an alias for account metadata), and `contract` (a
catalog bytes32 ID or `@organization/name`). User and account ciphertext authenticates
the address, so copying a label to a different address will not decrypt.
Writes use normal Registry permissions and timelocks; a successful receipt may mean the
change was queued. `--dry-run` previews the exact calldata.
Sync labels after execution to refresh completions.

`get --raw` returns stored bytes directly.
`get` decodes public labels directly and unlocks the vault for encrypted labels.
`labels encode TEXT --scope SCOPE` and `labels decode HEX --scope SCOPE` work offline;
add `--entity ADDRESS` for `user-label` or `account-label`. Decoding also tries cached
ancestor keys; use `kv history` after importing a rotated secret to populate that cache.
Add `--passphrase-file FILE` for noninteractive commands.

### Positional, named, and JSON arguments

For simple calls, use positional arguments:

```sh
chainwall groups add-member "$GROUP_ID" "$USER_ADDRESS"
```

For clarity, use the exact flags printed by method help:

```sh
chainwall users remove --arg-user "$USER_ADDRESS" --dry-run
```

Named flags use `--arg-` followed by the parameter name in kebab case.
This avoids collisions with global flags: a method’s `account` parameter uses
`--arg-account`, while `--account` selects a Foundry keystore.

For structs, arrays, and strings containing quotes, use `--args-file FILE`. It accepts
either an object keyed by exact ABI parameter names or an array in ABI argument order.
Nested tuples also accept named objects or arrays.
Choose either an argument file or positional ABI arguments for each command.

Store large integers as decimal strings in JSON. This avoids precision loss in software
that treats JSON numbers as floating-point values.
Use literal JSON `true` and `false` for booleans, and `0x` for empty bytes.
Shell examples using JSON arrays quote the entire array so it reaches the CLI as one
argument.

Options can appear before or after the command.
Both `--chain base` and `--chain=base` work.
Boolean flags such as `--json` take no value; write `--json`, not `--json true`. Use
`--` to end option parsing when an argument would otherwise look like an option.

## 7. Users, groups, and policies

### Register users

```sh
chainwall users list
chainwall users contains "$USER_ADDRESS"
chainwall users add "$USER_ADDRESS" --dry-run
chainwall users add "$USER_ADDRESS"
```

After any required timelock completes, the address becomes a registered user.
Registration is the starting point for group membership.
Assign administrative roles separately when required.

To remove a user, first consider their group memberships and pending approvals:

```sh
chainwall users remove "$USER_ADDRESS" --dry-run
chainwall users remove "$USER_ADDRESS"
```

Removal also removes the user from Registry groups.
Membership changes can affect live policy satisfaction and previously collected
approvals. Inspect pending work before changing an approval group’s members.

### Build an approval group

This example uses an ID derived from the name `treasury`:

```sh
GROUP_ID=$(chainwall id treasury)
chainwall groups add "$GROUP_ID"
```

Once group creation has executed, add existing users:

```sh
chainwall groups add-member "$GROUP_ID" "$FIRST_APPROVER"
chainwall groups add-member "$GROUP_ID" "$SECOND_APPROVER"
chainwall groups members "$GROUP_ID"
```

If a write queues an action, execute it before a later step that depends on its result.
Running the whole sequence without checking receipts may encounter a missing group or
user.

Other common group commands:

```sh
chainwall groups list --start 0 --count 50
chainwall groups remove-member "$GROUP_ID" "$FIRST_APPROVER" --dry-run
chainwall groups remove "$GROUP_ID" --dry-run
```

The contract can reject deletion while a group is still referenced by policy,
capability, or governance configuration.
Resolve those references through the appropriate governance process first.

### Create a threshold policy

A policy can require, for example, two approvals from the treasury group.
The `groupIds` and `thresholds` arrays correspond by position:

```sh
POLICY_ID=$(chainwall id treasury-two)
GROUP_ID=$(chainwall id treasury)
chainwall policies add "$POLICY_ID" "[$GROUP_ID]" '[2]' --dry-run
chainwall policies add "$POLICY_ID" "[$GROUP_ID]" '[2]'
chainwall policies get "$POLICY_ID"
```

The group must exist, and its live membership must be able to satisfy the chosen
threshold for the policy to be usable.
Multiple criteria express the required threshold for each specified group.
Do not assume that arbitrary members of another group can substitute for a required
criterion.

These positional arrays use Foundry’s notation: the bytes32 value inside `"[$GROUP_ID]"`
has no embedded JSON quotes.
For a JSON argument file or named array flag, use proper JSON arrays with quoted bytes32
strings instead.

After creating a policy, attach it to the intended account, interaction
execution, or timelock category.
The consuming component’s configuration determines where it applies.

For criteria changes or an additional policy program, inspect the full methods:

```sh
chainwall registry setPolicy --help
chainwall registry setPolicyProgram --help
chainwall policies list
```

A policy program is MiniScript with its own permitted operations, execution context, and
step limit. Compile and test it in the policy context required by the component
evaluating it.
The `subject` argument context is available for programs that read a policy subject; it
changes where `$arg0`, `$arg1`, and subsequent arguments come from.

## 8. Accounts, Safes, and administrative authority

### Balances, valuations, and execution activity

```sh
chainwall accounts assets "$ACCOUNT"
chainwall safes assets "$SAFE" --token-id circle/usdc --max-age 3600
chainwall accounts assets "$ACCOUNT" --start 20 --count 20 --block "$BLOCK"
chainwall accounts activity "$ACCOUNT"
chainwall safes activity "$SAFE" --logs --from-block "$DEPLOYMENT_BLOCK"
```

Both groups accept an address or an unlocked `@label` for these read commands.
Assets enumerate the selected Registry’s token catalog, with a default page size of 20
and maximum 100. Repeat `--token-id PATH|HASH` to select particular tokens.
The native balance appears only at `--start 0`. Metadata, latest token deployment,
balances and prices all use one verified block.
Use the returned block number with `--block` on subsequent pages and follow `nextStart`
until null.

`balance` is an exact integer string; `balanceFormatted` uses Registry decimals.
`price` retains the feed answer, decimals and update time.
`usdValue18` uses the Registry’s conservative, exact-ceiling USD valuation, with a
positive `--max-age` in seconds (default 3600). Registry feed-age limits and sequencer
checks also apply. Unconfigured, stale, inactive or unavailable prices stay null with an
error. A failed token balance stays null.
Zero and unavailable are distinct.

`pricedSubtotalUsd18` and `pricedSubtotalUsd` cover priced holdings in the returned page
only. Catalog aliases for the same token address are marked `duplicateOf` and excluded
from that page’s subtotal.
`unpricedAssets` counts holdings excluded for missing data.
`portfolioComplete` requires the complete Registry catalog in one page and a valuation
for every distinct holding.
This scope excludes tokens absent from that catalog, NFTs and offchain positions.

Activity defaults to the contract’s capped recent-execution index when enabled.
Its `coverage` is `recent-index`; transaction hashes are null because the index does not
store them.
`--logs` or `--from-block` selects RPC event history and includes transaction
hashes and log indexes.
Instances without execution indexing automatically use logs.
The default log range is the last 10,000 blocks; the report states `fromBlock` and
`toBlock`. Use `--block` as a stable upper bound.
Reports are newest first and support `--start`/`--count` pagination.

Log reads split provider-limited ranges and fail explicitly if the bounded request/log
budget is exhausted.
Narrow the range and retry; a failed scan is never reported as empty history.
Block hashes are checked against RPC and the anchor is checked again before output.
These are Chainwall execution events, not every native transfer, token transfer, or
external account transaction.
Use `transactions inspect HASH` to inspect a returned execution transaction.
Both views accept `--out FILE` to save their JSON report.

### Foundry accounts versus Registry accounts

These are intentionally different commands:

```sh
chainwall accounts
chainwall accounts list
chainwall safes list
```

`accounts` lists local Foundry keystores.
`accounts list` lists managed account addresses in the selected Registry.
`safes list` lists registered Safes.
A Foundry signer can administer or approve work involving a managed account without
being that managed account.

To inspect the calldata for registering existing addresses:

```sh
chainwall accounts add "$MANAGED_ACCOUNT" --dry-run
chainwall safes add "$SAFE_ADDRESS" --dry-run
```

These raw Registry methods only register addresses.
Use the following factory workflows to deploy accounts or configure an existing Safe.

### Create and inspect managed accounts

```sh
chainwall accounts create --salt "operations account" --dry-run
chainwall accounts create --salt "operations account" --account creator
chainwall accounts inspect "$MANAGED_ACCOUNT"
chainwall safes create --salt "treasury safe" \
  --owners "$OWNER1,$OWNER2" --threshold 2 --account creator
chainwall safes inspect "$SAFE_ADDRESS"
```

Factory addresses are resolved from saved deployment or imported app topology, then from
the configured/shared OKFactory when needed.
Override them with `--account-factory ADDRESS` or `--safe-factory ADDRESS`. The CLI
checks the factory component and its Interact/Registry binding.
`--dry-run` previews the predicted CREATE2 address and deployment calldata.
Both commands accept hex salts or phrases using the deployment conversion above.
OKAccount salts share a namespace across users of the same tenant factory.
Safe addresses also depend on their complete initialization settings. Reusing the
same salt and configuration predicts the same address and cannot create a second
account there, even if a different allowed user submits it.

Safe creation always installs the Chainwall guard and Interact gateway.
The optional OKModule defaults to enabled for a single owner with threshold 1; multisig
Safes omit it. Use `--no-module` or `--module` explicitly.
The latter requires exactly one owner and threshold 1. `--value WEI` funds a new Safe.
The connected factory caller must be an allowed Registry user.

Inspection reports factory provenance and Registry registration.
OKAccount inspection also checks Registry/Interact links and compares its engine runtime
with the factory’s engine.
Safe inspection checks proxy/singleton authenticity, owners, threshold, nonce, guard,
fallback, module guard, and bounded module pages.
Factory-managed Safes also pass the factory’s extension validator.
`valid` describes configuration; `registered` separately reports authorization.

`accounts import ADDRESS` re-registers a previously removed account created by this
tenant’s factory. It rejects unrelated accounts.
Registration can be timelocked; inspect the returned outcome and complete any queued
action.

### Import an existing Safe

```sh
chainwall safes inspect "$SAFE_ADDRESS"
chainwall safes sign-import "$SAFE_ADDRESS" --account owner1 --out owner1.json
chainwall safes sign-import "$SAFE_ADDRESS" --account owner2 --out owner2.json
jq -s . owner1.json owner2.json > import-signatures.json
chainwall safes import "$SAFE_ADDRESS" \
  --signatures-file import-signatures.json --account importer
```

Each owner signs the same Safe transaction, bound to its current nonce and the factory’s
configurator. The CLI sorts signatures, checks their transaction hashes, and submits
through SafeFactory.
The Safe enforces its threshold.
The importer must be an allowed Registry user.
A different existing guard or a module guard is rejected before signing.
A Safe must use an authentic proxy and a singleton approved by this factory.

By default, unrelated modules or a fallback handler prevent import.
To disable the module check for this Safe, pass `--no-module-check` to every
`sign-import` and `import` command. This trusts all current and future modules,
which can execute outside Chainwall policy. Fallback-handler, module-guard, and
OKModule ownership requirements still apply. The choice is signed by the owners.
Default imports keep the original ABI and signature format on both factory versions.
For standard opt-outs, the CLI probes `SUPPORTED_IMPORT_OPTIONS()` before signing;
these require the updated factory. RPC failures do not silently
select the old ABI. The new import uses a uint256 mask: zero is checked, bit 0
skips the module check, and unsupported bits revert.
To retain them, pass `--preserve-extensions` to **every** `sign-import` and `import`
command. This builds explicit allowlists from the inspected extensions and does not
enable a new OKModule.
Combined with `--no-module-check`, preservation only allowlists the current
fallback handler; modules remain unrestricted.
Opt-out imports inspect at most 256 modules and report `modulesComplete: false`
when the list is truncated, including after import. OKModule installation is
checked independently with `isModuleEnabled`, so its ownership requirements and
configuration remain correct even when it is outside the inspected list.
Imports with module checks enabled still require complete enumeration.
Without preservation, the optional OKModule follows the same single-owner default and
`--module`/`--no-module` switches as creation.
Changes to the configuration or Safe nonce require new signatures.
`--dry-run` previews the import transaction or signing request.

### Capabilities

Capabilities grant particular powers through groups.
For example, the user-onboarding capability uses the canonical name
`cap.directory.user.write`. Inspect its current assignments and a proposed grant:

```sh
ONBOARDING_CAPABILITY=$(chainwall id cap.directory.user.write)
ONBOARDERS_GROUP=$(chainwall id onboarders)
chainwall capabilities getCapabilityGroups "$ONBOARDING_CAPABILITY"
chainwall capabilities hasCapability "$ONBOARDING_CAPABILITY" "$USER_ADDRESS"
chainwall capabilities grantCapabilityGroup \
  "$ONBOARDING_CAPABILITY" "$ONBOARDERS_GROUP" --dry-run
```

The group must exist.
Granting authority is itself governed by the Registry’s authorization and timelock
rules.
Capability names are protocol-defined; hashing an arbitrary name does not create a
useful power. System-actor grants have additional restrictions, and the security council
uses dedicated configuration methods.

### Roles, ownership, and advanced administration

Roles and ownership are separate from group capabilities:

```sh
chainwall ownership get
chainwall roles --help
chainwall capabilities --help
chainwall registry ADMIN_ROLE
chainwall registry UPGRADER_ROLE
```

For a role ID obtained from the contract, inspect a grant using named arguments:

```sh
chainwall roles grant --arg-role "$ROLE_ID" \
  --arg-account "$NEW_ADMIN_ADDRESS" --dry-run
```

Ownership transfer uses a proposal/acceptance flow:

```sh
chainwall ownership transfer "$NEW_OWNER_ADDRESS" --dry-run
chainwall ownership accept --help
```

The acceptance transaction must come from the pending owner.
Bootstrap state, role governance, and capability configuration affect what ownership
permits; do not assume the owner always bypasses all other controls.

For terms, authorization, emergency controls, upgrades, and installed facets, use the
respective command groups and method help.
Upgrade calls can require structured parameters and timelock execution.
Methods beginning with `_` are also visible in the ABI; many are contract-internal
replay entry points whose caller restrictions prevent direct operator use.
Use the public administrative workflow specified for the deployment.

### Facet deployment and selector changes

`facets catalog` lists the app's canonical facet releases. Deploy a release with
`facets deploy NAME --out deployment.json`, then generate a reviewable installation
or upgrade using `facets plan NAME --target ADDRESS --out plan.json`. These commands
operate on registries with core and timelock facets already installed.

When the old facet has extra selectors, pass `--choices-file FILE` mapping each
selector to `{ "kind": "keep" }`, `{ "kind": "remove" }`, or
`{ "kind": "move", "address": "0x..." }`. Ambiguous current facets require
`--current ADDRESS`; `--current none` leaves unrelated routes untouched. Custom
move destinations need operator review. Core and direct selectors are protected.

Run `facets apply plan.json --dry-run --from ADDRESS` before submission, then
`facets apply plan.json` and `facets check plan.json`. Apply validates current
routes and code, simulates with the signer, and persists attempts and receipts
before verification. Code-only cuts prohibit arbitrary initialization calls.
Constructor-bound facets need their canonical creation transaction; locally
deployed proofs are cached, or provide `--deployment-tx HASH` explicitly.

Queued cuts require timelock execution. `facets reconcile plan.json TX_HASH`
verifies the exact canonical queued or applied event and checks resulting routes
after execution. Use it to recover from interrupted confirmation without sending
again. Repeating an attempted submission requires explicit `--retry` and unchanged
live state. `check` also verifies destination and constructor dependency code.

### Release deployment and upgrades

The CLI embeds release manifests, including constructor ABIs,
bytecode, immutable ranges, and storage-layout fingerprints.
List releases and export their bundled manifests locally:

```sh
chainwall upgrade releases
chainwall artifacts releases > releases.json
chainwall upgrade deploy interact --dry-run
```

Names accept camelCase or kebab-case (`accountFactory` or `account-factory`). Deploy
a replacement implementation with a Foundry signer, then inspect the tenant and submit
its adoption to Registry governance:

```sh
chainwall upgrade deploy interact --account publisher --out implementation.json
chainwall upgrade inspect interact
chainwall upgrade verify interact "$IMPLEMENTATION_ADDRESS"
chainwall upgrade propose interact "$IMPLEMENTATION_ADDRESS" --dry-run
chainwall upgrade propose interact "$IMPLEMENTATION_ADDRESS" --account governor --out upgrade.json
```

Adopt the deployed release through the upgrade workflow for each intended tenant.
`--nonce` is passed to `cast send --create`. The result contains the deployed address,
receipt, and verification report.
An `--out` file is reserved before broadcasting, then updated with the receipt before
further RPC verification.
Choose a new output path for each deployment.
If verification fails after deployment, recover the address from that file or the
printed deployment address and rerun `upgrade verify`.

`--constructor-file FILE` accepts named or positional JSON using the constructor ABI
shown by `upgrade releases`. OKGuard and OKModule use the default zero constructor
bindings when omitted.
SafeFactory and SafeSingletonMigrator need explicit constructor arguments.
Component adoption resolves the selected instance’s topology; `--target ADDRESS`
overrides it and is required for individual `okAccount` and `authAccount` proxies.
The target must be bound to the selected Registry.

Verification compares the deployed runtime with the embedded artifact, masking only
compiler-declared immutable ranges.
It checks component ID, upgrade protocol, UUPS slot where applicable, and the exact
allowed runtime hashes of Interact’s operations module and Registry’s pause module.
Inspection compares the reported implementation with the raw ERC-1967 slot and actual
implementation codehash.
A failed candidate report is printed with a nonzero exit status.
Older current implementations may differ from the embedded release and are shown as
such.

`upgrade propose` supports all eleven component implementation upgrades.
Use `--data-file FILE` for hex migration calldata.
Registry upgrades require empty calldata.
Before adopting a matching release, review its exported storage fingerprints, migration
data, and release changes for compatibility with your instance.
Successful upgrades invalidate prior runtime authorizations.

For explicit dependency and default-implementation changes, `upgrade release` accepts
the `RegistryUpgradeReleaseAction` JSON shape:

```json
{
  "kind": "replaceEngine",
  "target": "0x...",
  "newEngine": "0x..."
}
```

```sh
chainwall upgrade release action.json --dry-run
chainwall upgrade release action.json --account governor --out release.json
```

Supported kinds are the eleven `upgrade*` actions, `replaceEngine`,
`setAccountImplementation`, `setAuthAccountImplementation`, `setSafeProxyFactory`,
`setSafeSingleton`, `replaceSafeSingletonMigrator`, `replaceSafeConfigurator`, and
`migrateSafeSingleton`. The CLI verifies the corresponding embedded candidate release
and current tenant bindings before submission.
The contracts enforce capabilities, rollback checks, codehash snapshots, and binding
postconditions.

When a signer is selected, proposals and timelock actions are also simulated at the
pinned block before broadcast.
A failed simulation returns `ready: false` and the RPC error without sending a
transaction. A dry run without a signer has `simulation: null` and makes no claim about
permission to execute.
`--dry-run` keeps a failed simulation available for inspection without failing the
command. Inspect `ready` as well as artifact compatibility.

Governance may execute immediately or return queued action IDs.
Queue reports include each committed candidate codehash and current timelock state:

```sh
chainwall upgrade status "$ACTION_ID"
chainwall upgrade approve "$ACTION_ID" --account approver
chainwall upgrade execute "$ACTION_ID" --account governor --out execution.json
chainwall upgrade cancel "$ACTION_ID" --account governor
```

Policy thresholds and delay still apply.
Keep the proposal’s `--out` report: when indexing is disabled, terminal actions discard
their payload and `candidateCodehash` becomes null.
Terminal status remains available.
Approval and execution use the original queued calldata; a changed implementation,
codehash, binding, or runtime authorization can make the action stale.

### Inspect and accept terms

```sh
chainwall terms get-terms-context
chainwall terms document --out terms.md
chainwall terms accept-terms --document-file terms.md --dry-run
chainwall terms accept-terms --document-file terms.md --account admin
chainwall terms instance-has-accepted-initial-terms
```

The first `terms document --out` fetches and verifies the document before saving
it. To use another IPFS gateway, add `--ipfs-gateway https://YOUR_GATEWAY/ipfs`
to that command, for example if the default gateway returns HTTP 429.
`--document-file terms.md` verifies an existing local copy; use it after download
when previewing or submitting acceptance.

The Registry stores its factory's initial document once. The argument-free shortcut
captures that URI/digest, verifies the exact document bytes with SHA-256, and submits
that identity unchanged. The signer needs `ADMIN_ROLE`; acceptance uses the normal
Registry transaction path even before execution is unlocked. No deployment stage
accepts for the tenant.

Without `--document-file`, verification fetches IPFS through `--ipfs-gateway URL`
(default `https://ipfs.io/ipfs`). Redirects, unavailable content, invalid CID/paths,
wrong bytes, and invalid UTF-8 stop the operation before signing or saving content.
HTTP and IPNS are not document identities. `terms document --out FILE` saves only
verified bytes.

A later document must be published in the factory's licensing list:

```sh
chainwall terms document IPFS_URI SHA256_DIGEST
chainwall terms accept-terms SHA256_DIGEST --account admin
chainwall terms has-accepted-terms SHA256_DIGEST
chainwall terms get-terms-acceptance SHA256_DIGEST
```

Named `--document-hash` and `--args-file` select the same published hash.
The file contains `{ "documentHash": "0x..." }` or a one-element positional array.
Acceptance resolves the canonical URI onchain and rejects unpublished hashes. All acceptance paths verify bytes, including dry runs and exact
ABI aliases. Repeated hashes preserve the first URI, actor, timestamp, and execution
semantics. Later acceptance does not satisfy or replace initial acceptance, and
publication never disables an existing instance. A future release can require
another digest only through that tenant's existing upgrade governance.

## 9. Organizations, contracts, and tokens

### Organizations and catalog names

A reference such as `@token(circle/usdc)` identifies a Registry catalog entry with
organization `circle` and ID `usdc`. Its deployment address resolves through the
selected Registry and chain.

Organization and catalog identifiers use lowercase spelling.
Organization membership is distinct from user groups used for approvals.
Ownership or membership in an organization grants catalog-write authority only when the
deployment’s governance enables the relevant delegation and the organization is eligible
and unsuspended.

Inspect organizations with:

```sh
chainwall orgs list
chainwall orgs get acme
chainwall orgs add --help --json
```

For a new organization, save this as `organization.json`, replacing the owner:

```json
{
  "id": "acme",
  "owner_": "0x1111111111111111111111111111111111111111",
  "rugged": false,
  "initialMembers": []
}
```

```sh
chainwall orgs add --args-file organization.json --dry-run
```

The `rugged` field is the onchain record’s flag.
`initialMembers` is only for creation; updates require an empty initial-member array.
Existing organization ownership changes use `proposeOrgOwner` and `acceptOrgOwner`,
rather than supplying a different owner to `upsertOrg`.

```sh
chainwall orgs add-member acme "$USER_ADDRESS" --dry-run
chainwall registry proposeOrgOwner --help
chainwall registry acceptOrgOwner --help
```

### Contract versions

Contract records associate an organization/name with deployment versions.
The current record includes its address, version tag, and optional proxy implementation.
This is the information the compiler uses when resolving named calls and their ABIs.

```sh
CONTRACT_ID=$(chainwall id acme/vault)
chainwall contracts get "$CONTRACT_ID"
chainwall contracts list
chainwall contracts add --help --json
```

Here is a complete argument-file shape for `addContractVersion`. Save it as
`contract.json` and replace the address and tags for your deployment:

```json
{
  "org": "acme",
  "id": "vault",
  "addrData": {
    "addr": "0x2222222222222222222222222222222222222222",
    "version": "0x0000000000000000000000000000000000000000000000000000000000000001",
    "implementation": "0x0000000000000000000000000000000000000000"
  },
  "label": "0x0000000000000000000000000000000000000000000000000000000000000001"
}
```

```sh
chainwall contracts add --args-file contract.json --dry-run
```

`version` and `label` are bytes32 values. The Registry tracks its numeric version
counter separately.
Use a zero implementation address to leave implementation metadata unset.
For a proxy, record the appropriate implementation so ABI resolution matches the
intended deployment.

### Token metadata

Token metadata augments an existing contract entry.
It includes the token’s symbol and decimals plus an optional price-feed address and its
decimals. Set the `price` field to the price-feed address.

Save this shape as `token.json`, replacing the values with those of an existing
registered token contract:

```json
{
  "data": {
    "org": "acme",
    "id": "usd",
    "symbol": "USD",
    "decimals": 6,
    "price": "0x0000000000000000000000000000000000000000",
    "priceFeedDecimals": 0
  }
}
```

```sh
chainwall tokens add --args-file token.json --dry-run
TOKEN_ID=$(chainwall id acme/usd)
chainwall tokens get "$TOKEN_ID"
chainwall tokens list
```

Configure a price feed for tokens used in market valuations.
Token amounts passed to contract calls use the token’s integer base units: for a token
with six decimals, one token is `1000000`. Convert human amounts to those raw units
before supplying an argument.

### Native USD feed

Configure the native token's USD price feed using the same reviewed preset as the app:

```sh
chainwall tokens set-chainlink-native-feed --dry-run
chainwall tokens set-chainlink-native-feed --account admin
chainwall tokens get-native-usd-feed-config
chainwall tokens get-oracle-environment
```

The selected chain determines the preset. Ethereum, Sepolia, Base, Optimism, and
Arbitrum currently have reviewed presets; unsupported chains are rejected. Use
the profile's Registry and RPC, or override them with `--instance` and `--rpc-url`.

One transaction calls `setOracleEnvironment`, `setFeedMaxAge`, and `setNativeUsdFeed`
through Registry `multicall`. The L2 presets include sequencer uptime protection.
The Registry's global maximum feed age is preserved. Before submission, the CLI
checks the feed decimals, positive answer, round completeness, timestamp, and age
at one canonical block. Dry runs perform these RPC checks and output the batch
calldata without a signer or transaction log.

The signer needs `ADMIN_ROLE`. Normal transaction logs and explorer links apply.
If governance queues the changes, the result lists their action IDs; execute those
through the timelock workflow before expecting the feed to be configured.
This command applies the preset even when settings already exist. For custom
settings, use `tokens set-oracle-environment`, `tokens set-feed-max-age`, and
`tokens set-native-usd-feed` explicitly.

### Metadata

Registry metadata methods use a kind, entity ID string, key string, and byte value.
Inspect the schema before writing:

```sh
chainwall metadata get --help
chainwall metadata set --help
chainwall metadata delete --help
```

Metadata writes are onchain writes subject to the same authority and governance rules as
other Registry changes.
Prepare metadata values in the format required by their consumer. Use the label
commands for encrypted labels.

### Private commit and reveal

Reserve a contract, token, or interaction now and publish its private payload
later:

```sh
chainwall commitments template contract --out contract.json
# Fill in the payload fields in contract.json.
chainwall commitments prepare contract contract.json
chainwall commitments list
chainwall commitments commit "$COMMIT_HASH"
chainwall commitments status "$COMMIT_HASH"
chainwall commitments reveal "$COMMIT_HASH"
chainwall commitments archive "$COMMIT_HASH"
chainwall commitments archives
```

Use `token` or `interaction` in place of `contract` for those templates and
drafts. Input contains `payload` plus optional `deadline` (Unix seconds),
`forwarder`, and bytes32 `hint`. Contract versions accept text up to 32 bytes.
Interaction drafts accept complete bundles, including linked artifacts and
related contracts; `--source-file program.ls` compiles the main program directly.

Preparation generates a secret random salt and saves the complete draft in the
encrypted local vault, scoped to chain and Registry. It needs no KV deployment.
Use `--passphrase-file FILE` for automation. Normal reports never disclose the
salt or payload. Public salt phrases are not accepted for private commitments.

The active collection holds at most 1,024 drafts. `commitments archive HASH`
checks live state and moves an absent or expired commitment with no pending
action into encrypted local history. `commitments archives` lists that history.
`export HASH --out FILE` works for active and archived drafts; import the export
to restore a draft to the active collection. Archival never submits a transaction.

Deadlines default to seven days and cannot exceed 90 days. Submission checks
chain time, matching commitment state, pending actions and timelock delay.
Queued commitments must execute through the timelock before reveal. A reveal
simulation sends the private payload and salt to your selected RPC; its
transaction makes them public. `--dry-run` submits nothing, but with an explicit
sender it still simulates. Delegated reveals can provide a JSON signature using
`--actor-signature-file FILE`; contract permissions always apply.

Use `cancel HASH` to cancel a matching commitment or `expire HASH` after its
deadline. Drafts and attempted submissions are retained for recovery. After an
interruption, inspect `status HASH` and run `reconcile HASH TRANSACTION_HASH` to
verify the receipt. Repeating an attempted submission requires explicit
`--retry`; pending actions still block duplicates.

`commitments export HASH --out recovery.json` intentionally writes the complete
private draft and secret salt to a new mode-0600 file. Keep it private.
`commitments import recovery.json` validates the commitment and selected context,
then encrypts the draft in the destination vault. Keep your config directory or
a recovery export until the commitment is closed.

## 10. Write Lambdascript files

### Analyze and simulate

```sh
chainwall analyze transfer.ls --read-only --out analysis.json
chainwall analyze program.json --linked
chainwall operations simulate proposal.json --account executor --out simulation.json
chainwall policies simulate policy-input.json --out policy-result.json
```

Analysis accepts preprocessor-level source by default, compiler JSON, or hex bytecode.
Source accepts the same metadata/settings options as `compile`. Reports include calls
and recursive ABI plans, argument provenance, references, terminal stack shapes, runtime
counters and warnings.
`--read-only` rejects writes/native transfers; `--linked` requires one result on each
terminal path. Incomplete bounded analysis and violations return a nonzero exit status.
Compiler artifacts contain the same report under `analysis`; the LSP exposes it and
reports findings in editor diagnostics.
Use simulation to check execution and permission against current chain state.

Operation simulation prepares the exact execution transaction and runs a pinned
`eth_call`. It accepts execution options such as `--approve`, `--via safe`,
`--actor-signature-file`, `--signatures-file`, `--reveal-file` and `--max-steps`. Select
the intended sender; Safe simulation needs the intended signatures.
It reports decoded protocol reverts and catches a Safe’s false success result.
Simulation is read-only and leaves the operation ready for execution.
Later state changes can change execution results.

Policy input uses the generated `Interact.simulatePolicyProgram` ABI:

```json
{
  "policyId": "0x...",
  "input": {
    "interactionId": "0x...",
    "interactionArgs": ["100"],
    "nativeValue": "0",
    "operationId": "1",
    "payloadHash": "0x...",
    "actor": "0x...",
    "vault": "0x..."
  }
}
```

Replace abbreviated hex values with complete IDs/addresses.
Policy simulation uses Interact as sender, matching the app.
The protocol always rolls back; the CLI decodes its result sentinel and reports
`stackTop`. Zero or a different revert is a failed simulation.
Both commands return nonzero on failure and verify that the pinned block remains
canonical.

### Start with an offline program

Save this as `positive.ls`:

```lambdascript
$require($arg0 > 0)
```

Compile and inspect it:

```sh
chainwall compile positive.ls --out positive.json
chainwall decompile positive.json
chainwall disasm positive.json
```

`$arg0` is the first program argument.
`$require` aborts execution if its condition is false.
Compilation prints bytecode and, with `--out`, saves a JSON reference containing source,
bytecode, assembly, and settings.
This core program compiles entirely locally.

Write each source program as a self-contained file with the `.ls` extension.

### Call a registered token

Save this as `transfer.ls`:

```lambdascript
let token = @token(circle/usdc)
in $require(token.transfer($arg0 :: address, $arg1 :: uint256))
```

The first argument is the recipient; the second is the amount in base units.
The named token must exist in your selected Registry.
Its ABI must describe the called function.
This example expects `transfer(address,uint256)` to return a boolean, as in the ABI
supplied in the next section.

```sh
chainwall compile transfer.ls --chain base --out transfer.json
```

The compiler preprocesses named references, selects an ABI overload, determines
read/write behavior from that ABI, and emits the appropriate bytecode.
The `:: address` and `:: uint256` annotations select exact argument types.
They are especially useful when an ABI exposes several overloads with the same name.

You can add explicit argument checks.
Save this as `checked-transfer.ls`:

```lambdascript
{
  $require($arg0 != 0),
  $require($arg1 > 0),
  $require(@token(circle/usdc).transfer($arg0 :: address, $arg1 :: uint256))
}
```

The braced sequence evaluates the checks and call in order.
A failure reverts the execution.
These program checks run alongside the deployment's permission, policy, and execution
checks.

### A small language guide

| Construct | Example | Use |
| --- | --- | --- |
| Program argument | `$arg0` | Read a supplied argument. |
| Integer literal | `1000000`, `0xff`, `1e18` | Express an exact integer quantity. |
| Comparison | `$arg0 >= 100` | Form a condition. |
| Arithmetic | `$arg0 + 1` | Compute a value. |
| Requirement | `$require($arg0 > 0)` | Revert unless a condition holds. |
| Conditional | `if($arg0 > 0, 1, 0)` | Choose an expression by a condition. |
| Named contract | `@contract(acme/vault)` | Resolve a Registry contract entry. |
| Named token | `@token(circle/usdc)` | Resolve a Registry token entry. |
| Type annotation | `$arg0 :: uint256` | Disambiguate ABI argument types. |
| Array | `[$arg0, $arg1]` | Supply an ABI array where the selected function expects one. |
| Tuple or sequence | `{$arg0, $arg1}` | Supply structured arguments or a sequence, according to context. |

Numeric source literals must resolve to integers.
`1.5e18` is an exact integer quantity. Express fractional token amounts in raw units.
Arithmetic and contract inputs still need the correct units and bounds for their use.
In particular, rational expressions and integer division have different roles; use the
established program’s arithmetic conventions when modifying financial calculations.

Top-level `let ... in ...` bindings are lazy.
Reach a binding from the execution sequence to run its contract call.
A local `let` inside a braced sequence gives a strict, scoped binding when you need to
evaluate once and reuse the result.
Keep state-changing calls explicit and inspect the compiled result when introducing
bindings around them.

Payable calls require an explicit value in the source.
For a registered wrapped-native-token contract with a payable `deposit()` ABI, save this
as `wrap.ls`:

```lambdascript
@contract(weth/weth).deposit{value: $arg0}()
```

Here `$arg0` is native currency in wei.
The call option describes the program’s eventual contract call.
That call spends currency when the interaction executes. The CLI's `--value` option
sets the value of the Registry transaction itself.

### Compilation settings

```sh
chainwall compile positive.ls --optimization size --out positive.json
chainwall compile positive.ls --optimization baseline --out baseline.json
```

`size` is the default optimization.
`baseline` selects the baseline compiler path.
Different optimization settings can produce different bytes for the same behavior;
preserve settings when reproducing an artifact.

The default argument context is `frame`. `--argument-context subject` selects
policy-subject arguments instead.
Use the argument context required by the component that evaluates the program.

`--settings settings.json` accepts a settings object or a compiler JSON file containing
`settings`. For example:

```json
{
  "optimization": "size",
  "argumentContext": "frame",
  "$validity": 1800,
  "$slippage": 5
}
```

`$validity` is in seconds and is used by `$deadline()`, which computes the execution
timestamp plus that duration.
`$slippage` is per thousand and is used by `$slip(value)`; `5` represents 0.5 percent.
These settings affect programs that use the corresponding builtins.
Add expiry or slippage checks explicitly where your program needs them.

Advanced settings include exact target/selector ABI metadata and address resolution
maps. Retain the generated settings object when sharing compiled programs instead of
rebuilding those maps by hand.

## 11. ABIs and offline compilation

An ABI describes a contract’s function names, parameter types, return types, and
mutability. It enables the compiler to turn a high-level member call into correctly
encoded calldata. Check call permissions and contract behavior during simulation.

### Fetch verified ABIs

Configure an Etherscan API token in your shell or secret-management environment:

```sh
export ETHERSCAN_API_KEY='replace-with-your-api-token'
chainwall abi "$CONTRACT_ADDRESS" --chain base --out contract-abi.json
```

Etherscan V2 selects the network with a chain ID under its unified API. Obtain a token
and check network availability through the
[Etherscan documentation](https://docs.etherscan.io/introduction).

For a different environment-variable name:

```sh
chainwall config set etherscan_api_key_env TEAM_ETHERSCAN_TOKEN
```

Set that variable in the environment before running the CLI. A directly stored
`etherscan_api_key` is also supported, but it remains plaintext in the profile despite
display redaction.

The CLI uses the explorer’s
[`getsourcecode` endpoint](https://docs.etherscan.io/api-reference/endpoint/getsourcecode)
to obtain ABI and proxy implementation metadata.
For a named Registry target, its recorded implementation address takes precedence when
present. Retrieved ABIs persist under `abi/CHAIN_ID/ADDRESS.json` in the config
directory, keyed by the final implementation address for proxies or the contract
address for non-proxies. Proxy entries store only implementation mappings; proxy
ABIs are not merged into implementation ABIs. Online lookups recheck mappings after
24 hours. Offline CLI and LSP use the last known mapping. `--refresh-abi` bypasses
both caches, for example after a proxy upgrade.

```sh
chainwall abi "$CONTRACT_ADDRESS" --refresh-abi --out contract-abi.json
chainwall compile transfer.ls --refresh-abi --out transfer.json
```

Only call targets require ABI downloads.
Token references used as address arguments or price assets resolve through the
Registry catalog. Update Registry deployment metadata separately from the ABI cache.

### Supply an ABI file

For an unverified contract, or to use an explicitly reviewed interface:

```sh
chainwall compile transfer.ls \
  --abi circle/usdc=erc20-abi.json \
  --out transfer.json
```

The file may contain a JSON ABI array or an artifact object with an `abi` field.
Repeat `--abi target=file.json` for different targets.
Named Registry references are still checked against the chain unless you also supply an
offline snapshot.

### Complete offline example

This example compiles `transfer.ls` and `checked-transfer.ls` using local metadata.
Save the following as `erc20-abi.json`:

```json
[
  {
    "type": "function",
    "name": "transfer",
    "stateMutability": "nonpayable",
    "inputs": [
      { "name": "to", "type": "address" },
      { "name": "amount", "type": "uint256" }
    ],
    "outputs": [{ "name": "", "type": "bool" }]
  }
]
```

`chainwall id circle/usdc` produces the hash used in this `snapshot.json`:

```json
{
  "knownKindsByTargetHash": {
    "0xbad6ccbe8f6bed92553dd18910f79c66afaaa5d196515ba83f48c7fe256ee89a": "token"
  },
  "abiByTargetHash": {}
}
```

Compile with both files:

```sh
chainwall compile transfer.ls \
  --snapshot snapshot.json \
  --abi circle/usdc=erc20-abi.json \
  --out transfer.json
chainwall compile checked-transfer.ls \
  --snapshot snapshot.json \
  --abi circle/usdc=erc20-abi.json \
  --out checked-transfer.json
```

An offline snapshot declares known Registry kinds and ABIs.
Supported kinds are `contract`, `token`, and `contract+token`. You can place an ABI
directly in `abiByTargetHash`, keyed by the same hash, or supply it with `--abi`.
Additional ABI flags override snapshot ABIs for their targets.

This example metadata is sufficient to compile the sample. Verify the token entry
and deployed interface against your intended Registry before publishing.
For production reproduction, preserve the metadata used for the original build and
verify it against the intended instance.

Core source with explicit target hashes can use `--settings` or
`--abi 0xHASH=file.json`, where `0xHASH` is the full bytes32 target.
Automatic Registry discovery starts from named `@contract` and `@token` references.
Use `--no-preprocess` for already-lowered core source and its accompanying settings.
For named Registry references, provide the snapshot and ABI metadata shown above.

## 12. Publish and maintain interactions

### Add a program

After compiling and reviewing an interaction for your selected instance:

```sh
chainwall interactions add transfer.ls --chain base --dry-run
chainwall interactions add transfer.ls --chain base --out publication.json --json
```

The first command previews the Registry publication.
The second signs and submits it.
If the receipt is `queued`, publication takes effect only after the Registry action
executes.

The default interaction ID is the Keccak hash of the filename stem: `transfer.ls` uses
`chainwall id transfer`. A file in another directory with the same stem has the same
default ID. Select an explicit name or bytes32 ID when needed:

```sh
chainwall interactions add transfer.ls --id treasury-transfer --dry-run
```

Keep an explicit ID consistent on later updates.
Renaming the file changes its default ID. Use `--id` to keep targeting the existing
onchain interaction.

Publication compiles the file again with the options you supply.
If the reviewed build used local metadata, supply those same `--snapshot`, `--abi`, and
`--settings` inputs when publishing.
`--out publication.json` records what this publication invocation actually compiled.

### Update an existing bundle

```sh
chainwall interactions update transfer.ls --dry-run
chainwall interactions update transfer.ls --out publication.json --json
```

`add` rejects an existing ID; `update` rejects a missing ID. An interaction bundle
includes its bytecode, flags, and linked entries.
Updates preserve existing flags and links unless you explicitly replace them with
`--flags` or `--linked-file`.

The CLI reads publication state at one block and submits the current bundle hash with
the new bundle. This compare-and-swap check rejects an update if the expected bundle is
no longer current when applied.
If another author or queued action changes it, read the new state, review the intended
update, and prepare it again.

`--flags INTEGER` replaces the whole flag word.
A linked-file replacement is a JSON array of objects with `relation` (bytes32) and
`payload` (hex bytes).
Relations must be unique and ordered as required by the contract.
Omitting the option preserves existing links; supplying `[]` explicitly clears them.
Inspect the embedded bundle ABI and the application’s link conventions before editing
structured links.

### Activate or deactivate

```sh
chainwall interactions deactivate transfer --dry-run
chainwall interactions deactivate transfer
chainwall interactions activate transfer
```

These commands update the interaction’s active state using its current bundle hash.
They accept a name or actual bytes32 ID. Updating an inactive interaction’s source
preserves its inactive flag unless explicitly changed.
Activation is a Registry change, subject to the deployment’s governance rules.

### Review publication records

```sh
INTERACTION_ID=$(chainwall id transfer)
chainwall interactions get "$INTERACTION_ID" --json
chainwall interactions script "$INTERACTION_ID"
chainwall sync --only interactions
chainwall interactions list --offline
```

The `publication.json` file contains:

| Field | Meaning |
| --- | --- |
| `program` | The complete compiler JSON reference. |
| `publication.expectedCurrentBundleHash` | The bundle state expected by the update. |
| `publication.bundle` | The exact ID, script, flags, and linked entries supplied. |
| `block` | Block used for publication preparation. |
| `chainId`, `instance` | Intended Registry destination. |

The file is written before transaction submission.
It records the prepared publication. Keep the transaction receipt alongside it to
confirm submission and execution.

## 13. Inspect and reproduce bytecode

### Keep compiler JSON as the reference

```sh
chainwall compile positive.ls --json > positive.json
chainwall decompile positive.json
chainwall disasm positive.json
```

A compiler result has format `chainwall.program.v1`:

| Field | Meaning |
| --- | --- |
| `sourceFile`, `source` | Original file name and source text. |
| `coreSource` | Source after high-level preprocessing. |
| `bytecode` | MiniScript bytes in hexadecimal. |
| `bytecodeHash` | Keccak-256 of those bytes. |
| `assembly` | Lossless instruction listing. |
| `recoveredSource` | Source reconstructed from the bytecode. |
| `settings` | Resolved compiler settings, including ABI-sensitive metadata. |
| `references` | Static targets, completeness indicator, and raw reference count. |
| `metadata` | Registry kinds, canonical paths, and ABIs for offline source recovery. |

The reference’s source may contain details you do not intend to distribute; review it
before sharing. Publishing an interaction stores its program bundle onchain, while the
local reference additionally retains the original source.

`references.complete = false` means static reference discovery was incomplete.
Review dynamic behavior to identify additional targets.

### Decompile and disassemble

Both commands accept a compiler JSON file, a publication JSON file, or a file containing
hex bytecode:

```sh
chainwall decompile publication.json
chainwall disasm publication.json
chainwall disasm publication.json --source
chainwall decompile program.hex --settings transfer.json
chainwall interactions source transfer --live
chainwall interactions source transfer --offline
```

They read the saved program’s settings automatically when present.
An explicit `--settings` overrides them.
A raw bytecode file may need the original ABI metadata to recover source correctly.

`decompile` and `disasm --source` restore canonical `@token`/`@contract` names, short
aliases, named ABI reads/writes, payable options, and overload annotations.
They use the saved compiler `metadata` and the selected Registry/ABI cache.
Supply `--snapshot FILE` or `--abi org/id=FILE` for offline metadata; `--live` fetches
missing records and verified ABIs.
Named rewrites must recompile to the exact original bytes; missing or incompatible
metadata retains raw IO syntax.
Use `--no-preprocess` for core source.
Plain `disasm` keeps the lossless opcode listing.

`interactions source NAME|ID` displays the cached interaction script when one is
available, otherwise reads it from the Registry.
`--live` reads the current script and resolves metadata; `--offline` requires a cached
script. Its JSON output contains `id`, `bytecode`, `source`, and `restored`.

Source output uses Lambdascript syntax highlighting on ANSI terminals.
`--color auto|always|never` controls it; automatic mode respects `NO_COLOR`,
`CLICOLOR=0`, `TERM=dumb`, and output redirection.
Saved `--out` files and `--json` output use plain text.

Decompilation reconstructs equivalent supported source forms.
Keep the original source to preserve its formatting, aliases, and authorship.
Arbitrary VM bytecode may have a valid disassembly without matching a supported source
reconstruction pattern.

To check a compiler-generated program by recompilation:

```sh
chainwall decompile transfer.json --no-preprocess > recovered.ls
chainwall compile recovered.ls --no-preprocess \
  --settings transfer.json --out rebuilt.json
```

Compare `bytecode` or `bytecodeHash` between the files.
With the optional `jq` utility:

```sh
jq -r .bytecodeHash transfer.json rebuilt.json
```

Byte-for-byte reproduction requires the same compilation settings and relevant metadata.
A publication wrapper contains its settings inside `program`; extract that object first
if you want to use it as a compiler settings file.

### Inspect transactions and generate source

Inspect a transaction using its hash, chain, and RPC endpoint:

```sh
chainwall transactions inspect "$TX_HASH" --chain base --rpc-url "$RPC_URL"
chainwall transactions inspect "$TX_HASH" --abi "$TOKEN_ADDRESS=token.json" --json
chainwall transactions source "$TX_HASH" --out calls.ls --program-out calls.json
chainwall transactions source "$FIRST_HASH" "$SECOND_HASH" --out batch.ls --program-out batch.json
```

Inspection includes the transaction, receipt, canonical block, decoded function
arguments, decoded receipt logs, and generated compiler JSON where possible.
Pending, successful, and reverted transactions have distinct statuses.
The CLI checks the RPC chain ID and the transaction, receipt, and log block identities.

Repeat `--abi ADDRESS=FILE` for targets and log emitters.
Files can be ABI arrays or compiler artifacts containing `abi`. Otherwise the selected
Registry uses the embedded ABI, and other addresses use cached or explorer-resolved
ABIs. `--refresh-abi` refreshes explorer data, including proxy implementation ABIs.
Here `--offline` disables explorer fetches; transaction and receipt reads still need the
RPC. Explorer ABIs describe their currently indexed implementation; supply the
historical ABI explicitly when inspecting a proxy before an upgrade.

Unknown and malformed calls or logs retain their raw data.
Indexed dynamic event arguments are marked `hashed: true`; their original values cannot
be recovered from the topic.
Selector collisions are reported as ambiguous.

Source generation preserves the supplied transaction order, native value, and ABI
argument types, including recursive tuples, arrays, bytes, and strings.
Save `--program-out` to retain the compilation settings and metadata.
The file must be new.
To compile the exported source again with the same inputs:

```sh
jq .metadata calls.json > calls.metadata.json
chainwall compile calls.ls --settings calls.json --snapshot calls.metadata.json --out rebuilt.json
```

With a selected Registry, matching cached contract addresses become Registry references,
including address arguments.
Review current catalog deployments before publishing.
Other targets use the app’s `@chain/checksummed-address` identifier format, which must
be registered or resolvable before execution.
Use the intended chain name, such as `--chain base`, for these identifiers.

Missing ABIs may produce exact raw calldata words with a warning.
Do not change dynamic offsets without obtaining the ABI. Contract creation, transfers
without a selector, malformed ABI data, unsupported calls, and noncanonical calldata are
reported with `sourceError` or `compileError`. Source generation fails if any requested
call is unavailable; it never drops a call from a batch.
Inspection still displays the available data.
Source uses the same terminal highlighting as interaction source, and saved files
contain plain text.

### Embedded contract compiler outputs

The CLI also carries the Solidity compiler JSON reference used for its Registry ABI.
This is distinct from the Lambdascript compiler result:

```sh
chainwall artifacts > registry-reference.json
chainwall artifacts RegistryInteractionsFacet > interactions-artifact.json
chainwall artifacts storage > storage-reference.json
chainwall artifacts PasswordGatedKV > kv-artifact.json
chainwall artifacts Interact > interact-artifact.json
```

The Registry reference contains the embedded contract artifacts and artifact checksums.
Individual artifact exports include the ABI and available compiler metadata.
Storage exports cover auxiliary contracts used for encrypted journals and execution
status. Use these exports to inspect parameter layouts and errors.

The embedded reference describes this binary's contract interfaces. Verify the
deployed contracts separately and use the command groups listed in `chainwall --help`.

### Optional low-level `miniscript` executable

If included in your distribution, `miniscript` compiles core Lambdascript, decompiles,
disassembles, and assembles instruction listings:

```sh
miniscript compile positive.ls > positive.hex
miniscript disasm positive.hex > positive.asm
miniscript assemble positive.asm > rebuilt.hex
cmp positive.hex rebuilt.hex
```

It accepts a file path or `-` for standard input.
Its `json` command accepts one request object or an array of requests, using `action`,
`source` or `bytecode`, and `settings`. Use `chainwall compile` for named Registry
references and ABI member calls.

## 14. Sync and browse local data

### Make a snapshot

```sh
chainwall sync
chainwall users list
chainwall groups list
chainwall policies list
chainwall orgs list
chainwall contracts list
chainwall tokens list
chainwall interactions list
chainwall accounts list
chainwall safes list
chainwall timelocks list
```

Default sync covers these ten Registry datasets.
When `kv_address` is configured, it also syncs operation journals and may prompt for the
local vault passphrase.
To choose datasets explicitly, give a comma-separated list without spaces:

```sh
chainwall sync --only users,groups,policies
chainwall sync --only interactions,timelocks --confirmations 12
```

Public datasets can be synced separately from private journals. A failure in one
selected dataset leaves the previous selected snapshot intact.
You can sync an independent subset while resolving an unavailable explorer or KV
service.

Successful sync output includes the chain ID, instance, selected datasets, block
number/hash/timestamp, and a Registry RPC request count.
That count does not represent every HTTP exchange across explorers and a separate KV
chain.

### Cached and live lists

| Form | Behavior |
| --- | --- |
| `users list` and other entity lists | Use a cached snapshot when one exists; otherwise use their live RPC query. |
| Entity list with `--offline` | Read exclusively from the local cache. |
| Entity list with `--live` | Bypass the cache and query the chain. |
| `timelocks list` | Require cached action history. |
| `timelock pending` | Query the live pending action queue. |
| `operations list` | Unlock and read cached operation journals and saved statuses. |

The nine entity lists are users, groups, policies, orgs, contracts, tokens,
interactions, safes, and accounts.
Individual reads such as `policies get` and `interactions get` query the chain.

```sh
chainwall interactions list --offline --start 0 --count 100 --json
chainwall interactions list --live --start 0 --count 100 --json
chainwall timelock pending --start 0 --count 100
```

Page offsets start at zero.
The default page size is 50; cached lists accept at most 1,000 rows per page.
A page offset is a position in the current result. Each entity has its own stable ID. Advance
`--start` by the page size to get the next page.
Avoid syncing midway through a multi-page export if you need every page to represent the
same cached snapshot.

Cached entity records generally contain a stable `id`, a `key`, and a named `record`.
Users are an address array, and timelock rows are action summaries.
Live ABI pages can have a different shape and can return keys rather than full records.
Handle both formats explicitly when a JSON consumer uses live and cached output.

After a write, check the receipt, finish any queued action, then sync the affected
datasets to refresh cached lists.

### How incremental sync works

Most Registry collections expose stable IDs, live-entry bitmaps, and journals of changes
grouped into epochs.
The CLI fetches new live entries, removes deleted ones, and refreshes touched records.
It revisits the previously seen epoch so changes within an ongoing epoch are included.
Users have a different index and are reread in batches.

These entity indexes exist independently of the Registry’s optional `indexingEnabled`
flag. That flag changes the strategy for timelock discovery:

| Registry indexing | Timelock discovery |
| --- | --- |
| Enabled | Read pending summaries and newly executed summaries directly from onchain indexes; refresh previously observed actions that leave the pending queue. |
| Disabled | Use RPC or Etherscan V2 queue-event logs to discover action IDs, then read their current summaries through RPC. |

```sh
chainwall registry indexingEnabled
chainwall sync --only timelocks
```

Indexed discovery preserves terminal states for actions it observed.
An action queued and cancelled entirely between syncs may never enter that local
history. Treat indexed history as the available index plus observed transitions, not a
complete event audit.
Explorer-based discovery depends on the explorer’s own coverage and indexing progress.

`sync` detects and uses the configured indexing strategy.
Enabling optional indexing is a separate governed onchain change.

### Blocks, confirmations, and reorganizations

By default, a sync selects the latest available block.
To keep the snapshot behind the head, choose a confirmation depth:

```sh
chainwall sync --only users,groups,policies --confirmations 12
```

The number sets the block distance behind the head. Choose it according to the
chain's finality behavior and your operational requirements.
Alternatively, select a specific block or supported RPC block tag:

```sh
chainwall sync --only interactions --block "$SNAPSHOT_BLOCK"
chainwall registry getUserCount --block "$SNAPSHOT_BLOCK"
```

Choose either an explicit sync `--block` or a nonzero `--confirmations`. Historical
snapshots require an RPC capable of serving that state. `--block` selects the state
used for reads; transactions execute against the chain state when mined.

Sync reads are pinned to a block hash using EIP-1898 canonical-block selectors.
The RPC must support those selectors and JSON-RPC batches.
The CLI checks the old checkpoint for reorganization, resets affected snapshots when
necessary, and checks the new block before committing.
If the chain changes during the sync, retry from the preserved checkpoint.

Network reads and decoding use a private disk snapshot so they do not hold the live
database's write lock. Publication checks the source revision, then atomically applies
changed rows and checkpoints. Concurrent writers remain usable; if one changes the
database, `DatabaseChangedRetrySync` preserves its work and asks for a fresh sync.
The same staging applies to recipient refresh, checkpoint preparation and LSP metadata.

### Explorer ranges and full refreshes

```sh
chainwall sync --only timelocks --from-block "$REGISTRY_DEPLOYMENT_BLOCK"
chainwall sync --only timelocks --lookback 512
chainwall sync --only timelocks --log-source rpc
chainwall sync --only timelocks --full
```

`--from-block` is the lower bound for explorer discovery, defaulting to zero.
Starting at a known deployment block can reduce the first scan.
Starting too late can omit history.
The bound is recorded, and changing it resets the affected snapshot.
Keep the same bound on subsequent invocations when that is the range you intend to
maintain.

Explorer scans revisit the last 128 blocks by default to catch delayed logs.
`--lookback` changes that overlap; zero resumes after the previous checkpoint without
overlap. If indexing lag exceeds the overlap, use `--backfill-from N` to revisit
older logs without clearing cached records, or a full rescan of the intended range.
Use `--log-source rpc` for a backfill independent of explorer indexing lag.
Immutable KV values already cached are not downloaded again just because
their logs fall inside the overlap.

Checkpoint `block` describes the state snapshot. Its separate `discovery` record
reports the actual log source, requested range and verified contiguous coverage.
`historyComplete` refers to coverage from the configured `--from-block` through
the snapshot. Explorer responses cannot establish it: `indexerCompleteThrough`
remains null. Sync output includes these checkpoints for each completed dataset.

The explorer reader paginates, subdivides oversized ranges, retries rate limits within a
bounded allowance, and checks log block hashes against RPC. Provider errors are errors,
not an empty-history result.
A successful response still depends on the provider having indexed the relevant logs.

`--full` rebuilds the selected snapshots using the selected strategy.
It preserves the local vault and reads the current chain state.
Prefer it to deleting the database, which may contain your only encrypted copy of a
generated KV secret.

## 15. Manage queued Registry actions

A Registry write may be governed by a delay, approval policy, and grace period.
In that case its first transaction queues an action containing the intended change.
A later transaction executes that action after its requirements are met.

### Inspect the queue

```sh
chainwall timelock pending
chainwall sync --only timelocks
chainwall timelocks list --offline
```

The singular `timelock` group performs live queries and transactions.
The plural `timelocks list` reads cached history.
Use `timelock pending` for the current pending
queue.

Copy the actual action ID from the write’s receipt or a queue result:

```sh
chainwall timelock get "$ACTION_ID" --json
chainwall registry getActionApprovalState "$ACTION_ID" "$APPROVER_ADDRESS" --json
```

An action ID is a bytes32 value generated by the governance workflow.
It is not a label to invent with `chainwall id`, and it is different from an Interact
operation’s numeric ID.

The action view includes its original actor, category, scope, policy ID, payload hash,
schedule time, delay, earliest execution time (`eta`), expiry (`expiresAt`), status, and
`executable` indicator.
Timestamps are Unix seconds.
The approval-state query reports the current policy and the selected approver’s ability
to contribute.

Numeric action statuses are:

| Value | Name |
| ---: | --- |
| 0 | None |
| 1 | Queued |
| 2 | Ready |
| 3 | Executing |
| 4 | Executed |
| 5 | Cancelled |
| 6 | Expired |

Use the current view’s `executable` and approval-state fields when deciding whether to
execute. A cached status can be older than current time or policy membership.

### Approve and execute

Each approver signs from their own eligible address:

```sh
chainwall timelock approve "$ACTION_ID" --account first-approver
chainwall timelock approve "$ACTION_ID" --account second-approver
chainwall timelock get "$ACTION_ID"
```

After approvals and the required delay are satisfied, an authorized executor can submit:

```sh
chainwall timelock execute "$ACTION_ID" --dry-run
chainwall timelock execute "$ACTION_ID" --json
```

Execution rechecks the contract’s applicable conditions.
An actor’s revoked authority, changed policy, expired grace period, or stale expected
bundle hash can prevent a previously queued change from executing.
Recheck those conditions at execution time, after approval.

For cancellation or recording expiry:

```sh
chainwall timelock cancel "$ACTION_ID" --dry-run
chainwall timelock expire "$ACTION_ID" --dry-run
```

Use cancellation only with the required authority.
Expiry recording applies when the action is eligible to expire.
Inspect state after the transaction, then refresh cached history.

### Batches and configuration

For several ready actions, `executeActions` accepts an array of actual action IDs.
Its argument-file shape is an object with `actionIds`, or a single-element positional
array containing that array:

```sh
chainwall registry executeActions --help --json
chainwall registry executeActions --args-file actions.json --dry-run
```

Check `executedActions`, `expiredActions`, and `skippedActions` after submission.
Batch success can include skipped actions; it is not an all-or-nothing assertion that
every requested action executed.

Governance configuration is available through the same interface:

```sh
chainwall timelock getCategoryConfig --help
chainwall timelock setCategoryConfig --help --json
chainwall timelock getScopeOverride --help
chainwall timelock setScopeOverride --help --json
```

Category settings and scope overrides determine how later changes are queued.
Use deployment-specific category IDs and reviewed configuration values.
Changing governance rules can itself require governance approval.

## 16. Connect encrypted operation storage

### Connect the app’s existing journal

To see the same proposals as an existing app setup, use its KV address and current
shared secret. Creating a different KV makes a different journal.

The secret file contains one `0x`-prefixed 32-byte private key in hex.
Obtain it through your team’s established secret-sharing process and restrict access to
the file. Do not substitute a Foundry keystore JSON file or its password.

Configure the storage chain and connect:

```sh
chainwall config set kv_chain base
chainwall config set kv_rpc_url "$BASE_RPC_URL"
chainwall kv connect "$KV_ADDRESS" --secret-file /absolute/path/to/kv-secret
```

The CLI asks for a local vault passphrase.
On first vault setup it asks you to confirm it.
It derives a local encryption key with Argon2id and encrypts the imported secret with
AES-256-GCM. The connection checks that the secret’s password-signer address matches the
KV’s current signer, then saves the KV address and chain in the profile.

Private commands unlock the vault for each invocation. Public Registry commands
read their catalog data directly.

For noninteractive use:

```sh
chainwall kv connect "$KV_ADDRESS" \
  --secret-file /absolute/path/to/kv-secret \
  --passphrase-file /absolute/path/to/vault-passphrase
```

Passphrase files contain the passphrase, with an optional trailing newline.
Interactive input hides terminal echo on supported POSIX terminals.
Windows currently requires `--passphrase-file`, as does an invocation without a usable
interactive terminal.
`--password-file` remains the separate Foundry option.

### Create a new journal

If your deployment needs a new KV, obtain the configured PasswordGatedKVFactory address
for the storage chain:

```sh
chainwall config set kv_factory "$KV_FACTORY_ADDRESS"
chainwall config set kv_chain base
chainwall config set kv_rpc_url "$BASE_RPC_URL"
chainwall kv create --dry-run
chainwall kv create
```

Creation uses the selected Foundry signer on the KV chain, so that signer needs native
gas funds there. The created KV has indexing enabled.
The CLI generates a secret, encrypts and saves it before broadcast, then records the
deployed KV address from the factory event.
The output shows the public address and signer; the generated secret stays in the vault.

A creation preview also persists the encrypted pending secret.
A later create with the same profile, factory, and chain reuses that pending secret
unless you explicitly supply a secret file.
If broadcasting or receipt processing fails, keep the database and inspect the
transaction before retrying.
A transaction may have succeeded even if its receipt was not processed locally; blindly
retrying creation could create an additional KV.

The new journal starts empty. Coordinate its address and secret with the clients that
will publish proposals to it, and keep the old journal configuration for historical
records. Use `config export` to share the new configuration.

### Rotation and historical secrets

The KV owner can rotate the shared secret directly:

```sh
chainwall kv rotate --dry-run
chainwall kv rotation-status
chainwall kv rotate --resume
chainwall kv history
```

`rotate` generates a new secret unless `--secret-file FILE` supplies one.
It saves the exact encrypted recovery record before broadcast.
Even a dry run persists that record; use `--resume` to reuse its secret, ciphertext,
nonce and signature.
A second fresh rotation is refused while one is pending.
Add `--passphrase-file FILE` for noninteractive vault access.
Submission uses the selected signer, which must own the KV on its storage chain.

The local head changes only after the chain proves the expected new signer, rotation
nonce and exact encrypted parent entry.
If receipt processing or a profile write is interrupted, inspect `rotation-status`, then
`rotate --resume`. An already confirmed attempt is adopted from verified chain state.
A conflict is refused and the encrypted recovery record is retained.
Preserve the vault and reconcile the chain state before proceeding; do not delete the
recovery record merely to suppress an error.

`history` validates and caches the backwards chain and prints its public signer addresses.
`config export` includes the new current secret in the app format after confirmation.
Share it with the other app/CLI clients that need future writes.
Existing encrypted proposals and labels remain readable through their historical keys.
Rotation locks this profile’s active completion helper; run `completions unlock` again
to load the updated keyring.

When the app rotates its shared secret, connect again with the new current secret, then
sync:

```sh
chainwall kv connect "$KV_ADDRESS" --secret-file /absolute/path/to/new-kv-secret
chainwall sync --only operations
```

The CLI follows validated encrypted parent links to recover older secrets and read older
proposals, up to 64 secrets in a history.
Obtain the new current secret after each rotation to read subsequent records.
If a parent link is invalid, cyclic, or too deep, sync reports an error instead of
silently trusting it.

The SQLite database stores original onchain ciphertext, encrypted secret history, and
encrypted operation status snapshots.
Proposal contents are decrypted for use in memory after unlocking.
Public Registry records in the same database remain readable.

## 17. Read operation proposals

### Compact the operational view

```sh
chainwall operations checkpoint prepare
chainwall operations checkpoint inspect "$CHECKPOINT_ID"
chainwall operations checkpoint publish "$CHECKPOINT_ID"
chainwall sync --only operations
chainwall operations list --view operational
chainwall operations list --view audit --all-chains
```

Preparation syncs the complete indexed shared journal, including every readable
secret epoch and execution chain. It saves an encrypted local draft and reports
the checkpoint ID, retained count, excluded expiry count and canonical blocks.
It never applies the account, status or pagination filters from list commands.

Only proposals expired on the selected execution chain are excluded, using chain
time 12 blocks behind the head by default. Set `--confirmations N` for the desired
depth. An unproven `closed` status does not establish that a proposal belongs to
the selected tenant, so it is retained until its deadline. Other execution chains
are retained. `--keep-all` retains all distinct proposals and needs only KV RPC.
Unreadable or invalid proposal records prevent preparation.

`publish` rechecks saved canonical blocks and the current KV secret epoch, writes
encrypted chunks first, then publishes the checkpoint manifest. `--chunk-size 1..128`
on preparation sets proposals per chunk. Repeating publication verifies and skips
confirmed records. An unconfirmed attempt requires explicit `--retry`; inspect
the saved attempt first. A secret rotation or reorganization requires a new draft.
Drafts and attempt details are encrypted in the local vault. All three commands
accept `--passphrase-file FILE`; publication also supports `--dry-run`.

Operational listing validates checkpoint manifests, chunk hashes, covered signer
indexes and retained proposals, then replays all later proposals. Invalid or
incomplete checkpoints fall back to older valid checkpoints or full history.
Audit listing shows all raw proposal records, including duplicate pending IDs and
compacted records, without local-import overlays. It never deletes history.
Synchronization continues to cache full ciphertext history for audit and fallback.
`journalCheckpoint` reports the accepted journal checkpoint; `rejectedCheckpoints`
counts invalid candidates encountered. The separate `checkpoint` field describes
the local SQLite synchronization snapshot.

### Configure execution status and sync

Set Interact to the execution component bound to this profile’s Registry:

```sh
chainwall config set interact "$INTERACT_ADDRESS"
chainwall sync --only operations
chainwall operations list
```

The CLI verifies the Interact component identity and its Registry binding before saving
statuses.
Without a configured Interact, journal proposals can still be listed, but their
execution status is `unknown`.

Indexed KV sync reads new keys for each readable password signer.
A KV with indexing disabled uses RPC or Etherscan write-event logs instead.
Previously cached immutable values are reused.
Only supported operation journals are decoded; unrelated KV values are ignored, and
matching records with invalid or unreadable contents are counted.

This version reads version-3 proposal journals containing version-2 pending payloads.
Prepare journals in this supported format before importing them.

### Filter the list

```sh
chainwall operations list --safe "$SAFE_ADDRESS" --status active
chainwall operations list --status expired --start 0 --count 100
chainwall operations list --all-chains --offline --json
```

`--safe` accepts the proposal’s managed Safe or account address.
Lists normally show proposals for the selected execution chain.
`--all-chains` includes readable proposals for other execution chains in the same
journal.

Listings read local snapshots. Journal-backed lists require a prior operations
sync; `--offline` makes the cached read explicit and `sync --only operations`
refreshes the journal and status observations. Operational lists merge local
imports with journal entries before deduplication, sorting, and pagination.
`--local`, or a profile without `kv_address`, lists encrypted local imports
without a journal sync. This mode reports execution status as `unknown` and
requires a single selected execution chain.

`--view audit` lists raw journal entries, including duplicates, and excludes local
imports. It requires configured journal storage and rejects `--local`.

### Read an entry

All list modes include `entries` and `total`. Journal-backed output also includes
`checkpoint`, `statusBlock`, `unreadable`, and `invalid`; local-only output has
`source: "local-imports"` and a null `statusBlock`. `total` is the count after
chain, Safe, and status filtering, before pagination. Operational proposals are
deduplicated by pending identity and ordered with newer creation times first.

Each entry includes a pending ID, status, and a `payload`. Journal entries also
include a journal key and encryption-signer address. Imported entries instead
include `source: "local-import"` and `proposalTxHash`. Useful payload fields include:

| Field | Meaning |
| --- | --- |
| `safe` | Managed address for the proposed execution. |
| `creator` | Address recorded as the proposal creator. |
| `chainId` | Execution chain. |
| `interactionId` | Registry interaction ID. |
| `policyId` | Proposed approval policy ID. |
| `args` | Integer program arguments. |
| `nativeValue` | Native currency value in wei. |
| `operationId` | Numeric operation ID used by Interact. |
| `payloadHash`, `executionBindingHash` | Stored hashes binding proposal/execution data. |
| `deadline`, `createdAt` | Unix timestamps in seconds. |

The encryption-signer address is not necessarily the proposal creator or your Foundry
transaction signer. Numeric fields can be decimal strings; handle them without
floating-point truncation.

### Interpret status precisely

| Status | What the saved check establishes |
| --- | --- |
| `active` | A live Interact record matches the proposal’s Safe, policy, and native value, and the proposal deadline has not passed at the checked block. |
| `expired` | The live matching record’s proposal deadline is earlier than the checked block’s timestamp. |
| `closed` | Interact’s `isOperationExecuted` predicate returned true. It covers removed, withdrawn, and missing records as well as executed ones. |
| `mismatch` | A live record’s Safe, policy, or native value differs from the proposal. |
| `unknown` | No applicable verified status observation is available for this listing. |

For an `active` operation, check approval readiness and simulate execution.
For a `closed` operation, inspect transaction/event evidence to distinguish execution
from withdrawal or removal.

`checkpoint` describes journal synchronization on the storage chain.
`statusBlock` describes execution-state checks on the selected execution chain.
They can refer to different chains and times.
Offline statuses reflect the saved check. Sync again to evaluate expiry against a
newer block timestamp.

For `--all-chains`, another chain's status is used only when the profile explicitly
maps that chain's Registry in `[instances]` and a verified status snapshot exists
for that Registry and the same KV scope. Configure `[interacts]` and sync operations
on each execution chain to populate its observations. Missing mappings or snapshots
produce `unknown`. Per-entry `statusRegistry` and `statusBlock` identify the context;
the top-level `statusBlock` describes the currently selected execution chain.

The unreadable and invalid counts describe journal records encountered during decoding,
not necessarily just the page or filtered Safe you requested.
The operational list also includes local imports for the selected chain and Registry.
Audit view covers only readable, supported proposals in the configured journal.

### Create and publish a proposal

Configure `interact` or `[interacts]` for the execution chain.
The CLI verifies its Registry binding before every operation command.
Create `intent.json`:

```json
{
  "safe": "0xYOUR_SAFE_OR_OKACCOUNT",
  "interactionId": "0xYOUR_BYTES32_INTERACTION_ID",
  "policyId": "0xYOUR_BYTES32_POLICY_ID",
  "deadline": "1900000000",
  "args": ["2"],
  "nativeValue": "0"
}
```

Amounts and timestamps are integers in base units.
`args` defaults to `[]`; `nativeValue` defaults to `0`. The deadline must be in the
future onchain.

```sh
chainwall operations propose intent.json --dry-run
chainwall operations propose intent.json --out proposal.json --account proposer
chainwall operations publish proposal.json --account journal-writer
chainwall operations status 123
chainwall operations approve 123 --account approver
chainwall operations withdraw 123 --account proposer
```

`propose` obtains the current execution binding, computes the payload hash, and submits
to Interact. It reserves a new mode-0600 output file before broadcast, then stores the
app’s v3 journal proposal containing its v2 payload.
Existing files are rejected before broadcast.
A file still marked `prepared` means confirmation was interrupted; inspect the sender’s
transaction receipt before retrying, to avoid creating another operation.

`publish` unlocks the local vault and writes a protocol-compatible AES-GCM envelope under a
random journal key on the configured KV chain.
Use `--passphrase-file` for automation.
Publication is separate from proposal creation, so a KV failure can be retried without
proposing again. Repeated successful publication creates another immutable record;
readers deduplicate by pending identity.
`--nonce` on publish is the writer’s transaction nonce on the storage chain.
Proposal files contain decrypted operation details; keep them private.

### Execute without a proposal

```sh
chainwall operations direct intent.json --account operator --dry-run
chainwall operations direct intent.json --account operator --out execution.json
```

Direct execution uses the same intent fields as proposal creation and requires
the actor to satisfy the policy alone. A nonzero future `deadline` is required.
The signed context binds the chain, destination, policy, arguments, runtime
binding, native value, maximum steps, deadline, and actor nonce. Submission
revalidates that context and simulates the exact signed call.

For an owner-signed Safe transaction, use `direct-sign-actor --via safe`, then
`direct-sign --via safe` for every required owner. Collect the owner results into
a JSON array and pass both `--actor-signature-file` and `--signatures-file` to
`direct --via safe`. An enabled OKModule provides the shorter route below.

### Execute through an OKAccount

```sh
chainwall operations execute proposal.json --account executor --dry-run
chainwall operations execute proposal.json --account executor
chainwall operations execute proposal.json --account executor --approve
```

The default path calls Interact’s `executeFromAccount`. `--approve` selects
`approveAndExecuteFromAccount`. Policy and executor permissions still apply.
`--max-steps N` defaults to 100000. `--reveal-file FILE` selects the private variant and
reads the app/ABI reveal object (`bundle`, `relatedContracts`, `salt`, `signature`). The
contract validates the committed payload at execution.

### Execute through a Safe

```sh
chainwall operations sign-actor proposal.json --via safe \
  --account executor --out actor.json
chainwall operations sign proposal.json --via safe \
  --actor-signature-file actor.json --account safe-owner --out owner.json
jq -s . owner.json > signatures.json
chainwall operations execute proposal.json --via safe \
  --actor-signature-file actor.json --signatures-file signatures.json \
  --account submitter
```

Each required Safe owner runs `sign` with the same actor authorization.
Collect their output objects into one JSON array (`jq -s . owner1.json owner2.json`).
Use identical `--approve`, `--max-steps` and `--reveal-file` options throughout signing
and execution. Signing uses Foundry keystores.
The CLI sorts EOA owner signatures by address and rejects duplicates or a different Safe
transaction hash, including a changed Safe nonce.
Safe verifies the owner threshold and Interact verifies the actor.
A successful outer receipt is accepted only when Safe emits `ExecutionSuccess` for the
expected hash.

`--dry-run` on either signing command previews the typed data.
`execute --via safe --dry-run` can omit owner signatures to preview the call.
An actor authorization file is still required to construct that transaction.
These execution paths accept a v2 payload directly or its v3 journal wrapper.

### Execute through a Safe module

```sh
chainwall operations direct intent.json --via module --account operator
chainwall operations execute proposal.json --via module --account operator
chainwall operations execute proposal.json --via module --account operator --approve

# Separate actor authorization from gas payment.
chainwall operations sign-actor proposal.json --via module --account actor --out actor.json
chainwall operations simulate proposal.json --via module --actor-signature-file actor.json --account relayer
chainwall operations execute proposal.json --via module --actor-signature-file actor.json --account relayer
```

The optional OKModule must already be enabled on the Safe. The CLI discovers its
address from live, Registry-authorized Safe factories, using the indexed Safe
record when available. It validates the tenant binding, managed Safe, enabled
module, and extension policy. A missing or disabled module aborts the command.
Module execution uses actor authorization and keeps the Safe owner nonce intact.
The contract still enforces policy, execution permissions, and operation status.

Signing is automatic unless `--actor-signature-file` is supplied. Use
`direct-sign-actor --via module` to save a direct authorization for a relayer.
`--signatures-file` and owner-signing commands are invalid on this route.
Keep `--approve`, `--max-steps`, and `--reveal-file` consistent when signing and
executing. Public and private variants are supported. Dry runs do not sign, and
an unsigned preview does not prove executability. For read-only simulation,
provide a signed actor file and the intended relayer.

```sh
chainwall operations direct intent.json --via module --auth-profile passkey.json --account sponsor
chainwall operations execute proposal.json --via module --auth-profile passkey.json --bundler-url "$BUNDLER_RPC"

# Customer-funded OKAccount execution through a standard ERC-4337 bundler.
chainwall operations direct intent.json --via account --auth-profile passkey.json \
  --bundler-url "$BUNDLER_RPC" --paymaster "$PAYMASTER"
```

With a Foundry sponsor, the passkey signs the ERC-1271 actor authorization and
the sponsor relays the verified call. With a bundler, the approval page prepares
the app's full UserOperation, binds its authorization revision and execution
runtime, and supplies a transient proof valid only for the expected Interact
digest. Bundled calls use the selected passkey actor; external actor files are
rejected. UserOperation estimation and signing run in the approval flow.
Receipt verification requires the matching EntryPoint success event and the
module's matching execution event. Pending UserOperations remain recoverable
with `auth receipt`.

`--paymaster` selects the tenant's `OKAccountPaymaster` instead of the ZeroDev
sponsorship flow. It is valid only with `--bundler-url`. The approval app reads
the paymaster through the normal chain RPC, authenticates its release and
tenant bindings, checks the selected AuthAccount enrollment, and submits the
signed operation to the bundler. This path supports only `--via account`
OKAccount protocol calls; Safe and module routes are rejected before approval.

## 18. Use several chains

### Separate execution profiles

```sh
chainwall --profile treasury-base sync --only users,interactions,timelocks
chainwall --profile treasury-ethereum sync --only users,interactions,timelocks
chainwall --profile treasury-base interactions list --offline
chainwall --profile treasury-ethereum interactions list --offline
```

Records and checkpoints are scoped by chain ID, contract address, and dataset.
The same interaction ID on two chains can resolve to different program bundles, contract
deployments, or policies.
Sync each Registry separately to maintain its local catalog.

You can instead use chain tables in one profile:

```sh
chainwall sync --chain base --only interactions
chainwall sync --chain ethereum --only interactions
```

Configure the corresponding RPC, Registry, and Interact entries first.
Configure a provider URL and Chainwall deployment for each chain you select.

### Shared storage on another chain

For example, an Ethereum execution profile can read a Base-hosted journal:

```sh
chainwall --profile treasury-ethereum config set kv_chain base
chainwall --profile treasury-ethereum config set kv_rpc_url "$BASE_RPC_URL"
chainwall --profile treasury-ethereum kv connect "$KV_ADDRESS" \
  --secret-file /absolute/path/to/kv-secret
chainwall --profile treasury-ethereum config set interact "$ETHEREUM_INTERACT_ADDRESS"
chainwall --profile treasury-ethereum sync --only operations
chainwall --profile treasury-ethereum operations list
```

If the KV and execution chain are the same, their sync reads use the same selected
block. If they differ, the KV gets its own snapshot with the chosen confirmation depth.
These are two chain observations committed together locally, not a synchronized instant
shared by two blockchains.

Profiles pointing at the same KV chain and address share its cached ciphertext and
journal checkpoint. Syncing it from one profile can advance the journal checkpoint
visible to another; execution status remains scoped to the selected Registry and
execution chain.

`--from-block` is one numeric lower bound passed to explorer discovery, including KV
discovery. Block heights on different chains are unrelated.
Do not apply an Ethereum deployment height as a lower bound for Base KV logs.
Use zero, or split the scans with the right bound for each chain:

```sh
chainwall sync --only timelocks --from-block "$REGISTRY_DEPLOYMENT_BLOCK"
chainwall sync --only operations --from-block "$KV_DEPLOYMENT_BLOCK"
```

Repeat each command with its intended bound on later runs to retain the same discovery
range.

## 19. Automation and JSON output

### Validate and edit JSON inputs

Command JSON files are validated before RPC or signing; keystores are checked
when selected for signing. Diagnostics name the field without printing its value.
Signature, hash, tenant and live-state checks still apply after structural validation.

```sh
chainwall schemas list
chainwall schemas template operation-intent --out intent.json
chainwall schemas validate operation-document intent.json
chainwall schemas show operation-document --out operation.schema.json
chainwall registry upsertToken --schema
```

`--schema` prints the selected command's input schema without executing it. Add
`--edit-input signatures-file`, `settings` or another JSON option
to inspect that auxiliary input. Schemas are bundled for offline validation.
Large integers should be decimal strings to avoid precision loss in JSON tools.

To edit an input as part of the command:

```sh
chainwall config set editor hx
chainwall operations direct --interactive --dry-run
chainwall operations propose intent.json --interactive --out proposal.json
chainwall registry upsertToken --interactive --dry-run
```

Omit the JSON filename for a template, or supply a file to edit a copy. Supply
the other command arguments normally. Use `--interactive --edit-input OPTION`
to edit an auxiliary JSON input. Templates have placeholders to complete; they
do not generate signatures or provenance evidence.

Editor selection uses `--editor COMMAND`, `CHAINWALL_EDITOR`, the profile's
`editor`, `VISUAL`, `EDITOR`, then `vi`, in that order. Editor arguments are
supported without shell expansion. For a GUI editor, use its wait option, for
example `chainwall config set editor 'code --wait'`.

Save and quit successfully to validate and continue the command. Normal signing
and submission follow unless you supplied `--dry-run`. An editor error exit,
empty file or untouched new template cancels execution. Invalid JSON stops and
reports the retained draft path so you can correct and reuse it.

Working directories under `CONFIG_DIR/interactive` are private (0700), with
0600 input files and an exported `schema.json`. Original input files are preserved.
Successful temporary drafts are removed; failures retain them. Facet application
and reconciliation retain the working file with their receipt evidence. The CLI
cannot control the editor's separate backup, history or plugin settings.

### Saved transaction logs

All commands that submit transactions automatically save JSON logs under
`~/.config/chainwall/logs`, or `logs` within your selected `--config-dir` or
`CHAINWALL_CONFIG_DIR`. The usual `XDG_CONFIG_HOME` setting also applies.
Each command uses one log, including all stages of a deployment. Logs include the
profile, command name, receipts, full command result, and any final error name.
Files use mode 0600. RPC URLs, password options, and raw command arguments are not
recorded. Reads and dry runs do not create transaction logs.

```sh
chainwall logs list
chainwall logs show latest
chainwall logs show <filename-or-full-path-from-list>
chainwall logs show latest --json > transaction-log.json
```

These commands work offline and include all profiles in the selected config
directory. The list is newest first; `logs show` defaults to `latest`. JSON is
highlighted on supported terminals. Use `--color never` to disable color, or
`--color always` to force it. `--json` and saved files always contain plain JSON.

Receipts are saved as they arrive, before later verification or profile updates.
A command that fails afterward prints its log path on stderr. A `pending` log may
mean the command was interrupted; inspect its receipts before retrying. The log's
`complete` or `error` status describes the CLI command, not onchain execution.
Existing `--out` exports still work. With `--json`, the original command result
remains on stdout and the automatic log path goes to stderr.
On chains supported by Etherscan, each broadcast also prints its transaction
explorer URL to stderr when the hash is available, for example a BaseScan link
on Base. The URL appears even if subsequent verification fails. These links
are only displayed in the terminal; they are not added to saved logs or JSON
stdout. No Etherscan API key is needed.

### Capture predictable output

Use `--json` for structured calls and transaction results.
Many local commands, including sync and cached lists, already return JSON. Use
`--offline` to avoid an entity list switching to live ABI output before its first sync.

JSON output uses subtle syntax highlighting on supported terminals, including
dry-run previews, artifacts, config exports to stdout, and completion status.
Use `--color auto|always|never` to control it. Automatic mode respects `NO_COLOR`,
`CLICOLOR=0`, `TERM=dumb`, and output redirection. Explicit `--json` output and
saved files always remain plain, even with `--color always`.

```sh
chainwall --profile treasury-base sync --only users,groups --json > sync.json
chainwall --profile treasury-base users list --offline --count 1000 --json > users.json
chainwall --profile treasury-base groups list --offline --count 1000 --json > groups.json
```

For datasets larger than 1,000 rows, retrieve additional pages to complete the export.
Inspect `total` and the checkpoint in each result.

Common output shapes:

| Command | Output with `--json` |
| --- | --- |
| Generic Registry read | Array of ABI return values; tuples may be positional arrays. |
| Generic method help | Function ABI object. |
| Registry write | Classified status, action arrays, and original receipt. |
| Write preview | Chain ID, destination, function signature, calldata, and value. |
| Cached users | `total`, `users`, `checkpoint`. |
| Other cached entity lists | `total`, `entries`, `checkpoint`. |
| Cached timelocks | `total`, summary `entries`, `checkpoint`. |
| Operations | Filtered `total`, `entries`, journal `checkpoint`, `statusBlock`, decode counts. |
| Compile | Complete `chainwall.program.v1` result. |
| Config show | Redacted stored configuration object. |

`id`, `decompile`, `disasm`, version text, top-level/group help, and Foundry account
listing produce text, including with `--json`. Artifact exports produce JSON.

Successful commands normally exit zero.
Failures exit nonzero and print diagnostics to stderr. Capture stderr as text,
including when using `--json`.
Avoid parsing error text as a stable API. Preserve stdout and stderr separately when
collecting diagnostics.

### Check transaction outcomes in scripts

This example uses the optional `jq` utility.
It deliberately stops for a queued or incomplete outcome rather than continuing as if
the user had been added immediately:

```sh
set -eu
umask 077
chainwall --profile treasury-base users add "$USER_ADDRESS" \
  --password-file /absolute/path/to/foundry-password \
  --json > add-user-result.json

jq -e '.status == "confirmed"' add-user-result.json > /dev/null
chainwall --profile treasury-base users contains "$USER_ADDRESS" --json \
  > user-membership.json
jq -e '.[0] == true' user-membership.json > /dev/null
chainwall --profile treasury-base sync --only users --json > sync-users.json
```

For batches, also inspect the action arrays and verify the specific state changes your
script requires. On uncertain submission failures, inspect the transaction before
retrying a write.

### Unattended journal reads

```sh
umask 077
chainwall --profile treasury-base sync --only operations \
  --passphrase-file /absolute/path/to/vault-passphrase --json > operations-sync.json
chainwall --profile treasury-base operations list --offline --count 1000 \
  --passphrase-file /absolute/path/to/vault-passphrase --json > operations.json
```

The exported operations file contains decrypted proposal details.
Restrict its permissions and treat it according to the proposal’s confidentiality needs.
Keep passphrase/password files outside command logs and ordinary shared working
directories. Use a secret manager to provision them when available.

Schedule repeat sync invocations with your operating system’s scheduler if needed.
Avoid overlapping sync writers against the same local database; SQLite serializes writes
and a busy writer can cause another invocation to fail.

## 20. Backups, upgrades, and recovery

### What to preserve

Back up the complete configuration directory, including the SQLite database, profiles,
and any SQLite sidecar files that are present.
Keep the local vault passphrase separately in your password manager or equivalent
recovery process. The database may contain the only saved copy of a secret generated by
`kv create`.

Also preserve, separately:

- Foundry keystores and their recovery information.
- Original `.ls` programs and reviewed compiler/publication JSON files.
- Transaction receipts and the deployment addresses needed to reconnect.
- Any externally managed KV secret needed by other clients.

List exports are useful for inspection. For recovery, keep the complete vault backup
and its passphrase. Resync restores public chain data and ciphertext; decrypting private
records requires the saved secret and passphrase.

### Copy a consistent local store

Finish all Chainwall processes using the directory before taking a filesystem copy.
Include the database and any `-wal` and `-shm` sidecars together; copying only the main
database while a writer is active can omit committed data still in the WAL. A proper
SQLite backup tool is another option if you already use one.

To inspect a restored copy, point a command at its directory:

```sh
chainwall --config-dir /absolute/path/to/restored-chainwall profile list
chainwall --config-dir /absolute/path/to/restored-chainwall \
  --profile treasury-base users list --offline
chainwall --config-dir /absolute/path/to/restored-chainwall \
  --profile treasury-base operations list --offline
```

The operations command requires the restored store’s passphrase.
File paths stored in profiles, such as keystore and password paths, may need updating on
a new machine.

### Update the executable

Record `chainwall --version`, back up the store, and read the new binary’s release notes
before replacing it.
Check the new `--version` and `--help`, then inspect a cached list and refresh a small
dataset. A database created by a newer incompatible version can be rejected by an older
executable; keep the backup if you need to return to the earlier version.

For stale public data, use a selected `sync --full`. For an ABI issue, use
`--refresh-abi`. Neither requires deleting the entire config directory.

Recovery requires the original vault passphrase and intact vault data. An authentication
failure can mean the wrong passphrase or damaged data; preserve the store while checking
your password and backups.

## 21. Troubleshooting

### Connection and signer problems

| Symptom | What to check |
| --- | --- |
| Foundry `cast` is required on PATH | Run `cast --version` from the same terminal or automation environment. Install Foundry or fix PATH. |
| RPC URL required | Set `rpc_url` for the default chain, add `rpc.CHAIN`, or pass `--rpc-url`. A different `--chain` does not reuse an unrelated scalar RPC. |
| RPC chain ID mismatch | Check `--chain`, `CHAINWALL_CHAIN`, and the provider URL. Do not change the expected chain simply to silence a mismatch. |
| No code at instance | Check the chain and address. For historical sync, ensure the chosen block is after deployment. |
| Not a Chainwall Registry | Use the Registry address, rather than an Interact, factory, or KV address. |
| Signer required | Select an existing Foundry account with `--account` or `config set account`. |
| Conflicting signers | Choose one explicit account, keystore, or unlocked signer mode. |
| Foundry cannot unlock the account | Check account name, keystore path, and Foundry password. The KV vault passphrase is unrelated. |
| Transaction reverted or unauthorized | Read the Foundry/contract diagnostic. Check live membership, capabilities, role governance, pause state, policy conditions, and intended destination. |

Start diagnosis with local information:

```sh
chainwall --version
cast --version
chainwall profile list
chainwall config show
chainwall registry chainwallComponentId --help
```

Configuration output is redacted, so use your provider configuration to check the actual
RPC URL. Also inspect any `CHAINWALL_*` variables set by your shell or scheduler; they
may override a correct profile.

### Sync and lists

| Symptom | Explanation and next step |
| --- | --- |
| No cached snapshot / run sync first | Sync that dataset for the selected chain and instance. A cache for another profile’s destination does not satisfy it. |
| A successful change is missing from a list | Check whether it queued a timelock action, then sync after execution. |
| `timelocks list --live` fails | Use `timelock pending`, or sync history and list it offline. |
| Explorer token required for logs | The selected timelock or KV strategy needs Etherscan. Configure its token, or sync an independent public subset meanwhile. |
| Etherscan rejected the request | Check API token, endpoint, chain support, API plan, and rate limit. |
| Explorer logs disagree with RPC | The providers may disagree after a reorganization or explorer delay. Retry once the explorer catches up. |
| RPC rejected a read | Check support for JSON-RPC batches, EIP-1898 block-hash selectors, historical state, and the required Registry methods. |
| Incomplete or invalid RPC batch | The provider did not return a usable response for every request. Use a provider that supports these reads. |
| Chain changed during sync | Retry the sync. The failed attempt did not advance the snapshot. |
| More history is expected | Check selected instance/chain, filters, page size, `--from-block`, explorer coverage, and indexed-history limitations. |
| Database busy | Wait for the other writer to finish and avoid overlapping scheduled syncs. |

A selective refresh is often enough:

```sh
chainwall sync --only users,groups,interactions --full
```

For delayed explorer events, preserve the intended lower bound and extend lookback, or
rebuild the relevant history.
Increasing lookback cannot recover events that the explorer never indexed or events
outside your lower bound.

### Source, ABI, and publication problems

| Symptom | What to do |
| --- | --- |
| Source must be an individual `.ls` file | Pass the source filename, not a directory, bundle, or compiler JSON result. |
| Unknown Registry reference | Check the exact lowercase `org/id`, chain, Registry, and reference kind. In offline mode check `knownKindsByTargetHash`. |
| Missing or unverified ABI | Configure Etherscan or supply the reviewed `--abi org/id=file.json`. |
| Invalid/stale ABI cache | Retry with `--refresh-abi`; also verify the Registry’s implementation metadata. |
| Ambiguous ABI overload | Add exact type annotations such as `$arg0 :: address` or `$arg1 :: uint256`. |
| Payable call rejected during preprocessing | Supply the explicit `{value: expression}` call option required by the payable method. |
| Interaction already exists | Use `interactions update`, or choose a genuinely different `--id` for a new interaction. |
| Interaction missing on update | Check chain and ID, including the filename stem. Use `add` for a new ID. |
| Expected bundle hash no longer matches | Read the current bundle and prepare a reviewed update against it. |
| Decompilation fails but bytes are valid | Supply the original settings and ABI metadata; use `disasm` for patterns outside supported reconstruction. |
| Recompiled bytes differ | Compare optimization, argument context, ABI metadata, preprocessing inputs, and binary version. |
| Unknown option or argument count | Inspect the exact command’s help. Generic methods use ABI parameter names, not invented aliases. |

Useful inspection commands:

```sh
chainwall compile --help
chainwall registry upsertInteractionBundle --help --json
chainwall decompile --help
chainwall artifacts RegistryInteractionsFacet > interactions-artifact.json
```

### Encrypted journals

| Symptom | What to do |
| --- | --- |
| KV address or secret required | Connect the app’s KV with its current secret file. |
| Wrong passphrase or vault authentication failure | Check the local vault passphrase and restored database. Preserve the existing store while investigating. |
| Secret does not match current password signer | Obtain the current secret for that exact KV and chain, including any recent app rotation. |
| Interactive terminal required | Supply `--passphrase-file` for automation or unsupported terminal platforms. |
| KV RPC URL required | Configure `kv_rpc_url` or the matching `[rpc]` entry for the storage chain. |
| Interact/Registry mismatch | Set `interact` or `[interacts]` to the execution component bound to the selected Registry. |
| Every proposal is `unknown` | Local-only listings have no verified execution status. For journal listings, check Registry/Interact mappings and sync each execution chain; other-chain rows require an explicit Registry mapping and a matching saved status snapshot. |
| Proposal is `closed` but no execution is known | The predicate includes withdrawn or missing records. Check execution transaction/event evidence separately. |
| Unreadable/invalid journal count is nonzero | Check current secret, rotation history, compatible journal format, and the intended storage address. |
| Factory transaction may have succeeded but setup failed | Keep the encrypted pending secret in the database and inspect the receipt/deployment before retrying creation. |

For a support report, include binary versions, command shape, selected chain, public
contract addresses, error text, and relevant checkpoint information.
Remove API tokens, provider credentials, passwords, secret files, and private proposal
contents before sharing.
Keep the full SQLite database private. Share selected, redacted diagnostics.

## 22. Command and option reference

### Common commands

Arguments in uppercase below are values to supply.
Optional options are described in the corresponding sections; method help is the source
for exact ABI argument types.

| Command | Purpose |
| --- | --- |
| `chainwall --help` | General help. |
| `chainwall --version` | Binary version. |
| `chainwall login ADDRESS` | Connect using a Registry or SafeFactory instance address. |
| `chainwall deploy` | Deploy a tenant through an existing OKFactory. |
| `chainwall config import FILE` | Import the app’s version-2 configuration JSON. |
| `chainwall config export [FILE]` | Export app-format JSON, including the shared secret. |
| `chainwall profile list` | Show profile names and current selection. |
| `chainwall profile create NAME` | Create an empty profile. |
| `chainwall profile use NAME` | Select an existing profile. |
| `chainwall config show` | Print redacted stored settings. |
| `chainwall config get KEY` | Inspect a setting. |
| `chainwall config set KEY VALUE` | Save a setting. |
| `chainwall config unset KEY` | Remove a setting. |
| `chainwall accounts` | List Foundry keystores. |
| `chainwall sync` | Refresh selected local snapshots. |
| `chainwall users list` | List registered users. |
| `chainwall users add ADDRESS` | Submit user registration. |
| `chainwall users remove ADDRESS` | Submit user removal. |
| `chainwall users contains ADDRESS` | Read user membership. |
| `chainwall users count` | Read current user count. |
| `chainwall groups list` | List groups. |
| `chainwall groups add ID` | Create a group. |
| `chainwall groups remove ID` | Delete a group. |
| `chainwall groups members ID` | Read group members. |
| `chainwall groups add-member ID ADDRESS` | Add an existing user to a group. |
| `chainwall groups remove-member ID ADDRESS` | Remove a group member. |
| `chainwall policies list` | List policies. |
| `chainwall policies get ID` | Read criteria and optional policy program. |
| `chainwall accounts list` | List Registry-managed accounts. |
| `chainwall safes list` | List Registry-managed Safes. |
| `chainwall orgs list` | List organizations. |
| `chainwall contracts list` | List contract catalog entries. |
| `chainwall tokens list` | List token catalog entries. |
| `chainwall interactions list` | List interactions. |
| `chainwall compile FILE.ls` | Compile a program. |
| `chainwall interactions compile FILE.ls` | Produce a compiler artifact for review. |
| `chainwall interactions add FILE.ls` | Compile and publish a new interaction. |
| `chainwall interactions update FILE.ls` | Compile and update an existing interaction. |
| `chainwall interactions activate NAME_OR_ID` | Activate an interaction. |
| `chainwall interactions deactivate NAME_OR_ID` | Deactivate an interaction. |
| `chainwall decompile FILE` | Reconstruct source from JSON or hex bytecode. |
| `chainwall disasm FILE` | Produce a lossless instruction listing; `--source` shows readable Lambdascript. |
| `chainwall interactions source ID` | Display cached or live interaction source. |
| `chainwall abi ADDRESS` | Fetch/cache a verified ABI. |
| `chainwall timelocks list` | List cached governance action history. |
| `chainwall timelock pending` | Read the pending governance queue. |
| `chainwall timelock get ID` | Read one governance action. |
| `chainwall timelock approve ID` | Approve a governance action. |
| `chainwall timelock execute ID` | Execute an eligible governance action. |
| `chainwall timelock cancel ID` | Cancel an action when authorized. |
| `chainwall timelock expire ID` | Record an eligible action’s expiry. |
| `chainwall kv connect ADDRESS --secret-file FILE` | Import access to an existing journal. |
| `chainwall kv create` | Create indexed journal storage through the configured factory. |
| `chainwall operations list` | Unlock and list cached proposals. |
| `chainwall registry METHOD` | Call a method in the embedded Registry ABI. |
| `chainwall artifacts` | Export the Registry compiler reference. |
| `chainwall artifacts CONTRACT` | Export one embedded contract artifact. |
| `chainwall artifacts storage` | Export auxiliary storage/execution artifacts. |
| `chainwall id NAME_OR_ID` | Hash a name or normalize a nonzero bytes32 ID. |

### Method groups

Use `chainwall GROUP --help` for the complete method list in a group:

| Group | Area |
| --- | --- |
| `users`, `groups` | Participant and group directory. |
| `policies`, `policy-state` | Approval criteria, policy programs, and policy state. |
| `accounts`, `safes` | Managed addresses and related configuration. |
| `orgs`, `contracts`, `tokens` | Organization and asset catalog. |
| `interactions`, `interaction-sync` | Program bundles and catalog synchronization. |
| `metadata` | Entity metadata. |
| `capabilities`, `roles`, `ownership` | Administrative authority and ownership. |
| `timelock` | Queued governance, delays, release and upgrade workflows. |
| `terms` | Published terms and onchain acceptance. |
| `auth` | Registry authorization configuration. |
| `sync`, `sync-query` | Onchain catalog synchronization and query methods. |
| `token-commits` | Token commitment workflows. |
| `emergency` | Emergency controls supported by the deployment. |
| `diamond`, `facets` | Registry composition, ownership/roles, and facet methods. |
| `registry` | The union of embedded Registry methods. |

Bare `chainwall sync` is the local database synchronization command.
For the onchain sync methods, use `chainwall registry --help` or a specific
`chainwall sync METHOD --help`. Contract-to-contract catalog synchronization and local
SQLite synchronization are different operations.

### Options by task

| Option | Applies to / meaning |
| --- | --- |
| `--help`, `-h` | Help for the selected command. |
| `--version`, `-V` | Version text. |
| `--config-dir PATH` | Configuration, database, and ABI-cache directory. |
| `--profile NAME` | Profile for this invocation. |
| `--chain NAME_OR_ID` | Execution chain. |
| `--rpc-url URL` | Execution-chain RPC override. |
| `--instance ADDRESS` | Registry override. |
| `--account NAME` | Foundry account selection. |
| `--keystore PATH` | Explicit Foundry keystore path. |
| `--password-file FILE` | Foundry signing password. |
| `--from ADDRESS` | Explicit caller/sender address. |
| `--unlocked` | Select an RPC-managed signer; requires `--from`. |
| `--json` | Structured output where supported. |
| `--dry-run` | Transaction calldata preview. |
| `--args-file FILE` | JSON arguments for a generic ABI method. |
| `--arg-PARAMETER VALUE` | Named argument for a generic ABI method. |
| `--value AMOUNT` | Native value for a payable Registry method. |
| `--block NUMBER_OR_TAG` | Pin applicable RPC reads or the Registry sync snapshot. |
| `--start N`, `--count N` | List pagination. |
| `--offline` | Require cached entity data; also accepted by operations listing. |
| `--live` | Bypass an entity cache. |
| `--only DATASETS` | Comma-separated sync selection. |
| `--full` | Rebuild selected sync snapshots. |
| `--from-block N` | Explorer discovery lower bound. |
| `--lookback N` | Explorer overlap in blocks, default 128. |
| `--confirmations N` | Sync block distance behind latest, default zero. |
| `--passphrase-file FILE` | Local vault passphrase for KV/operations work. |
| `--secret-file FILE` | KV shared secret on connect, or optional explicit secret on create. |
| `--safe ADDRESS` | Operation-proposal managed-address filter. |
| `--status STATUS` | Operation status filter. |
| `--all-chains` | Include all readable proposal execution chains. |
| `--out FILE` | Save compiler JSON, publication JSON, or a fetched ABI, according to command. |
| `--settings FILE` | Compiler/decompiler settings. |
| `--optimization size\|baseline` | Compiler optimization mode. |
| `--argument-context frame\|subject` | Source argument context. |
| `--snapshot FILE` | Offline Registry kind and ABI metadata. |
| `--abi TARGET=FILE` | Explicit ABI, repeatable for different targets. |
| `--no-preprocess` | Compile already-lowered core source. |
| `--refresh-abi` | Bypass downloaded ABI cache. |
| `--etherscan-url URL` | Override Etherscan-compatible endpoint. |
| `--id NAME_OR_ID` | Interaction ID override for publication. |
| `--flags INTEGER` | Replace interaction bundle flags. |
| `--linked-file FILE` | Replace interaction bundle linked entries. |

Use each option with the task described in the table. Check the specific command's
`--help` output for its accepted options.

## 23. Glossary

| Term | Meaning in this manual |
| --- | --- |
| ABI | Contract interface describing function and data encoding. |
| Actor | The address whose authority applies to an action. |
| Argument context | The source of `$argN` values, normally the current frame or a policy subject. |
| Bundle | An interaction’s ID, bytecode, flags, and linked entries. |
| Calldata | Encoded function selector and arguments submitted to a contract. |
| Capability | A protocol-specific power, usually granted through groups. |
| Chain ID | Numeric network identifier checked against the RPC. |
| Checkpoint | Block and cursor recorded for a successfully synced dataset. |
| Ciphertext | Encrypted data, unreadable without the corresponding secret. |
| Compare-and-swap | An update requiring that the previous value/hash still matches what was reviewed. |
| Execution chain | Chain on which the Registry and proposed operation execute. |
| Facet | A module supplying part of the Registry’s contract interface. |
| Foundry account | A local signing keystore handled by `cast`. |
| Frame | The current program invocation and its arguments. |
| Gas | Native currency cost of executing a transaction. |
| Journal | KV records carrying encrypted proposal information. |
| Keccak | Hash function used to derive IDs and content hashes here. |
| KV | Key/value contract storage; here, PasswordGatedKV. |
| Linked entry | Relation ID and payload associated with an interaction bundle. |
| Local vault | Encrypted secret records in the CLI’s SQLite database. |
| Managed vault | An onchain account or Safe controlling assets; distinct from the local secret vault. |
| MiniScript | Bytecode format interpreted by Chainwall’s execution engine. |
| Operation | An interaction execution or proposal handled by Interact. |
| Policy | Group approval requirements and optional program conditions. |
| Profile | A named TOML set of connection and signer defaults. |
| Registry | The selected instance’s onchain configuration and catalog. |
| Reorganization | A change to which blocks form the canonical chain. |
| RPC | Provider interface used to read chain state and submit transactions. |
| Signer | A key/account used to authenticate a transaction or cryptographic message. |
| Snapshot | Local data representing a particular observed block. |
| Stable ID | An index identifier that is distinct from page position and an entity’s key. |
| Storage chain | Chain hosting the encrypted journal’s KV contract. |
| Timelock | Governance mechanism separating a queued action from its later execution. |
| Wei | Smallest integer unit used for native EVM currency values. |

Event discovery supports `sync --log-source auto|rpc|explorer`. The default
`auto` uses a configured explorer, falling back to RPC when it is unavailable;
without an explorer API key it uses RPC directly. Explicit `rpc` requires no API
key. Ranges are bounded and split when the provider rejects their size. A
single-block overflow fails without replacing the snapshot. Both backends verify
log block hashes against the selected RPC; the checkpoint records the source used.

Standalone terms verification is available with
`chainwall terms document IPFS_URI SHA256_DIGEST --document-file FILE --offline`.
With all three inputs, the command performs no network reads and reports
`publicationStatus: "not-checked"`. It checks the exact local bytes against the
caller-supplied SHA-256 digest, including their line endings; acceptance and
publication checks remain separate online operations.

To finish a prepared or mined proposal file after interruption, run
`chainwall operations reconcile FILE --proposal-tx HASH`. The hash can be omitted
when the file already contains the receipt or proposal hash. Reconciliation reads
canonical transaction evidence and restores the final operation ID and creation
timestamp without signing or broadcasting. The default atomically updates FILE;
`--out NEW_FILE` writes separately and `--dry-run` only previews. Repeating the
same reconciliation produces the same proposal bytes. Direct `propose`
transactions are supported; wrapped transaction envelopes are rejected.

Cached views expose the common `cache` / `cacheByDataset` metadata described in
[CLI.md](CLI.md). Its `source`, `checkpoint`, `freshness`, `statusBlock`, and
`completeness` fields distinguish discovery from separately checked status.
Offline reads retain the snapshot's block and never claim current head freshness.
Unknown checkpoints, status blocks and verified coverage bounds are explicit
`null` values. Existing command-specific checkpoint fields remain compatible.
