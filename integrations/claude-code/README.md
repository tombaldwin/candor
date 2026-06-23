# candor × Claude Code — edit-time blast-radius feedback

Close the loop: after an agent finishes a turn, candor scans the result, diffs the effects against a
baseline, and — if an edit **introduced a new effect** or **breached the architecture** — hands the verdict
*back to the agent* so it fixes it before yielding to you. The delta reaches the agent automatically instead
of waiting for a human review or a CI failure.

This is the deterministic counterpart to "the model will probably notice": candor computes an edit's *gained
effects and their transitive blast radius* exactly, and the Stop hook makes the agent see it.

## What's here

| File | Role |
|------|------|
| `candor-review.sh` | The review for the **JVM** (candor-java reads bytecode). Scan compiled classes → diff vs baseline → gate. Standalone (CI / manual / agent) or called by the hook. Prints the gained effects, their blast radius, and any `AS-EFF-…` policy violation; exit 1 if either fires. |
| `candor-review-source.sh` | The review for the **scan-source** engines (candor-ts / candor-swift / candor-scan) — same job, but reads source directly, so **no build step**. Same exit contract. |
| `stop-hook.sh` | A Claude Code **Stop** hook wrapping a review script: blocks the stop **once** and feeds the verdict to the agent when something fires; allows otherwise. On every turn it also shows you a one-line `systemMessage` notice (`✓` clean / `⚠` blocked / setup error) so candor is visible even when nothing's wrong — tune with `CANDOR_HOOK_NOTICE` (`summary` default / `changes` / `quiet` / `off`). `stop_hook_active` prevents an infinite loop. `CANDOR_REVIEW` selects the script (defaults to the JVM `candor-review.sh`). |

Two review scripts share one exit contract (0 clean / 1 block / 2 setup) so the hook is engine-agnostic:
pick the JVM script (`candor-review.sh`, scans bytecode) or the scan-source script
(`candor-review-source.sh`, scans source — no build) via `CANDOR_REVIEW`.

## Setup — JVM (candor-java, bytecode)

1. **Establish a baseline** from your last-known-good build:
   ```sh
   mvn -q compile   # or: ./gradlew classes
   jbang candor@tombaldwin/candor-java target/classes --json .candor/baseline.json
   ```
2. *(optional)* drop an `arch.policy` at the repo root (see [`../../adopt/arch.policy`](../../adopt/arch.policy))
   to also gate boundaries (`deny Db io.app.domain`, …).
3. **Wire the hook** in `.claude/settings.json` (project) or `~/.claude/settings.json` (global). The command
   must **build first** (the hook scans compiled classes), then run the hook:
   ```json
   {
     "hooks": {
       "Stop": [ { "hooks": [ {
         "type": "command",
         "command": "mvn -q compile && CANDOR_CLASSES=target/classes CANDOR_POLICY=arch.policy CANDOR_REVIEW_BASELINE=.candor/baseline.json /abs/path/to/integrations/claude-code/stop-hook.sh"
       } ] } ] }
     }
   }
   ```

## Setup — scan-source (candor-ts / candor-swift / candor-scan, no build)

These engines read source directly, so there's nothing to build — point `CANDOR_REVIEW` at
`candor-review-source.sh` and `CANDOR_SCAN` at the engine. `CANDOR_SRC` is the source dir.

1. **Establish a baseline** (the engine writes `<prefix>…json`; copy the report, dropping the
   `.callgraph`/`.hierarchy` sidecars):
   ```sh
   npx -y candor-ts src --out .candor/base       # ts   (swift: candor-swift · rust: candor-scan)
   cp "$(ls .candor/base*.json | grep -ve callgraph -e hierarchy | head -1)" .candor/baseline.json
   ```
2. *(optional)* an `arch.policy` as above — every engine honours `CANDOR_POLICY`.
3. **Wire the hook** — no build prefix needed:
   ```json
   {
     "hooks": {
       "Stop": [ { "hooks": [ {
         "type": "command",
         "command": "CANDOR_REVIEW=/abs/path/to/integrations/claude-code/candor-review-source.sh CANDOR_SCAN='npx -y candor-ts' CANDOR_SRC=src CANDOR_POLICY=arch.policy CANDOR_REVIEW_BASELINE=.candor/baseline.json /abs/path/to/integrations/claude-code/stop-hook.sh"
       } ] } ] }
     }
   }
   ```
   Per engine, set `CANDOR_SCAN` to: `npx -y candor-ts` · `candor-swift` · `candor-scan`.

## Environment

Shared by the hook and both review scripts:

| var | meaning | default |
|-----|---------|---------|
| `CANDOR_REVIEW` | the review script the hook runs | `candor-review.sh` (JVM) |
| `CANDOR_REVIEW_BASELINE` | the report to diff against | `.candor/baseline.json` |
| `CANDOR_POLICY` | architecture policy; a violation blocks the turn | *(unset → effect-delta only)* |

JVM review (`candor-review.sh`):

| var | meaning | default |
|-----|---------|---------|
| `CANDOR_CLASSES` | compiled classes dir / jar to scan (**required**; build before the hook runs) | — |
| `CANDOR_CMD` | the engine | `jbang candor@tombaldwin/candor-java` |

Scan-source review (`candor-review-source.sh`):

| var | meaning | default |
|-----|---------|---------|
| `CANDOR_SCAN` | the analyze command (**required**) — `npx -y candor-ts` / `candor-swift` / `candor-scan` | — |
| `CANDOR_SRC` | the source dir to scan | `.` |

## Behavior

- **Clean** (no new effects, no violation) → the turn ends normally.
- **A new effect or a policy violation** → the Stop hook blocks once and returns the verdict (the gained
  effects, the blast-radius count, the offending method) as the reason; the agent addresses it. If the change
  is intended, refresh the baseline (`… --json .candor/baseline.json`) or relax the policy.
- **Loop-safe** — on the re-invocation after a block, `stop_hook_active` is set, so the hook allows the stop
  rather than blocking forever.

## Notes

- Runs **once per turn** (a Stop hook), not per edit — one scan, not one per keystroke. The JVM path also
  builds once per turn; the scan-source path skips the build entirely.
- Either review script is also a fine **git pre-commit hook** or CI step on its own — same verdict, no Claude
  Code required.
- The effect delta is computed straight from the two spec-0.7 report files (the standard envelope), so it's
  engine-agnostic and catches the dominant case: a function that was pure and is now effectful.
