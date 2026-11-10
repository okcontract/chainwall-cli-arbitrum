# Setup: change the vault's per-operation cap (timelocked policy change)

Extends [usdc-aave-vault](usdc-aave-vault.md). Read `../SKILL.md`
and that setup first; their rules on signer, profile, dry runs and "never
invent a command" apply. Take every flag from `chainwall <command> --help --json`.

## Outcome

The vault's policy program is replaced so each operation may move up to
`{{newCap}}` USDC base units instead of 100 USDC (`100000000`). If the
`timelock.category.policy` delay is live, the change is queued and applies only
after the delay; the setup proves the old cap holds until then, then executes
or cancels the queued action. This is the smallest real example of a
timelocked rule change.


## Network

The network is the one the vault was built on. On Sepolia test mode, take
USDC, Pool, factory, RPC and balance floors from `networks.sepolia` in
[usdc-aave-vault setup.json](../assets/usdc-aave-vault/setup.json) and read
every "Arbitrum One" and ETH figure below as its Sepolia equivalent, exactly
as the vault setup's Network section says. Test USDC comes from the Aave
faucet there, not from the user.

## Prerequisites (read, do not write)

Run the Resume table of the vault setup. Required: instance bound in the
active profile, policy `usdc-vault-policy` with a published program, the three
interactions present. Read
`timelock get-category-config $(chainwall id timelock.category.policy)` and
record whether the delay is `0` (change applies at once) or `86400` (queued).

Ask the user for one value: the new cap in USDC. Default 500 USDC
(`500000000`). Nothing else.

## Mechanics the user should hear first

- A policy program change is a Registry write in `timelock.category.policy`
  (`RegistryPolicyStateFacet`/`RegistryPoliciesFacet` route every policy write
  through `TimelockLib.enforceOrQueue`). With the delay live, the write returns
  `status: queued` with an `actionId` and `eta`; nothing changes until someone
  executes the action after `eta`, and the action expires `gracePeriod`
  (604800 s) after `eta`.
- Execution is permissionless once ready: `executeAction` checks status `Ready`,
  `block.timestamp >= eta`, and approvals for the action's policy id; the
  category's `defaultPolicyId` is `0x0`, so no approvals are needed.
- Cancellation is allowed only while the action is `Queued` or `Ready`, by the
  actor who queued it, an `ADMIN_ROLE` holder, or a `cap.registry.timelock.cancel`
  holder.
- Operation payload hashes bind the policy program hash. Any proposal created
  before the change becomes unexecutable after it and must be re-proposed.
- `setPolicyProgram` on a policy also stales approvals on queued actions that
  reference it; there are none in this setup.

## Names

Existing: policy `usdc-vault-policy`, interactions `usdc-vault-supply`,
`usdc-vault-withdraw`, `usdc-vault-payout`, vault `{{vault}}`. Compute ids with
`chainwall id NAME`.

## Script

[policy.ls](../assets/vault-change-cap/policy.ls) is the vault setup's program with `{{cap}}` in place of
`100000000`. Fill `{{policyId}}`, `{{vault}}`, `{{supplyId}}`, `{{withdrawId}}`,
`{{payoutId}}`, `{{cap}}`; no comments in `.ls`. Compile:

```sh
chainwall policies program compile policy.ls --out policy.json
```

It must be valid and complete with no external calls.

## Order

1. Record the current program hash: `registry get-policy-program POLICY`.
2. Prove the old cap: `policies program simulate usdc-vault-policy ctx.json`
   with a `policy-context` for `usdc-vault-supply`, args `["200000000"]`,
   actor OWNER, vault VAULT, operationId 0, zero payloadHash. It must reject.
3. `policies program publish usdc-vault-policy policy.json --dry-run`, show it,
   then send with `--account NAME`.
   - Delay `0`: the result is `confirmed`; go to step 6.
   - Delay live: the result is `status: queued` with `actionId` and `eta`.
     Record both. Read `timelock get-action-summary ACTIONID`: status
     `Queued`, `eta`, `expiresAt`, category = `chainwall id timelock.category.policy`.
4. Prove the old cap still holds: repeat step 2; it must still reject. Read
   `registry get-policy-program POLICY`: unchanged hash.
5. Wait until `eta` (read chain time with `cast block latest -f timestamp`).
   Then `timelock execute-action ACTIONID --dry-run`, send it, and read the
   summary: status `Executed`. Before `eta` the same call must revert
   `TimelockActionNotReady`; show that once as proof, then wait.
   To abandon instead: `timelock cancel-action ACTIONID` (only while Queued or
   Ready), then confirm status `Cancelled` and the program hash unchanged.
6. Prove the new cap: step 2's context with `["200000000"]` now passes, and
   `["{{cap}} + 1"]` rejects. `registry get-policy-program POLICY` shows the new
   hash, equal to the `bytecodeHash` in `policy.json`.
7. Tell the user: proposals made before this change must be re-proposed.

## Signing and pauses

Dry-run every write, show it, send with `--account NAME`. Pause for the user's
yes once: before step 3's send. Never print keys or passwords.

## Finish

Append to `usdc-vault-record.md`: old and new program hash, `actionId`, `eta`,
`expiresAt`, every transaction hash, the three simulation results, and whether
the change was executed or cancelled.
