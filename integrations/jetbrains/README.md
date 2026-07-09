# candor for JetBrains IDEs — plugin skeleton

**Status: UPLOADED to the JetBrains Marketplace (2026-07-03; first-plugin moderation pending).**
`./gradlew buildPlugin` produces `build/distributions/candor-intellij-<pluginVersion>.zip`
(sideloadable via Settings → Plugins → ⚙ → Install from disk) against IC 2024.3 + LSP4IJ 0.20.1,
with both artifacts embedded and verified at build time: the single-file server bundle
(`server/candor-lsp.mjs`, handshake-gated by `verifyServerBundle`) and the pinned released engine
(`engine/candor-java-all.jar`, self-report-gated by `verifyEngineJar` against `candorJavaVersion`).
Not yet `runIde`-smoked.

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

**Versioning:** the plugin's major.minor tracks the candor-spec version of its bundled toolchain
(the family rule) — 0.8.x ships spec-0.8 tools (candor-java 0.8.x jar + the candor-ts 0.8.x server);
the patch floats per plugin release.

## Build

```bash
./gradlew buildPlugin       # first run downloads Gradle + the IntelliJ SDK (large)
# → build/distributions/candor-intellij-<version>.zip (install via Settings → Plugins → ⚙ → Install from disk)
```

The engine + server pins live in `gradle.properties` (`candorJavaVersion`, `candorTsVersion`); both are
build-task inputs, so bumping a pin re-stages and re-verifies the embed on the next build.

## Remaining

1. Marketplace moderation (uploaded 2026-07-03) → on approval, wire `publishPlugin` + the token as a
   repo secret so 0.8.1+ ship headlessly.
2. `runIde` smoke (compile-verification done — the build listener uses the modern
   `finished(ProjectTaskManager.Result)` + declarative `<projectListeners>` with constructor injection);
   an install-from-disk smoke in a real IDE is worthwhile whenever convenient.
3. Multi-module JVM projects: scan a report SET (one per output root) — the LSP already merges a prefix.
4. A "propose a policy" first-run notification (the `candor-init` logic as an IDE action).
