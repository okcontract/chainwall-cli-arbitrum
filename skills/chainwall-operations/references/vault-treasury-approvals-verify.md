# Verify vault-treasury-approvals

1. Program: simulate `usdc-vault-pay-<a>` with `["1000000"]` → pass;
   `["1000000001"]` → reject; the owner's `usdc-vault-payout` id under this
   policy → reject.
2. One approval is not enough (write for the proposal only). Owner:
   `operations propose` `usdc-vault-pay-<a>`, args `["1000000"]`, safe VAULT,
   policyId the treasury policy, deadline now + 86400, `--out pay.json`.
   `operations status OPID` shows 1 approval. `operations simulate pay.json --via account`
   fails for missing approvals; report the decoded reason.
3. Second approval (write): `operations approve OPID --account APPROVER2`
   (or from the approver's machine). `operations status OPID` shows 2.
4. Real payout (write, user's yes first): read `accounts assets VAULT`; if
   below 1 USDC ask the user to fund it. `operations execute pay.json --via account`.
   Read the recipient's USDC balance before and after: +1000000. Read the meter
   bucket (`registry get-policy-meter-bucket POLICY METER 2592000 BUCKET VAULT32 0x00…00 0x00…00 0x00…00` (VAULT32 is the vault address left-padded to 32 bytes; the three zero words are full 32-byte zeros),
   `BUCKET = block.timestamp / 2592000`): `1000000`.
5. Removed member (read-only reasoning, no write): state that removing
   APPROVER2 from the group would invalidate their standing approvals at
   execution time; do not perform it.

Record every command, decoded result and transaction hash.
