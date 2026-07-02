#!/usr/bin/env bash
# candor init — scaffold the architecture gate in ONE command (the JVM flagship path):
#   1. scan the compiled bytecode           → .candor/report.json (+ callgraph sidecar)
#   2. PROPOSE a starter policy from what your code already does → arch.policy   (via candor-init)
#   3. record a baseline                     → .candor/baseline.json  (the AS-EFF-005 regression ratchet)
#   4. drop the GitHub Action                → .github/workflows/candor.yml
# Then review arch.policy (every proposed rule currently passes) and commit. Existing files are never
# clobbered. Non-JVM projects: see adopt/README for the engine-agnostic flow (scan → candor-init → gate).
#
#   Usage:  candor-init.sh [<classes-dir>]
#   The scanner defaults to `jbang candor@tombaldwin/candor-java`; override with CANDOR_SCAN_CMD
#   (e.g. a pinned jar, or a non-JVM engine like `npx -y candor-ts` for a source tree).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SCAN="${CANDOR_SCAN_CMD:-jbang candor@tombaldwin/candor-java}"

# Locate what to scan: an explicit arg, else the conventional compiled-output dir.
TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  for d in target/classes build/classes/java/main build/classes/kotlin/main; do
    [ -d "$d" ] && { TARGET="$d"; break; }
  done
fi
if [ -z "$TARGET" ] || { [ ! -d "$TARGET" ] && [ ! -f "$TARGET" ]; }; then
  echo "candor init: no scan target found (looked for target/classes, build/classes/java/main)."
  echo "  Build first — Maven: mvn -q compile   ·   Gradle: ./gradlew classes"
  echo "  then re-run, or pass the target explicitly:  candor-init.sh <classes-dir>"
  exit 2
fi
command -v python3 >/dev/null 2>&1 || { echo "candor init: python3 is required for policy inference."; exit 2; }

mkdir -p .candor

# Engine-agnostic report output: candor-java writes a file via `--json <file>`; the scan-source engines
# (ts/scan/swift) write files via `--out <prefix>` and treat `--json` as a STDOUT boolean — passing it a
# filename there silently produces no report (max-review find). Probe the engine's --help for --out.
if $SCAN --help 2>&1 | grep -q -- '--out'; then
  SCAN_ARGS=(--out .candor/report)
else
  SCAN_ARGS=(--json .candor/report.json)
fi

echo "candor init: scanning $TARGET ($SCAN) ..."
if ! $SCAN "$TARGET" "${SCAN_ARGS[@]}" >/dev/null 2>&1; then
  echo "candor init: the scan failed — is the engine installed (jbang / npx)? Run it manually to see why:"
  echo "  $SCAN $TARGET ${SCAN_ARGS[*]}"
  exit 2
fi
# The report filename varies per engine (java: report.json; ts: report.json; swift: report.<pkg>.Swift.json;
# scan: report.<crate>.scan.json) — glob the prefix, drop the callgraph/hierarchy sidecars.
REPORT=$(ls .candor/report*.json 2>/dev/null | grep -vE 'callgraph|hierarchy' | head -1)
if [ -z "$REPORT" ] || [ ! -s "$REPORT" ]; then
  echo "candor init: the scan reported success but produced no report under .candor/report* — run it"
  echo "  manually to see why:  $SCAN $TARGET ${SCAN_ARGS[*]}"
  exit 2
fi

# 2. propose the policy (NEVER clobber a hand-edited one — write the proposal beside it instead).
# A failed proposal STOPS the scaffold (no false "done", no Action dropped that would fail every CI run
# on a policy that doesn't exist — max-review find: failures here were silently ignored).
if [ -f arch.policy ]; then
  python3 "$HERE/candor-init" "$REPORT" --out arch.policy.proposed \
    || { echo "candor init: policy proposal failed — stopping (nothing scaffolded beyond the scan)"; exit 2; }
  POLICY_NOTE="arch.policy already exists — left it; wrote the fresh proposal to arch.policy.proposed"
else
  python3 "$HERE/candor-init" "$REPORT" --out arch.policy \
    || { echo "candor init: policy proposal failed — stopping (nothing scaffolded beyond the scan)"; exit 2; }
  POLICY_NOTE="arch.policy  ← REVIEW THIS (proposed from your code; every rule currently passes)"
fi

# 3. the regression-ratchet baseline — NEVER clobbered on a re-run: overwriting it would silently
# grandfather every effect gained since adoption (the AS-EFF-005 ratchet reset, max-review find).
if [ -f .candor/baseline.json ]; then
  BASELINE_NOTE=".candor/baseline.json already exists — left it (refresh deliberately: cp $REPORT .candor/baseline.json)"
else
  cp "$REPORT" .candor/baseline.json \
    || { echo "candor init: could not record the baseline — stopping"; exit 2; }
  BASELINE_NOTE=".candor/baseline.json   ← the regression ratchet baseline"
fi

# 3b. vendor the SARIF reporter beside the baseline (never clobber) — the Action prefers this copy over
# a curl of the umbrella repo's unpinned main, so a breaking upstream push can't affect this repo's CI.
if [ ! -f .candor/candor-sarif ] && [ -f "$HERE/../integrations/github/candor-sarif" ]; then
  cp "$HERE/../integrations/github/candor-sarif" .candor/candor-sarif
fi

# 4. drop the GitHub Action (never clobber).
mkdir -p .github/workflows
if [ -f .github/workflows/candor.yml ]; then
  ACTION_NOTE=".github/workflows/candor.yml already exists — left it"
else
  cp "$HERE/candor.yml" .github/workflows/candor.yml
  ACTION_NOTE=".github/workflows/candor.yml  ← the PR gate (edit the build + CLASSES/SRC lines)"
fi

echo
echo "candor init: done. Scaffolded:"
echo "  $POLICY_NOTE"
echo "  $BASELINE_NOTE"
echo "  $ACTION_NOTE"
echo
echo "Next: review arch.policy, keep the rules you want, then commit. Check it locally:"
echo "  $SCAN $TARGET --policy arch.policy   # exit 1 on a violation"
