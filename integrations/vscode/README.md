# candor for VS Code — effects & architecture gate

**Status: BUILT + artifact-verified (2026-07-10); not yet on the Marketplace (publisher setup
pending) — install the `.vsix` from disk.** Works in VS Code and its VSIX-compatible forks
(Cursor, Windsurf).

## What it is

A THIN LSP client (a manifest, a spawn, and two settings) over the same `candor-lsp` server every
other editor runs — the [JetBrains plugin](../jetbrains/) bundles the identical single-file build:

- **CodeLens**: `⚡ Db, Net · blast radius 12` on every effectful function — the transitive effect
  set, and how many functions transitively call it.
- **Diagnostics**: your checked-in architecture policy ("the domain does no I/O") enforced live,
  violations squiggled at the offending function.
- **Hover**: effect provenance — the call chain an inherited effect travels, plus opacity
  (`unknownWhy` / `invisible`) disclosure.

The server is a pure consumer of the spec report envelope (any engine — JVM bytecode, TS/JS, Rust,
Swift): whatever refreshes `.candor/report*` (candor-ts-watch, the Claude Code stop hook, a build
step) refreshes the lenses. It never scans, and it runs on VS Code's **own** Node runtime — no
system Node, npm, or candor install required.

**Coming with the next server pin bump:** the `whatif` code-action ("what if this function gained
Net?") is landing in candor-ts `main`; it arrives here when `candorTsVersion` is bumped past the
next npm release — the client needs no change (code actions flow through `vscode-languageclient`
natively; `scripts/verify-server.mjs` prints whether the bundled server advertises them).

## Install (from .vsix)

```
code --install-extension candor-vscode-<version>.vsix
```

or: Extensions view → `⋯` menu → **Install from VSIX…** (same menu in Cursor/Windsurf).

## Activation

The extension activates only when a workspace has adopted candor —
`workspaceContains:**/.candor/config` or `workspaceContains:**/.candor/*.json` — or when you run
the **`candor: start`** command (`candor.start`) explicitly. It never activates on an arbitrary
window.

## Settings

- `candor.policyPath` — override the policy the diagnostics enforce (exported as `CANDOR_POLICY`
  to the server; absolute, or relative to the first workspace folder). Empty = the server discovers
  the checked-in `.candor/config` policy (spec §3.4).
- `candor.trace.server` — LSP traffic tracing (`off` / `messages` / `verbose`).

## Build + verify

```bash
npm ci
npm run build      # stage candor-ts@<pin> from npm → esbuild → dist/candor-lsp.mjs (handshake-gated) + dist/extension.cjs
npm run package    # vsce → candor-vscode-<version>.vsix
bash test-vscode.sh   # the full gate: pin, handshake, .vsix contents, README drift
```

The server pin lives in `package.json` (`candorTsVersion`) — the analog of the JetBrains plugin's
`gradle.properties` pin. Bumping it re-stages and re-verifies the bundle on the next build; the
staged package must self-report the pin or the build fails. **Versioning:** the extension's version
tracks the bundled server (0.8.x ships spec-0.8 tools, the family rule); `test-vscode.sh` gates the
major.minor agreement.

## Remaining

1. Marketplace publishing: create the `polymorphism` publisher on
   [marketplace.visualstudio.com](https://marketplace.visualstudio.com/manage) (+ an Azure DevOps
   PAT), then `vsce publish` — the packaging path is already gated. Open VSX (`ovsx publish`) is
   worth doing at the same time for the forks that default to it.
2. Bump `candorTsVersion` when the next candor-ts ships to pick up the `whatif` code-action
   (verify-server will start reporting `codeAction`).
3. Large-repo lens performance rides the server, not this client.
