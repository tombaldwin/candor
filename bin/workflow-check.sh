#!/usr/bin/env bash
# workflow-check.sh — catch workflow files that are VALID YAML and INVALID GitHub Actions.
#
#   bash bin/workflow-check.sh [<repo> ...]     # default: every repo in RS_FAMILY
#   bash bin/workflow-check.sh --selftest
#
# WHY THIS EXISTS, stated as it happened. 2026-09-13: the `assert-audit` CI job's comment named its own
# mechanism by writing an EMPTY GitHub expression literally. GitHub interpolates expressions BEFORE the
# shell sees the file, so it parsed that as an expression, failed, and rejected the WHOLE workflow. No
# jobs ran, and all four engines reported the failure against `.github/workflows/ci.yml` — the file
# PATH rather than the workflow `name:`, which is the tell that a workflow did not PARSE.
#
# `python3 -c "yaml.safe_load(...)"` passes on that file. It is valid YAML. The two validators disagree
# and only one of them runs locally, which is exactly the gap this closes: every check that stood
# between the edit and `main` was blind to it, and the cost was four red mains at once.
#
# DELIBERATELY NARROW. This does not reimplement GitHub's expression grammar — that is a second copy of
# someone else's parser, and it would rot. It asks the small number of questions whose answers are
# unambiguous and whose failure mode is total (the workflow does not run AT ALL):
#   1. every `${{ … }}` has a non-empty body;
#   2. an opener with no closer anywhere in the file (`${{ foo }` at EOF). A STRAY CLOSER
#      (`${{ foo }}}`) is NOT flagged and must not be: GitHub interpolates and leaves the extra
#      brace as text, so it is valid. The first cut of this header claimed both were caught —
#      a false claim about coverage, in a file whose subject is checks that assert more than
#      they do. Caught by review, measured: rc 0.
#   3. the file parses as YAML and has `on:` and `jobs:` with at least one job;
#   4. every job has `runs-on` and `steps`.
# A workflow that passes all four can still be rejected for something else. This is a floor, not a
# proof, and saying so is the point — see `candor-oracle-disclosure-recall`: a check nobody has seen
# fail is a check nobody has tested, so `--selftest` drives each arm in both directions.
set -uo pipefail
ROOT="${CANDOR_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

check_file() {  # $1 = path -> prints problems; rc 1 if any
  python3 - "$1" <<'CHECK_PY'
import sys, yaml

p = sys.argv[1]
text = open(p, encoding="utf-8").read()
bad = 0

# ---- expressions -------------------------------------------------------------------------------
# SCANNED ACROSS THE WHOLE TEXT, opener to the next closer — NOT line-by-line with `[^}]*`.
# The first cut did the latter and reported two FALSE POSITIVES on workflows GitHub accepts, in a
# BLOCKING gate:
#     matrix: ${{ fromJSON('{"os":["ubuntu-latest"]}') }}     a brace INSIDE the expression
#     if: >-                                                   a folded scalar, which YAML joins
#       ${{ github.event_name == 'push' &&                     into ONE line before GitHub sees it
#       github.ref == 'refs/heads/main' }}
# Neither shape exists in this family today, so it was latent — but a gate that reds valid YAML gets
# disabled, which is the failure this file's own header argues against.
i = 0
while True:
    o = text.find("${{", i)
    if o < 0:
        break
    c = text.find("}}", o + 3)
    line = text.count("\n", 0, o) + 1
    if c < 0:
        print(f"  {p}:{line}: `${{{{` is never closed — GitHub rejects the whole workflow")
        bad = 1
        break
    if not text[o + 3:c].strip():
        print(f"  {p}:{line}: EMPTY expression — valid YAML, invalid Actions. GitHub interpolates")
        print(f"        BEFORE the shell sees the file, so this is parsed even inside a # comment.")
        bad = 1
    i = c + 2

# ---- structure ---------------------------------------------------------------------------------
try:
    d = yaml.safe_load(text)
except Exception as e:
    print(f"  {p}: not valid YAML — {e}")
    sys.exit(1)
if not isinstance(d, dict):
    print(f"  {p}: top level is not a mapping")
    sys.exit(1)
# PyYAML parses the unquoted key `on:` as the BOOLEAN True (the Norway problem's cousin), so accept
# both spellings rather than reporting a trigger that is plainly there.
if "on" not in d and True not in d:
    print(f"  {p}: no `on:` trigger — the workflow can never run")
    bad = 1
jobs = d.get("jobs")
if not isinstance(jobs, dict) or not jobs:
    print(f"  {p}: no `jobs:` mapping")
    sys.exit(1)
for name, j in jobs.items():
    if not isinstance(j, dict):
        print(f"  {p}: job `{name}` is not a mapping")
        bad = 1
        continue
    if "uses" in j:          # a reusable-workflow call has neither runs-on nor steps
        continue
    for key in ("runs-on", "steps"):
        if key not in j:
            print(f"  {p}: job `{name}` has no `{key}`")
            bad = 1
sys.exit(bad)
CHECK_PY
}

if [ "${1:-}" = "--selftest" ]; then
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT; fails=0
  good='name: t
on: {push: {branches: [main]}}
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - run: echo "${{ github.sha }}"
'
  printf '%s' "$good" > "$tmp/good.yml"
  check_file "$tmp/good.yml" >/dev/null 2>&1 || { echo "  ✘ a VALID workflow was rejected"; fails=1; }
  # THE REAL DEFECT, IN A COMMENT — which is what made it slip past review. Written as an explicit
  # fixture, never by substituting into `$good`: the first cut built it with a bash `${var/a/b}` whose
  # escaping silently did not substitute, so the arm tested the GOOD file and reported the checker
  # broken. The selftest caught its own fixture, which is the only reason that was not a false alarm
  # about the checker.
  cat > "$tmp/empty.yml" <<'EMPTY_FIXTURE'
name: t
on: {push: {branches: [main]}}
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi   # this comment carries ${{ }} and GitHub parses it anyway
EMPTY_FIXTURE
  check_file "$tmp/empty.yml" >/dev/null 2>&1 && { echo "  ✘ an EMPTY \${{ }} in a comment was accepted — the 2026-09-13 defect"; fails=1; }
  printf 'name: t\non: {push: {}}\njobs: {}\n' > "$tmp/nojobs.yml"
  check_file "$tmp/nojobs.yml" >/dev/null 2>&1 && { echo "  ✘ an empty jobs: map was accepted"; fails=1; }
  printf 'name: t\non: {push: {}}\njobs:\n  a:\n    steps: [{run: "x"}]\n' > "$tmp/noruns.yml"
  check_file "$tmp/noruns.yml" >/dev/null 2>&1 && { echo "  ✘ a job with no runs-on was accepted"; fails=1; }
  printf 'name: t\non: {push: {}}\njobs:\n  a: {uses: ./.github/workflows/x.yml}\n' > "$tmp/reusable.yml"
  check_file "$tmp/reusable.yml" >/dev/null 2>&1 || { echo "  ✘ a reusable-workflow CALL was rejected (it has no runs-on by design)"; fails=1; }
  [ "$fails" = 0 ] && { echo "workflow-check selftest: OK — 5 cases, and the empty-expression arm is the one that cost four red mains"; exit 0; }
  echo "workflow-check selftest: FAILED"; exit 1
fi

repos=("$@")
if [ "${#repos[@]}" -eq 0 ]; then
  # shellcheck source=/dev/null
  . "$(dirname "${BASH_SOURCE[0]}")/_release_set.sh"
  read -r -a repos <<< "$RS_FAMILY"
fi
rc=0; n=0
for repo in "${repos[@]}"; do
  d="$ROOT/$repo"; [ -d "$d/.github/workflows" ] || continue
  for f in "$d"/.github/workflows/*.yml "$d"/.github/workflows/*.yaml; do
    [ -e "$f" ] || continue
    n=$((n + 1))
    check_file "$f" || rc=1
  done
done
# ZERO FILES IS NOT A PASS. `[ -d ... ] || continue` silently skips an unknown repo name, and zero
# findings over zero files aggregated to OK — the exact defect `gate-run.sh` already carries a guard
# for ("an unknown repo name produced an empty list, the loop ran zero times, zero failures aggregated
# to OK"). A new instrument repeating a defect its sibling already fixed is the R288 shape.
if [ "$n" = 0 ]; then
  echo "workflow-check: INCOMPLETE — examined ZERO workflow files. Named: ${repos[*]}. That is not a"
  echo "  pass; it means no repo in that list had a .github/workflows directory (a typo, or a repo that"
  echo "  is not checked out here)."
  exit 2
fi
[ "$rc" = 0 ] && echo "workflow-check: OK — $n workflow file(s), every expression non-empty and balanced, every job runnable"
[ "$rc" = 0 ] || echo "workflow-check: FAILED — see above. A workflow GitHub cannot parse runs NO jobs and reports against the file PATH."
exit "$rc"
