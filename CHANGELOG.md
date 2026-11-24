# Changelog

## 0.3.2 - 2026-11-23

- Explain RPC chain ID mismatches and decode contract reverts and Safe error
  codes in human-readable and JSON diagnostics.
- Name rejected options in CLI errors and report missing account and Safe
  address arguments.
- Keep native balances visible when a USD price feed is missing and show how
  to configure the feed.
- Check that Foundry supports `cast send --data` in `chainwall doctor` and
  report how to install the tested Foundry version.
- Show one explorer link per submitted transaction hash, including replacements.
- Document how to download and verify terms and use an alternate IPFS gateway.
- Free canceled shell completion responses and release LSP input frames on errors.
- Apply the same 64 MiB limit whether `miniscript` reads from a file or standard
  input.
- Require Zig 0.17.1 for source builds. Use the package manifest version for
  binaries and archive names, and rebuild archives from the current install tree.

## 0.3.1 - 2026-10-27

- Preserve discovered replacement transactions across observations, revalidate
  their receipts, and keep confirmation tracking stable while scanning in batches.
- Publish current LSP diagnostics after failed metadata refreshes, including edits
  waiting for the diagnostic debounce.
- Improve RPC retries, batch handling, persistence, configuration validation, and
  reconciliation of operation proposals from confirmed receipts.
- Correct compiler arithmetic and bytecode semantics, enforce resource limits,
  and improve source diagnostics and regression coverage.
- Include editor assets in fetched source packages and verify installed binaries,
  documentation, shell completions, and editor integration.
- Isolate package fetch caches outside the source directory to prevent recursive
  copies when a global Zig cache is stored inside the checkout.
- Keep allocation-failure tests deterministic across allocator layouts while
  retaining out-of-memory and leak checks.
