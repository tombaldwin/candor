#!/usr/bin/env bash
# ts-fitness-pin.sh — PIN the one predicate `corpus-census.sh ts` copies from candor-ts.
#
# SOUNDNESS R744.  The ts census arm decides whether a pinned repository holds ANALYSABLE source, and
# "analysable" is not this tool's opinion — it is candor-ts's, at `scan.mjs`:
#
#     (/\.[mc]?tsx?$/.test(name) && !name.endsWith(".d.ts"))
#     || (allowJs && /\.[mc]?jsx?$/.test(name) && !/\.min\.js$/.test(name));
#
# §G says ask the authority rather than reimplement it, and a shell `find` cannot import an inline
# arrow from an `.mjs`.  So the census arm carries a COPY — and this file is what makes the copy
# honest: it FAILS when candor-ts's predicate changes, so whoever changes it is told that a corpus
# roster depends on it.  That is the family's own rule for a deliberate duplicate: PIN the difference,
# do not collapse it and do not trust it.
#
# WHY THIS FILE EXISTS AT ALL, and it is not a nicety.  The comment in `corpus-census.sh` referred to
# this script before it was written.  A comment asserting that a check exists, when it does not, is
# SOUNDNESS R736 — the class closed hours earlier, where `doc-gates.sh`'s header claimed "no engine is
# built or invoked" while one of its gates invoked all four.  Writing the sentence is what stops the
# thing being measured, so the sentence had to become a script.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Overridable ONLY so `--selftest` can drive every failure path over throwaway copies. A pin whose
# four branches have never been executed is the shape it exists to catch.
TS="${CANDOR_TS_SCAN:-$HERE/../candor-ts/scan.mjs}"
CENSUS="${CANDOR_CENSUS_SH:-$HERE/bin/corpus-census.sh}"

if [ "${1:-}" = "--selftest" ]; then
  t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT; bad=0
  drive() {  # name, ts-body, census-body, want-exit
    printf '%s\n' "$2" > "$t/scan.mjs"; printf '%s\n' "$3" > "$t/census.sh"
    CANDOR_TS_SCAN="$t/scan.mjs" CANDOR_CENSUS_SH="$t/census.sh" \
      bash "$HERE/bin/ts-fitness-pin.sh" >/dev/null 2>&1
    rc=$?
    if [ "$rc" -ne "$4" ]; then
      echo "  FAIL $1 — exit $rc, want $4"; bad=$((bad + 1))
    else
      echo "  ok   $1 (exit $rc)"
    fi
  }
  GOOD_TS='x = (/\.[mc]?tsx?$/.test(name) && !name.endsWith(".d.ts")) || y;'
  GOOD_CE="find . -name '*.ts' -o -name '*.tsx' -o -name '*.mts' -o -name '*.cts' -not -name '*.d.ts'"
  drive "both sides intact"                    "$GOOD_TS" "$GOOD_CE" 0
  drive "candor-ts predicate CHANGED"          'x = (/\.tsx?$/.test(name) && !name.endsWith(".d.ts")) || y;' "$GOOD_CE" 1
  drive "census extension list CHANGED"        "$GOOD_TS" "find . -name '*.ts' -not -name '*.d.ts'" 1
  drive "candor-ts stopped excluding .d.ts"    'x = (/\.[mc]?tsx?$/.test(name)) || y;' "$GOOD_CE" 1
  drive "census stopped excluding .d.ts"       "$GOOD_TS" "find . -name '*.ts' -o -name '*.tsx' -o -name '*.mts' -o -name '*.cts'" 1
  # …and the intact pair again AFTER five injections, so a mutation that leaked between cases would
  # show up here rather than making a later injection pass for the wrong reason.
  drive "intact pair still passes after injections" "$GOOD_TS" "$GOOD_CE" 0
  rm -f "$t/scan.mjs"
  CANDOR_TS_SCAN="$t/gone.mjs" CANDOR_CENSUS_SH="$t/census.sh" bash "$HERE/bin/ts-fitness-pin.sh" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -ne 3 ]; then
    echo "  FAIL an ABSENT candor-ts must self-skip with exit 3, not pass — got $rc"; bad=$((bad + 1))
  else
    echo "  ok   an absent candor-ts self-skips (exit 3) rather than reading as agreement"
  fi
  echo "ts-fitness-pin selftest: $([ "$bad" -eq 0 ] && echo OK || echo "FAILED ($bad)")"
  exit "$([ "$bad" -eq 0 ] && echo 0 || echo 1)"
fi

if [ ! -f "$TS" ]; then
  echo "ts-fitness-pin: SKIPPED — it did not run.  candor-ts is not checked out beside this repo"
  echo "  ($TS).  This pin compares two files and cannot compare one; an absent sibling must not read"
  echo "  as agreement." >&2
  exit 3
fi

# The authority, read from candor-ts rather than restated here.
want_ts='(/\.[mc]?tsx?$/.test(name) && !name.endsWith(".d.ts"))'
# The copy, as the census arm spells it for `find`.
want_census="-name '*.ts' -o -name '*.tsx' -o -name '*.mts' -o -name '*.cts'"
fail=0

if ! grep -qF -- "$want_ts" "$TS"; then
  echo "ts-fitness-pin: FAIL — candor-ts's source predicate has CHANGED."
  echo "  Expected this text in candor-ts/scan.mjs and did not find it:"
  echo "    $want_ts"
  echo "  The ts census arm in bin/corpus-census.sh copies it to decide whether a pinned repository"
  echo "  holds analysable source.  Re-derive the copy, then update the expectation here.  If the"
  echo "  extension set grew, bin/corpus-census-ts.tsv's fourth column is now wrong for every entry."
  fail=1
fi
if ! grep -qF -- "$want_census" "$CENSUS"; then
  echo "ts-fitness-pin: FAIL — the CENSUS side of the copy has changed or moved."
  echo "  Expected this text in bin/corpus-census.sh and did not find it:"
  echo "    $want_census"
  fail=1
fi
# …and that the exclusion is on BOTH sides.  The extension list agreeing while one side forgets to
# exclude declarations is the failure that matters: a `.d.ts`-only repository would then read FIT, and
# a fit-looking repository with no bodies contributes zero rows — R666 in TypeScript, and the hollow
# corpus that printed 0/0/0.
if ! grep -qF -- '!name.endsWith(".d.ts")' "$TS"; then
  echo "ts-fitness-pin: FAIL — candor-ts no longer excludes .d.ts from its parse set."; fail=1
fi
if ! grep -qF -- "-not -name '*.d.ts'" "$CENSUS"; then
  echo "ts-fitness-pin: FAIL — the census fitness check no longer excludes .d.ts.  A declaration-only"
  echo "  repository would read FIT and contribute zero rows, which is indistinguishable from a change"
  echo "  that is correctly inert."
  fail=1
fi

[ "$fail" -eq 0 ] && echo "ts-fitness-pin: OK — the ts fitness copy still matches candor-ts's own predicate, exclusion included."
exit "$fail"
