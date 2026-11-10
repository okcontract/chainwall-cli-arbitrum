# Recipe: guarded USDC vault on Arbitrum One (Aave v3)

Read `../../SKILL.md` first. Its rules on profiles, dry runs, signing and
"never invent a command, selector or address" apply throughout this recipe.
Take every command's exact flags from `chainwall <command> --help --json`.

## Outcome

A Chainwall OKAccount on Arbitrum One that holds USDC and can do exactly three
things, each capped at 100 USDC per operation: supply USDC to Aave v3, withdraw
it back to the vault, and pay USDC out to the owner's wallet. Every other call is
rejected on chain. The recipe ends with one real 1 USDC supply and a record file.

The user is owner, administrator, operator and sole approver. Nothing in this
recipe adds other people or grants anything beyond the three interactions.

## Inputs

Fixed values are in [recipe.json](recipe.json). Verify each on chain before use
and stop on any mismatch:

- Chain 42161. RPC: the one in the profile, else `https://arb1.arbitrum.io/rpc`.
- OKFactory `0x20d2eD7f3d008a70b2aED91CC7F9801Ff14b449b`. It must equal the `to`
  address of `chainwall deploy --dry-run`.
- USDC `0xaf88d065e77c8cC2239327C5EDb3A432268e5831`: `symbol()` is USDC,
  `decimals()` is 6.
- Aave v3 Pool `0x794a61358D6845594F94dc1DB02A252b5b4814aD`: `getPool()` on the
  PoolAddressesProvider `0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb` returns it.

Ask the user for nothing else. The only user-specific value is the signer.

## Signer

Resolve the keystore as the base skill says: `cast wallet list`; one entry is
the signer, several means ask, none means stop. Pass it as `--account NAME` on
every write. The owner address comes from `cast wallet address --account NAME`,
or from the user if the keystore cannot be unlocked in this shell. No password
in chat, no password file; Touch ID enrollment or the user's own terminal for
signatures.

The signer needs ETH on Arbitrum One for about 20 transactions. Read its
balance with `cast balance OWNER --rpc-url RPC`. Stop below 0.0015 ETH when the
instance still has to be deployed; when it already exists, the remaining
writes are about 2M gas in total, so stop only below 0.0002 ETH. The fee is small, but a send reserves `gasLimit x maxFeePerGas` up
front and the factory stages are large (stage 1 estimates around 16.5M gas), so
a stage can be refused on balance while the fee itself is affordable. If that
happens, send that stage with `cast send` and an explicit tight `--gas-limit`
and `--gas-price`, then bind the instance with `chainwall login ADDRESS`.

## Profile

Create and select a Chainwall profile named `usdc-vault` with `chain 42161`,
the RPC, and `account NAME`. Leave other profiles unchanged.

## Names

Compute every id with `chainwall id NAME`; never type an id from memory.

| Thing | Name |
| --- | --- |
| Group (one member: owner) | `usdc-vault-approvers` |
| Policy, criteria `[group]`, thresholds `[1]` | `usdc-vault-policy` |
| Catalog token | `circle/usdc` (org `circle`) |
| Catalog contract | `aave/pool-v3` (org `aave`) |
| Interactions | `usdc-vault-supply`, `usdc-vault-withdraw`, `usdc-vault-payout` |

Nothing else goes in the catalog.

## Scripts

[supply.ls](supply.ls), [withdraw.ls](withdraw.ls), [payout.ls](payout.ls) and
[policy.ls](policy.ls) are templates. Copy them into the working project and
replace `{{policyId}}` (bytes32), `{{vault}}` and `{{owner}}` (addresses), and in
`policy.ls` also `{{supplyId}}`, `{{withdrawId}}`, `{{payoutId}}`. The CLI does
not interpolate. The parser accepts no comments.

Each interaction takes one argument: the USDC amount in base units (6 decimals;
1 USDC is `1000000`). The policy program caps it at `100000000`.

Compile with the bundled ABIs ([erc20.json](erc20.json), [pool.json](pool.json)):

```sh
chainwall compile supply.ls --abi circle/usdc=erc20.json --abi aave/pool-v3=pool.json --out supply.json
chainwall analyze supply.json
chainwall policies program compile policy.ls --out policy.json
```

Repeat for withdraw and payout. Named `@contract` and `@token` references
resolve against the connected Registry, so this runs after step 5 below. Show
the user the targets, selectors and warnings from each analysis. Expected
selectors: supply `0x095ea7b3` then `0x617ba037`; withdraw `0x69328dec`; payout
`0xa9059cbb`. Stop if an analysis is invalid, incomplete, or targets anything
else.

## Order

The order is forced by the contracts; each line says why. Apply and verify each
step on chain before the next. Follow [setup.md](../../references/setup.md) and
[authoring.md](../../references/authoring.md) for command details.

1. Instance. If the profile already binds an instance on 42161, reuse it and go
   to step 2. Otherwise run `chainwall deploy --dry-run` with
   `--owner OWNER --indexing --no-auth-accounts --salt "usdc-aave-vault v1"`,
   confirm `to` is the OKFactory, then send it. `deploy` runs three stages
   (bootstrap, prepare, finalize). It does not resume: if this owner and salt
   were deployed before it fails with `DeploymentAlreadyStarted` and prints the
   Registry address. Then read `getInstance(address)` on the factory: a nonzero
   `interact` means the instance is complete, so `chainwall login ADDRESS`;
   zero means resume with `chainwall deploy --stage prepare --registry ADDRESS`
   then `--stage finalize --registry ADDRESS`, each with its own `--out` file
   (`PathAlreadyExists` otherwise). If a stage broadcasts and the CLI times out
   waiting for the receipt, do not resend: confirm the stage by nonce and
   receipt, then resume the same way.
2. Terms. `chainwall terms document --out terms.md`, show the document and its
   hash (retry with `--ipfs-gateway https://gateway.pinata.cloud/ipfs` if the
   default gateway fails). Accept with `terms accept-terms HASH` only after the
   user says yes. Nothing executes until the instance has accepted its initial
   terms.
3. Users, group, policy, in this order: `users add OWNER` (membership requires
   an existing user); `groups create-group` for `usdc-vault-approvers`;
   `groups add-group-member GROUP OWNER`; `policies create-policy` for
   `usdc-vault-policy` with group ids `[GROUP]` and thresholds `[1]` (every group
   in a policy must already exist).
4. Vault. `chainwall accounts create --salt "usdc-aave-vault v1"`. The caller
   must already be a user (step 3), and creation registers the account in the
   Registry in the same transaction, which is why `timelock.category.account`
   is never delayed in this recipe. Record the address as `{{vault}}`.
5. Catalog, in this order. `orgs add` for `circle` and `aave` (optional for an
   admin, kept for readability). `contracts add` for `aave/pool-v3` with the
   Pool address, and for `circle/usdc` with the USDC address; `version` and
   `label` are bytes32, use `0x…01`, implementation `0x0`. Then
   `tokens upsert-token` for `circle/usdc` with
   `("circle","usdc","USDC",6,0x0000000000000000000000000000000000000000,0)`.
   The token write reverts `TokenContractMissing` unless the `circle/usdc`
   contract version exists first; a zero feed requires `priceFeedDecimals` 0.
6. Fill the templates, compile, analyze, show results.
7. Publish. `policies program publish usdc-vault-policy policy.json`, then
   `interactions add supply.ls --id usdc-vault-supply --abi circle/usdc=erc20.json --abi aave/pool-v3=pool.json`
   and the same for withdraw and payout with their ids. `--id` is required:
   without it the id is the file stem (`supply`), which the policy program does
   not allow.
8. Execute capability. `capabilities grant-capability-group` with capability
   `chainwall id cap.registry.interaction.execute` and the group hash. Grant to
   the group, never to the owner address: actor grants are only for system
   contracts and revert `ActorCapabilityNotSystem`.
9. Delays, last. For each category in recipe.json, `timelock set-category-config`
   with `(86400, 86400, 86400, 604800, 0x0000000000000000000000000000000000000000000000000000000000000000)`,
   then `timelock get-category-config` to read it back. The category id is
   `chainwall id` of the full name, for example
   `chainwall id timelock.category.policy`; the bare suffix hashes to a
   different, meaningless id. Set `timelock.category.config` last of all: it
   governs the others, and any delay set earlier queues the remaining setup.
10. Governance state. Read `ownerBootstrapFinalized` and the owner's roles and
    capabilities, and report them. Do not call `finalize-owner-bootstrap`
    unless the user asks.

If any write returns `queued`, finish that timelock action before the next step.

## Signing and pauses

Run every write with `--dry-run` first and show the output, then send it with
`--account NAME`. Pause for the user's explicit yes at exactly two points:
before accepting terms (step 2) and before the real 1 USDC supply (verify.md).
Never print keys or passwords.

## Prove it

Follow [verify.md](verify.md). No local fork or node.

## Finish

Write `usdc-vault-record.md`: chain ID, every address, `chainwall --version`,
every transaction hash, and the configuration read back from chain (users,
group, policy, catalog, interactions, timelock delays). Add a table of what the
vault can and cannot do, and state this: the factory already enabled role
governance and completed the ownership handover, and the owner holds
`ADMIN_ROLE` and `UPGRADER_ROLE`; until `finalizeOwnerBootstrap` runs, which
needs an explicit `TIMELOCK_GOVERNOR` grant to a group the owner is in, the owner
key is the implicit timelock governor, so the delays bound operators, not the
owner. If the CLI cannot do a step, stop and name it.
