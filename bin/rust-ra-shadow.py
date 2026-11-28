#!/usr/bin/env python3
"""rust-ra-shadow.py: rust-analyzer's resolution (the ra SHADOW arm) vs candor-scan's call-graph sidecar and report rows.

A shared, calibrated INSTRUMENT (Fable review of the rust typer strategy, 2026-11-28, "Phase 0 only: the ra arm as a
SHADOW diff instrument, no product change"). It never changes a report. It measures where rust-analyzer and the hand
resolver disagree, and what a UNION of the two would add. The swift analogue is bin/swift-index-diff.py; the (A)/(B)
vocabulary and the per-caller-unit matching rule are kept the same on purpose.

The ra arm is tools/ra-shadow-arm (ra_ap_* 0.0.358, built with its own Cargo.lock, OUTSIDE candor-rust's workspace). It
loads a cargo project without building it (no build scripts, no proc-macro server) and writes every call site's
resolved callee (+ generic substitution), every fn decl with its line range, and the trait-impl index with each impl's
own cfg predicate.

USAGE
  rust-ra-shadow.py run <entries-file> --ra BIN (--cs BIN | --cs-from RUNDIR) --work DIR --out DIR [--jobs 2]
        [--online] [--only a,b]
        per entry: copy the tree into --work, run the ra arm (--offline unless --online), `cargo metadata`, and
        candor-scan (`--out`, fresh CANDOR_CACHE_DIR), then `diff`. Writes <out>/<entry>/{diff.json,diff.txt,...}.
        A summary of every entry is written to <out>/SUMMARY.txt by `summary`.
  rust-ra-shadow.py diff <entry-out-dir>           re-run the diff over a finished `run` entry.
        $RA_SHADOW_CLASSIFY names the candor-classify-paths binary (the sink oracle; without it: builtin table).
  rust-ra-shadow.py summary <out-dir>              pool totals over every entry, + the detector table.
  rust-ra-shadow.py gate <entry-out-dir> --cs BIN --tree DIR
        the (B) gate check: one policy with `deny <E> <unit>` for every ADDED (unit, E), run candor-scan --gate-json
        on the tree, and require that NONE of them is a violation today (so each ADDED row is a would-be 0->1 flip).
        A calibration line (`deny <E> <unit>` for a unit candor-scan DOES charge) must be a violation, or exit 2.
  rust-ra-shadow.py reach <sites.jsonl> <impls.jsonl> <probe> [--no-subst] [--trace]
        fixture-level: does the probe reach a std effect sink over ra's edges? --no-subst drops every generic
        substitution (a trait call on a type parameter falls to CHA): the proxy for a SCIP index, which carries
        definition symbols per occurrence but no substitutions.
  rust-ra-shadow.py fixture <dir> <probe>... --ra BIN --cs BIN --target-dir DIR [--work DIR]
        one executed fixture (a bin crate whose main dispatches on argv[1] to the probe fn; path deps allowed): per
        probe, EXECUTED ground truth (`cargo run` with MARK set: Fs when the file appears), candor-scan's row token
        (cfgtwin `reading()` semantics: - / E / U / E+U / []{inv,key}) and gate `U<rc>F<rc>` (`deny Unknown p` /
        `deny Fs p`) standalone AND chained over the path deps' own reports (leaves first), and the ra arm's reach
        with and without substitution. One TSV line per probe on stdout.
  rust-ra-shadow.py scip-reach <index.scip> <probe> [--trace]
        the SCIP alternative (Fable change 11): over `rust-analyzer scip <dir>` (the rustup component, no linking),
        does the probe reach a std sink? An occurrence is attributed to the innermost fn DEFINITION whose range
        contains it; a reference to a trait method DECLARATION fans out to every `impl#[..][Tr]m()` and the default
        (SCIP carries no substitution, so this is CHA); a call token that lives in a macro_rules! BODY is attributed
        to no fn (SCIP records it at the definition site), and is counted as `macro-body` instead.
  rust-ra-shadow.py --selftest                     synthetic calibration, no binaries needed (exit 0/1).

WHAT IT MEASURES (candor-scan's sidecar has no positions, so a "site" is ra's site and candor's answer is the CALLER
UNIT's edge set; matching is name-level on `module::Type::member`, the crate prefix and generics dropped):
  (A) ra resolved the site to a LOCAL definite callee X (free / inherent / trait impl, or a trait default with a
      concrete Self). AGREE when the caller's candor edges include X. DISAGREE when they do not but include a
      same-leaf unit Y (candor bound the site elsewhere). Each DISAGREE is classified:
        naming-artefact             X and Y are the same unit under two spellings (same Type::member);
        wrong-target-effectful/sil  X carries a concrete effect Y lacks (candor's binding is the silent one);
        wrong-target-effectful/fab  Y carries a concrete effect X lacks (candor's binding fabricates);
        wrong-target-pure           the effect sets are equal (no gate consequence).
      HEDGED: the caller row already has an Unknown whose reason names the member: candor did not RESOLVE it.
  (B) ADDED charged rows under a UNION (candor edges + ra-only/DISAGREE local edges + ra's direct std-sink edges):
      the fixpoint over the union graph, minus what candor's row already carries. Each added (unit, effect) names
      its ROOT ra edge (the site to ground-truth). Rows are split by what candor's row carries today: absent `-`,
      `[]` (invisible/dispatchesOn), U (Unknown only), E+U, E (other concrete effects, no Unknown). Only `-`, `[]`
      and E are silent today for the added effect; U and E+U already fail `deny Unknown`. An ra edge whose target is OUTSIDE the
      scanned crate (origin dep) adds nothing (Fable rule: it may remove nothing either) and is only counted.
  DETECTORS (each seeded in --selftest and, on real binaries, in the lane report):
      D1 deps     ra LOADED fewer dependency crates than `cargo metadata` resolves for the host: ra's own fallback
                  when metadata fails is a WITHOUT-DEPS load that says nothing. `deps: full|partial|metadata-failed`.
      D2 attrib   a macro-expanded site attributed to a caller whose line range does not contain the macro call
                  (the e10 shape: a cfg-disabled impl from an item macro charged to the preceding fn).
      D3 cfgimpl  an impl in ra's index whose own cfg predicate is FALSE on this host (ra's hir should drop it).
      D4 sysroot  no call site resolved into std/core/alloc: rust-src absent, resolution collapses silently.
  An entry with D1 != full, D2 > 0, D3 > 0 or D4 set is reported, and its (B) rows are tagged with the detector, so
  a degraded load is never read as a clean diff.

BOUNDARIES (printed in every diff.txt): ra sees ONE configuration (host target, default features); sites ra marks
`inactive` (cfg-disabled items) are counted, never compared. Sites with no enclosing fn (const/static initialisers)
have caller "" and are counted as unattributed. Callers or callees with no candor key are counted and excluded.
Sinks: every std/core/alloc callee is classified by candor-classify itself ($RA_SHADOW_CLASSIFY, the
candor-classify-paths helper); without it a std::fs/env/net/process table is used and diff.txt says `sinks=builtin`.

Exit codes: 0 measured; 2 usage; 3 not a measurement (an arm failed, no candor sidecar, nothing compared).
"""
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

SINKS = [('Fs', re.compile(r'^std::fs::')), ('Env', re.compile(r'^std::env::')),
         ('Net', re.compile(r'^std::net::')), ('Exec', re.compile(r'^std::process::'))]
DEFINITE = ('free', 'inherent', 'trait_impl')
NONCONCRETE = {'Unknown'}


def _open(p):
    return gzip.open(p, 'rt') if p.endswith('.gz') else open(p)


# ---------------------------------------------------------------------------------------------------------- ra side
def split_path(p):
    """`k::m::<Ty<A, B> as Tr<X>>::f` -> ['k', 'm', '<Ty<A, B> as Tr<X>>', 'f'], respecting <...>."""
    toks, buf, d, i = [], '', 0, 0
    while i < len(p):
        ch = p[i]
        if ch == '<':
            d += 1
        elif ch == '>':
            d -= 1
        if d == 0 and p.startswith('::', i):
            toks.append(buf)
            buf = ''
            i += 2
            continue
        buf += ch
        i += 1
    toks.append(buf)
    return [t for t in toks if t]


def _seg(t):
    if t.startswith('<') and t.endswith('>'):
        t = t[1:-1]
        if t.startswith('dyn '):
            t = t[4:]
        elif ' as ' in t:
            # `<Ty as Tr>`: the impl's self type names the candor unit; split at the TOP-LEVEL ' as '
            d, cut = 0, None
            for i, ch in enumerate(t):
                d += (ch == '<') - (ch == '>')
                if d == 0 and t.startswith(' as ', i):
                    cut = i
                    break
            t = t[:cut] if cut is not None else t
    t = t.lstrip('&').replace('mut ', '').replace('dyn ', '').strip()
    t = re.sub(r'<.*', '', t)
    return t.split('::')[-1]


def cs_key(ra_path):
    """ra's fn path -> candor-scan's unit key spelling: crate prefix dropped, impl segment -> its self type (or the
    trait for a default/declaration), generics dropped."""
    segs = split_path(ra_path)
    return '::'.join(_seg(s) for s in segs[1:]) if len(segs) > 1 else (segs[0] if segs else '')


def cs_keys(ra_path):
    """The primary spelling plus the two candor spellings measured on real crates (sqlx-core, 2026-11-28): an impl on a
    REFERENCE or `dyn Tr + 'a` self type is keyed WITHOUT a type segment (`impl Executor for &Pool` -> `pool::executor::
    fetch_many`), and a raw identifier keeps its `r#` (`Yielder::r#yield`)."""
    segs = split_path(ra_path)
    out = [cs_key(ra_path)]
    if len(segs) > 2 and segs[-2].startswith('<'):
        inner = segs[-2][1:-1]
        if inner.startswith('&') or (inner.startswith('dyn ') and ('+' in inner)):
            out.append('::'.join([_seg(x) for x in segs[1:-2]] + [segs[-1]]))
    out += [k.rsplit('::', 1)[0] + '::r#' + leaf(k) if '::' in k else 'r#' + k for k in list(out)]
    return out


def decl_keys(d):
    """cs_keys() of a decl, plus the spelling from the impl's self type AS WRITTEN (ra prints the canonical type:
    `NonZero<i16>` where the source, and candor's key, say `NonZeroI16`; a tuple self type has no type segment)."""
    out = cs_keys(d['path'])
    st = d.get('self_src')
    segs = split_path(d['path'])
    # a `#[path = "x64.rs"] mod x;` module: candor keys it by the FILE stem (`soft::fixslice64::f`), ra by the mod name
    stem = os.path.splitext(os.path.basename(d.get('file') or ''))[0]
    if stem and stem not in ('mod', 'lib', 'main') and len(segs) > 2:
        mi = next((i for i in range(len(segs) - 1, 0, -1) if not segs[i].startswith('<') and i < len(segs) - 1), None)
        if mi and segs[mi] != stem:
            alt = segs[:mi] + [stem] + segs[mi + 1:]
            # the file-stem spelling goes FIRST: candor keeps a `platform::f` placeholder with no edges beside the
            # real `tz_linux::f` (measured: iana-time-zone), so an exact hit on the mod-name spelling is the wrong unit
            out = decl_keys({'path': '::'.join(alt), 'self_src': st}) + out
    if st and len(segs) > 2 and segs[-2].startswith('<'):
        mods = [_seg(x) for x in segs[1:-2]]
        t = st.strip()
        if t.startswith('(') or t.startswith('&') or t.startswith('['):
            out.append('::'.join(mods + [segs[-1]]))
        else:
            ty = re.sub(r'<.*', '', t.replace('dyn ', '')).split('+')[0].strip().split('::')[-1]
            out.append('::'.join(mods + [ty, segs[-1]]))
    return out


def leaf(k):
    return k.rsplit('::', 1)[-1]


def last2(k):
    return '::'.join(k.split('::')[-2:])


class Ra:
    def __init__(self, sites_p, impls_p, summary=None):
        self.decl, self.sites, self.impls, self.markers, self.assoc = {}, [], collections.defaultdict(list), [], {}
        self.summary = summary or {}
        for l in _open(sites_p):
            r = json.loads(l)
            if 'decl' in r:
                self.decl[r['decl']] = r
            else:
                self.sites.append(r)
        if impls_p and os.path.exists(impls_p):
            for l in _open(impls_p):
                r = json.loads(l)
                if 'impl' in r:
                    self.markers.append(r)
                elif 'assoc' in r:
                    self.assoc[(r['tname'], r['self'], r['assoc'])] = r['ty']
                    self.assoc[(r['self'], r['assoc'])] = r['ty']
                else:
                    self.impls[(r['tname'], r['method'])].append(r)

    def trait_cands(self, s):
        """The impl-index candidates for a trait-declaration site, keyed by the TRAIT'S IDENTITY (ra's TraitId, via the
        declaration fn the site names), never by its name: two traits both named `TV` in different modules are
        different traits (measured: cfgtwin r4_unrel2_q, which the name-keyed lookup charged from the OTHER `TV`'s
        effectful default). Falls back to the name key only when the site's declaration is not in the index."""
        m = re.search(r'<dyn ([^>]+)>::(\w+)$', s.get('target', ''))
        if not m:
            return [], None
        cand = self.impls.get((m.group(1), m.group(2)), [])
        tid = s.get('tid')
        tr = next((r.get('trait') for r in cand if r.get('fn') == tid and r['self'] == '<default>'), None)
        if tr:
            cand = [r for r in cand if r.get('trait') == tr]
        return cand, tr

    def default_of(self, tname, meth):
        for r in self.impls.get((tname, meth), []):
            if r['self'] == '<default>' and r.get('has_body'):
                return r
        return None

    def edge(self, s):
        """The site's ra-definite callee as (path, origin, how), or None. A trait declaration counts only when its
        Self is CONCRETE in ra's substitution: then the impl index (or the default body) names the callee."""
        o = s.get('outcome')
        if o in DEFINITE:
            return s['target'], s['origin'], 'definite', s.get('tid')
        if o != 'trait_decl':
            return None
        sub = {n: (d, tp) for n, d, tp in (s.get('subst') or [])}
        st = sub.get('Self')
        if not st or st[1] or st[0].startswith('dyn ') or st[0].startswith('impl '):
            return None
        m = re.search(r'<dyn ([^>]+)>::(\w+)$', s['target'])
        if not m:
            return None
        cand, tr = self.trait_cands(s)
        hit = [r for r in cand if r['self'] == st[0]]
        if len(hit) == 1:
            return hit[0]['path'], s['origin'], 'subst-impl', hit[0]['fn']
        if not hit:
            d = [r for r in cand if r['self'] == '<default>' and r.get('has_body') and (not tr or r.get('fn') == s.get('tid'))]
            if len(d) == 1:
                return d[0]['path'], s['origin'], 'subst-default', d[0]['fn']
        return None


def sink_of(path):
    for e, rx in SINKS:
        if rx.search(path):
            return e
    return None


class Classifier:
    """The SINK ORACLE. With a candor-classify-paths binary (tools/ra-shadow-arm/classify-paths: the PUBLISHED
    candor-classify's classify_all, one `<crate>\t<path>` per line) every std/core/alloc callee ra names is asked of
    candor's own classifier; never a reimplementation (AGENT-CORPUS-BRIEF §G; measured 2026-11-28: a std::process::
    prefix table charged `std::process::abort` as Exec on 53 rows, and the classifier says it is not an effect).
    Without one, the builtin SINKS table is used and every report says so (`sinks=builtin`)."""

    def __init__(self, binp=None):
        self.bin, self.cache = binp, {}
        self.name = 'classifier' if binp else 'builtin'

    @staticmethod
    def spellings(path):
        segs = split_path(path)
        if not segs:
            return []
        plain, trait_form = [], []
        for t in segs:
            if t.startswith('<') and t.endswith('>'):
                inner = t[1:-1]
                if inner.startswith('dyn '):
                    plain.append(re.sub(r'<.*', '', inner[4:]).split(' + ')[0].strip())
                    trait_form.append(plain[-1])
                elif ' as ' in inner:
                    a, b = inner.split(' as ', 1)
                    plain.append(re.sub(r'<.*', '', a.lstrip('&').replace('mut ', '')).strip().split('::')[-1])
                    trait_form.append(re.sub(r'<.*', '', b).strip())
                else:
                    plain.append(re.sub(r'<.*', '', inner.lstrip('&').replace('mut ', '')).strip().split('::')[-1])
                    trait_form.append(plain[-1])
            else:
                plain.append(t)
                trait_form.append(t)
        out = ['::'.join(plain)]
        if trait_form != plain:
            out.append('::'.join(trait_form))
        return out

    def effects(self, path):
        if not self.bin:
            e = sink_of(path)
            return {e} if e else set()
        if path not in self.cache:
            self.ask([path])
        return self.cache[path]

    def ask(self, paths):
        todo = [p for p in set(paths) if p not in self.cache]
        if not todo or not self.bin:
            return
        q = []
        for p in todo:
            for sp in self.spellings(p):
                q.append((p, sp.split('::')[0], sp))
        r = subprocess.run([self.bin], input=''.join(f'{k}\t{sp}\n' for _, k, sp in q), capture_output=True, text=True, check=True)
        res = {}
        for ln in r.stdout.splitlines():
            k, sp, e = ln.split('\t')
            res[sp] = set() if e == '-' else set(e.split('+'))
        for p in todo:
            self.cache[p] = set().union(*(res.get(sp, set()) for sp in self.spellings(p))) - NONCONCRETE


# ------------------------------------------------------------------------------------------------------ candor side
class Cs:
    def __init__(self, report_p, callgraph_p):
        rep = json.load(open(report_p))
        self.package = rep.get('package')
        self.rows = collections.defaultdict(list)
        for f in rep.get('functions', []):
            self.rows[f['fn']].append(f)
        self.cg = json.load(open(callgraph_p))
        self.keys = set(self.cg) | set(self.rows)
        self.by_last2 = collections.defaultdict(set)
        for k in self.keys:
            self.by_last2[last2(k)].add(k)

    def eff(self, k):
        out = set()
        for r in self.rows.get(k, []):
            out |= set(r.get('inferred') or [])
        return out

    def conc(self, k):
        return self.eff(k) - NONCONCRETE

    def state(self, k):
        rs = self.rows.get(k)
        if not rs:
            return '-'
        e = self.eff(k)
        if e - NONCONCRETE:
            return 'E+U' if 'Unknown' in e else 'E'
        if 'Unknown' in e:
            return 'U'
        if any(r.get('invisible') or r.get('dispatchesOn') for r in rs):
            return '[]'
        return '-'

    def why(self, k):
        out = []
        for r in self.rows.get(k, []):
            out += r.get('unknownWhy') or []
        return out

    def resolve(self, key):
        """ra key (or the list cs_keys() gives) -> candor key: exact on any spelling, else the UNIQUE candor key with
        the primary spelling's last two segments ('fuzzy')."""
        keys = key if isinstance(key, list) else [key]
        for k in keys:
            if k in self.keys:
                return k, 'exact'
        c = self.by_last2.get(last2(keys[0]), set())
        if len(c) == 1:
            return next(iter(c)), 'fuzzy'
        return None, ('ambiguous' if c else 'absent')


# ------------------------------------------------------------------------------------------------------------- diff
def deps_check(summary, metadata):
    """D1: ra's loaded dependency crates vs `cargo metadata`'s resolve for the host. metadata None = it failed."""
    if metadata is None:
        return 'metadata-failed', []
    loaded = {n.replace('-', '_') for n, o, _v in summary.get('loaded', []) if o == 'dep'}
    members = set(metadata.get('workspace_members') or [])
    want = set()
    nodes = {n['id']: n for n in (metadata.get('resolve') or {}).get('nodes', [])}
    pkgs = {p['id']: p for p in metadata.get('packages', [])}
    for m in members:
        for d in nodes.get(m, {}).get('deps', []):
            if d['pkg'] in members:
                continue
            kinds = {k.get('kind') for k in d.get('dep_kinds', [])} or {None}
            if kinds <= {'dev'}:
                continue
            p = pkgs.get(d['pkg'])
            if p and not any('proc-macro' in t.get('kind', []) for t in p.get('targets', [])):
                want.add(p['name'].replace('-', '_'))
    # a lib target may be renamed (`[lib] name`): accept either spelling
    for pid, p in pkgs.items():
        for t in p.get('targets', []):
            if 'lib' in t.get('kind', []) or 'rlib' in t.get('kind', []):
                if t['name'].replace('-', '_') in loaded:
                    loaded.add(p['name'].replace('-', '_'))
    miss = sorted(want - loaded)
    return ('full' if not miss else ('none' if not loaded else 'partial')), miss


def diff(ra, cs, metadata=None, with_metadata=False, classifier=None):
    out = {'A': collections.Counter(), 'A_rows': [], 'B_rows': [], 'edges': collections.Counter(), 'det': {}}
    clf = classifier or Classifier()
    out['det']['sinks'] = clf.name
    clf.ask([s['target'] for s in ra.sites if s.get('origin') == 'lang' and s.get('target')])
    # ---- detectors
    if with_metadata:
        out['det']['deps'], out['det']['deps_missing'] = deps_check(ra.summary, metadata)
    bad = []
    for s in ra.sites:
        if not s.get('macro') or not s.get('caller') or s['caller'] == '<inactive>' or not s.get('mline'):
            continue
        d = ra.decl.get(s['caller'])
        if d and d.get('start') and d.get('file') == s.get('file') and not (d['start'] <= s['mline'] <= d['end']):
            bad.append((s['file'], s['mline'], d.get('path'), s.get('target') or s.get('outcome')))
    out['det']['attrib'] = len(bad)
    out['det']['attrib_ex'] = bad[:5]
    cfgbad = [m for m in ra.markers if m.get('cfg_ok') is False]
    out['det']['cfgimpl'] = len(cfgbad)
    out['det']['cfgimpl_ex'] = [(m['impl'], m['self'], m['cfg']) for m in cfgbad[:5]]
    lang = sum(1 for s in ra.sites if s.get('origin') == 'lang')
    callsites = sum(1 for s in ra.sites if s.get('outcome') not in ('inactive', 'ctor', 'unexpanded'))
    out['det']['sysroot'] = 'absent' if (callsites >= 5 and lang == 0) else 'ok'   # calibrated: e10 --no-sysroot has 7
    out['det']['inactive'] = sum(1 for s in ra.sites if s.get('outcome') == 'inactive')
    out['det']['unattributed'] = sum(1 for s in ra.sites if s.get('caller') == '')
    # ---- edges
    caller_key = {}
    for fid, d in ra.decl.items():
        caller_key[fid] = cs.resolve(decl_keys(d))
    # a NESTED fn (a fn item inside another fn's body) has no candor unit: candor folds its body into the enclosing
    # unit, so its calls are compared as the enclosing unit's (measured: bstr `findpos` inside `first_non_ascii_byte_sse2`)
    byfile = collections.defaultdict(list)
    for fid, d in ra.decl.items():
        if d.get('start') and d.get('file'):
            byfile[d['file']].append((d['start'], d['end'], fid))

    def enclosing(fid):
        d = ra.decl.get(fid) or {}
        best = None
        for a, b, g in byfile.get(d.get('file'), ()):
            if g != fid and a <= d.get('start', 0) and d.get('end', 0) <= b and (a, b) != (d.get('start'), d.get('end')):
                if best is None or (b - a) < (best[1] - best[0]):
                    best = (a, b, g)
        return best[2] if best else None
    for fid in list(caller_key):
        if caller_key[fid][0] is None:
            g = enclosing(fid)
            while g and caller_key.get(g, (None,))[0] is None:
                g = enclosing(g)
            if g:
                caller_key[fid] = (caller_key[g][0], 'nested')
    added = collections.defaultdict(set)        # cs caller key -> {('edge', key) | ('sink', E)}
    root = {}                                   # (caller key, item) -> site evidence
    for s in ra.sites:
        e = ra.edge(s)
        if not e:
            out['edges']['no-ra-edge:' + str(s.get('outcome'))] += 1
            continue
        tpath, origin, how, tfid = e
        if s.get('caller') in ('', '<inactive>'):
            out['edges']['unattributed'] += 1
            continue
        ck, cmode = caller_key.get(s['caller'], (None, 'absent'))
        if ck is None:
            # candor-scan's default scope excludes tests/ benches/ examples/ and build scripts (`--include-tests` is
            # off), while ra loads every target: say which, so a large count is read as scope, not as a mapping miss
            f = '/' + (ra.decl.get(s['caller'], {}).get('file') or '')
            kind = next((k for k in ('/tests/', '/benches/', '/examples/', '/build.rs', '/builder/') if k in f), 'src')
            out['edges']['caller-unmapped:' + kind.strip('/')] += 1
            continue
        ev = {'file': s.get('file'), 'line': s.get('line'), 'mline': s.get('mline'), 'text': s.get('text'),
              'target': tpath, 'how': how, 'macro': s.get('macro')}
        if origin == 'lang':
            ses = clf.effects(tpath)
            if ses:
                out['edges']['sink'] += 1
                for se in sorted(ses):
                    if se not in cs.conc(ck):
                        added[ck].add(('sink', se))
                        root.setdefault((ck, ('sink', se)), ev)
            else:
                out['edges']['lang'] += 1
            continue
        if origin == 'dep':
            out['edges']['dep(adds-nothing)'] += 1
            continue
        tk, tmode = (caller_key[tfid] if tfid in caller_key else cs.resolve(cs_keys(tpath)))
        if tk is None:
            out['edges']['callee-unmapped'] += 1
            continue
        if tk == ck:
            out['edges']['self'] += 1
            continue
        cedges = set(cs.cg.get(ck, []))
        if tk in cedges:
            out['A']['AGREE'] += 1
            continue
        alts = sorted(y for y in cedges if leaf(y) == leaf(tk))
        if not alts:
            out['A']['RA-ONLY'] += 1
            added[ck].add(('edge', tk))
            root.setdefault((ck, ('edge', tk)), ev)
            continue
        hedged = any(leaf(tk) in w for w in cs.why(ck))
        ex, ey = cs.conc(tk), set().union(*(cs.conc(y) for y in alts))
        if any(last2(y) == last2(tk) for y in alts):
            cls = 'naming-artefact'
        elif ex - ey:
            cls = 'wrong-target-effectful/sil'
        elif ey - ex:
            cls = 'wrong-target-effectful/fab'
        else:
            cls = 'wrong-target-pure'
        out['A']['DISAGREE' + ('-HEDGED' if hedged else '')] += 1
        out['A'][cls] += 1
        out['A_rows'].append({'caller': ck, 'ra': tk, 'cs': alts, 'class': cls, 'hedged': hedged,
                              'ra_eff': sorted(ex), 'cs_eff': sorted(ey),
                              'gate_visible': sorted(ex - cs.conc(ck)), **ev})
        if cls != 'naming-artefact':
            added[ck].add(('edge', tk))
            root.setdefault((ck, ('edge', tk)), ev)
    # ---- (B) union fixpoint
    graph = collections.defaultdict(set)
    for k, vs in cs.cg.items():
        graph[k] |= set(vs)
    seed = collections.defaultdict(set)
    for ck, items in added.items():
        for kind, v in items:
            if kind == 'edge':
                graph[ck].add(v)
            else:
                seed[ck].add(v)
    nodes = set(graph) | {v for vs in graph.values() for v in vs} | set(seed)
    eff = {k: cs.conc(k) | seed.get(k, set()) for k in nodes}
    rev = collections.defaultdict(set)
    for k, vs in graph.items():
        for v in vs:
            rev[v].add(k)
    work = list(nodes)
    while work:
        v = work.pop()
        for u in rev.get(v, ()):
            if not eff[v] <= eff[u]:
                eff[u] |= eff[v]
                work.append(u)
    for k in sorted(nodes):
        gain = eff[k] - cs.conc(k)
        if not gain or k not in cs.keys:
            continue
        for E in sorted(gain):
            r = _witness(k, E, graph, eff, cs, seed, added, root)
            out['B_rows'].append({'unit': k, 'effect': E, 'cs_state': cs.state(k), 'cs_inferred': sorted(cs.eff(k)),
                                  'root': r})
    return out


def _witness(k, E, graph, eff, cs, seed, added, root):
    """BFS from k over the union graph (nodes that carry E) to the nearest E SOURCE (a candor row that already carries
    E, or a seeded ra sink). Every ADDED item on that path is needed for the charge, so all of them are returned; the
    LAST one is the root to ground-truth first."""
    prev, q = {k: None}, collections.deque([k])
    end = None
    while q:
        u = q.popleft()
        if u != k and E in cs.conc(u) or E in seed.get(u, set()):
            end = u
            break
        for v in sorted(graph.get(u, ())):
            if v not in prev and E in eff.get(v, set()):
                prev[v] = u
                q.append(v)
    if end is None:
        return {'path': [k], 'item': None, 'items': []}
    path = [end]
    while prev[path[-1]] is not None:
        path.append(prev[path[-1]])
    path.reverse()
    items = []
    for u, v in zip(path, path[1:]):
        if ('edge', v) in added.get(u, set()):
            items.append({'item': ['edge', u, v], **root.get((u, ('edge', v)), {})})
    if E in seed.get(end, set()) and E not in cs.conc(end):
        items.append({'item': ['sink', end, E], **root.get((end, ('sink', E)), {})})
    last = items[-1] if items else {}
    return {'path': path, 'items': items, **last}


def render(name, d):
    L = [f'== {name}', 'BOUNDARIES: one host configuration; inactive sites counted not compared; sinks std::fs/env/net/process only.']
    L.append('detectors: ' + ', '.join(f'{k}={v}' for k, v in d['det'].items() if not k.endswith('_ex')))
    L.append('edges: ' + ', '.join(f'{k} {v}' for k, v in sorted(d['edges'].items())))
    L.append('(A): ' + ', '.join(f'{k} {v}' for k, v in sorted(d['A'].items())))
    for r in d['A_rows']:
        if r['class'] != 'naming-artefact':
            L.append(f"  A {r['class']:28} {r['caller']} -> ra {r['ra']} {r['ra_eff']} | cs {r['cs'][:3]} {r['cs_eff']}"
                     f"{' HEDGED' if r['hedged'] else ''} @{os.path.basename(r['file'] or '')}:{r['line']}")
    L.append(f"(B) added (unit, effect): {len(d['B_rows'])}; by cs state: "
             + ', '.join(f'{k} {v}' for k, v in collections.Counter(r['cs_state'] for r in d['B_rows']).most_common()))
    for r in d['B_rows']:
        rt = r['root']
        L.append(f"  B {r['effect']:4} {r['cs_state']:2} {r['unit']}  <= {' -> '.join(rt.get('path', []))}"
                 f"  [{rt.get('item')}] @{os.path.basename(rt.get('file') or '')}:{rt.get('line')} {(rt.get('text') or '')[:60]!r}")
    return '\n'.join(L) + '\n'


# -------------------------------------------------------------------------------------------------------------- run
def _timed(cmd, env=None, cwd=None, timeout=1800):
    t0 = time.time()
    pre = (['/usr/bin/time', '-l'] if sys.platform == 'darwin' else ['/usr/bin/time', '-v']) if os.path.exists('/usr/bin/time') else []
    p = subprocess.run(pre + cmd, capture_output=True, text=True, env=env, cwd=cwd, timeout=timeout)
    rss = 0
    for l in p.stderr.splitlines():
        if 'maximum resident set size' in l:
            rss = int(l.split()[0])
        elif 'Maximum resident set size' in l:
            rss = int(l.split()[-1]) * 1024
    return p, time.time() - t0, rss


def entry_name(e):
    return os.path.basename(e.rstrip('/'))


def _copy_tree(e, tree):
    top = os.path.abspath(e)
    shutil.copytree(e, tree, symlinks=True,
                    ignore=lambda d, names: [n for n in names if n in ('target', '.git') and os.path.abspath(d) == top])


def run_one(e, ra_bin, cs_bin, work, out, online=False, cs_from=None):
    name = entry_name(e)
    od = os.path.join(out, name)
    shutil.rmtree(od, ignore_errors=True)
    os.makedirs(od)
    tree = os.path.join(work, name)
    shutil.rmtree(tree, ignore_errors=True)
    # ignore ONLY the top-level build dir and VCS dir: `ignore_patterns('target')` matches at every depth and
    # hollowed cc's `src/target/` module out of BOTH arms (measured 2026-11-28: 236 vs 244 analysed units)
    _copy_tree(e, tree)
    meta = {'entry': e}
    try:
        sites, impls = os.path.join(od, 'ra.sites.jsonl'), os.path.join(od, 'ra.impls.jsonl')
        p, w, rss = _timed([ra_bin, tree, '--sites', sites, '--impls', impls] + ([] if online else ['--offline']))
        summ = next((json.loads(l) for l in p.stdout.splitlines() if l.startswith('{')), None)
        meta.update(ra_rc=p.returncode, ra_wall=round(w, 1), ra_rss_mb=round(rss / 1e6))
        if summ is None:
            meta['ra_err'] = '\n'.join(p.stderr.strip().splitlines()[-5:])[:600]
        else:
            json.dump(summ, open(os.path.join(od, 'ra.summary.json'), 'w'))
        md = subprocess.run(['cargo', 'metadata', '--format-version', '1'] + ([] if online else ['--offline'])
                            + ['--filter-platform', _host()], cwd=tree, capture_output=True, text=True, timeout=600)
        if md.returncode == 0:
            open(os.path.join(od, 'metadata.json'), 'w').write(md.stdout)
        else:
            meta['metadata_err'] = md.stderr.strip().splitlines()[-1:] if md.stderr else ['?']
        if cs_from:      # the candor-scan arm of ANOTHER run (a host where the cs binary runs; cs is syntactic)
            src = os.path.join(cs_from, name)
            for f in os.listdir(src) if os.path.isdir(src) else []:
                if f.startswith('cs.'):
                    shutil.copy(os.path.join(src, f), od)
            meta.update(cs_from=src)
        else:
            cache = os.path.join(work, name + '.cache')
            env = dict(os.environ, CANDOR_CACHE_DIR=cache)
            env.pop('CANDOR_DEPS', None)
            p2, w2, rss2 = _timed([cs_bin, tree, '--out', os.path.join(od, 'cs')], env=env)
            shutil.rmtree(cache, ignore_errors=True)
            meta.update(cs_rc=p2.returncode, cs_wall=round(w2, 1), cs_rss_mb=round(rss2 / 1e6))
        for f in (sites, impls):
            if os.path.exists(f):
                subprocess.run(['gzip', '-f', f])
    finally:
        shutil.rmtree(tree, ignore_errors=True)
    json.dump(meta, open(os.path.join(od, 'meta.json'), 'w'), indent=1)
    return diff_dir(od)


_HOST = None
_CLF = Classifier(os.environ.get('RA_SHADOW_CLASSIFY') or None)


def _host():
    global _HOST
    if _HOST is None:
        v = subprocess.run(['rustc', '-vV'], capture_output=True, text=True).stdout
        _HOST = next((l.split()[1] for l in v.splitlines() if l.startswith('host:')), 'unknown')
    return _HOST


def _cs_files(od):
    reps = sorted(f for f in os.listdir(od) if f.startswith('cs.') and f.endswith('.scan.json'))
    return [(os.path.join(od, f), os.path.join(od, f[:-len('.json')] + '.callgraph.json')) for f in reps]


def diff_dir(od):
    meta = json.load(open(os.path.join(od, 'meta.json')))
    sp = os.path.join(od, 'ra.sites.jsonl.gz')
    if not os.path.exists(sp):
        sp = sp[:-3]
    if not os.path.exists(sp) or not os.path.exists(os.path.join(od, 'ra.summary.json')):
        meta['verdict'] = 'NOT-A-MEASUREMENT: ra arm failed'
        json.dump(meta, open(os.path.join(od, 'meta.json'), 'w'), indent=1)
        return 3
    reps = [(r, c) for r, c in _cs_files(od) if os.path.exists(c)]
    if not reps:
        meta['verdict'] = 'NOT-A-MEASUREMENT: no candor-scan report+sidecar'
        json.dump(meta, open(os.path.join(od, 'meta.json'), 'w'), indent=1)
        return 3
    ip = sp.replace('ra.sites', 'ra.impls')
    summ = json.load(open(os.path.join(od, 'ra.summary.json')))
    ra = Ra(sp, ip, summ)
    mdp = os.path.join(od, 'metadata.json')
    md = json.load(open(mdp)) if os.path.exists(mdp) else None
    res = {}
    txt = ''
    for rp, cp in reps:          # a workspace: one report per member; every member diffs against the same ra arm
        cs = Cs(rp, cp)
        d = diff(ra, cs, md, with_metadata=True, classifier=_CLF)
        res[cs.package] = d
        txt += render(f"{os.path.basename(od)} [{cs.package}]", d)
    json.dump({'meta': meta, 'packages': res}, open(os.path.join(od, 'diff.json'), 'w'), default=list)
    open(os.path.join(od, 'diff.txt'), 'w').write(txt)
    meta['verdict'] = 'measured'
    json.dump(meta, open(os.path.join(od, 'meta.json'), 'w'), indent=1)
    return 0


def summary(out):
    tot = collections.Counter()
    det = collections.Counter()
    brows, arows, ents = [], [], []
    for name in sorted(os.listdir(out)):
        p = os.path.join(out, name, 'diff.json')
        if not os.path.exists(p):
            if os.path.exists(os.path.join(out, name, 'meta.json')):
                ents.append((name, json.load(open(os.path.join(out, name, 'meta.json'))).get('verdict', '?')))
            continue
        d = json.load(open(p))
        ents.append((name, 'measured'))
        for pkg, x in d['packages'].items():
            for k, v in x['A'].items():
                tot['A.' + k] += v
            for k, v in x['edges'].items():
                tot['edges.' + k] += v
            dt = x['det']
            det['deps=' + str(dt.get('deps'))] += 1
            det['attrib>0'] += dt.get('attrib', 0) > 0
            det['cfgimpl>0'] += dt.get('cfgimpl', 0) > 0
            det['sysroot=' + dt.get('sysroot', '?')] += 1
            tot['inactive'] += dt.get('inactive', 0)
            tot['unattributed'] += dt.get('unattributed', 0)
            tag = [] if dt.get('deps') == 'full' else ['deps:' + str(dt.get('deps'))]
            for r in x['B_rows']:
                brows.append((name, pkg, tag, r))
            for r in x['A_rows']:
                arows.append((name, pkg, r))
    L = [f"entries: {len(ents)} ({sum(1 for _, v in ents if v == 'measured')} measured)"]
    L += [f'  NOT MEASURED {n}: {v}' for n, v in ents if v != 'measured']
    L.append('detectors (per package): ' + ', '.join(f'{k} {v}' for k, v in sorted(det.items())))
    L.append('totals: ' + ', '.join(f'{k} {v}' for k, v in sorted(tot.items())))
    L.append(f'(A) DISAGREE rows: {len(arows)} by class: '
             + ', '.join(f'{k} {v}' for k, v in collections.Counter(r['class'] for _, _, r in arows).most_common()))
    L.append(f'(B) added (unit,effect): {len(brows)}; entries {len({b[0] for b in brows})}; by cs state: '
             + ', '.join(f'{k} {v}' for k, v in collections.Counter(r['cs_state'] for *_, r in brows).most_common())
             + '; by effect: ' + ', '.join(f'{k} {v}' for k, v in collections.Counter(r['effect'] for *_, r in brows).most_common()))
    roots = collections.Counter()
    for n, pkg, tag, r in brows:
        rt = r['root']
        roots[(n, rt.get('file'), rt.get('line'), str(rt.get('item')))] += 1
    L.append(f'(B) distinct root ra edges: {len(roots)}')
    open(os.path.join(out, 'SUMMARY.txt'), 'w').write('\n'.join(L) + '\n')
    print('\n'.join(L))
    return 0


# ------------------------------------------------------------------------------------------------------------- gate
def gate(od, cs_bin, tree):
    """(B)'s gate check on the REAL crate: one policy holding `deny <E> <unit>` for every ADDED (unit, E), plus up to
    five CALIBRATION lines (`deny <E> <unit>` for units candor-scan already charges with E). A calibration line must come
    back as a violation (else exit 2: the gate was not shown able to fire on this tree). Each ADDED line is then read
    as: `violation today` (not a flip: the report already carries it), `zeroMatch` (the gate cannot see that unit at all,
    e.g. a build-script unit: not a flip either, and said so), or `flip` (exit 0 today, 1 under the union)."""
    d = json.load(open(os.path.join(od, 'diff.json')))
    want = set()
    calib = []
    for pkg, x in d['packages'].items():
        for r in x['B_rows']:
            want.add((r['effect'], r['unit']))
    effs = {e for e, _ in want}
    for rp, cp in _cs_files(od):
        cs = Cs(rp, cp)
        own = [k for k in sorted(cs.rows) if any((r.get('hash') or '').startswith(f'{cs.package}#') for r in cs.rows[k])]
        for k in own:          # the package's OWN units: an interfaceUnion row hashed to a dependency is not gate-scoped
            hit = sorted(cs.conc(k) & effs) or sorted(cs.conc(k))
            if hit and not any(k.startswith(p) for p in ('builder::', 'build_script')) and len(calib) < 5:
                calib.append((hit[0], k))
    if not want:
        print('gate: no ADDED rows')
        return 0
    if not calib:
        print('gate: NO CALIBRATION UNIT (no candor-scan row carries a concrete effect): cannot show the gate can fire')
        return 2
    td = tempfile.mkdtemp(prefix='rashadow-gate-')
    try:
        pol = os.path.join(td, 'pol')
        open(pol, 'w').write(''.join(f'deny {e} {u}\n' for e, u in sorted(want | set(calib))))
        env = dict(os.environ, CANDOR_CACHE_DIR=os.path.join(td, 'c'))
        env.pop('CANDOR_DEPS', None)
        p = subprocess.run([cs_bin, tree, '--policy', pol, '--gate-json', os.path.join(td, 'g.json'),
                            '--out', os.path.join(td, 'r')], env=env, capture_output=True, text=True)
        g = json.load(open(os.path.join(td, 'g.json')))
        viol = {(e, v.get('fn')) for v in g.get('violations', []) for e in v.get('effects', [])}
        zero = set(g.get('zeroMatch', []))
        cal_ok = [c for c in calib if c in viol]
        res = {'flip': [], 'violation-today': [], 'zeroMatch': []}
        for e, u in sorted(want):
            k = 'violation-today' if (e, u) in viol else 'zeroMatch' if f'deny {e} {u}' in zero else 'flip'
            res[k].append([e, u])
        print(f'gate: exit {p.returncode}; calibration {len(cal_ok)}/{len(calib)} fired; ADDED {len(want)}: '
              + ', '.join(f'{k} {len(v)}' for k, v in res.items()))
        json.dump({'rc': p.returncode, 'calib': calib, 'calib_fired': cal_ok, **res}, open(os.path.join(od, 'gate.json'), 'w'))
        return 0 if cal_ok else 2
    finally:
        shutil.rmtree(td, ignore_errors=True)


# ------------------------------------------------------------------------------------------------------------ reach
def reach(sites_p, impls_p, probe, no_subst=False, trace=False):
    ra = Ra(sites_p, impls_p)
    out = collections.defaultdict(list)
    for s in ra.sites:
        out[s.get('caller')].append(s)
    starts = [f for f, d in ra.decl.items() if d['path'].endswith('::' + probe) or d['path'] == probe]
    if not starts:
        return 'NOPROBE', set(), ''
    eff, mode, tr = set(), 'exact', ''
    seen = set()
    stack = [(s, (), [ra.decl[s]['path']]) for s in starts]
    path_fid = {}
    for f, d in ra.decl.items():
        path_fid.setdefault(d['path'], f)
    while stack:
        fn, env, path = stack.pop()
        if (fn, env) in seen or len(path) > 40:
            continue
        seen.add((fn, env))
        envd = dict(env)
        for s in out.get(fn, []):
            if s['outcome'] in ('unexpanded', 'unresolved'):
                eff.add('Unknown')
                continue
            if s['outcome'] in ('inactive', 'ctor', 'closure', 'fnptr', 'fn_trait', 'macro'):
                continue
            tgt = s['target']
            e = sink_of(tgt)
            if e:
                if e not in eff and trace:
                    tr = ' -> '.join(path + [tgt])
                eff.add(e)
            subst, unres = {}, set()
            for n, disp, tp in ([] if no_subst else (s.get('subst') or [])):
                if tp and tp not in envd:
                    unres.add(n)
                subst[n] = envd.get(tp, disp) if tp else disp
            nxt = []
            if s['outcome'] == 'trait_decl':
                m = re.search(r'<dyn ([^>]+)>::(\w+)$', tgt)
                cand, _tr = ra.trait_cands(s)
                selfty = subst.get('Self')
                selfty, still = _normalize(selfty, envd, ra)
                if still:
                    unres.add('Self')
                if selfty is None or 'Self' in unres or selfty.startswith('dyn '):
                    mode = 'cha'
                    nxt += [(r['fn'], ()) for r in cand]
                else:
                    hit = [r for r in cand if r['self'] == selfty]
                    if hit:
                        nxt += [(r['fn'], ()) for r in hit]
                    else:
                        dft = [r for r in cand if r['self'] == '<default>' and (not _tr or r.get('fn') == s.get('tid'))]
                        if dft:
                            nxt += [(r['fn'], (('Self', selfty),)) for r in dft]
                        else:
                            mode = 'cha'
                            nxt += [(r['fn'], ()) for r in cand]
            else:
                nxt.append((s['tid'], tuple(sorted((k, v) for k, v in subst.items() if k != 'Self'))))
            for f, e2 in nxt:
                stack.append((f, e2, path + [ra.decl.get(f, {}).get('path', f)]))
    return ('REACH' if eff else 'NOREACH'), eff, mode + ('\n    ' + tr if tr else '')


_PROJ = re.compile(r'^(?:<(\w+) as (\w+)(?:<.*>)?>|(\w+))::(\w+)$')


def _normalize(t, envd, ra):
    m = _PROJ.match(t or '')
    if not m:
        return t, False
    base, tr, assoc = m.group(1) or m.group(3), m.group(2), m.group(4)
    conc = envd.get(base)
    if conc is None:
        return t, True
    v = ra.assoc.get((tr, conc, assoc)) if tr else ra.assoc.get((conc, assoc))
    return (v, False) if v else (t, True)


# ------------------------------------------------------------------------------------------------------------- scip
def _varint(b, i):
    r = sh = 0
    while True:
        x = b[i]
        i += 1
        r |= (x & 0x7f) << sh
        sh += 7
        if x < 0x80:
            return r, i


def _pb(b):
    i = 0
    while i < len(b):
        k, i = _varint(b, i)
        f, t = k >> 3, k & 7
        if t == 0:
            v, i = _varint(b, i)
        elif t == 2:
            n, i = _varint(b, i)
            v = b[i:i + n]
            i += n
        elif t == 1:
            v, i = b[i:i + 8], i + 8
        elif t == 5:
            v, i = b[i:i + 4], i + 4
        else:
            raise ValueError(f'protobuf wire type {t}')
        yield f, t, v


def _packed(v, t):
    if t != 2:
        return [v]
    out, i = [], 0
    while i < len(v):
        x, i = _varint(v, i)
        out.append(x)
    return out


def scip_load(p):
    """scip.proto: Index.documents=2; Document.relative_path=1, occurrences=2; Occurrence.range=1 (packed),
    symbol=2, symbol_roles=3 (bit 0 = Definition), enclosing_range=7."""
    docs = []
    for f, t, v in _pb(open(p, 'rb').read()):
        if f != 2:
            continue
        d = {'path': '', 'occ': []}
        for f2, t2, v2 in _pb(v):
            if f2 == 1:
                d['path'] = v2.decode()
            elif f2 == 2:
                o = {'range': [], 'sym': '', 'roles': 0, 'enc': []}
                for f3, t3, v3 in _pb(v2):
                    if f3 == 1:
                        o['range'] = _packed(v3, t3)
                    elif f3 == 2:
                        o['sym'] = v3.decode()
                    elif f3 == 3:
                        o['roles'] = v3
                    elif f3 == 7:
                        o['enc'] = _packed(v3, t3)
                d['occ'].append(o)
        docs.append(d)
    return docs


def _span(r):
    """SCIP range: [line, startcol, endcol] (one line) or [startline, startcol, endline, endcol]."""
    if len(r) == 3:
        return (r[0], r[1]), (r[0], r[2])
    if len(r) == 4:
        return (r[0], r[1]), (r[2], r[3])
    return None


SCIP_SINK = re.compile(r' std \S+ (fs|env|net|process)/')


def scip_reach(p, probe, trace=False):
    docs = scip_load(p)
    defs, edges, macro_body = [], collections.defaultdict(list), 0
    for d in docs:
        dd = []
        for o in d['occ']:
            if o['roles'] & 1 and o['sym'].endswith(').') and o['enc']:
                sp = _span(o['enc'])
                if sp:
                    dd.append((sp, o['sym']))
            if o['roles'] & 1 and o['sym'].endswith('!') and o['enc']:
                sp = _span(o['enc'])
                if sp:
                    dd.append((sp, '#macro#' + o['sym']))
        defs += [s for _, s in dd]
        for o in d['occ']:
            if o['roles'] & 1 or not o['sym'].endswith(').'):
                continue
            pos = (o['range'][0], o['range'][1])
            inner = [(sp, s) for sp, s in dd if sp[0] <= pos <= sp[1]]
            if not inner:
                continue
            sp, s = max(inner, key=lambda x: x[0][0])      # innermost = latest start
            if s.startswith('#macro#'):
                macro_body += 1
                continue
            edges[s].append(o['sym'])
    impls = collections.defaultdict(list)
    for s in defs:
        m = re.search(r'impl#\[[^\]]*\]\[`?([A-Za-z_][A-Za-z0-9_]*)[^\]]*\]([A-Za-z0-9_]+)\(\)\.$', s)
        if m:
            impls[(m.group(1), m.group(2))].append(s)
    starts = [s for s in defs if re.search(r'[/ ]' + re.escape(probe) + r'\(\)\.$', s)]
    if not starts:
        return 'NOPROBE', set(), ''
    eff, seen, stack, mode, tr = set(), set(), [(s, [s]) for s in starts], 'exact', ''
    while stack:
        fn, path = stack.pop()
        if fn in seen:
            continue
        seen.add(fn)
        for t in edges.get(fn, []):
            m = SCIP_SINK.search(t)
            if m:
                e = {'fs': 'Fs', 'env': 'Env', 'net': 'Net', 'process': 'Exec'}[m.group(1)]
                if e not in eff and trace:
                    tr = ' -> '.join(path + [t])
                eff.add(e)
                continue
            m = re.search(r'([A-Za-z_][A-Za-z0-9_]*)#([A-Za-z0-9_]+)\(\)\.$', t)
            nxt = [t]
            if m and 'impl#' not in t:
                cand = impls.get((m.group(1), m.group(2)), [])
                if cand:
                    mode = 'cha'
                    nxt += cand
            for n in nxt:
                stack.append((n, path + [n]))
    return ('REACH' if eff else 'NOREACH'), eff, f'{mode} macro-body-refs={macro_body}' + ('\n    ' + tr if tr else '')


# ---------------------------------------------------------------------------------------------------------- fixture
def token(row):
    """cfgtwin run.py reading(): `-` absent/empty, `E`, `U`, `E+U`, `[]{inv=..;key=..}` (a disclosure, NOT a `-`)."""
    if row is None:
        return '-'
    inf = row.get('inferred') or []
    unk, conc = 'Unknown' in inf, [e for e in inf if e != 'Unknown']
    inv, key = row.get('invisible') or [], row.get('dispatchesOn') or []
    t = 'E+U' if conc and unk else 'E' if conc else 'U' if unk else ('[]' if (inv or key) else '-')
    if conc:
        t += ':' + '+'.join(sorted(conc))
    if t == '[]':
        t += '{' + ';'.join((['inv=' + ','.join(inv)] if inv else []) + (['key=' + ','.join(key)] if key else [])) + '}'
    return t


def _probe_row(report, probe):
    rows = [f for f in json.load(open(report)).get('functions', []) if f['fn'] == probe or f['fn'].endswith('::' + probe)]
    if not rows:
        return None
    m = {}
    for f in rows:
        for k, v in f.items():
            if isinstance(v, list):
                m[k] = sorted(set(m.get(k, [])) | set(v))
            else:
                m.setdefault(k, v)
    return m


def fixture(d, probes, ra_bin, cs_bin, tdir, work=None):
    d = os.path.abspath(d)
    work = work or tempfile.mkdtemp(prefix='rashadow-fx-')
    os.makedirs(work, exist_ok=True)
    md = subprocess.run(['cargo', 'metadata', '--format-version', '1', '--offline'], cwd=d, capture_output=True, text=True)
    if md.returncode:
        print(f'fixture: cargo metadata failed: {md.stderr.strip()[-300:]}', file=sys.stderr)
        return 3
    m = json.loads(md.stdout)
    root_id = (m.get('resolve') or {}).get('root') or m['workspace_members'][0]
    pk = {p['id']: p for p in m['packages']}
    nodes = {n['id']: n for n in m['resolve']['nodes']}
    local = {i for i, p in pk.items() if p.get('source') is None and i != root_id}
    order, seen = [], set()

    def visit(i):
        if i in seen:
            return
        seen.add(i)
        for dd in nodes.get(i, {}).get('deps', []):
            if dd['pkg'] in local:
                visit(dd['pkg'])
        if i in local:
            order.append(i)
    visit(root_id)
    dep_reps = []
    for i in order:
        p = pk[i]
        pre = os.path.join(work, 'dep.' + p['name'])
        env = dict(os.environ, CANDOR_CACHE_DIR=os.path.join(work, 'c'), CANDOR_DEPS=os.pathsep.join(dep_reps))
        subprocess.run([cs_bin, os.path.dirname(p['manifest_path']), '--out', pre], env=env, capture_output=True)
        shutil.rmtree(os.path.join(work, 'c'), ignore_errors=True)
        dep_reps += sorted(os.path.join(work, f) for f in os.listdir(work)
                           if f.startswith('dep.' + p['name'] + '.') and f.endswith('.scan.json'))
    rootname = pk[root_id]['name']
    arms = {}
    for arm, deps in (('solo', []), ('chain', dep_reps)):
        pre = os.path.join(work, arm)
        env = dict(os.environ, CANDOR_CACHE_DIR=os.path.join(work, 'c'), CANDOR_DEPS=os.pathsep.join(deps))
        subprocess.run([cs_bin, d, '--out', pre], env=env, capture_output=True)
        shutil.rmtree(os.path.join(work, 'c'), ignore_errors=True)
        rep = next((os.path.join(work, f) for f in sorted(os.listdir(work))
                    if f.startswith(arm + '.') and f.endswith('.scan.json')), None)
        arms[arm] = (rep, env)
    sites, impls = os.path.join(work, 'ra.sites.jsonl'), os.path.join(work, 'ra.impls.jsonl')
    rp = subprocess.run([ra_bin, d, '--sites', sites, '--impls', impls, '--offline'], capture_output=True, text=True)
    ra_ok = rp.returncode == 0 and os.path.exists(sites)
    for probe in probes:
        mark = os.path.join(work, 'MARK.' + probe)
        if os.path.exists(mark):
            os.remove(mark)
        ex = subprocess.run(['cargo', 'run', '-q', '--offline', '--', probe], cwd=d, capture_output=True, text=True,
                            env=dict(os.environ, MARK=mark, CARGO_TARGET_DIR=tdir))
        if ex.returncode and 'error[' in ex.stderr:
            exe = 'NOCOMPILE'
        else:
            exe = 'Fs' if os.path.exists(mark) else ('none' if ex.returncode == 0 else f'none(rc{ex.returncode})')
        cols = [probe, exe]
        for arm in ('solo', 'chain'):
            rep, env = arms[arm]
            tok = token(_probe_row(rep, probe)) if rep else 'NOREPORT'
            g = ''
            for e in ('Unknown', 'Fs'):
                pol = os.path.join(work, 'pol')
                open(pol, 'w').write(f'deny {e} {probe}\n')
                r = subprocess.run([cs_bin, d, '--policy', pol, '--out', os.path.join(work, 'g')], env=env, capture_output=True)
                shutil.rmtree(os.path.join(work, 'c'), ignore_errors=True)
                g += e[0] + str(r.returncode)
            cols += [tok, g]
        for ns in (False, True):
            if ra_ok:
                st, eff, _ = reach(sites, impls, probe, no_subst=ns)
                cols.append(','.join(sorted(eff)) if st == 'REACH' else st)
            else:
                cols.append('RAFAIL')
        print('\t'.join(cols), flush=True)
    return 0


# --------------------------------------------------------------------------------------------------------- selftest
def _selftest():
    td = tempfile.mkdtemp(prefix='rashadow-selftest-')
    fails = []

    def ok(c, msg):
        print(('ok   ' if c else 'FAIL ') + msg)
        if not c:
            fails.append(msg)
    try:
        F = '/x/src/lib.rs'

        def site(caller, target, origin='local', outcome='free', line=10, macro=False, mline=0, subst=None):
            return {'file': F, 'line': line, 'form': 'call', 'macro': macro, 'outcome': outcome, 'target': target,
                    'origin': origin, 'text': target, 'caller': caller, 'tid': 't:' + target, 'subst': subst, 'mline': mline}
        decls = [{'decl': 'c1', 'path': 'k::m::caller1', 'file': F, 'start': 1, 'end': 20, 'macro': False},
                 {'decl': 'c2', 'path': 'k::m::caller2', 'file': F, 'start': 21, 'end': 30, 'macro': False},
                 {'decl': 'c3', 'path': 'k::m::<S as Tr>::go', 'file': F, 'start': 31, 'end': 40, 'macro': False},
                 {'decl': 'c4', 'path': 'k::m::caller4', 'file': F, 'start': 41, 'end': 45, 'macro': False},
                 {'decl': 'c5', 'path': 'k::m::top', 'file': F, 'start': 46, 'end': 50, 'macro': False}]
        sites = [
            site('c1', 'k::m::<Loud>::write'),                     # cs bound caller1.write to Quiet::write: silence
            site('c2', 'k::m::<Quiet>::write2'),                   # cs bound caller2.write2 to Loud::write2: fabrication
            site('c4', 'k::m::helper'),                            # cs has no edge at all: RA-ONLY
            site('c4', 'std::fs::<File>::create', origin='lang'),  # direct sink cs lacks
            site('c5', 'k::m::caller4'),                           # top -> caller4 (cs edge): the gain propagates up
            site('c1', 'k::m::<S as Tr>::go', outcome='trait_impl'),  # AGREE
            site('c1', 'k::m::other::<P>::name'),                  # cs spells it P::name via a re-export: artefact
            site('c2', 'dep::thing', origin='dep'),                # outside the scan: adds nothing
            # D2 seed: a macro site at mline 99 charged to caller2 (lines 21-30): the e10 shape
            site('c2', 'std::env::var', origin='lang', macro=True, mline=99),
        ]
        sp, ip = os.path.join(td, 's.jsonl'), os.path.join(td, 'i.jsonl')
        open(sp, 'w').write(''.join(json.dumps(r) + '\n' for r in decls + sites))
        open(ip, 'w').write(json.dumps({'impl': 'Tr', 'self': 'W', 'cfg': 'not(unix)', 'cfg_ok': False,
                                        'impl_in_macro': True, 'nitems': 1}) + '\n')
        rep = {'package': 'k', 'functions': [
            {'fn': 'm::Loud::write', 'inferred': ['Fs']}, {'fn': 'm::Loud::write2', 'inferred': ['Fs']},
            {'fn': 'm::helper', 'inferred': ['Net']}, {'fn': 'm::caller2', 'inferred': ['Fs']},
            {'fn': 'm::top', 'inferred': [], 'invisible': ['dep']}]}
        cg = {'m::caller1': ['m::Quiet::write', 'm::S::go', 'P::name'], 'm::caller2': ['m::Loud::write2'],
              'm::caller4': [], 'm::top': ['m::caller4'], 'm::S::go': [], 'm::Quiet::write': [], 'm::Loud::write': [],
              'm::Quiet::write2': [], 'm::Loud::write2': [], 'm::helper': [], 'm::other::P::name': [], 'P::name': []}
        rp, cp = os.path.join(td, 'r.json'), os.path.join(td, 'r.callgraph.json')
        json.dump(rep, open(rp, 'w'))
        json.dump(cg, open(cp, 'w'))
        summ_full = {'loaded': [['k', 'local', '0.1'], ['dep', 'dep', '1.0']]}
        md = {'workspace_members': ['k 0.1'], 'packages': [
            {'id': 'k 0.1', 'name': 'k', 'targets': [{'kind': ['lib'], 'name': 'k'}]},
            {'id': 'dep 1.0', 'name': 'dep', 'targets': [{'kind': ['lib'], 'name': 'dep'}]}],
            'resolve': {'nodes': [{'id': 'k 0.1', 'deps': [{'pkg': 'dep 1.0', 'dep_kinds': [{'kind': None}]}]}]}}
        d = diff(Ra(sp, ip, summ_full), Cs(rp, cp), md, with_metadata=True)
        cls = collections.Counter(r['class'] for r in d['A_rows'])
        ok(cls['wrong-target-effectful/sil'] == 1, '(A) seeded silence-direction mis-binding fires (caller1: Loud vs Quiet)')
        ok(cls['wrong-target-effectful/fab'] == 1, '(A) seeded fabrication-direction mis-binding fires (caller2)')
        ok(d['A']['AGREE'] == 2, '(A) AGREE on the seeded agreeing trait-impl edge and the top -> caller4 edge')
        ok(cls['naming-artefact'] == 1 and not any(r['root'].get('target', '').endswith('name') for r in d['B_rows']),
           '(A) a re-export spelling is a naming-artefact and adds nothing to (B)')
        ok(d['edges']['dep(adds-nothing)'] == 1, '(B) a dependency edge adds nothing (counted only)')
        B = {(r['unit'], r['effect']): r for r in d['B_rows']}
        ok(('m::caller1', 'Fs') in B and B[('m::caller1', 'Fs')]['cs_state'] == '-', '(B) silence mis-binding -> caller1 gains Fs (state -)')
        ok(('m::caller4', 'Net') in B and ('m::caller4', 'Fs') in B, '(B) RA-ONLY edge + direct sink -> caller4 gains Net and Fs')
        ok(('m::top', 'Net') in B and B[('m::top', 'Net')]['cs_state'] == '[]', '(B) the gain propagates to a caller through a candor edge, state []')
        ok(B[('m::top', 'Net')]['root'].get('item') == ['edge', 'm::caller4', 'm::helper'], '(B) the witness names the ROOT ra edge (caller4 -> helper)')
        ok(('m::caller2', 'Fs') not in B, '(B) a unit already carrying the effect gains nothing')
        ok(d['det']['attrib'] == 1, 'D2 seeded misattributed macro site (mline outside the caller) fires')
        ok(d['det']['cfgimpl'] == 1, 'D3 seeded cfg-false impl in the index fires')
        ok(d['det']['deps'] == 'full', 'D1 a full load reads full')
        d2 = diff(Ra(sp, ip, {'loaded': [['k', 'local', '0.1']]}), Cs(rp, cp), md, with_metadata=True)
        ok(d2['det']['deps'] == 'none' and d2['det']['deps_missing'] == ['dep'], 'D1 seeded without-deps load fires (missing dep)')
        d3 = diff(Ra(sp, ip, summ_full), Cs(rp, cp), None, with_metadata=True)
        ok(d3['det']['deps'] == 'metadata-failed', 'D1 a failed cargo metadata is reported, not read as full')
        # D4: no lang edges at all over >= 20 sites
        sp4 = os.path.join(td, 's4.jsonl')
        open(sp4, 'w').write(''.join(json.dumps(r) + '\n' for r in decls + [site('c1', 'k::m::helper')] * 20))
        ok(diff(Ra(sp4, None, summ_full), Cs(rp, cp))['det']['sysroot'] == 'absent', 'D4 seeded no-sysroot load fires')
        ok(d['det']['sysroot'] == 'ok', 'D4 silent on a load with std edges')
        # the sink oracle: a classifier that says std::fs::<File>::create is NOT an effect must win over the table
        fake = os.path.join(td, 'clf.py')
        open(fake, 'w').write('#!/usr/bin/env python3\nimport sys\nfor l in sys.stdin:\n    k, p = l.rstrip("\\n").split("\\t")\n'
                              '    print(k, p, "Net" if p.endswith("env::var") else "-", sep="\\t")\n')
        os.chmod(fake, 0o755)
        dc = diff(Ra(sp, ip, summ_full), Cs(rp, cp), md, with_metadata=True, classifier=Classifier(fake))
        Bc = {(r['unit'], r['effect']) for r in dc['B_rows']}
        ok(dc['det']['sinks'] == 'classifier' and ('m::caller4', 'Fs') not in Bc and ('m::caller2', 'Net') in Bc,
           'sinks: the classifier oracle overrides the builtin table (File::create not an effect; env::var -> Net)')
        ok(d['det']['sinks'] == 'builtin', 'sinks: a run without the oracle says builtin')
        # the working copy keeps a NESTED `target/` module and drops only the top-level build dir
        src = os.path.join(td, 'tree')
        for sub in ('src/target', 'target/debug', '.git'):
            os.makedirs(os.path.join(src, sub))
        open(os.path.join(src, 'src/target/mod.rs'), 'w').write('pub fn f() {}')
        _copy_tree(src, os.path.join(td, 'copy'))
        ok(os.path.exists(os.path.join(td, 'copy/src/target/mod.rs')) and not os.path.exists(os.path.join(td, 'copy/target'))
           and not os.path.exists(os.path.join(td, 'copy/.git')), 'copy: a nested src/target/ module survives; top-level target/ and .git do not')
        # a nested fn (no candor unit) is compared as its enclosing unit
        spn = os.path.join(td, 'sn.jsonl')
        open(spn, 'w').write(''.join(json.dumps(r) + '\n' for r in decls + [
            {'decl': 'c6', 'path': 'k::m::inner', 'file': F, 'start': 3, 'end': 5, 'macro': False},
            site('c6', 'k::m::<S as Tr>::go', outcome='trait_impl')]))
        dn = diff(Ra(spn, None, summ_full), Cs(rp, cp))
        ok(dn['A']['AGREE'] == 1 and not dn['edges']['caller-unmapped'], 'map: a nested fn site is compared as the enclosing unit')
        # the mapping
        ok(cs_key('k::m::<Foo<T, U> as Tr<X>>::go') == 'm::Foo::go', 'map: <Foo<T,U> as Tr<X>>::go -> m::Foo::go')
        ok(cs_key('k::<dyn Tr>::go') == 'Tr::go', 'map: trait default <dyn Tr>::go -> Tr::go')
        ok(cs_key('k::f') == 'f', 'map: a crate-root fn')
        ok('pool::fetch' in cs_keys('k::pool::<&Pool<DB> as Executor>::fetch'), 'map: an impl on &T has the type-less spelling')
        ok('m::Y::r#yield' in cs_keys('k::m::<Y<T>>::yield'), 'map: a raw identifier spelling')
        ok('t::NonZeroI16::decode' in decl_keys({'path': 'k::t::<NonZero<i16> as Decode>::decode', 'self_src': 'NonZeroI16'}),
           'map: the self type as written beats ra canonical display')
        ok(decl_keys({'path': 'k::soft::fx::ks', 'file': '/c/src/soft/fx64.rs'})[0] == 'soft::fx64::ks',
           'map: a #[path] module keys by its file stem, before the mod-name placeholder')
        ok('fr::from_row' in decl_keys({'path': 'k::fr::<(T1, T2) as FromRow>::from_row', 'self_src': '(T1, T2)'}),
           'map: a tuple self type has the type-less spelling')
        # reach, with and without substitution
        rs = [{'decl': 'p', 'path': 'k::probe_e'}, {'decl': 'g', 'path': 'k::via'},
              {'decl': 'lf', 'path': 'k::<Loud as Tr>::go'}, {'decl': 'qf', 'path': 'k::<Quiet as Tr>::go'},
              {'decl': 'df', 'path': 'k::<dyn Tr>::go'}, {'decl': 'q', 'path': 'k::probe_q'},
              dict(site('p', 'k::via', subst=[['T', 'Quiet', None]]), tid='g'),
              dict(site('q', 'k::via', subst=[['T', 'Quiet', None]]), tid='g'),
              dict(site('p', 'k::via', subst=[['T', 'Loud', None]]), tid='g'),
              dict(site('g', 'k::<dyn Tr>::go', outcome='trait_decl', subst=[['Self', 'T', 'T']]), tid='df'),
              dict(site('lf', 'std::fs::write', origin='lang'), tid='w')]
        rsp, rip = os.path.join(td, 'rs.jsonl'), os.path.join(td, 'ri.jsonl')
        open(rsp, 'w').write(''.join(json.dumps(r) + '\n' for r in rs))
        open(rip, 'w').write(''.join(json.dumps(r) + '\n' for r in [
            {'tname': 'Tr', 'method': 'go', 'self': 'Loud', 'fn': 'lf', 'path': 'k::<Loud as Tr>::go'},
            {'tname': 'Tr', 'method': 'go', 'self': 'Quiet', 'fn': 'qf', 'path': 'k::<Quiet as Tr>::go'}]))
        ok(reach(rsp, rip, 'probe_e')[0] == 'REACH', 'reach: Loud instantiation reaches Fs')
        # r4_unrel2_q: two traits both named TV; the site names v1's (pure) default; v2's default is effectful
        r2 = [{'decl': 'u', 'path': 'k::unrel_q'}, {'decl': 'd1', 'path': 'k::v1::<dyn TV>::gv'}, {'decl': 'd2', 'path': 'k::v2::<dyn TV>::gv'},
              dict(site('u', 'k::v1::<dyn TV>::gv', outcome='trait_decl', subst=[['Self', 'R2', None]]), tid='d1'),
              dict(site('d2', 'std::fs::write', origin='lang'), tid='w')]
        r2s, r2i = os.path.join(td, 'r2s.jsonl'), os.path.join(td, 'r2i.jsonl')
        open(r2s, 'w').write(''.join(json.dumps(r) + '\n' for r in r2))
        open(r2i, 'w').write(''.join(json.dumps(r) + '\n' for r in [
            {'tname': 'TV', 'method': 'gv', 'self': '<default>', 'fn': 'd1', 'path': 'k::v1::<dyn TV>::gv', 'trait': 'T1', 'has_body': True},
            {'tname': 'TV', 'method': 'gv', 'self': '<default>', 'fn': 'd2', 'path': 'k::v2::<dyn TV>::gv', 'trait': 'T2', 'has_body': True}]))
        ok(reach(r2s, r2i, 'unrel_q')[0] == 'NOREACH', 'reach: a same-NAMED other trait\'s effectful default is not charged (r4_unrel2_q)')
        # the CHA path (Self still a type parameter): only implementors of the NAMED trait's identity are candidates
        r3 = [{'decl': 'g', 'path': 'k::gen_q'}, {'decl': 'd1', 'path': 'k::v1::<dyn TV>::gv'}, {'decl': 'i2', 'path': 'k::<W as TV>::gv'},
              dict(site('g', 'k::v1::<dyn TV>::gv', outcome='trait_decl', subst=[['Self', 'T', 'T']]), tid='d1'),
              dict(site('i2', 'std::fs::write', origin='lang'), tid='w')]
        r3s, r3i = os.path.join(td, 'r3s.jsonl'), os.path.join(td, 'r3i.jsonl')
        open(r3s, 'w').write(''.join(json.dumps(r) + '\n' for r in r3))
        open(r3i, 'w').write(''.join(json.dumps(r) + '\n' for r in [
            {'tname': 'TV', 'method': 'gv', 'self': '<default>', 'fn': 'd1', 'path': 'k::v1::<dyn TV>::gv', 'trait': 'T1', 'has_body': False},
            {'tname': 'TV', 'method': 'gv', 'self': 'W', 'fn': 'i2', 'path': 'k::<W as TV>::gv', 'trait': 'T2'}]))
        ok(reach(r3s, r3i, 'gen_q')[0] == 'NOREACH', 'reach: CHA over a type parameter fans out to the named trait\'s implementors only')
        ok(reach(rsp, rip, 'probe_q')[0] == 'NOREACH', 'reach: the Quiet-only twin stays pure WITH substitution')
        ok(reach(rsp, rip, 'probe_q', no_subst=True)[0] == 'REACH', 'reach --no-subst (SCIP proxy): the twin falls to CHA and charges')
    finally:
        shutil.rmtree(td, ignore_errors=True)
    print(f'selftest: {"FAIL " + str(len(fails)) if fails else "OK"}')
    return 1 if fails else 0


# ------------------------------------------------------------------------------------------------------------- main
def main(argv):
    if not argv or argv[0] in ('-h', '--help'):
        print(__doc__)
        return 0 if argv else 2

    def opt(k, d=None):
        return argv[argv.index(k) + 1] if k in argv else d
    if argv[0] == '--selftest':
        return _selftest()
    if argv[0] == 'run':
        ents = [l.strip() for l in open(argv[1]) if l.strip() and not l.startswith('#')]
        only = set(opt('--only').split(',')) if opt('--only') else None
        if only:
            ents = [e for e in ents if entry_name(e) in only]
        ra_bin, cs_bin, work, out = opt('--ra'), opt('--cs'), opt('--work'), opt('--out')
        if not all((ra_bin, cs_bin or opt('--cs-from'), work, out)):
            print('run: --ra --cs --work --out are required', file=sys.stderr)
            return 2
        os.makedirs(work, exist_ok=True)
        os.makedirs(out, exist_ok=True)
        jobs = int(opt('--jobs', '2'))
        import concurrent.futures as cf
        with cf.ThreadPoolExecutor(jobs) as ex:
            futs = {ex.submit(run_one, e, ra_bin, cs_bin, work, out, '--online' in argv, opt('--cs-from')): e for e in ents}
            for f in cf.as_completed(futs):
                try:
                    rc = f.result()
                except Exception as exc:     # an entry that crashes the driver is NOT a measurement, and says so
                    rc = f'driver error {exc!r}'
                print(f'{entry_name(futs[f])}\t{rc}', flush=True)
        return summary(out)
    if argv[0] == 'diff':
        return diff_dir(argv[1])
    if argv[0] == 'summary':
        return summary(argv[1])
    if argv[0] == 'gate':
        return gate(argv[1], opt('--cs'), opt('--tree'))
    if argv[0] == 'fixture':
        rest = [a for a in argv[2:] if not a.startswith('--')]
        flags = {argv[i] for i in range(len(argv)) if argv[i].startswith('--')}
        probes = [a for i, a in enumerate(argv[2:], 2) if not a.startswith('--') and not argv[i - 1] in flags]
        del rest
        return fixture(argv[1], probes, opt('--ra'), opt('--cs'), opt('--target-dir'), opt('--work'))
    if argv[0] == 'scip-reach':
        st, eff, mode = scip_reach(argv[1], argv[2], '--trace' in argv)
        print(st, ','.join(sorted(eff)) or '-', mode)
        return 0
    if argv[0] == 'reach':
        st, eff, mode = reach(argv[1], argv[2], argv[3], '--no-subst' in argv, '--trace' in argv)
        print(st, ','.join(sorted(eff)) or '-', mode)
        return 0
    print(__doc__)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
