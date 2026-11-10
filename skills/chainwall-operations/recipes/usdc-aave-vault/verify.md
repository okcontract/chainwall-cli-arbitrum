# Verify the USDC vault

All checks use the live instance. Do not start a local fork or node.

1. Policy cap. Build a `policy-context` (`chainwall schemas show policy-context`;
   fields interactionId, interactionArgs, nativeValue, operationId, payloadHash,
   actor, vault) for `usdc-vault-supply` with args `["101000000"]`, actor =
   owner, vault = the OKAccount.
   `chainwall policies program simulate usdc-vault-policy context.json` must
   reject it. The same context with `["1000000"]` must pass.
2. Unauthorized actor. `operations propose` a `usdc-vault-supply` with args
   `["1000000"]`, `safe` = the OKAccount, `policyId` = usdc-vault-policy,
   `deadline` = now + 86400, `--out proposal.json`. This is a small write; the
   owner satisfies the policy alone, so the proposal is approved on creation.
   Then test from outside with read-only calls, since the CLI's `--from` must
   match the signer: the policy program with a `policy-context` whose `actor`
   is `0x000000000000000000000000000000000000dEaD`, and
   `cast call INTERACT "executeFromAccount(uint256,bytes32,uint256[],uint256)" OPID SUPPLY_ID "[1000000]" 100000 --from 0x000000000000000000000000000000000000dEaD --rpc-url RPC`.
   Both must revert; the second with "caller is not a user". Report the decoded
   reasons. `executeFromAccount` is the OKAccount path; plain `execute` is for
   Safes and would revert `SafeCallerRequired` for an unrelated reason.
3. Catalog boundary. Write a one-line script that calls `transfer` on
   `@token(circle/usdt)`, which is not registered. `chainwall compile` on it
   must fail to resolve the reference, or if it compiles,
   `interactions add --dry-run` must refuse to build a publishable bundle.
   Report where it failed and the error.
4. Real run. Tell the user to send 5 USDC to the OKAccount and wait. Do not
   move the user's funds yourself. Read the balance with
   `chainwall accounts assets VAULT`. Reuse `proposal.json` from step 2:
   `operations simulate proposal.json --via account`, ask the user's yes, then
   `operations execute proposal.json --via account`. Do not create a second
   proposal. Read back the vault's aUSDC balance (aToken address from
   `getReserveData(USDC)` on the Pool) and USDC balance.

Record every command, decoded result and transaction hash in the record file.
