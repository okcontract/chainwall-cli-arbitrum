# Observe, automate, and recover

## Holdings and activity

```sh
chainwall accounts assets "$VAULT" --out holdings.json
chainwall safes assets "$SAFE" --token-id circle/usdc --max-age 3600
chainwall accounts activity "$VAULT" --logs --from-block "$DEPLOYMENT_BLOCK"
chainwall transactions inspect "$TX_HASH"
```

Assets use one verified block for metadata, balances and valuations. Follow
`nextStart` at that same `--block`; do not add partial page totals as though
they represent a complete portfolio. Catalog aliases can refer to the same
token. Null balances or prices mean unavailable, not zero. Respect
`unpricedAssets` and `portfolioComplete`; even complete catalog coverage
excludes unregistered assets, NFTs and offchain positions.

Activity's default recent index is bounded and may omit transaction hashes.
Explicit logs provide a stated block range. Neither is a full transfer ledger
or proof of every external transaction. Narrow an oversized log scan; do not
interpret provider errors as no activity.

## Machine-readable workflows

Use `--json`, preserve stdout and stderr separately, validate input schemas
before submitting, and inspect semantic status fields after exit code zero.
Generic Registry reads return arrays of ABI outputs; tuples can be positional.
`id`, `decompile`, `disasm`, version and group help remain text with `--json`.
Structured `--args-file` inputs use native ABI encoding for an offline generic
write preview; positional Foundry-notation inputs can require `cast` even for
`--dry-run`. Both routes still need live checks for actual execution.

Use explicit profile/chain/Registry context in unattended jobs. Never allow an
ambient profile switch to select another tenant. Use Foundry password files and
the local vault passphrase file as distinct inputs. Do not log their contents
or raw secrets. Keep output names unique so an existing evidence file is not
overwritten. Save compiler inputs and outputs alongside the job definition.

For fee review, `--estimate --from ADDRESS` estimates at a canonical block and
does not send. `transactions estimate` accepts a prepared transaction. Fee
limits must be supplied again on submission; estimated execution gas omits
chain-specific costs such as rollup L1 data fees.

## Recover interrupted sends

```sh
chainwall logs list
chainwall logs show latest --json
chainwall transactions list
chainwall transactions track "$TX_HASH"
chainwall transactions wait "$TX_HASH" --timeout 120 --confirmations 2
```

Logs save broadcast/receipt evidence before later checks. A CLI failure or
timeout can follow a successful transaction. `wait`, `track` and `refresh`
observe transactions without resubmitting them. `nonce-used` is not proof of
the intended effect; inspect the replacement and resulting state. An operation
file still marked `prepared` needs receipt recovery before another proposal.

For staged commands, use their recovery path after identifying the receipt:
deployment `--stage`, `facets reconcile`, `security-council reconcile`, or
`commitments reconcile`, as applicable. `--retry` is an explicit decision after
reconciliation, not a general network-error handler. Same-nonce speed-up and
cancellation can race the original; use those only for the intended transaction
with authorization for the replacement. Never silently change RPC endpoints to
resolve ambiguous submission status.

## Optional encrypted sharing

Use an existing app journal when collaboration requires it:

```sh
chainwall config set kv_chain 42161
chainwall config set kv_rpc_url "$KV_RPC_URL"
chainwall kv connect "$KV_ADDRESS" --secret-file /private/path/kv-secret \
  --passphrase-file /private/path/vault-passphrase
chainwall operations publish proposal.json --account journal-writer \
  --passphrase-file /private/path/vault-passphrase
chainwall sync --only operations
chainwall operations list --json
```

The shared secret is a 32-byte KV key, not a Foundry key or password. This example
uses Arbitrum for the journal; the writer needs gas on its configured KV chain.
When reusing an existing journal on another chain, preserve and verify that
chain/RPC explicitly. Only Arbitrum has a bundled KV factory for new deployments.
Journal ciphertext establishes shared proposal data, not execution evidence.
`active` is not approval readiness; `closed` includes withdrawn/missing records;
`unknown` requires fresh context or status checks. Preserve both journal
checkpoint and execution `statusBlock` when reporting.

Private address books use `recipients --help`; private catalog publication
uses `commitments template|prepare|commit|status|reveal`. Do not improvise salts
or export private payloads into reports. Reveal simulation exposes its salt and
payload to the chosen RPC, and a reveal transaction publishes them.

Back up the configuration and SQLite store consistently. It can hold the only
encrypted copy of pending secrets. `kv create --dry-run` and `kv rotate
--dry-run` can persist local recovery material. Resume rotation with
`kv rotate --resume`; deleting the store is not a recovery strategy.

## Passkeys and maintenance

Use `auth recover` for an existing resident passkey or the
`auth enroll` -> `auth create` -> `auth register` workflow for a new one.
`--auth-profile` selects the actor; an EOA `--account` can pay gas, or a supported
bundler can sponsor the UserOperation. Browser approval must use the factory's
exact RP/origin. Use `--app-url` for an externally hosted app with the CLI
approval route, or `--approval-url` for an externally hosted approval page;
both must match the configured origin. Do not replace passkey approval with an
agent-held key. Recover a pending UserOperation using `auth receipt` and its
actual hash.

For requested upgrades, use `upgrade releases|inspect|verify|propose`, or the
facet `catalog|plan|apply|check|reconcile` workflow. Inspect storage fingerprints,
codehashes, constructor bindings and resulting routes. A component identity
check is not full release verification. Tenant adoption can queue; successful
upgrades invalidate earlier runtime authorizations. Recreate affected requests
and signatures after the new state is confirmed.

Registry pause does not automatically cancel pending operations or governance
actions. Ordinary pause capability and security-council resume authority are
different. Inspect the native council, its current revision, contract-account
seats and independent recovery authority before preparing council actions.
