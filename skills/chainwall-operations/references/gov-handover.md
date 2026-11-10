# Setup: close the owner shortcut and hold governor power in a group

Shared mechanics: [governance.md](governance.md). Record: `gov-handover-record.md`.

## Outcome

Until now the owner key could reconfigure delays and start upgrades simply by
being the owner. After this setup that implicit power is gone for good:
timelock governance belongs to the `governors` group, whose membership is a
visible, delayed rule like any other.

## Inputs

Ask for the other governors' addresses (none is allowed: OWNER alone, held
explicitly) and whether each signs on this machine.

## Mechanics the user should hear first

- `capabilities finalize-owner-bootstrap` is permanent. It needs role
  governance and the ownership handover to be complete (the factory does both;
  read `registry role-governance-enabled` and
  `registry ownership-handover-completed`), the owner to hold `ADMIN_ROLE` and
  `UPGRADER_ROLE`, and the caller to hold `cap.registry.timelock.write`.
- It runs in `timelock.category.diamond`, so do it before the delays or it
  queues.
- What stays with OWNER: `owner()`, `ADMIN_ROLE` and `UPGRADER_ROLE`. What
  goes: acting as governor, upgrader or org writer without an explicit grant.
  To take single-key power off rule changes as well, run
  [gov-approved-changes.md](gov-approved-changes.md) next.

## Order

1. Instance, terms; `users add` OWNER and each governor.
2. `groups create-group $(chainwall id governors)`; add OWNER and each
   governor; read the members.
3. `capabilities grant-capability-group $(chainwall id cap.registry.timelock.write) GROUP`;
   `capabilities has-capability CAP OWNER` must read true.
4. Read `capabilities owner-bootstrap-finalized`: false. Show the user what
   step 5 removes and that it cannot be undone.
5. `capabilities finalize-owner-bootstrap` (OWNER signs). Read
   `capabilities owner-bootstrap-finalized`: true. If it returned `queued`
   (a `diamond` delay was already live), record the action and stop until
   `eta`.
6. Delays (governance.md), `config` last.

Pause for the user's yes before step 3 and, separately and explicitly, before
step 5. Then run [gov-handover-verify.md](gov-handover-verify.md) and Finish.
