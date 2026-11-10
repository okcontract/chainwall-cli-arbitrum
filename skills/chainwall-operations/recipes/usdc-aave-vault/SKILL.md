# Recipe: guarded USDC vault on Arbitrum One (Aave v3)

Read `../../SKILL.md` first. Its rules on profiles, dry runs, signing and
"never invent a command, selector or address" apply throughout this recipe.

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

- Chain 42161. RPC `https://arb1.arbitrum.io/rpc` unless the user gives another.
- OKFactory `0x20d2eD7f3d008a70b2aED91CC7F9801Ff14b449b`. It must equal the `to`
  address of `chainwall deploy --dry-run`.
- USDC `0xaf88d065e77c8cC2239327C5EDb3A432268e5831`: `symbol()` is USDC,
  `decimals()` is 6.
- Aave v3 Pool `0x794a61358D6845594F94dc1DB02A252b5b4814aD`: `getPool()` on the
  PoolAddressesProvider `0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb` returns it.

Ask the user for nothing else. The only user-specific value is the signer.

## Signer

Use the signer configured in the Chainwall profile: `chainwall config show`
prints `account` (and `password_file` if set). Do not print, open or copy the
password file. Get the owner address with
`cast wallet address --account NAME` (add `--password-file PATH` only when the
profile has one; otherwise Foundry prompts the user).

If no account is configured, run `cast wallet list`. If it shows accounts, ask
the user which one to use. If it is empty, stop and tell the user to run one of
these in their own terminal, then `chainwall config set account NAME`:

```sh
cast wallet new NAME
cast wallet import NAME --interactive
```

Check any Foundry command with `cast <command> --help` before showing it.
The signer needs ETH on Arbitrum One for about 20 transactions. Read its
balance with `cast balance OWNER --rpc-url RPC` and stop if it is below
0.005 ETH.

## Profile

The user's default profile may be on another chain. Create and select a profile
named `usdc-vault`, set `chain 42161`, the RPC, and the same `account` and
`password_file` values. Leave the default profile unchanged.

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

Repeat for withdraw and payout. Show the user the targets, selectors and
warnings from each analysis. Expected selectors: supply `0x095ea7b3` then
`0x617ba037`; withdraw `0x69328dec`; payout `0xa9059cbb`. Stop if an analysis
is invalid, incomplete, or targets anything else.

## Order

Apply and verify each step on chain before the next. Follow
[setup.md](../../references/setup.md) and [authoring.md](../../references/authoring.md)
for exact commands.

1. `chainwall deploy` through the OKFactory, owner = the signer,
   `--indexing --no-auth-accounts --salt "usdc-aave-vault v1"`. The salt is
   fixed so the same owner always resolves to the same instance; rerunning the
   recipe resumes that instance instead of deploying a second one.
2. Download and show the terms document and its hash. Accept only after the
   user says yes.
3. Add the owner as a user, create the group, add the owner, create the policy.
4. `chainwall accounts create` the OKAccount. Record its address as `{{vault}}`.
5. Register orgs `circle` and `aave`, the Pool contract version, the USDC
   contract version and token record.
6. Fill the templates, compile, analyze, show results. This step cannot run
   before step 4 because `{{vault}}` is the OKAccount address.
7. Publish the policy program to `usdc-vault-policy`, then the three
   interactions under their ids.
8. Check the owner holds `cap.registry.interaction.execute`. If not, show the
   grant and wait for yes.
9. Last, set a 1 day delay (86400 seconds) on the timelock categories listed in
   recipe.json and read each back. Setting delays earlier queues the setup
   behind them.

If any write returns `queued`, finish that timelock action before the next step.

## Signing and pauses

Run every write with `--dry-run` first and show the output, then send it with
the profile signer. Pause for the user's explicit yes at exactly two points:
before accepting terms (step 2) and before the real 1 USDC supply (verify.md).
Never print keys, passwords or the password file.

## Prove it

Follow [verify.md](verify.md). No local fork or node.

## Finish

Write `usdc-vault-record.md`: chain ID, every address, `chainwall --version`,
every transaction hash, and the configuration read back from chain (users,
group, policy, catalog, interactions, timelock delays). Add a table of what the
vault can and cannot do. If the CLI cannot do a step, stop and name it.
