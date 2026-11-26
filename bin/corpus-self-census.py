#!/usr/bin/env python3
"""bin/corpus-self-census.py — count `Self::m` sites of the rust Self/std binding rows (R1846, R1849, R1850, R1858,
R1859, R1860) by SHAPE, joined with a candor-scan reading of the enclosing unit.

    corpus-self-census.py sites  --roster FILE|--crates D... --out sites.jsonl [--std-table std_assoc.tsv]
    corpus-self-census.py scan   --sites sites.jsonl --scan-bin BIN --work DIR [--jobs N] [--roster FILE --with-deps]
    corpus-self-census.py join   --sites sites.jsonl --work DIR --out joined.json [--roster FILE] [--rustc-oracle]
    corpus-self-census.py sample --joined joined.json --row R1846 --n 25 --seed 1 [--effect-only]
    corpus-self-census.py --selftest

WHY.  A population count of `Self::m` says nothing about how many matter.  A fix for a row needs the CONJUNCTION:
the site has the row's shape AND the callee it names really performs an effect AND the enclosing unit's reading on
the engine under test does not already carry that effect (or an `Unknown`).  This counts that conjunction.

SHAPES (a site can carry several):
  R1846  `Self::m` in a trait DEFAULT body, `m` not declared by the trait itself, trait has a supertrait bound.
         callee effect = effects of local units named `m` (the supertrait's declaration/default, or impls of it),
         or of the dependency's `Leaf::m` rows when the dependency is in the roster and was scanned.
  R1849  `Self::m` in an impl whose self type is std-rooted (written `std::..`, `use std::..` leaf, or prelude),
         `m` is a std INHERENT per the engine's own table (std_assoc.tsv, passed with --std-table).
  R1858  as R1849 but the self type is a crate-local `type X = std..;` alias.
  R1859  `Self::m` where `m` is the impl's own (or a sibling impl's) member AND the table says the std leaf has an
         inherent `m`.  --rustc-oracle then compiles `<std path>::m` with no trait in scope to learn whether the
         std type's PUBLIC surface really has it (executed ground truth for the table's leaf-keyed answer).
  R1860  std-rooted self type, `m` defined in ANOTHER impl of the same std leaf in this crate.
  R1850  impl self type is a >= 2-segment path whose first segment is neither std, crate-relative, a declared
         `mod`/`use` name nor a Cargo dependency, in a file that has a glob `use`: only a glob can bind it.

INSTRUMENT.  A token-level reader (the lexer is corpus-macro-census.py's, imported: comments, strings, raw strings,
lifetimes stripped).  It shares no code with candor-scan.  It is a HEURISTIC on these axes, all reported:
module scoping of `use` is per FILE (nested `mod` blocks and fn-local `use` merge in), `macro_rules!` bodies are not
walked (their `Self::` sites are not counted), the effect of a std callee comes from a small named table
(STD_EFFECT), and a callee in a dependency is resolved only when that dependency is itself in the roster.
Selftest seeds one site per shape, shows each fire, and shows the verdict/flip classifier able to say each class.
"""
import argparse, glob, importlib.util, json, os, random, re, subprocess, sys, tempfile
from collections import Counter, defaultdict

_here = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("corpus_macro_census", os.path.join(_here, "corpus-macro-census.py"))
mc = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(mc)
lex, isid, isp, isg, at_item_start, crate_files, crate_key = mc.lex, mc.isid, mc.isp, mc.isg, mc.at_item_start, mc.crate_files, mc.crate_key

STD_ROOTS = {"std", "core", "alloc"}
REL_ROOTS = {"crate", "self", "super"}
PRELUDE = {"Vec", "String", "Option", "Result", "Box"}
PRELUDE_TRAITS = {"Clone", "Copy", "Eq", "PartialEq", "Ord", "PartialOrd", "Default", "Iterator", "IntoIterator", "DoubleEndedIterator", "ExactSizeIterator",
                  "Extend", "From", "Into", "TryFrom", "TryInto", "AsRef", "AsMut", "Drop", "Fn", "FnMut", "FnOnce", "ToString", "ToOwned", "FromIterator", "Send", "Sync", "Sized", "Unpin"}

# std inherent members that perform an effect, by type leaf: (class, names)
_PATHFS = {"exists", "try_exists", "is_file", "is_dir", "is_symlink", "metadata", "symlink_metadata", "read_dir", "canonicalize", "read_link"}
STD_EFFECT = {
    "File": ("Fs", {"open", "create", "create_new", "sync_all", "sync_data", "set_len", "metadata", "try_clone", "set_permissions", "set_times", "lock", "unlock", "try_lock"}),
    "OpenOptions": ("Fs", {"open"}),
    "DirBuilder": ("Fs", {"create"}),
    "DirEntry": ("Fs", {"metadata", "file_type"}),
    "Path": ("Fs", _PATHFS), "PathBuf": ("Fs", _PATHFS),
    "TcpStream": ("Net", {"connect", "connect_timeout", "peek", "shutdown", "try_clone", "set_nodelay", "peer_addr", "local_addr"}),
    "TcpListener": ("Net", {"bind", "accept", "incoming", "try_clone", "local_addr"}),
    "UdpSocket": ("Net", {"bind", "connect", "send", "send_to", "recv", "recv_from", "peek", "peek_from", "try_clone", "local_addr"}),
    "UnixStream": ("Net", {"connect", "pair", "try_clone", "connect_addr"}),
    "UnixListener": ("Net", {"bind", "accept", "incoming", "try_clone", "bind_addr"}),
    "UnixDatagram": ("Net", {"bind", "unbound", "pair", "connect", "send", "recv", "send_to", "recv_from"}),
    "Command": ("Exec", {"output", "spawn", "status", "exec"}),
    "Instant": ("Clock", {"now", "elapsed"}),
    "SystemTime": ("Clock", {"now", "elapsed"}),
}

def std_effect(leaf, m):
    e = STD_EFFECT.get(leaf)
    return e[0] if e and m in e[1] else None

def load_std_table(path):
    inh = set()
    if path and os.path.exists(path):
        for l in open(path):
            f = l.rstrip("\n").split("\t")
            if len(f) == 3 and f[0] == "I": inh.add((f[1], f[2]))
    return inh

# ───────────────────────── token helpers ─────────────────────────
def angle_skip(t, i):
    """t[i] is `<`: the index after its matching `>` (`->` does not close)."""
    d = 0; n = len(t)
    while i < n:
        x = t[i]
        if isp(x, "<"): d += 1
        elif isp(x, ">") and not (i > 0 and isp(t[i - 1], "-")):
            d -= 1
            if d == 0: return i + 1
        i += 1
    return n

def path_of(t, i=0):
    """Parse a type/trait path at t[i]: (segments or None, next index).  Skips `&`, lifetimes, `mut`, `dyn`, `?`
    and generic arguments."""
    n = len(t)
    while i < n and (isp(t[i], "&") or isp(t[i], "?") or (isinstance(t[i], mc.Tok) and t[i].k == "l") or isid(t[i], "mut") or isid(t[i], "dyn")): i += 1
    segs = []
    if i + 1 < n and isp(t[i], ":") and isp(t[i + 1], ":"): i += 2
    while i < n and isid(t[i]):
        segs.append(t[i].t); i += 1
        if i < n and isp(t[i], "<"): i = angle_skip(t, i)
        if i + 2 < n and isp(t[i], ":") and isp(t[i + 1], ":") and isid(t[i + 2]): i += 2; continue
        break
    return (segs or None), i

def parse_use(kids, prefix, uses, globs):
    """kids: tokens of one use tree (no `use`, no `;`)."""
    items, cur = [], []
    for x in kids:
        if isp(x, ","): items.append(cur); cur = []
        else: cur.append(x)
    items.append(cur)
    for it in items:
        if not it: continue
        segs, i, n = list(prefix), 0, len(it)
        if i + 1 < n and isp(it[i], ":") and isp(it[i + 1], ":"): i += 2
        while i < n:
            x = it[i]
            if isid(x) and x.t != "as":
                segs.append(x.t); i += 1
                if i + 1 < n and isp(it[i], ":") and isp(it[i + 1], ":"): i += 2; continue
                break
            if isp(x, "*"): globs.append(segs); segs = None; break
            if isg(x, "{"): parse_use(x.kids, segs, uses, globs); segs = None; break
            i += 1
        if segs is None: continue
        alias = segs[-1] if segs else None
        if i < n and isid(it[i], "as") and i + 1 < n and isid(it[i + 1]): alias = it[i + 1].t
        if segs and segs[-1] == "self" and len(segs) > 1:
            segs = segs[:-1]; alias = alias if alias != "self" else segs[-1]
        if alias and alias != "_" and segs: uses[alias] = segs

# ───────────────────────── crate model ─────────────────────────
class Crate:
    def __init__(s, root):
        s.root = root; s.files = {}
        s.mods = set(); s.aliases = {}; s.alias_all = defaultdict(list)
        s.traits = []; s.impls = []; s.units = []; s.sites = []; s.deps = set(); s.local_types = set()

def parse_cargo_deps(root):
    deps = set(); sect = None
    p = os.path.join(root, "Cargo.toml")
    if not os.path.exists(p): return deps
    for ln in open(p, encoding="utf-8", errors="replace"):
        ln = ln.strip()
        m = re.match(r"\[(.+?)\]", ln)
        if m:
            sect = m.group(1)
            m2 = re.match(r"(?:target\..*\.)?(?:build-)?dependencies\.(.+)", sect)
            if m2: deps.add(m2.group(1).strip('"').replace("-", "_"))
            continue
        if sect and re.match(r"(?:target\..*\.)?(?:build-)?dependencies$", sect):
            m = re.match(r'([A-Za-z0-9_\-]+)\s*=', ln)
            if m: deps.add(m.group(1).replace("-", "_"))
            m = re.search(r'package\s*=\s*"([^"]+)"', ln)
            if m: deps.add(m.group(1).replace("-", "_"))
    return deps

def self_sites(kids, out):
    """(line, m, kind, call?) for `Self::m` and `<Self>::m` in a token tree (descends into every group)."""
    k = list(kids); n = len(k)
    for i, x in enumerate(k):
        if isinstance(x, mc.Grp): self_sites(x.kids, out); continue
        if not isid(x, "Self"): continue
        j = i + 1; kind = "path"
        if i > 0 and isp(k[i - 1], "<") and j < n and isp(k[j], ">"):
            # `<Self>::m` is a qualified path; `Vec::<Self>::new` / `Vec<Self>::new` / `Key::<Self>::f` are generic ARGUMENTS
            # (the census's first run counted those: crypto-common `Key::<Self>::generate_from_rng`, zerocopy `MaybeUninit::<Self>::uninit`)
            pr = k[i - 2] if i >= 2 else None
            if pr is not None and (isp(pr, ":") or (isid(pr) and pr.t not in ("return", "in", "else", "break", "move", "yield", "await", "if", "match", "while"))): continue
            j += 1; kind = "qself"
        elif i > 0 and isp(k[i - 1], "<"): continue
        if j + 2 < n and isp(k[j], ":") and isp(k[j + 1], ":") and isid(k[j + 2]):
            m = k[j + 2].t
            if m[:1].islower() or m[:1] == "_":
                out.append((x.line, m, kind, j + 3 < n and isg(k[j + 3], "(")))

def header_split(t):
    """impl header tokens -> (trait segs or None, self segs or None)."""
    if t and isp(t[0], "<"): t = t[angle_skip(t, 0):]
    for q, x in enumerate(t):
        if isid(x, "where"): t = t[:q]; break
    d, fo = 0, None
    for q, x in enumerate(t):
        if isp(x, "<"): d += 1
        elif isp(x, ">") and not (q and isp(t[q - 1], "-")): d -= 1
        elif d == 0 and isid(x, "for"): fo = q; break
    if fo is None: return None, path_of(t)[0]
    return path_of(t[:fo])[0], path_of(t[fo + 1:])[0]

def trait_header(t):
    """tokens after `trait`: (name, [supertrait segs])."""
    if not t or not isid(t[0]): return None, []
    name = t[0].t; i = 1
    if i < len(t) and isp(t[i], "<"): i = angle_skip(t, i)
    sup = []
    if i < len(t) and isp(t[i], ":") and not (i + 1 < len(t) and isp(t[i + 1], ":")):
        rest = []
        for x in t[i + 1:]:
            if isid(x, "where"): break
            rest.append(x)
        cur = []; d = 0
        for x in rest + [None]:
            if x is None or (d == 0 and isp(x, "+")):
                p = path_of(cur)[0]
                if p: sup.append(p)
                cur = []; continue
            if isp(x, "<"): d += 1
            elif isp(x, ">") and not (cur and isp(cur[-1], "-")): d -= 1
            cur.append(x)
    return name, sup

def fn_items(kids):
    out = []; n = len(kids); i = 0
    while i < n:
        x = kids[i]
        if isid(x, "fn") and i + 1 < n and isid(kids[i + 1]):
            j = i + 2
            while j < n and not (isg(kids[j], "{") or isp(kids[j], ";")): j += 1
            out.append((kids[i + 1].t, x.line, kids[j] if j < n and isg(kids[j], "{") else None)); i = j + 1; continue
        i += 1
    return out

def walk(kids, cr, file):
    n = len(kids); i = 0; start = 0; fi = cr.files[file]
    while i < n:
        x = kids[i]
        if isinstance(x, mc.Grp):
            walk(x.kids, cr, file); i += 1
            if x.d == "{": start = i                       # a brace group ends an item (struct/enum/const-block/macro call)
            continue
        if isp(x, ";"): start = i + 1; i += 1; continue
        if isid(x, "macro_rules") and i + 1 < n and isp(kids[i + 1], "!"): i += 4; start = i; continue
        if isid(x, "use") and at_item_start(kids, start, i):
            j = i + 1
            while j < n and not isp(kids[j], ";"): j += 1
            parse_use(kids[i + 1:j], [], fi["uses"], fi["globs"]); i = j + 1; start = i; continue
        if isid(x, "mod") and i + 1 < n and isid(kids[i + 1]) and at_item_start(kids, start, i):
            cr.mods.add(kids[i + 1].t)
            if i + 2 < n and isg(kids[i + 2], "{"): walk(kids[i + 2].kids, cr, file); i += 3; start = i; continue
        if isid(x, "type") and at_item_start(kids, start, i) and i + 1 < n and isid(kids[i + 1]):
            j = i + 2
            while j < n and not isp(kids[j], ";") and not isp(kids[j], "="): j += 1
            if j < n and isp(kids[j], "="):
                rhs, _ = path_of(list(kids[j + 1:]))
                if rhs: cr.aliases[(file, kids[i + 1].t)] = rhs; cr.alias_all[kids[i + 1].t].append((file, rhs))
            while j < n and not isp(kids[j], ";"): j += 1
            i = j + 1; start = i; continue
        if isid(x) and x.t in ("struct", "enum", "union") and i + 1 < n and isid(kids[i + 1]) and at_item_start(kids, start, i):
            cr.local_types.add(kids[i + 1].t); cr.local_types.add((file, kids[i + 1].t)); i += 2; continue
        if isid(x, "trait") and i + 1 < n and at_item_start(kids, start, i):
            j = i + 1
            while j < n and not (isg(kids[j], "{") or isp(kids[j], ";")): j += 1
            if j < n and isg(kids[j], "{"):
                name, sup = trait_header(list(kids[i + 1:j]))
                fns = fn_items(kids[j].kids)
                own = [a for a, _, _ in fns]
                cr.traits.append(dict(name=name, sup=sup, file=file, line=x.line, fns=own))
                for fname, fline, body in fns:
                    cr.units.append(dict(file=file, name=fname, fn_line=fline, owner=("trait", name)))
                    if body:
                        out = []; self_sites(body.kids, out)
                        for (ln, m, kind, call) in out:
                            cr.sites.append(dict(ctx="trait", file=file, line=ln, m=m, kind=kind, call=call, fn=fname, fn_line=fline, trait=name, sup=sup, own=own))
                        walk(body.kids, cr, file)
            i = (j + 1) if j < n else n; start = i; continue
        if isid(x, "impl") and at_item_start(kids, start, i):
            j = i + 1
            while j < n and not (isg(kids[j], "{") or isp(kids[j], ";")): j += 1
            if j < n and isg(kids[j], "{"):
                tr, sf = header_split(list(kids[i + 1:j]))
                fns = fn_items(kids[j].kids)
                im = dict(file=file, line=x.line, trait=tr, self=sf, fns=[a for a, _, _ in fns], idx=len(cr.impls))
                cr.impls.append(im)
                for fname, fline, body in fns:
                    cr.units.append(dict(file=file, name=fname, fn_line=fline, owner=("impl", im["idx"])))
                    if body:
                        out = []; self_sites(body.kids, out)
                        for (ln, m, kind, call) in out:
                            cr.sites.append(dict(ctx="impl", file=file, line=ln, m=m, kind=kind, call=call, fn=fname, fn_line=fline, impl=im["idx"]))
                        walk(body.kids, cr, file)
            i = (j + 1) if j < n else n; start = i; continue
        if isid(x, "fn") and i + 1 < n and isid(kids[i + 1]) and at_item_start(kids, start, i):
            j = i + 2
            while j < n and not (isg(kids[j], "{") or isp(kids[j], ";")): j += 1
            if j < n and isg(kids[j], "{"): walk(kids[j].kids, cr, file)
            i = j + 1; start = i; continue
        i += 1

def analyse_crate(root):
    cr = Crate(root); cr.deps = parse_cargo_deps(root)
    for f in sorted(crate_files(root)):
        try: src = open(f, encoding="utf-8", errors="replace").read()
        except OSError: continue
        rel = os.path.relpath(f, root)
        cr.files[rel] = dict(uses={}, globs=[])
        walk(lex(src), cr, rel)
    return cr

# ───────────────────────── classification ─────────────────────────
def alias_rhs(cr, file, name):
    """a crate-local `type name = ..;` visible in this file: defined here, or imported by `use` (last segment).  A struct/
    enum/union of that name declared in THIS file shadows it (the census's first run took `Instant` for an alias
    declared in another module, beside a local `struct Instant`)."""
    if (file, name) in cr.local_types: return None
    if (file, name) in cr.aliases: return (file, cr.aliases[(file, name)])
    u = cr.files[file]["uses"].get(name)
    if u and u[0] in REL_ROOTS | cr.mods and len(cr.alias_all.get(u[-1], [])) == 1: return cr.alias_all[u[-1]][0]
    return None

def self_kind(cr, file, segs):
    """-> (kind, leaf, std path or None).  kind: std-path | std-use | std-prelude | std-alias | other."""
    if not segs: return "other", None, None
    leaf = segs[-1]; uses = cr.files[file]["uses"]
    if segs[0] in STD_ROOTS: return "std-path", leaf, segs
    if len(segs) == 1 and segs[0] in uses and uses[segs[0]][0] in STD_ROOTS: return "std-use", leaf, uses[segs[0]]
    if len(segs) == 1:
        ar = alias_rhs(cr, file, segs[0])
        if ar:
            f2, rhs = ar; u2 = cr.files[f2]["uses"]
            e = u2[rhs[0]] + rhs[1:] if rhs[0] in u2 and u2[rhs[0]] != [rhs[0]] else rhs
            if e and e[0] in STD_ROOTS: return "std-alias", e[-1], e
    if len(segs) > 1 and segs[0] in uses and uses[segs[0]][0] in STD_ROOTS: return "std-path", leaf, uses[segs[0]] + segs[1:]
    if len(segs) == 1 and leaf in PRELUDE and leaf not in cr.local_types and leaf not in uses and not cr.alias_all.get(leaf): return "std-prelude", leaf, ["std", leaf]
    return "other", leaf, None

def glob_bound(cr, file, segs):
    """R1850: >=2-segment path, first segment not std/relative/declared/imported/dependency, in a file with a non-std glob."""
    if not segs or len(segs) < 2: return None
    h = segs[0]; fi = cr.files[file]
    if h in STD_ROOTS or h in REL_ROOTS or h in cr.mods or h in fi["uses"] or h.replace("-", "_") in cr.deps: return None
    g = [x for x in fi["globs"] if x and x[0] not in STD_ROOTS]
    if not g: return None
    ext = [x[0] for x in g if x[0] not in REL_ROOTS]
    return dict(globs=["::".join(x) for x in g][:4], dep_roots=ext[:4], kind="glob-external" if ext else "glob-local")

def sites_for(cr, std_inh):
    impls_by_leaf = defaultdict(list)
    for im in cr.impls:
        if im["self"]: impls_by_leaf[im["self"][-1]].append(im)
    traits_by_name = defaultdict(list)
    for t in cr.traits: traits_by_name[t["name"]].append(t)
    def units_of(owner, m): return [(u["file"], u["fn_line"]) for u in cr.units if u["owner"] == owner and u["name"] == m]
    out = []
    for s in cr.sites:
        rec = dict(file=s["file"], line=s["line"], m=s["m"], kind=s["kind"], call=s["call"], fn=s["fn"], fn_line=s["fn_line"], shapes=[])
        if s["ctx"] == "trait":
            sup = [x for x in s["sup"] if x[-1] not in ("Sized", "Send", "Sync", "Unpin")]
            if s["m"] in s["own"] or not sup: continue
            rec["trait"] = s["trait"]
            cls = set(); dep = []
            for sp in sup:
                e = sp
                uses = cr.files[s["file"]]["uses"]
                if sp[0] in uses: e = uses[sp[0]] + sp[1:]
                if sp[-1] in traits_by_name and (len(sp) == 1 or sp[0] in REL_ROOTS or sp[0] in cr.mods): cls.add("local")
                elif e[0] in STD_ROOTS or (len(sp) == 1 and sp[0] in PRELUDE_TRAITS and sp[0] not in uses): cls.add("std")
                elif e[0] in REL_ROOTS or e[0] in cr.mods: cls.add("local-unresolved")
                else: cls.add("dep"); dep.append([e[0], e[-1]])
            callee, seen, frontier, declared = [], set(), [x[-1] for x in sup if x[-1] in traits_by_name], False
            while frontier:
                tn = frontier.pop()
                if tn in seen: continue
                seen.add(tn)
                for t in traits_by_name[tn]:
                    if s["m"] in t["fns"]: declared = True; callee += units_of(("trait", tn), s["m"])
                    frontier += [sp2[-1] for sp2 in t["sup"] if sp2[-1] in traits_by_name]
            seen_leaf = seen | {x[-1] for x in sup}            # local impls of ANY supertrait (std/dep ones too) that define m
            for im in cr.impls:
                if im["trait"] and im["trait"][-1] in seen_leaf and s["m"] in im["fns"]: callee += units_of(("impl", im["idx"]), s["m"])
            rec["shapes"].append("R1846")
            rec["r1846"] = dict(sup_class=sorted(cls), declared_local=declared, callee_units=sorted(set(callee))[:12], dep=dep[:3], sup=["::".join(x) for x in sup][:4])
            out.append(rec); continue
        im = cr.impls[s["impl"]]; sf = im["self"]
        if not sf: continue
        rec["impl_line"] = im["line"]; rec["impl_trait"] = "::".join(im["trait"]) if im["trait"] else None; rec["impl_self"] = "::".join(sf)
        gb = glob_bound(cr, s["file"], sf)
        if gb: rec["shapes"].append("R1850"); rec["r1850"] = gb
        kind, leaf, std = self_kind(cr, s["file"], sf)
        if kind != "other":
            m = s["m"]
            own = m in im["fns"]
            sib = [o["idx"] for o in impls_by_leaf.get(leaf, []) if o["idx"] != im["idx"] and m in o["fns"] and self_kind(cr, o["file"], o["self"])[0] != "other"]
            inh = (leaf, m) in std_inh
            rec.update(self_kind=kind, std_leaf=leaf, std_path="::".join(std), std_inherent=inh, std_effect=std_effect(leaf, m),
                       member="own" if own else ("sibling" if sib else ("std-inherent" if inh else "other")))
            callee = (units_of(("impl", im["idx"]), m) if own else []) + [u for ix in sib for u in units_of(("impl", ix), m)]
            rec["callee_units"] = sorted(set(callee))[:12]
            if kind == "std-alias":
                if inh or own or sib: rec["shapes"].append("R1858")
            else:
                if inh: rec["shapes"].append("R1849")
                if (own or sib) and inh and kind != "std-prelude": rec["shapes"].append("R1859")
                if sib: rec["shapes"].append("R1860")
        if rec["shapes"]: out.append(rec)
    return out

def cmd_sites(a):
    roots = list(a.crates or [])
    if a.roster: roots += load_roster(a.roster)
    std_inh = load_std_table(a.std_table)
    n_cr = 0; shapes = Counter(); n_site = 0; pop = Counter()
    with open(a.out, "w") as fo:
        for r in roots:
            if not os.path.isdir(r): continue
            n_cr += 1
            cr = analyse_crate(r); ss = sites_for(cr, std_inh)
            for s in ss:
                for sh in s["shapes"]: shapes[sh] += 1
            n_site += len(ss)
            pop["units"] += len(cr.units); pop["raw_self_sites"] += len(cr.sites); pop["impls"] += len(cr.impls)
            pop["traits"] += len(cr.traits); pop["traits_with_supertrait"] += sum(1 for t in cr.traits if t["sup"])
            for im in cr.impls:
                if im["self"]: pop["impl_self_" + self_kind(cr, im["file"], im["self"])[0]] += 1
            fo.write(json.dumps(dict(crate=r, units=len(cr.units), raw_self_sites=len(cr.sites), impls=len(cr.impls), sites=ss)) + "\n")
    print(f"sites: {n_cr} crates parsed, {n_site} shaped site records -> {a.out}; per shape {dict(sorted(shapes.items()))}")
    print("population (the detector's own denominators):", dict(sorted(pop.items())))

# ───────────────────────── scan + join ─────────────────────────
def load_roster(path): return [ln.split()[0] for ln in open(path) if ln.strip()]

def dep_dirs(roster_dirs):
    idx = defaultdict(list)
    for d in roster_dirs:
        m = re.match(r"(.+?)-(\d+\.\d+\.\d+.*)$", os.path.basename(d.rstrip("/")))
        if m: idx[m.group(1).replace("-", "_")].append(d)
    return idx

def dep_roots_of(s):
    out = []
    if "R1850" in s["shapes"]: out += s["r1850"].get("dep_roots", [])
    if "R1846" in s["shapes"]: out += [d[0] for d in s["r1846"].get("dep", [])]
    return out

def cmd_scan(a):
    import concurrent.futures as cf
    todo = set(); idx = dep_dirs(load_roster(a.roster)) if a.roster else {}
    for ln in open(a.sites):
        j = json.loads(ln)
        if not j["sites"]: continue
        todo.add(j["crate"])
        if a.with_deps:
            for s in j["sites"]:
                for rt in dep_roots_of(s):
                    for d in idx.get(rt.replace("-", "_"), [])[:1]: todo.add(d)
    todo = sorted(todo); os.makedirs(a.work, exist_ok=True)
    def one(r):
        k = crate_key(r); out = f"{a.work}/{k}/r"
        if glob.glob(out + ".*.scan.json"): return k, "cached"
        os.makedirs(os.path.dirname(out), exist_ok=True)
        env = dict(os.environ, CANDOR_CACHE_DIR=f"{a.work}/cache")
        try: return k, f"rc={subprocess.run([a.scan_bin, r, '--out', out], capture_output=True, env=env, timeout=a.timeout, text=True).returncode}"
        except subprocess.TimeoutExpired: return k, "timeout"
    with cf.ThreadPoolExecutor(a.jobs) as ex: res = list(ex.map(one, todo))
    print("scan:", dict(Counter(r for _, r in res)), f"({len(todo)} crates)")

def load_report(work, crate):
    d = f"{work}/{crate_key(crate)}"
    fs = [f for f in sorted(glob.glob(d + "/r.*.scan.json")) if not f.endswith("callgraph.json")]
    if not fs: return None
    g = glob.glob(d + "/r.*.scan.callgraph.json")
    return json.load(open(fs[0])), (json.load(open(g[0])) if g else {})

def rows_at(rep, file, line):
    out = []
    for f in rep[0].get("functions", []):
        p = f.get("loc", "").split(":")
        if len(p) > 1 and p[0] == file and p[1].isdigit() and int(p[1]) == line: out.append(f)
    return out

def reading(rows):
    """-> (verdict, concrete set, unknown reasons).  CHARGED | UNKNOWN | UNKNOWN+CHARGED | SILENT (pure or ABSENT)."""
    inf = set(); why = []
    for r in rows:
        inf |= set(r.get("inferred") or []); why += r.get("unknownWhy") or []
    conc = inf - {"Unknown"}
    if "Unknown" in inf: return ("UNKNOWN+CHARGED" if conc else "UNKNOWN"), conc, why
    return ("CHARGED" if conc else "SILENT"), conc, why

def silent_for(verdict, conc, target):
    """does the unit's reading leave the TARGET effect classes uncovered?  An Unknown means disclosed, not silent."""
    if not target: return None
    if verdict in ("UNKNOWN", "UNKNOWN+CHARGED"): return "DISCLOSED"
    return "CAUGHT" if set(target) <= conc else "SILENT-WITH-EFFECT"

def rustc_oracle(path, m, cache):
    """does the std type at `path` have a PUBLIC inherent `m` with no trait in scope?  compile `<path>::m`."""
    key = ("::".join(path), m)
    if key in cache: return cache[key]
    d = tempfile.mkdtemp(prefix="selfcensus-rustc-")
    open(d + "/a.rs", "w").write(f"#![allow(unused)]\nfn f() {{ let _ = <{'::'.join(path)}>::{m}; }}\n")
    p = subprocess.run(["rustc", "--edition", "2021", "--crate-type", "lib", "--emit=metadata", "-o", d + "/a.rmeta", d + "/a.rs"], capture_output=True, text=True)
    err = p.stderr
    # E0599 = the name does not resolve with only the prelude in scope (no inherent, no prelude trait member).  A generic
    # item (`File::create<P: AsRef<Path>>`) compiles to E0282/E0283/E0790 "type annotations needed", which PROVES it resolved.
    if p.returncode == 0 or re.search(r"error\[E0(282|283|790)\]", err) and "E0599" not in err: v = "public-inherent"
    elif "error[E0599]" in err: v = "no-public-inherent"
    else: v = "oracle-error"
    cache[key] = v
    return v

def cmd_join(a):
    rows = []; cache = {}; dep_rep = {}
    idx = dep_dirs(load_roster(a.roster)) if a.roster else {}
    for ln in open(a.sites):
        j = json.loads(ln)
        if not j["sites"]: continue
        rep = load_report(a.work, j["crate"])
        for s in j["sites"]:
            s = dict(s); s["crate"] = crate_key(j["crate"])
            if rep is None: s.update(verdict="NOREPORT", conc=[], unknown_why=[], target=[], target_how="no-report", flip=None); rows.append(s); continue
            v, conc, why = reading(rows_at(rep, s["file"], s["fn_line"]))
            if v == "SILENT":
                s["silent_how"] = "PURE(callgraph)" if any(k == s["fn"] or k.endswith("::" + s["fn"]) for k in rep[1]) else "ABSENT"
            s.update(verdict=v, conc=sorted(conc), unknown_why=why[:3])
            tgt, how = set(), None
            cu = s.get("callee_units") or (s.get("r1846") or {}).get("callee_units") or []
            for (f, l) in cu:
                tgt |= reading(rows_at(rep, f, l))[1]
            if cu: how = "local-callee"
            if s.get("std_effect") and not tgt: tgt = {s["std_effect"]}; how = "std-table"
            if not tgt and ("R1850" in s["shapes"] or "R1846" in s["shapes"]):
                leaf = (s.get("impl_self") or "").split("::")[-1] if "R1850" in s["shapes"] else ((s["r1846"].get("dep") or [[0, None]])[0][1])
                roots = dep_roots_of(s)
                how = "NO-DEP-ROOT" if not roots else "DEP-NOT-IN-ROSTER"
                for rt in roots:
                    for d in idx.get(rt.replace("-", "_"), [])[:1]:
                        if d not in dep_rep: dep_rep[d] = load_report(a.work, d)
                        if dep_rep[d] is None: how = "DEP-NOT-SCANNED"; continue
                        hit = [f for f in dep_rep[d][0].get("functions", []) if f["fn"].endswith(f"{leaf}::{s['m']}")]
                        if hit:
                            for f in hit: tgt |= set(f.get("inferred") or []) - {"Unknown"}
                            how = "dep-callee" if tgt else "dep-callee-no-effect"
                        else: how = "DEP-NO-ROW"
            s.update(target=sorted(tgt), target_how=how or "no-effect-source", flip=silent_for(v, conc, tgt) if tgt else "NO-TARGET-EFFECT")
            if a.rustc_oracle and "R1859" in s["shapes"]: s["rustc"] = rustc_oracle(s["std_path"].split("::"), s["m"], cache)
            rows.append(s)
    json.dump(rows, open(a.out, "w")); summarise(rows)

ROWS = ("R1846", "R1849", "R1850", "R1858", "R1859", "R1860")

def summarise(rows):
    for R in ROWS:
        sub = [r for r in rows if R in r["shapes"]]
        print(f"\n== {R}: {len(sub)} sites, {len({(r['crate'], r['file'], r['fn_line']) for r in sub})} distinct enclosing units, {len({r['crate'] for r in sub})} crates")
        if not sub: continue
        print("   reading of enclosing unit:", dict(Counter(r["verdict"] for r in sub)))
        print("   callee-effect source:", dict(Counter(r["target_how"] for r in sub)))
        eff = [r for r in sub if r.get("target")]
        sw = [r for r in eff if r["flip"] == "SILENT-WITH-EFFECT"]
        print(f"   callee performs an effect (oracle): {len(eff)} sites; unit reading vs that effect: {dict(Counter(r['flip'] for r in eff))}")
        print(f"   SILENT-WITH-EFFECT: {len(sw)} sites, {len({(r['crate'], r['file'], r['fn_line']) for r in sw})} units, {len({r['crate'] for r in sw})} crates; by class {dict(Counter(c for r in sw for c in r['target']))}")
        if R == "R1846": print("   supertrait class:", dict(Counter(",".join(r["r1846"]["sup_class"]) for r in sub)))
        if R in ("R1849", "R1858", "R1859", "R1860"): print("   self kind / member:", dict(Counter((r.get("self_kind"), r.get("member")) for r in sub)))
        if R == "R1850": print("   glob kind:", dict(Counter(r["r1850"]["kind"] for r in sub)))
        if R == "R1859" and any("rustc" in r for r in sub): print("   rustc oracle (std PUBLIC inherent?):", dict(Counter(r.get("rustc") for r in sub)))

def cmd_sample(a):
    rows = [r for r in json.load(open(a.joined)) if a.row in r["shapes"]]
    if a.effect_only: rows = [r for r in rows if r.get("target")]
    random.Random(a.seed).shuffle(rows)
    strata = defaultdict(list)
    for r in rows: strata[(r["verdict"], r.get("flip"))].append(r)
    out, per = [], max(1, a.n // max(1, len(strata)))
    for k, v in sorted(strata.items(), key=lambda kv: str(kv[0])): out += v[:per]
    for r in out[:a.n]:
        print(json.dumps({k: r.get(k) for k in ("crate", "file", "line", "fn", "fn_line", "m", "verdict", "flip", "target", "target_how", "impl_self", "impl_trait", "trait", "member", "rustc")}))

# ───────────────────────── selftest ─────────────────────────
FIXTURE = r'''
use std::fs::File;
use depx::*;
pub trait Tr { fn create(p: &str) -> u8; fn a(p: &str) -> u8; fn sib(p: &str) -> u8; }
impl Tr for File { fn create(_p: &str) -> u8 { 0 } fn a(p: &str) -> u8 { Self::create(p); 1 } fn sib(p: &str) -> u8 { Self::other_sib(p) } }
pub trait Tr2 { fn other_sib(p: &str) -> u8; }
impl Tr2 for File { fn other_sib(_p: &str) -> u8 { 2 } }
pub trait LSup { fn ls_w(p: &str) { std::fs::write(p, b"x").unwrap(); } }
pub trait Q4: LSup { fn q4_a(p: &str) { Self::ls_w(p) } fn own() {} fn q4_own() { Self::own() } }
type F = std::fs::File;
pub struct Brace { a: u8 }
impl Tr for F { fn create(_p: &str) -> u8 { 0 } fn a(p: &str) -> u8 { Self::open(p); 1 } fn sib(_p: &str) -> u8 { 0 } }
impl Tr for std::net::TcpStream { fn create(_p: &str) -> u8 { 0 } fn a(p: &str) -> u8 { Self::connect(p); 1 } fn sib(_p: &str) -> u8 { 0 } }
impl Tr for d::Lone { fn create(_p: &str) -> u8 { 0 } fn a(p: &str) -> u8 { Self::m(p) } fn sib(_p: &str) -> u8 { 0 } }
pub struct Mine;
impl std::str::FromStr for Mine { type Err = (); fn from_str(s: &str) -> Result<Self, ()> { let _ = std::fs::read(s); Ok(Mine) } }
pub trait Q5: std::str::FromStr { fn q5() { let _ = Self::from_str("x"); } }
impl Tr2 for Mine { fn other_sib(_p: &str) -> u8 { let _ = Vec::<Self>::new(); let _ = <Self>::y2(); 0 } }
impl Mine { fn y2() -> u8 { 0 } }
impl Mine { fn x() -> u8 { Self::y() } fn y() -> u8 { 0 } }
fn str_comment() { let _ = "Self::create(p)"; /* Self::create(q) */ }
'''
TABLE = "I\tFile\topen\nI\tFile\tcreate\nI\tTcpStream\tconnect\n"

def selftest():
    d = tempfile.mkdtemp(prefix="selfcensus-selftest-")
    os.makedirs(d + "/src"); open(d + "/src/lib.rs", "w").write(FIXTURE)
    open(d + "/Cargo.toml", "w").write('[package]\nname="t"\n[dependencies]\nserde = "1"\n')
    tp = d + "/std_assoc.tsv"; open(tp, "w").write(TABLE)
    cr0 = analyse_crate(d); ss = sites_for(cr0, load_std_table(tp))
    got = {(s["fn"], s["m"], sh) for s in ss for sh in s["shapes"]}
    want = {("q4_a", "ls_w", "R1846"), ("q5", "from_str", "R1846"), ("a", "create", "R1849"), ("a", "create", "R1859"), ("sib", "other_sib", "R1860"),
            ("a", "open", "R1858"), ("a", "connect", "R1849"), ("a", "m", "R1850")}
    ok = True
    for w in sorted(want):
        hit = w in got; print(("OK   " if hit else "FAIL ") + "seeded site " + str(w)); ok &= hit
    for e in sorted(got - want): print("FAIL unexpected", e); ok = False
    q5 = [x for x in ss if x["fn"] == "q5"]
    okq = bool(q5) and bool(q5[0]["r1846"]["callee_units"]); print(("OK   " if okq else "FAIL ") + "std supertrait: local implementor of from_str is a callee unit"); ok &= okq
    okt = not any(x["m"] == "new" for x in cr0.sites) and any(x["m"] == "y2" and x["kind"] == "qself" for x in cr0.sites)   # raw sites: shaped ones would hide it
    print(("OK   " if okt else "FAIL ") + "`Vec::<Self>::new` (generic argument) does not fire as a qself path"); ok &= okt
    for fn, m in [("q4_own", "own"), ("x", "y"), ("str_comment", "create")]:
        bad = any(s["fn"] == fn and s["m"] == m for s in ss); print(("FAIL " if bad else "OK   ") + f"negative {fn}::{m} does not fire"); ok &= not bad
    vs = {reading([])[0], reading([dict(inferred=["Fs"])])[0], reading([dict(inferred=["Unknown"])])[0], reading([dict(inferred=["Fs", "Unknown"])])[0]}
    okv = vs == {"SILENT", "CHARGED", "UNKNOWN", "UNKNOWN+CHARGED"}; print(("OK   " if okv else "FAIL ") + f"reading verdicts {sorted(vs)}"); ok &= okv
    fl = {silent_for("SILENT", set(), {"Fs"}), silent_for("CHARGED", {"Fs"}, {"Fs"}), silent_for("UNKNOWN", set(), {"Fs"}), silent_for("CHARGED", {"Net"}, {"Fs"})}
    okf = fl == {"SILENT-WITH-EFFECT", "CAUGHT", "DISCLOSED"}; print(("OK   " if okf else "FAIL ") + f"flip classes {sorted(fl)}"); ok &= okf
    okse = std_effect("File", "create") == "Fs" and std_effect("File", "new") is None and std_effect("Command", "output") == "Exec"
    print(("OK   " if okse else "FAIL ") + "std effect oracle"); ok &= okse
    if subprocess.run(["rustc", "--version"], capture_output=True).returncode == 0:      # executed oracle: able to say both answers
        oc = {}; a1 = rustc_oracle(["std", "fs", "File"], "read_at", oc); a2 = rustc_oracle(["std", "fs", "File"], "create", oc)
        oko = (a1, a2) == ("no-public-inherent", "public-inherent"); print(("OK   " if oko else "FAIL ") + f"rustc oracle: File::read_at={a1}, File::create={a2}"); ok &= oko
    d2 = tempfile.mkdtemp(prefix="selfcensus-selftest2-"); os.makedirs(d2 + "/src")
    open(d2 + "/src/lib.rs", "w").write("use serde::*;\npub trait T { fn m(); }\nimpl T for serde::x::Y { fn m() { Self::q() } }\n")
    open(d2 + "/Cargo.toml", "w").write('[package]\nname="t"\n[dependencies]\nserde = "1"\n')
    bad = any("R1850" in s["shapes"] for s in sites_for(analyse_crate(d2), set()))
    print(("FAIL " if bad else "OK   ") + "declared dependency root does not count as glob-bound"); ok &= not bad
    print("selftest:", "OK" if ok else "FAILED"); return 0 if ok else 1

def main():
    if "--selftest" in sys.argv: sys.exit(selftest())
    p = argparse.ArgumentParser(); sp = p.add_subparsers(dest="cmd", required=True)
    s = sp.add_parser("sites"); s.add_argument("--roster"); s.add_argument("--crates", nargs="*"); s.add_argument("--out", required=True)
    s.add_argument("--std-table", help="crates/candor-scan/src/std_assoc.tsv of the commit under test")
    s = sp.add_parser("scan"); s.add_argument("--sites", required=True); s.add_argument("--scan-bin", required=True)
    s.add_argument("--work", required=True); s.add_argument("--jobs", type=int, default=2); s.add_argument("--timeout", type=int, default=900)
    s.add_argument("--roster"); s.add_argument("--with-deps", action="store_true")
    s = sp.add_parser("join"); s.add_argument("--sites", required=True); s.add_argument("--work", required=True); s.add_argument("--out", required=True)
    s.add_argument("--roster"); s.add_argument("--rustc-oracle", action="store_true")
    s = sp.add_parser("sample"); s.add_argument("--joined", required=True); s.add_argument("--row", required=True)
    s.add_argument("--n", type=int, default=25); s.add_argument("--seed", type=int, default=1); s.add_argument("--effect-only", action="store_true")
    a = p.parse_args()
    {"sites": cmd_sites, "scan": cmd_scan, "join": cmd_join, "sample": cmd_sample}[a.cmd](a)

if __name__ == "__main__": main()
