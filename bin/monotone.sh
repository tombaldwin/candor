#!/usr/bin/env bash
# monotone.sh — THE MONOTONICITY ORACLE: resolving MORE must never certify MORE.
#
# Scan a package twice, once with `node_modules` absent and once with it installed, and compare the two
# reports FUNCTION BY FUNCTION. Installing dependencies only ever gives the analyzer more information,
# so for every function the second answer must be at least as strict as the first:
#
#   Unknown → a concrete effect      REFINEMENT, fine   (it learned what the call was)
#   Unknown → nothing                VIOLATION          (it learned, and then said "pure")
#   Fs      → nothing                VIOLATION
#   present → ABSENT from the report VIOLATION          (absence means pure)
#
# WHY THIS ORACLE EXISTS. candor-ts's shadow guard asked "is this `fetch` declared in a project file?",
# and for `import { fetch } from "node-fetch-native/proxy"` the declaration is the IMPORT SPECIFIER,
# which lives in the importing file. So with the package INSTALLED the guard called it the project's own
# and withheld Net, while with the package ABSENT the unresolved call honestly read Unknown. `deny Net`
# certified an exfiltrating POST — and only in the better-informed run. A per-package effect count would
# not have seen it; the comparison is what makes it visible.
#
# The direction is the whole point: this oracle does NOT flag effects that APPEAR when deps are
# installed. That is the analysis working.
#
# DO NOT "REDUCE THE NOISE" BY SKIPPING `no-node_modules:<pkg>`. That is the obvious optimisation — most
# false positives carry it (globby's `expectType` from tsd, consola's `string-width`, all legitimate
# refinements to genuinely pure helpers). The `fetch` cardinal sin carried THE SAME MARKER:
#     before: exfil ['Unknown'] unknownWhy ['no-node_modules:node-fetch-native']
#     after:  exfil []                                    ← the silent certification
# Signal and noise are indistinguishable by that field. The instrument NARROWS the search — a handful of
# functions out of thousands — and a human traces each one. Three of its first four hits were true
# negatives, and the fourth was `require.resolve`.
#
# USAGE
#   bash bin/monotone.sh <ts-package-dir>...     # installs deps in each (--ignore-scripts), restores after
set -uo pipefail
S="${MONOTONE_WORK:-${TMPDIR:-/tmp}/candor-monotone}"; mkdir -p "$S/mono-out"
TS="${CANDOR_TS:-/Users/tom/git/candor-ts}/scan.mjs"
findings=0; checked=0
finding() { echo "  FINDING: $*"; findings=$((findings+1)); }

for dir in "$@"; do
  [ -d "$dir" ] || continue
  n="$(basename "$dir")"
  [ -f "$dir/package.json" ] || { echo "  skip $n (no package.json)"; continue; }

  # BEFORE: no node_modules.
  [ -d "$dir/node_modules" ] && mv "$dir/node_modules" "$dir/.nm-parked"
  node "$TS" "$dir" --out "$S/mono-out/$n.before" >/dev/null 2>&1

  # AFTER: install and re-scan. --ignore-scripts: a corpus round must not run a package's install hooks.
  (cd "$dir" && npm install --no-fund --no-audit --ignore-scripts >/dev/null 2>&1)
  node "$TS" "$dir" --out "$S/mono-out/$n.after" >/dev/null 2>&1
  [ -d "$dir/.nm-parked" ] && { rm -rf "$dir/node_modules"; mv "$dir/.nm-parked" "$dir/node_modules"; }

  checked=$((checked+1))
  python3 - "$n" "$S/mono-out/$n.before.json" "$S/mono-out/$n.after.json" <<'PY' || findings=$((findings+1))
import json, sys
name, bp, ap = sys.argv[1], sys.argv[2], sys.argv[3]
def load(p):
    try: d = json.load(open(p))
    except Exception: return None
    return {f["fn"]: set((f.get("inferred") or [])) for f in (d.get("functions") or [])}
b, a = load(bp), load(ap)
if b is None or a is None:
    print(f"  ok   {name}: one side produced no report (a JS-only tree refuses; nothing to compare)"); sys.exit(0)
bad = []
for fn, before in b.items():
    after = a.get(fn)
    if after is None:
        # PRESENT-WITH-NO-EFFECTS and ABSENT both mean pure, so that transition is not a weakening.
        # The unchained run lists such a function precisely BECAUSE its package was uncovered (the
        # coverage ledger discloses it); once the dep resolves and it is genuinely pure, it is omitted.
        # Flagging it cost this oracle a false positive on its first dep-chaining run.
        if before:
            bad.append(f"{fn}: {sorted(before)} -> ABSENT (absence means PURE)")
    elif before and not after:
        bad.append(f"{fn}: {sorted(before)} -> {{}} (all effects dropped)")
    elif "Unknown" in before and not after:
        bad.append(f"{fn}: Unknown -> nothing")
for line in bad[:6]:
    print(f"  FINDING: {name}: {line}")
if bad:
    print(f"  FINDING: {name}: {len(bad)} function(s) got WEAKER when dependencies resolved"); sys.exit(1)
print(f"  ok   {name}: {len(b)} fn(s) before, {len(a)} after — nothing weakened")
PY
done
echo
[ "$findings" = 0 ] && echo "monotonicity: OK — $checked package(s), nothing weakened by resolving" \
                    || echo "monotonicity: $findings FINDING(S)"
