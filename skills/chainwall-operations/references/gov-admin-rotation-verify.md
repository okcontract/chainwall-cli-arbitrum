# Verify gov-admin-rotation

1. Before step 6 (read-only): `executeAction` on the grant reverts
   `TimelockActionNotReady`; `roles has-role ROLE NEW` false.
2. After step 6: `roles has-role ROLE NEW` true, and NEW is authorized as an
   admin (read-only, must not revert; sent for real it would queue):
   `cast call REGISTRY "grantCapabilityGroup(bytes32,bytes32)" $(chainwall id cap.registry.pause) GOVERNORS --from NEW --rpc-url RPC`.
3. Even an admin cannot grant `ADMIN_ROLE` without `cap.registry.admin.grant`
   (NEW is not in `governors`; read-only, must revert):
   `cast call REGISTRY "grantRole(bytes32,address)" ROLE CANARY --from NEW`.
4. Cancel path (write, optional): OWNER queues `roles grant-role ROLE CANARY`,
   then `timelock cancel-action ID` → status 5; `has-role ROLE CANARY` false.
5. If step 7 ran: `roles has-role ROLE OWNER` false and
   `cast call REGISTRY "grantCapabilityGroup(bytes32,bytes32)" CAP GOVERNORS --from OWNER`
   reverts.

Record every command, result and hash.
