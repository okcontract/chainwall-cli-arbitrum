# Verify the USDC vault

All checks use the live instance. Do not start a local fork or node.

1. Policy cap. Build a `policy-context` (schema: `chainwall schemas show policy-context`)
   for `usdc-vault-supply` with args `["101000000"]`, actor = owner, vault = the
   OKAccount. `chainwall policies program simulate usdc-vault-policy context.json`
   must reject it. The same context with `["1000000"]` must pass.
2. Unauthorized actor. `operations simulate` evaluates a proposed operation,
   so first `operations propose` a `usdc-vault-supply` with amount `1000000` on
   chain (this is a small write). Then simulate it with `--from` an address
   that is not the owner (for example `0x000000000000000000000000000000000000dEaD`),
   with operationId, creator and createdAt from the proposal receipt. It must be
   rejected for lack of approval or execute capability. Report the decoded
   revert. The same proposal is reused for the real run in step 4.
3. Catalog boundary. Write a one-line script that calls `transfer` on a
   `@token(circle/usdt)` that is not registered. `chainwall compile` without a
   snapshot must fail to resolve it; `interactions add --dry-run` must not
   produce a publishable bundle. Report the error.
4. Real run. Tell the user to send 5 USDC to the OKAccount and wait. Do not
   move the user's funds yourself. Read the balance with
   `chainwall accounts assets`. Reuse the proposal from step 2 (amount
   `1000000`, already proposed and approved by the owner): simulate it as the
   owner, ask the user's yes, then `operations execute` it. Do not create a
   second proposal. Read back the vault's aUSDC balance (aToken address from
   `getReserveData(USDC)` on the Pool) and USDC balance.

Record every command, decoded result and transaction hash in the record file.
