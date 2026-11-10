# Verify swap-desk

1. Policy: simulate `swap-desk-weth-to-usdc` with args
   `["1000000000000000","1"]` → pass; `["20000000000000000","1"]` → reject
   (cap); `["1000000000000000","0"]` → reject (min out must be positive);
   one argument only → reject (`$subjectArgCount == 2`).
2. Outsider: `cast call INTERACT "executeFromAccount(uint256,bytes32,uint256[],uint256)" 999999 W2U_ID "[1000000000000000,1]" 100000 --from 0x000000000000000000000000000000000000dEaD --rpc-url RPC`
   → "caller is not a user".
3. Quote: read the expected output with the Uniswap QuoterV2 if listed in
   setup.json for the chain, otherwise skip and use min out `1` for the test.
4. Real swap (write, user's yes): the account holds at least 0.001 WETH.
   `operations propose` `swap-desk-weth-to-usdc`, args
   `["1000000000000000","1"]`, safe VAULT, deadline now + 86400; simulate;
   execute. Read: vault WETH down by 0.001, vault USDC up by the returned
   amount (from the receipt log or the balance delta), router allowance back
   to 0.
5. Wrong recipient impossible: there is no argument for it; state that the
   recipient is the literal vault address in the published source
   (`interactions source W2U_ID`).
6. Swap back (write, user's yes): `operations propose` `swap-desk-usdc-to-weth`
   with a USDC amount the account now holds (for example `["10000000", MIN]`,
   MIN from the quote or the executed price minus 5 percent); simulate;
   execute. Read: vault USDC down by the input, vault WETH up by at least MIN,
   USDC allowance to the router back to 0, operation closed.

Record every command, decoded result, hash and balance.
