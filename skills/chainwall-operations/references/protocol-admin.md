# Setup: protocol admin behind Chainwall (Arbitrum One)

Read `../SKILL.md` first. Its rules on profiles, dry runs, signing and
"never invent a command, selector or address" apply throughout this setup.

## Outcome

The owner role of a protocol contract is held by a Chainwall OKAccount. Two
kinds of admin action are separated on chain:

- Routine: `setFee`, bounded to 1000 bps, runs under policy `admin-routine`
  with one approval and no delay.
- Sensitive: `setOracle`, runs under policy `admin-sensitive` with every
  approver's approval, and any new sensitive interaction waits one day in the
  `interaction` timelock category before it can be used.

The owner's own EOA can no longer call the contract directly. Ownership is
transferred as the final, separately reviewed step.


## Network

Arbitrum One by default. In Sepolia test mode (the user says so, or the
profile's chain is 11155111), take the factory, RPC and balance floors from
`networks.sepolia` in [usdc-aave-vault setup.json](../assets/usdc-aave-vault/setup.json)
and read every "Arbitrum One" and ETH figure below as its Sepolia equivalent;
the demo contract is deployed on that chain and nothing else changes.

## Target contract

Preferred: the user's own contract. Ask for its address and ABI, and which
functions are routine and which are sensitive; adapt the two scripts and two
policy programs accordingly, keeping the same shape.

Fallback for a demo: [contract/GuardedParams.sol](../assets/protocol-admin/contract/GuardedParams.sol),
a 30-line owner-gated parameter contract. Deploy it with `forge create` from the
user's signer and treat it as unreviewed demo code. Its ABI is
[params.json](../assets/protocol-admin/params.json).

Before any change, read `owner()` and show the user who holds it now. On a
contract with AccessControl, map every role holder the same way.

## Inputs

Fixed values are in [setup.json](../assets/protocol-admin/setup.json). Verify on chain and stop on
any mismatch:

- Chain 42161 (11155111 in Sepolia test mode). RPC: the one in the profile,
  else `https://arb1.arbitrum.io/rpc`.
- OKFactory `0x20d2eD7f3d008a70b2aED91CC7F9801Ff14b449b` (the `to` of
  `chainwall deploy --dry-run`); Sepolia `0xA27260B6c0F31Ed0f06daE7789eF00A6A1a9C8b7`.
- Target contract: address from the user, or the deployed demo. It must have
  code and return the user's signer from `owner()`.

## Signer and approvers

Signer: exactly as the base skill's "Check the signer first" section says
(keystore from `cast wallet list`, unlock as described there). Owner address
from `cast wallet address --account NAME`. Check the balance with
`cast balance`, floor 0.0015 ETH (Sepolia: the test-mode floor).

The signer is the owner, the routine operator, and one approver. If the user
names more approver addresses, add each to `admin-approvers` and set the
sensitive threshold to the group size; each approver needs ETH for its
approval call. With one approver the delay is the only extra control on
sensitive changes, and the setup says so in the final record.

## Profile

Use the active Chainwall profile (`chainwall config show`), or the one the
user names. Set `chain` (42161, or 11155111 in test mode) and the RPC on it if
missing. Do not create or switch profiles unasked. If it binds an instance on
that chain, reuse it; otherwise step 1 deploys and binds a new one.

## Names

Compute every id with `chainwall id NAME`.

| Thing | Name |
| --- | --- |
| Groups | `admin-operators` (signer), `admin-approvers` (signer plus any approvers) |
| Policies | `admin-routine` = [`admin-operators`], thresholds [1]; `admin-sensitive` = [`admin-approvers`], thresholds [group size] |
| Catalog | org `myprotocol`, contract `myprotocol/params` |
| Interactions | `admin-set-fee`, `admin-set-oracle` |

## Scripts

[set-fee.ls](../assets/protocol-admin/set-fee.ls), [set-oracle.ls](../assets/protocol-admin/set-oracle.ls),
[routine-policy.ls](../assets/protocol-admin/routine-policy.ls), [sensitive-policy.ls](../assets/protocol-admin/sensitive-policy.ls).
Replace `{{routinePolicyId}}`, `{{sensitivePolicyId}}`, `{{adminAccount}}`,
`{{setFeeId}}`, `{{setOracleId}}` with literals. No comments in .ls files.

Compile with `--abi myprotocol/params=params.json`, run `chainwall analyze` on
both interactions and show targets and selectors. Expected: set-fee
`0x69fe0e2d`, set-oracle `0x7adbf973`. Stop if an analysis is invalid,
incomplete, or targets anything else.

## Order

1. Instance. If the profile binds an instance on the chain, reuse it. Otherwise
   `chainwall deploy --dry-run` with `--owner OWNER --indexing
   --no-auth-accounts --salt "protocol-admin v1"`, confirm `to` is the
   OKFactory, then send it (three stages). `deploy` does not resume: for an
   owner and salt deployed before it fails with `DeploymentAlreadyStarted` and
   prints the Registry address; read `getInstance(address)` on the factory with that Registry address,
   `chainwall login ADDRESS` if `interact` is nonzero, else resume with
   `--stage prepare` then `--stage finalize --registry ADDRESS`, each with its
   own `--out`. Show the terms (`terms document --out terms.md`) and `terms accept-terms --document-file terms.md`
   only on the user's yes.
2. In this order: `users add` for the signer and each approver (membership
   needs an existing user); `groups create-group` for both groups;
   `groups add-group-member` for each member; `policies create-policy` for both
   policies (every group in a policy must already exist).
3. `accounts create --salt "protocol-admin v1"`. The caller must already be a
   user (step 2); creation registers the account atomically, which is why
   `timelock.category.account` is never delayed here. Record the address as
   `{{adminAccount}}`.
4. Catalog, only this entry, with `V` the bytes32 value 1 written in full and
   `Z` the zero address:
   `chainwall contracts add myprotocol params "(TARGET,$V,$Z)" "$V"`.
   (`orgs add` is optional for an admin; skip it.)
5. Fill templates, compile, analyze, show results.
6. `policies program publish admin-routine routine-policy.json` and
   `policies program publish admin-sensitive sensitive-policy.json`, then
   `interactions add set-fee.ls --id admin-set-fee --abi myprotocol/params=params.json`
   and `interactions add set-oracle.ls --id admin-set-oracle --abi myprotocol/params=params.json`.
   `--id` is required: the default id is the file stem, which the policy
   programs do not allow.
7. Grant `cap.registry.interaction.execute` to both groups (group grants, not
   actor grants).
8. Set each timelock category in setup.json to `(86400, 86400, 86400,
   604800, 0x0)` and read each back. The id is `chainwall id` of the full name
   (`chainwall id timelock.category.interaction`), never the bare suffix.
   `timelock.category.config` last. From here, every new interaction waits a
   day. Then read `ownerBootstrapFinalized` and the owner's roles and report
   them; do not finalize unless the user asks. The factory already enabled role
   governance and completed the ownership handover; finalizing needs only an
   explicit `TIMELOCK_GOVERNOR` grant to a group the owner is in, and until
   then the owner key is the implicit timelock governor, so the delays bound
   operators, not the owner.
9. Ownership handover, as its own reviewed step: show the exact
   `transferOwnership(adminAccount)` call on the target, the current owner, and
   what the EOA loses. Wait for the user's yes. The user signs it with the
   contract's current owner key (outside Chainwall). Read `owner()` back.

## Pauses

Exactly three: before accepting terms, before the ownership transfer, and
before any step in protocol-admin-verify.md that changes the target's state. Everything else
runs dry-run, then send, then verify.

## Prove it

Follow [protocol-admin-verify.md](protocol-admin-verify.md).

## Finish

Write `protocol-admin-record.md`: chain, instance, admin account and target
addresses, CLI version, every transaction hash, role map before and after, the
configuration read back from chain, a table of who can do what, and a line
stating how many approvers the sensitive policy has. If the CLI cannot do a
step, stop and name it.
