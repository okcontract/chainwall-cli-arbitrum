# Setup: token issuer (mint, burn, pause behind Chainwall)

Read `../SKILL.md` first. Shared mechanics (signer, profile, instance deploy or
reuse, terms, Sepolia test mode, resume) are the ones in
[usdc-aave-vault.md](usdc-aave-vault.md), followed by section name; this setup
does not need that vault. Use the active profile or the one the user names (on Sepolia any profile with
chain 11155111 and the Sepolia factory), and write `token-issuer-record.md`. Take
flags from `chainwall <command> --help`.

## Outcome

A project's own ERC-20 has its owner role held by a Chainwall OKAccount. Two
kinds of action are separated: minting, which a minters group can do up to
`{{mintCap}}` per call and `{{dailyMintLimit}}` per UTC day (Registry policy
meter), and burn or pause, which only the admins group can do. The deployer's
EOA can no longer mint. Nothing else on the token is reachable through Chainwall.

## Target token

Preferred: the user's own token with an `onlyOwner` mint, burn and pause. Ask
for its address and ABI and adapt the scripts. Fallback for a demo:
[GuardedToken.sol](../assets/token-issuer/contract/GuardedToken.sol), deployed
with `forge create` from the signer and treated as unreviewed demo code; ABI in
[token.json](../assets/token-issuer/token.json). Read `owner()` first and show
who holds it.

## Mechanics the user should hear first

- The meter is `consumePolicyMeter`, counted in the token's own base units
  (18 decimals). Defaults when the user names no limits: `mintCapBaseUnits`
  and `dailyMintLimitBaseUnits` in setup.json. Fixed UTC windows, as in vault-bot-operator.
- `mint(to, amount)` takes two arguments; the policy requires `to != 0` and caps
  `amount`. The recipient is not fixed: that is the point of a minter role.
- Pause is the token's own `setPaused(bool)`, an admin action here, distinct
  from the Registry pause.
- Ownership handover is the final, separately reviewed step, exactly as in
  protocol-admin.

## Names

| Thing | Name |
| --- | --- |
| Groups | `token-minters` (signer, plus any minters), `token-admins` (signer, plus any admins) |
| Policies | `token-minter-policy` = [`token-minters`], thresholds [1]; `token-admin-policy` = [`token-admins`], thresholds [group size] |
| Catalog | org `myproject`, contract `myproject/token` |
| Account | salt `token-issuer v1` |
| Interactions | `token-mint`, `token-burn`, `token-pause` |
| Meter | `token-mint-daily` |

Compute every id with `chainwall id NAME`.

## Scripts

[mint.ls](../assets/token-issuer/mint.ls), [burn.ls](../assets/token-issuer/burn.ls),
[pause.ls](../assets/token-issuer/pause.ls),
[minter-policy.ls](../assets/token-issuer/minter-policy.ls),
[admin-policy.ls](../assets/token-issuer/admin-policy.ls). Fill
`{{minterPolicyId}}`, `{{adminPolicyId}}`, `{{issuerAccount}}`, `{{mintId}}`,
`{{burnId}}`, `{{pauseId}}`, `{{meterId}}`, `{{mintCap}}`, `{{dailyMintLimit}}`,
`{{registryWord}}` (Registry address as a 32 byte word). Compile the three
interactions with `--abi myproject/token=token.json`; expected selectors mint
`0x40c10f19`, burn `0x9dc29fac`, setPaused `0x16c38b3c`.

## Order

1. Instance: reuse or deploy with terms, as the vault setup's steps 1 and 2,
   with deploy `--salt "token-issuer v1"`.
2. Deploy the demo token (or take the user's address); read `owner()`.
3. Users, groups, members, both policies, in that order.
4. `accounts create --salt "token-issuer v1"`. Record `{{issuerAccount}}`.
5. `orgs add myproject` (optional), `contracts add myproject token TOKEN …`.
6. Fill, compile, analyze, show results.
7. Publish both programs, then the three interactions with `--id`.
8. Grant `cap.registry.interaction.execute` to both groups.
9. Ownership handover, reviewed: `transferOwnership(issuerAccount)` signed by
   the token's current owner key; read `owner()` back.
10. Delays, only after the verify file has passed (a mistake found later
   takes 24 hours to fix): the vault setup's step 9 (skip only if the user says more setups
   will be added to this instance).

## Pauses

Before accepting terms (new instance only), before the ownership transfer, and
before any state-changing check.

## Prove it

[token-issuer-verify.md](token-issuer-verify.md).

## Finish

`token-issuer-record.md`: addresses, ids, every hash, `totalSupply` and
`owner()` before and after, and the table of who can do what.
