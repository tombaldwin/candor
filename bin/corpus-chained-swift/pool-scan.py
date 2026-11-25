#!/usr/bin/env python3
"""pool-scan.py BIN POOL OUTDIR [--jobs N] [--only a,b] — scan every pool entry CHAINED to its in-pool dependency
closure, and UNCHAINED where the closure is non-empty, with ONE binary, then hand the two report dirs to
`bin/corpus-chained-judge.py --report-swift` (which decides liveness by COUNT).

Why not chain.py per entry: chain.py re-scans an entry's whole closure for every entry (vapor alone is 13 scans).  An
entry's chained report IS the report its dependants need (chained to its own closure), so here each entry is scanned once
chained, in dependency order, and the report is reused.  Output:
    OUTDIR/ch/<entry>.json   the entry's report, chained   (the arm a chained A/B compares)
    OUTDIR/un/<entry>.json   the entry's report, unchained (only for entries with a non-empty closure; the liveness twin)
    OUTDIR/raw/              sidecars and logs
Exit 0 if every scan produced a report, 3 otherwise.  --jobs is capped at 2 (24 GB shared machine)."""
import argparse, concurrent.futures as cf, os, shutil, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import graph as G

ap = argparse.ArgumentParser()
ap.add_argument("bin"); ap.add_argument("pool"); ap.add_argument("out")
ap.add_argument("--jobs", type=int, default=2); ap.add_argument("--only", default="")
ap.add_argument("--timeout", type=int, default=3600)
a = ap.parse_args()
jobs = max(1, min(a.jobs, 2))
pool, out = os.path.abspath(a.pool), os.path.abspath(a.out)
for d in ("ch", "un", "raw"):
    os.makedirs(os.path.join(out, d), exist_ok=True)
g = G.graph(pool)
names = sorted(g)
only = {x for x in a.only.split(",") if x}
want = set(names) if not only else {c for n in only for c in [n] + G.closure(g, n)}
ENV = {k: v for k, v in os.environ.items() if k not in ("CANDOR_DEPS", "CANDOR_POLICY", "CANDOR_CONFIG", "CANDOR_BASELINE")}
failed = []

def main_report(prefix):
    d = os.path.dirname(prefix); b = os.path.basename(prefix)
    c = [f for f in os.listdir(d) if f.startswith(b + ".") and f.endswith(".json") and not f.endswith((".callgraph.json", ".hierarchy.json", ".locs.json"))]
    return os.path.join(d, c[0]) if c else None

def scan(n, deps_reports, tag, dest):
    env = dict(ENV)
    if deps_reports:
        env["CANDOR_DEPS"] = " ".join(deps_reports)
    prefix = os.path.join(out, "raw", f"{tag}.{n}")
    t = time.time()
    try:
        r = subprocess.run([a.bin, os.path.join(pool, n), "--out", prefix], env=env, stdout=subprocess.DEVNULL,
                           stderr=subprocess.PIPE, timeout=a.timeout)
        err = r.stderr.decode("utf-8", "replace")
    except subprocess.TimeoutExpired:
        err = "TIMEOUT"
    open(prefix + ".stderr", "w").write(err)
    rep = main_report(prefix)
    if not rep:
        failed.append((n, tag)); print(f"  FAILED {tag} {n}", flush=True); return None
    shutil.copy(rep, os.path.join(out, dest, n + ".json"))
    print(f"  {tag:3s} {n:34s} {time.time() - t:6.0f}s", flush=True)
    return rep

done = {}
def run_level(level):
    def one(n):
        deps = G.closure(g, n)
        reps = [done[d] for d in deps if d in done]
        rep = scan(n, reps, "ch", "ch")
        if rep and deps:
            scan(n, [], "un", "un")
        return n, rep
    with cf.ThreadPoolExecutor(max_workers=jobs) as ex:
        for n, rep in ex.map(one, level):
            if rep:
                done[n] = rep

# dependency order: a level is every unscanned entry whose closure is already scanned
pending = [n for n in G.topo(g, set(want))]
while pending:
    level = [n for n in pending if all((d in done) or (d not in want) for d in g.get(n, []))]
    if not level:
        level = pending[:1]   # a cycle or a failed dependency: scan it anyway, unchained from what exists
    run_level(level)
    pending = [n for n in pending if n not in level]
print("pool-scan: %d entries, %d failed" % (len(want), len(failed)))
sys.exit(3 if failed else 0)
