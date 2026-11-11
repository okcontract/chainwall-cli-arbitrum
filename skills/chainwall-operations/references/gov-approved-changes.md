# Setup: rule changes need approvals as well as a delay

Shared mechanics: [governance.md](governance.md). Record: `gov-approved-changes-record.md`.

## Outcome

Every rule change waits DELAY and needs THRESHOLD approvals from a
`governors` group before it can execute. One key, the owner's included, can
queue a change but cannot make it happen. Outside this: account creation
stays undelayed, `roles pause` is immediate, and an admin can still cancel a
queued change.

## Inputs

Ask for the other governors' addresses (at least two, so there are three with
OWNER) and whether each signs on this machine. THRESHOLD is 2 unless the user
says otherwise; it must be at least 2 and less than the number of governors.

## Mechanics the user should hear first

- This binds everything, including later fixes to this setup. If fewer than
  THRESHOLD governors can sign, no rule can change again and nobody can
  override that. Keep THRESHOLD below the group size.
- Approval is per action: `timelock approve-action ID` from a governor. The
  proposer must approve too if they want to count. Status 2 means approvals
  are complete; execution still waits for `eta`.
- Membership is read live: removing a governor voids their approval.

## Order

1. Instance, terms; `users add` OWNER and each governor.
2. `groups create-group $(chainwall id governors)`; `groups add-group-member`
   for OWNER and each governor; read the members.
3. `policies create-policy $(chainwall id change-approvers) "[GROUP]" "[THRESHOLD]"`;
   read `registry get-policy-criteria`.
4. Delays (governance.md) with POLICY = the `change-approvers` id, `config`
   last. From the first of these writes on, that category needs approvals.

Pause for the user's yes before step 4, restating the lock-out risk. Then run
[gov-approved-changes-verify.md](gov-approved-changes-verify.md) and Finish.
