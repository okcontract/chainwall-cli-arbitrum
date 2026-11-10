# Verify token-issuer

1. Minter policy: simulate `token-mint` with args `["RECIPIENT_AS_UINT","1000000000000000000"]`
   → pass; amount `"2000000000000000000000"` → reject (cap); `to` = 0 →
   reject; `token-burn` id under the minter policy → reject.
2. Admin policy: simulate `token-pause` with `["1"]` under
   `token-admin-policy` → pass; `token-mint` id under it → reject.
3. Outsider: `cast call INTERACT "executeFromAccount(uint256,bytes32,uint256[],uint256)" 999999 MINT_ID "[RECIPIENT_AS_UINT,1000000000000000000]" 100000 --from 0x000000000000000000000000000000000000dEaD --rpc-url RPC`
   → "caller is not a user".
4. Direct path closed (after step 9): `cast call TOKEN "mint(address,uint256)" OWNER_EOA 1 --from OWNER_EOA --rpc-url RPC`
   → revert `NotOwner`.
5. Real mint (write, user's yes): propose `token-mint` with
   `["RECIPIENT_AS_UINT","1000000000000000000"]`, safe ISSUER, policy the
   minter policy, deadline now + 86400; execute. Read `totalSupply` +1e18,
   recipient `balanceOf` +1e18, meter bucket = 1e18.
6. Real pause and unpause (write): `token-pause` with `["1"]` under the admin
   policy; execute; `paused()` true; a `cast call TOKEN "transfer(address,uint256)" X 1 --from RECIPIENT` reverts `TransfersPaused`. Then `["0"]`; `paused()` false.
7. Burn (write): `token-burn` with `["RECIPIENT_AS_UINT","500000000000000000"]`;
   `totalSupply` down by 5e17.

Record every command, decoded result and hash.
