# Verify vault-emergency-exit

1. Program: simulate `usdc-vault-exit` with `interactionArgs: []`, actor OWNER →
   pass; with args `["1"]` → reject (`$subjectArgCount == 0`); the owner's
   `usdc-vault-supply` id under this policy → reject.
2. Outsider: `cast call INTERACT "executeFromAccount(uint256,bytes32,uint256[],uint256)" 999999 EXIT_ID "[]" 100000 --from 0x000000000000000000000000000000000000dEaD --rpc-url RPC`
   → revert "caller is not a user".
3. Exit drill (write, user's yes first). Read first: aToken `balanceOf(VAULT)`
   (A) and USDC `balanceOf(VAULT)` (U); the vault needs U + A > 0, otherwise
   ask the user to fund it. `operations propose` `usdc-vault-exit`, args `[]`,
   safe VAULT, policyId the exit policy, deadline now + 86400, `--out exit-proposal.json`;
   `operations simulate exit-proposal.json --via account` → pass; execute. Read: vault
   aToken balance 0, vault USDC 0, COLD USDC increased by U + A (within Aave
   interest rounding). State which branch ran: A > 0 means the withdraw
   executed (the receipt has Aave's `Withdraw` event), A = 0 means it was
   skipped.
4. Kill switch (write). First propose a second exit (`--out exit-fresh.json`).
   `roles pause --dry-run`, send. Then
   `operations simulate exit-fresh.json --via account` fails
   while paused (`EnforcedPause`), and a rule change is blocked too: show it
   read-only with `cast call REGISTRY "addUser(address)" 0x000000000000000000000000000000000000dEaD --from OWNER --rpc-url RPC`
   → revert `EnforcedPause` (`--dry-run` on CLI writes only prints calldata,
   it does not simulate). Send nothing while paused. `roles unpause`, send;
   simulate passes again and the same `eth_call` no longer reverts. Then
   `operations withdraw` the fresh proposal so no approved exit stays open.
5. Guardian (if configured): `cast call REGISTRY "unpause()" --from GUARDIAN --rpc-url RPC`
   → revert (admin only); `cast call REGISTRY "pause()" --from GUARDIAN` → no
   revert in eth_call (would succeed).

Record every command, decoded result and transaction hash.
