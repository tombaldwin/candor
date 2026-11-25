#!/usr/bin/env python3
"""cachechain.py BIN CACHEDIR ENTRY OUTDIR [K=V ...] — chain.py memoised per CACHEDIR (K=V added to the env)."""
import os, shutil, subprocess, sys
binp, cache, entry, outdir = sys.argv[1:5]
env = dict(os.environ)
for kv in sys.argv[5:]:
    k, v = kv.split("=", 1); env[k] = v
d = os.path.join(cache, os.path.basename(entry))
if not os.path.exists(os.path.join(d, ".rc")):
    if os.path.isdir(d): shutil.rmtree(d)
    os.makedirs(d)
    r = subprocess.run([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), "chain.py"), binp, entry, d], env=env)
    open(os.path.join(d, ".rc"), "w").write(str(r.returncode))
rc = int(open(os.path.join(d, ".rc")).read())
os.makedirs(outdir, exist_ok=True)
for f in os.listdir(d):
    if f != ".rc": shutil.copy(os.path.join(d, f), os.path.join(outdir, f))
sys.exit(rc)
