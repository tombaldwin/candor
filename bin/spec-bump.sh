#!/usr/bin/env bash
# spec-bump.sh — REHEARSE a spec-floor bump before committing one.
#
#   bash bin/spec-bump.sh --check          # are all seven declarations already consistent?
#   bash bin/spec-bump.sh 0.28             # bump every declaration, then verify the whole family
#
# WHY THIS EXISTS, stated as it happened.
#
# `release-stage.sh` performs the RELEASE bump (build versions, crate deps, changelogs) and deliberately
# does NOT touch the spec declarations, because a floor bump is a contract decision on a different axis.
# So the contract bump had no tooling at all: on 2026-08-04 the ⟨0.27⟩ bump was done by hand and turned
# SIX repos' CI red on version-coupled assertions — four in candor-agents' test.py, three in candor-java's
# smoke.sh, several in candor-rust's cli tests plus its integration script and its own doc-drift gate,
# README/AGENTS/package.json in candor-ts, and doc strings in three more. Every one was findable locally in
# minutes. None was found until CI went red, because nothing ran the family's suites against the bump.
#
# WHAT IT DOES
#   1. Bumps the SEVEN declaration sites (the constants each engine emits as `candor.spec`, plus SPEC.md).
#   2. Runs every engine's own suite, the four-way conformance run, and the doc-drift gates.
#   3. LISTS every remaining mention of the old version for a human to triage.
#
# WHY STEP 3 IS A LIST AND NOT A SWEEP. A blanket find-and-replace would have caused harm on 2026-08-04:
# candor-rust's `crates/candor-scan/src/tests.rs` builds fixture reports declaring the PREVIOUS spec
# version as INPUTS, proving an older report still loads. Replacing those would have silently deleted a
# backward-compatibility test. So the script bumps what it KNOWS is a declaration and reports the rest.
#
# It does not commit, tag or push. It leaves the tree bumped on failure ON PURPOSE — you fix forward from
# a rehearsal, and reverting would throw away the diff you need to read.
set -uo pipefail
ROOT="${CANDOR_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
say()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✘\033[0m %s\n' "$*"; }
note() { printf '  \033[33m•\033[0m %s\n' "$*"; }

# label | repo-relative file | sed pattern capturing the version
DECLS=(
  "rust|candor-rust/crates/candor-report/src/lib.rs|pub const SPEC_VERSION: &str = \"%s\";"
  "java|candor-java/src/main/java/io/poly/candor/Candor.java|    static final String SPEC_VERSION = \"%s\";"
  "ts-scan|candor-ts/scan.mjs|const SPEC_VERSION = \"%s\";"
  "ts-query|candor-ts/query.mjs|const SPEC_VERSION = \"%s\";"
  "swift|candor-swift/Sources/candor-swift/main.swift|let specVersion = \"%s\""
  "agents|candor-agents/candor_agents/scan.py|SPEC = \"%s\""
)

current_of() {  # echo the version a declaration file currently carries
  grep -oE 'SPEC_VERSION[^"]*"[0-9]+\.[0-9]+"|specVersion = "[0-9]+\.[0-9]+"|^SPEC = "[0-9]+\.[0-9]+"' "$1" 2>/dev/null \
    | grep -oE '[0-9]+\.[0-9]+' | head -1
}

# ── --check: are the seven already consistent? ──────────────────────────────────────────────────────
if [ "${1:-}" = "--check" ]; then
  say "declaration consistency"
  seen=""; rc=0
  for d in "${DECLS[@]}"; do
    IFS='|' read -r label rel _ <<<"$d"
    v="$(current_of "$ROOT/$rel")"
    [ -n "$v" ] || { bad "$label: no declaration found in $rel"; rc=1; continue; }
    note "$(printf '%-9s %s' "$label" "$v")"
    case " $seen " in *" $v "*) ;; *) seen="$seen $v";; esac
  done
  sv="$(grep -oE '^\*\*Version [0-9]+\.[0-9]+' "$ROOT/candor-spec/SPEC.md" | grep -oE '[0-9]+\.[0-9]+')"
  note "$(printf '%-9s %s' "SPEC.md" "${sv:-?}")"
  case " $seen " in *" $sv "*) ;; *) seen="$seen $sv";; esac
  n=$(echo $seen | wc -w | tr -d ' ')
  if [ "$n" = 1 ]; then ok "every declaration agrees on ${seen# }"; else
    bad "declarations DISAGREE (${seen# }) — an engine emitting a spec version the others do not is a
       four-way contract split, not a version-number detail"; rc=1; fi
  exit $rc
fi

NEW="${1:?usage: spec-bump.sh <new-spec e.g. 0.28> | --check}"
case "$NEW" in [0-9]*.[0-9]*) ;; *) echo "spec-bump: '$NEW' is not an X.Y spec version" >&2; exit 2;; esac

# Refuse a dirty tree: this rewrites seven files across seven repos and an interrupted run is unreviewable.
say "0. preconditions"
dirty=0
for r in candor-spec candor-rust candor-java candor-ts candor-swift candor-agents candor; do
  [ -d "$ROOT/$r" ] || continue
  [ -z "$(git -C "$ROOT/$r" status --porcelain)" ] || { bad "$r has uncommitted changes"; dirty=1; }
done
[ "$dirty" = 0 ] || { echo; echo "spec-bump: commit or stash first — a rehearsal must start from a known tree."; exit 1; }
OLD="$(current_of "$ROOT/candor-rust/crates/candor-report/src/lib.rs")"
[ -n "$OLD" ] || { bad "cannot read the current spec version"; exit 2; }
ok "clean trees; bumping $OLD → $NEW"

# ── 1. the declarations ─────────────────────────────────────────────────────────────────────────────
say "1. spec declarations"
for d in "${DECLS[@]}"; do
  IFS='|' read -r label rel tmpl <<<"$d"
  f="$ROOT/$rel"
  [ -f "$f" ] || { bad "$label: missing $rel"; continue; }
  # shellcheck disable=SC2059
  from="$(printf "$tmpl" "$OLD")"; to="$(printf "$tmpl" "$NEW")"
  if grep -qF "$from" "$f"; then
    python3 - "$f" "$from" "$to" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert s.count(a) == 1, f"{p}: expected exactly one declaration, found {s.count(a)}"
open(p, "w").write(s.replace(a, b, 1))
PY
    ok "$(printf '%-9s → %s   (%s)' "$label" "$NEW" "$rel")"
  else
    bad "$(printf '%-9s declaration not found — the site moved; update DECLS in this script   (%s)' "$label" "$rel")"
  fi
done
python3 - "$ROOT/candor-spec/SPEC.md" "$OLD" "$NEW" <<'PY'
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
a = f"**Version {old}** — all code engines declare `{old}`"
b = f"**Version {new}** — all code engines declare `{new}`"
if a in s:
    open(p, "w").write(s.replace(a, b, 1)); print("  \033[32m✔\033[0m SPEC.md   → " + new)
else:
    print("  \033[31m✘\033[0m SPEC.md headline version not found in the expected form")
PY

# `--decls-only` exists so the harness can exercise the bump MECHANICS against a fixture tree without
# running seven real suites. It is not a shortcut for a real bump: skipping step 2 is skipping the entire
# reason this script exists.
if [ "${2:-}" = "--decls-only" ]; then
  echo; ok "declarations bumped (--decls-only: suites and triage SKIPPED — not a rehearsal)"
  exit 0
fi

# ── 2. the family's own suites ──────────────────────────────────────────────────────────────────────
say "2. every engine's suite (this is the step that was missing)"
rc=0
run_suite() { # $1 label ; $2 dir ; shift 2 = command
  local label="$1" dir="$2"; shift 2
  printf '  … %-8s ' "$label"
  if ( cd "$dir" && "$@" >/tmp/spec-bump-$label.log 2>&1 ); then printf '\033[32mPASS\033[0m\n'
  else printf '\033[31mFAIL\033[0m  (see /tmp/spec-bump-%s.log)\n' "$label"; rc=1; fi
}
[ -d "$ROOT/candor-rust" ]   && run_suite rust   "$ROOT/candor-rust"   cargo test --workspace
[ -d "$ROOT/candor-rust" ]   && run_suite rustint "$ROOT/candor-rust"  bash tests/integration.sh
[ -d "$ROOT/candor-java" ]   && run_suite java   "$ROOT/candor-java"   ./gradlew -q test
[ -d "$ROOT/candor-java" ]   && run_suite jsmoke "$ROOT/candor-java"   bash test/smoke.sh
[ -d "$ROOT/candor-ts" ]     && run_suite ts     "$ROOT/candor-ts"     npm test
[ -d "$ROOT/candor-swift" ]  && run_suite swift  "$ROOT/candor-swift"  swift test
[ -d "$ROOT/candor-swift" ]  && run_suite ssmoke "$ROOT/candor-swift"  bash smoke.sh
[ -d "$ROOT/candor-agents" ] && run_suite agents "$ROOT/candor-agents" python3 test.py
[ -f "$ROOT/candor-spec/scripts/check_agents_drift.py" ] \
  && run_suite drift "$ROOT/candor-spec" python3 scripts/check_agents_drift.py
[ -f "$ROOT/candor-spec/conformance/run.sh" ] \
  && run_suite conform "$ROOT/candor-spec/conformance" ./run.sh

# ── 3. what is LEFT — reported, never swept ─────────────────────────────────────────────────────────
say "3. remaining mentions of $OLD — TRIAGE THESE BY HAND"
echo "  A blanket replace would be wrong: on the 0.27 bump, candor-rust's tests.rs built FIXTURE reports"
echo "  at the old version as INPUTS (proving an older report still loads). Sweeping them would have"
echo "  silently deleted a backward-compatibility test. Read each one."
echo
found=0
for r in candor-spec candor-rust candor-java candor-ts candor-swift candor-agents candor; do
  [ -d "$ROOT/$r" ] || continue
  hits="$(grep -rn "spec.\{0,3\}$OLD\|\"$OLD\"" "$ROOT/$r" \
    --include='*.rs' --include='*.java' --include='*.mjs' --include='*.swift' --include='*.py' \
    --include='*.sh' --include='*.md' --include='*.json' 2>/dev/null \
    | grep -viE "/target/|/\.build/|node_modules|/build/|CHANGELOG|⟨$OLD⟩|$OLD\.[0-9]" | head -12)"
  [ -n "$hits" ] && { printf '  \033[1m%s\033[0m\n' "$r"; echo "$hits" | sed "s|$ROOT/||" | sed 's/^/    /' | cut -c1-118; found=1; }
done
[ "$found" = 0 ] && ok "no remaining mentions"

echo
if [ "$rc" = 0 ]; then
  printf '\033[32mspec-bump: the family is GREEN at %s.\033[0m Review the diff, triage any list above, then commit.\n' "$NEW"
else
  printf '\033[31mspec-bump: %s — the tree is left BUMPED on purpose so you can fix forward.\033[0m\n' "suites failed"
  echo "Prefer DERIVING a version-coupled assertion from the engine's own constant over re-editing a literal:"
  echo "  that class was closed as \"a one-off\" once and cost an edit in every repo the next rung."
fi
exit $rc
