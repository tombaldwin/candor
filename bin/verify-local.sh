#!/usr/bin/env bash
# verify-local.sh — run what CI runs, before pushing. Written because CI caught two defects in one day
# that no local command I had run could see.
#
# WHY THIS EXISTS (2026-08-19, the ⟨0.30⟩ release):
#
#   `cargo test --workspace` passed twice on candor-rust while `cargo clippy --workspace --all-targets --
#   -D warnings` — which is what CI runs — failed: once on a duplicated `#[allow]`, once on a doc comment
#   left attached to a `thread_local!` macro. Both times "the suite is green" was true and useless, both
#   times the push burned a CI round, and the second time it happened AFTER the first, because the lesson
#   lived in my head rather than in a command.
#
#   The gap is not clippy specifically. It is that each engine's real gate is a DIFFERENT command per
#   language, kept in that repo's CI workflow, and nothing local ran the union. So this runs the union.
#
# USAGE
#   bash bin/verify-local.sh              # every engine
#   bash bin/verify-local.sh candor-rust  # one
#
# Exit 0 only if every step of every engine passed. Prints the command for each step so a failure can be
# re-run directly, and prints what it SKIPPED (a missing toolchain) rather than passing over it silently.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ONLY="${1:-}"
rc=0
skipped=""
TMP="$(mktemp -d)"; RESULTS="$TMP/results"; FAILED="$TMP/failed"; : > "$RESULTS"; : > "$FAILED"
trap 'rm -rf "$TMP"' EXIT INT TERM

# MEASURED 2026-08-20, which is why this now runs concurrently: candor-ts `node test.mjs` takes 298s
# and every other step takes 3-30s. Run in sequence that is 385s of which 77% is one step; run
# concurrently it is ~300s, and the wait is the slowest engine rather than their sum. Output is buffered
# per step and printed on completion, so concurrent rows do not interleave.
step() {  # step <repo> <label> <cmd...>  — run from the repo's dir, which the caller has cd'd into
  local repo="$1" label="$2"; shift 2
  local t0 t1
  t0=$(date +%s)
  if ! out="$("$@" 2>&1)"; then
    t1=$(date +%s)
    { printf "  %-14s %-22s ✘ FAILED  (%ss)\n" "$repo" "$label" "$((t1-t0))"
      printf "      %s\n" "$*"
      printf "%s\n" "$out" | grep -iE "^error|error\[|FAILED|panicked|✘" | head -4 | sed 's/^/      /'
    } >> "$RESULTS"
    echo 1 >> "$FAILED"
  else
    t1=$(date +%s)
    printf "  %-14s %-22s ✔        (%ss)\n" "$repo" "$label" "$((t1-t0))" >> "$RESULTS"
  fi
}

want() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }
have() { command -v "$1" >/dev/null 2>&1; }

if want candor-rust && [ -d "$ROOT/candor-rust" ]; then
  if have cargo; then
    cd "$ROOT/candor-rust" || exit 2
    ( step candor-rust "cargo test"          cargo test --workspace ) &
    # THE ONE THAT KEEPS BITING. CI runs this with -D warnings; `cargo test` never does.
    ( step candor-rust "clippy -D warnings"  cargo clippy --all-targets -- -D warnings ) &
    # NO `cargo fmt --check` HERE, deliberately: ci.yml does not run it, and a local gate STRICTER than
    # CI trains you to ignore its output. This script mirrors CI; it does not invent policy.
  else skipped="$skipped candor-rust(no-cargo)"; fi
fi

if want candor-ts && [ -d "$ROOT/candor-ts" ]; then
  if have node; then
    cd "$ROOT/candor-ts" || exit 2
    ( step candor-ts "node test.mjs"         node test.mjs ) &
    ( step candor-ts "npm pack bins run"     bash -c '
      set -e; T=$(mktemp -d); npm pack --pack-destination "$T" >/dev/null 2>&1
      tar xzf "$T"/*.tgz -C "$T"; (cd "$T/package" && npm install --omit=dev --silent >/dev/null 2>&1)
      # Executing every declared bin from the PACKED tarball is the only thing that sees what a consumer
      # receives: 0.29.0 and 0.29.1 both shipped two bins that died on a file `files` omitted.
      #
      # THE ASSERTION IS "IT LOADS", NOT "IT ANSWERS --version". The first version of this demanded a
      # zero exit from `--version` and reported `bin failed: ./verify.mjs` — but that bin is present,
      # loads, and prints a usage error because it takes verbs rather than that flag. A check that
      # invents a contract the code never made produces a red nobody can act on, which is how a real
      # red later gets waved through. The defect this exists for is ERR_MODULE_NOT_FOUND at startup,
      # so that is what it looks for, on any exit code.
      for b in $(node -e "console.log(Object.values(require(\"$T/package/package.json\").bin).join(\" \"))"); do
        # `|| true`: the block runs under `set -e`, and a bin that prints a usage error exits non-zero
        # by design. Without it the assignment itself killed the step — a non-zero exit is DATA here,
        # not a failure.
        out=$(node "$T/package/${b#./}" --version </dev/null 2>&1) || true
        case "$out" in
          *ERR_MODULE_NOT_FOUND*|*"Cannot find module"*|*ERR_REQUIRE_ESM*)
            echo "bin does not load: $b"; echo "$out" | head -3; exit 1 ;;
        esac
      done; rm -rf "$T"' ) &
  else skipped="$skipped candor-ts(no-node)"; fi
fi

if want candor-java && [ -d "$ROOT/candor-java" ]; then
  cd "$ROOT/candor-java" || exit 2
  ( step candor-java "gradlew test"          ./gradlew test ) &
else :; fi

if want candor-swift && [ -d "$ROOT/candor-swift" ]; then
  if have swift; then
    cd "$ROOT/candor-swift" || exit 2
    ( step candor-swift "swift test"         swift test ) &
  else skipped="$skipped candor-swift(no-swift)"; fi
fi

if want candor-agents && [ -d "$ROOT/candor-agents" ]; then
  if have python3 && [ -f "$ROOT/candor-agents/test.py" ]; then
    cd "$ROOT/candor-agents" || exit 2
    ( step candor-agents "python3 test.py"   python3 test.py ) &
  else skipped="$skipped candor-agents(no-python)"; fi
fi

# THE CHEAP CHECK THAT COSTS A WHOLE ROUND WHEN IT IS SKIPPED. changelog-lag is release-preflight [5b],
# and it runs in about a second — but it lives at PREFLIGHT, so tonight it first spoke after CI had gone
# green, which meant another commit and another ~19-minute round for one paragraph. It answers the same
# question before the push. Advisory here (a pure refactor legitimately needs no entry) but printed
# loudly, because the fix is to write the line in the SAME commit as the source change.
if [ -z "$ONLY" ] && [ -x "$ROOT/candor/bin/changelog-lag.sh" ]; then
  if ! lag="$(bash "$ROOT/candor/bin/changelog-lag.sh" 2>&1)"; then
    printf "  %-14s %-22s ⚠  a changelog describes less than its repo ships\n" "(all)" "changelog-lag"
    printf "%s\n" "$lag" | grep -E "✘|  [0-9a-f]{7} " | head -8 | sed 's/^/      /'
    printf "      Write the entry INTO that commit — at preflight this costs another full CI round.\n"
  else
    printf "  %-14s %-22s ✔\n" "(all)" "changelog-lag"
  fi
fi

wait
sort "$RESULTS"
[ -s "$FAILED" ] && rc=1
echo
[ -n "$skipped" ] && echo "  SKIPPED (toolchain absent, NOT passed):$skipped"
if [ "$rc" -eq 0 ]; then
  echo "verify-local: OK — every step of every engine present passed"
  echo "  This is not a substitute for CI: conformance is four-way and lives in candor-spec"
  echo "  (bash conformance/run.sh), and only CI runs the released-artifact arms."
else
  echo "verify-local: FAILED — see the commands above; each is runnable as printed"
fi
exit "$rc"
