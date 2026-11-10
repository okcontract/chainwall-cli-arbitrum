# Verify protocol-admin

All checks use the live instance and target. No local fork or node.

1. Routine executes. `operations propose` `admin-set-fee` with args `["50"]`,
   `safe` = the admin account, `policyId` = admin-routine, `deadline` = now +
   86400, `--out fee.json`; the signer satisfies the policy alone so it is
   approved on creation. `operations execute fee.json --via account`.
   `owner()` on the target is the admin account, so the call succeeds; read
   `feeBps()` back as 50.
2. Routine cap. `policies program simulate admin-routine` with a context for
   `admin-set-fee` and args `["5000"]` must reject (cap is 1000 bps).
3. Wrong policy for a sensitive call. Simulate `admin-set-oracle` under
   `admin-routine`: the interaction's own `$subjectPolicy` check rejects it, and
   the routine program's id allowlist rejects it. Report both.
4. Unauthorized actor. `operations propose` `admin-set-oracle` with the real
   oracle address, deadline now + 86400, `--out oracle.json`. The CLI's `--from`
   must match the signer, so test from outside with read-only calls:
   `policies program simulate admin-sensitive` with a `policy-context` whose
   `actor` is outside `admin-approvers`, and
   `cast call INTERACT "executeFromAccount(uint256,bytes32,uint256[],uint256)" OPID SET_ORACLE_ID "[ORACLE_AS_UINT]" 100000 --from 0x000000000000000000000000000000000000dEaD --rpc-url RPC`.
   Both must revert, the second with "caller is not a user". Report the decoded
   reasons. (`execute` is the Safe path and reverts `SafeCallerRequired` for an
   unrelated reason.) Then execute `oracle.json` as the signer so the oracle is
   set.
5. Premature sensitive change. Publish a new interaction `admin-set-oracle-v2`
   (same script). With the `interaction` category delayed, the write returns
   `queued`. `timelock execute-action` before the delay must revert; report the
   revert and the earliest execution time. Then `timelock cancel-action` it and
   confirm it is gone.
6. Direct path closed. `cast call TARGET "setFee(uint256)" 1 --from OWNER_EOA`
   must revert with `NotOwner`, because the admin account now owns the
   contract. No transaction is sent.

Record every command, decoded result and transaction hash in the record file.
