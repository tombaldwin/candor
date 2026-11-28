#!/usr/bin/env python3
"""swift-index-diff.py: the compiler's index store vs candor-swift's hand resolver, per call site.

A shared, calibrated INSTRUMENT (Fable review of the swift typer strategy, 2026-11-28: "build the differential now,
no product change"). It never changes a report; it measures where the hand resolver and the compiler disagree.

USAGE
  swift-index-diff.py run  <pkg-dir> --work <dir> --out <dir> [--candor BIN] [--keep-build] [--no-copy]
        copy <pkg-dir> (without .build/.swiftpm) into --work, `swift build` it (debug: the only configuration
        SwiftPM 6.4 indexes), read the index store, scan the same tree with candor-swift (standalone, --out),
        and diff. Writes <out>/diff.json, <out>/diff.txt, <out>/occ.jsonl.gz and the candor report.
  swift-index-diff.py diff --occ <occ.jsonl.gz> --report <candor .Swift.json> --root <dir> --out <dir>
        diff only, over an existing store dump and report (the .callgraph.json sidecar beside it is required).
  swift-index-diff.py pool <manifest.tsv> --work <dir> --out <dir> [--only a,b] [--candor BIN]
        clone each pinned package (name, url, commit; default manifest swift-index-diff.pool.tsv beside this
        file), `run` it, delete its tree, and write <out>/SUMMARY.txt. One build at a time.
  swift-index-diff.py summary <out-dir>...       pool totals over several `run`/`diff` outputs.
  swift-index-diff.py locate <pkg-dir>           list every index store under the tree (and DerivedData if given).
  swift-index-diff.py --selftest [--candor BIN]  calibration: seeded disagreement, seeded silent drop, seeded
        contradicted dispatch reason and a clean pair, first on a synthetic candor arm (proves the COMPARATOR can
        fire, independent of the engine) and then on the real engine (proves the R2031/R2034 seeds still reproduce).

WHAT IT MEASURES (each per caller unit; candor's sidecar has no positions, so a "site" is the compiler's site and
candor's answer is the caller unit's edge set; matching is name-level on Type.Nested.member, overload-blind,
strengthened by a loc join for every unit that has a report row):
  (A) sites BOTH resolve: the compiler bound the site to Y and candor has an edge with Y's member name from that
      caller. AGREE when one of those edges names Y (or an overrider of Y for a dynamic call, or the base of a
      synthesized/inherited Y); DISAGREE otherwise; DISAGREE-EXT when the compiler bound the site OUTSIDE the
      package and candor bound an in-package unit of that name. Each disagreement is classified
      naming-artefact / wrong-target-effectful (silence or fabrication direction) / wrong-target-pure.
  (B) every `dispatch:T.m` (and other) Unknown reason, against the compiler's sites of member m in that unit:
      STATIC (the store resolves the site to a concrete callee: a hedge a typer would close), CONTRADICTED (the
      compiler's callee is not a member of T: R2001's false spelling), DYNAMIC (consistent open dispatch, with
      the in-build implementor count), NO-SITE.
  (C) first-hop unhedged loss: a compiler-resolved in-package callee carries a concrete effect (on every one of
      its overload rows) that the caller's row lacks; UNHEDGED when the caller row has no Unknown and no
      invisible. Same rule as the strategy prototype's covpool.py, so the 156/12 figure is regenerable.

BOUNDARIES (printed in every diff.txt, Fable change 5): sites with no calledBy (initialiser bodies of stored
properties and globals) are attributed to their containedBy declaration and reported in their own block;
sites with neither are counted as unattributed; callers with no candor unit are counted and excluded; a build
sees ONE configuration (the inactive #if arms candor reads are invisible to the store, so a candor-only edge is
not by itself an error); callees outside the package are compared only for DISAGREE-EXT and (B).

Exit codes: 0 measured; 2 not a measurement (stale store, build failed, no store, no candor arm); selftest 0/1."""
import collections
import gzip
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import swift_indexstore as IS  # noqa: E402

HARNESS_DIRS = {'Tests', 'Benchmarks', 'Examples', 'Snippets', 'Plugins'}
CALLEE_KINDS = {12, 16, 17, 18, 19, 20, 21, 22}   # function, methods, properties (accessors), constructor
ACCESSOR = re.compile(r'^(getter|setter|_modify|modify|willSet|didSet|_read|read|init|unsafeAddress|unsafeMutableAddress):')
EFFECT_NONCONCRETE = {'Unknown'}


# ----------------------------------------------------------------------------------------------------------------
# candor side
def norm(k):
    k = re.sub(r'#\d+$', '', k)
    k = re.sub(r'\(.*$', '', k)
    return re.sub(r'\.<(get|set|modify|read|willSet|didSet)>$', '', k)


def leaf(q):
    return q.rsplit('.', 1)[-1] if q else q


class Candor:
    def __init__(self, report_path):
        self.report_path = report_path
        rep = json.load(open(report_path))
        self.package = rep.get('package')
        cgp = report_path[:-len('.json')] + '.callgraph.json'
        if not os.path.exists(cgp):
            raise SystemExit('swift-index-diff: no callgraph sidecar beside %s (scan with --out)' % report_path)
        cg = json.load(open(cgp))
        self.raw_keys = set(cg)
        self.units = collections.Counter(norm(k) for k in cg)          # name -> number of overload units
        self.edges = collections.defaultdict(set)                      # name -> callee names
        for k, v in cg.items():
            for t in v:
                self.edges[norm(k)].add(norm(t))
        self.rows = collections.defaultdict(list)
        for f in rep.get('functions', []):
            self.rows[norm(f['fn'])].append(f)

    def eff_any(self, n):
        return set().union(*(set(f.get('inferred', [])) for f in self.rows.get(n, []))) - EFFECT_NONCONCRETE

    def eff_all(self, n):
        """concrete effects carried by EVERY overload unit of n (a pure overload has no row, so it empties the set)"""
        fs = self.rows.get(n, [])
        if not fs or len(fs) != self.units.get(n, 0):
            return set()
        return set.intersection(*(set(f.get('inferred', [])) for f in fs)) - EFFECT_NONCONCRETE

    def hedged(self, n):
        return any('Unknown' in f.get('inferred', []) or f.get('invisible') for f in self.rows.get(n, []))

    def has_row(self, n):
        return n in self.rows


# ----------------------------------------------------------------------------------------------------------------
# compiler side
class Store:
    def __init__(self, occ, root):
        self.root = os.path.realpath(root)
        self.occ = occ
        self.name, self.parent, self.ext_of, self.deffile, self.defline, self.kind = {}, {}, {}, {}, {}, {}
        self.explicit, self.implicit_def = set(), set()
        self.overriders = collections.defaultdict(set)
        self.bases = collections.defaultdict(set)
        for o in occ:
            u = o['usr']
            self.name.setdefault(u, o['name'])
            isdef = 'def' in o['roles']
            if isdef or 'decl' in o['roles']:
                self.kind.setdefault(u, o['kind'])
            if isdef:
                self.deffile.setdefault(u, o['file'])
                if 'implicit' in o['roles']:
                    self.implicit_def.add(u)
                else:
                    self.explicit.add(u)
                    self.defline.setdefault(u, (self.rel(o['file']), o['line']))
            for r in o['rel']:
                self.name.setdefault(r[1], r[2])
                if (isdef or 'decl' in o['roles']) and ('childOf' in r[0] or 'accessorOf' in r[0]):
                    self.parent.setdefault(u, r[1])
                if 'extendedBy' in r[0]:
                    self.ext_of[r[1]] = u
                if 'overrideOf' in r[0]:
                    self.overriders[r[1]].add(u)
                    self.bases[u].add(r[1])
        self._q = {}
        self._src = {}

    def fnvalue(self, o):
        """the site reads a STORED property and invokes the value: `self.f()` where f is a closure-typed stored
        property. The store records only the (implicit) getter call; the invocation itself is a function value."""
        if not (o['name'].startswith('getter:') and 'implicit' in o['roles']):
            return False
        if o['usr'] in self.explicit:
            return False
        lines = self._src.get(o['file'])
        if lines is None:
            try:
                lines = open(o['file'], encoding='utf-8', errors='replace').read().split('\n')
            except OSError:
                lines = []
            self._src[o['file']] = lines
        if not 0 < o['line'] <= len(lines):
            return False
        tail = lines[o['line'] - 1].encode('utf-8')[o['col'] - 1 + len(o['name'][len('getter:'):].split('(')[0].encode('utf-8')):]
        return bool(re.match(rb'^\s*[?!]?\s*\(', tail))

    def rel(self, f):
        return os.path.relpath(os.path.realpath(f), self.root)

    def own(self, f):
        rf = os.path.realpath(f)
        if not rf.startswith(self.root + os.sep) or '/.build/' in rf:
            return False
        return not (set(self.rel(f).split(os.sep)[:-1]) & HARNESS_DIRS)

    def qual(self, u, d=0):
        if u in self._q:
            return self._q[u]
        if d > 20:
            return '?'
        n = self.name.get(u, '?')
        if ACCESSOR.match(n) and u in self.parent:
            q = self.qual(self.parent[u], d + 1)
        else:
            n = n.split('(')[0]
            p = self.parent.get(u)
            if p in self.ext_of:
                p = self.ext_of[p]
            q = (self.qual(p, d + 1) + '.' + n) if p else n
        self._q[u] = q
        return q

    def family(self, u, dynamic):
        """the declarations a call to u can reach: u, every transitive overrider when dynamic, and what an implicit
        (synthesized / inherited) declaration stands for"""
        out, st = {u}, [u]
        if u in self.parent and ACCESSOR.match(self.name.get(u, '')):
            out.add(self.parent[u])          # overrideOf is recorded on the property / subscript, not its accessors
            st.append(self.parent[u])
        if dynamic:
            while st:
                x = st.pop()
                for y in self.overriders.get(x, ()):
                    if y not in out:
                        out.add(y)
                        st.append(y)
        if u in self.implicit_def:
            out |= self.bases.get(u, set())
        return out

    def category(self, u):
        f = self.deffile.get(u)
        if f and self.own(f):
            return 'in-package-C' if u.startswith('c:') else 'in-package'
        return 'dependency-source' if f else 'external'


def demangle(usrs):
    """owner names for Swift USRs (s:...) via `swift demangle`; {} if the tool is missing"""
    usrs = [u for u in usrs if u.startswith('s:')]
    if not usrs:
        return {}
    try:
        out = subprocess.run(['xcrun', 'swift-demangle', '--compact'], input='\n'.join('$s' + u[2:] for u in usrs),
                             capture_output=True, text=True, timeout=120).stdout.splitlines()
    except (OSError, subprocess.SubprocessError):
        try:
            out = subprocess.run(['swift', 'demangle', '--compact'], input='\n'.join('$s' + u[2:] for u in usrs),
                                 capture_output=True, text=True, timeout=120).stdout.splitlines()
        except (OSError, subprocess.SubprocessError):
            return {}
    return dict(zip(usrs, out)) if len(out) == len(usrs) else {}


def dq_module(s):
    s = re.sub(r'^((static|class|mutating|nonmutating|__owned|final|dynamic|@objc)\s+)+', '', s.strip())
    m = re.match(r'^\(extension in ([^)]*)\):', s)
    return m.group(1) if m else re.split(r'[ .(:<]', s, 1)[0]


HOOK_OWNERS = {'KeyedEncodingContainer', 'UnkeyedEncodingContainer', 'SingleValueEncodingContainer',
               'KeyedDecodingContainer', 'UnkeyedDecodingContainer', 'SingleValueDecodingContainer',
               'Hasher', 'DefaultStringInterpolation', 'String', 'TextOutputStream'}
HOOK_LEAVES = {'encode', 'decode', 'hash', 'combine', 'description', 'debugDescription', 'appendInterpolation', 'write'}
STDLIB_MODULES = {'Swift', '_Concurrency', '_StringProcessing', 'Synchronization', 'Observation'}


def dq_path(s):
    """a demangled symbol -> its path without module and accessor: 'Equatable.==', 'HTTPFields.init', 'Sequence.isASCII'"""
    s = re.sub(r'^((static|class|mutating|nonmutating|__owned|final|dynamic|@objc)\s+)+', '', s.strip())
    s = re.sub(r'^\(extension in [^)]*\):', '', s)
    for _ in range(4):
        s = re.sub(r'<[^<>]*>', '', s)
    head = re.split(r' |\(|:', s, 1)[0]
    parts = [p for p in head.split('.') if p]
    if parts and parts[-1] in ('getter', 'setter', 'modify', 'read', '_modify', 'unsafeAddressor', 'unsafeMutableAddressor', 'willset', 'didset'):
        parts = parts[:-1]
    return '.'.join(parts[1:]) if len(parts) > 1 else (parts[0] if parts else '')


def owner_of_demangled(s):
    """'static Swift.Equatable.== infix(A, A) -> Swift.Bool' -> 'Equatable'; '(extension in Swift):Swift.RawRepresentable<...>.== ...' -> 'RawRepresentable'"""
    s = re.sub(r'^(static|class|mutating|nonmutating|__owned|final|dynamic)\s+', '', s.strip())
    s = re.sub(r'^\(extension in [^)]*\):', '', s)
    s = re.sub(r'<[^<>]*>', '', s)
    s = re.sub(r'<[^<>]*>', '', s)
    head = re.split(r'[ (:]', s, 1)[0]
    parts = [p for p in head.split('.') if p]
    return parts[-2] if len(parts) >= 2 else ''


# ----------------------------------------------------------------------------------------------------------------
# the diff
def diff(occ, report_path, root, sample_n=12, seed=1928):
    st, cd = Store(occ, root), Candor(report_path)
    # loc join: a candor row's loc (decl start, modifiers and attributes included) to the compiler's explicit def of
    # the same member name within the 4 lines that follow it
    defs_at = collections.defaultdict(list)
    for u, (f, ln) in st.defline.items():
        defs_at[(f, ln)].append(u)
    loc_map = {}
    for n, fs in cd.rows.items():
        for f in fs:
            m = re.match(r'^(.*):(\d+):\d+$', f.get('loc', ''))
            if not m:
                continue
            for dl in range(0, 5):
                hit = [u for u in defs_at.get((m.group(1), int(m.group(2)) + dl), []) if leaf(st.qual(u)) == leaf(n)]
                if hit:
                    loc_map.setdefault(n, set()).update(hit)
                    break
    known_quals = set(st.qual(u) for u in st.explicit)

    dem = demangle(sorted(set(o['usr'] for o in occ if 'call' in o['roles'] and st.own(o['file'])
                              and st.category(o['usr']) != 'in-package')))
    sites = collections.Counter()
    by_caller = collections.defaultdict(list)     # candor caller name -> [site]
    init_sites = collections.defaultdict(list)
    for o in occ:
        if 'call' not in o['roles'] or not st.own(o['file']):
            continue
        cal = [r[1] for r in o['rel'] if 'calledBy' in r[0]]
        initsite = False
        if not cal:
            cal = [r[1] for r in o['rel'] if 'containedBy' in r[0]]
            initsite = True
        if not cal:
            sites['unattributed'] += 1
            continue
        y = o['usr']
        cat = st.category(y)
        dyn = 'dynamic' in o['roles']
        s = dict(site='%s:%d:%d' % (st.rel(o['file']), o['line'], o['col']), usr=y, q=st.qual(y), leaf=leaf(st.qual(y)),
                 cat=cat, dyn=dyn, impl='implicit' in o['roles'], fnvalue=st.fnvalue(o),
                 fam=sorted(set(st.qual(x) for x in st.family(y, dyn))), famu=st.family(y, dyn),
                 recv=[r[2] for r in o['rel'] if 'receivedBy' in r[0]], dq=dq_path(dem.get(y, '')) if cat != 'in-package' else '',
                 dmod=dq_module(dem.get(y, '')) if cat != 'in-package' else '')
        for c in cal:
            cq = st.qual(c)
            s2 = dict(s, caller=cq)
            if initsite:
                sites['initialiser:' + cat] += 1
                init_sites[cq].append(s2)
            else:
                sites['body:' + cat] += 1
                by_caller[cq].append(s2)

    def matches(x, s):
        if x in s['fam'] or bool(loc_map.get(x, set()) & s['famu']):
            return True
        # a member the compiler synthesized or inherited has no def in the store: its demangled path names it
        return bool(s['dq']) and (x == s['dq'] or x.endswith('.' + s['dq']))

    # ---- (A) + (C) over body sites, and the same over initialiser sites
    def compare(groups):
        res = dict(no_unit_sites=0, no_unit_callers=0, agree=0, disagree=0, disagree_ext=0, missing=0, external=0,
                   sites=0, disagreements=[], loss=[])
        for cq, ss in groups.items():
            if cq not in cd.units:
                res['no_unit_callers'] += 1
                res['no_unit_sites'] += len(ss)
                continue
            K = cd.edges.get(cq, set())
            # a candor edge is EXPLAINED when some compiler site of this caller (any category) names its target
            expl = set(x for x in K if any(matches(x, s2) for s2 in ss))

            def explained(x):
                return x in expl
            seen_edge = set()
            for s in ss:
                res['sites'] += 1
                same = sorted(x for x in K if leaf(x) == s['leaf'])
                if s['leaf'] == 'init':
                    # a construction names its type in source: only a same-short-name type is a rival binding
                    yo = leaf((s['dq'] or s['q']).rsplit('.', 1)[0]) if '.' in (s['dq'] or s['q']) else ''
                    same = [x for x in same if matches(x, s) or ('.' in x and leaf(x.rsplit('.', 1)[0]) == yo)]
                if s['cat'] == 'in-package':
                    if any(matches(x, s) for x in same):
                        res['agree'] += 1
                        continue
                    wrong = [x for x in same if not explained(x)]
                    if wrong:
                        res['disagree'] += 1
                        kind, same = 'DISAGREE', wrong
                    else:
                        res['missing'] += 1
                        kind = None
                else:
                    if any(matches(x, s) for x in same):
                        res['agree'] += 1
                        continue
                    wrong = [x for x in same if not explained(x)]
                    if s['cat'] != 'in-package-C' and wrong and not s['impl']:
                        res['disagree_ext'] += 1
                        kind, same = 'DISAGREE-EXT', wrong
                    else:
                        res['external'] += 1
                        continue
                if kind and (cq, s['q'], tuple(same)) not in seen_edge:
                    seen_edge.add((cq, s['q'], tuple(same)))
                    res['disagreements'].append(classify(kind, cq, s, same))
                if kind is None:
                    # (C) first-hop loss: a missed in-package edge whose callee carries a concrete effect on every
                    # overload row, absent from the caller row
                    ey = set()
                    if s['dyn']:
                        # open dispatch: any in-build implementor can be the receiver, and candor charges a
                        # dispatched call with its implementors, so a clean caller has dropped the edge
                        for t in s['fam']:
                            ey |= cd.eff_all(t)
                    else:
                        for t in s['fam']:
                            if cd.has_row(t):
                                ey = cd.eff_all(t)
                                break
                    lost = ey - cd.eff_any(cq)
                    if lost:
                        res['loss'].append(dict(caller=cq, callee=s['q'], site=s['site'], dyn=s['dyn'], impl=s['impl'],
                                                lost=sorted(lost), hedged=cd.hedged(cq), caller_row=cd.has_row(cq)))
        return res

    def classify(kind, cq, s, xs):
        ey = set().union(*(cd.eff_any(t) for t in s['fam'])) if s['cat'] == 'in-package' else None
        ex = set().union(*(cd.eff_any(x) for x in xs))
        ec = cd.eff_any(cq)
        if any(loc_map.get(x, set()) & s['famu'] for x in xs):
            cls = 'naming-artefact:same-decl'
        elif all(x not in known_quals for x in xs):
            cls = 'naming-artefact:spelling'
        elif ey is None and s['dq'].rsplit('.', 1)[0] in HOOK_OWNERS and s['leaf'] in HOOK_LEAVES | {'combine'}:
            cls = 'naming-artefact:modelled-hook'
        elif ey is None and ex:
            cls = 'wrong-target-effectful:fabrication'
        elif ey is None and s['dmod'] not in STDLIB_MODULES:
            cls = 'wrong-target-effectful:possible-silence-ext'
        elif ey is None:
            cls = 'wrong-target-pure'
        elif ey - ex - ec:
            cls = 'wrong-target-effectful:silence'
        elif ex - ey:
            cls = 'wrong-target-effectful:fabrication'
        elif ey != ex:
            cls = 'wrong-target-effectful:masked'
        else:
            cls = 'wrong-target-pure'
        return dict(kind=kind, cls=cls, caller=cq, compiler=s['dq'] or s['q'], compiler_cat=s['cat'], compiler_module=s['dmod'], candor=xs, site=s['site'],
                    dyn=s['dyn'], eff_compiler=sorted(ey) if ey is not None else None, eff_candor=sorted(ex),
                    eff_caller=sorted(ec), caller_hedged=cd.hedged(cq))

    A = compare(by_caller)
    I = compare(init_sites)

    # ---- (B) Unknown reasons vs the store
    B = collections.Counter()
    breasons = []
    for n, fs in cd.rows.items():
        whys = sorted(set(w for f in fs for w in f.get('unknownWhy', [])))
        ss = by_caller.get(n, []) + init_sites.get(n, [])
        for w in whys:
            kind = w.split(':', 1)[0] if ':' in w else w
            B['reason:' + kind] += 1
            m = re.match(r'^dispatch:(.+)\.([^.]+)$', w)
            if not m:
                continue
            T, mem = m.group(1), m.group(2)
            untyped = T.startswith('<') or 'untyped' in T
            hits = [s for s in ss if s['leaf'] == mem]
            if not hits:
                cls = 'NO-SITE'
            elif all(s['fnvalue'] for s in hits):
                cls = 'FN-VALUE'
            else:
                hits = [s for s in hits if not s['fnvalue']]
                owners = set()
                for s in hits:
                    if s['cat'] == 'in-package' or s['cat'] == 'dependency-source':
                        owners.add(s['q'].rsplit('.', 1)[0] if '.' in s['q'] else '')
                    else:
                        owners.add(s['dq'].rsplit('.', 1)[0] if '.' in s['dq'] else owner_of_demangled(dem.get(s['usr'], '')))
                    for b in st.bases.get(s['usr'], ()):
                        owners.add(st.qual(b).rsplit('.', 1)[0] if '.' in st.qual(b) else '')
                    owners.update(s['recv'])
                tleaf = leaf(T)
                if all(not s['dyn'] for s in hits):
                    cls = 'STATIC-ONE' if len(set(s['usr'] for s in hits)) == 1 else 'STATIC-MANY'
                    if not untyped and tleaf not in set(leaf(x) for x in owners if x):
                        cls += '+CONTRADICTED'
                elif untyped or tleaf in set(leaf(x) for x in owners if x):
                    cls = 'DYNAMIC'
                else:
                    cls = 'CONTRADICTED'
            B['dispatch:' + cls] += 1
            B['dispatch:' + ('untyped:' if untyped else 'typed:') + cls] += 1
            impls = sorted(set(len(s['famu']) - 1 for s in hits if s['dyn']))
            breasons.append(dict(unit=n, reason=w, cls=cls, untyped=untyped, dispatchesOn=any(f.get('dispatchesOn') for f in fs),
                                 sites=[s['site'] for s in hits][:4], callees=sorted(set(s['q'] for s in hits))[:4],
                                 owners=sorted(o for o in set((s['dq'] or s['q']).rsplit('.', 1)[0] for s in hits) if o)[:4],
                                 implementors=impls))

    unhedged = [x for x in A['loss'] if not x['hedged']]
    out = dict(
        package=cd.package, root=root, report=report_path,
        boundary=dict(call_sites=dict(sites), candor_units=sum(cd.units.values()), candor_names=len(cd.units),
                      body_callers_without_unit=A['no_unit_callers'], body_sites_without_unit=A['no_unit_sites'],
                      loc_joined_rows=len(loc_map), rows=len(cd.rows)),
        A=dict(sites=A['sites'], agree=A['agree'], disagree=A['disagree'], disagree_ext=A['disagree_ext'],
               missing=A['missing'], external_not_comparable=A['external'],
               both_resolve=A['agree'] + A['disagree'] + A['disagree_ext'],
               classes=dict(collections.Counter(d['cls'] for d in A['disagreements'])),
               disagreements=A['disagreements']),
        B=dict(counts=dict(B), reasons=breasons),
        C=dict(loss_edges=len(A['loss']), loss_callers=len(set(x['caller'] for x in A['loss'])),
               loss_callers_unhedged=len(set(x['caller'] for x in unhedged)), loss=A['loss']),
        initialisers=dict(sites=I['sites'], agree=I['agree'], disagree=I['disagree'], disagree_ext=I['disagree_ext'],
                          missing=I['missing'], callers_without_unit=I['no_unit_callers'],
                          sites_without_unit=I['no_unit_sites'], loss_edges=len(I['loss']),
                          loss_unhedged=[x for x in I['loss'] if not x['hedged']],
                          disagreements=I['disagreements']))
    return out


def render(d):
    b, A, B, Cc, I = d['boundary'], d['A'], d['B'], d['C'], d['initialisers']
    L = ['swift-index-diff: %s' % d['package'],
         'BOUNDARY  call sites by class: ' + ', '.join('%s %d' % kv for kv in sorted(b['call_sites'].items())),
         '          candor units %d (%d names), rows %d, loc-joined rows %d; body callers with NO candor unit %d (%d sites, excluded)'
         % (b['candor_units'], b['candor_names'], b['rows'], b['loc_joined_rows'], b['body_callers_without_unit'], b['body_sites_without_unit']),
         '          matching is NAME-LEVEL (Type.Nested.member, overload-blind) plus a loc join; one build = one configuration',
         '(A) both-resolve %d: agree %d, DISAGREE %d, DISAGREE-EXT %d  (missing %d, external-not-comparable %d)'
         % (A['both_resolve'], A['agree'], A['disagree'], A['disagree_ext'], A['missing'], A['external_not_comparable']),
         '    classes: ' + ', '.join('%s %d' % kv for kv in sorted(A['classes'].items()))]
    for x in A['disagreements']:
        L.append('    %-12s %-38s %s  %s -> compiler %s (%s%s) | candor %s  eff c=%s x=%s caller=%s'
                 % (x['kind'], x['cls'], x['site'], x['caller'], x['compiler'], x['compiler_cat'], ' dyn' if x['dyn'] else '',
                    x['candor'][:3], x['eff_compiler'], x['eff_candor'], x['eff_caller']))
    L.append('(B) ' + ', '.join('%s %d' % kv for kv in sorted(B['counts'].items())))
    for x in B['reasons']:
        if x['cls'] != 'DYNAMIC':
            L.append('    %-24s %s  %s  callees %s owners %s @ %s' % (x['cls'], x['unit'], x['reason'], x['callees'], x['owners'], x['sites'][:2]))
    L.append('(C) first-hop loss: %d edges, %d callers, %d UNHEDGED callers' % (Cc['loss_edges'], Cc['loss_callers'], Cc['loss_callers_unhedged']))
    for x in Cc['loss']:
        if not x['hedged']:
            L.append('    UNHEDGED %s  %s -> %s %s%s%s' % (x['site'], x['caller'], x['callee'], x['lost'], ' dyn' if x['dyn'] else '', '' if x['caller_row'] else ' (caller ABSENT)'))
    L.append('INITIALISER sites (containedBy, no calledBy) %d: agree %d, DISAGREE %d, DISAGREE-EXT %d, missing %d; owner with no candor unit %d (%d sites); loss %d edges, %d unhedged'
             % (I['sites'], I['agree'], I['disagree'], I['disagree_ext'], I['missing'], I['callers_without_unit'], I['sites_without_unit'], I['loss_edges'], len(I['loss_unhedged'])))
    for x in I['loss_unhedged']:
        L.append('    UNHEDGED-INIT %s  %s -> %s %s' % (x['site'], x['caller'], x['callee'], x['lost']))
    return '\n'.join(L) + '\n'


# ----------------------------------------------------------------------------------------------------------------
# acquisition
def find_stores(tree):
    out = []
    for dp, dn, fn in os.walk(tree):
        if os.path.basename(dp) == 'v5' and 'units' in dn:
            out.append(os.path.dirname(dp))
            dn[:] = []
        elif os.path.basename(dp) in ('checkouts', 'repositories', 'artifacts'):
            dn[:] = []
    return sorted(out)


def default_candor():
    return os.environ.get('CANDOR_SWIFT_BIN') or shutil.which('candor-swift') or os.path.expanduser('~/git/candor-swift/.build/release/candor-swift')


def scan(candor, tree, prefix):
    env = dict(os.environ)
    env.pop('CANDOR_DEPS', None)
    r = subprocess.run([candor, tree, '--out', prefix], env=env, capture_output=True, text=True, cwd=os.path.dirname(prefix))
    reps = sorted(p for p in (os.path.join(os.path.dirname(prefix), f) for f in os.listdir(os.path.dirname(prefix)))
                  if p.startswith(prefix + '.') and p.endswith('.Swift.json'))
    return r.returncode, reps, r.stderr


def run(pkg, work, out, candor, keep_build=False, copy=True, jobs='4', log=print):
    os.makedirs(out, exist_ok=True)
    tree = os.path.join(work, os.path.basename(os.path.realpath(pkg).rstrip('/')))
    meta = dict(pkg=pkg, tree=tree, candor=candor)
    if copy:
        if os.path.exists(tree):
            shutil.rmtree(tree)
        subprocess.run(['rsync', '-a', '--exclude', '.build', '--exclude', '.swiftpm', pkg.rstrip('/') + '/', tree + '/'], check=True)
    t = time.time()
    with open(os.path.join(out, 'build.log'), 'w') as bl:
        rc = subprocess.run(['swift', 'build', '-j', jobs], cwd=tree, stdout=bl, stderr=subprocess.STDOUT).returncode
    meta.update(build_rc=rc, build_wall=round(time.time() - t, 1))
    stores = find_stores(os.path.join(tree, '.build'))
    meta['stores'] = [os.path.relpath(s, tree) for s in stores]
    if rc != 0 or not stores:
        meta['verdict'] = 'NOT A MEASUREMENT: build rc %d, stores %s' % (rc, meta['stores'])
        json.dump(meta, open(os.path.join(out, 'meta.json'), 'w'), indent=1)
        log(meta['verdict'])
        return 2
    t = time.time()
    occ, stats = [], dict(stale_files=[])
    for s in stores:
        o, stt = IS.read_store(s, tree)
        occ += o
        stats = {k: (stats.get(k, 0) + v if k != 'stale_files' else stats.get(k, []) + v) for k, v in stt.items()}
    meta.update(read_wall=round(time.time() - t, 1), store_stats={k: (v if k != 'stale_files' else len(v)) for k, v in stats.items()})
    IS.write_occ(os.path.join(out, 'occ.jsonl.gz'), occ)
    if stats['stale_files']:
        meta['verdict'] = 'NOT A MEASUREMENT: %d source files newer than their unit: %s' % (len(stats['stale_files']), stats['stale_files'][:5])
        json.dump(meta, open(os.path.join(out, 'meta.json'), 'w'), indent=1)
        log(meta['verdict'])
        return 2
    t = time.time()
    crc, reps, err = scan(candor, tree, os.path.join(out, 'cand'))
    meta.update(candor_rc=crc, candor_wall=round(time.time() - t, 1), reports=[os.path.basename(r) for r in reps])
    if not keep_build:
        shutil.rmtree(os.path.join(tree, '.build'), ignore_errors=True)
    if not reps:
        meta['verdict'] = 'NOT A MEASUREMENT: candor wrote no report (rc %d): %s' % (crc, err[-400:])
        json.dump(meta, open(os.path.join(out, 'meta.json'), 'w'), indent=1)
        log(meta['verdict'])
        return 2
    d = diff(occ, reps[0], tree)
    d['meta'] = meta
    json.dump(d, open(os.path.join(out, 'diff.json'), 'w'), indent=1, default=sorted)
    open(os.path.join(out, 'diff.txt'), 'w').write(render(d))
    json.dump(meta, open(os.path.join(out, 'meta.json'), 'w'), indent=1)
    log(render(d).split('\n(B)')[0].split('\n')[4] + '   [%s]' % d['package'])
    return 0


def pool(manifest, work, out, candor, only=None):
    os.makedirs(work, exist_ok=True)
    os.makedirs(out, exist_ok=True)
    done = []
    for line in open(manifest):
        if not line.strip() or line.startswith('#'):
            continue
        name, url, sha = line.split()[:3]
        if only and name not in only:
            continue
        src = os.path.join(work, 'src', name)
        shutil.rmtree(src, ignore_errors=True)
        os.makedirs(src)
        ok = all(subprocess.run(c, cwd=src, capture_output=True).returncode == 0 for c in (
            ['git', 'init', '-q'], ['git', 'fetch', '-q', '--depth', '1', url, sha], ['git', 'checkout', '-q', 'FETCH_HEAD']))
        od = os.path.join(out, name)
        if not ok:
            os.makedirs(od, exist_ok=True)
            json.dump(dict(verdict='NOT A MEASUREMENT: could not fetch %s@%s' % (url, sha)), open(os.path.join(od, 'meta.json'), 'w'))
        else:
            run(src, os.path.join(work, 'build'), od, candor)
            shutil.rmtree(os.path.join(work, 'build', name), ignore_errors=True)
        shutil.rmtree(src, ignore_errors=True)
        done.append(od)
    s = summary(done)
    open(os.path.join(out, 'SUMMARY.txt'), 'w').write(s)
    sys.stdout.write(s)
    return 0 if all(os.path.exists(os.path.join(d, 'diff.json')) for d in done) else 2


def summary(dirs):
    tot = collections.Counter()
    cls, bc = collections.Counter(), collections.Counter()
    rows = []
    for dd in dirs:
        p = os.path.join(dd, 'diff.json')
        if not os.path.exists(p):
            rows.append('%-28s NOT A MEASUREMENT (%s)' % (os.path.basename(dd), json.load(open(os.path.join(dd, 'meta.json'))).get('verdict') if os.path.exists(os.path.join(dd, 'meta.json')) else 'no meta'))
            continue
        d = json.load(open(p))
        A, C_, I = d['A'], d['C'], d['initialisers']
        for k in ('sites', 'both_resolve', 'agree', 'disagree', 'disagree_ext', 'missing'):
            tot['A_' + k] += A[k]
        tot['C_edges'] += C_['loss_edges']
        tot['C_callers'] += C_['loss_callers']
        tot['C_unhedged'] += C_['loss_callers_unhedged']
        tot['I_sites'] += I['sites']
        tot['I_unhedged'] += len(I['loss_unhedged'])
        tot['no_unit_sites'] += d['boundary']['body_sites_without_unit']
        for k, v in d['boundary']['call_sites'].items():
            tot['sites:' + k] += v
        cls.update(A['classes'])
        bc.update(d['B']['counts'])
        rows.append('%-28s both %6d  dis %4d  ext %4d  (%.3f%%)  loss %4d/%3d unhedged %2d  init %5d' % (
            d['package'], A['both_resolve'], A['disagree'], A['disagree_ext'],
            100.0 * (A['disagree'] + A['disagree_ext']) / max(1, A['both_resolve']), C_['loss_edges'], C_['loss_callers'],
            C_['loss_callers_unhedged'], I['sites']))
    rows.append('TOTAL ' + json.dumps(dict(tot)))
    rows.append('A classes ' + json.dumps(dict(cls)))
    rows.append('B ' + json.dumps(dict(sorted(bc.items()))))
    return '\n'.join(rows) + '\n'


# ----------------------------------------------------------------------------------------------------------------
# selftest
SELFTEST_PKG = {
    'Package.swift': '''// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "IdxDiffCal", targets: [.target(name: "Cal", path: "Sources/Cal")])
''',
    'Sources/Cal/Cal.swift': '''import Foundation
func calMark(_ n: String) { _ = FileManager.default.createFile(atPath: "/tmp/idxdiff-" + n, contents: Data()) }

// SEED-DROP (R2031 shape): a literal-typed receiver; the compiler binds Int.calLoud, the hand resolver drops it
extension Int { var calLoud: Int { calMark("drop"); return self } }
func calDropCaller() -> Int { (true ? 1 : 0).calLoud }

// SEED-DISAGREE (R2034 shape): a subscript forwarding to the sibling subscript of its base class; the compiler
// binds CalBase.subscript(_:), the hand resolver edges the unit's own subscript
struct CalComps { static let shared = CalComps(); let one = CalC() }
struct CalC {}
class CalBase { subscript(_ c: CalC) -> String { calMark("dis"); return "x" } }
final class CalAlias: CalBase {
    subscript(dynamicMember k: KeyPath<CalComps, CalC>) -> String { self[CalComps.shared[keyPath: k]] }
}

// CLEAN PAIR: a plain call both resolve to the same callee
struct CalClean { func calCleanCallee() { calMark("clean") } }
func calCleanCaller() { CalClean().calCleanCallee() }

// SEED-B (R2001 shape): the hand resolver hedges `&&` as `dispatch:String.&&`; the compiler binds Bool.&&
struct CalEntry: Equatable {
    enum Level: String { case a, b }
    var level: Level
    var msg: String
    static func == (l: CalEntry, r: CalEntry) -> Bool { l.level == r.level && l.msg == r.msg }
}
'''}


def _selftest(candor):
    fails = []
    tmp = tempfile.mkdtemp(prefix='swiftagent-idxdiff-selftest-')
    try:
        pk = os.path.join(tmp, 'IdxDiffCal')
        for p, s in SELFTEST_PKG.items():
            os.makedirs(os.path.dirname(os.path.join(pk, p)), exist_ok=True)
            open(os.path.join(pk, p), 'w').write(s)
        r = subprocess.run(['swift', 'build'], cwd=pk, capture_output=True, text=True)
        if r.returncode:
            print('selftest: NOT A MEASUREMENT: fixture build failed\n' + r.stdout[-800:] + r.stderr[-800:])
            return 1
        stores = find_stores(os.path.join(pk, '.build'))
        if not stores:
            print('selftest: NOT A MEASUREMENT: swift build wrote no index store')
            return 1
        occ = []
        for s in stores:
            occ += IS.read_store(s, pk)[0]

        def check(name, cond, detail=''):
            print('  %-4s %s %s' % ('ok' if cond else 'FAIL', name, detail))
            if not cond:
                fails.append(name)

        # ---- layer 1: a SYNTHETIC candor arm built from the store itself, then mutated. Proves the comparator
        # fires on a disagreement and a drop and stays quiet on a clean pair, whatever the engine does today.
        st = Store(occ, pk)
        cg = collections.defaultdict(set)
        for o in occ:
            if 'call' in o['roles'] and st.own(o['file']):
                for r_ in o['rel']:
                    if 'calledBy' in r_[0] and st.category(o['usr']) == 'in-package':
                        cg[st.qual(r_[1])].add(st.qual(o['usr']))
                        cg.setdefault(st.qual(o['usr']), set())
        need = ['calDropCaller', 'Int.calLoud', 'CalAlias.subscript', 'CalBase.subscript', 'calCleanCaller', 'CalClean.calCleanCallee']
        check('synthetic arm has the fixture units', all(k in cg for k in need), sorted(cg))
        effs = {'Int.calLoud': ['Fs'], 'CalBase.subscript': ['Fs'], 'CalClean.calCleanCallee': ['Fs'], 'calMark': ['Fs']}

        def write_arm(tag, mutate, why=None):
            g = {k: set(v) for k, v in cg.items()}
            fx = {k: list(v) for k, v in effs.items()}
            mutate(g, fx)
            rows = []
            for k in g:              # one hop is enough: the fixture's effectful callees call calMark directly
                e = set(fx.get(k, []))
                for t in g[k]:
                    e |= set(fx.get(t, []))
                if e or (why and k in why):
                    rows.append(dict(fn=k, inferred=sorted(e | ({'Unknown'} if why and k in why else set())), direct=[],
                                     calls=sorted(g[k]), unknownWhy=(why or {}).get(k, [])))
            pre = os.path.join(tmp, tag + '.IdxDiffCal.Swift')
            json.dump(dict(package='IdxDiffCal', functions=rows), open(pre + '.json', 'w'))
            json.dump({k: sorted(v) for k, v in g.items()}, open(pre + '.callgraph.json', 'w'))
            return diff(occ, pre + '.json', pk)

        clean = write_arm('clean', lambda g, fx: None)
        check('L1 clean arm: (A) 0 disagreements', clean['A']['disagree'] + clean['A']['disagree_ext'] == 0, clean['A']['classes'])
        check('L1 clean arm: (C) 0 losses', clean['C']['loss_edges'] == 0)

        def seed(g, fx):
            g['calDropCaller'].discard('Int.calLoud')                       # the drop
            g['CalAlias.subscript'] = {'CalAlias.subscript'}                 # the wrong target (own unit)
        seeded = write_arm('seeded', seed)
        dis = [x for x in seeded['A']['disagreements'] if x['caller'] == 'CalAlias.subscript']
        check('L1 seeded disagreement reported', len(dis) == 1 and dis[0]['compiler'] == 'CalBase.subscript', dis)
        check('L1 seeded disagreement is wrong-target-effectful:silence', bool(dis) and dis[0]['cls'] == 'wrong-target-effectful:silence', dis[0]['cls'] if dis else '')
        loss = [x for x in seeded['C']['loss'] if x['caller'] == 'calDropCaller' and not x['hedged']]
        check('L1 seeded drop reported UNHEDGED', len(loss) == 1 and loss[0]['lost'] == ['Fs'], loss)
        check('L1 clean pair silent in the seeded arm', not any(x['caller'] == 'calCleanCaller' for x in seeded['A']['disagreements'] + seeded['C']['loss']))

        def hedge(g, fx):
            g['calDropCaller'].discard('Int.calLoud')
            fx['calDropCaller'] = ['Unknown']
        hd = write_arm('hedged', hedge)
        check('L1 a hedged drop is not UNHEDGED', hd['C']['loss_callers_unhedged'] == 0 and hd['C']['loss_edges'] == 1)

        bw = write_arm('bseed', lambda g, fx: g['calCleanCaller'].discard('CalClean.calCleanCallee'),
                       why={'calCleanCaller': ['dispatch:CalClean.calCleanCallee', 'dispatch:CalWrong.calCleanCallee']})
        bcls = {x['reason']: x['cls'] for x in bw['B']['reasons']}
        check('L1 a dispatch reason the store binds statically is STATIC-ONE', bcls.get('dispatch:CalClean.calCleanCallee') == 'STATIC-ONE', bcls)
        check('L1 a dispatch reason naming the wrong type is CONTRADICTED', bcls.get('dispatch:CalWrong.calCleanCallee') == 'STATIC-ONE+CONTRADICTED', bcls)
        cw = {x['reason']: x['cls'] for x in clean['B']['reasons']}
        check('L1 clean arm: (B) no reasons', not cw, cw)

        # ---- layer 2: the REAL engine on the same tree. The seeds are R2031 / R2034 as measured on candor-swift
        # 1e81824; when the engine fixes either, this layer says SEED-STALE (replace the seed), not FAIL.
        if not candor or not os.path.exists(candor):
            print('  SKIP layer 2: no candor-swift binary (--candor or $CANDOR_SWIFT_BIN)')
        else:
            crc, reps, err = scan(candor, pk, os.path.join(tmp, 'real'))
            check('L2 candor wrote a report', bool(reps), '' if reps else err[-300:])
            if reps:
                real = diff(occ, reps[0], pk)
                d2 = [x for x in real['A']['disagreements'] if x['caller'] == 'CalAlias.subscript']
                l2 = [x for x in real['C']['loss'] if x['caller'] == 'calDropCaller' and not x['hedged']]
                cln = [x for x in real['A']['disagreements'] + real['C']['loss'] if x['caller'] == 'calCleanCaller']
                print('  %-4s L2 R2034 seed: real engine disagreement %s' % ('ok' if d2 else 'SEED-STALE', [(x['compiler'], x['candor'], x['cls']) for x in d2]))
                print('  %-4s L2 R2031 seed: real engine unhedged drop %s' % ('ok' if l2 else 'SEED-STALE', [(x['callee'], x['lost']) for x in l2]))
                b2 = [x for x in real['B']['reasons'] if x['unit'] == 'CalEntry.==' and x['reason'].endswith('.&&')]
                print('  %-4s L2 R2001 seed: real engine contradicted reason %s' % ('ok' if b2 and 'CONTRADICTED' in b2[0]['cls'] else 'SEED-STALE', [(x['reason'], x['cls'], x['owners']) for x in b2]))
                check('L2 clean pair reports nothing on the real engine', not cln, cln)
        print('selftest: %s' % ('FAILED ' + ', '.join(fails) if fails else 'OK'))
        return 1 if fails else 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main(argv):
    if not argv or argv[0] in ('-h', '--help'):
        print(__doc__)
        return 0

    def opt(name, default=None):
        return argv[argv.index(name) + 1] if name in argv else default
    if argv[0] == '--selftest':
        return _selftest(opt('--candor', default_candor()))
    cmd = argv[0]
    if cmd == 'run':
        return run(argv[1], opt('--work'), opt('--out'), opt('--candor', default_candor()), keep_build='--keep-build' in argv,
                   copy='--no-copy' not in argv, jobs=opt('-j', '4'))
    if cmd == 'diff':
        d = diff(IS.load_occ(opt('--occ')), opt('--report'), opt('--root'))
        o = opt('--out')
        os.makedirs(o, exist_ok=True)
        json.dump(d, open(os.path.join(o, 'diff.json'), 'w'), indent=1, default=sorted)
        open(os.path.join(o, 'diff.txt'), 'w').write(render(d))
        sys.stdout.write(render(d))
        return 0
    if cmd == 'pool':
        man = argv[1] if len(argv) > 1 and not argv[1].startswith('--') else os.path.join(HERE, 'swift-index-diff.pool.tsv')
        only = set(opt('--only').split(',')) if opt('--only') else None
        return pool(man, opt('--work'), opt('--out'), opt('--candor', default_candor()), only)
    if cmd == 'summary':
        sys.stdout.write(summary(argv[1:]))
        return 0
    if cmd == 'locate':
        for s in find_stores(argv[1]):
            print(s)
        return 0
    print(__doc__)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
