#!/usr/bin/env bash
# WHAT CI ACTUALLY RUNS, PER REPO — printed from the workflows, never from memory.
#
# Why this exists. Twice now I have verified a push against the gate list in an AGENT'S REPORT
# rather than the repo's own list, and both times the gate I skipped was the one that was red:
#   2026-08-29  candor-swift  ci/self-gate.sh   — main sat RED for four commits, every push "green"
#   2026-08-30  candor-rust   soundness/run.sh  — TEN silent under-reports reached main (reverted)
# In both cases I ran a NEIGHBOURING gate with a similar name (self-gate for rust, run_drop.sh for
# the fuzzer) and read its pass as coverage. A list I have to remember to consult is not a control.
#
# So: do not write the list down here either — a hand-maintained copy drifts from the workflows the
# moment a step is added, which is the same failure one level up. Print it from the source of truth.
#
#   bash bin/gates.sh            # every repo
#   bash bin/gates.sh candor-rust
#
# Run every line it prints for a repo before pushing that repo. If a step is genuinely not runnable
# locally (a released-artifact arm, a matrix leg), say so out loud in the report rather than
# quietly dropping it.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPOS=(candor-spec candor-rust candor-java candor-ts candor-swift candor-agents candor)

want="${1:-}"
for r in "${REPOS[@]}"; do
  [ -n "$want" ] && [ "$r" != "$want" ] && continue
  d="$ROOT/$r/.github/workflows"
  printf '\n\033[1m== %s ==\033[0m\n' "$r"
  if [ ! -d "$d" ]; then echo "  (no workflows directory at $d)"; continue; fi
  for wf in "$d"/*.yml "$d"/*.yaml; do
    [ -e "$wf" ] || continue
    # Skip release/tag-triggered workflows: they need a cut, not a push. Named, not hidden.
    case "$(basename "$wf")" in
      release*|publish*|nightly*) printf '  -- %s (release/scheduled — not a pre-push gate)\n' "$(basename "$wf")"; continue ;;
    esac
    printf '  -- %s\n' "$(basename "$wf")"
    # `run:` steps, both the one-line and block forms. Crude on purpose: over-printing a line is
    # cheap, and a clever parser that silently drops a step is exactly the failure this prevents.
    python3 - "$wf" <<'PY'
import sys, re
lines = open(sys.argv[1]).read().splitlines()
i = 0
while i < len(lines):
    m = re.match(r'^(\s*)-?\s*run:\s*(\|?)\s*(.*)$', lines[i])
    if m:
        indent, block, rest = m.group(1), m.group(2), m.group(3).strip()
        if block or not rest:
            i += 1
            while i < len(lines) and (not lines[i].strip() or len(lines[i]) - len(lines[i].lstrip()) > len(indent)):
                if lines[i].strip():
                    # `~` marks a line lifted from a multi-line block. It is part of a script, not
                    # necessarily a standalone command, so bin/gate-run.sh must not execute it blind.
                    print("      ~", lines[i].strip())
                i += 1
            continue
        print("       ", rest)
    i += 1
PY
  done
done
printf '\nRun every line above for the repo you are pushing. The gate you skip is the one that is red.\n'
