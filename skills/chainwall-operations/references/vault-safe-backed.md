# Setup: the same vault as a guarded Safe with two owners

Extends [usdc-aave-vault](usdc-aave-vault.md). Read `../SKILL.md`,
that setup, and [execution.md](execution.md) ("Guarded Safe
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


## Network

The network is the one the vault was built on. On Sepolia test mode, take
USDC, Pool, factory, RPC and balance floors from `networks.sepolia` in
[usdc-aave-vault setup.json](../assets/usdc-aave-vault/setup.json) and read
every "Arbitrum One" and ETH figure below as its Sepolia equivalent, exactly
as the vault setup's Network section says. Test USDC comes from the Aave
faucet there, not from the user.

## Prerequisites

This setup layers on the vault from [usdc-aave-vault.md](usdc-aave-vault.md),
and it builds that vault itself when it is missing. Run the vault setup's
Resume table against the active profile:

- No instance bound, or any of the vault's steps 1 to 8 not done: run
  [usdc-aave-vault.md](usdc-aave-vault.md) now, steps 1 to 8 and its checks 1
  to 3, and skip its step 9 (delays) for the moment. Then come back here; the
  vault's step 10 reads run once, at the very end.
- Steps 1 to 8 done and delays still at zero: continue here directly. This is
  the fast path.
- Any delay already live (a category reads 86400): Registry writes in that
  category return `queued` and apply 24 hours later. Say so first. A write
  whose dependency is still queued cannot be queued yet (token record after
  its contract version, program and interactions after their policy and
  catalog entries), so the build takes one 24 hour round per dependency
  level. Each round: send the writes that are ready, record every `actionId`
  and `eta`, and stop with the remaining steps listed; resume with
  `timelock execute-action` after `eta`.

Tell the user which of the three cases applies before the first write.

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

The vault setup's [supply.ls](../assets/usdc-aave-vault/supply.ls),
[withdraw.ls](../assets/usdc-aave-vault/withdraw.ls), [payout.ls](../assets/usdc-aave-vault/payout.ls)
and [policy.ls](../assets/usdc-aave-vault/policy.ls), with `{{policyId}}` = the safe
policy id, `{{vault}}` = the Safe address, and the three new interaction ids in
`policy.ls`. Compile exactly as the vault setup says.

## Order

1. `safes create --salt "usdc-aave-vault safe v1" --owners OWNER,OWNER2 --threshold 2 --dry-run`,
   show the predicted address, send. Read `safes inspect SAFE`: owners,
   threshold 2, guard set, registered; `modules` lists only Interact (the
   execution module), not the OKModule.
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
vault-safe-backed-verify.md.

## Finish

Append to the vault's record file (`usdc-vault-record.md`, on Sepolia
`usdc-vault-sepolia-record.md`; create it if missing): Safe address, owners, threshold, guard,
policy and interaction ids, every transaction hash, and the signature files
used for the test operation. State: the Safe can only act through Interact;
both owners sign every operation; the owner set cannot be changed from inside
the Safe.

Then finish the vault's protection if it is still open: if the vault setup's
step 9 delays are not set (`timelock get-category-config` on the full category
names reads `[[0,…]]`), run that step 9 now, exactly as the vault setup
describes, so the tenant does not stay without delays (if `config` is already
delayed these writes queue too; record their ids). Record the result.
