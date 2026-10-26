# Contributing

Use Zig 0.17.0, as pinned in `.zig-version`. From the repository root:

```sh
zig fmt --check build.zig build.zig.zon src test
zig build -Doptimize=safe
zig build test
```

The existing native tests cover the compiler, CLI internals, language server,
and checked-in compiler fixtures. No JavaScript dependencies or live chain are
needed.

`zig build test-commands` runs the real CLI against isolated temporary profiles,
a strict Zig fake `cast` executable, and a loopback RPC server. It checks account,
Safe and module envelopes and failure-before-mutation behavior. The fake process
rejects every unimplemented command, including broadcasts; it is never installed.

`test/oracle.zig` independently decodes and executes a bounded VM subset.
`test/semantics.zig` compares values and ordered mock call effects in both compiler
modes, including 2,000 deterministic generated cases. The model uses wrapping
uint256 arithmetic and checked uint512 ratio intermediates. It rejects unsupported
opcodes and oversized products explicitly. This complements golden bytecode
fixtures; it does not claim equivalence with every deployed VM instruction.
See [test/README.md](test/README.md) for corpus inputs, stable generator seeds,
expected-result origins and the explicit candidate-generation workflow.

`zig build test-lsp` launches the installed-shape LSP executable over framed stdio,
using temporary workspaces. It checks protocol lifecycle, editor requests, push
and pull diagnostics, late cancellation, response IDs and malformed frames.

Release validation uses `zig build test -Doptimize=safe` and `zig build smoke
-Doptimize=safe --prefix zig-out/smoke`. Check compiler-only installation with
`zig build smoke -Dcli=false -Dlsp=false --prefix zig-out/compiler-only`.
`zig build package -Doptimize=safe` writes a versioned target-specific archive
under `zig-out/packages/`, including binaries, documentation and license notices.
Use a fresh prefix when changing the CLI/LSP selection to avoid stale files.
`zig build test-package` uses `zig fetch` to produce the manifest-filtered source
archive, extracts it, and runs default installation smoke checks from that source.
This catches required assets omitted from `build.zig.zon`'s `.paths` list.
The fetch uses an isolated cache under `TMPDIR` (or `/tmp`), which must be outside
the checkout; the extracted build reuses the caller's compiler and dependency caches.
CI runs native tests and installation smoke checks on macOS and Linux, checks
archive extraction, and cross-builds x86_64/aarch64 Linux musl packages. Windows
is not currently a release target. Cross-builds establish compilation, not runtime
compatibility; native execution is required before adding a supported target.

Keep changes focused and include the problem, resulting behavior, and validation
in pull requests. Never include wallet secrets or personal configuration.
Shared execution options live in `src/cli/command_options.zig`: startup consumes
route and sponsorship settings once, and handlers receive the resolved route.
Direct and proposed operations share a typed input parser. Route applicability
and completion choices come from `schema.zig`; add commands there when extending
the execution surface, and keep command-level envelope tests in sync.
Review updates to bundled protocol data in `src/cli/artifacts/` together with
their associated ABIs, deployment bytecode, runtime hashes, and license notices.
Keep factory defaults limited to Arbitrum One (chain ID `42161`).

Contributions are governed by [LICENSE](LICENSE), including its Additional Use
Grant and eventual GPLv3 conversion. Preserve third-party notices and only
contribute material you have the right to license.

To measure SQLite query growth, run `zig build bench-store -Doptimize=safe`.
The native Zig benchmark inserts 512-byte records into an in-memory database and
averages 100 indexed point queries and 20-record pages at each size. It reports
latency and peak query-arena capacity; SQLite's own cache is outside that counter.
A local arm64 macOS run produced:

| Records | Point lookup | Keyset page | Offset page and count |
| ---: | ---: | ---: | ---: |
| 100 | 3.3 µs | 22.6 µs | 28.0 µs |
| 10,000 | 2.3 µs | 15.7 µs | 356 µs |
| 100,000 | 2.2 µs | 13.1 µs | 3,330 µs |

Query arena capacity stayed at 2,846 bytes for point lookups, 89,688 bytes for
keyset pages, and 37,606 bytes for offset pages. These measurements are illustrative,
not CI timing thresholds. `Store.get` uses the `(scope,dataset,id)` primary key;
`Store.scan` uses an exclusive ID cursor and fetches at most 1,001 rows. Cursor
pages stay bounded as the dataset grows. Offset pages retain existing CLI syntax
but counting and skipping rows costs more as history grows. Transaction tracking
uses point lookups; list and bulk refresh decode only the selected SQL page.

Synchronization processes Registry indexes, users, labels, timelocks, KV records,
log ranges, and operation statuses in disposable page arenas. Pending work uses a
file-backed SQLite temporary queue in the private staging database. Publication
of records and checkpoints remains atomic. Human output reports page progress;
JSON reports `processedRecords` (including discovery/status work) and
`peakPageArenaBytes`. The latter measures decoded page allocations, not total RSS,
HTTP buffers, SQLite caches, or the fixed catalog and secret history.

Local operation imports and status snapshots now use individually encrypted
records. Existing status snapshots remain readable. The first write/sync migrates
a legacy import map atomically; that one-time migration still needs memory for the
old map. Listing commands may deliberately materialize their full result.

Metadata views batch independent reads with an EIP-1898 canonical block selector.
Instance summaries and recipient lists retain per-field/per-recipient errors;
token metadata is batched across each asset page. Price pairs, account activity
context, and recipient context checks also share requests. Batch responses are
validated and reordered by ID before decoding. A transport/framing failure fails
the batch; a contract revert remains attached to its individual result.

The LSP caches parsed syntax, tokens, and metadata per open URI, document version,
and metadata revision. Edits/close release the document cache. Configuration,
workspace-folder, watched-file notifications, `chainwall.reload`, and completed
refresh/fetch commands invalidate metadata. Editors should watch their LSP config,
snapshot/ABI files, and Chainwall cache, or invoke reload after external changes.
Each request owns its preprocessing/rendering allocations; cached syntax stays
immutable and does not accumulate allocations across hover/completion requests.

LSP edit diagnostics debounce for 150 ms. A newer edit, close, reload, or shutdown
cancels pending diagnostics; pull diagnostics flush the latest version immediately.
Diagnostics compile and analyze bytecode directly, without building the full
publication artifact (decompilation, disassembly, and metadata exports).
Cancellation is checked between preprocessing, compilation, and analysis; a
bounded compiler phase already running is allowed to finish before cancellation.

After a successful LSP metadata refresh or ABI fetch, the server invalidates cached
catalogs and republishes diagnostics for every open document. Completion wakes an
idle input loop. Clients supporting pull-diagnostic refresh also receive the
standard refresh request; push-only clients need no additional request or edit.
