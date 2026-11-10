# Setup: ETH treasury (wrap, unwrap, pay in WETH)

Read `../SKILL.md` first. The shared mechanics (signer, profile, instance
deploy or reuse, terms, Sepolia test mode, resume rules) are the ones in
[usdc-aave-vault.md](usdc-aave-vault.md); this setup follows those sections by
name and does not need that vault to exist. Take every flag from
`chainwall <command> --help --json`.

## Outcome

A Chainwall OKAccount that holds ETH and can do exactly three things: wrap ETH
into WETH, unwrap WETH back to ETH, and pay WETH to one fixed recipient, each
capped at `{{capWei}}` (default 0.01 ETH = `10000000000000000`). Nothing else:
no other token, no other contract, no other recipient. It is the native-asset
counterpart of the USDC vault and proves the payable call path.

## Mechanics the user should hear first

- The account's own ETH is spent by the script. The proposal's `nativeValue`
  is the ceiling: Interact passes it to the account as `maxNativeValue`
  (`executeFromAccount` is not payable; the executor sends no ETH). The wrap
  policy therefore requires `$subjectNativeValue == $subjectArg(0)`, and the
  proposal for a wrap must carry `nativeValue` equal to the amount.
- A payable call needs `{value: …}` in Lambdascript:
  `@token(weth/weth).deposit{value: $arg0}()`. Unwrap and transfer carry no
  value and the policy requires `$subjectNativeValue == 0` for them.
- The recipient is a literal in the script. MiniScript can only call contracts,
  so ETH leaves the account as WETH, and the recipient unwraps on their side.
- `withdraw` sends ETH back to the caller, which is the account itself; the
  OKAccount has a `receive()` function, so the ETH lands.

## Inputs

From [setup.json](../assets/eth-treasury/setup.json), network block by chain.
Verify on chain and stop on any mismatch:

- WETH: `symbol()` is WETH, `name()` is Wrapped Ether. Arbitrum One
  `0x82aF49447D8a07e3bd95BD0d56f35241523fBab1`; Sepolia
  `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14`.
- Factory, RPC and floors as in the vault setup's network block.

Ask the user for one value: the recipient address, RECIPIENT. Nothing else.

## Names

| Thing | Name |
| --- | --- |
| Group (owner) | `eth-treasury-approvers` |
| Policy, criteria `[group]`, thresholds `[1]` | `eth-treasury-policy` |
| Catalog | org `weth`, contract and token `weth/weth` |
| Account | salt `eth-treasury v1` |
| Interactions | `eth-treasury-wrap`, `eth-treasury-unwrap`, `eth-treasury-pay` |

Compute every id with `chainwall id NAME`.

## Scripts

[wrap.ls](../assets/eth-treasury/wrap.ls), [unwrap.ls](../assets/eth-treasury/unwrap.ls),
[pay.ls](../assets/eth-treasury/pay.ls), [policy.ls](../assets/eth-treasury/policy.ls).
Fill `{{policyId}}`, `{{vault}}`, `{{recipient}}`, `{{wrapId}}`, `{{unwrapId}}`,
`{{payId}}`, `{{capWei}}`. Compile with
`--abi weth/weth=weth.json` (copy the asset files into the working folder). Expected selectors: wrap
`0xd0e30db0`, unwrap `0x2e1a7d4d`, pay `0xa9059cbb`. The program compiles with
`policies program compile`.

## Order

1. Instance: reuse the one bound in the active profile, else deploy and accept
   terms exactly as the vault setup's steps 1 and 2, with deploy
   `--salt "eth-treasury v1"`.
2. `users add OWNER` if not a user; `groups create-group`; `groups
   add-group-member`; `policies create-policy` with thresholds `[1]`.
3. `accounts create --salt "eth-treasury v1"`. Record `{{vault}}`.
4. Catalog: `orgs add weth` (optional), `contracts add weth weth WETH …`, then
   `tokens upsert-token` `("weth","weth","WETH",18,0x0…0,0)` (contract version
   first, else `TokenContractMissing`).
5. Fill, compile, analyze, show results.
6. `policies program publish eth-treasury-policy policy.json`, then
   `interactions add` each script with `--id` and `--abi weth/weth=weth.json`.
7. `capabilities grant-capability-group` of `cap.registry.interaction.execute`
   to the group.
8. Fund: the user sends ETH to the account (on Sepolia, the owner sends
   0.02 test ETH with `cast send VAULT --value 20000000000000000 --account NAME --rpc-url RPC`).
9. Delays, only after the verify file has passed (a mistake found later
   takes 24 hours to fix): the vault setup's step 9 (skip only if the user says more setups
   will be added to this instance).

## Pauses

Before accepting terms (new instance only) and before the real wrap.

## Prove it

[eth-treasury-verify.md](eth-treasury-verify.md).

## Finish

`eth-treasury-record.md`: addresses, ids, every hash, balances before and
after, and the table of what the account can and cannot do.
