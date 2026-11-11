# Verify eth-treasury

1. Policy: simulate `eth-treasury-wrap` with args `["1000000000000000"]` and
   `nativeValue` `"1000000000000000"` → pass; same args with `nativeValue`
   `"0"` → reject (`$subjectNativeValue == $subjectArg(0)`); args
   `["20000000000000000"]` with matching value → reject (cap). Simulate
   `eth-treasury-pay` with `nativeValue` `"1"` → reject.
2. Outsider: `cast call INTERACT "executeFromAccount(uint256,bytes32,uint256[],uint256)" 999999 WRAP_ID "[1000000000000000]" 100000 --from 0x000000000000000000000000000000000000dEaD --rpc-url RPC`
   → "caller is not a user".
3. Real wrap (write, user's yes): `operations propose` `eth-treasury-wrap`,
   args `["1000000000000000"]`, `nativeValue` `"1000000000000000"`, safe
   VAULT, deadline now + 86400, `--out wrap-proposal.json`; `operations simulate` then `operations execute`,
   both `--via account`. Read:
   vault ETH down by 0.001 plus nothing else (the executor paid gas), vault
   WETH `balanceOf` = 1000000000000000.
4. Real pay (write), same propose, simulate, execute pattern: `eth-treasury-pay` with `["500000000000000"]`,
   `nativeValue` `"0"`; execute; RECIPIENT WETH balance +500000000000000, vault
   WETH 500000000000000.
5. Real unwrap (write), same pattern: `eth-treasury-unwrap` with `["500000000000000"]`, `nativeValue` `"0"`;
   execute; vault WETH 0, vault ETH back up by 0.0005.
6. Wrong value: propose a wrap with args `["1000000000000000"]` and
   `nativeValue` `"2000000000000000"`; simulate → reject by the policy; then `operations withdraw` it.

Record every command, decoded result, hash and balance.
