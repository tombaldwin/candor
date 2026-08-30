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

# The trigger classifier used by the loop below. See the long comment at its call site for WHY the
# question is "what does this workflow's own `on:` block say" and not "what is it called".
TRIGGERS="$(mktemp -t candor-gates-triggers)"
trap 'rm -f "$TRIGGERS"' EXIT
cat > "$TRIGGERS" <<'PY'
import sys, re
lines = open(sys.argv[1]).read().splitlines()
i = 0
while i < len(lines) and not re.match(r'''^["']?on["']?\s*:''', lines[i]):
    i += 1
if i >= len(lines) or lines[i].split(':', 1)[1].strip():
    print(""); raise SystemExit          # no readable `on:`, or an inline one — PRINT the workflow
keys, push_sub = [], []
i += 1
while i < len(lines):
    if lines[i].strip() and not lines[i][:1].isspace():
        break                            # dedented back out of the `on:` mapping
    m = re.match(r'^  ([A-Za-z_]+)\s*:', lines[i])
    if m:
        keys.append(m.group(1))
        if m.group(1) == 'push':
            j = i + 1
            while j < len(lines) and (not lines[j].strip() or lines[j].startswith('    ')):
                s = re.match(r'^    ([A-Za-z_-]+)\s*:', lines[j])
                if s and not lines[j].lstrip().startswith('#'):
                    push_sub.append(s.group(1))
                j += 1
    i += 1
# `push: tags: [v*]` needs a CUT, not a push. A `push:` restricted to anything else — or to nothing —
# can land on a branch, so it gates a push and must be printed.
tags_only = bool(push_sub) and set(push_sub) <= {'tags', 'tags-ignore'}
gate = ('pull_request' in keys) or ('push' in keys and not tags_only)
# EXCLUDING IS NARROWING, SO SAY WHAT IS BEHIND THE EXCLUSION. A bare "not a pre-push gate" reads as
# "nothing here"; the step COUNT says how much this line is standing in front of, so a wrong call is
# visible as a number rather than as an absence. This is the same reason gate-run.sh reports skipped
# and block lines instead of dropping them.
steps = sum(1 for l in lines if re.match(r'^\s*-?\s*run:', l))
print("" if gate else "on: %s%s — not a pre-push gate; %d run step(s) behind this line" % (
    ", ".join(keys) or "?", " (tags only)" if tags_only else "", steps))
PY

excluded=0
for r in "${REPOS[@]}"; do
  [ -n "$want" ] && [ "$r" != "$want" ] && continue
  d="$ROOT/$r/.github/workflows"
  printf '\n\033[1m== %s ==\033[0m\n' "$r"
  if [ ! -d "$d" ]; then echo "  (no workflows directory at $d)"; continue; fi
  for wf in "$d"/*.yml "$d"/*.yaml; do
    [ -e "$wf" ] || continue
    # WHICH WORKFLOWS GATE A PUSH IS DECIDED BY THEIR OWN `on:` BLOCK — NEVER BY THEIR FILENAME.
    #
    # This was `case "$(basename "$wf")" in release*|publish*|nightly*)`, and a name glob was wrong in
    # BOTH directions on the repo that holds this file. Measured 2026-08-30:
    #   * DROPPED a real gate. The umbrella's own `release-scripts.yml` is `on: push: branches:[main]`
    #     + `pull_request` — it is the job that runs `bash bin/release-test.sh` — and it was excluded
    #     from `gates.sh candor` by its NAME, under a parenthetical that read like a considered
    #     decision. The gate list for this repo was silently narrowed by a string match, which is the
    #     exact failure these two files exist to prevent (AGENT-CORPUS-BRIEF §9: a boundary drawn
    #     around a NAME is as bad as one drawn around its trigger).
    #   * KEPT three lines that cannot run. `corpus.yml` is schedule-only and builds SIBLINGS from
    #     paths CI creates by checking them out into the workspace, so `cargo build --manifest-path
    #     candor-rust/Cargo.toml` from the umbrella root fails on every desk — `gate-run.sh candor`
    #     was permanently red for a reason that is not a defect, the same shape as candor-java's
    #     unexpanded `${{ matrix.asset }}`, and a reader learns to discount the red.
    #
    # Ask the authority (attack G). Crude in the SAFE direction, like the rest of this file: a
    # workflow is PRINTED unless the parse positively proves it cannot run on a push to a branch, so
    # an `on:` shape this cannot read — or a dead python3 — over-prints rather than drops. The reason
    # names the triggers it read, so a WRONG parse is visible on screen instead of being a short list.
    #
    # The classifier is written to a FILE at the top of this script rather than heredoc'd here: a
    # heredoc nested inside `$(...)` is a shell parse hazard, and it is the first of the nine defects
    # bin/release-test.sh's own header records (0.25). Reproduced while writing this line.
    why="$(python3 "$TRIGGERS" "$wf")"
    if [ -n "$why" ]; then
      printf '  -- %s (%s)\n' "$(basename "$wf")" "$why"
      excluded=$((excluded + 1))
      continue
    fi
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
# COUNT WHAT WAS EXCLUDED, at the bottom, where the verdict is read. Each exclusion is already named
# beside its workflow, but a per-workflow parenthetical scrolls past; a total does not. If this number
# is not what you expect, the `on:` parse is wrong and the list above is short.
[ "$excluded" -gt 0 ] && printf '%s workflow(s) excluded above as not-pre-push (schedule / dispatch / tag-only) — each named with its own triggers.\n' "$excluded"
exit 0
