# Recipe: guarded USDC vault on Arbitrum One (Aave v3), with a free Sepolia test mode

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

## Start here: tell the user what to expect

Assume the user has never used Chainwall, Foundry or a keystore. Do the
read-only checks first (tools below, Signer, Inputs, Resume), then send one
short opening message in plain words that fits what is actually left:

- What they get: the Outcome above, in two sentences.
- What they need, only the parts still needed: a Mac or Linux terminal;
  Foundry's `cast` and the Chainwall CLI; one Foundry keystore for the owner;
  ETH on Arbitrum One for gas (about 0.002 ETH for a fresh deploy, much less
  when the instance exists); 5 USDC on Arbitrum One for the final test (not
  needed if Resume shows the real run already happened). On Sepolia: only free
  Sepolia test ETH from a faucet; the test USDC is minted for them.
- What they will do themselves, only the parts still needed: pick the keystore
  (if there are several); give the keystore password once so the agent can
  sign (or choose Touch ID or scripts instead); say yes to the terms (if not yet accepted) and to the real supply (if
  not yet run); send 5 USDC to the vault (same condition). Everything else the
  agent does or prepares.
- On a resumed run, say first what is already done and what is left, in one
  line each, before any detail.

Explain any term the user must act on in a few words the first time it
appears, for example: "a keystore is the encrypted file that holds your wallet
key"; "the keystore password unlocks that key; I use it only to sign this setup"; "a timelock delay
makes rule changes wait 24 hours before they apply".

Check the tools and stop with the exact fix when one is missing:

- `cast --version` fails: the user installs Foundry in their own terminal with
  `curl -L https://foundry.paradigm.xyz | bash` and then `foundryup`.
- `chainwall --version` fails: the user installs a verified Chainwall CLI
  distribution (https://chainwall.org) or builds it as in
  [setup.md](../../references/setup.md).
- `cast wallet list` is empty: the user runs `cast wallet new NAME` (or
  `cast wallet import NAME --interactive` for an existing key) in their own
  terminal, chooses a password there, and funds that address with ETH on
  the network in use. Give them the address to fund once they can share it.

Keep every later message to the user short: what just happened, what is next,
and what (if anything) they must do. Never ask a question whose answer is
already in this recipe or on chain.

## Network

Arbitrum One is the default and the only network with real money. If the
user's request names Sepolia (or "testnet"), use the free Ethereum Sepolia test
network instead: take every chain value below from `networks.sepolia` in
recipe.json, and wherever this recipe says Arbitrum One, 42161, ETH or USDC,
read the Sepolia equivalent (Sepolia test ETH; Aave's Sepolia test USDC). Say
which network you are using in the opening message. Never mix the two: every
command in one run uses the same chain, RPC and addresses.

Sepolia differences, all of them:

- Profile: use a dedicated profile named `usdc-vault-sepolia`. If
  `chainwall profile list` does not have it, create it with
  `chainwall profile create usdc-vault-sepolia`, then set four keys on it with
  `chainwall --profile usdc-vault-sepolia config set KEY VALUE`: `chain`
  `11155111`, `rpc_url` (`networks.sepolia.defaultRpc`), `factory`
  (`networks.sepolia.okFactory`) and `account` (the keystore name). Pass
  `--profile usdc-vault-sepolia` on every `chainwall` command; in zsh a function
  is the reliable shortcut: `cw() { chainwall --profile usdc-vault-sepolia "$@"; }`
  (a variable such as `P="chainwall --profile …"; $P …` fails with "command
  not found").
- RPC: the deploy needs an RPC that allows very large gas estimates (stage 1
  estimates about 73M gas, gas limit about 88M). Use
  `networks.sepolia.defaultRpc` (Tenderly's public gateway). Some public RPCs,
  such as publicnode, reject it: `deploy --estimate` prints "The RPC rejected a
  read" and a send fails with a bare `TransactionFailed`. Before the first
  deploy send, run `deploy … --estimate --from OWNER`; it must print
  `"balanceSufficient": true`. If the RPC rejects it, switch `rpc_url` to
  another Sepolia RPC that passes this estimate before anything is sent. This is the one
  case where the recipe creates a profile; it never changes the active profile.
- Factory: the CLI bundles no Sepolia factory (`deploy` fails with
  `FactoryRequired` otherwise); the profile's `factory` key supplies it.
- Gas: Sepolia ETH is free from public faucets. Use only
  `networks.sepolia.minSignerBalanceWei` (0.02 ETH to deploy, 0.002 ETH when
  the instance exists); the ETH figures in Signer are Arbitrum One. If the
  owner has less, tell the user to get about 0.05
  Sepolia ETH from a Sepolia faucet for the owner address and wait. A fresh
  Sepolia deploy uses far more gas than Arbitrum (about 180M across the three
  stages) but costs almost nothing at Sepolia prices.
- USDC: Aave on Sepolia accepts only its own test USDC
  (`networks.sepolia.usdc`), not Circle's Sepolia USDC. The catalog still names
  it `circle/usdc`, so every script, id and policy is identical across networks.
- Funding the vault (verify.md check 4): instead of asking the user to send
  USDC, mint 5 test USDC straight to the vault with the open Aave faucet:
  `cast send FAUCET "mint(address,address,uint256)" USDC VAULT 5000000 --account NAME --rpc-url RPC`
  (dry-run first with `cast call ... --from OWNER`). It is free and moves none
  of the user's funds.

## Inputs

Fixed values are in [recipe.json](recipe.json) (Arbitrum One shown here; for
Sepolia use `networks.sepolia`). Verify each on chain before use and stop on
any mismatch:

- Chain 42161. RPC: the one in the profile, else `https://arb1.arbitrum.io/rpc`.
- OKFactory `0x20d2eD7f3d008a70b2aED91CC7F9801Ff14b449b`. It must equal the `to`
  address of `chainwall deploy --dry-run`.
- USDC `0xaf88d065e77c8cC2239327C5EDb3A432268e5831`: `symbol()` is USDC,
  `decimals()` is 6.
- Aave v3 Pool `0x794a61358D6845594F94dc1DB02A252b5b4814aD`: `getPool()` on the
  PoolAddressesProvider `0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb` returns it.
- The same USDC must be an Aave reserve: `getReserveData(USDC)` on the Pool
  returns a nonzero aToken address.

In the commands and templates below, `USDC`, `POOL`, `FACTORY`, `RPC` and the
chain id mean the values of the network in use.

Never ask the user about these values. The user is asked only about the
things listed under "What they will do themselves" in Start here.

## Signer

Resolve the keystore as the base skill says: `cast wallet list`; one entry is
the signer, several means ask, none means stop (see Start here). When asking,
offer the keystore named by the profile's `account` key first.

Ask for the keystore password once. The agent's shell cannot answer a password
prompt, and a fresh run has about 32 signatures (3 deploy stages, terms, user,
group and member, policy, vault, 2 orgs, 2 contracts, token, program, 3
interactions, capability, 9 delays, propose, execute; plus the faucet mint on
Sepolia). So, right after the opening message and before any write, ask:

> "To sign the setup transactions without prompting you about 32 times, I need
> the password of your `NAME` keystore once. I keep it only in a private
> temporary file on this machine for this run and delete it when we finish.
> It will be visible in this chat, so prefer a test or dev wallet; if you would
> rather not share it, say so and I will use Touch ID or give you scripts to
> run instead."

Handle the password exactly like this:

1. Create a private file: `PWFILE=$(mktemp -t chainwall-session)` (mode 600,
   outside the project). Write the password into it with your file-writing
   tool, as the only content with no trailing newline. Never put the password
   in a shell command, an environment variable, a script, a log, the record
   file, memory, or a later message; never repeat it back.
2. Prove it works before any write:
   `cast wallet address --account NAME --password-file "$PWFILE"` prints the
   owner address (this is OWNER, and the proof that the keystore is that
   address), and
   `cast wallet sign --account NAME --password-file "$PWFILE" "chainwall signing check"`
   prints a signature. If either fails, the password is wrong: empty the file,
   say so, and ask once more.
3. Pass `--account NAME --password-file "$PWFILE"` on every write (`chainwall`
   writes and any `cast send`). Do not store the path in the profile.
4. When the run ends, including when it stops early or fails, delete the file
   (`rm -f "$PWFILE"`), confirm it is gone, and tell the user: "I deleted the
   temporary password file. Your password was shown in this chat, so change it
   if this is a wallet you use for real funds."

Existing password file. If `chainwall config show` already lists
`password_file` and that file exists, the user set it up earlier: do not ask
for the password. Run the two checks in item 2 with that path, sign with it,
and leave it in place at the end. Never open, print, move or delete a password
file you did not create. If the path does not exist, tell the user in one line
and ask for the password as above.

If the user declines to share the password, use one of these instead and say
which:

- Touch ID (macOS). `cast wallet touch-id status NAME`; if not enrolled, the
  user runs `cast wallet touch-id enroll NAME` once in their own terminal. Then
  the agent sends each write and the user approves each one on their Mac. Tell
  them the number of prompts and that nothing proceeds while one is unanswered.
  Before the first write, say "a Touch ID prompt appears now; approve it" and
  run `cast wallet sign --account NAME "chainwall signing check"` with a
  timeout of about 120 seconds. No result in that time means the prompt was
  missed: stop and ask; send nothing until it works. Apply the same 120-second
  rule to every later write; ask the user, do not resend.
- The user's own terminal. The agent dry-runs every write in a phase, then
  writes one shell script per phase (for example `step3-users.sh`,
  `step9-timelocks.sh`) that sends those writes in order with
  `set -euo pipefail`, saves each result with `--json | tee logs/NAME.json`,
  and reads each change back. Each script starts with `cd "$(dirname "$0")"`
  and passes `--profile PROFILE` on every `chainwall` command so it works from
  any folder. Tell the user the one exact line to run, for example
  `zsh /full/path/step9-timelocks.sh`; cast asks them for the password at each
  send. One script per phase (steps 1, 2, 3, 4, 5, 7, 8, 9; step 6 has no
  writes). After each script, read its logs and verify on chain before writing
  the next one.

Without a password or Touch ID, read the owner address by asking the user to
run `cast wallet address --account NAME` in their own terminal and paste the
address. Do not infer the owner from the Registry or old logs.

The signer needs ETH on the network for about 20 transactions (Sepolia limits: `networks.sepolia.minSignerBalanceWei`; the figures below are Arbitrum One). Read its
balance with `cast balance OWNER --rpc-url RPC`. Stop below 0.0015 ETH when the
instance still has to be deployed; when it already exists, the remaining
writes are at most about 2M gas in total (step 9 alone is about 117k gas per
category, about 1.05M for all nine), so stop only below 0.0002 ETH. These
limits assume Arbitrum's usual gas price (well under 0.1 gwei). Check
`cast gas-price --rpc-url RPC`; if it is higher, the limit is the remaining
gas times that price, with a 2x margin. The fee is small, but a send reserves `gasLimit x maxFeePerGas` up
front and the factory stages are large (stage 1 estimates around 16.5M gas), so
a stage can be refused on balance while the fee itself is affordable. If that
happens, send that stage with `cast send` and an explicit tight `--gas-limit`
and `--gas-price`, then bind the instance with `chainwall login ADDRESS`.

## Profile

On Arbitrum One, use the active Chainwall profile (`chainwall config show`).
Set `chain 42161` and the RPC on it if they are missing. Do not create or
switch profiles. (On Sepolia, see Network.) If the profile already binds an
instance on the network's chain, step 1 reuses it; otherwise step 1 deploys and
`deploy` binds the new instance to this profile.

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
replace `{{policyId}}` (bytes32), `{{vault}}`, `{{owner}}`, `{{usdc}}` and `{{pool}}`
(addresses; `{{usdc}}` and `{{pool}}` are the network's USDC and Aave Pool), and in
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

## Resume: check state before any write

People rerun this recipe after a partial attempt. If the profile binds no
instance on the network's chain, nothing is done yet: skip this section and start at step 1.
Otherwise run `chainwall status` and the reads below, with ids from
`chainwall id`, and show the user a table of which steps are done. Skip a step
only when its read shows exactly the recipe's values; if a read shows something
else (another vault, another member, a different program), stop and ask rather
than overwrite.

Use only live chain reads here. `users list`, `timelocks list` and `search`
read the local SQLite cache, which can be a day or more old. Some reads print a
bare value (`1`, `true`, an address); reads that return arrays or tuples print
nested JSON such as `[[…]]`, with bytes32 values as quoted strings. Compare
values, not text.

| Step | Live read | Done when |
| --- | --- | --- |
| 1 Instance | `status` (with `--all-chains` if needed) | `"status": "installed"` and `"complete": true` |
| 2 Terms | `terms instance-has-accepted-initial-terms` | `true` |
| 3 Users | `users contains OWNER` | `true` |
| 3 Group | `registry get-group-members GROUP` | `[["OWNER"]]` (exactly one member, case-insensitive) |
| 3 Policy | `registry get-policy-criteria POLICY` | `[["GROUP"],["1"]]` |
| 4 Vault | `registry get-account-count`, then `registry get-account-at 0` | count ≥ 1; the address is the vault (ask if count > 1) |
| 5 Catalog | `registry get-address circle usdc`, `registry get-address aave pool-v3` | the recipe.json addresses |
| 7 Publish | `registry get-policy-program POLICY`; `registry get-interaction-keys-page 0 10`; `interactions source ID` for each | program bytes nonempty; all three interaction ids present; each source shows this vault, policy and (payout) owner |
| 8 Capability | `registry get-capability-groups CAP` | contains GROUP |
| 9 Delays | `timelock get-category-config $(chainwall id timelock.category.NAME)` for every NAME in recipe.json | each is `[[86400,86400,86400,604800,"0x00…00"]]`. The factory default `[[0,2592000,0,2592000,"0x00…00"]]` (zero delay) means **not done**. `has-category-config` is true for both, so never use it to decide this row |
| Pending | `timelock get-pending-action-count` | `0`; otherwise list them with `timelock get-pending-action-summaries 0 50` and finish or cancel each before dependent steps |
| Real run | `accounts activity VAULT` | a record with `interactionId` = the supply id and `caller` = OWNER means the real 1 USDC supply already ran: do not run it again (verify.md step 4) |

Steps 6 and 10 have no chain state of their own: rerun them.

Wrong-id check for step 9. An earlier attempt may have set delays on the hash
of a bare suffix (`chainwall id policy` instead of
`chainwall id timelock.category.policy`). Check each bare suffix with
`timelock has-category-config $(chainwall id SUFFIX)`. `true` means that
mistake happened. Those entries are inert: the Registry looks up only the full-name ids, so
they delay nothing and protect nothing. The CLI has no command to delete a category
config; leave them, tell the user in one line, list them in the record, and
still do step 9 on the real ids.

`accounts activity` currently shows wrong block numbers, 2022 timestamps and
`transactionHash: null` (seen on Arbitrum; a CLI defect). Use it only to see *that*
an interaction ran and by whom; take hashes from logs (see Finish). The
activity may also show withdraw or payout runs made outside this recipe; list
them in the record as found, without judging them.

## Order

The order is forced by the contracts; each line says why. Apply and verify each
step on chain before the next. Follow [setup.md](../../references/setup.md) and
[authoring.md](../../references/authoring.md) for command details. Those
references use short aliases for some commands in this list (`groups add`,
`groups add-member`, `policies add`); they are the same commands as
`groups create-group`, `groups add-group-member` and `policies create-policy`.
Use the names written here.

Help names. A few commands here are aliases that `--help` lists under their
contract method name: `orgs add` is `upsert-org` in `chainwall orgs --help`,
and `contracts add` is `add-contract-version` in `chainwall contracts --help`.
Both names work. If a
command seems missing, check these before concluding it does not exist.

1. Instance. If the profile already binds an instance on the network's chain, reuse it and go
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

   If a send ends with `TransactionFailed` and no transaction hash, check
   `cast nonce OWNER --rpc-url RPC`. If the nonce did not change, nothing was
   broadcast (the `deployment.json` it wrote can still say `"prepared"`; ignore
   it). The two usual causes are a signing problem (wrong password file, or an
   unanswered Touch ID prompt; rerun the signing check in Signer) and
   an RPC that rejects the large estimate (run `deploy … --estimate --from
   OWNER`; see Network). Fix the cause, then send again with a new `--out` file
   name. If the nonce did change, recover that transaction's receipt first.
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
   admin, kept for readability). `orgs add` is `upsertOrg(string id, address
   owner_, bool rugged, address[] initialMembers)`; pass it as
   `chainwall orgs add --args-file org-circle.json` with
   `{"id":"circle","owner_":"OWNER","rugged":false,"initialMembers":[]}`, and
   the same for `aave`. `contracts add` is
   `addContractVersion(string org, string id, (address addr, bytes32 version,
   address implementation), bytes32 label)`. Use exactly:

   ```sh
   V=0x0000000000000000000000000000000000000000000000000000000000000001
   Z=0x0000000000000000000000000000000000000000
   chainwall contracts add aave pool-v3 "(POOL,$V,$Z)" "$V" --dry-run
   chainwall contracts add circle usdc "(USDC,$V,$Z)" "$V" --dry-run
   ```

   (`version` and `label` are both the bytes32 value 1, written in full.) Then
   `tokens upsert-token` for `circle/usdc` with
   `'("circle","usdc","USDC",6,0x0000000000000000000000000000000000000000,0)'`;
   its log file is named `tokens-configure`, which is the same write.
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
9. Delays, last. Before sending, tell the user: once this step is done, any
   later change to policy, catalog, interactions, capabilities, groups, roles
   or the diamond (including a rerun that "fixes" an earlier step) returns
   `queued` and applies only after 86400 seconds; track it with
   `timelock get-pending-action-count`.

   Never type or paste a category id. Compute it inside the same command from
   the full name, exactly in this form, for these names in this order
   (`config` last: it governs the others, and any delay set earlier queues the
   remaining setup):

   ```sh
   CFG='(86400,86400,86400,604800,0x0000000000000000000000000000000000000000000000000000000000000000)'
   for NAME in policy contract token interaction capability group role.admin diamond config; do
     ID=$(chainwall id "timelock.category.$NAME")
     chainwall timelock set-category-config "$ID" "$CFG" --dry-run
   done
   ```

   For the send, use the same loop without `--dry-run` and with
   `--account NAME --json | tee logs/timelock-$NAME.json`, followed in the loop
   by `chainwall timelock get-category-config "$ID"` on that same `$ID`. A
   result of `[[86400,86400,86400,604800,"0x00…00"]]` is done. `chainwall id
   policy` (the bare suffix) is a different, inert id: see Resume. Each write
   costs about 117k gas.
10. Governance state. Read `registry owner-bootstrap-finalized`,
    `registry ownership-handover-completed`, `registry role-governance-enabled`,
    and `registry has-role ROLE OWNER` for the values of `registry admin-role`,
    `registry upgrader-role` and `registry default-admin-role`, and report them.
    Do not call `finalize-owner-bootstrap`: it is out of scope for this recipe,
    and neither the CLI help nor the manual names the grant it needs. If the
    user asks for it, say so and stop rather than guess a role or capability id.

If any write returns `queued`, finish that timelock action before the next step.

## Signing and pauses

Run every write with `--dry-run` first and show the output, then send it with
`--account NAME` and the signing method chosen in Signer. Pause for the user's explicit yes at exactly two points:
before accepting terms (step 2) and before the real 1 USDC supply (verify.md).
Never print keys or passwords.

## Prove it

Follow [verify.md](verify.md). No local fork or node.

## Finish

Write `usdc-vault-record.md` (`usdc-vault-sepolia-record.md` on Sepolia, stating at the top that it is a test network with no real value): chain ID, every address, `chainwall --version`,
every transaction hash, and the configuration read back from chain (users,
group, policy, catalog, interactions, timelock delays, and any inert
bare-suffix category configs found in Resume). Add a table of what the vault
can and cannot do. Then state the governance position using the step 10 reads,
in plain words:

Build it from three parts, each from the reads, never assumed:

1. Roles: "The owner holds ADMIN_ROLE: yes/no; UPGRADER_ROLE: yes/no" as read.
2. Delays: if every step 9 read is `[[86400,…]]`, "Rule changes wait 24 hours
   before they apply."; otherwise "No timelock delays are active; every rule
   change applies immediately." Never claim delays bound anyone when they are
   not set.
3. Bootstrap: if `owner-bootstrap-finalized` is false, "Owner bootstrap is not
   finalized, so the owner key still acts as the timelock governor: any delays
   bound other operators, not the owner."

Always end with: "Keep the owner key safe: whoever holds it can change the
vault's rules."

If a receipt or read shows an address the recipe does not name, list it as
"unidentified address seen in EVENT" rather than guessing what it is.

Write the record for a reader who has never used Chainwall: one opening
paragraph on what the vault is and what it can do, then the details.

If the CLI cannot do a step, stop and name it.

Transaction hashes. Take them from `chainwall logs list`, then
`chainwall logs show FILE` with the file name (including `.json`) or full path
that `logs list` prints; a bare name returns "Log not found". Logs span
sessions and profiles in the config directory. Also read the phase scripts'
`logs/` folder. A log with `"status": "error"` and `TransactionMonitorTimedOut`
can still hold a transaction that succeeded: take `submissions[].hash` and
check it with `cast receipt HASH --async --rpc-url RPC` (without `--async`,
cast can wait minutes for a receipt). Record the receipt's status, not the
log's. For a step completed in an earlier session whose
log is gone, write "done before this session, hash not recovered" with the read
that proves the state; never invent or guess a hash.
