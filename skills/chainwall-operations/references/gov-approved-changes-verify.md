# Verify gov-approved-changes

G2 is a second governor. Steps 2 to 5 are writes.

1. Reads: every category in the governance.md loop and `config` reads
   `[[DELAY,2592000,DELAY,604800,POLICY]]`.
2. OWNER: `users add CANARY` → `queued`, action ID; summary status 1, policyId
   = POLICY.
3. OWNER: `timelock approve-action ID` → status still 1 (one approval).
   Read-only: `executeAction` reverts `TimelockActionNotReady(ID, 1)`.
4. G2: `timelock approve-action ID` → status 2. If `eta` has not passed yet
   (with a short DELAY it often has), `executeAction` still reverts
   `TimelockActionNotReady(ID, 2)`; otherwise skip that read.
5. If DELAY is 600 or less (or the user chooses to wait): after `eta`, anyone
   runs `timelock execute-action ID` → status 4, `users contains CANARY` true.
   Then remove it the same way: `users remove CANARY` (queued), two approvals,
   execute after `eta`, `users contains` false. Otherwise OWNER runs
   `timelock cancel-action ID` → status 5, and the record says a real change
   completes with `timelock execute-action` after `eta`.
6. An outsider cannot approve (read-only):
   `cast call REGISTRY "approveAction(bytes32)" ID --from CANARY` reverts
   `TimelockNotEligible` (run it before step 5 closes the action).

Record every command, result and hash.
