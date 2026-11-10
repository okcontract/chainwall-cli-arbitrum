# Verify gov-delegated-admin

Checks 1 to 5 are read-only `cast call REGISTRY ... --from D --rpc-url RPC`,
D a delegate of the job. "Works" means no revert.

1. Onboarder: `"addUser(address)" CANARY` works.
2. Catalog manager: `"addContractVersion(string,string,(address,bytes32,address),bytes32)" drill thing "(REGISTRY,V,Z)" V`
   works (V the bytes32 value 1, Z the zero address), and
   `capabilities has-capability CAP D` is true for both capabilities.
3. Policy author: `"createPolicy(bytes32,bytes32[],uint256[])" $(chainwall id drill-policy) "[GROUP]" "[1]"`
   works, GROUP being the delegate's own group id.
4. Each delegate is refused outside the job (each must revert
   `AccessControlUnauthorizedAccount`): `"createGroup(bytes32)" $(chainwall id drill)`,
   and `"grantCapabilityGroup(bytes32,bytes32)" CAP GROUP` with the delegate's
   own capability and group.
5. A delegate of one job is refused another job: an onboarder calling the
   `createPolicy` line reverts; a policy author or catalog manager calling
   `addUser` reverts. Run the pairs that exist.
6. Delay proof (governance.md), ACTOR = an onboarder if one exists, else
   OWNER: the delay binds delegates too.

Record every command and result.
