# Verify gov-delegated-admin

All read-only `cast call REGISTRY ... --from D --rpc-url RPC`, D a delegate of
the job. "Works" means no revert.

1. Onboarder: `"addUser(address)" CANARY` works.
2. Catalog manager: `capabilities has-capability CAP D` true for both
   capabilities.
3. Policy author: `"createPolicy(bytes32,bytes32[],uint256[])" $(chainwall id drill-policy) "[GROUP]" "[1]"`
   works, GROUP being the delegate's own group id.
4. Each delegate is refused outside the job (each must revert
   `AccessControlUnauthorizedAccount`): `"createGroup(bytes32)" $(chainwall id drill)`,
   and `"grantCapabilityGroup(bytes32,bytes32)" CAP GROUP`.
5. A delegate of one job is refused another job: an onboarder calling the
   `createPolicy` line reverts; a policy author calling `addUser` reverts.

Record every command and result.
