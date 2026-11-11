# Setup: hand day-to-day admin jobs to narrow groups

Shared mechanics: [governance.md](governance.md). Record: `gov-delegated-admin-record.md`.

## Outcome

Routine jobs move from the admin key to groups that can do that job and
nothing else, so the admin key can stay offline.

| Job | Group | Capabilities (`chainwall id` of each) |
| --- | --- | --- |
| Onboard and remove users | `onboarders` | `cap.directory.user.write` |
| Maintain the catalog | `catalog-managers` | `cap.registry.contract.write`, `cap.registry.token.write` |
| Write approval policies | `policy-authors` | `cap.directory.policy.write` |

## Inputs

Ask which jobs to delegate and one or more addresses for each (not OWNER).
A job nobody is named for is skipped.

## Mechanics the user should hear first

- A capability lets its holders do that job directly; the category delay
  still applies to what they do once delays are live.
- Policy authors can create and edit policies, which decide who approves
  spending. Delegate that job only to people trusted with it.
- None of these groups can grant capabilities, change groups, pause, or
  touch delays.

## Order

1. Instance, terms; `users add` OWNER and every delegate.
2. For each chosen job: `groups create-group`, `groups add-group-member` for
   its delegates, read the members.
3. For each chosen job: `capabilities grant-capability-group CAP GROUP` for
   each capability in the table; read `capabilities get-capability-groups CAP`.
4. Delays (governance.md), `config` last.

Pause for the user's yes before step 3 and before step 4. Then run
[gov-delegated-admin-verify.md](gov-delegated-admin-verify.md) and Finish.
