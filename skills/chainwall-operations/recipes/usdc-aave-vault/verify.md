# Verify the USDC vault

All checks use the live instance. Do not start a local fork or node. Checks 1–3
are read-only and need no signature or funds. Only check 4 writes or moves money.

The vault has two layers, and the checks test each one:

- The policy program limits *what* runs: this vault, this policy, one of the
  three interaction ids, an amount between 1 and 100000000 base units, no
  native value. The policy language has no caller variable.
- Interact limits *who* runs it: the caller must be a registered user, in a
  group that holds the execute capability, and the operation must be approved.

## 1. Policy cap

Write a `policy-context` file (`chainwall schemas show policy-context`) for
`usdc-vault-supply`, using exactly these values:

```json
{
  "interactionId": "SUPPLY_ID",
  "interactionArgs": ["101000000"],
  "nativeValue": "0",
  "operationId": "0",
  "payloadHash": "0x0000000000000000000000000000000000000000000000000000000000000000",
  "actor": "OWNER",
  "vault": "VAULT"
}
```

`SUPPLY_ID` is `chainwall id usdc-vault-supply`. `operationId` 0 and the zero
`payloadHash` are fine: this policy does not read them.

- `chainwall policies program simulate usdc-vault-policy context-over.json`
  must reject it. The CLI shows this as an undecoded revert with raw data
  `0x80cf34d4…` (`ERR_01`) and "Simulation did not pass". That is the expected
  result, not a tooling error.
- The same file with `["1000000"]` must pass:
  `PolicyProgramSimulationResult` with `stackTop` 1.

## 2. Outsider cannot execute

- Expected pass: the same 1 USDC context with `"actor"` set to
  `0x000000000000000000000000000000000000dEaD` passes the policy simulation,
  because the policy never checks the caller. Report it as "passes by design",
  not as a failure.
- Must revert: call Interact as the outsider. No proposal is needed, because
  Interact checks the caller before it looks up the operation; use the unused
  operation id `999999`:

  ```sh
  cast call INTERACT "executeFromAccount(uint256,bytes32,uint256[],uint256)" 999999 SUPPLY_ID "[1000000]" 100000 --from 0x000000000000000000000000000000000000dEaD --rpc-url RPC
  ```

  It must revert with `AccessControlPolicy: caller is not a user`. Then run the
  same call with `--from OWNER`: it must revert with
  `AccessControlPolicy: operation does not exist`. The different reasons prove
  the outsider was stopped by the user check, not by the missing operation. If
  the outsider call does not revert with "caller is not a user", stop: the
  vault is open to outsiders. `INTERACT` is the profile's `interact` address.
  Keep the last argument `100000` as written. `executeFromAccount` is the
  OKAccount path; plain `execute` is for Safes and reverts
  `SafeCallerRequired` for an unrelated reason.

## 3. Catalog boundary

Write a one-line script that calls `transfer` on `@token(circle/usdt)`, which
is not registered:

```
{
  @token(circle/usdt).transfer(OWNER :: address, 1 :: uint256)
}
```

Replace `OWNER` with the owner address (the check fails on the token reference
either way). `chainwall compile` on it must fail with "An @contract or @token reference is
missing from the selected Registry or snapshot." (the message does not name
the reference). If it compiles, `interactions add --dry-run` must refuse to
build a publishable bundle. Report where it failed and the error.

## 4. Real run: one 1 USDC supply

First check whether it already ran (Resume, "Real run" row): if
`accounts activity VAULT` has a record with the supply `interactionId` and
`caller` = OWNER, the real run is done. Do not run it again. Find its
`operations-execute` log with `chainwall logs list` and prove the supply from
that transaction's receipt, not from today's balances (a later withdraw or
payout can leave the vault at 0): in the receipt's ERC-20 `Transfer` logs,
USDC must move from VAULT to the aUSDC token (aUSDC address from
`getReserveData(USDC)` on the Pool), and aUSDC must be minted to VAULT for
about the same amount (Aave rounding can make it 1 base unit less). Then report
current balances for information only.

Otherwise:

1. Arbitrum One: tell the user: "Send 5 USDC on Arbitrum One to VAULT, then
   tell me when it's sent." Do not move the user's funds yourself. Sepolia:
   mint 5 test USDC to VAULT with the Aave faucet instead (SKILL.md, Network). Confirm with
   `chainwall accounts assets VAULT` that the USDC arrived.
2. Propose: `operations propose` a `usdc-vault-supply` with args `["1000000"]`,
   `safe` = VAULT, `policyId` = POLICY, `deadline` = now + 86400,
   `--out proposal.json`. Dry-run it first. The owner satisfies the policy
   alone, so the proposal is approved on creation.
3. `operations simulate proposal.json --via account`. Show the result, then ask
   the user's explicit yes.
4. `operations execute proposal.json --via account`. Make exactly one proposal;
   if the execute fails or times out, recover its receipt before anything else.
5. Read back the vault's USDC balance and its aUSDC balance. The aUSDC token
   address comes from `getReserveData(USDC)` on the Pool. 1 USDC should have
   moved from USDC to aUSDC.

Record every command, decoded result and transaction hash in the record file.
