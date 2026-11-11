# Verify vault-safe-backed

1. Registration: `registry is-safe-allowed SAFE` → true. `safes inspect SAFE`: guard present,
   threshold 2, both owners.
2. Program: simulate `usdc-vault-safe-supply` with `["101000000"]`, vault SAFE
   → reject; `["1000000"]` → pass.
3. Guard (read-only): the Safe cannot be used outside Interact. Encode a plain
   USDC transfer and call the guard directly:
   `cast call GUARD "checkTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes,address)" USDC 0 TRANSFER_CALLDATA 0 0 0 0 0x0000000000000000000000000000000000000000 0x0000000000000000000000000000000000000000 0x SAFE --from SAFE --rpc-url RPC`
   → revert. `GUARD` is the guard address from `safes inspect`. A Safe
   self-call (`to` = SAFE) → revert as well.
4. Actor check (read-only): `cast code OWNER` is `0x` (see execution.md:
   an EIP-7702 delegated actor fails every actor signature). If it is not,
   pick another user with execute rights as `--account` for `sign-actor`,
   `simulate` and `execute`.
5. Real supply through the Safe (write, user's yes first). Fund the Safe with
   2 USDC (the user sends). Then, following execution.md:
   `operations propose` (`safe` = SAFE, `usdc-vault-safe-supply`, `["1000000"]`,
   policy the safe policy, deadline now + 86400) `--out safe-supply.json`;
   `operations sign-actor safe-supply.json --via safe --account OWNER --out actor.json`;
   `operations sign safe-supply.json --via safe --actor-signature-file actor.json --account OWNER --out o1.json`;
   the same for OWNER2 to `o2.json` (or OWNER2 signs on their own machine and
   sends the file back); `jq -s . o1.json o2.json > owners.json`;
   `operations simulate safe-supply.json --via safe --actor-signature-file actor.json --signatures-file owners.json --account OWNER`
   → pass; execute the same way. Read the Safe's aUSDC balance: 1000000.
6. One signature is not enough (read-only): simulate with `owners.json`
   holding only `o1.json` → fails with Safe `GS020` (signatures too short).
7. If step 5 cannot run because Aave itself refuses the supply (a direct
   `Pool.supply` from the Safe reverts, for example `51` when the reserve is
   at its supply cap), make no supply proposal and run steps 5 and 6 with
   `usdc-vault-safe-payout` `["1000000"]` instead (`safe-payout.json`): the Safe pays the owner
   1 USDC, the receipt has the Safe's `ExecutionSuccess` and a USDC
   `Transfer`, the Safe nonce increases by 1, the operation is closed.

Record every command, decoded result, signature file name and transaction hash.
