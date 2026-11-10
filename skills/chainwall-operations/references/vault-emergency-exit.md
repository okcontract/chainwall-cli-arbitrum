# Setup: emergency exit and kill switch for the vault

Extends [usdc-aave-vault](usdc-aave-vault.md). Read `../SKILL.md`
and that setup first; their rules apply. Take every flag from
`chainwall <command> --help --json`.

## Outcome

One owner-only interaction, `usdc-vault-exit`, pulls the vault's whole Aave
position back and sends the vault's entire USDC balance to a fixed cold
address, in one atomic script with no arguments. Plus the Registry pause as a
kill switch: one `roles pause` stops every operation and every rule change;
`roles unpause` restarts them. Together: if anything looks wrong, exit first,
then pause.


## Network

The network is the one the vault was built on. On Sepolia test mode, take
USDC, Pool, factory, RPC and balance floors from `networks.sepolia` in
[usdc-aave-vault setup.json](../assets/usdc-aave-vault/setup.json) and read
every "Arbitrum One" and ETH figure below as its Sepolia equivalent, exactly
as the vault setup's Network section says. Test USDC comes from the Aave
faucet there, not from the user.

## Prerequisites

Vault setup steps 1 to 8 done. If the policy or interaction delays are live,
the two writes below return `queued`; collect `actionId` and `eta`, execute
after `eta`, then continue. Say so first. An exit path should exist before the
delays are set, since adding one afterwards takes a day.

## Inputs

Ask for one value: the cold address, COLD. It must not be the vault, the owner's
hot signer, or any contract without a known way to move USDC out. Read
`cast code COLD`: if it has code, ask the user to confirm it can hold and move
USDC.

## Mechanics the user should hear first

- Order matters. Pause blocks execution: Interact reads
  `getInteractionBundle`, which is `whenNotPausedD`, so no operation executes
  while paused. Exit, then pause. Pausing first means unpausing before exiting.
- Pause authority: `pause()` for `ADMIN_ROLE` or `cap.registry.pause`;
  `unpause()` for `ADMIN_ROLE` only. A guardian group holding `cap.registry.pause`
  can stop the tenant but cannot restart it.
- The exit script withdraws `type(uint256).max` from Aave, which Aave treats as
  "everything". If the vault has no Aave position, Aave reverts and the whole
  exit reverts (atomic). The transfer amount is the vault's live USDC balance
  read in the same script.
- `$subjectArgCount == 0`: the exit takes no argument, so nothing about it can
  be chosen at proposal time.

## Names

| Thing | Name |
| --- | --- |
| Policy, criteria `[usdc-vault-approvers]`, thresholds `[1]` | `usdc-vault-exit-policy` |
| Interaction | `usdc-vault-exit` |
| Optional guardian group for pause only | `usdc-vault-guardians` |

Compute every id with `chainwall id NAME`. Catalog: the existing entries.

## Scripts

[exit.ls](../assets/vault-emergency-exit/exit.ls): fill `{{policyId}}`, `{{vault}}`, `{{usdc}}`, `{{cold}}`.
[exit-policy.ls](../assets/vault-emergency-exit/exit-policy.ls): fill `{{policyId}}`, `{{vault}}`, `{{exitId}}`.
Compile `exit.ls` with [erc20.json](../assets/vault-emergency-exit/erc20.json) (`transfer`, `balanceOf`) and
[pool.json](../assets/vault-emergency-exit/pool.json) (`withdraw`); expected selectors `0x69328dec`,
`0x70a08231`, `0xa9059cbb`, valid and complete. Compile the program with
`policies program compile`.

## Order

1. `policies create-policy` `usdc-vault-exit-policy`, groups
   `[usdc-vault-approvers]`, thresholds `[1]`.
2. Compile and analyze; show the user the three calls and the literal COLD.
3. `policies program publish usdc-vault-exit-policy exit-policy.json`.
4. `interactions add exit.ls --id usdc-vault-exit --abi circle/usdc=erc20.json --abi aave/pool-v3=pool.json`.
5. Execution rights already exist: `usdc-vault-approvers` holds
   `cap.registry.interaction.execute` from the vault setup; read
   `registry get-capability-groups CAP` to confirm.
6. Optional guardian: if the user names one, `users add GUARDIAN`,
   `groups create-group usdc-vault-guardians`, add the member, and
   `capabilities grant-capability-group` of `chainwall id cap.registry.pause`
   to that group.

## Signing and pauses

Dry-run every write, show it, send with the owner's `--account`. Pause for the
user's yes before step 4 and before any real exit or pause in vault-emergency-exit-verify.md.

## Finish

Append to `usdc-vault-record.md`: COLD, policy and interaction ids, guardian
group if any, every transaction hash, and the drill results. State in plain
words: exit moves everything to COLD and needs only the owner; pause stops
everything and only the owner can unpause.
