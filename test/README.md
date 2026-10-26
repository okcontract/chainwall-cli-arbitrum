# Compiler corpus

`corpus.json` enumerates source and settings for every golden fixture, in stable
order. `fixtures.json` adds expected bytecode. These 1,204 expected vectors were
established using an independent compiler and are retained unchanged; the Zig
generator does not silently replace them with its own output.

The 128 generated source programs use xorshift32 seed `0x12345678` (`305419896`),
with both baseline and size optimization settings. `generator.zig` contains the
complete grammar, draw order and per-program local-name reset. Each generated
fixture ID records its seed and index. The other inputs are explicit curated
cases and do not use randomness. Separate execution tests in `semantics.zig`
use the documented LCG seed `0x434841494e57414c` for 2,000 arithmetic cases.

Run from the repository root with the pinned Zig toolchain:

```sh
zig build fixtures
zig build fixtures -- generate /tmp/chainwall-fixtures-candidate.json
diff -u test/fixtures.json /tmp/chainwall-fixtures-candidate.json
zig build test
```

The default check regenerates the grammar sources, compiles every enumerated
input, and compares the complete records with the golden corpus. It also runs
under `zig build test`. Generation writes only the explicitly named destination.
For an intentional language change, edit `corpus.json`, inspect the candidate
diff and independent semantic results, then copy the approved candidate to
`fixtures.json` and commit both files. New expected vectors must record their
mathematical or independent-runtime rationale in the associated Zig test.

`zig build fixtures -- extract INPUT OUTPUT` removes bytecode from a fixture
array to recover its explicit inputs. It does not recreate expected bytecode.
Do not use an unreviewed golden update to make a failing semantic test pass.
