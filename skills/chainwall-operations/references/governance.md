# Governance setups: shared mechanics

Read `../SKILL.md` first. The `gov-*.md` setups change who may change a
tenant's rules. They all use the mechanics below. Signer, profile, network
(Arbitrum One by default, Sepolia test mode on request), instance deploy,
terms and resume are the ones in [usdc-aave-vault.md](usdc-aave-vault.md),
followed by section name; no vault is needed. Use the active profile or the
one the user names, deploy with `--salt "governance v1"` when the profile has
no instance, and write the record file each setup names.

## What governs what

- Owner: the deploying key. Until `finalize-owner-bootstrap` it is also an
  implicit timelock governor and upgrader.
- `ADMIN_ROLE`: grants and revokes capabilities, unpauses, cancels any queued
  action. The owner holds it after deploy.
- Capabilities: narrow powers held by groups. Ids are `chainwall id NAME` of
  the protocol names used in these setups; an invented name grants nothing.
- Timelock categories: every rule change belongs to one. A category config is
  `(minDelay, maxDelay, defaultDelay, gracePeriod, defaultPolicyId)`. With a
  delay or a policy set, the write returns `"status": "queued"` and
  `queuedActions[0]` is the action id. Delays bind every key, the owner
  included.
- A queued action runs with `timelock execute-action ID` by anyone once it is
  past `eta` and, when the category names a policy, approved by that policy's
  groups (`timelock approve-action ID`; queuing does not count as approving).

## People and keys

OWNER signs the setup. Other people (guardians, approvers, delegates) are
addresses the user gives; each must be an EOA they control (`cast code ADDR`
is `0x`) and needs a little gas for its own transactions (0.0002 ETH on
Arbitrum One, 0.002 on Sepolia). When another person must sign, use their
keystore if it is on this machine, else hand the user the exact command for
them, in cast form so they need no Chainwall profile:
`cast send REGISTRY "approveAction(bytes32)" ID --account NAME --rpc-url RPC`.

If the user has nobody else yet and wants to rehearse, they create the extra
keystores themselves (`cast wallet new ~/.foundry/keystores NAME` in their own
terminal) and OWNER sends each the gas above with `cast send`. Say in the
record that all keys belong to one person.

## Order inside every setup

1. Instance and terms (vault steps 1 and 2).
2. `users add` for OWNER and every person, then groups, members, policies and
   capability grants, each verified by a read before the next.
3. Delays last, `config` very last (see below). Anything sent after a delay is
   live queues for that delay.

If a category already has a delay or policy when the setup starts
(`timelock get-category-config`), writes in it queue. Say so first; send what
is ready, record each action id and `eta`, list what remains and stop. Resume
after `eta` with `timelock execute-action`.

## Delays

DELAY is 86400 seconds unless the user asks for another value (a rehearsal on
Sepolia may use 60). POLICY is the 32-byte zero word unless the setup names an
approval policy. Never type a category id; compute it from the full name:

```sh
CFG="($DELAY,2592000,$DELAY,604800,$POLICY)"
for NAME in user policy contract token interaction activation capability group role.admin diamond; do
  ID=$(chainwall id "timelock.category.$NAME")
  chainwall timelock set-category-config "$ID" "$CFG" --dry-run
done
```

Send the same loop with `--account NAME --json`, read each back with
`timelock get-category-config "$ID"`, and resend any that does not read
`[[DELAY,2592000,DELAY,604800,POLICY]]`. Only then send `config` the same way:
it governs the delays themselves, and after it every correction waits DELAY.
`account` stays undelayed (account creation needs it). `roles pause` is never
timelocked.

## Reading an action

`timelock get-action-summary ID` prints one array: `[id, category, scope,
actor, queuedAt, delay, eta, expiresAt, status, policyId, payloadHash]`.
Status: 1 Queued, 2 Ready (approvals complete), 4 Executed, 5 Cancelled,
6 Expired. `timelock get-pending-action-count` counts open actions.
Executing early: `cast call REGISTRY "executeAction(bytes32)" ID --from OWNER --rpc-url RPC`
reverts `TimelockActionNotReady(id, status)`.

## The drill change

Proofs use one harmless change: `users add 0x000000000000000000000000000000000000dEaD`
(CANARY). A user entry alone grants nothing, and nobody holds that key. A
drill that is cancelled leaves nothing behind. A drill that executes is
followed by `users remove CANARY` through the same path. Negative checks are
read-only `cast call REGISTRY "sig" args --from ADDR --rpc-url RPC`; match raw
revert data with `cast sig`.

## Finish

Write the record: network, Registry, every group with members, every grant,
every category config as read, every action id with its final status, every
transaction hash, and one plain table of who can do what. Then the vault
setup's step 10 reads (owner, roles, bootstrap state).
