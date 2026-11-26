#!/usr/bin/env python3
"""bin/corpus-macro-census.py — count PATH-INVOKED LOCAL MACRO sites that matter to candor-scan (rust).

    corpus-macro-census.py sites  --roster FILE|--crates D... --out sites.jsonl
    corpus-macro-census.py scan   --sites sites.jsonl --scan-bin BIN --work DIR [--jobs N]
    corpus-macro-census.py join   --sites sites.jsonl --work DIR --out joined.json
    corpus-macro-census.py sample --joined joined.json --n 40 --seed 1
    corpus-macro-census.py --selftest [--scan-bin BIN]
    corpus-macro-census.py dep-sites|dep-scan|dep-join|dep-sample ...   (M-c1: DEPENDENCY macros; see the DEP-MODE block)

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
    def __init__(s, root):
        s.root = root; s.defs = {}; s.invs = []; s.units = []; s.calls = defaultdict(set)
        s.finvs = []                     # dep-mode: invocations with a FOREIGN path prefix (`D::m!`)
        s.ctest = 0; s.cfgx = 0          # dep-mode: depth inside #[cfg(test)]/#[test] items / other #[cfg(..)] items

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

def item_gate(kids, start, i):
    """(test, cfg) for the attributes in kids[start:i]: `#[test]`/`#[cfg(test)]` -> test; any other `#[cfg(..)]` -> cfg."""
    test = cfg = False
    for j in range(start, i):
        x = kids[j]
        if isg(x, "["):
            ids = [t.t for t in flat(x.kids) if t.k == "i"]
            if ids[:1] == ["test"] or (ids[:1] == ["cfg"] and "test" in ids and "not" not in ids): test = True
            elif ids[:1] in (["cfg"], ["cfg_attr"]): cfg = True
    return test, cfg

def unit_of(fn_stack):
    u = fn_stack[-1] if fn_stack else None
    return None if u is None else [u["file"], u["fn_line"], u["start_line"], u["name"], u["end"]]

def crate_calls(kids):
    """`$crate::a::b::f(` call paths in a macro body -> list of segment lists (the callee is the last segment)."""
    out, n = [], len(kids)
    for i, x in enumerate(kids):
        if isp(x, "$") and i + 1 < n and isid(kids[i + 1], "crate"):
            j, segs = i + 2, []
            while j + 2 < n and isp(kids[j], ":") and isp(kids[j + 1], ":") and isid(kids[j + 2]):
                segs.append(kids[j + 2].t); j += 3
            if j + 2 < n and isp(kids[j], ":") and isp(kids[j + 1], ":") and isp(kids[j + 2], "<"):   # turbofish
                d, j = 0, j + 2
                while j < n:
                    if isp(kids[j], "<"): d += 1
                    elif isp(kids[j], ">"):
                        d -= 1
                        if d == 0: j += 1; break
                    j += 1
            if segs and j < n and isg(kids[j], "("): out.append(segs)
        if isinstance(x, Grp): out += crate_calls(x.kids)
    return out

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
                                                      fnnames=fn_names_in(g.kids), callees=sorted(callees_in(g.kids)), ccalls=crate_calls(g.kids), end=g.end,
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
                                    args=sorted(set(idents(args.kids)))[:40], args_fns=fn_names_in(args.kids)[:20],
                                    unit=unit_of(fn_stack), ctest=cr.ctest > 0, cfgx=cr.cfgx > 0))
            elif segs:
                cr.finvs.append(dict(name=x.t, prefix=segs, file=file, line=x.line, ctx=ctx, in_def=in_def, unit=unit_of(fn_stack),
                                     ctest=cr.ctest > 0, cfgx=cr.cfgx > 0))
            elif not segs:
                cr.invs.append(dict(name=x.t, prefix=[], dollar=False, file=file, line=x.line, ctx=ctx, modpath=modpath,
                                    fn=[u["name"] for u in fn_stack[-1:]], in_def=in_def, impl=impl_name, args=sorted(set(idents(kids[i + 2].kids)))[:40], args_fns=fn_names_in(kids[i + 2].kids)[:20],
                                    unit=unit_of(fn_stack), ctest=cr.ctest > 0, cfgx=cr.cfgx > 0))
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
                    gt, gc = item_gate(kids, start, i); cr.ctest += gt; cr.cfgx += gc
                    walk(kids[j].kids, "body", modpath, fn_stack + [unit], cr, file, None)
                    cr.ctest -= gt; cr.cfgx -= gc
                i = j + 1; start = i; continue
            if x.t in ("impl", "trait") and at_item_start(kids, start, i):
                j = i + 1
                while j < n and not (isg(kids[j], "{") or isp(kids[j], ";")): j += 1
                if j < n and isg(kids[j], "{"):
                    hdr = [t.t for t in flat(kids[i + 1:j]) if t.k == "i"]
                    gt, gc = item_gate(kids, start, i); cr.ctest += gt; cr.cfgx += gc
                    walk(kids[j].kids, x.t, modpath, fn_stack, cr, file, None, impl_name="/".join(hdr[:6]))
                    cr.ctest -= gt; cr.cfgx -= gc
                i = j + 1; start = i; continue
            if x.t == "mod" and i + 2 < n and isid(kids[i + 1]) and at_item_start(kids, start, i):
                if isg(kids[i + 2], "{"):
                    gt, gc = item_gate(kids, start, i); cr.ctest += gt; cr.cfgx += gc
                    walk(kids[i + 2].kids, "item", modpath + [kids[i + 1].t], fn_stack, cr, file, None)
                    cr.ctest -= gt; cr.cfgx -= gc
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

# ═════════════════════ DEP-MODE (M-c1): a DEPENDENCY's macro_rules! at expression position ═════════════════════
# The shape (S-c1, Fable's rust-macropath review §3): a consumer crate C invokes `D::m!()` / `use D::m; m!()` / bare `m!()`
# (via `#[macro_use] extern crate D` or a glob) at fn-body position; D's `macro_rules! m` expands to a call of D's own
# effectful fn.  Standalone the enclosing unit reads `[] invisible:[D]`; chained with D's real report the unit is ABSENT,
# because a macro is not a unit and the join finds no key `D::m` -- the chain DELETES the only disclosure.
#
#     dep-sites  --roster FILE [--seeds DIR...] --out dsites.jsonl      step (1) + the static half of step (2)
#     dep-scan   --dsites F --scan-bin BIN --work DIR [--jobs 2]         scan D (for (2)(b)), C standalone, C chained
#     dep-join   --dsites F --work DIR --out joined.json                 the four-prefix table, by spelling
#     dep-sample --joined F --n 20 [--seed 1]                            macro bodies to READ (criterion check)
#
# FOUR PREFIXES, each a conjunction over the one before:
#   (1) a fn-body invocation whose macro resolves, through the module's `use`s / `#[macro_use] extern crate` / globs and the
#       dependency's Cargo.toml requirement, to a dependency D that is not std/core/alloc/log/tracing/cfg_if
#   (2) D's macro (any arm, nested macros to depth 3) names a std effect locator (a), OR calls `$crate::path::f(` where D's OWN
#       standalone report has a row for f carrying a concrete effect or Unknown (b)
#   (3) the enclosing unit reads [] (no concrete effect, no Unknown) with D in `invisible`, scanned standalone by main
#   (4) chained with D's real report the unit is ABSENT / carries no D disclosure, no concrete effect and no Unknown --
#       on a consumer whose chain is LIVE (some row differs between the arms; the judge's rule) and D joined.
# Instrument limits, stated: `use` maps are per FILE (module scoping inside one file is not modelled); a dependency macro
# re-exported by `pub use` in another module is counted only as the REEXP spelling; test-gated sites (#[cfg(test)], #[test])
# are counted apart and excluded; closures are not units (the site is attributed to the enclosing fn's row).
import shutil

DEP_SKIP_HEADS = {"std", "core", "alloc", "log", "tracing", "cfg_if"}
STD_BARE = {"println", "eprintln", "print", "eprint", "format", "write", "writeln", "vec", "panic", "assert", "assert_eq",
            "assert_ne", "debug_assert", "debug_assert_eq", "debug_assert_ne", "matches", "todo", "unimplemented",
            "unreachable", "dbg", "format_args", "concat", "stringify", "include_str", "include_bytes", "include", "env",
            "option_env", "line", "file", "column", "module_path", "cfg", "compile_error", "thread_local", "macro_rules",
            "try", "ready", "pin", "join"}
REG_GLOB = os.path.expanduser("~/.cargo/registry/src/*/*")
_REG = None
def reg_index():
    global _REG
    if _REG is None:
        _REG = defaultdict(list)
        for d in glob.glob(REG_GLOB):
            m = re.match(r"^(.+?)-(\d+\.\d+\.\d+(?:[-+].*)?)$", os.path.basename(d))
            if m: _REG[m.group(1)].append((m.group(2), d))
    return _REG

def semver(v):
    m = re.match(r"(\d+)(?:\.(\d+))?(?:\.(\d+))?", v)
    return tuple(int(x or 0) for x in m.groups()) if m else (0, 0, 0)

def req_ok(req, ver):
    v = semver(ver)
    for part in [p.strip() for p in req.split(",") if p.strip()]:
        m = re.match(r"^(\^|~|=|>=|<=|>|<)?\s*(.*)$", part)
        op, rv = (m.group(1) or "^"), m.group(2)
        if rv in ("*", ""): continue
        r = semver(rv); nparts = len(rv.split("."))
        if op == "=":
            if v[:nparts] != r[:nparts]: return False
        elif op == ">=":
            if v < r: return False
        elif op == "<=":
            if v > r: return False
        elif op == ">":
            if v <= r: return False
        elif op == "<":
            if v >= r: return False
        elif op == "~":
            k = max(1, min(2, nparts))
            if not (v >= r and v[:k] == r[:k]): return False
        else:   # ^
            if v < r: return False
            lead = next((i for i, x in enumerate(r) if x), 2)
            if v[:lead + 1] != r[:lead + 1]: return False
    return True

def parse_cargo(path):
    """-> (deps, libname, proc_macro).  deps: key -> dict(package, version, path, workspace, optional).  Normal + target
    dependencies only (dev- and build-dependencies never reach a fn body this census reads)."""
    deps, libname, procm = {}, None, False
    try: lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    except OSError: return deps, libname, procm
    sect, i = "", 0
    def add(key, text):
        d = deps.setdefault(key, dict(package=None, version=None, path=None, workspace=False, optional=False))
        for f, rx in (("package", r'package\s*=\s*"([^"]+)"'), ("version", r'version\s*=\s*"([^"]+)"'), ("path", r'path\s*=\s*"([^"]+)"')):
            m = re.search(rx, text)
            if m: d[f] = m.group(1)
        if re.search(r'workspace\s*=\s*true', text): d["workspace"] = True
        if re.search(r'optional\s*=\s*true', text): d["optional"] = True
        if d["version"] is None:
            m = re.match(r'^\s*"([^"]*)"', text)
            if m: d["version"] = m.group(1)
    while i < len(lines):
        ln = lines[i].strip(); i += 1
        if not ln or ln.startswith("#"): continue
        if ln.startswith("["):
            sect = ln.strip("[] ").strip(); continue
        if sect == "lib":
            m = re.match(r'name\s*=\s*"([^"]+)"', ln)
            if m: libname = m.group(1)
            if re.match(r'proc[-_]macro\s*=\s*true', ln): procm = True
            continue
        if not re.search(r"(^|\.)dependencies(\.|$)", sect) or "dev-dependencies" in sect or "build-dependencies" in sect: continue
        m = re.search(r"dependencies\.([^.]+)$", sect)
        if m:                                   # [dependencies.foo] table: key = value lines
            add(m.group(1).strip("'\""), ln); continue
        m = re.match(r'^([A-Za-z0-9_\-]+)\s*=\s*(.*)$', ln)
        if m:
            key, rest = m.group(1), m.group(2)
            while rest.count("{") > rest.count("}") and i < len(lines): rest += " " + lines[i].strip(); i += 1
            add(key, rest); continue
        m = re.match(r'^([A-Za-z0-9_\-]+)\.(workspace|version|package|path|optional)\s*=\s*(.*)$', ln)
        if m: add(m.group(1), f'{m.group(2)} = {m.group(3)}')
    return deps, libname, procm

def resolve_dep(croot, key, info):
    """-> dict(key, lib, pkg, ver, dir, how) ; dir None when D is neither a path dep nor in the registry."""
    pkg = info.get("package") or key
    lib = key.replace("-", "_")
    if info.get("path"):
        d = os.path.normpath(os.path.join(croot, info["path"]))
        if os.path.isdir(d): return dict(key=key, lib=lib, pkg=pkg, ver="path", dir=d, how="path")
    cands = sorted(reg_index().get(pkg, []), key=lambda t: semver(t[0]))
    if not cands: return dict(key=key, lib=lib, pkg=pkg, ver=None, dir=None, how="NOT-IN-REGISTRY")
    req = info.get("version")
    if req and not info.get("workspace"):
        ok = [c for c in cands if req_ok(req, c[0])]
        if ok: return dict(key=key, lib=lib, pkg=pkg, ver=ok[-1][0], dir=ok[-1][1], how="req-match")
        return dict(key=key, lib=lib, pkg=pkg, ver=cands[-1][0], dir=cands[-1][1], how="FALLBACK-highest(no match for %s)" % req)
    return dict(key=key, lib=lib, pkg=pkg, ver=cands[-1][0], dir=cands[-1][1], how="FALLBACK-highest(no req)")

# ---- use / extern crate maps ----
def parse_use_tree(seq, j, prefix, out, globs):
    segs, n = list(prefix), len(seq)
    while j < n:
        x = seq[j]
        if isp(x, ":") and j + 1 < n and isp(seq[j + 1], ":"): j += 2; continue
        if isid(x, "as"):
            alias = seq[j + 1].t if j + 1 < n and isid(seq[j + 1]) else None
            if alias and alias != "_" and segs: out[alias] = list(segs)
            return j + 2
        if isid(x): segs.append(x.t); j += 1; continue
        if isg(x, "{"):
            cur, subs = [], []
            for kk in x.kids:
                if isp(kk, ","): subs.append(cur); cur = []
                else: cur.append(kk)
            if cur: subs.append(cur)
            for sb in subs: parse_use_tree(sb, 0, segs, out, globs)
            return j + 1
        if isp(x, "*"): globs.append(list(segs)); return j + 1
        break
    if len(segs) > len(prefix):
        last = segs[-1]
        if last == "self":
            if len(segs) >= 2: out[segs[-2]] = segs[:-1]
        else: out[last] = segs
    return j

def collect_uses(kids, uses, globs, exts):
    n = len(kids)
    for i, x in enumerate(kids):
        if isid(x, "use") and not (i and isp(kids[i - 1], "$")):
            j = i + 1; seq = []
            while j < n and not isp(kids[j], ";"): seq.append(kids[j]); j += 1
            parse_use_tree(seq, 0, [], uses, globs)
        elif isid(x, "extern") and i + 2 < n and isid(kids[i + 1], "crate") and isid(kids[i + 2]):
            name, alias, k = kids[i + 2].t, None, i + 3
            if k + 1 < n and isid(kids[k], "as") and isid(kids[k + 1]): alias = kids[k + 1].t
            mu, b = False, i - 1                      # attributes immediately before: `# [ .. ]` pairs
            while b >= 1 and isg(kids[b], "[") and isp(kids[b - 1], "#"):
                if "macro_use" in [t.t for t in flat(kids[b].kids) if t.k == "i"]: mu = True
                b -= 2
            exts.append(dict(name=name, alias=alias, macro_use=mu))
        if isinstance(x, Grp): collect_uses(x.kids, uses, globs, exts)

def crate_files2(root):
    """crate_files minus nested packages (a nested Cargo.toml is a different package to candor-scan), build.rs, tests.rs."""
    for dp, dn, fn in os.walk(root):
        dn[:] = [d for d in dn if d not in SKIP_DIRS and not os.path.exists(os.path.join(dp, d, "Cargo.toml"))]
        for f in fn:
            if f.endswith(".rs") and not (dp == root and f == "build.rs") and f not in ("tests.rs", "test.rs"):
                yield os.path.join(dp, f)

def analyse_dep_crate(root):
    """Crate + per-file use maps + crate-wide extern/macro_use list."""
    cr = Crate(root); cr.fuses = {}; cr.fglobs = {}; cr.exts = []
    for f in sorted(crate_files2(root)):
        try: src = open(f, encoding="utf-8", errors="replace").read()
        except OSError: continue
        rel = os.path.relpath(f, root); toks = lex(src)
        walk(toks, "item", modpath_of(rel), [], cr, rel)
        u, g, e = {}, [], []
        collect_uses(toks, u, g, e)
        cr.fuses[rel], cr.fglobs[rel] = u, g; cr.exts += e
    return cr

_DCR = {}
def dcrate(d):
    if d not in _DCR: _DCR[d] = analyse_dep_crate(d)
    return _DCR[d]

def dep_sites_for(croot, cr, deps):
    """step (1): one record per fn-body invocation that resolves to a dependency D."""
    libs = {}                                   # name as written in code -> resolved dep
    for key, info in deps.items():
        rd = resolve_dep(croot, key, info); libs[rd["lib"]] = rd
    for e in cr.exts:
        if e["alias"] and e["name"] in libs: libs[e["alias"]] = libs[e["name"]]
    mu = [libs[e["name"]] for e in cr.exts if e["macro_use"] and e["name"] in libs]
    allu = {}
    for u in cr.fuses.values():
        for k, v in u.items(): allu.setdefault(k, v)
    def d_has(rd, m): return bool(rd["dir"]) and m in dcrate(rd["dir"]).defs
    out = []
    def emit(v, rd, spell, mname, head):
        out.append(dict(site_file=v["file"], line=v["line"], unit=v["unit"], spelling=spell, macro=mname, head=head, D=rd["lib"], pkg=rd["pkg"],
                        ver=rd["ver"], ddir=rd["dir"], how=rd["how"], ctest=v["ctest"], cfgx=v["cfgx"]))
    def site_ok(v): return v["ctx"] == "body" and v["in_def"] is None and v["unit"] is not None
    for v in cr.finvs:                          # `head::...::m!`
        if not site_ok(v): continue
        head, uses = v["prefix"][0], cr.fuses.get(v["file"], {})
        if head in DEP_SKIP_HEADS: continue
        if head in libs: emit(v, libs[head], "PATH", v["name"], head)
        elif head in uses and uses[head] and uses[head][0] in libs and uses[head][0] not in DEP_SKIP_HEADS:
            emit(v, libs[uses[head][0]], "PATH", v["name"], uses[head][0])
    for v in cr.invs:
        if not site_ok(v): continue
        nm, uses, globs = v["name"], cr.fuses.get(v["file"], {}), cr.fglobs.get(v["file"], [])
        if v["prefix"]:                         # crate::m! / self::m! / super::m! of a re-exported dependency macro
            if v["dollar"] or nm in cr.defs: continue
            p = allu.get(nm)
            if p and p[0] in libs and p[0] not in DEP_SKIP_HEADS: emit(v, libs[p[0]], "REEXP", p[-1], p[0])
            continue
        if nm in cr.defs or (nm in STD_BARE and nm not in uses): continue
        p = uses.get(nm)
        if p and p[0] in libs and len(p) >= 2:
            if p[0] not in DEP_SKIP_HEADS: emit(v, libs[p[0]], "USE", p[-1], p[0])
            continue
        hit = [libs[g[0]] for g in globs if g and g[0] in libs and d_has(libs[g[0]], nm)]
        if hit:
            if hit[0]["lib"] not in DEP_SKIP_HEADS: emit(v, hit[0], "BARE-GLOB", nm, hit[0]["lib"])
            continue
        hit = [rd for rd in mu if d_has(rd, nm)]
        if hit and hit[0]["lib"] not in DEP_SKIP_HEADS: emit(v, hit[0], "BARE-MU", nm, hit[0]["lib"])
    return out

# ---- step (2) ----
def closure2(cr, name, depth=3, seen=None):
    """-> (strong effect classes, weak classes, [$crate:: call segment lists], nested names) over any arm, nested local macros <= depth."""
    seen = seen or set()
    if name in seen or name not in cr.defs: return set(), set(), [], set()
    seen = seen | {name}; eff, weak, cc, nest = set(), set(), [], set()
    for d in cr.defs[name]:
        eff |= set(d["effects"]) & STRONG; weak |= set(d["effects"]) - STRONG; cc += d.get("ccalls") or []
    if depth:
        for v in cr.invs:
            if v["in_def"] == name and v["name"] in cr.defs and v["name"] != name:
                e2, w2, c2, n2 = closure2(cr, v["name"], depth - 1, seen); eff |= e2; weak |= w2; cc += c2; nest |= n2 | {v["name"]}
    return eff, weak, cc, nest

def row_hits(report, segs):
    """D rows matching a `$crate::` call path: (strict, loose)."""
    full = "::".join(segs); strict, loose = [], []
    for f in report.get("functions", []):
        fn = f.get("fn", "")
        if fn == full or fn.endswith("::" + full): strict.append(f)
        elif fn.split("::")[-1] == segs[-1]: loose.append(f)
    return strict, loose

def eval2(ddir, mname, report):
    """-> dict(status, a, b, b_strict, eff, weak, ncc, bclasses).  status: NO-D-SRC | NO-DEF | NEEDS-REPORT | PASS | FAIL (PASS carries a/b)."""
    z = dict(a=False, b=False, b_strict=False, eff=[], weak=[], ncc=0, bclasses=[])
    if not ddir: return dict(z, status="NO-D-SRC")
    cr = dcrate(ddir)
    if mname not in cr.defs: return dict(z, status="NO-DEF")
    eff, weak, cc, nest = closure2(cr, mname)
    a = bool(eff); b = bs = False; bcl = set()
    if cc and report is not None:
        for segs in cc:
            st, lo = row_hits(report, segs)
            for f in st + lo:
                inf = set(f.get("inferred") or [])
                if inf:                                  # a concrete effect or Unknown
                    b = True; bcl |= inf
                    if f in st: bs = True
    stt = "PASS" if (a or b) else ("NEEDS-REPORT" if (cc and report is None) else "FAIL")
    return dict(status=stt, a=a, b=b, b_strict=bs, eff=sorted(eff), weak=sorted(weak), ncc=len(cc), bclasses=sorted(bcl))

def dscan_dir(work, ddir): return f"{work}/D/{os.path.basename(ddir.rstrip('/'))}"
def is_report(f): return f.endswith(".scan.json") and not f.endswith((".callgraph.json", ".hierarchy.json", ".locs.json"))
def dreport(work, ddir):
    fs = [f for f in sorted(glob.glob(dscan_dir(work, ddir) + "/r.*.scan.json")) if is_report(f)]
    if not fs: return None
    try: return json.load(open(fs[0]))
    except (OSError, ValueError): return None

def cmd_dep_sites(a):
    roots = list(a.seeds or [])
    if a.roster: roots += [ln.split()[0] for ln in open(a.roster) if ln.strip()]
    n_cr = 0
    with open(a.out, "w") as fo:
        for r in roots:
            if not os.path.isdir(r): continue
            n_cr += 1
            deps, _, _ = parse_cargo(os.path.join(r, "Cargo.toml"))
            cr = analyse_dep_crate(r)
            ss = dep_sites_for(r, cr, deps) if deps else []
            for s in ss: s["eval0"] = eval2(s["ddir"], s["macro"], None)
            fo.write(json.dumps(dict(crate=r, ckey=crate_key(r), ndeps=len(deps), nunits=len(cr.units),
                                     raw_foreign_body=sum(1 for v in cr.finvs if v["ctx"] == "body"),
                                     macro_use=[e["name"] for e in cr.exts if e["macro_use"]], sites=ss)) + "\n")
    print(f"dep-sites: {n_cr} crates -> {a.out}")

def load_dsites(path): return [json.loads(ln) for ln in open(path) if ln.strip()]

def finalize2(recs, work):
    for rec in recs:
        for s in rec["sites"]:
            s["ev"] = eval2(s["ddir"], s["macro"], dreport(work, s["ddir"]) if s["ddir"] else None)

def run_scan(binp, target, out, deps_dir, work, timeout):
    env = dict(os.environ, CANDOR_CACHE_DIR=f"{work}/cache")
    if deps_dir: env["CANDOR_DEPS"] = deps_dir
    else: env.pop("CANDOR_DEPS", None)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    try: return subprocess.run([binp, target, "--out", out], capture_output=True, env=env, timeout=timeout, text=True).returncode
    except subprocess.TimeoutExpired: return "timeout"

def have(out): return any(is_report(f) for f in glob.glob(out + ".*.scan.json"))

def cmd_dep_scan(a):
    import concurrent.futures as cf
    recs = load_dsites(a.dsites); work = a.work
    for sub in ("D", "C", "cache"): os.makedirs(f"{work}/{sub}", exist_ok=True)
    def par(fn, items, label):
        with cf.ThreadPoolExecutor(a.jobs) as ex: res = list(ex.map(fn, items))
        print(f"dep-scan {label}:", dict(Counter(str(r) for r in res)), f"({len(items)})", flush=True)
    def dscan(d):
        out = dscan_dir(work, d) + "/r"
        if have(out): return "cached"
        return f"rc={run_scan(a.scan_bin, d, out, None, work, a.timeout)}"
    need1 = sorted({s["ddir"] for r in recs for s in r["sites"] if s["ddir"] and s["eval0"]["status"] == "NEEDS-REPORT" and not s["ctest"]})
    par(dscan, need1, "phase1 D scans for (2)(b)")
    finalize2(recs, work)
    live = lambda s: s["ev"]["status"] == "PASS" and not s["ctest"]
    par(dscan, sorted({s["ddir"] for r in recs for s in r["sites"] if s["ddir"] and live(s)}), "phase2 D scans for chaining")
    cs = [r for r in recs if any(live(s) for s in r["sites"])]
    def cscan(r):
        out = f"{work}/C/{r['ckey']}/sa"
        if have(out): return "cached"
        return f"rc={run_scan(a.scan_bin, r['crate'], out, None, work, a.timeout)}"
    par(cscan, cs, "phase3 C standalone")
    def cchain(r):
        ds = sorted({s["ddir"] for s in r["sites"] if live(s)})
        dd = f"{work}/C/{r['ckey']}/dep"
        if os.path.isdir(dd): shutil.rmtree(dd)
        os.makedirs(dd)
        for d in ds:
            for f in glob.glob(dscan_dir(work, d) + "/r.*"):
                try: os.symlink(f, f"{dd}/{os.path.basename(f)}")
                except FileExistsError: pass
        out = f"{work}/C/{r['ckey']}/ch"
        if have(out): return "cached"
        return f"rc={run_scan(a.scan_bin, r['crate'], out, dd, work, a.timeout)}"
    par(cchain, cs, "phase4 C chained")

# ---- step (3)/(4) readings ----
def creport(work, ckey, arm):
    d = f"{work}/C/{ckey}"
    fs = [f for f in sorted(glob.glob(f"{d}/{arm}.*.scan.json")) if is_report(f)]
    if not fs: return None
    j = json.load(open(fs[0])); g = {}
    gs = glob.glob(f"{d}/{arm}.*.scan.callgraph.json")
    if gs:
        try: g = json.load(open(gs[0]))
        except (OSError, ValueError): g = {}
    return j, g

def rows_of(rep, unit):
    j, g = rep; file, fl, sl, name = unit[0], unit[1], unit[2], unit[3]
    rows = []
    for f in j.get("functions", []):
        loc = f.get("loc", "").rsplit(":", 2)
        if len(loc) == 3 and loc[0] == file and loc[1].isdigit() and min(sl, fl) <= int(loc[1]) <= fl: rows.append(f)
    named = [f for f in rows if f["fn"].split("::")[-1] == name]
    return named or rows

def norm(x): return x.replace("-", "_")

def read_unit(rep, unit, D):
    """-> (class, details).  ROW-D-EMPTY (the (3) shape) | ROW-D-UNKNOWN | ROW-CHARGED | ROW-UNKNOWN-NO-D | ROW-NO-D | NOROW-ANALYSED | NOROW-NOT-ANALYSED."""
    rows = rows_of(rep, unit)
    if not rows:
        g = rep[1]; nm = unit[3]
        return ("NOROW-ANALYSED" if any(k == nm or k.endswith("::" + nm) for k in g) else "NOROW-NOT-ANALYSED"), {}
    inf, inv = set(), set()
    for r in rows:
        inf |= set(r.get("inferred") or []); inv |= {norm(x) for x in (r.get("invisible") or [])}
    conc = inf - {"Unknown"}
    det = dict(inferred=sorted(inf), invisible=sorted(inv), fn=rows[0]["fn"])
    if conc: return "ROW-CHARGED", det
    if norm(D) in inv: return ("ROW-D-UNKNOWN" if "Unknown" in inf else "ROW-D-EMPTY"), det
    if "Unknown" in inf: return "ROW-UNKNOWN-NO-D", det
    return "ROW-NO-D", det

def chain_liveness(sa, ch):
    """judge-style liveness: how many rows differ between the arms (inferred / invisible / unknownWhy / presence)."""
    def key(rep): return {f["fn"] + "@" + f.get("loc", ""): (tuple(f.get("inferred") or []), tuple(f.get("invisible") or []), tuple(f.get("unknownWhy") or []))
                          for f in rep[0].get("functions", [])}
    a, b = key(sa), key(ch)
    return sum(1 for k in set(a) | set(b) if a.get(k) != b.get(k))

def join_rows(recs, work):
    finalize2(recs, work)
    rows, dead, live_n = [], [], 0
    for rec in recs:
        sa = creport(work, rec["ckey"], "sa"); ch = creport(work, rec["ckey"], "ch")
        live = diff = None
        if sa and ch:
            diff = chain_liveness(sa, ch); live = diff > 0
            if live: live_n += 1
            else: dead.append(rec["ckey"])
        for s in rec["sites"]:
            s = dict(s); s["crate"] = rec["ckey"]; s["live"] = live; s["rowsdiff"] = diff
            s["p1"] = not s["ctest"]
            s["p2"] = s["p1"] and s["ev"]["status"] == "PASS"
            s["r3"] = s["r4"] = None; s["p3"] = s["p4"] = s["p3u"] = False
            if s["p2"] and sa:
                s["r3"], s["d3"] = read_unit(sa, s["unit"], s["D"])
                s["p3"] = s["r3"] == "ROW-D-EMPTY"; s["p3u"] = s["r3"] == "ROW-D-UNKNOWN"
            if s["p3"] and ch:
                s["r4"], s["d4"] = read_unit(ch, s["unit"], s["D"])
                cov = ch[0].get("coverage")
                unc = cov.get("uncovered", []) if isinstance(cov, dict) else []
                s["d_uncovered_in_chain"] = any(norm(u.get("name", "")) == norm(s["D"]) for u in unc)
                s["p4"] = bool(live) and s["r4"] in ("NOROW-ANALYSED", "ROW-NO-D") and not s["d_uncovered_in_chain"]
            rows.append(s)
    # DEAD-JOIN means a chain that should have joined and did not: only a consumer holding a (3) site can say so.
    p3c = {r["crate"] for r in rows if r["p3"]}
    dead = [c for c in dead if c in p3c]
    return rows, dead, live_n

def cmd_dep_join(a):
    rows, dead, live_n = join_rows(load_dsites(a.dsites), a.work)
    json.dump(rows, open(a.out, "w"))
    dep_summary(rows, dead, live_n)

SPELLS = ("PATH", "USE", "BARE-MU", "BARE-GLOB", "REEXP")
def dep_cnt(rows, sel):
    sub = [r for r in rows if sel(r)]
    return len(sub), len({(r["crate"], tuple(r["unit"][:4])) for r in sub}), len({r["crate"] for r in sub})

def dep_summary(rows, dead, live_n):
    print(f"\nrows (all dependency-macro body sites incl. test-gated): {len(rows)}; test-gated (excluded from P1): {sum(1 for r in rows if r['ctest'])}")
    print("chain liveness: %d consumers LIVE; DEAD-JOIN (excluded from (4), listed): %s" % (live_n, dead or "none"))
    print("\n%-34s %s" % ("prefix \\ spelling (sites/units/crates)", "  ".join("%-14s" % s for s in SPELLS + ("ALL",))))
    for name, key in (("(1) site", "p1"), ("(1^2) macro expands to effect", "p2"), ("(1^2^3) unit reads [] inv:[D]", "p3"), ("(1^2^3^4) chained ABSENT", "p4")):
        cells = ["%-14s" % ("%d/%d/%d" % dep_cnt(rows, lambda r, sp=sp, key=key: r[key] and (sp == "ALL" or r["spelling"] == sp))) for sp in SPELLS + ("ALL",)]
        print("%-34s %s" % (name, "  ".join(cells)))
    def qual(r):
        c = set(r["ev"]["bclasses"]) - {"Unknown"}
        return ("strict" if r["ev"]["b_strict"] or r["ev"]["a"] else "loose") + "/" + ("concrete" if (c or r["ev"]["a"]) else "unknown-only")
    print("\n(2)(b) QUALITY of each prefix (sites/units/crates) -- 'concrete' = D's row carries a concrete effect, 'unknown-only' = only Unknown;")
    print("      'strict' = the row's path ends with the whole $crate:: path, 'loose' = last segment only")
    for name, key in (("(1^2)", "p2"), ("(1^2^3)", "p3"), ("(1^2^3^4)", "p4")):
        for q in ("strict/concrete", "strict/unknown-only", "loose/concrete", "loose/unknown-only"):
            c = dep_cnt(rows, lambda r, key=key, q=q: r[key] and qual(r) == q)
            if c[0]: print("   %-10s %-20s %d/%d/%d" % (name, q, *c))
    sil = dep_cnt(rows, lambda r: r["p2"] and r["r3"] == "NOROW-ANALYSED")
    print("(1^2) with the unit ANALYSED but ABSENT from the standalone report (silent standalone too): %d/%d/%d" % sil)
    print("\n(2) status over (1):", dict(Counter(r["ev"]["status"] for r in rows if r["p1"])))
    print("(2) passes by criterion:", dict(Counter(("a" if r["ev"]["a"] else "") + ("b" if r["ev"]["b"] else "") for r in rows if r["p2"])))
    print("(3) reading over (1^2):", dict(Counter(r["r3"] for r in rows if r["p2"])))
    print("(4) reading over (1^2^3):", dict(Counter(r["r4"] for r in rows if r["p3"])), " live=%s" % dict(Counter(str(r["live"]) for r in rows if r["p3"])))
    print("(1^2^3) units that already carry Unknown beside D (not counted at (3)):", sum(1 for r in rows if r.get("p3u")))
    print("(1^2) heads:", Counter(r["head"] for r in rows if r["p2"]).most_common(15))
    print("(1) heads:", Counter(r["head"] for r in rows if r["p1"]).most_common(15))

def cmd_dep_sample(a):
    rows = [r for r in json.load(open(a.joined)) if r["p1"]]
    rng = random.Random(a.seed); seen, picks = set(), []
    pas = [r for r in rows if r["ev"]["status"] == "PASS"]; fail = [r for r in rows if r["ev"]["status"] == "FAIL"]
    rng.shuffle(pas); rng.shuffle(fail)
    for lst, k in ((pas, a.n // 2), (fail, a.n - a.n // 2)):
        got = 0
        for r in lst:
            key = (r["ddir"], r["macro"])
            if key in seen: continue
            seen.add(key); picks.append(r); got += 1
            if got >= k: break
    for r in picks:
        cr = dcrate(r["ddir"]); ds = cr.defs.get(r["macro"], [])
        print("=" * 100); print(f"{r['ev']['status']}  {r['D']}::{r['macro']}  spelling={r['spelling']}  consumer={r['crate']}  eff={r['ev']['eff']} bclasses={r['ev']['bclasses']}")
        for d in ds[:2]:
            lines = open(os.path.join(r["ddir"], d["file"]), errors="replace").read().splitlines()
            print(f"--- {d['file']}:{d['line']}"); print("\n".join(lines[d["line"] - 1: d["end"]][:40]))

# ---- selftest fixtures: c1 (PATH), c1u (USE), c1m (BARE-MU), glob, and `nop` twins -- one variable each ----
def mk_dep_fixture(root):
    EMIT = 'pub fn emit() { ::std::fs::write(::std::env::var("MARK").unwrap(), b"x").unwrap(); }\n'
    NOP = '#[macro_export] macro_rules! nop { () => { () } }\n'
    MK = '#[macro_export] macro_rules! mk { () => { $crate::emit() } }\n'
    specs = {  # name: (consumer lib.rs, extra consumer files)
        "c1": ("pub fn go() { fxdepc1::mk!() }\npub fn q_pure() { fxdepc1::nop!() }\n", ""),
        "c1u": ("use fxdepc1u::{mk, nop};\npub fn go() { mk!() }\npub fn q_pure() { nop!() }\n", ""),
        "c1m": ("#[macro_use] extern crate fxdepc1m;\npub fn go() { mk!() }\npub fn q_pure() { nop!() }\n", ""),
        "c1g": ("use fxdepc1g::*;\npub fn go() { mk!() }\npub fn q_pure() { nop!() }\n", ""),
        "c1t": ("pub fn q_pure() { fxdepc1t::nop!() }\n#[cfg(test)] mod t { pub fn go() { fxdepc1t::mk!() } }\n", ""),
    }
    for nm, (src, _) in specs.items():
        os.makedirs(f"{root}/{nm}/src"); os.makedirs(f"{root}/{nm}/fxdep{nm}/src")
        open(f"{root}/{nm}/Cargo.toml", "w").write(f'[package]\nname = "{nm}"\nversion = "0.1.0"\nedition = "2021"\n[dependencies]\nfxdep{nm} = {{ path = "fxdep{nm}" }}\n')
        open(f"{root}/{nm}/fxdep{nm}/Cargo.toml", "w").write(f'[package]\nname = "fxdep{nm}"\nversion = "0.1.0"\nedition = "2021"\n')
        open(f"{root}/{nm}/fxdep{nm}/src/lib.rs", "w").write(EMIT + MK + NOP)
        open(f"{root}/{nm}/src/lib.rs", "w").write(src)
    return sorted(specs)

def selftest_dep():
    d = tempfile.mkdtemp(prefix="macrocensus-dep-selftest-")
    names = mk_dep_fixture(d)
    ok = True
    rep = dict(functions=[dict(fn="emit", inferred=["Env", "Fs"])])          # D's own report, as a scan would give it
    want = {"c1": "PATH", "c1u": "USE", "c1m": "BARE-MU", "c1g": "BARE-GLOB"}
    for nm in names:
        r = f"{d}/{nm}"; deps, _, _ = parse_cargo(f"{r}/Cargo.toml"); cr = analyse_dep_crate(r)
        ss = dep_sites_for(r, cr, deps)
        by = {s["unit"][3]: s for s in ss}
        if nm == "c1t":
            t = [s for s in ss if s["macro"] == "mk"]
            ck = [("c1t: the cfg(test) site is found AND flagged ctest", bool(t) and all(s["ctest"] for s in t)),
                  ("c1t: the non-test twin is a site", "q_pure" in by and not by["q_pure"]["ctest"])]
        else:
            go, q = by.get("go"), by.get("q_pure")
            e0 = lambda s: eval2(s["ddir"], s["macro"], None)["status"]
            e1 = lambda s: eval2(s["ddir"], s["macro"], rep)["status"]
            ck = [(f"{nm}: writer is a site with spelling {want[nm]}", bool(go) and go["spelling"] == want[nm]),
                  (f"{nm}: twin is a site with the same spelling", bool(q) and q["spelling"] == want[nm]),
                  (f"{nm}: writer needs D's report at (2) (calls $crate::emit), then PASSES (b) with it", bool(go) and e0(go) == "NEEDS-REPORT" and e1(go) == "PASS"),
                  (f"{nm}: twin FAILS (2) with and without the report", bool(q) and e0(q) == "FAIL" and e1(q) == "FAIL"),
                  (f"{nm}: (2)(b) is CALIBRATED -- an effect-free D report keeps the writer out", bool(go) and eval2(go["ddir"], go["macro"], dict(functions=[dict(fn="emit", inferred=[])]))["status"] == "FAIL")]
        for t, v in ck: print(("OK   " if v else "FAIL ") + t); ok &= bool(v)
    # (2)(a) must be able to fire: a D macro that names a std effect locator INLINE passes with no report at all, its pure twin does not
    os.makedirs(f"{d}/da/src"); open(f"{d}/da/Cargo.toml", "w").write('[package]\nname = "da"\nversion = "0.1.0"\nedition = "2021"\n')
    open(f"{d}/da/src/lib.rs", "w").write('#[macro_export] macro_rules! wr { () => { ::std::fs::write("a", b"x").unwrap() } }\n#[macro_export] macro_rules! quiet { () => { 1 + 1 } }\n')
    ea, eq = eval2(f"{d}/da", "wr", None), eval2(f"{d}/da", "quiet", None)
    for t, v in (("(2)(a): an inline ::std::fs::write macro PASSES with no report, class Fs", ea["status"] == "PASS" and ea["a"] and ea["eff"] == ["Fs"]),
                 ("(2)(a): its effect-free twin FAILS", eq["status"] == "FAIL"),
                 ("(2): a macro name D does not define is NO-DEF, an unresolved D is NO-D-SRC", eval2(f"{d}/da", "nosuch", None)["status"] == "NO-DEF" and eval2(None, "wr", None)["status"] == "NO-D-SRC")):
        print(("OK   " if v else "FAIL ") + t); ok &= bool(v)
    # the (3)/(4) readers must be able to say each class
    sa = ({"functions": [dict(fn="inner::go", loc="src/inner.rs:1:1", inferred=[], invisible=["fx-d"])]}, {"inner::go": [], "inner::q": []})
    ch = ({"functions": []}, {"inner::go": [], "inner::q": []})
    u = ["src/inner.rs", 1, 1, "go", 1]; uq = ["src/inner.rs", 2, 2, "q", 2]
    cl = {read_unit(sa, u, "fx_d")[0], read_unit(ch, u, "fx_d")[0], read_unit(({"functions": [dict(fn="go", loc="src/inner.rs:1:1", inferred=["Fs"])]}, {}), u, "fx_d")[0],
          read_unit(({"functions": [dict(fn="go", loc="src/inner.rs:1:1", inferred=["Unknown"], invisible=["fx_d"])]}, {}), u, "fx_d")[0],
          read_unit(({"functions": []}, {}), uq, "fx_d")[0]}
    wc = {"ROW-D-EMPTY", "NOROW-ANALYSED", "ROW-CHARGED", "ROW-D-UNKNOWN", "NOROW-NOT-ANALYSED"}
    print(("OK   " if cl == wc else "FAIL ") + f"(3)/(4) reader classes {sorted(cl)}"); ok &= cl == wc
    # cargo + semver
    t = [("^1.2 matches 1.9.0, not 2.0.0", req_ok("^1.2", "1.9.0") and not req_ok("^1.2", "2.0.0")), ("^0.3.1 matches 0.3.9, not 0.4.0", req_ok("^0.3.1", "0.3.9") and not req_ok("^0.3.1", "0.4.0")),
         ("bare 0.2 is caret", req_ok("0.2", "0.2.7") and not req_ok("0.2", "0.3.0"))]
    for tt, v in t: print(("OK   " if v else "FAIL ") + tt); ok &= bool(v)
    shutil.rmtree(d, ignore_errors=True)
    return ok

def selftest_dep_engine(binp):
    """With a scan binary: run the whole pipeline over the seeds; c1/c1u must count at (4), the nop twin must fall out at (2),
    c1m (bare, macro_use) must be silent standalone too (counted at (2) but NOT (3))."""
    d = tempfile.mkdtemp(prefix="macrocensus-dep-engine-"); mk_dep_fixture(d + "/fx")
    roots = [f"{d}/fx/{n}" for n in ("c1", "c1u", "c1m", "c1g")]
    class A: pass
    s = A(); s.roster = None; s.seeds = roots; s.out = d + "/ds.jsonl"; cmd_dep_sites(s)
    sc = A(); sc.dsites = s.out; sc.scan_bin = binp; sc.work = d + "/w"; sc.jobs = 2; sc.timeout = 300; cmd_dep_scan(sc)
    rows, dead, live_n = join_rows(load_dsites(s.out), sc.work)
    ok = True
    for r in rows: print("   ", r["crate"], r["spelling"], r["unit"][3], r["macro"], "ev=", r["ev"]["status"], "r3=", r["r3"], "r4=", r["r4"], "p4=", r["p4"])
    def get(c, u): return [r for r in rows if r["crate"] == c and r["unit"][3] == u]
    ck = [("c1 writer counts at (4)", any(r["p4"] for r in get("c1", "go"))), ("c1u writer counts at (4)", any(r["p4"] for r in get("c1u", "go"))),
          ("nop twins fall out at (2)", all(not r["p2"] for c in ("c1", "c1u", "c1m", "c1g") for r in get(c, "q_pure"))),
          ("c1m (bare via macro_use) passes (2) but is not (3): silent standalone too", any(r["p2"] and not r["p3"] for r in get("c1m", "go")))]
    for t, v in ck: print(("OK   " if v else "FAIL ") + t); ok &= bool(v)
    shutil.rmtree(d, ignore_errors=True)
    return ok

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
    print("-- dep-mode (M-c1) --")
    ok &= bool(selftest_dep())
    if "--scan-bin" in sys.argv: ok &= bool(selftest_dep_engine(sys.argv[sys.argv.index("--scan-bin") + 1]))
    print("selftest:", "OK" if ok else "FAILED"); return 0 if ok else 1

def main():
    if "--selftest" in sys.argv: sys.exit(selftest())
    p = argparse.ArgumentParser(); sp = p.add_subparsers(dest="cmd", required=True)
    s = sp.add_parser("sites"); s.add_argument("--roster"); s.add_argument("--crates", nargs="*"); s.add_argument("--out", required=True)
    s = sp.add_parser("scan"); s.add_argument("--sites", required=True); s.add_argument("--scan-bin", required=True)
    s.add_argument("--work", required=True); s.add_argument("--jobs", type=int, default=2); s.add_argument("--timeout", type=int, default=900)
    s = sp.add_parser("join"); s.add_argument("--sites", required=True); s.add_argument("--work", required=True); s.add_argument("--out", required=True)
    s = sp.add_parser("sample"); s.add_argument("--joined", required=True); s.add_argument("--n", type=int, default=40); s.add_argument("--seed", type=int, default=1)
    s = sp.add_parser("dep-sites"); s.add_argument("--roster"); s.add_argument("--seeds", nargs="*"); s.add_argument("--out", required=True)
    s = sp.add_parser("dep-scan"); s.add_argument("--dsites", required=True); s.add_argument("--scan-bin", required=True)
    s.add_argument("--work", required=True); s.add_argument("--jobs", type=int, default=2); s.add_argument("--timeout", type=int, default=900)
    s = sp.add_parser("dep-join"); s.add_argument("--dsites", required=True); s.add_argument("--work", required=True); s.add_argument("--out", required=True)
    s = sp.add_parser("dep-sample"); s.add_argument("--joined", required=True); s.add_argument("--n", type=int, default=20); s.add_argument("--seed", type=int, default=1)
    a = p.parse_args()
    {"sites": cmd_sites, "scan": cmd_scan, "join": cmd_join, "sample": cmd_sample, "dep-sites": cmd_dep_sites, "dep-scan": cmd_dep_scan,
     "dep-join": cmd_dep_join, "dep-sample": cmd_dep_sample}[a.cmd](a)

if __name__ == "__main__": main()
