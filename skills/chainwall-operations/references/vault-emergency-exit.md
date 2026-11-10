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

Then finish the vault's protection if it is still open: if the vault setup's
step 9 delays are not set (`timelock get-category-config` on the full category
names reads `[[0,…]]`), run that step 9 now, exactly as the vault setup
describes, so the tenant does not stay without delays. Record the result.
