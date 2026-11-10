---
name: chainwall-operations
description: Set up and operate Chainwall vaults, Safes, and onchain automation on Arbitrum One through the native CLI. Use for tenant onboarding, holdings reports, Lambdascript interactions, approval policies, execution, operational recovery, and complete builds such as a guarded USDC vault on Aave v3, a bot operator with a daily budget, two-approval treasury payouts, an emergency exit, a guarded Safe, a timelocked cap change, putting a protocol's admin role behind Chainwall, an ETH treasury that wraps to WETH and pays fixed recipients, a Uniswap v3 swap desk, a token issuer with a metered minter, or tenant governance (guardians, approved rule changes, tiered delays, delegated admin, admin rotation, owner handover).
---

# Operate Chainwall

Use the `chainwall` executable built from this repository's root, or an installed
Chainwall CLI distribution. These instructions also work in projects that use
an installed binary.

## Establish the task

Identify the requested outcome, chain, Registry, managed vault, authorized
actor, and whether the user wants preparation, simulation, or execution. Reuse
existing configuration and authorization. Ask only for missing information that
blocks the next step. Setup work does not authorize unrelated asset movements,
new administrators, terms acceptance, or recurring jobs.

Start with `chainwall --version`, `chainwall --help`, and `chainwall config show`.
Confirm Arbitrum One (chain ID `42161`), or Ethereum Sepolia (`11155111`) when a
setup's test mode is requested, and the intended Registry in the selected
profile. Use explicit profiles for separate tenants and preserve existing
configuration; use `CHAINWALL_CONFIG_DIR` for an isolated project when needed.
All relative reference and asset paths below are relative to this skill folder,
not the working directory.

## Choose the workflow

- Installation, existing-instance login, tenant deployment, users, groups, or
  vault setup: read [setup.md](references/setup.md).
- Writing, importing, analyzing, or publishing interactions and policies: read
  [authoring.md](references/authoring.md). It includes editable transfer and
  spending-policy templates.
- Proposing, approving, simulating, or executing an operation, including Safe
  owner signatures: read [execution.md](references/execution.md).
- Portfolio reporting, unattended operation, journal sharing, passkeys,
  recovery, or upgrades: read [operations.md](references/operations.md).
- A complete end-to-end build with fixed inputs: open the matching reference
  after reading this file. [usdc-aave-vault.md](references/usdc-aave-vault.md)
  builds a guarded USDC vault that can only supply to and withdraw from Aave
  v3 and pay out to its owner. Extensions of that vault, each reusing its
  instance and catalog, and each building the vault first when it is missing: [vault-change-cap.md](references/vault-change-cap.md)
  (a timelocked change of the per-operation cap),
  [vault-bot-operator.md](references/vault-bot-operator.md) (a bot key with a
  daily meter and the Registry pause as kill switch),
  [vault-treasury-approvals.md](references/vault-treasury-approvals.md)
  (2-of-3 payouts to fixed recipients with a 30 day meter),
  [vault-emergency-exit.md](references/vault-emergency-exit.md) (one
  owner-only exit to a cold address, plus pause),
  [vault-safe-backed.md](references/vault-safe-backed.md) (the same vault as a
  guarded Safe with two owners). [protocol-admin.md](references/protocol-admin.md)
  puts a protocol's owner role behind a Chainwall account, with routine
  parameter changes separated from delayed sensitive changes. Standalone
  builds that do not involve Aave or USDC, each on its own instance:
  [eth-treasury.md](references/eth-treasury.md) (an ETH treasury that wraps
  to and unwraps from WETH and pays WETH to fixed recipients under a cap),
  [swap-desk.md](references/swap-desk.md) (a desk that can only swap WETH
  and USDC through Uniswap v3 back to itself, with a minimum-out argument),
  [token-issuer.md](references/token-issuer.md) (a demo ERC-20 whose minter
  is metered per 24 hours and whose burn and pause stay owner-only). Governance
  setups change who may change the rules; they share
  [governance.md](references/governance.md) and need no vault:
  [gov-guardians.md](references/gov-guardians.md) (a group that can pause and
  cancel but not act), [gov-approved-changes.md](references/gov-approved-changes.md)
  (rule changes need approvals plus a delay),
  [gov-tiered-delays.md](references/gov-tiered-delays.md) (a longer delay for
  constitutional changes), [gov-delegated-admin.md](references/gov-delegated-admin.md)
  (narrow groups for routine admin jobs),
  [gov-admin-rotation.md](references/gov-admin-rotation.md) (add or replace an
  admin through a delayed change), [gov-handover.md](references/gov-handover.md)
  (close the owner shortcut for good). Each
  has a companion `*-verify.md` and its templates under `assets/<name>/`.

Read only the relevant references. The installed manual is normally
`share/doc/chainwall/manual.md` beneath the distribution prefix; in a checkout,
use `MANUAL.md` at the repository root. Get exact command shapes from the binary:

```sh
chainwall registry upsertToken --help --json
chainwall registry upsertToken --schema
chainwall schemas list
chainwall schemas show operation-document
```

The embedded ABI describes what the client can encode; the selected tenant
must actually have the corresponding facets. Prefer current method help,
schemas, and contract behavior over an older prose example. Never invent a
convenient CLI subcommand, selector, tuple layout, deployment address, or policy
capability. Use `chainwall artifacts` for protocol artifacts.

## Check the signer first

The CLI signs through Foundry `cast` with a named keystore. Before the first
write, run `cast wallet list`:

- one keystore: use it, as `--account NAME` on every write.
- several: ask the user which one.
- none: stop and tell the user to run `cast wallet new NAME` (or
  `cast wallet import NAME --interactive`) in their own terminal.

Agent shells usually have no TTY, so Foundry cannot prompt for a password
there. Default: ask the user once for the keystore password, write it only to a
private temporary file (`mktemp`, mode 600, outside the project) with your
file-writing tool, pass that path as `--password-file` on every signing
command, and delete the file when the work ends. Never put the password in a
shell command, environment variable, script, log, report or memory, and never
repeat it back. Tell the user it will be visible in the chat and that a test
or dev wallet is the safer choice. If the profile already has a working
`password_file`, use it without asking and leave it in place; never open,
print, move or delete a password file you did not create. If the user declines
to share the password: on macOS they can enroll the keystore once with
`cast wallet touch-id enroll NAME` (each signature then asks for Touch ID), or
they run the signed commands in their own terminal when you hand them over.
Read the owner address with `cast wallet address --account NAME` (add
`--password-file` when you have one); if it cannot unlock the keystore, ask
the user for the address instead. Check any Foundry command with
`cast <command> --help` before showing it. The signer needs native currency for
gas.

## CLI behaviours to expect

These hold on the current CLI; none of them is a failed setup.

- RPC: a profile's `rpc.<chainId>` entry shadows `rpc_url`. To change the RPC
  set both: `config set rpc.<chainId> URL` and `config set rpc_url URL`.
  `config show` redacts the URL; for `cast --rpc-url` read it from the profile
  file under `~/.config/chainwall/`.
- `chainwall status` may report `"complete": false` (the `securityCouncil`
  read reverts) or `"status": "unavailable"` with `RpcHttpFailure`. Treat the
  instance as complete when `getInstance(address)` on the factory, called
  with the Registry address, returns a nonzero Interact.
- A write that ends in a bare `TransactionFailed` with no hash: read
  `cast nonce SIGNER`. Unchanged means nothing was broadcast; resend once.
  Changed means it was sent; recover the receipt, never resend. The same
  goes for a write that exits with "Recover with chainwall transactions
  wait HASH": the transaction is usually mined; read its receipt and state.
  `deploy` can stop between stages this way; resume with `--stage`.
- `accounts create` can exit `CreatedAccountMismatch` after a confirmed
  transaction. Check `accounts inspect` at the dry run's predicted address
  before any retry.
- A read straight after a confirmed write can be stale once; read again.
- Terms: `terms document --out terms.md` (add
  `--ipfs-gateway https://gateway.pinata.cloud/ipfs` if the default gateway
  fails), then `terms accept-terms --document-file terms.md`. The hash form
  downloads the document again and fails on the same gateway.
- `operations status` prints `approved: true|false`, not a count.
- `--out FILE` never overwrites. Name proposals `<name>-proposal.json` so
  they do not collide with a compiled `<name>.json`, and use a new name when
  resending after a failed attempt.
- If `deploy` exits before printing the Registry, run the same `deploy`
  again: it fails with `DeploymentAlreadyStarted` and prints the address.
- `operations withdraw ID` every test proposal you do not execute, so no
  approved operation stays open. If `operations propose` exits with an RPC
  error after broadcasting, its saved file is unusable: withdraw that
  operation and propose again under a new file name.

## Preserve the execution model

The Registry stores the catalog, membership, policy and governance state.
Interact checks an operation and its approvals. A managed OKAccount or guarded
Safe executes MiniScript against that catalog. An EOA operator, approval actor,
gas payer, vault, Registry and Interact can all be different addresses.

- Keep amounts, uint256 words and timestamps as exact integer strings in JSON.
  Obtain token decimals before converting amounts. Do not use floating point.
- Use actual IDs from the selected tenant. `chainwall id NAME` is public
  Keccak-256; it cannot reconstruct app-encrypted or opaque IDs from labels.
- Bind sensitive scripts to the intended policy and vault. Merely creating a
  policy does not attach it to every operation.
- `--dry-run` normally previews calldata. Explicit simulation checks a pinned
  chain state; neither proves that a later submission will succeed.
- Normal write commands broadcast. Honor authorization already provided for
  the concrete action; prepare the full artifact before seeking any missing
  authorization. Do not collect other people's approvals on their behalf.
- A `queued` write has not applied its intended change. Finish its Registry
  timelock before dependent steps. Interact operation approvals are separate.
- On an interrupted send, recover its receipt and state before retrying.
  Preserve output files, operation IDs, signatures and transaction logs.

Finish with evidence appropriate to the request: source and compiler artifact,
selected chain/Registry/vault, simulation block and result, transaction hashes,
actual operation/action IDs, applied or pending state, and verified asset or
configuration changes. State any remaining approvals, delay, or missing input.
