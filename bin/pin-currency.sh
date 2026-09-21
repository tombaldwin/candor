#!/usr/bin/env bash
# pin-currency.sh — does every cross-repo pin name the LATEST PUBLISHED version of the artifact it pins?
#
#   bash bin/pin-currency.sh              # report + verdict
#   bash bin/pin-currency.sh --selftest   # prove it can FAIL, offline
#
# WHY THIS EXISTS, and it is a DIFFERENT question from release-preflight [3].
#
# [3] asks "does this pin name the version being CUT". That is the right question ON RELEASE DAY and it
# is blind the rest of the time: between cuts there is no $WANT_VER, so nothing asks anything, and a pin
# can sit arbitrarily far behind while every gate stays green.
#
# MEASURED TWICE, both times found by a person rather than by a gate:
#   · 2026-08-16 — both IDE pins sat at 0.16.0 while candor-ts was 0.28.2. TWELVE rungs, including the
#     ⟨0.29⟩ `forbid`-answered-from-a-report fix that those two extensions are the delivery vehicle for.
#     The remedy was to register them in [3]. That closed release day and left this open.
#   · 2026-09-21 — at the v0.39.1 cut, `candorTsVersion` was 0.38.3 in BOTH IDE integrations: they had
#     missed the entire 0.39.0 family release. The vscode drift gate did not catch it either, because it
#     compares the extension VERSION against `candorTsVersion` and both had gone stale TOGETHER.
#     A GATE COMPARING TWO VALUES THAT MOVE TOGETHER CANNOT CATCH THEM BOTH BEING STALE.
#
# So this resolves each pin against its REGISTRY, never against another value in the tree.
#
# THREE STATES, NOT TWO (the R470 rule, already applied to the rust asset pin): a network failure is
# INCOMPLETE and exits 2. Folding it into either pass or fail is how an unreachable registry becomes a
# green release gate.
#
# AHEAD is reported and is NOT a failure. A scoped patch legitimately puts one engine ahead of the
# family line (ENGINE_PIN_TS=0.39.1 over ENGINE_PIN=0.39.0), which is the whole point of a per-engine
# pin. A pin ahead of what is PUBLISHED is a different thing entirely and fails loudly — that is the
# 0.24 shape, where jbang named a release that did not exist and every download 404'd.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/_release_set.sh
. "$HERE/_release_set.sh"
ROOT="${CANDOR_ROOT:-$(cd "$HERE/../.." && pwd)}"
GH_OWNER="${CANDOR_GH_OWNER:-tombaldwin}"

stale=0; incomplete=0; ahead=0; current=0
ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✘\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m•\033[0m %s\n' "$*"; }

# --- registry resolution. CURL WITH --max-time, NEVER `timeout`: this is macOS, where `timeout` does not
# exist and its absence exits 127 — which has been read as a RESULT three times in this project. ---
latest_npm() {   # $1 = package
  local j; j="$(curl -fsS --max-time 25 "https://registry.npmjs.org/$1/latest" 2>/dev/null)" || return 2
  printf '%s' "$j" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("version",""))' 2>/dev/null || return 2
}
latest_crate() { # $1 = crate
  # crates.io REFUSES a request with no User-Agent, and curl -f turns that into a silent non-zero — which
  # this script would then report as "network INCOMPLETE". Measured 2026-09-21: the row read INCOMPLETE
  # against a crate that was sitting there perfectly. An UNSENT HEADER AND AN UNREACHABLE REGISTRY ARE THE
  # SAME EXIT CODE, which is the whole reason INCOMPLETE must never read as a pass.
  local j; j="$(curl -fsS --max-time 25 -H 'User-Agent: candor-pin-currency (https://github.com/tombaldwin/candor)' "https://crates.io/api/v1/crates/$1" 2>/dev/null)" || return 2
  printf '%s' "$j" | python3 -c 'import json,sys; print(json.load(sys.stdin)["crate"]["max_stable_version"])' 2>/dev/null || return 2
}
latest_gh() {    # $1 = repo — the newest SEMVER tag, not the newest by date
  local t; t="$(gh release list --repo "$GH_OWNER/$1" --limit 40 --json tagName -q '.[].tagName' 2>/dev/null)" || return 2
  [ -n "$t" ] || return 2
  printf '%s\n' "$t" | sed 's/^v//' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1
}
resolve() {      # $1 = kind:name
  case "${1%%:*}" in
    npm)   latest_npm   "${1#*:}";;
    crate) latest_crate "${1#*:}";;
    gh)    latest_gh    "${1#*:}";;
    *)     return 2;;
  esac
}

# --- the pin table. ONE declaration; `--selftest` asserts it agrees with release-preflight's. ---
# label|file (relative to ROOT)|key regex for pin_version|artifact
PINS="
adopt java  |candor/adopt/candor.yml|CANDOR_JAVA_VERSION:[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+|gh:candor-java
adopt agents|candor/adopt/candor-digest.yml|candor-agents@v[0-9]+\.[0-9]+\.[0-9]+|gh:candor-agents
jbang       |candor-java/jbang-catalog.json|releases/download/v[0-9]+\.[0-9]+\.[0-9]+|gh:candor-java
engine pin  |candor/bin/candor|^ENGINE_PIN=\"[0-9]+\.[0-9]+\.[0-9]+\"|gh:candor
vscode ts   |candor/integrations/vscode/package.json|\"candorTsVersion\":[[:space:]]*\"[0-9]+\.[0-9]+\.[0-9]+\"|npm:candor-ts
jetbrains ts|candor/integrations/jetbrains/gradle.properties|candorTsVersion=[0-9]+\.[0-9]+\.[0-9]+|npm:candor-ts
jetbrains jvm|candor/integrations/jetbrains/gradle.properties|candorJavaVersion=[0-9]+\.[0-9]+\.[0-9]+|gh:candor-java
"

# ── THE PER-ENGINE PINS, checked SEPARATELY. ────────────────────────────────────────────────────────
# Not in PINS above, deliberately: that table is asserted equal to release-preflight's `checkpin` set, and
# preflight handles these through its own `rs_engine_pin` loop instead. Kept apart so neither assertion
# has to be weakened — but CHECKED, because these are the pins most likely to go stale. A scoped pin is
# the one thing in this file that is SUPPOSED to differ from the family line, which is exactly why a
# forgotten one survives: nothing reads it as wrong.
#
# ADDED 2026-09-21 AFTER I ASSERTED THIS TOOL CHECKED THEM AND IT DID NOT. The umbrella CHANGELOG and the
# comment beside ENGINE_PIN_RUST both said "pin-currency reports AHEAD for both, which is correct for a
# scoped pin"; it reported neither, because the table had no row for either. A claim about an instrument,
# written without running the instrument against the case — the same shape as a comment asserting safety.
#
# An EMPTY per-engine pin is not checked and not counted: empty means "follow ENGINE_PIN", which the
# `engine pin` row above already judges. Only a DECLARED override is a claim about a published artifact.
ENGINE_PINS="
ENGINE_PIN_TS|npm:candor-ts
ENGINE_PIN_RUST|crate:candor-scan
ENGINE_PIN_JAVA|gh:candor-java
ENGINE_PIN_SWIFT|gh:candor-swift
"

check_engine_pins() {
  local famline; famline="$(pin_version "$ROOT/candor/bin/candor" '^ENGINE_PIN="[0-9]+\.[0-9]+\.[0-9]+"')"
  while IFS='|' read -r key art; do
    [ -z "$key" ] && continue
    local v; v="$(pin_version "$ROOT/candor/bin/candor" "^$key=\"[0-9]+\.[0-9]+\.[0-9]+\"")" || v=""
    if [ -z "$v" ]; then
      note_pin "$key: (empty — follows ENGINE_PIN $famline; nothing declared, nothing to judge)"; continue
    fi
    local live; live="$(resolve "$art")" || live=""
    if [ -z "$live" ]; then
      warn "$key: $v — could not resolve $art (network). INCOMPLETE"; incomplete=$((incomplete+1)); continue
    fi
    local scoped=""; [ "$v" != "$famline" ] && scoped=" — SCOPED, differs from ENGINE_PIN $famline; CLEAR IT AT THE NEXT FAMILY CUT"
    if [ "$v" = "$live" ]; then ok "$key: $v == latest $art$scoped"; current=$((current+1))
    elif [ "$(printf '%s\n%s\n' "$v" "$live" | sort -V | head -1)" = "$v" ]; then
      bad "$key: $v but $art publishes $live — STALE, and a non-empty per-engine pin SILENTLY BEATS ENGINE_PIN"
      stale=$((stale+1))
    else
      bad "$key: $v is AHEAD of published $live ($art) — this pin names something that does not exist; the front door will 404"
      stale=$((stale+1))
    fi
  done <<< "$(printf '%s' "$ENGINE_PINS" | grep -v '^$')"
}
note_pin() { printf '  \033[33m·\033[0m %s\n' "$*"; }

if [ "${1:-}" = "--selftest" ]; then
  echo "== pin-currency selftest =="
  rc=0
  # 1. THE TWO LISTS MUST NOT DIVERGE. preflight [3] and this file enumerate the same pins for different
  #    questions; two hand-maintained copies of one list is this project's four-copies-of-two-questions
  #    shape, so assert agreement rather than trusting it.
  pf="$(grep -oE '^checkpin "[^"]+"' "$HERE/release-preflight.sh" | sed 's/^checkpin "//; s/"$//' | sed 's/[[:space:]]*$//' | sort -u)"
  mine="$(printf '%s' "$PINS" | grep -v '^$' | cut -d'|' -f1 | sed 's/[[:space:]]*$//' | sort -u)"
  if [ "$pf" = "$mine" ]; then echo "  ok   pin set matches release-preflight's checkpin set ($(printf '%s\n' "$mine" | grep -c .) pins)"
  else echo "  FAIL pin set DIVERGED from release-preflight's:"; diff <(printf '%s\n' "$pf") <(printf '%s\n' "$mine") | sed 's/^/       /'; rc=1; fi
  # 2. VERSION ORDERING MUST DETECT A BEHIND. A comparator that cannot say 0.38.3 < 0.39.0 makes every
  #    row below vacuous, which is the failure class this repo keeps re-finding in its own guards.
  behind() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ] && [ "$1" != "$2" ]; }
  for t in "0.38.3 0.39.0 yes" "0.39.0 0.38.3 no" "0.39.0 0.39.0 no" "0.9.0 0.10.0 yes" "1.0.0 0.39.9 no"; do
    set -- $t
    if behind "$1" "$2"; then g=yes; else g=no; fi
    if [ "$g" = "$3" ]; then echo "  ok   $1 behind $2 -> $g"; else echo "  FAIL $1 behind $2 -> $g, want $3"; rc=1; fi
  done
  # 3. EVERY DECLARED PIN MUST BE EXTRACTABLE FROM THE LIVE TREE. A regex that matches nothing reports
  #    ABSENT, and an absent pin is indistinguishable from a current one unless it is called out.
  printf '%s' "$PINS" | grep -v '^$' | while IFS='|' read -r label file keyre _art; do
    if [ ! -f "$ROOT/$file" ]; then
      # A MISSING SIBLING IS NOT A PASS. `pin_version` returns the same rc for "file absent" as for
      # "key absent", and in a CI checkout that omits a sibling repo the whole row would silently
      # evaporate — the shape this project keeps re-finding, where a check that measured nothing
      # reports the same thing as a check that measured something and was happy.
      echo "  SKIP ${label%% *}: $file not in this checkout — NOT JUDGED (check out the sibling)"; continue
    fi
    v="$(pin_version "$ROOT/$file" "$keyre")"; r=$?
    if [ $r -eq 0 ] && [ -n "$v" ]; then echo "  ok   ${label%% *} pin extracts as $v"
    else echo "  FAIL ${label%% *}: pin_version rc=$r over $file — the row below would judge nothing"; fi
  done | tee /tmp/pc-sel.$$ 
  grep -q '^  FAIL' /tmp/pc-sel.$$ && rc=1
  _sk=$(grep -c '^  SKIP' /tmp/pc-sel.$$ || true); rm -f /tmp/pc-sel.$$
  # THREE STATES HERE TOO. Printing OK beside "1 pin NOT JUDGED" is the contradiction this whole file
  # exists to stop — a green word over a check that did not run. A skip is INCOMPLETE (exit 2), never OK.
  if [ $rc -ne 0 ]; then echo "pin-currency selftest: FAILED"; exit 1; fi
  if [ "${_sk:-0}" -gt 0 ]; then
    echo "  NOTE $_sk pin(s) NOT JUDGED — a selftest that skips is not a selftest that passed"
    echo "pin-currency selftest: INCOMPLETE — check out the missing sibling(s) and re-run"; exit 2
  fi
  echo "pin-currency selftest: OK"
  exit 0
fi

echo "== pin currency — every pin against the LATEST PUBLISHED version of what it names =="
while IFS='|' read -r label file keyre art; do
  [ -z "$label" ] && continue
  pinned="$(pin_version "$ROOT/$file" "$keyre")"; prc=$?
  if [ $prc -ne 0 ] || [ -z "$pinned" ]; then
    warn "$label: pin NOT FOUND in $file (pin_version rc=$prc) — nothing judged"; incomplete=$((incomplete+1)); continue
  fi
  live="$(resolve "$art")" || live=""
  if [ -z "$live" ]; then
    warn "$label: $pinned — could not resolve $art (network). INCOMPLETE, not pass and not fail"
    incomplete=$((incomplete+1)); continue
  fi
  if [ "$pinned" = "$live" ]; then ok "$label: $pinned == latest $art"; current=$((current+1))
  elif [ "$(printf '%s\n%s\n' "$pinned" "$live" | sort -V | head -1)" = "$pinned" ]; then
    bad "$label: $pinned but $art publishes $live — STALE, and nothing else asks"; stale=$((stale+1))
  else
    warn "$label: $pinned is AHEAD of published $live ($art) — intended for a scoped pin, a 404 otherwise"
    ahead=$((ahead+1))
  fi
done <<< "$(printf '%s' "$PINS" | grep -v '^$')"

echo
echo "== per-engine pins (scoped overrides — a non-empty one SILENTLY beats ENGINE_PIN) =="
check_engine_pins

echo
printf 'pin-currency: %d current, %d STALE, %d ahead, %d incomplete\n' "$current" "$stale" "$ahead" "$incomplete"
if [ "$stale" -gt 0 ]; then
  echo "  A stale pin ships a stale ENGINE to whoever installs through it. Bump it, and remember the"
  echo "  pin-bump commit must touch that repo's CHANGELOG — release-preflight [5b] counts pins as SOURCE."
  exit 1
fi
[ "$incomplete" -gt 0 ] && { echo "  INCOMPLETE is not a pass: a pin nothing could resolve was not judged."; exit 2; }
exit 0
