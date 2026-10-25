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

Keep changes focused and include the problem, resulting behavior, and validation
in pull requests. Never include wallet secrets or personal configuration.
Review updates to bundled protocol data in `src/cli/artifacts/` together with
their associated ABIs, deployment bytecode, runtime hashes, and license notices.
Keep factory defaults limited to Arbitrum One (chain ID `42161`).

Contributions are governed by [LICENSE](LICENSE), including its Additional Use
Grant and eventual GPLv3 conversion. Preserve third-party notices and only
contribute material you have the right to license.
