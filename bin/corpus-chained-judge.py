#!/usr/bin/env python3
"""corpus-chained-judge.py — read the two arms of the CHAINED census.  SOUNDNESS R668 / R671.

Two jobs `bin/corpus-ab.py` deliberately does not do:

  1. ABSENT IS NOT PURE.  corpus-ab diffs ROWS, so a consumer row that never appears in either arm is
     invisible to it — and a generated consumer's probe is exactly the place where a missing row is a
     POSITIVE PURITY CLAIM about a function the engine was asked about.  SOUNDNESS R636 is this trap
     one repo over: PART 92's `judge()` renders a missing entry as `eff=∅, unknown=False` and two arms
     pass unconditionally on it.  So every generated probe is accounted for in FOUR states, with
     ABSENT in its own column, never folded into pure.

  2. THE SCOPE COLLAPSE.  A `deny Net <function>` gate and a `deny Net com.acme` gate see different
     amounts of the same movement, and R664/R665 measured that the second sees almost none of it.
     The table here is the same arithmetic as the standalone census's, so the two are comparable:
       function  a probe qual that gains any concrete effect
       class     a (entry, enclosing class) that gains any concrete effect
       package   summed NEW (package, effect) pairs, package by longest declared prefix
       artifact  NEW (entry, effect) pairs
"""
import collections
import glob
import json
import os
import sys

SIDE = (".callgraph.json", ".hierarchy.json", ".locs.json")


def load_arm(d):
    out = {}
    for f in sorted(glob.glob(os.path.join(d, "*.json"))):
        if f.endswith(SIDE):
            continue
        try:
            out[os.path.basename(f)[:-5]] = json.load(open(f))
        except (OSError, ValueError) as e:
            print("  UNREADABLE %s: %s" % (f, e))
    return out


def pkg_of(fn, pkgs):
    best = ""
    for p in pkgs:
        if fn.startswith(p + ".") and len(p) > len(best):
            best = p
    return best or "(default)"


def index(doc):
    """(effects by fn, effects by package, effects at entry, set of fn quals present)."""
    pkgs = doc.get("packages") or []
    byfn = collections.defaultdict(set)
    bypkg = collections.defaultdict(set)
    byent = set()
    present = set()
    for r in doc.get("functions", []):
        fn = r.get("fn")
        present.add(fn)
        if r.get("interfaceUnion"):
            continue          # C1: filtered at every gate's ingress, so it moves no verdict
        eff = {e for e in (r.get("inferred") or []) if e != "Unknown"}
        if not eff:
            continue
        byfn[fn] |= eff
        bypkg[pkg_of(fn, pkgs)] |= eff
        byent |= eff
    return byfn, bypkg, byent, present


def coverage(work, entries):
    tot = collections.Counter()
    skips = collections.Counter()
    missing = []
    n = 0
    for jar in open(entries):
        jar = jar.strip()
        if not jar:
            continue
        n += 1
        name = os.path.basename(jar)[:-4] if jar.endswith(".jar") else os.path.basename(jar)
        mf = os.path.join(work, "c", name, "manifest.json")
        if not os.path.exists(mf):
            missing.append(name)
            continue
        d = json.load(open(mf))
        tot["entries_with_consumer"] += 1
        for k in ("classes_in_jar", "probe_types", "probe_files", "dispatch_probes",
                  "field_probes", "call_lines"):
            tot[k] += d.get(k, 0)
        for k, v in (d.get("skips") or {}).items():
            skips[k] += v
        cls = glob.glob(os.path.join(work, "c", name, "cls", "**", "*.class"), recursive=True)
        tot["class_files"] += len(cls)
        rec = os.path.join(work, "c", name, "recovery.txt")
        if os.path.exists(rec):
            for ln in open(rec):
                p = ln.split()
                if len(p) >= 7:
                    tot["javac_lines_dropped"] += int(p[2])
                    tot["javac_files_dropped"] += int(p[5])
    print("== consumer BUILD coverage (%d entries)" % n)
    for k in ("entries_with_consumer", "classes_in_jar", "probe_types", "probe_files",
              "class_files", "dispatch_probes", "field_probes", "call_lines",
              "javac_lines_dropped", "javac_files_dropped"):
        print("   %-24s %d" % (k, tot[k]))
    if missing:
        print("   NO CONSUMER for %d entr(ies): %s" % (len(missing), ", ".join(missing[:12])))
    print("   generator skips (a skip is a probe NOT written; it is not a clean result):")
    for k, v in sorted(skips.items(), key=lambda kv: -kv[1]):
        print("      %-62s %d" % (k[:62], v))
    return tot


def report(out, work, entries):
    pre_d, post_d = os.path.join(out, "rep-pre"), os.path.join(out, "rep-post")
    PRE, POST = load_arm(pre_d), load_arm(post_d)
    names = sorted(set(PRE) & set(POST))
    if not names:
        print("corpus-chained-judge: NO ENTRY has both arms — nothing to compare.")
        return 3

    # ── probe accounting, ABSENT in its own column ────────────────────────────────────────────────
    move = collections.Counter()
    per_entry_moved = []
    fnflip = clsflip = pkgflip = entflip = 0
    fnlost = 0
    analyzed = 0
    probes_total = 0
    reach_rows = 0
    lost_detail, gain_detail, unk_detail = [], [], []

    for name in names:
        a, b = PRE[name], POST[name]
        ia, ib = index(a), index(b)
        analyzed += (b.get("analyzed") or {}).get("count") or 0
        mf = os.path.join(work, "c", name, "manifest.json")
        quals = list((json.load(open(mf)).get("quals") or {}).keys()) if os.path.exists(mf) else []
        probes_total += len(quals)

        pre_unk = {r.get("fn") for r in a.get("functions", [])
                   if "Unknown" in (r.get("inferred") or []) and not r.get("interfaceUnion")}
        post_unk = {r.get("fn") for r in b.get("functions", [])
                    if "Unknown" in (r.get("inferred") or []) and not r.get("interfaceUnion")}

        def st(idx, unk, q):
            byfn, _p, _e, present = idx
            if q not in present:
                return "ABSENT"
            if byfn.get(q):
                return "CONCRETE"
            return "UNKNOWN" if q in unk else "PURE"

        for q in quals:
            sa, sb = st(ia, pre_unk, q), st(ib, post_unk, q)
            move[(sa, sb)] += 1
            if sa != "ABSENT" or sb != "ABSENT":
                reach_rows += 1
            if sa in ("ABSENT", "PURE") and sb == "UNKNOWN":
                unk_detail.append((name, q))

        # ── the scope table, over EVERY consumer row (not just probe quals) ───────────────────────
        f = 0
        cls_new = set()
        for fn, eff in ib[0].items():
            new = eff - ia[0].get(fn, set())
            if new:
                f += 1
                cls_new.add(fn.rsplit(".", 1)[0])
                gain_detail.append((name, fn, sorted(new)))
        lost = 0
        for fn, eff in ia[0].items():
            gone = eff - ib[0].get(fn, set())
            if gone:
                lost += 1
                lost_detail.append((name, fn, sorted(gone)))
        p = sum(len(eff - ia[1].get(pk, set())) for pk, eff in ib[1].items())
        e = len(ib[2] - ia[2])
        fnflip += f; clsflip += len(cls_new); pkgflip += p; entflip += e; fnlost += lost
        if f or p or e or lost:
            per_entry_moved.append((name, f, len(cls_new), p, e, lost))

    print("== CHAINED consumer A/B — %d entries with both arms" % len(names))
    print("   analysed units at the CONSUMER (POST, summed analyzed.count): %d" % analyzed)
    print()
    print("== generated probes: PRE state -> POST state   (ABSENT is its own column, never 'pure')")
    print("   %d probe quals over %d entries; %d of them produced a row in at least one arm (REACH)"
          % (probes_total, len(names), reach_rows))
    order = ["ABSENT", "PURE", "UNKNOWN", "CONCRETE"]
    print("   %-10s %s" % ("PRE\\POST", "".join("%12s" % o for o in order)))
    for sa in order:
        print("   %-10s %s" % (sa, "".join("%12d" % move.get((sa, sb), 0) for sb in order)))
    changed = sum(v for (x, y), v in move.items() if x != y)
    print("   probes whose state CHANGED: %d" % changed)
    print("   probes that were ABSENT in BOTH arms: %d  (the engine made a positive purity claim"
          % move.get(("ABSENT", "ABSENT"), 0))
    print("      about a function it was handed, in both arms — not a pass, and not movement)")
    print()
    print("== scope sensitivity at the CONSUMER (newly-red, PRE -> POST)")
    print("   FUNCTION  probe/consumer quals gaining a concrete effect : %d%s"
          % (fnflip, "   (%.4f%% of %d analysed)" % (100.0 * fnflip / analyzed, analyzed) if analyzed else ""))
    print("   CLASS     distinct (entry, class) gaining an effect      : %d%s" % (clsflip,
          "   [DEGENERATE BY CONSTRUCTION: the generator emits one probe METHOD per probe CLASS,"
          " so class scope cannot differ from function scope here.  Package and artifact are the"
          " informative rungs.]" if clsflip == fnflip else ""))
    print("   PACKAGE   new (package, effect) pairs                    : %d" % pkgflip)
    print("   ARTIFACT  new (entry, effect) pairs                      : %d" % entflip)
    print("   LOST      quals losing a concrete effect (expect ~0)     : %d" % fnlost)
    print("   entries with any movement: %d of %d" % (len(per_entry_moved), len(names)))
    for row in sorted(per_entry_moved, key=lambda x: -x[1])[:20]:
        print("      %-44s fn=%-5d cls=%-4d pkg=%-3d jar=%d lost=%d" % row)
    if lost_detail:
        print("   LOST detail (every one, no sampling — E1: the removals are the claim under test):")
        for row in lost_detail[:60]:
            print("      %-38s %-58s %s" % row)
    json.dump({"entries": len(names), "analyzed": analyzed, "probes": probes_total,
               "reach_rows": reach_rows,
               "move": {"%s->%s" % k: v for k, v in move.items()},
               "scope": {"function": fnflip, "class": clsflip, "package": pkgflip,
                         "artifact": entflip, "lost": fnlost},
               "per_entry": per_entry_moved, "lost_detail": lost_detail,
               "unk_detail": unk_detail,
               "gain_detail": gain_detail[:5000]},
              open(os.path.join(out, "judge.json"), "w"), indent=1)
    return 0


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "--coverage":
        coverage(sys.argv[2], sys.argv[3]); sys.exit(0)
    if len(sys.argv) >= 2 and sys.argv[1] == "--report":
        sys.exit(report(sys.argv[2], sys.argv[3], sys.argv[4]))
    print(__doc__)
    sys.exit(2)
