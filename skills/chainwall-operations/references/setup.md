# Install and configure

Use a verified Chainwall CLI distribution or build this repository. Binary
users need Foundry's `cast` on PATH for wallet handling and transaction commands.
The Safe owner-signature example also uses `jq` to collect JSON signature files.
Check `chainwall --version` and command help before following a workflow.

For a source checkout, read the root `README.md`, then build with Zig 0.17.0:

```sh
zig build -Doptimize=safe
zig build test
export PATH="$PWD/zig-out/bin:$PATH"
chainwall --version
cast --version
```

`chainwall` includes Registry preprocessing and operational tools. `miniscript`
is the lower-level compiler for already-resolved core source. The optional
`chainwall-lsp` supports editors; no editor is required for CLI workflows.

## Connect an existing tenant

Use Arbitrum One (chain ID `42161`). Obtain its RPC and the Registry or
SafeFactory instance address from existing project configuration or the user.
For an isolated new project:

```sh
umask 077
export CHAINWALL_CONFIG_DIR="$PWD/.chainwall"
chainwall profile create treasury
chainwall profile use treasury
chainwall config set chain 42161
chainwall config set rpc_url "$RPC_URL"
chainwall login "$REGISTRY_ADDRESS"
chainwall config show
chainwall status --json
```

Reuse an existing profile instead of recreating it. Keep `.chainwall`, private
proposal files and password files out of source control. `config show` is
redacted; `config export` can contain the app's shared secret.

Login verifies chain ID and component bindings. A SafeFactory login discovers
Interact and Registry. A direct Registry login clears an old Interact binding
when switching tenants; discover the correct Interact from deployment/topology
records and set `chainwall config set interact "$INTERACT_ADDRESS"` if needed.
Generic `--instance` overrides expect the Registry, not the SafeFactory.
Inspect `status` errors and nulls, not just process success.

For an existing app deployment, `chainwall config import app-config.json`
imports its supported configuration, including secrets when present. Inspect
the selected profile afterward. A KV journal is optional for local operations.

```sh
chainwall sync --only users,groups,policies,contracts,tokens,interactions
chainwall accounts list
chainwall safes list
chainwall timelock pending
```

Cached lists represent their checkpoint block. Use live method reads and fresh
simulation for decisions. Unindexed enumeration can require an Etherscan token
and the correct deployment log range; an empty old cache proves little.

## Deploy a tenant when requested

The CLI deploys through an existing compatible OKFactory. It does not provision
global factory infrastructure. Verify the selected factory/network and obtain
the exact initial terms document. Source builds and binary distributions embed
factory defaults only for Arbitrum One (`42161`); confirm the intended target
against the original Chainwall contracts published by OKcontract Pte. Ltd.

```sh
chainwall deploy --factory "$OK_FACTORY_ADDRESS" --owner "$OWNER_ADDRESS" \
  --salt "$DEPLOYMENT_SALT" --indexing --no-auth-accounts --dry-run
chainwall deploy --factory "$OK_FACTORY_ADDRESS" --owner "$OWNER_ADDRESS" \
  --salt "$DEPLOYMENT_SALT" --indexing --no-auth-accounts \
  --account bootstrap --out deployment.json --json
```

Choose `--auth-accounts` instead when the tenant needs passkeys. Do not combine
named deployment flags with numeric `--flags`. Save all receipts. The stages
are bootstrap, prepare, finalize; the all-stage preview shows bootstrap and
lists dependent stages. If interrupted, inspect the records before resuming
only the missing `--stage prepare` or `--stage finalize` with `--registry`.
Finalization saves the tenant connection; it does not accept terms or close
the owner's temporary governance bootstrap.

```sh
chainwall terms get-terms-context
chainwall terms document --document-file factory-terms.md
chainwall terms accept-terms --document-file factory-terms.md --dry-run
```

If accepting these exact terms is authorized, submit the same acceptance with
an admin signer, then check `terms instance-has-accepted-initial-terms`.
The CLI verifies SHA-256 document identity. Do not use legacy current-version
terms commands or assume deployment accepted the terms.

## Users, policies, and managed vaults

Use Foundry keystore names with `--account`; import keys interactively through
Foundry when needed. `--password-file` unlocks a keystore. `--from` supplies a
caller and does not authorize signing. `--unlocked --from` is for an explicitly
selected RPC-managed account, typically a disposable Anvil fixture.

Apply and verify each prerequisite before the next dependent write:

```sh
chainwall users contains "$APPROVER1"
chainwall users add "$APPROVER1" --account administrator
chainwall users add "$APPROVER2" --account administrator
GROUP_ID=$(chainwall id treasury)
POLICY_ID=$(chainwall id treasury-two)
chainwall groups add "$GROUP_ID" --account administrator
chainwall groups add-member "$GROUP_ID" "$APPROVER1" --account administrator
chainwall groups add-member "$GROUP_ID" "$APPROVER2" --account administrator
chainwall policies add "$POLICY_ID" "[$GROUP_ID]" '[2]' --account administrator
chainwall policies get "$POLICY_ID"
```

Skip existing records rather than replaying creation. Positional arrays above
use Foundry syntax; named flags and JSON files require proper JSON. Group
thresholds apply to live members, and every criterion must be satisfied.
Registration, group membership, and administrative capabilities are distinct.
Inspect `capabilities --help` and the deployment's grants; execution uses the
protocol capability `cap.registry.interaction.execute`. Grant only the powers
required for the requested actors. Bootstrap owners do not universally bypass
role governance or capability gates.

```sh
chainwall accounts create --salt "$VAULT_SALT" --account creator --json
chainwall accounts inspect "$VAULT_ADDRESS"
chainwall safes create --salt "$SAFE_SALT" --owners "$OWNER1,$OWNER2" \
  --threshold 2 --account creator --json
chainwall safes inspect "$SAFE_ADDRESS"
```

Choose one vault type. Account/Safe creation verifies the tenant factory and
bindings; raw `accounts add`/`safes add` only change admission. Safe creation
installs the guard/gateway. Existing Safe migration has an import and signature
workflow: use `safes import --help` and the manual, retaining ownership,
threshold, module and guard review. Never equate raw registration with migration.

Before funding a new production tenant, complete the requested authority
handover, council/recovery setup and timelock configuration. Inspect ownership,
roles, capabilities, `ownerBootstrapFinalized`, and live council membership.
Keep a usable execution and recovery path; configure delays after prerequisites
so setup does not queue behind rules it has only partly installed.
