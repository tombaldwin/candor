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

THE RUST HALF (`--coverage-rs` / `--report-rs`, SOUNDNESS R673(a)) answers the same two questions for
`bin/corpus-chained-rs.sh`.  It is a SECOND SCOPE LADDER, not a second judge: the probe accounting, the
ABSENT column and the lost-effect audit are the same code.  Only the scope rungs differ, because a rust
report has no `packages` key and a rust qual is a `::` path:

       function  the whole qual
       parent    the qual minus its last segment       (R664's "parent type or module")
       module    the qual's FIRST segment              (R664's "top-level module")
       crate     NEW (entry, effect) pairs

A rust consumer report also REPUBLISHES rows it read off the wire — `tower_service#Service::call` shows
up in a consumer's own report.  Those are not the consumer's units, so a row is counted only when its
`hash` names the report's own package, and the count of rows dropped by that rule is printed rather than
assumed to be zero.

THE SWIFT HALF (`--report-swift` / `--live-swift`, swift L0, 2026-11-25) answers ONE question and no other: did the
chain JOIN?  A swift consumer is scanned twice by the SAME engine, unchained and chained (`CANDOR_DEPS` naming the
reports of its in-pool dependencies, `bin/corpus-chained-swift/chain.py`), and the join is LIVE for an entry only
if the chained report DIFFERS from the unchained one: a row's `inferred`, `invisible` or `unknownWhy`, or a row
present in one arm only.  Liveness is a COUNT of rows, never the absence of a symptom: R700 measured a chained arm
byte-identical to the standalone one (no `.build/checkouts`, so no module -> package map) and R1523 one that
imported module `Algorithms` against a report whose package is `swift-algorithms`.  Both print a clean 0/0/0 exactly
like a safe change.  An entry whose pool dependency closure is EMPTY is NO-DEPS (chained == unchained by
construction): neither live nor dead.  An entry WITH dependencies whose count is 0 is DEAD-JOIN and is excluded and
LISTED; no live entry at all is `NOT A MEASUREMENT` (rc 3).  An entry that is live but still lists a chained
dependency in its own uncovered ledger is PARTIAL (listed, kept: some dependency joined and another did not).
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



# ── JOIN LIVENESS.  A chained arm whose join did not happen is NOT A MEASUREMENT. ────────────────
# Measured 2026-11-08 (swift, R1523): a "real producer chained" arm was INERT. The consumer imported
# `Algorithms` against a report whose package is `swift-algorithms`, so nothing joined, both arms read
# the library as uncovered, and a comparison of two identically-blind arms prints a clean 0/0/0 exactly
# like a safe change. The tell was the consumer report itself: the LIBRARY'S OWN NAME sat in the
# consumer's `invisible` / `coverage.uncovered` ledger, i.e. the engine said "I could not see it".
#
# So before any cell is read, each entry's two consumer reports are asked: does either name the
# library being chained as uncovered?  If yes the entry is DEAD-JOIN: it is excluded and LISTED, and when
# no entry is live the whole run returns 3 and says NOT A MEASUREMENT.  `lib_names(...)` gives the names
# to look for: java = the library packages the generated probes mirror (`candorgen.<pkg>.<Class>.<m>`);
# rust = the crate name from the entry directory, version suffix stripped, `-` read as `_`.
def uncovered_names(doc):
    out = set()
    for u in ((doc.get("coverage") or {}).get("uncovered") or []):
        out.add(u.get("name") if isinstance(u, dict) else u)
    for r in doc.get("functions", []):
        out.update(r.get("invisible") or [])
    return {n for n in out if n}


def _norm(n):
    return (n or "").replace("-", "_").lower()


def java_lib_names(quals):
    pk = set()
    for q in quals:
        parts = q.split(".")
        if len(parts) >= 4 and parts[0] == "candorgen":
            pk.add(".".join(parts[1:-2]))
    return pk


def rust_lib_names(entry):
    import re
    base = re.sub(r"-[0-9][0-9A-Za-z.+_-]*$", "", entry)
    return {_norm(base)}


def dead_join(doc, libs, rust=False):
    """the library names this consumer report lists as UNCOVERED (sorted); empty means the join is live."""
    hit = set()
    for n in uncovered_names(doc):
        for l in libs:
            if rust:
                if _norm(n) == l:
                    hit.add(n)
            elif n == l or l.startswith(n + ".") or n.startswith(l + "."):
                hit.add(n)
    return sorted(hit)


def split_live(PRE, POST, names, libs_of, rust=False):
    """-> (live names, {dead name: {arm: [uncovered library names]}}) — and the printed accounting."""
    live, dead = [], {}
    for n in names:
        libs = libs_of(n)
        d = {}
        for arm, doc in (("pre", PRE[n]), ("post", POST[n])):
            h = dead_join(doc, libs, rust)
            if h:
                d[arm] = h
        (dead.__setitem__(n, d) if d else live.append(n))
    if dead:
        print("== JOIN LIVENESS: %d of %d entries are DEAD-JOIN (the consumer's own ledger lists the chained" % (len(dead), len(names)))
        print("   library as UNCOVERED, so the chain never joined) — excluded; their cells are NOT A MEASUREMENT:")
        for n, d in sorted(dead.items())[:40]:
            print("      %-44s %s" % (n, "; ".join("%s: invisible/uncovered=%s" % (a, ",".join(v)) for a, v in sorted(d.items()))))
        print()
    return live, dead


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
        name = entry_name(jar)
        name = name[:-4] if name.endswith(".jar") else name
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
    def LIBS(n):
        mf = os.path.join(work, "c", n, "manifest.json")
        try:
            return java_lib_names(list((json.load(open(mf)).get("quals") or {}).keys()))
        except (OSError, ValueError):
            return set()
    RUST = False
    live, dead = split_live(PRE, POST, names, LIBS, RUST)
    if not live:
        print("corpus-chained-judge: NOT A MEASUREMENT — no entry's chain JOINED (%d of %d dead-join)." % (len(dead), len(names)))
        print("  Both arms read the library as uncovered, so identical arms say nothing about the engine.")
        print("  Fix the join (the consumer must name the dependency as the report's package does) and re-run.")
        return 3
    names = live

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
    json.dump({"dead_join": {k: v for k, v in dead.items()}, "entries": len(names), "analyzed": analyzed, "probes": probes_total,
               "reach_rows": reach_rows,
               "move": {"%s->%s" % k: v for k, v in move.items()},
               "scope": {"function": fnflip, "class": clsflip, "package": pkgflip,
                         "artifact": entflip, "lost": fnlost},
               "per_entry": per_entry_moved, "lost_detail": lost_detail,
               "unk_detail": unk_detail,
               "gain_detail": gain_detail[:5000]},
              open(os.path.join(out, "judge.json"), "w"), indent=1)
    return 0


# ── THE RUST LADDER ───────────────────────────────────────────────────────────────────────────────
def rs_index(doc):
    """(effects by fn, effects by parent, effects by top-level segment, effects at entry, present,
    foreign_rows_dropped)."""
    pkg = doc.get("package") or ""
    byfn = collections.defaultdict(set)
    bypar = collections.defaultdict(set)
    bymod = collections.defaultdict(set)
    byent = set()
    present = set()
    foreign = 0
    for r in doc.get("functions", []):
        fn = r.get("fn")
        if r.get("interfaceUnion"):
            continue          # C1/R660: filtered at every gate's ingress, so it moves no verdict
        h = r.get("hash") or ""
        if h and pkg and not h.startswith(pkg + "#"):
            # A row the consumer read off the wire and republished.  Not a unit of this crate, so not
            # a thing any policy scoped to this crate addresses.
            foreign += 1
            continue
        present.add(fn)
        eff = {e for e in (r.get("inferred") or []) if e != "Unknown"}
        if not eff:
            continue
        segs = (fn or "").split("::")
        byfn[fn] |= eff
        bypar["::".join(segs[:-1]) or "(crate)"] |= eff
        bymod[segs[0] if len(segs) > 1 else "(crate)"] |= eff
        byent |= eff
    return byfn, bypar, bymod, byent, present, foreign


def entry_name(path):
    """An entry's name as the shell generators spell it (`basename`, which ignores trailing slashes).

    `os.path.basename("/a/b/")` is `''`, NOT `b`: an entries file whose lines end in `/` made this judge look up
    `gen/.noimpl.json`, find nothing, and count ZERO probe quals while the generator had written 135 (measured
    on the R1754 lane's workdir, 2026-11-14).  Strip the slashes first; every Python reader of an entry path
    goes through here or does `rstrip("/")` itself."""
    return os.path.basename((path or "").strip().rstrip("/"))


def rs_manifests(work, entries, variant):
    """probe quals per entry name, from the generator's own manifest (empty for `standalone`)."""
    out = {}
    for line in open(entries):
        entry = line.split("\t")[0].strip()
        if not entry:
            continue
        name = entry_name(entry)
        mf = os.path.join(work, "gen", "%s.%s.json" % (name, variant))
        if variant in ("noimpl", "impl") and os.path.exists(mf):
            try:
                out[name] = json.load(open(mf))
            except ValueError:
                out[name] = {}
        else:
            out[name] = {}
    return out


def coverage_rs(work, entries):
    tot = collections.Counter()
    skips = collections.Counter()
    n = 0
    for variant in ("noimpl", "impl"):
        mans = rs_manifests(work, entries, variant)
        for name, d in mans.items():
            if not d:
                continue
            tot["consumers_%s" % variant] += 1
            tot["probes_%s" % variant] += d.get("probes", 0)
            tot["probes_before_cap_%s" % variant] += d.get("probes_before_cap", 0)
            tot["modules_%s" % variant] += d.get("consumer_modules", 0)
            tot["implementors_%s" % variant] += d.get("implementors", 0)
            if variant == "noimpl":
                for k in ("public_traits", "public_fns", "public_inherent"):
                    tot[k] += d.get(k, 0)
                for k, v in (d.get("skips") or {}).items():
                    skips[k] += v
    for line in open(entries):
        if line.strip():
            n += 1
    print("== consumer BUILD coverage, rust (%d entries)" % n)
    for k in sorted(tot):
        print("   %-28s %d" % (k, tot[k]))
    print("   generator skips (a skip is a probe NOT written; it is not a clean result):")
    for k, v in sorted(skips.items(), key=lambda kv: -kv[1]):
        print("      %-70s %d" % (k[:70], v))
    return tot


def report_rs(out, work, entries, variant):
    pre_d, post_d = os.path.join(out, "rep-pre"), os.path.join(out, "rep-post")
    PRE, POST = load_arm(pre_d), load_arm(post_d)
    names = sorted(set(PRE) & set(POST))
    if not names:
        print("corpus-chained-judge: NO ENTRY has both arms — nothing to compare.")
        return 3
    mans = rs_manifests(work, entries, variant)
    # A VACUOUS PROBE TABLE IS NOT A MEASUREMENT.  The generator declared probes but this judge read no qual:
    # every cell below would be a 0/0 that looks exactly like a change with no effect (the trailing-slash defect).
    declared = sum(d.get("probes", 0) for d in mans.values() if d)
    read = sum(len(d.get("quals") or {}) for d in mans.values() if d)
    if declared > 0 and read == 0:
        print("corpus-chained-judge: NOT A MEASUREMENT — the manifests declare %d probe(s) but 0 probe quals were read." % declared)
        print("  The judge's entry-name lookup or the manifest `quals` key is broken; every probe cell would read 0.")
        return 3
    LIBS = rust_lib_names
    RUST = True
    dead = {}
    if variant != "standalone":   # a standalone scan chains nothing, so there is no join to be dead
        live, dead = split_live(PRE, POST, names, LIBS, RUST)
        if not live:
            print("corpus-chained-judge: NOT A MEASUREMENT — no entry's chain JOINED (%d of %d dead-join)." % (len(dead), len(names)))
            print("  Both arms read the library as uncovered, so identical arms say nothing about the engine.")
            print("  Fix the join (the consumer must name the dependency as the report's package does) and re-run.")
            return 3
        names = live

    move = collections.Counter()
    per_entry_moved = []
    fnflip = parflip = modflip = entflip = 0
    fnlost = 0
    analyzed = 0
    probes_total = 0
    reach_rows = 0
    foreign_dropped = 0
    lost_detail, gain_detail, unk_detail = [], [], []

    for name in names:
        a, b = PRE[name], POST[name]
        ia, ib = rs_index(a), rs_index(b)
        foreign_dropped += ia[5] + ib[5]
        analyzed += (b.get("analyzed") or {}).get("count") or 0
        quals = list((mans.get(name, {}).get("quals") or {}).keys())
        probes_total += len(quals)

        def unk(doc):
            pkg = doc.get("package") or ""
            return {r.get("fn") for r in doc.get("functions", [])
                    if "Unknown" in (r.get("inferred") or []) and not r.get("interfaceUnion")
                    and (not r.get("hash") or not pkg or (r.get("hash") or "").startswith(pkg + "#"))}
        pre_unk, post_unk = unk(a), unk(b)

        def st(idx, u, q):
            byfn, _p, _m, _e, present, _f = idx
            if q not in present:
                return "ABSENT"
            if byfn.get(q):
                return "CONCRETE"
            return "UNKNOWN" if q in u else "PURE"

        for q in quals:
            sa, sb = st(ia, pre_unk, q), st(ib, post_unk, q)
            move[(sa, sb)] += 1
            if sa != "ABSENT" or sb != "ABSENT":
                reach_rows += 1
            if sa in ("ABSENT", "PURE") and sb == "UNKNOWN":
                unk_detail.append((name, q))

        f = 0
        for fn, eff in ib[0].items():
            new = eff - ia[0].get(fn, set())
            if new:
                f += 1
                gain_detail.append((name, fn, sorted(new)))
        lost = 0
        for fn, eff in ia[0].items():
            gone = eff - ib[0].get(fn, set())
            if gone:
                lost += 1
                lost_detail.append((name, fn, sorted(gone)))
        pa = sum(len(eff - ia[1].get(k, set())) for k, eff in ib[1].items())
        mo = sum(len(eff - ia[2].get(k, set())) for k, eff in ib[2].items())
        e = len(ib[3] - ia[3])
        fnflip += f; parflip += pa; modflip += mo; entflip += e; fnlost += lost
        if f or pa or mo or e or lost:
            per_entry_moved.append((name, f, pa, mo, e, lost))

    label = {"noimpl": "CHAINED consumer (no implementor supplied)",
             "impl": "CHAINED consumer (an effectful implementor of every public trait)",
             "standalone": "STANDALONE library scan"}.get(variant, variant)
    print("== %s — rust, %d entries with both arms" % (label, len(names)))
    print("   analysed units (POST, summed analyzed.count): %d" % analyzed)
    print("   rows dropped as REPUBLISHED-FROM-THE-WIRE (hash names another package): %d" % foreign_dropped)
    print()
    if variant != "standalone":
        print("== generated probes: PRE state -> POST state   (ABSENT is its own column, never 'pure')")
        print("   %d probe quals over %d entries; %d produced a row in at least one arm (REACH)"
              % (probes_total, len(names), reach_rows))
        order = ["ABSENT", "PURE", "UNKNOWN", "CONCRETE"]
        print("   %-10s %s" % ("PRE\\POST", "".join("%12s" % o for o in order)))
        for sa in order:
            print("   %-10s %s" % (sa, "".join("%12d" % move.get((sa, sb), 0) for sb in order)))
        changed = sum(v for (x, y), v in move.items() if x != y)
        print("   probes whose state CHANGED: %d" % changed)
        print("   probes ABSENT in BOTH arms: %d  (a positive purity claim about a function the engine"
              % move.get(("ABSENT", "ABSENT"), 0))
        print("      was handed, in both arms — not a pass, and not movement)")
        print()
    print("== scope sensitivity (newly-red, PRE -> POST)")
    pct = (lambda v: "   (%.4f%% of %d analysed)" % (100.0 * v / analyzed, analyzed)) if analyzed else (lambda v: "")
    print("   FUNCTION  quals gaining a concrete effect          : %d%s" % (fnflip, pct(fnflip)))
    print("   PARENT    new (qual-minus-last-segment, effect)    : %d" % parflip)
    print("   MODULE    new (top-level segment, effect) pairs    : %d" % modflip)
    print("   CRATE     new (entry, effect) pairs                : %d" % entflip)
    print("   LOST      quals losing a concrete effect (expect ~0): %d" % fnlost)
    print("   entries with any movement: %d of %d" % (len(per_entry_moved), len(names)))
    for row in sorted(per_entry_moved, key=lambda x: -x[1])[:20]:
        print("      %-40s fn=%-5d par=%-4d mod=%-4d crate=%d lost=%d" % row)
    if variant == "impl":
        print("   NOT QUOTABLE AT MODULE OR CRATE SCOPE: this variant plants an effectful implementor in")
        print("      the consumer, so the crate already carries that effect on BOTH arms.  Quote FUNCTION")
        print("      scope and the probe table from this variant; quote scope from `noimpl`.")
    if lost_detail:
        print("   LOST detail (every one, no sampling — E1: the removals are the claim under test):")
        for row in lost_detail[:80]:
            print("      %-34s %-58s %s" % row)
    json.dump({"dead_join": {k: v for k, v in dead.items()}, "variant": variant, "entries": len(names), "analyzed": analyzed,
               "probes": probes_total, "reach_rows": reach_rows,
               "foreign_dropped": foreign_dropped,
               "move": {"%s->%s" % k: v for k, v in move.items()},
               "scope": {"function": fnflip, "parent": parflip, "module": modflip,
                         "crate": entflip, "lost": fnlost},
               "per_entry": per_entry_moved, "lost_detail": lost_detail,
               "unk_detail": unk_detail,
               "gain_detail": gain_detail[:20000]},
              open(os.path.join(out, "judge.json"), "w"), indent=1)
    return 0



# ── THE SWIFT LADDER: JOIN LIVENESS BY COUNT ──────────────────────────────────────────────────────
def _swift_rowkey(r):
    return (tuple(sorted(r.get("inferred") or [])), tuple(sorted(r.get("invisible") or [])),
            tuple(sorted(r.get("unknownWhy") or [])))


def swift_rows_differing(chained, unchained):
    """-> (n, detail): how many rows of the two reports differ.  A row counts when its (inferred, invisible,
    unknownWhy) differs between the arms, or when it exists in exactly one arm.  `interfaceUnion` rows are skipped
    as everywhere else here (C1)."""
    def idx(doc):
        out = {}
        for r in doc.get("functions", []):
            if r.get("interfaceUnion"):
                continue
            out[r.get("fn")] = _swift_rowkey(r)
        return out
    a, b = idx(unchained), idx(chained)
    changed = sorted(k for k in a.keys() & b.keys() if a[k] != b[k])
    only_ch = sorted(b.keys() - a.keys())
    only_un = sorted(a.keys() - b.keys())
    return len(changed) + len(only_ch) + len(only_un), {"changed": changed, "only_chained": only_ch, "only_unchained": only_un}


def swift_still_uncovered(chained, deps):
    """closure members that the CHAINED consumer still lists as uncovered (normalised: `-` read as `_`, case folded)."""
    un = {_norm(n) for n in uncovered_names(chained)}
    return sorted(d for d in deps if _norm(d) in un)


def swift_liveness(names, CH, UN, closure_of, imports_closure=None):
    """-> (live, partial, dead, nodeps, noimport, counts).  `imports_closure(n)` (optional) says whether the entry's NON-TEST sources
    import any module of its dependency closure: an entry that has a closure but imports none of it (a dev/test-only dependency) has
    nothing to join, so 0 differing rows is the RIGHT answer and it is NO-IMPORT, not DEAD-JOIN.  Without the callback every
    closure entry with 0 rows is DEAD-JOIN (the conservative reading)."""
    live, partial, dead, nodeps, noimport, counts = [], [], [], [], [], {}
    for n in names:
        deps = closure_of(n)
        if n in CH and n in UN:
            c, _d = swift_rows_differing(CH[n], UN[n])
        else:
            c = 0   # no unchained twin was scanned: only legitimate for an entry with no closure
        counts[n] = c
        if not deps:
            nodeps.append(n)
        elif c == 0:
            (noimport if (imports_closure is not None and not imports_closure(n)) else dead).append(n)
        else:
            live.append(n)
            if swift_still_uncovered(CH[n], deps) and any(_norm(d) in {_norm(x) for x in uncovered_names(UN[n])} for d in deps):
                partial.append(n)
    return live, partial, dead, nodeps, noimport, counts


def report_swift(chained_dir, unchained_dir, pool):
    """`--report-swift CH_DIR UN_DIR POOL`: `<entry>.json` per entry in each dir (pool-scan.py writes them; the unchained dir holds
    only entries WITH a closure).  POOL names the entries' Package.swift files so the closure and the imports are known."""
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "corpus-chained-swift"))
    import graph as G
    CH, UN = load_arm(chained_dir), load_arm(unchained_dir)
    names = sorted(CH)
    if not names:
        print("corpus-chained-judge: NO chained report — nothing to compare.")
        return 3
    g = G.graph(pool)
    mods = {}
    def imports_closure(n):
        want = set()
        for d in G.closure(g, n):
            want |= mods.setdefault(d, G.modules(pool, d))
        return bool(want & G.imported(pool, n))
    missing = [n for n in names if G.closure(g, n) and n not in UN]
    live, partial, dead, nodeps, noimport, counts = swift_liveness(names, CH, UN, lambda n: G.closure(g, n), imports_closure)
    live = [n for n in live]
    print("== SWIFT JOIN LIVENESS (by COUNT of rows that differ, chained vs the unchained twin) — %d entries" % len(names))
    print("   LIVE %d   (of which PARTIAL %d)   DEAD-JOIN %d   NO-IMPORT %d   NO-DEPS %d" % (len(live), len(partial), len(dead), len(noimport), len(nodeps)))
    print("   rows differing across the live entries: %d" % sum(counts[n] for n in live))
    for n in live:
        print("      LIVE      %-34s rows differing=%-6d closure=%d%s" % (
            n, counts[n], len(G.closure(g, n)), "  PARTIAL (a chained dependency is still listed uncovered)" if n in partial else ""))
    for n in dead:
        print("      DEAD-JOIN %-34s rows differing=0  closure=%d and its sources IMPORT a closure module — the chain did not join;"
              " NOT A MEASUREMENT for this entry" % (n, len(G.closure(g, n))))
    for n in noimport:
        print("      NO-IMPORT %-34s rows differing=0  closure=%d but its non-test sources import none of it (dev/test-only dependency):"
              " nothing to join, excluded from the live count" % (n, len(G.closure(g, n))))
    if nodeps:
        print("      NO-DEPS   %d entries have no in-pool dependency (chained == unchained by construction): %s"
              % (len(nodeps), ", ".join(nodeps[:12]) + (" ..." if len(nodeps) > 12 else "")))
    if missing:
        print("corpus-chained-judge: NOT A MEASUREMENT — %d entr(ies) have a closure but NO unchained twin report: %s" % (len(missing), ", ".join(missing[:8])))
        return 3
    if not live:
        print("corpus-chained-judge: NOT A MEASUREMENT — no entry's chain JOINED (%d dead-join, %d no-import, %d no-deps)." % (len(dead), len(noimport), len(nodeps)))
        print("  A chained arm that differs from the unchained one in NO row is blind, and identical arms say nothing about the engine.")
        return 3
    return 0


def live_swift(chained_json, unchained_json):
    """`--live-swift CH.json UN.json`: the single-report form the attack-matrix runner uses.  Prints the count and
    returns 0 when it is > 0, 3 (NOT A MEASUREMENT) when it is 0."""
    c, d = swift_rows_differing(json.load(open(chained_json)), json.load(open(unchained_json)))
    print("swift join liveness: %d row(s) differ (changed %d, only-chained %d, only-unchained %d)"
          % (c, len(d["changed"]), len(d["only_chained"]), len(d["only_unchained"])))
    if c == 0:
        print("corpus-chained-judge: NOT A MEASUREMENT — the chained report is row-identical to the unchained one.")
        return 3
    return 0


def selftest():
    """SEEDS for the join-liveness gate: it must FIRE on a dead join and stay QUIET on a live one, java and rust."""
    import tempfile, shutil
    bad = 0
    def check(label, ok):
        nonlocal bad
        print("  %s %s" % ("ok " if ok else "FAIL", label))
        bad += 0 if ok else 1
    def run(fn, *a):
        import io, contextlib
        b = io.StringIO()
        with contextlib.redirect_stdout(b):
            rc = fn(*a)
        return rc, b.getvalue()
    def fnrow(fn, inv=None):
        r = {"fn": fn, "inferred": []}
        if inv: r["invisible"] = inv
        return r
    # java: two entries; `dead` lists its own library package as uncovered in both arms, `live` does not.
    t = tempfile.mkdtemp(prefix="cjudge.")
    try:
        out, work = os.path.join(t, "o"), os.path.join(t, "w")
        for arm in ("rep-pre", "rep-post"):
            os.makedirs(os.path.join(out, arm))
        for ent, inv in (("live-1.0", None), ("dead-1.0", ["org.acme.lib"])):
            q = "candorgen.org.acme.lib.Foo.m"
            os.makedirs(os.path.join(work, "c", ent))
            json.dump({"quals": {q: "x"}}, open(os.path.join(work, "c", ent, "manifest.json"), "w"))
            for arm in ("rep-pre", "rep-post"):
                json.dump({"analyzed": {"count": 1}, "functions": [fnrow(q, inv)],
                           "coverage": {"uncovered": [{"name": n, "calls": 1} for n in (inv or [])]}},
                          open(os.path.join(out, arm, ent + ".json"), "w"))
        ent_file = os.path.join(t, "entries"); open(ent_file, "w").write("live-1.0.jar\ndead-1.0.jar\n")
        rc, txt = run(report, out, work, ent_file)
        check("java: a dead-join entry is listed and excluded, run continues on the live one",
              rc == 0 and "1 of 2 entries are DEAD-JOIN" in txt and "dead-1.0" in txt and "with both arms" in txt and "1 entries with both arms" in txt)
        # every entry dead -> NOT A MEASUREMENT, rc 3
        os.remove(os.path.join(work, "c", "live-1.0", "manifest.json"))
        for arm in ("rep-pre", "rep-post"):
            json.dump({"analyzed": {"count": 1}, "functions": [fnrow("candorgen.org.acme.lib.Foo.m", ["org.acme.lib"])]},
                      open(os.path.join(out, arm, "live-1.0.json"), "w"))
        json.dump({"quals": {"candorgen.org.acme.lib.Foo.m": "x"}}, open(os.path.join(work, "c", "live-1.0", "manifest.json"), "w"))
        rc, txt = run(report, out, work, ent_file)
        check("java: all entries dead -> rc 3 and 'NOT A MEASUREMENT'", rc == 3 and "NOT A MEASUREMENT" in txt)
    finally:
        shutil.rmtree(t, ignore_errors=True)
    # rust: crate name from the entry dir, `-` read as `_`; the swift-shaped mismatch is exactly this tell.
    check("rust: library name uncovered in the consumer ledger -> dead",
          dead_join({"coverage": {"uncovered": [{"name": "swift_algorithms"}]}}, rust_lib_names("swift-algorithms-1.2.0"), True) == ["swift_algorithms"])
    check("rust: an unrelated uncovered package leaves the join live",
          dead_join({"coverage": {"uncovered": [{"name": "libc"}]}, "functions": [fnrow("a::b", ["libc"])]}, rust_lib_names("serde-1.0.1"), True) == [])
    check("java: an unrelated uncovered package leaves the join live",
          dead_join({"functions": [fnrow("x", ["java.sql"])]}, {"org.acme.lib"}) == [])
    # rust: the trailing-slash entries file (the R1754 defect).  FAILS on the old `os.path.basename(entry)`.
    t = tempfile.mkdtemp(prefix="cjudge.")
    try:
        os.makedirs(os.path.join(t, "w", "gen"))
        json.dump({"probes": 2, "quals": {"a::b": "x", "a::c": "x"}},
                  open(os.path.join(t, "w", "gen", "foo-1.0.noimpl.json"), "w"))
        ef = os.path.join(t, "entries")
        open(ef, "w").write("/x/y/foo-1.0/\n")
        m = rs_manifests(os.path.join(t, "w"), ef, "noimpl")
        check("rust: an entry path ending in '/' still finds its manifest (old code: {'': 0})",
              list(m) == ["foo-1.0"] and len(m["foo-1.0"].get("quals", {})) == 2)
        # vacuous table -> refusal: probes>0 declared, quals empty
        json.dump({"probes": 3, "quals": {}}, open(os.path.join(t, "w", "gen", "foo-1.0.noimpl.json"), "w"))
        for arm in ("rep-pre", "rep-post"):
            os.makedirs(os.path.join(t, "o", arm))
            json.dump({"analyzed": {"count": 1}, "functions": []}, open(os.path.join(t, "o", arm, "foo-1.0.json"), "w"))
        rc, txt = run(report_rs, os.path.join(t, "o"), os.path.join(t, "w"), ef, "noimpl")
        check("rust: probes declared but 0 quals read -> rc 3 NOT A MEASUREMENT",
              rc == 3 and "NOT A MEASUREMENT" in txt and "0 probe quals" in txt)
    finally:
        shutil.rmtree(t, ignore_errors=True)
    # swift: liveness by COUNT.  Seeds: a live entry, a dead one (deps, imports them, 0 rows differ), a no-deps one, a partial one,
    # and a dev/test-only one (closure non-empty, its sources import none of it: NO-IMPORT, not dead).
    t = tempfile.mkdtemp(prefix="cjudge.")
    try:
        pool = os.path.join(t, "pool")
        spec = (("libA", [], []), ("libB", [], []), ("appLive", ["libA"], ["libA"]), ("appDead", ["libA"], ["libA"]), ("appNone", [], []),
                ("appPart", ["libA", "libB"], ["libA", "libB"]), ("appTest", ["libA"], []))
        for n, urls, imps in spec:
            os.makedirs(os.path.join(pool, n, "Sources", n))
            open(os.path.join(pool, n, "Package.swift"), "w").write(
                "let package = Package(name: \"%s\", dependencies: [%s], targets: [.target(name: \"%s\")])\n"
                % (n, ", ".join('.package(url: "https://x/%s.git", from: "1.0.0")' % u for u in urls), n))
            open(os.path.join(pool, n, "Sources", n, "a.swift"), "w").write("".join("import %s\n" % i for i in imps) + "func f() {}\n")
        ch, un = os.path.join(t, "ch"), os.path.join(t, "un")
        os.makedirs(ch); os.makedirs(un)
        def put(d, name, rows, uncovered=()):
            json.dump({"analyzed": {"count": len(rows)}, "functions": rows,
                       "coverage": {"uncovered": [{"name": u} for u in uncovered]}}, open(os.path.join(d, name + ".json"), "w"))
        base = [{"fn": "f", "inferred": []}]
        for n in ("libA", "libB", "appNone"):
            put(ch, n, base)                       # no closure: no unchained twin is needed (pool-scan.py writes none)
        put(un, "appLive", base);  put(ch, "appLive", [{"fn": "f", "inferred": ["Fs"]}])
        put(un, "appDead", base);  put(ch, "appDead", base)
        put(un, "appTest", base);  put(ch, "appTest", base)
        put(un, "appPart", base, ["libB"]); put(ch, "appPart", [{"fn": "f", "inferred": ["Fs"]}], ["libB"])
        rc, txt = run(report_swift, ch, un, pool)
        check("swift: live=2 (appLive, appPart), dead=1 (appDead imports its dep, 0 rows differ), no-import=1 (appTest), no-deps=3",
              rc == 0 and "LIVE 2" in txt and "DEAD-JOIN 1" in txt and "NO-IMPORT 1" in txt and "NO-DEPS 3" in txt)
        check("swift: the dead entry is LISTED by name and called NOT A MEASUREMENT for itself; the dev-only one is NOT called dead",
              "DEAD-JOIN appDead" in txt and "DEAD-JOIN appTest" not in txt and "NO-IMPORT appTest" in txt)
        check("swift: a live entry that still lists a chained dependency uncovered is PARTIAL (and appLive is not)",
              any(l.startswith("      LIVE      appPart") and "PARTIAL" in l for l in txt.splitlines())
              and any(l.startswith("      LIVE      appLive") and "PARTIAL" not in l for l in txt.splitlines()))
        # the whole pool dead -> rc 3
        put(ch, "appLive", base); put(ch, "appPart", base, ["libB"])
        rc, txt = run(report_swift, ch, un, pool)
        check("swift: every entry with deps dead -> rc 3 and 'NOT A MEASUREMENT' (seeded: a chained arm identical to the unchained)",
              rc == 3 and "NOT A MEASUREMENT" in txt)
        # an only-in-one-arm row counts as a difference (a join may ADD a row, not just change one)
        put(ch, "appLive", base + [{"fn": "g", "inferred": []}])
        rc, txt = run(report_swift, ch, un, pool)
        check("swift: a row present in the chained arm only counts as a differing row", rc == 0 and "LIVE 1" in txt)
        # a closure entry with NO unchained twin is not silently read as 'nothing differs'
        os.remove(os.path.join(un, "appDead.json"))
        rc, txt = run(report_swift, ch, un, pool)
        check("swift: a closure entry missing its unchained twin -> rc 3 (never read as 0 differing rows)",
              rc == 3 and "NO unchained twin" in txt)
        # the single-report form
        json.dump({"functions": base}, open(os.path.join(t, "a.json"), "w"))
        json.dump({"functions": [{"fn": "f", "inferred": ["Net"]}]}, open(os.path.join(t, "b.json"), "w"))
        rc, txt = run(live_swift, os.path.join(t, "b.json"), os.path.join(t, "a.json"))
        rc2, txt2 = run(live_swift, os.path.join(t, "a.json"), os.path.join(t, "a.json"))
        check("swift: --live-swift prints the count and fires (rc 3) on identical reports, stays quiet (rc 0) on a differing pair",
              rc == 0 and "1 row(s) differ" in txt and rc2 == 3 and "NOT A MEASUREMENT" in txt2)
    finally:
        shutil.rmtree(t, ignore_errors=True)
    print("corpus-chained-judge selftest: %s" % ("OK" if not bad else "FAILED (%d)" % bad))
    return 1 if bad else 0

if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "--selftest":
        sys.exit(selftest())
    if len(sys.argv) >= 2 and sys.argv[1] == "--coverage":
        coverage(sys.argv[2], sys.argv[3]); sys.exit(0)
    if len(sys.argv) >= 2 and sys.argv[1] == "--coverage-rs":
        coverage_rs(sys.argv[2], sys.argv[3]); sys.exit(0)
    if len(sys.argv) >= 2 and sys.argv[1] == "--report-rs":
        sys.exit(report_rs(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]))
    if len(sys.argv) >= 2 and sys.argv[1] == "--report-swift":
        sys.exit(report_swift(sys.argv[2], sys.argv[3], sys.argv[4]))
    if len(sys.argv) >= 2 and sys.argv[1] == "--live-swift":
        sys.exit(live_swift(sys.argv[2], sys.argv[3]))
    if len(sys.argv) >= 2 and sys.argv[1] == "--report":
        sys.exit(report(sys.argv[2], sys.argv[3], sys.argv[4]))
    print(__doc__)
    sys.exit(2)
