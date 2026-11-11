# Verify vault-bot-operator

1. Allowlist. `policies program simulate usdc-vault-bot-policy` with a
   `policy-context` for `usdc-vault-payout` (the owner's payout id), args
   `["1000000"]`, actor BOT, vault VAULT → reject. Same for
   `usdc-vault-bot-supply` with `["1000000"]` → pass; `["100000001"]` → reject.
2. Not a member. `cast call INTERACT "executeFromAccount(uint256,bytes32,uint256[],uint256)" 999999 BOT_SUPPLY_ID "[1000000]" 100000 --from 0x000000000000000000000000000000000000dEaD --rpc-url RPC`
   → revert "caller is not a user".
3. Real bot run (write, user's yes first). Read `accounts assets VAULT` first; if the
   vault holds less than 1 USDC, ask the user to send 2 USDC to it and wait. As the bot: `operations propose` for
   `usdc-vault-bot-supply`, args `["1000000"]`, safe VAULT, policyId the bot
   policy, deadline now + 86400, `--account BOT --out bot-supply.json`; then
   `operations execute bot-supply.json --via account --account BOT`. Read the
   meter: `registry get-policy-meter-bucket POLICY METER 86400 BUCKET VAULT32 0x00…00 0x00…00 0x00…00` (VAULT32 is the vault address left-padded to 32 bytes; the three zero words are full 32-byte zeros)
   with `BUCKET = block.timestamp / 86400`; it reads `1000000`.
4. Budget (write, optional, costs gas): repeat step 3 with `["100000000"]` five
   times, then once more; the sixth execution reverts
   `PolicyStateLimitExceeded`. If the user declines, state that the meter is
   source-verified and bucket-read only.
5. Kill switch (write). Owner: `roles pause`. Then the bot's
   `operations simulate bot-supply.json --via account --account BOT` fails
   (`EnforcedPause`). Owner: `roles unpause`; the simulation passes again. Record both hashes.
6. Bot cannot change rules: `cast call REGISTRY "setPolicyProgram(bytes32,bytes,uint32)" POLICY 0x00 1 --from BOT --rpc-url RPC`
   → revert (not admin, no policy capability).

Record every command, decoded result and transaction hash.
