# Setup: guardians who can stop but not start

Shared mechanics: [governance.md](governance.md). Record: `gov-guardians-record.md`.

## Outcome

A `guardians` group can pause the tenant, cancel any queued rule change and
cancel any pending operation. It cannot unpause, approve, execute or change
anything. Rule changes wait DELAY, which is the window guardians act in.

## Inputs

Ask for the guardian addresses (one or more; not OWNER, or the separation
means nothing) and whether each signs on this machine.

## Mechanics the user should hear first

- `pause()` takes `ADMIN_ROLE` or `cap.registry.pause`; `unpause()` takes
  `ADMIN_ROLE` only. While paused no operation executes and no rule changes.
- `cap.registry.timelock.cancel` cancels queued actions, except one that
  revokes that same capability, so a bad guardian can always be removed.
- `cap.interact.operation.cancel` cancels a pending Interact operation
  (otherwise only its submitter can). It is granted here but not drilled:
  that needs a vault with an open operation.

## Order

1. Instance, terms; `users add` OWNER and each guardian.
2. `groups create-group $(chainwall id guardians)`; `groups add-group-member`
   for each guardian; read `registry get-group-members`.
3. `capabilities grant-capability-group CAP GROUP` for `chainwall id` of
   `cap.registry.pause`, `cap.registry.timelock.cancel` and
   `cap.interact.operation.cancel`; read `capabilities get-capability-groups CAP`
   for each.
4. Delays (governance.md), `config` last.

Pause for the user's yes before step 3 and before step 4. Then run
[gov-guardians-verify.md](gov-guardians-verify.md) and Finish.
