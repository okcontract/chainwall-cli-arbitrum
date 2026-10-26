# Standalone MiniScript toolchain

`compileDetailed(allocator, source, settings, &diagnostic)` preserves the ordinary
`compile` result and adds phase, error code, explanation, a primary span and an
optional related binding span on failure. Spans use half-open UTF-8 byte offsets;
diagnostic strings have static lifetime, so no diagnostic cleanup is needed.
Compiler JSON responses include this object as `diagnostic` alongside `error`.
The CLI and LSP also expose compiler diagnostics. When Registry preprocessing
changes the source, diagnostic metadata explicitly names `coreSource` as its
coordinate space; the editor retains a source range from surface analysis rather
than treating generated offsets as original-file offsets.

`miniscript --help` (`-h`) and `miniscript --version` (`-V`) work without input.
Unknown subcommands and invalid argument counts fail with usage before opening
an input file or reading stdin. Each subcommand also accepts `--help`.

Compiler settings are strict across JSON requests, `--settings` files and nested
LSP configuration: unknown keys are rejected. Supported keys are `optimization`,
`argumentContext`, `$validity`, `$slippage`, `forceRecursiveAbi`,
`abiFunctionsByCallKey`, `knownResolvableHashes`, and
`addressArgResolutionsByWriteKey`. The catalog annotations `payableWriteKeys`
and `payableSelectors` are also validated and accepted for artifact compatibility;
they do not change this compiler's explicit payable-call syntax.

Native Zig 0.17 implementation of the onchain-compilable Lambdascript language,
MiniScript bytecode generation, lossless assembly/disassembly, and source
reconstruction. The library and executable depend only on Zig's standard
library. Core compilation runs entirely in Zig without a runtime dependency or RPC.

The same build produces **chainwall**, the Registry CLI. It adds Foundry signing,
TOML profiles, Registry-aware `.ls` preprocessing, and Etherscan ABI retrieval.
It also provides SQLite-backed incremental sync and encrypted operation journals.
Account and Safe views show native/token balances, fresh USD valuations, and
execution activity from indexes or RPC logs. The CLI also manages operation
execution, passkey approvals, encrypted labels and secret rotation, verified
release upgrades, terms acceptance and publication governor actions. Compilation
includes MiniScript analysis; explicit operation/policy simulations use pinned
RPC state without broadcasting.
The build also produces **chainwall-lsp**, a native Lambdascript language server
with profile-aware Registry completion, ABI assistance, diagnostics, navigation,
formatting, compiler JSON, and explicit catalog refresh. See the
[editor guide](LSP.md), installed at `share/doc/chainwall/LSP.md`.
Both Chainwall binaries link bundled SQLite through zqlite;
`-Dcli=false -Dlsp=false` builds only the
standard-library compiler and avoids fetching that dependency.
Binary users should start with the [Chainwall CLI user manual](MANUAL.md), also
installed at `share/doc/chainwall/manual.md`. See [CLI.md](CLI.md) for repository
setup and CLI development checks.

## Build and use

```sh
zig build -Doptimize=safe
zig build test
printf '%s' '$arg0 + 1' | zig-out/bin/miniscript compile
# 0x010023010110ff
printf '%s' '0x010023010110ff' | zig-out/bin/miniscript disasm
printf '%s' '0x010023010110ff' | zig-out/bin/miniscript decompile
```

Each command accepts a file path or `-` for stdin. `assemble` consumes the
instruction listing from `disasm`. Listings preserve push widths, jump offsets,
and complete recursive ABI descriptors. `decompile` reconstructs structured
Lambdascript from compiler-generated stack and branch patterns. Arbitrary VM
programs can have lossless listings without having a supported source
reconstruction; unsupported patterns return an error.

Cross-compile the executable with, for example:

```sh
zig build -Dtarget=x86_64-linux-musl -Doptimize=safe
```

The `json` command accepts one request or an array. Requests have an optional
`id`, an `action` (default `compile`), `source` or `bytecode`, and `settings`.
Results contain `bytecode`, `source`, or `assembly`; failed requests contain
`error`. Batch results retain input order and IDs. Malformed JSON fails the
process. There are no hidden compiler defaults supplied by a host application.

```json
{
  "id": "minimum-output",
  "action": "compile",
  "source": "$require($arg0 >= 100)",
  "settings": { "optimization": "size", "argumentContext": "frame" }
}
```

`optimization` supports `baseline` and `size` (default). `argumentContext`
supports `frame` (default) and `subject`. JSON settings also accept `$validity`
(default 1800 seconds), `$slippage` (default 5 per thousand),
`forceRecursiveAbi`, `abiFunctionsByCallKey`, `knownResolvableHashes`, and
`addressArgResolutionsByWriteKey` in the compiler JSON format. Large words
belong in source literals or JSON strings, avoiding JSON number precision loss.

Exact ABI metadata maps `0x<64 hex target>:0x<8 hex selector>` to an ABI function
object, including its name, inputs, outputs and state mutability. The compiler
validates the selector against the signature. Supply the same settings when
decompiling and recompiling. In particular, recursive ABI source needs its
target-qualified metadata; the lossless listing is independent of that metadata.

## Library

Use this directory as a Zig package dependency and import its `miniscript`
module. All four top-level operations return caller-owned allocations:

```zig
const ms = @import("miniscript");

const bytes = try ms.compile(allocator, "$arg0 + 1", .{});
defer allocator.free(bytes);
const source = try ms.decompile(allocator, bytes, .{});
defer allocator.free(source);
const listing = try ms.disasm(allocator, bytes);
defer allocator.free(listing);
const restored = try ms.assemble(allocator, listing);
defer allocator.free(restored);
```

`bytecode.decode` returns a caller-owned instruction slice whose immediates
borrow the input bytes; `bytecode.encode` returns owned bytes. `references.scan`
extracts static targets, CALLI IDs, linked relations and price assets, together
with completeness and raw-reference counts. Release it with `deinit(allocator)`.
The compiler checks reference preservation across its optimization passes and
enforces the 128-reference cap. Parser/IR APIs use an explicit `tree.Factory`
allocator and are intended for an arena owned by the caller.
Parsed identifier spelling borrows the source text, which must remain alive
while using that syntax tree.

Resource limits reject oversized work with `ResourceLimit`: 32,768 parser token
advances, 8,192 parsed syntax nodes, 256 syntax/lowering nesting levels, 1,024
intermediate tree levels, and 100,000 node allocations per factory. The node
allocation budget includes discarded compiler/decompiler rewrites. ABI schemas
are limited to 16 levels and 256 nodes before recursive layout begins.

`Settings` uses Zig enums and typed fields (`validity` and `slippage`), with
optional `std.json.Value` metadata. `json.settings` decodes the JSON interface.
The public compiler performs semantic word/Unit/tuple checks and lexical
validation. It does not implement the reactive evaluator's general-purpose
type inference. It accepts raw word predicates.

## Language and implementation

The compiler handles exact uint256 literals, arithmetic and comparisons, wrapping
scalar operations, exact ratios, lazy Boolean branches, strict tuple locals,
first-demand ordinary definitions, call ordering, frame/subject arguments,
checks, hashing, balance/native operations, pricing, linked calls, and raw or
recursive ABI reads/writes. Recursive ABI supports nested tuples and arrays,
bytes/string tapes, version-1 schemas, version-2 precompiled plans, `$abiArgs`
slices and READWORDS tuple projections. Both optimization modes preserve the
bytecode format, with stack cleanup and constant reuse. Nested unary negation
preserves its operations rather than folding away the source grouping.

The library and `miniscript` executable take **core Lambdascript**. Registry names
and authoring syntax such as `@contract(org/id).method(...)` must first be
resolved to core calls and exact ABI metadata. Runtime imports, closures, and
application rendering are outside this compiler. The `chainwall` executable
provides native preprocessing, wallet integration, and RPC submission.

The pipeline is parser -> builtin/ABI lowering and first-demand memoization ->
normalization/scheduling -> stack codegen -> machine/constant optimization ->
checked byte encoding. Source reconstruction interprets stack identities and
branch regions, preserves effects, and restores source Boolean and Unit types.

## Tests

`zig build test` uses checked-in fixtures for the release catalog,
READWORDS, evaluation ordering, regressions and 128 seeded programs, under both
optimization modes. It checks exact compilation, lossless listings and source
round trips with allocator leak detection. Additional tests cover invalid input
and injected allocation failures. These tests run from a copy of this directory.

### Allocation and borrowing contracts

Use the same allocator to release an independently owned result. For arena APIs,
keep the arena alive for the entire graph and reset/deinitialize it on success or
failure; freeing only the final slice does not release intermediate allocations.
An arena does not extend the lifetime of input slices borrowed by its objects.

| API | Result lifetime and cleanup | Borrowed input |
| --- | --- | --- |
| `compile`, `compileDetailed`, `decompile`, `disasm`, `assemble`, `leanProgram` | Independent result slice; `allocator.free(result)`. Internal work is released on success and failure. | Source/bytes/settings needed only during the call. |
| `compileDetailed` diagnostic | Static strings and numeric source spans; no cleanup. | To display a span's text, retain the original source. |
| `bytecode.hex`, `unhex`, `encode` | Independent result slice; `allocator.free(result)`. | Input needed during the call. |
| `bytecode.decode` | Independent instruction slice; `allocator.free(instructions)`. | Each immediate borrows the original bytecode. |
| `references.scan` | Independently disposable collections; `references.deinit(allocator)`. | Input needed during the call. |
| `Parser.parse`, `tree.Factory` | Arena-owned syntax/IR graph, including partial work on failure. | Parser spelling/literal slices borrow source; manually supplied names and child nodes retain their original lifetimes. |
| `Factory.clone` | Arena-owned shallow node and copied child-pointer slice. | Names, descendants and metadata are shared with the original graph. |
| `bytecode.Builder` | Arena-owned list and immediate buffers; `emit` copies its immediate. | Other instruction references supplied manually retain their lifetimes. |
| `abi.method`, `decodeSchema`, `encodeSchema`, `precompiled` | Use a caller-owned arena for schemas and intermediate work. | Inputs needed during the call. |
| `abi.decode` | Arena-owned root/validations; no independent destructor. | `Descriptor.schema` borrows the input descriptor bytes. |
| `json.field`, `string`, `settings` | Borrowed values/views; no cleanup. | Keep the parsed JSON and its allocator alive. |
| `json.normalize` | Arena-owned normalized containers/keys, with borrowed values. | Keep the original settings JSON alive too. |
| `syntax.tokens` | Arena-owned token storage. | Token text borrows source. |
| `syntax.format`, `formatWithOptions` | Use an arena for result and parser/token intermediates. | Input needed during the call. |

A typical lower-level caller creates one arena per compilation or editor request,
keeps source and settings alive through that request, and copies only the result
that must outlive it. Never recursively free an IR graph: rewrites and shallow
clones can share nodes. CLI/LSP internal `c.Value` results follow their request or
page allocator lifetime; they are not independently disposable JSON documents.

`ms.limits` (`src/limits.zig`, also available through `tree.limits`) names these
budgets. ABI schema depth, schema nodes, array length, descriptor bytes, tape
words, and expanded calldata bytes have separate constants even when values
coincide. Authoring limits and static-analysis frame limits are also separate:
the analyzer can inspect broader frames without promising that the compiler or
a deployed VM accepts them. Update the relevant producer, validator, decoder,
and existing boundary regressions together when changing a limit.

### Scaled integer boundaries

Decimal/scientific literals must represent exact nonnegative integers that fit
`uint256` (a leading sign is handled by expression parsing). Decimal scaling is
cancelled before the integer is accumulated: appending `.0` or `000e-3` to the
maximum `uint256` is accepted and yields that same value. Nonzero fractional
remainders and final overflow are rejected, never rounded. Leading zeros do not
consume the significant-digit budget. The exponent must fit a signed 32-bit
integer; zero accepts any exponent in that domain. Processing is linear in the
spelling length, with at most 78 significant result digits to accumulate.
