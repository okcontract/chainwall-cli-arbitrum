# Governance setups: shared mechanics

Read `../SKILL.md` first. The `gov-*.md` setups change who may change a
tenant's rules. They all use the mechanics below. Signer, profile, network
(Arbitrum One by default, Sepolia test mode on request), instance deploy,
terms and resume are the ones in [usdc-aave-vault.md](usdc-aave-vault.md),
followed by section name; no vault is needed, so ignore that file's profile
name, record name, USDC figures and signature counts. Use the active profile
or the one the user names (pass `--profile NAME` on every `chainwall` command
when it is not the active one, including inside the loop below), and write
the record file each setup names, on every network.

Instance step, in full: if the profile has no instance,
`chainwall deploy --owner OWNER --indexing --no-auth-accounts --salt "governance v1"`
(dry-run, estimate and resume as the vault's step 1, keeping this salt), then
`terms document --out terms.md --ipfs-gateway https://gateway.pinata.cloud/ipfs`,
show it, and `terms accept-terms --document-file terms.md` on the user's yes.

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
Signing with another person's keystore is allowed only when the user says
that key is theirs to use here.

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

Send the same loop with `--account NAME --json`; a failed write does not stop
the loop, so read each back with
`timelock get-category-config "$ID"` and resend any that does not read
`[[DELAY,2592000,DELAY,604800,POLICY]]`. Only then send `config` the same way:
it governs the delays themselves, and after it every correction waits DELAY.
`account` stays undelayed (account creation needs it). `roles pause` is never
timelocked.

## Reading an action

`timelock get-action-summary ID` prints one array: `[id, category, scope,
actor, queuedAt, delay, eta, expiresAt, status, policyId, payloadHash]`.
Status: 1 Queued, 2 Ready (approvals complete; without a policy an action
stays 1 until it executes), 4 Executed, 5 Cancelled, 6 Expired. `timelock get-pending-action-count` counts open actions.
Executing early: `cast call REGISTRY "executeAction(bytes32)" ID --from OWNER --rpc-url RPC`
reverts `TimelockActionNotReady(id, status)`.

## The drill change

Proofs use one harmless change: `users add 0x000000000000000000000000000000000000dEaD`
(CANARY). A user entry alone grants nothing, and nobody holds that key. A
drill that is cancelled leaves nothing behind. A drill that executes is
followed by `users remove CANARY` through the same path. Negative checks are
read-only `cast call REGISTRY "sig" args --from ADDR --rpc-url RPC`; every
`cast call` in the verify files takes `--rpc-url RPC` even where the line
omits it. Match raw revert data with `cast sig`.

Delay proof, run once after the delays are live unless the setup's own drill
already queued something: ACTOR (OWNER unless the verify file names another)
sends `users add CANARY` → `queued`; early `executeAction` reverts
`TimelockActionNotReady`. Then, when DELAY is 600 or less or the user chooses
to wait: after `eta` OWNER (anyone may) runs `timelock execute-action ID` → status 4,
`users contains CANARY` true, and `users remove CANARY` goes through the same
path. Otherwise `timelock cancel-action ID` → status 5.

## Finish

Run the vault setup's step 10 reads (owner, roles, bootstrap state; none of
its other Finish text applies). `ownership-handover-completed` true only
means the factory handed the tenant to OWNER; the owner shortcut is closed
only when `owner-bootstrap-finalized` is true. Then write the record:
network, Registry, every group with members, every grant, every category
config as read, every action id with its final status, every transaction
hash, those reads, and one plain table of who can do what.
