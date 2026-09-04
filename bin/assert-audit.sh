#!/usr/bin/env bash
# assert-audit.sh — find SAFETY ASSERTIONS a diff adds, and fail when none of them is backed by a test.
#
#   bash bin/assert-audit.sh <repo> [<git-range>]      # default range: origin/main..HEAD, else HEAD~1..HEAD
#   bash bin/assert-audit.sh --selftest
#
# WHY THIS EXISTS. Measured 2026-09-01, across the whole family in one round. Four engines shipped
# ⟨0.35⟩ CHA-completeness fixes; every one carried a comment ASSERTING a property, and every one of
# those assertions was false:
#
#   ts     "PROVEN — not guessed"      guessed. TS certifies type-compatibility, never that T -> T IS
#                                      the identity. Cardinal sin, introduced by the fix.
#   java   "inert, not wrong"          wrong. Static-field lambdas -> `deny Unknown` exit 0.
#   rust   "already works"             works for a free fn; a method-call callee was never tried.
#   swift  a stated known limit        narrower than the real hole.
#
# A documented LIMITATION at least names a gap. A documented GUARANTEE closes the question in the
# reader's mind AND supplies the justification for narrowing a sound over-approximation — so it converts
# into a silent under-report directly. Three of those four did exactly that.
#
# And in every case the assertion was written by the same commit that needed it to be true. Nobody
# verifies the sentence that makes their own diff correct — which is why this is a tool and not a habit.
#
# WHAT IT DOES, AND THE ONE THING IT REFUSES TO DO. It does NOT judge whether an assertion is correct;
# no grep can. It asks the cheaper question that would have caught the real case: you asserted safety —
# did you add a test in the same change? candor-ts's `7ecda11` asserted "PROVEN" and shipped ZERO tests
# (only CHANGELOG.md and scan.mjs changed). That is mechanically visible, and it is the shape to catch.
#
# So: assertions with test changes beside them PRINT (a review checklist — read them, they are the
# highest-value lines in the diff). Assertions with NO test changes anywhere in the range FAIL.
#
# DELIBERATELY NOT A CONTENT JUDGEMENT AND DELIBERATELY NOT SILENT. A tool that tried to decide which
# assertions are load-bearing would be another unverified assertion. This one states what it found and
# what it cannot know.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

# The vocabulary. Every entry earned its place from a real false assertion in this family's history —
# the four above, plus the older "cannot happen"/"already handled" forms that preceded them. Matched
# case-insensitively, on ADDED lines only (a `+` line in the diff), because an assertion that was
# already there is not this commit's claim to defend.
#
# NOT INCLUDED, on purpose: "correct", "sound", "valid", "ensures". They occur constantly in ordinary
# prose about what code does, and a vocabulary that fires on every third comment is a red nobody reads —
# this project has retired two such checks already. Narrow on measured spellings; widen only when a
# missed instance is measured, never on a hunch.
ASSERT_RE='proven|guaranteed|cannot happen|can not happen|can never|never happens|impossible|inert|already (works|handled|covered|checked)|by construction|safe because|no need to check|trivially (true|safe|pure)'

# What counts as a test. Per-repo conventions across the family: java/gradle `src/test`, rust `tests/`
# and `#[test]` in-file, ts `test.mjs`/`*.test.*`, swift `Tests/`, plus every repo's `ci/`, `smoke.sh`,
# `soundness/`, `conformance/` and `fuzz` harnesses. A CHANGELOG entry is NOT a test and must not count
# as one — that is precisely what `7ecda11` had instead of coverage.
#
# `eval/` AND `verify*.sh` ADDED 2026-09-02, from a measured false FAIL. An agent's diff was five files,
# all of it harness code, four of them wired into `candor-rust/.github/workflows/ci.yml` as gates — and
# this tool demanded a test anyway, because **0 of the 9 tracked `eval/**/*.sh` matched.** So a change
# that touched nothing BUT CI gates could never be credited, and the tool's own verdict was the thing that
# was wrong. That is this session's recurring class pointed at the auditor: a check whose negative is
# indistinguishable from the case it exists to catch.
#
# THE `eval/` FIX WAS ITSELF TOO WIDE — R158, 2026-09-02. The alternative above was `(^|/)(ci|soundness|
# conformance|eval)/` — a bare directory, matched anywhere in the path, with no extension check. That
# credits `eval/RESULTS.md`, `ci/README.md`, a `.gitignore` under `conformance/`, ANY file dropped into
# one of those trees. Measured battery (14 files, HEAD~1..HEAD, one real assertion + one companion file
# each): 12 of 14 non-test companions were wrongly credited (rc 0) — `eval/RESULTS.md`, `eval/notes.txt`,
# `ci/README.md`, `ci/CHANGELOG.md`, `conformance/SPEC-notes.md`, `conformance/.gitignore`,
# `soundness/TODO.md`, and — same shape, pre-dating this widening — `spec/overview.md`, `test/README.md`,
# `docs/tests/plan.md` via the bare `(test|tests|Tests|spec|specs)(/|$)` alternative below, which has the
# identical defect: a directory match with no extension check. Only the two files with no directory match
# at all (`.gitignore`, `CHANGELOG.md` at repo root) correctly failed.
#
# The fix is a denylist by construction, never a broader allowlist: every directory alternative below now
# requires the path to END in one of the script/source extensions this file already enumerates elsewhere
# (mjs/js/ts/py/sh/java/swift/rs, plus kt for candor-java's `soundness/KotlinProbe.kt`) — measured against
# every repo's actually-tracked test/gate files (`git ls-files` under test/tests/Tests/spec/specs/ci/
# soundness/conformance/eval across all six repos, 2026-09-02): every real test or gate script in the
# family already carries one of these extensions, and no repo has an extensionless one. Fixture data
# beside a real test file (`.candor/policy`, `.json`, `.toml`, `.tsv`) does not need to match on its own —
# only ONE recognisable test/gate file need be present in the range for the audit to pass.
TEST_RE='(^|/)(test|tests|Tests|spec|specs|ci|soundness|conformance|eval)/.*\.(mjs|js|ts|py|sh|java|swift|rs|kt)$|test[^/]*\.(mjs|js|ts|py|sh|java|swift|rs)$|[^/]*[Tt]est[s]?\.(java|swift|rs|mjs|ts|py)$|smoke\.sh$|fuzz[^/]*\.(py|sh|rs)$|verify[^/]*\.sh$|\.test\.[a-z]+$'

selftest() {
  fails=0
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  git -C "$tmp" init -q . 2>/dev/null || { echo "  ✘ selftest could not init a scratch repo"; return 1; }
  git -C "$tmp" config user.email t@e; git -C "$tmp" config user.name t
  # BOTH DIRECTIONS. The defect this whole round kept finding was a one-directional check — an arm that
  # only ever answered "yes" and was never asked to say no. So: an assertion with no test must FAIL, an
  # assertion WITH a test must pass, and an ordinary diff with no assertion at all must pass silently.
  printf 'x\n' > "$tmp/base.txt"; git -C "$tmp" add -A; git -C "$tmp" commit -qm base

  # (1) assertion, no test -> FAIL
  printf '// this is PROVEN safe\nint f(){return 0;}\n' > "$tmp/a.c"
  git -C "$tmp" add -A; git -C "$tmp" commit -qm one
  out="$(scan_range "$tmp" "HEAD~1..HEAD" 2>&1)"; rc=$?
  if [ "$rc" -ne 1 ]; then echo "  ✘ an assertion with NO test in the range did not FAIL (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/      | /'; fails=$((fails+1))
  else echo "  ✔ an assertion with no test change in the same range FAILS"; fi

  # (2) same assertion, test added alongside -> pass
  # NOTE: the test fixture below is `tests/a_test.rs`, not `.c` — R158's fix requires the directory
  # alternative to end in a real script/source extension, and `.c` is not one this family uses anywhere.
  printf '// also PROVEN safe\n' >> "$tmp/a.c"
  mkdir -p "$tmp/tests"; printf 'assert(1);\n' > "$tmp/tests/a_test.rs"
  git -C "$tmp" add -A; git -C "$tmp" commit -qm two
  out="$(scan_range "$tmp" "HEAD~1..HEAD" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then echo "  ✘ an assertion WITH a test beside it was failed anyway (rc=$rc) — the tool would be a red nobody reads"; printf '%s\n' "$out" | sed 's/^/      | /'; fails=$((fails+1))
  else echo "  ✔ …and the same assertion PASSES when a test lands in the same range — the check is not one-directional"; fi

  # (3) no assertion at all -> pass, and say nothing alarming
  printf 'int g(){return 1;}\n' > "$tmp/b.c"
  git -C "$tmp" add -A; git -C "$tmp" commit -qm three
  out="$(scan_range "$tmp" "HEAD~1..HEAD" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then echo "  ✘ an ordinary diff with no assertion was failed (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/      | /'; fails=$((fails+1))
  else echo "  ✔ an ordinary diff with no safety assertion passes quietly"; fi

  # (4) a CHANGELOG is NOT a test — the exact `7ecda11` shape.
  # PROVE THE FIXTURE REACHED THE CODE before trusting its verdict. The first cut of this case wrote the
  # changelog with `printf '- fixed a thing\n'`; printf parsed the leading `-` as a flag, the file was
  # never created, and the case PASSED — over a fixture that did not exist. A broken instrument's
  # negative is indistinguishable from a real one, which is the whole subject of this script.
  printf '// PROVEN correct\n' > "$tmp/c.c"; printf '%s\n' '- fixed a thing' > "$tmp/CHANGELOG.md"
  git -C "$tmp" add -A; git -C "$tmp" commit -qm four
  if ! git -C "$tmp" diff --name-only HEAD~1..HEAD | grep -qx 'CHANGELOG.md'; then
    echo "  ✘ selftest case 4 is BROKEN — CHANGELOG.md is not in the range, so this case proves nothing"
    fails=$((fails+1))
  else
    out="$(scan_range "$tmp" "HEAD~1..HEAD" 2>&1)"; rc=$?
    if [ "$rc" -ne 1 ]; then echo "  ✘ a CHANGELOG entry was accepted as coverage for an assertion (rc=$rc) — that is the 7ecda11 shape exactly"; printf '%s\n' "$out" | sed 's/^/      | /'; fails=$((fails+1))
    else echo "  ✔ a CHANGELOG entry does NOT count as a test, and the fixture is PROVEN present in the range — the 7ecda11 shape still fails"; fi
  fi

  # (5) R158: a doc/results file dropped INSIDE eval/, ci/, conformance/ or soundness/ is NOT a test
  # either — the exact defect this row is about. Before this file's fix, the bare directory alternative
  # `(^|/)(ci|soundness|conformance|eval)/` credited any file under those trees regardless of extension;
  # `eval/RESULTS.md` is a real tracked file in candor-rust, so this is not a hypothetical shape.
  mkdir -p "$tmp/eval"; printf '// this is PROVEN correct too\nint h(){return 2;}\n' > "$tmp/d.c"
  printf 'ran the corpus, all clean\n' > "$tmp/eval/RESULTS.md"
  git -C "$tmp" add -A; git -C "$tmp" commit -qm five
  if ! git -C "$tmp" diff --name-only HEAD~1..HEAD | grep -qx 'eval/RESULTS.md'; then
    echo "  ✘ selftest case 5 is BROKEN — eval/RESULTS.md is not in the range, so this case proves nothing"
    fails=$((fails+1))
  else
    out="$(scan_range "$tmp" "HEAD~1..HEAD" 2>&1)"; rc=$?
    if [ "$rc" -ne 1 ]; then echo "  ✘ eval/RESULTS.md (a doc, not a test) was accepted as coverage for an assertion (rc=$rc) — R158's exact shape"; printf '%s\n' "$out" | sed 's/^/      | /'; fails=$((fails+1))
    else echo "  ✔ a doc/results file under eval/ does NOT count as a test — R158's shape now fails"; fi
  fi

  # (6) the OTHER direction of R158's fix: a REAL script under one of those same directories still
  # counts. Narrowing TEST_RE to "must end in a script/source extension" must not turn eval/, ci/,
  # soundness/, conformance/ into dead weight for the repos where a shell gate genuinely IS the test.
  printf '// PROVEN correct, and tested\nint i(){return 3;}\n' > "$tmp/e.c"
  printf '#!/usr/bin/env bash\nset -e\necho ok\n' > "$tmp/eval/run.sh"
  git -C "$tmp" add -A; git -C "$tmp" commit -qm six
  out="$(scan_range "$tmp" "HEAD~1..HEAD" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then echo "  ✘ eval/run.sh (a real gate script) was NOT credited as a test (rc=$rc) — the narrowing went too far"; printf '%s\n' "$out" | sed 's/^/      | /'; fails=$((fails+1))
  else echo "  ✔ …and a real script under eval/ still counts — the narrowing didn't overshoot into the safe-but-noisy direction"; fi

  if [ "$fails" -eq 0 ]; then echo; echo "assert-audit selftest: OK — 6 cases, both directions, a CHANGELOG is not coverage, and neither is a doc file under eval/ci/soundness/conformance"; return 0
  else echo; echo "assert-audit selftest: FAILED — $fails case(s)"; return 1; fi
}

scan_range() {  # $1 = repo dir, $2 = git range -> prints findings; rc 1 if any assertion lacks test cover
  local d="$1" range="$2" diff hits testfiles n
  diff="$(git -C "$d" diff -U0 "$range" 2>/dev/null)" || { echo "assert-audit: cannot diff $range in $d"; return 2; }
  [ -z "$diff" ] && { echo "assert-audit: empty range $range — nothing to audit (that is not a pass, there is no diff)"; return 0; }

  # ADDED lines only, and never the diff's own +++ header.
  hits="$(printf '%s\n' "$diff" | grep -E '^\+' | grep -vE '^\+\+\+' | grep -iE "$ASSERT_RE" || true)"
  testfiles="$(git -C "$d" diff --name-only "$range" 2>/dev/null | grep -E "$TEST_RE" || true)"

  if [ -z "$hits" ]; then
    echo "assert-audit: no safety assertions added in $range — nothing to defend"
    return 0
  fi

  n="$(printf '%s\n' "$hits" | grep -c .)"
  echo "assert-audit: $n added line(s) ASSERT a safety property. These are the highest-value lines in the"
  echo "  diff to review, because the logic gets read and the assertion gets believed:"
  printf '%s\n' "$hits" | sed 's/^+/    /' | cut -c1-160
  echo
  if [ -n "$testfiles" ]; then
    echo "  Test files also changed in this range:"
    printf '%s\n' "$testfiles" | sed 's/^/    /'
    echo
    echo "assert-audit: OK — assertions are present AND this range changes tests. THIS TOOL CANNOT TELL"
    echo "  you whether those tests actually exercise those assertions; that judgement is still yours."
    return 0
  fi
  echo "assert-audit: FAILED — safety assertions added and NO test file changed anywhere in this range."
  echo "  Measured: candor-ts \`7ecda11\` asserted \"PROVEN — not guessed\" and shipped zero tests (only"
  echo "  CHANGELOG.md and scan.mjs changed). It was guessed, and it was a cardinal sin. Either add the"
  echo "  fixture that would fail if the assertion were false, or word the claim as the assumption it is."
  return 1
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  "" ) echo "usage: assert-audit.sh <repo> [<git-range>]   |   assert-audit.sh --selftest" >&2; exit 2 ;;
esac

repo="$1"
# `git rev-parse --git-dir`, NEVER `-d "$d/.git"`. A git WORKTREE's `.git` is a FILE, not a directory,
# so the `-d` test reports "not a checkout" for exactly the case `verify-umbrella.sh` creates — a
# throwaway worktree at the last commit. This project has already fixed that same bug in
# `changelog-lag.sh`, and release-test.sh section 2 greps every script for its return, which is how this
# one was caught the first time it ran. Reusing the existing answer rather than the plausible one.
is_repo() { git -C "$1" rev-parse --git-dir >/dev/null 2>&1; }
d="$ROOT/$repo"; is_repo "$d" || d="$repo"
is_repo "$d" || { echo "assert-audit: $repo is not a git repository (looked in $ROOT/$repo and $repo)" >&2; exit 2; }

range="${2:-}"
if [ -z "$range" ]; then
  if git -C "$d" rev-parse --verify -q origin/main >/dev/null; then range="origin/main..HEAD"; else range="HEAD~1..HEAD"; fi
fi
echo "assert-audit: $repo @ $range"
scan_range "$d" "$range"
exit $?
