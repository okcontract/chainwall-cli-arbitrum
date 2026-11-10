# Recipe: the same vault as a guarded Safe with two owners

Extends [usdc-aave-vault](../usdc-aave-vault/SKILL.md). Read `../../SKILL.md`,
that recipe, and [execution.md](../../references/execution.md) ("Guarded Safe
execution") first; their rules apply. Take every flag from
`chainwall <command> --help --json`.

## Outcome

A Gnosis Safe with two owners and threshold 2, created by the tenant's Safe
factory with Chainwall's guard installed, holding USDC and running the same
three interactions (supply, withdraw, payout) as the OKAccount vault. Every
Safe transaction must go through Interact: the guard rejects any other call.
Both owners sign each operation, and the Registry policy is checked on top.
The Safe's owners can never change their own set, threshold, modules or guard
from inside the Safe (self-calls are blocked by the guard).

## Prerequisites

Vault recipe steps 1 to 8 done (the catalog and the approvers group are
reused). If delays are live, writes below return `queued`; collect `actionId`
and `eta`, execute after `eta`, continue. Say so first.

## Inputs

Ask for the second Safe owner: address OWNER2 and, if it signs on this machine,
its keystore name. OWNER2 needs no ETH: Safe owner signatures are off chain;
only the relayer (the owner's signer) pays gas. Nothing else.

## Mechanics the user should hear first

- `safes create` calls the tenant SafeFactory's `newSafe(salt, owners,
  threshold, fallbackHandler, installGuard, installModule)`. The caller must be
  a registered user. The guard is installed; with two owners the OKModule is
  not (`--module` requires a single owner at threshold 1). Creation registers
  the Safe in the Registry (`addSafe`) atomically, as with OKAccounts.
- `OKGuard.checkTransaction` allows only `CALL` to Interact's execution
  selectors or a `DELEGATECALL` to the singleton migrator, with zero refund
  parameters. Self-calls to the Safe are refused, so owners cannot be rotated
  from inside.
- Execution route: `operations sign-actor --via safe` (an actor holding the
  execute capability authorises the policy side), `operations sign --via safe`
  by each owner, then `operations simulate|execute --via safe` by a relayer
  with the actor signature and the owners' signatures. The Safe nonce changes
  on every execution, so signatures are per operation.
- Policy approval and Safe signatures are different checks. Here the owner is
  the sole approver (threshold 1) and both Safe owners must sign (threshold 2).

## Names

| Thing | Name |
| --- | --- |
| Safe salt | `usdc-aave-vault safe v1` |
| Policy, criteria `[usdc-vault-approvers]`, thresholds `[1]` | `usdc-vault-safe-policy` |
| Interactions | `usdc-vault-safe-supply`, `usdc-vault-safe-withdraw`, `usdc-vault-safe-payout` |

Compute every id with `chainwall id NAME`. Catalog: existing `circle/usdc` and
`aave/pool-v3`.

## Scripts

The vault recipe's [supply.ls](../usdc-aave-vault/supply.ls),
[withdraw.ls](../usdc-aave-vault/withdraw.ls), [payout.ls](../usdc-aave-vault/payout.ls)
and [policy.ls](../usdc-aave-vault/policy.ls), with `{{policyId}}` = the safe
policy id, `{{vault}}` = the Safe address, and the three new interaction ids in
`policy.ls`. Compile exactly as the vault recipe says.

## Order

1. `safes create --salt "usdc-aave-vault safe v1" --owners OWNER,OWNER2 --threshold 2 --dry-run`,
   show the predicted address, send. Read `safes inspect SAFE`: owners,
   threshold 2, guard set, no module, registered.
2. `policies create-policy` `usdc-vault-safe-policy`, groups
   `[usdc-vault-approvers]`, thresholds `[1]`.
3. Fill templates with the Safe address, compile, analyze, show results.
4. `policies program publish usdc-vault-safe-policy policy.json`.
5. `interactions add` each script with `--id usdc-vault-safe-<name>` and the
   two `--abi` flags.
6. Execution rights: `usdc-vault-approvers` already holds
   `cap.registry.interaction.execute`; confirm with
   `registry get-capability-groups CAP`.

## Signing and pauses

Dry-run every Registry write, show it, send with the owner's `--account`.
Pause for the user's yes before step 1's send and before the real supply in
verify.md.

## Finish

Append to `usdc-vault-record.md`: Safe address, owners, threshold, guard,
policy and interaction ids, every transaction hash, and the signature files
used for the test operation. State: the Safe can only act through Interact;
both owners sign every operation; the owner set cannot be changed from inside
the Safe.
