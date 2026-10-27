# Changelog

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
