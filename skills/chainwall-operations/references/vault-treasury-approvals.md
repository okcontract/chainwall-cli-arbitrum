# Setup: treasury payouts with two approvals, fixed recipients and a monthly budget

Extends [usdc-aave-vault](usdc-aave-vault.md). Read `../SKILL.md`
and that setup first; their rules apply. Take every flag from
`chainwall <command> --help --json`.

## Outcome

The vault can pay USDC to exactly two fixed recipients. Each payout needs
approval from 2 of 3 people, is capped at 1000 USDC, and all payouts together
are capped at 5000 USDC per 30 day window by a Registry policy meter. A payout
to any other address is impossible: there is no interaction for it, and the
Lambdascript recipient is a literal, not an argument. The vault setup's
owner-only `usdc-vault-payout` interaction is deactivated in step 8, so the
owner alone can no longer pay anyone; until step 8 runs it still can.


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
  to 3, and skip its step 9 (delays) for the moment. Then come back here.
- Steps 1 to 8 done and delays still at zero: continue here directly. This is
  the fast path.
- Delays already live (86400): every Registry write below returns `queued` and
  applies after 24 hours. Say so first, collect each `actionId` and `eta`,
  execute them with `timelock execute-action` after `eta`, and continue only
  when the read-back shows the change.

Tell the user which of the three cases applies before the first write.

## Inputs

Ask the user for:

- Two approver addresses, APPROVER2 and APPROVER3, with their Foundry keystore
  names if they sign on this machine (otherwise they approve from their own
  machines with `chainwall operations approve OPID --account NAME`). Each needs
  about 0.0002 ETH on Arbitrum One for approval transactions.
- Two recipient addresses with a short lowercase label each, for example
  `payroll` and `vendor`.

Defaults: per payout cap 1000 USDC (`1000000000`), 30 day budget 5000 USDC
(`5000000000`), threshold 2 of 3.

## Mechanics the user should hear first

- Approval is live group membership: `approveOperation` and execution recheck
  that approvers are members of the policy's group at execution time. Removing
  a member later invalidates their approval.
- A proposer who is a group member approves on creation (`Interact.sol`,
  `_createProposedOperation`), so the owner's proposal counts as 1 of 2; one
  more member must `operations approve OPID`.
- The 30 day budget uses `consumePolicyMeter` with window `2592000`; buckets are
  `block.timestamp / 2592000`, fixed windows since the epoch, not calendar
  months.
- Recipients are fixed in the script. Changing a recipient means publishing a
  new interaction, which is a Registry write under `timelock.category.interaction`.

## Names

| Thing | Name |
| --- | --- |
| Group (owner, APPROVER2, APPROVER3) | `usdc-vault-treasury` |
| Policy, criteria `[usdc-vault-treasury]`, thresholds `[2]` | `usdc-vault-treasury-policy` |
| Interactions | `usdc-vault-pay-<label>` for each recipient |
| Meter id | `usdc-vault-treasury-monthly` |

Compute every id with `chainwall id NAME`. Catalog: the existing `circle/usdc`.

## Scripts

[pay.ls](../assets/vault-treasury-approvals/pay.ls) is one template per recipient: fill `{{policyId}}`,
`{{vault}}`, `{{recipient}}`, save as `pay-<label>.ls`. [treasury-policy.ls](../assets/vault-treasury-approvals/treasury-policy.ls)
takes `{{policyId}}`, `{{vault}}`, `{{payAId}}`, `{{payBId}}`, `{{meterId}}`,
`{{cap}}`, `{{monthlyLimit}}`, `{{registryWord}}` (Registry address as a 32 byte
word, as in vault-bot-operator). Compile each `pay-*.ls` with
`--abi circle/usdc=erc20.json`; selector `0xa9059cbb`. Compile the program with
`policies program compile`.

## Order

1. `users add` APPROVER2 and APPROVER3 (the owner is already a user).
2. `groups create-group` `usdc-vault-treasury`; `groups add-group-member` for
   the owner, APPROVER2, APPROVER3.
3. `policies create-policy` `usdc-vault-treasury-policy`, groups `[GROUP]`,
   thresholds `[2]`.
4. Compile and analyze; show results.
5. `policies program publish usdc-vault-treasury-policy treasury-policy.json`.
6. `interactions add pay-<label>.ls --id usdc-vault-pay-<label> --abi circle/usdc=erc20.json`
   for each recipient.
7. `capabilities grant-capability-group` of `chainwall id cap.registry.interaction.execute`
   to the treasury group.
8. `interactions deactivate usdc-vault-payout` (after the test payout in the
   verify file, so the owner's own route is closed last). It sends
   `setInteractionActive(bundleHash, id, false)` in the
   `timelock.category.activation` category: immediate while that delay is 0,
   `queued` once the vault's step 9 delays are live (then `timelock execute-action`
   after the delay). Read back `registry get-interaction-flags` of
   `chainwall id usdc-vault-payout`: bit 1 (`INACTIVE`) set. Skip with a note
   if the user wants to keep the owner payout.

Verify each step on chain before the next.

## Signing and pauses

Dry-run every write, show it, send with the owner's `--account`. Pause for
the user's yes before step 7, before the real payout in
vault-treasury-approvals-verify.md, and before step 8.

## Finish

Append to `usdc-vault-record.md`: group members, policy and interaction ids,
recipients, caps, meter id, every transaction hash, and the approval sequence
of the test payout. State: payouts go only to the two listed addresses, need
two of three approvals, and are limited to 1000 USDC each and 5000 USDC per
30 day window; the owner-only payout is deactivated (or say that it was kept).

Then finish the vault's protection if it is still open: if the vault setup's
step 9 delays are not set (`timelock get-category-config` on the full category
names reads `[[0,…]]`), run that step 9 now, exactly as the vault setup
describes, so the tenant does not stay without delays. Record the result.
