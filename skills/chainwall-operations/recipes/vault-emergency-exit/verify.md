# Verify vault-emergency-exit

1. Program: simulate `usdc-vault-exit` with `interactionArgs: []`, actor OWNER →
   pass; with args `["1"]` → reject (`$subjectArgCount == 0`); the owner's
   `usdc-vault-supply` id under this policy → reject.
2. Outsider: `cast call INTERACT "executeFromAccount(uint256,bytes32,uint256[],uint256)" 999999 EXIT_ID "[]" 100000 --from 0x000000000000000000000000000000000000dEaD --rpc-url RPC`
   → revert "caller is not a user".
3. Exit drill (write, user's yes first). Only if the vault has an Aave position
   (`getReserveData(USDC)` aToken `balanceOf(VAULT)` > 0); if not, say the
   drill needs a position and offer to run the vault recipe's 1 USDC supply
   first. `operations propose` `usdc-vault-exit`, args `[]`, safe VAULT,
   policyId the exit policy, deadline now + 86400, `--out exit.json`;
   `operations simulate exit.json --via account` → pass; execute. Read: vault
   aToken balance 0, vault USDC 0, COLD USDC increased by the sum.
4. Kill switch (write). `roles pause --dry-run`, send. Then
   `operations simulate exit.json --via account` on a fresh proposal fails
   while paused, and `users add 0x000000000000000000000000000000000000dEaD --dry-run`
   is the only kind of write to try: it must revert `EnforcedPause` (read-only
   via dry run). `roles unpause`, send; simulate passes again.
5. Guardian (if configured): `cast call REGISTRY "unpause()" --from GUARDIAN --rpc-url RPC`
   → revert (admin only); `cast call REGISTRY "pause()" --from GUARDIAN` → no
   revert in eth_call (would succeed).

Record every command, decoded result and transaction hash.
