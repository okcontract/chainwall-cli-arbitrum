# Verify the USDC vault

All checks use the live instance. Do not start a local fork or node.

1. Policy cap. Build a `policy-context` (schema: `chainwall schemas show policy-context`)
   for `usdc-vault-supply` with args `["101000000"]`, actor = owner, vault = the
   OKAccount. `chainwall policies program simulate usdc-vault-policy context.json`
   must reject it. The same context with `["1000000"]` must pass.
2. Unauthorized actor. `operations propose` a `usdc-vault-supply` with amount
   `1000000` (a small write; the owner's approval is recorded with it). Then
   check from a non-member address with a read-only call, since the CLI's
   `--from` must match the signer: run the policy program with a
   `policy-context` whose `actor` is `0x000000000000000000000000000000000000dEaD`
   (`policies program simulate usdc-vault-policy context.json`), and
   `cast call INTERACT "execute(uint256,bytes32,uint256[],uint256)" OPID SUPPLY_ID "[1000000]" 100000 --from 0x000000000000000000000000000000000000dEaD`.
   Both must revert; report the decoded reasons. The proposal is reused in
   step 4.
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
