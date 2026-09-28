#!/usr/bin/env bash
# fast-gates.sh — every umbrella gate that needs NO engine build, NO IDE distribution and NO npm.
#
# WHY THIS EXISTS, measured 2026-09-24. I edited ONE PARAGRAPH of markdown in
# `bin/AGENT-CORPUS-BRIEF.md` and, following the standing rule in CLAUDE.md ("before pushing a repo,
# run ITS gates — from a fixed list, not from whatever the agent's report mentioned"), ran
# `bin/gate-run.sh candor`. Gate 12 of 18 is `./gradlew verifyPlugin`, the JetBrains Plugin Verifier,
# which unpacks and checks the plugin against SEVEN IntelliJ distributions. It ran for an hour and
# consumed **28 GB**, taking the volume to 121 MiB free — 100% full.
#
# That is not a nuisance, it is the disk hazard this repo already documents one level up: "a full disk
# fakes a FAIL and fakes an empty result, and says neither". A docs edit had put every other agent's
# measurement at risk, and the only way to avoid it was to skip the gate list by judgement — which is
# precisely the habit the fixed-list rule exists to remove. **A rule with no affordable path gets
# broken, and then it is not a rule.** candor-spec solved the same problem with `scripts/doc-gates.sh`;
# the umbrella had no equivalent, so this is it.
#
# WHAT THIS COVERS: the 13 gates below, ~50s wall clock total (measured, see the table in the commit).
# WHAT IT DOES NOT COVER, and the omission is NAMED rather than silent — these five are in
# `bin/gates.sh candor` and are deliberately absent here:
#
#     cd integrations/jetbrains && ./gradlew buildPlugin    — builds the plugin (gradle)
#     cd integrations/jetbrains && ./gradlew verifyPlugin   — 7 IDE distributions, ~1h, ~28 GB
#     bash bin/release-test.sh                              — BUILDS ENGINES (18 build invocations)
#     bash integrations/vscode/test-vscode.sh               — needs npm
#     python -m pip install --quiet jsonschema              — provisioning; CI-only
#
# SO — AND THE FIRST VERSION OF THIS PARAGRAPH WAS WRONG, corrected 2026-09-24 the same day it was
# written. It said this script was "sufficient for a change to docs, briefs, workflows, or the shell
# tooling in `bin/`". It is NOT sufficient for a `bin/**` change, and that is the very case it was
# written for. THREE umbrella workflows filter on `bin/**` — `integrations.yml`, `release-scripts.yml`
# and `shell-lint.yml` — and all three ran, green, on the markdown commit that prompted this file
# (`3ec56b3`, 13:06). One of them runs `bash bin/release-test.sh`, the 18-build engine gate this tier
# deliberately omits. So for a `bin/**` edit, CI runs strictly MORE than this does.
#
# THE ERROR IS THE ONE THIS REPO DOCUMENTS MOST OFTEN: a comment asserting safety, written in the same
# commit as the code, that nobody verifies because it is what makes the diff look correct. I then
# repeated the claim ("CI would have run nothing for that edit") twice before measuring it — the
# measurement took one `gh run list` per workflow.
#
# WHAT IS ACTUALLY TRUE: this tier is sufficient for a change to documentation and briefs — files no
# workflow's `paths:` selects. For `bin/**`, treat it as a fast FIRST pass and let CI be the gate, or
# run `bin/gate-run.sh candor`. It is NOT sufficient for the plugin, the VS Code extension, the
# release ladder, or anything an engine builds, and it is NEVER a substitute for `gate-run.sh` before
# a release. Naming the five omissions above is so a reader sees the trade rather than discovering it
# after a push — which is exactly what failed here, because the omission was named and the SCOPE
# sentence beside it was not true.
#
# NOTE ON `python` vs `python3`: two of CI's steps invoke bare `python`, which is not installed on a
# stock macOS, so `gate-run.sh` reports them SKIP locally and the syntax of two shipped scripts goes
# unchecked on the machine they are edited on. This tier runs them under `python3`, which is strictly
# more coverage than the local gate list gives — it is the same check, not a different one.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bin_warn_state() {  # <dirty> <staged> <last-commit> <upstream-name> <ahead-count>  -> WARN|QUIET
  [ "$1" = "1" ] || [ "$2" = "1" ] && { echo WARN; return; }
  [ "$3" = "1" ] || { echo QUIET; return; }
  [ -n "$4" ] || { echo WARN; return; }            # no upstream — cannot tell, so warn
  case "$5" in ''|*[!0-9]*) echo WARN ;; 0) echo QUIET ;; *) echo WARN ;; esac
}

if [ "${1:-}" = "--selftest" ]; then
  bad=0
  chk() {  # <want> <label> <args...>
    want="$1"; label="$2"; shift 2
    got="$(bin_warn_state "$@")"
    if [ "$got" = "$want" ]; then echo "  ok   $label -> $got"
    else echo "  FAIL $label -> $got, want $want"; bad=$((bad + 1)); fi
  }
  chk WARN  "an uncommitted bin/ edit warns"                 1 0 0 origin/main 0
  chk WARN  "a STAGED bin/ edit warns"                       0 1 0 origin/main 0
  chk QUIET "no bin/ anywhere is quiet"                      0 0 0 origin/main 0
  chk WARN  "an UNPUSHED bin/ commit warns"                  0 0 1 origin/main 2
  chk QUIET "a PUSHED bin/ commit is quiet (the wolf case)"  0 0 1 origin/main 0
  chk WARN  "NO UPSTREAM warns — R544, cannot tell"          0 0 1 ""          0
  chk WARN  "an UNREADABLE ahead-count warns, not silences"  0 0 1 origin/main ""
  chk WARN  "a non-numeric ahead-count warns"                0 0 1 origin/main "fatal:"
  chk WARN  "dirty beats a pushed last commit"               1 0 1 origin/main 0
  echo "fast-gates --selftest: $([ "$bad" -eq 0 ] && echo OK || echo "FAILED ($bad)")"
  exit "$([ "$bad" -eq 0 ] && echo 0 || echo 1)"
fi

cd "$HERE" || exit 2

# THE DISK CHECK IS FIRST, for the reason in the header: this file exists BECAUSE a gate filled the
# disk, and a full disk makes every result below meaningless in the OK direction.
#
# IT NOW LATCHES, AND FOR TWO DAYS THE COMMENT SAYING SO WAS FALSE. SOUNDNESS R644: the first version
# ran `disk-guard.sh` ONCE, AS A SUBPROCESS, and never again — there was nothing to latch, because
# `CANDOR_DISK_BROKE` lives in the guard's own process and dies with it. The comment was then corrected
# to admit that (the honest move, and still only a comment), and this is the mechanism it was admitting
# to not having: the guard is SOURCED, exactly as `gate-run.sh:85` does it, and `disk_guard_check` runs
# after EVERY gate.
#
# WHY THE MECHANISM AND NOT THE SENTENCE. CLAUDE.md names this blind spot: "the dangerous case is the
# MID-RUN crossing, not the start … a startup-only check is blind to precisely the case that bites."
# The residual risk in a ~50s tier is small, which is why a corrected sentence was defensible — but the
# crossing does not need this script to be the thing that fills the disk. A concurrent agent's rust
# build or Docker leg is GB each, and half of this tier's gates run node, python and shellcheck over
# trees that another wave is writing to. A gate that goes red at second 40 because the volume filled at
# second 20 is a FALSE FAIL, and this file exists because that failure is indistinguishable from a real
# one. Sourcing the guard costs one line.
. "$HERE/bin/disk-guard.sh"
if ! disk_guard_check "before the first gate"; then
  echo "fast-gates: REFUSING — bin/disk-guard.sh is unhappy. A full disk fakes a FAIL and fakes an"
  echo "  empty result, and says neither. Reclaim space, then re-run."
  bash "$HERE/bin/disk-guard.sh"
  exit 2
fi

fail=0
ran=0
run() {
  local label="$1"; shift
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  ran=$((ran + 1))
  if [ $rc -eq 0 ]; then
    printf '  %-30s OK\n' "$label"
  else
    printf '  %-30s FAIL (exit %d)\n' "$label" "$rc"
    printf '%s\n' "$out" | sed 's/^/      /' | head -20
    fail=1
  fi
  # AFTER EVERY GATE, and the latch is why the ORDER of these two lines does not matter: once
  # `disk_guard_check` has seen a breach it stays broken for the rest of the run, so the verdict below
  # can name the gate it first crossed at rather than the one that happened to be running last.
  disk_guard_check "$label" || true
}

echo "fast-gates — no engine build, no IDE, no npm. NOT a substitute for gate-run.sh before a release."
echo "  For a bin/** change CI runs MORE than this (release-scripts.yml runs release-test.sh)."
run "ast: candor-sarif"     python3 -c "import ast; ast.parse(open('integrations/github/candor-sarif').read())"
run "ast: candor-init"      python3 -c "import ast; ast.parse(open('adopt/candor-init').read())"
run "test-stop-hook"        bash integrations/claude-code/test-stop-hook.sh
run "test-candor-sarif"     bash integrations/github/test-candor-sarif.sh
run "test-candor-init"      bash adopt/test-candor-init.sh
run "test-candor-init-sh"   bash adopt/test-candor-init-sh.sh
run "test-fingerprint"      bash fingerprint/test-fingerprint.sh
run "candor.test"           bash bin/candor.test.sh
run "corpus-ab.test"        bash bin/corpus-ab.test.sh
run "corpus-ledger.test"    bash bin/corpus-ledger.test.sh
run "ci-watch --selftest"   bash bin/ci-watch.sh --selftest
run "pin-currency --selftest" bash bin/pin-currency.sh --selftest
run "shellcheck bin"        sh -c 'shellcheck -S warning bin/*.sh'
run "ts-fitness-pin"        bash bin/ts-fitness-pin.sh
run "ts-fitness-pin --selftest" bash bin/ts-fitness-pin.sh --selftest
# This file gating ITSELF is not circular: `--selftest` short-circuits before the gate list, so the
# subprocess runs nine pure-function cases and exits. It is here because the bin/** predicate it
# checks had NO test until it cried wolf, and an untested predicate inside a warning about untested
# changes is the shape this register keeps finding.
run "fast-gates --selftest" bash bin/fast-gates.sh --selftest
run "workflow-check"        bash bin/workflow-check.sh candor

# AN EMPTY RUN IS NOT A PASS. Same fail-closed shape as gate-run.sh's zero-gate guard and the spec's
# `soundness-status.py` refusal: if the list above ever stops executing — a rename, a bad `cd`, the
# `run` helper losing its name — silence must not read as success.
#
# ONE OF THE THREE TRIGGERS THIS COMMENT USED TO NAME COULD NEVER FIRE, and it was measured rather than
# reasoned about (SOUNDNESS R644): "a `set -e` added at the top" cannot reach this guard, because under
# `set -e` the first failing gate aborts the script before the check below is read. A trigger list is a
# claim about reachability, so it gets the same treatment as any other comment asserting a property.
if [ "$ran" -eq 0 ]; then
  echo "fast-gates: REFUSING — zero gates executed. Silence is not success."
  exit 2
fi

# THE DISK VERDICT OUTRANKS BOTH OF THE OTHERS, deliberately — CLAUDE.md: "a FAIL after the crossing is
# not a finding", and neither is a PASS. A run that crossed the floor put rows from both sides of the
# line in one list and does not otherwise say which is which.
if disk_guard_verdict_note; then
  echo "fast-gates: INCOMPLETE — $ran gate(s) ran, and the disk crossed the floor DURING the run."
  echo "  Neither the greens nor the reds above are evidence. Reclaim space and re-run."
  exit 2
fi

# THE `bin/**` WARNING BELONGS IN THE OUTPUT, NOT ONLY IN THE HEADER. Measured 2026-09-27: this file's
# header has said since the day it was written that it is NOT sufficient for a `bin/**` change — "for a
# `bin/**` edit, CI runs strictly MORE than this does" — and I pushed a `bin/**` change on the strength
# of a green run here anyway, because what I read was the CLOSING LINE ("named at the top of this
# file") and not the top of the file. CI then went red on `release-scripts` over a real defect in that
# change: `-d "$d/.git"` as a checkout test, which is FALSE for a git worktree.
#
# The header was right, in the right place, and unread — which is this family's own
# documented-limitation shape. So the warning now fires where the reader already is, and it names the
# one command that would have caught it. Deliberately NOT a failure: making the cheap tier red on a
# `bin/**` edit would destroy the affordable path it exists to provide, and a rule with no affordable
# path gets broken.
# AND IT MUST NOT CRY WOLF, measured 2026-09-28. The third clause below read `HEAD~1..HEAD`
# unconditionally, so after any `bin/**` commit the warning kept firing on EVERY later run — including
# after the change had been pushed and CI had already run the gate it names. I hit that one turn after
# editing this warning into existence: a BACKLOG.md-only edit printed "THIS CHANGE TOUCHES bin/**",
# over a bin/ commit whose `release-test.sh` had already passed AND been pushed.
#
# That matters more than the noise: this warning exists because a HEADER saying the same thing went
# unread for weeks. A warning that fires when there is nothing to do is on exactly that road, and the
# register is full of guards that were true and therefore ignored. So the last-commit clause now asks
# whether the commit has REACHED CI, i.e. whether HEAD is ahead of its upstream.
#
# FAIL-SAFE IS TO WARN. R544 is the trap: `@{u}` is unset on 6 of 7 repos in this family and
# `git rev-parse` then FAILS, so a `!` test reads a fatal error as a confident answer — and
# `rev-list` returning empty is AMBIGUOUS between "nothing ahead" and "the command failed".
# Every path that cannot answer keeps the warning; only a definite "0 commits ahead" silences it.
_bin_dirty=0;  _bin_staged=0;  _bin_last=0
git -C "$HERE" diff --name-only HEAD 2>/dev/null | grep -q '^bin/' && _bin_dirty=1
git -C "$HERE" diff --name-only --cached HEAD 2>/dev/null | grep -q '^bin/' && _bin_staged=1
git -C "$HERE" diff --name-only 'HEAD~1..HEAD' 2>/dev/null | grep -q '^bin/' && _bin_last=1
_bin_up="$(git -C "$HERE" rev-parse --abbrev-ref '@{u}' 2>/dev/null || true)"
_bin_ahead="$(git -C "$HERE" rev-list --count "$_bin_up..HEAD" 2>/dev/null || true)"
touched_bin=""
[ "$(bin_warn_state "$_bin_dirty" "$_bin_staged" "$_bin_last" "$_bin_up" "$_bin_ahead")" = "WARN" ] \
  && touched_bin=1

if [ "$fail" -eq 0 ]; then
  echo "fast-gates: OK — $ran gate(s), none of which builds an engine, an IDE or an npm tree."
  echo "  Five heavier gates were NOT run; they are named at the top of this file. Before a release,"
  echo "  run \`bash bin/gate-run.sh candor\`."
  if [ -n "$touched_bin" ]; then
    echo
    echo "  ⚠ THIS CHANGE TOUCHES bin/** AND THIS RUN IS NOT SUFFICIENT FOR IT."
    echo "    Three umbrella workflows filter on bin/** — integrations, release-scripts, shell-lint —"
    echo "    and release-scripts runs \`bash bin/release-test.sh\`, which this tier omits. It takes"
    echo "    ~130s locally. Run it before pushing:  bash bin/release-test.sh"
  fi
  exit 0
fi
echo "fast-gates: FAILED — $ran gate(s) run, at least one red."
exit 1
