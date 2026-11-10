# Verify gov-handover

Checks 1 to 4 are read-only. CFG is any valid category config tuple; CAT is
`chainwall id timelock.category.user`.

1. `capabilities owner-bootstrap-finalized` true.
2. A second finalize reverts `OwnerBootstrapAlreadyFinalized`:
   `cast call REGISTRY "finalizeOwnerBootstrap()" --from OWNER`.
3. Governor power comes from the group: for OWNER and each governor,
   `cast call REGISTRY "setCategoryConfig(bytes32,(uint64,uint64,uint64,uint64,bytes32))" CAT "CFG" --from ADDR`
   does not revert; from CANARY it reverts `OwnableUnauthorizedAccount`.
4. `capabilities get-capability-groups $(chainwall id cap.registry.timelock.write)`
   lists exactly the `governors` id.
5. Delay proof (governance.md), ACTOR = OWNER.

Record every command and result.
