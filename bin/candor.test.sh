#!/usr/bin/env bash
# Hermetic routing test for the `candor` dispatcher. Uses CANDOR_DISPATCH_DRYRUN + fake engine stubs on PATH,
# so it asserts WHICH engine each invocation resolves to without any engine actually installed. No network,
# no builds.  Run:  bash bin/candor.test.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
D="$HERE/candor"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export CANDOR_DISPATCH_DRYRUN=1
mkdir -p "$T/fakebin"; for e in candor-query candor-scan candor-ts candor-ts-query candor-swift candor-java; do printf '#!/bin/sh\n' > "$T/fakebin/$e"; chmod +x "$T/fakebin/$e"; done
export PATH="$T/fakebin:$PATH"

fails=0
ok() { # $1 label ; $2 expected-substring ; $3… command
  local label="$1" want="$2"; shift 2
  local got; got="$("$@" 2>&1)"
  if [[ "$got" == *"$want"* ]]; then echo "  ok   $label"; else echo "  FAIL $label"; echo "       want: *$want*"; echo "       got:  $got"; fails=$((fails+1)); fi
}
emptyarm() { # $1 label ; $2 dir — context_arm must return NOTHING there
  local label="$1" dir="$2" got
  got="$(cd "$dir" && CANDOR_SELFTEST=arm bash "$D" 2>&1)"
  if [[ -z "$got" ]]; then echo "  ok   $label"; else echo "  FAIL $label"; echo "       context_arm answered: '$got'"; fails=$((fails+1)); fi
}
no() { # $1 label ; $2 substring that must be ABSENT ; $3… command
  local label="$1" nope="$2"; shift 2
  local got; got="$("$@" 2>&1)"
  if [[ "$got" != *"$nope"* ]]; then echo "  ok   $label"; else echo "  FAIL $label"; echo "       must NOT contain: *$nope*"; echo "       got:  $got"; fails=$((fails+1)); fi
}
qdir() { mkdir -p "$T/$1/.candor"; : > "$T/$1/.candor/report.pkg.$2.json"; }
sdir() { mkdir -p "$T/$1"; : > "$T/$1/$2"; }

echo "query routing (by report backend):"
qdir qr scan;  ok "rust report → candor-query"       "WOULD-RUN: candor-query where Net"    bash -c "cd '$T/qr'  && '$D' where Net"
qdir qt JS;    ok "ts report → candor-ts-query"       "WOULD-RUN: candor-ts-query where Net" bash -c "cd '$T/qt'  && '$D' where Net"
qdir qj jvm;   ok "java report → candor-java"         "WOULD-RUN: candor-java path f Net"    bash -c "cd '$T/qj'  && '$D' path f Net"
qdir qs Swift; ok "swift report → candor-swift"       "WOULD-RUN: candor-swift fix-gate"     bash -c "cd '$T/qs'  && '$D' fix-gate --policy p"

echo
echo "verb CAPABILITY (which engine implements what — not just which is installed):"
# THE TWO ENGINE-ONLY VERBS ARE NOW REACHABLE. Before this, `candor privacy-manifest` said "unknown action"
# because the umbrella did not know candor-swift has it, and `candor gate` was routed by nothing at all.
ok "privacy-manifest → candor-swift"  "WOULD-RUN: candor-swift privacy-manifest" bash -c "cd '$T/qs' && '$D' privacy-manifest"
ok "gate is routed at all"            "WOULD-RUN: candor-query gate"             bash -c "cd '$T/qr' && '$D' gate --policy p"
# THE WORSE DIRECTION: an engine handed a verb it lacks used to read the FUNCTION NAME AS A PATH and answer
# "no such path: foo" — blaming the user's argument for a capability gap.
ok "swift + show → names the engines that do" "does not implement \`show\`"     bash -c "cd '$T/qs' && '$D' show foo"
ok "swift + show → suggests candor-ts"        "candor-ts"                        bash -c "cd '$T/qs' && '$D' show foo"
ok "rust + privacy-manifest → refused"        "does not implement \`privacy-manifest\`" bash -c "cd '$T/qr' && '$D' privacy-manifest"
# THE ASYMMETRIES ARE REAL AND EACH WOULD MISROUTE WITHOUT ITS OWN ROW: java has no parsepolicy, ts has no
# rewire, only rust has agents.
# CORRECTED 2026-08-05 by a review: java DOES implement parsepolicy and ts DOES implement agents, so
# the original two rows here asserted FALSE REFUSALS — the dispatcher telling a user their engine lacks
# a verb it has, which is the bug this table exists to fix. Both are now asserted to ROUTE.
ok "java + parsepolicy → routes (java HAS it)" "WOULD-RUN: candor-java parsepolicy" bash -c "cd '$T/qj' && '$D' parsepolicy p"
ok "ts + agents → routes (ts HAS it)"          "WOULD-RUN: candor-ts-query agents"  bash -c "cd '$T/qt' && '$D' agents"
ok "swift + parsepolicy → routes"              "WOULD-RUN: candor-swift parsepolicy" bash -c "cd '$T/qs' && '$D' parsepolicy p"
ok "ts + rewire → refused"                    "does not implement \`rewire\`"      bash -c "cd '$T/qt' && '$D' rewire a b"
ok "java + agents → refused, names who has it" "does not implement \`agents\`"     bash -c "cd '$T/qj' && '$D' agents"
# THE REGRESSION GUARD. Rust owns the OPEN REMAINDER of backend tokens (`scan`, `lib`, `Executable`, …), so
# comparing the raw token refuses every supported verb on a Rust report. The first version of the capability
# check did exactly that — a routing fix that became a routing regression.
ok "rust + show still routes (open remainder)" "WOULD-RUN: candor-query show foo"  bash -c "cd '$T/qr' && '$D' show foo"
qdir qr2 lib; ok "rust nightly-lint token routes too" "WOULD-RUN: candor-query where Net" bash -c "cd '$T/qr2' && '$D' where Net"

echo
echo "verb help is CAPABILITY-AWARE (help for a verb this engine lacks is a dead end in documentation's clothes):"
ok "swift + show --help names the engines that do" "does not implement \`show\`" bash -c "cd '$T/qs' && '$D' show --help"
ok "swift + show --help suggests candor-ts"        "candor-ts"                    bash -c "cd '$T/qs' && '$D' show --help"
no "swift + path --help stays silent (swift HAS it)" "NOT AVAILABLE"              bash -c "cd '$T/qs' && '$D' path --help"
no "rust + show --help stays silent (rust HAS it)"   "NOT AVAILABLE"              bash -c "cd '$T/qr' && '$D' show --help"
ok "rust + privacy-manifest --help warns"          "does not implement \`privacy-manifest\`" bash -c "cd '$T/qr' && '$D' privacy-manifest --help"
# NEVER GUESS: when the arm is unknowable a note on the WRONG arm is worse than none. Two ways it is
# unknowable, and BOTH must stay silent. Not /tmp: on this machine `detect_langs /tmp` answers `java` from
# whatever else is lying there, so that dir passes this assertion without ever reaching the unknown path.
mkdir -p "$T/qempty"
emptyarm "empty tree → arm is EMPTY, not a guess" "$T/qempty"
no "empty tree → no capability note at all"        "NOT AVAILABLE"                bash -c "cd '$T/qempty' && '$D' show --help"
mkdir -p "$T/qmixed"; : > "$T/qmixed/Cargo.toml"; echo '{}' > "$T/qmixed/package.json"
no "mixed tree → no capability note either"        "NOT AVAILABLE"                bash -c "cd '$T/qmixed' && '$D' privacy-manifest --help"
# and the likelier mixed case, since chained dep reports arrive one per engine: a .candor holding TWO
# engines' reports. Found by mutation — making context_arm take the first of several broke no assertion.
mkdir -p "$T/qmixrep/.candor"; : > "$T/qmixrep/.candor/report.a.scan.json"; : > "$T/qmixrep/.candor/report.b.JS.json"
emptyarm "two engines' reports → arm is EMPTY, not the first" "$T/qmixrep"
no "two engines' reports → no capability note"     "NOT AVAILABLE"                bash -c "cd '$T/qmixrep' && '$D' privacy-manifest --help"
# the two newly-routed verbs need their own help, or routing them just moved the dead end
ok "gate --help has its own text"                  "apply a policy to an EXISTING report" bash -c "cd '$T/qr' && '$D' gate --help"
ok "privacy-manifest --help has its own text"      "usage-description keys"        bash -c "cd '$T/qs' && '$D' privacy-manifest --help"
qdir ql lib;   ok "rust lint report → candor-query"   "WOULD-RUN: candor-query where Net"    bash -c "cd '$T/ql'  && '$D' where Net"
qdir qx Executable; ok "rust Executable → candor-query" "WOULD-RUN: candor-query show f"    bash -c "cd '$T/qx'  && '$D' show f"

echo "scan routing (by manifest):"
sdir sr Cargo.toml;        ok "Cargo.toml → candor-scan"    "WOULD-RUN: candor-scan"  bash -c "cd '$T/sr' && '$D' scan ."
sdir st package.json;      ok "package.json → candor-ts"    "WOULD-RUN: candor-ts"    bash -c "cd '$T/st' && '$D' ."
sdir sj build.gradle.kts;  ok "gradle → candor-java"        "WOULD-RUN: candor-java"  bash -c "cd '$T/sj' && '$D' scan ."
sdir sm pom.xml;           ok "maven → candor-java"         "WOULD-RUN: candor-java"  bash -c "cd '$T/sm' && '$D' scan ."
sdir sv Package.swift;     ok "Package.swift → candor-swift" "WOULD-RUN: candor-swift" bash -c "cd '$T/sv' && '$D' scan ."

echo "loud failures (never a silent wrong-engine run):"
mkdir -p "$T/amb"; : > "$T/amb/Cargo.toml"; : > "$T/amb/package.json"
ok "polyglot scan → error"      "mixes languages"      bash -c "cd '$T/amb' && '$D' scan ."
mkdir -p "$T/mx/.candor"; : > "$T/mx/.candor/report.a.scan.json"; : > "$T/mx/.candor/report.b.JS.json"
ok "polyglot report → error"    "disambiguate"         bash -c "cd '$T/mx' && '$D' where Net"
ok "no report → error"          "no report"            bash -c "cd '$T' && '$D' where Net"
ok "--report override wins"     "WOULD-RUN: candor-query where Net --report" bash -c "cd /tmp && '$D' where Net --report '$T/qr'"

echo "§3.3.1 locator forms + tour (the scan opener's suggested commands must route):"
# tour is a query verb (was missing from QUERY_VERBS — `candor tour` fell through to SCAN routing and died)
ok "tour routes as a query"     "WOULD-RUN: candor-query tour 5"       bash -c "cd '$T/qr' && '$D' tour 5"
# a --report pointing at a DIRECT .json report file (any basename — not just `report.*`)
: > "$T/loose.pkg.scan.json"
ok "--report <file.json> routes" "WOULD-RUN: candor-query tour --report" bash -c "cd /tmp && '$D' tour --report '$T/loose.pkg.scan.json'"
: > "$T/loosej.pkg.jvm.json"
ok "--report <jvm file> → java" "WOULD-RUN: candor-java where Net"     bash -c "cd /tmp && '$D' where Net --report '$T/loosej.pkg.jvm.json'"
# a --report naming a BARE PREFIX whose basename isn't `report`
ok "--report <bare prefix> routes" "WOULD-RUN: candor-query where Net" bash -c "cd /tmp && '$D' where Net --report '$T/loose'"

echo "max-review regressions (phantom-engine sidecars; the token-less candor-ts report shape):"
# candor-scan's own ledger sidecars must NOT count as engine backends (they made the dispatcher
# refuse a completely standard scan family with "multiple engines' reports").
mkdir -p "$T/scanfam/.candor"
: > "$T/scanfam/.candor/report.demo.scan.json"
: > "$T/scanfam/.candor/report.demo.scan.callgraph.json"
: > "$T/scanfam/.candor/report.calibrated.json"
: > "$T/scanfam/.candor/report.encountered-demo.json"
: > "$T/scanfam/.candor/report.gate.json"
ok "scan family + ledgers → candor-query (not 'multiple engines')" "WOULD-RUN: candor-query where Net" \
   bash -c "cd '$T/scanfam' && '$D' where Net"
# candor-ts writes a TOKEN-LESS primary report (.candor/report.json) — the family glob can't see it.
mkdir -p "$T/tsfam/.candor"
: > "$T/tsfam/.candor/report.json"
: > "$T/tsfam/.candor/report.callgraph.json"
ok "token-less report.json → candor-ts-query" "WOULD-RUN: candor-ts-query tour" \
   bash -c "cd '$T/tsfam' && '$D' tour"
# THE candor-ts `.locs.json` SIDECAR. Found by a usability review actually using the tool: candor-ts
# writes report.locs.json on every scan, the sidecar-exclusion list did not name it, so discovery read it
# as a SECOND ENGINE and every bare verb after a TS scan dead-ended with "multiple engines' reports …
# disambiguate" — including the command the scan itself prints as the next step. The list lived in FIVE
# places and `.locs.json` was in none of them; there is one now (`is_sidecar`).
mkdir -p "$T/tslocs/.candor"
: > "$T/tslocs/.candor/report.json"
: > "$T/tslocs/.candor/report.callgraph.json"
: > "$T/tslocs/.candor/report.hierarchy.json"
: > "$T/tslocs/.candor/report.locs.json"
ok "ts scan family + .locs sidecar → candor-ts-query (not 'multiple engines')" "WOULD-RUN: candor-ts-query tour" \
   bash -c "cd '$T/tslocs' && '$D' tour"
no "…and no disambiguate error"                    "disambiguate"                bash -c "cd '$T/tslocs' && '$D' tour"
# the same sidecar beside a TOKENED report family must behave too
mkdir -p "$T/rlocs/.candor"
: > "$T/rlocs/.candor/report.p.scan.json"
: > "$T/rlocs/.candor/report.p.scan.locs.json"
ok "rust family + .locs sidecar still routes"      "WOULD-RUN: candor-query where Net" \
   bash -c "cd '$T/rlocs' && '$D' where Net"

# and a --report pointing directly at a token-less .json file routes to ts too
ok "--report <token-less .json> → candor-ts-query" "WOULD-RUN: candor-ts-query where Net" \
   bash -c "cd /tmp && '$D' where Net --report '$T/tsfam/.candor/report.json'"

echo "max-review r2: token-less files sniff the ENVELOPE (never blind-JS); mixed families disambiguate:"
# a java `--json > baseline.json` direct file (the AGENTS-doc workflow) must route to JAVA, not ts
printf '{"candor":{"version":"abc1234","toolchain":"jdk-21","spec": "0.23"},"functions":[]}' > "$T/baseline.json"
ok "token-less java baseline.json -> candor-java (envelope sniff)" "WOULD-RUN: candor-java where Net" \
   bash -c "cd /tmp && '$D' where Net --report '$T/baseline.json'"
printf '{"candor":{"version":"candor-swift-0.15.0","toolchain":"swiftsyntax","spec": "0.23"},"functions":[]}' > "$T/swbase.json"
# `tour`, not `where`: this asserts the ENVELOPE SNIFF picks the swift arm, and the verb is incidental to
# that — but candor-swift does not implement `where`, so the original form asserted a route to a command
# that could never have run. The capability check surfaced it by refusing, which is the check working.
ok "token-less swift baseline -> candor-swift (envelope sniff)" "WOULD-RUN: candor-swift tour" \
   bash -c "cd /tmp && '$D' tour --report '$T/swbase.json'"
printf '{"meta":{"version":"scan-0.15.0","toolchain":"stable","spec": "0.23"},"functions":[]}' > "$T/rbase.json"
ok "token-less rust baseline -> candor-query (envelope sniff)" "WOULD-RUN: candor-query where Net" \
   bash -c "cd /tmp && '$D' where Net --report '$T/rbase.json'"
# a ts report.json BESIDE a tokened engine's reports must trip the ambiguity check, never be shadowed
mkdir -p "$T/mixed/.candor"
printf '{"candor":{"version":"candor-ts-0.15.0","toolchain":"node-23.0.0","spec": "0.23"},"functions":[]}' > "$T/mixed/.candor/report.json"
: > "$T/mixed/.candor/report.demo.scan.json"
ok "ts report.json beside a scan family -> disambiguate (not silently shadowed)" "disambiguate" \
   bash -c "cd '$T/mixed' && '$D' where Net"

echo "code-review regressions (2026-07-15):"
# want()/token bugs (bare update skipped every engine; `update java` was a no-op) — asserted network-free
# by checking the RESOLVED engine set the update case would fetch, via CANDOR_UPDATE_DRYRUN (prints the
# `want`-selected engines and exits before any curl).
ok "bare update selects all engines" "jvm rust ts swift" \
   bash -c "CANDOR_UPDATE_DRYRUN=1 '$D' update"
ok "update java → the jvm engine (token synonym, not a no-op)" "jvm" \
   bash -c "CANDOR_UPDATE_DRYRUN=1 '$D' update java"
ok "update rust ts → only those" "rust ts" \
   bash -c "CANDOR_UPDATE_DRYRUN=1 '$D' update rust ts"
# bare `candor` on a structurally-corrupt-but-valid-JSON report degrades to 'unreadable', no traceback.
# (DRYRUN doesn't affect the status dashboard — it reads the report directly, no engine needed.)
mkdir -p "$T/corruptshape/.candor"
printf '{"functions":{"a":1},"candor":"nope","coverage":"nope"}' > "$T/corruptshape/.candor/report.json"
notrace="$(cd "$T/corruptshape" && CANDOR_DISPATCH_DRYRUN= "$D" 2>&1)"
if [[ "$notrace" != *Traceback* ]]; then echo "  ok   corrupt-shape report → no python traceback in status"; else echo "  FAIL corrupt-shape traceback"; echo "$notrace"; fails=$((fails+1)); fi
# (init's report iteration is space-safe now — reps is a quoted bash array, not an unquoted string —
# but a real scan is needed to produce reports to iterate, which this DRYRUN harness can't do; that path
# is covered by the manual UX probes instead.)

echo "persona-audit UX fixes (0.16.3):"
# effect-name validation: the umbrella catches an unambiguous WRONG-CASE typo (`fs`→Fs, `net`→Net) with a
# did-you-mean, BEFORE report discovery. Any OTHER unknown name (Network, Banana, a spec-EXTENSION effect) is
# DEFERRED to the engine, which validates report-aware (accepts an extension effect present in the report,
# errors only when it's neither known nor present) — so the umbrella must NOT hard-reject it (review fix).
ok "where <wrong-case effect> → did-you-mean"   "did you mean \`Fs\`"  bash -c "cd /tmp && '$D' where fs"
ok "whatif <fn> <wrong-case effect> caught too" "did you mean \`Net\`" bash -c "cd /tmp && '$D' whatif f net"
# an unknown NON-wrong-case name is NOT rejected by the umbrella — it defers to the engine (here: no report,
# so the report error surfaces, NOT a premature `unknown effect` from the dispatcher).
ok "where <unknown extension-shaped> defers"    "no report"            bash -c "cd /tmp && '$D' where Netlify"
# a VALID effect must NOT be caught by the validator — it routes on to the engine (needs a report).
ok "where Net (valid) → no effect error"  "WOULD-RUN: candor-query where Net" bash -c "cd '$T/qr' && '$D' where Net"
# --report's VALUE must not be mistaken for the effect positional
ok "where --report <dir> Net (valid)"     "WOULD-RUN: candor-query where Net --report" bash -c "cd /tmp && '$D' where Net --report '$T/qr'"
# the effect glossary
ok "candor effects explains the concept"  "An effect is something your code does" bash -c "'$D' effects"
ok "candor glossary is an alias"          "Unknown    a call candor could NOT"    bash -c "'$D' glossary"
# per-action --help no longer reaches the engine as a bogus arg
ok "where --help → its own usage"         "the functions that perform an effect"  bash -c "'$D' where --help"
ok "path --help → its own usage"          "the call path by which"                bash -c "'$D' path --help"
ok "fix --help names the policy source"   "Reads the wired policy"                bash -c "'$D' fix --help"
ok "init --help → its own usage"          "stand up the gate"                     bash -c "'$D' init --help"
ok "hook --help → end-of-turn framing"    "END of each agent turn"               bash -c "'$D' hook --help"
ok "mcp --help → paste-ready config"      "mcpServers"                            bash -c "'$D' mcp --help"
# hook-run resolves the scripts itself (the portability fix) and always emits contract-valid Stop-hook
# JSON on stdout — never a crash — even with no scan/config to review (graceful non-block, rc-safe).
ok "hook-run emits contract JSON, no crash" "systemMessage" bash -c "cd /tmp && printf '{}' | '$D' hook-run"

echo "persona-audit polish (#17):"
# #24: a nonexistent scan target is a "no such file or directory" naming the FULL path — not a dirname-
# truncated, manifest-blaming message.
ok "scan <nonexistent> → no such file (full path)" "no such file or directory: /does/not/exist" \
   bash -c "cd '$T' && '$D' scan /does/not/exist"
# #10: gains/diff route by their FIRST positional report locator (discovery does not apply), so they work
# from any dir — the dispatcher must NOT demand a discovered .candor/ when both reports are named.
: > "$T/gcur.pkg.scan.json"; : > "$T/gbase.pkg.scan.json"
ok "gains <cur> <base> routes via the positional (rust)" "WOULD-RUN: candor-query gains" \
   bash -c "cd /tmp && '$D' gains '$T/gcur.pkg.scan.json' '$T/gbase.pkg.scan.json'"
: > "$T/gcur.pkg.jvm.json"; : > "$T/gbase.pkg.jvm.json"
ok "gains routes by the FIRST positional's backend (jvm)" "WOULD-RUN: candor-java gains" \
   bash -c "cd /tmp && '$D' gains '$T/gcur.pkg.jvm.json' '$T/gbase.pkg.jvm.json'"

echo "0.17 re-audit fixes:"
# [14] a polyglot repo's status dashboard must NOT suggest `candor scan .` (the scanner refuses a mixed dir)
# — it names the per-engine gate instead. Dashboard reads the report directly, so no engine needed.
mkdir -p "$T/polyd/.candor"; : > "$T/polyd/Cargo.toml"; : > "$T/polyd/package.json"
printf '{"candor":{"version":"scan-0.18.0","toolchain":"stable","spec": "0.23"},"functions":[{"fn":"f","inferred":["Fs"]}]}' > "$T/polyd/.candor/report.p.scan.json"
printf 'baseline .candor/baseline.json\n' > "$T/polyd/.candor/config"; : > "$T/polyd/.candor/baseline.json"
ok "polyglot dashboard names per-engine gates (not \`scan .\`)" "one per language" bash -c "cd '$T/polyd' && CANDOR_DISPATCH_DRYRUN= '$D'"
ok "polyglot dashboard: rust gate is the raw engine"  "candor-scan . --gate-json"  bash -c "cd '$T/polyd' && CANDOR_DISPATCH_DRYRUN= '$D'"
# hook-run run interactively (a TTY on stdin) must NOT hang — it explains + exits. Here stdin is a PIPE, so
# it does NOT take the tty branch; assert the tty-guard text is absent (proving we only gate on -t 0).
ok "hook-run piped stdin does not print the tty guidance" "systemMessage" bash -c "cd '$T' && printf '{}' | '$D' hook-run"

echo
if [ "$fails" -eq 0 ]; then echo "candor-dispatch: OK"; else echo "candor-dispatch: $fails FAILED"; exit 1; fi
