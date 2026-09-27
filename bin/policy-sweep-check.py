#!/usr/bin/env python3
"""The per-jar arithmetic a ruling asked for, which had no home. SOUNDNESS R731.

    python3 bin/policy-sweep-check.py PRE.tsv POST.tsv      # two arms — did anything LOSE cover?
    python3 bin/policy-sweep-check.py ONE.tsv               # one arm — is the reason split DISJOINT?
    python3 bin/policy-sweep-check.py --selftest

The ruling: *a jar whose `[X]` count equals `[X,unresolved]` minus `[unresolved]` in both arms, with
`[dispatch,unresolved]` and bare `deny Unknown` unchanged, has lost nothing* — so that the next relabel
needs no ruling for its fontbox.

WHAT THAT IDENTITY ACTUALLY SAYS, spelled out because it is not obvious and the ruling did not say it:
`deny Unknown[X,unresolved]` denies a row whose reason is X **or** unresolved, so its count is
|X ∪ unresolved| = |X| + |unresolved| − |X ∩ unresolved|. The identity therefore holds **exactly when the
two reason classes are DISJOINT**. A jar where it fails has rows carrying BOTH reasons at once, and that
overlap is the fontbox anomaly's shape — not an arithmetic slip but a real statement about the report.

So this tool answers two different questions and says which it answered:

  DISJOINTNESS (one arm)  — for each jar and each X, does |X| + |unresolved| == |X ∪ unresolved|?
                            A violation is a jar whose rows carry two reasons, which the ruling's
                            arithmetic assumes away.
  NO-LOSS (two arms)      — bare and `[dispatch,unresolved]` unchanged, AND disjointness holding in
                            both. Anything else is a jar that has to be read.

NA IS NOT ZERO. `policy-sweep.sh` records a refused or unreadable run as NA, and this tool reports those
jars as UNMEASURED rather than folding them into either verdict. A jar the engine refused has not been
shown to have lost nothing; it has not been shown anything.
"""
import sys

POLICIES = ("bare", "reflect", "dispatch", "unresolved",
            "reflect_unresolved", "dispatch_unresolved")
PAIRS = (("reflect", "reflect_unresolved"), ("dispatch", "dispatch_unresolved"))


def read(path):
    """jar -> {policy: int|None}. None means NA — measured as unmeasurable, which is not 0."""
    out, seen_header = {}, False
    with open(path) as fh:
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 3:
                continue
            if not seen_header and parts[0] == "jar":
                seen_header = True
                continue
            jar, pol, n = parts[0], parts[1], parts[2]
            out.setdefault(jar, {})[pol] = None if n == "NA" else int(n)
    return out


def disjointness(arm):
    """(violations, unmeasured) for one arm. A violation names the overlap it implies."""
    viol, unmeasured = [], []
    for jar, row in sorted(arm.items()):
        missing = [p for p in POLICIES if p not in row]
        if missing:
            unmeasured.append((jar, "no row for " + ", ".join(missing)))
            continue
        if any(row[p] is None for p in POLICIES):
            unmeasured.append((jar, "NA for " + ", ".join(p for p in POLICIES if row[p] is None)))
            continue
        for x, xu in PAIRS:
            lhs = row[x] + row["unresolved"]
            if lhs != row[xu]:
                viol.append((jar, x, row[x], row["unresolved"], row[xu], lhs - row[xu]))
    return viol, unmeasured


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    if "--selftest" in argv:
        return selftest()
    if not args or len(args) > 2:
        print(__doc__.strip().split("\n\n")[1])
        return 2

    arms = [(p, read(p)) for p in args]
    for path, arm in arms:
        if not arm:
            print("policy-sweep-check: REFUSING — %s holds no rows. An empty sweep would print a clean"
                  % path)
            print("  arithmetic over nothing at all, which is the most flattering possible output.")
            return 2

    rc = 0
    for path, arm in arms:
        viol, unmeasured = disjointness(arm)
        print("%s: %d jar(s)" % (path, len(arm)))
        if unmeasured:
            print("  UNMEASURED (NA or missing — NOT 'lost nothing'): %d" % len(unmeasured))
            for jar, why in unmeasured[:8]:
                print("    %-34s %s" % (jar, why))
            rc = 1
        if viol:
            print("  REASON CLASSES OVERLAP on %d (jar, X) pair(s) — rows carrying BOTH reasons, which is"
                  % len(viol))
            print("  what the ruling's arithmetic assumes away. This is the fontbox shape:")
            for jar, x, a, u, au, d in viol[:12]:
                print("    %-30s %-9s |X|=%-6d |unres|=%-5d |X∪unres|=%-6d overlap=%d"
                      % (jar, x, a, u, au, d))
            rc = 1
        if not viol and not unmeasured:
            # VACUITY FIRST. `|X| + |unresolved| == |X ∪ unresolved|` cannot fail when `|unresolved|` is
            # 0, so on a corpus where no jar carries that reason the identity is ARITHMETIC rather than a
            # measurement. Measured on the first real run: 0 of 40 census jars had `unresolved > 0`, and
            # the tool printed "DISJOINT on every jar" — a reassuring green over a check that could not
            # come out wrong. Saying so is the difference between this instrument and the ad-hoc sweeps
            # it replaces.
            nz = [j for j, r in arm.items() if r.get("unresolved")]
            if not nz:
                print("  VACUOUS HERE — `unresolved` is 0 on ALL %d jar(s), so |X| + 0 == |X ∪ {}| is"
                      % len(arm))
                print("  arithmetic and this check CANNOT FAIL on this corpus. The ruling's identity is")
                print("  not wrong; it is not discriminating here, and a green line would have implied")
                print("  it had been tested. Find jars whose reports carry an `unresolved` reason, or")
                print("  treat the no-loss half below as the only claim this run supports.")
            else:
                print("  DISJOINT on every jar and both X — the identity holds, and it was EXERCISED:")
                print("  %d of %d jar(s) carry a non-zero `unresolved` count." % (len(nz), len(arm)))

    if len(arms) == 2:
        (pa, pre), (pb, post) = arms
        shared = sorted(set(pre) & set(post))
        print()
        print("NO-LOSS across the two arms, over %d shared jar(s):" % len(shared))
        if not shared:
            print("  REFUSING — the two arms share NO jar. Two sweeps of different rosters cannot be")
            print("  differenced, and a comparison over an empty intersection reports no loss.")
            return 2
        moved = []
        for jar in shared:
            for p in ("bare", "dispatch_unresolved"):
                a, b = pre[jar].get(p), post[jar].get(p)
                if a is None or b is None:
                    continue
                if a != b:
                    moved.append((jar, p, a, b))
        if moved:
            print("  %d (jar, policy) count(s) MOVED where the ruling requires them unchanged:" % len(moved))
            for jar, p, a, b in moved[:12]:
                print("    %-30s %-20s %d -> %d" % (jar, p, a, b))
            rc = 1
        else:
            print("  bare and [dispatch,unresolved] are unchanged on every shared jar.")
        if rc == 0:
            print()
            print("policy-sweep-check: NOTHING LOST — the identity holds in both arms and the two")
            print("  unchanged policies are unchanged. This is the printed check the ruling asked for,")
            print("  and it is the whole of what it licenses: it says no jar lost COVER, and it says")
            print("  nothing about whether the relabel was the right label.")
    if rc:
        print()
        print("policy-sweep-check: READ THE JARS ABOVE. Not necessarily a defect — an overlap is a fact")
        print("  about the report, and an NA is a jar that was never measured.")
    return rc


def selftest():
    import tempfile, os
    bad = 0

    def tsv(rows):
        fd, p = tempfile.mkstemp(suffix=".tsv")
        with os.fdopen(fd, "w") as fh:
            fh.write("jar\tpolicy\tviolations\texit\n")
            for jar, pol, n in rows:
                fh.write("%s\t%s\t%s\t0\n" % (jar, pol, n))
        return p

    def full(jar, bare, refl, disp, unres, ru, du):
        return [(jar, "bare", bare), (jar, "reflect", refl), (jar, "dispatch", disp),
                (jar, "unresolved", unres), (jar, "reflect_unresolved", ru),
                (jar, "dispatch_unresolved", du)]

    def case(name, rows, want_viol, want_unmeasured):
        nonlocal bad
        arm = read(tsv(rows))
        v, u = disjointness(arm)
        ok = (len(v) > 0) == want_viol and (len(u) > 0) == want_unmeasured
        print("  %s %-56s viol=%d unmeasured=%d" % ("ok  " if ok else "FAIL", name, len(v), len(u)))
        if not ok:
            bad += 1

    # Disjoint: |X| + |unres| == |X ∪ unres| for both X.
    case("disjoint reason classes pass", full("a", 10, 4, 6, 2, 6, 8), False, False)
    # Overlapping: reflect and unresolved share a row, so the union is SMALLER than the sum.
    case("OVERLAPPING reason classes are reported", full("b", 10, 4, 6, 2, 5, 8), True, False)
    # unresolved == 0 is the common real shape and must pass.
    case("unresolved=0 passes (the common shape)", full("c", 730, 483, 717, 0, 483, 717), False, False)
    # NA must not be read as 0 — with NA the jar is UNMEASURED, and 4+2 != 5 must NOT be reported.
    case("an NA jar is UNMEASURED, not a violation",
         full("d", 10, 4, 6, "NA", 5, 8), False, True)
    # A jar missing a policy row entirely is unmeasured too, not silently disjoint.
    case("a jar missing a policy row is UNMEASURED",
         [("e", "bare", 1), ("e", "reflect", 1)], False, True)

    # THE VACUITY REPORT, pinned. An all-zero `unresolved` column must NOT print a clean "DISJOINT"
    # line, because the check cannot fail there — this is the case the first real run failed to make.
    import io, contextlib
    for nm, rows, want_vac in (
            ("an all-zero `unresolved` column reports VACUOUS", full("g", 10, 4, 6, 0, 4, 6), True),
            ("a non-zero `unresolved` column reports EXERCISED", full("h", 10, 4, 6, 2, 6, 8), False)):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            main(["x", tsv(rows)])
        out = buf.getvalue()
        got_vac = "VACUOUS HERE" in out
        ok = got_vac == want_vac and ("EXERCISED" in out) == (not want_vac)
        print("  %s %-56s" % ("ok  " if ok else "FAIL", nm))
        if not ok:
            bad += 1

    # …and the TWO-ARM half: a moved `bare` count must be reported.
    pre = tsv(full("f", 10, 4, 6, 2, 6, 8))
    post_same = tsv(full("f", 10, 4, 6, 2, 6, 8))
    post_moved = tsv(full("f", 9, 4, 6, 2, 6, 8))
    for nm, pth, want_rc in (("two identical arms report NO LOSS", post_same, 0),
                             ("a moved `bare` count is REPORTED", post_moved, 1)):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = main(["x", pre, pth])
        ok = rc == want_rc
        print("  %s %-56s rc=%d" % ("ok  " if ok else "FAIL", nm, rc))
        if not ok:
            bad += 1

    # An empty TSV must REFUSE, not report a clean arithmetic.
    empty = tsv([])
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = main(["x", empty])
    ok = rc == 2
    print("  %s %-56s rc=%d" % ("ok  " if ok else "FAIL", "an EMPTY sweep REFUSES rather than passing", rc))
    if not ok:
        bad += 1

    print("policy-sweep-check selftest: " + ("OK" if not bad else "FAILED (%d)" % bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
