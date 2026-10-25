# Author an interaction and policy

Establish the vault, token/contract, function, argument units, intended policy,
recipient constraints, native budget and failure conditions. Reuse catalog
entries and installed interactions when suitable. For a new entry, inspect:

```sh
chainwall orgs add --help --json
chainwall contracts addContractVersion --help --json
chainwall tokens configure --help
chainwall artifacts RegistryInteractionsFacet
```

An organization is a catalog namespace, not an approval group. Register the
contract version before token metadata; a token record needs its underlying
contract. Use reviewed deployment addresses and local artifacts or verified
ABIs. Do not copy an address from a similarly named chain/catalog entry.
Price feed liveness does not prove the feed is for the intended asset/USD pair.

## Source and metadata

Copy [transfer.ls](../assets/transfer.ls) into the working project. Replace
`{{policyId}}`, `{{vault}}`, and `{{tokenPath}}` with the actual bytes32 policy,
managed address, and catalog path such as `circle/usdc`. These are source
templates; the CLI does not interpolate them. The two operation args are the
recipient address as a uint256 decimal word and the amount in base units.
This transfer template expects an ERC20 whose `transfer` returns a boolean;
adapt it to the actual ABI/return behavior. Keep explanatory comments outside
these `.ls` files; the current native parser does not accept `//` or `/* */` comments.

Copy [spending-policy.ls](../assets/spending-policy.ls) when a per-operation
ceiling is wanted. Also replace `{{interactionId}}` and `{{maxAmount}}`. Compile
both after rendering. Use a stable explicit interaction ID on every publish.
The interaction checks its policy and vault so selecting a weaker policy in an
intent cannot bypass the policy program.

```sh
INTERACTION_ID=$(chainwall id treasury-transfer)
chainwall compile transfer.ls --abi circle/usdc=token-artifact.json --out transfer.json
chainwall analyze transfer.json --out transfer-analysis.json
chainwall disasm transfer.json
chainwall policies program compile spending-policy.ls --out spending-policy.json
```

`--abi` accepts an ABI array or a compiler artifact with `abi`. Compilation
uses the Registry to resolve named targets unless a snapshot is supplied. For
offline work, obtain `TOKEN_HASH` with `chainwall id circle/usdc`, then create:

```json
{
  "knownKindsByTargetHash": { "TOKEN_HASH": "token" },
  "abiByTargetHash": {}
}
```

Replace the JSON key `TOKEN_HASH` with the actual hash and pass both
`--snapshot snapshot.json` and `--abi circle/usdc=token-artifact.json`. A snapshot
declares compilation metadata; it does not register a target or prove live
deployment identity. Retain source, ABI, snapshot, settings and compiled JSON.

The program artifact includes analysis, lowered source, assembly and bytecode.
Inspect targets, selectors, write calls, argument provenance and terminal
shape. `analyze --read-only` is for programs intended to have no writes; it
should reject the transfer. `--linked` checks the one-result requirement of a
linked program. Neither option belongs on every interaction indiscriminately.
Reject incomplete/invalid analysis and investigate warnings in context.

`decompile artifact.json --no-preprocess` reconstructs core source. Recompile
it using the original `--settings artifact.json --no-preprocess` to preserve
ABI metadata. Without that option, decompilation can restore named references.
Disassembly/assembly is lossless even where source reconstruction is unsupported.

## Policy programs and execution order

Use `policies templates` to discover maintained budget, allowlist, pause and
timelock templates. Render a selected template with its required IDs and review
its state initialization. `policies program compile` requires **frame** context;
read the evaluated operation through `$subjectId`, `$subjectPolicy`,
`$subjectVault`, `$subjectNativeValue`, `$subjectArgCount` and `$subjectArg(i)`.
Do not select `--argument-context subject` merely because this is a policy.

For privileged actions, bind the subject interaction, vault, policy, argument
shape, native value and any fixed target identity. A per-operation cap does not
limit a day's cumulative spend. Use the maintained policy-meter pattern when a
budget is required, and test rollback when the asset call fails. Recipient
allowlists and slippage/freshness checks also need explicit enforcement.

Lambdascript top-level `let ... in ...` definitions are lazy. An unused binding
does not execute a write. Put effects in the evaluated sequence, or use a strict
local binding within it. `$deadline()` is execution time plus validity, not a
deadline fixed when the user reviewed the proposal. For quote expiry, supply a
reviewed absolute expiry and check it. `$slippage` is per thousand, so 5 is 0.5%.
Payable calls require `{value: ...}` in source and the correct operation budget;
Registry publication `--value` is not that budget.

## Publish and verify

Create the threshold policy and required policy state first. Then:

```sh
chainwall policies program publish "$POLICY_ID" spending-policy.json \
  --max-steps 100000 --dry-run
chainwall policies program publish "$POLICY_ID" spending-policy.json \
  --max-steps 100000 --account administrator --out policy-publication.json
chainwall interactions add transfer.ls --id "$INTERACTION_ID" \
  --snapshot snapshot.json --abi circle/usdc=token-artifact.json --dry-run
chainwall interactions add transfer.ls --id "$INTERACTION_ID" \
  --snapshot snapshot.json --abi circle/usdc=token-artifact.json \
  --account administrator --out publication.json --json
chainwall policies program inspect "$POLICY_ID"
chainwall interactions source "$INTERACTION_ID"
```

The snapshot flags above assume the offline metadata was used during review;
otherwise preserve the actual reviewed inputs. Publication recompiles source.
Compare its output with the reviewed artifact, and complete any queued actions
before treating publication as installed. Use `update` for existing IDs.
Updates preserve flags/linked artifacts unless explicitly replaced and bind the
current bundle hash; a stale queued update needs fresh review. A linked-file
containing `[]` clears links, and `--flags` replaces the entire word.

Simulate the installed policy with `policies program simulate POLICY
context.json`, then simulate the exact operation after approvals. The context
schema comes from `chainwall schemas show policy-context`; it includes actor,
vault, interaction, args, native value, payload hash and operation ID.
Policy simulation rolls back state and reports a nonzero stack result as
success. It does not simulate an unpublished source file.
