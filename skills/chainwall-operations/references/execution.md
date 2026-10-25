# Propose, approve, and execute

Resolve the intended Registry, Interact, managed vault, interaction and policy
from live configuration. Read the installed interaction and policy, admission,
pause and terms state. Select an actor with the needed execution capability.
Inspect balances and allowances in the vault that will actually make calls.

## Make an exact intent

```sh
chainwall schemas template operation-intent --out intent.json
chainwall schemas show operation-document
```

Fill the generated fields. An illustrative intent is:

```json
{
  "safe": "0x1111111111111111111111111111111111111111",
  "interactionId": "0x2222222222222222222222222222222222222222222222222222222222222222",
  "policyId": "0x3333333333333333333333333333333333333333333333333333333333333333",
  "deadline": "1900000000",
  "args": ["389733769954907444854315955391008805241582011460", "1000000"],
  "nativeValue": "0"
}
```

These addresses, IDs and timestamp are examples, not a deployable configuration.
`safe` also names an OKAccount. A transfer's address argument is encoded as a
uint256 word: convert the actual recipient with `cast to-dec "$RECIPIENT_ADDRESS"`.
Set a bounded future deadline relative to chain time. `nativeValue` is wei;
token amounts use their own decimals. Keep integers as strings.

```sh
chainwall schemas validate operation-document intent.json
chainwall operations propose intent.json --account proposer --dry-run
chainwall operations propose intent.json --account proposer --out proposal.json --json
```

The CLI computes payload and runtime binding hashes. Do not synthesize or edit
signed pending payloads by hand. The saved v3 proposal contains its v2 payload;
the operation ID is `payload.operationId`. Proposal creation records the
proposer's approval. Inspect status and obtain only the remaining approvals:

```sh
chainwall operations status "$OP_ID" --json
chainwall operations approve "$OP_ID" --account second-approver --json
chainwall operations status "$OP_ID" --json
```

An operation ID is an integer. A Registry timelock action ID is bytes32. Neither
is the interaction ID. Use IDs actually returned by the chain.

No KV, encrypted journal, browser or app is required to execute a saved local
proposal. `operations publish proposal.json` is a separate optional journal
transaction; it is not required to propose or approve.

## OKAccount execution

```sh
chainwall operations simulate proposal.json --account executor --out simulation.json
chainwall operations execute proposal.json --account executor --dry-run
chainwall operations execute proposal.json --account executor --out execution.json --json
```

The default route is `--via account`. Use `--approve` consistently if the
executor is meant to contribute a remaining approval and execute atomically.
Simulation checks the exact call at a pinned canonical block, reports decoded
reverts, and broadcasts nothing. Correct a rejected policy or authorization;
do not weaken it simply to make simulation pass. State changes between
simulation and execution can invalidate the result.

After submission, inspect the receipt, execution event and intended state
change, such as recipient and vault balances. Use a fresh read for final
verification. An operation becoming `closed` alone is insufficient evidence:
that predicate also covers withdrawal and missing records.

## Guarded Safe execution

Choose the existing Safe's supported route. `safes inspect` reports owners,
threshold, guard/gateway and module state. Safe owner signatures and Interact
policy approvals satisfy different checks.

For the owner-signed route:

```sh
chainwall operations sign-actor proposal.json --via safe \
  --account actor --out actor.json
chainwall operations sign proposal.json --via safe \
  --actor-signature-file actor.json --account owner1 --out owner1.json
chainwall operations sign proposal.json --via safe \
  --actor-signature-file actor.json --account owner2 --out owner2.json
jq -s . owner1.json owner2.json > owners.json
chainwall operations simulate proposal.json --via safe \
  --actor-signature-file actor.json --signatures-file owners.json --account relayer
chainwall operations execute proposal.json --via safe \
  --actor-signature-file actor.json --signatures-file owners.json --account relayer
```

Collect the actual required threshold; two owners here is just an example.
Keep `--approve`, `--max-steps`, and `--reveal-file` identical throughout signing,
simulation and execution. A changed Safe nonce or transaction needs fresh
signatures. The CLI checks matching Safe execution success, not just receipt
success. Never bypass the guard with an arbitrary Safe call.

For a Safe with an already enabled, tenant-bound OKModule:

```sh
chainwall operations sign-actor proposal.json --via module \
  --account actor --out actor.json
chainwall operations simulate proposal.json --via module \
  --actor-signature-file actor.json --account relayer
chainwall operations execute proposal.json --via module \
  --actor-signature-file actor.json --account relayer
```

This route uses actor authorization and leaves the Safe owner nonce unchanged;
do not supply owner signature files. A missing module is not permission to
enable one automatically.

## Direct execution and automation

`operations direct intent.json` executes without creating a proposal only when
the actor can satisfy the policy alone. It still requires the future deadline,
runtime/nonce binding, admission and permissions. Preview with `--dry-run`, then
submit with a new `--out` report when authorized. Direct execution revalidates
and simulates the signed request before sending.

Direct Safe owner signing uses `direct-sign-actor --via safe`, then
`direct-sign --via safe`; module execution uses `--via module`. Read their help
for the current file shapes. Do not feed a proposal to the direct workflow.

For recurring automation, preserve a durable business-job to operation/receipt
mapping and allow only one in-flight submission per job. Re-evaluate chain
time, balances, prices, policy state, runtime bindings and nonces per run. New
approvals are required when the reviewed operation changes. Chainwall does not
schedule a cron job merely by publishing an interaction; configure a scheduler
only when the user requests recurring execution.

## Finish Registry governance separately

A catalog, group, policy, capability or upgrade write can return `queued`.
Save each returned action ID and stop dependent work until it applies:

```sh
chainwall timelock get "$ACTION_ID" --json
chainwall registry getActionApprovalState "$ACTION_ID" "$APPROVER_ADDRESS" --json
chainwall timelock approve "$ACTION_ID" --account approver
chainwall timelock get "$ACTION_ID" --json
chainwall timelock execute "$ACTION_ID" --account governor --json
```

Execute only after approvals, ETA and live `executable` state allow it and
before expiry. Waiting is not approval. Read the resulting configuration.
For a batch, inspect `executedActions`, `expiredActions` and `skippedActions`;
`partial` and `no-actions-executed` do not mean full application. Cancellation
uses `timelock cancel` for governance and `operations withdraw` for Interact.
