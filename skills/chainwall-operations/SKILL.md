---
name: chainwall-operations
description: Set up and operate Chainwall vaults, Safes, and onchain automation on Arbitrum through the native CLI. Use for tenant onboarding, holdings reports, Lambdascript interactions, approval policies, execution, and operational recovery.
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
Confirm Arbitrum One (chain ID `42161`) and the intended Registry in the selected
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
