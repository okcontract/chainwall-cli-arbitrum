# Setup: swap desk (Uniswap v3, bounded output, vault as recipient)

Read `../SKILL.md` first. Shared mechanics (signer, profile, instance deploy or
reuse, terms, resume) are the ones in
[usdc-aave-vault.md](usdc-aave-vault.md), followed by section name; this setup
does not need that vault. Use the active profile or the one the user names, and write `swap-desk-record.md`. Take
flags from `chainwall <command> --help`.

## Outcome

A Chainwall OKAccount that can swap WETH to USDC and USDC to WETH on Uniswap v3,
and nothing else. Each swap: the router is the only approved spender, the
recipient is always the account itself, the pool fee is fixed, the caller must
pass a minimum output, and the input is capped per swap at `{{capIn}}` of the
input token. This is the DEX counterpart of the lending vault and proves
tuple-argument calls and a two-argument policy.

## Mechanics the user should hear first

- `exactInputSingle` takes one tuple
  `(tokenIn, tokenOut, fee, recipient, amountIn, amountOutMinimum, sqrtPriceLimitX96)`.
  In Lambdascript a tuple is `{a :: type, b :: type, …}`. The router function is
  payable, so the call is written `exactInputSingle{value: 0}(...)`.
- Two arguments: `$arg0` amount in, `$arg1` minimum out. The policy requires
  both to be positive and caps `$arg0`; it cannot judge the price, so the
  minimum out is the operator's slippage protection, enforced by Uniswap.
- The recipient is a literal (`{{vault}}`), so swap output can only land in the
  account. Approve is for the exact amount, right before the swap, in the same
  atomic script.
- The account needs WETH or USDC to swap; the user sends it to the account.

## Inputs

From [setup.json](../assets/swap-desk/setup.json) (Arbitrum One).
Verify on chain and stop on any mismatch:

- SwapRouter02: `factory()` and `WETH9()` return the listed values. Arbitrum
  One `0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45`.
- WETH `0x82aF49447D8a07e3bd95BD0d56f35241523fBab1` and USDC
  `0xaf88d065e77c8cC2239327C5EDb3A432268e5831`: `symbol()` and `decimals()`.
- Pool: `getPool(USDC, WETH, 500)` on the factory is nonzero and
  `liquidity()` > 0.

Ask the user for nothing. Defaults: fee 500, cap 0.01 WETH in
(`10000000000000000`) and 100 USDC in (`100000000`).

## Names

| Thing | Name |
| --- | --- |
| Group (owner) | `swap-desk-traders` |
| Policy, criteria `[group]`, thresholds `[1]` | `swap-desk-policy` |
| Catalog | org `uniswap`, contract `uniswap/swap-router-02`; org `weth`, token `weth/weth`; org `circle`, token `circle/usdc` |
| Account | salt `swap-desk v1` |
| Interactions | `swap-desk-weth-to-usdc`, `swap-desk-usdc-to-weth` |

Compute every id with `chainwall id NAME`.

## Scripts

[weth-to-usdc.ls](../assets/swap-desk/weth-to-usdc.ls),
[usdc-to-weth.ls](../assets/swap-desk/usdc-to-weth.ls),
[policy.ls](../assets/swap-desk/policy.ls). Fill `{{policyId}}`, `{{vault}}`,
`{{router}}`, `{{weth}}`, `{{usdc}}`, `{{w2uId}}`, `{{u2wId}}`, `{{capWethIn}}`,
`{{capUsdcIn}}`. Compile with `--abi weth/weth=erc20.json --abi circle/usdc=erc20.json --abi uniswap/swap-router-02=router.json`.
Expected selectors: `0x095ea7b3` then `0x04e45aaf` for both.

## Order

1. Instance: reuse or deploy with terms, as the vault setup's steps 1 and 2,
   with deploy `--salt "swap-desk v1"`.
2. User, group, member, policy (thresholds `[1]`).
3. `accounts create --salt "swap-desk v1"`. Record `{{vault}}`.
4. Catalog (no `orgs add` needed): contract versions for the router, WETH and USDC; token records for
   WETH (18) and USDC (6), each after its contract version.
5. Fill, compile, analyze, show results.
6. Publish the program, then both interactions with `--id`.
7. Grant `cap.registry.interaction.execute` to the group.
8. Fund the account with the input token: the user sends WETH or USDC to it.
9. Delays, only after the verify file has passed (a mistake found later
   takes 24 hours to fix): the vault setup's step 9 (skip only if the user says more setups
   will be added to this instance).

## Pauses

Before accepting terms (new instance only) and before the real swap.

## Prove it

[swap-desk-verify.md](swap-desk-verify.md).

## Finish

`swap-desk-record.md`: addresses, ids, pool, every hash, balances before and
after the real swap, and the table of what the desk can and cannot do.
