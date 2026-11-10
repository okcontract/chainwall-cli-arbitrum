# Verify the USDC vault

All checks use the live instance. Do not start a local fork or node.

1. Policy cap. Build a `policy-context` (schema: `chainwall schemas show policy-context`)
   for `usdc-vault-supply` with args `["101000000"]`, actor = owner, vault = the
   OKAccount. `chainwall policies program simulate usdc-vault-policy context.json`
   must reject it. The same context with `["1000000"]` must pass.
2. Unauthorized actor. Create an intent for `usdc-vault-supply`, amount
   `1000000`, and `operations propose --dry-run` / `operations simulate` it with
   `--from` an address that is not the owner (for example
   `0x000000000000000000000000000000000000dEaD`). It must be rejected for lack
   of approval or execute capability. Report the decoded revert.
3. Catalog boundary. Write a one-line script that calls `transfer` on a
   `@token(circle/usdt)` that is not registered. `chainwall compile` without a
   snapshot must fail to resolve it; `interactions add --dry-run` must not
   produce a publishable bundle. Report the error.
4. Real run. Tell the user to send 5 USDC to the OKAccount and wait. Read the
   balance with `chainwall accounts assets`. Then propose `usdc-vault-supply`
   with `["1000000"]`, simulate, and ask the user's yes before `operations
   execute`. Read back the vault's aUSDC balance (aToken address from
   `getReserveData(USDC)` on the Pool) and USDC balance.

Record every command, decoded result and transaction hash in the record file.
