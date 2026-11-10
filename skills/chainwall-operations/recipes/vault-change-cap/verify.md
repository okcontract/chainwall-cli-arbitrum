# Verify vault-change-cap

Read-only unless marked.

1. Old cap rejects 200 USDC: `policies program simulate usdc-vault-policy`
   with args `["200000000"]` → reject (`ERR_01` style undecoded revert is the
   expected form).
2. After publish with a live delay: `timelock get-action-summary ACTIONID`
   shows `Queued`, and step 1 still rejects. `registry get-policy-program`
   hash unchanged.
3. Before `eta`: `timelock execute-action ACTIONID --dry-run` reverts
   `TimelockActionNotReady` (read-only via dry run).
4. After `eta` (write): execute, summary `Executed`, program hash equals
   `policy.json` `bytecodeHash`.
5. New cap: `["200000000"]` passes; `["500000001"]` (or `{{cap}} + 1`) rejects;
   `["100000000"]` passes.
6. Stale proposal (if any pre-change `proposal.json` exists):
   `operations simulate proposal.json --via account` fails on payload hash
   mismatch. Report the decoded reason and re-propose.

Record every command, result and hash.
