# Verify gov-guardians

G is one guardian. Writes are marked; ask before the pause drill.

1. Reads: `capabilities has-capability CAP G` is true for the three
   capabilities and false for `chainwall id cap.registry.timelock.write`.
2. Cancel drill (write). OWNER: `users add CANARY` → `queued`, action ID,
   status 1. G: `timelock cancel-action ID` → status 5;
   `users contains CANARY` false.
3. Pause drill (write). G: `roles pause` → `roles paused` true. Read-only
   while paused: `cast call REGISTRY "addUser(address)" CANARY --from OWNER`
   reverts `EnforcedPause`; `cast call REGISTRY "unpause()" --from G` reverts.
   OWNER: `roles unpause` → `roles paused` false.
4. Guardians cannot change rules (read-only, each must revert):
   `cast call REGISTRY "addUser(address)" CANARY --from G` and
   `cast call REGISTRY "grantCapabilityGroup(bytes32,bytes32)" CAP GROUP --from G`.

Record every command, result and hash.
