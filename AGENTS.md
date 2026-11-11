# Agents

This repository is the Chainwall CLI for Arbitrum One (chain ID 42161), with a
Lambdascript compiler, language server, and the `chainwall-operations` agent skill.

## Operate Chainwall

Read `skills/chainwall-operations/SKILL.md` and follow it. For a complete build
with fixed inputs, use a recipe under `skills/chainwall-operations/recipes/`.
Chainwall is not published on npm, pip or Homebrew; the npm package named
`chainwall` is unrelated.

## Build

Zig 0.17.0 and Foundry `cast` 1.8.6.

```sh
zig build -Doptimize=safe
zig build test
export PATH="$PWD/zig-out/bin:$PATH"
chainwall doctor --json
```

## Rules

- Take command shapes from the binary: `chainwall <command> --help --json`,
  `chainwall schemas list`, `chainwall schemas show NAME`.
- Never invent a subcommand, selector, tuple layout, deployment address or
  capability name. Factory defaults: `src/cli/artifacts/factory-addresses.json`.
- Run every write with `--dry-run` first. A `queued` write has not applied.
- Signing goes through named Foundry keystore accounts. Never ask for, read,
  print or store keys, passwords or password files.
- Use an isolated profile for a new project (`CHAINWALL_CONFIG_DIR` or
  `chainwall profile create NAME`). Do not change a profile you did not create.
- Check Foundry commands with `cast <command> --help` before showing them.
- Keep amounts and timestamps as exact integer strings. Read token decimals
  from chain.
