#!/usr/bin/env bash
# _shell_output_damage.sh — does a commit message carry shell output a shell spliced into prose?
#
#     git log -1 --format=%B <sha> | bash bin/_shell_output_damage.sh     # exit 0 = damaged, 1 = clean
#     bash bin/_shell_output_damage.sh --selftest
#
# Factored out of release-preflight.sh [7c] on 2026-09-29, because the predicate had NO calibration
# anywhere (the comment said "CALIBRATED below" and nothing below exercised it) and it had just produced
# a false positive that would have stopped a release at step 0 over PUSHED history (candor-swift
# `92496cb`, which quotes `  Executed 2 tests, with 7 failures` as §1b calibration evidence, indented 2).
#
# THE NARROWING, AND WHY IT IS SAFE IN THE DIRECTION THAT MATTERS. Only the XCTest alternative changed.
# Real XCTest output always ends `(N unexpected) in X (Y) seconds`; a shell splicing real output carries
# the whole tail. A human quoting a line trims it — and measured over 2,624 commits, what humans reliably
# drop is the TIMING: candor-swift 0c16614 keeps `(0 unexpected)` and drops `in … seconds`, so the first
# cut of this narrowing (requiring only the `(N unexpected)` part) still fired on it. The pattern now
# requires the timing, which is the part a splice always has and a quotation reliably loses. At the same
# time it is WIDENED to accept XCTest's real TAB-space indent (`\t Executed …`), which `^ *` never matched.
# Cargo's patterns are untouched: cargo indents `   Compiling` 3 and `    Finished` 4, so no indent-based
# exemption can be widened without blinding the check to cargo's own output.
set -uo pipefail

damaged() {  # stdin: a commit message. exit 0 if it carries shell output outside a quotation.
  sed -e 's/^    .*$//' -e 's/`[^`]*`//g' \
  | grep -qE "test result: (ok|FAILED)\. [0-9]+ passed|^ *Compiling [a-z-]+ v[0-9]|^ *Finished .(dev|release|test) profile|^[ 	]*Executed [0-9]+ tests?, with [0-9]+ failures? \([0-9]+ unexpected\) in [0-9.]+ \([0-9.]+\) seconds"
}

if [ "${1:-}" = "--selftest" ]; then
  bad=0
  chk() {  # <want: fire|clean> <label> <message>
    if printf '%s\n' "$3" | damaged; then got=fire; else got=clean; fi
    if [ "$got" = "$1" ]; then echo "  ok   $2 -> $got"; else echo "  FAIL $2 -> $got, want $1"; bad=$((bad+1)); fi
  }
  chk fire  "bare mid-sentence cargo result"      "Fixed it and test result: ok. 38 passed; 0 failed now."
  chk fire  "spliced cargo Compiling (3 spaces)"   "Body
   Compiling candor-scan v0.39.2 (/x)"
  chk fire  "spliced real XCTest line"             "Executed 794 tests, with 0 failures (0 unexpected) in 1.2 (1.3) seconds"
  chk fire  "spliced XCTest, real tab indent"      "$(printf '\t Executed 3 tests, with 1 failure (0 unexpected) in 0.1 (0.1) seconds')"
  chk clean "92496cb: quoted, 2-indent, trimmed"   "  XCTAssertNil failed
  Executed 2 tests, with 7 failures"
  chk clean "0c16614: quoted, keeps (N unexpected)"  "  Executed 1 test, with 4 failures (0 unexpected)"
  chk clean "quoted 4-indent code block"           "Red line:
    test result: FAILED. 0 passed; 3 failed"
  chk clean "backticked mid-sentence citation"     "it printed \`test result: ok. 38 passed\` before"
  chk clean "plain prose"                          "Nothing here resembles output."
  echo "_shell_output_damage selftest: $([ $bad -eq 0 ] && echo OK || echo "FAILED ($bad)")"
  exit $bad
fi
damaged
