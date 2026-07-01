# candor → GitHub PR-native gate (SARIF)

Surface candor architecture-gate violations **where code review happens** — inline on the
pull-request diff and in the repo's **Code-scanning / Security** tab — on the exact line a
boundary is crossed. A red CI check says *"something failed"*; this says *"`OrderService.quote`
now reaches `Db`, crossing the domain→infra boundary you declared."*

This is a **reporter over candor's standard outputs**, not a new analysis: it reads the spec-0.7
report envelope + the engine's structured gate verdict and writes [SARIF 2.1.0](https://sarifweb.azurewebsites.net/).
It never changes the pass/fail decision — the engine's exit code stays the source of truth.

## Pieces

| File | What it is |
|------|------------|
| [`candor-sarif`](./candor-sarif) | The reporter: `report.json` + `gate.json` → `candor.sarif`. Python 3, stdlib only. |
| [`test-candor-sarif.sh`](./test-candor-sarif.sh) | Hermetic contract test (16 assertions — no engine, no network). |
| [`PR-GATE-DESIGN.md`](./PR-GATE-DESIGN.md) | The design + scope. |

The GitHub Action wiring lives in [`../../adopt/candor.yml`](../../adopt/candor.yml) (copy-paste starter).

## How it works

1. The gating run emits a machine-readable verdict alongside the report:
   ```bash
   CANDOR_POLICY=arch.policy candor <classes> --json report.json --gate-json gate.json
   ```
   `gate.json` is `{ "spec", "ok", "violations":[ { "rule", "fn", "detail" } ] }` — the structured
   analog of the `AS-EFF-…` console lines, captured from the **same** diagnostics that set the exit
   code, so the SARIF can never disagree with the gate. (candor-java engine feature; the other
   engines gain it as the capability is promoted to the shared spec.)
2. The reporter joins each violation to its source location + effects from the report envelope and
   writes SARIF:
   ```bash
   candor-sarif report.json --gate gate.json --src-root src/main/java -o candor.sarif
   ```
3. `github/codeql-action/upload-sarif` publishes it — inline PR annotations **and** the Security tab
   from one file.

## `candor-sarif` options

```
candor-sarif <report.json> --gate <gate.json> [--src-root DIR] [--query-cmd "CMD"] [-o out.sarif]
```

- `--src-root DIR` — where SARIF `uri`s are rooted. candor-java's `loc` is a bare `File.java:line`
  (the bytecode SourceFile), so the repo path is rebuilt from the fn's package:
  `app.domain.Order.audit` + `Order.java` + `--src-root src/main/java` → `src/main/java/app/domain/Order.java`.
  A scan engine whose `loc` is **already a path** (ts/swift/rust) is used as-is — `--src-root` only
  affects the bytecode rebuild.
- `--query-cmd "CMD"` — optional. When set, each violation gets a SARIF **codeFlow** from
  `CMD path <report> <fn> <effect> --json` — the hop chain to the effect's source, rendered as a
  clickable trace in the Security tab (e.g. `checkout → audit — source`). Costs one query per
  violation; omit it for the fastest CI.

## Notes

- **Fail-safe:** a malformed/missing input is reported on stderr and yields an empty-results SARIF
  (exit 0) — the reporter never masks the gate.
- **`loc` precision (candor-java):** bytecode line numbers need debug info (`LineNumberTable`, present
  with default `mvn`/`gradle` builds). Without `-g`, a violation lands at file granularity rather than
  fabricating a line.
- **Scope today:** the reporter covers every AS-EFF code candor emits (policy 006/008/009, baseline
  005, ambient 004, conformance 001–003; advisory 007 as a warning). `ok` reflects the CI gate verdict.
