# candor for JetBrains IDEs — plugin skeleton

**Status: SKELETON (AGENT-SURFACE-DESIGN bet 2, the JetBrains slice) — written against the documented
LSP4IJ + IntelliJ Platform APIs, not yet compile-verified** (the first `buildPlugin` downloads the ~1 GB
IDE SDK; run it before trusting the Java sources). The two load-bearing pieces ARE verified:

- the **single-file server bundle** (esbuild of candor-ts's `lsp.mjs`, ~20 KB, zero deps) handshakes
  over LSP stdio with full capabilities — `bundleServer` reproduces it;
- the **bundled engine** is the released `candor-java-all.jar` (~1 MB) — `fetchEngineJar` pins it.

## What it is

A THIN client (a manifest, a spawn, and a build hook) over the same `candor-lsp` server every other
editor runs:

- **LSP4IJ** (`com.redhat.devtools.lsp4ij`, works on Community editions) provides the LSP client;
  this plugin contributes the candor server definition + language mappings → CodeLens
  (`⚡ effects · blast radius`), architecture-gate diagnostics, provenance hover.
- **The JVM freshness loop** (the IntelliJ-specific value): `CandorBuildListener` hooks successful
  builds and re-runs the bundled candor-java jar over the compiled output with the IDE's own JVM,
  writing `.candor/report.json`. Opt-in by presence of a `.candor/` directory — the plugin never
  writes into a repo that hasn't adopted candor. Zero external tools (no jbang, no npm for JVM users).
- **Runtime prerequisite:** Node.js on PATH (the server runtime; `$CANDOR_NODE` overrides).

## Build

```bash
gradle buildPlugin          # first run downloads the IntelliJ SDK (large)
# → build/distributions/candor-intellij-<version>.zip (install via Settings → Plugins → ⚙ → Install from disk)
```

## Remaining before Marketplace

1. Compile-verify + `runIde` smoke (the API surface here matches LSP4IJ `0.14.x` docs; pin on build).
2. Multi-module JVM projects: scan a report SET (one per output root) — the LSP already merges a prefix.
3. A "propose a policy" first-run notification (the `candor-init` logic as an IDE action).
4. Marketplace publishing (needs the vendor account) + plugin icon (Beaky).
