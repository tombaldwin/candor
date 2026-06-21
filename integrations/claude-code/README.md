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
| `candor-review.sh` | The review itself — scan → diff vs baseline → gate. Standalone (CI / manual / agent) or called by the hook. Prints the gained effects, their blast radius, and any `AS-EFF-…` policy violation; exit 1 if either fires. |
| `stop-hook.sh` | A Claude Code **Stop** hook wrapping `candor-review.sh`: blocks the stop **once** and feeds the verdict to the agent when something fires; allows otherwise. `stop_hook_active` prevents an infinite loop. |

Engine-agnostic via `CANDOR_CMD` (default `jbang candor@tombaldwin/candor-java`; set it to `npx -y candor-ts`, `cargo candor`, etc.).

## Setup

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

## Environment

| var | meaning | default |
|-----|---------|---------|
| `CANDOR_CLASSES` | compiled classes dir / jar to scan (**required**; build before the hook runs) | — |
| `CANDOR_REVIEW_BASELINE` | the report to diff against | `.candor/baseline.json` |
| `CANDOR_POLICY` | architecture policy; a violation blocks the turn | *(unset → effect-delta only)* |
| `CANDOR_CMD` | the engine | `jbang candor@tombaldwin/candor-java` |

## Behavior

- **Clean** (no new effects, no violation) → the turn ends normally.
- **A new effect or a policy violation** → the Stop hook blocks once and returns the verdict (the gained
  effects, the blast-radius count, the offending method) as the reason; the agent addresses it. If the change
  is intended, refresh the baseline (`… --json .candor/baseline.json`) or relax the policy.
- **Loop-safe** — on the re-invocation after a block, `stop_hook_active` is set, so the hook allows the stop
  rather than blocking forever.

## Notes

- Runs **once per turn** (a Stop hook), not per edit — one build+scan, not one per keystroke.
- For the **scan-source** engines (candor-ts / candor-scan) the build step is unnecessary — point
  `CANDOR_CLASSES` (or the engine's target arg) straight at the source tree.
- `candor-review.sh` is also a fine **git pre-commit hook** or CI step on its own — same verdict, no Claude
  Code required.
