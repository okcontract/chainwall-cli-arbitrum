# Setup: a bot operator with a daily budget and a kill switch

Extends [usdc-aave-vault](usdc-aave-vault.md). Read `../SKILL.md`
and that setup first; their rules on signer, profile, dry runs and "never
invent a command" apply. Take every flag from `chainwall <command> --help --json`.

## Outcome

A second key, the bot, can run two things on the existing vault, supply to Aave
and withdraw back to the vault, each capped at 100 USDC and together capped at
500 USDC per rolling 24 hour window, enforced by a Registry policy meter. The
bot cannot pay out, cannot touch any other contract, and cannot change any
rule. The owner can stop everything with one Registry pause and restart it with
one unpause. If the bot key leaks, the attacker gets at most one day of
budget, into Aave or back to the vault, and nowhere else.


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

- The bot keystore: ask the user for its name. If it does not exist, the user
  runs `cast wallet new vault-bot` in their own terminal and funds the address
  with about 0.0005 ETH on Arbitrum One (its transactions are proposals and
  executions, about 300k gas each). The bot address is BOT.
- Daily budget: default 500 USDC (`500000000`). Per operation cap: 100 USDC.

Nothing else. The owner (vault setup signer) signs every Registry write; the
bot signs only its own operations.

## Mechanics the user should hear first

- The meter is `consumePolicyMeter(policyId, meterId, 86400, amount, limit,
  d0..d3)` in `RegistryPolicyStateFacet`. Buckets are fixed windows
  `block.timestamp / 86400`, so the budget resets at 00:00 UTC, not 24 hours
  after the first spend. The amount is the USDC base-unit argument of the
  operation; no price feed is involved.
- The write is allowed only while Interact is running the policy program for
  this policy (`_requirePolicyStateRuntimeWrite`), so nobody can spend the
  meter from outside.
- `policies program simulate` evaluates with rollback, so it cannot show the
  meter filling up. The meter is proven by reading
  `registry get-policy-meter-bucket` after real executions.
- Pause: `roles pause` flips the Registry's pause; every `whenNotPausedD`
  function then reverts, including `getInteractionBundle`, which Interact reads
  on every execution, so no operation executes while paused. Pause also bumps
  the execution semantics revision. `pause()` is allowed for `ADMIN_ROLE` or a
  `cap.registry.pause` holder; `unpause()` for `ADMIN_ROLE` only
  (`RegistryPauseModule._requirePauseAuthority`). The owner is admin. Pause
  blocks Registry writes too, including the owner's, until unpause.
- The bot's interactions are separate from the owner's because each
  interaction is bound to one policy (`$subjectPolicy`). Same scripts, new ids,
  bound to the bot policy.

## Names

| Thing | Name |
| --- | --- |
| Group (one member: BOT) | `usdc-vault-bots` |
| Policy, criteria `[usdc-vault-bots]`, thresholds `[1]` | `usdc-vault-bot-policy` |
| Interactions | `usdc-vault-bot-supply`, `usdc-vault-bot-withdraw` |
| Meter id | `usdc-vault-bot-daily` |

Compute every id with `chainwall id NAME`. Catalog entries are the vault
setup's `circle/usdc` and `aave/pool-v3`; add nothing.

## Scripts

[supply.ls](../assets/vault-bot-operator/supply.ls) and [withdraw.ls](../assets/vault-bot-operator/withdraw.ls) equal the vault setup's
with `{{policyId}}` = the bot policy id. [bot-policy.ls](../assets/vault-bot-operator/bot-policy.ls) is the
allowlist plus cap plus meter. Fill `{{policyId}}`, `{{vault}}`, `{{usdc}}`,
`{{pool}}`, `{{supplyId}}`, `{{withdrawId}}`, `{{meterId}}`, `{{dailyLimit}}`,
and `{{registryWord}}`: the Registry (instance) address left-padded to 32 bytes,
`0x000000000000000000000000` followed by the 40 hex digits of the address, as
`chainwall policies templates daily-meter-budget --instance ADDRESS` prints it.
`0x4671fe19` is the selector of `consumePolicyMeter(bytes32,bytes32,uint64,uint256,uint256,bytes32,bytes32,bytes32,bytes32)`;
confirm with `cast sig`. No comments in `.ls`.

Compile the two interactions with the vault setup's ABIs and the program with
`policies program compile`; all must be valid and complete, selectors
`0x095ea7b3` then `0x617ba037`, and `0x69328dec`.

## Order

1. `users add BOT`.
2. `groups create-group` `usdc-vault-bots`; `groups add-group-member GROUP BOT`.
3. `policies create-policy` `usdc-vault-bot-policy`, groups `[GROUP]`,
   thresholds `[1]`.
4. Compile and analyze; show results.
5. `policies program publish usdc-vault-bot-policy bot-policy.json`.
6. `interactions add supply.ls --id usdc-vault-bot-supply --abi circle/usdc=erc20.json --abi aave/pool-v3=pool.json`,
   same for withdraw with `--id usdc-vault-bot-withdraw`.
7. `capabilities grant-capability-group` with
   `chainwall id cap.registry.interaction.execute` and the bots group hash.
8. Optional, only if the user names a guardian who is not the owner:
   `capabilities grant-capability-group` of `chainwall id cap.registry.pause` to
   a guardian group, so that address can pause but not unpause.

Verify each step on chain before the next (`users contains BOT`,
`registry get-group-members`, `registry get-policy-criteria`,
`registry get-policy-program`, `registry get-interaction-keys-page 0 10`,
`registry get-capability-groups CAP`).

## Signing and pauses

Dry-run every write, show it, send with the owner's `--account`. Pause for the
user's yes at two points: before step 7 (the bot gains execution rights) and
before the real bot supply in vault-bot-operator-verify.md.

## Finish

Append to `usdc-vault-record.md`: BOT, group and policy ids, interaction ids,
meter id and limits, every transaction hash, the meter bucket read, and the
pause and unpause hashes. State plainly: the bot can supply and withdraw up to
500 USDC per UTC day in operations of at most 100 USDC; it cannot pay out; the
owner can pause everything; while paused, nobody, including the owner, can
write to the Registry until unpause.

Then finish the vault's protection if it is still open: if the vault setup's
step 9 delays are not set (`timelock get-category-config` on the full category
names reads `[[0,…]]`), run that step 9 now, exactly as the vault setup
describes, so the tenant does not stay without delays. Record the result.
