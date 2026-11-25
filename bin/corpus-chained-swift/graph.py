#!/usr/bin/env python3
"""Dependency graph of the scratch corpus: each package's Package.swift `url:` basenames that name a sibling."""
import os, re, sys, json
def graph(pool):
    names = {n.lower(): n for n in os.listdir(pool) if os.path.isfile(os.path.join(pool, n, "Package.swift"))}
    g = {}
    for low, n in names.items():
        src = open(os.path.join(pool, n, "Package.swift"), encoding="utf-8", errors="replace").read()
        deps = []
        for u in re.findall(r'url:\s*"([^"]+)"', src):
            b = u.rstrip("/").split("/")[-1]
            b = b[:-4] if b.endswith(".git") else b
            if b.lower() in names and names[b.lower()] != n and names[b.lower()] not in deps:
                deps.append(names[b.lower()])
        g[n] = deps
    return g
def closure(g, n):
    out, stack = [], list(g.get(n, []))
    seen = set()
    while stack:
        d = stack.pop()
        if d in seen: continue
        seen.add(d); out.append(d); stack.extend(g.get(d, []))
    return out
def topo(g, nodes):
    order, done = [], set()
    def visit(n, path):
        if n in done or n in path: return
        for d in g.get(n, []):
            if d in nodes: visit(d, path | {n})
        done.add(n); order.append(n)
    for n in sorted(nodes): visit(n, frozenset())
    return order
if __name__ == "__main__":
    g = graph(sys.argv[1]); print(json.dumps({n: closure(g, n) for n in g}, indent=1))


def modules(pool, n):
    """module names package `n` declares: every `.target(name: "X"` / `.library(name: "X"` / `.product(name: ...)` in its Package.swift
    plus its Sources/ directory names (SwiftPM's default).  A superset on purpose: it is used to ask 'does this consumer IMPORT it'."""
    out = set()
    pk = os.path.join(pool, n, "Package.swift")
    try:
        src = open(pk, encoding="utf-8", errors="replace").read()
    except OSError:
        return out
    out.update(re.findall(r'\.(?:target|library|executableTarget)\(\s*name:\s*"([^"]+)"', src))
    sd = os.path.join(pool, n, "Sources")
    if os.path.isdir(sd):
        out.update(d for d in os.listdir(sd) if os.path.isdir(os.path.join(sd, d)))
    return out

def imported(pool, n):
    """module names imported by package `n`'s NON-test sources (Sources/, Plugins/ excluded).  Textual, `@testable`/`import struct X.Y` aware."""
    out = set()
    root = os.path.join(pool, n, "Sources")
    for r, ds, fs in os.walk(root):
        for f in fs:
            if not f.endswith(".swift"):
                continue
            try:
                for line in open(os.path.join(r, f), encoding="utf-8", errors="replace"):
                    m = re.match(r"\s*(?:@\w+(?:\([^)]*\))?\s+)*import\s+(?:(?:struct|class|enum|protocol|func|var|let|typealias)\s+)?([A-Za-z_][A-Za-z0-9_]*)", line)
                    if m:
                        out.add(m.group(1))
            except OSError:
                pass
    return out
