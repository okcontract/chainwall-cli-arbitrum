# Verify gov-tiered-delays

Each drill is queued by OWNER, read, then cancelled (`timelock cancel-action`,
status 5). Nothing executes.

1. Routine: `users add CANARY` → summary `delay` = DELAY.
2. Governors membership: `groups add-group-member GOVERNORS CANARY` → `delay`
   = LONG. Confirm after the cancel that the members are unchanged.
3. Delays themselves: `timelock set-category-config $(chainwall id timelock.category.user) "($DELAY,2592000,$DELAY,604800,$POLICY)"`
   (the current value) → `delay` = LONG.
4. Each extra item: one harmless write in its scope → `delay` = LONG.
5. Clean up: `users remove CANARY` → queued at DELAY. In a rehearsal wait and
   execute it; otherwise record the action id and tell the user anyone can
   execute it after `eta` (leaving it is harmless).
6. `timelock get-pending-action-count` is back to its starting value, plus
   one if step 5 is still waiting.

Record every command, result and hash.
