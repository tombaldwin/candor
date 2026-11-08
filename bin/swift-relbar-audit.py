#!/usr/bin/env python3
"""swift-relbar-audit.py — an INDEPENDENT checker for swift 1->0 release-bar cells (published arm vs candidate).

It shares no code with candor-swift. It reads the engine's REPORTS only as data (which cells moved, and the pub/head
call graphs used to collapse leaves onto roots), and decides every verdict from the SOURCE with its own Swift lexer,
declaration index, binder scopes, receiver typing and sink scan. Built for the rb157 audit (2026-11-08, see
~/candor-handoff/swift-rb157/); the R1105 precedent says a removal at scale needs a checker that does not share the
lane's model.

    swift-relbar-audit.py --corpus DIR --pub DIR --head DIR --cells TSV --out JSON

  --pub/--head  per-entry report dirs (DIR/<entry>/report.*.json + .callgraph.json), the published arm and the candidate.
  --cells       TSV: entry<TAB>fn<TAB>effect, one 1->0 cell per line (an `incomplete` marker is the effect `incomplete`).
  --corpus      DIR/<entry>/ holds each entry's source tree.

A CLEAN RESULT IS EVIDENCE ONLY BESIDE SEEDS THAT FIRED. The rb157 harness (~/candor-handoff/swift-rb157/seeds.py)
plants four defects in copies of the real inputs: (i) a dropped edge whose callee is effectful in both arms, (ii) a
C3 -- a hedge removed while an implementor in another file is effectful, (iii) a lost `incomplete` with a non-literal
locator left uncovered, (iv) a propagation chain where only the root is effectful (leaves must FLAG by attribution).
Run it, or an equivalent, on the same arms before trusting a clean audit.

ROOTS. A cell collapses onto the root(s) that explain it in the PUB graph:
  OWN       the unit's own pub `direct` carried the effect (for Unknown, its unknownWhy names the key: dispatch:P.m);
  LOSTEDGE  a pub edge A->C, with C carrying the effect on pub, is absent on head;
  UNION     an interfaceUnion row: its roots are those of its same-member implementor rows;
  PROPAGATED the pub edge is still present on head but the callee lost the effect: recurse into the callee.
A leaf inherits its root's verdict only if every edge on its pub path is still present on head (EDGE-IDENTICAL).

RULES (one per root class; each verdict comes from source):
  LOSTEDGE  every reference to C's name in A's body must be shown NOT to bind C: the identifier is bound by a closure
            parameter / local / parameter, or the receiver / operand types to a type other than C's owner, or the
            operand is `nil`. Any reference left unresolved FLAGS. Then any member call on a rebound name (`x.m(...)`)
            must be covered on head (a resolved edge to `*.m`, or an Unknown whose why names `.m`), else FLAG.
  OWN dispatch:P.m (a lost hedge)  enumerate EVERY in-tree declaration of member m on a type conforming to P
            (directly, by extension, or through refinement) and on P's own extensions; sink-scan each. Any sink FLAGS.
            Also reports whether P declares m at all, P's visibility (public => out-of-tree conformers possible), and
            the operand/receiver types at each call site of m in the root body.
  OWN concrete (rare)  sink-scan the root body for that effect.
  incomplete  the marker must have arrived only through a LOSTEDGE that does not bind; and every locator-bearing call
            in the root body with a NON-literal locator must be covered on head (Unknown naming it, or `incomplete`).
  UNPROPAGATED  the edge A->C survives and C still carries the effect on head but A lost it: every reference must bind
            statically to a concrete type whose own declarations of the member are sink-free.
  Any root: the root body is sink-scanned for the lost effect (Unknown: any effect), following typed calls (and
            untyped ones by name; an ambiguous name is scanned one hop). A sink reached only through a call that the
            head row hedges by name (`dispatch:<...>.m`) or still charges is HEDGED -- release-bar slot (d) -- and a
            HEDGED leaf must itself carry Unknown on head. Any other sink FLAGS.
  Limits, stated: the sink lists are name patterns (SINKS); property reads on a rebound name are not required to be
  hedged (only calls); test/benchmark/example targets are excluded from reach (a library cannot call them).

Exit: 0 every root CLEAN or HEDGED, 1 any FLAG (or a leaf with no root). The JSON names every root,
its rule, its evidence and every leaf's path check.
"""
import argparse, collections, copy, glob, json, os, re, sys

# ----------------------------------------------------------------------------------------------- lexer
OPCH = set('/=-+!*%<>&|^~?')
PUNCT = set('(){}[],:;@#')


def lex(src, line0=1):
    """Swift tokens [(kind, text, line)]. kinds: id num str op p (punct) dot. Comments dropped; string interpolations
    are lexed inline (their tokens follow the str token) so calls inside "\\(...)" are seen."""
    out = []
    i, n, line = 0, len(src), line0
    while i < n:
        c = src[i]
        if c == '\n':
            line += 1; i += 1; continue
        if c in ' \t\r':
            i += 1; continue
        if src.startswith('//', i):
            j = src.find('\n', i); i = n if j < 0 else j; continue
        if src.startswith('/*', i):
            d, j = 1, i + 2
            while j < n and d:
                if src.startswith('/*', j): d += 1; j += 2
                elif src.startswith('*/', j): d -= 1; j += 2
                else:
                    if src[j] == '\n': line += 1
                    j += 1
            i = j; continue
        if c == '#' and i + 1 < n and src[i + 1] in '"#':          # raw string #"..."#
            k = i
            while k < n and src[k] == '#': k += 1
            hashes = k - i
            if k < n and src[k] == '"':
                multi = src.startswith('"""', k)
                q = '"""' if multi else '"'
                end = src.find(q + '#' * hashes, k + len(q))
                end = n if end < 0 else end + len(q) + hashes
                line += src.count('\n', i, end); out.append(('str', src[i:end], line)); i = end; continue
        if c == '"':
            multi = src.startswith('"""', i)
            q = '"""' if multi else '"'
            j = i + len(q); start_line = line; buf_start = j; interps = []
            while j < n:
                if src[j] == '\\' and j + 1 < n and src[j + 1] == '(':
                    d, k = 1, j + 2
                    while k < n and d:
                        if src[k] == '(': d += 1
                        elif src[k] == ')': d -= 1
                        elif src[k] == '"':                   # nested string inside interpolation
                            m = src.find('"', k + 1); k = n if m < 0 else m
                        k += 1
                    interps.append((src[j + 2:k - 1], line + src.count('\n', i, j)))
                    j = k; continue
                if src[j] == '\\': j += 2; continue
                if src.startswith(q, j): break
                if not multi and src[j] == '\n': break
                j += 1
            end = min(n, j + len(q))
            out.append(('str', src[i:end], start_line))
            for body, ln in interps:
                out.extend(lex(body, ln))
            line += src.count('\n', i, end); i = end; continue
        if c.isalpha() or c == '_' or c == '$':
            j = i + 1
            while j < n and (src[j].isalnum() or src[j] in '_$'): j += 1
            out.append(('id', src[i:j], line)); i = j; continue
        if c == '`':
            j = src.find('`', i + 1); j = n if j < 0 else j
            out.append(('id', src[i + 1:j], line)); i = j + 1; continue
        if c.isdigit():
            j = i + 1
            while j < n and (src[j].isalnum() or src[j] in '_.'):
                if src[j] == '.' and not (j + 1 < n and src[j + 1].isdigit()): break
                j += 1
            out.append(('num', src[i:j], line)); i = j; continue
        if c == '.':
            if src.startswith('...', i): out.append(('op', '...', line)); i += 3; continue
            if src.startswith('..<', i): out.append(('op', '..<', line)); i += 3; continue
            out.append(('dot', '.', line)); i += 1; continue
        if c in OPCH:
            j = i + 1
            while j < n and src[j] in OPCH: j += 1
            out.append(('op', src[i:j], line)); i = j; continue
        out.append(('p', c, line)); i += 1
    return out


def match_close(T, i):
    """index of the bracket closing T[i] (one of ( [ {)."""
    o = T[i][1]; c = {'(': ')', '[': ']', '{': '}'}[o]; d = 0
    for j in range(i, len(T)):
        if T[j][0] == 'p':
            if T[j][1] == o: d += 1
            elif T[j][1] == c:
                d -= 1
                if d == 0: return j
    return len(T) - 1


# ----------------------------------------------------------------------------------------------- index
TESTPATH = re.compile(r'/(Tests|Benchmarks|Benchmark|Examples|IntegrationTests|Snippets)/')
TYPEKW = {'struct', 'class', 'enum', 'actor', 'protocol', 'extension'}
MODS = {'public', 'private', 'fileprivate', 'internal', 'open', 'package', 'static', 'final', 'override', 'mutating',
        'nonmutating', 'convenience', 'required', 'lazy', 'weak', 'unowned', 'indirect', 'nonisolated', 'dynamic',
        'optional', 'consuming', 'borrowing', 'distributed', 'async'}


class Decl:
    __slots__ = ('kind', 'name', 'owner', 'file', 'line', 'toks', 'b0', 'b1', 'params', 'vis', 'sig')

    def __repr__(self):
        return '%s %s.%s @%s:%d' % (self.kind, self.owner, self.name, self.file, self.line)


def norm_type(s):
    s = re.sub(r'<.*>', '', s or '')
    s = s.replace('?', '').replace('!', '').replace('inout', '').replace('some ', '').replace('any ', '')
    s = re.sub(r'@\w+', '', s).strip()
    if s.startswith('[') or s.startswith('('): return None
    return s.split()[0] if s.split() else None


class Index:
    def __init__(self, root):
        self.root = root
        self.decls = []                         # functions / inits / subscripts / computed vars / accessors
        self.fields = collections.defaultdict(dict)   # owner -> name -> type (stored or computed var with annotation)
        self.conforms = collections.defaultdict(set)  # type -> {protocol or superclass}
        self.protocols = {}                     # protocol name -> (vis, set(member names declared))
        self.byname = collections.defaultdict(list)
        self.files = {}
        for p in sorted(glob.glob(os.path.join(root, '**', '*.swift'), recursive=True)):
            if '/.build/' in p: continue
            rel = os.path.relpath(p, root)
            try: src = open(p, encoding='utf-8', errors='replace').read()
            except OSError: continue
            T = lex(src); self.files[rel] = T
            self._walk(rel, T, 0, len(T), [])
        for d in self.decls:
            if not TESTPATH.search('/' + d.file): self.byname[d.name].append(d)

    def _walk(self, rel, T, a, b, owner):
        i = a
        while i < b:
            k, t, ln = T[i]
            if k == 'id' and t in TYPEKW and i + 1 < b and T[i + 1][0] == 'id':
                # name (dotted for extensions)
                j = i + 1; name = T[j][1]
                while j + 2 < b and T[j + 1][0] == 'dot' and T[j + 2][0] == 'id':
                    name += '.' + T[j + 2][1]; j += 2
                # generic params
                j += 1
                if j < b and T[j][1] == '<':
                    d = 0
                    while j < b:
                        if T[j][1].startswith('<'): d += T[j][1].count('<')
                        if T[j][1].endswith('>'): d -= T[j][1].count('>')
                        j += 1
                        if d <= 0: break
                inh = []
                if j < b and T[j][1] == ':':
                    j += 1
                    while j < b and not (T[j][0] == 'p' and T[j][1] == '{') and not (T[j][0] == 'id' and T[j][1] == 'where'):
                        if T[j][0] == 'id': inh.append(T[j][1])
                        j += 1
                while j < b and not (T[j][0] == 'p' and T[j][1] == '{'): j += 1
                if j >= b: i += 1; continue
                close = match_close(T, j)
                full = name if t == 'extension' or not owner else '.'.join(owner + [name])
                if t == 'extension':
                    full = name
                vis = 'public' if any(T[x][1] in ('public', 'open', 'package') for x in range(max(a, i - 4), i)) else 'internal'
                for x in inh:
                    self.conforms[full].add(x)
                if t == 'protocol':
                    mem = set()
                    for x in range(j, close):
                        if T[x][0] == 'id' and T[x][1] in ('func', 'var', 'subscript', 'init') and x + 1 < close:
                            nm = T[x + 1][1] if T[x][1] in ('func', 'var') else T[x][1]
                            mem.add(nm)
                    self.protocols[full] = (vis, mem)
                self._walk(rel, T, j + 1, close, full.split('.') if t == 'extension' else owner + [name])
                i = close + 1; continue
            if k == 'id' and t in ('func', 'init', 'subscript', 'deinit'):
                d = Decl(); d.kind = t; d.file = rel; d.line = ln; d.owner = '.'.join(owner)
                j = i + 1
                if t == 'func':
                    d.name = T[j][1] if j < b else '?'; j += 1
                else:
                    d.name = t
                    if j < b and T[j][1] in ('?', '!'): j += 1
                if j < b and T[j][1].startswith('<'):
                    dd = 0
                    while j < b:
                        dd += T[j][1].count('<') - T[j][1].count('>'); j += 1
                        if dd <= 0: break
                d.params = {}
                if j < b and T[j][1] == '(':
                    pc = match_close(T, j); d.params = parse_params(T, j + 1, pc); j = pc + 1
                d.sig = j
                # body
                while j < b and not (T[j][0] == 'p' and T[j][1] in '{};') and not (T[j][0] == 'id' and T[j][1] in ('func', 'var', 'let', 'init')):
                    j += 1
                vis = 'public' if any(T[x][1] in ('public', 'open', 'package') for x in range(max(a, i - 5), i)) else 'internal'
                d.vis = vis; d.toks = T
                if j < b and T[j][1] == '{':
                    d.b0, d.b1 = j, match_close(T, j)
                    self.decls.append(d); i = d.b1 + 1; continue
                d.b0 = d.b1 = None; self.decls.append(d); i = j; continue
            if k == 'id' and t in ('var', 'let') and i + 1 < b and T[i + 1][0] == 'id':
                name = T[i + 1][1]; j = i + 2; ty = None
                if j < b and T[j][1] == ':':
                    s = j + 1; e = s
                    while e < b and T[e][2] == T[s][2] and not (T[e][0] == 'p' and T[e][1] in '{;') and T[e][1] != '=':
                        if T[e][0] == 'p' and T[e][1] in '([':
                            e = match_close(T, e)
                        e += 1
                    ty = ''.join(x[1] for x in T[s:e]); j = e
                if owner and ty:
                    self.fields['.'.join(owner)][name] = ty
                if j < b and T[j][0] == 'p' and T[j][1] == '{' and owner:
                    d = Decl(); d.kind = 'var'; d.name = name; d.owner = '.'.join(owner); d.file = rel; d.line = ln
                    d.params = {}; d.toks = T; d.b0, d.b1 = j, match_close(T, j); d.sig = j
                    d.vis = 'public' if any(T[x][1] in ('public', 'open', 'package') for x in range(max(a, i - 5), i)) else 'internal'
                    self.decls.append(d); i = d.b1 + 1; continue
                i = j if j > i else i + 1; continue
            if k == 'id' and t == 'case' and owner:
                # enum case declarations are not decls with bodies; skip the line
                i += 1; continue
            i += 1

    # --- queries
    def decl_at(self, rel, line):
        best = None
        for d in self.decls:
            if d.file == rel and line <= d.line <= line + 3 and d.b0 is not None:
                if best is None or d.line < best.line: best = d
        return best

    def field_type(self, owner, name):
        if not hasattr(self, '_fs'):
            self._fs = collections.defaultdict(dict)       # last component -> merged fields
            for cand, fs in self.fields.items():
                for k, v in fs.items(): self._fs[cand.split('.')[-1]].setdefault(k, v)
        o = owner
        while o:
            fs = self.fields.get(o) or {}
            if name in fs: return norm_type(fs[name])
            fs = self._fs.get(o.split('.')[-1]) or {}
            if name in fs: return norm_type(fs[name])
            o = '.'.join(o.split('.')[:-1])
        return None

    def _short(self):
        if not hasattr(self, '_bys'):
            self._bys = collections.defaultdict(set)      # last component -> {direct supers}
            for cand, ps in self.conforms.items(): self._bys[cand.split('.')[-1]] |= ps
            self._sup = {}
        return self._bys

    def supers(self, ty):
        """every protocol / superclass `ty` reaches, transitively (keyed by last name component)."""
        bys = self._short(); k = ty.split('.')[-1]
        if k in self._sup: return self._sup[k]
        seen = set(); stack = [k]
        while stack:
            for p in bys.get(stack.pop(), ()):
                if p not in seen: seen.add(p); stack.append(p.split('.')[-1])
        self._sup[k] = seen
        return seen

    def conformers(self, proto):
        """every type (or protocol) that reaches `proto` through conformance or refinement, transitively."""
        p = proto.split('.')[-1]
        return {ty for ty in list(self.conforms) if p in {x.split('.')[-1] for x in self.supers(ty)}}


def parse_params(T, a, b):
    """internal names -> type text, for a parameter clause T[a:b]."""
    out = {}; i = a; seg = []
    def flush(seg):
        if not seg: return
        ids = []
        k = 0
        while k < len(seg) and not (seg[k][1] == ':'):
            if seg[k][0] == 'id': ids.append(seg[k][1])
            k += 1
        ty = ''.join(x[1] for x in seg[k + 1:]) if k < len(seg) else ''
        ty = ty.split('=')[0]
        if ids: out[ids[-1]] = ty
    d = 0
    while i < b:
        tk = T[i]
        if tk[0] == 'p' and tk[1] in '([': d += 1
        if tk[0] == 'p' and tk[1] in ')]': d -= 1
        if d == 0 and tk[0] == 'p' and tk[1] == ',': flush(seg); seg = []
        else: seg.append(tk)
        i += 1
    flush(seg)
    return out


# ----------------------------------------------------------------------------------------------- binders & typing
def closure_params(T, lb, rb):
    """names bound by the closure whose `{` is at lb, if it has an `in` clause."""
    j = lb + 1; names = []
    if j < rb and T[j][1] == '[':
        j = match_close(T, j) + 1
    k = j
    while k < rb and k < j + 40:
        if T[k][0] == 'id' and T[k][1] == 'in':
            for x in range(j, k):
                if T[x][0] == 'id' and T[x][1] not in ('_', 'inout', 'async', 'throws') and not (x + 1 < k and T[x + 1][1] == '.') \
                        and not (x > j and T[x - 1][1] == ':') and not (x > j and T[x - 1][0] == 'dot'):
                    names.append(T[x][1])
            return set(names)
        if T[k][0] == 'p' and T[k][1] in '{}': return set()
        k += 1
    return set()


BINDKW = {'let', 'var'}


def binders_before(T, a, i):
    """names bound by let/var/case-let/for/catch inside T[a:i] at any depth (approximation used for the enclosing
    blocks only)."""
    out = set(); k = a
    while k < i:
        t = T[k]
        if t[0] == 'id' and t[1] in BINDKW:
            j = k + 1
            if j < i and T[j][0] == 'id': out.add(T[j][1])
            elif j < i and T[j][1] == '(':
                for x in range(j, match_close(T, j)):
                    if T[x][0] == 'id': out.add(T[x][1])
        if t[0] == 'id' and t[1] == 'for':
            j = k + 1
            if j < i and T[j][0] == 'id' and T[j][1] not in ('try', 'await', 'case'): out.add(T[j][1])
            elif j < i and T[j][1] == '(':
                for x in range(j, match_close(T, j)):
                    if T[x][0] == 'id': out.add(T[x][1])
        k += 1
    return out


def bound_at(T, d, i, name):
    """is identifier `name` at token i (inside decl d's body) bound by something other than an outer/global name?"""
    if name in d.params: return 'parameter'
    # enclosing braces of i within the body
    stack = []; j = d.b0
    while j <= i:
        if T[j][0] == 'p' and T[j][1] == '{':
            stack.append(j)
        elif T[j][0] == 'p' and T[j][1] == '}':
            if stack: stack.pop()
        j += 1
    for lb in reversed(stack):
        if name in closure_params(T, lb, match_close(T, lb)): return 'closure-parameter'
    for lb in reversed(stack):
        if name in binders_before(T, lb + 1, i): return 'local'
    return None


NONEXPR = {'unsafe', 'try', 'await', 'return', 'in', 'else', 'case', 'throw', 'where', 'let', 'var', 'if', 'guard'}


def chain_before(T, i):
    """receiver chain tokens for a member reference whose `.` is at T[i-1] (T[i] the member). Returns list of ids
    (outermost first), [] for an implicit member (`.name` with no receiver), or None if not a plain chain."""
    out = []; j = i - 2
    if j >= 0 and (T[j][0] in ('op', 'p') and T[j][1] not in (')', ']') or T[j][0] == 'id' and T[j][1] in NONEXPR):
        return []
    while j >= 0:
        if T[j][0] == 'id':
            out.append(T[j][1])
            if j - 1 >= 0 and T[j - 1][0] == 'dot': j -= 2; continue
            break
        if T[j][0] == 'p' and T[j][1] == ')':
            return None
        return None
    return list(reversed(out))


def type_chain(ix, d, T, chain, at):
    if not chain: return None
    head = chain[0]
    if head == 'self': ty = d.owner
    elif head in d.params: ty = norm_type(d.params[head])
    elif head and head[0].isupper(): ty = head
    else:
        ty = None
        # a local with an explicit annotation  `let head: T`
        for k in range(d.b0, at):
            if T[k][0] == 'id' and T[k][1] in BINDKW and k + 3 < at and T[k + 1][1] == head and T[k + 2][1] == ':':
                ty = norm_type(T[k + 3][1]); break
        if ty is None:
            for k in range(d.b0, at):
                if T[k][0] == 'id' and T[k][1] in BINDKW and k + 2 < at and T[k + 1][1] == head and T[k + 2][1] == '=':
                    j = k + 3
                    while j < at and T[j][1] in ('try', 'await', '?', '!'): j += 1
                    seq = []
                    while j < at and T[j][0] in ('id', 'dot'):
                        if T[j][0] == 'id': seq.append(T[j][1])
                        j += 1
                    if seq and j < at and T[j][1] == '(':
                        fname = seq[-1]
                        rts = {ret_type(c) for c in ix.byname.get(fname, [])
                               if (len(seq) == 1 or seq[0] == 'self') and owner_match(ix, c.owner, d.owner) or seq[0][:1].isupper() and owner_match(ix, c.owner, seq[0])}
                        rts.discard(None)
                        if len(rts) == 1: ty = rts.pop()
                        elif fname[:1].isupper() and len(seq) == 1: ty = fname        # T(...) constructs a T
                    break
        if ty is None:
            ty = ix.field_type(d.owner, head)
    for f in chain[1:]:
        if ty is None: return None
        ty = ix.field_type(ty, f)
    return ty


def same_type(a, b):
    if not a or not b: return False
    a, b = a.split('.')[-1], b.split('.')[-1]
    return a == b


# ----------------------------------------------------------------------------------------------- sinks
SINKS = {
    'Clock': [r'\bDate \( \)', r'\bDate \. now\b', r'\b(NIODeadline|DispatchTime|DispatchWallTime|ContinuousClock|SuspendingClock|NIODeadline) \. now\b',
              r'\b(gettimeofday|clock_gettime|mach_absolute_time|CFAbsoluteTimeGetCurrent|usleep|nanosleep)\b', r'\bTask \. sleep\b',
              r'\btimeIntervalSinceNow\b', r'\bsystemUptime\b'],
    'Env': [r'\bProcessInfo\b', r'\b(getenv|setenv|unsetenv|environ|getcwd|NSHomeDirectory|NSTemporaryDirectory)\b', r'\bCommandLine\b',
            r'\bhomeDirectoryForCurrentUser\b', r'\bcurrentDirectoryPath\b'],
    'Net': [r'\b(socket|getaddrinfo|sendto|recvfrom|sendmsg|recvmsg|NWConnection|NWListener|URLSession)\b',
            r'\b(ClientBootstrap|ServerBootstrap|DatagramBootstrap)\b', r'\bconnect \( to\b', r'\bconnect \( host\b', r'\bbind \( to\b'],
    'Fs': [r'\bFileManager\b', r'\b(fopen|unlink|rmdir|mkdir|opendir|readdir|lstat|FileHandle|realpath)\b', r'\b(Data|String|NSData|NSString) \( contentsOf', r'\bcontentsOfFile\b',
           r'\bwrite \( to(File)?\b', r'\bopen \( '],
    'Exec': [r'\bProcess \( \)', r'\b(posix_spawn|fork|execve|execvp|popen)\b', r'\bsystem \( '],
    'Rand': [r'\b(arc4random|arc4random_uniform|SystemRandomNumberGenerator|randomElement|shuffled)\b', r'\bUUID \( \)', r'\. random \( '],
    'Db': [r'\bsqlite3_\w+'],
}
SINKRE = {k: [re.compile(p) for p in v] for k, v in SINKS.items()}
LOCATOR = [re.compile(p) for p in (r'\bconnect \( to : (\S+)', r'\bbind \( to : (\S+)', r'\bURL \( string : (\S+)',
                                     r'\bopen \( (\S+)', r'\bFileManager \. default \. \w+ \( atPath : (\S+)',
                                     r'\bconnect \( host : (\S+)')]


def body_text(T, a, b):
    return ' '.join(t[1] for t in T[a:b + 1])


AMBIG = 4


def owner_match(ix, owner, want):
    """does a decl owned by `owner` serve a receiver of static type `want`?"""
    if not owner or not want: return False
    o, w = owner.split('.')[-1], want.split('.')[-1]
    return o == w or o in {x.split('.')[-1] for x in ix.supers(want)}


def ret_type(dd):
    T = dd.toks
    for k in range(dd.sig or dd.b0, dd.b0 or 0):
        if T[k][1] == '->' and k + 1 < len(T): return norm_type(T[k + 1][1])
    return None


def call_targets(ix, dd):
    """[(name, candidates, how)] for each call in dd's body. Typed where the receiver types; by name otherwise."""
    T = dd.toks; out = []
    for k in range(dd.b0 + 1, dd.b1):
        if T[k][0] != 'id': continue
        is_call = k + 1 <= dd.b1 and T[k + 1][0] == 'p' and T[k + 1][1] in '({'
        member = T[k - 1][0] == 'dot'
        if not (is_call or member): continue
        nm = T[k][1]; cands = [c for c in ix.byname.get(nm, []) if c is not dd]
        if not cands: continue
        if member:
            ch = chain_before(T, k)
            if ch == []: want = ret_type(dd)                  # implicit member: the contextual type, best effort
            elif ch and ch[0][:1].isupper() and len(ch) == 1: want = ch[0]
            elif ch: want = type_chain(ix, dd, T, ch, k)
            else: want = None
            if want:
                typed = [c for c in cands if owner_match(ix, c.owner, want)]
                out.append((nm, typed, 'typed:' + want)); continue
        else:
            if bound_at(T, dd, k, nm): continue
            own = [c for c in cands if owner_match(ix, c.owner, dd.owner)]
            if own: out.append((nm, own, 'self')); continue
            glob_ = [c for c in cands if not c.owner]
            if glob_: out.append((nm, glob_, 'global')); continue
        out.append((nm, cands, 'by-name'))
    return out


def scan_body(dd, effects):
    txt = body_text(dd.toks, dd.b0, dd.b1); hits = []
    for e in effects:
        for rx in SINKRE.get(e, []):
            m = rx.search(txt)
            if m: hits.append((e, m.group(0)))
    return hits


def sink_scan(ix, d, effects, depth=2, skip=frozenset()):
    """sink hits reachable from d's body. Calls whose receiver types are followed to that type's (and its
    protocols') declarations; bare calls to the enclosing type, then to globals. An untyped call with at most AMBIG
    same-named declarations follows all of them; one with more is not recursed into, but each candidate body is still
    scanned directly (one hop), so an ambiguous name cannot hide a sink sitting in its own body."""
    hits = []; seen = set(); frontier = [(d, [repr(d)])]
    for lvl in range(depth + 1):
        nxt = []
        for dd, path in frontier:
            if id(dd) in seen or dd.b0 is None: continue
            seen.add(id(dd))
            hits += [(e, m, path) for e, m in scan_body(dd, effects)]
            if lvl < depth:
                for nm, cands, how in call_targets(ix, dd):
                    if nm in skip: continue
                    if how == 'by-name' and len(cands) > AMBIG:
                        for c in cands:
                            if id(c) in seen or c.b0 is None: continue
                            hits += [(e, m, path + ['%s|%s (ambiguous x%d, one hop)' % (nm, repr(c), len(cands))])
                                     for e, m in scan_body(c, effects)]
                        continue
                    for c in cands:
                        nxt.append((c, path + ['%s|%s' % (nm, repr(c))]))
        frontier = nxt
    return hits


# ----------------------------------------------------------------------------------------------- reports
def load_arm(d, entry):
    rows, cg = collections.defaultdict(list), collections.defaultdict(set)
    for p in glob.glob(os.path.join(d, entry, 'report.*.json')):
        if p.endswith('.hierarchy.json'): continue
        j = json.load(open(p))
        if p.endswith('.callgraph.json'):
            for f, cs in j.items(): cg[f].update(cs)
        else:
            for r in j.get('functions', []): rows[r['fn']].append(r)
    return rows, cg


def eff(rows, fn):
    s = set()
    for r in rows.get(fn, []):
        s |= set(r.get('inferred', []))
        if r.get('incomplete'): s.add('incomplete')
    return s


def field(rows, fn, k):
    out = []
    for r in rows.get(fn, []):
        v = r.get(k)
        if isinstance(v, list): out += v
        elif v: out.append(v)
    return out


def collapse(P, H, fn, x, seen, path):
    pr, pc = P; hr, hc = H
    fn = fn[2:] if fn.startswith('U:') else fn
    out = []
    if x in field(pr, fn, 'direct'):
        out.append({'kind': 'OWN', 'root': fn, 'why': field(pr, fn, 'unknownWhy') if x == 'Unknown' else [], 'path': path})
    for c in sorted(pc.get(fn, ())):
        if x not in eff(pr, c): continue
        if c not in hc.get(fn, set()):
            out.append({'kind': 'LOSTEDGE', 'root': fn, 'callee': c, 'path': path}); continue
        if x in eff(hr, c):
            # the edge survives and the callee still carries x, yet this unit lost it: propagation was cut here
            out.append({'kind': 'UNPROPAGATED', 'root': fn, 'callee': c, 'path': path}); continue
        if c in seen: continue
        seen.add(c); out += collapse(P, H, c, x, seen, path + [c])
    if not out and any(r.get('interfaceUnion') for r in pr.get(fn, [])):
        mem = fn.split('.', 1)[-1] if '.' in fn else fn
        owner = fn.rsplit('.' + mem, 1)[0] if False else None
        member = fn[len(fn.split('.')[0]) + 1:]
        for g in sorted(pr):
            if g != fn and g.endswith('.' + member) and x in eff(pr, g) and x not in eff(hr, g) and g not in seen:
                seen.add(g); out.append({'kind': 'UNION', 'root': fn, 'implementor': g, 'path': path})
                out += collapse(P, H, g, x, seen, path + ['U:' + g])
    return out


# ----------------------------------------------------------------------------------------------- rules
def loc_of(rows, fn):
    for r in rows.get(fn, []):
        if r.get('loc'): return r['loc']
    return None


def callee_ref(callee):
    """(owner, member) for a callgraph node name."""
    base = re.sub(r'#\d+$', '', callee)
    base = re.sub(r'\(.*\)$', '', base)
    if base.endswith('.==') or base.endswith('.!='):
        return base[:-3], base[-2:]
    if '.' not in base: return None, base
    o, m = base.rsplit('.', 1)
    return o, m


def rule_lostedge(ix, d, callee, hrow_why, hcg_callees):
    T = d.toks; owner, member = callee_ref(callee)
    refs = []
    for k in range(d.b0 + 1, d.b1):
        tk = T[k]
        if member in ('==', '!='):
            if tk[0] == 'op' and tk[1] in ('==', '!='):
                ch = chain_before(T, k + 1) if T[k - 1][0] == 'id' else None
                left = ch if ch else None
                # left operand: postfix chain ending at k-1
                lch = []; j = k - 1
                while j >= d.b0 and T[j][0] == 'id':
                    lch.append(T[j][1])
                    if T[j - 1][0] == 'dot': j -= 2
                    else: break
                lch = list(reversed(lch))
                right = T[k + 1] if k + 1 < d.b1 else ('', '', 0)
                if right[0] == 'id' and right[1] == 'nil':
                    refs.append((tk[2], tk[1], 'NOT-BOUND', 'operand is nil (Optional nil comparison)')); continue
                lt = type_chain(ix, d, T, lch, k) if lch else None
                rch = []
                j = k + 1
                while j < d.b1 and T[j][0] in ('id', 'dot'):
                    if T[j][0] == 'id': rch.append(T[j][1])
                    if j + 1 < d.b1 and T[j + 1][0] == 'dot': j += 2; continue
                    break
                rt = type_chain(ix, d, T, rch, k) if rch and T[k + 1][0] == 'id' else None
                if right[0] == 'str': rt = 'String'
                elif right[0] == 'num': rt = 'Int' if '.' not in right[1] else 'Double'
                for tt in (lt, rt):
                    if tt and not same_type(tt, owner):
                        refs.append((tk[2], tk[1], 'NOT-BOUND', 'operand types to %s, callee owner %s' % (tt, owner))); break
                else:
                    if lt and same_type(lt, owner) or rt and same_type(rt, owner):
                        refs.append((tk[2], tk[1], 'BINDS', 'operand types to %s' % owner))
                    else:
                        refs.append((tk[2], tk[1], 'UNRESOLVED', 'operands %s / %s untyped' % ('.'.join(lch), '.'.join(rch))))
            continue
        if tk[0] == 'id' and tk[1] == member:
            if T[k - 1][0] == 'dot':
                ch = chain_before(T, k)
                if ch is None:
                    refs.append((tk[2], member, 'UNRESOLVED', 'receiver is not a plain chain')); continue
                rt = type_chain(ix, d, T, ch, k)
                if rt is None:
                    refs.append((tk[2], member, 'UNRESOLVED', 'receiver %s untyped' % '.'.join(ch)))
                elif owner and same_type(rt, owner):
                    refs.append((tk[2], member, 'BINDS', 'receiver %s : %s' % ('.'.join(ch), rt)))
                elif owner and owner.split('.')[-1] in ix.supers(rt):
                    refs.append((tk[2], member, 'BINDS', 'receiver %s : %s conforms to %s' % ('.'.join(ch), rt, owner)))
                else:
                    refs.append((tk[2], member, 'NOT-BOUND', 'receiver %s : %s, callee owner %s' % ('.'.join(ch), rt, owner)))
            else:
                if T[k - 1][0] == 'id' and T[k - 1][1] in ('func', 'var', 'let', 'case'): continue
                if k + 1 < d.b1 and T[k + 1][1] == ':' and T[k - 1][1] in ('(', ','): continue       # argument label
                b = bound_at(T, d, k, member)
                if b: refs.append((tk[2], member, 'NOT-BOUND', 'bound by ' + b))
                elif owner is None:
                    refs.append((tk[2], member, 'BINDS', 'unbound identifier reaches the global'))
                elif same_type(d.owner, owner) or d.owner.split('.')[-1] in (owner.split('.')[-1],):
                    refs.append((tk[2], member, 'BINDS', 'implicit self member of ' + d.owner))
                else:
                    refs.append((tk[2], member, 'UNRESOLVED', 'bare identifier, owner %s vs %s' % (d.owner, owner)))
    verdict = 'CLEAN'
    if not refs: verdict = 'FLAG'; refs.append((d.line, member, 'NO-REFERENCE', 'no reference to the callee name in the body'))
    if any(r[2] in ('BINDS', 'UNRESOLVED') for r in refs): verdict = 'FLAG'
    # real member calls on a rebound name must be covered on head
    uncovered = []
    if owner is None:
        for k in range(d.b0 + 1, d.b1 - 1):
            if T[k][0] == 'id' and T[k][1] == member and T[k + 1][0] == 'dot' and T[k + 2][0] == 'id':
                j = k + 2
                while j + 2 < d.b1 and T[j + 1][0] == 'dot' and T[j + 2][0] == 'id': j += 2
                if not (j + 1 < d.b1 and T[j + 1][0] == 'p' and T[j + 1][1] in '({'): continue   # a property read, no call
                m = T[j][1]
                if bound_at(T, d, k, member) is None: continue
                cov = any(w.endswith('.' + m) for w in hrow_why) or any(re.sub(r'\(.*$', '', c).endswith('.' + m) for c in hcg_callees)
                if not cov: uncovered.append((T[k][2], member + '.' + m))
    if uncovered: verdict = 'FLAG'
    return verdict, {'refs': refs, 'uncoveredRealSites': uncovered}


def rule_hedge(ix, key, root_decl, effects):
    m = re.match(r'dispatch:(.*)\.([^.]+)$', key)
    if not m: return 'FLAG', {'note': 'unparsed key ' + key}
    proto, member = m.group(1), m.group(2)
    pshort = proto.split('.')[-1]
    pinfo = None
    for p, v in ix.protocols.items():
        if p == pshort or p.endswith('.' + pshort): pinfo = (p, v)
    confs = ix.conformers(pshort) | {pshort}
    impls = []
    for dd in ix.byname.get(member, []):
        o = dd.owner
        if o in confs or o.split('.')[-1] in {c.split('.')[-1] for c in confs}:
            impls.append(dd)
    hits = []
    for dd in impls:
        for h in sink_scan(ix, dd, effects, depth=1):
            hits.append((repr(dd),) + h[:2])
    # stored-property implementors (a requirement satisfied by a stored field) are pure by construction
    stored = sorted(c for c in confs if member in ix.fields.get(c, {}) and not any(dd.owner == c for dd in impls))
    sites = []
    if root_decl is not None:
        T = root_decl.toks
        for k in range(root_decl.b0 + 1, root_decl.b1):
            if T[k][1] == member:
                lch = []; j = k - 1
                if member in ('==', '!=', '<', '>', '<=', '>=', '+', '-'):
                    j = k - 1
                    while j > root_decl.b0 and T[j][0] == 'id':
                        lch.append(T[j][1])
                        if T[j - 1][0] == 'dot': j -= 2
                        else: break
                    lch = list(reversed(lch))
                elif T[k - 1][0] == 'dot':
                    lch = chain_before(T, k) or []
                ty = type_chain(ix, root_decl, T, lch, k) if lch else None
                sites.append((T[k][2], '.'.join(lch) or '?', ty))
    declares = bool(pinfo and member in pinfo[1][1])
    vis = pinfo[1][0] if pinfo else 'not-in-tree'
    verdict = 'FLAG' if hits else 'CLEAN'
    return verdict, {'protocol': pinfo[0] if pinfo else proto, 'protocolVisibility': vis, 'protocolDeclaresMember': declares,
                     'conformers': sorted(confs)[:40], 'nConformers': len(confs),
                     'implementors': [repr(x) for x in impls][:40], 'nImplementors': len(impls), 'storedImplementors': stored,
                     'sinkHits': hits, 'callSites': sites}


def rule_unpropagated(ix, ds, callee, effects):
    """the edge A->C survives, C still carries the effect on head, but A does not. Clean only if every reference to
    C's member in A binds statically to a concrete type whose own declarations (or its protocols' extensions) of that
    member are sink-free -- i.e. the interface-wide charge on C never applied to this call."""
    owner, member = callee_ref(callee); refs = []
    for d in ds:
        T = d.toks
        for k in range(d.b0 + 1, d.b1):
            if T[k][0] == 'id' and T[k][1] == member and T[k - 1][0] == 'dot':
                ch = chain_before(T, k) or []
                want = ch[0] if len(ch) == 1 and ch[0][:1].isupper() else (type_chain(ix, d, T, ch, k) if ch else None)
                if not want or same_type(want, owner):
                    refs.append((T[k][2], '.'.join(ch) + '.' + member, 'UNRESOLVED', 'receiver %s does not pin a concrete type' % want)); continue
                cands = [c for c in ix.byname.get(member, []) if owner_match(ix, c.owner, want)]
                hits = [h for c in cands for h in sink_scan(ix, c, effects, depth=2)]
                refs.append((T[k][2], '.'.join(ch) + '.' + member, 'FLAG' if hits or not cands else 'CLEAN',
                             {'type': want, 'candidates': [repr(c) for c in cands], 'hits': hits[:5]}))
    v = 'CLEAN' if refs and all(r[2] == 'CLEAN' for r in refs) else 'FLAG'
    return v, {'refs': refs}


def rule_incomplete(ix, d, hrow_why, head_incomplete):
    T = d.toks; txt_hits = []
    txt = body_text(T, d.b0, d.b1)
    for rx in LOCATOR:
        for mm in rx.finditer(txt):
            arg = mm.group(1)
            literal = arg.startswith('"')
            api = mm.group(0).split(' ')[0]
            cov = head_incomplete or any(w.endswith('.' + api) for w in hrow_why)
            txt_hits.append({'site': mm.group(0)[:60], 'literal': literal, 'coveredOnHead': cov})
    bad = [h for h in txt_hits if not h['literal'] and not h['coveredOnHead']]
    return ('FLAG' if bad else 'CLEAN'), {'locatorSites': txt_hits}


# ----------------------------------------------------------------------------------------------- driver
def audit(args, cells, corpus, pub, head):
    ixs, arms = {}, {}
    roots = {}; leaves = []
    for e, fn, x in cells:
        if e not in arms:
            arms[e] = (load_arm(pub, e), load_arm(head, e))
        P, H = arms[e]
        rs = collapse(P, H, fn, x, {fn}, [fn])
        leaf = {'entry': e, 'fn': fn, 'effect': x, 'roots': []}
        for r in rs:
            if r['kind'] == 'UNION': continue
            key = (e, r['kind'], r['root'], r.get('callee') or ','.join(r.get('why', [])), x)
            roots.setdefault(key, {'entry': e, 'kind': r['kind'], 'root': r['root'], 'callee': r.get('callee'),
                                   'why': r.get('why', []), 'effect': x, 'leaves': []})
            # edge-identity of the propagation path
            path = r['path']; hc = H[1]; hr = H[0]
            def hop_ok(a_, b_):
                a_ = a_[2:] if a_.startswith('U:') else a_
                if b_.startswith('U:'):          # a union-membership hop: the implementor must still exist on head
                    return b_[2:] in hc or b_[2:] in hr
                return b_ in hc.get(a_, set())
            ident = all(hop_ok(path[i], path[i + 1]) for i in range(len(path) - 1))
            roots[key]['leaves'].append({'fn': fn, 'path': path, 'edgeIdentical': ident})
            leaf['roots'].append({'key': list(key), 'edgeIdentical': ident})
        leaves.append(leaf)
    for key, R in roots.items():
        e = R['entry']; P, H = arms[e]
        if e not in ixs: ixs[e] = Index(os.path.join(corpus, e))
        ix = ixs[e]
        loc = loc_of(P[0], R['root'])
        d = None
        if loc:
            f, ln = loc.split(':')[:2]; d = ix.decl_at(f, int(ln))
        merged = d is not None and '(' not in R['root']      # an engine name without a signature merges same-named decls
        ds = ([d] + [x for x in ix.decls if merged and x is not d and x.b0 is not None
                     and x.owner == d.owner and x.name == d.name]) if d else []
        # an engine unit name can merge same-named declarations (a getter and a setter func, overloads);
        # judge the union of their bodies so no merged body is skipped
        R['loc'] = loc; R['decl'] = [repr(x) for x in ds]
        effects = list(SINKS) if R['effect'] in ('Unknown', 'incomplete') else [R['effect']]
        hwhy = field(H[0], R['root'], 'unknownWhy'); hcg = H[1].get(R['root'], set())
        checks = {}
        if d is None:
            R['verdict'] = 'FLAG'; R['evidence'] = {'note': 'root has no source declaration at ' + str(loc)}; continue
        if R['kind'] == 'LOSTEDGE':
            evs = [rule_lostedge(ix, x, R['callee'], hwhy, hcg)[1] for x in ds]
            refs = [r for ev in evs for r in ev['refs'] if r[2] != 'NO-REFERENCE']
            unc = [u for ev in evs for u in ev['uncoveredRealSites']]
            v = 'FLAG' if (not refs or unc or any(r[2] in ('BINDS', 'UNRESOLVED') for r in refs)) else 'CLEAN'
            checks['lostedge'] = (v, {'refs': refs or [('-', '-', 'NO-REFERENCE', 'no merged body references the callee')],
                                      'uncoveredRealSites': unc})
            if R['effect'] == 'incomplete':
                v2, ev2 = rule_incomplete(ix, d, hwhy, 'incomplete' in eff(H[0], R['root'])); checks['incomplete'] = (v2, ev2)
        elif R['kind'] == 'UNPROPAGATED':
            checks['unpropagated'] = rule_unpropagated(ix, ds, R['callee'], effects)
        elif R['kind'] == 'OWN':
            keys = [w for w in R['why'] if w.startswith('dispatch:')]
            for w in keys:
                checks['hedge ' + w] = rule_hedge(ix, w, d, list(SINKS))
            others = [w for w in R['why'] if not w.startswith('dispatch:')]
            if others: checks['other-why'] = ('FLAG', {'note': 'lost hedge reasons this rule does not judge', 'why': others})
        skip = {callee_ref(R['callee'])[1]} if R.get('callee') else set()
        if R['kind'] == 'OWN':
            skip |= {re.sub(r'.*\.', '', w) for w in R['why']}
        sh = [h for x in ds for h in sink_scan(ix, x, effects, depth=2, skip=frozenset(skip))]
        heff = eff(H[0], R['root'])
        cov, unc = [], []
        for h in sh:
            e_, m_, path_ = h
            first = path_[1].split('|')[0] if len(path_) > 1 else re.split(r'[ (.]', m_.strip())[0]
            ok = e_ in heff or ('Unknown' in heff and any(w.endswith('.' + first) or w.endswith(':' + first) for w in hwhy))
            (cov if ok else unc).append(h)
        checks['sinkReach'] = ('FLAG' if unc else ('HEDGED' if cov else 'CLEAN'),
                               {'uncovered': unc[:20], 'coveredOnHead': cov[:20],
                                'note': 'a covered hit is reached only through a call the head row charges or hedges by name'})
        R['checks'] = {k: {'verdict': v[0], 'evidence': v[1]} for k, v in checks.items()}
        vs = [v[0] for v in checks.values()]
        R['verdict'] = 'FLAG' if 'FLAG' in vs else ('HEDGED' if 'HEDGED' in vs else 'CLEAN')
    for L in leaves:
        vs = []
        for r in L['roots']:
            R = roots[tuple(r['key'])]
            v = R['verdict'] if r['edgeIdentical'] else 'FLAG'
            if v == 'HEDGED' and 'Unknown' not in eff(arms[L['entry']][1][0], L['fn']): v = 'FLAG'
            vs.append(v)
        L['verdict'] = 'NOROOT' if not vs else ('FLAG' if 'FLAG' in vs else ('HEDGED' if 'HEDGED' in vs else 'CLEAN'))
    return roots, leaves


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--corpus', required=True); ap.add_argument('--pub', required=True); ap.add_argument('--head', required=True)
    ap.add_argument('--cells', required=True); ap.add_argument('--out', required=True)
    a = ap.parse_args()
    cells = []
    for l in open(a.cells):
        p = l.rstrip('\n').split('\t')
        if len(p) >= 3 and not l.startswith('#'): cells.append(tuple(p[:3]))
    roots, leaves = audit(a, cells, a.corpus, a.pub, a.head)
    out = {'roots': [dict(v, key=list(k)) for k, v in roots.items()], 'leaves': leaves}
    json.dump(out, open(a.out, 'w'), indent=1, default=str)
    c = collections.Counter(R['verdict'] for R in roots.values()); lc = collections.Counter(L['verdict'] for L in leaves)
    print('swift-relbar-audit: %d cells -> %d roots; roots %s; leaves %s' % (len(cells), len(roots), dict(c), dict(lc)))
    for k, R in sorted(roots.items()):
        print('%-5s %-9s %s %s %s %s' % (R['verdict'], R['kind'], R['entry'], R['effect'], R['root'][:70],
                                       (R.get('callee') or ','.join(R['why']))[:60]))
    return 1 if c.get('FLAG') or lc.get('FLAG') or lc.get('NOROOT') else 0


if __name__ == '__main__':
    sys.exit(main())
