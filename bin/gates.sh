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
# CANDOR_ROOT, the same injection point probe.sh and verify-local.sh carry — so this script's own
# output shape (the 8-space gate lines and the 6-space `~` block lines that bin/gate-run.sh parses
# by column) can be driven against a fixture instead of only ever against the real siblings.
ROOT="${CANDOR_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
REPOS=(candor-spec candor-rust candor-java candor-ts candor-swift candor-agents candor)

want="${1:-}"
# A NAME THIS SCRIPT DOES NOT KNOW MUST BE AN ERROR, NOT AN EMPTY LIST. `gates.sh candor-old`
# silently printed nothing, and bin/gate-run.sh — reading that nothing — printed
# "OK — every gate ran and passed" and exited 0. A tool whose whole purpose is "the gate you skip is
# the one that is red" reported green over a repo it had never heard of. Measured 2026-08-30.
if [ -n "$want" ]; then
  _known=0
  for r in "${REPOS[@]}"; do [ "$r" = "$want" ] && _known=1; done
  if [ "$_known" = 0 ]; then
    printf 'gates: unknown repo %s — this script knows: %s\n' "$want" "${REPOS[*]}" >&2
    printf '  An unrecognised name would otherwise print an EMPTY gate list, which reads exactly like\n' >&2
    printf '  a repo with nothing to run. Add it to REPOS above if it is real.\n' >&2
    exit 2
  fi
fi
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
import sys, re, shlex
lines = open(sys.argv[1]).read().splitlines()

# A STEP'S `working-directory:` IS PART OF THE COMMAND, and dropping it is not a cosmetic loss.
# Measured 2026-08-30: this script printed candor-spec's `bash check.sh` and the umbrella's
# `./gradlew buildPlugin --no-daemon` bare, because both live under a `working-directory:`. Run from
# the repo root — which is what bin/gate-run.sh did — neither file exists, so BOTH repos were
# permanently un-greenable, and the reader learns to discount the red. Worse in the other direction:
# where a same-named script DOES exist at the root, the wrong thing runs and passes.
#
# So resolve it per STEP (a `- ` list item), in a pre-pass, because `working-directory:` may sit
# either side of `run:` within the step. Crude in the same direction as the rest of this file: a
# wrongly-attributed `cd` is PRINTED and therefore visible, never silent.
WD = re.compile(r'^\s*-?\s*working-directory:\s*(.+?)\s*$')
starts = [k for k, l in enumerate(lines) if re.match(r'^\s*-\s', l)] + [len(lines)]
wd_of = [""] * (len(lines) + 1)
for a, b in zip(starts, starts[1:]):
    hit = next((WD.match(lines[k]) for k in range(a, b) if WD.match(lines[k])), None)
    w = hit.group(1).strip('\'"') if hit else ""
    for k in range(a, b):
        wd_of[k] = w

i = 0
while i < len(lines):
    # EVERY YAML BLOCK-SCALAR INDICATOR, not just `|`. `run: >` (folded) matched only as a one-line
    # step whose command was the literal `>`, and the step's ACTUAL body — the lines below it — was
    # dropped from the output altogether: not a gate line, not a `~` line, absent. Latent (nothing in
    # the family uses `>` today) but it is precisely the silently-narrowed list these two files exist
    # to prevent, and it was reachable by writing one workflow.
    m = re.match(r'^(\s*)-?\s*run:\s*([|>][-+0-9]*)?\s*(.*)$', lines[i])
    if m:
        indent, block, rest = m.group(1), (m.group(2) or ''), m.group(3).strip()
        wd = wd_of[i]
        if block or not rest:
            if wd:
                # Informational, and deliberately at neither of the two column positions gate-run.sh
                # parses (8 spaces = a gate, 6 spaces + `~ ` = a block line): it is not a command.
                print("      (working-directory: %s — the ~ lines below run there)" % wd)
            i += 1
            while i < len(lines) and (not lines[i].strip() or len(lines[i]) - len(lines[i].lstrip()) > len(indent)):
                if lines[i].strip():
                    # `~` marks a line lifted from a multi-line block. It is part of a script, not
                    # necessarily a standalone command, so bin/gate-run.sh must not execute it blind.
                    print("      ~", lines[i].strip())
                i += 1
            continue
        # `cd X && …` rather than a separate annotation: it is what a human should type, AND it is
        # directly executable, so the printed list and the run list cannot drift apart.
        print("       ", ("cd %s && %s" % (shlex.quote(wd), rest)) if wd else rest)
    i += 1
PY
  done
done
printf '\nRun every line above for the repo you are pushing. The gate you skip is the one that is red.\n'
