# Setup: add or replace an admin through a delayed, cancellable change

Shared mechanics: [governance.md](governance.md). Record: `gov-admin-rotation-record.md`.

## Outcome

Granting or revoking `ADMIN_ROLE` needs a named capability, waits DELAY and
can be cancelled while it waits. NEW becomes an admin through that path. On
request the old admin is removed afterwards.

## Inputs

Ask for NEW (an EOA the user controls; not OWNER) and whether OWNER's own
admin role should be removed once NEW works. Default: keep both.

## Mechanics the user should hear first

- `roles grant-role` and `roles revoke-role` for `ADMIN_ROLE` revert unless
  the caller holds `cap.registry.admin.grant` or `cap.registry.admin.revoke`,
  even for the owner. Both run in `timelock.category.role.admin`.
- A queued grant can be cancelled by any holder of the grant capability, a
  queued revoke by any holder of the revoke capability, and either by an
  admin.
- Removing OWNER's admin role does not change `owner()` or `UPGRADER_ROLE`.
  Never revoke the old admin before NEW has been shown to work.

## Order

1. Instance, terms; `users add` OWNER and NEW.
2. `groups create-group $(chainwall id governors)` and add OWNER, unless the
   group exists.
3. `capabilities grant-capability-group` of `chainwall id cap.registry.admin.grant`
   and of `chainwall id cap.registry.admin.revoke` to `governors`; read both.
4. Delays (governance.md), `config` last.
5. ROLE = `chainwall roles admin-role`. `roles grant-role ROLE NEW` →
   `queued`; record the action id and `eta`. With a long DELAY, stop here and
   tell the user to resume after `eta`.
6. After `eta`: `timelock execute-action ID`; `roles has-role ROLE NEW` true.
   Run the verify file.
7. Only if asked, and only after verify check 2 passed:
   `roles revoke-role ROLE OWNER` → queued → execute after `eta` →
   `roles has-role ROLE OWNER` false.

Pause for the user's yes before steps 4, 5 and 7. Verify:
[gov-admin-rotation-verify.md](gov-admin-rotation-verify.md). Then Finish.
