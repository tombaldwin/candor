#!/usr/bin/env python3
"""INTERNAL CONSISTENCY — a report's own claims must agree with each other.

Every oracle so far has compared a report against something ELSE: another engine, another run, the
runtime, a library's purpose. This one needs no comparison at all, which is why it can run over every
report on disk. A report says several things about the same function, and some pairs cannot both be
true:

  · a `hosts` literal without Net   — a destination for an effect the function does not have
  · a `cmds`  literal without Exec
  · a `paths` literal without Fs
  · a `tables` literal without Db
  · `unknownWhy` without Unknown    — a REASON for an effect that is not claimed
  · `direct` ⊄ `inferred`           — inferred is direct plus what propagates; it cannot LOSE one
  · analyzed.count < |functions|    — the analysed universe is smaller than the functions reported

A violation is a fabrication or a drop INSIDE one document, so it needs no ground truth to judge — and
none of these is asserted anywhere in the suite today.

The locator keys are per-effect by SPEC §2, so the pairs above are the contract, not a guess.
"""
import json, sys, glob, collections

PAIRS = [("hosts", "Net"), ("cmds", "Exec"), ("paths", "Fs"), ("tables", "Db")]

def check(path):
    try:
        d = json.load(open(path))
    except Exception:
        return []                                  # unreadable/partial: other oracles own that
    if not isinstance(d, dict) or "functions" not in d:
        return []
    out, fns = [], d.get("functions") or []
    for f in fns:
        if not isinstance(f, dict):
            continue
        name = f.get("fn", "?")
        inf = set(f.get("inferred") or [])
        dir_ = set(f.get("direct") or [])
        for key, eff in PAIRS:
            if (f.get(key) or []) and eff not in inf:
                out.append(f"{name}: `{key}` names {len(f[key])} literal(s) but `inferred` lacks {eff} "
                           f"— a locator for an effect the function does not claim")
        if (f.get("unknownWhy") or []) and "Unknown" not in inf:
            out.append(f"{name}: `unknownWhy` gives a reason but `inferred` lacks Unknown")
        if dir_ - inf:
            out.append(f"{name}: `direct` has {sorted(dir_ - inf)} that `inferred` does not — "
                       f"inferred is direct PLUS what propagates, it cannot lose one")
    an = (d.get("analyzed") or {}).get("count")
    if isinstance(an, int) and an < len(fns):
        out.append(f"analyzed.count {an} < {len(fns)} reported function(s) — the analysed universe "
                   f"cannot be smaller than what was reported from it")
    return out

SELFTEST = [
    ("hosts without Net",       {"fn": "f", "inferred": [], "hosts": ["example.com"]}),
    ("cmds without Exec",       {"fn": "f", "inferred": [], "cmds": ["sh"]}),
    ("paths without Fs",        {"fn": "f", "inferred": [], "paths": ["/tmp/x"]}),
    ("tables without Db",       {"fn": "f", "inferred": [], "tables": ["t"]}),
    ("unknownWhy w/o Unknown",  {"fn": "f", "inferred": [], "unknownWhy": ["dyn"]}),
    ("direct not in inferred",  {"fn": "f", "inferred": [], "direct": ["Net"]}),
]

def selftest():
    """A zero is not evidence until the instrument is shown able to fail.

    Every rule gets a report that violates it and nothing else; a rule that stays silent here would
    have reported a clean sweep over any corpus, which is the cardinal sin wearing an oracle's hat.
    """
    import tempfile, os
    bad = 0
    for label, fn in SELFTEST:
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
            json.dump({"analyzed": {"count": 1}, "functions": [fn]}, fh)
            p = fh.name
        fired = check(p)
        os.unlink(p)
        print(f"  {'✔' if fired else '✘'} {label:26} {'fires' if fired else 'SILENT — rule is dead'}")
        bad += 0 if fired else 1
    # the analyzed.count rule needs a shape of its own (two functions, a universe of one)
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
        json.dump({"analyzed": {"count": 1}, "functions": [{"fn": "a"}, {"fn": "b"}]}, fh)
        p = fh.name
    fired = check(p)
    os.unlink(p)
    print(f"  {'✔' if fired else '✘'} {'analyzed.count < |functions|':26} "
          f"{'fires' if fired else 'SILENT — rule is dead'}")
    bad += 0 if fired else 1
    print(f"  selftest: {7 - bad}/7 rule(s) proven able to fail")
    return 1 if bad else 0

def main():
    pats = sys.argv[1:]
    if pats and pats[0] == "--selftest":
        return selftest()
    files, bad, checked = [], 0, 0
    for p in pats:
        files.extend(glob.glob(p, recursive=True))
    by_engine = collections.Counter()
    for f in sorted(set(files)):
        if any(k in f for k in ("callgraph", "hierarchy", "locs", "node_modules")):
            continue
        findings = check(f)
        checked += 1
        for line in findings:
            bad += 1
            print(f"  FINDING {f.split('/')[-1]}: {line}")
        if findings:
            by_engine[f.split("/")[-1].split(".")[0]] += len(findings)
    print(f"  self-consistency: {checked} report(s) checked, {bad} violation(s)"
          + (f" by engine: {dict(by_engine)}" if by_engine else ""))
    return 1 if bad else 0

if __name__ == "__main__":
    sys.exit(main())
