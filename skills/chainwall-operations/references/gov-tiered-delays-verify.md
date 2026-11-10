# Verify gov-tiered-delays

OWNER queues each drill and reads `timelock get-action-summary`. Drills 1 to
3 are cancelled (`timelock cancel-action`, status 5) and never execute.

1. Governors membership: `groups add-group-member GOVERNORS CANARY` → `delay`
   = LONG. Confirm after the cancel that the members are unchanged.
2. Delays themselves: `timelock set-category-config $(chainwall id timelock.category.user) "($DELAY,2592000,$DELAY,604800,$POLICY)"`
   (the current value) → `delay` = LONG.
3. Each extra item: one harmless write in its scope → `delay` = LONG.
4. Routine, and the cleanup: `users remove CANARY` → `delay` = DELAY; early
   `executeAction` reverts `TimelockActionNotReady`. In a rehearsal wait and
   run `timelock execute-action ID` → status 4, `users contains CANARY` false.
   Otherwise record the action id and tell the user anyone can execute it
   after `eta` (leaving it is harmless).
5. `timelock get-pending-action-count` is back to its starting value, plus
   one if step 4 is still waiting.

Record every command, result and hash.
