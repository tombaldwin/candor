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
cd "$HERE" || exit 2

# THE DISK CHECK IS FIRST AND IT LATCHES, for the reason in the header: this file exists BECAUSE a
# gate filled the disk, and a full disk makes every result below meaningless in the OK direction.
if ! bash "$HERE/bin/disk-guard.sh" >/dev/null 2>&1; then
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
run "ci-watch --selftest"   bash bin/ci-watch.sh --selftest
run "pin-currency --selftest" bash bin/pin-currency.sh --selftest
run "shellcheck bin"        sh -c 'shellcheck -S warning bin/*.sh'
run "workflow-check"        bash bin/workflow-check.sh candor

# AN EMPTY RUN IS NOT A PASS. Same fail-closed shape as gate-run.sh's zero-gate guard and the spec's
# `soundness-status.py` refusal: if the list above ever stops executing — a rename, a bad `cd`, a
# `set -e` added at the top — silence must not read as success.
if [ "$ran" -eq 0 ]; then
  echo "fast-gates: REFUSING — zero gates executed. Silence is not success."
  exit 2
fi

if [ "$fail" -eq 0 ]; then
  echo "fast-gates: OK — $ran gate(s), none of which builds an engine, an IDE or an npm tree."
  echo "  Five heavier gates were NOT run; they are named at the top of this file. Before a release,"
  echo "  run \`bash bin/gate-run.sh candor\`."
  exit 0
fi
echo "fast-gates: FAILED — $ran gate(s) run, at least one red."
exit 1
