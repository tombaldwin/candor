#!/usr/bin/env bash
# Shell-level contract for the corpus A/B (bin/corpus-ab.py) and for the R242 query mode it depends on
# (bin/corpus.sh --hollow-check).  Run:  bash bin/corpus-ab.test.sh
#
# WHY THIS EXISTS BESIDE `corpus-ab.py --selftest` RATHER THAN INSTEAD OF IT. The Python selftest calls
# `run()` in-process, so it proves the LOGIC. It cannot prove the two things a caller actually depends
# on, both of which live outside the process:
#
#   · THE EXIT CODES.  Every caller of this tool is a shell or a CI step reading `$?`, and the whole
#     R289 shape — a failure that reads as a clean result — is an exit-code property.  A tool whose
#     in-process return value is 3 and whose process exits 0 is the defect, not the fix.
#   · THE AUTHORITY IT ASKS.  `corpus-ab.py` does not carry its own hollow check; it shells out to
#     `bin/corpus.sh --hollow-check` (§G).  That contract is a second process's stdout and exit code,
#     and nothing else in the family tests it.  A cargo registry crate reads NOTGIT there, not HOLLOW,
#     and if that ever flips, an intact corpus starts being called hollow.
#
# Hermetic: no engine, no corpus, no network.  The arms are `cat` over fixture JSON.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AB="$HERE/corpus-ab.py"
CORPUS="$HERE/corpus.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

fails=0
ok()   { echo "  ok   $1"; }
bad()  { echo "  FAIL $1"; shift; [ $# -gt 0 ] && printf '       %s\n' "$@"; fails=$((fails + 1)); }

# $1 label ; $2 expected exit ; rest: command.  Runs the command, captures BOTH streams and the real
# exit status — never `$?` after a pipe, which reads the pipe's last stage and has faked a pass here
# before.
rc_is() {
  local label="$1" want="$2"; shift 2
  local out got
  out="$("$@" 2>&1)"; got=$?
  LAST_OUT="$out"
  if [ "$got" = "$want" ]; then ok "$label (exit $got)"
  else bad "$label" "want exit $want, got $got" "$(printf '%s' "$out" | tail -3)"; fi
}
says() { # $1 label ; $2 substring that must be in the LAST captured output
  case "$LAST_OUT" in *"$2"*) ok "$1" ;; *) bad "$1" "missing: $2" ;; esac
}
says_not() {
  case "$LAST_OUT" in *"$2"*) bad "$1" "must NOT contain: $2" ;; *) ok "$1" ;; esac
}

# ── fixtures ──────────────────────────────────────────────────────────────────────────────────────
# `judged` is `analyzed.count`.  It is the field the R242 guard keys on, and keying on the emptiness of
# `functions` instead is SPEC ⟨0.24⟩'s measured-wrong fix — so the fixtures below carry BOTH an entry
# that judged nothing and one that judged units and found nothing, and the gate asserts they are
# treated differently.  Without the second one this file would pass while the guard was wrong.
mkentry() { # $1 name ; $2 judged ; $3 pre-fns-json ; $4 post-fns-json
  mkdir -p "$T/corpus/$1"
  printf '{"candor":{"spec":"0.35"},"package":"p","analyzed":{"count":%s},"functions":%s}' "$2" "$3" > "$T/corpus/$1/pre.json"
  printf '{"candor":{"spec":"0.35"},"package":"p","analyzed":{"count":%s},"functions":%s}' "$2" "$4" > "$T/corpus/$1/post.json"
}
# Five rows sharing one `fn` — the async-std/tiff shape — all moving together.
DUP_PRE='[{"fn":"E::x","hash":"p#E::x","inferred":["Unknown"],"unknownWhy":["ambiguous:m"]},{"fn":"E::x","hash":"p#E::x","inferred":["Unknown"],"unknownWhy":["ambiguous:m"]},{"fn":"E::x","hash":"p#E::x","inferred":["Unknown"],"unknownWhy":["ambiguous:m"]},{"fn":"E::x","hash":"p#E::x","inferred":["Unknown"],"unknownWhy":["ambiguous:m"]},{"fn":"E::x","hash":"p#E::x","inferred":["Unknown"],"unknownWhy":["ambiguous:m"]}]'
DUP_POST='[{"fn":"E::x","hash":"p#E::x","inferred":["Unknown"],"unknownWhy":["macro:m"]},{"fn":"E::x","hash":"p#E::x","inferred":["Unknown"],"unknownWhy":["macro:m"]},{"fn":"E::x","hash":"p#E::x","inferred":["Unknown"],"unknownWhy":["macro:m"]},{"fn":"E::x","hash":"p#E::x","inferred":["Unknown"],"unknownWhy":["macro:m"]},{"fn":"E::x","hash":"p#E::x","inferred":["Unknown"],"unknownWhy":["macro:m"]}]'
ONE='[{"fn":"a","hash":"p#a","inferred":[]}]'

mkentry dup      5 "$DUP_PRE" "$DUP_POST"
mkentry same     1 "$ONE"     "$ONE"
mkentry unjudged 0 '[]'       '[]'          # judged NOTHING — R242's shape
mkentry allpure  9 '[]'       '[]'          # judged 9 units, reported none — SPEC ⟨0.24⟩'s control

ab() { python3 "$AB" --pre-cmd "bash -c 'cat {entry}/pre.json'" --post-cmd "bash -c 'cat {entry}/post.json'" "$@"; }

echo "the in-process calibration (the four proofs):"
rc_is "corpus-ab.py --selftest passes" 0 python3 "$AB" --selftest
says  "…and it is a calibration, not a smoke test"      "R288"

echo
echo "exit codes, from a shell — the property every caller actually reads:"
rc_is "a real comparison exits 0" 0 ab --entry "$T/corpus/dup" --allow-zero-reach
# ASSERT THE HEADLINE, NOT THE TABLE ROW.  The calibration table computes every key independently, so
# a `CHANGED 5` anywhere in the output is satisfied by the table even when the headline has been
# reverted to the merged key — measured by mutating corpus-ab.py to do exactly that, at which point
# this gate still said OK.  The headline is the number a reader quotes, so it is the number under test.
headline() { printf '%s' "$LAST_OUT" | grep -F 'HEADLINE'; }
if headline | grep -q 'CHANGED 5 '; then ok "…the HEADLINE reports the multiset count (5), not the merged one (1)"
else bad "…the HEADLINE reports the multiset count (5), not the merged one (1)" "$(headline)"; fi
says  "…beside the old key's count, so the delta is visible" "LAST-WINS"
if printf '%s' "$LAST_OUT" | grep -F 'LAST-WINS' | grep -q 'CHANGED 1 '; then ok "…and the old key really does report 1 here, so the two differ"
else bad "…and the old key really does report 1 here, so the two differ" "$(printf '%s' "$LAST_OUT" | grep -F 'LAST-WINS')"; fi

rc_is "an entry that judged NOTHING exits 3" 3 ab --entry "$T/corpus/dup" --entry "$T/corpus/unjudged"
says     "…names the entry"                    "corpus/unjudged"
says     "…cites the row"                      "R242"
says_not "…and prints NO diff summary"         "HEADLINE"

rc_is "…and --allow-unjudged compares the rest" 0 ab --entry "$T/corpus/dup" --entry "$T/corpus/unjudged" --allow-unjudged --allow-zero-reach
says  "…while still naming what it dropped"     "judged NOTHING"

# THE CONTROL FOR THE LINE ABOVE.  A guard keyed on the EMPTINESS of `functions` passes every assertion
# so far and is still wrong: SPEC ⟨0.24⟩ measured that it withdraws 104 legitimate all-pure claims to
# catch 6 real ones, and the first draft of corpus-ab.py refused 238 of 1,509 real crates on that rule.
rc_is "an ALL-PURE entry (count 9, no rows) is COMPARED, not refused" 0 ab --entry "$T/corpus/dup" --entry "$T/corpus/allpure" --allow-zero-reach
says     "…and counted as the legitimate kind"  "all-pure kind"
says_not "…not as an entry that judged nothing" "judged NOTHING"

rc_is "an empty diff with no reach measured exits 4" 4 ab --entry "$T/corpus/same"
says  "…and says why"                               "EMPTY DIFF WITH NO REACH"
rc_is "…and exits 0 once acknowledged" 0 ab --entry "$T/corpus/same" --allow-zero-reach

rc_is "an arm that cannot run exits 3" 3 python3 "$AB" --pre-cmd "bash -c 'exit 2'" --post-cmd "bash -c 'cat {entry}/post.json'" --entry "$T/corpus/dup"
says_not "…and prints no diff"          "HEADLINE"
rc_is "an empty entry set exits 3" 3 ab --entries-dir "$T/corpus/same"
rc_is "a usage error exits 2"      2 python3 "$AB" --entry "$T/corpus/dup"

echo
echo "the authority it asks — bin/corpus.sh --hollow-check (§G: one implementation, two callers):"
mkdir -p "$T/hc/empty" "$T/hc/gutted/.git/hooks" "$T/hc/gutted/.git/info" "$T/hc/notgit"
for f in a b c; do echo x > "$T/hc/notgit/$f"; done
: > "$T/hc/file.jar"
git init -q "$T/hc/real" 2>/dev/null
for f in a b c; do echo x > "$T/hc/real/$f"; done
git -C "$T/hc/real" add -A >/dev/null 2>&1
git -C "$T/hc/real" -c user.email=t@e -c user.name=t commit -qm i >/dev/null 2>&1

rc_is "a real checkout is ok"                       0 bash "$CORPUS" --hollow-check "$T/hc/real"
says  "…and says so"                                  "ok "
rc_is "the MEASURED gutting shape is HOLLOW"        2 bash "$CORPUS" --hollow-check "$T/hc/gutted"
says  "…and explains which shape"                     "HEAD does not resolve"
rc_is "a directory with no files at all is EMPTY"   2 bash "$CORPUS" --hollow-check "$T/hc/empty"
rc_is "a missing path is MISSING"                   2 bash "$CORPUS" --hollow-check "$T/hc/nope"
# THE FALSE-POSITIVE CONTROL, and the reason this check is tri-state.  A cargo registry crate has no
# `.git`, so the underlying `hollow_checkout` says "hollow" for a perfectly intact tree.  Answering
# HOLLOW there would be a false positive in the instrument whose job is to stop false negatives.
rc_is "a non-git tree WITH content declines, exit 0" 0 bash "$CORPUS" --hollow-check "$T/hc/notgit"
says  "…rather than calling an intact tree hollow"    "NOTGIT"
rc_is "a jar declines too — a file is not a tree"    0 bash "$CORPUS" --hollow-check "$T/hc/file.jar"
says  "…and does not claim it is MISSING"             "NOTDIR"
rc_is "no argument is a usage error"                1 bash "$CORPUS" --hollow-check

# A READ-ONLY QUESTION MUST NOT WRITE.  `corpus.sh` creates $CORPUS_HOME on every other path; running a
# writing line to answer a read-only question is the habit that destroyed a day of evidence once.
CH="$T/corpushome"
CORPUS_HOME="$CH" bash "$CORPUS" --hollow-check "$T/hc/real" >/dev/null 2>&1
if [ -d "$CH" ]; then bad "--hollow-check does not create \$CORPUS_HOME" "it created $CH"
else ok "--hollow-check does not create \$CORPUS_HOME"; fi

echo
if [ "$fails" -eq 0 ]; then echo "corpus-ab: OK"; exit 0; fi
echo "corpus-ab: $fails FAILED"; exit 1
