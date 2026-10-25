# Chainwall CLI for Arbitrum

Native tools for working with Chainwall Registry contracts, authoring interactions,
and managing accounts on Arbitrum. The toolchain is written in Zig and includes
a CLI, compiler, and language server. Select Arbitrum explicitly in your profile.
Bundled factory addresses are provided only for Arbitrum One (chain ID `42161`).

| Program | Purpose |
| --- | --- |
| `chainwall` | Registry, account, policy, and transaction CLI |
| `chainwall-lsp` | Lambdascript language server |
| `miniscript` | Compiler, assembler, disassembler, and decompiler |

## Build

Install [Zig 0.17.0](https://ziglang.org/download/), then run from this repository:

```sh
zig build -Doptimize=safe
zig build test
export PATH="$PWD/zig-out/bin:$PATH"
chainwall --version
chainwall-lsp --version
printf '%s' '$arg0 + 1' | miniscript compile
```

The build downloads the hash-pinned zqlite dependency and compiles SQLite into the
CLI and language server. All protocol data needed to build is included here.
Compiler-only builds use
`zig build -Dcli=false -Dlsp=false` and need no external dependency.

Install [Foundry's `cast`](https://getfoundry.sh/) for wallet and transaction
commands. All CLI implementation code is native Zig. Passkey approvals use an
externally hosted Chainwall approval app.

## Configure Arbitrum

```sh
chainwall config set chain 42161
chainwall config set rpc_url https://arb1.arbitrum.io/rpc
chainwall config set instance YOUR_REGISTRY_ADDRESS
chainwall --help
```

Replace `YOUR_REGISTRY_ADDRESS` with the Registry you intend to use. See the
[CLI manual](MANUAL.md) for profiles, signing, dry runs, and transaction recovery.
Production use is permitted with the original Chainwall contracts published by
OKcontract Pte. Ltd., as specified in the license.

## Documentation

- [CLI manual](MANUAL.md) and [command/developer reference](CLI.md)
- [Compiler and library](COMPILER.md)
- [Language server reference](LSP.md)
- [Contributing and testing](CONTRIBUTING.md)

## Agent skill

[chainwall-operations](skills/chainwall-operations/SKILL.md) guides assistants
through Arbitrum setup, interaction and policy authoring, approvals, execution,
and recovery. Copy the complete `skills/chainwall-operations` folder into your
assistant's configured skills directory, including its references and templates.
Invoke it as `$chainwall-operations` in assistants that support that syntax.
Installed distributions include it under `share/doc/chainwall/skills/`.

## Install

```sh
zig build -Doptimize=safe --prefix "$HOME/.local"
```

This installs the three binaries, manuals, agent skill, shell completions, and
license notices. Add `$HOME/.local/bin` to your `PATH`. To cross-compile for Linux:

```sh
zig build -Dtarget=x86_64-linux-musl -Doptimize=safe
```

## License

[Business Source License 1.1 (BUSL-1.1)](LICENSE), with an Additional Use Grant
allowing production use with the original Chainwall smart contracts as published
by OKcontract Pte. Ltd. Each version converts to GPL-3.0-only on the fourth
anniversary of its first public distribution under this license. The source is
available; BUSL-1.1 is not an Open Source license before conversion.

Third-party components retain their own licenses. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and [LICENSES/](LICENSES/).
