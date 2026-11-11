# Setup: a longer delay for the changes that matter most

Shared mechanics: [governance.md](governance.md). Record: `gov-tiered-delays-record.md`.

## Outcome

Routine rule changes wait DELAY. Constitutional ones wait LONG: changing the
delays themselves, changing who is in the `governors` group, and any further
item the user names.

## Inputs

LONG is 604800 seconds (7 days) unless the user asks otherwise (a rehearsal
may use 300); it must be above DELAY and at most 2592000. Ask whether any
existing policy, interaction, group or catalog entry should also get LONG;
none is a valid answer.

## Mechanics the user should hear first

- A scope override sets the delay for one item inside a category:
  `timelock set-scope-override CATEGORY SCOPE "(true,LONG,false,ZERO32,false,0)"`
  (set delay, leave policy and grace alone). It must sit inside the
  category's `[minDelay, maxDelay]`, which is why the delays loop uses
  2592000 as the maximum.
- SCOPE is the item's own id: a group id for `timelock.category.group`, a
  policy id for `policy`, an interaction id for `interaction`,
  `chainwall id ORG/NAME` for `contract`.
- Overrides are themselves `config` changes, so set them before `config`.

## Order

1. Instance, terms; `users add` OWNER and `users add CANARY` (the membership
   drill needs CANARY to be a user; governance.md explains why that is
   harmless).
2. `groups create-group $(chainwall id governors)` and add OWNER, unless the
   group exists. This setup gives the group no power; it is the group the
   other governance setups grant power to.
3. Overrides: one `set-scope-override` for category
   `chainwall id timelock.category.group`, scope the `governors` id, and one
   per extra item. Read each with
   `timelock get-scope-override CATEGORY SCOPE`.
4. Delays (governance.md) for the ten categories, then `config` with
   `($LONG,2592000,$LONG,604800,$POLICY)` instead of DELAY.

Pause for the user's yes before step 4. Then run
[gov-tiered-delays-verify.md](gov-tiered-delays-verify.md) and Finish.
