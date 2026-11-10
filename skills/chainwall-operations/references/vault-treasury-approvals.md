# Setup: treasury payouts with two approvals, fixed recipients and a monthly budget

Extends [usdc-aave-vault](usdc-aave-vault.md). Read `../SKILL.md`
and that setup first; their rules apply. Take every flag from
`chainwall <command> --help --json`.

## Outcome

The vault can pay USDC to exactly two fixed recipients. Each payout needs
approval from 2 of 3 people, is capped at 1000 USDC, and all payouts together
are capped at 5000 USDC per 30 day window by a Registry policy meter. A payout
to any other address is impossible: there is no interaction for it, and the
Lambdascript recipient is a literal, not an argument. The owner alone can no
longer pay anyone.


## Network

The network is the one the vault was built on. On Sepolia test mode, take
USDC, Pool, factory, RPC and balance floors from `networks.sepolia` in
[usdc-aave-vault setup.json](../assets/usdc-aave-vault/setup.json) and read
every "Arbitrum One" and ETH figure below as its Sepolia equivalent, exactly
as the vault setup's Network section says. Test USDC comes from the Aave
faucet there, not from the user.

## Prerequisites

Vault setup steps 1 to 8 done. If the policy, group, interaction or
capability delays are live, every write below returns `queued`; collect
`actionId` and `eta`, execute after `eta` with `timelock execute-action`, then
continue. Say so before starting.

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

Verify each step on chain before the next.

## Signing and pauses

Dry-run every write, show it, send with the owner's `--account`. Pause for
the user's yes before step 7 and before the real payout in vault-treasury-approvals-verify.md.

## Finish

Append to `usdc-vault-record.md`: group members, policy and interaction ids,
recipients, caps, meter id, every transaction hash, and the approval sequence
of the test payout. State: payouts go only to the two listed addresses, need
two of three approvals, and are limited to 1000 USDC each and 5000 USDC per
30 day window.
