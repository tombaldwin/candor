#!/bin/bash
# mkpool.sh SRC DST — build a LIVE swift release-bar pool (R1562).
# Copies the swift-t4 corpus (SRC, read-only) to DST and, for every entry, symlinks the TRANSITIVE closure of its
# in-pool dependencies (graph.py: Package.swift `url:` basenames naming a sibling) into DST/<entry>/.build/checkouts,
# so candor-swift can map module -> package and a CANDOR_DEPS chain actually JOINS.  Without that directory the
# chained arm is byte-identical to the standalone one (SOUNDNESS R700) — which is what R1562 found the old pool was.
# Idempotent: refuses if DST exists.  Prints one line per entry: name, closure size, symlinks made.
set -euo pipefail
SRC=${1:?SRC}; DST=${2:?DST}
TOOLS=$(cd "$(dirname "$0")" && pwd)
[ -e "$DST" ] && { echo "mkpool: $DST exists; refusing" >&2; exit 2; }
mkdir -p "$DST"
for e in "$SRC"/*/; do
  n=$(basename "$e")
  cp -R "$e" "$DST/$n"
  rm -rf "$DST/$n/.build"          # stale build dirs from the source corpus carry no checkouts
done
python3 -I - "$TOOLS" "$DST" <<'PY'
import os, sys
sys.path.insert(0, sys.argv[1]); import graph as G
pool = sys.argv[2]; g = G.graph(pool); total = 0
for n in sorted(g):
    cl = G.closure(g, n)
    co = os.path.join(pool, n, '.build', 'checkouts'); os.makedirs(co, exist_ok=True)
    for d in cl:
        os.symlink(os.path.join(pool, d), os.path.join(co, d)); total += 1
    print('%-32s closure=%d' % (n, len(cl)))
print('TOTAL symlinks', total)
PY
