# Standalone MiniScript toolchain

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
