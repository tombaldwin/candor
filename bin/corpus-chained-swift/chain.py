#!/usr/bin/env python3
"""chain.py BIN ENTRY OUTDIR — scan ENTRY with BIN, chained (CANDOR_DEPS) to the reports of its transitive corpus
dependencies, each scanned FIRST by the SAME BIN and itself chained to its own. Only the ENTRY's report lands in
OUTDIR. Exit: the entry scan's rc, or 3 if any dependency scan failed. CHAIN_KEEP=dir copies the dependency reports."""
import os, subprocess, sys, tempfile, shutil
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import graph as G
binp, entry, outdir = sys.argv[1], os.path.abspath(sys.argv[2]), sys.argv[3]
pool, name = os.path.dirname(entry), os.path.basename(entry)
g = G.graph(pool)
deps = G.closure(g, name)
tmp = tempfile.mkdtemp(prefix="chain-", dir=os.environ.get("CHAIN_TMP"))
reports = {}
env0 = {k: v for k, v in os.environ.items() if k not in ("CANDOR_DEPS", "CANDOR_POLICY", "CANDOR_CONFIG", "CANDOR_BASELINE")}
def report_of(outprefix):
    d = os.path.dirname(outprefix)
    return [os.path.join(d, f) for f in os.listdir(d) if f.startswith(os.path.basename(outprefix) + ".") and f.endswith(".json")
            and not f.endswith(".callgraph.json") and not f.endswith(".hierarchy.json")]
try:
    for d in G.topo(g, set(deps)):
        mine = [p for x in G.closure(g, d) for p in reports.get(x, [])]
        env = dict(env0)
        if mine: env["CANDOR_DEPS"] = " ".join(mine)
        pre = os.path.join(tmp, "dep_" + d)
        r = subprocess.run([binp, os.path.join(pool, d), "--out", pre], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        reps = report_of(pre)
        if not reps:
            sys.stderr.write("chain: dependency %s produced no report (rc=%d): %s\n" % (d, r.returncode, r.stderr[-400:]))
            sys.exit(3)
        reports[d] = reps
    env = dict(env0)
    mine = [p for x in deps for p in reports.get(x, [])]
    if mine: env["CANDOR_DEPS"] = " ".join(mine)
    os.makedirs(outdir, exist_ok=True)
    r = subprocess.run([binp, entry, "--out", os.path.join(outdir, "report")], env=env, stderr=subprocess.PIPE)
    err = r.stderr.decode("utf-8", "replace")
    open(outdir.rstrip("/") + ".stderr", "w").write(err)   # swiftagent-r1472: keep the entry scan's stderr (probe lines)
    sys.stderr.write(err)
    sys.stderr.write("CHAINDEPS %s %d\n" % (name, len(mine)))
    sys.exit(r.returncode)
finally:
    if os.environ.get("CHAIN_KEEP"):
        shutil.copytree(tmp, os.path.join(os.environ["CHAIN_KEEP"], name), dirs_exist_ok=True)
    shutil.rmtree(tmp, ignore_errors=True)
