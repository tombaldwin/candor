#!/usr/bin/env python3
"""bin/corpus-macro-census.py — count PATH-INVOKED LOCAL MACRO sites that matter to candor-scan (rust).

    corpus-macro-census.py sites  --roster FILE|--crates D... --out sites.jsonl
    corpus-macro-census.py scan   --sites sites.jsonl --scan-bin BIN --work DIR [--jobs N]
    corpus-macro-census.py join   --sites sites.jsonl --work DIR --out joined.json
    corpus-macro-census.py sample --joined joined.json --n 40 --seed 1
    corpus-macro-census.py --selftest

WHY.  Neither candor-scan resolver binds a path-invoked macro (`$crate::m!`, `crate::m!`, `self::m!`,
`super::m!`).  A POPULATION count of such sites (3,812 in 172 crates, by regex) says nothing about how many
matter.  This counts the CONJUNCTION the fix needs: a path-invoked site whose LOCAL macro (any arm) is
effect-bearing or emits a fn/impl, by POSITION (item / body / trait-item / impl-item), joined with the
enclosing unit's reading on a built candor-scan: charged-for-the-macro's-effect / Unknown (with reason) /
pure / ABSENT from the report.

INSTRUMENT.  A token-level reader (comments, strings, raw strings, lifetimes stripped; delimiter trees).  It
shares no code with candor-scan.  It is a HEURISTIC on two axes, both stated in the output:
  * effect-bearing = the macro text names a std effect locator (fs/File, TcpStream, Command, env::var, ...).
  * emits = the macro text contains `fn` or `impl`.
A site that sits inside ANOTHER macro's body (`$crate::m!` in a transcriber, the commonest form) has no
position of its own: it is attributed, to depth 3, to every SOURCE invocation of the outer macro, and counted
in its own column (`nested`).  Selftest seeds a fixture with one site per position and shows each one fire.
"""
import argparse, glob, json, os, random, re, subprocess, sys, tempfile
from collections import Counter, defaultdict

# ───────────────────────── lexer ─────────────────────────
class Tok:
    __slots__ = ("k", "t", "line")
    def __init__(s, k, t, line): s.k, s.t, s.line = k, t, line
    def __repr__(s): return f"{s.k}:{s.t}"
class Grp:
    __slots__ = ("d", "kids", "line", "end")
    def __init__(s, d, line): s.d, s.kids, s.line, s.end = d, [], line, line
    def __repr__(s): return f"G{s.d}{len(s.kids)}"

CLOSE = {")": "(", "]": "[", "}": "{"}
IDSTART = re.compile(r"[A-Za-z_\u0080-￿]")
IDCH = re.compile(r"[A-Za-z0-9_\u0080-￿]")

def lex(src):
    """-> list of Tok/Grp (a delimiter tree). Never raises on odd input: unbalanced input returns what it has."""
    i, n, line = 0, len(src), 1
    root = Grp("", 1); stack = [root]
    def emit(x): stack[-1].kids.append(x)
    while i < n:
        c = src[i]
        if c == "\n": line += 1; i += 1; continue
        if c in " \t\r": i += 1; continue
        if c == "/" and src.startswith("//", i):
            j = src.find("\n", i); i = n if j < 0 else j; continue
        if c == "/" and src.startswith("/*", i):
            depth, i = 1, i + 2
            while i < n and depth:
                if src.startswith("/*", i): depth += 1; i += 2
                elif src.startswith("*/", i): depth -= 1; i += 2
                else:
                    if src[i] == "\n": line += 1
                    i += 1
            continue
        # raw / byte / c strings
        m = re.match(r'(?:b|c)?r(#*)"', src[i:i+300]) if c in "brc" else None
        if m:
            hashes = m.group(1); close = '"' + hashes
            j = src.find(close, i + m.end())
            j = n if j < 0 else j + len(close)
            line += src.count("\n", i, j); emit(Tok("s", "", line)); i = j; continue
        if c == '"' or (c in "bc" and src.startswith('"', i + 1)):
            i += 1 if c == '"' else 2
            while i < n and src[i] != '"':
                if src[i] == "\\": i += 1
                if i < n and src[i] == "\n": line += 1
                i += 1
            i += 1; emit(Tok("s", "", line)); continue
        if c == "'" or (c == "b" and src.startswith("'", i + 1)):
            j = i + (1 if c == "'" else 2)
            # char literal or lifetime
            if j < n and src[j] == "\\":
                k = src.find("'", j + 2); i = n if k < 0 else k + 1; emit(Tok("s", "", line)); continue
            if j + 1 < n and src[j + 1] == "'":
                i = j + 2; emit(Tok("s", "", line)); continue
            # lifetime: 'ident
            k = j
            while k < n and IDCH.match(src[k]): k += 1
            i = max(k, j); emit(Tok("l", src[j:k], line)); continue
        if IDSTART.match(c):
            j = i + 1
            while j < n and IDCH.match(src[j]): j += 1
            word = src[i:j]
            if word == "r" and src.startswith("#", j) and j + 1 < n and IDSTART.match(src[j + 1]):  # r#ident
                j += 1
                while j < n and IDCH.match(src[j]): j += 1
                word = src[i + 2:j]
            emit(Tok("i", word, line)); i = j; continue
        if c.isdigit():
            j = i + 1
            while j < n and (IDCH.match(src[j]) or (src[j] == "." and j + 1 < n and src[j + 1].isdigit())): j += 1
            emit(Tok("n", "", line)); i = j; continue
        if c in "([{":
            g = Grp(c, line); emit(g); stack.append(g); i += 1; continue
        if c in ")]}":
            if len(stack) > 1 and stack[-1].d == CLOSE[c]:
                stack[-1].end = line; stack.pop()
            i += 1; continue
        emit(Tok("p", c, line)); i += 1
    return root.kids

def isid(x, t=None): return isinstance(x, Tok) and x.k == "i" and (t is None or x.t == t)
def isp(x, t): return isinstance(x, Tok) and x.k == "p" and x.t == t
def isg(x, d=None): return isinstance(x, Grp) and (d is None or x.d == d)

def flat(kids):
    for x in kids:
        if isinstance(x, Grp):
            yield from flat(x.kids)
        else: yield x

def idents(kids): return [x.t for x in flat(kids) if x.k == "i"]

# ───────────────────────── effect heuristic ─────────────────────────
# (class, regex over the macro's flat token stream joined by space). Deliberately std-locator based.
EFFECT_PAT = [
    ("Fs", r"\bfs\b|\bFile\b|\bOpenOptions\b|\bread_to_string\b|\bcreate_dir|\bremove_file\b|\bread_dir\b"),
    ("Net", r"\bTcpStream\b|\bTcpListener\b|\bUdpSocket\b|\bToSocketAddrs\b|\breqwest\b|\bhyper\b"),
    ("Exec", r"\bCommand\b|\bprocess\b :: (?:Command|exit)|\bexecv|\bposix_spawn\b"),
    ("Env", r"\benv\b :: (?:var|vars|args|current_dir|set_var|home_dir|temp_dir)|\bvar_os\b|\bcurrent_exe\b"),
    ("Clock", r"\bSystemTime\b|\bInstant\b|\bUNIX_EPOCH\b"),
    ("Rand", r"\bthread_rng\b|\bgetrandom\b|\bOsRng\b|\brandom\b"),
    ("Log?", r"\bprintln\b|\beprintln\b|\bprint\b|\beprint\b|\binfo\b|\bwarn\b|\berror\b|\bdebug\b|\btrace\b"),
]
EFFECT_RX = [(c, re.compile(p)) for c, p in EFFECT_PAT]
STRONG = {"Fs", "Net", "Exec", "Env", "Clock", "Rand"}

KW = {"if", "while", "match", "for", "fn", "return", "in", "let", "loop", "move", "unsafe", "as", "else", "impl", "where", "Some", "Ok", "Err", "None", "Self", "Box", "Vec", "String", "Option", "Result"}
def callees_in(kids):
    out = set(); fl = list(kids)
    for a, b in zip(fl, fl[1:]):
        if isid(a) and isg(b, "(") and a.t not in KW: out.add(a.t)
    for x in fl:
        if isinstance(x, Grp): out |= callees_in(x.kids)
    return out

def macro_effects(kids):
    s = " ".join(x.t if x.k in "ip" else "" for x in flat(kids))
    cls = {c for c, rx in EFFECT_RX if rx.search(s)}
    toks = {x.t for x in flat(kids) if x.k == "i"}
    return cls, ("fn" in toks), ("impl" in toks)

# ───────────────────────── item walker ─────────────────────────
QUAL = {"pub", "const", "async", "unsafe", "extern", "default", "crate", "super", "in", "self"}
PATH_FIRST = {"crate", "self", "super"}

class Crate:
    def __init__(s, root): s.root = root; s.defs = {}; s.invs = []; s.units = []; s.calls = defaultdict(set)

def at_item_start(kids, start, i):
    """tokens kids[start:i] are only qualifiers/attributes (so kids[i] begins an item)."""
    j = start
    while j < i:
        x = kids[j]
        if isp(x, "#") or isp(x, "!"): j += 1; continue
        if isg(x): j += 1; continue
        if x.k == "s": j += 1; continue
        if x.k == "i" and x.t in QUAL: j += 1; continue
        return False
    return True

def path_before(kids, i):
    """kids[i] is the macro-name ident. Return (prefix segments list, start_index) walking back over `seg ::`."""
    segs, j = [], i - 1
    # leading `::`
    while j >= 1 and isp(kids[j], ":") and isp(kids[j - 1], ":") and j >= 2 and isid(kids[j - 2]):
        segs.append(kids[j - 2].t); j -= 3
    prefix_dollar = False
    if segs and segs[-1] == "crate" and j >= 0 and isp(kids[j], "$"): prefix_dollar = True
    segs.reverse()
    return segs, prefix_dollar

def walk(kids, ctx, modpath, fn_stack, cr, file, in_def=None, impl_name=None):
    """ctx: item|impl|trait|body|def (macro body)."""
    n = len(kids); i = 0; start = 0
    while i < n:
        x = kids[i]
        if isinstance(x, Grp):
            if x.d == "{" and ctx in ("item", "impl", "trait"):
                # unknown brace group at item level (struct/enum/extern block/const init): look for invocations only
                walk(x.kids, "other", modpath, fn_stack, cr, file, in_def); start = i + 1
            else:
                walk(x.kids, "body" if ctx in ("body", "other") else ctx if ctx == "def" else "other", modpath, fn_stack, cr, file, in_def)
            i += 1; continue
        if isp(x, ";"): start = i + 1; i += 1; continue
        # macro_rules! name { ... }
        if isid(x, "macro_rules") and i + 3 < n and isp(kids[i + 1], "!") and isid(kids[i + 2]) and isg(kids[i + 3]):
            name = kids[i + 2].t; g = kids[i + 3]
            cls, fn, impl = macro_effects(g.kids)
            cr.defs.setdefault(name, []).append(dict(name=name, file=file, line=x.line, effects=sorted(cls), fn=fn, impl=impl,
                                                      fnnames=fn_names_in(g.kids), callees=sorted(callees_in(g.kids)),
                                                      text=" ".join(("fn$" if (isid(a, "fn") and isp(b, "$")) else "") for a, b in zip(list(flat(g.kids)), list(flat(g.kids))[1:]))))
            walk(g.kids, "def", modpath, fn_stack, cr, file, name)
            i += 4; start = i; continue
        # macro invocation  [path ::] name ! group
        if x.k == "i" and i + 2 < n and isp(kids[i + 1], "!") and isg(kids[i + 2]) and not isid(x, "macro_rules"):
            segs, dollar = path_before(kids, i)
            if segs and segs[0] in PATH_FIRST or (segs and dollar):
                args = kids[i + 2]
                cr.invs.append(dict(name=x.t, prefix=segs, dollar=dollar, file=file, line=x.line, ctx=ctx,
                                    modpath=modpath, fn=[u["name"] for u in fn_stack[-1:]], in_def=in_def, impl=impl_name,
                                    args=sorted(set(idents(args.kids)))[:40], args_fns=fn_names_in(args.kids)[:20]))
            elif not segs:
                cr.invs.append(dict(name=x.t, prefix=[], dollar=False, file=file, line=x.line, ctx=ctx, modpath=modpath,
                                    fn=[u["name"] for u in fn_stack[-1:]], in_def=in_def, impl=impl_name, args=sorted(set(idents(kids[i + 2].kids)))[:40], args_fns=fn_names_in(kids[i + 2].kids)[:20]))
            walk(kids[i + 2].kids, "body" if ctx in ("body",) else ("def" if ctx == "def" else "other"), modpath, fn_stack, cr, file, in_def)
            i += 3; start = i if (kids[i - 1].d == "{" ) else start; continue
        if x.k == "i" and ctx == "body" and fn_stack and i + 1 < n and isg(kids[i + 1], "(") and x.t not in KW:
            u = fn_stack[-1]; cr.calls[x.t].add((u["file"], u["fn_line"], u["name"]))
        if x.k == "i" and ctx != "def":
            if x.t == "fn" and i + 1 < n and isid(kids[i + 1]) and at_item_start(kids, start, i):
                j = i + 2
                while j < n and not (isg(kids[j], "{") or isp(kids[j], ";")): j += 1
                if j < n and isg(kids[j], "{"):
                    unit = dict(file=file, name=kids[i + 1].t, fn_line=x.line, start_line=kline(kids, start, i),
                                modpath=modpath, ctx=ctx, impl=impl_name, end=kids[j].end)
                    cr.units.append(unit)
                    walk(kids[j].kids, "body", modpath, fn_stack + [unit], cr, file, None)
                i = j + 1; start = i; continue
            if x.t in ("impl", "trait") and at_item_start(kids, start, i):
                j = i + 1
                while j < n and not (isg(kids[j], "{") or isp(kids[j], ";")): j += 1
                if j < n and isg(kids[j], "{"):
                    hdr = [t.t for t in flat(kids[i + 1:j]) if t.k == "i"]
                    walk(kids[j].kids, x.t, modpath, fn_stack, cr, file, None, impl_name="/".join(hdr[:6]))
                i = j + 1; start = i; continue
            if x.t == "mod" and i + 2 < n and isid(kids[i + 1]) and at_item_start(kids, start, i):
                if isg(kids[i + 2], "{"):
                    walk(kids[i + 2].kids, "item", modpath + [kids[i + 1].t], fn_stack, cr, file, None)
                    i += 3; start = i; continue
        i += 1

def kline(kids, start, i):
    x = kids[start] if start < len(kids) else kids[i]
    return x.line if isinstance(x, (Tok, Grp)) else 0

def fn_names_in(kids):
    out, fl = [], list(kids)
    for a, b in zip(fl, fl[1:]):
        if isid(a, "fn") and isid(b): out.append(b.t)
    for x in kids:
        if isinstance(x, Grp): out += fn_names_in(x.kids)
    return out

def modpath_of(rel):
    parts = rel[:-3].split("/")
    if parts[0] in ("src",): parts = parts[1:]
    if parts and parts[0] == "bin": return []
    if parts and parts[-1] in ("lib", "main", "mod"): parts = parts[:-1]
    return parts

SKIP_DIRS = {"target", "tests", "benches", "examples", ".git", "node_modules"}
def crate_files(root):
    for dp, dn, fn in os.walk(root):
        dn[:] = [d for d in dn if d not in SKIP_DIRS]
        for f in fn:
            if f.endswith(".rs"): yield os.path.join(dp, f)

def analyse_crate(root, files=None):
    cr = Crate(root)
    for f in (files or sorted(crate_files(root))):
        try: src = open(f, encoding="utf-8", errors="replace").read()
        except OSError: continue
        rel = os.path.relpath(f, root)
        walk(lex(src), "item", modpath_of(rel), [], cr, rel)
    return cr

# ───────────────────────── site attribution ─────────────────────────
def macro_closure(cr, name, depth=3, seen=None):
    """(effects, emits, names) of a macro including path-invoked/bare local macros nested in its body (<= depth)."""
    seen = seen or set()
    if name in seen or name not in cr.defs: return set(), False, set(), False
    seen = seen | {name}
    eff, emits, names, impl = set(), False, set(), False
    for d in cr.defs[name]:
        eff |= set(d["effects"]); emits |= d["fn"] or d["impl"]; impl |= d["impl"]; names |= set(d["fnnames"])
        names |= {"call:" + c for c in d["callees"]}
    if depth:
        for v in cr.invs:
            if v["in_def"] == name and v["name"] in cr.defs:
                e2, m2, n2, i2 = macro_closure(cr, v["name"], depth - 1, seen)
                eff |= e2; emits |= m2; names |= n2; impl |= i2
    return eff, emits, names, impl

def sites_for(cr):
    """One record per (source path-invoked local macro site) and per (outer source invocation of a macro whose
    body path-invokes a local macro: 'nested')."""
    out = []
    by_outer = defaultdict(list)
    for v in cr.invs:
        if v["in_def"] is None: by_outer[v["name"]].append(v)
    def add(site, via):
        tgt = site["name"]
        eff, emits, names, impl = macro_closure(cr, tgt)
        eff_strong = sorted(eff & STRONG); weak = sorted(eff - STRONG)
        cand = list(site.get("args_fns") or [])
        lit = [n for n in names if not n.startswith("call:")]
        cand += lit
        bound = any(re.search(r"\bfn\s*\$", d.get("text", "")) for d in cr.defs[tgt])
        if bound: cand += [x for x in site["args"] if x not in KW][:12]
        cand = sorted(set(cand))[:16]
        callers = {c: sorted(cr.calls.get(c, ()))[:6] for c in cand if c in cr.calls}
        out.append(dict(target=tgt, via=via, args_fns=site.get("args_fns") or [], cand=cand, callers=callers, file=site["file"], line=site["line"], ctx=site["ctx"], modpath=site["modpath"],
                        fn=site["fn"][0] if site["fn"] else None, impl=site.get("impl"), args=site["args"],
                        prefix="::".join((["$"] if site["dollar"] else []) + site["prefix"]),
                        effects=eff_strong, weak=weak, emits=emits, emits_impl=impl,
                        fnnames=sorted(n for n in names if not n.startswith("call:"))[:30],
                        callees=sorted(n[5:] for n in names if n.startswith("call:"))[:80],
                        inner=[site.get("ifile", site["file"]), site.get("iline", site["line"])]))
    for v in cr.invs:
        if v["name"] not in cr.defs or not v["prefix"]: continue       # path-invoked, local macro only
        if v["in_def"] is None: add(v, "direct")
        else:
            # nested: attribute to every source invocation of the outermost macro (depth <= 3)
            frontier, seen, depth = {v["in_def"]}, set(), 0
            while frontier and depth < 4:
                nxt = set()
                for m in frontier:
                    if m in seen: continue
                    seen.add(m)
                    for o in by_outer.get(m, []):
                        s2 = dict(v); s2.update(args_fns=o.get("args_fns"), ifile=v["file"], iline=v["line"], file=o["file"], line=o["line"], ctx=o["ctx"], modpath=o["modpath"], fn=o["fn"], impl=o.get("impl"), args=o["args"])
                        add(s2, "nested:" + m)
                    for w in cr.invs:                                     # outer macro invoked from another macro body
                        if w["name"] == m and w["in_def"]: nxt.add(w["in_def"])
                frontier, depth = nxt, depth + 1
    for v in cr.invs:   # sites that live in a macro body that nobody invokes from source: record them once as unattributed
        pass
    return out

def cmd_sites(a):
    roots = list(a.crates or [])
    if a.roster:
        for ln in open(a.roster):
            ln = ln.strip()
            if ln: roots.append(ln.split()[0])
    n_cr = n_site = 0
    with open(a.out, "w") as fo:
        for r in roots:
            if not os.path.isdir(r): continue
            n_cr += 1
            cr = analyse_crate(r)
            ss = sites_for(cr)
            raw = sum(1 for v in cr.invs if v["prefix"] and v["name"] in cr.defs)
            dd = [d for ds in cr.defs.values() for d in ds]
            fo.write(json.dumps(dict(crate=r, units=len(cr.units), defs=len(dd), defs_effect=sum(1 for d in dd if set(d["effects"]) & STRONG),
                                     defs_emit=sum(1 for d in dd if d["fn"] or d["impl"]), raw_path_sites=raw,
                                     raw_all_path=sum(1 for v in cr.invs if v["prefix"]),
                                     units_list=[(u["file"], u["fn_line"], u["start_line"], u["name"], u["modpath"], u["ctx"], u["impl"]) for u in cr.units] if ss else [],
                                     sites=ss)) + "\n")
            n_site += len(ss)
    print(f"sites: {n_cr} crates scanned, {n_site} attributed site records -> {a.out}")

# ───────────────────────── scan + join ─────────────────────────
def crate_key(r): return os.path.basename(r.rstrip("/"))

def cmd_scan(a):
    import concurrent.futures as cf
    todo = []
    for ln in open(a.sites):
        j = json.loads(ln)
        if j["sites"]: todo.append(j["crate"])
    os.makedirs(a.work, exist_ok=True)
    def one(r):
        k = crate_key(r); out = f"{a.work}/{k}/r"
        if glob.glob(out + ".*.scan.json"): return k, "cached"
        os.makedirs(os.path.dirname(out), exist_ok=True)
        env = dict(os.environ, CANDOR_CACHE_DIR=f"{a.work}/cache")
        try:
            p = subprocess.run([a.scan_bin, r, "--out", out], capture_output=True, env=env, timeout=a.timeout, text=True)
            return k, f"rc={p.returncode}"
        except subprocess.TimeoutExpired: return k, "timeout"
    with cf.ThreadPoolExecutor(a.jobs) as ex:
        res = list(ex.map(one, todo))
    c = Counter(r for _, r in res)
    print("scan:", dict(c), f"({len(todo)} crates)")

def load_report(work, crate):
    d = f"{work}/{crate_key(crate)}"
    fs = sorted(glob.glob(d + "/r.*.scan.json"))
    if not fs: return None
    j = json.load(open([f for f in fs if not f.endswith("callgraph.json")][0]))
    cg = {}
    g = [f for f in glob.glob(d + "/r.*.scan.callgraph.json")]
    if g: cg = json.load(open(g[0]))
    return j, cg

def reading(row_list, effects):
    """classify one unit's report rows (loc match) relative to the macro's effect classes."""
    if not row_list: return None
    inf = set()
    why = []
    for r in row_list:
        inf |= set(r.get("inferred") or [])
        why += r.get("unknownWhy") or []
    conc = inf - {"Unknown"}
    if conc & set(effects): return "CHARGED-MATCH", why
    if "Unknown" in inf: return ("UNKNOWN+other" if conc else "UNKNOWN"), why
    if conc: return "CHARGED-OTHER", why
    return "PURE?", why

def locate(rep, cg, site, units):
    """map a body-position site to its enclosing unit's reading."""
    if rep is None: return "NOREPORT", [], None
    j, g = rep
    cand = [u for u in units if u[0] == site["file"] and u[2] <= site["line"] <= 10**9 and u[1] <= site["line"]]
    # innermost enclosing fn by start line (units are (file, fn_line, start_line, name, modpath, ctx, impl))
    cand = [u for u in cand if u[3] == site["fn"]] or cand
    if not cand: return "NOUNIT", [], None
    u = max(cand, key=lambda u: u[1])
    rows = [f for f in j.get("functions", []) if f.get("loc", "").split(":")[0] == u[0] and
            u[2] <= int(f["loc"].split(":")[1]) <= u[1]]
    rd = reading(rows, site["effects"])
    if rd: return rd[0], rd[1], u[3]
    keys = [k for k in g if k == u[3] or k.endswith("::" + u[3])]
    if keys: return "PURE(callgraph)", [], u[3]
    return "ABSENT", [], u[3]

def unit_reading(rep, file, fn_line, name, effects=()):
    j, g = rep
    rows = []
    for f in j.get("functions", []):
        loc = f.get("loc", "").split(":")
        if len(loc) > 1 and loc[0] == file and fn_line - 4 <= int(loc[1]) <= fn_line: rows.append(f)
    rd = reading(rows, effects)
    if rd: return rd
    if any(k == name or k.endswith("::" + name) for k in g): return "PURE(callgraph)", []
    return "ABSENT", []

def emitted_reading(rep, site):
    """item/trait/impl-position emitter: do the names it would emit appear in the report, and if not, how do the
    in-crate CALLERS of those names read (silent = pure/absent, disclosed = Unknown or charged)?"""
    if rep is None: return "NOREPORT", []
    j, g = rep
    if not site["cand"]: return "NO-CAND", []
    mp = "::".join(site["modpath"])
    def present(n): return any((k == n or k.endswith("::" + n)) and (not mp or k.startswith(mp + "::") or True) for k in g)
    absent = [n for n in site["cand"] if not present(n)]
    if not absent: return "EMITTED-VISIBLE", []
    rds = []
    for n in absent:
        for (f, fl, fnm) in site["callers"].get(n, []):
            rd = unit_reading(rep, f, fl, fnm)
            rds.append((n, fnm, rd[0]))
    if not rds: return "ABSENT-NO-INCRATE-CALLER", absent[:4]
    if any(r[2] in ("PURE(callgraph)", "ABSENT", "PURE?") for r in rds): return "ABSENT-CALLER-SILENT", [f"{n}<-{u}:{r}" for n, u, r in rds][:4]
    return "ABSENT-CALLER-DISCLOSED", [f"{n}<-{u}:{r}" for n, u, r in rds][:4]

def cmd_join(a):
    rows = []; totals = Counter()
    for ln in open(a.sites):
        j = json.loads(ln)
        totals["all_crates"] += 1; totals["all_defs"] += j.get("defs", 0); totals["all_defs_effect"] += j.get("defs_effect", 0)
        totals["all_defs_emit"] += j.get("defs_emit", 0)
        if not j["sites"]: continue
        rep = load_report(a.work, j["crate"])
        units = [tuple(u) for u in j["units_list"]]
        crate_why = []
        eff_names = set()
        if rep:
            crate_why = [w for f in rep[0].get("functions", []) for w in (f.get("unknownWhy") or [])]
            eff_names = {f["fn"].split("::")[-1] for f in rep[0].get("functions", []) if set(f.get("inferred") or []) - {"Unknown"}}
        totals["defs"] += j.get("defs", 0); totals["defs_effect"] += j.get("defs_effect", 0); totals["defs_emit"] += j.get("defs_emit", 0)
        totals["crates"] += 1
        for s in j["sites"]:
            s = dict(s); s["crate"] = crate_key(j["crate"])
            s["callee_eff"] = sorted(set(s["callees"]) & eff_names)[:12]
            s["emits_any"] = s["emits"] or bool(s["args_fns"])
            s["bearing"] = bool(s["effects"]) or s["emits_any"] or bool(s["callee_eff"])
            if s["ctx"] == "body":
                s["reading"], s["why"], s["unit"] = locate(rep, rep[1] if rep else {}, s, units)
            else:
                s["reading"], s["why"] = emitted_reading(rep, s)
                s["unit"] = None
            rows.append(s)
    json.dump(rows, open(a.out, "w"))
    print("corpus totals (detector-fires evidence):", dict(totals))
    summarise(rows)

POS = {"item": "item", "other": "item", "body": "body", "trait": "trait-item", "impl": "impl-item", "def": "def"}
def summarise(rows):
    def tab(title, sel):
        sub = [r for r in rows if sel(r)]
        print(f"\n== {title}: {len(sub)} sites in {len({r['crate'] for r in sub})} crates")
        for via in ("direct", "nested"):
            s2 = [r for r in sub if r["via"].startswith(via)]
            print(f"  -- via={via}: {len(s2)} records, {len({(r['crate'], tuple(r['inner'])) for r in s2})} distinct source sites, {len({r['crate'] for r in s2})} crates")
            for pos in ("item", "body", "trait-item", "impl-item"):
                s3 = [r for r in s2 if POS.get(r["ctx"]) == pos]
                if not s3: continue
                c = Counter(r["reading"] for r in s3)
                print(f"     {pos:10} {len(s3):6}  " + "  ".join(f"{k}={v}" for k, v in sorted(c.items(), key=lambda kv: -kv[1])))
    tab("ALL path-invoked LOCAL macro sites", lambda r: True)
    tab("BEARING (effect-bearing or emits fn/impl)", lambda r: r["bearing"])
    tab("EFFECT-BEARING only (strong effect classes)", lambda r: bool(r["effects"]))
    tab("REACHES an effectful report row by callee name", lambda r: bool(r["callee_eff"]))
    tab("EMITS fn/impl (macro body or invocation args)", lambda r: r["emits_any"])

def cmd_sample(a):
    rows = [r for r in json.load(open(a.joined)) if r["bearing"]]
    random.Random(a.seed).shuffle(rows)
    strata = defaultdict(list)
    for r in rows: strata[(POS.get(r["ctx"]), r["reading"])].append(r)
    out, per = [], max(1, a.n // max(1, len(strata)))
    for k, v in sorted(strata.items(), key=lambda kv: str(kv[0])): out += v[:per]
    for r in out[:a.n]:
        print(json.dumps({k: r[k] for k in ("crate", "file", "line", "ctx", "via", "target", "prefix", "unit", "reading", "why", "effects", "emits")}))

# ───────────────────────── selftest ─────────────────────────
FIXTURE = r'''
#[macro_export] macro_rules! wr { ($p:expr) => { ::std::fs::write($p, b"x").unwrap() } }
#[macro_export] macro_rules! mk { ($n:ident) => { fn $n() { ::std::fs::write("a", b"x").unwrap(); } } }
macro_rules! outer { () => { $crate::wr!("o") } }
macro_rules! quiet { () => { 1 + 1 } }
macro_rules! shadow { () => { println!("x") } }
pub fn body_site() { crate::wr!("p"); }
pub fn body_quiet() { let _ = self::quiet!(); }
pub fn body_nested() { outer!(); }
crate::mk! { item_made }
pub trait T { crate::mk! { trait_made } }
pub struct S;
impl S { self::mk! { impl_made } }
mod m { pub fn deep() { super::wr!("q"); } }
fn lt<'a>(x: &'a str) -> char { let c = '\''; let _ = "crate::wr!(\"no\")"; /* crate::wr!("c") */ c }
'''

def selftest():
    d = tempfile.mkdtemp(prefix="macrocensus-selftest-")
    os.makedirs(d + "/src"); open(d + "/src/lib.rs", "w").write(FIXTURE)
    cr = analyse_crate(d)
    ss = sites_for(cr)
    got = {(s["ctx"], s["target"], s["via"].split(":")[0], s["fn"] or "") for s in ss}
    want = {("body", "wr", "direct", "body_site"), ("body", "quiet", "direct", "body_quiet"),
            ("item", "mk", "direct", ""), ("trait", "mk", "direct", ""), ("impl", "mk", "direct", ""),
            ("body", "wr", "direct", "deep"), ("body", "wr", "nested", "body_nested")}
    ok = True
    for w in sorted(want):
        hit = w in got
        print(("OK   " if hit else "FAIL ") + "seeded site " + str(w)); ok &= hit
    extra = got - want
    for e in sorted(extra): print("FAIL unexpected site", e); ok = False       # strings/comments must not fire
    # bearing flags
    by = {(s["ctx"], s["target"], s["fn"] or ""): s for s in ss if s["via"] == "direct"}
    chk = [("quiet is NOT bearing", not (by[("body", "quiet", "body_quiet")]["effects"] or by[("body", "quiet", "body_quiet")]["emits"])),
           ("wr is Fs-bearing", by[("body", "wr", "body_site")]["effects"] == ["Fs"]),
           ("mk emits fn", by[("item", "mk", "")]["emits"] and not by[("item", "mk", "")]["effects"] == [])]
    for t, v in chk: print(("OK   " if v else "FAIL ") + t); ok &= bool(v)
    # reading classifier must be able to say each of its categories
    cls = {reading([dict(inferred=["Fs"])], ["Fs"])[0], reading([dict(inferred=["Unknown"], unknownWhy=["macro:x"])], ["Fs"])[0],
           reading([dict(inferred=["Net"])], ["Fs"])[0], reading([dict(inferred=[])], ["Fs"])[0]}
    want_cls = {"CHARGED-MATCH", "UNKNOWN", "CHARGED-OTHER", "PURE?"}
    print(("OK   " if cls == want_cls else "FAIL ") + f"reading categories {sorted(cls)}"); ok &= cls == want_cls
    print("selftest:", "OK" if ok else "FAILED"); return 0 if ok else 1

def main():
    if "--selftest" in sys.argv: sys.exit(selftest())
    p = argparse.ArgumentParser(); sp = p.add_subparsers(dest="cmd", required=True)
    s = sp.add_parser("sites"); s.add_argument("--roster"); s.add_argument("--crates", nargs="*"); s.add_argument("--out", required=True)
    s = sp.add_parser("scan"); s.add_argument("--sites", required=True); s.add_argument("--scan-bin", required=True)
    s.add_argument("--work", required=True); s.add_argument("--jobs", type=int, default=2); s.add_argument("--timeout", type=int, default=900)
    s = sp.add_parser("join"); s.add_argument("--sites", required=True); s.add_argument("--work", required=True); s.add_argument("--out", required=True)
    s = sp.add_parser("sample"); s.add_argument("--joined", required=True); s.add_argument("--n", type=int, default=40); s.add_argument("--seed", type=int, default=1)
    a = p.parse_args()
    {"sites": cmd_sites, "scan": cmd_scan, "join": cmd_join, "sample": cmd_sample}[a.cmd](a)

if __name__ == "__main__": main()
